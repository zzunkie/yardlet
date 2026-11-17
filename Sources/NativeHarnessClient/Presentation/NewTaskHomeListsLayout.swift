import Foundation

/// What the home's lists show now, in the keyboard's order: the projects' panels with the lines each shows
/// before "Show {count} more", the projects left alone for a while as one more panel among them, the projects
/// past the screen's share, and the folder's rows over the composer. The Mac's lists (`NewTaskHomeLists`) and the
/// Windows home draw it; which lines a panel shows, what choosing one does and the words beside a name are read
/// here, so both say the same.
struct NewTaskHomeListsLayout {
    struct Panel {
        let summary: NewTaskProjectSummary
        let isChosen: Bool
        let tasks: [NewTaskProjectTask]
        let upcoming: [NewTaskUpcomingRow]
        let hidden: Int
        let isExpanded: Bool

        var section: NewTaskHomeSection { .project(summary.id) }

        var entries: [NewTaskHomeListKeyboard.Entry] {
            [.row(section, NewTaskHomeListKeyboard.headerID)]
                + tasks.map { .row(section, $0.id.uuidString) }
                + upcoming.map { .row(section, $0.id) }
                + (hidden > 0 || isExpanded ? [.toggle(section)] : [])
        }
    }

    /// The projects left alone for a while, as one more panel among the projects.
    struct Idle {
        let projects: [NewTaskIdleProject]
        let hidden: Int
        let isExpanded: Bool

        var entries: [NewTaskHomeListKeyboard.Entry] {
            projects.map { .row(.idle, $0.id.uuidString) } + (hidden > 0 || isExpanded ? [.toggle(.idle)] : [])
        }
    }

    enum Item: Identifiable {
        case project(Panel)
        case idle(Idle)

        var id: String {
            switch self {
            case let .project(panel): panel.summary.id
            case .idle: "idle"
            }
        }

        var entries: [NewTaskHomeListKeyboard.Entry] {
            switch self {
            case let .project(panel): panel.entries
            case let .idle(idle): idle.entries
            }
        }
    }

    var panels: [Panel] = []
    var idle: Idle?
    /// How many projects stand side by side; the idle panel follows their first row.
    var columns = 1
    /// Projects past the screen's share, behind "Show {count} more".
    var hiddenProjects = 0
    var showsAllProjects = false
    var folderRows: [NewTaskFolderRow] = []

    /// The panels in the order they are dealt into the columns: the first row of projects, the
    /// projects left alone for a while, then the rest, so what needs the person keeps the top and
    /// what was left stays in sight.
    var items: [Item] {
        var items = panels.map(Item.project)
        if let idle { items.insert(.idle(idle), at: min(columns, items.count)) }
        return items
    }

    var entries: [NewTaskHomeListKeyboard.Entry] {
        items.flatMap(\.entries)
            + (hiddenProjects > 0 || showsAllProjects ? [.toggle(.moreProjects)] : [])
            + folderRows.map { .row(.folder, $0.id) }
    }

    /// Lines a project shows before "Show {count} more" (the Claude app's projects show three, `pU`).
    static let projectLines = 3
    /// The folder's rows over the composer: the same-folder warning first, then one that starts something.
    static let folderLines = 2
    /// Projects left alone for a while the panel names before "Show {count} more".
    static let idleLines = 3

    /// The projects' part: each project's tasks and then what comes up there, `projectLines` of them before
    /// "Show more" unless its section is in `expanded`; as many projects as `rowLimit` gives each of the
    /// `columns` lines for, the rest behind "Show more"; and the projects left alone for a while, `idleLines` of
    /// them.
    static func projects(
        _ summaries: [NewTaskProjectSummary], idle: [NewTaskIdleProject] = [], expanded: Set<NewTaskHomeSection>,
        rowLimit: Int, columns: Int, isChosen: (NewTaskProjectSummary) -> Bool
    ) -> NewTaskHomeListsLayout {
        let idleExpanded = expanded.contains(.idle)
        let idlePanel = idle.isEmpty ? nil : Idle(
            projects: idleExpanded ? idle : Array(idle.prefix(Self.idleLines)),
            hidden: idleExpanded ? 0 : max(0, idle.count - Self.idleLines),
            isExpanded: idleExpanded && idle.count > Self.idleLines)
        /// A project's tasks and then what comes up there, `projectLines` of them before "Show more".
        func panel(_ summary: NewTaskProjectSummary) -> Panel {
            let isExpanded = expanded.contains(.project(summary.id))
            let total = summary.tasks.count + summary.upcoming.count
            let shown = isExpanded ? total : min(total, Self.projectLines)
            let tasks = Array(summary.tasks.prefix(shown))
            return Panel(summary: summary, isChosen: isChosen(summary), tasks: tasks,
                         upcoming: Array(summary.upcoming.prefix(shown - tasks.count)),
                         hidden: total - shown, isExpanded: isExpanded && total > Self.projectLines)
        }
        // As many projects as the window's height gives each column lines for (the Claude app's
        // section limit, `dU`), the rest behind "Show more".
        let share = rowLimit * max(1, columns)
        let showsAll = expanded.contains(.moreProjects)
        let shown = showsAll ? summaries : Array(summaries.prefix(share))
        return NewTaskHomeListsLayout(panels: shown.map(panel), idle: idlePanel, columns: max(1, columns),
                                      hiddenProjects: summaries.count - shown.count,
                                      showsAllProjects: showsAll && summaries.count > share)
    }

