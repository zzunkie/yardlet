import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A detached Codex task, opened after a relaunch, shows its newest turns as the Codex app does:
/// commands and file changes, not only the messages its reading snapshot keeps. Opening reads the
/// saved thread through the task's App Server (`thread/read` without its turns, then the newest
/// page of `thread/turns/list`, in the shapes a real `codex app-server` 0.157.1 gives for a
/// not-loaded thread) and never resumes it, starts a turn or connects the task. The snapshot is the
/// first paint; the thread replaces it in the same view.
@MainActor
final class CodexDetachedThreadReadTests: XCTestCase {
    private static let threadID = "thread-saved"

    func testOpeningADetachedTaskReadsItsThreadWithoutResumingIt() async throws {
        let fixture = try DetachedCodexFixture(in: self)
        let model = fixture.model, session = fixture.session
        XCTAssertNil(model.codexPresentationBySessionID[session.id])
        XCTAssertEqual(model.transcriptBySessionID[session.id], fixture.snapshot, "the snapshot is the first paint")
        XCTAssertFalse(Self.kinds(in: Self.snapshotPresentation(fixture.snapshot)).contains("command"))

        // What the task's composer does when the task is opened.
        await model.refreshConversationStatus(for: session)

        let methods = await fixture.transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/read", "thread/turns/list"],
                       "reading resumes nothing and starts no turn")
        let read = await fixture.transport.requests.first { $0.method == "thread/read" }
        XCTAssertEqual(read?.params["threadId"]?.stringValue, Self.threadID)
        XCTAssertEqual(read?.params["includeTurns"], .bool(false), "the thread without its turns")
        let page = await fixture.transport.requests.first { $0.method == "thread/turns/list" }
        XCTAssertEqual(page?.params["threadId"]?.stringValue, Self.threadID)
        XCTAssertEqual(page?.params["sortDirection"], .string("desc"), "the newest turns")
        XCTAssertEqual(page?.params["itemsView"], .string("full"))
        XCTAssertEqual(page?.params["limit"], .integer(CodexThreadPaging.newestTurns))
        XCTAssertNil(page?.params["cursor"])
        XCTAssertFalse(model.isAttached(session.id))
        let current = try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
        XCTAssertEqual(current.status, .completed)
        XCTAssertEqual(current.updatedAt, session.updatedAt)

