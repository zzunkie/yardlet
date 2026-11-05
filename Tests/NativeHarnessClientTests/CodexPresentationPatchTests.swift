import Foundation
import XCTest
@testable import NativeHarnessClient

/// Live Codex presentation patches across the YHP boundary must leave the host with exactly the
/// presentation a complete snapshot would have given it.
final class CodexPresentationPatchTests: XCTestCase {
    private let localSessionID = UUID()
    private let codec = HarnessProtocolPayloadCodec()

    func testPatchesRebuildTheSnapshotPresentationAcrossAFixtureStream() throws {
        let steps = Self.fixtureStream()
        var sent: (revision: UInt64, state: CodexTaskState, answerable: [String], unique: Bool)?
        var chain: CodexYHPPresentationChain?
        var nextRevision: UInt64 = 1
        var outcomes: [String] = []
        for (index, step) in steps.enumerated() {
            let state = step.state
            let answerable = Self.answerable(state)
            let expected = CodexYHPProjection.presentation(CodexPresentationWire.snapshot(
                state, localSessionID: localSessionID, answerableServerRequestIDs: answerable
            ))
            var sentSnapshot = true
            if let base = sent, base.unique, var held = chain {
                switch CodexPresentationDiff.outcome(
                    from: base.state, baseAnswerableServerRequestIDs: base.answerable,
                    to: state, answerableServerRequestIDs: answerable,
                    localSessionID: localSessionID, baseRevision: base.revision, revision: nextRevision
                ) {
                case .unchanged:
                    outcomes.append("unchanged")
                    XCTAssertEqual(held.state, expected, "step \(index) \(step.name)")
                    sentSnapshot = false
                case let .patch(patch):
                    outcomes.append("patch")
                    // Across the wire, exactly as the bridge sends it.
                    let decoded = try codec.decode(
                        HarnessProtocolCodexPresentationPatch.self, from: try codec.encode(patch)
                    )
                    XCTAssertEqual(decoded, patch)
                    XCTAssertTrue(CodexYHPProjection.apply(decoded, to: &held), "step \(index) \(step.name)")
                    XCTAssertEqual(held.state, expected, "step \(index) \(step.name)")
                    XCTAssertEqual(held.revision, nextRevision)
                    XCTAssertEqual(
                        held.serverRequestsByID,
                        Dictionary(uniqueKeysWithValues: state.serverRequestsByID.values.map {
                            ($0.id, CodexPresentationWire.serverRequest($0))
                        })
                    )
                    chain = held
                    sent = (nextRevision, state, answerable, true)
                    nextRevision += 1
                    sentSnapshot = false
                case .needsSnapshot:
                    outcomes.append("snapshot")
                }
            } else {
                outcomes.append("snapshot")
            }
            if sentSnapshot {
                var snapshot = CodexPresentationWire.snapshot(
                    state, localSessionID: localSessionID, answerableServerRequestIDs: answerable
                )
                snapshot.revision = nextRevision
                chain = CodexYHPPresentationChain(
                    revision: nextRevision,
                    state: CodexYHPProjection.presentation(snapshot),
                    serverRequestsByID: Dictionary(uniqueKeysWithValues: snapshot.serverRequests.map { ($0.id, $0) })
                )
                sent = (nextRevision, state, answerable, CodexPresentationDiff.hasUniqueIDs(state))
                nextRevision += 1
            }
        }
        XCTAssertEqual(outcomes, steps.map(\.expectedOutcome), "\(zip(steps.map(\.name), outcomes).map { "\($0): \($1)" })")
    }

    func testAPatchAgainstAnotherBaseDoesNotApply() throws {
        let steps = Self.fixtureStream()
        let base = steps[2].state
        let next = steps[3].state
        guard case let .patch(patch) = CodexPresentationDiff.outcome(
            from: base, baseAnswerableServerRequestIDs: [], to: next, answerableServerRequestIDs: [],
            localSessionID: localSessionID, baseRevision: 1, revision: 2
        ) else { return XCTFail("expected a patch") }
        // A host holding an older presentation lacks the item the patch changes.
        var stale = CodexYHPPresentationChain(
            revision: 1,
            state: CodexYHPProjection.presentation(CodexPresentationWire.snapshot(
                steps[1].state, localSessionID: localSessionID, answerableServerRequestIDs: []
            )),
            serverRequestsByID: [:]
        )
        XCTAssertFalse(CodexYHPProjection.apply(patch, to: &stale))
    }

