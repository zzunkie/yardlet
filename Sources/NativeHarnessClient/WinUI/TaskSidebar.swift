import Foundation
import Observation
import UWP
import WinUI

/// What the window shows beside the sidebar, which the sidebar shows chosen.
enum SidebarPlace: Equatable {
    /// New task, the Mac's home.
    case home
    case task(UUID)
    case settings
}

/// A window's sidebar, as the Mac's (`TaskSidebar`): Home and "Search tasks" at the top; then the pinned tasks, the
/// chats and the projects, each project under its name, which collapses it and opens its menu, listing its first five
/// tasks until "Show more"; each task nested under the task it was started from; and Settings at the bottom, or the
/// window's own footer. What it lists, in what order and with what state is the Mac's own reading of the tasks
/// (`SidebarProjection`, `SidebarTaskIndicatorProjection`), followed through Observation; only the drawing is Windows'.
/// The tasks are this computer's or another computer's (`TaskSource`), as the Mac's host window draws the same sidebar
/// from its host's mirror. The search narrows the lists by the tasks' titles and the projects' names. The Mac's split
/// views, activity view, grouping by state, hover cards and drags are the Mac's alone.
@MainActor
final class TaskSidebar {
    let view = Grid()
    /// Called when the person chooses a place: Home, a task, Settings.
    var onChoose: (SidebarPlace) -> Void = { _ in }
    /// New task in a project, from its menu: the project's folder.
    var onNewTaskInProject: (URL) -> Void = { _ in }
    /// The + beside Projects.
    var onAddProject: () -> Void = {}
    /// The rows as last drawn, in order, which the window's keys move through.
    private(set) var layout = SidebarProjection.Layout()

    private let source: TaskSource
    private let actions: TaskActions
    /// Which projects and families are collapsed: kept across launches for this computer's tasks, and only while the
    /// window is open for another computer's, which leaves nothing of its projects here.
    private let disclosure: SidebarDisclosureStore
    private var query: String?
    private var chosen: SidebarPlace?
    private var generation = 0

    private let places = SidebarList(rest: WindowsTheme.hoverFill)
    private let search = TextBox()
    private let scroller = ScrollViewer()
    private let lists = StackPanel()
    private let status = TextBlock()
    private let pinnedTitle = SidebarStyle.label(L10n.string("Pinned"), semibold: true)
    private let pinned = SidebarList()
    private let chatsTitle = SidebarStyle.label(L10n.string("Chats"), semibold: true)
    private let chats = SidebarList()
    private let chatsMore = Button()
    private let projectsTitle = Grid()
    private let projectsPanel = StackPanel()
    private var projects: [String: SidebarProjectSection] = [:]
    private var shownProjectKeys: [String] = []
    private let footer = SidebarList()
    private var rows: [UUID: SidebarTaskRow] = [:]
    /// The lines under collapsed families, by the task at the top of each.
    private var summaries: [UUID: SidebarFamilySummaryRow] = [:]
    /// Where each of the footer's rows goes.
    private var footerPlaces: [String: SidebarPlace] = [:]

    /// - Parameter footer: what the sidebar ends in, in place of Settings: another computer's window names that
    ///   computer there, as the Mac's does.
    init(source: TaskSource, actions: TaskActions, footer: FrameworkElement? = nil) {
        self.source = source
        self.actions = actions
        disclosure = source.managesProjects ? SidebarDisclosureStore() : SidebarDisclosureStore(defaults: nil)
        make(footer: footer)
        follow()
    }

    // MARK: Choosing

    /// Shows `place` chosen, as the window shows it, without telling `onChoose`.
    func choose(_ place: SidebarPlace?) {
        let isNew = place != chosen
        chosen = place
        markChosen()
        // A task chosen elsewhere (a notification, the window's keys) in a collapsed project opens it, as on the Mac.
        // The project of the task already shown stays collapsed when the person collapses it.
        if isNew, case let .task(id) = place,
           let key = SidebarProjection.disclosureKey(holding: .session(id), in: layout), disclosure.isCollapsed(key) {
            disclosure.expand(key)
        }
    }

