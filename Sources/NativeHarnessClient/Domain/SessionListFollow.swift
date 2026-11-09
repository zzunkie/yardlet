import Foundation

/// Keeping Yardlet's task list in step with the Claude app's Code sessions and the Codex threads a
/// person started, the way the Codex app shows every thread in `~/.codex` without an import step
/// (docs/NATIVE_SESSION_STORAGE.md, "Following the session list"). The
/// sources are only read. What changes is Yardlet's own index: a new task through the import path,
/// a task's last activity moved forward, a provider title, a task archived in Yardlet. These are
/// the rules; `AppModel.followSessionLists` reads the sources and applies them.
enum SessionListFollow {
    /// At most one pass this often: once after launch, then when the app becomes active.
    static let interval: TimeInterval = 10 * 60

    /// A conversation as a source lists it, open or archived there.
    struct Entry: Equatable, Sendable {
        /// What importing it needs; `updatedAt` is the source's last activity.
        var conversation: ImportableConversation
        var isArchived: Bool
        /// The title the source keeps for it, when it keeps one: the Claude app's own title, a
        /// Codex thread's name. A title made from the first request is not one to follow.
        var sourceTitle: String?

        var lastActivity: Date { conversation.updatedAt }
    }

    /// What one pass changes in Yardlet's index.
    struct Plan: Equatable, Sendable {
        /// Conversations that come in as new tasks, through the import path.
        var imports: [ImportableConversation] = []
        /// Tasks whose last activity moves forward to the source's.
        var activity: [UUID: Date] = [:]
        /// Tasks whose provider title becomes the source's.
        var titles: [UUID: String] = [:]
        /// Listed tasks the source archived, archived in Yardlet only, each with the source's last
        /// activity, which the task's own must not be past when it is archived.
        var archives: [UUID: Date] = [:]
        /// Tasks the person kept listed in Yardlet that the source lists open again, so a later
        /// archive there counts once more.
        var keptListedReleased: Set<UUID> = []

        var isEmpty: Bool {
            imports.isEmpty && activity.isEmpty && titles.isEmpty && archives.isEmpty && keptListedReleased.isEmpty
        }
    }

    /// A provider session in Yardlet's index, in any state, under any account or storage scope.
    struct IndexedSession: Hashable, Sendable {
        let harness: HarnessKind
        let providerSessionID: String

        init(harness: HarnessKind, providerSessionID: String) {
            self.harness = harness
            self.providerSessionID = providerSessionID.lowercased()
        }
    }

    /// What Yardlet knows when it plans a pass.
    struct State {
        /// The tasks in the list.
        var tasks: [SessionRecord]
        /// Every provider session the index has a row for, listed, archived or deleted, and the
        /// sessions attached right now, whose IDs may not be saved yet.
        var indexed: Set<IndexedSession>
        /// The listed task that continues this conversation under the same history, as the import
        /// sheet finds it (`AppModel.existingTask`).
        var task: (ImportableConversation) -> SessionRecord?
        /// Whether a task has work or input of the person's that archiving would cut off or lose.
        var isBusy: (SessionRecord) -> Bool
        /// Tasks the person brought back from the archive in Yardlet while the source still had
        /// them archived.
        var keptListed: Set<UUID> = []
        /// A folder whose conversations are not followed (`isTemporaryFolder`).
        var skipsFolder: (URL) -> Bool = SessionListFollow.isTemporaryFolder
        var now = Date()
    }

    static func plan(_ entries: [Entry], state: State) -> Plan {
        var plan = Plan()
        var planned = Set<String>()
        var seenTasks = Set<UUID>()
        for entry in entries {
            let conversation = entry.conversation
            if let task = state.task(conversation) {
                // A task followed once per pass, from the first (most recent) entry naming it.
                guard seenTasks.insert(task.id).inserted else { continue }
                if entry.isArchived {
                    if canArchive(task, archivedAt: entry, state: state) { plan.archives[task.id] = entry.lastActivity }
                    continue
                }
                if state.keptListed.contains(task.id) { plan.keptListedReleased.insert(task.id) }
                if entry.lastActivity > task.updatedAt { plan.activity[task.id] = entry.lastActivity }
                if task.titleOrigin == .provider,
                   let title = SessionTitleProjection.normalizedProviderTitle(entry.sourceTitle), title != task.title {
                    plan.titles[task.id] = title
                }
                continue
            }
            guard !entry.isArchived,
                  !state.indexed.contains(IndexedSession(harness: conversation.harness,
                                                         providerSessionID: conversation.providerSessionID)),
                  !state.skipsFolder(conversation.workspaceURL),
                  !mayBeStarting(conversation, tasks: state.tasks, now: state.now),
                  planned.insert(conversation.id).inserted else { continue }
            plan.imports.append(conversation)
        }
        return plan
    }

    /// A listed task leaves the list when its source archived it, unless the person is working in
    /// it, has input waiting in it, continued it in Yardlet after its last activity there, pinned
    /// it, or brought it back from Yardlet's archive.
    static func canArchive(_ task: SessionRecord, archivedAt entry: Entry, state: State) -> Bool {
        !task.isPinned && !state.keptListed.contains(task.id) && !state.isBusy(task)
            && task.updatedAt <= entry.lastActivity
    }

    /// Whether a Yardlet task that has no provider session yet may be the one this conversation
    /// belongs to: same harness and folder, made in the last pass interval, and not after the
    /// conversation's last activity. A native Codex task's thread is listed as soon as it starts,
    /// a moment before the task records its ID; it is left for the next pass.
    static func mayBeStarting(_ conversation: ImportableConversation, tasks: [SessionRecord], now: Date) -> Bool {
        let folder = ProjectSidebarPresentation.normalizedPath(for: conversation.workspaceURL)
        return tasks.contains { task in
            task.harness == conversation.harness && task.providerSessionID == nil
                && now.timeIntervalSince(task.createdAt) < interval
                && task.createdAt <= conversation.updatedAt.addingTimeInterval(60)
                && ProjectSidebarPresentation.normalizedPath(for: task.workspaceURL) == folder
        }
    }

    /// Conversations in a temporary folder are test or scratch runs, not work to follow: the
    /// user's temporary directory, `/private/var/folders` and `/tmp`.
    static func isTemporaryFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let temporary = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let roots = [temporary, "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        return roots.contains { PathRules.current.isInside(path, folder: $0) }
    }

    /// When a pass may start: one at a time, at most once per `interval` unless the person asked.
    struct Schedule: Equatable, Sendable {
        private(set) var lastStart: Date?
        private(set) var isRunning = false

        /// Starts a pass at `now` when one is due (or `asked`) and none is running.
        mutating func begin(at now: Date, asked: Bool = false) -> Bool {
            guard !isRunning else { return false }
            if !asked, let lastStart, now.timeIntervalSince(lastStart) < SessionListFollow.interval { return false }
            lastStart = now
            isRunning = true
            return true
        }

        mutating func end() { isRunning = false }
    }
}
