import Foundation

/// A Codex approval or server request as the one request card draws it (plan B4, M12a): its
/// answers by kind, with the buttons and the `CodexServerRequestResponse` values the Codex cards
/// sent, its free-text questions, and its state.
///
/// A kind Yardlet does not answer offers nothing and says so in the card's own words; it fails
/// closed, as the Codex card did.
enum CodexRequestResponseProjection {
    /// A server request as a conversation request.
    static func request(_ request: CodexServerRequestState) -> ConversationRequest {
        let state = state(request.resolution)
        let questions = request.kind == .toolUserInput ? questions(request.params) : []
        let form: ConversationRequestForm? = request.kind == .toolUserInput ? .freeText(questions) : mcpForm(request)
        let responses = responses(for: request)
        var recordedAnswers: [String: ConversationQuestionAnswer]?
        if request.kind == .toolUserInput, case let .resolved(response) = request.resolution {
            recordedAnswers = answers(response, to: questions)
        }
        return ConversationRequest(
            id: request.id,
            title: request.kind.cardTitle,
            detail: mcpUnsupportedReason(request),
            command: command(request.params),
            form: form,
            state: state,
            responses: state == .pending ? responses : [],
            toolCallID: request.itemID,
            unanswerableReason: responses.isEmpty ? L10n.string("This Codex request needs a structured response.") : nil,
            method: request.method,
            recordedAnswers: recordedAnswers,
            source: .codexServerRequest(request)
        )
    }

    /// An approval the thread holds without a server request: allow or deny through the
    /// permission control.
    static func request(_ approval: CodexApprovalState) -> ConversationRequest {
        let state: ConversationRequestState = switch approval.resolution {
        case .pending: .pending
        case let .resolved(response): resolvedState(response)
        }
        return ConversationRequest(
            id: approval.id,
            title: CodexApprovalState.cardTitle,
            command: command(approval.raw),
            state: state,
            responses: state == .pending ? [
                .init(LocalizedText("Deny"), role: .destructive, route: .decision(.deny)),
                .init(LocalizedText("Allow"), role: .primary, route: .decision(.allow))
            ] : [],
            toolCallID: approval.itemID,
            method: approval.method,
            source: .codexApproval(approval)
        )
    }

    /// The answers a server request's kind takes, in the order the card draws them: the denial
    /// first and the plain allow last and prominent. Each value is what the Codex request card
    /// sent for the same button.
    static func responses(for request: CodexServerRequestState) -> [ConversationRequestResponse] {
        let allow = LocalizedText("Allow")
        let allowForSession = LocalizedText("Allow for session")
        let deny = LocalizedText("Deny")
        switch request.kind {
        case .commandExecutionApproval:
            if let offered = CodexCommandApprovalOptions(params: request.params) { return offered.responses }
            return [
                .init(deny, role: .destructive, route: .codex(.command(.decline))),
                .init(allowForSession, role: .secondary, route: .codex(.command(.acceptForSession))),
                .init(allow, role: .primary, route: .codex(.command(.accept)))
            ]
        case .fileChangeApproval:
            return [
                .init(deny, role: .destructive, route: .codex(.fileChange(.decline))),
                .init(allowForSession, role: .secondary, route: .codex(.fileChange(.acceptForSession))),
                .init(allow, role: .primary, route: .codex(.fileChange(.accept)))
            ]
        case .permissionsApproval:
            let requested = request.params?["permissions"] ?? .object([:])
            return [
                .init(deny, role: .destructive,
                      route: .codex(.permissions(permissions: .object([:]), scope: .turn, strictAutoReview: nil))),
                .init(allowForSession, role: .secondary,
                      route: .codex(.permissions(permissions: requested, scope: .session, strictAutoReview: nil))),
                .init(allow, role: .primary,
                      route: .codex(.permissions(permissions: requested, scope: .turn, strictAutoReview: nil)))
            ]
        case .applyPatchApproval, .execCommandApproval:
            return [
                .init(deny, role: .destructive,
                      route: .codex(.legacyReview(.denied(rejection: L10n.string("Denied"))))),
                .init(allowForSession, role: .secondary, route: .codex(.legacyReview(.approvedForSession))),
                .init(allow, role: .primary, route: .codex(.legacyReview(.approved)))
            ]
        case .toolUserInput:
            return [.init(LocalizedText("Send answer"), role: .primary, route: .structured)]
        case .mcpElicitation:
            if let approval = CodexMCPToolApproval(params: request.params) { return approval.responses }
            return CodexMCPElicitation(params: request.params).responses
        case .dynamicToolCall:
            return [
                .init(deny, role: .destructive, route: .codex(.dynamicToolCall(contentItems: [], success: false))),
                .init(allow, role: .primary, route: .codex(.dynamicToolCall(contentItems: [], success: true)))
            ]
        case .authenticationRefresh, .attestation, .currentTime, .unknown:
            return []
        }
    }

