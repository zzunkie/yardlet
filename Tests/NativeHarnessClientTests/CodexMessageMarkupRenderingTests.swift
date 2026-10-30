import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Codex app's markup drawn the way the app draws it, by the one renderer, with no window on
/// screen: an automation's heartbeat under "Sent by scheduled task" in a two-line bubble, its reply as
/// words, directives left out, and a long sent message clipped at twenty lines with "Show more".
/// Review images go to `.build/codex-render-qa/` in both appearances.
@MainActor
final class CodexMessageMarkupRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private static let workspace = URL(filePath: "/tmp/yardlet-codex-markup", directoryHint: .isDirectory)

    // MARK: - Review renders

    /// A Codex thread an automation runs in: two heartbeats (one reply that notifies, one quiet), a
    /// request of the person's own past twenty lines, and an answer that ends in directives.
    func testAnAutomationThreadDrawsAsTheCodexAppDoes() throws {
        let directory = try WindowlessRender.directory("codex-render-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .codex(automationThread(), workspaceURL: Self.workspace, historySelection: nil),
                                     actions: ConversationActions(forkCodexTurn: { _ in })),
                size: NSSize(width: 760, height: 2_100), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "automation-thread-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertEqual(drawing.elements.filter { $0.value == L10n.string("Sent by scheduled task") }.count, 2, texts)
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXGroup" && $0.label == L10n.string("Scheduled task") }.count,
                           2, texts)
            for markup in ["<heartbeat>", "<decision>", "<instructions>", "::inbox-item", "::git-commit", "::git-push"] {
                XCTAssertFalse(texts.contains(markup), "\(markup) is drawn:\n\(texts)")
            }
            XCTAssertTrue(texts.contains("The nightly build failed in two parser tests."), texts)
            XCTAssertTrue(texts.contains("Everything is still green."), texts)
            XCTAssertTrue(texts.contains("Opened the pull request."), texts)
            // Each heartbeat's instructions run past two lines, and the request past twenty.
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXButton" && $0.label == L10n.string("Show more") }.count,
                           3, texts)
            XCTAssertFalse(texts.contains("Line 25 of the request"), "the request is not clipped:\n\(texts)")
        }
    }

    /// The same conversation read from a detached Codex task's transcript draws the same marks.
    func testADetachedCodexTaskDrawsItsHeartbeatTheSameWay() throws {
        let directory = try WindowlessRender.directory("codex-render-qa")
        let entries = [
            TranscriptEntry(content: .user(text: heartbeat(instructions: shortInstructions))),
            TranscriptEntry(content: .assistant(text: quietReply, isStreaming: false))
        ]
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .codex, status: .ready,
                                                         latestTurnIsComplete: true)),
                size: NSSize(width: 760, height: 360), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "detached-heartbeat-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(drawing.elements.contains { $0.value == L10n.string("Sent by scheduled task") }, texts)
            XCTAssertTrue(texts.contains("Everything is still green."), texts)
            XCTAssertFalse(texts.contains("<heartbeat>"), texts)
            XCTAssertFalse(drawing.elements.contains { $0.label == L10n.string("Show more") }, "two lines fit:\n\(texts)")
        }
    }

    // MARK: - Clipping

    /// Every harness clips a sent message past twenty drawn lines, whether they are its own lines or
    /// lines the bubble wraps, and opens it on "Show more"; "Show less" folds it again.
    func testALongSentMessageClipsAtTwentyLinesAndOpens() throws {
        let directory = try WindowlessRender.directory("codex-render-qa")
        let wrapped = (1...14).map { "Paragraph \($0) is long enough that the bubble has to wrap it onto a second line, because the bubble stops well before the edge." }
            .joined(separator: "\n")
        let cases: [(name: String, text: String, clips: Bool)] = [
            ("twenty-lines", lines(20), false),
            ("thirty-lines", lines(30), true),
            ("wrapped-lines", wrapped, true),
            ("short", "Fix the build and tell me what broke", false)
        ]
        for harness in [HarnessKind.claudeCode, .openCode] {
            for (name, text, clips) in cases {
                let view = ConversationTimeline(source: .transcript(
                    entries: [TranscriptEntry(content: .user(text: text))], harness: harness, status: .ready,
                    latestTurnIsComplete: true
                ))
                let host = WindowlessRender.Host(
                    view.environment(\.colorScheme, .light).frame(width: 760, height: 900, alignment: .top)
                        .background(ParityTheme.canvas),
                    size: NSSize(width: 760, height: 900), appearance: .light
                )
                defer { host.close() }
                host.settle(passes: 10)
                let folded = host.accessibilityElements()
                XCTAssertEqual(folded.contains { $0.role == "AXButton" && $0.label == L10n.string("Show more") }, clips,
                               "\(harness) \(name)")
                guard clips else { continue }
                let foldedHeight = try drawnRows(host.capture().bitmap)
                if harness == .claudeCode {
                    try WindowlessRender.writePNG(host.capture().bitmap,
                                                  to: directory.appending(path: "long-message-\(name)-folded-light.png"))
                }
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show more")))
                host.settle(passes: 10)
                let open = host.accessibilityElements()
                XCTAssertTrue(open.contains { $0.role == "AXButton" && $0.label == L10n.string("Show less of a sent message") },
                              "\(harness) \(name)")
                XCTAssertGreaterThan(try drawnRows(host.capture().bitmap), foldedHeight + 40, "\(harness) \(name) did not open")
                if harness == .claudeCode {
                    try WindowlessRender.writePNG(host.capture().bitmap,
                                                  to: directory.appending(path: "long-message-\(name)-open-light.png"))
                }
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show less of a sent message")))
                host.settle(passes: 10)
                XCTAssertEqual(try drawnRows(host.capture().bitmap), foldedHeight, "\(harness) \(name) did not fold again")
            }
        }
        // The folded request in the dark, for review.
        try WindowlessRender.hostedInBothAppearances("long-message-thirty-lines", in: directory,
                                                     size: NSSize(width: 760, height: 760)) { appearance in
            ConversationTimeline(source: .transcript(entries: [TranscriptEntry(content: .user(text: lines(30)))],
                                                     harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 760, height: 760, alignment: .top)
                .background(ParityTheme.canvas)
        }
    }

    /// Opening a long message at the bottom of a followed conversation keeps it followed, as opening
    /// a card does, and later output stays in view.
    func testOpeningALongMessageKeepsFollowing() throws {
        let feed = Feed([
            TranscriptEntry(content: .user(text: "Start")),
            TranscriptEntry(content: .assistant(text: String(repeating: "Earlier work. ", count: 60), isStreaming: false)),
            TranscriptEntry(content: .user(text: lines(40)))
        ])
        let size = NSSize(width: 620, height: 420)
        let host = WindowlessRender.Host(FollowHost(feed: feed).frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle(passes: 10)
        let scroll = try XCTUnwrap(scrollView(in: host.hosting))
        XCTAssertLessThanOrEqual(distance(scroll), 48)
        let folded = scroll.documentView?.frame.height ?? 0

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show more")))
        host.settle(passes: 10)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, folded + 200, "the message did not open")
        XCTAssertLessThanOrEqual(distance(scroll), 48, "opening the message stopped following")

        feed.entries.append(TranscriptEntry(content: .assistant(
            text: String(repeating: "New output after opening it. ", count: 30), isStreaming: true)))
        host.settle(passes: 10)
        XCTAssertLessThanOrEqual(distance(scroll), 48, "later output left the bottom")
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("codex-render-qa")
            .appending(path: "long-message-opened-while-following-light.png"))
    }

    /// Find's current match in the folded part of a message opens it, as the Codex app reveals one.
    func testFindOpensAFoldedMessageToItsMatch() async throws {
        let entries = [TranscriptEntry(content: .user(text: lines(30)))]
        let find = ConversationFindModel()
        find.debounce = .zero
        let view = ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                            latestTurnIsComplete: true))
            .environment(\.conversationFind, find)
            .environment(\.colorScheme, .light)
            .frame(width: 760, height: 900, alignment: .top)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 900), appearance: .light)
        defer { host.close() }
        func settle(_ passes: Int) async throws {
            for _ in 0..<passes {
                host.hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await settle(6)
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Show more") })
        find.open()
        find.updateSource(.conversation(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )))
        find.query = "Line 27 of"
        await find.waitForSearch()
        try await settle(10)
        let elements = host.accessibilityElements()
        XCTAssertEqual(find.currentResult?.matches.count, 1)
        XCTAssertTrue(elements.contains { $0.label == L10n.string("Show less of a sent message") },
                      elements.map(\.description).joined(separator: "\n"))
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("codex-render-qa")
            .appending(path: "long-message-find-opened-light.png"))
    }

    // MARK: - Fixtures

    private let shortInstructions = "Check the nightly build and the open pull requests."
    private let longInstructions = """
    Check the nightly build for the main branch.
    If a test failed, find the commit that broke it.
    Look at the open pull requests waiting on review.
    Tell me only when something needs my attention.
    """
    private let notifyReply = """
    <heartbeat>
      <automation_id>nightly-check</automation_id>
      <decision>NOTIFY</decision>
      <message>The nightly build failed in two parser tests.</message>
    </heartbeat>
    """
    private let quietReply = """
    <heartbeat>
      <automation_id>nightly-check</automation_id>
      <decision>DONT_NOTIFY</decision>
      <message>Everything is still green.</message>
    </heartbeat>
    """

    private func heartbeat(instructions: String) -> String {
        """
        <heartbeat>
          <automation_id>nightly-check</automation_id>
          <current_time_iso>2026-10-13T09:00:00Z</current_time_iso>
          <instructions>
        \(instructions)
          </instructions>
        </heartbeat>
        """
    }

    private func lines(_ count: Int) -> String {
        (1...count).map { "Line \($0) of the request" }.joined(separator: "\n")
    }

    private func automationThread() -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-automation")]))!
        thread.turns = [
            turn("turn-1", durationMs: 41_000, items: [
                user("u1", heartbeat(instructions: longInstructions)),
                agent("c1", "commentary", "Checking the nightly build."),
                agent("a1", "final_answer", notifyReply)
            ]),
            turn("turn-2", durationMs: 12_000, items: [
                user("u2", heartbeat(instructions: longInstructions)),
                agent("a2", "final_answer", quietReply)
            ]),
            turn("turn-3", durationMs: 95_000, items: [
                user("u3", lines(30)),
                agent("a3", "final_answer", """
                Opened the pull request.

                ::git-stage{cwd="/tmp/yardlet-codex-markup"}
                ::git-commit{cwd="/tmp/yardlet-codex-markup"}
                ::git-push{cwd="/tmp/yardlet-codex-markup" branch="fix/parser"}
                ::inbox-item{title="Parser fix ready" summary="Pull request opened; waiting on review"}
                """)
            ])
        ]
        return CodexTaskState(thread: thread)
    }

    private func turn(_ id: String, durationMs: Int64, items: [CodexItemState]) -> CodexTurnState {
        var turn = decoder.turn(from: .object(["id": .string(id), "status": .string("completed"),
                                               "durationMs": .integer(durationMs), "items": .array([])]),
                                fallbackID: id)!
        turn.items = items
        return turn
    }

    private func user(_ id: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func agent(_ id: String, _ phase: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)
        ]), fallbackID: id, lifecycle: .completed)
    }

    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct FollowHost: View {
        let feed: Feed
        var body: some View {
            ConversationTimeline(source: .transcript(entries: feed.entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false))
        }
    }

    /// The conversation's scroll view, the tallest one.
    private func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    private func distance(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }

    /// The rows of `bitmap` that hold anything but the canvas: the height of what was drawn.
    private func drawnRows(_ bitmap: NSBitmapImageRep) throws -> Int {
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        var rows = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y), color != background { rows += 1; break }
            }
        }
        return rows
    }
}
