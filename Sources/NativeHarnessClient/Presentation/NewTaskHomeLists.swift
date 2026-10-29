import Foundation

/// What a row on the new-task screen does when it is chosen. Nothing here sends anything: a draft
/// row only fills the composer, and the person sends it (as a suggested task's chip does).
enum NewTaskHomeAction: Equatable, Sendable {
    /// Opens the task, as its sidebar row does.
    case openTask(UUID)
    /// Answers the task in the composer's place: its own conversation and composer take the new
    /// task's title and composer (`NewTaskHome`), until the person replies or leaves.
    case reply(UUID)
    /// Puts the prompt in the new-task draft.
    case draft(String)
    /// Chooses New worktree for the new task.
    case useNewWorktree
    /// Starts the new task in the project, as its name in the title's menu does.
    case chooseProject(UUID)
    /// Starts the new task as a chat with no project.
    case chooseChat
    /// Opens the schedule in Scheduled tasks.
    case openSchedule(UUID)
}

/// The chosen folder's Git checkout, as the "In this folder" rows need it. The branch is read from
/// Git's files; the uncommitted files are counted by `git --no-optional-locks status`, which writes
/// nothing, and only for a branch that is not the default one (the only row that shows them).
struct NewTaskFolderGitState: Equatable, Sendable {
    var isRepository = false
    var branch: String?
    /// The branch is the remote's default one (`main` in most), which work in progress is not on.
    var isDefaultBranch = false
    /// Nil when not counted.
    var uncommittedFiles: Int?

    static let none = NewTaskFolderGitState()

    /// Reads the folder's state off the main actor.
    static func read(_ folder: URL, git: GitDiffService = GitDiffService(processTimeout: .seconds(5))) async
        -> NewTaskFolderGitState {
        let files = await Task.detached(priority: .utility) { () -> NewTaskFolderGitState in
            guard GitWorktreeOriginResolver.isInRepository(folder) else { return .none }
            let branch = GitWorktreeOriginResolver.currentBranch(folder)
            let isDefault = branch.map { GitWorktreeOriginResolver.defaultBranches(folder).contains($0) } ?? false
            return NewTaskFolderGitState(isRepository: true, branch: branch, isDefaultBranch: isDefault)
        }.value
        guard files.branch != nil, !files.isDefaultBranch else { return files }
        var state = files
        state.uncommittedFiles = try? await git.uncommittedFileCount(workspaceURL: folder)
        return state
    }
}

extension GitLeftWork {
    /// How long a project's reading stands before the home reads its folder again: the screen comes
    /// back often, and a project left alone changes little meanwhile.
    static let readingLifetime: Duration = .seconds(10 * 60)

    /// Reads a project's folder off the main actor (`GitDiffService.leftWork`), once per
    /// `readingLifetime`. Nil outside Git or when Git fails.
    static func read(_ folder: URL) async -> GitLeftWork? {
        await GitLeftWorkReadings.shared.reading(of: folder)
    }
}

/// The projects' latest readings, shared by every home this app shows.
private actor GitLeftWorkReadings {
    static let shared = GitLeftWorkReadings()
    private var readings: [String: (work: GitLeftWork?, at: ContinuousClock.Instant)] = [:]
    private let git = GitDiffService(processTimeout: .seconds(10))

    func reading(of folder: URL) async -> GitLeftWork? {
        let key = ProjectSidebarPresentation.normalizedPath(for: folder)
        if let kept = readings[key], ContinuousClock.now - kept.at < GitLeftWork.readingLifetime { return kept.work }
        let work = try? await Task.detached(priority: .utility) { [git] in try await git.leftWork(workspaceURL: folder) }.value
        readings[key] = (work, .now)
        return work
    }
}

/// A project left alone for a while that still holds unfinished work, as the home names it
/// (`NewTaskHomeListsProjection.idleProjects`): when it was last active and what it left.
struct NewTaskIdleProject: Equatable, Identifiable, Sendable {
    let project: Project
    /// Its most recent task, which a double-click opens.
    let latestTask: SessionRecord
    let lastActive: Date
    var git = GitLeftWork()
    /// Its tasks' open pull requests, most recent first.
    var pullRequests: [NewTaskPullRequestRow] = []
    /// Its schedules that turned themselves off.
    var stoppedSchedules = 0
    /// Tasks its agents suggested that were neither started nor dismissed.
    var suggestions = 0

    var id: UUID { project.id }

    var hasWorkLeft: Bool { !git.isEmpty || !pullRequests.isEmpty || stoppedSchedules > 0 || suggestions > 0 }

