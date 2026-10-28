import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// An attached image in the composer shows as a thumbnail (2026-10-16: a pasted image used to read
/// "image.png"), decoded off the main thread at a bounded size and shared with the sent message's
/// preview; a pasted image is called "Image", and an image that cannot be read falls back to its
/// name. Renders of the task composer and of the sent request go to `.build/composer-image-chip-qa`
/// in light and dark. No provider, CLI, app window or screen capture.
@MainActor
final class ComposerImageChipTests: XCTestCase {
    private var scratch: URL!
    private var pasted: [URL] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "composer-image-chip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        // Only the folders this test pasted into; other pastes in the shared folder stay.
        for url in pasted { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    // MARK: - Model

    func testAnImageChipIsAThumbnailAndAPastedImageIsCalledImage() throws {
        let pastedURL = ComposerAttachmentIntake.pastedImageDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory).appending(path: "image.png")
        let picked = URL(filePath: "/Users/me/Desktop/Screen Shot 2026-10-16.png")
        let inline = try XCTUnwrap(InlineImageInput.url(mimeType: "image/png", base64: Data([0x89, 0x50]).base64EncodedString()))
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/image.png"))

        XCTAssertEqual(ComposerChipContent(.localImage(pastedURL, detail: .auto)),
                       .thumbnail(pastedURL, name: L10n.string("Image")), "Not the made-up file name")
        XCTAssertEqual(ComposerChipContent(.localImage(picked, detail: .auto)),
                       .thumbnail(picked, name: "Screen Shot 2026-10-16.png"))
        XCTAssertEqual(ComposerChipContent(.image(inline, detail: .auto)), .thumbnail(inline, name: L10n.string("Image")))
        XCTAssertEqual(ComposerChipContent(.image(remote, detail: .auto)), .label(symbol: "photo", text: "image.png"),
                       "A remote image is never fetched")
        XCTAssertEqual(ComposerChipContent(.mention(name: "README.md", path: URL(filePath: "/repo/README.md"))),
                       .label(symbol: "at", text: "@README.md"))
        XCTAssertEqual(ComposerChipContent(.localAudio(URL(filePath: "/tmp/note.m4a"))),
                       .label(symbol: "waveform", text: "note.m4a"))

        // The sent message calls it the same.
        XCTAssertNil(TranscriptImageAttachment(url: pastedURL).name)
        XCTAssertEqual(TranscriptImageAttachment(url: picked).name, "Screen Shot 2026-10-16.png")
    }

    func testOnlyAFileThatAPasteWroteIsAPastedImage() throws {
        let folder = scratch.appending(path: "pastes", directoryHint: .isDirectory)
        let stored = try ComposerAttachmentIntake.storePastedImage(try png(width: 4, height: 4), in: folder)
        XCTAssertTrue(ComposerAttachmentIntake.isPastedImage(stored, in: folder))
        XCTAssertFalse(ComposerAttachmentIntake.isPastedImage(folder.appending(path: "image.png"), in: folder))
        XCTAssertFalse(ComposerAttachmentIntake.isPastedImage(
            stored.deletingLastPathComponent().appending(path: "shot.png"), in: folder))
        XCTAssertFalse(ComposerAttachmentIntake.isPastedImage(stored, in: scratch))
        XCTAssertFalse(ComposerAttachmentIntake.isPastedImage(stored), "Not the app's own paste folder")
        let real = try paste(width: 4, height: 4)
        XCTAssertTrue(ComposerAttachmentIntake.isPastedImage(real))
    }

    // MARK: - The composer

