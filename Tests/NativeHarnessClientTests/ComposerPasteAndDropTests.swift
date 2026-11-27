import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Pasted and dropped files and images reach the composer as the same typed inputs its pickers
/// produce. These use private pasteboards and an unshown window; the user's clipboard, a real
/// drag session and real key events are not involved.
@MainActor
final class ComposerPasteAndDropTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("nhc-composer-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func pngData(width: Int = 4, height: Int = 3) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.setColor(.systemRed, atX: 0, y: 0)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Input projection

    func testFilesBecomeTheInputsThePickersWouldHaveMade() throws {
        let folder = try makeFolder()
        let image = folder.appending(path: "shot.png"), audio = folder.appending(path: "memo.m4a")
        let source = folder.appending(path: "main.swift"), directory = folder.appending(path: "Sources", directoryHint: .isDirectory)
        for file in [image, audio, source] { try Data("x".utf8).write(to: file) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = [image, audio, source, directory, source]

        let codex = ComposerAttachmentIntake.inputs(forFiles: files, policy: .init(harness: .codex))
        XCTAssertEqual(codex.inputs, [
            .localImage(image.standardizedFileURL, detail: .auto),
            .localAudio(audio.standardizedFileURL),
            .mention(name: "main.swift", path: source.standardizedFileURL),
            .mention(name: "Sources", path: directory.standardizedFileURL)
        ], "Each file is added once, even when it is pasted twice")
        XCTAssertNil(codex.notice)

        // Claude has no audio envelope, so the recording is referenced by path like any file.
        let claude = ComposerAttachmentIntake.inputs(forFiles: files, policy: .init(harness: .claudeCode))
        XCTAssertEqual(claude.inputs, [
            .localImage(image.standardizedFileURL, detail: .auto),
            .mention(name: "memo.m4a", path: audio.standardizedFileURL),
            .mention(name: "main.swift", path: source.standardizedFileURL),
            .mention(name: "Sources", path: directory.standardizedFileURL)
        ])

        // An agent that declined images keeps `@`, so the image travels as a path line.
        let declined = ComposerAttachmentIntake.inputs(
            forFiles: [image], policy: .init(harness: .kimiCode, negotiatedImageInput: false))
        XCTAssertEqual(declined.inputs, [.mention(name: "shot.png", path: image.standardizedFileURL)])

        // A harness with no attachment surface says so instead of dropping the file.
        let cursor = ComposerAttachmentIntake.inputs(forFiles: [image, source], policy: .init(harness: .cursorAgent))
        XCTAssertEqual(cursor.inputs, [])
        XCTAssertEqual(cursor.notice, L10n.string("Unsupported attachment type"))
    }

    func testAPastedImageIsAPrivateFileThatTravelsLikeAPickedOne() throws {
        let folder = try makeFolder()
        let data = try pngData()
        let stored = try ComposerAttachmentIntake.storePastedImage(data, in: folder)
        XCTAssertEqual(try Data(contentsOf: stored), data)
        XCTAssertEqual(stored.pathExtension, "png")
        let fileMode = try FileManager.default.attributesOfItem(atPath: stored.path(percentEncoded: false))[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(
            atPath: stored.deletingLastPathComponent().path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(folderMode, 0o700)
        // Two pastes never share a file.
        XCTAssertNotEqual(try ComposerAttachmentIntake.storePastedImage(data, in: folder), stored)

        let image = try XCTUnwrap(CodexUserInput.localAttachment(for: stored))
        let mention = CodexUserInput.mention(name: "README.md", path: URL(filePath: "/repo/README.md"))
        let draft = CodexComposerDraft(inputs: [.text("What changed?"), image, mention])
        guard case let .send(input) = HarnessComposerInputPolicy(harness: .claudeCode).submission(for: draft) else {
            return XCTFail("Claude carries a pasted image and a mention")
        }
        XCTAssertEqual(input.images.map(\.mimeType), ["image/png"])
        XCTAssertEqual(input.promptText, "What changed?\n@/repo/README.md")
        XCTAssertEqual(try input.encodedImages().map(\.base64Data), [data.base64EncodedString()])
        // Codex keeps its own typed envelopes, so the draft is the wire input.
        XCTAssertEqual(draft.inputs.map(\.jsonValue)[1], .object([
            "type": .string("localImage"), "path": .string(stored.standardizedFileURL.path(percentEncoded: false)),
            "detail": .string("auto")
        ]))
    }

    // MARK: - Paste handling

    func testPasteTakesFilesThenLeavesTextAloneThenTakesAnImage() throws {
        let png = try pngData()
        let files = makePasteboard()
        files.clearContents()
        files.writeObjects([URL(filePath: "/tmp/a.swift") as NSURL, URL(filePath: "/tmp/b.png") as NSURL])
        files.addTypes([.string], owner: nil)
        files.setString("a.swift\nb.png", forType: .string)
        XCTAssertEqual(ComposerExternalInput.read(from: files, isPaste: true),
                       .files([URL(filePath: "/tmp/a.swift"), URL(filePath: "/tmp/b.png")]))

        // A spreadsheet range or a styled snippet also offers a picture of itself; it stays text.
        let textWithPicture = makePasteboard()
        textWithPicture.declareTypes([.string, .png], owner: nil)
        textWithPicture.setString("A1\tB1", forType: .string)
        textWithPicture.setData(png, forType: .png)
        XCTAssertNil(ComposerExternalInput.read(from: textWithPicture, isPaste: true))
        // Dragged, the same content is an image: there is no text reading to preserve.
        XCTAssertEqual(ComposerExternalInput.read(from: textWithPicture, isPaste: false), .image(png, type: .png))

        let text = makePasteboard()
        text.declareTypes([.string], owner: nil)
        text.setString("plain text", forType: .string)
        XCTAssertNil(ComposerExternalInput.read(from: text, isPaste: true))
        XCTAssertFalse(ComposerExternalInput.canRead(from: text))

        let screenshot = makePasteboard()
        let tiff = try XCTUnwrap(NSImage(data: png)?.tiffRepresentation)
        screenshot.declareTypes([.tiff], owner: nil)
        screenshot.setData(tiff, forType: .tiff)
        XCTAssertTrue(ComposerExternalInput.canRead(from: screenshot))
        guard case let .image(data, type) = ComposerExternalInput.read(from: screenshot, isPaste: true) else {
            return XCTFail("An image with no text is an attachment")
        }
        let converted = try XCTUnwrap(ComposerExternalInput.pngData(data, type: type))
        XCTAssertEqual(Array(converted.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(NSBitmapImageRep(data: converted)?.pixelsWide, 4)
        XCTAssertEqual(ComposerExternalInput.pngData(png, type: .png), png, "A copied PNG is kept as it was")
    }

    func testOnlyCommandVIsThePasteShortcut() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 9,
                 ignoringModifiers: String? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                isARepeat: false, keyCode: keyCode
            ))
        }
        XCTAssertTrue(ComposerExternalInput.isPasteShortcut(try key("v", .command)))
        XCTAssertTrue(ComposerExternalInput.isPasteShortcut(try key("v", [.command, .capsLock])))
        XCTAssertFalse(ComposerExternalInput.isPasteShortcut(try key("v", [.command, .shift])))
        XCTAssertFalse(ComposerExternalInput.isPasteShortcut(try key("v", [.command, .option])))
        XCTAssertFalse(ComposerExternalInput.isPasteShortcut(try key("v", [])))
        XCTAssertFalse(ComposerExternalInput.isPasteShortcut(try key("c", .command, keyCode: 8)))
        // The key is read as it types with ⌘, as the menu bar reads it (`NSEvent.commandShortcutKey`):
        // 2-Set Korean and Russian type ㅍ and м on the V key without ⌘, and v with it.
        XCTAssertTrue(ComposerExternalInput.isPasteShortcut(try key("v", .command, ignoringModifiers: "ㅍ")))
        XCTAssertTrue(ComposerExternalInput.isPasteShortcut(try key("v", .command, ignoringModifiers: "м")))
        XCTAssertFalse(ComposerExternalInput.isPasteShortcut(try key("c", .command, keyCode: 8, ignoringModifiers: "ㅊ")))
    }

    // MARK: - The composer's own text field

    private struct TwoComposers: View {
        @State var first = ""
        @State var second = ""
        let onInput: (String, ComposerExternalInput) -> Void

        var body: some View {
            VStack(spacing: 20) {
                composer("first", text: $first)
                composer("second", text: $second)
            }
            .padding(20)
            .frame(width: 420, height: 320)
        }

        private func composer(_ name: String, text: Binding<String>) -> some View {
            ComposerTextField(text: text, placeholder: name, accessibilityLabel: name, accessibilityHint: nil,
                              style: ComposerTextStyle(), lineLimit: 2...8, minHeight: nil, actions: ComposerTextActions())
                .padding(12)
                .frame(height: 120)
                .overlay {
                    ComposerExternalInputTarget(isTargeted: .constant(false)) { onInput(name, $0) }
                }
        }
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    func testTheTargetLetsClicksThroughAndPastesOnlyIntoItsOwnField() throws {
        var received: [(String, ComposerExternalInput)] = []
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: TwoComposers { received.append(($0, $1)) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let targets = views(ComposerExternalInputView.self, in: hosting)
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        let fields = views(ComposerMarkdownTextView.self, in: hosting)
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(targets.allSatisfy { Set($0.registeredDraggedTypes).isSuperset(of: [.fileURL, .png, .tiff]) })
        XCTAssertFalse(targets.contains { $0.registeredDraggedTypes.contains(.string) },
                       "A text drag still goes to the text field")

        // A click on the text lands on the text field, not on the target above it.
        let firstField = fields[0]
        let center = firstField.convert(NSPoint(x: firstField.bounds.midX, y: firstField.bounds.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.superview?.hitTest(center) ?? hosting.hitTest(center))
        XCTAssertFalse(hit is ComposerExternalInputView)
        XCTAssertTrue(hit === firstField || hit.isDescendant(of: firstField), "\(type(of: hit))")

        // Editing the first field: ⌘V with an image belongs to the first composer only.
        XCTAssertTrue(window.makeFirstResponder(firstField))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(targets[0].owns(editor))
        XCTAssertFalse(targets[1].owns(editor))

        let png = try pngData()
        let image = makePasteboard()
        image.declareTypes([.png], owner: nil)
        image.setData(png, forType: .png)
        let paste = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
        XCTAssertTrue(targets[0].handlePaste(paste, pasteboard: image))
        XCTAssertFalse(targets[1].handlePaste(paste, pasteboard: image))
        XCTAssertEqual(received.map(\.0), ["first"])
        XCTAssertEqual(received.first?.1, .image(png, type: .png))

        // Text on the pasteboard is left to the editor's own paste.
        let text = makePasteboard()
        text.declareTypes([.string], owner: nil)
        text.setString("hello", forType: .string)
        XCTAssertFalse(targets[0].handlePaste(paste, pasteboard: text))

        // An input method still composing keeps the key as well.
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(targets[0].handlePaste(paste, pasteboard: image))
        editor.unmarkText()
        XCTAssertEqual(received.count, 1)
        window.contentView = nil
    }

    // MARK: - ComposerMarkdownTextView paste

    /// A `ComposerMarkdownTextView` on its own. The paste contract is exercised through
    /// `preferredPasteboardType(from:restrictedToTypesFrom:)` and `readSelection(from:type:)` against
    /// private pasteboards from `makePasteboard()`, so this file's header contract (lines 6-8)
    /// holds: the user's clipboard is not involved, and these tests run under
    /// `scripts/test-fast.sh`'s four parallel `xctest` processes without racing on OS state.
    private func makeStagedTextView() -> ComposerMarkdownTextView {
        _ = NSApplication.shared
        return ComposerMarkdownTextView()
    }

    func testReadableAndAcceptableTypesListBothTheModernUtiAndTheLegacyStringType() {
        let view = makeStagedTextView()
        let legacy = ComposerMarkdownTextView.legacyStringPasteboardType
        XCTAssertEqual(legacy.rawValue, "NSStringPboardType")
        // AppKit's `-[NSTextView pasteAsPlainText:]` and its menu-item validation restrict the
        // preferred-type pick to `["NSStringPboardType"]`; leaving the legacy UTI out makes the
        // intersection with `readablePasteboardTypes` empty, so every text paste is a silent no-op.
        XCTAssertTrue(view.readablePasteboardTypes.contains(.string))
        XCTAssertTrue(view.readablePasteboardTypes.contains(legacy))
        // A text drag is sent to the text field (see `testTheTargetLetsClicksThroughAndPastesOnlyIntoItsOwnField`),
        // so the drag types stay in step with the paste types.
        XCTAssertTrue(view.acceptableDragTypes.contains(.string))
        XCTAssertTrue(view.acceptableDragTypes.contains(legacy))
    }

    /// The core proof of the fix: with the legacy type in `readablePasteboardTypes`, the
    /// `pasteAsPlainText:`-style restriction picks a type rather than coming up empty. The `paste:`
    /// path runs with no restriction and still finds a readable type on the same pasteboard.
    func testPreferredTypeFindsAReadableTypeForBothPasteAndPasteAsPlainText() throws {
        let view = makeStagedTextView()
        let legacy = ComposerMarkdownTextView.legacyStringPasteboardType
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello 안녕", forType: .string)
        let available = pasteboard.types ?? []
        // macOS bridges a string written under `.string` to the legacy type on any pasteboard,
        // which is what makes the `pasteAsPlainText:` restriction land on a value at runtime.
        XCTAssertTrue(available.contains(legacy))

        let pasteAsPlainTextType = view.preferredPasteboardType(from: available, restrictedToTypesFrom: [legacy])
        XCTAssertNotNil(pasteAsPlainTextType,
                        "`pasteAsPlainText:` would come up empty without the legacy type in `readablePasteboardTypes`")
        XCTAssertNotNil(view.preferredPasteboardType(from: available, restrictedToTypesFrom: nil),
                        "`paste:` sends no restriction and reads whatever the view says it can")

        let chosen = try XCTUnwrap(pasteAsPlainTextType)
        XCTAssertTrue(view.readSelection(from: pasteboard, type: chosen))
        XCTAssertEqual(view.string, "hello 안녕")
    }

    /// RTF and plain text on a private pasteboard: the composer (because of `isRichText = false`
    /// and `paste(_:)` forwarding to `pasteAsPlainText(_:)`) inserts only the plain text, with no
    /// color or size carried over from the RTF.
    func testRichTextOnAPrivatePasteboardStillInsertsOnlyThePlainText() throws {
        let view = makeStagedTextView()
        let legacy = ComposerMarkdownTextView.legacyStringPasteboardType
        let rtf = try XCTUnwrap(NSAttributedString(
            string: "styled text",
            attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.boldSystemFont(ofSize: 24)]
        ).rtf(from: NSRange(location: 0, length: "styled text".utf16.count)))
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("styled text", forType: .string)

        let available = pasteboard.types ?? []
        let chosen = try XCTUnwrap(view.preferredPasteboardType(from: available, restrictedToTypesFrom: [legacy]),
                                   "`pasteAsPlainText:` still lands on a plain-text type even when RTF is also on the pasteboard")
        XCTAssertTrue(view.readSelection(from: pasteboard, type: chosen))
        XCTAssertEqual(view.string, "styled text")

        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertGreaterThan(storage.length, 0)
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotEqual(attrs[.foregroundColor] as? NSColor, .systemRed,
                          "A red run from the RTF would have survived the plain-text paste")
        XCTAssertNotEqual((attrs[.font] as? NSFont)?.pointSize, 24,
                          "The RTF's 24pt size would have survived the plain-text paste")
    }

    /// AppKit splits a pasteboard that declares only `.string` into both the modern UTI and the
    /// legacy `NSStringPboardType`. This confirms the bridge, which is what the fix relies on to
    /// make `pasteAsPlainText:`'s intersection non-empty.
    func testMacOSBridgesStringUtiToNSStringPboardTypeOnAPrivatePasteboard() {
        let legacy = ComposerMarkdownTextView.legacyStringPasteboardType
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("ready", forType: .string)
        let available = pasteboard.types ?? []
        XCTAssertTrue(available.contains(.string))
        XCTAssertTrue(available.contains(legacy),
                      "macOS always exposes the legacy string pasteboard type alongside `.string`")
    }

    /// `validateUserInterfaceItem(_:)` for `paste:` asks `preferredPasteboardType` with no
    /// restriction; for `pasteAsPlainText:` it restricts to `["NSStringPboardType"]`. Observed
    /// read-only, with no writes to `NSPasteboard.general`, through a local subclass that captures
    /// each restriction before forwarding to `super`.
    func testValidationAsksPreferredTypeWithNilForPasteAndLegacyForPasteAsPlainText() {
        final class Recording: ComposerMarkdownTextView, @unchecked Sendable {
            var pasteRestriction: Recorded = .notCalled
            var matchRestriction: Recorded = .notCalled
            var currentSelector: Selector?
            enum Recorded: Equatable { case notCalled, called([NSPasteboard.PasteboardType]?) }
            override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType],
                                                  restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
                switch currentSelector {
                case #selector(NSText.paste(_:)): pasteRestriction = .called(allowedTypes)
                case #selector(NSTextView.pasteAsPlainText(_:)): matchRestriction = .called(allowedTypes)
                default: break
                }
                return super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
            }
        }
        let view = Recording()
        let pasteSel = #selector(NSText.paste(_:))
        let matchSel = #selector(NSTextView.pasteAsPlainText(_:))

        view.currentSelector = pasteSel
        _ = view.validateUserInterfaceItem(NSMenuItem(title: "Paste", action: pasteSel, keyEquivalent: ""))
        view.currentSelector = matchSel
        _ = view.validateUserInterfaceItem(NSMenuItem(title: "Paste and Match Style", action: matchSel, keyEquivalent: ""))
        view.currentSelector = nil

        XCTAssertEqual(view.pasteRestriction, .called(nil),
                       "`paste:` validation asks for any readable type on the view")
        let legacy = ComposerMarkdownTextView.legacyStringPasteboardType
        XCTAssertEqual(view.matchRestriction, .called([legacy]),
                       "`pasteAsPlainText:` validation restricts to the legacy string type")
        // And the intersection the fix widens is non-empty: with the legacy type in
        // `readablePasteboardTypes`, the restricted pick succeeds for a pasteboard that offers it.
        XCTAssertEqual(view.preferredPasteboardType(from: [.string, legacy], restrictedToTypesFrom: [legacy]), legacy)
    }
}