    /// What it left, in words: the pull requests first, then the folder's state, schedules and
    /// suggestions.
    var workLeft: [String] {
        var words: [String] = []
        func count(_ value: Int, _ one: @autoclosure () -> String, _ many: (Int) -> String) {
            guard value > 0 else { return }
            words.append(value == 1 ? one() : many(value))
        }
        count(pullRequests.count, L10n.string("1 open pull request")) { L10n.format("%lld open pull requests", $0) }
        count(git.uncommittedFiles, L10n.string("1 uncommitted file")) { L10n.format("%lld uncommitted files", $0) }
        count(git.unpushedCommits, L10n.string("1 unpushed commit")) { L10n.format("%lld unpushed commits", $0) }
        count(git.openWorktrees, L10n.string("1 worktree with work left")) {
            L10n.format("%lld worktrees with work left", $0)
        }
        count(stoppedSchedules, L10n.string("1 stopped schedule")) { L10n.format("%lld stopped schedules", $0) }
        count(suggestions, L10n.string("1 suggestion not started")) { L10n.format("%lld suggestions not started", $0) }
        return words
    }
}

/// One of the rows the Claude app puts on a new session's first turn (`c73f45bc3-*.js` `Sl`), for the
/// folder the new task starts in, in the order that app lists them. Review comments are not here:
/// they need the unresolved review threads, which Yardlet's pull request lookup does not read.
enum NewTaskFolderRow: Equatable, Identifiable, Sendable {
    /// A task in this folder waits for an approval or an answer.
    case waiting(SessionRecord, TaskPendingRequest)
    /// A task in this folder is running and the new one would start beside it, in the same checkout.
    case runningHere(SessionRecord)
    /// A task in this folder has a pull request from the folder's branch whose checks fail.
    case failingChecks(SessionRecord, branch: String)
    /// The folder is on a branch other than the default one, with files not yet committed.
    case continueBranch(branch: String, uncommittedFiles: Int)
    /// The most recent task in this folder.
    case resume(SessionRecord)

    var id: String {
        switch self {
        case let .waiting(task, _): "waiting:\(task.id)"
        case let .runningHere(task): "running:\(task.id)"
        case let .failingChecks(task, _): "checks:\(task.id)"
        case let .continueBranch(branch, _): "branch:\(branch)"
        case let .resume(task): "resume:\(task.id)"
        }
    }

    var action: NewTaskHomeAction {
        switch self {
        case let .waiting(task, _), let .resume(task): .openTask(task.id)
        case .runningHere: .useNewWorktree
        case let .failingChecks(_, branch):
            .draft(L10n.format("Fix the failing CI checks on %@: find out why they fail and fix them.", branch))
        case let .continueBranch(branch, _):
            .draft(L10n.format("Continue the work in progress on %@: look at the uncommitted changes, tell me what state they’re in, and finish what’s started.", branch))
        }
    }

    /// The Claude app's words for the row (`/pzMA+qaRi`, `Z61amEZusU`, `SrTU7wr19B`, `8mRiC8DEly`, `ycaFd/l54A`).
    var title: String {
        switch self {
        case let .waiting(task, _): L10n.format("%@ is waiting on you", task.title)
        case .runningHere: L10n.string("Another session is running here")
        case let .failingChecks(_, branch): L10n.format("Fix the failing checks on %@", branch)
        case let .continueBranch(branch, _): L10n.format("Continue on %@", branch)
        case let .resume(task): L10n.format("Resume “%@”", task.title)
        }
    }

    /// The quieter words after the title (`Sd5SR9sneP`, `WuRoLHVt6Y`, `L4aVCBm8Ds`, `YdF9hMzOl5`,
    /// `LN3XHCjJRQ`); a resumed task shows when it was last active instead.
    var detail: String? {
        switch self {
        case .waiting(_, .input): L10n.string("asked a question")
        case .waiting(_, .approval): L10n.string("needs a permission")
        case .runningHere: L10n.string("turn on New worktree to keep their changes apart")
        case .failingChecks: L10n.string("CI failed")
        case let .continueBranch(_, count):
            count == 1 ? L10n.string("1 uncommitted file") : L10n.format("%lld uncommitted files", count)
        case .resume: nil
        }
    }

    /// The task the row is about, whose harness it shows.
    var task: SessionRecord? {
        switch self {
        case let .waiting(task, _), let .runningHere(task), let .failingChecks(task, _), let .resume(task): task
        case .continueBranch: nil
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "hand.raised"
        case .runningHere: "arrow.triangle.branch"
        case .failingChecks: "xmark.octagon"
        case .continueBranch: "pencil.line"
        case .resume: "arrow.uturn.forward"
        }
    }
}

