import Darwin
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Ten tasks streaming at once through the product adapters, the way the person runs six Claude
/// Code tasks with subagents and four Codex tasks while reading one of them. The CLIs are fake
/// transports speaking their stream shapes; no model is asked anything.
///
/// `testTenStreamingTasksLeaveTheShownTaskAndTheMainActorAlone` runs with every `swift test`
/// for a few seconds and holds generous bounds. The full benchmark runs only with
/// `NHC_PERF_BENCH=1` (`NHC_PERF_BENCH_SECONDS`, default 180) and prints `[perf]` lines.
@MainActor
final class ConcurrentStreamingPerformanceTests: XCTestCase {
    func testBenchmarkTenConcurrentStreamingTasks() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to run the benchmark")
        let seconds = environment["NHC_PERF_BENCH_SECONDS"].flatMap(Double.init) ?? 180
        let scenario = try await StreamingScenario.make(claude: 6, codex: 4, testCase: self)
        let report = try await scenario.run(
            measuring: .seconds(seconds),
            warmUp: .seconds(5),
            rates: .heavy,
            streamsShownTask: true
        )
        report.print(label: environment["NHC_PERF_BENCH_LABEL"] ?? "benchmark")
        XCTAssertTrue(report.lostText.isEmpty, "Lost streamed text: \(report.lostText)")
    }

    /// The shown task sits idle while nine others stream. Its view must not be invalidated by
    /// their output, nothing the stream causes may write the disk on the main thread for every
    /// fragment, and the main actor must keep most of its time.
    func testTenStreamingTasksLeaveTheShownTaskAndTheMainActorAlone() async throws {
        let scenario = try await StreamingScenario.make(claude: 6, codex: 4, testCase: self)
        let report = try await scenario.run(
            measuring: .seconds(3),
            warmUp: .seconds(1),
            rates: .heavy,
            streamsShownTask: false
        )
        report.print(label: "regression")
        XCTAssertTrue(report.lostText.isEmpty, "Lost streamed text: \(report.lostText)")
        XCTAssertGreaterThan(report.framesPerSecond, 100, "The fixture must actually stream")
        // Generous bounds: an idle shown task re-renders only for the sidebar's status changes,
        // and background fragments are not each a disk write on the main thread.
        XCTAssertLessThan(report.shownTaskViewEvaluationsPerSecond, 8)
        XCTAssertLessThan(report.mainThreadSnapshotWritesPerSecond, 20)
        XCTAssertLessThan(report.mainBusyFraction, 0.8)
    }
}

// MARK: - Scenario

private struct StreamRates: Sendable {
    var textPerSecond: Double
    var thinkingPerSecond: Double
    var subagentFramesPerSecond: Double
    var subagentProgressPerSecond: Double
    var commandOutputPerSecond: Double

    static let heavy = StreamRates(
        textPerSecond: 30,
        thinkingPerSecond: 30,
        subagentFramesPerSecond: 20,
        subagentProgressPerSecond: 2,
        commandOutputPerSecond: 40
    )
}

@MainActor
private final class StreamingScenario {
    let model: AppModel
    let root: URL
    let claudeTasks: [(task: SessionRecord, transport: FakeClaudeTransport)]
    let codexTasks: [(task: SessionRecord, threadID: String)]
    let codexTransport: FakeCodexTransport
    let shownTask: SessionRecord
    let probes: PersistenceProbes
    let notifications: CountingNotificationCenter
    let expectations = ExpectedText()

    private init(
        model: AppModel, root: URL,
        claudeTasks: [(task: SessionRecord, transport: FakeClaudeTransport)],
        codexTasks: [(task: SessionRecord, threadID: String)],
        codexTransport: FakeCodexTransport, shownTask: SessionRecord,
        probes: PersistenceProbes, notifications: CountingNotificationCenter
    ) {
        self.model = model
        self.root = root
        self.claudeTasks = claudeTasks
        self.codexTasks = codexTasks
        self.codexTransport = codexTransport
        self.shownTask = shownTask
        self.probes = probes
        self.notifications = notifications
    }