    func testAStreamedDeltaOnALongThreadCarriesOnlyTheChangedItem() throws {
        var state = Self.longThread(turns: 300, itemsPerTurn: 10)
        let base = state
        let snapshotBytes = try JSONEncoder().encode(CodexPresentationWire.snapshot(
            base, localSessionID: localSessionID, answerableServerRequestIDs: []
        )).count
        let last = state.thread!.turns.count - 1
        Self.mutateItem(in: &state, turn: last, item: 2) { item in
            guard case var .commandExecution(command) = item.content else { return XCTFail("command") }
            command.aggregatedOutput = (command.aggregatedOutput ?? "") + "[1/400] Compiling Module1.swift\n"
            item.content = .commandExecution(command)
        }
        state.lastAppliedSequence = (state.lastAppliedSequence ?? 0) + 1
        guard case let .patch(patch) = CodexPresentationDiff.outcome(
            from: base, baseAnswerableServerRequestIDs: [], to: state, answerableServerRequestIDs: [],
            localSessionID: localSessionID, baseRevision: 7, revision: 8
        ) else { return XCTFail("expected a patch") }
        XCTAssertNil(patch.thread?.fields)
        XCTAssertNil(patch.thread?.turnIDs)
        XCTAssertEqual(patch.thread?.turns.map(\.id), [state.thread!.turns[last].id])
        XCTAssertNil(patch.thread?.turns.first?.fields)
        XCTAssertNil(patch.thread?.turns.first?.itemIDs)
        XCTAssertEqual(patch.thread?.turns.first?.items.map(\.id), [state.thread!.turns[last].items[2].id])
        let patchBytes = try JSONEncoder().encode(patch).count
        XCTAssertGreaterThan(snapshotBytes, 1_000_000)
        XCTAssertLessThan(patchBytes, 4_000, "the patch carries one command card, not the thread")
    }

    func testHistoryKeepsOnlyTheNewestSnapshotAndThePatchesAfterIt() {
        var history = HarnessProtocolEventHistory(limit: 10)
        func event(_ sequence: UInt64, _ name: String?) -> HarnessProtocolEventEnvelope {
            HarnessProtocolEventEnvelope(
                localSessionID: localSessionID, sequence: sequence,
                payload: name.map {
                    .extensionEvent(HarnessProtocolExtensionEvent(namespace: "yardlet.codex", name: $0, payload: .object([:])))
                } ?? .assistantDelta(turnID: "t", messageID: "m", text: "a")
            )
        }
        let names: [String?] = ["presentation.updated", "presentation.patched", nil, "presentation.patched",
                                "presentation.updated", "presentation.patched", nil, "presentation.patched"]
        for (sequence, name) in names.enumerated() { history.append(event(UInt64(sequence), name)) }
        XCTAssertEqual(history.events.map(\.payload.extensionEvent?.name), [
            "presentation.superseded", "presentation.superseded", nil, "presentation.superseded",
            "presentation.updated", "presentation.patched", nil, "presentation.patched"
        ])
        // Overflow drops the oldest events and keeps tracking the ones left.
        for sequence in 8..<14 { history.append(event(UInt64(sequence), sequence == 13 ? "presentation.updated" : nil)) }
        XCTAssertEqual(history.events.count, 10)
        XCTAssertEqual(history.events.filter(\.isCodexPresentationPatch).count, 0)
        XCTAssertEqual(history.events.filter(\.isCodexPresentationSnapshot).count, 1)
        XCTAssertEqual(history.events.last?.payload.extensionEvent?.name, "presentation.updated")

        // A long stream of patches keeps a bounded number; the snapshot they need goes with them.
        var streaming = HarnessProtocolEventHistory(limit: 500)
        streaming.append(event(0, "presentation.updated"))
        let limit = HarnessProtocolEventHistory.presentationPatchLimit
        for sequence in 1...limit { streaming.append(event(UInt64(sequence), "presentation.patched")) }
        XCTAssertEqual(streaming.events.filter(\.isCodexPresentationSnapshot).count, 1)
        XCTAssertEqual(streaming.events.filter(\.isCodexPresentationPatch).count, limit)
        for sequence in (limit + 1)...(limit + 10) { streaming.append(event(UInt64(sequence), "presentation.patched")) }
        XCTAssertEqual(streaming.events.filter(\.isCodexPresentationSnapshot).count, 0)
        XCTAssertEqual(streaming.events.filter(\.isCodexPresentationPatch).count, limit)
        XCTAssertEqual(streaming.events.count, limit + 11, "Every event keeps its place in the sequence")
        XCTAssertEqual(streaming.events.last?.sequence, UInt64(limit + 10))
    }