    /// Marks the chosen place's row in the lists.
    private func markChosen() {
        places.choose(chosen == .home ? Self.homeKey : nil)
        let taskKey: String? = if case let .task(id) = chosen { Self.key(id) } else { nil }
        for list in taskLists { list.choose(taskKey) }
        footer.choose(footerPlaces.first { $0.value == chosen }?.key)
    }

    private func pick(_ place: SidebarPlace) {
        guard place != chosen else { return }
        choose(place)
        onChoose(place)
    }

    private var taskLists: [SidebarList] {
        [pinned, chats] + projects.values.map(\.list)
    }

    private static let homeKey = "home"
    private static func key(_ id: UUID) -> String { "task:" + id.uuidString }

    // MARK: Making

    private func make(footer custom: FrameworkElement?) {
        view.width = WindowsTheme.sidebarWidth
        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            view.rowDefinitions.append(row)
        }

        let home = SidebarList.actionRow(glyph: "\u{E80F}", title: L10n.string("Home"),
                                         height: SidebarStyle.homeRowHeight, weight: 500)
        places.fill([(key: Self.homeKey, item: home)])
        places.onPick = { [weak self] _ in self?.pick(.home) }
        places.view.margin = Thickness(left: 0, top: 4, right: 0, bottom: 0)
        view.children.append(places.view)

        let searchRow = makeSearch()
        try? Grid.setRow(searchRow, 1)
        view.children.append(searchRow)

        lists.padding = Thickness(left: 0, top: 4, right: 0, bottom: 8)
        status.fontSize = SidebarStyle.titleFontSize
        status.foreground = WindowsTheme.secondaryText.brush
        status.margin = Thickness(left: SidebarStyle.rowInset + SidebarStyle.gutterWidth, top: 8, right: 8, bottom: 8)
        status.visibility = .collapsed
        lists.children.append(status)
        for title in [pinnedTitle, chatsTitle] {
            title.margin = Thickness(left: SidebarStyle.labelLeading, top: 12, right: 8, bottom: 2)
        }
        lists.children.append(pinnedTitle)
        lists.children.append(pinned.view)
        lists.children.append(chatsTitle)
        lists.children.append(chats.view)
        chatsMore.content = Self.moreLabel()
        SidebarStyle.stylePlain(chatsMore)
        chatsMore.margin = Thickness(left: SidebarStyle.rowInset, top: 0, right: SidebarStyle.rowInset, bottom: 0)
        chatsMore.click.addHandler { [weak self] _, _ in self?.disclosure.showMore(SidebarChats.disclosureKey) }
        lists.children.append(chatsMore)
        makeProjectsTitle()
        lists.children.append(projectsTitle)
        lists.children.append(projectsPanel)
        for list in [pinned, chats] {
            list.onPick = { [weak self] key in self?.pickTask(key) }
        }
        scroller.content = lists
        scroller.verticalScrollBarVisibility = .auto
        scroller.horizontalScrollBarVisibility = .disabled
        try? Grid.setRow(scroller, 2)
        view.children.append(scroller)