    /// An MCP elicitation's form to fill in, for a form with fields (`CodexMCPElicitation`).
    static func mcpForm(_ request: CodexServerRequestState) -> ConversationRequestForm? {
        guard request.kind == .mcpElicitation, CodexMCPToolApproval(params: request.params) == nil,
              case let .form(form) = CodexMCPElicitation(params: request.params), !form.fields.isEmpty else { return nil }
        return .mcpForm(form.answered(request.resolution))
    }

    /// Why an MCP elicitation can only be declined or cancelled, for one Yardlet does not fill in.
    static func mcpUnsupportedReason(_ request: CodexServerRequestState) -> String? {
        guard request.kind == .mcpElicitation, CodexMCPToolApproval(params: request.params) == nil,
              case let .unsupported(reason) = CodexMCPElicitation(params: request.params) else { return nil }
        return reason
    }

    /// The questions of `item/tool/requestUserInput`, each answered under its ID: its options
    /// (`options`, the first preselected), the person's own words where it takes them (`isOther`, or
    /// no options), its label (`header`) and whether the answer is a secret (`isSecret`). A question
    /// without text reads as Codex asking for an answer; a request without questions is one unnamed
    /// answer.
    static func questions(_ params: JSONValue?) -> [ConversationRequestQuestion] {
        let questions = (params?["questions"]?.arrayValue ?? []).enumerated().map { index, question in
            let options = (question["options"]?.arrayValue ?? []).compactMap { option -> PermissionQuestionOption? in
                guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
                let description = option["description"]?.stringValue
                return PermissionQuestionOption(label: label, description: description?.isEmpty == false ? description : nil)
            }
            let header = question["header"]?.stringValue
            return ConversationRequestQuestion(
                id: question["id"]?.stringValue ?? (index == 0 ? "answer" : "answer-\(index)"),
                text: question["text"]?.stringValue ?? question["question"]?.stringValue
                    ?? L10n.string("Codex requests an answer"),
                header: header?.isEmpty == false ? header : nil,
                options: options,
                allowsCustomAnswer: options.isEmpty || question["isOther"]?.boolValue == true,
                isSecret: question["isSecret"]?.boolValue == true
            )
        }
        return questions.isEmpty ? [ConversationRequestQuestion(id: "answer", text: nil)] : questions
    }

    /// What a `requestUserInput` response answered (`answers`, each question's `answers` under its
    /// ID): a value that names one of the question's options is that option, any other the person's
    /// own words.
    static func answers(_ response: JSONValue?, to questions: [ConversationRequestQuestion])
        -> [String: ConversationQuestionAnswer]? {
        guard let recorded = response?["answers"]?.objectValue else { return nil }
        var answers: [String: ConversationQuestionAnswer] = [:]
        for question in questions {
            let values = (recorded[question.id]?["answers"]?.arrayValue ?? []).compactMap(\.stringValue)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty else { continue }
            let labels = Set(question.options.map(\.label))
            let own = values.filter { !labels.contains($0) }
            answers[question.id] = ConversationQuestionAnswer(
                options: question.options.map(\.label).filter(values.contains),
                custom: own.isEmpty ? nil : own.joined(separator: ", ")
            )
        }
        return answers
    }