    // MARK: - Fixture

    struct Step {
        let name: String
        let state: CodexTaskState
        let expectedOutcome: String
    }

    /// Turns starting and finishing, items streaming, settling, deleted and reordered, turns
    /// reordered and rolled back, approvals and server requests coming and going, and the cases
    /// that need a complete snapshot.
    static func fixtureStream() -> [Step] {
        var steps: [Step] = []
        var state = CodexTaskState.empty
        func record(_ name: String, _ outcome: String) { steps.append(Step(name: name, state: state, expectedOutcome: outcome)) }

        record("empty", "snapshot")
        state.thread = thread(id: "thread-1", turns: [
            turn("turn-1", status: .completed, items: [user("u1"), command("c1", output: "one\n", done: true), answer("a1", "Done.")]),
            turn("turn-2", status: .completed, items: [user("u2"), reasoning("r2", "Looking"), answer("a2", "Fixed.")])
        ])
        record("thread appears", "snapshot")
        state.thread?.turns.append(turn("turn-3", status: .inProgress, items: [user("u3")]))
        state.lastAppliedSequence = 1
        record("turn starts", "patch")
        mutateTurn(in: &state, turn: 2) { $0.items.append(reasoning("r3", "")) }
        record("reasoning starts", "patch")
        mutateItem(in: &state, turn: 2, item: 1) { $0.content = reasoning("r3", "Reading the module").content }
        state.lastAppliedSequence = 2
        record("reasoning streams", "patch")
        mutateTurn(in: &state, turn: 2) { $0.items.append(command("c3", output: nil, done: false)) }
        state.serverRequestsByID["s1"] = CodexServerRequestState(
            id: "s1", method: "item/commandExecution/requestApproval", kind: .commandExecutionApproval,
            threadID: "thread-1", turnID: "turn-3", itemID: "c3", params: .object(["command": .string("swift build")]),
            resolution: .pending
        )
        state.approvalsByID["s1"] = CodexApprovalState(
            id: "s1", method: "item/commandExecution/requestApproval", threadID: "thread-1",
            turnID: "turn-3", itemID: "c3", resolution: .pending, raw: .object(["id": .string("s1")])
        )
        record("approval requested", "patch")
        record("nothing changed", "unchanged")
        state.serverRequestsByID["s1"]?.resolution = .resolved(.object(["decision": .string("accept")]))
        state.approvalsByID["s1"]?.resolution = .resolved(.object(["decision": .string("accept")]))
        record("approval resolved", "patch")
        for line in ["Compiling\n", "Linking\n"] {
            mutateItem(in: &state, turn: 2, item: 2) { item in
                guard case var .commandExecution(command) = item.content else { return }
                command.aggregatedOutput = (command.aggregatedOutput ?? "") + line
                item.content = .commandExecution(command)
            }
            state.lastAppliedSequence = (state.lastAppliedSequence ?? 0) + 1
            record("command output", "patch")
        }
        mutateItem(in: &state, turn: 2, item: 2) { item in item = command("c3", output: "Compiling\nLinking\n", done: true) }
        mutateTurn(in: &state, turn: 2) { $0.items.append(answer("a3", "Built 한글 👩🏽‍💻")) }
        record("command settles, answer starts", "patch")
        mutateTurn(in: &state, turn: 2) { turn in
            turn.status = .completed
            turn.completedAt = Date(timeIntervalSince1970: 1_800_000_000)
            turn.durationMilliseconds = 4_200
            turn.diff = "diff --git a/A.swift b/A.swift\n"
            turn.plan = CodexPlanState(explanation: "Plan", steps: [CodexPlanStep(id: "p1", text: "Build", status: .completed)])
            turn.tokenUsage = CodexThreadTokenUsage(
                total: CodexTokenUsageBreakdown(inputTokens: 10, cachedInputTokens: 2, cacheWriteInputTokens: 0,
                                                outputTokens: 5, reasoningOutputTokens: 1, totalTokens: 15),
                last: CodexTokenUsageBreakdown(inputTokens: 10, cachedInputTokens: 2, cacheWriteInputTokens: 0,
                                               outputTokens: 5, reasoningOutputTokens: 1, totalTokens: 15),
                modelContextWindow: 200_000
            )
        }
        record("turn completes", "patch")
        state.thread?.name = "Renamed"
        state.thread?.status = .idle
        state.thread?.updatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        record("thread fields change", "patch")
        mutateTurn(in: &state, turn: 0) { $0.items.remove(at: 1) }
        mutateTurn(in: &state, turn: 1) { $0.items.swapAt(0, 2) }
        record("item deleted and items reordered", "patch")
        state.thread?.turns.swapAt(0, 1)
        state.serverRequestsByID.removeValue(forKey: "s1")
        state.approvalsByID.removeValue(forKey: "s1")
        state.serverRequestsByID["s2"] = CodexServerRequestState(
            id: "s2", method: "item/tool/requestUserInput", kind: CodexServerRequestKind(wireName: "toolUserInput"),
            threadID: "thread-1", turnID: "turn-3", itemID: nil, params: nil,
            resolution: .rejected(code: -1, message: "Expired")
        )
        record("turns reordered, requests replaced", "patch")
        state.thread?.turns.removeAll { $0.id == "turn-2" }
        record("turn rolled back", "patch")
        state.thread?.turns.append(turn("turn-4", status: .inProgress, items: [user("dup"), answer("dup", "twice")]))
        record("repeated item IDs", "snapshot")
        state.thread?.turns.removeLast()
        record("after repeated IDs", "snapshot")
        mutateTurn(in: &state, turn: 0) { $0.items.append(answer("a-late", "late")) }
        record("patches again", "patch")
        state.thread = thread(id: "thread-2", turns: [turn("turn-x", status: .completed, items: [answer("ax", "x")])])
        record("thread replaced", "snapshot")
        state.thread = nil
        record("thread gone", "snapshot")
        return steps
    }

