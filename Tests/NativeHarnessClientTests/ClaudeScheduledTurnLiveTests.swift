import Foundation
import XCTest
@testable import NativeHarnessClient

/// A turn Claude Code starts itself while Yardlet runs the task, on the product route. The frames are
/// the ones CLI 2.1.299 sent when a one-shot `CronCreate` fired (`yardlet-sandbox`, 2026-10-22):
/// `command_lifecycle` `started` under the uuid it saves the prompt under, `system/init`, the answer,
/// `result`, then `completed`; no `user` frame, and the saved record on disk only after `started`
/// (the CLI writes its transcript every 100 ms). A background task's notice, which it queues under no
/// uuid, comes with no lifecycle frame at all (2026-10-24). The fake transport speaks those frames and
/// the test writes the record as the CLI does; no model is asked anything.
@MainActor final class ClaudeScheduledTurnLiveTests: XCTestCase {
    func testAPromptTheCLIQueuedItselfOpensItsOwnTurnAndReadsAsItsRecordSays() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await transport.emit(try json(assistantText("Handled both files and filed them.")))
        await transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }

        // A check-in fires: the turn opens at once, before the CLI has written its prompt.
        let checkIn = UUID().uuidString.lowercased()
        await transport.emit(try json(lifecycle(checkIn, "started")))
        await transport.emit(try json(initFrame))
        try await waitUntil { self.lines(model, task).last == "pending: " }
        try await waitUntil { model.store.sessions.first?.status == .running }
        XCTAssertEqual(answers(model, task), [["Handled both files and filed them."], []],
                       "the report before the check-in stays its turn's answer")
        try save([
            #"{"type":"user","uuid":"\#(checkIn)","parentUuid":null,"sessionId":"\#(fixture.providerID)","timestamp":"2026-10-22T14:36:00.730Z","promptId":"p2","isMeta":true,"promptSource":"system","turnOrigin":"scheduled","turnPosition":{"promptIndex":0,"turnIndex":2},"queueSkipAttachments":true,"message":{"role":"user","content":"[Inbox check] Look for new messages and handle them."}}"#
        ], in: fixture)
        await transport.emit(try json(assistantText("No new messages.")))
        await transport.emit(try json(result))
        await transport.emit(try json(lifecycle(checkIn, "completed")))
        try await waitUntil { self.lines(model, task).contains("scheduled: [Inbox check] Look for new messages and handle them.") }
        try await waitUntil { model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), [
            "user: Some files came in by message.", "assistant: Handled both files and filed them.",
            "scheduled: [Inbox check] Look for new messages and handle them.", "assistant: No new messages."
        ])
        XCTAssertEqual(answers(model, task), [["Handled both files and filed them."], ["No new messages."]])
        let turns = presentation(model, task).turns
        guard case let .scheduledTaskMessage(message) = turns[1].prompt.first?.kind else {
            return XCTFail("the check-in is drawn as the schedule's, not the person's")
        }
        XCTAssertEqual(message.claudeSchedule, .checkIn)
        XCTAssertNil(turns[1].actions.editLatest)
        XCTAssertNil(turns[1].actions.restoreFiles)
        XCTAssertEqual(turns[0].actions.restoreFiles?.text, "Some files came in by message.")

        // A background subagent starts a command of its own after Claude answered: a row of the line
        // above the composer, which leaves that answer its turn's answer.
        await transport.emit(try json(subagentTaskStarted))
        try await waitUntil {
            (model.transcriptBySessionID[task.id] ?? []).contains {
                if case let .activity(activity, _) = $0.content { activity.subtask?.isSubagentWork == true } else { false }
            }
        }
        XCTAssertEqual(answers(model, task).last, ["No new messages."])

        // A background task's notice reads as the saved conversation reads it. 2.1.299 queues it under
        // no uuid: no `command_lifecycle` and no `user` frame, only `system/task_notification`,
        // `system/init` and the answer (`yardlet-sandbox`, 2026-10-24). The CLI writes the notice as the
        // turn starts, before it asks the model.
        await transport.emit(try json(taskNotification))
        await transport.emit(try json(initFrame))
        try save([
            #"{"type":"user","uuid":"\#(UUID().uuidString.lowercased())","parentUuid":null,"sessionId":"\#(fixture.providerID)","timestamp":"2026-10-22T14:40:00.000Z","origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","turnOrigin":"task_notification","message":{"role":"user","content":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"Sync the inbox\" completed</summary>\n</task-notification>"}}"#
        ], in: fixture)
        await transport.emit(try json(assistantText("The inbox is synced.")))
        await transport.emit(try json(result))
        try await waitUntil { self.presentation(model, task).turns.last?.prompt.first?.backgroundTaskNotice != nil }
        XCTAssertEqual(presentation(model, task).turns.last?.prompt.first?.backgroundTaskNotice?.summary,
                       "Background command \"Sync the inbox\" completed")
        XCTAssertEqual(answers(model, task), [["Handled both files and filed them."], ["No new messages."],
                                              ["The inbox is synced."]],
                       "the answer to the notice is its own turn's, and the one before keeps its answer")

        // Only `started` opens a turn; another state of a command the CLI queued itself changes nothing.
        let sentBefore = lines(model, task).count
        await transport.emit(try json(lifecycle(UUID().uuidString.lowercased(), "completed")))
        XCTAssertEqual(lines(model, task).count, sentBefore, "only `started` opens a turn")
    }

    /// A command the CLI takes into the turn that is running is no turn of its own.
    func testACommandTheCLIReadsIntoTheRunningTurnOpensNoTurn() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await transport.emit(try json(lifecycle(UUID().uuidString.lowercased(), "started")))
        await transport.emit(try json(assistantText("Still on the first request.")))
        await transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), ["user: Some files came in by message.", "assistant: Still on the first request."])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let transport: FakeClaudeTransport
        let providerID: String
        let transcript: URL
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        func make() -> FakeClaudeTransport {
            let transport = FakeClaudeTransport()
            lock.withLock { transports.append(transport) }
            return transport
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
    }

    /// A Claude task on its account's own config folder, its first request running.
    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-scheduled-\(UUID().uuidString)")
        let config = root.appending(path: "config"), project = root.appending(path: "project")
        let folder = config.appending(path: "projects/project")
        for directory in [project, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.299 (Claude Code)'; exit 0; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("ClaudeScheduledTurns")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let account = ProviderConnection(id: "claude-scheduled", name: "qa@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: config.path, credentialSelector: nil)
        let saved = SessionRecord(harness: .claudeCode, workspaceURL: project, runtimeExecutableURL: cli,
            title: "Inbox", status: .ready, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providerSessionID: UUID().uuidString.lowercased(), connection: account)
        let transports = TransportLog()
        let model = AppModel(
            store: SessionStore(sessions: [saved], repository: InMemorySessionRepository(sessions: [saved])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let task = saved
        await model.send(HarnessUserInput(text: "Some files came in by message."), to: task)
        let transport = try XCTUnwrap(transports.all.first, model.errorBySessionID.values.first ?? "Not attached")
        try await waitUntil {
            model.eventsBySessionID[task.id]?.contains { $0.payload == .sessionStatusChanged(.running) } == true
                && model.store.sessions.first?.status == .running
        }
        let session = try XCTUnwrap(model.store.sessions.first)
        let providerID = try XCTUnwrap(session.providerSessionID)
        return Fixture(model: model, task: session, transport: transport, providerID: providerID,
                       transcript: folder.appending(path: "\(providerID).jsonl"))
    }

    /// Appends records to the task's saved transcript, as the CLI writes them after the frame.
    private func save(_ records: [String], in fixture: Fixture) throws {
        let data = Data((records.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fixture.transcript) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fixture.transcript)
        }
    }

    private func lines(_ model: AppModel, _ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            switch entry.content {
            case let .user(text, _):
                switch entry.origin {
                case .scheduled: "scheduled: \(text)"
                case .provider: "pending: \(text)"
                case nil: ClaudeTaskNotification.parse(text).map { "notice: \($0.summary)" } ?? "user: \(text)"
                }
            case let .assistant(text, _): "assistant: \(text)"
            default: nil
            }
        }
    }

    private func presentation(_ model: AppModel, _ task: SessionRecord) -> ConversationPresentation {
        TranscriptConversationProjection.presentation(
            from: model.transcriptBySessionID[task.id] ?? [], harness: .claudeCode,
            status: model.store.sessions.first?.status ?? .ready, latestTurnIsComplete: true)
    }

    private func answers(_ model: AppModel, _ task: SessionRecord) -> [[String]] {
        presentation(model, task).turns.map { turn in
            turn.answers.compactMap { if case let .answer(text, _) = $0.kind { text } else { nil } }
        }
    }

    private func lifecycle(_ id: String, _ state: String) -> String {
        #"{"type":"command_lifecycle","command_uuid":"\#(id)","state":"\#(state)","uuid":"\#(UUID().uuidString)","session_id":"s"}"#
    }

    /// A command a background subagent started itself, as 2.1.299 reports it on the main stream.
    private var subagentTaskStarted: String {
        #"{"type":"system","subtype":"task_started","task_id":"bsub1","tool_use_id":"toolu_sub1","description":"Run the quick test suite once","task_type":"local_bash","is_backgrounded":true,"owned_by_subagent":true,"session_id":"s","uuid":"\#(UUID().uuidString)"}"#
    }

    private var taskNotification: String {
        #"{"type":"system","subtype":"task_notification","task_id":"b1","tool_use_id":"toolu_b1","status":"completed","output_file":"","summary":"Background command \"Sync the inbox\" completed","session_id":"s","uuid":"\#(UUID().uuidString)"}"#
    }

    private var initFrame: String {
        #"{"type":"system","subtype":"init","session_id":"s","uuid":"\#(UUID().uuidString)","model":"claude-haiku","permissionMode":"default"}"#
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","parent_tool_use_id":null,"session_id":"s","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private var result: String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
