import Foundation
import YardletRemote

/// Next-step buttons use the current host projection, never a plan or retry payload supplied by a client.
extension AppModelRemoteBridge {
    func nextStep(taskID: String, turnID: String, action: RemoteNextStep, text: String?) async -> RemoteError? {
        guard let model, let session = session(taskID) else { return RemoteError(.notFound) }
        guard !model.isHeld(session, by: TaskBlocker.holdingOffActions) else {
            return RemoteError(.busy, "The task is changing on the Mac", reason: .changing)
        }
        guard model.composerDrafts.tasks.existingDraft(for: session.id)?.editState == nil else {
            return RemoteError(.busy, "A message is being edited on the Mac", reason: .editing)
        }
        let presentation = presentation(of: session, in: model)
        guard let turn = presentation.turns.first(where: { $0.id == turnID }) else { return RemoteError(.notFound) }
        // What waits for the task to be idle says so, as the Mac hides these buttons until then; a retry looks at the
        // task's status only, as the Mac's does.
        func busy(_ codexTurnCounts: Bool = true) -> RemoteError? {
            if session.status == .running || session.status == .waitingForApproval
                || (codexTurnCounts && Self.codexState(of: session, in: model)?.activeTurnID != nil) {
                return RemoteError(.notAllowed, "Available when the turn ends", reason: .running)
            }
            if !model.followUps.queue(for: session.id).isEmpty {
                return RemoteError(.notAllowed, "Messages wait in the task's queue", reason: .queue)
            }
            return nil
        }
        switch action {
        case .implementPlan:
            guard presentation.turns.last?.id == turnID, let plan = turn.actions.planToImplement else { return RemoteError(.notAllowed) }
            if let busy = busy() { return busy }
            Task { await model.implementCodexPlan(plan, in: session) }
        case .answer, .answerWhileWorking:
            guard session.harness == .codex, presentation.turns.last?.id == turnID,
                  !turn.actions.questionsToAnswer.isEmpty, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 32_000, let answers = CodexAsyncQuestionReply.answers(in: text),
                  (action == .answer) == turn.status.isTerminal else { return RemoteError(.notAllowed) }
            let questions = Dictionary(turn.actions.questionsToAnswer.map { ($0.itemID, $0) }, uniquingKeysWith: { _, newer in newer })
            guard Set(answers.map(\.questionItemID)).count == answers.count,
                  answers.allSatisfy({ questions[$0.questionItemID] != nil }) else { return RemoteError(.notAllowed) }
            let reply = CodexAsyncQuestionReply.message(answers.map { answer in
                .init(questionItemID: answer.questionItemID, question: questions[answer.questionItemID]!.title, answer: answer.answer)
            })
            if action == .answerWhileWorking {
                guard Self.codexState(of: session, in: model)?.activeTurnID == turnID else { return RemoteError(.notAllowed) }
            }
            if action == .answer, let busy = busy() { return RemoteError(.busy, busy.message, reason: busy.reason) }
            Task { await model.submitCodex(CodexComposerDraft(inputs: [.text(reply)]),
                                            action: action == .answerWhileWorking ? .steer : .automatic, to: session) }
        case .retry:
            guard turn.actions.canRetry else { return RemoteError(.notAllowed) }
            if let busy = busy(false) { return busy }
            guard session.status == .ready || session.status == .failed else { return RemoteError(.notAllowed) }
            Task { await model.retryTurn(turnID, in: session) }
        case .resumeAfterReset:
            guard session.harness == .claudeCode, session.status != .running, session.status != .waitingForApproval,
                  let card = UsageLimitContinuation.card(in: model.transcriptBySessionID[session.id] ?? []),
                  case let .usageLimit(limit) = card.content, let resetsAt = limit.resetsAt, resetsAt <= Date(),
                  case let .usageLimit(_, entryID)? = turn.outcome, entryID == card.id else { return RemoteError(.notAllowed) }
            Task { await model.continueAfterUsageLimitReset(entryID: card.id, for: session) }
        }
        return nil
    }
}

/// Carried with the memoized turn, so old questions and plans are not rebuilt for each event. Every subscription
/// gets them, so a client that reads the conversation in its basic detail offers the same next steps; only the plan's
/// words are cut there as its plan items' are.
extension RemoteConversationProjection {
    static func addNextSteps(_ actions: ConversationTurnActions, to item: inout RemoteItem, isFull: Bool = true) {
        func question(_ source: CodexAsyncQuestion) -> RemoteNextQuestion {
            RemoteNextQuestion(title: RemoteText.capped(source.title, RemoteText.questionLimit).text,
                options: source.options.prefix(32).map { RemoteText.capped($0, RemoteText.questionLimit).text },
                itemID: source.itemID)
        }
        item.planToImplement = RemoteText.short(actions.planToImplement, isFull ? RemoteText.fullTextLimit : RemoteText.planTextLimit)
        if !actions.questionsToAnswer.isEmpty { item.nextQuestions = actions.questionsToAnswer.prefix(32).map(question) }
        if let answered = actions.answeredQuestions {
            item.answeredQuestions = answered.questions.prefix(32).map { source in
                var wire = question(source)
                wire.answerOptions = answered.answers[source.itemID]?.options.prefix(32).map { RemoteText.capped($0, RemoteText.questionLimit).text }
                wire.customAnswer = RemoteText.short(answered.answers[source.itemID]?.custom, RemoteText.planTextLimit)
                return wire
            }
        }
    }
}
