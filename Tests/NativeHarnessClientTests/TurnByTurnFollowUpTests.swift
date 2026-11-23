import Foundation
import XCTest
@testable import NativeHarnessClient

/// A harness that takes one message per turn and nothing while it runs (Antigravity's `agy`, which
/// Yardlet runs a process per turn): a message sent meanwhile waits in Yardlet's follow-up queue,
/// said as "Send when this turn ends", and starts the next turn when this one ends. Nothing reaches
/// the runtime while its turn runs, so nothing can stop or cut it short. The runtime is a fake;
/// no model is asked anything.
@MainActor final class TurnByTurnFollowUpTests: XCTestCase {
    func testAntigravityHoldsAMessageSentWhileItsTurnRunsAndSendsItWhenTheTurnEnds() async throws {
        let adapter = TurnRecordingAdapter()
        let root = FileManager.default.temporaryDirectory.appending(path: "turn-by-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TurnByTurnFollowUps")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .antigravityCLI, workspaceURL: root,
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Turns")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        await model.send(HarnessUserInput(text: "Build the site"), to: task)
        await adapter.emit(.sessionStatusChanged(.running))
        try await waitUntil { model.store.sessions.first?.status == .running }

        // Return while the turn runs, whatever the follow-up setting says: held for the next turn.
        defaults.set(FollowUpMode.steer.rawValue, forKey: FollowUpMode.preferenceKey)
        await model.send(HarnessUserInput(text: "Then deploy it"), to: task)
        await model.submitFollowUp(HarnessUserInput(text: "And post the link"), action: .steer, to: task)
        let held = model.followUps.queue(for: task.id)
        XCTAssertEqual(held.map(\.draft.text), ["Then deploy it", "And post the link"])
        XCTAssertEqual(held.map(\.state), [.pending, .pending])
        let sentWhileRunning = await adapter.sent
        XCTAssertEqual(sentWhileRunning.count, 1, "Nothing reaches the runtime while its turn runs")
        let interrupts = await adapter.interrupts
        XCTAssertEqual(interrupts, 0, "Nothing stops the turn")
        XCTAssertFalse(userLines(model, task).contains("Then deploy it"), "No sent bubble before it goes")

        // The chip's send cannot cut in either; the message goes when the turn ends.
        await model.sendQueuedNow(held[0].id, for: task)
        let sentAfterChip = await adapter.sent
        XCTAssertEqual(sentAfterChip.count, 1)

        await adapter.emit(.assistantMessageCompleted("Built."))
        await adapter.emit(.turnCompleted)
        await adapter.emit(.sessionStatusChanged(.ready))
        try await waitUntil { await adapter.sent.count == 2 }
        let next = await adapter.sent.last
        XCTAssertEqual(next, "Then deploy it")
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text), ["And post the link"])
        try await waitUntil { self.userLines(model, task).last == "Then deploy it" }

        await adapter.emit(.sessionStatusChanged(.running))
        await adapter.emit(.assistantMessageCompleted("Deployed."))
        await adapter.emit(.turnCompleted)
        await adapter.emit(.sessionStatusChanged(.ready))
        try await waitUntil { await adapter.sent.count == 3 }
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
        XCTAssertEqual(userLines(model, task), ["Build the site", "Then deploy it", "And post the link"])
    }

    func testStopAndSendInterruptsTurnMovesChosenItemFirstAndStartsItWhenReady() async throws {
        let adapter = TurnRecordingAdapter()
        let root = FileManager.default.temporaryDirectory.appending(path: "turn-by-turn-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TurnByTurnStopAndSend")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .antigravityCLI, workspaceURL: root,
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "StopAndSend")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        await model.send(HarnessUserInput(text: "Build the site"), to: task)
        await adapter.emit(.sessionStatusChanged(.running))
        try await waitUntil { model.store.sessions.first?.status == .running }

        await model.send(HarnessUserInput(text: "Then deploy it"), to: task)
        await model.send(HarnessUserInput(text: "Fix the broken test first"), to: task)
        let held = model.followUps.queue(for: task.id)
        XCTAssertEqual(held.map(\.draft.text), ["Then deploy it", "Fix the broken test first"])

        // Stop and send on the second item interrupts the running turn, moves it first, and leaves the queue running.
        await model.stopAndSendQueued(held[1].id, for: task)
        let interruptCount = await adapter.interrupts
        XCTAssertEqual(interruptCount, 1)
        XCTAssertFalse(model.followUps.isPaused(task.id))
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text),
                       ["Fix the broken test first", "Then deploy it"])
        let sentBeforeReady = await adapter.sent
        XCTAssertEqual(sentBeforeReady, ["Build the site"], "Waits until the cancelled turn finishes")

        await adapter.emit(.turnCompleted)
        await adapter.emit(.sessionStatusChanged(.ready))
        try await waitUntil { await adapter.sent.count == 2 }
        let sentAfterReady = await adapter.sent
        XCTAssertEqual(sentAfterReady, ["Build the site", "Fix the broken test first"])
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text), ["Then deploy it"])

        await adapter.emit(.sessionStatusChanged(.running))
        await adapter.emit(.turnCompleted)
        await adapter.emit(.sessionStatusChanged(.ready))
        try await waitUntil { await adapter.sent.count == 3 }
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
        XCTAssertEqual(userLines(model, task), ["Build the site", "Fix the broken test first", "Then deploy it"])
    }

    func testStopAndSendDrainsEvenWhenTurnReportsReadyBeforeInterruptReturns() async throws {
        let adapter = TurnRecordingAdapter(emitReadyOnInterrupt: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "turn-by-turn-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TurnByTurnStopAndSendSync")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .antigravityCLI, workspaceURL: root,
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "StopSync")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        await model.send(HarnessUserInput(text: "First"), to: task)
        await adapter.emit(.sessionStatusChanged(.running))
        try await waitUntil { model.store.sessions.first?.status == .running }

        await model.send(HarnessUserInput(text: "Urgent"), to: task)
        let item = try XCTUnwrap(model.followUps.queue(for: task.id).first)

        await model.stopAndSendQueued(item.id, for: task)
        try await waitUntil { await adapter.sent.count == 2 }
        let sent = await adapter.sent
        XCTAssertEqual(sent, ["First", "Urgent"])
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
    }

    func testConcurrentStopAndSendDoesNotFireDuplicateInterrupts() async throws {
        let adapter = TurnRecordingAdapter(suspendInterrupt: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "turn-by-turn-conc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TurnByTurnStopAndSendConcurrent")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .antigravityCLI, workspaceURL: root,
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "StopConc")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        await model.send(HarnessUserInput(text: "Initial"), to: task)
        await adapter.emit(.sessionStatusChanged(.running))
        try await waitUntil { model.store.sessions.first?.status == .running }

        await model.send(HarnessUserInput(text: "First queued"), to: task)
        await model.send(HarnessUserInput(text: "Second queued"), to: task)
        let held = model.followUps.queue(for: task.id)

        let firstCall = Task { await model.stopAndSendQueued(held[0].id, for: task) }
        try await waitUntil { await adapter.interrupts == 1 }
        // A second Stop and send while the first interrupt is in flight is ignored instead of firing a second interrupt.
        await model.stopAndSendQueued(held[1].id, for: task)
        let interruptsDuringFlight = await adapter.interrupts
        XCTAssertEqual(interruptsDuringFlight, 1)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text), ["First queued", "Second queued"])

        await adapter.resumeInterrupt()
        await firstCall.value
        await adapter.emit(.turnCompleted)
        await adapter.emit(.sessionStatusChanged(.ready))
        try await waitUntil { await adapter.sent.count == 2 }
        let sent = await adapter.sent
        XCTAssertEqual(sent, ["Initial", "First queued"])
    }

    private func userLines(_ model: AppModel, _ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            if case let .user(text, _) = entry.content { return text }
            return nil
        }
    }
}