        // The Mac's account button at the bottom is Settings here, as Windows apps keep it, under a line.
        // Import conversation is New task's link, as on the Mac's home.
        footer.fill([(key: "settings", item: SidebarList.actionRow(glyph: "\u{E713}", title: L10n.string("Settings")))])
        footerPlaces["settings"] = .settings
        footer.onPick = { [weak self] key in
            guard let self, let place = self.footerPlaces[key] else { return }
            self.pick(place)
        }
        let footerFrame = Border()
        footerFrame.borderBrush = WindowsTheme.separator.brush
        footerFrame.borderThickness = Thickness(left: 0, top: 1, right: 0, bottom: 0)
        footerFrame.padding = Thickness(left: 0, top: 4, right: 0, bottom: 4)
        footerFrame.child = custom ?? footer.view
        try? Grid.setRow(footerFrame, 3)
        view.children.append(footerFrame)
    }

    /// "Search tasks", as the Mac's field: its magnifier in the rows' gutter and the words where titles start, on a
    /// light fill. Windows' own clear button and focus line stay.
    private func makeSearch() -> Grid {
        let row = Grid()
        row.margin = Thickness(left: SidebarStyle.rowInset, top: 8, right: SidebarStyle.rowInset, bottom: 4)
        search.placeholderText = L10n.string("Search tasks")
        try? AutomationProperties.setName(search, L10n.string("Search tasks"))
        search.fontSize = SidebarStyle.titleFontSize
        search.minHeight = SidebarStyle.rowHeight
        search.padding = Thickness(left: SidebarStyle.gutterWidth, top: 6, right: 8, bottom: 5)
        search.cornerRadius = CornerRadius(topLeft: SidebarStyle.rowCornerRadius, topRight: SidebarStyle.rowCornerRadius,
                                           bottomRight: SidebarStyle.rowCornerRadius,
                                           bottomLeft: SidebarStyle.rowCornerRadius)
        let resources = search.resources
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver"] {
            _ = resources?.insert(key, WindowsTheme.subtleFill.brush)
        }
        for key in ["TextControlBorderBrush", "TextControlBorderBrushPointerOver"] {
            _ = resources?.insert(key, SidebarStyle.clear)
        }
        search.textChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            let words = self.search.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = words.isEmpty ? nil : words
            guard query != self.query else { return }
            self.query = query
            self.follow()
        }
        row.children.append(search)
        let magnifier = SidebarStyle.glyph("\u{E721}", size: 12, color: WindowsTheme.tertiaryText)
        magnifier.width = SidebarStyle.gutterWidth
        magnifier.horizontalAlignment = .left
        magnifier.verticalAlignment = .center
        magnifier.isHitTestVisible = false
        row.children.append(magnifier)
        return row
    }

    /// "Projects" with the + that adds one, as the Mac's section title.
    private func makeProjectsTitle() {
        projectsTitle.margin = Thickness(left: SidebarStyle.labelLeading, top: 12, right: SidebarStyle.rowInset, bottom: 0)
        SidebarStyle.columns(projectsTitle, [SidebarStyle.star, SidebarStyle.auto])
        projectsTitle.children.append(SidebarStyle.label(L10n.string("Projects"), semibold: true))
        let add = Button()
        SidebarStyle.stylePlain(add)
        add.horizontalAlignment = .right
        add.width = 24
        add.height = 24
        add.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        add.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        let plus = SidebarStyle.glyph("\u{E710}", size: 10, color: WindowsTheme.secondaryText)
        plus.horizontalAlignment = .center
        add.content = plus
        try? AutomationProperties.setName(add, L10n.string("Add project"))
        try? ToolTipService.setToolTip(add, L10n.string("Add project"))
        add.click.addHandler { [weak self] _, _ in self?.onAddProject() }
        // Another computer's projects are added there, as the Mac's host window offers no +.
        add.visibility = source.managesProjects ? .visible : .collapsed
        try? Grid.setColumn(add, 1)
        projectsTitle.children.append(add)
    }

    static func moreLabel() -> TextBlock {
        let words = SidebarStyle.label(L10n.string("Show more"), size: SidebarStyle.titleFontSize,
                                       color: WindowsTheme.tertiaryText)
        words.margin = Thickness(left: SidebarStyle.gutterWidth, top: 0, right: 0, bottom: 0)
        return words
    }

    private func pickTask(_ key: String) {
        // The line under a collapsed family shows the family again; the task shown stays chosen.
        if key.hasPrefix("family:") {
            disclosure.toggle(key)
            markChosen()
            return
        }
        guard key.hasPrefix("task:"), let id = UUID(uuidString: String(key.dropFirst(5))) else { return }
        pick(.task(id))
    }

    /// What a task's row menu offers for its family, as the Mac's row menu reads it when it opens: Hide or Show nested
    /// sessions for a task with tasks nested under it, and its moves among the families of its list.
    private func family(of id: UUID) -> TaskActions.Family {
        let key = SidebarProjection.familyKey(for: id)
        let hasFamily = layout.rows.contains { $0.id == .session(id) && $0.hasFamily }
        return TaskActions.Family(
            isCollapsed: hasFamily ? disclosure.isCollapsed(key) : nil,
            toggle: { [weak self] in self?.disclosure.toggle(key) },
            nesting: TaskNesting.options(for: id, in: layout))
    }

    // MARK: Following the tasks

    /// What the lists show, worked out from the model.
    private struct Drawing {
        struct Project {
            let key: String
            let group: WorkspaceGroup
            let isCollapsed: Bool
            let rows: [Entry]
            let hiddenRowCount: Int
            let showsEmptyState: Bool
            /// A collapsed project's most urgent task's state.
            let status: SidebarTaskStatus?
        }

        /// A row of a list: a task, or the line under a collapsed family, under the task at its top.
        enum Entry: Equatable {
            case task(UUID, SidebarTaskRow.State)
            case familySummary(UUID, SidebarFamilySummaryRow.State)
        }

        var layout = SidebarProjection.Layout()
        var pinned: [Entry] = []
        var chats: [Entry] = []
        var chatsHidden = 0
        var projects: [Project] = []
        var isRestoring = false
        /// Home heads the list: always here, and for another computer while it can start a task.
        var showsHome = true
    }

    /// The lists drawn now and again whenever what they read changes: the tasks, their state, the projects, which are
    /// collapsed and how many each lists. A change waits for the window's next turn, so a burst of changes draws once.
    private func follow() {
        generation += 1
        let generation = generation
        let drawing = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                self.follow()
            }
        }
        draw(drawing)
    }

    private func read() -> Drawing {
        let lists = source.lists()
        let groups = lists.groups
        let allChats = lists.chats
        let details = lists.details
        let shellBusy = lists.shellBusy
        let listed = groups.flatMap(\.sessions) + allChats
        let noConversation: (SessionRecord.ID, String) -> Bool = { _, _ in false }
        let visibleGroups = query.map {
            TaskNavigationProjection.filteredGroups(in: groups, query: $0, projectNames: lists.projectNames,
                                                    conversationMatches: noConversation)
        } ?? groups
        let visibleChats = query.map {
            TaskNavigationProjection.filteredSessions(allChats, query: $0, conversationMatches: noConversation)
        } ?? allChats
        let waiting = Set(listed.lazy.filter {
            TaskAttentionProjection.waitingRequest(of: $0, detail: details[$0.id]) != nil
        }.map(\.id))
        let selection: WindowItem = if case let .task(id) = chosen { .session(id) } else { .home }
        let layout = SidebarProjection.layout(
            visibleGroups: visibleGroups, allGroups: groups, chats: visibleChats, allChats: allChats, splits: [],
            isFiltering: query != nil, disclosure: disclosure.disclosure, selection: selection, waiting: waiting,
            archivedParents: lists.archivedParents)

        // Each task, the tasks nested under it, and, while its family is collapsed, the line counting what it hides.
        func states(_ rows: [SidebarRow], title: (SidebarRow, SessionRecord) -> String) -> [Drawing.Entry] {
            rows.flatMap { family -> [Drawing.Entry] in
                var entries: [Drawing.Entry] = family.rowsWithChildren.compactMap { row in
                    guard case let .session(session) = row.content else { return nil }
                    let status = SidebarTaskIndicatorProjection.status(
                        of: session, detail: details[session.id], isShellBusy: shellBusy.contains(session.id))
                    return .task(session.id, SidebarTaskRow.State(
                        title: title(row, session), harness: session.harness, isUnread: session.hasUnreadUpdate,
                        status: status, place: row.familyPlace))
                }
                if !family.hiddenChildren.isEmpty, case let .session(top) = family.content {
                    entries.append(.familySummary(top.id, SidebarFamilySummaryRow.State(
                        counts: SidebarFamilySummary.counts(of: family.hiddenChildren, details: details,
                                                            shellBusy: shellBusy),
                        showsMore: !family.children.isEmpty)))
                }
                return entries
            }
        }

        var drawing = Drawing(layout: layout, isRestoring: lists.isRestoring, showsHome: source.startsTasks)
        drawing.pinned = states(layout.pinned) { _, session in session.title }
        if let chats = layout.chats {
            drawing.chats = states(chats.rows) { row, _ in SidebarProjection.chatRowTitle(for: row) }
            drawing.chatsHidden = chats.hiddenRowCount
        }
        drawing.projects = layout.sections.map { section in
            Drawing.Project(
                key: section.disclosureKey, group: section.group, isCollapsed: section.isCollapsed,
                rows: states(section.rows) { _, session in SidebarProjection.rowTitle(for: session, under: section.group) },
                hiddenRowCount: section.hiddenRowCount, showsEmptyState: section.showsEmptyState,
                status: section.isCollapsed ? SidebarTaskIndicatorProjection.summary(
                    of: section.allRows.flatMap(\.familySessions), details: details, shellBusy: shellBusy) : nil)
        }
        return drawing
    }

    /// Draws `drawing`: rows whose state changed are redrawn in place, and a list is filled again only when its rows
    /// or their order change. Every list that changes is emptied before any is filled, so a row moving from one list to
    /// another (a task pinned, moved to a project) is never in two.
    private func draw(_ drawing: Drawing) {
        layout = drawing.layout
        places.view.visibility = drawing.showsHome ? .visible : .collapsed
        var listed = Set<UUID>()
        var summarized = Set<UUID>()
        func items(_ entries: [Drawing.Entry]) -> [(key: String, item: ListViewItem)] {
            entries.map { entry in
                switch entry {
                case let .task(id, state):
                    listed.insert(id)
                    let row = rows[id] ?? SidebarTaskRow(id: id, actions: actions) { [weak self] in
                        self?.family(of: id)
                    }
                    rows[id] = row
                    row.show(state)
                    return (key: Self.key(id), item: row.item)
                case let .familySummary(top, state):
                    summarized.insert(top)
                    let line = summaries[top] ?? SidebarFamilySummaryRow()
                    summaries[top] = line
                    line.show(state)
                    return (key: SidebarProjection.familyKey(for: top), item: line.item)
                }
            }
        }

        var plans: [(list: SidebarList, rows: [(key: String, item: ListViewItem)])] = [
            (pinned, items(drawing.pinned)), (chats, items(drawing.chats)),
        ]
        var sections: [SidebarProjectSection] = []
        var keptKeys = Set<String>()
        for project in drawing.projects {
            let section = projects[project.key] ?? makeProject(project.key)
            projects[project.key] = section
            keptKeys.insert(project.key)
            section.show(group: project.group, isCollapsed: project.isCollapsed, hiddenRowCount: project.hiddenRowCount,
                         showsEmptyState: project.showsEmptyState, status: project.status)
            plans.append((section.list, items(project.rows)))
            sections.append(section)
        }
        // A project no longer listed lets its rows go first.
        for (key, section) in projects where !keptKeys.contains(key) {
            plans.append((section.list, []))
        }
        let changed = plans.filter { $0.list.differs($0.rows.map(\.key)) }
        for plan in changed { plan.list.empty() }
        for plan in changed { plan.list.fill(plan.rows) }
        projects = projects.filter { keptKeys.contains($0.key) }
        rows = rows.filter { listed.contains($0.key) }
        summaries = summaries.filter { summarized.contains($0.key) }

        let projectKeys = sections.map(\.key)
        if projectKeys != shownProjectKeys {
            shownProjectKeys = projectKeys
            projectsPanel.children.clear()
            for section in sections { projectsPanel.children.append(section.view) }
        }

        pinnedTitle.visibility = drawing.pinned.isEmpty ? .collapsed : .visible
        pinned.view.visibility = drawing.pinned.isEmpty ? .collapsed : .visible
        chatsTitle.visibility = drawing.chats.isEmpty ? .collapsed : .visible
        chats.view.visibility = drawing.chats.isEmpty ? .collapsed : .visible
        chatsMore.visibility = drawing.chatsHidden > 0 ? .visible : .collapsed
        // While searching, Projects heads only the projects with a match, as on the Mac.
        projectsTitle.visibility = query != nil && drawing.projects.isEmpty ? .collapsed : .visible
        let isEmpty = drawing.pinned.isEmpty && drawing.chats.isEmpty && drawing.projects.allSatisfy(\.rows.isEmpty)
        let note = drawing.isRestoring && isEmpty ? L10n.string("Restoring tasks…")
            : query != nil && isEmpty ? L10n.string("No matching tasks.") : ""
        status.text = note
        status.visibility = note.isEmpty ? .collapsed : .visible
        // The rows are chosen again as the window shows them; a list filled again has none chosen.
        markChosen()
    }

    private func makeProject(_ key: String) -> SidebarProjectSection {
        let section = SidebarProjectSection(key: key)
        section.onToggle = { [weak self] in self?.disclosure.toggle(key) }
        section.onShowMore = { [weak self] in self?.disclosure.showMore(key) }
        section.list.onPick = { [weak self] picked in self?.pickTask(picked) }
        let group: @MainActor () -> WorkspaceGroup? = { [weak self] in
            self?.layout.sections.first { $0.disclosureKey == key }?.group
        }
        let newTask: @MainActor () -> Void = { [weak self] in
            guard let self, let folder = group()?.workspaceURL else { return }
            self.onNewTaskInProject(folder)
        }
        section.onNewTask = newTask
        // One menu for a right click on the name and one for its options button, which open on their own.
        section.header.contextFlyout = actions.projectMenu(for: group, newTask: newTask)
        section.options.flyout = actions.projectMenu(for: group, newTask: newTask)
        return section
    }
}

