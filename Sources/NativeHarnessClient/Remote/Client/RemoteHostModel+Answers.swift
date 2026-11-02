import Foundation
import YardletRemote

/// A request card's answer, sent back to the host as the command that answers it there
/// (docs/REMOTE_PROTOCOL.md §15.3, §15.4, §15.18, §15.19): the card draws the host's request with the
/// answers `RemoteTurnProjection` gave it, and the route it sends names which.
extension RemoteHostModel {
    /// The task's conversation's answer to `requestID` by `route`.
    func respond(taskID: String, requestID: String, route: ConversationRequestRoute) {
        guard let item = conversations[taskID]?.pendingRequest(requestID) else {
            commandError = L10n.string("This request was already answered.")
            return
        }
        switch route {
        case let .providerAction(action):
            send(answer(action, taskID: taskID, requestID: requestID))
        case let .decision(decision):
            if item.requestKind == "planReview" {
                send(.reviewPlan(taskID: taskID, requestID: requestID, decision: decision == .deny ? .keepPlanning : .approve,
                                 reason: nil))
            } else {
                send(.answerApproval(taskID: taskID, requestID: requestID, answer: decision == .deny ? .deny : .allowOnce))
            }
        case let .answer(.denial(reason)):
            send(.reviewPlan(taskID: taskID, requestID: requestID, decision: .keepPlanning, reason: reason))
        case let .answer(.questions(answers)):
            send(.answerQuestion(taskID: taskID, requestID: requestID, answers: Self.answers(answers, steps: item.questionSteps ?? [])))
        case let .codex(.toolUserInput(answers)):
            let steps = item.questionSteps ?? []
            send(.answerQuestion(taskID: taskID, requestID: requestID, answers: steps.map { step in
                guard let value = answers[step.id]?.first else { return RemoteQuestionAnswer(questionId: step.id, skipped: true) }
                return step.options.contains { $0.label == value }
                    ? RemoteQuestionAnswer(questionId: step.id, options: [value])
                    : RemoteQuestionAnswer(questionId: step.id, text: value)
            }))
        case .codex, .structured:
            commandError = L10n.format("Answer this on %@.", name)
        }
    }

    private func answer(_ action: PermissionRequestAction, taskID: String, requestID: String) -> RemoteRequest {
        let id = action.id
        if id.hasPrefix(RemoteTurnProjection.Route.choice) {
            return .chooseAnswer(taskID: taskID, requestID: requestID, choice: String(id.dropFirst(RemoteTurnProjection.Route.choice.count)))
        }
        if id.hasPrefix(RemoteTurnProjection.Route.handoff),
           let answer = RemoteHandoffAnswer(rawValue: String(id.dropFirst(RemoteTurnProjection.Route.handoff.count))) {
            return .answerHandoff(taskID: taskID, requestID: requestID, answer: answer)
        }
        let answer = RemoteApprovalAnswer(rawValue: String(id.dropFirst(RemoteTurnProjection.Route.answer.count))) ?? .deny
        return .answerApproval(taskID: taskID, requestID: requestID, answer: answer)
    }

    /// The card's answers by question text, as the host's steps name them; a step left out was skipped.
    static func answers(_ answers: [PermissionQuestionAnswer], steps: [RemoteQuestionStep]) -> [RemoteQuestionAnswer] {
        steps.map { step in
            let text = step.text ?? step.header ?? step.id
            guard let answer = answers.first(where: { $0.question == text }) else {
                return RemoteQuestionAnswer(questionId: step.id, skipped: true)
            }
            return RemoteQuestionAnswer(questionId: step.id, options: answer.selectedLabels.isEmpty ? nil : answer.selectedLabels,
                                        text: answer.customAnswer)
        }
    }
}
