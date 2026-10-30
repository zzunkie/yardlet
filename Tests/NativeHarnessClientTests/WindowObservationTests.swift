import Darwin
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What a streaming task costs the rest of the window. A task's output is read by its own surface
/// (`TaskObservationScope`); the window's own body — the sidebar, the commands it publishes to the
/// menu bar — and the scene's keep-awake reading must not observe it. Before this, every published
/// fragment of the shown task, and of any task while no search was typed, re-evaluated
/// `MainWindow.body`, which rebuilt the Task and Split View menus and the window's root host.
///
/// The window's body is evaluated outside a hosting view, under Observation, as SwiftUI tracks it;
/// the fake CLIs speak Claude Code's stream shapes and no model is asked anything.
@MainActor
final class WindowObservationTests: XCTestCase {
    func testAStreamingTaskLeavesTheWindowAndTheSceneAlone() async throws {
        let fixture = try await makeWindowFixture(tasks: 3)
        let model = fixture.model
        let shown = fixture.tasks[0], background = fixture.tasks[1]
        model.splits.activate(.session(shown.id))
        for task in [shown, background] { await model.send(HarnessUserInput(text: "Start"), to: task) }
        try await waitUntil { model.store.sessions.filter { $0.status == .running }.count == 2 }
        try await Task.sleep(for: .milliseconds(200))

        let window = Invalidations { _ = MainWindow(model: model).body }
        let scene = Invalidations { _ = model.keepsMacAwake }
        let shownSurface = Invalidations { _ = model.transcriptBySessionID[shown.id] }
        let shownTransport = try XCTUnwrap(fixture.transport(shown.id))
        let backgroundTransport = try XCTUnwrap(fixture.transport(background.id))
        for step in 0..<120 {
            if step.isMultiple(of: 30) {
                await shownTransport.emit(json(["type": "assistant", "session_id": "s", "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "t\(step)", "name": "Bash",
                     "input": ["command": "rg -n thing Sources", "description": "Search the sources"]]]]]))
                await shownTransport.emit(json(["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "t\(step)", "content": "Sources/A.swift:1: thing"]]]]))
            }
            for transport in [shownTransport, backgroundTransport] {
                await transport.emit(json(["type": "stream_event", "session_id": "s", "event": [
                    "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "word\(step) "]]]))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        window.stop(); scene.stop(); shownSurface.stop()
        print("[window] shown surface \(shownSurface.count), window \(window.count), scene \(scene.count)")

        XCTAssertGreaterThan(shownSurface.count, 20, "The fixture must publish the shown task many times")
        // Before: one window evaluation per publication of either task (about 70 here).
        XCTAssertLessThanOrEqual(window.count, 2, "Streaming re-evaluated the window's own body")
        XCTAssertEqual(scene.count, 0, "Streaming re-evaluated the scene's keep-awake reading")
    }

    /// The keep-awake reading still follows work, now from outside the views: a running turn holds
    /// the sleep assertion and its end lets it go.
    func testKeepingTheMacAwakeFollowsWorkFromOutsideTheViews() async throws {
        let fixture = try await makeWindowFixture(tasks: 1)
        let model = fixture.model, task = fixture.tasks[0]
        let activity = RunningWorkActivity()
        defer { activity.update(isWorking: false) }
        activity.follow(model)
        XCTAssertFalse(activity.isHolding)
        await model.send(HarnessUserInput(text: "Start"), to: task)
        try await waitUntil { activity.isHolding }
        let transport = try XCTUnwrap(fixture.transport(task.id))
        await transport.emit(json(["type": "result", "subtype": "success", "is_error": false, "result": "Done.",
                                   "session_id": "s"]))
        try await waitUntil { !activity.isHolding }
        XCTAssertEqual(model.store.sessions.first?.status, .ready)
    }

    /// A running turn's rows ask for their wording each time the turn redraws; the forms kept for a
    /// description are the ones the rules work out. `WindowObservationPerformanceTests` times both.
    func testKeptDescriptionFormsAreTheRulesAnswer() {
        for description in descriptionSamples {
            XCTAssertEqual(ClaudeDescriptionVerbs.forms(of: description), ClaudeDescriptionVerbs.conjugated(description))
        }
    }

    /// Quitting writes every reading snapshot still waiting before it goes on.
    func testQuittingSavesWaitingSnapshots() async throws {
        let repository = SlowTranscriptRepository(delay: 0)
        let task = try await quitWithAWaitingSnapshot(in: repository).task
        XCTAssertGreaterThanOrEqual(repository.saves, 1, "Quitting saved the waiting snapshot")
        XCTAssertTrue(repository.load(for: task.id).contains { entry in
            if case let .assistant(text, _) = entry.content { return text == "Waiting to be saved" }
            return false
        })
    }

    /// When quitting, a Codex thread's newest text, which no checkpoint has written yet, is what is saved.
    func testQuittingSavesACodexThreadsNewestText() async throws {
        let repository = SlowTranscriptRepository(delay: 0)
        let session = try await quitWithACodexThread(in: repository).session
        XCTAssertTrue(repository.load(for: session.id).contains { entry in
            if case let .assistant(text, _) = entry.content { return text == "Saved when quitting" }
            return false
        }, "quitting saved the thread's newest text")
    }
}

/// What the same work costs the main thread. These bounds are times, so they run with the other
/// performance tests rather than with the quick ones.
@MainActor
final class WindowObservationPerformanceTests: XCTestCase {
    /// The forms of a description are worked out once: the same answer, without running the rules again.
    func testDescriptionFormsAreWorkedOutOnce() {
        let clock = ContinuousClock()
        let rounds = 20
        let worked = clock.measure {
            for _ in 0..<rounds { for description in descriptionSamples { _ = ClaudeDescriptionVerbs.conjugated(description) } }
        }
        let kept = clock.measure {
            for _ in 0..<rounds { for description in descriptionSamples { _ = ClaudeDescriptionVerbs.forms(of: description) } }
        }
        print("[window] \(rounds * descriptionSamples.count) descriptions: worked out \(worked), kept \(kept)")
        XCTAssertLessThan(kept, worked / 5, "Kept forms should cost a lookup, not the rules")
    }

    /// Quitting writes the waiting snapshots off the main thread: a long conversation takes a while
    /// to encode and write, and holding the main thread that long showed Yardlet as not responding
    /// while an update installed.
    func testQuittingSavesWaitingSnapshotsWithoutHoldingTheMainThread() async throws {
        let repository = SlowTranscriptRepository(delay: 0.4)
        let longestGap = try await quitWithAWaitingSnapshot(in: repository).gap
        print("[window] longest main-thread gap while quitting: \(longestGap)")
        XCTAssertGreaterThanOrEqual(repository.saves, 1, "Quitting saved the waiting snapshot")
        XCTAssertLessThan(longestGap, .milliseconds(250), "Quitting held the main thread while it wrote")
    }

    /// A Codex thread's reading snapshot is flattened and written off the main thread when quitting.
    func testQuittingSavesACodexThreadsSnapshotWithoutHoldingTheMainThread() async throws {
        let repository = SlowTranscriptRepository(delay: 0.4)
        let (session, longestGap) = try await quitWithACodexThread(in: repository)
        print("[window] longest main-thread gap while quitting with a Codex thread: \(longestGap)")
        XCTAssertFalse(repository.load(for: session.id).isEmpty, "Quitting saved the thread")
        XCTAssertLessThan(longestGap, .milliseconds(250), "Quitting held the main thread while it wrote")
    }
}

// MARK: - Fixture

private let descriptionSamples = (0..<200).map { index in
    ["Run the tests and check the build \(index)", "Search the sources for thing \(index)",
     "Update the README then commit \(index)", "List files in folder \(index)",
     "Build and run the app \(index)"][index % 5]
}

private struct WindowFixture {
    let model: AppModel
    let tasks: [SessionRecord]
    let book: TransportBook
    func transport(_ id: UUID) -> FakeClaudeTransport? { book.transport(for: id) }
}

private final class TransportBook: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [UUID: FakeClaudeTransport] = [:]
    func make(for id: UUID) -> FakeClaudeTransport {
        let transport = FakeClaudeTransport()
        lock.withLock { transports[id] = transport }
        return transport
    }
    func transport(for id: UUID) -> FakeClaudeTransport? { lock.withLock { transports[id] } }
}

@MainActor
private extension XCTestCase {
    func makeWindowFixture(tasks count: Int, transcripts: (any TranscriptRepository)? = nil) async throws -> WindowFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi\n".utf8)
            .write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("WindowObservation")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let book = TransportBook()
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { book.make(for: $0) }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: transcripts ?? FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        var tasks: [SessionRecord] = []
        for index in 0..<count {
            let folder = root.appending(path: "project-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(harness: .claudeCode, workspaceURL: folder,
                                                    runtimeExecutableURL: cli, title: "Task \(index)")
            tasks.append(try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Task did not start"))
        }
        return WindowFixture(model: model, tasks: tasks, book: book)
    }

    /// Streams text into a Claude task and quits before its reading snapshot is written; returns the
    /// task and the main thread's longest gap while quitting.
    func quitWithAWaitingSnapshot(in repository: SlowTranscriptRepository) async throws -> (task: SessionRecord, gap: Duration) {
        let fixture = try await makeWindowFixture(tasks: 1, transcripts: repository)
        let model = fixture.model, task = fixture.tasks[0]
        await model.send(HarnessUserInput(text: "Start"), to: task)
        let transport = try XCTUnwrap(fixture.transport(task.id))
        await transport.emit(json(["type": "stream_event", "session_id": "s", "event": [
            "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Waiting to be saved"]]]))
        try await waitUntil {
            (model.transcriptBySessionID[task.id] ?? []).contains { $0.content == .assistant(text: "Waiting to be saved", isStreaming: true) }
        }
        XCTAssertEqual(repository.saves, 0, "The snapshot waits for the burst to end")

        let lag = MainActorGapProbe()
        await lag.start()
        await model.shutdown()
        return (task, await lag.stop())
    }

    /// A Codex thread whose newest text no checkpoint has written yet, then quitting; returns the
    /// thread's task and the main thread's longest gap while quitting.
    func quitWithACodexThread(in repository: SlowTranscriptRepository) async throws -> (session: SessionRecord, gap: Duration) {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let suite = testDefaultsSuite("WindowObservation.Codex")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter }, transcriptRepository: repository,
            restoresIndexOnLaunch: false)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/quit-codex"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Quit")
        let session = try XCTUnwrap(created)
        func thread(_ text: String) -> CodexTaskState {
            CodexTaskState(thread: CodexTaskDecoder().thread(from: .object([
                "id": .string("quit-thread"), "turns": .array((0..<40).map { index in .object([
                    "id": .string("turn-\(index)"), "status": .string(index == 39 ? "inProgress" : "completed"),
                    "items": .array([
                        .object(["id": .string("user-\(index)"), "type": .string("userMessage"), "content": .array([
                            .object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                        .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                                 "text": .string(index == 39 ? text : "Answer \(index)")])
                    ])
                ]) })
            ])))
        }
        await adapter.emitPresentation(thread("Saved by a checkpoint"), for: session.id)
        try await waitUntil { model.codexPresentationBySessionID[session.id]?.thread?.turns.count == 40 }
        await adapter.emitPresentation(thread("Saved when quitting"), for: session.id)
        try await waitUntil {
            model.codexPresentationBySessionID[session.id]?.thread?.turns.last?.items.contains {
                if case let .agentMessage(message) = $0.content { return message.text == "Saved when quitting" }
                return false
            } == true
        }

        let lag = MainActorGapProbe()
        await lag.start()
        await model.shutdown()
        return (session, await lag.stop())
    }
}

/// How often what `reads` reads changed, re-reading after each change as a view body would.
@MainActor
private final class Invalidations {
    private(set) var count = 0
    private let reads: @MainActor () -> Void
    private var isStopped = false

    init(_ reads: @escaping @MainActor () -> Void) {
        self.reads = reads
        arm()
    }

    func stop() { isStopped = true }

    private func arm() {
        guard !isStopped else { return }
        withObservationTracking { reads() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}

/// The longest the main actor went without running a 5 ms timer.
@MainActor
private final class MainActorGapProbe {
    private var longest = Duration.zero
    private var task: Task<Void, Never>?

    /// Returns once the timer runs.
    func start() async {
        task = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                if let self { self.longest = max(self.longest, now - last) }
                last = now
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func stop() async -> Duration {
        // One more tick, so a hold that ends the measured work is counted.
        try? await Task.sleep(for: .milliseconds(20))
        task?.cancel()
        await task?.value
        return longest
    }
}

/// A transcript store whose writes take `delay` seconds, as a long conversation's do.
private final class SlowTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: [TranscriptEntry]] = [:]
    private var saveCount = 0
    private let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    var saves: Int { lock.withLock { saveCount } }

    func load(for sessionID: UUID) -> [TranscriptEntry] { lock.withLock { entries[sessionID] ?? [] } }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        Thread.sleep(forTimeInterval: delay)
        lock.withLock {
            self.entries[sessionID] = entries
            saveCount += 1
        }
    }

    func remove(for sessionID: UUID) { lock.withLock { entries[sessionID] = nil } }
}

private func json(_ object: [String: Any]) -> JSONValue {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
}
