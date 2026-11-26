import Foundation

/// What the new-task screen's lists read beside the draft: the tasks the sidebar lists and their
/// attention (`TaskAttentionProjection`, the definition `⌥⌘A`, the Dock badge and the sidebar marks
/// share), where each task sits, the schedules, what is wrong, and how tall the window is. All of it
/// is what Yardlet already keeps; nothing here asks a harness or a model.
struct NewTaskHomeActivity {
    /// Every task the sidebar can list (`AppModel.sidebarSessions`).
    var sessions: [SessionRecord] = []
    var details: [UUID: TaskAttentionDetail] = [:]
    var shellBusy: Set<UUID> = []
    /// The project, or "Chats", a task is listed under (`AppModel.taskPlaceNames`).
    var placeName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
    /// The sidebar's groups of those tasks, and the chats with no project.
    var groups: [WorkspaceGroup] = []
    var chats: [SessionRecord] = []
    /// How many agents a task's `run_agent` calls are running (`AppModel.railAgentRuns`).
    var agents: (UUID) -> Int = { _ in 0 }
    /// Each schedule with its next run (`ScheduledTaskCenter.nextRun`).
    var schedules: [(schedule: ScheduledTask, nextRun: Date)] = []
    /// The schedules that turned themselves off (`ScheduledTask.hasStoppedItself`), which a project
    /// left alone for a while names.
    var stoppedSchedules: [ScheduledTask] = []
    /// A suggested task neither started nor dismissed (`TaskSuggestionStore.resolution`).
    var isSuggestionOpen: (TaskAttentionSuggestion, UUID) -> Bool = { _, _ in true }
    /// The accounts nearly out of their limits. Read by the notice line in its own body: the readings
    /// change with every plan-limit report a running turn makes, which must not redraw the home.
    var notices: () -> [NewTaskHomeNotice] = { [] }
    /// Token usage counted from this Mac's transcripts, while Settings › Usage counts it; nil leaves
    /// the band out. The band reads it in its own body, so a new count redraws the band alone.
    var usage: (() -> TokenUsageOverview)? = nil
    /// Opens Settings › Usage.
    var onOpenUsage: () -> Void = {}
    /// The time "today" and next runs are read against.
    var now = Date()
    /// The window's height, which sets how many rows each list shows. Nil uses the screen's own.
    var windowHeight: CGFloat? = nil
    /// "Mark all as read" and a row's mark-as-read.
    var onMarkRead: ([UUID]) -> Void = { _ in }
    /// Opens a schedule in Scheduled tasks.
    var onOpenSchedule: (UUID) -> Void = { _ in }
    /// Shows a calendar event on the calendar, chosen.
    var onOpenEvent: (CalendarEvent) -> Void = { _ in }
    /// Sets a project left alone for a while aside until it is active after the date
    /// (`ProjectStore.setAside`).
    var onSetAside: (UUID, Date) -> Void = { _, _ in }
    /// A task's latest finished message's first line (`AppModel.answerLineBySessionID`).
    var answerLine: (UUID) -> String? = { _ in nil }
    /// When a task's latest turn started and what it suggested (`AppModel.latestTurnBySessionID`).
    var latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil }
    /// The tasks an archived task was started from (`SessionStore.archivedParentTaskIDs`), which the desk
    /// counts as coordinators.
    var archivedParents: Set<UUID> = []
    /// What a waiting task's newest request asks, on one line: the question, or the command to approve.
    var requestLine: (SessionRecord) -> NewTaskHomeRequestLine? = { _ in nil }
    /// Each task's pull request where it comes with the tasks (a remote window, from the host's list); nil
    /// asks this Mac's pull request lookup.
    var pullRequest: ((UUID) -> TaskPullRequest?)?
}

extension AppModel {
    /// The home's reading of this computer's tasks (`NewTaskHomeActivity`): the tasks the sidebar lists, their
    /// attention and where each sits, the agents each runs, the schedules and suggestions, and marking read and
    /// setting a project aside. The window adds what is its own: the notice line's readings, the usage band, the
    /// window's height and where a schedule or an event opens.
    func newTaskHomeActivity() -> NewTaskHomeActivity {
        let sidebarSessions = sidebarSessions
        return NewTaskHomeActivity(
            sessions: sidebarSessions, details: taskAttentionDetails,
            shellBusy: shellBusySessionIDs, placeName: taskPlaceNames(),
            groups: projects.visibleGroups(sessions: sidebarSessions),
            chats: projects.chats(sessions: sidebarSessions),
            agents: { self.railAgentRuns(hostedBy: $0).filter { !$0.state.isFinished }.count },
            schedules: scheduledTasks.schedules.compactMap { schedule in
                self.scheduledTasks.nextRun(of: schedule).map { (schedule, $0) }
            },
            stoppedSchedules: scheduledTasks.schedules.filter(\.hasStoppedItself),
            isSuggestionOpen: { self.taskSuggestions.resolution(of: $0.id, in: $1) == nil },
            now: scheduledTasks.displayNow,
            onMarkRead: { ids in Task { await self.store.markRead(ids: ids) } },
            onSetAside: { self.projects.setAside($0, through: $1) },
            answerLine: { self.answerLineBySessionID[$0] },
            latestTurn: { self.latestTurnBySessionID[$0] },
            archivedParents: store.archivedParentTaskIDs,
            requestLine: { AppModelRemoteBridge.requestLine(of: $0, in: self) })
    }
}

/// What a waiting task's newest request asks, on one line for the desk, and what kind of answer it waits for:
/// a command to approve shows in a code box, any other approval and a question as a sentence.
struct NewTaskHomeRequestLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A command to run, shown as code.
        case command
        /// A file change or another tool's permission.
        case approval
        /// A question, a form or a plan to review: it waits for an answer, not an approval.
        case question
    }

    let text: String
    let kind: Kind
}