    static func state(_ resolution: CodexServerRequestResolution) -> ConversationRequestState {
        switch resolution {
        case .pending: .pending
        case let .resolved(response): resolvedState(response)
        case let .rejected(code, message):
            code == CodexPendingServerRequest.expiredRuntimeCode ? .expired(message: message) : .rejected(message: message)
        }
    }

    /// What an answered request's response says: allowed or denied where its decision, granted
    /// permissions or tool result tell, answered otherwise.
    static func resolvedState(_ response: JSONValue?) -> ConversationRequestState {
        if let decision = response?["decision"] {
            if let value = decision.stringValue {
                switch value {
                case "accept", "acceptForSession", "approved", "approved_for_session", "approved_mcp_policy_amendment":
                    return .allowed
                case "decline", "cancel", "abort", "timed_out", "denied":
                    return .denied
                default:
                    return .answered
                }
            }
            let keys = Set(decision.objectValue?.keys.map { $0 } ?? [])
            if !keys.isDisjoint(with: ["acceptWithExecpolicyAmendment", "approved_execpolicy_amendment"]) { return .allowed }
            if keys.contains("denied") { return .denied }
            return .answered
        }
        if let permissions = response?["permissions"]?.objectValue {
            return permissions.isEmpty ? .denied : .allowed
        }
        if case let .bool(success)? = response?["success"] {
            return success ? .allowed : .denied
        }
        // An MCP elicitation declined or cancelled was not answered.
        if let action = response?["action"]?.stringValue, action == "decline" || action == "cancel" {
            return .denied
        }
        return .answered
    }