    static func longThread(turns: Int, itemsPerTurn: Int) -> CodexTaskState {
        var state = CodexTaskState.empty
        let text = String(repeating: "The module builds and its tests pass. ", count: 40)
        state.thread = thread(id: "long", turns: (0..<turns).map { index in
            turn("turn-\(index)", status: .completed, items: (0..<itemsPerTurn).map { slot in
                slot % 3 == 2 ? command("turn-\(index)-\(slot)", output: text, done: true)
                    : answer("turn-\(index)-\(slot)", text)
            })
        })
        state.lastAppliedSequence = 1
        return state
    }

    static func mutateTurn(in state: inout CodexTaskState, turn index: Int, _ body: (inout CodexTurnState) -> Void) {
        guard var thread = state.thread else { return }
        body(&thread.turns[index])
        state.thread = thread
    }

    static func mutateItem(
        in state: inout CodexTaskState, turn: Int, item: Int, _ body: (inout CodexItemState) -> Void
    ) {
        mutateTurn(in: &state, turn: turn) { body(&$0.items[item]) }
    }

    private static func answerable(_ state: CodexTaskState) -> [String] {
        state.serverRequestsByID.values.filter { $0.resolution == .pending }.map(\.id).sorted()
    }

    private static func thread(id: String, turns: [CodexTurnState]) -> CodexThreadState {
        CodexThreadState(
            id: id, sessionID: nil, name: nil, preview: "Fix the build", workspacePath: "/tmp/workspace",
            cliVersion: "0.160.0", modelProvider: "openai", parentThreadID: nil, forkedFromID: nil,
            status: .active(flags: []), canAcceptDirectInput: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: nil, turns: turns,
            turnsNextCursor: nil, turnsBackwardsCursor: nil, itemsBackwardsCursor: nil,
            raw: .object(["id": .string(id)])
        )
    }

