import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [SessionRecord]
    /// Archived tasks once `loadArchivedSessions()` or `restore()` has read them; nil before that.
    private(set) var archivedSessions: [ArchivedSessionRecord]? {
        didSet {
            archivedParentIDs = Dictionary(
                (archivedSessions ?? []).compactMap { record in record.session.parentTaskID.map { (record.id, $0) } },
                uniquingKeysWith: { first, _ in first })
        }
    }
    /// The task each archived task was started from, which the sidebar follows to nest a task whose
    /// parent is archived under the nearest task it lists (`SidebarProjection.nest`).
    private(set) var archivedParentIDs: [UUID: UUID] = [:]
    /// The shown task, or the focused split pane's task. `SplitStore` owns the arrangement and
    /// keeps this mirror in step, so existing single-selection callers and tests stay unchanged.
    var selectedSessionID: SessionRecord.ID? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            onSelectionChange?(selectedSessionID)
        }
    }
    @ObservationIgnored var onSelectionChange: ((SessionRecord.ID?) -> Void)?
    private let repository: any SessionRepository
    /// How a task folder's Git identity is read. Injected so tests can describe a worktree
    /// without one on disk; the live reader only reads Git's own files.
    @ObservationIgnored private let resolveWorkspaceOrigin: (URL) -> WorkspaceGitOrigin

    init(
        sessions: [SessionRecord] = [],
        repository: (any SessionRepository)? = nil,
        workspaceOrigin: @escaping (URL) -> WorkspaceGitOrigin = {
            GitWorktreeOriginResolver.resolve(workspaceURL: $0)
        }
    ) {
        self.sessions = sessions
        self.repository = repository ?? InMemorySessionRepository(sessions: sessions)
        self.resolveWorkspaceOrigin = workspaceOrigin
        self.selectedSessionID = sessions.first?.id
    }

    /// The folder a new task in this folder would record as its origin, when the folder is a
    /// linked worktree. The new-task path uses it to keep the task under the original project.
    func workspaceOrigin(for workspaceURL: URL) -> WorkspaceGitOrigin {
        resolveWorkspaceOrigin(workspaceURL)
    }

    func restore() async throws {
        sessions = try await repository.loadSessions()
        // The archived list's links place nested tasks from the first sidebar on; without them, a task
        // whose parent is archived waits at top level until the list is read.
        if let archived = try? await repository.loadArchivedSessions() { archivedSessions = archived }
        for index in sessions.indices where
            sessions[index].status == .running || sessions[index].status == .waitingForApproval {
            sessions[index].status = .ready
            sessions[index].updatedAt = Date()
            try await repository.upsert(sessions[index])
        }
        if let selectedSessionID,
           sessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = sessions.first?.id
    }

    /// What each task's context usage last showed, as the index keeps it beside the task.
    func loadContextUsage() async throws -> [UUID: TaskContextUsageSnapshot] {
        try await repository.loadContextUsage()
    }

    /// Keeps a task's context usage in the index. Not activity: the task itself does not change.
    func saveContextUsage(_ snapshot: TaskContextUsageSnapshot, for id: UUID) async throws {
        guard sessions.contains(where: { $0.id == id }) else { return }
        try await repository.saveContextUsage(snapshot, for: id)
    }

    var selectedSession: SessionRecord? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var workspaceGroups: [WorkspaceGroup] {
        TaskNavigationProjection.workspaceGroups(from: sessions)
    }

    @discardableResult
    func createSession(
        harness: HarnessKind,
        workspaceURL: URL,
        runtimeExecutableURL: URL,
        title: String,
        titleOrigin: SessionTitleOrigin = .manual,
        providerSessionID: String? = nil,
        environmentScope: SessionEnvironmentScope = .native,
        selectsSession: Bool = true,
        inheritedContext: SideChatContext? = nil,
        providerOptions: [String: String] = [:],
        connection: ProviderConnection? = nil,
        projectID: UUID? = nil,
        additionalRoots: [String] = [],
        workspaceOrigin knownOrigin: WorkspaceGitOrigin? = nil,
        lastActivityAt: Date? = nil,
        parentTaskID: UUID? = nil
    ) async throws -> SessionRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A task made in a linked worktree keeps the worktree as its cwd and additionally
        // remembers where it came from, so the sidebar can show it under the original project.
        // What the folder's own records say wins; a conversation imported from another app may
        // name its origin when the worktree folder is gone.
        let resolved = resolveWorkspaceOrigin(workspaceURL)
        let origin = resolved.isWorktree ? resolved : (knownOrigin ?? resolved)
        let now = Date()
        let session = SessionRecord(
            harness: harness,
            workspaceURL: workspaceURL,
            runtimeExecutableURL: runtimeExecutableURL,
            title: trimmedTitle.isEmpty ? L10n.string("New task") : trimmedTitle,
            titleOrigin: titleOrigin,
            createdAt: now,
            updatedAt: lastActivityAt ?? now,
            providerSessionID: providerSessionID,
            providerOptions: providerOptions,
            environmentScope: environmentScope,
            inheritedContext: inheritedContext,
            connection: connection,
            projectID: projectID,
            additionalRoots: additionalRoots,
            originWorkspacePath: origin.originWorkspacePath,
            worktreeName: origin.worktreeName,
            branch: origin.branch,
            parentTaskID: parentTaskID
        )

        try await repository.upsert(session)
        sessions.append(session)
        if selectsSession { selectedSessionID = session.id }
        return session
    }

    /// Fills a task's worktree origin the first time the task is opened, and only when its
    /// folder really is a linked worktree. Launch never rescans saved folders, so a row written
    /// before this record keeps its nulls until someone opens it; recency is left alone because
    /// nothing about the task itself changed.
    @discardableResult
    func recordWorkspaceOriginIfMissing(id: UUID) async throws -> SessionRecord? {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].originWorkspacePath == nil else { return nil }
        let origin = resolveWorkspaceOrigin(sessions[index].workspaceURL)
        guard origin.isWorktree else { return nil }
        return try await modify(id) {
            $0.originWorkspacePath = origin.originWorkspacePath
            $0.worktreeName = origin.worktreeName
            $0.branch = origin.branch
        }
    }

    /// - Parameter updatesRecency: whether the change is activity that moves the task up the
    ///   sidebar: a turn starting, running, waiting, ending or failing. Connecting a runtime to a
    ///   saved task, and the ready state it reports when no turn was running, are not.
    func updateSession(
        id: UUID,
        status: SessionStatus? = nil,
        providerSessionID: String? = nil,
        setProviderSessionID: Bool = false,
        hasUnreadUpdate: Bool? = nil,
        completionState: SessionCompletionState? = nil,
        inheritedContextDelivered: Bool? = nil,
        inheritedContext: SideChatContext? = nil,
        setInheritedContext: Bool = false,
        updatesRecency: Bool = true
    ) async throws {
        let now = Date()
        try await modify(id) { updated in
            if setInheritedContext { updated.inheritedContext = inheritedContext }
            if let inheritedContextDelivered { updated.inheritedContext?.isDelivered = inheritedContextDelivered }
            if let status {
                updated.status = status
            }
            if setProviderSessionID {
                updated.providerSessionID = providerSessionID
            }
            if let hasUnreadUpdate {
                updated.hasUnreadUpdate = hasUnreadUpdate
            }
            if let completionState {
                updated.completionState = completionState
            } else if let status {
                switch status {
                case .completed: updated.completionState = .completed
                case .failed: updated.completionState = .failed
                case .ready, .running, .waitingForApproval: break
                }
            }
            if updatesRecency { updated.updatedAt = now }
        }
    }

    func renameSession(
        id: UUID,
        title: String,
        titleOrigin: SessionTitleOrigin = .manual,
        updatesRecency: Bool = true
    ) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard sessions[index].title != title || sessions[index].titleOrigin != titleOrigin else { return }
        let now = Date()
        try await modify(id) {
            $0.title = title
            $0.titleOrigin = titleOrigin
            if updatesRecency { $0.updatedAt = now }
        }
    }

    /// Moves a task's last activity forward to `date`, the time a source app last worked in its
    /// conversation (`SessionListFollow`), and never back. Only the place in recency order changes:
    /// status, reading state, pin, title, project and the provider session stay as they are.
    @discardableResult
    func moveLastActivity(id: UUID, forwardTo date: Date) async throws -> SessionRecord? {
        guard let current = sessions.first(where: { $0.id == id }), current.updatedAt < date else { return nil }
        return try await modify(id) { if $0.updatedAt < date { $0.updatedAt = date } }
    }

    /// Every provider session the index has a row for, in any state (`SessionRepository`), with
    /// the tasks listed now.
    func indexedProviderSessions() async throws -> Set<SessionListFollow.IndexedSession> {
        var indexed = try await repository.indexedProviderSessions()
        for session in sessions {
            if let id = session.providerSessionID {
                indexed.insert(SessionListFollow.IndexedSession(harness: session.harness, providerSessionID: id))
            }
        }
        return indexed
    }

    func togglePinned(id: UUID) async throws {
        guard let pinned = sessions.first(where: { $0.id == id })?.isPinned else { return }
        try await modify(id) { $0.isPinned = !pinned }
    }

    /// Puts a task in another project, or in none (`projectID` nil), with the roots that come along.
    /// Nothing else changes: the folder, provider session, storage scope, account, title, status,
    /// pin, and the task's place in recency order, because a move is not activity.
    @discardableResult
    func moveSession(id: UUID, toProject projectID: UUID?, additionalRoots: [String]) async throws -> SessionRecord? {
        try await modify(id) { $0.assignProject(projectID, additionalRoots: additionalRoots) }
    }

    /// Records the task each task was started from (`TaskLineage`), only for a task that has none
    /// yet: a link already recorded is never replaced, a task the person detached to the top level
    /// is never linked again, and a link that would make a task its own ancestor is skipped.
    /// Linking is not activity, so the tasks keep their place. Returns the tasks it linked.
    @discardableResult
    func linkParents(_ links: [UUID: UUID]) async throws -> [UUID] {
        var linked: [UUID] = []
        for (child, parent) in links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard child != parent, let current = sessions.first(where: { $0.id == child }),
                  current.parentTaskID == nil, !current.isLineageDetached,
                  !TaskLineage.isAncestor(child, of: parent, in: sessions) else { continue }
            if try await modify(child, {
                if $0.parentTaskID == nil, !$0.isLineageDetached { $0.parentTaskID = parent }
            })?.parentTaskID == parent {
                linked.append(child)
            }
        }
        return linked
    }

    /// "Detach to top level": the task leaves the family it is listed in and stays at the top level,
    /// as the Claude app records `lineageDetached`; links read later are not recorded for it
    /// (`linkParents`). Detaching is not activity, so the task keeps its place; the tasks started
    /// from it stay with it.
    @discardableResult
    func detachFromParent(id: UUID) async throws -> SessionRecord? {
        try await modify(id) {
            $0.parentTaskID = nil
            $0.isLineageDetached = true
        }
    }

    /// Keeps a setting the task runs with (its model, effort, mode). A setting is not activity:
    /// the task stays where its last turn put it in the sidebar.
    func updateProviderOption(id: UUID, optionID: String, value: String) async throws {
        try await modify(id) {
            $0.providerOptions[optionID] = value
        }
    }

    func removeProviderOption(id: UUID, optionID: String) async throws {
        try await modify(id) {
            $0.providerOptions.removeValue(forKey: optionID)
        }
    }

    /// Points a task at the runtime it continues with after the recorded one disappeared. The
    /// provider session, its storage scope, and its account binding stay exactly as they were.
    @discardableResult
    func updateRuntimeExecutable(id: UUID, to url: URL) async throws -> SessionRecord? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = sessions[index]
        updated.runtimeExecutableURL = url.standardizedFileURL
        guard updated.runtimeExecutableURL != sessions[index].runtimeExecutableURL else { return updated }
        try await repository.upsert(updated)
        guard let currentIndex = sessions.firstIndex(where: { $0.id == id }) else { return updated }
        sessions[currentIndex].runtimeExecutableURL = updated.runtimeExecutableURL
        return sessions[currentIndex]
    }

    func updateConnection(id: UUID, connection: ProviderConnection) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw ProviderConnectionError.invalidBinding }
        try connection.validate(for: sessions[index].harness)
        var updated = sessions[index]
        updated.connection = connection
        try await repository.upsert(updated)
        guard let currentIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[currentIndex].connection = connection
    }

    /// Archives a task so it can be restored from the archived list. `providerArchived` says the
    /// provider's thread was archived as well.
    func archiveSession(id: UUID, providerArchived: Bool = false) async throws {
        let record = sessions.first { $0.id == id }
        try await repository.archive(id: id, providerArchived: providerArchived)
        removeFromIndex(id)
        if let record, archivedSessions != nil {
            archivedSessions?.removeAll { $0.id == id }
            archivedSessions?.insert(
                ArchivedSessionRecord(session: record, archivedAt: Date(), isProviderArchived: providerArchived),
                at: 0
            )
        }
    }

    /// Removes a deleted task, or one a failed fork, import, or side chat created, without
    /// listing it among archived tasks.
    func discardSession(id: UUID) async throws {
        try await repository.discard(id: id)
        removeFromIndex(id)
    }

    func loadArchivedSessions() async throws {
        archivedSessions = try await repository.loadArchivedSessions()
    }

    /// Puts an archived task back in the index with its provider session, storage scope,
    /// account binding, and project exactly as they were. A task archived mid-turn comes back
    /// ready, the way relaunch restores one, because no turn is running for it any more.
    /// Returns nil, and drops the stale row, when the index no longer has it archived.
    @discardableResult
    func unarchiveSession(id: UUID) async throws -> SessionRecord? {
        guard var restored = try await repository.unarchive(id: id) else {
            archivedSessions?.removeAll { $0.id == id }
            return nil
        }
        if restored.status == .running || restored.status == .waitingForApproval {
            restored.status = .ready
            try await repository.upsert(restored)
        }
        archivedSessions?.removeAll { $0.id == id }
        sessions.removeAll { $0.id == id }
        // Keep the index's recency order; the task returns where its last activity puts it.
        let index = sessions.firstIndex { $0.updatedAt < restored.updatedAt } ?? sessions.endIndex
        sessions.insert(restored, at: index)
        return restored
    }

    /// A task that goes while it is on screen leaves the window on the home: the person is done with
    /// it, and the most recent other task would open (and read as read) without being chosen.
    private func removeFromIndex(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = nil
        }
    }

    func markRead(id: UUID) async {
        guard sessions.first(where: { $0.id == id })?.hasUnreadUpdate == true else { return }
        do {
            try await modify(id) { $0.hasUnreadUpdate = false }
        } catch {
            // Read state is advisory UI metadata; keep the in-memory selection usable if a
            // background index write is unavailable.
            if let current = sessions.firstIndex(where: { $0.id == id }) { sessions[current].hasUnreadUpdate = false }
        }
    }

    /// "Mark all as read" in the activity view: each task in turn, as opening it would.
    func markRead(ids: [UUID]) async {
        for id in ids { await markRead(id: id) }
    }

    func markUnread(id: UUID) async {
        guard sessions.first(where: { $0.id == id })?.hasUnreadUpdate == false else { return }
        do {
            try await modify(id) { $0.hasUnreadUpdate = true }
        } catch {
            if let current = sessions.firstIndex(where: { $0.id == id }) { sessions[current].hasUnreadUpdate = true }
        }
    }

    /// Saves one change to a task, then makes the same change to the task as it is once the save
    /// is done. Other changes to the task can finish during the save, and writing back the copy
    /// taken before it would undo them; archiving or deleting tasks can also move or remove rows.
    /// When those other changes are in the record, it is saved once more so the index matches.
    @discardableResult
    private func modify(_ id: UUID, _ change: (inout SessionRecord) -> Void) async throws -> SessionRecord? {
        guard var updated = sessions.first(where: { $0.id == id }) else { return nil }
        change(&updated)
        try await repository.upsert(updated)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        change(&sessions[index])
        let current = sessions[index]
        if current != updated { try await repository.upsert(current) }
        return current
    }
}
