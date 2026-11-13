import Foundation

/// How the desk stands in the home's width: three zones side by side when the body is wide and the
/// calendar is on, two columns from `twoColumnWidth`, one column below that. The width is the home's
/// own, so a split view or a side panel narrows it as the sidebar does.
enum DeskLayout: String, Equatable, Sendable {
    /// One column: what waits, what runs, then today, over the composer.
    case one
    /// Two columns: what waits on the person over the composer, and beside them today, what runs and
    /// what just finished.
    case two
    /// Three zones: what waits, what runs, and today on a time axis. Today needs the calendar.
    case zones

    static let twoColumnWidth: CGFloat = 880
    static let zonesWidth: CGFloat = 1200

    static func choose(width: CGFloat, calendarOn: Bool) -> DeskLayout {
        if width < twoColumnWidth { return .one }
        if calendarOn, width >= zonesWidth { return .zones }
        return .two
    }
}

/// A line of "Waiting on you": a task that needs the person to do something, with what it needs.
struct DeskWaitingItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// It waits for an approval, an answer or a browser tab: its sidebar mark's state.
        case request(SidebarTaskStatus)
        /// Its latest turn failed, or a plan limit stopped it.
        case stopped(SidebarTaskStatus)
        /// The checks of its open pull request fail while it does nothing about them.
        case checksFailed(TaskPullRequest)
        /// A coordinator's result nobody read: it reports to the person, or asks them to decide.
        case report
    }

    let session: SessionRecord
    let kind: Kind
    var id: UUID { session.id }

    /// The mark the line starts with, the sidebar's own where the task has one.
    var status: SidebarTaskStatus? {
        switch kind {
        case let .request(status), let .stopped(status): status
        case .checksFailed: nil
        case .report: .unread
        }
    }

    /// An unread result can be marked read from its line; a request stays until it is answered.
    var canMarkRead: Bool {
        switch kind {
        case .request: false
        case .stopped, .report: session.hasUnreadUpdate
        case .checksFailed: false
        }
    }
}

/// A line of "Running": a task at the top of its family, with the tasks under it that run or wait.
/// A coordinator counts them by state ("2 running · 1 approval"); a task running alone shows how long.
struct DeskFamily: Equatable, Identifiable, Sendable {
    /// A task under the top one, with its sidebar mark.
    struct Member: Equatable, Identifiable, Sendable {
        let session: SessionRecord
        let status: SidebarTaskStatus
        var id: UUID { session.id }
    }

    let root: SessionRecord
    /// The top task's own mark; nil when it does nothing while tasks under it work.
    let status: SidebarTaskStatus?
    /// The tasks under it that run or wait, the most urgent first, then the most recent.
    var members: [Member] = []
    /// How many agents its `run_agent` calls and its members' run now.
    var agents = 0
    var id: UUID { root.id }

    /// How many of its tasks run now, itself included.
    var running: Int { (status.map(DeskProjection.runs) == true ? 1 : 0) + members.filter { DeskProjection.runs($0.status) }.count }
}

/// Today's runs of a schedule: one that ran, one that failed to start, or the next one still to come.
struct DeskScheduledRun: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case ran
        case failed
        case upcoming
    }

    let schedule: ScheduledTask
    let at: Date
    let kind: Kind
    var id: String { "\(schedule.id):\(at.timeIntervalSinceReferenceDate)" }
}

/// What the desk ("Now", the home's first view) shows: what waits on the person, what runs and what
/// just finished, and today. Nothing here is new state: it is `TaskAttentionProjection`'s attention,
/// the pull request lookup's checks, the schedules' runs and the mailbox's inboxes, arranged.
struct Desk: Equatable, Sendable {
    var waiting: [DeskWaitingItem] = []
    var families: [DeskFamily] = []
    /// Unread results that ask nothing: not a coordinator's report, not a failure, read by no parent.
    var finished: [SessionRecord] = []
    /// Today's scheduled runs, in time order.
    var today: [DeskScheduledRun] = []
    /// How many tasks run now, the header's count: every family's running tasks.
    var running = 0