/// A task that needs the person, with the mark and name its sidebar row shows, on its project's
/// lines: waiting (an approval, an answer, a failed turn, a plan limit) or an unread result.
struct NewTaskAttentionRow: Equatable, Identifiable, Sendable {
    let session: SessionRecord
    /// `SidebarTaskIndicatorProjection.status`, the sidebar row's mark.
    let status: SidebarTaskStatus
    /// The first line of the latest answer, under an unread result's title.
    var answerLine: String? = nil
    var id: UUID { session.id }

    /// The person must do something; an unread result only waits to be read.
    var waitsOnPerson: Bool { status != .unread }
    /// An unread result can be marked read from the row; a waiting task stays until it is answered.
    var canMarkRead: Bool {
        guard session.hasUnreadUpdate else { return false }
        switch status {
        case .awaitingApproval, .needsInput, .waitingInBrowser: return false
        default: return true
        }
    }
}

/// An open pull request a task made, as its project's pill.
struct NewTaskPullRequestRow: Equatable, Identifiable, Sendable {
    let session: SessionRecord
    let pullRequest: TaskPullRequest
    var id: String { pullRequest.url.absoluteString }

    /// The Claude app's state pill for an open pull request, from what Yardlet asks GitHub: changes
    /// requested, failing checks and running checks first, then approved and passing.
    var pill: (title: String, tone: TaskPullRequestBadge.Tone) {
        if pullRequest.review == .changesRequested { return (TaskPullRequestBadge.label(.changesRequested), .failure) }
        switch pullRequest.checks {
        case .failing: return (TaskPullRequestBadge.label(.failing), .failure)
        case .pending: return (TaskPullRequestBadge.label(.pending), .pending)
        case .passing, nil: break
        }
        if pullRequest.review == .approved { return (TaskPullRequestBadge.label(.approved), .success) }
        if pullRequest.checks == .passing { return (TaskPullRequestBadge.label(.passing), .success) }
        return (TaskPullRequestBadge.label(.open), .success)
    }
}

/// What the new-task screen shows: each project with its tasks, results, pull requests and what comes
/// up there (`projectSummaries`), and the Claude app's first-turn rows for the chosen folder
/// (`folderRows`). Attention comes only from `TaskAttentionProjection`, so what waits on the person
/// is exactly what `⌥⌘A` goes through, the Dock badge counts and the sidebar marks. Everything is read
/// from Yardlet's own records, the pull request lookup and the folders' Git files; no harness or model
/// is asked.
enum NewTaskHomeListsProjection {
    /// How many recent tasks the screen asks the pull request lookup about, beside the folder's own.
    static let pullRequestCandidateLimit = 12
    /// How many of the folder's tasks it asks about.
    static let folderPullRequestCandidateLimit = 3

    /// The Claude app's landing lists show 3 rows per section, and one more for each of 800, 900, 1000
    /// and 1100 points the window is taller than (`dU`): 3 to 7. The home shows that many projects per
    /// column.
    static func rowLimit(windowHeight: CGFloat) -> Int {
        3 + [800, 900, 1000, 1100].filter { windowHeight > CGFloat($0) }.count
    }

