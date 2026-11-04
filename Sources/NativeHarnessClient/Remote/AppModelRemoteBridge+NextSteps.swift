import Foundation
import YardletRemote

/// Next-step buttons use the current host projection, never a plan or retry payload supplied by a client.
extension AppModelRemoteBridge {
    func nextStep(taskID: String, turnID: String, action: RemoteNextStep, text: String?) async -> RemoteError? {
        guard let model, let session = session(taskID) else { return RemoteError(.notFound) }
        guard !model.switchingAccounts.contains(session.id), !model.sessionMutations.contains(session.id),
              model.composerDrafts.tasks.draft(for: session.id).editState == nil else { return RemoteError(.busy) }
        let presentation = presentation(of: session, in: model)
        guard let turn = presentation.turns.first(where: { $0.id == turnID }) else { return RemoteError(.notFound) }
        switch action {
        case .implementPlan:
            guard presentation.turns.last?.id == turnID, let plan = turn.actions.planToImplement,
                  session.status != .running, session.status != .waitingForApproval,
                  Self.codexState(of: session, in: model)?.activeTurnID == nil,
                  model.followUps.queue(for: session.id).isEmpty else { return RemoteError(.notAllowed) }
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
            if action == .answer {
                guard session.status != .running, session.status != .waitingForApproval,
                      Self.codexState(of: session, in: model)?.activeTurnID == nil,
                      model.followUps.queue(for: session.id).isEmpty else { return RemoteError(.busy) }
            }
            Task { await model.submitCodex(CodexComposerDraft(inputs: [.text(reply)]),
                                            action: action == .answerWhileWorking ? .steer : .automatic, to: session) }
        case .retry:
            guard turn.actions.canRetry, session.status == .ready || session.status == .failed,
                  model.followUps.queue(for: session.id).isEmpty else { return RemoteError(.notAllowed) }
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

/// Carried with the memoized turn, so old questions and plans are not rebuilt for each event.
extension RemoteConversationProjection {
    static func addNextSteps(_ actions: ConversationTurnActions, to item: inout RemoteItem) {
        func question(_ source: CodexAsyncQuestion) -> RemoteNextQuestion {
            RemoteNextQuestion(title: RemoteText.capped(source.title, RemoteText.questionLimit).text,
                options: source.options.prefix(32).map { RemoteText.capped($0, RemoteText.questionLimit).text },
                itemID: source.itemID)
        }
        item.planToImplement = RemoteText.short(actions.planToImplement, RemoteText.fullTextLimit)
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