    /// The command a request would run: Codex's string, or the argument list of an older review.
    static func command(_ params: JSONValue?) -> String? {
        guard let value = params?["command"] else { return nil }
        if let text = value.stringValue {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        let parts = value.arrayValue?.compactMap(\.stringValue) ?? []
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// An MCP tool approval (`_meta.codex_approval_kind` `mcp_tool_call`) answered with the Codex app's
/// options (26.1016 `mcp-request-card`, `computer-use-app-approval-request-card`): Deny; Always
/// allow where `persist` offers `always`; Allow this conversation where it offers `session`; and
/// Allow once. Computer Use's main answer is Allow this conversation, as there. An accept carries
/// `content: {}` and the chosen `_meta.persist`, which Computer Use keeps for the conversation or
/// for good, so the same app is not asked about again.
struct CodexMCPToolApproval: Equatable {
    let persistModes: [String]
    let isComputerUse: Bool

    init?(params: JSONValue?) {
        let meta = params?["_meta"]
        guard meta?["codex_approval_kind"]?.stringValue == "mcp_tool_call" else { return nil }
        switch meta?["persist"] {
        case let .string(mode)?: persistModes = [mode]
        case let .array(modes)?: persistModes = modes.compactMap(\.stringValue)
        default: persistModes = []
        }
        let connector = (meta?["connector_id"]?.stringValue ?? "").lowercased()
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        isComputerUse = connector == "computer-use" || connector.hasPrefix("computer-use-")
    }

    var responses: [ConversationRequestResponse] {
        var responses: [ConversationRequestResponse] = [
            .init(LocalizedText("Deny"), role: .destructive, route: .codex(.mcpElicitation(action: .decline)))
        ]
        if persistModes.contains("always") {
            responses.append(.init(LocalizedText("Always allow"), role: .secondary, route: .codex(Self.accept("always"))))
        }
        let session = persistModes.contains("session") ? "session" : nil
        if isComputerUse {
            responses.append(.init(LocalizedText("Allow this conversation"), role: .primary,
                                   route: .codex(Self.accept(session))))
            return responses
        }
        if let session {
            responses.append(.init(LocalizedText("Allow this conversation"), role: .secondary,
                                   route: .codex(Self.accept(session))))
        }
        responses.append(.init(LocalizedText("Allow once"), role: .primary, route: .codex(Self.accept(nil))))
        return responses
    }

    static func accept(_ persist: String?) -> CodexServerRequestResponse {
        .mcpElicitation(action: .accept, content: .object([:]),
                        meta: persist.map { .object(["persist": .string($0)]) })
    }
}

/// The decisions a command approval offers (`availableDecisions`, Codex 0.163), in the card's
/// order: the denials first, then the allows, the narrowest last and prominent. Each one is sent
/// back as the provider listed it, so a command rule (`acceptWithExecpolicyAmendment`) or a host
/// rule (`applyNetworkPolicyAmendment`) keeps the exact prefix or host it was offered with. A
/// decision Yardlet does not know is left out; a list that cannot be read offers nothing. Nil only
/// when the request sends no list (absent or null), and the card keeps the decisions every command
/// approval takes.
struct CodexCommandApprovalOptions: Equatable {
    let decisions: [CodexCommandApprovalDecision]

    init?(params: JSONValue?) {
        let value = params?["availableDecisions"]
        guard let value, value != .null else { return nil }
        let offered = value.arrayValue ?? []
        var decisions: [CodexCommandApprovalDecision] = []
        for value in offered {
            guard let decision = Self.decision(value), !decisions.contains(decision) else { continue }
            decisions.append(decision)
        }
        self.decisions = decisions
    }

    static func decision(_ value: JSONValue) -> CodexCommandApprovalDecision? {
        switch value.stringValue {
        case "accept": return .accept
        case "acceptForSession": return .acceptForSession
        case "decline": return .decline
        case "cancel": return .cancel
        case _?: return nil
        case nil: break
        }
        guard let object = value.objectValue, object.count == 1 else { return nil }
        if let amendment = object["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"]?.arrayValue {
            let words = amendment.compactMap(\.stringValue)
            guard !words.isEmpty, words.count == amendment.count else { return nil }
            return .acceptWithExecpolicyAmendment(words)
        }
        if let policy = object["applyNetworkPolicyAmendment"]?["network_policy_amendment"],
           let host = policy["host"]?.stringValue, !host.isEmpty,
           let action = policy["action"]?.stringValue.flatMap(CodexNetworkPolicyAction.init(rawValue:)) {
            return .applyNetworkPolicyAmendment(host: host, action: action)
        }
        return nil
    }

    var responses: [ConversationRequestResponse] {
        let denials = decisions.filter { Self.breadth($0) == nil }
        let allows = decisions.compactMap { decision in Self.breadth(decision).map { (decision, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
        func response(_ decision: CodexCommandApprovalDecision, _ role: ConversationRequestResponse.Role) -> ConversationRequestResponse {
            .init(Self.text(decision), role: role, route: .codex(.command(decision)))
        }
        return denials.map { response($0, .destructive) }
            + allows.dropFirst().map { response($0, .secondary) }
            + allows.prefix(1).map { response($0, .primary) }
    }

    /// How far an allow reaches, narrowest first: this command, this session, a command rule, a
    /// host rule; nil for a denial.
    private static func breadth(_ decision: CodexCommandApprovalDecision) -> Int? {
        switch decision {
        case .accept: 0
        case .acceptForSession: 1
        case .acceptWithExecpolicyAmendment: 2
        case .applyNetworkPolicyAmendment(_, .allow): 3
        case .applyNetworkPolicyAmendment(_, .deny), .decline, .cancel: nil
        }
    }

    static func title(_ decision: CodexCommandApprovalDecision) -> String {
        text(decision).resolved
    }

    static func text(_ decision: CodexCommandApprovalDecision) -> LocalizedText {
        switch decision {
        case .accept: LocalizedText("Allow")
        case .acceptForSession: LocalizedText("Allow for session")
        case let .acceptWithExecpolicyAmendment(prefix):
            LocalizedText("Always allow commands starting with “%@”", .verbatim(prefix.joined(separator: " ")))
        case let .applyNetworkPolicyAmendment(host, .allow): LocalizedText("Always allow %@", .verbatim(host))
        case let .applyNetworkPolicyAmendment(host, .deny): LocalizedText("Always block %@", .verbatim(host))
        case .decline: LocalizedText("Deny")
        case .cancel: LocalizedText("Deny and stop")
        }
    }

}
