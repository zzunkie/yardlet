import Foundation
import UWP
import WinSDK
import WinUI

/// New task's projects over the composer, as the Mac's home lists them (`NewTaskHomeLists`): each project, then the
/// chats, with its tasks that wait on the person, run or hold an unread result, then its latest tasks, each with the
/// first line of its latest answer where Yardlet read one; the project's open pull requests as the Claude app's pill
/// beside its name, with what its folder is on and what finished today; and the projects left alone for a while that
/// still hold unfinished work, as one more panel. The projects stand side by side in as many columns as fit
/// (`NewTaskHomeLayout.columns`), the one that needs the person most first, and keep their places while the home shows.
/// What it lists, in what order and with what words is the engine's (`NewTaskHomeListsProjection`,
/// `NewTaskHomeListsLayout`), read from the model's tasks (`AppModel.newTaskHomeActivity`) and the pull request lookup
/// (`TaskPullRequestMonitor`), which asks about the tasks it reads while it shows, as a sidebar row's task is asked.
///
/// Choosing a project's name starts the new task there; choosing a task that needs the person answers it in the
/// composer's place (`onAction` with `.reply`), and a double-click opens it; any other task opens. Ctrl-click opens the
/// pull request on GitHub, as ⌘-click does on the Mac. An unread result has a ✕ under the pointer that marks it read,
/// and a project left alone has one that sets it aside until it is active again. Each panel is drawn again only when
/// what it shows changes, so the home keeps up with tasks streaming events.
@MainActor
final class NewTaskHomeListsView {
    let view = StackPanel()
    var onAction: (NewTaskHomeAction) -> Void = { _ in }
    /// Asks the home to read and draw again: a folder's reading came back, or a section opened.
    var onRedraw: () -> Void = {}

    private let model: AppModel
    private let log: QAEventLog
    private let columnsGrid = Grid()
    private let moreProjects = Button()
    private var columnPanels: [StackPanel] = []
    private var panels: [String: (drawing: PanelDrawing, view: FrameworkElement)] = [:]
    private var placed: [[String]] = []
    private var shownMore: String??
    /// The sections opened past their first lines while the home shows.
    private var expanded: Set<NewTaskHomeSection> = []
    /// The projects' places since the home was shown (`NewTaskHomeListsProjection.keepingPlaces`).
    private var places: [String] = []
    private var projectGit: [UUID: NewTaskFolderGitState] = [:]
    private var leftWork: [UUID: GitLeftWork] = [:]
    /// The projects whose folders were asked about since the home was shown.
    private var gitAsked: Set<UUID> = []
    private var leftWorkAsked: Set<UUID> = []
    /// Ends the readings of a home no longer shown.
    private var readingGeneration = 0
    private var pullRequestTargets: [TaskPullRequestTarget] = []
    /// The activity's mark-as-read and set-aside, from the last reading.
    private var markRead: ([UUID]) -> Void = { _ in }
    private var setAside: (UUID, Date) -> Void = { _, _ in }
    private var loggedFacts: String?
    /// This home's own set of tasks in the pull request lookup.
    private let screenID = UUID()

    init(model: AppModel, log: QAEventLog) {
        self.model = model
        self.log = log
        view.spacing = 20
        columnsGrid.columnSpacing = Double(NewTaskHomeLayout.columnSpacing)
        view.children.append(columnsGrid)
        ComposerParts.styleFlat(moreProjects, radius: 8)
        moreProjects.horizontalAlignment = .stretch
        moreProjects.horizontalContentAlignment = .left
        moreProjects.padding = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        moreProjects.minHeight = 32
        moreProjects.click.addHandler { [weak self] _, _ in self?.toggle(.moreProjects) }
        moreProjects.visibility = .collapsed
        view.children.append(moreProjects)
    }

    /// The home was shown: the sections fold again, the projects take new places and their folders are read anew,
    /// as the Mac's home does each time it appears.
    func reset() {
        expanded = []
        places = []
        projectGit = [:]
        leftWork = [:]
        stopReading()
    }

    /// The home left the window: its tasks leave the pull request lookup and its folders are no longer read.
    func hide() {
        stopReading()
        if !pullRequestTargets.isEmpty {
            pullRequestTargets = []
            model.pullRequests.showHome([], screen: screenID)
        }
    }

    // MARK: Reading

