import Foundation

// How a request card's answers reach the provider, for every harness (plan B4, M12a): one card
// draws `ConversationRequest.responses`, and each one it sends goes by one route
// (`ConversationActions.respond(_:_:)`). The routes keep each provider's own answers: the shared
// transcript's decisions, provider options and form answers, and Codex's per-kind responses
// (`CodexRequestResponseProjection`).

/// What the person entered on a request's form before answering, by each question's
/// `ConversationQuestionStep.id`: the provider's question text (Claude Code, Muse) or its ID (Codex).
struct ConversationRequestFormInput: Equatable, Sendable {
    /// The options picked per question.
    var selections: [String: Set<String>] = [:]
    /// The words typed per question: a free-text question's answer, or the person's own answer
    /// besides the options.
    var text: [String: String] = [:]
    /// What to change, typed on a plan review.
    var reason = ""
    /// What was entered per MCP form field, by the field's name.
    var fields: [String: CodexMCPElicitationFieldValue] = [:]
    /// The questions the person skipped.
    var skipped: Set<String> = []
}

extension ConversationRequest {
    /// The route `response` takes with what the form collected, or nil while the form cannot be
    /// sent yet: a question neither answered nor skipped (`ConversationQuestionStepper`).
    ///
    /// - A question form returns the picked options in the provider's question and option order and
    ///   the person's own words after them, leaving out a question the person skipped.
    /// - "Keep planning" carries the reason typed on the card, or is a plain deny without one.
    /// - A Codex form answers each question under its ID with its one option or the words, as the
    ///   Codex app does, leaving out a question the person skipped.
    func route(for response: ConversationRequestResponse, input: ConversationRequestFormInput) -> ConversationRequestRoute? {
        guard response.route == .structured else { return response.route }
        switch form {
        case let .choices(questions):
            var answers: [PermissionQuestionAnswer] = []
            for (question, step) in zip(questions, questions.map(ConversationQuestionStep.init)) {
                guard input.isSettled(step) else { return nil }
                guard let answer = input.answer(for: step) else { continue }
                answers.append(PermissionQuestionAnswer(question: question.question, selectedLabels: answer.options,
                                                        customAnswer: answer.custom))
            }
            return .answer(.questions(answers))
        case .planReview:
            let reason = input.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? .decision(.deny) : .answer(.denial(reason: reason))
        case let .freeText(questions):
            var answers: [String: [String]] = [:]
            for step in questions.map(ConversationQuestionStep.init) {
                guard input.isSettled(step) else { return nil }
                if let answer = input.answer(for: step), let value = answer.values.first { answers[step.id] = [value] }
            }
            return .codex(.toolUserInput(answers: answers))
        case let .mcpForm(form):
            return form.content(input.fields).map { .codex(.mcpElicitation(action: .accept, content: $0)) }
        case nil:
            return nil
        }
    }

    /// The answers a host offers: `responses`, unless one needs a route the host cannot carry. A
    /// host that cannot return a form's answer (`canAnswer`) or the provider's own option
    /// (`canChooseOption`) offers the plain answers instead, so nothing the person picks is
    /// dropped on the way back.
    func offeredResponses(canChooseOption: Bool, canAnswer: Bool) -> [ConversationRequestResponse] {
        let needsAnswer = responses.contains { response in
            guard response.route == .structured else { return false }
            switch form {
            case .choices, .planReview: return true
            case .freeText, .mcpForm, nil: return false
            }
        }
        let needsOption = responses.contains { if case .providerAction = $0.route { true } else { false } }
        guard (needsAnswer && !canAnswer) || (needsOption && !canChooseOption) else { return responses }
        return ConversationRequestResponses.plain(providerActions: canChooseOption ? providerActions : [])
    }
}

/// The answers of a shared-transcript request.
enum ConversationRequestResponses {
    /// A question form: submit what was picked.
    static var questions: [ConversationRequestResponse] {
        [.init(LocalizedText("Submit answers"), role: .primary, route: .structured)]
    }

    /// A plan review: keep planning (with the reason typed on the card, or a plain deny), or
    /// approve.
    static var planReview: [ConversationRequestResponse] {
        [
            .init(LocalizedText("Keep planning"), role: .destructive, route: .structured),
            .init(LocalizedText("Approve plan"), role: .primary, route: .decision(.allow))
        ]
    }

    /// The provider's own options, denials first and the narrowest allow prominent; or deny and
    /// allow when it sent none.
    static func plain(providerActions: [PermissionRequestAction]) -> [ConversationRequestResponse] {
        guard !providerActions.isEmpty else {
            return [
                .init(LocalizedText("Deny"), role: .destructive, route: .decision(.deny)),
                .init(LocalizedText("Allow"), role: .primary, route: .decision(.allow))
            ]
        }
        let prominent = PermissionActionPreference.preferred(from: providerActions, decision: .allow)
        let ordered = providerActions.filter { $0.decision == .deny } + providerActions.filter { $0.decision == .allow }
        return ordered.map { action in
            let role: ConversationRequestResponse.Role = action.decision == .deny ? .destructive
                : action.id == prominent?.id ? .primary : .secondary
            return .init(title: action.label, role: role, route: .providerAction(action), text: action.labelText)
        }
    }
}

// MARK: - Order

extension ConversationRequest {
    /// The order of a turn's requests when the provider gives them no order of its own (Codex keeps
    /// them by ID): by the position of the item each asks about (`itemPositions`, from the turn),
    /// then by ID, numbers by value. The same requests always draw in the same order.
    static func providerOrder(
        _ lhs: ConversationRequest, _ rhs: ConversationRequest, itemPositions: [String: Int]
    ) -> Bool {
        let left = lhs.toolCallID.flatMap { itemPositions[$0] } ?? Int.max
        let right = rhs.toolCallID.flatMap { itemPositions[$0] } ?? Int.max
        if left != right { return left < right }
        return lhs.id.compare(rhs.id, options: [.numeric, .literal]) == .orderedAscending
    }
}