    /// The "In this folder" rows, for a new task starting in `folder`. A chat has none.
    ///
    /// - Parameters:
    ///   - sessions: the tasks the sidebar lists (archived ones never are).
    ///   - isInRepository: the folder is in Git, read when it was chosen (the worktree choice's own reading).
    static func folderRows(
        folder: URL?, startsChat: Bool, isInRepository: Bool, startsInNewWorktree: Bool,
        git: NewTaskFolderGitState, sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        pullRequest: (UUID) -> TaskPullRequest? = { _ in nil }
    ) -> [NewTaskFolderRow] {
        guard let folder, !startsChat else { return [] }
        let path = ProjectSidebarPresentation.normalizedPath(for: folder)
        let here = sessions
            .filter { ProjectSidebarPresentation.normalizedPath(for: $0.workspaceURL) == path }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
        var rows: [NewTaskFolderRow] = []

        // The first task here that waits on the person, in attention order (most recent first).
        let waiting = TaskAttentionProjection.attentionList(in: here, details: details, shellBusy: shellBusy)
            .lazy.compactMap { task in
                TaskAttentionProjection.waitingRequest(of: task, detail: details[task.id]).map { (task, $0) }
            }.first
        if let (task, request) = waiting { rows.append(.waiting(task, request)) }

        // The same-folder warning, which this row now carries.
        if let running = NewTaskFolderConflict.runningTask(
            in: folder, isInRepository: isInRepository, startsInNewWorktree: startsInNewWorktree,
            startsChat: startsChat, sessions: here) {
            rows.append(.runningHere(running))
        }

        // A pull request from the branch the folder is on, open or draft, with failing checks.
        if let branch = git.branch {
            let failing = here.first { task in
                guard let pr = pullRequest(task.id), pr.state == .open || pr.state == .draft,
                      pr.checks == .failing else { return false }
                switch pr.source {
                case let .branch(name): return name == branch
                // A link the task's own conversation names: its branch is the folder's, unless the
                // folder is back on the default branch.
                case .transcriptLink: return !git.isDefaultBranch
                }
            }
            if let failing { rows.append(.failingChecks(failing, branch: branch)) }
        }

        if let branch = git.branch, !git.isDefaultBranch, let count = git.uncommittedFiles, count > 0 {
            rows.append(.continueBranch(branch: branch, uncommittedFiles: count))
        }

        // The most recent task here that no row above already opens.
        let opened = Set(rows.compactMap { row -> UUID? in
            if case let .openTask(id) = row.action { return id }
            return nil
        })
        if let recent = here.first(where: { !opened.contains($0.id) }) { rows.append(.resume(recent)) }
        return rows
    }

    /// Every task that needs the person — waiting for an approval or an answer (a system error or a
    /// usage limit included), or with a result not yet read — in `⌥⌘A`'s order. A running task is not
    /// here (`runningRows`).
    static func attentionRows(
        sessions: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        answerLine: (UUID) -> String? = { _ in nil }
    ) -> [NewTaskAttentionRow] {
        TaskAttentionProjection.attentionList(in: sessions, details: details, shellBusy: shellBusy).compactMap { session in
            SidebarTaskIndicatorProjection.status(of: session, detail: details[session.id],
                                                  isShellBusy: shellBusy.contains(session.id))
                .map { status in
                    NewTaskAttentionRow(session: session, status: status,
                                        answerLine: status == .unread ? answerLine(session.id) : nil)
                }
        }
    }

