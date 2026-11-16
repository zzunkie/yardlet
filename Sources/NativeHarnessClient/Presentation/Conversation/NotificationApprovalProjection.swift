import Foundation

/// The request a waiting task's notification is about, and the one answer the notification may
/// give for it: "Allow once", the narrowest allow the task's request card offers, sent by the
/// card's own route (`ConversationRequestRoute`).
///
/// Like the Claude app, which leaves the action off questions, plan reviews and requests that need
/// the app (`allowOnceAction: false`), and the Codex app, which offers its approve action only on
/// command and file-change approvals, "Allow once" is offered only for a plain tool approval:
/// - never for a question or a plan review (Claude's AskUserQuestion and ExitPlanMode, a Codex
///   question or MCP form);
/// - never for a request the provider holds for review in the app (`requiresInAppAnswer`), a
///   mode switch, or a Codex request for more permissions (sandbox or network access, the
///   Codex counterpart of Full access);
/// - never where the card's allow is broader than this one request ("for session", "always").
/// Everything else is answered on the card; its notification only opens the task.
///
/// The composer's keys answer the same requests the same way (`ComposerApprovalKey`): "Allow once",
/// or the card's one-time denial (`deny`).
///
/// A message the person sends while a request waits declines it first (`declinedByMessage`), as the
/// harness's own app lets the person type past a request: Claude Code's "No, and tell Claude what to
/// do differently", the Codex app's decline. That one is given for every request it can answer once,
/// questions and plan reviews too.
enum NotificationApprovalProjection {
    struct PendingRequest: Equatable, Sendable {
        let id: String
        /// What "Allow once" sends; nil when the request is answered only on its card.
        let allowOnce: ConversationRequestRoute?
        /// The card's denial that leaves no rule behind, for a request that takes "Allow once";
        /// nil otherwise.
        var deny: ConversationRequestRoute? = nil
        /// It asks the person a question rather than for approval (`asksQuestion`), which Settings lets notify on
        /// its own switch (`TaskNotificationKind`).
        var asksQuestion = false
        /// What a message the person sends while it waits answers it with (`AppModel.answerWaits(_:forPersonsMessageIn:)`);
        /// nil for a request only its card answers.
        var declinedByMessage: ConversationRequestRoute? = nil
    }

    /// Claude Code's AskUserQuestion and the other harnesses' questions in the shared transcript.
    static func asksQuestion(_ request: PermissionRequest) -> Bool {
        if case .questions = request.structured { true } else { false }
    }

    /// A Codex question (`item/tool/requestUserInput`) or MCP form.
    static func asksQuestion(_ request: CodexServerRequestState) -> Bool {
        request.kind == .toolUserInput || request.kind == .mcpElicitation
    }

    /// The requests a task waits on, oldest first: a Codex task's pending server requests, and the
    /// shared transcript's pending requests for every other harness, as the task's card draws them.
    static func pendingRequests(
        harness: HarnessKind,
        transcript: [TranscriptEntry],
        codex: CodexTaskState?
    ) -> [PendingRequest] {
        if harness == .codex {
            return (codex?.serverRequestsByID.values.filter { $0.resolution == .pending } ?? [])
                .sorted { $0.id.compare($1.id, options: [.numeric, .literal]) == .orderedAscending }
                .map { PendingRequest(id: $0.id, allowOnce: allowOnce(for: $0), deny: deny(for: $0),
                                      asksQuestion: asksQuestion($0), declinedByMessage: messageDecline(for: $0)) }
        }
        return transcript.compactMap { entry in
            guard case let .permission(request, .pending) = entry.content else { return nil }
            return PendingRequest(id: request.id, allowOnce: allowOnce(for: request), deny: deny(for: request),
                                  asksQuestion: asksQuestion(request), declinedByMessage: messageDecline(for: request))
        }
    }

    /// The same for a request as its card holds it, by the record it was read from; nil for one that
    /// no longer waits or asks for more than an approval.
    static func pendingRequest(for request: ConversationRequest) -> PendingRequest? {
        guard request.state == .pending, request.form == nil else { return nil }
        switch request.source {
        case let .transcript(entry):
            guard case let .permission(permission, _) = entry.content else { return nil }
            return PendingRequest(id: request.id, allowOnce: allowOnce(for: permission), deny: deny(for: permission),
                                  declinedByMessage: messageDecline(for: permission))
        case let .codexServerRequest(state):
            return PendingRequest(id: request.id, allowOnce: allowOnce(for: state), deny: deny(for: state),
                                  declinedByMessage: messageDecline(for: state))
        case .codexApproval:
            return nil
        }
    }

    /// The answer a message the person sends gives a request as its card holds it, by the record it was read from,
    /// whatever form the card shows.
    static func messageDecline(for request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending else { return nil }
        switch request.source {
        case let .transcript(entry):
            guard case let .permission(permission, _) = entry.content else { return nil }
            return messageDecline(for: permission)
        case let .codexServerRequest(state):
            return messageDecline(for: state)
        case .codexApproval:
            return nil
        }
    }

