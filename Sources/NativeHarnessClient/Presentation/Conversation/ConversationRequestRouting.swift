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
    /// One control of the card's row: an answer's own button, or the wider allows as one split button.
    enum AnswerControl {
        case answer(ConversationRequestResponse)
        case widerAllows([ConversationRequestResponse])
    }

    /// The answers as the row draws them. The wider allows (the secondary answers between the denials and
    /// "Allow") become one split button when Yardlet can name their scope or there are several, as the
    /// Claude app keeps "Always allow" short and its scopes in the button's menu; otherwise each keeps its
    /// own button.
    static func controls(_ responses: [ConversationRequestResponse]) -> [AnswerControl] {
        let wider = responses.filter { $0.role == .secondary }
        guard let first = wider.first, wider.count > 1 || ConversationAllowScope(first) != nil
        else { return responses.map(AnswerControl.answer) }
        var controls: [AnswerControl] = []
        for response in responses {
            if response.role != .secondary {
                controls.append(.answer(response))
            } else if response == first {
                controls.append(.widerAllows(wider))
            }
        }
        return controls
    }

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

    /// The provider's own options, denials first and the narrowest allow prominent and last, as both apps
    /// end the row with "Allow once"; or deny and allow when it sent none.
    static func plain(providerActions: [PermissionRequestAction]) -> [ConversationRequestResponse] {
        guard !providerActions.isEmpty else {
            return [
                .init(LocalizedText("Deny"), role: .destructive, route: .decision(.deny)),
                .init(LocalizedText("Allow"), role: .primary, route: .decision(.allow))
            ]
        }
        let prominent = PermissionActionPreference.preferred(from: providerActions, decision: .allow)
        let allows = providerActions.filter { $0.decision == .allow }
        let ordered = providerActions.filter { $0.decision == .deny }
            + allows.filter { $0.id != prominent?.id } + allows.filter { $0.id == prominent?.id }
        return ordered.map { action in
            let role: ConversationRequestResponse.Role = action.decision == .deny ? .destructive
                : action.id == prominent?.id ? .primary : .secondary
            return .init(title: action.label, role: role, route: .providerAction(action), text: action.labelText)
        }
    }
}

/// How a broad allow reads on the card, as both apps show one: a short name on the button ("Always allow")
/// and its scope under it in the button's menu ("Saves to local project settings on this Mac"). Read from
/// the words Yardlet gave the answer; nil for words it does not know, which the button keeps as they are.
struct ConversationAllowScope: Equatable {
    let name: String
    let scope: String

    init?(_ response: ConversationRequestResponse) {
        guard let text = response.text, let wording = Self.wording(text) else { return nil }
        name = wording.name.resolved
        scope = wording.scope.resolved
    }

    private static func wording(_ text: LocalizedText) -> (name: LocalizedText, scope: LocalizedText)? {
        let argument = text.args.first
        switch text.key {
        case "Allow for session":
            return (text, LocalizedText("Applies to this session only"))
        case "Allow and switch to %@ mode for this session":
            guard let mode = argument else { return nil }
            return (LocalizedText("Allow and switch"), LocalizedText("Switches this session to %@ mode", mode))
        case "Always allow in this project (saved to %@)":
            // One settings file, by the name `ClaudePermissionSuggestions.placeName` gave it; several keep
            // the words that name them all.
            switch argument?.key {
            case ".claude/settings.local.json":
                #if os(macOS)
                return (LocalizedText("Always allow"), LocalizedText("Saves to local project settings on this Mac"))
                #else
                return (LocalizedText("Always allow"), LocalizedText("Saves to local project settings"))
                #endif
            case "shared .claude/settings.json":
                return (LocalizedText("Always allow"), LocalizedText("Saves to shared project settings"))
            default:
                return nil
            }
        case "Always allow in every project (saved to %@)":
            return (LocalizedText("Always allow"), LocalizedText("Saves to user settings for all projects"))
        case "Always allow commands starting with “%@”":
            guard let prefix = argument else { return nil }
            return (LocalizedText("Allow similar commands"), LocalizedText("Always allows commands starting with “%@”", prefix))
        case "Always allow %@":
            guard let host = argument else { return nil }
            return (LocalizedText("Always allow host"), LocalizedText("Always allows network access to %@", host))
        default:
            return nil
        }
    }
}

// MARK: - Words

extension ConversationRequest {
    /// What the request was about, on its outcome line: the provider's own words (a Codex request's reason or
    /// question) when it gave any, otherwise the request's detail.
    var outcomeDetail: String? {
        if let message = codexContext?.messages.first { return message }
        if let detail, !detail.isEmpty { return detail }
        return nil
    }

    /// The headline is the provider's description of a call (Claude Code's "Run the unit tests") when it gave
    /// one, under the tool's name; otherwise the request's own title.
    var descriptionHeadline: String? {
        guard form == nil, case let .command(_, description)? = preview,
              let description, !description.isEmpty else { return nil }
        return description
    }

    /// What the card says above the request's title, for every platform's card: a question or form
    /// reads as the answer it got, a plan review as the plan's fate, anything else as an approval.
    var stateTitle: String {
        switch (form, state) {
        case (.choices?, .pending), (.freeText?, .pending), (.mcpForm?, .pending): L10n.string("Answer required")
        case (.choices?, .allowed), (.freeText?, .allowed), (.mcpForm?, .allowed),
             (.choices?, .answered), (.freeText?, .answered), (.mcpForm?, .answered): L10n.string("Answered")
        case (.planReview?, .pending): L10n.string("Plan review")
        case (.planReview?, .allowed): L10n.string("Plan approved")
        case (.planReview?, .denied): L10n.string("Planning continued")
        case (_, .pending): L10n.string("Approval required")
        case (_, .allowed): L10n.string("Allowed")
        case (_, .denied): L10n.string("Denied")
        case (_, .answered): L10n.string("Resolved")
        case (_, .expired): L10n.string("Expired")
        case (_, .rejected): L10n.string("Rejected")
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
