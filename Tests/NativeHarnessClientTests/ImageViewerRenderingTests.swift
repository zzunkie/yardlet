import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A conversation image opened over the window (`ImageViewer`), as the Codex and Claude apps open
/// one: fitted and never enlarged, zoomed by keys, moved between a message's images by the arrows,
/// put away by Esc, and named for assistive apps. Renders over a real conversation at window size go
/// to `.build/image-viewer-qa` in light and dark. No provider, CLI, app window or screen capture.
@MainActor
final class ImageViewerRenderingTests: XCTestCase {
    private var scratch: URL!
    private let size = NSSize(width: 1_280, height: 800)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "image-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAMessageImageOpensFittedOverTheConversationAndTheKeysMoveAndZoomIt() async throws {
        let screenshot = try write(Self.screenshot(), as: "Screen Shot 2026-10-27.png")
        let portrait = try write(Self.screenshot(width: 1_170, height: 2_532, dpiScale: 3), as: "phone.png")
        let small = try write(Self.screenshot(width: 300, height: 200, dpiScale: 1), as: "icon.png")
        let images = [screenshot, portrait, small].map { TranscriptImageAttachment(url: $0) }
        let request = ImageViewerRequest(
            items: images.map { ImageViewerItem(name: $0.name ?? "", source: .url($0.url!)) }, index: 0
        )
        let directory = try WindowlessRender.directory("image-viewer-qa")

        for appearance in WindowlessRender.Appearance.allCases {
            var closed = false
            let host = WindowlessRender.Host(
                ZStack {
                    conversation(images: images)
                    ImageViewer(request: request) { closed = true }
                }
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height),
                size: size, appearance: appearance
            )
            defer { host.close() }
            let first = try await canvas(in: host, showing: NSSize(width: 1_440, height: 900))
            // Fitted between the name and the zoom controls, below its own size.
            XCTAssertLessThan(first.magnification, 1)
            XCTAssertEqual(first.magnification, first.fitMagnification, accuracy: 0.001)
            XCTAssertTrue(first.fitsWindow)
            XCTAssertTrue(host.window.firstResponder === first, "The viewer holds the keyboard, not the composer behind it")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-sent-image-\(appearance.suffix).png"))

            // ⌘= steps up from the fitted zoom to the image's own size, then on; ⌘0 fits again.
            XCTAssertTrue(first.performKeyEquivalent(with: key(24, "=", modifiers: .command)))
            XCTAssertEqual(first.magnification, 1, accuracy: 0.001)
            XCTAssertFalse(first.fitsWindow)
            await settle(host)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-sent-image-100-\(appearance.suffix).png"))
            first.keyDown(with: key(24, "=", modifiers: .command))
            XCTAssertEqual(first.magnification, 1.5, accuracy: 0.001)
            XCTAssertTrue(first.performKeyEquivalent(with: key(29, "0", modifiers: .command)))
            XCTAssertEqual(first.magnification, first.fitMagnification, accuracy: 0.001)