    private static func turn(_ id: String, status: CodexTurnStatus, items: [CodexItemState]) -> CodexTurnState {
        CodexTurnState(
            id: id, status: status, startedAt: Date(timeIntervalSince1970: 1_700_000_100), completedAt: nil,
            durationMilliseconds: nil, itemsView: .full, items: items, itemsNextCursor: nil, plan: nil,
            tokenUsage: nil, error: nil, raw: .object(["id": .string(id), "items": .array([])])
        )
    }

    private static func item(_ value: [String: JSONValue], lifecycle: CodexItemLifecycle) -> CodexItemState {
        CodexTaskDecoder().item(from: .object(value), fallbackID: value["id"]?.stringValue ?? "item", lifecycle: lifecycle)
    }

    private static func user(_ id: String) -> CodexItemState {
        item(["id": .string(id), "type": .string("userMessage"),
              "content": .array([.object(["type": .string("text"), "text": .string("Fix \(id)")])])],
             lifecycle: .completed)
    }

    private static func reasoning(_ id: String, _ text: String) -> CodexItemState {
        item(["id": .string(id), "type": .string("reasoning"),
              "summary": .array(text.isEmpty ? [] : [.string(text)]), "content": .array([])],
             lifecycle: .inProgress)
    }

    private static func answer(_ id: String, _ text: String) -> CodexItemState {
        item(["id": .string(id), "type": .string("agentMessage"), "text": .string(text),
              "phase": .string("final_answer")], lifecycle: .completed)
    }

    private static func command(_ id: String, output: String?, done: Bool) -> CodexItemState {
        item(["id": .string(id), "type": .string("commandExecution"), "command": .string("swift build"),
              "cwd": .string("/tmp/workspace"), "status": .string(done ? "completed" : "inProgress"),
              "aggregatedOutput": output.map(JSONValue.string) ?? .null,
              "exitCode": done ? .integer(0) : .null],
             lifecycle: done ? .completed : .inProgress)
    }
}

/// The product route with live patches against the same route sending complete snapshots, and
/// against the Codex adapter itself, over one provider stream.
final class CodexPresentationPatchRouteTests: XCTestCase {
    private static let threadID = "codex-thread-1"