    static func make(claude: Int, codex: Int, testCase: XCTestCase) async throws -> StreamingScenario {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-concurrent-streaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let claudeCLI = root.appending(path: "claude")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi

        """.utf8).write(to: claudeCLI)
        let codexCLI = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: codexCLI)
        for cli in [claudeCLI, codexCLI] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        let suite = testDefaultsSuite("ConcurrentStreaming")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        let probes = PersistenceProbes()
        let sessions = CountingSessionRepository(
            base: try SQLiteSessionRepository(databaseURL: root.appending(path: "session-index.sqlite3")),
            probes: probes
        )
        let transcripts = CountingTranscriptRepository(
            base: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            probes: probes
        )
        let timeline = CountingCodexTimelineItemRepository(
            base: UserDefaultsCodexTimelineItemRepository(defaults: defaults), probes: probes
        )
        let requests = CountingCodexPendingRequestRepository(
            base: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults), probes: probes
        )
        let threadIDs = (0..<codex).map { "thread-\($0)" }
        let codexTransport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": threadIDs.map { id in
                .object(["thread": .object([
                    "id": .string(id), "status": .object(["type": .string("idle")]), "turns": .array([])
                ])])
            }
        ])
        let claudeTransports = ClaudeTransportBook()
        let notifications = CountingNotificationCenter()
        let model = AppModel(
            store: SessionStore(repository: sessions),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { kind, url in
                if kind == .codex {
                    return YHPCodexCompatibilityAdapter(
                        adapter: CodexAdapter(executableURL: url, transport: codexTransport),
                        manifest: HarnessProtocolCompatibilityManifest.codex()
                    )
                }
                return YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { claudeTransports.make(for: $0) }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: requests,
            codexTimelineItemRepository: timeline,
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: transcripts,
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: notifications,
            restoresIndexOnLaunch: false
        )
        testCase.addTeardownBlock { await model.shutdown() }

        var claudeTasks: [(task: SessionRecord, transport: FakeClaudeTransport)] = []
        for index in 0..<claude {
            let folder = root.appending(path: "claude-project-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(
                harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: claudeCLI,
                title: "Claude \(index)"
            )
            let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Claude task did not start")
            let transport = try XCTUnwrap(claudeTransports.transport(for: task.id))
            claudeTasks.append((task, transport))
        }
        var codexTasks: [(task: SessionRecord, threadID: String)] = []
        for index in 0..<codex {
            let folder = root.appending(path: "codex-project-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(
                harness: .codex, workspaceURL: folder, runtimeExecutableURL: codexCLI,
                title: "Codex \(index)"
            )
            let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Codex task did not start")
            codexTasks.append((task, threadIDs[index]))
        }
        let shown = try XCTUnwrap(claudeTasks.first?.task)
        model.store.selectedSessionID = shown.id
        // Every task attached; Codex presentation streams are live.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
              codexTasks.contains(where: { model.codexPresentationBySessionID[$0.task.id]?.thread == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        return StreamingScenario(
            model: model, root: root, claudeTasks: claudeTasks, codexTasks: codexTasks,
            codexTransport: codexTransport, shownTask: shown, probes: probes, notifications: notifications
        )
    }

    // MARK: Run

    func run(
        measuring duration: Duration,
        warmUp: Duration,
        rates: StreamRates,
        streamsShownTask: Bool
    ) async throws -> StreamingReport {
        let model = self.model
        let shownID = shownTask.id
        let windowView = ViewInvalidationModel { [unowned model] in
            Self.readSidebar(model)
            Self.readTaskContent(model, shownID)
        }
        let shownTaskView = ViewInvalidationModel { [unowned model] in Self.readTaskContent(model, shownID) }
        let sidebarView = ViewInvalidationModel { [unowned model] in Self.readSidebar(model) }
        let lag = MainActorLagProbe()
        let frames = FrameCounter()
        let end = ContinuousClock.now + warmUp + duration
        var producers: [Task<Void, Never>] = []
        for (index, entry) in claudeTasks.enumerated() where streamsShownTask || entry.task.id != shownID {
            let driver = ClaudeDriver(
                index: index, task: entry.task, transport: entry.transport, model: model,
                rates: rates, frames: frames, expected: expectations
            )
            producers.append(Task.detached { await driver.run(until: end) })
        }
        for (index, entry) in codexTasks.enumerated() {
            let driver = CodexDriver(
                index: index, task: entry.task, threadID: entry.threadID, transport: codexTransport,
                rates: rates, frames: frames
            )
            producers.append(Task.detached { await driver.run(until: end) })
        }

        try await Task.sleep(for: warmUp)
        lag.start()
        let mainThread = MainThreadClock()
        let start = Sample.take(model: model, probes: probes, frames: frames, views: [windowView, shownTaskView, sidebarView])
        var memory: [(seconds: Double, megabytes: Double)] = [(0, ProcessMemory.footprintMegabytes())]
        let measureStart = ContinuousClock.now
        while ContinuousClock.now < end {
            try await Task.sleep(for: .seconds(min(10, max(0.05, (end - ContinuousClock.now).seconds))))
            memory.append(((ContinuousClock.now - measureStart).seconds, ProcessMemory.footprintMegabytes()))
        }
        let elapsed = (ContinuousClock.now - measureStart).seconds
        let mainBusy = mainThread.elapsedCPUSeconds()
        let finish = Sample.take(model: model, probes: probes, frames: frames, views: [windowView, shownTaskView, sidebarView])
        lag.stop()
        windowView.stop(); shownTaskView.stop(); sidebarView.stop()
        for producer in producers { producer.cancel() }
        for producer in producers { await producer.value }

        // Every fragment that was sent must be in the model once the stream settles.
        let lost = try await settledTextMismatches()
        let delta = finish.minus(start)
        return StreamingReport(
            seconds: elapsed,
            framesPerSecond: Double(delta.frames) / elapsed,
            mainBusyFraction: mainBusy / elapsed,
            processCPUFraction: delta.processCPUSeconds / elapsed,
            lag: lag.summary(),
            windowEvaluationsPerSecond: Double(delta.viewEvaluations[0]) / elapsed,
            shownTaskViewEvaluationsPerSecond: Double(delta.viewEvaluations[1]) / elapsed,
            sidebarEvaluationsPerSecond: Double(delta.viewEvaluations[2]) / elapsed,
            publications: delta.publications,
            persistence: delta.persistence,
            notifications: notifications.posts,
            memory: memory,
            lostText: lost,
            backgroundTasks: claudeTasks.count + codexTasks.count - (streamsShownTask ? 0 : 1)
        )
    }

    /// What `MainWindow` reads for the shown task's surface (`taskContent(for:)`).
    static func readTaskContent(_ model: AppModel, _ id: UUID) {
        _ = model.transcriptBySessionID[id]
        _ = model.errorBySessionID[id]
        _ = model.codexPresentationBySessionID[id]
        _ = model.codexHistorySelectionBySessionID[id]
        _ = model.followUps.queue(for: id)
        _ = model.codexCapabilitiesBySessionID[id]
        _ = model.providerCapabilitiesBySessionID[id]
        _ = model.providerUsageBySessionID[id]
        _ = model.providerRetryBySessionID[id]
        _ = model.rateLimitWarningBySessionID[id]
        _ = model.isAttached(id)
    }

    /// What `MainWindow` reads for the sidebar's rows.
    static func readSidebar(_ model: AppModel) {
        _ = model.store.sessions
        _ = model.splits.selection
        _ = model.isRestoringIndex
    }

    private func settledTextMismatches() async throws -> [String] {
        // Let the last turn's publications and any coalescing window pass.
        try await Task.sleep(for: .seconds(2))
        var mismatches: [String] = []
        for (task, _) in claudeTasks {
            let expected = expectations.texts(for: task.id)
            guard !expected.isEmpty else { continue }
            let shown = (model.transcriptBySessionID[task.id] ?? []).compactMap { entry -> String? in
                if case let .assistant(text, _) = entry.content { return text }
                return nil
            }
            // The transcript keeps its newest entries; compare the newest answers it holds.
            let tail = Array(expected.suffix(shown.count))
            if Array(shown.suffix(tail.count)) != tail {
                mismatches.append("\(task.title): expected \(tail.suffix(2)) got \(shown.suffix(2))")
            }
        }
        return mismatches
    }
}

// MARK: - Drivers

/// Six-phase Claude turns: thinking, an answer, a Bash call, two subagents with progress and their
/// own inner frames, a second answer, and the result.
private struct ClaudeDriver: Sendable {
    let index: Int
    let task: SessionRecord
    let transport: FakeClaudeTransport
    let model: AppModel
    let rates: StreamRates
    let frames: FrameCounter
    let expected: ExpectedText

    func run(until end: ContinuousClock.Instant) async {
        var turn = 0
        while ContinuousClock.now < end, !Task.isCancelled {
            turn += 1
            await model.send(HarnessUserInput(text: "Task \(index) turn \(turn)"), to: task)
            let prefix = "c\(index)t\(turn)"
            await pace(rates.thinkingPerSecond, for: .seconds(2), until: end) { step in
                await emit(streamEvent(["type": "thinking_delta", "thinking": "Considering step \(step) of the plan. "]))
            }
            await answer(prefix: "\(prefix)a", seconds: 3, until: end)
            await emit(assistant([toolUse(id: "\(prefix)-bash", name: "Bash", input: ["command": "swift test --filter Thing"])]))
            try? await Task.sleep(for: .milliseconds(500))
            await emit(toolResult(id: "\(prefix)-bash", output: String(repeating: "Test Case passed (0.001 seconds)\n", count: 60)))
            await subagents(prefix: prefix, seconds: 6, until: end)
            await answer(prefix: "\(prefix)b", seconds: 3, until: end)
            await emit(json([
                "type": "result", "subtype": "success", "is_error": false, "result": "Done.",
                "session_id": "s", "usage": ["input_tokens": 1_000, "output_tokens": 500], "total_cost_usd": 0
            ]))
            // The next turn starts once Claude reported this one finished.
            let settle = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < settle, !Task.isCancelled {
                let running = await MainActor.run {
                    model.store.sessions.first { $0.id == task.id }?.status == .running
                }
                if !running { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func answer(prefix: String, seconds: Double, until end: ContinuousClock.Instant) async {
        var text = ""
        await pace(rates.textPerSecond, for: .seconds(seconds), until: end) { step in
            let fragment = "\(prefix)-\(step) streamed words, "
            text += fragment
            await emit(streamEvent(["type": "text_delta", "text": fragment]))
        }
        guard !text.isEmpty else { return }
        expected.append(text, for: task.id)
        await emit(assistant([["type": "text", "text": text]]))
    }

    private func subagents(prefix: String, seconds: Double, until end: ContinuousClock.Instant) async {
        let agents = ["\(prefix)-agent1", "\(prefix)-agent2"]
        await emit(assistant(agents.map {
            toolUse(id: $0, name: "Agent", input: ["description": "Review \($0)", "prompt": "Review the module", "subagent_type": "general-purpose"])
        }))
        for agent in agents {
            await emit(json([
                "type": "system", "subtype": "task_started", "task_id": "task-\(agent)", "tool_use_id": agent,
                "description": "Review \(agent)", "task_type": "local_agent", "prompt": "Review the module"
            ]))
        }
        let progressEvery = max(1, Int(rates.subagentFramesPerSecond / max(rates.subagentProgressPerSecond, 0.1)))
        await pace(rates.subagentFramesPerSecond, for: .seconds(seconds), until: end) { step in
            let agent = agents[step % agents.count]
            if step % 2 == 0 {
                await emit(json([
                    "type": "assistant", "parent_tool_use_id": agent, "session_id": "s",
                    "message": ["role": "assistant", "content": [
                        ["type": "tool_use", "id": "\(agent)-child-\(step)", "name": "Read", "input": ["file_path": "Sources/File\(step).swift"]]
                    ]]
                ]))
            } else {
                await emit(json([
                    "type": "stream_event", "parent_tool_use_id": agent, "session_id": "s",
                    "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "inner \(step) "]]
                ]))
            }
            if step % progressEvery == 0 {
                for agent in agents {
                    await emit(json([
                        "type": "system", "subtype": "task_progress", "task_id": "task-\(agent)", "tool_use_id": agent,
                        "description": "Review \(agent)", "last_tool_name": "Read",
                        "usage": ["tool_uses": step, "total_tokens": step * 300, "duration_ms": step * 50]
                    ]))
                }
            }
        }
        for agent in agents {
            await emit(json([
                "type": "system", "subtype": "task_notification", "task_id": "task-\(agent)", "tool_use_id": agent,
                "status": "completed", "summary": "Reviewed.", "usage": ["tool_uses": 9, "total_tokens": 9_000, "duration_ms": 6_000]
            ]))
            await emit(json([
                "type": "user",
                "tool_use_result": [
                    "status": "completed", "agentId": "child-\(agent)",
                    "content": [["type": "text", "text": "The module is fine."]],
                    "totalToolUseCount": 9, "totalTokens": 9_000, "totalDurationMs": 6_000
                ],
                "message": ["content": [["type": "tool_result", "tool_use_id": agent, "content": [["type": "text", "text": "The module is fine."]]]]]
            ]))
        }
    }

    private func emit(_ value: JSONValue) async {
        await transport.emit(value)
        frames.add()
    }

    private func streamEvent(_ delta: [String: Any]) -> JSONValue {
        json([
            "type": "stream_event", "session_id": "s",
            "event": ["type": "content_block_delta", "index": 0, "delta": delta]
        ])
    }

    private func assistant(_ blocks: [[String: Any]]) -> JSONValue {
        json([
            "type": "assistant", "session_id": "s",
            "message": ["role": "assistant", "content": blocks]
        ])
    }

    private func toolUse(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private func toolResult(id: String, output: String) -> JSONValue {
        json([
            "type": "user", "session_id": "s",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": output]]]
        ])
    }
}

/// Codex turns: reasoning summary, a streaming command, an answer, another command and answer.
private struct CodexDriver: Sendable {
    let index: Int
    let task: SessionRecord
    let threadID: String
    let transport: FakeCodexTransport
    let rates: StreamRates
    let frames: FrameCounter

    func run(until end: ContinuousClock.Instant) async {
        var turn = 0
        while ContinuousClock.now < end, !Task.isCancelled {
            turn += 1
            let turnID = "x\(index)t\(turn)"
            await emit("turn/started", ["turn": ["id": turnID, "status": "inProgress", "items": [Any]()]])
            await reasoning(turnID: turnID, seconds: 2, until: end)
            await command(turnID: turnID, id: "\(turnID)-cmd1", seconds: 4, until: end)
            await message(turnID: turnID, id: "\(turnID)-msg1", seconds: 4, until: end)
            await command(turnID: turnID, id: "\(turnID)-cmd2", seconds: 2, until: end)
            await message(turnID: turnID, id: "\(turnID)-msg2", seconds: 2, until: end)
            await emit("turn/completed", ["turn": ["id": turnID, "status": "completed", "items": [Any]()]])
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func reasoning(turnID: String, seconds: Double, until end: ContinuousClock.Instant) async {
        let id = "\(turnID)-reasoning"
        await emit("item/started", ["turnId": turnID, "item": ["id": id, "type": "reasoning", "summary": [Any](), "content": [Any]()]])
        var text = ""
        await pace(rates.thinkingPerSecond * 2 / 3, for: .seconds(seconds), until: end) { step in
            let fragment = "Reading part \(step). "
            text += fragment
            await emit("item/reasoning/summaryTextDelta", ["turnId": turnID, "itemId": id, "delta": fragment, "summaryIndex": 0])
        }
        await emit("item/completed", ["turnId": turnID, "item": ["id": id, "type": "reasoning", "summary": [text], "content": [Any]()]])
    }

    private func command(turnID: String, id: String, seconds: Double, until end: ContinuousClock.Instant) async {
        await emit("item/started", ["turnId": turnID, "item": commandItem(id: id, status: "inProgress", output: nil)])
        var output = ""
        await pace(rates.commandOutputPerSecond, for: .seconds(seconds), until: end) { step in
            let line = "[\(step)/400] Compiling Module\(step).swift and linking its objects\n"
            output += line
            await emit("item/commandExecution/outputDelta", ["turnId": turnID, "itemId": id, "delta": line])
        }
        await emit("item/completed", ["turnId": turnID, "item": commandItem(id: id, status: "completed", output: output)])
    }

    private func message(turnID: String, id: String, seconds: Double, until end: ContinuousClock.Instant) async {
        await emit("item/started", ["turnId": turnID, "item": ["id": id, "type": "agentMessage", "text": ""]])
        var text = ""
        await pace(rates.textPerSecond, for: .seconds(seconds), until: end) { step in
            let fragment = "\(id)-\(step) streamed words, "
            text += fragment
            await emit("item/agentMessage/delta", ["turnId": turnID, "itemId": id, "delta": fragment])
        }
        await emit("item/completed", ["turnId": turnID, "item": ["id": id, "type": "agentMessage", "text": text]])
    }

    private func commandItem(id: String, status: String, output: String?) -> [String: Any] {
        [
            "id": id, "type": "commandExecution", "command": "swift build", "cwd": "/tmp/workspace",
            "processId": NSNull(), "source": "agent", "status": status, "commandActions": [Any](),
            "aggregatedOutput": output ?? NSNull(), "exitCode": output == nil ? NSNull() : 0, "durationMs": NSNull()
        ]
    }

    private func emit(_ method: String, _ params: [String: Any]) async {
        var params = params
        params["threadId"] = threadID
        await transport.emit(method: method, params: json(params))
        frames.add()
    }
}

/// Runs `body` at `rate` per second for `duration`, on an absolute schedule so a slow step does
/// not lower the rate.
private func pace(
    _ rate: Double,
    for duration: Duration,
    until end: ContinuousClock.Instant,
    _ body: (Int) async -> Void
) async {
    guard rate > 0 else { return }
    let start = ContinuousClock.now
    let interval = Duration.seconds(1 / rate)
    var step = 0
    while ContinuousClock.now - start < duration, ContinuousClock.now < end, !Task.isCancelled {
        await body(step)
        step += 1
        try? await Task.sleep(until: start + interval * step, clock: .continuous)
    }
}

private func json(_ value: Any) -> JSONValue {
    switch value {
    case let value as JSONValue: value
    case let value as String: .string(value)
    case let value as Bool: .bool(value)
    case let value as Int: .integer(Int64(value))
    case let value as Double: .number(value)
    case let value as [String: Any]: .object(value.mapValues(json))
    case let value as [Any]: .array(value.map(json))
    case is NSNull: .null
    default: .string(String(describing: value))
    }
}

// MARK: - Measurement

/// A SwiftUI view's body modelled with Observation: it re-registers what it reads after each
/// change, at most once per 60 Hz frame, the way SwiftUI re-evaluates an invalidated body.
@MainActor
private final class ViewInvalidationModel {
    private(set) var evaluations = 0
    private let reads: @MainActor () -> Void
    private var isScheduled = false
    private var isStopped = false
    private var lastEvaluation = ContinuousClock.now

    init(reads: @escaping @MainActor () -> Void) {
        self.reads = reads
        evaluate()
    }

    func stop() { isStopped = true }

    private func evaluate() {
        guard !isStopped else { return }
        evaluations += 1
        lastEvaluation = ContinuousClock.now
        withObservationTracking { reads() } onChange: { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
    }

    private func invalidate() {
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        let frame = lastEvaluation + .microseconds(16_667)
        Task { @MainActor in
            try? await Task.sleep(until: frame, clock: .continuous)
            self.isScheduled = false
            self.evaluate()
        }
    }
}

/// How late the main actor runs a 10 ms timer: the delay a click or keystroke would see.
@MainActor
private final class MainActorLagProbe {
    private var samples: [Double] = []
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(10))
                let late = (ContinuousClock.now - started - .milliseconds(10)).seconds * 1_000
                self?.samples.append(max(0, late))
            }
        }
    }

    func stop() { task?.cancel() }

    func summary() -> LagSummary {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        return LagSummary(
            p50: percentile(0.5), p99: percentile(0.99), max: sorted.last ?? 0,
            over50ms: sorted.filter { $0 > 50 }.count
        )
    }
}

private struct LagSummary {
    let p50: Double
    let p99: Double
    let max: Double
    let over50ms: Int
}

/// CPU time the main thread used since this clock was made.
@MainActor
private struct MainThreadClock {
    private let port = pthread_mach_thread_np(pthread_self())
    private let start: Double

    init() { start = Self.cpuSeconds(of: pthread_mach_thread_np(pthread_self())) }

    func elapsedCPUSeconds() -> Double { Self.cpuSeconds(of: port) - start }

    nonisolated static func cpuSeconds(of thread: mach_port_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }
}

private enum ProcessMemory {
    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The complete answers each Claude driver streamed, in order.
private final class ExpectedText: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [UUID: [String]] = [:]
    func append(_ text: String, for id: UUID) { lock.withLock { texts[id, default: []].append(text) } }
    func texts(for id: UUID) -> [String] { lock.withLock { texts[id] ?? [] } }
}

/// Counts and main-thread time of every persistence call the model makes.
private final class PersistenceProbes: @unchecked Sendable {
    struct Totals: Equatable {
        var calls: [String: Int] = [:]
        var mainThreadCalls: [String: Int] = [:]
        var mainThreadSeconds: [String: Double] = [:]

        func minus(_ other: Totals) -> Totals {
            Totals(
                calls: calls.merging(other.calls.mapValues { -$0 }, uniquingKeysWith: +),
                mainThreadCalls: mainThreadCalls.merging(other.mainThreadCalls.mapValues { -$0 }, uniquingKeysWith: +),
                mainThreadSeconds: mainThreadSeconds.merging(other.mainThreadSeconds.mapValues { -$0 }, uniquingKeysWith: +)
            )
        }
    }

    private let lock = NSLock()
    private var totals = Totals()

    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let isMain = Thread.isMainThread
        let started = ContinuousClock.now
        defer {
            let seconds = (ContinuousClock.now - started).seconds
            lock.withLock {
                totals.calls[name, default: 0] += 1
                if isMain {
                    totals.mainThreadCalls[name, default: 0] += 1
                    totals.mainThreadSeconds[name, default: 0] += seconds
                }
            }
        }
        return try body()
    }

    func count(_ name: String) {
        lock.withLock { totals.calls[name, default: 0] += 1 }
    }

    var snapshot: Totals { lock.withLock { totals } }
}

private final class CountingSessionRepository: SessionRepository, @unchecked Sendable {
    let base: any SessionRepository
    let probes: PersistenceProbes
    init(base: any SessionRepository, probes: PersistenceProbes) {
        self.base = base
        self.probes = probes
    }
    func loadSessions() async throws -> [SessionRecord] { try await base.loadSessions() }
    func upsert(_ session: SessionRecord) async throws {
        probes.count("sqlite.upsert")
        try await base.upsert(session)
    }
    func archive(id: UUID) async throws { try await base.archive(id: id) }
    func archive(id: UUID, providerArchived: Bool) async throws { try await base.archive(id: id, providerArchived: providerArchived) }
    func loadArchivedSessions() async throws -> [ArchivedSessionRecord] { try await base.loadArchivedSessions() }
    func unarchive(id: UUID) async throws -> SessionRecord? { try await base.unarchive(id: id) }
    func discard(id: UUID) async throws { try await base.discard(id: id) }
}

private final class CountingTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    let base: any TranscriptRepository
    let probes: PersistenceProbes
    init(base: any TranscriptRepository, probes: PersistenceProbes) {
        self.base = base
        self.probes = probes
    }
    func load(for sessionID: UUID) -> [TranscriptEntry] { probes.measure("transcript.load") { base.load(for: sessionID) } }
    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        probes.measure("transcript.save") { base.save(entries, for: sessionID) }
    }
    func remove(for sessionID: UUID) { probes.measure("transcript.remove") { base.remove(for: sessionID) } }
}

private final class CountingCodexTimelineItemRepository: CodexTimelineItemRepository, @unchecked Sendable {
    let base: any CodexTimelineItemRepository
    let probes: PersistenceProbes
    init(base: any CodexTimelineItemRepository, probes: PersistenceProbes) {
        self.base = base
        self.probes = probes
    }
    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem] { probes.measure("codexItems.load") { base.load(for: sessionID) } }
    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID) {
        probes.measure("codexItems.save") { base.save(items, for: sessionID) }
    }
    func remove(for sessionID: UUID) { probes.measure("codexItems.remove") { base.remove(for: sessionID) } }
}

private final class CountingCodexPendingRequestRepository: CodexPendingServerRequestRepository, @unchecked Sendable {
    let base: any CodexPendingServerRequestRepository
    let probes: PersistenceProbes
    init(base: any CodexPendingServerRequestRepository, probes: PersistenceProbes) {
        self.base = base
        self.probes = probes
    }
    func load(for sessionID: UUID) -> [CodexPendingServerRequest] { probes.measure("codexRequests.load") { base.load(for: sessionID) } }
    func save(_ requests: [CodexPendingServerRequest], for sessionID: UUID) {
        probes.measure("codexRequests.save") { base.save(requests, for: sessionID) }
    }
    func remove(for sessionID: UUID) { probes.measure("codexRequests.remove") { base.remove(for: sessionID) } }
}

private final class ClaudeTransportBook: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [UUID: FakeClaudeTransport] = [:]
    func make(for id: UUID) -> FakeClaudeTransport {
        let transport = FakeClaudeTransport()
        lock.withLock { transports[id] = transport }
        return transport
    }
    func transport(for id: UUID) -> FakeClaudeTransport? { lock.withLock { transports[id] } }
}

private final class CountingNotificationCenter: SystemNotificationCenter {
    private(set) var posts = 0
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async { posts += 1 }
}

@MainActor
private struct Sample {
    var frames = 0
    var processCPUSeconds = 0.0
    var viewEvaluations: [Int] = []
    var publications = AppModelPublicationCounts()
    var persistence = PersistenceProbes.Totals()

    static func take(model: AppModel, probes: PersistenceProbes, frames: FrameCounter, views: [ViewInvalidationModel]) -> Sample {
        Sample(
            frames: frames.value,
            processCPUSeconds: ProcessMemory.processCPUSeconds(),
            viewEvaluations: views.map(\.evaluations),
            publications: model.publicationCounts,
            persistence: probes.snapshot
        )
    }

    func minus(_ other: Sample) -> Sample {
        Sample(
            frames: frames - other.frames,
            processCPUSeconds: processCPUSeconds - other.processCPUSeconds,
            viewEvaluations: zip(viewEvaluations, other.viewEvaluations).map { $0 - $1 },
            publications: AppModelPublicationCounts(
                transcripts: publications.transcripts - other.publications.transcripts,
                backgroundTranscripts: publications.backgroundTranscripts - other.publications.backgroundTranscripts,
                codexStates: publications.codexStates - other.publications.codexStates,
                backgroundCodexStates: publications.backgroundCodexStates - other.publications.backgroundCodexStates
            ),
            persistence: persistence.minus(other.persistence)
        )
    }
}

private struct StreamingReport {
    let seconds: Double
    let framesPerSecond: Double
    let mainBusyFraction: Double
    let processCPUFraction: Double
    let lag: LagSummary
    let windowEvaluationsPerSecond: Double
    let shownTaskViewEvaluationsPerSecond: Double
    let sidebarEvaluationsPerSecond: Double
    let publications: AppModelPublicationCounts
    let persistence: PersistenceProbes.Totals
    let notifications: Int
    let memory: [(seconds: Double, megabytes: Double)]
    let lostText: [String]
    let backgroundTasks: Int

    var mainThreadSnapshotWritesPerSecond: Double {
        Double(persistence.mainThreadCalls["transcript.save"] ?? 0) / seconds
    }

    func print(label: String) {
        func rate(_ value: Int) -> String { String(format: "%.1f/s", Double(value) / seconds) }
        func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }
        var lines = [
            "[perf] \(label): \(String(format: "%.0f", seconds)) s measured, \(String(format: "%.0f", framesPerSecond)) provider frames/s, \(backgroundTasks) background tasks",
            "[perf] main thread busy \(String(format: "%.1f%%", mainBusyFraction * 100)), whole process CPU \(String(format: "%.1f%%", processCPUFraction * 100))",
            "[perf] main-actor timer lateness p50 \(ms(lag.p50)) p99 \(ms(lag.p99)) max \(ms(lag.max)), >50 ms \(lag.over50ms)x",
            "[perf] view bodies/s (60 Hz model): window \(String(format: "%.1f", windowEvaluationsPerSecond)), shown task \(String(format: "%.1f", shownTaskViewEvaluationsPerSecond)), sidebar \(String(format: "%.1f", sidebarEvaluationsPerSecond))",
            "[perf] transcript publications \(rate(publications.transcripts)) (background \(rate(publications.backgroundTranscripts))), codex states \(rate(publications.codexStates)) (background \(rate(publications.backgroundCodexStates)))",
            "[perf] sqlite upserts \(rate(persistence.calls["sqlite.upsert"] ?? 0)), notifications \(notifications)"
        ]
        for key in persistence.calls.keys.sorted() where key != "sqlite.upsert" {
            let calls = persistence.calls[key] ?? 0
            let main = persistence.mainThreadCalls[key] ?? 0
            let seconds = persistence.mainThreadSeconds[key] ?? 0
            lines.append("[perf] \(key): \(rate(calls)), on main \(rate(main)) costing \(ms(seconds * 1_000 / self.seconds))/s")
        }
        let memoryLine = memory.map { String(format: "%.0fs %.0f MB", $0.seconds, $0.megabytes) }.joined(separator: ", ")
        lines.append("[perf] memory footprint: \(memoryLine)")
        Swift.print(lines.joined(separator: "\n"))
        PerfBenchRecord.write("ten-streaming-tasks", [
            "mainThreadBusyPercent": mainBusyFraction * 100, "processCPUPercent": processCPUFraction * 100,
            "mainActorLatenessP99Ms": lag.p99, "mainActorLatenessMaxMs": lag.max,
            "windowBodiesPerSecond": windowEvaluationsPerSecond,
            "shownTaskBodiesPerSecond": shownTaskViewEvaluationsPerSecond,
            "footprintMiB": memory.last?.megabytes ?? 0
        ])
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

// MARK: - Long Codex thread

/// One Codex task whose thread already holds hundreds of finished turns, streaming command output
/// and an answer in a new turn. A presentation update should cost what changed in it, not the
/// length of the conversation. Runs only with `NHC_PERF_BENCH=1` (`NHC_PERF_BENCH_SECONDS`,
/// default 20; `NHC_PERF_BENCH_TURNS`, default 300; `NHC_PERF_BENCH_ITEMS_PER_TURN`, default 10;
/// `NHC_PERF_BENCH_ROUTES`, default `direct,yhp,app,projection`; `window` and `window-all` on
/// request) and prints `[perf] long-codex` lines for an empty and a long
/// thread on each route.
@MainActor
final class LongCodexThreadPerformanceTests: XCTestCase {
    func testBenchmarkLongCodexThreadStreaming() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to run the benchmark")
        let seconds = environment["NHC_PERF_BENCH_SECONDS"].flatMap(Double.init) ?? 20
        let turns = environment["NHC_PERF_BENCH_TURNS"].flatMap(Int.init) ?? 300
        let itemsPerTurn = environment["NHC_PERF_BENCH_ITEMS_PER_TURN"].flatMap(Int.init) ?? 10
        let routes = (environment["NHC_PERF_BENCH_ROUTES"] ?? "direct,yhp,app,projection")
            .split(separator: ",").compactMap { LongCodexRoute(rawValue: String($0)) }
        let label = environment["NHC_PERF_BENCH_LABEL"] ?? "benchmark"
        for history in [0, turns] {
            for route in routes {
                let report = try await LongCodexScenario.run(
                    route: route, historyTurns: history, itemsPerTurn: itemsPerTurn,
                    measuring: .seconds(seconds), warmUp: .seconds(2), testCase: self
                )
                report.print(label: label)
                XCTAssertGreaterThan(report.updates, 0, "The fixture must actually stream")
            }
        }
    }
}

private enum LongCodexRoute: String, CaseIterable {
    /// `CodexAdapter` alone: the reducer and its own publication policy.
    case direct
    /// The product's YHP route without the app model: what the protocol boundary adds.
    case yhp
    /// The app model over the YHP route, as the product runs it.
    case app
    /// `CodexAdapter` alone, each published state projected through a `ConversationProjectionCache`
    /// as the renderer projects it: what the conversation model adds per update.
    case projection
    /// The `app` route with the task's conversation mounted in an unshown window and laid out at
    /// 60 Hz, drawn by `ConversationTimeline` (its latest 40 turns, D11): what the renderer adds on the
    /// main thread. The window is never drawn to the screen, so this counts view updates and layout,
    /// not drawing.
    case window
    /// `window` drawing every loaded turn: the renderer without its turn window.
    case windowAll = "window-all"

    var mountsConversation: Bool { self == .window || self == .windowAll }

    /// The turns the renderer draws at first.
    var turnWindowCount: Int {
        self == .windowAll ? 100_000 : ConversationTurnWindow.initialTurnCount
    }
}

/// The shown task's conversation on the `window-*` routes, read from the app model as the window
/// reads it.
private struct LongCodexConversation: View {
    let model: AppModel
    let sessionID: UUID
    var turnWindowCount = ConversationTurnWindow.initialTurnCount

    var body: some View {
        TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/tmp/workspace"),
            entries: model.transcriptBySessionID[sessionID] ?? [],
            codexTaskState: model.codexPresentationBySessionID[sessionID],
            turnWindowCount: turnWindowCount
        )
        .frame(width: 900, height: 900)
    }
}

/// Projection time and turn counts on the `projection` route.
private final class ProjectionMeter: @unchecked Sendable {
    struct Totals {
        var seconds = 0.0
        var updates = 0
        var counts = ConversationProjectionCache.Counts()
    }

    private let lock = NSLock()
    private var totals = Totals()

    func add(_ duration: Duration, counts: ConversationProjectionCache.Counts) {
        lock.withLock {
            totals.seconds += duration.seconds
            totals.updates += 1
            totals.counts = counts
        }
    }

    var value: Totals { lock.withLock { totals } }
}

private struct LongCodexReport {
    let route: LongCodexRoute
    let historyTurns: Int
    let itemsPerTurn: Int
    let seconds: Double
    let frames: Int
    let updates: Int
    let processCPUSeconds: Double
    let mainThreadCPUSeconds: Double?
    let setupSeconds: Double
    /// The `projection` route's projections over the measured window.
    var projection: (seconds: Double, updates: Int, projected: Int, reused: Int)? = nil

    func print(label: String) {
        let perUpdate = updates > 0 ? processCPUSeconds * 1_000 / Double(updates) : 0
        var line = "[perf] long-codex \(label) route=\(route.rawValue) history=\(historyTurns)x\(itemsPerTurn)"
            + String(format: ": %.0f frames/s, %.1f updates/s, process CPU %.1f%%, %.2f ms CPU/update",
                     Double(frames) / seconds, Double(updates) / seconds,
                     processCPUSeconds / seconds * 100, perUpdate)
        if let mainThreadCPUSeconds {
            line += String(format: ", main thread %.1f%% (%.2f ms/update)",
                           mainThreadCPUSeconds / seconds * 100,
                           updates > 0 ? mainThreadCPUSeconds * 1_000 / Double(updates) : 0)
        }
        if let projection, projection.updates > 0 {
            let updates = Double(projection.updates)
            line += String(format: ", projection %.3f ms/update (%.2f turns projected, %.1f reused per update)",
                           projection.seconds * 1_000 / updates, Double(projection.projected) / updates,
                           Double(projection.reused) / updates)
        }
        line += String(format: ", setup %.1f s", setupSeconds)
        Swift.print(line)
        var metrics = ["processCPUPercent": processCPUSeconds / seconds * 100, "cpuPerUpdateMs": perUpdate]
        if let mainThreadCPUSeconds { metrics["mainThreadCPUPercent"] = mainThreadCPUSeconds / seconds * 100 }
        PerfBenchRecord.write("long-codex-\(route.rawValue)-\(historyTurns)x\(itemsPerTurn)", metrics)
    }
}

/// Counts the presentation states a consumer received.
private final class StateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var latestTurnCount = 0
    func add(_ state: CodexTaskState) {
        lock.withLock {
            count += 1
            latestTurnCount = state.thread?.turns.count ?? 0
        }
    }
    var value: Int { lock.withLock { count } }
    var turns: Int { lock.withLock { latestTurnCount } }
}

@MainActor
private enum LongCodexScenario {
    static let threadID = "long-thread"

    static func run(
        route: LongCodexRoute,
        historyTurns: Int,
        itemsPerTurn: Int,
        measuring duration: Duration,
        warmUp: Duration,
        testCase: XCTestCase
    ) async throws -> LongCodexReport {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object([
                "id": .string(threadID), "status": .object(["type": .string("idle")]), "turns": .array([])
            ])])]
        ])
        let counter = StateCounter()
        let projections = route == .projection ? ProjectionMeter() : nil
        var consumer: Task<Void, Never>?
        var model: AppModel?
        let turnCount: @MainActor () async -> Int
        switch route {
        case .direct, .yhp, .projection:
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
            let adapter: any CodexPresentationProviding & HarnessAdapter = route == .yhp
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex())
                : direct
            let workspaceURL = URL(filePath: "/tmp/long-codex")
            let handle = try await adapter.createSession(.init(
                localSessionID: UUID(), workspaceURL: workspaceURL, initialPrompt: nil
            ))
            let stream = try await adapter.presentationStates(for: handle)
            consumer = Task.detached {
                let cache = projections.map { _ in ConversationProjectionCache() }
                for await state in stream {
                    if let projections, let cache {
                        let start = ContinuousClock.now
                        _ = cache.codex(state, workspaceURL: workspaceURL, historySelection: nil)
                        projections.add(ContinuousClock.now - start, counts: cache.counts)
                    }
                    counter.add(state)
                }
            }
            testCase.addTeardownBlock { await adapter.close(handle) }
            turnCount = { counter.turns }
        case .app, .window, .windowAll:
            let built = try await makeModel(transport: transport, testCase: testCase)
            model = built.model
            let id = built.sessionID
            if route.mountsConversation {
                let host = WindowlessRender.Host(
                    LongCodexConversation(model: built.model, sessionID: id, turnWindowCount: route.turnWindowCount),
                    size: NSSize(width: 900, height: 900)
                )
                // The display's refresh: an unshown window lays out only when asked.
                let display = Task { @MainActor in
                    while !Task.isCancelled {
                        host.hosting.layoutSubtreeIfNeeded()
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
                testCase.addTeardownBlock { @MainActor in
                    display.cancel()
                    host.close()
                }
            }
            turnCount = { [weak model = built.model] in
                model?.codexPresentationBySessionID[id]?.thread?.turns.count ?? 0
            }
        }
        defer { consumer?.cancel() }

        let setupStart = ContinuousClock.now
        for turn in 0..<historyTurns {
            for (method, params) in LongCodexHistory.turn(turn, itemsPerTurn: itemsPerTurn, threadID: threadID) {
                await transport.emit(method: method, params: params)
            }
        }
        let settleDeadline = ContinuousClock.now + .seconds(600)
        while await turnCount() < historyTurns, ContinuousClock.now < settleDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(1))
        let setupSeconds = (ContinuousClock.now - setupStart).seconds

        let frames = FrameCounter()
        let end = ContinuousClock.now + warmUp + duration
        let driver = LongCodexDriver(threadID: threadID, transport: transport, frames: frames)
        let producer = Task.detached { await driver.run(until: end) }
        try await Task.sleep(for: warmUp)
        let mainThread = MainThreadClock()
        let startCPU = ProcessMemory.processCPUSeconds()
        let startFrames = frames.value
        let startUpdates = model?.publicationCounts.codexStates ?? counter.value
        let startProjections = projections?.value
        let measureStart = ContinuousClock.now
        try await Task.sleep(until: end, clock: .continuous)
        let elapsed = (ContinuousClock.now - measureStart).seconds
        let mainBusy = mainThread.elapsedCPUSeconds()
        let cpu = ProcessMemory.processCPUSeconds() - startCPU
        let updates = (model?.publicationCounts.codexStates ?? counter.value) - startUpdates
        let emitted = frames.value - startFrames
        let endProjections = projections?.value
        producer.cancel()
        await producer.value
        var report = LongCodexReport(
            route: route, historyTurns: historyTurns, itemsPerTurn: itemsPerTurn, seconds: elapsed,
            frames: emitted, updates: updates, processCPUSeconds: cpu,
            mainThreadCPUSeconds: route == .app || route.mountsConversation ? mainBusy : nil,
            setupSeconds: setupSeconds
        )
        if let startProjections, let endProjections {
            report.projection = (
                seconds: endProjections.seconds - startProjections.seconds,
                updates: endProjections.updates - startProjections.updates,
                projected: endProjections.counts.projected - startProjections.counts.projected,
                reused: endProjections.counts.reused - startProjections.counts.reused
            )
        }
        return report
    }

    private static func makeModel(
        transport: FakeCodexTransport,
        testCase: XCTestCase
    ) async throws -> (model: AppModel, sessionID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-long-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let codexCLI = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: codexCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexCLI.path)
        let suite = testDefaultsSuite("LongCodexThread")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(repository: try SQLiteSessionRepository(
                databaseURL: root.appending(path: "session-index.sqlite3")
            )),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPCodexCompatibilityAdapter(
                    adapter: CodexAdapter(executableURL: url, transport: transport),
                    manifest: HarnessProtocolCompatibilityManifest.codex()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: CountingNotificationCenter(),
            restoresIndexOnLaunch: false
        )
        testCase.addTeardownBlock { await model.shutdown() }
        let folder = root.appending(path: "codex-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let created = await model.createSession(
            harness: .codex, workspaceURL: folder, runtimeExecutableURL: codexCLI, title: "Long Codex"
        )
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Codex task did not start")
        let deadline = ContinuousClock.now + .seconds(5)
        while model.codexPresentationBySessionID[task.id]?.thread == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (model, task.id)
    }
}

/// Finished turns the way the App Server reports them while the person works: a request,
/// reasoning, commands with output, a file change, and answers.
private enum LongCodexHistory {
    static func turn(_ index: Int, itemsPerTurn: Int, threadID: String) -> [(String, JSONValue)] {
        let turnID = "history-\(index)"
        var frames: [(String, JSONValue)] = [
            ("turn/started", json(["threadId": threadID, "turn": ["id": turnID, "status": "inProgress", "items": [Any]()]]))
        ]
        for slot in 0..<itemsPerTurn {
            frames.append(("item/completed", json([
                "threadId": threadID, "turnId": turnID, "item": item(slot, id: "\(turnID)-item-\(slot)")
            ])))
        }
        frames.append(("turn/completed", json([
            "threadId": threadID, "turn": ["id": turnID, "status": "completed", "items": [Any]()]
        ])))
        return frames
    }

    private static func text(_ length: Int, seed: String) -> String {
        let words = "\(seed) reads the module, checks the failing case and explains the change. "
        return String(String(repeating: words, count: length / words.count + 1).prefix(length))
    }

    private static func item(_ slot: Int, id: String) -> [String: Any] {
        switch slot % 10 {
        case 0:
            return ["id": id, "type": "userMessage",
                    "content": [["type": "text", "text": text(240, seed: id), "text_elements": [Any]()]]]
        case 1, 7:
            return ["id": id, "type": "reasoning", "summary": [text(320, seed: id)], "content": [Any]()]
        case 3:
            return ["id": id, "type": "agentMessage", "text": text(400, seed: id), "phase": "commentary"]
        case 5:
            return ["id": id, "type": "fileChange", "status": "completed", "changes": [[
                "path": "Sources/Module\(slot).swift",
                "kind": ["type": "update", "move_path": NSNull()],
                "diff": "@@ -1,3 +1,3 @@\n" + text(800, seed: id)
            ]]]
        case 9:
            return ["id": id, "type": "agentMessage", "text": text(900, seed: id), "phase": "final_answer"]
        default:
            return [
                "id": id, "type": "commandExecution", "command": "swift test --filter Module\(slot)Tests",
                "cwd": "/tmp/workspace", "processId": NSNull(), "source": "agent", "status": "completed",
                "commandActions": [Any](), "aggregatedOutput": text(1_500, seed: id), "exitCode": 0,
                "durationMs": 1_234
            ]
        }
    }
}

/// The measured turn: reasoning, a streaming command, an answer, another command and answer.
private struct LongCodexDriver: Sendable {
    let threadID: String
    let transport: FakeCodexTransport
    let frames: FrameCounter

    func run(until end: ContinuousClock.Instant) async {
        var turn = 0
        while ContinuousClock.now < end, !Task.isCancelled {
            turn += 1
            let turnID = "live-\(turn)"
            await emit("turn/started", ["turn": ["id": turnID, "status": "inProgress", "items": [Any]()]])
            await stream(turnID: turnID, id: "\(turnID)-reasoning", type: "reasoning", rate: 20, seconds: 2, until: end)
            await stream(turnID: turnID, id: "\(turnID)-cmd1", type: "commandExecution", rate: 40, seconds: 4, until: end)
            await stream(turnID: turnID, id: "\(turnID)-msg1", type: "agentMessage", rate: 30, seconds: 4, until: end)
            await stream(turnID: turnID, id: "\(turnID)-cmd2", type: "commandExecution", rate: 40, seconds: 2, until: end)
            await stream(turnID: turnID, id: "\(turnID)-msg2", type: "agentMessage", rate: 30, seconds: 2, until: end)
            await emit("turn/completed", ["turn": ["id": turnID, "status": "completed", "items": [Any]()]])
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func stream(
        turnID: String, id: String, type: String, rate: Double, seconds: Double,
        until end: ContinuousClock.Instant
    ) async {
        let started: [String: Any]
        switch type {
        case "reasoning": started = ["id": id, "type": type, "summary": [Any](), "content": [Any]()]
        case "agentMessage": started = ["id": id, "type": type, "text": ""]
        default: started = command(id: id, status: "inProgress", output: nil)
        }
        await emit("item/started", ["turnId": turnID, "item": started])
        var text = ""
        await pace(rate, for: .seconds(seconds), until: end) { step in
            let fragment = type == "commandExecution"
                ? "[\(step)/400] Compiling Module\(step).swift and linking its objects\n"
                : "\(id)-\(step) streamed words, "
            text += fragment
            switch type {
            case "reasoning":
                await emit("item/reasoning/summaryTextDelta", [
                    "turnId": turnID, "itemId": id, "delta": fragment, "summaryIndex": 0
                ])
            case "agentMessage":
                await emit("item/agentMessage/delta", ["turnId": turnID, "itemId": id, "delta": fragment])
            default:
                await emit("item/commandExecution/outputDelta", ["turnId": turnID, "itemId": id, "delta": fragment])
            }
        }
        let completed: [String: Any]
        switch type {
        case "reasoning": completed = ["id": id, "type": type, "summary": [text], "content": [Any]()]
        case "agentMessage": completed = ["id": id, "type": type, "text": text]
        default: completed = command(id: id, status: "completed", output: text)
        }
        await emit("item/completed", ["turnId": turnID, "item": completed])
    }

    private func command(id: String, status: String, output: String?) -> [String: Any] {
        [
            "id": id, "type": "commandExecution", "command": "swift build", "cwd": "/tmp/workspace",
            "processId": NSNull(), "source": "agent", "status": status, "commandActions": [Any](),
            "aggregatedOutput": output ?? NSNull(), "exitCode": output == nil ? NSNull() : 0, "durationMs": NSNull()
        ]
    }

    private func emit(_ method: String, _ params: [String: Any]) async {
        var params = params
        params["threadId"] = threadID
        await transport.emit(method: method, params: json(params))
        frames.add()
    }
}
