import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// D11: a conversation draws its latest 10 turns, whatever its harness. The rail's "Load more
/// history" brings in 10 more at a time, drawn over the next few display cycles; a Codex thread's
/// earlier pages are asked for only once every loaded turn is drawn. A saved place or an opened history result in a turn the window leaves out
/// widens the window to it (find: `ConversationFindUnifiedTests`).
@MainActor
final class ConversationTurnWindowRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()

    func testATranscriptDrawsItsLatestTenTurnsAndTheRailBringsInTenMore() async throws {
        let entries = (1...90).flatMap { index in
            [TranscriptEntry(content: .user(text: "Request \(index)")),
             TranscriptEntry(content: .assistant(text: "Answer \(index)", isStreaming: false))]
        }
        let host = mount(ConversationTimeline(source: .transcript(
            entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )))
        defer { host.close() }
        XCTAssertEqual(drawnRequests(host).last, 90, "the latest turn is in view")
        XCTAssertEqual(drawnTurnCount(host), 10)
        XCTAssertTrue(listed(host).contains(L10n.string("Load more history")))

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load more history")))
        await host.settle { drawnTurnCount(host) == 20 }

        // Pressed again before the turns it brought in are all drawn, too.
        for _ in 0..<7 {
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load more history")))
            host.settle(passes: 2)
        }
        await host.settle { drawnTurnCount(host) == 90 }
        XCTAssertFalse(listed(host).contains(L10n.string("Load more history")), "every turn is drawn")
    }

    /// A Codex thread holds 20 loaded turns and more behind the provider's cursor: the window draws 10
    /// of the loaded turns, the rail first brings in the other 10, and only then asks the provider for
    /// its earlier page, which is drawn whole over the next few display cycles, not in the one it
    /// arrives in.
    func testACodexThreadWindowsItsLoadedTurnsBeforeAskingForEarlierPages() async throws {
        var state = codexThread(turns: 81...100)
        state.thread?.turnsNextCursor = "earlier"
        let requests = Counter()
        var actions = ConversationActions()
        actions.loadMoreCodexTurns = { requests.count += 1 }
        let feed = Feed(state)
        let host = mount(FeedView(feed: feed, actions: actions))
        defer { host.close() }
        XCTAssertEqual(drawnTurnCount(host), 10)

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load more history")))
        await host.settle { drawnTurnCount(host) == 20 }
        XCTAssertEqual(requests.count, 0, "the loaded turns come first")
        XCTAssertTrue(listed(host).contains(L10n.string("Load more history")), "the provider holds more")

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load more history")))
        host.settle(passes: 6)
        XCTAssertEqual(requests.count, 1)
        // The provider's page of 80 earlier turns arrives in front of the loaded ones.
        var paged = codexThread(turns: 100)
        paged.thread?.turnsNextCursor = nil
        feed.state = paged
        host.settle(passes: 1)
        XCTAssertLessThan(drawnTurnCount(host) ?? 0, 100, "a page's turns are not all built in one display cycle")
        await host.settle { drawnTurnCount(host) == 100 }
        XCTAssertFalse(listed(host).contains(L10n.string("Load more history")), "every turn is drawn")
    }

    /// A saved place in a Codex turn the window leaves out widens the window to it; the turns before
    /// it stay out.
    func testASavedCodexPlaceOutsideTheWindowWidensIt() throws {
        let position = TranscriptReadingPosition()
        position.bookmark = .init(anchorID: "turn-5", fraction: 0, followsLatest: false)
        let host = mount(ConversationTimeline(
            source: .codex(codexThread(turns: 60), workspaceURL: URL(filePath: "/tmp/yardlet"), historySelection: nil),
            readingPosition: position
        ), passes: 16)
        defer { host.close() }
        XCTAssertEqual(position.bookmark.anchorID, "turn-5")
        let shown = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        XCTAssertTrue(shown.contains("Request 5"), "the saved place is in view:\n\(shown)")
        XCTAssertEqual(drawnTurnCount(host), 56, "turns 5 to 60; the ones before it stay out")
    }

    /// A Codex task opened from a history search result whose match is in a turn the window leaves
    /// out widens the window to that turn and shows it.
    func testAHistoryResultOutsideTheWindowWidensIt() throws {
        let selection = CodexHistorySearchSelection(query: "Answer 3", snippet: nil, turnID: "turn-3", itemID: "a3")
        let host = mount(ConversationTimeline(
            source: .codex(codexThread(turns: 60), workspaceURL: URL(filePath: "/tmp/yardlet"), historySelection: selection)
        ), passes: 16)
        defer { host.close() }
        XCTAssertEqual(drawnTurnCount(host), 58, "turns 3 to 60; the ones before it stay out")
        // Bringing the match into view is an animated scroll, which a locked or sleeping Mac stops
        // (`TranscriptAutoFollowTests`), so only that check waits for an awake, unlocked display.
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "Scrolling needs an awake display")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf((session?["CGSSessionScreenIsLocked"] as? Bool) == true, "Scrolling needs an unlocked screen")
        let shown = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        XCTAssertTrue(shown.contains("Answer 3"), "the history match is in view:\n\(shown)")
    }

    // MARK: - Fixtures

    @Observable
    final class Feed {
        var state: CodexTaskState
        init(_ state: CodexTaskState) { self.state = state }
    }

    private struct FeedView: View {
        let feed: Feed
        let actions: ConversationActions
        var body: some View {
            ConversationTimeline(
                source: .codex(feed.state, workspaceURL: URL(filePath: "/tmp/yardlet"), historySelection: nil),
                actions: actions
            )
        }
    }

    private final class Counter { var count = 0 }

    private func mount(_ view: some View, passes: Int = 10) -> WindowlessRender.Host<AnyView> {
        let host = WindowlessRender.Host(
            AnyView(view.frame(width: 620, height: 600).background(ParityTheme.canvas)),
            size: NSSize(width: 620, height: 600)
        )
        host.settle(passes: passes)
        return host
    }

    private func listed(_ host: WindowlessRender.Host<AnyView>) -> String {
        host.accessibilityElements().map(\.description).joined(separator: "\n")
    }

    /// How many turns the conversation draws, as its rail names them ("Turn 40 of 40"): the rail
    /// keeps its latest marks in view, and turns are laid out lazily, so the conversation's own
    /// elements list only the turns near the viewport.
    private func drawnTurnCount(_ host: WindowlessRender.Host<AnyView>) -> Int? {
        host.accessibilityElements().compactMap { element -> Int? in
            guard ConversationDrawing.isRailTurn(element.label) else { return nil }
            return element.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
        }.max()
    }

    /// The requests the conversation draws, by number, in order.
    private func drawnRequests(_ host: WindowlessRender.Host<AnyView>) -> [Int] {
        host.accessibilityElements().compactMap { element in
            let text = element.value.isEmpty ? element.label : element.value
            guard text.hasPrefix("Request ") else { return nil }
            return Int(text.dropFirst("Request ".count))
        }
    }

    /// `turns` finished Codex turns, `turn-1` first, each a request and its answer.
    private func codexThread(turns: Int) -> CodexTaskState {
        codexThread(turns: 1...turns)
    }

    /// Turns `turns` of the thread, as the pages loaded so far hold them.
    private func codexThread(turns: ClosedRange<Int>) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-window")]))!
        thread.turns = turns.map { index in
            decoder.turn(from: .object([
                "id": .string("turn-\(index)"), "status": .string("completed"), "durationMs": .integer(1_000),
                "items": .array([
                    .object(["id": .string("u\(index)"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                    .object(["id": .string("a\(index)"), "type": .string("agentMessage"),
                             "text": .string("Answer \(index)"), "phase": .string("final_answer")])
                ])
            ]), fallbackID: "turn-\(index)")!
        }
        return CodexTaskState(thread: thread)
    }
}