/// A project in the sidebar, as the Mac's: its name, which collapses and expands it (with a caret while collapsed
/// and, then, its most urgent task's state at its end) and opens the project's menu on a right click; under the
/// pointer, the Mac's Project options and New task in project at its end; its tasks; and "Show more", or "No chats"
/// for a project with none.
@MainActor
final class SidebarProjectSection {
    let key: String
    let view = StackPanel()
    let header = Button()
    /// Project options, the project's menu, at the name's end under the pointer.
    let options = Button()
    let list = SidebarList()
    var onToggle: () -> Void = {}
    var onShowMore: () -> Void = {}
    var onNewTask: () -> Void = {}
    private let headerRow = Grid()
    private let hoverButtons = StackPanel()
    private let name = SidebarStyle.label("")
    private let caret = SidebarStyle.glyph("\u{E76C}", size: 8, color: WindowsTheme.secondaryText)
    private let end = Grid()
    private let more = Button()
    private let empty = SidebarStyle.label(L10n.string("No chats"), size: SidebarStyle.titleFontSize,
                                           color: WindowsTheme.tertiaryText)
    private var drawn: String?

    init(key: String) {
        self.key = key
        let words = Grid()
        words.height = 28
        SidebarStyle.columns(words, [SidebarStyle.auto, SidebarStyle.auto, SidebarStyle.star, SidebarStyle.auto])
        words.children.append(name)
        caret.margin = Thickness(left: 4, top: 1, right: 0, bottom: 0)
        caret.verticalAlignment = .center
        try? Grid.setColumn(caret, 1)
        words.children.append(caret)
        end.width = 14
        end.height = 14
        end.verticalAlignment = .center
        try? Grid.setColumn(end, 3)
        words.children.append(end)
        SidebarStyle.stylePlain(header)
        header.padding = Thickness(left: SidebarStyle.labelLeading - SidebarStyle.rowInset, top: 0,
                                   right: SidebarStyle.rowTrailingPadding, bottom: 0)
        header.content = words
        header.click.addHandler { [weak self] _, _ in self?.onToggle() }
        headerRow.margin = Thickness(left: SidebarStyle.rowInset, top: 4, right: SidebarStyle.rowInset, bottom: 0)
        headerRow.children.append(header)
        hoverButtons.orientation = .horizontal
        hoverButtons.horizontalAlignment = .right
        hoverButtons.verticalAlignment = .center
        hoverButtons.margin = Thickness(left: 0, top: 0, right: 3, bottom: 0)
        hoverButtons.opacity = 0
        let newTask = Button()
        newTask.click.addHandler { [weak self] _, _ in self?.onNewTask() }
        for (button, glyph, name) in [(options, "\u{E712}", L10n.string("Project options")),
                                      (newTask, "\u{E70F}", L10n.string("New task in project"))] {
            SidebarStyle.stylePlain(button)
            button.width = 24
            button.height = 24
            button.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
            button.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
            button.isTabStop = false
            let mark = SidebarStyle.glyph(glyph, size: 11, color: WindowsTheme.secondaryText)
            mark.horizontalAlignment = .center
            button.content = mark
            try? AutomationProperties.setName(button, name)
            try? ToolTipService.setToolTip(button, name)
            hoverButtons.children.append(button)
        }
        headerRow.children.append(hoverButtons)
        // The Mac shows the project's buttons in place of its state while the pointer is over its name.
        headerRow.pointerEntered.addHandler { [weak self] _, _ in self?.showHoverButtons(true) }
        headerRow.pointerExited.addHandler { [weak self] _, _ in self?.showHoverButtons(false) }
        view.children.append(headerRow)
        view.children.append(list.view)
        more.content = TaskSidebar.moreLabel()
        SidebarStyle.stylePlain(more)
        more.margin = Thickness(left: SidebarStyle.rowInset, top: 0, right: SidebarStyle.rowInset, bottom: 0)
        more.click.addHandler { [weak self] _, _ in self?.onShowMore() }
        view.children.append(more)
        empty.margin = Thickness(left: SidebarStyle.rowInset + SidebarStyle.gutterWidth, top: 6, right: 8, bottom: 6)
        view.children.append(empty)
        view.padding = Thickness(left: 0, top: 0, right: 0, bottom: 8)
    }

