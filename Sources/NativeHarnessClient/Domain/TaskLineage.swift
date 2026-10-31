import Foundation

/// Which task a task was started from, the same for every harness (`SessionRecord.parentTaskID`).
/// Each harness says it in its own words, and every one of them ends up here as a provider session
/// ID of the parent, which becomes the parent's Yardlet task:
///
/// - Claude: the Claude app's session file, `spawnedFrom.sessionId` (a session another session
///   started, unless the person moved it to top level, `lineageDetached`), read through
///   `ClaudeDesktopSessionCatalog`; the CLI's own transcript does not record it.
/// - A task the person placed in Yardlet ("Detach to top level", or moved under another task in the
///   sidebar, `SessionRecord.isLineageDetached`) keeps the place the person gave it, whatever a
///   harness or another app says later.
/// - Codex: the App Server thread's `forkedFromId` (a fork) or `parentThreadId` (a subagent).
/// - Yardlet itself, for any harness: a fork, an opened Codex subagent, and the original opened
///   from an edited conversation record the task they came from when they are made. A side chat,
///   which lives in its parent's side panel, and a blank new chat are not children.
enum TaskLineage {
    /// Whether `ancestor` is `task` itself or a task it descends from, through archived tasks too
    /// when `archivedParents` (`SessionStore.archivedParentIDs`) is given.
    static func isAncestor(_ ancestor: UUID, of task: UUID, in sessions: [SessionRecord],
                           archivedParents: [UUID: UUID] = [:]) -> Bool {
        let parents = Dictionary(sessions.map { ($0.id, $0.parentTaskID) }, uniquingKeysWith: { first, _ in first })
        var current: UUID? = task
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = parents[id] ?? archivedParents[id]
        }
        return false
    }

    /// The Yardlet task that continues the provider session `providerSessionID` of `harness`, the
    /// parent a link names. A task in the list wins over one only archived. When a storage scope
    /// is supplied, both that scope and its saved account binding must match, including nil for
    /// the default account. Codex thread IDs alone do not identify a task across homes.
    static func task(
        continuing providerSessionID: String?,
        harness: HarnessKind,
        among sessions: [SessionRecord],
        archived: [SessionRecord] = [],
        environmentScope: SessionEnvironmentScope? = nil,
        connection: ProviderConnection? = nil
    ) -> UUID? {
        guard let wanted = providerSessionID?.lowercased(), !wanted.isEmpty else { return nil }
        func matches(_ session: SessionRecord) -> Bool {
            guard session.harness == harness, session.providerSessionID?.lowercased() == wanted else { return false }
            guard let environmentScope else { return true }
            return session.environmentScope == environmentScope && session.connection == connection
        }
        return (sessions.first(where: matches) ?? archived.first(where: matches))?.id
    }

    /// Links for the tasks whose provider session another session of the same harness started,
    /// given each child's parent by provider session ID (`parents`, child → parent). Only a task
    /// with no link yet, and not detached to the top level, is linked, and only to a task that is
    /// in Yardlet too.
    static func links(
        parents: [String: String],
        harness: HarnessKind,
        sessions: [SessionRecord],
        archived: [SessionRecord] = []
    ) -> [UUID: UUID] {
        guard !parents.isEmpty else { return [:] }
        let byChild = Dictionary(parents.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var links: [UUID: UUID] = [:]
        for session in sessions where session.harness == harness && session.parentTaskID == nil
            && !session.isLineageDetached {
            guard let child = session.providerSessionID?.lowercased(), let parentID = byChild[child],
                  let parent = task(continuing: parentID, harness: harness, among: sessions, archived: archived,
                                    environmentScope: harness == .codex ? session.environmentScope : nil,
                                    connection: session.connection),
                  parent != session.id else { continue }
            links[session.id] = parent
        }
        return links
    }

    /// The thread a Codex thread was started from: the one it was forked from, else the one whose
    /// subagent it is.
    static func codexParentThreadID(forkedFromID: String?, parentThreadID: String?) -> String? {
        [forkedFromID, parentThreadID].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