/// An Antigravity runtime that records what it is sent and reports what the test tells it to.
private actor TurnRecordingAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.antigravityCLI
    private let emitReadyOnInterrupt: Bool
    private let suspendInterrupt: Bool
    private var interruptGate: CheckedContinuation<Void, Never>?
    private(set) var sent: [String] = []
    private(set) var interrupts = 0
    private var session: HarnessSessionHandle?
    private var continuation: AsyncStream<HarnessEventEnvelope>.Continuation?
    private var sequence: UInt64 = 0

    init(emitReadyOnInterrupt: Bool = false, suspendInterrupt: Bool = false) {
        self.emitReadyOnInterrupt = emitReadyOnInterrupt
        self.suspendInterrupt = suspendInterrupt
    }

    func resumeInterrupt() {
        interruptGate?.resume()
        interruptGate = nil
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/usr/bin/true"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let handle = HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                          providerSessionID: request.localSessionID.uuidString,
                                          workspaceURL: request.workspaceURL)
        session = handle
        return handle
    }

    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
        -> HarnessSessionHandle {
        try await createSession(CreateHarnessSessionRequest(localSessionID: localSessionID, workspaceURL: workspaceURL,
                                                            initialPrompt: nil))
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { sent.append(prompt) }
    func interrupt(_ session: HarnessSessionHandle) async throws {
        interrupts += 1
        if suspendInterrupt {
            await withCheckedContinuation { interruptGate = $0 }
        }
        if emitReadyOnInterrupt {
            emit(.turnCompleted)
            emit(.sessionStatusChanged(.ready))
        }
    }
    func respond(to permissionRequestID: String, decision: PermissionDecision,
                 in session: HarnessSessionHandle) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = AsyncStream<HarnessEventEnvelope>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func close(_ session: HarnessSessionHandle) async {}

    func emit(_ payload: HarnessEventPayload) {
        guard let session else { return }
        sequence += 1
        continuation?.yield(HarnessEventEnvelope(localSessionID: session.localSessionID, sequence: sequence,
                                                 payload: payload))
    }
}