    /// Running: every task whose turn or bash-mode command is running and that waits on nothing, in
    /// attention order. A running task under another running one is counted on that one's row rather
    /// than listed, as the sidebar nests it.
    static func runningRows(
        sessions: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        agents: (UUID) -> Int = { _ in 0 }, latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil }
    ) -> [NewTaskRunningRow] {
        let running = TaskAttentionProjection.activityList(in: sessions, details: details, shellBusy: shellBusy)
            .filter { TaskAttentionProjection.place(of: $0, details: details, shellBusy: shellBusy).state == .active }
        let runningIDs = Set(running.map(\.id))
        let parents = Dictionary(sessions.map { ($0.id, $0.parentTaskID) }, uniquingKeysWith: { first, _ in first })
        /// The highest running task above `id`, through any number of levels.
        func listedAncestor(of id: UUID) -> UUID? {
            var listed: UUID?
            var seen: Set<UUID> = [id]
            var next = parents[id] ?? nil
            while let parent = next, seen.insert(parent).inserted {
                if runningIDs.contains(parent) { listed = parent }
                next = parents[parent] ?? nil
            }
            return listed
        }
        var nested: [UUID: Int] = [:]
        for task in running { if let ancestor = listedAncestor(of: task.id) { nested[ancestor, default: 0] += 1 } }
        return running.filter { listedAncestor(of: $0.id) == nil }.map { task in
            NewTaskRunningRow(session: task, subtasks: nested[task.id, default: 0] + agents(task.id),
                              since: latestTurn(task.id)?.startedAt ?? task.updatedAt)
        }
    }

    /// How long a project stays on the home after its last activity: the Claude app's seven days (`zH`).
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// How long a project goes without activity before the home names what it left unfinished. The
    /// person's own projects go quiet for a weekend and come back; three days is past that.
    static let idleAfter: TimeInterval = 3 * 24 * 60 * 60

    /// The projects that may have been left: a task is still listed there (archiving every task
    /// closes a project out), none of them needs the person or runs, the latest was active
    /// `idleAfter` or longer ago, and the person has not set it aside since (`Project.setAsideThrough`).
    /// The most recently left first. Their folders are read for what they left (`GitLeftWork.read`)
    /// and their latest tasks asked about pull requests.
    static func idleCandidates(
        groups: [WorkspaceGroup], details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        now: Date = Date()
    ) -> [(project: Project, latest: SessionRecord)] {
        groups.compactMap { group -> (project: Project, latest: SessionRecord)? in
            guard let project = group.project,
                  let latest = group.sessions.max(by: { $0.updatedAt < $1.updatedAt }),
                  now.timeIntervalSince(latest.updatedAt) >= idleAfter,
                  project.setAsideThrough.map({ latest.updatedAt > $0 }) ?? true,
                  group.sessions.allSatisfy({
                      TaskAttentionProjection.place(of: $0, details: details, shellBusy: shellBusy).state == .idle
                  }) else { return nil }
            return (project, latest)
        }
        .sorted { $0.latest.updatedAt > $1.latest.updatedAt }
    }

    /// The projects left alone for a while that still hold unfinished work (`idleCandidates`): files
    /// not committed, commits not pushed, worktrees with work left, open pull requests, schedules that
    /// turned themselves off, suggestions not started. Being old alone does not list a project, and
    /// one whose folder is not read yet waits for it. The most recently left first, so the one just
    /// slipping away leads.
    static func idleProjects(
        groups: [WorkspaceGroup], details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        work: (UUID) -> GitLeftWork? = { _ in nil }, pullRequest: (UUID) -> TaskPullRequest? = { _ in nil },
        stoppedSchedules: [ScheduledTask] = [],
        isSuggestionOpen: (TaskAttentionSuggestion, UUID) -> Bool = { _, _ in true },
        latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil },
        now: Date = Date()
    ) -> [NewTaskIdleProject] {
        let tasks = Dictionary(groups.compactMap { group in group.project.map { ($0.id, group.sessions) } },
                               uniquingKeysWith: { first, _ in first })
        return idleCandidates(groups: groups, details: details, shellBusy: shellBusy, now: now).compactMap { candidate in
            let sessions = tasks[candidate.project.id] ?? []
            var idle = NewTaskIdleProject(project: candidate.project, latestTask: candidate.latest,
                                          lastActive: candidate.latest.updatedAt)
            idle.git = work(candidate.project.id) ?? GitLeftWork()
            idle.pullRequests = pullRequestRows(sessions: sessions, pullRequest: pullRequest)
            idle.stoppedSchedules = stoppedSchedules.filter { belongs($0, to: candidate.project) }.count
            idle.suggestions = sessions.reduce(0) { count, task in
                count + (latestTurn(task.id)?.suggestions ?? []).filter { isSuggestionOpen($0, task.id) }.count
            }
            return idle.hasWorkLeft ? idle : nil
        }
    }

    /// A schedule starts its tasks in the project: it names the project, or one of its folders.
    static func belongs(_ schedule: ScheduledTask, to project: Project) -> Bool {
        if schedule.destination.projectID == project.id { return true }
        guard let folder = schedule.destination.workspaceURL else { return false }
        let path = ProjectSidebarPresentation.normalizedPath(for: folder)
        return project.roots.contains { ProjectSidebarPresentation.normalizedPath(for: $0) == path }
    }

    /// The home's projects, then the chats: each with what its tasks need, what they finished today,
    /// its open pull requests, and its schedules and suggestions. A place is listed while a task there
    /// needs the person or runs, a pull request is open, something comes up, or it was active in the
    /// last `recentWindow`. The one that needs the person most comes first, then the most recent. The
    /// projects in `leaving` are not: the home names them with what they left (`idleProjects`).
    static func projectSummaries(
        groups: [WorkspaceGroup], chats: [SessionRecord] = [], details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = [], pullRequest: (UUID) -> TaskPullRequest? = { _ in nil },
        schedules: [(schedule: ScheduledTask, nextRun: Date)] = [],
        isSuggestionOpen: (TaskAttentionSuggestion, UUID) -> Bool = { _, _ in true },
        agents: (UUID) -> Int = { _ in 0 }, answerLine: (UUID) -> String? = { _ in nil },
        latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil },
        leaving: Set<UUID> = [], now: Date = Date(), calendar: Calendar = .current
    ) -> [NewTaskProjectSummary] {
        let everyTask = groups.flatMap(\.sessions) + chats
        let attention = Dictionary(attentionRows(sessions: everyTask, details: details, shellBusy: shellBusy,
                                                 answerLine: answerLine)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = Dictionary(runningRows(sessions: everyTask, details: details, shellBusy: shellBusy, agents: agents,
                                             latestTurn: latestTurn)
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let taskIDs = Set(everyTask.map(\.id))

        func summary(_ place: NewTaskProjectSummary.Place, name: String, tasks: [SessionRecord],
                     runs: [(schedule: ScheduledTask, nextRun: Date)]) -> NewTaskProjectSummary? {
            let places = Dictionary(tasks.map {
                ($0.id, TaskAttentionProjection.place(of: $0, details: details, shellBusy: shellBusy))
            }, uniquingKeysWith: { first, _ in first })
            let ordered = tasks.sorted { lhs, rhs in
                let left = places[lhs.id]!, right = places[rhs.id]!
                if left.state != right.state { return left.state < right.state }
                if left.recency != right.recency { return left.recency > right.recency }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            var result = NewTaskProjectSummary(place: place, name: name,
                                               state: ordered.first.flatMap { places[$0.id]?.state } ?? .idle)
            for task in ordered {
                if let row = attention[task.id] {
                    result.tasks.append(.attention(row))
                    if row.waitsOnPerson { result.waiting += 1 } else { result.unread += 1 }
                } else if let row = running[task.id] {
                    result.tasks.append(.running(row))
                    result.running += 1
                } else if places[task.id]?.state == .active {
                    // Running under a running task: counted on that task's line.
                    result.running += 1
                } else if task.parentTaskID.map(taskIDs.contains) != true {
                    // A task nested under another is that task's, as the sidebar nests it.
                    result.tasks.append(.recent(task, answerLine: answerLine(task.id)))
                }
                if task.status == .completed, calendar.isDate(task.updatedAt, inSameDayAs: now) {
                    result.finishedToday += 1
                }
            }
            result.pullRequests = pullRequestRows(sessions: tasks, pullRequest: pullRequest)
            result.upcoming = upcomingRows(schedules: runs, sessions: tasks, latestTurn: latestTurn,
                                           isOpen: isSuggestionOpen, now: now)
            result.latest = tasks.map(\.updatedAt).max() ?? .distantPast
            guard result.state != .idle || !result.pullRequests.isEmpty || !result.upcoming.isEmpty
                    || now.timeIntervalSince(result.latest) <= recentWindow else { return nil }
            return result
        }

        var summaries = groups.compactMap { group -> NewTaskProjectSummary? in
            guard let project = group.project, !leaving.contains(project.id) else { return nil }
            let runs = schedules.filter { belongs($0.schedule, to: project) }
            return summary(.project(project), name: project.name, tasks: group.sessions, runs: runs)
        }
        if let chatSummary = summary(.chats, name: L10n.string("Chats"), tasks: chats,
                                     runs: schedules.filter {
                                         $0.schedule.destination.workspaceURL == nil && $0.schedule.destination.projectID == nil
                                     }) {
            summaries.append(chatSummary)
        }
        return summaries.enumerated().sorted { lhs, rhs in
            if lhs.element.state != rhs.element.state { return lhs.element.state < rhs.element.state }
            if lhs.element.latest != rhs.element.latest { return lhs.element.latest > rhs.element.latest }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The projects' places while the screen shows: the ones already placed keep their order, a new
    /// one comes after them, and one no longer listed leaves. The Codex app keeps its priority list
    /// the same way until it closes, as the activity view does (`TaskAttentionProjection.activityList`).
    static func places(_ kept: [String], listing ids: [String]) -> [String] {
        let listed = Set(ids)
        let placed = kept.filter(listed.contains)
        let known = Set(placed)
        return placed + ids.filter { !known.contains($0) }
    }

    /// The summaries in the places kept, any not placed yet after them in their own order.
    static func keepingPlaces(_ places: [String], of summaries: [NewTaskProjectSummary]) -> [NewTaskProjectSummary] {
        let index = Dictionary(places.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries.enumerated().sorted { lhs, rhs in
            switch (index[lhs.element.id], index[rhs.element.id]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// How far ahead a project lists a schedule's next run.
    static let upcomingWindow: TimeInterval = 24 * 60 * 60

    /// What comes up: the schedules that run in the next day, soonest first, then the tasks the agents
    /// suggested that were neither started nor dismissed, most recent first.
    static func upcomingRows(
        schedules: [(schedule: ScheduledTask, nextRun: Date)], sessions: [SessionRecord],
        latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil },
        isOpen: (TaskAttentionSuggestion, UUID) -> Bool = { _, _ in true }, now: Date = Date()
    ) -> [NewTaskUpcomingRow] {
        let runs = schedules
            .filter { $0.schedule.isEnabled && $0.nextRun.timeIntervalSince(now) <= upcomingWindow }
            .sorted { $0.nextRun != $1.nextRun ? $0.nextRun < $1.nextRun : $0.schedule.name < $1.schedule.name }
            .map { NewTaskUpcomingRow.schedule($0.schedule, nextRun: $0.nextRun) }
        let suggested = sessions
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
            .flatMap { task in
                (latestTurn(task.id)?.suggestions ?? []).reversed().filter { isOpen($0, task.id) }
                    .map { NewTaskUpcomingRow.suggestion($0, in: task) }
            }
        return runs + suggested
    }

    /// The accounts with a limit window nearly spent (`AccountLimitWindow.isNearlySpent`), from the
    /// readings Yardlet already has, as the menu bar's Usage lines name them.
    static func usageNotices(choices: [AccountChoice]) -> [NewTaskHomeNotice] {
        MenuBarMenuProjection.nearlySpentWindows(choices: choices).map {
            .usage(account: $0.account, window: $0.window, remaining: $0.remaining)
        }
    }

    /// The open pull requests the tasks made — not drafts, merged or closed ones,
    /// nor ones GitHub has not described — once each by link, most recently active task first.
    static func pullRequestRows(
        sessions: [SessionRecord], pullRequest: (UUID) -> TaskPullRequest?
    ) -> [NewTaskPullRequestRow] {
        var seen: Set<String> = []
        return sessions
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
            .compactMap { session in
                guard let pr = pullRequest(session.id), pr.state == .open,
                      seen.insert(pr.url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted
                else { return nil }
                return NewTaskPullRequestRow(session: session, pullRequest: pr)
            }
    }

    /// How many projects left alone for a while have their latest task asked about.
    static let idlePullRequestCandidateLimit = 6

    /// The tasks the screen asks the pull request lookup about while it shows: the folder's most
    /// recent ones (for the failing checks row), the most recent tasks overall (for the list), and the
    /// latest task of each project left alone for a while (`idle`, for what it left).
    static func pullRequestCandidates(folder: URL?, sessions: [SessionRecord], idle: [SessionRecord] = []) -> [SessionRecord] {
        let recent = sessions.sorted { $0.updatedAt > $1.updatedAt }
        var picked = Array(recent.prefix(pullRequestCandidateLimit))
        var more: [SessionRecord] = []
        if let folder {
            let path = ProjectSidebarPresentation.normalizedPath(for: folder)
            more += recent.lazy.filter { ProjectSidebarPresentation.normalizedPath(for: $0.workspaceURL) == path }
                .prefix(folderPullRequestCandidateLimit)
        }
        more += idle.prefix(idlePullRequestCandidateLimit)
        for task in more where !picked.contains(where: { $0.id == task.id }) { picked.append(task) }
        return picked
    }
}

/// A running task in Running: how many running tasks and agents it has under it, and since when its
/// turn runs.
struct NewTaskRunningRow: Equatable, Identifiable, Sendable {
    let session: SessionRecord
    var subtasks: Int = 0
    let since: Date
    var id: UUID { session.id }
}

/// A project on the home, or the chats with no project: its tasks in attention order and what it
/// has today. Choosing a project starts the new task there.
struct NewTaskProjectSummary: Equatable, Identifiable, Sendable {
    enum Place: Equatable, Sendable {
        case project(Project)
        case chats
    }

    let place: Place
    let name: String
    /// The most urgent state among its tasks, which orders the places.
    var state: TaskAttentionState
    /// Waiting, unread and running first, then the others most recent first.
    var tasks: [NewTaskProjectTask] = []
    var waiting = 0
    var unread = 0
    var running = 0
    var finishedToday = 0
    /// Its tasks' open pull requests, most recent first.
    var pullRequests: [NewTaskPullRequestRow] = []
    /// Its schedules' next runs and its tasks' suggestions not yet started.
    var upcoming: [NewTaskUpcomingRow] = []
    var latest: Date = .distantPast

    init(place: Place, name: String, state: TaskAttentionState) {
        self.place = place
        self.name = name
        self.state = state
    }

    var id: String {
        switch place {
        case let .project(project): project.id.uuidString
        case .chats: "chats"
        }
    }

    var project: Project? {
        if case let .project(project) = place { return project }
        return nil
    }
}

/// A task on a project's lines.
enum NewTaskProjectTask: Equatable, Identifiable, Sendable {
    /// It waits on the person, or holds an unread result.
    case attention(NewTaskAttentionRow)
    case running(NewTaskRunningRow)
    /// It needs nothing; the first line of its latest answer when Yardlet has read it.
    case recent(SessionRecord, answerLine: String?)

    var session: SessionRecord {
        switch self {
        case let .attention(row): row.session
        case let .running(row): row.session
        case let .recent(task, _): task
        }
    }

    var id: UUID { session.id }
}

/// What comes up in a project: a schedule's next run, or a task an agent suggested that waits to be
/// started.
enum NewTaskUpcomingRow: Equatable, Identifiable, Sendable {
    case schedule(ScheduledTask, nextRun: Date)
    case suggestion(TaskAttentionSuggestion, in: SessionRecord)

    var id: String {
        switch self {
        case let .schedule(schedule, _): "schedule:\(schedule.id)"
        case let .suggestion(suggestion, task): "suggestion:\(task.id):\(suggestion.id)"
        }
    }
}

/// Something wrong enough to say before starting a task, said on one line under the composer only
/// while it lasts.
enum NewTaskHomeNotice: Equatable, Hashable, Identifiable, Sendable {
    /// An account's limit window has 10% or less left.
    case usage(account: String, window: String, remaining: String)
    /// The disk the home folder is on has less than `NewTaskHomeNotice.lowDiskBytes` free.
    case lowDisk(availableBytes: Int64)
    /// macOS reports memory pressure.
    case memoryPressure
    /// macOS slows the Mac to cool it.
    case thermal

    static let lowDiskBytes: Int64 = 10_000_000_000

    var id: Self { self }

    var text: String {
        switch self {
        case let .usage(account, window, remaining): L10n.format("%@ %@ %@ left", account, window, remaining)
        case let .lowDisk(bytes):
            L10n.format("%@ free on disk", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .memoryPressure: L10n.string("Memory is low")
        case .thermal: L10n.string("The Mac is slowing down to cool")
        }
    }
}

/// A list on the new-task screen the keyboard moves through: a project's lines, the projects past the
/// screen's share, or the folder's rows over the composer.
enum NewTaskHomeSection: Hashable, Sendable {
    case project(String)
    /// The projects left alone for a while (`NewTaskIdleProject`).
    case idle
    case moreProjects
    case folder
}

/// How the keyboard moves through the lists, as the Codex and Claude new-task screens do: Tab from
/// the composer goes to the first row, ↑ and ↓ move between rows (each section's "Show more" is a
/// row too), Return does what the row does, and Tab or Shift-Tab goes back to the composer. Escape
/// does nothing here: neither app leaves the new-task screen on Escape.
struct NewTaskHomeListKeyboard: Equatable {
    /// A project's name line, which chooses the project.
    static let headerID = "header"

    enum Entry: Hashable {
        case row(NewTaskHomeSection, String)
        case toggle(NewTaskHomeSection)
    }

    enum Key: Equatable {
        case up, down, `return`, tab, escape
    }

    enum Outcome: Equatable {
        case handled
        case ignored
        case perform(Entry)
        case returnToComposer
    }

    private(set) var entries: [Entry] = []
    private(set) var highlighted: Int?

    var highlightedEntry: Entry? { highlighted.map { entries[$0] } }

    /// The rows now listed. The highlight stays on its entry when it is still listed, else on the
    /// same place.
    mutating func list(_ entries: [Entry]) {
        let previous = highlightedEntry
        self.entries = entries
        guard let highlighted else { return }
        if entries.isEmpty {
            self.highlighted = nil
        } else if let previous, let index = entries.firstIndex(of: previous) {
            self.highlighted = index
        } else {
            self.highlighted = min(highlighted, entries.count - 1)
        }
    }

    /// Tab in the composer: `entry` when it is listed (the line of the task the composer answers),
    /// else the first row, when there is one.
    mutating func enter(at entry: Entry? = nil) -> Bool {
        guard !entries.isEmpty else { return false }
        highlighted = entry.flatMap { entries.firstIndex(of: $0) } ?? 0
        return true
    }

    /// The list lost the keyboard.
    mutating func leave() { highlighted = nil }

    mutating func press(_ key: Key) -> Outcome {
        guard let current = highlighted, !entries.isEmpty else { return key == .tab ? .returnToComposer : .ignored }
        switch key {
        case .up:
            highlighted = max(0, current - 1)
            return .handled
        case .down:
            highlighted = min(entries.count - 1, current + 1)
            return .handled
        case .return:
            return .perform(entries[current])
        case .tab:
            return .returnToComposer
        case .escape:
            return .ignored
        }
    }
}