    func testThePastedImageShowsAsAThumbnailThatKeepsItsNameAndRemoveButton() async throws {
        let image = try paste(width: 1_400, height: 900, hue: 0.58)
        _ = await TranscriptImageThumbnails.shared.preview(for: image)
        let draft = TaskComposerDraft()
        draft.attachments = [.localImage(image, detail: .auto)]
        let host = WindowlessRender.Host(AnyView(PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
            .frame(width: 760, height: 220, alignment: .bottom)), size: NSSize(width: 760, height: 220))
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        // As the label chip reads: the group, the image by its name, its remove button.
        let chip = [L10n.string("Attached input"), L10n.string("Image"), L10n.string("Remove attachment")]
        XCTAssertEqual(Array(elements.prefix(3).map(\.label)), chip, "\(elements)")
        // A click opens it over the window, so it reads as a button, as a sent message's thumbnail does.
        XCTAssertEqual(elements[1].role, "AXButton")
        XCTAssertFalse(elements.contains { $0.value == "image.png" || $0.label == "image.png" })
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Remove attachment")))
        host.settle()
        XCTAssertTrue(draft.attachments.isEmpty)
    }

    func testThePreviewIsBoundedAndAMissingImageFallsBackToItsName() async throws {
        let wide = try paste(width: 4_000, height: 1_000)
        guard case let .image(preview) = await TranscriptImageThumbnails.shared.preview(for: wide) else {
            return XCTFail("A pasted image has a preview")
        }
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), TranscriptImageThumbnails.longSidePixels)
        XCTAssertLessThanOrEqual(min(preview.width, preview.height), TranscriptImageThumbnails.shortSidePixels)

        // Not read beforehand: the chip's own task finds that the file is gone.
        let missing = scratch.appending(path: "deleted-mockup.png")
        TranscriptImageThumbnails.shared.discardCachedPreview(for: missing)
        let draft = TaskComposerDraft()
        draft.attachments = [.localImage(missing, detail: .auto)]
        let host = WindowlessRender.Host(AnyView(PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
            .frame(width: 760, height: 200, alignment: .bottom)), size: NSSize(width: 760, height: 200))
        defer { host.close() }
        await host.settle { host.accessibilityElements().dropFirst(2).first?.role == "AXStaticText" }
        let elements = host.accessibilityElements()
        // The name chip, as before: the group, the photo symbol, the name, its remove button.
        XCTAssertEqual(elements.prefix(4).map(\.role), ["AXGroup", "AXImage", "AXStaticText", "AXButton"], "\(elements)")
        XCTAssertEqual(elements.first?.label, L10n.string("Attached input"))
        XCTAssertEqual(elements.dropFirst(2).first?.value, "deleted-mockup.png")
    }

    /// NSCache may drop a preview at any time. A chip that found its image's fallback in the cache
    /// keeps it when its body is read again after the entry is gone; it does not fall back to an
    /// empty tile whose loading never runs again for the same file. A synchronous test, so the
    /// chip's own `.task` runs while the window settles.
    func testAChipKeepsItsPreviewAfterTheCacheDropsIt() throws {
        let missing = scratch.appending(path: "evicted-mockup.png")
        let cached = expectation(description: "The fallback is cached")
        Task { _ = await TranscriptImageThumbnails.shared.preview(for: missing); cached.fulfill() }
        wait(for: [cached], timeout: 5)
        let draft = TaskComposerDraft()
        draft.attachments = [.localImage(missing, detail: .auto)]
        let host = WindowlessRender.Host(AnyView(PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
            .frame(width: 760, height: 200, alignment: .bottom)), size: NSSize(width: 760, height: 200))
        defer { host.close() }
        host.settle()
        XCTAssertEqual(host.accessibilityElements().prefix(4).map(\.role),
                       ["AXGroup", "AXImage", "AXStaticText", "AXButton"], "The name chip, from the cache")

        TranscriptImageThumbnails.shared.discardCachedPreview(for: missing)
        XCTAssertNil(TranscriptImageThumbnails.shared.cachedPreview(for: missing))
        draft.text = "The composer draws again"
        host.settle()
        let elements = host.accessibilityElements()
        XCTAssertEqual(elements.prefix(4).map(\.role), ["AXGroup", "AXImage", "AXStaticText", "AXButton"], "\(elements)")
        XCTAssertEqual(elements.dropFirst(2).first?.value, "evicted-mockup.png")
    }

    // MARK: - Renders

    func testRendersTheComposerChipsAndTheSentRequestInBothAppearances() async throws {
        let directory = try WindowlessRender.directory("composer-image-chip-qa")
        let pastedImage = try paste(width: 1_400, height: 900, hue: 0.58)
        let tall = scratch.appending(path: "Phone mockup.png")
        try png(width: 600, height: 1_200, hue: 0.08).write(to: tall)
        let missing = scratch.appending(path: "deleted-mockup.png")
        for url in [pastedImage, tall, missing] { _ = await TranscriptImageThumbnails.shared.preview(for: url) }

        let draft = TaskComposerDraft()
        draft.text = "Why is the toolbar clipped here?"
        draft.attachments = [
            .localImage(pastedImage, detail: .auto), .localImage(tall, detail: .auto),
            .localImage(missing, detail: .auto),
            .mention(name: "AppTitleBar.swift", path: URL(filePath: "/Users/me/yardlet/Sources/AppTitleBar.swift"))
        ]
        try WindowlessRender.hostedInBothAppearances("composer", in: directory, size: NSSize(width: 760, height: 220)) {
            PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
                .environment(\.colorScheme, $0.colorScheme)
                .frame(width: 760, height: 220, alignment: .bottom)
                .background(ParityTheme.canvas)
        }

        // The request as it was sent: Claude Code's live entry and Codex's `localImage`.
        let entries = [
            TranscriptEntry(content: .user(text: "Why is the toolbar clipped here?",
                                           images: [TranscriptImageAttachment(url: pastedImage)])),
            TranscriptEntry(content: .assistant(text: "The title bar keeps a fixed height.", isStreaming: false))
        ]
        let claude = TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                          entries: entries, actions: ConversationActions())
        try WindowlessRender.hostedInBothAppearances("sent-claude", in: directory, size: NSSize(width: 760, height: 300)) {
            claude.environment(\.colorScheme, $0.colorScheme)
                .frame(width: 760, height: 300, alignment: .top)
                .background(ParityTheme.canvas)
        }
        let decoder = CodexTaskDecoder()
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread-image-chip")])))
        thread.turns = [try XCTUnwrap(decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Why is the toolbar clipped here?")]),
                    .object(["type": .string("localImage"), "path": .string(pastedImage.path(percentEncoded: false))])
                ])]),
                .object(["id": .string("a1"), "type": .string("agentMessage"),
                         "text": .string("The title bar keeps a fixed height."), "phase": .string("final_answer")])
            ])
        ]), fallbackID: "turn-1"))]
        let codex = TaskConversationView(harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [],
                                         codexTaskState: CodexTaskState(thread: thread),
                                         actions: ConversationActions(retryTurn: { _ in }))
        try WindowlessRender.hostedInBothAppearances("sent-codex", in: directory, size: NSSize(width: 760, height: 300)) {
            codex.environment(\.colorScheme, $0.colorScheme)
                .frame(width: 760, height: 300, alignment: .top)
                .background(ParityTheme.canvas)
        }
    }

    // MARK: - Fixtures

    /// A real paste: written by `storePastedImage` into the app's own paste folder.
    private func paste(width: Int, height: Int, hue: CGFloat = 0.58) throws -> URL {
        let url = try ComposerAttachmentIntake.storePastedImage(try png(width: width, height: height, hue: hue))
        pasted.append(url)
        return url
    }

    private func png(width: Int, height: Int, hue: CGFloat = 0.58) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(
            starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
            ending: NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.55, alpha: 1)
        )?.draw(in: bounds, angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: CGFloat(width) * 0.18, dy: CGFloat(height) * 0.3),
                     xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private extension NSView {
    /// Presses the first accessibility element under the view with this label, as an assistive app
    /// would (`CodexPromptRenderingTests` does the same).
    func pressAccessibilityElement(labelled label: String) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(self)?.accessibilityPerformPress?() ?? false
    }
}
