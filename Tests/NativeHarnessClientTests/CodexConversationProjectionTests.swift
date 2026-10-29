import Foundation
import XCTest
@testable import NativeHarnessClient

/// What the Codex projection puts where: requests under their
/// turn, a turn's outcome and what it offers, the reading fixture's history match, find, and the
/// cache over a stream of presentation patches. Every step of the reducer and streaming test
/// sequences also goes through the cache (`CodexReducerSteps`).
final class CodexConversationProjectionTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let workspace = URL(filePath: "/tmp/yardlet-codex-projection", directoryHint: .isDirectory)

    #if DEBUG
    /// The reading fixture: 80 turns behind a provider cursor, opened at a history result.
    func testTheReadingFixtureOpensAtItsHistoryResult() {
        var reading = decoder.thread(from: .object(["id": .string("reading-fixture")]))!
        reading.turns = (101...180).map(CodexReadingFixtureView.turn)
        reading.turnsNextCursor = "older-101"
        let selection = CodexHistorySearchSelection(query: "Response 140", snippet: nil, turnID: "turn-140", itemID: "answer-140")
        let presentation = CodexConversationProjection.presentation(
            CodexTaskState(thread: reading), workspaceURL: workspace, historySelection: selection
        )
        XCTAssertEqual(presentation.earlier, .provider(cursor: "older-101"))
        XCTAssertEqual(presentation.turns.count, 80)
        XCTAssertEqual(presentation.turns.flatMap { $0.answers + $0.work + $0.prompt }.filter(\.isHistoryMatch).map(\.id),
                       ["answer-140"])
    }
    #endif

    /// The cache follows every presentation patch step and keeps returning what a fresh projection
    /// makes.
    func testTheCacheFollowsThePresentationPatchSteps() {
        let steps = CodexPresentationPatchTests.fixtureStream()
        XCTAssertGreaterThan(steps.count, 15)
        CodexReducerSteps.assertCacheFollows(steps.map { (step: $0.name, state: $0.state) })
    }

    func testRequestsLandUnderTheirTurn() {
        var state = state([
            turn("turn-1", status: "completed", items: [user("u1", "First"), command("c1", status: "completed", output: "ok\n")]),
            turn("turn-2", status: "inProgress", items: [user("u2", "Second"), command("c2", status: "inProgress", output: nil)])
        ])
        // An approval that is also a server request is drawn once, as the server request.
        state.approvalsByID["shared"] = approval("shared", turnID: "turn-2", itemID: "c2", resolution: .pending)
        state.serverRequestsByID["shared"] = serverRequest("shared", kind: .commandExecutionApproval, turnID: "turn-2",
                                                           itemID: "c2", resolution: .pending)
        state.approvalsByID["alone"] = approval("alone", turnID: "turn-2", itemID: nil, resolution: .pending)
        state.approvalsByID["answered"] = approval("answered", turnID: "turn-1", itemID: "c1",
                                                   resolution: .resolved(.object(["decision": .string("accept")])))
        state.serverRequestsByID["expired"] = serverRequest(
            "expired", kind: .toolUserInput, turnID: "turn-1", itemID: nil,
            resolution: .rejected(code: CodexPendingServerRequest.expiredRuntimeCode, message: "The runtime ended")
        )
        state.serverRequestsByID["refused"] = serverRequest("refused", kind: .mcpElicitation, turnID: "turn-2", itemID: nil,
                                                            resolution: .rejected(code: -1, message: "Unsupported"))
        state.serverRequestsByID["answered-input"] = serverRequest("answered-input", kind: .dynamicToolCall,
                                                                   turnID: "turn-2", itemID: nil, resolution: .resolved(nil))
        // A request without a turn, or for a turn the thread does not hold, is not drawn.
        state.serverRequestsByID["no-turn"] = serverRequest("no-turn", kind: .authenticationRefresh, turnID: nil,
                                                            itemID: nil, resolution: .pending)
        state.approvalsByID["elsewhere"] = approval("elsewhere", turnID: "turn-9", itemID: nil, resolution: .pending)

        let presentation = project(state)
        XCTAssertEqual(presentation.pendingRequestIDs, ["shared", "alone", "elsewhere"])
        // Only waiting requests are pinned under the turn, in one order: by the item each asks
        // about (c2 is the turn's second item), then by ID (D1, M12a).
        XCTAssertEqual(presentation.turns[1].requests.map(\.id), ["shared", "alone"])
        XCTAssertEqual(presentation.turns[1].requests.first { $0.id == "shared" }?.title, L10n.string("Command approval"))
        // Answered ones join the work: after the item they asked about, or at its end.
        func workRequests(_ turn: ConversationTurn) -> [(id: String, request: ConversationRequest)] {
            turn.work.compactMap { item in
                if case let .request(request) = item.kind { return (item.id, request) }
                return nil
            }
        }
        XCTAssertEqual(presentation.turns[0].work.map(\.id), ["c1", "answered", "expired"])
        XCTAssertEqual(presentation.turns[1].work.map(\.id), ["c2", "answered-input", "refused"])
        let answered = workRequests(presentation.turns[0])
        XCTAssertEqual(answered.first { $0.id == "expired" }?.request.state, .expired(message: "The runtime ended"))
        // The answer's own response tells allowed from denied.
        XCTAssertEqual(answered.first { $0.id == "answered" }?.request.state, .allowed)
        XCTAssertEqual(answered.first { $0.id == "answered" }?.request.toolCallID, "c1")
        XCTAssertEqual(workRequests(presentation.turns[1]).first { $0.id == "refused" }?.request.state,
                       .rejected(message: "Unsupported"))
        // The dictionaries' order does not change the turn.
        var reordered = state
        reordered.approvalsByID = Dictionary(uniqueKeysWithValues: state.approvalsByID.reversed().map { ($0.key, $0.value) })
        XCTAssertEqual(project(reordered), presentation)
        // A subagent reads its waiting requests, and the line its card shows, without the turns.
        assertReadAloneAsTheTurnsDraw(state, "requests")
        state.approvalsByID["alone"]?.resolution = .resolved(nil)
        state.serverRequestsByID["shared"]?.resolution = .resolved(nil)
        assertReadAloneAsTheTurnsDraw(state, "requests answered")
        XCTAssertEqual(CodexConversationProjection.pendingRequests(in: state).map(\.id), [])
    }

    /// What a subagent reads on every state it streams (its waiting requests, latest answer and the
    /// line its card shows) is what the full presentation draws, read without projecting the turns.
    func testASubagentsRequestsAnswerAndLineReadAloneAsTheTurnsDrawThem() {
        let sentWhileWorking = JSONValue.object(["id": .string("async"), "type": .string("agentMessage"),
                                      "text": .string("Started on it."), "phase": .string("final_answer"),
                                      "delivery": .string("async")])
        let reasoning = JSONValue.object(["id": .string("r1"), "type": .string("reasoning"),
                                          "summary": .array([.string("Checked")]), "content": .array([])])
        let cases: [(String, [JSONValue], String)] = [
            ("closing answer", [user("u", "Go"), command("c", status: "completed", output: "ok"), answer("a", "Done")], "completed"),
            ("sent while working", [user("u", "Go"), sentWhileWorking, command("c", status: "completed", output: "ok"), answer("a", "Done")], "completed"),
            ("async last", [user("u", "Go"), command("c", status: "completed", output: "ok"), sentWhileWorking], "inProgress"),
            ("went on past it", [user("u", "Go"), answer("a", "First"), command("c", status: "inProgress", output: nil)], "inProgress"),
            ("then notes", [user("u", "Go"), answer("a", "First"), message("m", "Checking", phase: "commentary")], "inProgress"),
            ("reasoning and plan after", [user("u", "Go"), answer("a", "Done"), reasoning, plan("p", "# Plan")], "completed"),
            ("plan before", [user("u", "Go"), plan("p", "# Plan"), command("c", status: "completed", output: "ok")], "completed"),
            ("steered", [user("u", "Go"), answer("a", "First"), user("s", "Also this")], "inProgress"),
            ("empty answer", [user("u", "Go"), answer("a0", "Earlier"), answer("a", "")], "inProgress"),
            ("no answer", [user("u", "Go"), command("c", status: "failed", output: "boom")], "failed"),
            ("interrupted", [user("u", "Go"), answer("a", "Partial"), command("c", status: "inProgress", output: nil)], "interrupted"),
            ("request only", [user("u", "Go")], "inProgress")
        ]
        for (name, items, status) in cases {
            var state = state([turn("turn-1", status: "completed", items: [user("u0", "Before"), answer("a-old", "Old")]),
                               turn("turn-2", status: status, items: items)])
            assertReadAloneAsTheTurnsDraw(state, name)
            state.approvalsByID["waiting"] = approval("waiting", turnID: "turn-2", itemID: "c", resolution: .pending)
            state.approvalsByID["earlier"] = approval("earlier", turnID: "turn-1", itemID: nil, resolution: .pending)
            state.approvalsByID["done"] = approval("done", turnID: "turn-2", itemID: "c", resolution: .resolved(nil))
            assertReadAloneAsTheTurnsDraw(state, name + " with requests")
        }
        for step in CodexPresentationPatchTests.fixtureStream() {
            assertReadAloneAsTheTurnsDraw(step.state, step.name)
        }
    }

    /// A subagent reads its own Codex thread's requests and answer, named for it, and its
    /// conversation's transcript until the thread has a turn.
    @MainActor
    func testASubagentReadsItsTranscriptUntilItsThreadHasATurn() {
        let host = UUID()
        let run = AgentRun(callerID: host, hostTaskID: host, harness: .codex, prompt: "Check the build",
                           workspaceURL: workspace, depth: 1)
        var builder = TranscriptBuilder()
        builder.appendUser("Check the build")
        builder.apply(.assistantMessageCompleted("Looking."))
        builder.apply(.permissionRequested(PermissionRequest(id: "perm", title: "Run tests", detail: nil, command: "swift test")))
        run.entries = builder.entries
        run.codexState = state([])
        XCTAssertEqual(run.pendingRequests.map(\.id), ["perm"])
        XCTAssertEqual(run.pendingRequests.first?.title, L10n.format("%@: %@", run.name, "Run tests"))
        XCTAssertEqual(run.latestAnswer, AppModel.latestAnswer(in: run.presentation()))

        var thread = state([turn("turn-1", status: "inProgress", items: [user("u", "Check the build"), answer("a", "Built.")])])
        thread.approvalsByID["waiting"] = approval("waiting", turnID: "turn-1", itemID: nil, resolution: .pending)
        run.codexState = thread
        XCTAssertEqual(run.pendingRequests.map(\.id), ["waiting"])
        XCTAssertEqual(run.pendingRequests.first?.title, L10n.format("%@: %@", run.name, CodexApprovalState.cardTitle))
        XCTAssertEqual(run.latestAnswer, "Built.")
        XCTAssertEqual(run.progressLine, "Built.")
    }

    /// A failed latest turn the server was too busy for, on an idle thread, offers retry and edit,
    /// and reads as the error card.
    func testAServerBusyTurnOffersRetryAndEdit() {
        var busy = state([
            turn("turn-1", status: "completed", durationMs: 2_000, items: [user("u1", "First"), answer("a1", "Done")]),
            turn("turn-2", status: "failed", items: [user("u2", "Second")], error: .object([
                "message": .string("Server is overloaded"), "codexErrorInfo": .string("serverOverloaded")
            ]))
        ])
        busy.thread?.status = .idle
        let busyTurn = project(busy).turns[1]
        XCTAssertTrue(busyTurn.actions.canRetry)
        XCTAssertTrue(busyTurn.actions.canEdit)
        XCTAssertNotNil(busyTurn.actions.failedRequestDraft)
        XCTAssertEqual(busyTurn.outcome, .error(ConversationTurnError(
            title: L10n.string("Server is busy."), message: TranscriptRecoveryProjection.codexErrorDetails(busy.thread?.turns[1].error) ?? "",
            isRecoverable: true
        )))
    }

    /// Find reads a Codex message as the conversation draws it, its directives included.
    func testFindReadsCodexMessagesWithTheirDirectives() {
        let states = CodexPresentationPatchTests.fixtureStream().map(\.state) + [
            state([
                turn("turn-1", status: "completed", items: [
                    user("u1", "Find the title bar"), message("m1", "Looking at the title bar", phase: "commentary"),
                    answer("a1", "The title bar is fixed."), plan("p1", "# Title bar plan")
                ])
            ])
        ]
        for (index, state) in states.enumerated() {
            let units = ConversationFindSource.conversation(project(state)).units
            XCTAssertFalse(units.contains { if case .markdown(_, .standard) = $0.body { true } else { false } }, "state \(index)")
        }
        let units = ConversationFindSource.conversation(project(states.last!)).units
        XCTAssertEqual(units.map(\.id), ["u1", "m1", "a1"])
        XCTAssertEqual(units.map(\.revealID), [nil, "turn-1", nil])
    }

    // MARK: - Fixtures

    private func assertReadAloneAsTheTurnsDraw(
        _ state: CodexTaskState, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let presentation = project(state)
        XCTAssertEqual(CodexConversationProjection.pendingRequests(in: state), presentation.turns.flatMap(\.requests),
                       step, file: file, line: line)
        XCTAssertEqual(CodexConversationProjection.latestAnswer(in: state, workspaceURL: workspace),
                       presentation.turns.last.flatMap { ConversationTurnLayout.latestAnswer(answers: $0.answers, work: $0.work) },
                       step, file: file, line: line)
        let last = presentation.turns.last.flatMap { ($0.work + $0.answers).last }
        let read = CodexConversationProjection.lastItem(in: state, workspaceURL: workspace)
        XCTAssertEqual(read?.id, last?.id, step, file: file, line: line)
        XCTAssertEqual(read?.kind, last?.kind, step, file: file, line: line)
    }

    private func project(_ state: CodexTaskState) -> ConversationPresentation {
        CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
    }

    private func state(_ turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-qa")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }

    private func turn(
        _ id: String, status: String, durationMs: Int64? = nil, items: [JSONValue], error: JSONValue? = nil
    ) -> CodexTurnState {
        var value: [String: JSONValue] = ["id": .string(id), "status": .string(status), "items": .array(items)]
        if let durationMs { value["durationMs"] = .integer(durationMs) }
        if let error { value["error"] = error }
        return decoder.turn(from: .object(value), fallbackID: id)!
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func answer(_ id: String, _ text: String) -> JSONValue {
        message(id, text, phase: "final_answer")
    }

    private func message(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }

    private func plan(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("plan"), "text": .string(text)])
    }

    private func command(_ id: String, status: String, output: String?) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string("swift test"),
            "cwd": .string(workspace.path(percentEncoded: false)), "status": .string(status),
            "commandActions": .array([]), "aggregatedOutput": output.map(JSONValue.string) ?? .null, "exitCode": .null
        ])
    }

    private func approval(
        _ id: String, turnID: String?, itemID: String?, resolution: CodexApprovalResolution
    ) -> CodexApprovalState {
        CodexApprovalState(id: id, method: "item/commandExecution/requestApproval", threadID: "thread-qa",
                           turnID: turnID, itemID: itemID, resolution: resolution, raw: .object(["reason": .string(id)]))
    }

    private func serverRequest(
        _ id: String, kind: CodexServerRequestKind, turnID: String?, itemID: String?,
        resolution: CodexServerRequestResolution
    ) -> CodexServerRequestState {
        CodexServerRequestState(id: id, method: kind.wireName, kind: kind, threadID: "thread-qa", turnID: turnID,
                                itemID: itemID, params: .object(["message": .string(id)]), resolution: resolution)
    }
}
