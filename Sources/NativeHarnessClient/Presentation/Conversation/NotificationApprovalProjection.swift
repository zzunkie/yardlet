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
enum NotificationApprovalProjection {
    struct PendingRequest: Equatable, Sendable {
        let id: String
        /// What "Allow once" sends; nil when the request is answered only on its card.
        let allowOnce: ConversationRequestRoute?
        /// It asks the person a question rather than for approval (`asksQuestion`), which Settings lets notify on
        /// its own switch (`TaskNotificationKind`).
        var asksQuestion = false
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
                .map { PendingRequest(id: $0.id, allowOnce: allowOnce(for: $0), asksQuestion: asksQuestion($0)) }
        }
        return transcript.compactMap { entry in
            guard case let .permission(request, .pending) = entry.content else { return nil }
            return PendingRequest(id: request.id, allowOnce: allowOnce(for: request), asksQuestion: asksQuestion(request))
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
