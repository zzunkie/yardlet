import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Sent requests in both conversation surfaces: their images travel beside the text instead of as
/// file names in it, the reading cache stays small, previews are bounded and never fetched, and
/// the rendered messages (with their copy action shown) go to `.build/sent-message-qa` for review.
/// The renders draw through `TaskConversationView`, as a task draws them.
@MainActor
final class SentUserMessageTests: XCTestCase {
    let decoder = CodexTaskDecoder()
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "sent-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func checkRendersCodexAndClaudeRequestsWithImagesAndTheirCopyAction() async throws {
        let screenshot = scratch.appending(path: "Screen Shot 2026-10-08.png")
        try png(width: 1_600, height: 1_000).write(to: screenshot)
        let inline = try dataURL(png(width: 300, height: 420, hue: 0.08))
        let missing = scratch.appending(path: "deleted-mockup.png")
        for url in [screenshot, inline, missing] {
            _ = await TranscriptImageThumbnails.shared.preview(for: url)
        }

        var thread = decoder.thread(from: .object(["id": .string("thread-qa")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"), "durationMs": .integer(18_000),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Find out why the title bar is cut off on this screen")]),
                    .object(["type": .string("localImage"), "path": .string(screenshot.path(percentEncoded: false))]),
                    .object(["type": .string("image"), "url": .string(inline.absoluteString)]),
                    .object(["type": .string("localImage"), "path": .string(missing.path(percentEncoded: false))]),
                    .object(["type": .string("mention"), "name": .string("AppTitleBar.swift"),
                             "path": .string("/Users/me/yardlet/Sources/AppTitleBar.swift")])
                ])]),
                .object(["id": .string("a1"), "type": .string("agentMessage"),
                         "text": .string("The title bar keeps a fixed height while the toolbar grows."),
                         "phase": .string("final_answer")])
            ])
        ]), fallbackID: "turn-1")!]
        let timeline = TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [],
            codexTaskState: CodexTaskState(thread: thread), actions: ConversationActions(retryTurn: { _ in })
        )
        try render(timeline.environment(\.revealsSentMessageActions, true), height: 420, name: "codex-request")
        try render(timeline, height: 420, name: "codex-request-at-rest")

        let entries = [
            TranscriptEntry(content: .user(text: "", images: [TranscriptImageAttachment(url: inline)])),
            TranscriptEntry(content: .assistant(text: "That is the settings sheet.", isStreaming: false)),
            // The latest request carries the side menu, which stays level with its bubble.
            TranscriptEntry(content: .user(
                text: "Why is the toolbar clipped here?\n@/Users/me/yardlet/Sources/AppTitleBar.swift",
                images: [TranscriptImageAttachment(url: screenshot), TranscriptImageAttachment(url: inline),
                         TranscriptImageAttachment(url: missing), TranscriptImageAttachment(url: nil, name: nil)]
            ))
        ]
        let rewind = ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        )
        let transcript = TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                              entries: entries, actions: ConversationActions(rewind: rewind))
        try render(transcript.environment(\.revealsSentMessageActions, true), height: 560, name: "claude-request")
    }

    // MARK: - Fixtures

    func png(width: Int, height: Int, hue: CGFloat = 0.58) throws -> Data {
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

    func dataURL(_ data: Data) throws -> URL {
        try XCTUnwrap(InlineImageInput.url(mimeType: "image/png", base64: data.base64EncodedString()))
    }

    private func render<Content: View>(_ content: Content, height: CGFloat, name: String) throws {
        let captures = try WindowlessRender.hostedInBothAppearances(
            name, in: WindowlessRender.directory("sent-message-qa"), size: NSSize(width: 760, height: height)
        ) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 760, height: height, alignment: .top)
                .background(ParityTheme.canvas)
        }
        for capture in captures {
            XCTAssertEqual(capture.bitmap.pixelsWide, Int(760 * capture.backingScaleFactor))
        }
    }
}

extension SentUserMessageTests {
    // MARK: - Model