    /// What the lists show now, read where the Mac's lists read it; called inside the home's observation, so a
    /// change to what it reads draws the home again.
    struct Reading {
        var drawing: Drawing
        var facts: NewTaskHomeProjectFacts
        fileprivate var summaryIDs: [String] = []
        fileprivate var targets: [TaskPullRequestTarget] = []
        fileprivate var gitRoots: [(id: UUID, root: URL)] = []
        fileprivate var idleRoots: [(id: UUID, root: URL)] = []

        var isEmpty: Bool { drawing.panels.isEmpty }
    }

    func read(activity: NewTaskHomeActivity, selectedProjectID: UUID?, startsChat: Bool, replyTaskID: UUID?,
              columns: Int, rowLimit: Int) -> Reading {
        markRead = activity.onMarkRead
        setAside = activity.onSetAside
        let pullRequests = model.pullRequests
        let pullRequest: (UUID) -> TaskPullRequest? = { pullRequests.pullRequest(for: $0) }
        let leftWork = leftWork
        let idle = NewTaskHomeListsProjection.idleProjects(
            groups: activity.groups, details: activity.details, shellBusy: activity.shellBusy,
            work: { leftWork[$0] }, pullRequest: pullRequest, stoppedSchedules: activity.stoppedSchedules,
            isSuggestionOpen: activity.isSuggestionOpen, latestTurn: activity.latestTurn, now: activity.now)
        let listed = NewTaskHomeListsProjection.projectSummaries(
            groups: activity.groups, chats: activity.chats, details: activity.details,
            shellBusy: activity.shellBusy, pullRequest: pullRequest, schedules: activity.schedules,
            isSuggestionOpen: activity.isSuggestionOpen, agents: activity.agents, answerLine: activity.answerLine,
            latestTurn: activity.latestTurn, leaving: Set(idle.map(\.id)), now: activity.now)
        let ids = listed.map(\.id)
        let summaries = NewTaskHomeListsProjection.keepingPlaces(NewTaskHomeListsProjection.places(places, listing: ids),
                                                                 of: listed)
        let layout = NewTaskHomeListsLayout.projects(
            summaries, idle: idle, expanded: expanded, rowLimit: rowLimit, columns: columns,
            isChosen: { NewTaskHomeListsLayout.isChosen($0, selectedProjectID: selectedProjectID, startsChat: startsChat) })
        let candidates = NewTaskHomeListsProjection.idleCandidates(groups: activity.groups, details: activity.details,
                                                                    shellBusy: activity.shellBusy, now: activity.now)
        let words = Words(now: activity.now, pullRequest: pullRequest, replyTaskID: replyTaskID)
        var drawing = Drawing(columns: layout.columns)
        drawing.panels = layout.items.map { item -> PanelDrawing in
            switch item {
            case let .project(panel):
                return .project(words.panel(panel, git: panel.summary.project.flatMap { projectGit[$0.id] }))
            case let .idle(idle):
                return .idle(words.idle(idle))
            }
        }
        if layout.hiddenProjects > 0 || layout.showsAllProjects {
            drawing.moreProjects = layout.showsAllProjects ? L10n.string("Show less")
                : L10n.format("Show %lld more", layout.hiddenProjects)
        }
        return Reading(
            drawing: drawing, facts: NewTaskHomeProjectFacts(summaries: summaries, idle: idle), summaryIDs: ids,
            targets: NewTaskHomeListsProjection.pullRequestCandidates(folder: nil, sessions: activity.sessions,
                                                                       idle: candidates.map(\.latest))
                .map { TaskPullRequestTarget(session: $0) },
            gitRoots: summaries.compactMap(\.project).map { ($0.id, $0.primaryRoot) },
            idleRoots: candidates.map { ($0.project.id, $0.project.primaryRoot) })
    }

    /// Takes what was read: the projects keep their places, the lookup asks about the tasks read, the folders not
    /// read yet are read, and the panels whose drawing changed are drawn again.
    func show(_ reading: Reading) {
        places = NewTaskHomeListsProjection.places(places, listing: reading.summaryIDs)
        if reading.targets != pullRequestTargets {
            pullRequestTargets = reading.targets
            model.pullRequests.showHome(reading.targets, screen: screenID)
        }
        readGit(reading.gitRoots)
        readLeftWork(reading.idleRoots)
        if let summary = reading.facts.summary, summary != loggedFacts {
            loggedFacts = summary
            log.write("home lists: \(summary)")
        }
        draw(reading.drawing)
    }