    /// The new task starts in the project, or as a chat with no project.
    static func isChosen(_ summary: NewTaskProjectSummary, selectedProjectID: UUID?, startsChat: Bool) -> Bool {
        switch summary.place {
        case let .project(project): !startsChat && project.id == selectedProjectID
        case .chats: startsChat
        }
    }

    // MARK: - Words

    /// What the project's folder is on, when it is not the default branch, and what finished today. `git` is
    /// the reading of its primary folder: for the chosen project, the one the composer read.
    static func facts(_ summary: NewTaskProjectSummary, git state: NewTaskFolderGitState?) -> String? {
        var parts: [String] = []
        if summary.project != nil, let state, let branch = state.branch, !state.isDefaultBranch {
            parts.append(branch)
            if let count = state.uncommittedFiles, count > 0 {
                parts.append(count == 1 ? L10n.string("1 uncommitted file")
                             : L10n.format("%lld uncommitted files", count))
            }
        }
        if summary.finishedToday > 0 { parts.append(L10n.format("%lld finished today", summary.finishedToday)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Today 3:00 PM" or "Tomorrow 9:00 AM": a schedule's next run within the coming day.
    static func nextRunText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return L10n.format("Today %@", time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.format("Tomorrow %@", time)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func chooseHelp(_ summary: NewTaskProjectSummary) -> String {
        summary.project == nil ? L10n.string("Start a chat with no project") : L10n.format("Start a task in %@", summary.name)
    }

    /// How long a running task's turn has run ("12 min"): minutes under an hour, then hours and minutes.
    /// Apple's Foundation says it with `DateComponentsFormatter`; Foundation elsewhere has `Duration`'s
    /// units style.
    static func duration(from start: Date, to end: Date) -> String {
        #if canImport(Darwin)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = end.timeIntervalSince(start) < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, end.timeIntervalSince(start))) ?? ""
        #else
        let units: Set<Duration.UnitsFormatStyle.Unit> = end.timeIntervalSince(start) < 3600 ? [.minutes] : [.hours, .minutes]
        return Duration.seconds(max(60, end.timeIntervalSince(start)))
            .formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
        #endif
    }

    // MARK: - Choosing

    static func choose(_ summary: NewTaskProjectSummary) -> NewTaskHomeAction {
        summary.project.map { .chooseProject($0.id) } ?? .chooseChat
    }

    static func canMarkRead(_ task: NewTaskProjectTask) -> Bool {
        if case let .attention(row) = task { return row.canMarkRead }
        return false
    }

    /// A task that waits on the person or holds an unread result is answered in the composer's place.
    static func answersInPlace(_ task: NewTaskProjectTask) -> Bool {
        if case .attention = task { return true }
        return false
    }

    /// What choosing a task's line does: one that needs the person is answered in the composer's
    /// place unless `opens` (a double-click, or Return on the line already answered); any other opens.
    static func action(_ task: NewTaskProjectTask, opens: Bool) -> NewTaskHomeAction {
        answersInPlace(task) && !opens ? .reply(task.id) : .openTask(task.id)
    }

    /// A project left alone for a while: choosing it starts the new task there, as a project's name
    /// does; `opens` (a double-click) opens the task it was left at.
    static func action(_ idle: NewTaskIdleProject, opens: Bool) -> NewTaskHomeAction {
        opens ? .openTask(idle.latestTask.id) : .chooseProject(idle.project.id)
    }

    /// A schedule opens Scheduled tasks; a suggestion opens the task whose conversation shows its chip.
    static func action(_ row: NewTaskUpcomingRow) -> NewTaskHomeAction {
        switch row {
        case let .schedule(schedule, _): .openSchedule(schedule.id)
        case let .suggestion(_, task): .openTask(task.id)
        }
    }
}

extension SidebarTaskStatus {
    /// The state's name on a waiting task's line: the sidebar's words, shorter for a failed turn and a
    /// plan limit, whose error or reset follows the title (`homeDetail`).
    var homeName: String {
        switch self {
        case .failed: L10n.string("Failed")
        case .usageLimit: L10n.string("Usage limit")
        default: accessibilityName
        }
    }

    var homeDetail: String? {
        switch self {
        case let .failed(message?):
            let summary = TranscriptRecoveryProjection.errorSummary(message)
            return summary.isEmpty ? nil : ConversationLineWording.oneLine(summary)
        case let .usageLimit(limit):
            return ProviderNoticeText.limitReset(limit)
        default:
            return nil
        }
    }
}

/// The new-task screen's measures: the composer as wide as a conversation, and the projects in as
/// many columns of at least `columnWidth` as fit, up to three.
enum NewTaskHomeLayout {
    static let composerWidth: CGFloat = 760
    static let gridWidth: CGFloat = 1360
    static let columnWidth: CGFloat = 400
    static let columnSpacing: CGFloat = 40
    static let inset: CGFloat = 28

    /// How tall the answered task's conversation and composer stand: half the screen, at least room
    /// for a request card and the composer, and never so tall that the projects lose their first lines.
    static func replyHeight(_ height: CGFloat) -> CGFloat {
        max(min(height * 0.5, 560), min(320, height - 260))
    }

    static func columns(width: CGFloat) -> Int {
        let room = min(width - 2 * inset, gridWidth)
        return max(1, min(3, Int((room + columnSpacing) / (columnWidth + columnSpacing))))
    }
}