    private func showHoverButtons(_ shown: Bool) {
        hoverButtons.opacity = shown ? 1 : 0
        end.opacity = shown ? 0 : 1
    }

    func show(group: WorkspaceGroup, isCollapsed: Bool, hiddenRowCount: Int, showsEmptyState: Bool,
              status: SidebarTaskStatus?) {
        let drawing = "\(group.displayName)|\(isCollapsed)|\(hiddenRowCount > 0)|\(showsEmptyState)|\(String(describing: status))"
        guard drawing != drawn else { return }
        drawn = drawing
        name.text = group.displayName
        caret.visibility = isCollapsed ? .visible : .collapsed
        list.view.visibility = isCollapsed ? .collapsed : .visible
        more.visibility = hiddenRowCount > 0 ? .visible : .collapsed
        empty.visibility = showsEmptyState ? .visible : .collapsed
        end.children.clear()
        if let status { end.children.append(SidebarStatusMark.view(status)) }
        // The Mac's words for the project's row, with whether it is open.
        try? AutomationProperties.setName(header, L10n.format("Project %@", group.displayName))
        let help = [group.displayName, L10n.string(isCollapsed ? "Expand folder" : "Collapse folder")]
            + (status.map { [$0.help] } ?? [])
        try? ToolTipService.setToolTip(header, help.joined(separator: "\n"))
    }
}
