import Foundation

/// The two halves of "Rename from Recent Conversation" (`renameFromRecentConversation`): what the
/// task's conversation says now, and the harness's side call that names it.
extension AppModel {
    /// The excerpt of the task's latest turns (`RecentConversationTitle.excerpt`). A task nothing has
    /// shown yet reads its saved history first, as the routing evaluation does; no turn starts.
    func recentConversationExcerpt(of session: SessionRecord) async -> String? {
        if transcriptBySessionID[session.id]?.isEmpty != false, codexPresentationBySessionID[session.id] == nil {
            await refreshConversationStatus(for: session)
        }
        guard let current = store.sessions.first(where: { $0.id == session.id }) else { return nil }
        // Only the end is projected; turns without words leave room for ones further back.
        let reading = RecentConversationTitle.turnLimit * 2
        let presentation = sessionToolPresentation(of: current) { ids in max(0, ids.count - reading)..<ids.count }
        return RecentConversationTitle.excerpt(of: presentation.turns)
    }

    /// The name the task's harness suggests for `excerpt`, from its smallest current model on the
    /// task's account: Claude Code's latest Haiku through `claude -p`, Codex's newest luna on a side
    /// thread of the account's App Server.
    func recentConversationTitle(for session: SessionRecord, excerpt: String) async throws -> String {
        // Asked of the CLI the task runs now, its harness's current runtime.
        let session = await sessionWithCurrentRuntime(session)
        switch session.harness {
        case .claudeCode:
            let executable = await startedExecutable(of: session)
            guard ExecutableLookup.current.isProgram(executable) else {
                throw HarnessAdapterError.runtimeNotFound(executable)
            }
            return try await ClaudeTitleRequest.run(
                executableURL: executable, environment: session.connection?.environment ?? [:],
                model: RecentConversationTitle.claudeModel(from: modelCatalogs.claudeModels(for: session.connection)),
                prompt: RecentConversationTitle.prompt(for: excerpt, structured: false))
        default:
            // The adapter the task attaches with, or the one its detached history is read with.
            try session.connection?.validate(for: session.harness)
            let adapter = await registryAdapter(for: session)
            guard let suggesting = adapter as? any HarnessTaskTitleSuggesting else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.format("%@ did not suggest a name.", session.harness.displayName))
            }
            return try await suggesting.suggestTaskTitle(fromRecentConversation: excerpt)
        }
    }
}