    /// The answer "Allow once" gives a shared-transcript request: a plain allow where the provider
    /// listed no options, or its own one-time allow. Nil for anything else.
    static func allowOnce(for request: PermissionRequest) -> ConversationRequestRoute? {
        guard request.structured == nil, !request.requiresInAppAnswer,
              request.detail != modeSwitchKind else { return nil }
        let route: ConversationRequestRoute
        if request.actions.isEmpty {
            route = .decision(.allow)
        } else {
            guard let action = PermissionActionPreference.preferred(from: request.actions, decision: .allow),
                  PermissionActionPreference.scope(id: action.id, intent: action.kind) == .once
            else { return nil }
            route = .providerAction(action)
        }
        // Only an answer the card itself offers.
        let offered = ConversationRequestResponses.plain(providerActions: request.actions).map(\.route)
        return offered.contains(route) ? route : nil
    }

    /// The denial a shared-transcript request that takes "Allow once" gets from the keyboard: the plain
    /// deny where the provider listed no options, or its own narrowest denial unless that one is standing.
    static func deny(for request: PermissionRequest) -> ConversationRequestRoute? {
        allowOnce(for: request) == nil ? nil : messageDecline(for: request)
    }

    /// The answer a message the person sends while a shared-transcript request waits gives it: the plain deny where
    /// the provider listed no options, which declines a question or a plan review as a whole (Claude Code's
    /// AskUserQuestion and ExitPlanMode), or the provider's own narrowest denial unless that one is standing.
    static func messageDecline(for request: PermissionRequest) -> ConversationRequestRoute? {
        guard !request.actions.isEmpty else { return .decision(.deny) }
        guard let action = PermissionActionPreference.preferred(from: request.actions, decision: .deny),
              PermissionActionPreference.scope(id: action.id, intent: action.kind) != .broad else { return nil }
        return .providerAction(action)
    }

    /// The same for a Codex server request: the answer Stop gives it (`CodexAdapter.stopAnswer`), which declines an
    /// approval, a permissions request or an MCP form and sends a question back unanswered.
    static func messageDecline(for request: CodexServerRequestState) -> ConversationRequestRoute? {
        guard request.resolution == .pending else { return nil }
        return CodexAdapter.stopAnswer(for: request.method).map { .codex($0) }
    }

    /// The denial a Codex server request that takes "Allow once" gets from the keyboard: the card's
    /// decline, or its cancel where it offers no decline; never a rule such as a host's network denial.
    static func deny(for request: CodexServerRequestState) -> ConversationRequestRoute? {
        guard allowOnce(for: request) != nil else { return nil }
        let denials = CodexRequestResponseProjection.responses(for: request)
            .filter { $0.role == .destructive }.map(\.route)
        let plain: [ConversationRequestRoute] = [
            .codex(.command(.decline)), .codex(.fileChange(.decline)), .codex(.command(.cancel)),
            .codex(.fileChange(.cancel)), .codex(.legacyReview(.abort))
        ]
        return plain.first(where: denials.contains) ?? denials.first { route in
            if case .codex(.legacyReview(.denied)) = route { true } else { false }
        }
    }

    /// The answer "Allow once" gives a Codex server request: accept, for a command or file-change
    /// approval only.
    static func allowOnce(for request: CodexServerRequestState) -> ConversationRequestRoute? {
        guard request.resolution == .pending else { return nil }
        let route: ConversationRequestRoute
        switch request.kind {
        case .commandExecutionApproval: route = .codex(.command(.accept))
        case .fileChangeApproval: route = .codex(.fileChange(.accept))
        case .applyPatchApproval, .execCommandApproval: route = .codex(.legacyReview(.approved))
        case .permissionsApproval, .toolUserInput, .mcpElicitation, .dynamicToolCall,
             .authenticationRefresh, .attestation, .currentTime, .unknown:
            return nil
        }
        let offered = CodexRequestResponseProjection.responses(for: request).map(\.route)
        return offered.contains(route) ? route : nil
    }

    /// ACP's tool kind for a call that switches the agent's mode, such as leaving plan mode.
    private static let modeSwitchKind = "switch_mode"
}

/// What the agent is told of a request or a wait that a message from the person answered
/// (`AppModel.answerWaits(_:forPersonsMessageIn:)`).
enum PersonsMessageAnswer {
    /// Where the message is: with this result where the harness takes a message during its turn, after the turn
    /// where it does not.
    static let followUp = "Go by their message rather than this request; if it did not reach you with this result, "
        + "end your turn to receive it."

    /// A request declined for it, where the harness reads a denial's words (Claude Code), as Claude Code itself closes
    /// an approval that a new message arrives after: it did not run, and the person did not refuse it.
    static let denial = "The person sent a message instead of answering this request, so it did not run. They did not "
        + "refuse it. " + followUp + " Ask again if it is still needed."
}