            // → shows the message's next image; ← at the first one stays.
            first.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            let second = try await canvas(in: host, showing: NSSize(width: 390, height: 844))
            XCTAssertNotIdentical(second, first)
            second.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            // A small image keeps its own size.
            let third = try await canvas(in: host, showing: NSSize(width: 300, height: 200))
            XCTAssertEqual(third.magnification, 1, accuracy: 0.001)
            await settle(host)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-small-image-\(appearance.suffix).png"))
            if appearance == .light {
                let labels = host.accessibilityElements().map(\.label)
                for label in ["Close image preview", "Copy Image", "Save Image…", "Previous image", "Next image",
                              "Zoom Out", "Zoom In"] {
                    XCTAssertTrue(labels.contains(L10n.string(label)), "\(label) in \(labels)")
                }
                XCTAssertTrue(labels.contains("icon.png"), "The image by its name, in \(labels)")
            }
            XCTAssertFalse(closed)
            third.keyDown(with: key(53, "\u{1b}"))
            XCTAssertTrue(closed, "Esc puts the viewer away")
        }
    }

    func testAComposerImageOpensWithItsMarkupAndTheHostPutsItAwayWithEsc() async throws {
        let screenshot = try write(Self.screenshot(), as: "Screen Shot 2026-10-27.png")
        var markedUp = false
        let request = ImageViewerRequest(items: [ImageViewerItem(name: L10n.string("Image"), source: .url(screenshot))],
                                         index: 0, markUp: { markedUp = true })
        let directory = try WindowlessRender.directory("image-viewer-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                ImageViewerProbe(request: request)
                    .imageViewerHost()
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance
            )
            defer { host.close() }
            let canvas = try await canvas(in: host, showing: NSSize(width: 1_440, height: 900))
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-composer-image-\(appearance.suffix).png"))
            if appearance == .light {
                XCTAssertTrue(host.accessibilityElements().map(\.label).contains(L10n.string("Mark Up")))
                XCTAssertFalse(host.accessibilityElements().map(\.label).contains(L10n.string("Next image")),
                               "One image has no arrows")
            }
            canvas.keyDown(with: key(53, "\u{1b}"))
            await host.settle { Self.canvases(in: host.hosting).isEmpty }
        }
        XCTAssertFalse(markedUp)
    }

    /// The right-click menu over the image: Copy, Save…, Show in Finder (only for a file on disk),
    /// Actual Size, Zoom to Fit, and Mark Up (only when the request offered it).
    func testTheImageViewersRightClickMenuHasCopySaveZoomAndContextualItems() async throws {
        // A file on disk, no markup: Show in Finder in, Mark Up out.
        let onDisk = try write(Self.screenshot(width: 40, height: 30, dpiScale: 1), as: "shot.png")
        try await assertContextMenu(
            request: ImageViewerRequest(items: [ImageViewerItem(name: "shot.png", source: .url(onDisk))], index: 0),
            keys: ["Copy Image", "Save Image…", "Show in Finder", "Actual Size", "Zoom to Fit"]
        )

        // Bytes with no file: Show in Finder out, Mark Up out.
        let bytes = try Self.screenshot(width: 40, height: 30, dpiScale: 1)
        try await assertContextMenu(
            request: ImageViewerRequest(items: [ImageViewerItem(name: "bytes", source: .data(bytes))], index: 0),
            keys: ["Copy Image", "Save Image…", "Actual Size", "Zoom to Fit"]
        )

        // A composer attachment with markup: Mark Up in.
        try await assertContextMenu(
            request: ImageViewerRequest(items: [ImageViewerItem(name: "shot.png", source: .url(onDisk))], index: 0,
                                        markUp: {}),
            keys: ["Copy Image", "Save Image…", "Show in Finder", "Actual Size", "Zoom to Fit", "Mark Up"]
        )
    }

    private func assertContextMenu(request: ImageViewerRequest, keys: [String],
                                   file: StaticString = #file, line: UInt = #line) async throws {
        let host = WindowlessRender.Host(
            ImageViewerProbe(request: request)
                .imageViewerHost()
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas),
            size: size, appearance: .light
        )
        defer { host.close() }
        let canvas = try await canvas(in: host, showing: NSSize(width: 40, height: 30))
        let menu = try XCTUnwrap(canvas.contextMenu, "The viewer builds a right-click menu once the image loads", file: file, line: line)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, keys.map { L10n.string($0) }, file: file, line: line)
        // Every item has a target so it is enabled when the menu opens.
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.target, "\(item.title) has no target", file: file, line: line)
            XCTAssertNotNil(item.action, "\(item.title) has no action", file: file, line: line)
        }
    }

    func testASavedImageKeepsItsNameAndTypeAndCopyPutsTheOriginalOnThePasteboard() async throws {
        XCTAssertEqual(ImageViewerModel.fileName(for: "Screen Shot.png", type: .png), "Screen Shot.png")
        XCTAssertEqual(ImageViewerModel.fileName(for: "photo.JPG", type: .jpeg), "photo.JPG")
        XCTAssertEqual(ImageViewerModel.fileName(for: "Image", type: .png), "Image.png")
        XCTAssertEqual(ImageViewerModel.fileName(for: "v1.2", type: .jpeg), "v1.2.jpeg")

        let data = try Self.screenshot(width: 40, height: 30, dpiScale: 1)
        let model = ImageViewerModel(items: [ImageViewerItem(name: "shot", source: .data(data))], index: 0)
        await model.load()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("yardlet-image-viewer-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    /// A call's images show at the end of its line, as the Claude app shows a call's screenshots: a
    /// Codex image view, MCP screenshot and generated image in a finished turn, unfolded; a Claude Code `Read` of an
    /// image and an MCP screenshot in a running turn, whose live line shows them too. A summary line
    /// shows its calls' images; an image that cannot be read leaves its line its words; opened, a
    /// line shows its image whole; a click opens the call's images over the window. Renders at window
    /// size go to `.build/tool-image-qa` in light and dark.
    func testACallsImagesShowOnItsLineAndOpenOverTheWindow() async throws {
        let settings = try write(Self.screenshot(), as: "settings.png")
        let phone = try write(Self.screenshot(width: 1_170, height: 2_532, dpiScale: 3), as: "phone.png")
        let gone = scratch.appending(path: "gone.png")
        let screenshot = try Self.screenshot(width: 1_440, height: 900, dpiScale: 1).base64EncodedString()
        let directory = try WindowlessRender.directory("tool-image-qa")
        let size = NSSize(width: 960, height: 760)
        let opened = OpenedImages()

        // Codex: a finished turn's image views and the computer-use screenshot it took.
        let decoder = CodexTaskDecoder()
        func message(_ id: String, _ text: String, _ phase: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
        }
        func imageView(_ id: String, _ url: URL) -> JSONValue {
            .object(["id": .string(id), "type": .string("imageView"), "path": .string(url.path(percentEncoded: false))])
        }
        let items: [JSONValue] = [
            .object(["id": .string("u1"), "type": .string("userMessage"),
                     "content": .array([.object(["type": .string("text"), "text": .string("The settings window clips its last row. Why?")])])]),
            message("m1", "Looking at the screenshot you saved first.", "commentary"),
            imageView("v1", settings),
            message("m2", "The older screenshot is gone, so I'll look at the phone layout and the window as it is now.", "commentary"),
            imageView("v2", gone),
            imageView("v3", phone),
            .object(["id": .string("s1"), "type": .string("mcpToolCall"), "server": .string("computer-use"),
                     "tool": .string("screenshot"), "status": .string("completed"), "arguments": .object([:]),
                     "result": .object(["content": .array([.object(["type": .string("image"), "data": .string(screenshot),
                                                                     "mimeType": .string("image/png")])])])]),
            message("m3", "Here is the window with the last row in view.", "commentary"),
            .object(["id": .string("g1"), "type": .string("imageGeneration"), "status": .string("completed"),
                     "result": .string(screenshot), "revisedPrompt": .string("The settings window with its last row in view")]),
            message("m4", "The list keeps a fixed height while the rows grow, so the last row falls below it.", "final_answer")
        ]
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread-images")])))
        thread.turns = [try XCTUnwrap(decoder.turn(from: .object([
            "id": .string("t1"), "status": .string("completed"), "durationMs": .integer(12_000), "items": .array(items)
        ]), fallbackID: "t1"))]
        let codex = CodexTaskState(thread: thread)

        // Claude Code: a running turn that read an image file, then took a screenshot and runs tests.
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("The settings window clips its last row. Why?")
        let png = try Self.screenshot(width: 1_440, height: 900, dpiScale: 1).base64EncodedString()
        let read = #"{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"\#(settings.path(percentEncoded: false))"}}"#
        let shot = #"{"type":"tool_use","id":"shot","name":"mcp__computer-use__app_screenshot","input":{"app":"com.example.settings"}}"#
        for json in [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the screenshot first."},\#(read)]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"read","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Now the window as it is, then the tests."},\#(shot)]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"shot","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}},{"type":"text","text":"Captured the window"}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"bash","name":"Bash","input":{"command":"swift test --filter SettingsTests","description":"Run the settings tests"}}]}}"#
        ] {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) { builder.apply(payload) }
        }

        let codexImages = ["settings.png", "phone.png", L10n.string("Tool result image"), L10n.string("Image")]
        for appearance in WindowlessRender.Appearance.allCases {
            let codexHost = WindowlessRender.Host(
                TaskConversationView(harness: .codex, workspaceURL: scratch, entries: [], sessionStatus: .ready,
                                     latestTurnIsComplete: true, codexTaskState: codex, providerSessionID: "thread-images")
                    .environment(\.openImageViewer) { opened.requests.append($0) }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance
            )
            defer { codexHost.close() }
            codexHost.settle(passes: 12)
            XCTAssertTrue(codexHost.hosting.pressButton(labeled: L10n.format("Worked for %lld seconds", Int64(12))))
            await codexHost.settle { Self.thumbnails(in: codexHost) == codexImages }
            try WindowlessRender.writePNG(codexHost.capture().bitmap,
                                          to: directory.appending(path: "codex-\(appearance.suffix).png"))
            // The image that is gone leaves its line its words.
            let words = codexHost.accessibilityElements().map(\.label).joined(separator: "\n")
            XCTAssertTrue(words.contains(ConversationLineWords.filling(L10n.string("codex.row.viewedImage"), ["gone.png"]).text),
                          words)

            // A click opens the call's images.
            XCTAssertTrue(codexHost.hosting.pressButton(labeled: "phone.png"))
            XCTAssertEqual(opened.requests.last?.items.map(\.name), ["phone.png"])
            // Folded, the summary line shows its calls' images and opens them together, leaving out
            // the one that cannot be read.
            XCTAssertTrue(codexHost.hosting.pressButton(labeled: L10n.string("codex.summary.calledTool.leading")))
            await settle(codexHost)
            XCTAssertEqual(Self.thumbnails(in: codexHost), codexImages)
            try WindowlessRender.writePNG(codexHost.capture().bitmap,
                                          to: directory.appending(path: "codex-folded-\(appearance.suffix).png"))
            XCTAssertTrue(codexHost.hosting.pressButton(labeled: L10n.string("Tool result image")))
            XCTAssertEqual(opened.requests.last?.items.map(\.name), ["phone.png", L10n.string("Tool result image")])
            XCTAssertEqual(opened.requests.last?.index, 1)

            // Opened, the line shows its image whole in place of the one at its end.
            let line = ConversationLineWords.filling(L10n.string("codex.row.viewedImage"), ["settings.png"]).text
            XCTAssertTrue(codexHost.hosting.pressButton(labeled: line))
            await settle(codexHost)
            await settle(codexHost)
            XCTAssertEqual(Self.thumbnails(in: codexHost), codexImages)
            try WindowlessRender.writePNG(codexHost.capture().bitmap,
                                          to: directory.appending(path: "codex-opened-\(appearance.suffix).png"))

            let claudeHost = WindowlessRender.Host(
                TaskConversationView(harness: .claudeCode, workspaceURL: scratch, entries: builder.entries,
                                     sessionStatus: .running)
                    .environment(\.openImageViewer) { opened.requests.append($0) }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance
            )
            defer { claudeHost.close() }
            // The read's line, and the live line for the screenshot and the running tests.
            await claudeHost.settle { Self.thumbnails(in: claudeHost) == [L10n.string("Image"), L10n.string("Image")] }
            try WindowlessRender.writePNG(claudeHost.capture().bitmap,
                                          to: directory.appending(path: "claude-\(appearance.suffix).png"))
        }
    }

    // MARK: - Helpers

    /// The call images that open the viewer, by name, top to bottom.
    private static func thumbnails<Content: View>(in host: WindowlessRender.Host<Content>) -> [String] {
        let names: Set = ["settings.png", "phone.png", "gone.png", L10n.string("Tool result image"), L10n.string("Image")]
        return host.accessibilityElements()
            .filter { $0.role == NSAccessibility.Role.button.rawValue && names.contains($0.label) }
            .map(\.label)
    }

    private func conversation(images: [TranscriptImageAttachment]) -> some View {
        let entries = [
            TranscriptEntry(content: .user(text: "The settings window clips its last row. Why?", images: images)),
            TranscriptEntry(content: .assistant(text: "The list keeps a fixed height while the rows grow.", isStreaming: false))
        ]
        return TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                    entries: entries, actions: ConversationActions())
            .background(ParityTheme.canvas)
    }

    /// The canvas once it shows an image of `imageSize` points.
    private func canvas<Content: View>(in host: WindowlessRender.Host<Content>, showing imageSize: NSSize) async throws
        -> ImageViewerCanvasView {
        var found: ImageViewerCanvasView?
        await host.settle {
            found = Self.canvases(in: host.hosting).first { $0.documentView?.frame.size == imageSize }
            return found != nil && host.window.firstResponder === found
        }
        await settle(host)
        return try XCTUnwrap(found)
    }

    /// Settles giving the main actor back between passes, so the zoom the canvas reports reaches the
    /// footer before a capture.
    private func settle<Content: View>(_ host: WindowlessRender.Host<Content>) async {
        for _ in 0..<4 {
            host.settle(passes: 1)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func canvases(in view: NSView) -> [ImageViewerCanvasView] {
        view.subviews.flatMap { ($0 as? ImageViewerCanvasView).map { [$0] } ?? canvases(in: $0) }
    }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = scratch.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// A Retina screenshot: by default 2,880 by 1,800 pixels at 144 dpi, as macOS saves one, of a
    /// settings window whose small text needs zooming to read.
    static func screenshot(width: Int = 2_880, height: Int = 1_800, dpiScale: CGFloat = 2) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let unit = CGFloat(min(width, height)) / 900
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.86, alpha: 1),
                   ending: NSColor(calibratedRed: 0.62, green: 0.38, blue: 0.70, alpha: 1))?.draw(in: bounds, angle: 30)
        let window = bounds.insetBy(dx: CGFloat(width) * 0.14, dy: CGFloat(height) * 0.12)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: window, xRadius: 12 * unit, yRadius: 12 * unit).fill()
        NSColor(white: 0.90, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: window.minX, y: window.maxY - 52 * unit, width: window.width, height: 40 * unit)).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + (20 + CGFloat(index) * 22) * unit, y: window.maxY - 32 * unit,
                                        width: 14 * unit, height: 14 * unit)).fill()
        }
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17 * unit), .foregroundColor: NSColor.black]
        ("General" as NSString).draw(at: NSPoint(x: window.minX + 110 * unit, y: window.maxY - 35 * unit), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * unit), .foregroundColor: NSColor.darkGray]
        let rows = ["Appearance: System", "Interface size: Standard", "Follow-up messages: Steer",
                    "Notifications: When a task needs you", "Browser: Ask before opening files outside the task",
                    "Updates: Check automatically"]
        for (index, row) in rows.enumerated() {
            let y = window.maxY - (95 + CGFloat(index) * 48) * unit
            guard y > window.minY + 20 * unit else { break }
            (row as NSString).draw(at: NSPoint(x: window.minX + 40 * unit, y: y), withAttributes: body)
            NSColor(white: 0.86, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: window.minX + 40 * unit, y: y - 13 * unit, width: window.width - 80 * unit, height: unit)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: CGFloat(width) / dpiScale, height: CGFloat(height) / dpiScale)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// The viewer requests a conversation made.
@MainActor
private final class OpenedImages {
    var requests: [ImageViewerRequest] = []
}

/// Opens `request` through the environment, as a thumbnail's click does.
private struct ImageViewerProbe: View {
    let request: ImageViewerRequest
    @Environment(\.openImageViewer) private var openImageViewer

    var body: some View {
        Color.clear.onAppear { openImageViewer(request) }
    }
}
