import QuickLook
import SwiftUI
import YardletRemote

/// A window for another Mac's Yardlet (File › Connect to Mac…): one window per host, its title the host's
/// name and how it is connected. Its sidebar lists the host's projects and tasks with their marks, a task
/// opens in the app's own conversation view with the same request cards, and the composer sends through the
/// host's own paths (docs/REMOTE_PROTOCOL.md). This Mac's own tasks stay in their own window; nothing of
/// the host's is mixed into them.
struct RemoteHostWindow: View {
    static let sceneID = "remote-host"

    let hostID: String?
    let directory: RemoteHostDirectory
    @State private var model: RemoteHostModel?

    var body: some View {
        Group {
            // A host removed meanwhile (from File › Connect to Mac…) leaves its window with nothing to show.
            if let model, directory.host(model.id) != nil {
                RemoteHostView(model: model, directory: directory)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(L10n.string("This Mac is no longer paired."))
                        .font(.callout.weight(.semibold))
                    Text(L10n.string("Pair it again from File › Connect to Mac…."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: hostID) {
            model = hostID.flatMap(directory.model(for:))
        }
        // A closed window ends its connection; reopening it connects again.
        .onDisappear { if let hostID { directory.close(hostID) } }
    }
}

/// The window's content once its host is known, in this Mac's own window shell: the sidebar column with the title bar's
/// sidebar part (Hide sidebar, the activity view, New task), this Mac's own sidebar (`TaskSidebar`) listing the host's
/// projects and tasks as the host's sidebar does (`RemoteHostModel.sidebar`), and the host's task, new task or schedule
/// beside it. The Task and View menus act on it as on the local window, through the host's own paths.
struct RemoteHostView: View {
    let model: RemoteHostModel
    let directory: RemoteHostDirectory
    @State private var drafts: RemoteComposerDrafts
    @State private var shell = RemoteHostShell()
    @State private var windowWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: RemoteHostModel, directory: RemoteHostDirectory, drafts: RemoteComposerDrafts = RemoteComposerDrafts(),
         shell: RemoteHostShell = RemoteHostShell()) {
        self.model = model
        self.directory = directory
        _drafts = State(initialValue: drafts)
        _shell = State(initialValue: shell)
    }

    var body: some View {
        HStack(spacing: 0) {
            if shell.isSidebarVisible {
                SidebarColumn(state: shell.sidebarWidth, windowWidth: windowWidth) {
                    VStack(spacing: 0) {
                        TitleBarSidebarPart(
                            isSidebarVisible: true, width: shell.sidebarWidth.shown(inWindowWidth: windowWidth),
                            onToggleSidebar: toggleSidebar, onNewTask: showNewTask,
                            activityToggle: ActivityViewToggle(isOn: shell.isShowingActivity, needsAttention: needsAttention,
                                                               toggle: toggleActivity))
                        if model.showsSchedules {
                            RemoteScheduleList(model: model)
                        } else {
                            sidebar
                        }
                    }
                }
            }
            VStack(spacing: 0) {
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ParityTheme.canvas)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // Ordinary controls stay monochrome, as in the local window; status, links and Send opt into the accent.
        .tint(Color.primary)
        .navigationTitle(model.name)
        .navigationSubtitle(RemoteConnectionText.line(model.connection))
        .modifier(RemotePresence(model: model))
        .modifier(RemoteTaskActionAlerts(model: model))
        .modifier(RemoteScheduleSheets(model: model))
        .focusedSceneValue(\.yardletTaskCommands, taskCommands)
        .focusedSceneValue(\.yardletSplitCommands, splitCommands)
        .onChange(of: windowSelection) { old, new in shell.follow(new, from: old) }
        .background(RemoteDraftAutosave(draft: shownDraft, drafts: drafts))
        .onAppear { drafts.restore(from: model.cacheFolder) }
        .onChange(of: model.selection) { _, _ in drafts.save() }
        .onDisappear { drafts.save() }
    }

    /// The draft the window shows: the task's, or the new task's.
    private var shownDraft: TaskComposerDraft {
        if case let .task(id) = model.selection { return drafts.draft(for: id) }
        return drafts.newTask
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        if model.showsArchive && model.taskActions {
            VStack(spacing: 0) {
                ArchivedTaskList(archived: model.archivedTasks, errorMessage: model.commandError,
                    restoringIDs: model.restoringArchived, searchText: $shell.archivedSearchText,
                    projectName: { model.archiveProjectNames[$0.id] ?? L10n.string("Chats") },
                    onBack: { model.showsArchive = false },
                    onUnarchive: { record in Task { await model.restoreTask(record) } }, showsWorkspace: false)
                if model.archiveCursor != nil {
                    Button(L10n.string("Load more")) { Task { await model.loadArchivedTasks(reset: false) } }
                        .disabled(model.readingArchive)
                }
            }.task { await model.loadArchivedTasks() }
        } else { taskSidebar }
    }

    private var taskSidebar: some View {
        let mirror = model.sidebar
        let layout = sidebarLayout(mirror)
        return TaskSidebar(
            layout: layout,
            allGroups: mirror.groups,
            isRestoring: !model.hasSnapshot,
            selection: SidebarProjection.row(for: windowSelection, in: layout) ?? windowSelection,
            searchText: $shell.searchText,
            onNewTask: showNewTask,
            onShowSchedules: model.offersSchedules ? { showSchedules() } : nil,
            onActivate: activate,
            onNewTaskInProject: { folder in showNewTaskInProject(mirror.projectIDs[folder.standardizedFileURL]) },
            projects: shell.projects,
            onEditProject: { _ in },
            onArchiveProjectChats: { model.archiveProject = $0 },
            onRemoveProject: { _ in },
            onTogglePinned: { session in model.send(.setPinned(taskID: session.id.uuidString, pinned: !session.isPinned)) },
            onArchive: { session in model.send(.archiveTask(taskID: session.id.uuidString)) },
            onDelete: model.taskActions ? { model.deleteTask = $0 } : nil,
            onRename: model.taskActions ? { model.renameTitle = $0.title; model.renameTask = $0 } : nil,
            onMarkRead: { session in model.send(.markRead(taskID: session.id.uuidString)) },
            onMarkUnread: model.taskActions ? { model.taskAction($0, .init(.markUnread)) } : nil,
            onMoveToProject: model.taskActions ? { model.taskAction($0, .init(.move, value: $1?.id.uuidString)) } : nil,
            onNest: model.taskActions ? { task, parent in model.send(.taskAction(taskID: task.uuidString, action: .init(.nest, value: parent?.uuidString))) } : nil,
            managesProjects: false,
            onRemoteProjectPin: model.taskActions ? { group in
                if let project = group.project { model.send(.projectAction(projectID: project.id.uuidString, pinned: !project.isPinned, archive: false)) }
            } : nil,
            canArchiveRemoteProject: model.taskActions,
            remoteProjectMoveOptions: model.projectMoveOptions,
            footer: AnyView(RemoteHostFooter(model: model, directory: directory)),
            disclosure: shell.disclosure,
            activity: activity(mirror)
        )
        .environment(\.taskAttentionDetails, mirror.details)
        .environment(\.openWindowItemInNewTab, WindowItemNewTabAction(open: { openInNewTab($0, before: nil) }))
    }

    /// The host's lists as the local sidebar lays them out, filtered by the search on titles and project names (a
    /// conversation's words stay on the host).
    private func sidebarLayout(_ mirror: RemoteSidebarMirror) -> SidebarProjection.Layout {
        let query = shell.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Dictionary(mirror.groups.map { ($0.workspaceURL, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return SidebarProjection.layout(
            visibleGroups: query.isEmpty ? mirror.groups
                : TaskNavigationProjection.filteredGroups(in: mirror.groups, query: query, projectNames: names),
            allGroups: mirror.groups,
            chats: query.isEmpty ? mirror.chats : TaskNavigationProjection.filteredSessions(mirror.chats, query: query),
            allChats: mirror.chats,
            splits: [],
            isFiltering: !query.isEmpty,
            disclosure: shell.disclosure.disclosure,
            selection: windowSelection,
            waiting: Set(mirror.sessions.filter {
                TaskAttentionProjection.waitingRequest(of: $0, detail: mirror.details[$0.id]) != nil
            }.map(\.id)))
    }

    /// The activity view's list while it is on: the host's tasks that need the person or work, in attention order.
    private func activity(_ mirror: RemoteSidebarMirror) -> SidebarActivity? {
        guard shell.isShowingActivity else { return nil }
        let query = shell.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = TaskAttentionProjection.activityList(in: mirror.sessions, details: mirror.details, kept: shell.activityPlaces)
        let names = Dictionary(mirror.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        return SidebarActivity(
            sessions: query.isEmpty ? listed : TaskNavigationProjection.filteredSessions(listed, query: query),
            selectedSessionID: shownTaskID,
            subtitle: { names[$0.id] ?? L10n.string("Chats") },
            onMarkAllRead: {
                for session in mirror.sessions where session.hasUnreadUpdate {
                    model.send(.markRead(taskID: session.id.uuidString))
                }
            })
    }

    private var needsAttention: Bool {
        let mirror = model.sidebar
        return TaskAttentionProjection.count(in: mirror.sessions, details: mirror.details) > 0
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case let .task(taskID):
            if let conversation = model.conversations[taskID] {
                RemoteTaskView(model: model, conversation: conversation, draft: drafts.draft(for: taskID),
                               editing: Binding(get: { drafts.edits[taskID] }, set: { drafts.edits[taskID] = $0 }),
                               titleBar: titleBar, find: drafts.find(for: taskID),
                               readingPosition: drafts.readingPosition(for: taskID), renderState: drafts.renderState(for: taskID),
                               showsRail: $shell.showsRail, railFolds: $shell.railFolds, railPreferences: shell.railPreferences,
                               panels: Binding(get: { shell.panels[taskID] ?? .init() }, set: { shell.panels[taskID] = $0 }),
                               layout: $shell.workspaceLayout,
                               review: Binding(get: { shell.reviews[taskID] ?? .init() }, set: { shell.reviews[taskID] = $0 }))
                    .id(taskID)
            }
        case .newTask:
            plainDetail { RemoteNewTaskView(model: model, draft: drafts.newTask, chosenProjectID: $drafts.newTaskProjectID) }
        case let .schedule(id):
            plainDetail {
                if let schedule = model.schedules.schedule(id) {
                    RemoteScheduleDetail(model: model, schedule: schedule)
                } else {
                    schedulePlaceholder
                }
            }
        case .none where model.showsSchedules:
            plainDetail { schedulePlaceholder }
        case .none:
            plainDetail {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text(model.hasSnapshot ? L10n.format("Choose a task on %@, or start a new one.", model.name)
                                           : L10n.format("Connecting to %@…", model.name))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.hasSnapshot, model.newTask != nil {
                        Button(L10n.string("New task")) { model.select(.newTask) }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A detail with nothing to name in the title bar: the bar's row over it, then the connection's line.
    private func plainDetail(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            RemoteTitleBar(context: titleBar) { WindowDragRegion().frame(maxWidth: .infinity) }
            RemoteConnectionBanner(model: model, directory: directory)
            content()
        }
    }

    private var titleBar: RemoteTitleBarContext {
        RemoteTitleBarContext(isSidebarVisible: shell.isSidebarVisible, toggleSidebar: toggleSidebar, newTask: showNewTask,
                              banner: AnyView(RemoteConnectionBanner(model: model, directory: directory)),
                              tabs: tabStrip, selectedTitle: shownTaskID.flatMap { model.task($0.uuidString)?.title })
    }

    // MARK: Tabs

    /// The window's tabs in the title bar once there are two or more, drawn by the local window's strip.
    private var tabStrip: TitleBarTabs? {
        guard shell.tabs.count > 1 else { return nil }
        let mirror = model.sidebar
        return TitleBarTabs(
            tabs: WindowTabProjection.tabs(shell.tabs, sessions: mirror.sessions, splits: [], details: mirror.details),
            selection: windowSelection, onSelect: activate, onClose: closeTab, onCloseOthers: closeOtherTabs,
            onNewTab: newTab, onOpenTask: { id, before in openInNewTab(.session(id), before: before) })
    }

    private func newTab() { openInNewTab(.home, before: nil) }

    /// Opens `item` in a tab of its own, before `before` or after the shown one, and shows it.
    private func openInNewTab(_ item: WindowItem, before: WindowItem?) {
        if shell.tabs.isEmpty { shell.tabs = [windowSelection] }
        shell.tabs.removeAll { $0 == item && $0 != windowSelection }
        if !shell.tabs.contains(item) {
            let index = before.flatMap { shell.tabs.firstIndex(of: $0) }
                ?? shell.tabs.firstIndex(of: windowSelection).map { $0 + 1 } ?? shell.tabs.endIndex
            shell.tabs.insert(item, at: index)
        }
        activate(item)
    }

    private func closeTab(_ item: WindowItem) {
        guard shell.tabs.count > 1, let index = shell.tabs.firstIndex(of: item) else { return }
        shell.tabs.remove(at: index)
        shell.closedTabs.append(item)
        if item == windowSelection { activate(shell.tabs[min(index, shell.tabs.count - 1)]) }
        if shell.tabs.count == 1 { shell.tabs = [] }
    }

    private func closeOtherTabs(_ item: WindowItem) {
        shell.closedTabs += shell.tabs.filter { $0 != item }
        shell.tabs = []
        activate(item)
    }

    private func selectTab(by offset: Int) {
        guard let index = shell.tabs.firstIndex(of: windowSelection), !shell.tabs.isEmpty else { return }
        activate(shell.tabs[(index + offset + shell.tabs.count) % shell.tabs.count])
    }

    /// The File and Window menus' tab commands, and ⌃1–⌃9 for the pinned rows, as the local window offers them.
    private var splitCommands: YardletSplitCommandSet {
        var commands = YardletSplitCommandSet()
        commands.selection = windowSelection
        commands.pinnedRows = sidebarLayout(model.sidebar).rows.filter(\.isPinned).prefix(9).compactMap { row in
            guard case let .session(session) = row.content else { return nil }
            return PinnedRowMenuItem(id: row.id, title: session.title)
        }
        commands.activate = activate
        commands.tabs.canCloseTab = shell.tabs.count > 1
        commands.tabs.canReopenClosedTab = !shell.closedTabs.isEmpty
        commands.tabs.newTab = newTab
        commands.tabs.closeTab = { closeTab(windowSelection) }
        commands.tabs.selectNextTab = { selectTab(by: 1) }
        commands.tabs.selectPreviousTab = { selectTab(by: -1) }
        commands.tabs.reopenClosedTab = {
            guard let item = shell.closedTabs.popLast() else { return }
            openInNewTab(item, before: nil)
        }
        return commands
    }

    // MARK: Actions

    /// What the window shows, as the local window's selection: the host's task, or the home for the rest.
    private var windowSelection: WindowItem {
        if case let .task(id) = model.selection, let uuid = UUID(uuidString: id) { return .session(uuid) }
        return .home
    }

    /// The host's task the window shows.
    private var shownTaskID: UUID? {
        if case let .session(id) = windowSelection { return id }
        return nil
    }

    private func activate(_ item: WindowItem) {
        switch item {
        case let .session(id): model.select(.task(id.uuidString))
        case .home: showNewTask()
        case .split: break
        }
    }

    private func showNewTask() {
        guard model.newTask != nil else { return }
        model.select(.newTask)
    }

    /// New task in a project, from its row: the new task screen with the project chosen.
    private func showNewTaskInProject(_ projectID: String?) {
        drafts.newTaskProjectID = projectID
        showNewTask()
    }

    private func showSchedules() {
        model.showsSchedules = true
        model.schedules.load()
    }

    private func toggleSidebar() {
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) { shell.isSidebarVisible.toggle() }
    }

    /// Turns the activity view on, keeping where its tasks are listed while it stays on, or off.
    private func toggleActivity() {
        model.showsSchedules = false
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            if shell.isShowingActivity {
                shell.isShowingActivity = false
                shell.activityPlaces = [:]
            } else {
                let mirror = model.sidebar
                shell.activityPlaces = TaskAttentionProjection.places(of: mirror.sessions, details: mirror.details)
                shell.isShowingActivity = true
                shell.isSidebarVisible = true
            }
        }
    }

    /// The Task and View menus' commands for this window: what they act on read from the host's lists as the local
    /// window reads its own (`TaskCommandTargets`), carried out through the host. Actions an older host does not
    /// advertise stay dimmed; the panels are the host's.
    private var taskCommands: YardletTaskCommandSet {
        let mirror = model.sidebar
        let layout = sidebarLayout(mirror)
        let activity = activity(mirror)
        let shown = shownTaskID.flatMap { id in mirror.sessions.first { $0.id == id } }
        var targets = TaskCommandTargets.make(
            layout: activity?.layout ?? layout, selection: activity?.selection ?? windowSelection, shownSession: shown,
            sidebarSessions: mirror.sessions, splits: [], details: mirror.details)
        if !model.taskActions { targets.markUnread = nil }
        var commands = YardletTaskCommandSet()
        commands.targets = targets
        commands.isSidebarVisible = shell.isSidebarVisible
        commands.activate = activate
        commands.toggleSidebar = toggleSidebar
        commands.toggleActivity = toggleActivity
        commands.togglePinned = { target in
            if case let .session(id, isPinned) = target { model.send(.setPinned(taskID: id.uuidString, pinned: !isPinned)) }
        }
        commands.archive = { id in model.send(.archiveTask(taskID: id.uuidString)) }
        commands.shownTaskID = shownTaskID
        commands.toggleSessionRail = { shell.showsRail.toggle() }
        commands.markUnread = { id in model.send(.taskAction(taskID: id.uuidString, action: .init(.markUnread))) }
        commands.showArchivedTasks = model.taskActions ? { model.showsArchive = true } : nil
        if model.newTask != nil { commands.newTask = { showNewTask() } }
        return commands
    }
}

/// What one window of a host keeps for itself, as the local window keeps its own: whether the sidebar shows and how
/// wide, the search, which projects are collapsed (only while the window is open), the activity view and the session
/// rail.
@MainActor
@Observable
final class RemoteHostShell {
    var isSidebarVisible = true
    let sidebarWidth = SidebarWidthState()
    var searchText = ""
    var archivedSearchText = ""
    let disclosure = SidebarDisclosureStore(defaults: nil)
    var isShowingActivity = false
    var activityPlaces: [UUID: TaskAttentionPlace] = [:]
    var showsRail = true
    /// Each task's side panel as the local task keeps its own (the tab shown, the tabs open), the panel's width, and each
    /// task's Review choices.
    var panels: [String: TaskSurfaceNavigationProjection.PanelState] = [:]
    var workspaceLayout = TaskWorkspacePreferences()
    var reviews: [String: DiffReviewPreferences] = [:]
    /// The rail's folded cards and the order the person gave them, as the local rail keeps them.
    var railFolds = SessionRailFolds()
    let railPreferences = SessionRailPreferenceStore()
    /// The sidebar's project actions are the host's (`TaskSidebar.managesProjects`); this store only stands in for them.
    let projects = ProjectStore()
    /// The window's tabs once it has two or more, as the local window's: what each shows, the shown one following what
    /// the window shows. Empty while there is one.
    var tabs: [WindowItem] = []
    /// Closed tabs, the latest last, for Reopen Closed Tab.
    var closedTabs: [WindowItem] = []

    /// The shown tab now shows `shown`, unless another tab already does.
    func follow(_ shown: WindowItem, from old: WindowItem) {
        guard !tabs.isEmpty, !tabs.contains(shown), let index = tabs.firstIndex(of: old) else { return }
        tabs[index] = shown
    }
}

/// What a detail's title bar row needs from the window: the sidebar part it starts with while the sidebar is hidden,
/// and the connection's line under it.
struct RemoteTitleBarContext {
    var isSidebarVisible: Bool
    var toggleSidebar: () -> Void
    var newTask: () -> Void
    var banner: AnyView
    /// The window's tabs, once there are two or more.
    var tabs: TitleBarTabs?
    /// The shown task's title, which its tab holds; nil for the new task.
    var selectedTitle: String?
}

/// The row in the window's title bar over the detail, as the local window's: with the sidebar hidden, the bar's sidebar
/// part (Show sidebar, New task) first, then what the detail names, with a drag region where it leaves room.
struct RemoteTitleBar<Content: View>: View {
    let context: RemoteTitleBarContext
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            if !context.isSidebarVisible {
                TitleBarSidebarPart(isSidebarVisible: false, width: TitleBarSidebarPart.collapsedWidth,
                                    onToggleSidebar: context.toggleSidebar, onNewTask: context.newTask)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
            }
            HStack(spacing: 8) {
                if let tabs = context.tabs {
                    WindowTabStrip(tabs: tabs.tabs, selection: tabs.selection, onSelect: tabs.onSelect,
                                   onClose: tabs.onClose, onCloseOthers: tabs.onCloseOthers, onNewTab: tabs.onNewTab,
                                   onOpenTask: tabs.onOpenTask, selectedTitle: {
                                       Text(context.selectedTitle ?? L10n.string("New task"))
                                           .font(.system(size: 12.5, weight: .medium))
                                           .lineLimit(1)
                                           .allowsHitTesting(false)
                                   })
                        .layoutPriority(1)
                    WindowDragRegion().frame(minWidth: 24, maxWidth: .infinity)
                } else {
                    content
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: ParityTheme.titleBarHeight)
    }
}

/// Tells the host whether the person is using its window: in front, with input in the last two minutes. The
/// host holds its phone pushes meanwhile (docs/REMOTE_PROTOCOL.md §18), as Claude Code's remote control does not
/// push to a phone while the person watches the terminal.
private struct RemotePresence: ViewModifier {
    let model: RemoteHostModel
    @Environment(\.controlActiveState) private var activeState

    static let idleLimit: Double = 120
    static let checkInterval: Duration = .seconds(30)

    func body(content: Content) -> some View {
        content
            .task(id: activeState == .key) {
                while !Task.isCancelled {
                    model.setPresence(activeState == .key && UserIdleTime.seconds < Self.idleLimit)
                    try? await Task.sleep(for: Self.checkInterval)
                }
            }
            .onDisappear { model.setPresence(false) }
    }
}

extension RemoteHostView {
    /// The detail while the host's scheduled tasks are listed and none is chosen.
    var schedulePlaceholder: some View {
        ScheduledTaskEmptyDetail(hasSchedules: model.schedules.list?.isEmpty == false,
                                 actions: model.schedules.actions)
    }

}

/// Each task's unsent words, the message it edits, its find and where the person was reading, kept on this Mac (a
/// host's own drafts stay there). The words outlast the window in the host's cache folder (`drafts.json`, 0600),
/// which goes with the host; the rest lasts while the window is open, as the local window keeps it.
@MainActor
@Observable
final class RemoteComposerDrafts {
    @ObservationIgnored private var drafts: [String: TaskComposerDraft] = [:]
    @ObservationIgnored private var finds: [String: ConversationFindModel] = [:]
    @ObservationIgnored private var readings: [String: TranscriptReadingPosition] = [:]
    @ObservationIgnored private var renders: [String: ConversationRenderState] = [:]
    /// Where the words are kept: the host's cache folder, nil where nothing is kept (tests).
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var savedWords: [String: String] = [:]
    private static let newTaskKey = "new-task"
    @ObservationIgnored let newTask = TaskComposerDraft()
    var edits: [String: RemoteMessageEdit] = [:]
    /// The project New task in a project chose, for the new task screen to start in.
    var newTaskProjectID: String?

    func draft(for taskID: String) -> TaskComposerDraft {
        if let draft = drafts[taskID] { return draft }
        let draft = TaskComposerDraft()
        drafts[taskID] = draft
        return draft
    }

    /// The task's find, kept while the window is open as the local task keeps its own.
    func find(for taskID: String) -> ConversationFindModel {
        if let find = finds[taskID] { return find }
        let find = ConversationFindModel()
        finds[taskID] = find
        return find
    }

    /// Where the person was reading the task's conversation, so going back to it comes back there.
    func readingPosition(for taskID: String) -> TranscriptReadingPosition {
        if let reading = readings[taskID] { return reading }
        let reading = TranscriptReadingPosition()
        readings[taskID] = reading
        return reading
    }

    /// The task's drawn conversation, kept so going back to it does not lay it out again.
    func renderState(for taskID: String) -> ConversationRenderState {
        if let render = renders[taskID] { return render }
        let render = ConversationRenderState()
        renders[taskID] = render
        return render
    }

    /// Reads the words kept in `folder`, once, into the drafts that are still empty.
    func restore(from folder: URL?) {
        guard file == nil, let folder else { return }
        file = folder.appending(path: "drafts.json")
        guard let data = try? Data(contentsOf: file!),
              let words = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        savedWords = words
        for (key, text) in words {
            let draft = key == Self.newTaskKey ? newTask : draft(for: key)
            if draft.text.isEmpty { draft.text = text }
        }
    }

    /// Keeps the drafts' words, when they changed since they were last kept.
    func save() {
        guard let file else { return }
        var words: [String: String] = [:]
        for (key, draft) in drafts where !draft.text.isEmpty { words[key] = draft.text }
        if !newTask.text.isEmpty { words[Self.newTaskKey] = newTask.text }
        guard words != savedWords else { return }
        savedWords = words
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        if !manager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let data = try? JSONEncoder().encode(words) else { return }
        manager.createFile(atPath: file.path(percentEncoded: false), contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// Keeps the shown draft's words a moment after the person stops typing, without the window drawing again for each key.
private struct RemoteDraftAutosave: View {
    @Bindable var draft: TaskComposerDraft
    let drafts: RemoteComposerDrafts

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: draft.text) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                drafts.save()
            }
    }
}

// MARK: - Connection

enum RemoteConnectionText {
    /// The window's subtitle: how the host is reached now.
    static func line(_ connection: RemoteHostModel.Connection) -> String {
        switch connection {
        case let .connected(.direct(address)):
            if isTailscale(address) { return L10n.string("Connected over Tailscale") }
            return L10n.string("Connected on the same network")
        case .connected(.relay): return L10n.string("Connected through the Yardlet server")
        case .connecting: return L10n.string("Connecting…")
        case .unreachable: return L10n.string("Reconnecting…")
        case .removed: return L10n.string("Not paired")
        case .stopped: return ""
        }
    }

    /// Tailscale's addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) and MagicDNS names.
    static func isTailscale(_ address: String) -> Bool {
        let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" })
            : String(address.split(separator: ":").first ?? "")
        if host.hasSuffix(".ts.net") || host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// One line above the conversation while the host cannot be reached, closed its connection, or removed
/// this Mac. What was last read stays below it; sending waits for the connection.
private struct RemoteConnectionBanner: View {
    let model: RemoteHostModel
    let directory: RemoteHostDirectory

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                Image(systemName: model.connection == .removed ? "xmark.octagon" : "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.connection == .removed {
                    Button(L10n.string("Remove from This Mac")) {
                        Task { await directory.forget(model.id) }
                    }
                    .controlSize(.small)
                } else {
                    Button(L10n.string("Try Again")) { model.reconnectNow() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var text: String? {
        switch model.connection {
        case .unreachable:
            switch model.closingReason {
            case "disabled": return L10n.format("%@ turned off remote connections.", model.name)
            case "quitting": return L10n.format("Yardlet on %@ quit.", model.name)
            default: return L10n.format("Can't reach %@. It may be off or asleep.", model.name)
            }
        case .removed:
            return L10n.format("%@ removed this Mac. To connect again, pair with a new link from its Settings › Remote.", model.name)
        case .connecting, .connected, .stopped:
            return nil
        }
    }
}

// MARK: - The host

/// The sidebar's last row, where the local window keeps its account button: the host's name and how it is reached, and
/// its menu (connect again, the paired Macs, and removing the host from this Mac).
private struct RemoteHostFooter: View {
    let model: RemoteHostModel
    let directory: RemoteHostDirectory
    @State private var isHovering = false
    @State private var confirmsRemoval = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Menu {
            if !model.isConnected {
                Button(L10n.string("Try Again")) { model.reconnectNow() }
            }
            Button(L10n.string("Connect to Mac…")) { openWindow(id: RemoteConnectWindow.sceneID) }
            Button(L10n.string("Archived tasks")) { model.showsArchive = true }.disabled(!model.taskActions)
            Divider()
            Button(L10n.string("Remove from This Mac"), role: .destructive) { confirmsRemoval = true }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.gutterWidth)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.name)
                        .font(.system(size: 13 * interfaceScale))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                        .lineLimit(1)
                    let line = RemoteConnectionText.line(model.connection)
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 11 * interfaceScale))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9 * interfaceScale, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.trailing, 10)
            .frame(height: 36 * interfaceScale)
            .contentShape(Rectangle())
            .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.format("%@, %@", model.name, RemoteConnectionText.line(model.connection)))
        .confirmationDialog(L10n.format("Remove %@ from this Mac?", model.name), isPresented: $confirmsRemoval) {
            Button(L10n.string("Remove from This Mac"), role: .destructive) { Task { await directory.forget(model.id) } }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.format("To connect again, pair with a new link from %@'s Settings › Remote.", model.name))
        }
    }
}


// MARK: - A task

/// A task of the host: its conversation in the app's own timeline, with the plan limit's actions on its card,
/// the queue's chips, and the composer; beside it, as the local session rail, the task's outputs when the host
/// serves its files (§15.22), and where the Mac's own window has the task's side panel, its browser (§15.25) while
/// it is open. Suggested tasks' chips act through the host (§15.9), and a file a link names or an output is read
/// from the host and opened here (`RemoteHostFiles`).
struct RemoteTaskView: View {
    let model: RemoteHostModel
    let conversation: RemoteConversationModel
    let draft: TaskComposerDraft
    /// A turn's message being edited in the composer (§15.23).
    @Binding var editing: RemoteMessageEdit?
    let titleBar: RemoteTitleBarContext
    /// Find in the conversation (⌘F), the task's own as the local task's is.
    let find: ConversationFindModel
    /// Where the person was reading and the drawn conversation, kept while the window is open.
    let readingPosition: TranscriptReadingPosition
    let renderState: ConversationRenderState
    /// The rail is shown, as the local rail is unless the person hid it; it draws only where it fits.
    @Binding var showsRail: Bool
    @Binding var railFolds: SessionRailFolds
    let railPreferences: SessionRailPreferenceStore
    /// The task's side panel, the panel's width and the task's Review choices, kept by the window.
    @Binding var panels: TaskSurfaceNavigationProjection.PanelState
    @Binding var layout: TaskWorkspacePreferences
    @Binding var review: DiffReviewPreferences
    /// An answer that leaves a rule behind, asked about once more before it goes.
    @State private var standingAnswer: (requestID: String, action: PermissionRequestAction)?
    @AppStorage(TerminalLocation.key) private var terminalLocation = TerminalLocation.bottom.rawValue
    @State private var width: CGFloat = 0
    /// A file read from the host, shown in Quick Look.
    @State private var preview: URL?
    @State private var changesSelectionID = UUID()
    @State private var selectedSubtask: HarnessActivity?
    @State private var stoppingSubtasks: Set<String> = []
    @State private var subtaskErrors: [String: String] = [:]
    @State private var subtaskReading = TranscriptReadingPosition()
    @State private var subtaskReturnSurface: String?
    @State private var stopSubtask: HarnessActivity?

    private var task: RemoteTask? { model.task(conversation.taskID) }

    /// The task's settings as the composer's bottom row reads them, from a host that sent them.
    private var settingsOptions: ComposerSessionOptions? {
        model.railComposerOptions(conversation.taskID)
    }

    /// The project the task is listed under, or Chats.
    private var projectName: String {
        guard let projectID = task?.projectId else { return L10n.string("Chats") }
        return model.projects.first { $0.id == projectID && $0.kind != .chats }?.name ?? L10n.string("Chats")
    }

    private var outputs: [RemoteOutput] { model.offersTaskFiles ? model.files.outputs[conversation.taskID] ?? [] : [] }

    private var showsBrowser: Bool { model.browser.taskID == conversation.taskID }

    /// The conversation as the host draws it, but for the handoff whose tab the browser panel shows: that one is the
    /// panel's bar alone, as on the Mac, where a handed tab's request is its panel's bar and no card. With the panel
    /// closed, the card's Show Tab opens it.
    private var presentation: ConversationPresentation {
        guard showsBrowser, let handed = model.browser.watchedTab?.requestId else { return conversation.presentation }
        return conversation.presentation.withoutRequest(handed)
    }

    var body: some View {
        // The local task's layout: the conversation, the rail beside it, and the side panel, whose tab strip shares the
        // title bar's row.
        TaskWorkspaceLayout(
            showsTrailing: panels.trailingSurfaceID != nil, showsTerminal: panels.isTerminalPresented && model.offersTerminals,
            preferences: $layout,
            wantsRail: showsRail && railSession != nil,
            onReturnToChat: closeSidePanel, onCloseTrailing: closeSidePanel, onCloseTerminal: closeTerminal,
            chat: {
                VStack(spacing: 0) {
                    titleBar.banner
                    conversationColumn
                }
            },
            rail: { rail },
            trailing: { sidePanel.environment(\.workSurfaceNavigation, sidePanelNavigation) },
            bottom: { terminal(inSidePanel: false) })
        .environment(\.taskAreaHeader, TaskAreaHeader(height: ParityTheme.titleBarHeight, isTitleBar: true,
                                                      content: AnyView(RemoteTitleBar(context: titleBar) { header })))
        // The browser's tab follows the host's watch, also as the view appears: a handoff's Show Tab or a new tab
        // shows it in the panel.
        .onChange(of: watchedSurfaceID, initial: true) { _, watched in
            if let watched, panels.trailingSurfaceID != watched { showSidePanelTab(watched) }
        }
        // A browser tab the host no longer lists has closed there: the panel forgets it and, where it showed it, goes to
        // the tab shown before it.
        .onChange(of: browserTabIDs) { _, listed in
            let gone = panels.trailingTabs.filter { Self.isBrowserTab($0) && !listed.contains($0) }
            if !gone.isEmpty { panels = TaskSurfaceNavigationProjection.closingTrailingTabs(gone, in: panels) }
        }
        // Leaving the browser's tab ends the watch, which the host's frames follow.
        .onChange(of: panels.trailingSurfaceID) { old, new in
            if let old, Self.isBrowserTab(old), new.map(Self.isBrowserTab) != true, showsBrowser { model.browser.hide() }
        }
        .confirmationDialog(L10n.string("Stop task"), isPresented: Binding(
            get: { stopSubtask != nil }, set: { if !$0 { stopSubtask = nil } })) {
            Button(L10n.string("Stop task"), role: .destructive) {
                if let activity = stopSubtask { requestSubtaskStop(activity) }; stopSubtask = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { stopSubtask = nil }
        }
        .focusedSceneValue(\.yardletConversationFind, find)
        .environment(\.taskSuggestionActions, suggestionActions)
        // The host's files: named here, and opened once read from the host where it serves them.
        .environment(\.transcriptOpensLocalFiles, false)
        .environment(\.openTaskFileChanges, fileChangesAction)
        .transformEnvironment(\.conversationLinkPlaces) { $0.fileElsewhere = fileElsewhere }
        .environment(\.openURL, OpenURLAction(handler: openLink))
        .quickLookPreview($preview)
        // What the task made, read again as it settles.
        .task(id: outputsMoment) {
            if model.offersTaskFiles { model.files.loadOutputs(conversation.taskID) }
        }
    }

    /// Where a file link of the host's opens: read from the host first, where it serves files.
    private var fileElsewhere: (@MainActor (URL) -> Void)? {
        guard model.offersTaskFiles else { return nil }
        return { url in open(url, .viewer) }
    }

    // MARK: Rail and side panel

    /// The host's task as the sidebar reads it, for the rail.
    private var railSession: SessionRecord? {
        model.sidebar.sessions.first { $0.id.uuidString == conversation.taskID }
    }

    @ViewBuilder
    private var rail: some View {
        if let session = railSession {
            RemoteTaskRail(
                session: session, projectName: projectName, options: settingsOptions, outputs: outputs,
                hostName: model.name, facts: model.taskRailFacts[conversation.taskID],
                hostActions: model.railActions(conversation.taskID, openChanges: { openSidePanel(TaskSurface.diff.rawValue) },
                    draftFix: { text in
                        let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.text = typed.isEmpty ? text : draft.text + "\n\n" + text
                    }),
                preferences: railPreferences, folds: $railFolds,
                choose: { [model, taskID = conversation.taskID] in model.chooseTaskSetting(taskID, $0) },
                prepareSettings: { [model, taskID = conversation.taskID] in await model.readTaskSettings(taskID, prepare: true) },
                open: { open($0, .viewer) }, openInItsApp: { open($0, .itsApp) }, revealInFinder: { open($0, .finder) })
        }
    }

    /// The side panel's tab, as the local task's: the launcher, Review, Files or the browser, each served by the host.
    @ViewBuilder
    private var sidePanel: some View {
        switch panels.trailingSurfaceID {
        case TaskSurfaceNavigationProjection.launcherID?:
            SidePanelLauncher(workspaceURL: nil, choices: sidePanelChoices, tasks: { [] }, onOpen: openSidePanel,
                              onClose: { closeSidePanelTab(TaskSurfaceNavigationProjection.launcherID) })
        case TaskSurface.diff.rawValue?:
            RemoteReviewPane(model: model, taskID: conversation.taskID, review: $review,
                             onClose: { closeSidePanelTab(TaskSurface.diff.rawValue) })
        case "subtask"?:
            if let activity = selectedSubtask, let session = railSession {
                HarnessSubtaskPane(activity: activity, session: session, readingPosition: subtaskReading,
                    actions: actions.readOnlyChild, load: { HarnessSubtaskTranscript(entries: [], isTruncated: false) },
                    onClose: { panels.trailingSurfaceID = subtaskReturnSurface; selectedSubtask = nil },
                    loadPresented: { try await model.readSubtask(taskID: conversation.taskID, activityID: activity.id) },
                    hostWorkspace: true)
                    .id(activity.id)
            }
        case "files"?:
            RemoteFilesPane(model: model, taskID: conversation.taskID, onClose: { closeSidePanelTab("files") })
                .id(conversation.taskID)
        case let id? where Self.isBrowserTab(id):
            RemoteBrowserPanel(model: model)
                .task(id: id) { if model.browser.tabID.map({ "browser:" + $0 }) != id { selectBrowserTab(id) } }
        case TaskSurfaceNavigationProjection.terminalID? where model.offersTerminals:
            terminal(inSidePanel: true)
        default:
            EmptyView()
        }
    }

    /// The host's browser tabs of the task, as the strip lists them (`RemoteBrowserModel.surfaceTabs`).
    private var browserTabs: [WorkSurfaceTab] { model.browser.surfaceTabs(for: conversation.taskID) }
    private var browserTabIDs: [String] { browserTabs.map(\.id) }

    /// The browser tab the host watches for this task now, by its strip ID.
    private var watchedSurfaceID: String? {
        guard showsBrowser, let tabID = model.browser.tabID else { return nil }
        return "browser:" + tabID
    }

    private static func isBrowserTab(_ id: String) -> Bool { id.hasPrefix("browser:") }

    /// The launcher's and the strip's + choices, as the local task's, each available where the host serves it. The
    /// terminal and a side chat are not served from another Mac yet.
    private var sidePanelChoices: [WorkSurfaceTab] {
        TaskSidePanelTabs.choices(canOpenSideChat: false, offersReview: model.offersReview).map { choice in
            var choice = choice
            switch choice.id {
            case TaskSurface.diff.rawValue: choice.isAvailable = model.offersReview
            case "files": choice.isAvailable = model.offersWorkspaceFiles
            // A new tab is opened on the host, which a host that only shows its tabs does not take.
            case TaskSurface.browser.rawValue: choice.isAvailable = model.offersBrowser && model.browser.canControlTabs
            case TaskSurface.terminal.rawValue: choice.isAvailable = model.offersTerminals
            default: break
            }
            return choice
        }
    }

    /// The panels the title bar's buttons cannot show here.
    private var unavailableSurfaces: Set<TaskSurface> {
        var surfaces: Set<TaskSurface> = []
        if !model.offersTerminals { surfaces.insert(.terminal) }
        if !model.offersReview { surfaces.insert(.diff) }
        return surfaces
    }

    /// The task's shell on the host, below the conversation or in the side panel as Settings place the terminal: the
    /// local terminal panel over the host's shell, its links opened as the conversation's are, a selection attached to
    /// the composer as the local terminal attaches it.
    private func terminal(inSidePanel: Bool) -> some View {
        RemoteTerminalPane(
            model: model, taskID: conversation.taskID,
            onAttachSelection: { [draft] selection, title in TerminalSelectionText.attach(selection, from: title, to: draft) },
            onOpenLink: { url in _ = openLink(url) },
            isInSidePanel: inSidePanel,
            onClose: closeTerminal)
            .id(conversation.taskID)
    }

    private func closeTerminal() {
        panels = TaskSurfaceNavigationProjection.hidingTerminal(panels)
    }

    /// The strip as the local task's: the panel's own tabs, then the host's browser tabs, which come from the host's
    /// list rather than the panel's state, so a tab the host has not closed (a page that asked before leaving, a
    /// refused close) stays.
    private var sidePanelNavigation: WorkSurfaceNavigation {
        WorkSurfaceNavigation(
            tabs: panels.trailingTabs.filter { !Self.isBrowserTab($0) }.compactMap { TaskSidePanelTabs.tab($0, selectedFilePath: nil) }
                + browserTabs,
            activeID: panels.trailingSurfaceID,
            choices: sidePanelChoices,
            select: { id in Self.isBrowserTab(id) ? selectBrowserTab(id) : showSidePanelTab(id) },
            open: { id in openSidePanel(id) },
            closeTab: { id in closeSidePanelTab(id) },
            closeTabs: { ids in
                model.browser.closeSurfaceTabs(ids.filter(Self.isBrowserTab), taskID: conversation.taskID)
                for id in ids where !Self.isBrowserTab(id) { closeSidePanelTab(id) }
            },
            closePanel: { closeSidePanel() })
    }

    private var fileChangesAction: (@MainActor @Sendable (String) -> Void)? {
        guard model.offersReview else { return nil }
        return { path in showChanges(path) }
    }

    private func showChanges(_ path: String) {
        guard model.offersReview, RemoteConversationFileLink.url(path) != nil else { return }
        let ticket = UUID()
        changesSelectionID = ticket
        // Provider turn diffs are task-relative; git scopes use repository-relative paths.
        if review.scope == .lastTurn {
            review.selectedPath = path
            showSidePanelTab(TaskSurface.diff.rawValue)
            return
        }
        let previousReview = review
        let previousSurface = panels.trailingSurfaceID
        Task {
            let target = try? await RemoteReviewFileTarget.read(path: path,
                reader: RemoteGitDiffReading(model: model, taskID: conversation.taskID))
            // Do not overwrite a file, scope or panel the person picked while metadata was read.
            guard changesSelectionID == ticket, review == previousReview,
                  panels.trailingSurfaceID == previousSurface else { return }
            if let target { review.repositoryPath = target.repository }
            review.selectedPath = target?.path ?? path
            showSidePanelTab(TaskSurface.diff.rawValue)
        }
    }

    private func openSidePanel(_ id: String) {
        guard sidePanelChoices.first(where: { $0.id == id })?.isAvailable != false
                || id == TaskSurfaceNavigationProjection.launcherID else { return }
        if id == TaskSurface.terminal.rawValue {
            // The terminal opens where Settings put it; a launcher it was chosen from has done its job.
            if panels.trailingSurfaceID == TaskSurfaceNavigationProjection.launcherID {
                panels = TaskSurfaceNavigationProjection.closingTrailingTab(TaskSurfaceNavigationProjection.launcherID, in: panels)
            }
            panels = TaskSurfaceNavigationProjection.showingTerminal(in: panels,
                                                                     at: TerminalLocation(rawValue: terminalLocation) ?? .bottom)
            return
        }
        if id == TaskSurface.browser.rawValue {
            // A new tab on the host, which shows in the strip once the host lists it.
            if panels.trailingSurfaceID == TaskSurfaceNavigationProjection.launcherID {
                panels = TaskSurfaceNavigationProjection.closingTrailingTab(TaskSurfaceNavigationProjection.launcherID, in: panels)
            }
            model.browser.newSurfaceTab(taskID: conversation.taskID)
            return
        }
        showSidePanelTab(id)
    }

    /// A browser tab shown in the panel, watched on the host.
    private func selectBrowserTab(_ id: String) {
        model.browser.selectSurfaceTab(id, taskID: conversation.taskID)
        showSidePanelTab(id)
    }

    private func showSidePanelTab(_ id: String) {
        panels = TaskSurfaceNavigationProjection.showing(id, in: panels)
    }

    /// A browser tab is closed on the host and leaves the strip once the host's list does; the panel's own tabs close
    /// here.
    private func closeSidePanelTab(_ id: String) {
        if Self.isBrowserTab(id) {
            model.browser.closeSurfaceTab(id, taskID: conversation.taskID)
        } else {
            panels = TaskSurfaceNavigationProjection.closingTrailingTab(id, in: panels)
        }
    }

    private func closeSidePanel() {
        panels.trailingSurfaceID = nil
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            ConversationTimeline(source: .presented(presentation), readingPosition: readingPosition,
                                 actions: actions, isLoading: !conversation.isLoaded, diagnosticID: nil,
                                 renderState: renderState)
                .environment(\.conversationFind, find)
                .overlay(alignment: .topTrailing) {
                    ConversationFindBar(find: find)
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                }
            if let notices = task?.notices {
                RemoteTaskNoticeLines(notices: notices, cancelAccountMove: {
                    model.send(.cancelAccountMove(taskID: conversation.taskID))
                })
            }
            if let editing {
                ConversationEditBanner(canCancel: true) {
                    draft.text = editing.previousText
                    draft.attachments = editing.previousAttachments
                    self.editing = nil
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.commandError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let name = model.files.reading {
                    Text(L10n.format("Reading %@ from %@…", name, model.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RemoteComposer(model: model, taskID: conversation.taskID, draft: draft, queued: conversation.queued,
                               editing: $editing)
            }
            // Where the local composer sits under its conversation.
            .frame(maxWidth: ParityTheme.contentWidth)
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            L10n.string("Allow and save this rule?"),
            isPresented: Binding(get: { standingAnswer != nil }, set: { if !$0 { standingAnswer = nil } })
        ) {
            Button(standingAnswer?.action.label ?? "") {
                if let standingAnswer { respond(standingAnswer.requestID, .providerAction(standingAnswer.action)) }
                standingAnswer = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { standingAnswer = nil }
        } message: {
            Text(L10n.format("This answer stays in effect on %@ after this request.", model.name))
        }
    }

    /// The window owns returning keyboard work to the conversation; the host owns task mutations.
    private var headerActions: TaskHeaderActions {
        var actions = model.taskHeaderActions
        actions.onBackToConversation = { _ in panels = TaskSurfaceNavigationProjection.closingAllPanels(panels) }
        return actions
    }

    @ViewBuilder
    private var header: some View {
        if let session = model.sidebar.sessions.first(where: { $0.id.uuidString == conversation.taskID }) {
            TaskHeaderIdentity(session: session, actions: headerActions)
        }
        WindowDragRegion().frame(minWidth: 8, maxWidth: .infinity)
        TaskSurfaceControls(showsSessionRail: showsRail, onToggleSessionRail: { showsRail.toggle() }, panelState: $panels,
                            unavailableSurfaces: unavailableSurfaces)
    }

    private var actions: ConversationActions {
        var actions = ConversationActions()
        let nextTurnID = conversation.presentation.turns.last?.id
        actions.decide = { id, decision in respond(id, .decision(decision)) }
        actions.chooseOption = { id, action in
            if action.kind == RemoteTurnProjection.Route.standing {
                standingAnswer = (id, action)
            } else {
                respond(id, .providerAction(action))
            }
        }
        actions.answer = { id, answer in respond(id, .answer(answer)) }
        actions.respondToCodexRequest = { id, response in respond(id, .codex(response)) }
        actions.loadMoreCodexTurns = { [model, taskID = conversation.taskID] in model.loadOlder(taskID) }
        actions.loadLineDetail = { [model, taskID = conversation.taskID] itemID in model.loadDetail(taskID, itemID: itemID) }
        if model.taskControls {
            // A turn's edit and fork, as the host's turn offers them (§15.23).
            actions.editTurnMessage = { turnID, text in beginEdit(turnID: turnID, text: text) }
            actions.branch = { [model, taskID = conversation.taskID] point in
                if case let .turn(turnID) = point { model.fork(taskID, turnID: turnID) } else { model.fork(taskID, turnID: nil) }
            }
        }
        // A subagent's child thread is the host's task it runs in (§15.24).
        actions.openCodexSubagent = { [model] taskID in model.select(.task(taskID)) }
        if model.nextSteps, model.isConnected {
            actions.retryTurn = { turnID in model.send(.nextStep(taskID: conversation.taskID, turnID: turnID, action: .retry)) }
            if model.task(conversation.taskID)?.running != true, conversation.queued.isEmpty, editing == nil {
                actions.implementCodexPlan = { _ in sendNextStep(.implementPlan, turnID: nextTurnID) }
                actions.answerQuestion = { sendNextStep(.answer, turnID: nextTurnID, text: $0) }
            }
            actions.answerQuestionWhileWorking = { sendNextStep(.answerWhileWorking, turnID: nextTurnID, text: $0) }
        }
        if model.offersFileRewind, task?.harness == "claude-code", let session = railSession {
            actions.rewind = model.fileRewindActions(taskID: conversation.taskID, session: session)
        }
        if model.offersSubtasks {
            actions.subtaskControls = HarnessActivityActions(open: { activity in
                if panels.trailingSurfaceID != "subtask" { subtaskReturnSurface = panels.trailingSurfaceID }
                selectedSubtask = activity; panels.trailingSurfaceID = "subtask"
            }, stop: { activity in stopSubtask = activity },
                isStopping: { stoppingSubtasks.contains($0) }, error: { subtaskErrors[$0] })
        }
        actions.providerNotices = limitActions
        return actions
    }

    /// What the latest limit card offers, as the host offers it (§15.17): continuing under another account that
    /// shares the task's history, and continuing once the limit resets.
    private var limitActions: TaskProviderNotices? {
        guard let limit = conversation.usageLimit else { return nil }
        let options = limit.options ?? []
        guard !options.isEmpty || model.bankedResets else { return nil }
        let taskID = conversation.taskID
        var notices = TaskProviderNotices()
        notices.canContinue = model.isConnected && model.task(taskID)?.running != true
        if model.nextSteps, options.contains("resumeAfterReset") {
            notices.continueAfterReset = { _ in
                model.send(.nextStep(taskID: taskID, turnID: limit.turnId, action: .resumeAfterReset))
            }
        }
        if model.bankedResets {
            notices.hostUsageReset = { [model] in await model.response(to: .usageReset(taskID: taskID)).usageReset }
            notices.useHostUsageReset = { [model] token in
                await model.response(to: .useUsageReset(taskID: taskID, token: token, confirmed: true)).usageReset
            }
        }
        // An armed continue is known by the reset it waits for, as on the host.
        if limit.autoContinue == true, let resetsAt = limit.resetsAt {
            notices.autoContinueResetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAt) / 1000)
        }
        notices.setAutoContinue = { [model] enabled, _ in model.send(.setAutoContinue(taskID: taskID, enabled: enabled)) }
        if options.contains("continueWithAccount") {
            notices.hostAccounts = { [model] in
                let response = await model.response(to: .limitAccounts(taskID: taskID))
                return (response.accounts ?? []).filter { $0.available == true }
                    .map { UsageLimitHostAccount(id: $0.id, name: $0.name, detail: $0.detail) }
            }
            notices.continueWithHostAccount = { [model] id in model.send(.continueWithAccount(taskID: taskID, accountID: id)) }
        }
        return notices
    }

    private func sendNextStep(_ action: RemoteNextStep, turnID: String?, text: String? = nil) {
        guard let turnID else { return }
        model.send(.nextStep(taskID: conversation.taskID, turnID: turnID, action: action, text: text))
    }

    private func requestSubtaskStop(_ activity: HarnessActivity) {
        guard stoppingSubtasks.insert(activity.id).inserted else { return }
        subtaskErrors[activity.id] = nil
        Task {
            let response = await model.response(to: .subtask(taskID: conversation.taskID, activityID: activity.id, stop: true))
            if !response.ok {
                stoppingSubtasks.remove(activity.id)
                subtaskErrors[activity.id] = RemoteHostModel.message(for: response.error, host: model.name)
            }
        }
    }

    private func respond(_ requestID: String, _ route: ConversationRequestRoute) {
        model.respond(taskID: conversation.taskID, requestID: requestID, route: route)
    }

    /// The chips' Start, Do it here and ✕, sent to the host (§15.9); what became of each is the host's.
    /// Options stays the host's: a suggestion starts with that Mac's choices.
    private var suggestionActions: TaskSuggestionActions {
        let taskID = conversation.taskID
        let model = model, conversation = conversation
        func act(_ id: String, _ action: RemoteSuggestionAction) {
            model.send(.actOnSuggestion(taskID: taskID, suggestionID: id, action: action))
        }
        return TaskSuggestionActions(
            resolution: { conversation.suggestions[$0].flatMap(RemoteSuggestionState.resolution) },
            progress: { id in conversation.suggestions[id].flatMap { RemoteSuggestionState.progress($0, host: model.name) } },
            start: { act($0.id, .start) },
            doHere: { act($0.id, .here) },
            optionsUnavailable: L10n.format("It starts with the choices set on %@.", model.name),
            dismiss: { act($0, .dismiss) },
            openTask: { model.select(.task($0.uuidString)) },
            canOpenTask: { model.task($0.uuidString) != nil })
    }

    /// A link in the conversation: a file is read from the host where it serves files, and never opened at
    /// the same path on this Mac; a task the host lists opens here; a web page on the host's own address (a server the
    /// task runs) in the host's browser, any other in this Mac's default browser.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "yardlet-remote-file" {
            guard let path = RemoteConversationFileLink.path(url), model.offersTaskFiles else { return .discarded }
            open(path: path, .viewer)
            return .handled
        }
        switch ConversationLinkKind(url) {
        case .file:
            guard model.offersTaskFiles else { return .discarded }
            open(url, .viewer)
            return .handled
        case let .task(.task(id)):
            guard model.task(id.uuidString) != nil else { return .discarded }
            model.select(.task(id.uuidString))
            return .handled
        case .task, .place:
            return .discarded
        case .web:
            return model.openHostBrowserLink(url, taskID: conversation.taskID) ? .handled : .systemAction
        case .other:
            return .systemAction
        }
    }

    private func open(_ url: URL, _ opening: RemoteFileOpening) {
        if url.scheme == "yardlet-remote-file" {
            guard let path = RemoteConversationFileLink.path(url) else { return }
            open(path: path, opening)
        } else {
            open(path: url.path(percentEncoded: false), opening)
        }
    }

    private func open(path: String, _ opening: RemoteFileOpening) {
        guard !path.isEmpty else { return }
        let taskID = conversation.taskID
        Task {
            switch await model.files.copy(taskID: taskID, path: path) {
            case let .success(copy):
                switch opening {
                case .viewer: preview = copy
                // A program is only shown: its own app would run it.
                case .itsApp where !FileElsewhereButtons.runs(copy): NSWorkspace.shared.open(copy)
                case .itsApp, .finder: NSWorkspace.shared.activateFileViewerSelecting([copy])
                }
            case let .failure(failure):
                model.commandError = RemoteFileOpening.message(failure, host: model.name)
            }
        }
    }

    /// When the outputs are read again: the task's state, and its last activity once it rests.
    private var outputsMoment: String {
        guard let task else { return "" }
        return "\(task.attention.rawValue)-\(task.running)-\(task.running ? 0 : task.lastActivityAt)"
    }

    /// The message goes into the composer to edit, as the local turn's Edit message puts it there; what the composer
    /// held waits to come back if the edit is cancelled.
    private func beginEdit(turnID: String, text: String) {
        let previous = editing.map { ($0.previousText, $0.previousAttachments) } ?? (draft.text, draft.attachments)
        editing = RemoteMessageEdit(turnID: turnID, previousText: previous.0, previousAttachments: previous.1)
        draft.text = text
        draft.attachments = []
        draft.notice = nil
    }
}