        let state = try XCTUnwrap(model.codexPresentationBySessionID[session.id])
        let presentation = CodexConversationProjection.presentation(
            state, workspaceURL: session.workspaceURL, historySelection: nil)
        XCTAssertEqual(presentation.turns.map(\.id), ["turn-1", "turn-2"])
        XCTAssertEqual(Self.kinds(in: presentation.turns[0]), ["command", "fileChange"])
        XCTAssertEqual(Self.kinds(in: presentation.turns[1]), ["command"])
        XCTAssertEqual(model.transcriptBySessionID[session.id], fixture.snapshot, "the snapshot itself is kept")
    }

    func testAThreadThatCannotBeReadLeavesTheSnapshot() async throws {
        let fixture = try DetachedCodexFixture(threadRead: nil, in: self)
        await fixture.model.refreshConversationStatus(for: fixture.session)
        let methods = await fixture.transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/read"])
        XCTAssertNil(fixture.model.codexPresentationBySessionID[fixture.session.id])
        XCTAssertEqual(fixture.model.transcriptBySessionID[fixture.session.id], fixture.snapshot)
        XCTAssertFalse(fixture.model.isAttached(fixture.session.id))
    }

    /// The read thread replaces the snapshot in the conversation already on screen: the same
    /// scroll view, now with the turns' work.
    func testTheThreadReplacesTheSnapshotInTheSameView() async throws {
        let fixture = try DetachedCodexFixture(in: self)
        await fixture.model.refreshConversationStatus(for: fixture.session)
        let state = try XCTUnwrap(fixture.model.codexPresentationBySessionID[fixture.session.id])

        let feed = Feed(entries: fixture.snapshot)
        let workspace = TaskWorkspaceState()
        let host = WindowlessRender.Host(
            ConversationUnderTest(feed: feed, workspace: workspace).background(ParityTheme.canvas),
            size: NSSize(width: 620, height: 520), appearance: .light)
        defer { host.close() }
        host.settle(passes: 12)
        let snapshotScroll = try XCTUnwrap(Self.scrollView(in: host.hosting))
        let before = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(before.contains("All tests pass now."), before)
        XCTAssertFalse(before.contains("Edited"), before)

        feed.state = state
        host.settle(passes: 12)
        XCTAssertTrue(try XCTUnwrap(Self.scrollView(in: host.hosting)) === snapshotScroll,
                      "the thread arrives in the view the snapshot was drawn in")
        let after = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(after.contains("All tests pass now."), after)
        // A finished turn folds its work, as Codex does; unfolded, the first turn shows its command
        // and its file change, which the snapshot never held.
        let worked = L10n.format("Worked for %lld seconds", Int64(12))
        XCTAssertTrue(Self.press(worked, in: host.hosting), after)
        host.settle(passes: 12)
        let unfolded = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(unfolded.contains("swift test --filter FlakyTests"), "the command shows: \(unfolded)")
        XCTAssertTrue(unfolded.contains("FlakyTests.swift"), "the file change shows: \(unfolded)")
        try WindowlessRender.writePNG(host.capture().bitmap, to: try WindowlessRender.directory("codex-thread-read-qa")
            .appending(path: "detached-read-light.png"))
    }

    // MARK: - Fixtures

    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        var state: CodexTaskState?
        init(entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct ConversationUnderTest: View {
        let feed: Feed
        let workspace: TaskWorkspaceState
        var body: some View {
            TaskConversationView(
                harness: .codex, workspaceURL: URL(filePath: "/tmp/qa"), entries: feed.entries,
                sessionStatus: .completed, latestTurnIsComplete: true, codexTaskState: feed.state,
                providerSessionID: CodexDetachedThreadReadTests.threadID,
                transcriptReading: workspace.transcript, codexReading: workspace.codex,
                actions: ConversationActions(retryTurn: { _ in }))
                .frame(width: 620, height: 520)
        }
    }

    /// A saved Codex task that has not connected this launch, with its reading snapshot, behind the
    /// product route (the YHP Codex adapter over the App Server adapter) and a fake App Server.
    @MainActor
    struct DetachedCodexFixture {
        let transport: FakeCodexTransport
        let model: AppModel
        let session: SessionRecord
        let snapshot: [TranscriptEntry]

        init(threadRead: JSONValue? = CodexDetachedThreadReadTests.savedThread, in test: XCTestCase) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "codex-thread-read-\(UUID().uuidString)")
            test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appending(path: "codex")
            try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var responses: [String: [JSONValue]] = ["initialize": [.object(["platformOs": .string("macos")])]]
            if let threadRead {
                responses["thread/read"] = [CodexSavedThreadResponses.metadata(threadRead)]
                responses["thread/turns/list"] = [CodexSavedThreadResponses.page(threadRead)]
            }
            transport = FakeCodexTransport(responses: responses)
            let adapter = YHPCodexCompatibilityAdapter(
                adapter: CodexAdapter(executableURL: executable, transport: transport),
                manifest: HarnessProtocolCompatibilityManifest.codex())
            session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
                title: "Saved", status: .completed, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), providerSessionID: CodexDetachedThreadReadTests.threadID)
            let saved = CodexTaskState(thread: CodexTaskDecoder().thread(from: CodexDetachedThreadReadTests.savedThread))
            snapshot = CodexTranscriptSnapshotProjection.entries(from: saved)
            let suite = testDefaultsSuite("CodexThreadRead")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let session = session
            let model = AppModel(
                store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
                registry: HarnessRegistry { _, _ in adapter },
                modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                    claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex-home"),
                    codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
                initialTranscripts: [session.id: snapshot],
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
                preferences: defaults,
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
            self.model = model
            test.addTeardownBlock { await model.shutdown() }
        }
    }

    /// A not-loaded thread as `thread/read` with `includeTurns` gives it: two finished turns with
    /// their commands, a file change, reasoning and answers.
    static var savedThread: JSONValue {
        func user(_ id: String, _ text: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("userMessage"),
                     "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
        }
        func command(_ id: String, _ command: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("commandExecution"), "command": .string(command),
                     "cwd": .string("/tmp/qa"), "status": .string("completed"), "exitCode": .integer(0),
                     "durationMs": .integer(1_200), "aggregatedOutput": .string("Test Suite passed"),
                     "commandActions": .array([]), "processId": .null, "source": .string("agent")])
        }
        func answer(_ id: String, _ text: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text),
                     "phase": .string("final_answer")])
        }
        func turn(_ id: String, _ items: [JSONValue]) -> JSONValue {
            .object(["id": .string(id), "status": .string("completed"), "durationMs": .integer(12_000),
                     "startedAt": .integer(1_700_000_000), "completedAt": .integer(1_700_000_012),
                     "itemsView": .string("full"), "error": .null, "items": .array(items)])
        }
        return .object([
            "id": .string(threadID), "status": .object(["type": .string("notLoaded")]),
            "historyMode": .string("paginated"), "cwd": .string("/tmp/qa"), "preview": .string("Fix the flaky test"),
            "turns": .array([
                turn("turn-1", [
                    user("user-1", "Fix the flaky test"),
                    .object(["id": .string("reasoning-1"), "type": .string("reasoning"),
                             "summary": .array([.string("Reading the failing test")]), "content": .array([])]),
                    command("command-1", "swift test --filter FlakyTests"),
                    .object(["id": .string("change-1"), "type": .string("fileChange"), "status": .string("completed"),
                             "changes": .array([.object(["path": .string("/tmp/qa/Tests/FlakyTests.swift"),
                                                         "kind": .object(["type": .string("update")]),
                                                         "diff": .string("@@ -1 +1 @@\n-sleep(1)\n+await settle()\n")])])]),
                    answer("answer-1", "The test waits for the run loop now.")
                ]),
                turn("turn-2", [
                    user("user-2", "Run it again"),
                    command("command-2", "swift test --filter FlakyTests"),
                    answer("answer-2", "All tests pass now.")
                ])
            ])
        ])
    }

    private static func kinds(in turn: ConversationTurn) -> [String] {
        turn.work.compactMap { item in
            switch item.kind {
            case .command: "command"
            case .fileChange: "fileChange"
            default: nil
            }
        }
    }

    private static func kinds(in presentation: ConversationPresentation) -> [String] {
        presentation.turns.flatMap(kinds(in:))
    }

    private static func snapshotPresentation(_ entries: [TranscriptEntry]) -> ConversationPresentation {
        TranscriptConversationProjection.presentation(from: entries, harness: .codex, status: .completed,
                                                 latestTurnIsComplete: true)
    }

    /// Presses the first accessibility element labelled `label`, as an assistive app would.
    private static func press(_ label: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false),
                            with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)?.accessibilityPerformPress?() ?? false
    }

    /// The conversation's scroll view: the tallest one.
    private static func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }
}