    func testARequestWithoutImagesKeepsTheSavedShapeOlderSnapshotsUse() throws {
        let saved = #"[{"id":"7C0B1E5E-6A3B-4F55-9C3E-3E3A8C1D2F10","createdAt":0,"content":{"user":{"text":"hello"}}}]"#
        let entries = try JSONDecoder().decode([TranscriptEntry].self, from: Data(saved.utf8))
        XCTAssertEqual(entries.first?.content, .user(text: "hello"))

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(entries), encoding: .utf8))
        XCTAssertFalse(encoded.contains("images"))

        var builder = TranscriptBuilder()
        builder.appendUser("hello", images: [])
        XCTAssertEqual(builder.entries.first?.content, .user(text: "hello", images: nil))
    }

    func testTheReadingCacheKeepsFileImagesButLeavesInlineBytesToTheLiveEntry() throws {
        let file = TranscriptImageAttachment(url: URL(filePath: "/tmp/shot one.png"))
        let inline = TranscriptImageAttachment(url: try dataURL(png(width: 4, height: 4)))
        XCTAssertEqual(file.name, "shot one.png")
        XCTAssertNil(inline.name)

        let entry = TranscriptEntry(content: .user(text: "Look", images: [file, inline]))
        let data = try JSONEncoder().encode([entry])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("base64"))
        let restored = try JSONDecoder().decode([TranscriptEntry].self, from: data)
        XCTAssertEqual(restored.first?.content, .user(text: "Look", images: [
            file, TranscriptImageAttachment(url: nil, name: nil)
        ]))
    }

    func testACodexRequestShowsItsImagesBesideTheTextAndKeepsMentionLabels() throws {
        let inline = try dataURL(png(width: 4, height: 4))
        let message = CodexUserMessageItem(content: [
            .object(["type": .string("text"), "text": .string("Why is this clipped?")]),
            .object(["type": .string("localImage"), "path": .string("/Users/me/Desktop/Screen Shot.png")]),
            .object(["type": .string("image"), "url": .string(inline.absoluteString)]),
            .object(["type": .string("image"), "url": .string("https://example.invalid/remote.png")]),
            .object(["type": .string("mention"), "name": .string("AppTitleBar.swift"), "path": .string("/repo/AppTitleBar.swift")]),
            .object(["type": .string("skill"), "name": .string("review"), "path": .string("/repo/.codex/skills/review")])
        ], clientID: nil)

        let sent = message.sentContent
        XCTAssertEqual(sent.text, "Why is this clipped?\n@AppTitleBar.swift\n$review")
        XCTAssertEqual(sent.images, [
            TranscriptImageAttachment(url: URL(filePath: "/Users/me/Desktop/Screen Shot.png"), name: "Screen Shot.png"),
            TranscriptImageAttachment(url: inline, name: nil),
            TranscriptImageAttachment(url: URL(string: "https://example.invalid/remote.png"), name: "remote.png")
        ])
        // Search keeps the labels but never the inline payload.
        XCTAssertFalse(message.displayText.contains("base64"))
        XCTAssertTrue(message.displayText.contains("Screen Shot.png"))

        var thread = decoder.thread(from: .object(["id": .string("thread-qa")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"),
            "items": .array([.object(["id": .string("u1"), "type": .string("userMessage"), "content": .array(message.content)])])
        ]), fallbackID: "turn-1")!]
        let entries = CodexTranscriptSnapshotProjection.entries(from: CodexTaskState(thread: thread))
        XCTAssertEqual(entries.map(\.content), [.user(text: sent.text, images: sent.images)])
    }

    func testTheImplementRequestStillShowsAsTheChoiceThatSentIt() {
        let message = CodexUserMessageItem(content: [
            .object(["type": .string("text"), "text": .string(CodexPlanImplementation.request(for: "# Plan"))])
        ], clientID: nil)
        XCTAssertEqual(message.sentContent.text, L10n.string("Yes, implement this plan"))
        XCTAssertEqual(message.sentContent.images, [])
    }

    func testAnAttachedImagesFileNameStaysSearchable() {
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/sent-search"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Untitled task")
        let transcripts = [session.id: [TranscriptEntry(content: .user(text: "Look", images: [
            TranscriptImageAttachment(url: URL(filePath: "/tmp/settings-mockup.png"))
        ]))]]
        let found = TaskNavigationProjection.filteredGroups(from: [session], query: "settings-mockup", transcripts: transcripts)
        XCTAssertEqual(found.flatMap(\.sessions).map(\.id), [session.id])
    }

    func testACodexDraftsImagesReachTheSharedTranscriptAsAttachments() throws {
        let file = URL(filePath: "/tmp/pasted/image.png")
        XCTAssertEqual(CodexUserInput.localImage(file, detail: .auto).sentImage, TranscriptImageAttachment(url: file))
        XCTAssertNil(CodexUserInput.mention(name: "a", path: file).sentImage)
    }

    // MARK: - Previews

    func testPreviewsAreDownscaledFromFilesAndInlineImagesAndNeverFetched() async throws {
        let thumbnails = TranscriptImageThumbnails(keepsEntriesForTesting: true)
        let wide = scratch.appending(path: "wide.png")
        try png(width: 2_400, height: 600).write(to: wide)
        guard case let .image(preview) = await thumbnails.preview(for: wide) else { return XCTFail("a PNG file previews") }
        XCTAssertEqual(preview.width, 960, "the shorter side is sized for the tile")
        XCTAssertEqual(preview.height, 240)
        // Checked at once: NSCache may let entries go under memory pressure, as on a loaded machine.
        if case .image = thumbnails.cachedPreview(for: wide) {} else { XCTFail("a preview is cached") }

        let banner = scratch.appending(path: "banner.png")
        try png(width: 6_000, height: 300).write(to: banner)
        guard case let .image(capped) = await thumbnails.preview(for: banner) else { return XCTFail("a long image previews") }
        XCTAssertEqual(capped.width, TranscriptImageThumbnails.longSidePixels)

        guard case let .image(small) = await thumbnails.preview(for: try dataURL(png(width: 50, height: 40))) else {
            return XCTFail("an inline image previews")
        }
        XCTAssertEqual([small.width, small.height], [50, 40], "a small image is not enlarged")

        let text = scratch.appending(path: "notes.png")
        try Data("not an image".utf8).write(to: text)
        let oversized = try XCTUnwrap(URL(string: "data:image/png;base64,"
            + String(repeating: "A", count: (InlineImageInput.maximumBytes + 2) / 3 * 4 + 4)))
        for unreadable: URL in [scratch.appending(path: "missing.png"), text, scratch!, oversized] {
            guard case .unavailable = await thumbnails.preview(for: unreadable) else {
                return XCTFail("\(unreadable.lastPathComponent) shows as its name")
            }
        }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/remote.png"))
        guard case .unavailable = thumbnails.cachedPreview(for: remote) else {
            return XCTFail("a remote image is decided without a request")
        }
    }

    // MARK: - Renders

    func testRendersCodexAndClaudeRequestsWithImagesAndTheirCopyAction() async throws {
        try await checkRendersCodexAndClaudeRequestsWithImagesAndTheirCopyAction()
    }
}
