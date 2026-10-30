import Darwin
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What a Claude Code task streaming tool calls costs the window around its conversation, counted
/// as body evaluations of the window, its sidebar rows and the composer (`ViewBodyCensus`) in the
/// real window drawn in an unshown window. The fake CLI speaks Claude Code's stream-json as it
/// streams a turn that calls tools: each API call's partial-message events, the finished blocks, the
/// plan-limit report after each call, the tool results, and a background agent's progress. No model
/// is asked anything.
///
/// Before (2026-10-22, 12 tasks, 12 tool calls): every sidebar row was drawn again whenever the
/// window was (24), the composer once per published fragment (52), and each resource sample drew
/// every row (120 for 10 samples).
@MainActor
final class StreamingWindowRedrawTests: XCTestCase {
    func testAStreamingTaskRedrawsItsConversationAndNotTheWindowAroundIt() async throws {
        let window = try await makeWindow(tasks: 12)
        defer { window.close() }
        let model = window.model, shown = window.tasks[0], other = window.tasks[5]
        let transport = try XCTUnwrap(window.fixture.transport(shown.id))

        // Streaming: the shown task calls twelve tools, one of them a background agent.
        let streaming = await window.measure("12 tool calls") {
            await ClaudeToolCallStream(emit: { await transport.emit($0) },
                                       pause: { window.host.settle(passes: 1, interval: 0.004) }).run(calls: 12)
        }
        XCTAssertGreaterThan(model.transcriptBySessionID[shown.id]?.count ?? 0, 12, "The fixture streamed the shown task")
        // The task's own status reports may redraw the window; its fragments may not.
        XCTAssertLessThanOrEqual(streaming[.mainWindow], 2, "Streaming redrew the window")
        XCTAssertLessThanOrEqual(streaming[.sidebarRow], 2, "Streaming redrew sidebar rows that show nothing new")
        XCTAssertLessThanOrEqual(streaming[.composer], 4, "The composer was drawn again for streamed fragments")

        // Another task changes: the window lists it anew, and only its row is drawn again.
        let unread = await window.measure("another task marked unread") {
            await model.store.markUnread(id: other.id)
        }
        XCTAssertGreaterThanOrEqual(unread[.mainWindow], 1, "The window lists the change")
        XCTAssertLessThanOrEqual(unread[.sidebarRow], 2, "Rows that did not change were drawn again")

        // The resource monitor's samples: the streaming task's CPU changes, the others stay idle.
        let samples = await window.measure("10 resource samples") {
            for sample in 0..<10 {
                model.resourceMonitor.apply([TaskResourceUsage(
                    owner: .task(shown.id), locations: [.yardlet], processCount: 2, memoryBytes: 1 << 26,
                    cpuPercent: Double(40 + sample * 7), isBusy: true)])
                window.host.settle(passes: 1, interval: 0.02)
            }
        }
        XCTAssertLessThanOrEqual(samples[.sidebarRow], 11, "A sample redrew rows whose CPU did not change")
        XCTAssertEqual(samples[.mainWindow], 0)

        // UserDefaults writes of state the window does not show, as saving app state makes them.
        let writes = await window.measure("10 unrelated UserDefaults writes") {
            for index in 0..<10 {
                UserDefaults.yardlet.set(index, forKey: "StreamingWindowRedraw.unrelated")
                window.host.settle(passes: 1, interval: 0.02)
            }
            UserDefaults.yardlet.removeObject(forKey: "StreamingWindowRedraw.unrelated")
        }
        XCTAssertEqual(writes[.mainWindow], 0)
        XCTAssertEqual(writes[.sidebarRow], 0)
    }

    /// A sidebar of forty tasks with nothing running: a task's CPU sample or unread mark redraws its
    /// own row, not every row on screen.
    func testASidebarRowIsDrawnAgainOnlyForItsOwnChange() async throws {
        let fixture = try await makeFixture(tasks: 40)
        let model = fixture.model
        model.splits.activate(.session(fixture.tasks[0].id))
        let window = Window(fixture: fixture, height: 1_200)
        defer { window.close() }
        window.host.settle(passes: 20)
        let samples = await window.measure("20 resource samples of one task") {
            for sample in 0..<20 {
                model.resourceMonitor.apply([TaskResourceUsage(
                    owner: .task(fixture.tasks[39].id), locations: [.yardlet], processCount: 2, memoryBytes: 1 << 26,
                    cpuPercent: Double(40 + sample * 7), isBusy: true)])
                window.host.settle(passes: 1, interval: 0.005)
            }
        }
        let unread = await window.measure("10 tasks marked unread in turn") {
            for task in fixture.tasks[30...39] {
                await model.store.markUnread(id: task.id)
                window.host.settle(passes: 1, interval: 0.005)
            }
        }
        XCTAssertLessThanOrEqual(samples[.sidebarRow], 21)
        XCTAssertLessThanOrEqual(unread[.sidebarRow], 12)
    }