    /// Each shown project's primary folder, read once while the home shows: its branch and uncommitted files.
    private func readGit(_ roots: [(id: UUID, root: URL)]) {
        let wanted = roots.filter { !gitAsked.contains($0.id) }
        guard !wanted.isEmpty else { return }
        gitAsked.formUnion(wanted.map(\.id))
        let generation = readingGeneration
        Task { [weak self] in
            for (id, root) in wanted {
                let state = await NewTaskFolderGitState.read(root)
                guard let self, self.readingGeneration == generation else { return }
                self.projectGit[id] = state
                self.onRedraw()
            }
        }
    }

    /// What each project that may have been left holds in its folder, read once while the home shows (and at most
    /// every few minutes across homes, `GitLeftWork.readingLifetime`).
    private func readLeftWork(_ roots: [(id: UUID, root: URL)]) {
        let wanted = roots.filter { !leftWorkAsked.contains($0.id) }
        guard !wanted.isEmpty else { return }
        leftWorkAsked.formUnion(wanted.map(\.id))
        let generation = readingGeneration
        Task { [weak self] in
            for (id, root) in wanted {
                let work = await GitLeftWork.read(root)
                guard let self, self.readingGeneration == generation else { return }
                self.leftWork[id] = work ?? GitLeftWork()
                self.onRedraw()
            }
        }
    }

    /// Readings still under way are dropped when they come back, and the folders are asked about anew.
    private func stopReading() {
        readingGeneration += 1
        gitAsked = []
        leftWorkAsked = []
    }