    /// How many of today's runs are still to come.
    var remainingToday: Int { today.filter { $0.kind == .upcoming }.count }

    /// Nothing waits on the person, nothing runs and no result is unread: the desk keeps today alone.
    var isQuiet: Bool { waiting.isEmpty && families.isEmpty && finished.isEmpty }
}

/// The desk's rules, worked out once each time what it reads changes. Attention comes only from
/// `TaskAttentionProjection`, so what waits here is what `⌥⌘A` goes through and the Dock badge counts,
/// and a result its parent already read (`SessionRecord.isParentRead`) is not unread here either.
enum DeskProjection {
    /// Lays the desk out from the tasks the sidebar lists.
    ///
    /// - Parameters:
    ///   - archivedParents: the tasks an archived task was started from (`SessionStore.archivedParentTaskIDs`):
    ///     a task whose subtasks are all archived still coordinated them.
    ///   - agents: how many agents a task's `run_agent` calls run now.
    ///   - pullRequest: the pull request lookup's reading of a task, for the ones it asked about.
    ///   - schedules: each schedule with its next run.
    static func desk(
        sessions: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:], shellBusy: Set<UUID> = [],
        archivedParents: Set<UUID> = [], agents: (UUID) -> Int = { _ in 0 },
        pullRequest: (UUID) -> TaskPullRequest? = { _ in nil },
        schedules: [(schedule: ScheduledTask, nextRun: Date)] = [], now: Date = Date(), calendar: Calendar = .current
    ) -> Desk {
        let listed = Set(sessions.map(\.id))
        var parents: [UUID: UUID] = [:]
        var hasSubtasks = archivedParents
        for session in sessions {
            guard let parent = session.parentTaskID else { continue }
            hasSubtasks.insert(parent)
            if listed.contains(parent) { parents[session.id] = parent }
        }
        /// The highest listed task above, through any number of levels; the task itself at the top.
        func top(of id: UUID) -> UUID {
            var current = id
            var seen: Set<UUID> = [id]
            while let parent = parents[current], seen.insert(parent).inserted { current = parent }
            return current
        }
        /// A coordinator: a top-level task that started tasks of its own, archived ones included.
        func coordinates(_ session: SessionRecord) -> Bool {
            session.parentTaskID == nil && hasSubtasks.contains(session.id)
        }

        var desk = Desk()
        var waiting: [(item: DeskWaitingItem, urgent: Bool)] = []
        var members: [UUID: [DeskFamily.Member]] = [:]
        var topStates: [UUID: (state: TaskAttentionState, status: SidebarTaskStatus?)] = [:]
        var activeTops: Set<UUID> = []

        for session in sessions {
            let detail = details[session.id]
            let isShellBusy = shellBusy.contains(session.id)
            let state = TaskAttentionProjection.state(of: session, detail: detail, isShellBusy: isShellBusy)
            let status = SidebarTaskIndicatorProjection.status(of: session, detail: detail, isShellBusy: isShellBusy)
            let topID = top(of: session.id)
            if topID == session.id { topStates[session.id] = (state, status) }

            switch state {
            case .waiting:
                if let status { waiting.append((DeskWaitingItem(session: session, kind: .request(status)), true)) }
                if topID != session.id, let status { members[topID, default: []].append(.init(session: session, status: status)) }
            case .active:
                desk.running += 1
                activeTops.insert(topID)
                if topID != session.id {
                    members[topID, default: []].append(.init(session: session, status: status ?? .running))
                }
            case .unread:
                if let status, stops(status) {
                    waiting.append((DeskWaitingItem(session: session, kind: .stopped(status)), false))
                } else if let failing = failingChecks(pullRequest(session.id)) {
                    waiting.append((DeskWaitingItem(session: session, kind: .checksFailed(failing)), false))
                } else if coordinates(session) {
                    waiting.append((DeskWaitingItem(session: session, kind: .report), false))
                } else {
                    desk.finished.append(session)
                }
            case .idle:
                if let failing = failingChecks(pullRequest(session.id)) {
                    waiting.append((DeskWaitingItem(session: session, kind: .checksFailed(failing)), false))
                }
            }
        }

        // What waits on a request first, then what stopped or reported, each the most recent first.
        desk.waiting = waiting.sorted { lhs, rhs in
            if lhs.urgent != rhs.urgent { return lhs.urgent }
            return isMoreRecent(lhs.item.session, than: rhs.item.session)
        }.map(\.item)

        // A family shows while any of its tasks runs: the top task, then its members.
        desk.families = sessions.filter { activeTops.contains($0.id) }
            .sorted(by: isMoreRecent)
            .map { root in
                let own = topStates[root.id]
                let family = (members[root.id] ?? []).sorted { lhs, rhs in
                    if lhs.status.urgency != rhs.status.urgency { return lhs.status.urgency < rhs.status.urgency }
                    return isMoreRecent(lhs.session, than: rhs.session)
                }
                let ownStatus: SidebarTaskStatus? = own?.state == .active ? (own?.status ?? .running)
                    : (own?.state == .waiting ? own?.status : nil)
                return DeskFamily(root: root, status: ownStatus, members: family,
                                  agents: agents(root.id) + family.reduce(0) { $0 + agents($1.session.id) })
            }
        desk.finished.sort(by: isMoreRecent)
        desk.today = todayRuns(schedules: schedules, now: now, calendar: calendar)
        return desk
    }

    /// A mark of a task at work: its turn runs, or continues once the network is back.
    static func runs(_ status: SidebarTaskStatus) -> Bool { status == .running || status == .reconnecting }

    /// A mark of a turn that stopped short: it failed, or a plan limit stopped it.
    static func stops(_ status: SidebarTaskStatus) -> Bool {
        switch status {
        case .failed, .usageLimit: true
        default: false
        }
    }

    /// An open or draft pull request whose checks fail.
    static func failingChecks(_ pullRequest: TaskPullRequest?) -> TaskPullRequest? {
        guard let pullRequest, pullRequest.state == .open || pullRequest.state == .draft,
              pullRequest.checks == .failing else { return nil }
        return pullRequest
    }

    /// Today's runs: the ones each schedule ran or failed to start today, and its next run when that is
    /// still today. Runs skipped, deferred or past their time are not: nothing ran.
    static func todayRuns(
        schedules: [(schedule: ScheduledTask, nextRun: Date)], now: Date, calendar: Calendar = .current
    ) -> [DeskScheduledRun] {
        var runs: [DeskScheduledRun] = []
        for (schedule, nextRun) in schedules {
            for run in schedule.state.runs where run.at <= now && calendar.isDate(run.at, inSameDayAs: now) {
                switch run.outcome {
                case .started: runs.append(DeskScheduledRun(schedule: schedule, at: run.at, kind: .ran))
                case .failed: runs.append(DeskScheduledRun(schedule: schedule, at: run.at, kind: .failed))
                case .deferred, .expired, .skipped: break
                }
            }
            if schedule.isEnabled, nextRun > now, calendar.isDate(nextRun, inSameDayAs: now) {
                runs.append(DeskScheduledRun(schedule: schedule, at: nextRun, kind: .upcoming))
            }
        }
        return runs.sorted { $0.at != $1.at ? $0.at < $1.at : $0.schedule.name < $1.schedule.name }
    }

    /// The inboxes' unread threads, newest first: the rule is only that, an inbox and unread.
    static func unreadMail(_ threads: [MailThreadSummary]) -> [MailThreadSummary] {
        threads.filter(\.isUnread).sorted { $0.date > $1.date }
    }

    private static func isMoreRecent(_ lhs: SessionRecord, than rhs: SessionRecord) -> Bool {
        lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
    }
}
