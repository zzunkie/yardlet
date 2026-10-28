import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Saved reading places read by the conversation renderer (plan A3.5, M7): old shared-transcript row
/// anchors, detached Codex snapshot entries and Codex turns all land on a turn, the snapshot names
/// its entries the same way at every checkpoint, a saved version 1 workspace keeps both bookmarks,
/// and a place the conversation cannot show yet is kept until it can.
@MainActor
final class ConversationAnchorMigrationTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let workspace = URL(filePath: "/tmp/yardlet-anchor-migration")

    // MARK: - Name-based IDs

    func testNameBasedUUIDsMatchTheStandard() {
        XCTAssertEqual(NameBasedUUID.sha1(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(NameBasedUUID.sha1([]).map { String(format: "%02x", $0) }.joined(),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let long = String(repeating: "a", count: 1_000)
        XCTAssertEqual(NameBasedUUID.sha1(Array(long.utf8)).map { String(format: "%02x", $0) }.joined(),
                       "291e9a6c66994949b57ba5e650361e98fc36b1ba")
        // RFC 4122 version 5 with the DNS namespace, as Python's uuid.uuid5 computes it.
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(NameBasedUUID.make(namespace: dns, name: "python.org").uuidString.lowercased(),
                       "886313e1-3b8a-5372-9b90-0c9aee199e5d")
        let url = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(NameBasedUUID.make(namespace: url, name: "https://example.com/한글").uuidString.lowercased(),
                       "de9bab8e-fea2-5f17-a64f-c31e79068fa5")
    }

    func testTheSnapshotNamesEachEntryTheSameAtEveryCheckpoint() {
        let state = thread()
        let first = CodexTranscriptSnapshotProjection.entries(from: state)
        let second = CodexTranscriptSnapshotProjection.entries(from: state)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "every entry has its own ID")

        // The message that opens a turn is named by the turn; the rest by turn and item.
        func id(_ text: String) -> UUID? {
            first.first { entry in
                switch entry.content {
                case let .user(value, _), let .assistant(value, _): value == text
                case let .plan(value): value == text
                case let .error(message, _, _): message == text
                default: false
                }
            }?.id
        }
        XCTAssertEqual(id("Request 2"), CodexTranscriptSnapshotProjection.turnEntryID(threadID: "thread-a", turnID: "turn-2"))
        XCTAssertEqual(id("Also this"), CodexTranscriptSnapshotProjection.itemEntryID(
            threadID: "thread-a", turnID: "turn-2", itemID: "steer-2"))
        XCTAssertEqual(id("Answer 2"), CodexTranscriptSnapshotProjection.itemEntryID(
            threadID: "thread-a", turnID: "turn-2", itemID: "answer-2"))
        XCTAssertEqual(id("Overloaded"), CodexTranscriptSnapshotProjection.errorEntryID(threadID: "thread-a", turnID: "turn-3"))
        // An empty message is not an entry, so the next message opens the turn.
        XCTAssertEqual(id("Request 3"), CodexTranscriptSnapshotProjection.turnEntryID(threadID: "thread-a", turnID: "turn-3"))
        // The same item ID in another thread is another entry.
        var other = state
        other.thread = decoder.thread(from: .object(["id": .string("thread-b")]))
        other.thread?.turns = state.thread?.turns ?? []
        XCTAssertTrue(Set(CodexTranscriptSnapshotProjection.entries(from: other).map(\.id)).isDisjoint(with: first.map(\.id)))
    }

    // MARK: - Resolving

    func testAnOldTranscriptRowReadsAsTheTurnThatHoldsIt() {
        let user = TranscriptEntry(content: .user(text: "Fix it"))
        let note = TranscriptEntry(content: .assistant(text: "Looking.", isStreaming: false))
        let tool = TranscriptEntry(content: .activity(HarnessActivity(id: "t1", kind: "Bash", title: "Bash"), state: .completed))
        let answer = TranscriptEntry(content: .assistant(text: "Fixed.", isStreaming: false))
        let next = TranscriptEntry(content: .user(text: "Thanks"))
        let reply = TranscriptEntry(content: .assistant(text: "You're welcome.", isStreaming: false))
        let plan = TranscriptEntry(content: .plan("☐ Step"))
        let failure = TranscriptEntry(content: .error(message: "Broke", recoverable: true))
        let entries = [user, note, tool, answer, next, reply, plan, failure]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        let resolver = ConversationAnchorResolver(presentation: presentation, threadID: nil)
        func bookmark(_ entry: TranscriptEntry) -> TranscriptReadingBookmark {
            .init(anchorID: entry.id.uuidString, fraction: 0.4, followsLatest: false)
        }
        // The message that opened the turn keeps the place within it.
        XCTAssertEqual(resolver.resolve(bookmark(user)), .init(anchorID: user.id.uuidString, fraction: 0.4, followsLatest: false))
        // Any other row, the old folded-work row (its first entry) included, starts at the turn's top.
        for entry in [note, tool, answer] {
            XCTAssertEqual(resolver.resolve(bookmark(entry)), .init(anchorID: user.id.uuidString, fraction: 0, followsLatest: false))
        }
        for entry in [reply, plan, failure] {
            XCTAssertEqual(resolver.resolve(bookmark(entry))?.anchorID, next.id.uuidString)
        }
        XCTAssertNil(resolver.resolve(.init(anchorID: UUID().uuidString, fraction: 0.4, followsLatest: false)))
        XCTAssertEqual(resolver.resolve(.init()), .init())
    }

    func testASnapshotPlaceReadsAsTheThreadTurnAndATurnAsTheSnapshotEntry() {
        let state = thread()
        let attached = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
        let detached = TranscriptConversationProjection.presentation(
            from: CodexTranscriptSnapshotProjection.entries(from: state), harness: .codex, status: .ready,
            latestTurnIsComplete: true
        )
        let opening = CodexTranscriptSnapshotProjection.turnEntryID(threadID: "thread-a", turnID: "turn-2").uuidString
        XCTAssertTrue(detached.turns.contains { $0.id == opening })

        // Detached place, attached thread.
        let thread = ConversationAnchorResolver(presentation: attached, threadID: "thread-a")
        XCTAssertEqual(thread.resolve(.init(anchorID: opening, fraction: 0.3, followsLatest: false)),
                       .init(anchorID: "turn-2", fraction: 0.3, followsLatest: false))
        let answer = CodexTranscriptSnapshotProjection.itemEntryID(threadID: "thread-a", turnID: "turn-2", itemID: "answer-2")
        XCTAssertEqual(thread.resolve(.init(anchorID: answer.uuidString, fraction: 0.3, followsLatest: false)),
                       .init(anchorID: "turn-2", fraction: 0, followsLatest: false))
        let error = CodexTranscriptSnapshotProjection.errorEntryID(threadID: "thread-a", turnID: "turn-3")
        XCTAssertEqual(thread.anchor(for: error.uuidString)?.turnID, "turn-3")
        // Another thread's snapshot names nothing here.
        XCTAssertNil(ConversationAnchorResolver(presentation: attached, threadID: "thread-b").resolve(
            .init(anchorID: opening, fraction: 0.3, followsLatest: false)))

        // A place on the thread's turn, shown detached.
        let snapshot = ConversationAnchorResolver(presentation: detached, threadID: "thread-a")
        XCTAssertEqual(snapshot.resolve(.init(anchorID: "turn-2", fraction: 0.6, followsLatest: false)),
                       .init(anchorID: opening, fraction: 0.6, followsLatest: false))
        XCTAssertNil(snapshot.resolve(.init(anchorID: "turn-9", fraction: 0.6, followsLatest: false)))

        // Renamed, not moved on: the snapshot's latest turn is the thread's latest turn.
        let snapshotLatest = CodexTranscriptSnapshotProjection.turnEntryID(threadID: "thread-a", turnID: "turn-3").uuidString
        XCTAssertTrue(thread.isRenamed(snapshotLatest, as: "turn-3"))
        XCTAssertFalse(thread.isRenamed(snapshotLatest, as: "turn-2"))
        XCTAssertFalse(thread.isRenamed("turn-2", as: "turn-3"), "a turn still shown was not renamed")
        XCTAssertFalse(thread.isRenamed(UUID().uuidString, as: "turn-3"), "a sent message's echo is a new request")
    }

    func testTheConversationsOwnBookmarkComesFirstAndAnEarlierOneIsReadOnlyWhenItFollows() {
        let state = thread()
        let attached = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
        let resolver = ConversationAnchorResolver(presentation: attached, threadID: "thread-a")
        let opening = CodexTranscriptSnapshotProjection.turnEntryID(threadID: "thread-a", turnID: "turn-1").uuidString
        let earlier = TranscriptReadingBookmark(anchorID: opening, fraction: 0.5, followsLatest: false)
        let own = TranscriptReadingBookmark(anchorID: "turn-2", fraction: 0.2, followsLatest: false)
        XCTAssertEqual(resolver.startingBookmark(saved: own, earlier: earlier), own)
        XCTAssertEqual(resolver.startingBookmark(saved: .init(), earlier: earlier),
                       .init(anchorID: "turn-1", fraction: 0.5, followsLatest: false))
        XCTAssertEqual(resolver.startingBookmark(saved: .init(), earlier: .init(anchorID: UUID().uuidString,
                                                                                 fraction: 0.5, followsLatest: false)),
                       .init())
        // A place this conversation does not hold yet is passed on as saved, for the tracker to keep.
        let elsewhere = TranscriptReadingBookmark(anchorID: "turn-0", fraction: 0.2, followsLatest: false)
        XCTAssertEqual(resolver.startingBookmark(saved: elsewhere, earlier: earlier), elsewhere)
    }

    // MARK: - Saved workspaces

    func testASavedVersionOneWorkspaceKeepsBothBookmarksAndReadsThemByTurn() throws {
        let state = thread()
        let snapshotAnswer = CodexTranscriptSnapshotProjection.itemEntryID(
            threadID: "thread-a", turnID: "turn-1", itemID: "answer-1"
        ).uuidString
        // As a build before M7 saved it: the shared transcript's bookmark on a detached snapshot's
        // row, and the Codex timeline's on a turn.
        let json = """
        {"version":1,"panels":{"trailingTabs":[],"isTerminalPresented":false},
         "layout":{"panelWidth":420,"terminalHeight":240,"isExpanded":false},
         "transcript":{"anchorID":"\(snapshotAnswer)","fraction":0.75,"followsLatest":false},
         "codex":{"anchorID":"turn-2","fraction":0.25,"followsLatest":false}}
        """
        let suite = testDefaultsSuite("ConversationAnchorMigrationTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let id = UUID()
        defaults.set(Data(json.utf8), forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        let repository = UserDefaultsTaskWorkspaceRepository(defaults: defaults)
        let saved = try XCTUnwrap(repository.load(for: id), "a version 1 workspace still decodes")
        let workspaceState = TaskWorkspaceState(snapshot: saved)
        XCTAssertEqual(workspaceState.codex.bookmark, .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false))
        XCTAssertEqual(workspaceState.transcript.bookmark.anchorID, snapshotAnswer)

        let attached = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
        let resolver = ConversationAnchorResolver(presentation: attached, threadID: "thread-a")
        XCTAssertEqual(resolver.startingBookmark(saved: workspaceState.codex.bookmark,
                                                 earlier: workspaceState.transcript.bookmark),
                       .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false))
        workspaceState.codex.bookmark = .init()
        XCTAssertEqual(resolver.startingBookmark(saved: workspaceState.codex.bookmark,
                                                 earlier: workspaceState.transcript.bookmark),
                       .init(anchorID: "turn-1", fraction: 0, followsLatest: false))

        // Saving again keeps version 1 and both fields.
        repository.save(workspaceState.snapshot, for: id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: "Yardlet.taskWorkspace.\(id.uuidString)"))) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["transcript"])
        XCTAssertNotNil(object["codex"])
    }

    // MARK: - Keeping a place

    func testAPlaceTheConversationCannotShowYetIsKeptUntilItCan() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false)
        let opening = "snapshot-turn-2"
        // Detached: the snapshot names turn-2 `opening`; this one does not hold it.
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["snapshot-turn-5"]) { saved in
            saved.anchorID == "turn-2" ? nil : saved
        }
        XCTAssertEqual(tracker.request, .latest)
        tracker.observe(offset: 0, height: 900, viewport: CGSize(width: 500, height: 400), followsLatest: true, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(record.bookmark, .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false),
                       "following the latest output does not overwrite a place kept for later")

        // The thread attaches and holds the place.
        tracker.updateItems(["turn-1", "turn-2", "turn-5"]) { saved in saved }
        XCTAssertEqual(tracker.request, .anchor("turn-2"))
        XCTAssertTrue(tracker.isRestoring)

        // Reading in one name, the conversation renames it: the place moves with it.
        let renamed = TranscriptReadingPosition()
        renamed.bookmark = .init(anchorID: opening, fraction: 0.5, followsLatest: false)
        let reading = TranscriptReadingTracker()
        reading.start(record: renamed, itemIDs: [opening, "snapshot-turn-3"]) { $0 }
        reading.measure(id: opening, frame: CGRect(x: 0, y: -400, width: 500, height: 800))
        reading.observe(offset: 400, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false,
                        userDriven: false)
        reading.settleGeometry()
        XCTAssertFalse(reading.isRestoring)
        reading.updateItems(["turn-2", "turn-3"]) { saved in
            saved.anchorID == opening ? .init(anchorID: "turn-2", fraction: saved.fraction, followsLatest: false) : saved
        }
        XCTAssertEqual(reading.request, .anchor("turn-2"))

        // The reader moving on lets the kept place go.
        let moved = TranscriptReadingPosition()
        moved.bookmark = .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false)
        let movedTracker = TranscriptReadingTracker()
        movedTracker.start(record: moved, itemIDs: ["snapshot-turn-5"]) { _ in nil }
        movedTracker.observe(offset: 0, height: 900, viewport: CGSize(width: 500, height: 400), followsLatest: true,
                             userDriven: true)
        movedTracker.settleGeometry()
        XCTAssertTrue(moved.bookmark.followsLatest)

        // Without a resolver the tracker behaves as before: a missing place falls back to the latest.
        let plain = TranscriptReadingPosition()
        plain.bookmark = .init(anchorID: "turn-2", fraction: 0.25, followsLatest: false)
        let plainTracker = TranscriptReadingTracker()
        plainTracker.start(record: plain, itemIDs: ["turn-5"])
        plainTracker.observe(offset: 0, height: 900, viewport: CGSize(width: 500, height: 400), followsLatest: true,
                             userDriven: false)
        plainTracker.settleGeometry()
        XCTAssertTrue(plain.bookmark.followsLatest)
    }

    func testTheLatestRequestKeepsItsKeyWhileTheTurnsAreRenamed() {
        let latest = ConversationLatestRequest()
        XCTAssertNil(latest.id(latestTurnID: nil) { _, _ in true })
        XCTAssertEqual(latest.id(latestTurnID: "echo") { _, _ in false }, "echo")
        XCTAssertEqual(latest.id(latestTurnID: "snapshot-3") { _, _ in false }, "snapshot-3")
        XCTAssertEqual(latest.id(latestTurnID: "turn-3") { old, new in old == "snapshot-3" && new == "turn-3" }, "snapshot-3")
        XCTAssertEqual(latest.id(latestTurnID: "turn-3") { _, _ in false }, "snapshot-3")
        XCTAssertEqual(latest.id(latestTurnID: "turn-4") { _, _ in false }, "turn-4")
    }

    // MARK: - A saved Claude workspace (M9)

    /// As a build before M9 saved a Claude task: the transcript bookmark on the row that folded a
    /// finished turn's work (the old rows named it by its first entry). The renderer shows the turn
    /// that holds the row, from its top, and saves the place by the turn, which reads the same after
    /// saving again.
    func testASavedClaudeWorkspaceReadsItsRowPlaceAsTheTurnThatHoldsIt() throws {
        let (entries, turns) = claudeConversation(turns: 12)
        let foldedRow = turns[3].work
        let json = """
        {"version":1,"panels":{"trailingTabs":[],"isTerminalPresented":false},
         "layout":{"panelWidth":420,"terminalHeight":240,"isExpanded":false},
         "transcript":{"anchorID":"\(foldedRow.id.uuidString)","fraction":0.6,"followsLatest":false},
         "codex":{"followsLatest":true,"fraction":0}}
        """
        let suite = testDefaultsSuite("ConversationAnchorMigrationTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let id = UUID()
        defaults.set(Data(json.utf8), forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        let repository = UserDefaultsTaskWorkspaceRepository(defaults: defaults)
        let workspaceState = TaskWorkspaceState(snapshot: try XCTUnwrap(repository.load(for: id)))
        XCTAssertEqual(workspaceState.transcript.bookmark.anchorID, foldedRow.id.uuidString)

        let host = mountClaude(entries, reading: workspaceState.transcript)
        let scroll = try XCTUnwrap(tallestScrollView(in: host.hosting))
        XCTAssertEqual(workspaceState.transcript.bookmark,
                       .init(anchorID: turns[3].request.id.uuidString, fraction: 0, followsLatest: false),
                       "the place reads as its turn, from the turn's top")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertGreaterThan(distanceToBottom(scroll), 48, "the saved place, not the latest output")
        let shown = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        XCTAssertTrue(shown.contains("Request 4"), shown)
        host.close()

        // Saving again keeps version 1 and the turn's place.
        repository.save(workspaceState.snapshot, for: id)
        let reloaded = TaskWorkspaceState(snapshot: try XCTUnwrap(repository.load(for: id)))
        let again = mountClaude(entries, reading: reloaded.transcript)
        defer { again.close() }
        XCTAssertEqual(reloaded.transcript.bookmark.anchorID, turns[3].request.id.uuidString)
        XCTAssertFalse(reloaded.transcript.bookmark.followsLatest)
        let shownAgain = again.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        XCTAssertTrue(shownAgain.contains("Request 4"), shownAgain)
    }

    /// A saved place in a turn the transcript's window leaves out widens the window to that turn
    /// (plan A5.3); the turns before it stay out behind "Load more history".
    func testASavedPlaceInATurnTheWindowLeavesOutWidensTheWindow() throws {
        let (entries, turns) = claudeConversation(turns: 12)
        let position = TranscriptReadingPosition()
        position.bookmark = .init(anchorID: turns[1].request.id.uuidString, fraction: 0, followsLatest: false)
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        XCTAssertTrue(ConversationTurnWindow(turnCount: 3).hides(turns[1].request.id.uuidString, in: presentation))
        let host = WindowlessRender.Host(
            ConversationTimeline(
                source: .transcript(entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true),
                readingPosition: position, turnWindowCount: 3
            )
            .frame(width: 620, height: 420)
            .background(ParityTheme.canvas),
            size: NSSize(width: 620, height: 420)
        )
        defer { host.close() }
        host.settle(passes: 16)
        XCTAssertEqual(position.bookmark, .init(anchorID: turns[1].request.id.uuidString, fraction: 0, followsLatest: false))
        let shown = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        XCTAssertTrue(shown.contains("Request 2"), shown)
        let listed = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertFalse(listed.contains("“Request 1”"), "the turn before the place stays out:\n\(listed)")
        XCTAssertTrue(listed.contains(L10n.string("Load more history")), listed)
    }

    // MARK: - Fixtures

    /// A Claude conversation of finished turns, each a request, commentary, a tool call and a long
    /// answer, so the work folds and the conversation scrolls.
    private func claudeConversation(turns count: Int)
        -> ([TranscriptEntry], [(request: TranscriptEntry, work: TranscriptEntry)]) {
        var entries: [TranscriptEntry] = []
        var turns: [(request: TranscriptEntry, work: TranscriptEntry)] = []
        for index in 1...count {
            let request = TranscriptEntry(content: .user(text: "Request \(index)"))
            let work = TranscriptEntry(content: .assistant(text: "Looking at \(index).", isStreaming: false))
            entries += [
                request, work,
                TranscriptEntry(content: .activity(HarnessActivity(id: "tool-\(index)", kind: "Bash", title: "Bash",
                                                                   input: "swift test"), state: .completed)),
                TranscriptEntry(content: .assistant(
                    text: "Answer \(index). " + String(repeating: "The change keeps the reading place. ", count: 10),
                    isStreaming: false
                ))
            ]
            turns.append((request, work))
        }
        return (entries, turns)
    }

    private func mountClaude(
        _ entries: [TranscriptEntry], reading: TranscriptReadingPosition
    ) -> WindowlessRender.Host<some View> {
        let host = WindowlessRender.Host(
            TaskConversationView(harness: .claudeCode, workspaceURL: workspace, entries: entries,
                                 latestTurnIsComplete: true, transcriptReading: reading)
                .frame(width: 620, height: 420)
                .background(ParityTheme.canvas),
            size: NSSize(width: 620, height: 420)
        )
        host.settle(passes: 16)
        return host
    }

    private func tallestScrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    private func distanceToBottom(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }

    /// Three turns: a plain one, one with a steered second message, and a failed one whose first
    /// message is empty.
    private func thread() -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-a")]))!
        thread.turns = [
            turn("turn-1", items: [user("user-1", "Request 1"), answer("answer-1", "Answer 1")]),
            turn("turn-2", items: [
                user("user-2", "Request 2"), user("steer-2", "Also this"),
                .object(["id": .string("note-2"), "type": .string("agentMessage"), "text": .string("Looking"),
                         "phase": .string("commentary")]),
                .object(["id": .string("plan-2"), "type": .string("plan"), "text": .string("# Plan")]),
                answer("answer-2", "Answer 2")
            ]),
            turn("turn-3", status: "failed", items: [
                .object(["id": .string("empty-3"), "type": .string("userMessage"), "content": .array([])]),
                user("user-3", "Request 3")
            ], error: .string("Overloaded"))
        ]
        return CodexTaskState(thread: thread)
    }

    private func turn(_ id: String, status: String = "completed", items: [JSONValue], error: JSONValue? = nil) -> CodexTurnState {
        var value: [String: JSONValue] = ["id": .string(id), "status": .string(status), "items": .array(items)]
        if let error { value["error"] = error }
        return decoder.turn(from: .object(value), fallbackID: id)!
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func answer(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")])
    }
}