    /// The composer, its bash-mode actions and its connectors are made afresh each time the task's
    /// conversation publishes; made again for the same task they are equal, and a change in what
    /// they show makes them unequal.
    func testWhatTheTaskSurfaceMakesAgainForTheSameTaskIsEqual() {
        let draft = TaskComposerDraft()
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/equal"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Equal")
        func composer(isRunning: Bool = true, entries: [TranscriptEntry] = []) -> PromptComposer {
            PromptComposer(harness: .claudeCode, composerDraft: draft, providerSession: session, providerEntries: entries,
                           isRunning: isRunning, actions: ComposerActions(send: { _ in }, submitFollowUp: { _, _ in }))
        }
        XCTAssertEqual(composer(), composer(), "Fresh actions for the same task")
        XCTAssertNotEqual(composer(), composer(isRunning: false))
        XCTAssertNotEqual(composer(), PromptComposer(harness: .claudeCode, composerDraft: draft, providerSession: session,
                                                     isRunning: true, actions: ComposerActions(send: { _ in })),
                          "An action the composer offers went away")
        XCTAssertNotEqual(composer(), PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(),
                                                     providerSession: session, isRunning: true,
                                                     actions: ComposerActions(send: { _ in }, submitFollowUp: { _, _ in })))
        var renamed = session
        renamed.title = "Renamed"
        func shell(_ task: SessionRecord, running: Bool = false) -> ClaudeShellCommandActions {
            ClaudeShellCommandActions(isRunning: running, run: { _ in }, stop: {}, runForEntry: { _ in nil }, task: task)
        }
        XCTAssertEqual(shell(session), shell(session))
        XCTAssertNotEqual(shell(session), shell(session, running: true))
        XCTAssertNotEqual(shell(session), shell(renamed))
        let scope = ConnectorTaskScope(harness: .claudeCode)
        func connectors(_ id: UUID) -> ComposerConnectorEnvironment {
            ComposerConnectorEnvironment(records: [], taskState: { _ in .on }, setOn: { _, _ in }, openSettings: {},
                                         target: .init(center: nil, taskID: id, scope: scope))
        }
        XCTAssertEqual(connectors(session.id), connectors(session.id))
        XCTAssertNotEqual(connectors(session.id), connectors(UUID()))
    }


    /// A long answer streamed for two seconds, as a model writes one: the conversation is published
    /// on the publication cadence (`AppModel.scheduleTranscriptPublication`), not once per fragment.
    /// Each publication lays the whole window out again, in the window's display cycle.
    ///
    /// The cadence is a time, so the publications are counted against the time the fragments took:
    /// on a Mac 200 fragments take about two seconds, on CI, where each pause lays the window out
    /// again, several.
    func testALongAnswerIsPublishedOnTheCadenceNotPerFragment() async throws {
        let window = try await makeWindow(tasks: 12)
        defer { window.close() }
        let model = window.model, shown = window.tasks[0]
        let transport = try XCTUnwrap(window.fixture.transport(shown.id))
        let fragments = 200
        let clock = ContinuousClock()
        /// At most one publication per interval of `elapsed`, and `extra` besides.
        func cadence(over elapsed: Duration, extra: Int) -> Int {
            Int((elapsed / AppModel.transcriptPublicationInterval).rounded(.up)) + extra
        }
        let published = model.publicationCounts.transcripts
        var text = ""
        let streamStart = clock.now
        let streaming = await window.measure("\(fragments) answer fragments 10 ms apart") {
            text = await ClaudeAnswerStream(emit: { await transport.emit($0) },
                                            pause: { window.host.settle(passes: 1, interval: 0.01) }).run(fragments: fragments)
        }
        let streamTime = clock.now - streamStart
        let publications = model.publicationCounts.transcripts - published
        print("[redraw] \(fragments) answer fragments in \(streamTime): \(publications) publications")
        let answers = (model.transcriptBySessionID[shown.id] ?? []).compactMap { entry -> String? in
            if case let .assistant(text, _) = entry.content { return text }
            return nil
        }
        XCTAssertTrue(answers.contains(text), "The whole answer arrived")
        XCTAssertLessThanOrEqual(streaming[.mainWindow], 2, "Streaming redrew the window")
        // The count tells the cadence from one publication per fragment only while the fragments came
        // faster than the cadence.
        XCTAssertLessThan(cadence(over: streamTime, extra: 0), fragments / 2, "The fragments came too slowly to tell")
        // Ten publications a second for the fragments, and the finished message's frames.
        XCTAssertLessThanOrEqual(publications, cadence(over: streamTime, extra: 8),
                                 "Fragments were published faster than the cadence")

        // A background agent reports its progress as often, and is published at the same cadence.
        let reports = 200
        let beforeReports = model.publicationCounts.transcripts
        let reportStart = clock.now
        await transport.emit(json(["type": "system", "subtype": "task_started", "task_id": "task-agent",
                                   "tool_use_id": "toolu_agent", "description": "Survey the sources",
                                   "task_type": "local_agent", "prompt": "Look around", "session_id": "s"]))
        for report in 1...reports {
            await transport.emit(json(["type": "system", "subtype": "task_progress", "task_id": "task-agent",
                                       "tool_use_id": "toolu_agent", "description": "Survey the sources",
                                       "last_tool_name": "Read", "session_id": "s",
                                       "usage": ["tool_uses": report, "total_tokens": report * 100, "duration_ms": report * 10]]))
            window.host.settle(passes: 1, interval: 0.01)
        }
        window.host.settle(passes: 20, interval: 0.01)
        let reportTime = clock.now - reportStart
        let reportPublications = model.publicationCounts.transcripts - beforeReports
        print("[redraw] \(reports) progress reports in \(reportTime): \(reportPublications) publications")
        XCTAssertLessThan(cadence(over: reportTime, extra: 0), reports / 2, "The reports came too slowly to tell")
        XCTAssertLessThanOrEqual(reportPublications, cadence(over: reportTime, extra: 8),
                                 "Progress was published faster than the cadence")
    }

    // MARK: - Window

    @MainActor
    private final class Window {
        let fixture: Fixture
        let host: WindowlessRender.Host<AnyView>
        var model: AppModel { fixture.model }
        var tasks: [SessionRecord] { fixture.tasks }

        init(fixture: Fixture, height: CGFloat = 820) {
            self.fixture = fixture
            host = WindowlessRender.Host(AnyView(SceneRoot(model: fixture.model)), size: NSSize(width: 1_280, height: height))
            ViewBodyCensus.isEnabled = true
        }

        /// The body evaluations `work` caused, and the main thread's time for it, printed.
        func measure(_ name: String, _ work: () async -> Void) async -> Counts {
            host.settle(passes: 6, interval: 0.01)
            ViewBodyCensus.reset()
            let start = MainThreadClock.now()
            await work()
            host.settle(passes: 20, interval: 0.01)
            let counts = Counts(values: ViewBodyCensus.counts)
            print("[redraw] \(name): window \(counts[.mainWindow]), rows \(counts[.sidebarRow]), "
                  + "composer \(counts[.composer]), main thread \(MainThreadClock.since(start))")
            return counts
        }

        func close() {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
            host.close()
        }
    }

    struct Counts {
        let values: [ViewBodyCensus.Body: Int]
        subscript(body: ViewBodyCensus.Body) -> Int { values[body] ?? 0 }
    }

    private func makeWindow(tasks count: Int) async throws -> Window {
        let fixture = try await makeFixture(tasks: count)
        let model = fixture.model, shown = fixture.tasks[0]
        model.splits.activate(.session(shown.id))
        let window = Window(fixture: fixture)
        window.host.settle(passes: 20)
        await model.send(HarnessUserInput(text: "Start"), to: shown)
        try await waitUntil { model.store.sessions.first { $0.id == shown.id }?.status == .running }
        window.host.settle(passes: 20)
        return window
    }

    // MARK: - Fixture

    struct Fixture {
        let model: AppModel
        let tasks: [SessionRecord]
        let book: TransportBook
        func transport(_ id: UUID) -> FakeClaudeTransport? { book.transport(for: id) }
    }

    final class TransportBook: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [UUID: FakeClaudeTransport] = [:]
        func make(for id: UUID) -> FakeClaudeTransport {
            let transport = FakeClaudeTransport()
            lock.withLock { transports[id] = transport }
            return transport
        }
        func transport(for id: UUID) -> FakeClaudeTransport? { lock.withLock { transports[id] } }
    }

    private func makeFixture(tasks count: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-redraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi\n".utf8)
            .write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("StreamingWindowRedraw")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let book = TransportBook()
        // The signed-in Claude account the app has read, whose plan usage each plan-limit report updates.
        let connections = ProviderConnectionStore()
        connections.publishDefaults([HarnessAccountSnapshot(
            id: "claude:qa", harness: .claudeCode, providerID: "anthropic", state: .signedIn, accountLabel: "qa@example.test",
            detail: "", credentialOwner: "Claude Code", checkedAt: Date(),
            usage: [AccountUsageMetric(id: "claude:session:", label: "5 hour limit", usedFraction: 0.1, detail: "",
                                       resetsAt: Date(timeIntervalSince1970: 1_900_000_000), evidence: .exactQuota)],
            canLogin: false, canLogout: false)])
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { book.make(for: $0) }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            connections: connections,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        var tasks: [SessionRecord] = []
        for index in 0..<count {
            let folder = root.appending(path: "project-\(index % 4)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(harness: .claudeCode, workspaceURL: folder,
                                                    runtimeExecutableURL: cli, title: "Task \(index)")
            tasks.append(try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Task did not start"))
        }
        return Fixture(model: model, tasks: tasks, book: book)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}

/// The main window as `NativeHarnessClientApp`'s window group shows it: the appearance and size
/// preferences read from UserDefaults around it, and the app-wide update actions it hands down.
private struct SceneRoot: View {
    let model: AppModel
    @AppStorage(YardletPreferenceKeys.appearance) private var appearanceRawValue =
        YardletAppearancePreference.system.rawValue
    @AppStorage(YardletPreferenceKeys.interfaceSize) private var interfaceSizeRawValue =
        YardletInterfaceSizePreference.standard.rawValue
    private let updateWait = YardletUpdateWait()

    var body: some View {
        MainWindow(model: model)
            .environment(\.yardletInterfaceScale, 1)
            .environment(\.yardletInstallUpdate, { [updateWait] in _ = updateWait })
            .environment(\.yardletUpdateWait, updateWait)
    }
}

/// The main thread's CPU time.
private enum MainThreadClock {
    static func now() -> Int64 {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return Int64(info.user_time.seconds + info.system_time.seconds) * 1_000_000
            + Int64(info.user_time.microseconds + info.system_time.microseconds)
    }

    static func since(_ start: Int64) -> Duration { .microseconds(now() - start) }
}

/// Claude Code's stream-json for a turn that calls tools, as `--include-partial-messages` streams
/// it: for each API call, `message_start`, a text block and a tool-use block with their deltas, the
/// finished blocks as `assistant` frames, `message_delta`/`message_stop`, the plan-limit report,
/// then the tool's result. The third call starts a background agent whose progress and nested
/// frames arrive while the main turn goes on.
@MainActor
struct ClaudeToolCallStream {
    let emit: @Sendable (JSONValue) async -> Void
    /// Between fragments, as the CLI streams them a few milliseconds apart.
    var pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(4)) }

    func run(calls: Int) async {
        for call in 0..<calls {
            await emit(event(["type": "message_start", "message": [
                "id": "msg_\(call)", "type": "message", "role": "assistant", "model": "claude-fable-5",
                "content": [Any](), "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000 + call * 900,
                                              "output_tokens": 1]]]))
            await emit(event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
            var text = ""
            for word in 0..<12 {
                let fragment = "word\(call)-\(word) "
                text += fragment
                await emit(event(["type": "content_block_delta", "index": 0,
                                  "delta": ["type": "text_delta", "text": fragment]]))
                await pause()
            }
            await emit(event(["type": "content_block_stop", "index": 0]))
            await emit(assistant(call: call, [["type": "text", "text": text]]))
            let toolID = "toolu_\(call)"
            let isAgent = call == 2
            let name = isAgent ? "Agent" : (call.isMultiple(of: 3) ? "Read" : "Bash")
            let input: [String: Any] = isAgent
                ? ["description": "Survey the sources", "prompt": "Look around", "subagent_type": "general-purpose",
                   "run_in_background": true]
                : name == "Read" ? ["file_path": "/tmp/project/Sources/File\(call).swift"]
                : ["command": "rg -n thing Sources/\(call)", "description": "Search the sources"]
            await emit(event(["type": "content_block_start", "index": 1, "content_block": [
                "type": "tool_use", "id": toolID, "name": name, "input": [String: Any]()]]))
            for part in 0..<6 {
                await emit(event(["type": "content_block_delta", "index": 1,
                                  "delta": ["type": "input_json_delta", "partial_json": "{\"p\(part)\":"]]))
                await pause()
            }
            await emit(event(["type": "content_block_stop", "index": 1]))
            await emit(assistant(call: call, [["type": "tool_use", "id": toolID, "name": name, "input": input]]))
            await emit(event(["type": "message_delta", "delta": ["stop_reason": "tool_use", "stop_sequence": NSNull()],
                              "usage": ["output_tokens": 80 + call]]))
            await emit(event(["type": "message_stop"]))
            await emit(json(["type": "rate_limit_event", "session_id": "s", "rate_limit_info": [
                "status": "allowed", "resetsAt": 1_900_000_000, "rateLimitType": "five_hour",
                "utilization": 0.2 + Double(call) / 100, "isUsingOverage": false]]))
            if isAgent {
                await emit(json(["type": "system", "subtype": "task_started", "task_id": "task-agent", "tool_use_id": toolID,
                                 "description": "Survey the sources", "task_type": "local_agent", "prompt": "Look around",
                                 "session_id": "s"]))
                await emit(json(["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": toolID,
                     "content": "Async agent launched successfully. agentId: a1"]]]]))
            } else {
                await emit(json(["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": toolID, "content": "Sources/A.swift:\(call): thing"]]]]))
            }
            if call > 2 {
                // The background agent works while the main turn goes on.
                await emit(json(["type": "assistant", "parent_tool_use_id": "toolu_2", "session_id": "s",
                                 "message": ["role": "assistant", "content": [
                                    ["type": "tool_use", "id": "child-\(call)", "name": "Read",
                                     "input": ["file_path": "/tmp/project/Sources/Child\(call).swift"]]]]]))
                await emit(json(["type": "system", "subtype": "task_progress", "task_id": "task-agent",
                                 "tool_use_id": "toolu_2", "description": "Survey the sources", "last_tool_name": "Read",
                                 "session_id": "s",
                                 "usage": ["tool_uses": call, "total_tokens": call * 1_000, "duration_ms": call * 700]]))
            }
        }
    }

    private func event(_ event: [String: Any]) -> JSONValue {
        json(["type": "stream_event", "session_id": "s", "event": event])
    }

    private func assistant(call: Int, _ content: [[String: Any]]) -> JSONValue {
        json(["type": "assistant", "session_id": "s", "message": [
            "id": "msg_\(call)", "type": "message", "role": "assistant", "model": "claude-fable-5", "content": content,
            "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000 + call * 900, "output_tokens": 80 + call]]])
    }
}

/// Claude Code's stream-json for a turn that answers in text alone: `message_start`, the text block
/// and its deltas, the finished block as an `assistant` frame, `message_delta`/`message_stop`.
@MainActor
struct ClaudeAnswerStream {
    let emit: @Sendable (JSONValue) async -> Void
    var pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }

    /// Streams `fragments` words and returns the whole answer.
    func run(fragments: Int) async -> String {
        await emit(event(["type": "message_start", "message": [
            "id": "msg_answer", "type": "message", "role": "assistant", "model": "claude-fable-5",
            "content": [Any](), "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000, "output_tokens": 1]]]))
        await emit(event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
        var text = ""
        for index in 0..<fragments {
            let fragment = "word\(index) "
            text += fragment
            await emit(event(["type": "content_block_delta", "index": 0,
                              "delta": ["type": "text_delta", "text": fragment]]))
            await pause()
        }
        await emit(event(["type": "content_block_stop", "index": 0]))
        await emit(json(["type": "assistant", "session_id": "s", "message": [
            "id": "msg_answer", "type": "message", "role": "assistant", "model": "claude-fable-5",
            "content": [["type": "text", "text": text]],
            "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000, "output_tokens": fragments]]]))
        await emit(event(["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                          "usage": ["output_tokens": fragments]]))
        await emit(event(["type": "message_stop"]))
        return text
    }

    private func event(_ event: [String: Any]) -> JSONValue {
        json(["type": "stream_event", "session_id": "s", "event": event])
    }
}

private func json(_ object: [String: Any]) -> JSONValue {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
}
