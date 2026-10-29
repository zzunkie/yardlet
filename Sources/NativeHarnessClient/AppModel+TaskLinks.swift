import Foundation

// A conversation's links to other tasks (`TaskLink`): the task each one names, in Yardlet.

extension AppModel {
    /// The task a conversation's link names, or nil when Yardlet has none open: a task by its ID or
    /// by its harness's session ID, and a Claude app session by the Claude Code session its file
    /// names. Only the one session file is read; nothing starts.
    func task(linkedBy link: TaskLink) async -> SessionRecord? {
        switch link {
        case let .task(id):
            return store.sessions.first { $0.id == id } ?? task(providerSessionID: id.uuidString)
        case let .codexThread(id):
            return task(providerSessionID: id, harness: .codex)
        case let .claudeDesktopSession(id):
            let root = claudeDesktopSessionsRoot
            let cliSessionID = await Task.detached(priority: .userInitiated) {
                ClaudeDesktopSessionCatalog.session(desktopSessionID: id, in: root)?.cliSessionID
            }.value
            return cliSessionID.flatMap { task(providerSessionID: $0, harness: .claudeCode) }
        case let .cloudSession(url):
            return store.sessions.first { $0.cloudURL == url || $0.cloudTargetURL() == url }
        }
    }

    private func task(providerSessionID: String, harness: HarnessKind? = nil) -> SessionRecord? {
        let id = providerSessionID.lowercased()
        return store.sessions.first { session in
            (harness == nil || session.harness == harness) && session.providerSessionID?.lowercased() == id
        }
    }
}
