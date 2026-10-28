import Foundation
import XCTest
@testable import NativeHarnessClient

/// What the common-transcript projection puts where.
final class TranscriptConversationProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A turn that is over folds its settled work under its last message, which is its answer. A
    /// turn still going has no answer and does not fold, and a request still waiting holds a finished
    /// turn open under its own card.
    func testACompletedTurnFoldsItsWorkUnderItsAnswer() {
        let request = entry(0, .user(text: "Check it"))
        let commentary = entry(1, .assistant(text: "I will inspect it.", isStreaming: false))
        let read = entry(2, .activity(HarnessActivity(id: "read-1", kind: "read", title: "Read file", detail: nil),
                                      state: .completed))
        let final = entry(3, .assistant(text: "It works.", isStreaming: false))
        // A background subagent's own task that starts after the answer is a row above the composer,
        // not the turn's last word (2026-10-24: the final report folded into the work as a note).
        let subagentTask = entry(4, .activity(HarnessActivity(id: "toolu_sub", kind: "Task", title: "Run the tests",
            isBackground: true, subtask: HarnessSubtaskReference(taskID: "b1", taskType: "local_bash", ownedBySubagent: true)),
            state: .running))
        let done = project([request, commentary, read, final, subagentTask], latestTurnIsComplete: true).turns[0]
        XCTAssertEqual(done.work.map(\.id), [commentary.id.uuidString, read.id.uuidString])
        XCTAssertEqual(done.answers.map(\.id), [final.id.uuidString])
        XCTAssertTrue(done.foldsWork)
        XCTAssertEqual(done.timing.completedAt, final.createdAt, "the subagent's task is no part of the turn's time")

        let going = project([request, commentary]).turns[0]
        XCTAssertEqual(going.answers, [], "a turn still going has no answer")
        XCTAssertEqual(going.work.map(\.kind), [.commentary(text: "I will inspect it.", isStreaming: false)])
        XCTAssertFalse(going.foldsWork)

        let permission = entry(4, .permission(PermissionRequest(id: "permission", title: "Run", detail: nil,
                                                                command: "pwd"), state: .pending))
        let waiting = entry(5, .assistant(text: "Waiting for you.", isStreaming: false))
        let held = project([request, permission, waiting], status: .waitingForApproval, latestTurnIsComplete: true).turns[0]
        XCTAssertEqual(held.requests.map(\.id), ["permission"])
        XCTAssertEqual(held.answers.map(\.id), [waiting.id.uuidString])
        XCTAssertTrue(held.work.isEmpty, "a waiting request is pinned under the turn, not folded with its work")
    }

    /// A message read into a running turn after Claude answered the one before it: that answer is not
    /// the turn's last words, but it is an answer, and it stays in view when the work folds (2026-10-22:
    /// a reply was hidden when messages followed one another). The message folds once the turn's answer
    /// follows it, as the Codex app 26.1016 folds a steered message (2026-10-23, one rule for every
    /// harness). Words followed by a call are progress and fold as before.
    func testTheAnswerBeforeAMessageReadIntoTheTurnStaysInView() {
        let request = entry(0, .user(text: "Fix the build", images: nil))
        let note = entry(1, .assistant(text: "Looking at the log.", isStreaming: false))
        let call = entry(2, .activity(HarnessActivity(id: "c1", kind: "Bash", title: "swift build"), state: .completed))
        let firstAnswer = entry(3, .assistant(text: "Fixed: the import was missing.", isStreaming: false))
        var readIn = entry(4, .user(text: "Also run the tests", images: nil))
        readIn.joinsRunningTurn = true
        let call2 = entry(5, .activity(HarnessActivity(id: "c2", kind: "Bash", title: "swift test"), state: .completed))
        let finalAnswer = entry(6, .assistant(text: "All tests pass.", isStreaming: false))
        let turn = project([request, note, call, firstAnswer, readIn, call2, finalAnswer], latestTurnIsComplete: true).turns[0]

        XCTAssertEqual(turn.answers.map(\.id), [finalAnswer.id.uuidString])
        XCTAssertTrue(turn.foldsWork)
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.kind), [.answer(text: "Fixed: the import was missing.", isStreaming: false)])
        XCTAssertTrue(turn.work.contains { $0.kind == .commentary(text: "Looking at the log.", isStreaming: false) },
                      "progress before a call still folds")
    }

    func testRequestsStartTurnsAndWhatComesFirstIsTheHeadTurn() {
        let context = entry(0, .compaction(.init(phase: .completed, tokensBefore: 10, tokensAfter: 4)))
        let early = entry(1, .assistant(text: "Earlier context", isStreaming: false))
        let request = entry(2, .user(text: "Look", images: [TranscriptImageAttachment(url: nil, name: "a.png")]))
        let answer = entry(3, .assistant(text: "Seen.", isStreaming: false))
        let turns = project([context, early, request, answer], latestTurnIsComplete: true).turns

        XCTAssertEqual(turns.map(\.id), [context.id.uuidString, request.id.uuidString])
        XCTAssertEqual(turns[0].prompt, [])
        // A head turn a later turn follows has ended, and what it ended with is its answer: the end of
        // a turn a read began inside, its final report (a real task's lost reports).
        XCTAssertEqual(turns[0].work.map(\.kind), [.compaction(.init(phase: .completed, tokensBefore: 10, tokensAfter: 4))])
        XCTAssertEqual(turns[0].answers.map(\.kind), [.answer(text: "Earlier context", isStreaming: false)])
        let alone = project([context, early], latestTurnIsComplete: true).turns
        XCTAssertEqual(alone.first?.answers, [], "A head turn with nothing after it has no answer to give")
        XCTAssertEqual(turns[0].status, .completed)
        XCTAssertEqual(turns[1].prompt.map(\.kind), [
            .userMessage(text: "Look", images: [TranscriptImageAttachment(url: nil, name: "a.png")])
        ])
        XCTAssertEqual(turns[1].answers.map(\.kind), [.answer(text: "Seen.", isStreaming: false)])
        XCTAssertEqual(turns[1].answers.first?.source, .transcript(answer))
    }

    func testABashRequestIsACommandOnlyInClaude() {
        let text = ClaudeBashMessage.text(command: "ls", stdout: "a")
        let request = entry(0, .user(text: text))
        let claude = project([request], harness: .claudeCode).turns[0].prompt.map(\.kind)
        XCTAssertEqual(claude, [.shellCommand(ClaudeBashMessage.parse(text)!, entryID: request.id)])
        let other = project([request], harness: .openCode).turns[0].prompt.map(\.kind)
        XCTAssertEqual(other, [.userMessage(text: text, images: [])])
    }

    func testRunningTurnHasNoAnswerAndCommentaryIsWork() {
        let request = entry(0, .user(text: "Go"))
        let said = entry(1, .assistant(text: "Looking.", isStreaming: false))
        let thought = entry(2, .reasoning(text: "Maybe", isStreaming: true))
        let turn = project([request, said, thought], status: .running).turns[0]
        XCTAssertEqual(turn.answers, [])
        XCTAssertEqual(turn.work.map(\.kind), [
            .commentary(text: "Looking.", isStreaming: false),
            .reasoning(summary: nil, detail: "Maybe", isStreaming: true)
        ])
        XCTAssertEqual(turn.work.map(\.phase), [.completed, .running])
        XCTAssertEqual(turn.status, .running)
        XCTAssertFalse(turn.foldsWork)
    }

    func testAllowedRequestBecomesTheMarkOnItsToolOrSubtask() {
        let request = entry(0, .user(text: "Go"))
        let call = entry(1, .activity(HarnessActivity(
            id: "call", kind: "Edit", title: "Edit README", input: "README.md", output: "ok",
            diff: HarnessActivityDiff(path: "README.md", oldText: "a", newText: "b"), isBackground: true
        ), state: .completed))
        let allowed = entry(2, .permission(PermissionRequest(id: "r1", title: "Edit", detail: nil, command: nil,
                                                             toolCallID: "call"), state: .allowed))
        let agent = HarnessSubtaskReference(taskID: "t1", toolUseID: "agent", taskType: "local_agent")
        let subtask = entry(3, .activity(HarnessActivity(id: "agent", kind: "Agent", title: "Review", output: "Fine.",
                                                         subtask: agent), state: .completed))
        let other = entry(4, .permission(PermissionRequest(id: "r2", title: "Other", detail: nil, command: nil,
                                                           toolCallID: "elsewhere"), state: .allowed))
        let answer = entry(5, .assistant(text: "Done.", isStreaming: false))
        let turn = project([request, call, allowed, subtask, other, answer], latestTurnIsComplete: true).turns[0]

        XCTAssertEqual(turn.work.map(\.id), [call.id.uuidString, subtask.id.uuidString, other.id.uuidString])
        // A call that reports its file change is the file change card (M12b).
        XCTAssertEqual(turn.work[0].kind, .fileChange(ConversationFileChange(
            rows: [ConversationFileChangeProjection.row(
                for: HarnessActivityDiff(path: "README.md", oldText: "a", newText: "b"), phase: .completed, workspaceURL: nil
            )],
            handoffs: [], isApproved: true, placesRowsInWorkspace: true
        )))
        XCTAssertEqual(turn.work[1].kind, .subagent(ConversationSubagent(
            title: "Review", status: nil, detail: nil, routes: [.harnessSubtask(agent, activityID: "agent")], isApproved: false,
            kind: "Agent", output: "Fine."
        )))
        guard case let .request(kept) = turn.work[2].kind else { return XCTFail("The unmatched request keeps its card") }
        XCTAssertEqual(kept.state, .allowed)
        XCTAssertTrue(turn.foldsWork)
        XCTAssertTrue(turn.hasWorkDetails)
        XCTAssertTrue(turn.showsHeader, "The folded work's \"Work details\" control")
    }

    func testPendingRequestsAreHeldAndAnsweredOnesStayInTheWork() {
        let request = entry(0, .user(text: "Go"))
        let plain = PermissionRequest(id: "plain", title: "Run", detail: "why", command: "pwd", toolCallID: "t")
        let options = PermissionRequest(id: "options", title: "Run", detail: nil, command: nil, actions: [
            PermissionRequestAction(id: "allow-always", label: "Always allow", decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "reject", label: "Reject", decision: .deny, kind: "reject_once"),
            PermissionRequestAction(id: "allow-once", label: "Allow once", decision: .allow, kind: "allow_once")
        ])
        let question = PermissionQuestion(question: "Which?", options: [.init(label: "A")])
        let asked = PermissionRequest(id: "asked", title: "Question", detail: nil, command: nil,
                                      structured: .questions([question]))
        let plan = PermissionRequest(id: "plan", title: "Plan", detail: nil, command: nil, structured: .plan("# Plan"))
        let entries = [
            request,
            entry(1, .permission(asked, state: .allowed)),
            entry(2, .permission(plain, state: .expired)),
            entry(3, .permission(plain, state: .pending)),
            entry(4, .permission(options, state: .pending)),
            entry(5, .permission(asked, state: .pending)),
            entry(6, .permission(plan, state: .pending))
        ]
        let presentation = project(entries, status: .waitingForApproval)
        let turn = presentation.turns[0]

        XCTAssertEqual(presentation.pendingRequestIDs, ["plain", "options", "asked", "plan"])
        XCTAssertEqual(turn.requests.map(\.id), ["plain", "options", "asked", "plan"])
        XCTAssertEqual(turn.requests.map(\.state), [.pending, .pending, .pending, .pending])
        XCTAssertEqual(turn.requests[0].detail, "why")
        XCTAssertEqual(turn.requests[0].toolCallID, "t")
        XCTAssertEqual(turn.requests[0].source, .transcript(entries[3]))
        XCTAssertEqual(turn.requests[0].responses.map(\.route), [.decision(.deny), .decision(.allow)])
        XCTAssertEqual(turn.requests[0].responses.map(\.role), [.destructive, .primary])
        // The provider's own options: denials first, the narrowest allow prominent.
        XCTAssertEqual(turn.requests[1].responses.map(\.title), ["Reject", "Always allow", "Allow once"])
        XCTAssertEqual(turn.requests[1].responses.map(\.role), [.destructive, .secondary, .primary])
        XCTAssertEqual(turn.requests[2].form, .choices([question]))
        XCTAssertEqual(turn.requests[2].responses.map(\.route), [.structured])
        XCTAssertEqual(turn.requests[3].form, .planReview("# Plan"))
        XCTAssertEqual(turn.requests[3].responses.map(\.route), [.structured, .decision(.allow)])

        XCTAssertEqual(turn.work.map(\.phase), [.completed, .stopped])
        let resolved = turn.work.compactMap { item -> ConversationRequest? in
            if case let .request(request) = item.kind { return request }
            return nil
        }
        XCTAssertEqual(resolved.map(\.state), [.answered, .expired(message: nil)])
        XCTAssertEqual(resolved.map(\.responses), [[], []])
    }

    func testTheLastErrorOrLimitIsTheOutcomeAndEarlierOnesStayWhereTheyHappened() {
        let request = entry(0, .user(text: "Go"))
        let blip = entry(1, .error(message: "blip", recoverable: true))
        let partial = entry(2, .assistant(text: "Partial", isStreaming: false))
        let failure = entry(3, .error(message: "{\"error\":{\"message\":\"Upstream gone\"}}", recoverable: false))
        let turn = project([request, blip, partial, failure], latestTurnIsComplete: true).turns[0]

        XCTAssertEqual(turn.outcome, .error(ConversationTurnError(
            title: nil, message: "{\"error\":{\"message\":\"Upstream gone\"}}", isRecoverable: false, entryID: failure.id
        )))
        guard case let .error(error)? = turn.outcome else { return XCTFail("The last error is the outcome") }
        XCTAssertEqual(error.summary, "Upstream gone")
        XCTAssertEqual(turn.work.map(\.kind), [
            .outcome(.error(ConversationTurnError(title: nil, message: "blip", isRecoverable: true, entryID: blip.id))),
            .commentary(text: "Partial", isStreaming: false)
        ])
        XCTAssertEqual(turn.work.map(\.phase), [.failed, .completed])
        XCTAssertEqual(turn.status, .failed)

        // Retry is offered only for an error its provider called transient, ending the latest turn while
        // the task is idle.
        XCTAssertFalse(turn.actions.canRetry)
        let busy = entry(3, .error(message: "API Error: 529 Overloaded", recoverable: true, transient: true))
        XCTAssertTrue(project([request, partial, busy], status: .failed).turns[0].actions.canRetry)
        XCTAssertFalse(project([request, partial, busy], status: .running).turns[0].actions.canRetry)
        XCTAssertFalse(project([request, busy, entry(4, .user(text: "Again"))]).turns[0].actions.canRetry)

        let limit = HarnessRateLimit(status: .rejected, window: .weekly)
        let stopped = entry(4, .usageLimit(limit))
        let limited = project([request, partial, stopped]).turns[0]
        XCTAssertEqual(limited.outcome, .usageLimit(limit, entryID: stopped.id))
        XCTAssertEqual(limited.status, .failed)
    }

    func testStatusAndApproximateTiming() {
        let first = entry(0, .user(text: "One"))
        let answer = entry(2.5, .assistant(text: "A", isStreaming: false))
        let second = entry(10, .user(text: "Two"))
        let working = entry(11, .assistant(text: "B", isStreaming: true))
        let entries = [first, answer, second, working]

        let running = project(entries, status: .running).turns
        XCTAssertEqual(running.map(\.status), [.completed, .running])
        XCTAssertEqual(running[0].timing, ConversationTurnTiming(
            startedAt: first.createdAt, completedAt: answer.createdAt, durationMilliseconds: 2_500, isApproximate: true
        ))
        XCTAssertEqual(running[1].timing, ConversationTurnTiming(
            startedAt: second.createdAt, completedAt: nil, durationMilliseconds: nil, isApproximate: true
        ))
        // Idle without the task marked complete: the turn's end is not known.
        XCTAssertEqual(project(entries, status: .ready).turns.map(\.status), [.completed, .unknown(nil)])
        XCTAssertEqual(project(entries, status: .ready, latestTurnIsComplete: true).turns[1].timing.durationMilliseconds, 1_000)
    }

    func testClaudeEditAndRestoreFollowTheMessageMenuRules() {
        let message = entry(0, .user(text: "Change it"))
        let answer = entry(1, .assistant(text: "Changed.", isStreaming: false))
        let bash = entry(2, .user(text: ClaudeBashMessage.text(command: "git diff", stdout: "")))

        let idle = project([message, answer], harness: .claudeCode).turns[0].actions
        XCTAssertEqual(idle.editLatest, ConversationMessageTarget(entryID: message.id, text: "Change it"))
        XCTAssertEqual(idle.restoreFiles, ConversationMessageTarget(entryID: message.id, text: "Change it"))
        // The latest turn forks the whole conversation while idle (D10, M12e).
        XCTAssertTrue(idle.canFork)
        // Busy: no edit or fork, but restore stays offered (the rewind sheet checks for itself).
        for status in [SessionStatus.running, .waitingForApproval] {
            let busy = project([message, answer], harness: .claudeCode, status: status).turns[0].actions
            XCTAssertNil(busy.editLatest)
            XCTAssertNotNil(busy.restoreFiles)
            XCTAssertFalse(busy.canFork)
        }
        // A later bash command: nothing to edit; restore stays on the latest message, and the fork
        // moves to the latest turn.
        let turns = project([message, answer, bash], harness: .claudeCode).turns
        XCTAssertNil(turns[0].actions.editLatest)
        XCTAssertEqual(turns[0].actions.restoreFiles?.entryID, message.id)
        XCTAssertFalse(turns[0].actions.canFork)
        XCTAssertEqual(turns[1].actions, ConversationTurnActions(canFork: true))
        // Other harnesses have neither.
        XCTAssertEqual(project([message, answer], harness: .openCode).turns[0].actions, ConversationTurnActions())
    }

    func testFailedRequestIsOfferedForEditingByTheRecoveryRule() {
        let request = entry(0, .user(text: "Try this"))
        let failure = entry(1, .error(message: "Failed", recoverable: true))
        let actions = project([request, failure], status: .failed).turns[0].actions
        XCTAssertEqual(actions.failedRequestDraft, CodexComposerDraft(inputs: [.text("Try this")]))
        XCTAssertEqual(actions.editLatest?.text, "Try this", "Claude's own rewind edit is a separate action on the same message")
        XCTAssertNil(project([request, failure], status: .running).turns[0].actions.failedRequestDraft)
        let later = entry(2, .assistant(text: "Recovered", isStreaming: false))
        XCTAssertNil(project([request, failure, later], status: .ready).turns[0].actions.failedRequestDraft)
        // An earlier turn's failure is followed by a request, so it is never offered.
        let next = entry(3, .user(text: "Next"))
        XCTAssertNil(project([request, failure, next], status: .ready).turns[0].actions.failedRequestDraft)
    }

    func testPlanIsParsedIntoItsTurn() {
        let request = entry(0, .user(text: "Plan"))
        let plan = entry(1, .plan("☑ Read\n◉ Write"))
        let turn = project([request, plan]).turns[0]
        XCTAssertEqual(turn.plan, ConversationPlan(explanation: nil, steps: [
            .init(id: "\(plan.id.uuidString):plan:0", text: "Read", status: .completed),
            .init(id: "\(plan.id.uuidString):plan:1", text: "Write", status: .inProgress)
        ], source: .transcript(plan)))
        XCTAssertEqual(turn.work, [])
        XCTAssertTrue(turn.hasWorkDetails, "The plan is work to fold")
    }

    func testFindUnitsScrollToTurns() {
        let request = entry(0, .user(text: "Find me"))
        let said = entry(1, .assistant(text: "Commentary", isStreaming: false))
        let answer = entry(2, .assistant(text: "Answer", isStreaming: false))
        let units = ConversationFindSource.conversation(project([request, said, answer], latestTurnIsComplete: true)).units
        let turn = request.id.uuidString
        XCTAssertEqual(units, [
            ConversationFindUnit(id: request.id.uuidString, scrollID: turn, revealID: nil, body: .plain("Find me")),
            ConversationFindUnit(id: said.id.uuidString, scrollID: turn, revealID: turn, body: .markdown("Commentary")),
            ConversationFindUnit(id: answer.id.uuidString, scrollID: turn, revealID: nil, body: .markdown("Answer"))
        ])
    }

    // MARK: - Helpers

    private func entry(_ seconds: TimeInterval, _ content: TranscriptEntryContent) -> TranscriptEntry {
        TranscriptEntry(createdAt: start.addingTimeInterval(seconds), content: content)
    }

    private func project(
        _ entries: [TranscriptEntry],
        harness: HarnessKind = .claudeCode,
        status: SessionStatus = .ready,
        latestTurnIsComplete: Bool = false
    ) -> ConversationPresentation {
        TranscriptConversationProjection.presentation(
            from: entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete
        )
    }
}
