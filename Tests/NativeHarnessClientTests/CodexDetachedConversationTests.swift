import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Codex task before its first turn and while detached (plan M7):
/// the saved snapshot or the sent message first, then the thread once it attaches, in the same view.
/// Mounted in an unshown window through `TaskConversationView`, as the task draws it. Images go to
/// `.build/codex-detached-qa/codex-{detached,attached}-{light,dark}.png`.
@MainActor
final class CodexDetachedConversationTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        var state: CodexTaskState?
        init(entries: [TranscriptEntry], state: CodexTaskState? = nil) {
            self.entries = entries
            self.state = state
        }
    }

    private static let size = NSSize(width: 620, height: 420)
    private static let pinned: CGFloat = 48
    private static let threadID = "thread-detached"
    private let decoder = CodexTaskDecoder()

    func testADetachedTaskKeepsItsViewWhenItsThreadAttaches() throws {
        let state = thread(turns: 1...10)
        let directory = try WindowlessRender.directory("codex-detached-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let feed = Feed(entries: CodexTranscriptSnapshotProjection.entries(from: state))
            let host = mount(feed, workspace: TaskWorkspaceState(), appearance: appearance)
            defer { host.close() }
            let detached = try XCTUnwrap(scrollView(in: host.hosting))
            XCTAssertLessThanOrEqual(distance(detached), Self.pinned, "a detached task opens at its latest turn")
            let detachedText = host.accessibilityElements().map(\.description).joined(separator: "\n")
            XCTAssertTrue(detachedText.contains("Answer 10"), detachedText)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "codex-detached-\(appearance.suffix).png"))

            feed.state = state
            host.settle(passes: 10)
            let attached = try XCTUnwrap(scrollView(in: host.hosting))
            XCTAssertTrue(attached === detached, "attaching replaced the conversation's scroll view")
            XCTAssertLessThanOrEqual(distance(attached), Self.pinned, "following goes on")
            let attachedText = host.accessibilityElements().map(\.description).joined(separator: "\n")
            XCTAssertTrue(attachedText.contains(L10n.format("Turn %lld of %lld", Int64(10), Int64(10))), attachedText)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "codex-attached-\(appearance.suffix).png"))
        }
    }

    func testAPlaceSavedOnACodexTurnIsShownDetachedAndKeptWhenTheThreadAttaches() throws {
        let state = thread(turns: 1...10)
        let workspace = TaskWorkspaceState()
        workspace.codex.bookmark = .init(anchorID: "turn-4", fraction: 0, followsLatest: false)
        let feed = Feed(entries: CodexTranscriptSnapshotProjection.entries(from: state))
        let host = mount(feed, workspace: workspace)
        defer { host.close() }
        let scroll = try XCTUnwrap(scrollView(in: host.hosting))
        let opening = CodexTranscriptSnapshotProjection.turnEntryID(threadID: Self.threadID, turnID: "turn-4").uuidString
        XCTAssertEqual(workspace.codex.bookmark.anchorID, opening, "the snapshot shows the saved turn")
        XCTAssertGreaterThan(distance(scroll), Self.pinned)
        let detachedOffset = scroll.contentView.bounds.minY

        feed.state = state
        host.settle(passes: 12)
        XCTAssertTrue(try XCTUnwrap(scrollView(in: host.hosting)) === scroll)
        XCTAssertEqual(workspace.codex.bookmark, .init(anchorID: "turn-4", fraction: 0, followsLatest: false),
                       "the thread shows the same turn and saves it by its own name")
        XCTAssertGreaterThan(distance(scroll), Self.pinned, "attaching is not a new request")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertGreaterThan(detachedOffset, 0)
    }

    func testAPlaceTheSnapshotDoesNotHoldIsKeptUntilTheThreadAttaches() throws {
        let state = thread(turns: 1...10)
        let workspace = TaskWorkspaceState()
        workspace.codex.bookmark = .init(anchorID: "turn-2", fraction: 0, followsLatest: false)
        // A snapshot that kept only the newest turns.
        let feed = Feed(entries: CodexTranscriptSnapshotProjection.entries(from: thread(turns: 6...10)))
        let host = mount(feed, workspace: workspace)
        defer { host.close() }
        let scroll = try XCTUnwrap(scrollView(in: host.hosting))
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned, "what the snapshot lacks, it cannot show")
        XCTAssertEqual(workspace.codex.bookmark, .init(anchorID: "turn-2", fraction: 0, followsLatest: false),
                       "the saved place is kept, not replaced by the latest output")

        feed.state = state
        host.settle(passes: 12)
        XCTAssertEqual(workspace.codex.bookmark, .init(anchorID: "turn-2", fraction: 0, followsLatest: false))
        XCTAssertGreaterThan(distance(scroll), Self.pinned, "the thread shows the kept place")
    }

    func testTheFirstMessageOfANewTaskStaysWhenItsTurnArrives() throws {
        let workspace = TaskWorkspaceState()
        // What the shared transcript kept for this task before (read once, then folded in).
        workspace.transcript.bookmark = .init(anchorID: UUID().uuidString, fraction: 0.5, followsLatest: false)
        let feed = Feed(entries: [TranscriptEntry(content: .user(text: "Start the build"))])
        let host = mount(feed, workspace: workspace)
        defer { host.close() }
        let scroll = try XCTUnwrap(scrollView(in: host.hosting))
        XCTAssertEqual(workspace.transcript.bookmark, TranscriptReadingBookmark(), "the old bookmark is read once")
        XCTAssertTrue(workspace.codex.bookmark.followsLatest)
        let echo = host.accessibilityElements().map(\.description)
        XCTAssertEqual(echo.filter { $0.contains("Start the build") }.count, 1, echo.joined(separator: "\n"))

        var started = thread(turns: 1...1)
        started.thread?.turns[0] = turn("turn-1", status: "inProgress", items: [user("user-1", "Start the build")])
        feed.state = started
        host.settle(passes: 10)
        XCTAssertTrue(try XCTUnwrap(scrollView(in: host.hosting)) === scroll)
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)
        let turnText = host.accessibilityElements().map(\.description)
        XCTAssertEqual(turnText.filter { $0.contains("Start the build") }.count, 1, turnText.joined(separator: "\n"))
    }

    // MARK: - Fixtures

    private struct Host: View {
        let feed: Feed
        let workspace: TaskWorkspaceState
        var body: some View {
            TaskConversationView(
                harness: .codex, workspaceURL: URL(filePath: "/tmp/qa"), entries: feed.entries,
                sessionStatus: .ready, latestTurnIsComplete: true, codexTaskState: feed.state,
                providerSessionID: CodexDetachedConversationTests.threadID,
                transcriptReading: workspace.transcript, codexReading: workspace.codex,
                actions: ConversationActions(retryTurn: { _ in })
            )
            .frame(width: CodexDetachedConversationTests.size.width, height: CodexDetachedConversationTests.size.height)
        }
    }

    private func mount(
        _ feed: Feed, workspace: TaskWorkspaceState,
        appearance: WindowlessRender.Appearance = .light
    ) -> WindowlessRender.Host<some View> {
        let host = WindowlessRender.Host(
            Host(feed: feed, workspace: workspace)
                .environment(\.colorScheme, appearance.colorScheme)
                .background(ParityTheme.canvas),
            size: Self.size, appearance: appearance
        )
        host.settle(passes: 12)
        return host
    }

    private func thread(turns: ClosedRange<Int>) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string(Self.threadID)]))!
        thread.turns = turns.map { index in
            turn("turn-\(index)", status: "completed", items: [
                user("user-\(index)", "Request \(index)"),
                answer("answer-\(index)", "Answer \(index). " + String(repeating: "The change keeps the reading place. ", count: 8))
            ])
        }
        return CodexTaskState(thread: thread)
    }

    private func turn(_ id: String, status: String, items: [JSONValue]) -> CodexTurnState {
        decoder.turn(from: .object([
            "id": .string(id), "status": .string(status), "durationMs": .integer(12_000), "items": .array(items)
        ]), fallbackID: id)!
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func answer(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")])
    }

    /// The conversation's scroll view: the tallest one, as the composer has small ones of its own.
    private func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    private func distance(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }
}