    func testPatchedRouteEndsEveryPhaseWithTheSnapshotRoutePresentation() async throws {
        let patched = try await PresentationRoute.make(.patches)
        let snapshots = try await PresentationRoute.make(.snapshots)
        let direct = try await PresentationRoute.make(.direct)
        let routes = [patched, snapshots, direct]
        defer { for route in routes { route.collection.cancel() } }

        func everyRoute(_ body: (PresentationRoute) async throws -> Void) async rethrows {
            for route in routes { try await body(route) }
        }
        func emit(_ method: String, _ params: [String: JSONValue]) async {
            var params = params
            params["threadId"] = .string(Self.threadID)
            await everyRoute { await $0.transport.emit(method: method, params: .object(params)) }
        }
        /// Waits until every route shows `reached` and they all agree, as does what each streamed last.
        func settle(_ phase: String, _ reached: @escaping @Sendable (CodexTaskState) -> Bool) async throws {
            try await waitUntil(phase) {
                let states = await routes.asyncMap { try? await $0.adapter.presentationState(for: $0.handle) }
                let latest = await routes.asyncMap { await $0.recorder.states.last }
                return states.allSatisfy { $0.map(reached) == true && $0 == states[0] }
                    && zip(states, latest).allSatisfy { $0 == $1 }
            }
            let state = try await patched.adapter.presentationState(for: patched.handle)
            let snapshot = try await snapshots.adapter.presentationState(for: snapshots.handle)
            XCTAssertEqual(state, snapshot, phase)
        }
        let turn1: [String: JSONValue] = ["turnId": .string("turn-1")]

        try await everyRoute { try await $0.adapter.send("Fix the build", to: $0.handle) }
        await emit("turn/started", ["turn": .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])])
        await emit("item/started", turn1.merging(["item": .object([
            "id": .string("r1"), "type": .string("reasoning"), "summary": .array([]), "content": .array([])
        ])]) { $1 })
        for delta in ["Reading ", "the module"] {
            await emit("item/reasoning/summaryTextDelta", turn1.merging([
                "itemId": .string("r1"), "delta": .string(delta), "summaryIndex": .integer(0)
            ]) { $1 })
        }
        await emit("item/started", turn1.merging(["item": Self.command("c1", status: "inProgress", output: nil)]) { $1 })
        for line in ["Compiling\n", "Linking\n", "한글 👩🏽‍💻\n"] {
            await emit("item/commandExecution/outputDelta", turn1.merging([
                "itemId": .string("c1"), "delta": .string(line)
            ]) { $1 })
        }
        try await settle("turn started, reasoning and command output streamed") {
            Self.output(of: "c1", in: $0) == "Compiling\nLinking\n한글 👩🏽‍💻\n"
        }

        await everyRoute {
            await $0.transport.emitServerRequest(id: .integer(41), method: "item/commandExecution/requestApproval", params: .object([
                "threadId": .string(Self.threadID), "turnId": .string("turn-1"), "itemId": .string("c1"),
                "command": .string("swift build"), "reason": .string("Needs network")
            ]))
        }
        try await settle("approval requested") { $0.serverRequestsByID["i:41"]?.resolution == .pending }
        let pending = try await patched.adapter.presentationState(for: patched.handle)
        XCTAssertEqual(pending.serverRequestsByID["i:41"]?.resolution, .pending)
        let answerable = await (patched.adapter as! YHPCodexCompatibilityAdapter).answerablePendingServerRequestIDs(
            [CodexPendingServerRequest(try XCTUnwrap(pending.serverRequestsByID["i:41"]))], for: patched.handle
        )
        XCTAssertEqual(answerable, ["i:41"], "Answerability crosses a patch too")
        try await everyRoute { try await $0.adapter.respond(to: "i:41", response: .command(.accept), in: $0.handle) }
        try await settle("approval answered") {
            $0.serverRequestsByID["i:41"].map { $0.resolution != .pending } == true
        }

        await emit("item/completed", turn1.merging(["item": Self.command("c1", status: "completed", output: "Compiling\nLinking\n한글 👩🏽‍💻\n")]) { $1 })
        await emit("item/started", turn1.merging(["item": .object([
            "id": .string("a1"), "type": .string("agentMessage"), "text": .string(""), "phase": .string("final_answer")
        ])]) { $1 })
        await emit("item/agentMessage/delta", turn1.merging(["itemId": .string("a1"), "delta": .string("Fixed it.")]) { $1 })
        await emit("turn/plan/updated", turn1.merging(["plan": .array([.object([
            "step": .string("Build"), "status": .string("completed")
        ])])]) { $1 })
        await emit("turn/completed", ["turn": .object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([])])])
        try await settle("turn completed") {
            $0.thread?.turns.first?.status == .completed && Self.text(of: "a1", in: $0) == "Fixed it."
        }

        try await everyRoute { try await $0.adapter.send("And the tests", to: $0.handle) }
        await emit("turn/started", ["turn": .object(["id": .string("turn-2"), "status": .string("inProgress"), "items": .array([])])])
        await emit("item/completed", ["turnId": .string("turn-2"), "item": .object([
            "id": .string("a2"), "type": .string("agentMessage"), "text": .string("Tests pass."), "phase": .string("final_answer")
        ])])
        await emit("turn/completed", ["turn": .object(["id": .string("turn-2"), "status": .string("completed"), "items": .array([])])])
        try await settle("second turn") {
            $0.thread?.turns.count == 2 && $0.thread?.turns.last?.status == .completed
        }

        // The provider's own history: turns in another order and a card it does not keep.
        _ = try await routes.asyncMap { try await $0.adapter.refreshPresentationState(for: $0.handle) }
        try await settle("refreshed from provider history") { $0.thread?.name == "Build fixes" }

        await emit("turn/started", ["turn": .object(["id": .string("turn-3"), "status": .string("inProgress"), "items": .array([])])])
        await emit("item/started", ["turnId": .string("turn-3"), "item": Self.command("c3", status: "inProgress", output: nil)])
        await emit("item/commandExecution/outputDelta", ["turnId": .string("turn-3"), "itemId": .string("c3"), "delta": .string("ok\n")])
        try await settle("streaming after the refresh") { Self.output(of: "c3", in: $0) == "ok\n" }

        let final = try await patched.adapter.presentationState(for: patched.handle)
        let directFinal = try await direct.adapter.presentationState(for: direct.handle)
        XCTAssertEqual(final, directFinal)
        // The refresh moved a turn, dropped the reasoning card, and reordered the cards left.
        XCTAssertEqual(final.thread?.turns.map(\.id), ["turn-2", "turn-1", "turn-3"])
        XCTAssertEqual(final.thread?.turns[1].items.map(\.id), ["a1", "c1"])
        let yhp = try XCTUnwrap(patched.adapter as? YHPCodexCompatibilityAdapter)
        let applied = await yhp.appliedPresentationPatchCount
        XCTAssertGreaterThan(applied, 5, "The patched route must actually patch")
        let resyncs = await yhp.presentationResyncCount
        XCTAssertEqual(resyncs, 0)
        let snapshotOnly = try XCTUnwrap(snapshots.adapter as? YHPCodexCompatibilityAdapter)
        let snapshotPatches = await snapshotOnly.appliedPresentationPatchCount
        XCTAssertEqual(snapshotPatches, 0)
        for route in routes { await route.adapter.close(route.handle) }
    }

    func testASubscriberWhoseReplayLostTheSnapshotReadsItAgain() async throws {
        let route = try await PresentationRoute.make(.patches)
        defer { route.collection.cancel() }
        let yhp = try XCTUnwrap(route.adapter as? YHPCodexCompatibilityAdapter)
        try await route.adapter.send("Run them all", to: route.handle)
        await route.transport.emit(method: "turn/started", params: .object([
            "threadId": .string(Self.threadID),
            "turn": .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])
        ]))
        // More patches than the protocol history keeps, so its replay starts after the snapshot.
        // Waiting for each one keeps the adapter from folding them into fewer updates.
        for index in 0..<700 {
            await route.transport.emit(method: "item/completed", params: .object([
                "threadId": .string(Self.threadID), "turnId": .string("turn-1"),
                "item": Self.command("c\(index)", status: "completed", output: "done \(index)\n")
            ]))
            let deadline = ContinuousClock.now + testWaitLimit
            while await route.recorder.states.last?.thread?.turns.first?.items.count != index + 1,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        try await waitUntil("history streamed") {
            await route.recorder.states.last?.thread?.turns.first?.items.count == 700
        }
        let patchesBefore = await yhp.appliedPresentationPatchCount
        XCTAssertGreaterThan(patchesBefore, 0)

        let again = try await route.adapter.presentationStates(for: route.handle)
        let recorder = StateRecorder()
        let collection = Task { for await state in again { await recorder.append(state) } }
        defer { collection.cancel() }
        try await waitUntil("gap noticed") { await yhp.presentationResyncCount == 1 }
        await route.transport.emit(method: "item/completed", params: .object([
            "threadId": .string(Self.threadID), "turnId": .string("turn-1"),
            "item": Self.command("after-gap", status: "completed", output: "ok\n")
        ]))
        // The complete snapshot comes first; what follows it is patched onto it.
        try await waitUntil("snapshot after the gap") {
            await recorder.states.last?.thread?.turns.first?.items.count == 701
        }
        await route.transport.emit(method: "item/started", params: .object([
            "threadId": .string(Self.threadID), "turnId": .string("turn-1"),
            "item": .object(["id": .string("after-gap-answer"), "type": .string("agentMessage"), "text": .string("")])
        ]))
        await route.transport.emit(method: "item/agentMessage/delta", params: .object([
            "threadId": .string(Self.threadID), "turnId": .string("turn-1"),
            "itemId": .string("after-gap-answer"), "delta": .string("Still streaming")
        ]))
        try await waitUntil("chain restarted") {
            let items = await recorder.states.last?.thread?.turns.first?.items ?? []
            return items.count == 702 && items.last.map {
                if case let .agentMessage(message) = $0.content { return message.text == "Still streaming" }
                return false
            } == true
        }
        let patchesAfter = await yhp.appliedPresentationPatchCount
        XCTAssertGreaterThan(patchesAfter, patchesBefore, "Patches apply again after the complete snapshot")
        let resyncs = await yhp.presentationResyncCount
        XCTAssertEqual(resyncs, 1, "Stale patches before the new snapshot do not ask again")
        await route.adapter.close(route.handle)
    }

    // MARK: - Routes

    private enum RouteKind {
        case patches
        case snapshots
        case direct
    }

    private struct PresentationRoute: Sendable {
        let transport: FakeCodexTransport
        let adapter: any HarnessAdapter & CodexPresentationProviding
        let handle: HarnessSessionHandle
        let recorder: StateRecorder
        let collection: Task<Void, Never>

        static func make(_ kind: RouteKind) async throws -> PresentationRoute {
            let transport = FakeCodexTransport(responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [.object(["thread": .object([
                    "id": .string(threadID), "cwd": .string("/tmp/codex-patches"), "preview": .string(""),
                    "status": .object(["type": .string("idle")]), "turns": .array([])
                ])])],
                "turn/start": [
                    .object(["turn": .object(["id": .string("turn-1")])]),
                    .object(["turn": .object(["id": .string("turn-2")])])
                ],
                "thread/read": [.object(["thread": .object([
                    "id": .string(threadID), "cwd": .string("/tmp/codex-patches"), "preview": .string("Fix the build"),
                    "name": .string("Build fixes"), "status": .object(["type": .string("idle")]),
                    "turns": .array([
                        .object(["id": .string("turn-2"), "status": .string("completed"), "items": .array([
                            .object(["id": .string("a2"), "type": .string("agentMessage"), "text": .string("Tests pass.")])
                        ])]),
                        .object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([
                            .object(["id": .string("a1"), "type": .string("agentMessage"), "text": .string("Fixed it.")]),
                            command("c1", status: "completed", output: "Compiling\nLinking\n한글 👩🏽‍💻\n")
                        ])])
                    ])
                ])])]
            ])
            let codex = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
            let adapter: any HarnessAdapter & CodexPresentationProviding
            switch kind {
            case .direct:
                adapter = codex
            case .patches:
                adapter = YHPCodexCompatibilityAdapter(adapter: codex, manifest: HarnessProtocolCompatibilityManifest.codex())
            case .snapshots:
                let manifest = HarnessProtocolCompatibilityManifest.codex()
                adapter = YHPCodexCompatibilityAdapter(adapter: codex, manifest: HarnessAdapterManifest(
                    adapterID: manifest.adapterID, harness: manifest.harness, displayName: manifest.displayName,
                    protocolVersions: manifest.protocolVersions,
                    capabilities: manifest.capabilities.filter { $0 != .codexPresentationPatches },
                    extensionNamespaces: manifest.extensionNamespaces
                ))
            }
            let handle = try await adapter.createSession(.init(
                localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/codex-patches"), initialPrompt: nil
            ))
            let stream = try await adapter.presentationStates(for: handle)
            let recorder = StateRecorder()
            let collection = Task { for await state in stream { await recorder.append(state) } }
            return PresentationRoute(
                transport: transport, adapter: adapter, handle: handle, recorder: recorder, collection: collection
            )
        }
    }

    private actor StateRecorder {
        private(set) var states: [CodexTaskState] = []
        func append(_ state: CodexTaskState) { states.append(state) }
    }

    private static func item(_ id: String, in state: CodexTaskState) -> CodexItemState? {
        state.thread?.turns.lazy.compactMap { $0.items.first { $0.id == id } }.first
    }

    private static func output(of id: String, in state: CodexTaskState) -> String? {
        guard case let .commandExecution(command) = item(id, in: state)?.content else { return nil }
        return command.aggregatedOutput
    }

    private static func text(of id: String, in state: CodexTaskState) -> String? {
        guard case let .agentMessage(message) = item(id, in: state)?.content else { return nil }
        return message.text
    }

    private static func command(_ id: String, status: String, output: String?) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string("swift build"),
            "cwd": .string("/tmp/codex-patches"), "status": .string(status), "commandActions": .array([]),
            "aggregatedOutput": output.map(JSONValue.string) ?? .null,
            "exitCode": output == nil ? .null : .integer(0)
        ])
    }

    private func waitUntil(
        _ phase: String,
        timeout: Duration = testWaitLimit,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied, phase)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