    private func toggle(_ section: NewTaskHomeSection) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        onRedraw()
    }

    // MARK: What is drawn

    struct Drawing: Equatable {
        var columns = 1
        /// In the order they are dealt into the columns (`NewTaskHomeListsLayout.items`).
        var panels: [PanelDrawing] = []
        /// "Show {count} more" under the projects, or "Show less".
        var moreProjects: String?
    }

    enum PanelDrawing: Equatable {
        case project(ProjectPanel)
        case idle(IdlePanel)

        var id: String {
            switch self {
            case let .project(panel): panel.id
            case .idle: "idle"
            }
        }
    }

    struct ProjectPanel: Equatable {
        var id: String
        var section: NewTaskHomeSection
        var name: String
        var isChat: Bool
        var isChosen: Bool
        var facts: String?
        var help: String
        var choose: NewTaskHomeAction
        var pill: Pill?
        /// "+{count}" after the pill, with the others' numbers and states.
        var otherPullRequests: OtherPullRequests?
        var lines: [Line]
        var toggle: String?
    }

    struct OtherPullRequests: Equatable {
        var count: Int
        var help: String
    }

    /// An open pull request's Claude-app pill: its number and state, in its state's color.
    struct Pill: Equatable {
        var number: Int
        var title: String
        var tone: TaskPullRequestBadge.Tone
        var url: URL
    }

    enum Line: Equatable {
        case task(TaskLine)
        case suggestion(id: String, title: String, task: String, action: NewTaskHomeAction)
    }

    struct TaskLine: Equatable {
        var id: UUID
        /// The sidebar's mark; nil for a task that needs nothing.
        var status: SidebarTaskStatus?
        /// A waiting task's state in words before its title.
        var statusName: String?
        var title: String
        var harness: HarnessKind
        var weight: UInt16
        /// A failed turn's error or a plan limit's reset, after the title.
        var detail: String?
        var subtasks: String?
        var pullRequestNumber: String?
        var pullRequestURL: URL?
        var time: String
        /// The first line of the latest answer, under the title.
        var answer: String?
        var canMarkRead: Bool
        var answersInPlace: Bool
        var isAnswering: Bool
    }

    struct IdlePanel: Equatable {
        var projects: [IdleLine]
        var toggle: String?
    }

    struct IdleLine: Equatable {
        var id: UUID
        var name: String
        var time: String
        var workLeft: String
        var help: String
        var lastActive: Date
        var pullRequestURL: URL?
        var choose: NewTaskHomeAction
        var open: NewTaskHomeAction
    }

    /// The Mac's words for what the lines show, read once per drawing.
    private struct Words {
        let now: Date
        let pullRequest: (UUID) -> TaskPullRequest?
        let replyTaskID: UUID?

        func time(_ date: Date) -> String { RelativeTime.ago(date, relativeTo: now, named: true) }

        func panel(_ panel: NewTaskHomeListsLayout.Panel, git: NewTaskFolderGitState?) -> ProjectPanel {
            let summary = panel.summary
            let first = summary.pullRequests.first
            return ProjectPanel(
                id: summary.id, section: panel.section, name: summary.name, isChat: summary.project == nil,
                isChosen: panel.isChosen, facts: NewTaskHomeListsLayout.facts(summary, git: git),
                help: NewTaskHomeListsLayout.chooseHelp(summary), choose: NewTaskHomeListsLayout.choose(summary),
                pill: first.map { Pill(number: $0.pullRequest.number, title: $0.pill.title, tone: $0.pill.tone,
                                       url: $0.pullRequest.url) },
                otherPullRequests: summary.pullRequests.count > 1 ? OtherPullRequests(
                    count: summary.pullRequests.count - 1,
                    help: summary.pullRequests.dropFirst().map { "#\($0.pullRequest.number) \($0.pill.title)" }
                        .joined(separator: "\n")) : nil,
                lines: panel.tasks.map { Line.task(task($0)) } + panel.upcoming.compactMap(upcoming),
                toggle: panel.hidden > 0 || panel.isExpanded
                    ? (panel.isExpanded ? L10n.string("Show less") : L10n.format("Show %lld more", panel.hidden)) : nil)
        }

        private func task(_ task: NewTaskProjectTask) -> TaskLine {
            let session = task.session
            let pr = pullRequest(session.id).flatMap { $0.hasState ? $0 : nil }
            var line = TaskLine(
                id: session.id, status: nil, statusName: nil, title: session.title, harness: session.harness,
                weight: 400, detail: nil, subtasks: nil, pullRequestNumber: pr.map { "#\($0.number)" },
                pullRequestURL: pr?.url, time: time(session.updatedAt), answer: nil,
                canMarkRead: NewTaskHomeListsLayout.canMarkRead(task),
                answersInPlace: NewTaskHomeListsLayout.answersInPlace(task), isAnswering: replyTaskID == session.id)
            switch task {
            case let .attention(row) where row.waitsOnPerson:
                line.status = row.status
                line.statusName = row.status.homeName
                line.weight = 500
                line.detail = row.status.homeDetail
            case let .attention(row):
                line.status = row.status
                line.weight = 600
                line.answer = row.answerLine
            case let .running(row):
                line.status = .running
                line.weight = 500
                line.pullRequestNumber = nil
                line.pullRequestURL = nil
                if row.subtasks > 0 {
                    line.subtasks = row.subtasks == 1 ? L10n.string("1 subtask") : L10n.format("%lld subtasks", row.subtasks)
                }
                line.time = L10n.format("%@ so far", NewTaskHomeListsLayout.duration(from: row.since, to: now))
            case let .recent(_, answerLine):
                line.answer = answerLine
            }
            return line
        }

        /// A suggestion opens the task whose conversation shows its chip. Schedules are not here: Windows does not
        /// run them.
        private func upcoming(_ row: NewTaskUpcomingRow) -> Line? {
            guard case let .suggestion(suggestion, task) = row else { return nil }
            return .suggestion(id: row.id, title: suggestion.title, task: L10n.format("Suggested in %@", task.title),
                               action: NewTaskHomeListsLayout.action(row))
        }

        func idle(_ idle: NewTaskHomeListsLayout.Idle) -> IdlePanel {
            IdlePanel(projects: idle.projects.map { project in
                IdleLine(id: project.id, name: project.project.name, time: time(project.lastActive),
                         workLeft: project.workLeft.joined(separator: " · "),
                         help: L10n.format("Start a task in %@", project.project.name) + "\n"
                            + L10n.format("Double-click to open “%@”", project.latestTask.title),
                         lastActive: project.lastActive, pullRequestURL: project.pullRequests.first?.pullRequest.url,
                         choose: NewTaskHomeListsLayout.action(project, opens: false),
                         open: NewTaskHomeListsLayout.action(project, opens: true))
            }, toggle: idle.hidden > 0 || idle.isExpanded
                ? (idle.isExpanded ? L10n.string("Show less") : L10n.format("Show %lld more", idle.hidden)) : nil)
        }
    }

    // MARK: Drawing

    /// Draws the panels whose drawing changed and deals them into the columns again when their order or the
    /// columns change.
    private func draw(_ drawing: Drawing) {
        var kept: [String: (drawing: PanelDrawing, view: FrameworkElement)] = [:]
        var changed = false
        for panel in drawing.panels {
            if let shown = panels[panel.id], shown.drawing == panel {
                kept[panel.id] = shown
            } else {
                kept[panel.id] = (panel, make(panel))
                changed = true
            }
        }
        let count = max(1, drawing.columns)
        var columns = Array(repeating: [String](), count: count)
        for (index, panel) in drawing.panels.enumerated() { columns[index % count].append(panel.id) }
        if changed || columns != placed {
            for column in columnPanels { column.children.clear() }
            if columnPanels.count != count {
                columnsGrid.children.clear()
                columnsGrid.columnDefinitions.clear()
                columnPanels = (0..<count).map { index in
                    let column = StackPanel()
                    column.spacing = 34
                    let definition = ColumnDefinition()
                    definition.width = GridLength(value: 1, gridUnitType: .star)
                    columnsGrid.columnDefinitions.append(definition)
                    try? Grid.setColumn(column, Int32(index))
                    columnsGrid.children.append(column)
                    return column
                }
            }
            for (index, ids) in columns.enumerated() {
                for id in ids { if let view = kept[id]?.view { columnPanels[index].children.append(view) } }
            }
            placed = columns
        }
        panels = kept
        if drawing.moreProjects != shownMore {
            shownMore = drawing.moreProjects
            moreProjects.content = ComposerParts.label(drawing.moreProjects ?? "", size: 12, weight: 400)
            moreProjects.visibility = drawing.moreProjects == nil ? .collapsed : .visible
        }
    }

    private func make(_ panel: PanelDrawing) -> FrameworkElement {
        switch panel {
        case let .project(project): projectPanel(project)
        case let .idle(idle): idlePanel(idle)
        }
    }

    /// A project: its name, which starts the new task there, then its lines and "Show more".
    private func projectPanel(_ panel: ProjectPanel) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 1
        stack.children.append(header(panel))
        for line in panel.lines {
            switch line {
            case let .task(task): stack.children.append(taskRow(task))
            case let .suggestion(_, title, task, action): stack.children.append(suggestionRow(title, task, action))
            }
        }
        if let toggle = panel.toggle { stack.children.append(toggleRow(toggle, section: panel.section)) }
        return stack
    }

    /// The project's name (the chosen one in the accent), what its folder is on and what finished today, and its
    /// open pull requests.
    private func header(_ panel: ProjectPanel) -> FrameworkElement {
        let button = Self.rowButton()
        let row = Grid()
        row.columnSpacing = 8
        SidebarStyle.columns(row, [SidebarStyle.pixels(16), SidebarStyle.auto, SidebarStyle.star, SidebarStyle.auto,
                                   SidebarStyle.auto])
        let tint = panel.isChosen ? WindowsTheme.accent : WindowsTheme.secondaryText
        let mark = ComposerParts.glyph(panel.isChat ? ComposerParts.Glyph.fromTask : ComposerParts.Glyph.folder,
                                       size: 12, color: tint)
        mark.horizontalAlignment = .center
        row.children.append(mark)
        let name = ComposerParts.label(panel.name, size: 14.5, color: panel.isChosen ? WindowsTheme.accent : WindowsTheme.text,
                                       weight: 600)
        name.maxWidth = 260
        try? Grid.setColumn(name, 1)
        row.children.append(name)
        if let facts = panel.facts {
            let words = ComposerParts.label(facts, size: 12, weight: 400)
            try? Grid.setColumn(words, 2)
            row.children.append(words)
        }
        if let pill = panel.pill {
            let badge = Self.pill(pill)
            try? Grid.setColumn(badge, 3)
            row.children.append(badge)
        }
        if let others = panel.otherPullRequests {
            let more = ComposerParts.label("+\(others.count)", size: 11.5, color: WindowsTheme.tertiaryText, weight: 400)
            try? ToolTipService.setToolTip(more, others.help)
            try? Grid.setColumn(more, 4)
            row.children.append(more)
        }
        button.content = row
        try? ToolTipService.setToolTip(button, panel.help)
        try? AutomationProperties.setName(button, panel.name)
        let action = panel.choose
        let url = panel.pill?.url
        button.click.addHandler { [weak self] _, _ in
            // Ctrl-click opens the project's pull request on GitHub, as ⌘-click does on the Mac.
            if Self.isControlDown, let url {
                WindowsBrowser.open(url)
            } else {
                self?.onAction(action)
            }
        }
        return button
    }

    /// A task's line: its mark, its state's name while it waits, its harness and title, what went wrong or its
    /// pull request, its time or how long it has run, and under it its latest answer's first line; the reply arrow
    /// where it is answered in the composer's place, and the ✕ that marks an unread result read.
    private func taskRow(_ task: TaskLine) -> FrameworkElement {
        let button = Self.rowButton()
        if task.isAnswering { button.background = WindowsTheme.selectedFill.brush }
        let row = Grid()
        row.columnSpacing = 7
        SidebarStyle.columns(row, [SidebarStyle.pixels(14), SidebarStyle.star, SidebarStyle.auto])
        let mark = Grid()
        mark.width = 14
        mark.height = 14
        mark.verticalAlignment = .top
        mark.margin = Thickness(left: 0, top: 2, right: 0, bottom: 0)
        if let status = task.status { mark.children.append(SidebarStatusMark.view(status)) }
        row.children.append(mark)

        let words = StackPanel()
        words.spacing = 1
        words.verticalAlignment = .center
        let line = Grid()
        line.columnSpacing = 7
        var columns: [GridLength] = []
        func add(_ element: FrameworkElement, _ width: GridLength) {
            try? Grid.setColumn(element, Int32(columns.count))
            columns.append(width)
            line.children.append(element)
        }
        if let name = task.statusName { add(ComposerParts.label(name, size: 12, weight: 400), SidebarStyle.auto) }
        if let icon = HarnessIcon.element(for: task.harness, size: 14) { add(icon, SidebarStyle.auto) }
        add(ComposerParts.label(task.title, size: 13, color: WindowsTheme.text, weight: task.weight), SidebarStyle.star)
        if let detail = task.detail {
            let text = ComposerParts.label(detail, size: 12, weight: 400)
            text.maxWidth = 220
            add(text, SidebarStyle.auto)
        }
        if let subtasks = task.subtasks {
            let capsule = Border()
            capsule.background = WindowsTheme.subtleFill.brush
            capsule.cornerRadius = ComposerParts.corners(9)
            capsule.padding = Thickness(left: 6, top: 1, right: 6, bottom: 1)
            capsule.child = ComposerParts.label(subtasks, size: 11.5, weight: 400)
            add(capsule, SidebarStyle.auto)
        }
        if let number = task.pullRequestNumber { add(ComposerParts.label(number, size: 12, weight: 400), SidebarStyle.auto) }
        add(ComposerParts.label(task.time, size: 11.5, color: WindowsTheme.tertiaryText, weight: 400), SidebarStyle.auto)
        for width in columns {
            let column = ColumnDefinition()
            column.width = width
            line.columnDefinitions.append(column)
        }
        words.children.append(line)
        if let answer = task.answer {
            let text = ComposerParts.label(answer, size: 12, weight: 400)
            text.margin = Thickness(left: 21, top: 0, right: 0, bottom: 0)
            words.children.append(text)
            button.padding = Thickness(left: 10, top: 5, right: 10, bottom: 5)
        }
        try? Grid.setColumn(words, 1)
        row.children.append(words)

        let chevron = ComposerParts.glyph(task.answersInPlace ? Self.replyGlyph : Self.chevronGlyph, size: 10,
                                          color: task.isAnswering ? WindowsTheme.accent : WindowsTheme.tertiaryText)
        try? Grid.setColumn(chevron, 2)
        row.children.append(chevron)
        button.content = row
        let name = ([task.statusName, task.title].compactMap { $0 }).joined(separator: " ")
        try? AutomationProperties.setName(button, name)
        try? ToolTipService.setToolTip(button, task.title)

        let id = task.id
        let reply = task.answersInPlace
        let url = task.pullRequestURL
        button.click.addHandler { [weak self] _, _ in
            // Ctrl-click opens the task's pull request on GitHub; a double-click opens the task.
            if Self.isControlDown, let url {
                WindowsBrowser.open(url)
            } else {
                self?.onAction(reply ? .reply(id) : .openTask(id))
            }
        }
        if reply { button.doubleTapped.addHandler { [weak self] _, _ in self?.onAction(.openTask(id)) } }
        guard task.canMarkRead else { return button }
        return Self.withDismiss(button, chevron: chevron, label: L10n.string("Mark task as read")) { [weak self] in
            self?.markRead([id])
        }
    }

    private func suggestionRow(_ title: String, _ task: String, _ action: NewTaskHomeAction) -> FrameworkElement {
        let button = Self.rowButton()
        let row = Grid()
        row.columnSpacing = 7
        SidebarStyle.columns(row, [SidebarStyle.pixels(14), SidebarStyle.auto, SidebarStyle.star, SidebarStyle.auto])
        let mark = ComposerParts.glyph(Self.lightbulbGlyph, size: 10.5)
        mark.horizontalAlignment = .center
        row.children.append(mark)
        let name = ComposerParts.label(title, size: 13, color: WindowsTheme.text, weight: 400)
        name.maxWidth = 260
        try? Grid.setColumn(name, 1)
        row.children.append(name)
        let source = ComposerParts.label(task, size: 12, color: WindowsTheme.tertiaryText, weight: 400)
        try? Grid.setColumn(source, 2)
        row.children.append(source)
        let chevron = ComposerParts.glyph(Self.chevronGlyph, size: 10, color: WindowsTheme.tertiaryText)
        try? Grid.setColumn(chevron, 3)
        row.children.append(chevron)
        button.content = row
        try? AutomationProperties.setName(button, title)
        button.click.addHandler { [weak self] _, _ in self?.onAction(action) }
        return button
    }

    /// "Show {count} more" or "Show less" under a panel's lines.
    private func toggleRow(_ words: String, section: NewTaskHomeSection) -> FrameworkElement {
        let button = Self.rowButton()
        let label = ComposerParts.label(words, size: 12, weight: 400)
        label.margin = Thickness(left: 23, top: 0, right: 0, bottom: 0)
        button.content = label
        button.click.addHandler { [weak self] _, _ in self?.toggle(section) }
        return button
    }

    /// The projects left alone for a while that still hold unfinished work: the name, when it was last active and
    /// what it left. Choosing one starts the new task there; a double-click opens the task it was left at; its ✕ sets
    /// it aside until it is active again.
    private func idlePanel(_ panel: IdlePanel) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 1
        let title = Grid()
        title.columnSpacing = 8
        title.minHeight = 32
        title.padding = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        SidebarStyle.columns(title, [SidebarStyle.pixels(16), SidebarStyle.star])
        let clock = ComposerParts.glyph(ComposerParts.Glyph.clock, size: 12)
        clock.horizontalAlignment = .center
        title.children.append(clock)
        let words = ComposerParts.label(L10n.string("Left for a while"), size: 14.5, weight: 600)
        try? Grid.setColumn(words, 1)
        title.children.append(words)
        stack.children.append(title)
        for project in panel.projects { stack.children.append(idleRow(project)) }
        if let toggle = panel.toggle { stack.children.append(toggleRow(toggle, section: .idle)) }
        return stack
    }

    private func idleRow(_ project: IdleLine) -> FrameworkElement {
        let button = Self.rowButton()
        button.padding = Thickness(left: 10, top: 5, right: 10, bottom: 5)
        let row = Grid()
        row.columnSpacing = 7
        SidebarStyle.columns(row, [SidebarStyle.pixels(14), SidebarStyle.star, SidebarStyle.auto])
        let mark = ComposerParts.glyph(ComposerParts.Glyph.folder, size: 11)
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .top
        mark.margin = Thickness(left: 0, top: 3, right: 0, bottom: 0)
        row.children.append(mark)
        let words = StackPanel()
        words.spacing = 1
        let line = Grid()
        line.columnSpacing = 7
        SidebarStyle.columns(line, [SidebarStyle.star, SidebarStyle.auto])
        line.children.append(ComposerParts.label(project.name, size: 13, color: WindowsTheme.text))
        let time = ComposerParts.label(project.time, size: 11.5, color: WindowsTheme.tertiaryText, weight: 400)
        try? Grid.setColumn(time, 1)
        line.children.append(time)
        words.children.append(line)
        words.children.append(ComposerParts.label(project.workLeft, size: 12, weight: 400))
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        let chevron = ComposerParts.glyph(Self.chevronGlyph, size: 10, color: WindowsTheme.tertiaryText)
        try? Grid.setColumn(chevron, 2)
        row.children.append(chevron)
        button.content = row
        try? AutomationProperties.setName(button, project.name)
        try? ToolTipService.setToolTip(button, project.help)
        let choose = project.choose
        let open = project.open
        let url = project.pullRequestURL
        button.click.addHandler { [weak self] _, _ in
            if Self.isControlDown, let url {
                WindowsBrowser.open(url)
            } else {
                self?.onAction(choose)
            }
        }
        button.doubleTapped.addHandler { [weak self] _, _ in self?.onAction(open) }
        let id = project.id
        let lastActive = project.lastActive
        return Self.withDismiss(button, chevron: chevron, label: L10n.string("Dismiss until it is active again")) {
            [weak self] in
            self?.setAside(id, lastActive)
        }
    }

    // MARK: Pieces

    private static let chevronGlyph = "\u{E76C}"
    private static let replyGlyph = "\u{E97A}"
    private static let lightbulbGlyph = "\u{E82F}"
    private static let dismissGlyph = "\u{E711}"

    /// A line of the lists: no frame, the Mac's fill under the pointer, rounded 8, at least 32 high.
    private static func rowButton() -> Button {
        let button = Button()
        ComposerParts.styleFlat(button, radius: 8)
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        button.padding = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        button.minHeight = 32
        return button
    }

    /// The row with a ✕ at its end while the pointer is on it, in the chevron's place, as the Mac's row has it.
    private static func withDismiss(_ row: Button, chevron: FrameworkElement, label: String,
                                    action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let container = Grid()
        container.children.append(row)
        let dismiss = Button()
        ComposerParts.styleFlat(dismiss, radius: 4)
        dismiss.width = 20
        dismiss.height = 20
        dismiss.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        dismiss.horizontalAlignment = .right
        dismiss.verticalAlignment = .center
        dismiss.margin = Thickness(left: 0, top: 0, right: 6, bottom: 0)
        dismiss.content = ComposerParts.glyph(dismissGlyph, size: 9)
        dismiss.opacity = 0
        dismiss.isHitTestVisible = false
        try? AutomationProperties.setName(dismiss, label)
        try? ToolTipService.setToolTip(dismiss, label)
        dismiss.click.addHandler { _, _ in action() }
        container.children.append(dismiss)
        container.pointerEntered.addHandler { [weak dismiss, weak chevron] _, _ in
            dismiss?.opacity = 1
            dismiss?.isHitTestVisible = true
            chevron?.opacity = 0
        }
        container.pointerExited.addHandler { [weak dismiss, weak chevron] _, _ in
            dismiss?.opacity = 0
            dismiss?.isHitTestVisible = false
            chevron?.opacity = 1
        }
        return container
    }

    /// An open pull request's pill: "#12 Open" in its state's color over a light fill of it.
    private static func pill(_ pill: Pill) -> FrameworkElement {
        let colors = toneColors(pill.tone)
        let border = Border()
        border.background = colors.fill.brush
        border.cornerRadius = ComposerParts.corners(9)
        border.padding = Thickness(left: 6, top: 1, right: 6, bottom: 1)
        border.verticalAlignment = .center
        border.child = ComposerParts.label("#\(pill.number) \(pill.title)", size: 11, color: colors.text)
        try? ToolTipService.setToolTip(border, pill.url.absoluteString)
        return border
    }

    /// The Mac's colors for a pull request's state (`TaskPullRequestBadgeView.color`), and their fill at 12%.
    private static func toneColors(_ tone: TaskPullRequestBadge.Tone) -> (text: ThemeColor, fill: ThemeColor) {
        switch tone {
        case .neutral: return (text: WindowsTheme.secondaryText, fill: WindowsTheme.subtleFill)
        case .success: return (text: SidebarStyle.green, fill: greenFill)
        case .pending: return (text: SidebarStyle.orange, fill: orangeFill)
        case .failure: return (text: SidebarStyle.red, fill: redFill)
        case .merged: return (text: purple, fill: purpleFill)
        }
    }

    private static let purple = ThemeColor(light: .rgb(0.69, 0.32, 0.87), dark: .rgb(0.75, 0.35, 0.95))
    private static let greenFill = ThemeColor(light: .tint(0.20, 0.78, 0.35), dark: .tint(0.19, 0.82, 0.35))
    private static let orangeFill = ThemeColor(light: .tint(1.00, 0.58, 0.00), dark: .tint(1.00, 0.62, 0.04))
    private static let redFill = ThemeColor(light: .tint(1.00, 0.23, 0.19), dark: .tint(1.00, 0.27, 0.23))
    private static let purpleFill = ThemeColor(light: .tint(0.69, 0.32, 0.87), dark: .tint(0.75, 0.35, 0.95))

    /// Ctrl is held: a click opens the pull request, as ⌘ does on the Mac.
    private static var isControlDown: Bool { GetKeyState(VK_CONTROL) < 0 }
}

private extension UWP.Color {
    /// A color at 12%, the fill under a pill's words.
    static func tint(_ red: Double, _ green: Double, _ blue: Double) -> UWP.Color {
        func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        return UWP.Color(a: byte(0.12), r: byte(red), g: byte(green), b: byte(blue))
    }
}
