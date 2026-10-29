import AppKit
import SwiftUI

/// Builds a task's surface in a body of its own. What the surface reads from the model — the task's
/// transcript, timeline, queue and provider state — is then observed by this view, not by
/// `MainWindow`: a task streaming on screen redraws its surface without re-evaluating the window
/// around it (the sidebar, the menu commands it publishes, and through them the menu bar and the
/// scene).
struct TaskObservationScope<Content: View>: View {
    let content: () -> Content

    var body: some View { content() }
}

private struct ProjectEditPresentation: Identifiable {
    let id: UUID
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var isSidebarVisible = true
    @State private var sidebarSection: ShellSection = .tasks
    /// This window's place in `AppModel.taskWindowIDs`: windows share one model, each says for itself
    /// whether it shows Tasks.
    @State private var windowID = UUID()
    @State private var personalAgents = PersonalAgentCenter(drafts: .live)
    @State private var personalAccountID = AccountChoice.nativeID(for: .codex)
    /// The width the person set by dragging the sidebar's line (`SidebarWidth`), kept across launches.
    /// Only the sidebar's column and the title bar read it, so a drag does not rebuild the window.
    @State private var sidebarWidth = SidebarWidthState()
    /// The task rows' hover card, drawn over the sidebar and the content beside it.
    @State private var sidebarHoverCard = SidebarHoverCardState()
    /// The shown task's place in the sidebar while the list is scrolled away from its top. The window
    /// is drawn again only when the hold changes the order, not each time the list crosses its top.
    @State private var sidebarOrderHold = SidebarOrderHold()
    @State private var isSidebarListAtTop = true
    @State private var searchText = ""
    /// The sidebar shows archived tasks in place of the task list until Back.
    @State private var isShowingArchivedTasks = false
    @State private var archivedSearchText = ""
    /// The sidebar shows the scheduled tasks, and the window the chosen one, until Back.
    @State private var schedulesWindow = ScheduledTasksWindowState()
    /// The sidebar shows the activity view (the Codex app's priority threads) in place of the
    /// task list until it is turned off.
    @State private var isShowingActivity = false
    /// Where each task the activity view has listed sits while the view stays open.
    @State private var activityPlaces: [UUID: TaskAttentionPlace] = [:]
    /// Collapsed projects and "Show more" in the sidebar.
    @State private var sidebarDisclosure = SidebarDisclosureStore()
    private var projects: ProjectStore { model.projects }
    private var newTaskDraft: NewTaskDraft { model.composerDrafts.home }
    @State private var sessionToRename: SessionRecord?
    @State private var sessionToDelete: SessionRecord?
    @State private var projectToEdit: UUID?
    @State private var projectToArchive: WorkspaceGroup?
    @State private var projectToRemove: WorkspaceGroup?
    @State private var renameTitle = ""
    @State private var taskRenamePresentationID = UUID()
    @State private var splitToRename: SplitGroup?
    @State private var splitToArchive: SplitGroup?
    @State private var splitRenameTitle = ""
    @State private var contentSize: CGSize = .zero
    /// A window tab, a split pane or a side panel's tab being dragged in the window.
    @State private var windowDrag = WindowDragState()
    /// The whole window's size, so a sheet such as Settings can be sized to fit inside it.
    @State private var windowSize: CGSize = .zero
    private struct ConnectionPresentation: Identifiable {
        let id = UUID()
        let tab: ConnectionCenterTab
        let harness: HarnessKind?
        let addsAccount: Bool
        let choice: AccountChoice?
    }
    @State private var connectionPresentation: ConnectionPresentation?
    private var isPresentingHarnesses: Bool { connectionPresentation != nil }
    /// The window's session rail switch and where each task's rail is (`SessionRailStorage` keeps the
    /// switch with the window).
    @State private var sessionRail = SessionRailWindowState()
    @State private var isPresentingSettings = false
    /// The connector directory opened from a task's rail or composer ("Add connectors"), over the
    /// window rather than inside Settings.
    @State private var connectorAddStart: ConnectorAddSheet.Start?
    /// The section and account filter the next Settings presentation opens on; General by default.
    @State private var settingsRoute: (section: SettingsSection, harness: HarnessKind?)?
    @State private var isPresentingCommandPalette = false
    @State private var isPresentingImport = false
    @State private var isPresentingOtherAppImport = false
    @State private var pendingCommand: CommandPaletteItem?
    @State private var shellFocusBookmark: WindowFocusBookmark?
    /// The new-task screen's keyboard handoff, which its panels share (`TaskWorkspaceStore.draft`).
    private var homeKeyboardFocus: TaskKeyboardFocus { model.taskWorkspaces.draft.keyboardFocus }
    /// The panels the title bar's buttons and the View menu's keys act on: the shown task's, or the
    /// new-task screen's.
    private var taskPanelState: Binding<TaskSurfaceNavigationProjection.PanelState> {
        guard let id = panelOwnerID else { return .constant(.init()) }
        let workspace = panelWorkspace(id)
        return Binding(get: { workspace.panels }, set: { workspace.setPanels($0) })
    }

    /// The workspace whose panels `id` names: a task's, or the new-task screen's.
    private func panelWorkspace(_ id: UUID) -> TaskWorkspaceState {
        id == TaskWorkspaceStore.draftID
            ? model.taskWorkspaces.draft
            : model.taskWorkspaces.state(for: id, initialSurface: model.initialTaskSurface)
    }
    @FocusState private var focusedTaskSurface: TaskSurface?
    /// The task whose harness settings sheet is open.
    @State private var harnessSettingsSession: SessionRecord?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openWindow) private var openWindow
    /// Yardlet › Install Update…, which the account menu also offers.
    @Environment(\.yardletInstallUpdate) private var installUpdate
    /// An update waiting for tasks to finish, which the account menu shows and cancels too.
    @Environment(\.yardletUpdateWait) private var updateWait
    /// Sparkle in a public build: the account menu's Check for Updates….
    @Environment(\.yardletSparkle) private var sparkle
    /// A staged build ready to install: the sidebar's "Restart to update".
    @Environment(\.yardletStagedUpdate) private var stagedUpdate
    /// The person on this Mac, read once for the account button.
    @State private var accountIdentity = SidebarAccountIdentity.current()

    /// What the personal agents are read through in place of the chosen account's Dots, for a rendered
    /// window; its drafts then stay in memory.
    private let personalAgentReader: (() -> any PersonalAgentClient)?

    init(model: AppModel, personalAgentReader: (() -> any PersonalAgentClient)? = nil) {
        self.model = model
        self.personalAgentReader = personalAgentReader
        if personalAgentReader != nil { _personalAgents = State(initialValue: PersonalAgentCenter()) }
    }

    private var visibleGroups: [WorkspaceGroup] {
        let groups = allVisibleGroups
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return groups }
        return TaskNavigationProjection.filteredGroups(
            in: groups,
            query: searchText,
            transcripts: model.transcriptBySessionID.dictionary,
            codexPresentation: model.codexPresentationBySessionID.dictionary,
            projectNames: projects.projectNames(for: groups)
        )
    }

    private var allVisibleGroups: [WorkspaceGroup] {
        projects.visibleGroups(sessions: listedSessions)
    }

    /// The tasks the sidebar lists under Chats: in a chat's folder that no project holds.
    private var allChats: [SessionRecord] {
        projects.chats(sessions: listedSessions)
    }

    /// The tasks as the task list orders them: the shown task where it was while the list is scrolled
    /// away from its top (`SidebarOrderHold`).
    private var listedSessions: [SessionRecord] {
        sidebarOrderHold.listing(model.store.sessions)
    }

    /// Holds the shown task's place from now, or lets it go with the list at its top.
    private func holdSidebarOrder() {
        guard !isSidebarListAtTop else {
            sidebarOrderHold.hold([], listing: model.store.sessions)
            return
        }
        let shown: [UUID]
        switch model.splits.selection {
        case let .session(id): shown = [id]
        case let .split(id): shown = model.splits.splits.first { $0.id == id }?.sessionIDs ?? []
        case .home: shown = []
        }
        let ids = Set(shown)
        sidebarOrderHold.hold(model.store.sessions.filter { ids.contains($0.id) }, listing: model.store.sessions)
    }

    private var visibleChats: [SessionRecord] {
        // Without a search the conversations are not read: reading them would make the window
        // observe every task's transcript and redraw whenever any task streams.
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return allChats }
        return TaskNavigationProjection.filteredSessions(
            allChats,
            query: searchText,
            transcripts: model.transcriptBySessionID.dictionary,
            codexPresentation: model.codexPresentationBySessionID.dictionary
        )
    }

    /// Every task the sidebar can list, whatever a search shows: what `⌥⌘A`, the Dock badge and the
    /// activity view look through.
    private var sidebarSessions: [SessionRecord] { model.sidebarSessions }

    /// The activity view's tasks in attention order, narrowed by the search as the task list is.
    private var activitySessions: [SessionRecord] {
        let listed = TaskAttentionProjection.activityList(
            in: sidebarSessions, details: model.taskAttentionDetails,
            shellBusy: model.shellBusySessionIDs, kept: activityPlaces)
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return listed }
        return TaskNavigationProjection.filteredSessions(
            listed, query: searchText,
            transcripts: model.transcriptBySessionID.dictionary,
            codexPresentation: model.codexPresentationBySessionID.dictionary
        )
    }

    private var sidebarActivity: SidebarActivity? {
        guard isShowingActivity else { return nil }
        return SidebarActivity(
            sessions: activitySessions,
            selectedSessionID: model.splits.selection == .home ? nil : model.store.selectedSessionID,
            subtitle: model.taskPlaceNames(),
            onMarkAllRead: markActivityRead
        )
    }

    /// Turns the activity view on, keeping the places its tasks are listed at, or off. Over the
    /// archived tasks it comes back on.
    private func toggleActivity() {
        sidebarSection = .tasks
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            if isShowingActivity, !isShowingArchivedTasks {
                isShowingActivity = false
                activityPlaces = [:]
            } else {
                activityPlaces = TaskAttentionProjection.places(
                    of: sidebarSessions, details: model.taskAttentionDetails, shellBusy: model.shellBusySessionIDs,
                    kept: isShowingActivity ? activityPlaces : [:])
                closeArchivedTasks()
                closeSchedules()
                isSidebarVisible = true
                isShowingActivity = true
            }
        }
    }

    /// "Mark all as read": every listed task with an unread result. They stay listed until the
    /// view is turned off, as opened ones do.
    private func markActivityRead() {
        let listed = activitySessions
        activityPlaces = TaskAttentionProjection.places(
            of: listed, details: model.taskAttentionDetails, shellBusy: model.shellBusySessionIDs, kept: activityPlaces)
        let unread = listed.filter(\.hasUnreadUpdate).map(\.id)
        Task { await model.store.markRead(ids: unread) }
    }

    /// A task opened while the activity view lists it keeps its place there once it is read.
    private func keepActivityPlace(of sessionID: UUID) {
        guard isShowingActivity, activityPlaces[sessionID] == nil,
              let session = activitySessions.first(where: { $0.id == sessionID }) else { return }
        activityPlaces = TaskAttentionProjection.places(
            of: [session], details: model.taskAttentionDetails, shellBusy: model.shellBusySessionIDs, kept: activityPlaces)
    }

    private func rememberShellFocus() {
        if shellFocusBookmark == nil {
            shellFocusBookmark = WindowFocusBookmark(window: NSApp.keyWindow)
        }
    }

    @State private var accountSwitchSession: SessionRecord?

    private func presentHarnesses() {
        presentSettings(.harnesses)
    }

    private func presentAccounts(_ harness: HarnessKind? = nil, add: Bool = false, connect: AccountChoice? = nil) {
        switch ConnectionEntryRoute.accounts(harness: harness, adds: add, connects: connect != nil) {
        case let .settings(section, harness):
            presentSettings(section, harness: harness)
        case .accountSheet:
            rememberShellFocus()
            connectionPresentation = ConnectionPresentation(tab: .accounts, harness: harness, addsAccount: add,
                choice: connect)
        }
    }

    private func presentSettings(_ section: SettingsSection = .general, harness: HarnessKind? = nil) {
        rememberShellFocus()
        settingsRoute = (section, harness)
        isPresentingSettings = true
    }

    private func presentConnectorDirectory() {
        rememberShellFocus()
        connectorAddStart = .directory
    }

    /// Every entry to a task's settings opens the one harness settings sheet (plan B6).
    private func presentHarnessSettings(_ session: SessionRecord) {
        rememberShellFocus()
        harnessSettingsSession = session
    }

    private func presentTaskRename(_ session: SessionRecord) {
        rememberShellFocus()
        taskRenamePresentationID = UUID()
        renameTitle = session.title
        sessionToRename = session
    }

    private func modalBinding(_ presented: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { presented.wrappedValue }, set: { value in
            if value { rememberShellFocus() }
            presented.wrappedValue = value
        })
    }

    private var hasPresentedModal: Bool {
        isPresentingSettings || isPresentingHarnesses || isPresentingCommandPalette
            || connectorAddStart != nil
            || isPresentingImport || isPresentingOtherAppImport
            || harnessSettingsSession != nil
            || projectToEdit != nil || hasManagementAlert
            || schedulesWindow.hasModal
    }

    private var hasManagementAlert: Bool {
        sessionToRename != nil || sessionToDelete != nil
            || projectToArchive != nil || projectToRemove != nil
            || splitToRename != nil || splitToArchive != nil
    }

    private func finishShellModal() {
        guard !hasPresentedModal, let bookmark = shellFocusBookmark else { return }
        // AppKit must finish disposing the sheet's field editor before restoring the parent.
        DispatchQueue.main.async {
            guard !hasPresentedModal, shellFocusBookmark === bookmark else { return }
            shellFocusBookmark = nil
            if !bookmark.restore() { focusCurrentContent() }
        }
    }

    private func restoreTaskModalFocus() {
        if shellFocusBookmark != nil { finishShellModal(); return }
        guard let id = model.store.selectedSessionID else { return }
        model.taskWorkspaces.state(for: id).keyboardFocus.returnFromModal()
    }

    private func finishCommandPalette() {
        let command = pendingCommand
        pendingCommand = nil
        command?.action()
        finishShellModal()
    }

    /// Adds a folder as a project (showing it again if it was hidden) and starts a task there.
    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("Add project")
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        let project = projects.ensureProject(forRoot: url)
        newTaskDraft.projectID = project.id
        newTaskDraft.workspaceURL = url
        showNewTask()
    }

    private func showNewTask() {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.showNewTask()
        homeKeyboardFocus.move(to: .chat)
    }

    // MARK: - Personal agents

    /// The sidebar's "Personal agents": the agents in the task list's place, the chosen one's conversation
    /// beside it. The tasks keep what they showed for the way back.
    private func showPersonalAgents() {
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            isSidebarVisible = true
            sidebarSection = .personalAgents
        }
    }

    private func closePersonalAgents() {
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) { sidebarSection = .tasks }
        focusCurrentContent()
    }

    // MARK: - Scheduled tasks

    /// The sidebar's "Scheduled tasks": the list in the task list's place, the chosen one beside it.
    private func showSchedules() {
        sidebarSection = .tasks
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            closeArchivedTasks()
            isShowingActivity = false
            activityPlaces = [:]
            isSidebarVisible = true
            if schedulesWindow.selection.flatMap(model.scheduledTasks.schedule(id:)) == nil {
                schedulesWindow.selection = model.scheduledTasks.schedules.first?.id
            }
            schedulesWindow.isShowing = true
        }
    }

    /// A created-schedule row's Open: Scheduled tasks with that schedule chosen.
    private func showSchedule(_ id: UUID) {
        guard model.scheduledTasks.schedule(id: id) != nil else { return }
        schedulesWindow.selection = id
        showSchedules()
    }

    /// The schedules a conversation's created-schedule rows read and open.
    private var scheduledTaskRowActions: ScheduledTaskRowActions {
        let center = model.scheduledTasks
        return ScheduledTaskRowActions(
            schedule: { center.schedule(id: $0) },
            nextRun: { center.nextRun(of: $0) },
            isStarting: { center.startingIDs.contains($0) },
            now: { center.displayNow },
            open: { showSchedule($0) })
    }

    private func closeSchedules() {
        guard schedulesWindow.isShowing else { return }
        schedulesWindow.isShowing = false
    }

    private var scheduleActions: ScheduledTaskActions {
        schedulesWindow.actions(model: model, newDraft: newScheduleDraft, openTask: { id in
            closeSchedules()
            activateTask(id)
        })
    }

    /// A new schedule starts with the new-task screen's place, harness, account, model and worktree.
    private func newScheduleDraft() -> ScheduleDraft {
        let draft = newTaskDraft
        let place: ScheduleDraft.Place
        if let id = draft.projectID, projects.project(id: id) != nil {
            place = .project(id)
        } else if let folder = draft.workspaceURL {
            place = projects.project(containingRoot: folder).map { .project($0.id) }
                ?? .folder(ProjectSidebarPresentation.normalizedPath(for: folder))
        } else {
            place = projects.projects.first { !$0.isHidden }.map { .project($0.id) } ?? .chat
        }
        let harness = draft.harness ?? model.runtimeSelections.connectedDescriptors.first?.id
        var worktree = false
        if case let .project(id) = place { worktree = draft.startsInNewWorktree(projectID: id) }
        return ScheduleDraft(now: model.scheduledTasks.now(), place: place, harness: harness,
                             accountID: harness.flatMap { model.connections.selection[$0] },
                             modelChoice: harness.flatMap { draft.modelChoices[$0] }, startsInNewWorktree: worktree)
    }

    /// "Use suggestion" on a Codex suggested task (`CodexSuggestedTaskCard`): as the Codex app opens a new
    /// thread with the prompt in its composer, a new task in the same project and harness opens with
    /// the prompt in its draft. Words already in the draft stay, before the prompt.
    private func startSuggestedTask(_ prompt: String, from session: SessionRecord) {
        newTaskDraft.takeSuggestedPrompt(prompt, project: projects.project(for: session), harness: session.harness)
        showNewTask()
    }

    /// Options on a suggested task's chip (`TaskSuggestionOptionsPopover`): what its Start starts
    /// with, over the new-task screen's own controls and model lists. Nil, with the reason on the
    /// row, where it cannot start now.
    private func taskSuggestionOptions(_ suggestion: ConversationTaskSuggestion,
                                       from session: SessionRecord) -> TaskSuggestionOptionsContext? {
        let source = sessionRecord(session.id) ?? session
        let start: SuggestedTaskStart
        switch model.suggestedTaskStart(for: suggestion, from: source) {
        case let .success(value): start = value
        case let .failure(failure):
            model.taskSuggestions.setProgress(.failed(failure.message), of: suggestion.id, in: source.id)
            return nil
        }
        let parent = start.parent
        let connections = model.connections, runtimes = model.runtimeSelections
        return TaskSuggestionOptionsContext(
            choice: { model.suggestedTaskChoice(for: suggestion, start: start, in: source.id) },
            parentLabel: parent.id == source.id ? nil : model.suggestedTaskPlaceLabel(for: suggestion, start: start, from: source),
            projects: projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project),
            harnesses: runtimes.connectedDescriptors,
            models: NewTaskModelSource(catalogs: model.modelCatalogs) {
                await model.loadNewTaskModels(harness: $0, runtimeURL: $1, connection: $2, workspaceURL: $3)
            },
            accounts: { connections.choices(for: [$0]) },
            checkAccounts: { await connections.checkNewTaskAccounts(for: $0, runtimeSelections: runtimes) },
            runtimeURL: { runtimes.selectedURL(for: $0) },
            defaults: { model.suggestedTaskOptions(harness: $0, parent: parent) },
            connection: { model.suggestedTaskConnection(harness: $0, parent: parent) },
            isRepository: SuggestedTaskPlace.isInRepository,
            asksForWorktree: suggestion.startsInNewWorktree,
            chooseWorkspace: { projects.ensureProject(forRoot: $0) },
            save: { model.taskSuggestions.setChoice($0, of: suggestion.id, in: source.id) },
            start: { choice in
                model.taskSuggestions.setChoice(choice, of: suggestion.id, in: source.id)
                Task { await model.startTaskSuggestion(suggestion, from: source.id) }
            })
    }

    /// The chips of `session`'s conversation, bound to it. Start and Do it here act in place; the
    /// window stays on this task.
    private func taskSuggestionActions(for session: SessionRecord) -> TaskSuggestionActions {
        TaskSuggestionActions(
            resolution: { model.taskSuggestions.resolution(of: $0, in: session.id) },
            progress: { model.taskSuggestions.progress(of: $0, in: session.id) },
            start: { suggestion in Task { await model.startTaskSuggestion(suggestion, from: session.id) } },
            doHere: { suggestion in Task { await model.doTaskSuggestionHere(suggestion, in: session.id) } },
            optionsContext: { taskSuggestionOptions($0, from: session) },
            startPlace: { suggestion in
                let source = sessionRecord(session.id) ?? session
                guard case let .success(start) = model.suggestedTaskStart(for: suggestion, from: source) else {
                    return TaskSuggestionStartPlace(startsInWorktree: false)
                }
                let choice = model.suggestedTaskChoice(for: suggestion, start: start, in: source.id)
                return TaskSuggestionStartPlace(
                    label: model.suggestedTaskPlaceLabel(for: suggestion, start: start, choice: choice, from: source),
                    startsInWorktree: choice.place.folder != nil && choice.place.startsInNewWorktree,
                    settings: model.suggestedTaskSettingsLabel(choice, for: suggestion))
            },
            dismiss: { model.dismissTaskSuggestion($0, in: session.id) },
            openTask: { activateTask($0) },
            canOpenTask: { id in model.store.sessions.contains { $0.id == id } }
        )
    }

    private func focusCurrentContent() {
        if let id = model.store.selectedSessionID {
            let workspace = model.taskWorkspaces.state(for: id, initialSurface: model.initialTaskSurface)
            workspace.keyboardFocus.move(to: .visibleContent(in: workspace.panels))
        } else {
            homeKeyboardFocus.move(to: .chat)
        }
    }

    private func activateTask(_ id: SessionRecord.ID) {
        activateRow(.session(id))
    }

    // MARK: - Window layer

    /// The window shows the new-task composer, one task, or a split view. A single task keeps the
    /// shell exactly as it is without pane chrome, so the common one-task layout is unchanged. The title
    /// bar heads what the tab shows: a task's or the new-task screen's area draws it over its conversation
    /// side, so a side panel beside the conversation reaches the window's top; a split view has it above
    /// its panes, whose headers head their tasks' areas.
    @ViewBuilder
    private var windowItemContent: some View {
        let item = model.splits.selection
        switch item {
        case .home:
            newTaskWorkspace
                .environment(\.taskAreaHeader, titleBarHeader(for: item))
        case let .session(id):
            if let session = sessionRecord(id) {
                TaskObservationScope { taskContent(for: session) }
                    .environment(\.taskAreaHeader, titleBarHeader(for: item))
                    .modifier(PaneDropTarget(sessionID: id) { dropped, direction in
                        placeDroppedTask(dropped, beside: nil, direction: direction)
                    })
            } else {
                VStack(spacing: 0) {
                    titleBar(for: item)
                    newTaskHome
                }
            }
        case .split:
            VStack(spacing: 0) {
                titleBar(for: item)
                if let split = model.splits.activeSplit {
                    SplitNodeView(
                        node: split.root,
                        path: [],
                        pane: { pane in paneCell(pane, split: split) },
                        onResize: { path, fractions in model.splits.resize(at: path, fractions: fractions) }
                    )
                } else {
                    newTaskHome
                }
            }
        }
    }

    private func sessionRecord(_ id: UUID?) -> SessionRecord? {
        id.flatMap { id in model.store.sessions.first { $0.id == id } }
    }

    private func paneCell(_ pane: SplitPane, split: SplitGroup) -> some View {
        let session = sessionRecord(pane.sessionID)
        let isFocused = pane.id == split.focusedPaneID
        let needsApproval = session?.status == .waitingForApproval
        let order = split.panes.firstIndex { $0.id == pane.id } ?? 0
        return Group {
            if let session {
                // The pane's header heads its task's area, where a side panel beside the conversation
                // puts its tabs in the header's row.
                TaskObservationScope { taskContent(for: session) }
                    .environment(\.taskAreaHeader, TaskAreaHeader(
                        height: SplitLayoutMetrics.paneHeaderHeight, isTitleBar: false,
                        content: AnyView(paneHeader(pane, session: session, isFocused: isFocused))))
            } else {
                VStack(spacing: 0) {
                    paneHeader(pane, session: nil, isFocused: isFocused)
                    newTaskHome
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
        .overlay {
            Rectangle()
                .strokeBorder(
                    needsApproval ? Color.orange : (isFocused ? ParityTheme.strongSeparator : .clear),
                    lineWidth: needsApproval ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // A simultaneous tap keeps the pane's own controls working while a click also claims focus.
        .simultaneousGesture(TapGesture().onEnded { focusPane(pane) })
        .modifier(PaneDropTarget(paneID: pane.id, sessionID: pane.sessionID) { dropped, direction in
            placeDroppedTask(dropped, beside: pane.id, direction: direction)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Pane"))
        .accessibilityValue(paneAccessibilityValue(session: session, isFocused: isFocused))
        // Reading order follows the visible layout so moving pane focus cannot reorder VoiceOver.
        .accessibilitySortPriority(ParityAccessibility.mainContent - Double(order))
        .focusSection()
    }

    /// The pane's task's header, whose buttons act on this pane's task (Claude app split panes each
    /// have theirs), or for an empty pane what fills it.
    private func paneHeader(_ pane: SplitPane, session: SessionRecord?, isFocused: Bool) -> some View {
        SplitPaneHeader(
            isFocused: isFocused,
            onFocus: { focusPane(pane) },
            onClose: { model.splits.closePane(pane.id) },
            dragged: session.map { ($0.id, WindowDragPreview(title: $0.title, harness: $0.harness)) },
            identity: {
                if let session {
                    TaskHeaderIdentity(session: session, actions: taskHeaderActions, compact: true)
                        .id(session.id)
                } else {
                    HStack(spacing: 6) {
                        Text(L10n.string("New task"))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        // An empty pane is filled from the sidebar, the way a split's empty half is.
                        Text(L10n.string("Or choose a task in the sidebar"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            },
            controls: { isFolded in
                if let session {
                    let workspace = model.taskWorkspaces.state(for: session.id, initialSurface: model.initialTaskSurface)
                    TaskSurfaceControls(
                        showsSessionRail: sessionRail.visibility.isOnScreen(session.id),
                        onToggleSessionRail: { sessionRail.toggle(for: session.id) },
                        panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
                        focusedSurface: isFocused ? $focusedTaskSurface : nil,
                        isFolded: isFolded,
                        // The focused pane's header takes `⌘1`–`⌘4`, as the title bar does for one task.
                        registersShortcuts: isFocused,
                        onActivate: { focusPane(pane) }
                    )
                    .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
                    .id(session.id)
                }
            }
        )
    }

    /// What a task's header offers, in the title bar for one task and in each split pane's header.
    private var taskHeaderActions: TaskHeaderActions {
        TaskHeaderActions(
            isAttached: { model.isAttached($0.id) },
            onResume: { session in Task { await model.resume(session) } },
            onRename: presentTaskRename,
            onTogglePinned: { session in Task { await model.togglePinned(session) } },
            onArchive: { session in Task { await model.archive(session) } },
            onBackToConversation: returnToConversation,
            projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) },
            projectMoveOptions: projectMoveOptions(for:),
            onMoveToProject: moveTask,
            onChooseAccount: { session in rememberShellFocus(); accountSwitchSession = session },
            canOpenOriginalConversation: { model.canOpenOriginalConversation(in: $0) },
            onOpenOriginalConversation: { session in Task { await model.openOriginalClaudeConversation(from: session) } },
            pullRequest: { model.pullRequests.pullRequest(for: $0.id) },
            servers: { model.resourceMonitor.servers(of: $0.id) },
            onOpenServer: openServer
        )
    }

    /// A task's server in a browser tab of the task, shown, with the keyboard on the page; in the default
    /// browser when the task has no room for another tab.
    private func openServer(_ session: SessionRecord, _ server: TaskServerPort) {
        let workspace = model.taskWorkspaces.state(for: session.id, initialSurface: model.initialTaskSurface)
        guard workspace.showServer(server) else {
            NSWorkspace.shared.open(server.url)
            return
        }
        workspace.keyboardFocus.move(to: .browser)
    }

    /// "Back to conversation": the task's panels close and the composer takes focus.
    private func returnToConversation(_ session: SessionRecord) {
        let workspace = model.taskWorkspaces.state(for: session.id)
        workspace.setPanels(TaskSurfaceNavigationProjection.closingAllPanels(workspace.panels))
        focusedTaskSurface = nil
        workspace.keyboardFocus.move(to: .chat)
    }

    private func paneAccessibilityValue(session: SessionRecord?, isFocused: Bool) -> String {
        var parts = [session?.title ?? L10n.string("New task")]
        if let session { parts.append(session.status.displayName) }
        if isFocused { parts.append(L10n.string("Focused")) }
        return parts.joined(separator: ", ")
    }

    private func focusPane(_ pane: SplitPane) {
        guard pane.id != model.splits.activeSplit?.focusedPaneID else { return }
        shellFocusBookmark = nil
        model.splits.focusPane(pane.id)
    }

    /// A sidebar row chosen: shown in the active tab, or with ⌘ held on the click in a new tab, as
    /// a browser opens a link. A cloud session opens in the agent's web page or app.
    private func activateRow(_ item: WindowItem) {
        if case let .session(id) = item,
           let session = model.store.sessions.first(where: { $0.id == id }),
           session.isCloud,
           let url = session.cloudTargetURL() {
            NSWorkspace.shared.open(url)
            return
        }
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.command),
           [.leftMouseDown, .leftMouseUp].contains(event.type) {
            return openInNewTab(item)
        }
        show(item)
    }

    private func show(_ item: WindowItem) {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.activate(item)
        focusCurrentContent()
    }

    /// View › Back, ⌘[ and the mouse's back button outside a browser page. The scheduled tasks list,
    /// which stands in for what the window shows, closes first. Personal agents keep no task history.
    private var goBack: (() -> Void)? {
        guard sidebarSection == .tasks, schedulesWindow.isShowing || model.splits.canGoBack else { return nil }
        return {
            shellFocusBookmark = nil
            if schedulesWindow.isShowing { closeSchedules() } else { model.splits.goBack() }
            focusCurrentContent()
        }
    }

    private var goForward: (() -> Void)? {
        guard sidebarSection == .tasks, model.splits.canGoForward else { return nil }
        return {
            shellFocusBookmark = nil
            closeSchedules()
            model.splits.goForward()
            focusCurrentContent()
        }
    }

    /// A conversation's link to another task (`TaskLink`): that task, in a new tab on ⌘-click as a
    /// sidebar row opens. A Codex thread Yardlet does not have opens in the Codex app; an anchor
    /// to a task Yardlet does not have only beeps.
    private func openLinkedTask(_ link: TaskLink, url: URL) {
        let inNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        Task {
            guard let task = await model.task(linkedBy: link) else {
                if link.opensElsewhere { NSWorkspace.shared.open(url) } else { NSSound.beep() }
                return
            }
            if inNewTab { openInNewTab(.session(task.id)) } else { show(.session(task.id)) }
        }
    }

    /// A file's related task: its conversation where it last touched the file, in a new tab on ⌘-click
    /// as a sidebar row opens.
    private func openFileTask(_ item: FileTasks.Item) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            openInNewTab(.session(item.id))
        } else {
            show(.session(item.id))
        }
        Task { await model.revealCall(item.callID, in: item.id) }
    }

    // MARK: - Tabs

    private func openInNewTab(_ item: WindowItem) {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.openInNewTab(item)
        focusCurrentContent()
    }

    private func selectTab(_ item: WindowItem) {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.selectTab(item)
        focusCurrentContent()
    }

    private func selectTab(offset: Int) {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.selectTab(offset: offset)
        focusCurrentContent()
    }

    private func closeTab(_ item: WindowItem? = nil) {
        shellFocusBookmark = nil
        model.splits.closeTab(item)
        focusCurrentContent()
    }

    private func newTab() {
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.newTab()
        focusCurrentContent()
    }

    private var windowTabs: [WindowTab] {
        WindowTabProjection.tabs(model.splits.tabs, sessions: model.store.sessions, splits: model.splits.splits,
                                 details: model.taskAttentionDetails, shellBusy: model.shellBusySessionIDs)
    }

    private func placeDroppedTask(_ sessionID: UUID, beside paneID: UUID?, direction: SplitDirection) {
        guard sessionRecord(sessionID) != nil else { return }
        shellFocusBookmark = nil
        model.splits.place(
            sessionID,
            beside: paneID,
            direction: direction,
            pinned: sessionRecord(model.store.selectedSessionID)?.isPinned ?? false
        )
    }

    /// A sidebar row's "Open in Split View": beside the focused pane when there is room for another,
    /// else a beep; from the new-task screen, which has no pane to put it beside, the task is shown.
    private func openInSplitView(_ id: UUID) {
        guard sessionRecord(id) != nil else { return }
        guard model.splits.selection != .home else { return show(.session(id)) }
        let isShown = model.splits.activeSplit?.pane(hosting: id) != nil
        guard isShown || canSplit(.right) else { return NSSound.beep() }
        shellFocusBookmark = nil
        closeSchedules()
        guard model.splits.openInSplitView(id, pinned: sessionRecord(model.store.selectedSessionID)?.isPinned ?? false)
        else { return NSSound.beep() }
        focusCurrentContent()
    }

    private func splitFocusedPane(_ direction: SplitDirection) {
        shellFocusBookmark = nil
        model.splits.split(direction, pinned: sessionRecord(model.store.selectedSessionID)?.isPinned ?? false)
        homeKeyboardFocus.move(to: .chat)
    }

    /// The focused pane's size, read from the content area and the pane's share of the split.
    private var focusedPaneSize: CGSize? {
        guard contentSize != .zero else { return nil }
        // Below the title bar, which heads the content.
        let area = CGSize(width: contentSize.width, height: max(0, contentSize.height - ParityTheme.titleBarHeight))
        guard let split = model.splits.activeSplit else { return area }
        guard let frame = split.root.frames()[split.focusedPaneID] else { return nil }
        return CGSize(width: area.width * frame.width, height: area.height * frame.height)
    }

    private func canSplit(_ direction: SplitDirection) -> Bool {
        model.splits.canSplit && SplitLayoutMetrics.canSplit(focusedPaneSize, direction)
    }

    /// The moves a task's menus and the command palette offer: the sidebar's projects, in its order.
    private func projectMoveOptions(for session: SessionRecord) -> TaskProjectMove.Options {
        model.projectMoveOptions(for: session, visibleProjects: allVisibleGroups.compactMap(\.project))
    }

    /// Moves a task to a project, or back to Chats (nil). The shown task stays in sight: a
    /// collapsed project it moves into opens, as going to a task in one does.
    private func moveTask(_ session: SessionRecord, to project: Project?) {
        Task {
            guard await model.moveTask(session, to: project) != nil, let project,
                  model.store.selectedSessionID == session.id else { return }
            sidebarDisclosure.expand(SidebarProjection.disclosureKey(
                for: WorkspaceGroup(workspaceURL: project.primaryRoot, sessions: [], project: project)))
        }
    }

    private var sidebarLayout: SidebarProjection.Layout {
        SidebarProjection.layout(
            visibleGroups: visibleGroups,
            allGroups: allVisibleGroups,
            chats: visibleChats,
            allChats: allChats,
            splits: model.splits.splits,
            isFiltering: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            disclosure: sidebarDisclosure.disclosure,
            selection: model.splits.selection,
            waiting: waitingSessionIDs,
            archivedParents: model.store.archivedParentIDs
        )
    }

    /// Tasks waiting on the person, which stay listed in a collapsed family.
    private var waitingSessionIDs: Set<UUID> {
        Set(model.store.sessions.lazy.filter {
            TaskAttentionProjection.waitingRequest(of: $0, detail: model.taskAttentionDetails[$0.id]) != nil
        }.map(\.id))
    }

    /// Pinned rows in sidebar order, whatever the search shows, for `⌃1`–`⌃9`.
    private var pinnedRows: [SidebarRow] {
        SidebarProjection.layout(
            visibleGroups: allVisibleGroups,
            allGroups: allVisibleGroups,
            chats: allChats,
            splits: model.splits.splits,
            isFiltering: false,
            archivedParents: model.store.archivedParentIDs
        ).pinned.flatMap(\.rowsWithChildren)
    }

    /// File › Refresh from the Claude App and Codex; nil while a pass runs.
    private var refreshFromOtherApps: (@MainActor () -> Void)? {
        guard !model.isFollowingSessionLists else { return nil }
        return { [model] in Task { await model.followSessionListsNow() } }
    }

    private var splitCommands: YardletSplitCommandSet {
        YardletSplitCommandSet(
            canSplitRight: sidebarSection == .tasks && canSplit(.right),
            canSplitDown: sidebarSection == .tasks && canSplit(.down),
            canClosePane: sidebarSection == .tasks && model.splits.canClosePane,
            pinnedRows: pinnedRows.map { PinnedRowMenuItem(id: $0.id, title: $0.title) },
            selection: sidebarSection == .tasks ? model.splits.selection : .home,
            splitRight: { splitFocusedPane(.right) },
            splitDown: { splitFocusedPane(.down) },
            closePane: { model.splits.closePane() },
            dissolve: {
                if let split = model.splits.activeSplit { model.splits.dissolve(split.id) }
            },
            focusPane: { model.splits.moveFocus($0) },
            activate: activateRow,
            tabs: YardletTabCommandSet(
                canCloseTab: sidebarSection == .tasks && model.splits.canCloseTab,
                canReopenClosedTab: model.splits.canReopenClosedTab,
                newTab: newTab,
                closeTab: { closeTab() },
                selectNextTab: { selectTab(offset: 1) },
                selectPreviousTab: { selectTab(offset: -1) },
                reopenClosedTab: {
                    sidebarSection = .tasks
                    shellFocusBookmark = nil
                    model.splits.reopenClosedTab()
                    focusCurrentContent()
                }
            )
        )
    }

    /// The window's width once it is known, which narrows the sidebar so the content keeps its minimum.
    private var knownWindowWidth: CGFloat? {
        windowSize == .zero ? nil : windowSize.width
    }

    /// The sidebar's account button: the person on this Mac, and the app-wide places its menu opens.
    private var accountMenu: SidebarAccountMenuContext {
        let connections = model.connections
        return SidebarAccountMenuContext(
            identity: accountIdentity,
            settingsSections: SettingsSection.available(hasAccounts: true, hasConnectors: true, hasVault: true,
                                                        hasRemote: model.remoteControl != nil),
            usage: { connections.usageLines() },
            checkUsage: { [model] in await model.checkUsageAccounts() },
            updateIsWaiting: { [updateWait] in updateWait?.isWaiting ?? false },
            checksForUpdates: sparkle != nil,
            refreshing: { [model] in model.isFollowingSessionLists },
            update: { [stagedUpdate, updateWait] in
                MenuBarMenu.UpdateLine(ready: stagedUpdate?.ready, isWaiting: updateWait?.isWaiting ?? false)
            },
            onSelect: openAccountMenuDestination
        )
    }

    /// Each item goes where its app menu or command palette item goes.
    private func openAccountMenuDestination(_ destination: SidebarAccountMenu.Destination) {
        switch destination {
        case .settings: presentSettings()
        case .settingsSection(.accounts): presentAccounts()
        case let .settingsSection(section): presentSettings(section)
        case let .accountUsage(harness): presentAccounts(harness)
        case .usage: presentAccounts()
        case .archivedTasks: showArchivedTasks()
        case .taskResourceUsage: openWindow(id: TaskResourceUsageWindow.sceneID)
        case .importConversation: rememberShellFocus(); isPresentingImport = true
        case .importFromOtherApps: rememberShellFocus(); isPresentingOtherAppImport = true
        case .refreshFromOtherApps: Task { await model.followSessionListsNow() }
        case .installUpdate: installUpdate?()
        case .checkForUpdates: sparkle?.checkForUpdates()
        case .updateWaiting: break
        case .cancelUpdateWait: updateWait?.cancel()
        }
    }

    private func toggleSidebar() {
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            isSidebarVisible.toggle()
        }
    }

    private func showArchivedTasks() {
        sidebarSection = .tasks
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            closeSchedules()
            isSidebarVisible = true
            isShowingArchivedTasks = true
        }
    }

    private func closeArchivedTasks() {
        isShowingArchivedTasks = false
        archivedSearchText = ""
    }

    /// The Task menu follows the rows the sidebar lists, the same order arrow keys move through.
    /// While a sheet, alert, or the environment panel is up, the task commands wait for it.
    private var taskCommands: YardletTaskCommandSet {
        var commands = YardletTaskCommandSet(
            targets: hasPresentedModal || sidebarSection != .tasks ? TaskCommandTargets() : TaskCommandTargets.make(
                layout: sidebarActivity.map(\.layout) ?? sidebarLayout,
                selection: schedulesWindow.isShowing ? .home : model.splits.selection,
                shownSession: schedulesWindow.isShowing ? nil : model.store.selectedSession,
                sidebarSessions: sidebarSessions,
                splits: model.splits.splits,
                details: model.taskAttentionDetails,
                shellBusy: model.shellBusySessionIDs
            ),
            isSidebarVisible: isSidebarVisible,
            activate: activateRow,
            toggleSidebar: toggleSidebar,
            toggleActivity: toggleActivity,
            togglePinned: { target in
                switch target {
                case let .split(id, _):
                    model.splits.togglePinned(id)
                case let .session(id, _):
                    guard let session = sessionRecord(id) else { return }
                    Task { await model.togglePinned(session) }
                }
            },
            markUnread: { id in Task { await model.store.markUnread(id: id) } },
            archive: { id in
                guard let session = sessionRecord(id) else { return }
                Task { await model.archive(session) }
            },
            showArchivedTasks: showArchivedTasks,
            sessionRail: sessionRail,
            shownTaskID: hasPresentedModal ? nil : commandTaskID,
            toggleSessionRail: toggleSessionRail,
            panels: hasPresentedModal || panelOwnerID == nil ? nil : taskPanelState.wrappedValue,
            toggleSidePanel: { toggleTaskPanel(TaskSurfaceNavigationProjection.sidePanelToggleID) },
            toggleTerminal: { toggleTaskPanel(TaskSurface.terminal.rawValue) }
        )
        if !hasPresentedModal {
            commands.newTask = { showNewTask() }
            commands.goBack = goBack
            commands.goForward = goForward
            commands.openModelMenu = sidebarSection == .tasks ? {
                let focus = model.store.selectedSessionID.map {
                    model.taskWorkspaces.state(for: $0, initialSurface: model.initialTaskSurface).keyboardFocus
                } ?? homeKeyboardFocus
                focus.move(to: .modelMenu)
            } : nil
        }
        return commands
    }

    /// View › Show/Hide side panel (⌘⌥B) and terminal (⌘J), and the command palette, for the shown
    /// task or the new-task screen: what the title bar's buttons do from the keyboard, so focus moves
    /// to what they show.
    private func toggleTaskPanel(_ targetID: String) {
        guard let id = panelOwnerID else { return }
        let workspace = panelWorkspace(id)
        workspace.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: workspace.panels, targetID: targetID))
        focusedTaskSurface = nil
        if targetID == TaskSurface.terminal.rawValue {
            workspace.keyboardFocus.move(to: .destination(for: .terminal, panels: workspace.panels))
        } else {
            workspace.keyboardFocus.move(to: TaskFocusTarget.visibleContent(in: workspace.panels))
        }
    }

    /// Find searches the shown task's conversation (the focused pane in split view). It waits while
    /// a sheet or alert is up, like the Task menu.
    private var conversationFind: ConversationFindModel? {
        guard !hasPresentedModal, let id = commandTaskID else { return nil }
        return model.taskWorkspaces.state(for: id, initialSurface: model.initialTaskSurface).conversationFind
    }

    private func splitMembers(_ split: SplitGroup) -> [SessionRecord] {
        split.sessionIDs.compactMap(sessionRecord)
    }

    private func presentSplitRename(_ split: SplitGroup) {
        rememberShellFocus()
        splitRenameTitle = split.customName ?? ""
        splitToRename = split
    }

    private func presentSplitArchive(_ split: SplitGroup) {
        rememberShellFocus()
        splitToArchive = split
    }

    /// A Claude task's retries, limit warning and limit-card actions, which other harnesses do not
    /// report, and for any task that Yardlet continued it after a restart.
    private func providerNotices(for session: SessionRecord) -> TaskProviderNotices? {
        let resumedAfterRestart = model.restartResumeNoticeSessionIDs.contains(session.id)
        let reconnecting = model.connectionResumes[session.id]?.isWaiting == true
        guard session.harness == .claudeCode else {
            return resumedAfterRestart || reconnecting
                ? TaskProviderNotices(resumedAfterRestart: resumedAfterRestart, reconnecting: reconnecting) : nil
        }
        return TaskProviderNotices(
            retry: model.providerRetryBySessionID[session.id],
            limitWarning: model.rateLimitWarningBySessionID[session.id],
            resumedAfterRestart: resumedAfterRestart,
            reconnecting: reconnecting,
            autoContinueEntryID: model.usageLimitAutoContinue[session.id]?.entryID,
            canContinue: session.status != .running && session.status != .waitingForApproval
                && !model.switchingAccounts.contains(session.id) && !model.sessionMutations.contains(session.id),
            switchError: model.usageLimitSwitchErrorBySessionID[session.id],
            accounts: { model.usageLimitAccountOptions(for: session) },
            refreshAccounts: { await model.refreshUsageLimitAccounts(for: session) },
            continueWithAccount: { connection in
                Task { await model.continueAfterUsageLimit(using: connection, for: session) }
            },
            setAutoContinue: { enabled, entryID, resetsAt in
                model.setUsageLimitAutoContinue(enabled, entryID: entryID, resetsAt: resetsAt, for: session)
            }
        )
    }

    /// How the task's subagent cards and background-task rows name their harness and model: in the
    /// composer's names, from the lists the harness last advertised for the task's account, and for
    /// a Codex task its thread's model, which a child thread spawned without one inherits.
    private func harnessModelNames(for session: SessionRecord) -> HarnessModelNames {
        HarnessModelNames(
            harness: session.harness,
            claude: model.modelCatalogs.claudeModels(for: session.connection),
            codex: model.modelCatalogs.codexModels(for: session.connection),
            threadModel: model.modelCatalogs.codexThreads[session.id]?.model
        )
    }

    /// A Codex task's open `/status` panel.
    private func codexStatusPanel(for session: SessionRecord) -> CodexStatusPanelState? {
        guard session.harness == .codex, let reading = model.codexStatusBySessionID[session.id] else { return nil }
        return CodexStatusPanelState(reading: reading, close: { model.closeCodexStatus(for: session) })
    }

    /// A Claude task's bash mode (`!`). Other harnesses have none, as their apps have none.
    private func shellCommands(for session: SessionRecord) -> ClaudeShellCommandActions? {
        guard ComposerSessionOptionsProjection.wiring(for: session.harness).runsShellCommands else { return nil }
        return ClaudeShellCommandActions(
            isRunning: model.isShellCommandRunning(in: session),
            run: { model.runShellCommand($0, in: session) },
            stop: { model.stopShellCommand(in: session) },
            runForEntry: { model.shellCommandRun(entryID: $0) },
            task: session
        )
    }

    /// - Parameter homeReply: the home answers the task in its composer's place (`NewTaskHome`): the
    ///   composer's Escape and Tab and every send or answer go to the home too.
    private func taskContent(for session: SessionRecord, conversationOnly: Bool = false, filePanelOwnerID: UUID? = nil,
                             homeReply: NewTaskHomeReplyHooks? = nil) -> some View {
        let workspace = model.taskWorkspaces.state(for: session.id, initialSurface: model.initialTaskSurface)
        return TaskPresentationBoundary(
            conversationOnly: conversationOnly,
            sideChat: conversationOnly ? nil : AnyView(sideChatContent(for: session)),
            onOpenSideChat: conversationOnly ? nil : { openSideChat(for: session) },
            sidePanelTasks: conversationOnly ? nil : sidePanelTaskServices(for: session),
            session: session,
            composerDraft: model.composerDrafts.tasks.draft(for: session.id),
            workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focusedTaskSurface,
            entries: model.transcriptBySessionID[session.id] ?? [],
            isReadingSavedConversation: model.isReadingSavedConversation(session.id),
            errorMessage: model.errorBySessionID[session.id],
            codexTaskState: model.codexPresentationBySessionID[session.id],
            codexHistorySelection: model.codexHistorySelectionBySessionID[session.id],
            codexQueue: model.followUps.queue(for: session.id),
            isCodexQueuePaused: model.followUps.isPaused(session.id),
            codexCapabilities: model.composerCodexCapabilities(for: session),
            providerCapabilities: model.composerProviderCapabilities(for: session),
            providerUsage: model.providerUsageBySessionID[session.id],
            restoredCodexTokenUsage: model.restoredCodexTokenUsageBySessionID[session.id],
            isProviderAttached: model.isAttached(session.id),
            onShowCodexCapabilities: { presentHarnessSettings(session) },
            conversationActions: homeReply.map { hooks in
                conversationActions(for: session).replying(hooks, waitsBeyond: { requestID in
                    // Another request of the task still waits: the home stays on it.
                    let task = sessionRecord(session.id) ?? session
                    return (model.railChildWait(task)?.requests ?? []).contains { $0.id != requestID }
                })
            } ?? conversationActions(for: session),
            composerActions: homeReply.map { composerActions(for: session).replying($0) } ?? composerActions(for: session)
        )
        .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
        .environment(\.codexStatusPanel, codexStatusPanel(for: session))
        .environment(\.claudeShellCommands, shellCommands(for: session))
        .environment(\.harnessModelNames, harnessModelNames(for: session))
        .environment(\.composerConnectors, composerConnectors(for: session))
        // A side chat's conversation draws no rail of its own.
        .environment(\.sessionRail, conversationOnly ? nil : sessionRailServices(for: session))
        // While shown and detached, the conversation follows another app's writes, read-only.
        .task(id: "\(session.id)|\(model.isAttached(session.id))") {
            await model.followDetachedConversation(for: session)
        }
        // A task whose folder is gone says so above its composer, looked at when it is shown and when
        // the app comes to the front.
        .environment(\.taskFolderMissing, model.missingTaskFolders[session.id].map { missing in
            TaskFolderMissingNotice(missing: missing, isRecreating: model.recreatingTaskWorktrees.contains(session.id),
                                    recreateWorktree: { Task { await model.recreateTaskWorktree(session.id) } })
        })
        .task(id: session.id) { await model.refreshTaskFolder(session.id) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshTaskFolder(session.id) }
        }
        .disabled(model.switchingAccounts.contains(session.id) || model.sessionMutations.contains(session.id))
        .environment(\.openURL, OpenURLAction { url in
            // A link to another task opens that task, as the Claude app and Codex open theirs.
            if let link = TaskLink(url) {
                openLinkedTask(link, url: url)
                return .handled
            }
            // Any other anchor names a place in the message, not a file.
            if url.scheme == nil, url.path(percentEncoded: false).isEmpty { return .discarded }
            guard url.isFileURL || url.scheme == nil else { return .systemAction }
            // A folder opens in Finder, as the Codex app opens a folder link; an app or another package
            // is shown there rather than run.
            if let folder = WorkspaceFileLocation.folder(url, in: session.workspaceURL) {
                if NSWorkspace.shared.isFilePackage(atPath: folder.path(percentEncoded: false)) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } else {
                    NSWorkspace.shared.open(folder)
                }
                return .handled
            }
            let owner = model.taskWorkspaces.state(for: panelOwnerID(for: session, filePanelOwnerID: filePanelOwnerID))
            owner.files.open(url, in: session.workspaceURL)
            var panels = owner.panels
            panels.trailingSurfaceID = "files"
            owner.setPanels(panels)
            owner.keyboardFocus.move(to: .files)
            return .handled
        })
        // A Codex suggested task's "Use suggestion" opens a new task holding its prompt.
        .environment(\.startSuggestedTask, { prompt in startSuggestedTask(prompt, from: session) })
        // An agent's suggested task (`spawn_task`) is a chip that starts it under this task, sends it
        // here, or lets the person choose what it starts with.
        .environment(\.taskSuggestionActions, taskSuggestionActions(for: session))
        // A schedule an agent created (`create_scheduled_task`) is a row whose Open shows it.
        .environment(\.scheduledTaskRowActions, scheduledTaskRowActions)
        // A `run_agent` card reads its subagent's live line and conversation, and stops it.
        .environment(\.agentRunActions, agentRunActions(for: session, opensInPanel: !conversationOnly))
        // A file change row's diff that is too long for the conversation continues here.
        .environment(\.openTaskChanges, {
            let owner = model.taskWorkspaces.state(for: panelOwnerID(for: session, filePanelOwnerID: filePanelOwnerID))
            var panels = owner.panels
            panels.trailingSurfaceID = TaskSurface.diff.rawValue
            owner.setPanels(panels)
            owner.keyboardFocus.move(to: .destination(for: .diff, panels: panels))
        })
        // A file's related tasks in the review and the files panel, each opening its conversation where it
        // touched the file, and that place, which the task's conversation goes to.
        .environment(\.fileTaskServices, FileTaskServices(
            currentTaskID: session.id, lookup: { await model.tasks(touching: $0) }, open: openFileTask))
        .environment(\.conversationPlace, model.conversationPlaceRequests[session.id].map { request in
            ConversationPlace(request: request, done: { model.finishConversationPlace(request, in: session.id) })
        })
        // The task's values above belong to its identity: as the window opens another task, the
        // outgoing task's views are not updated once more with the next task's values on the way out.
        .id(session.id)
    }

    /// The task whose side panel a conversation's file link or long diff opens in: the task whose panel
    /// shows the conversation (a side chat, another task's tab) when it has the same folder, else the
    /// conversation's own task, which the window then shows, since the panel's Files and Review read
    /// the panel's task's folder.
    private func panelOwnerID(for session: SessionRecord, filePanelOwnerID: UUID?) -> UUID {
        guard let ownerID = filePanelOwnerID, ownerID != session.id else { return session.id }
        if sessionRecord(ownerID)?.workspaceURL == session.workspaceURL { return ownerID }
        activateTask(session.id)
        return session.id
    }

    /// Other tasks' conversations in `owner`'s side panel: the tasks the sidebar lists, most recent
    /// first, each drawn as its own view draws it (`taskContent`, its conversation and composer).
    private func sidePanelTaskServices(for owner: SessionRecord) -> SidePanelTaskServices {
        SidePanelTaskServices(
            record: { id in id == owner.id ? nil : sessionRecord(id) },
            choices: { model.sidebarSessions.filter { $0.id != owner.id }.sorted { $0.updatedAt > $1.updatedAt } },
            projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) },
            tab: { session, onClose in AnyView(sidePanelTaskTab(session, ownerID: owner.id, onClose: onClose)) }
        )
    }

    /// Other tasks' conversations in the new-task screen's side panel, as in a task's.
    private var draftSidePanelTaskServices: SidePanelTaskServices {
        SidePanelTaskServices(
            record: { sessionRecord($0) },
            choices: { model.sidebarSessions.sorted { $0.updatedAt > $1.updatedAt } },
            projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) },
            tab: { session, onClose in
                AnyView(sidePanelTaskTab(session, ownerID: TaskWorkspaceStore.draftID, onClose: onClose))
            }
        )
    }

    /// Another task's conversation as a tab in the side panel of `ownerID`, a task or the new-task
    /// screen. Showing it reads its saved conversation as hovering its sidebar row would
    /// (`prefetchSavedConversation`): nothing resumes, and a turn cut off by a restart that waits for
    /// the task to be opened keeps waiting. Seeing it marks it read, as a side chat does.
    private func sidePanelTaskTab(_ session: SessionRecord, ownerID: UUID,
                                  onClose: @escaping () -> Void) -> some View {
        let otherPane = model.splits.activeSplit?.pane(hosting: session.id)
        return SidePanelTaskTab(
            session: session,
            projectName: model.project(for: session)?.name ?? projects.displayName(for: session.workspaceURL),
            showOtherPane: otherPane.map { pane in { focusPane(pane) } },
            parentFocus: model.taskWorkspaces.state(for: ownerID).keyboardFocus,
            childFocus: model.taskWorkspaces.state(for: session.id).keyboardFocus,
            onOpenTask: { activateTask(session.id) },
            onClose: onClose,
            content: AnyView(TaskObservationScope {
                taskContent(for: session, conversationOnly: true, filePanelOwnerID: ownerID)
            })
        )
        .task(id: session.id) { model.prefetchSavedConversation(of: session.id) }
        .task(id: "\(session.hasUnreadUpdate)|\(otherPane == nil)") {
            if otherPane == nil, session.hasUnreadUpdate { await model.store.markRead(id: session.id) }
        }
    }

    /// A sidebar row's "Open in Side Panel": its conversation as a tab in the side panel of the task
    /// the window shows (in a split view, the focused pane's), or of the new-task screen. With neither
    /// shown, or for the task shown itself, there is nothing to put it beside.
    private func openInSidePanel(_ id: UUID) {
        guard let ownerID = panelOwnerID, ownerID != id,
              ownerID == TaskWorkspaceStore.draftID || sessionRecord(ownerID) != nil, sessionRecord(id) != nil
        else { return NSSound.beep() }
        let workspace = model.taskWorkspaces.state(for: ownerID)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.taskTabID(id),
                                                                   in: workspace.panels))
        workspace.keyboardFocus.move(to: .taskTab)
    }

    /// What a task's conversation can ask of the app model, bound to the task.
    private func conversationActions(for session: SessionRecord) -> ConversationActions {
        ConversationActions(
            decide: { requestID, decision in
                Task { await model.respond(to: requestID, decision: decision, in: session) }
            },
            chooseOption: { requestID, action in
                Task { await model.respond(to: requestID, action: action, in: session) }
            },
            answer: { requestID, answer in
                Task { await model.respond(to: requestID, answer: answer, in: session) }
            },
            respondToCodexRequest: { requestID, response in
                Task { await model.respondCodex(to: requestID, response: response, in: session) }
            },
            heldRequests: model.heldRequests(in: session.id),
            openCodexSubagent: { threadID in
                Task { await model.openCodexSubagent(threadID: threadID, from: session) }
            },
            loadMoreCodexTurns: {
                Task { await model.loadMoreCodexTurns(for: session) }
            },
            readEarlierHistory: model.hasEarlierClaudeHistory(session) ? {
                Task { await model.readEarlierClaudeHistory(for: session) }
            } : nil,
            loadMoreCodexItems: { turnID in
                Task { await model.loadMoreCodexItems(for: session, turnID: turnID) }
            },
            retryTurn: { turnID in
                Task { await model.retryTurn(turnID, in: session) }
            },
            forkCodexTurn: { turnID in
                Task { await model.branch(session, at: .turn(turnID)) }
            },
            branch: model.canBranch(session) ? { point in
                Task { await model.branch(session, at: point) }
            } : nil,
            implementCodexPlan: { plan in
                Task { await model.implementCodexPlan(plan, in: session) }
            },
            answerQuestion: { answer in
                Task { await model.submitCodex(CodexComposerDraft(inputs: [.text(answer)]), action: .automatic, to: session) }
            },
            answerQuestionWhileWorking: { answer in
                Task { await model.submitCodex(CodexComposerDraft(inputs: [.text(answer)]), action: .steer, to: session) }
            },
            rewind: ConversationRewindActions(
                beginCodexEdit: { model.beginCodexEdit($0, in: session) },
                beginClaudeEdit: { text in Task { await model.beginClaudeEdit(text, in: session) } },
                cancelEdit: { model.cancelConversationEdit(in: session) },
                loadFilePoints: { try await model.loadClaudeFilePoints(in: session) },
                previewFiles: { try await model.previewClaudeFiles(pointID: $0, in: session) },
                restoreFiles: { try await model.restoreClaudeFiles($0) }
            ),
            showHarnessSettings: { presentHarnessSettings(session) },
            providerNotices: providerNotices(for: session),
            readSubtask: { activity in
                try await model.readClaudeSubtask(activityID: activity.id, from: session)
            },
            stopSubtask: { activity in
                try await model.stopClaudeSubtask(activityID: activity.id, from: session)
            }
        )
    }

    /// Yardlet's connectors as this task's composer lists them: each one's state in this task
    /// (`ConnectorCenter.state`, with what the harness was found to load itself), its switch, and
    /// "Reconnect".
    private func composerConnectors(for session: SessionRecord) -> ComposerConnectorEnvironment {
        let center = model.connectorCenter
        let scope = model.connectorScopeBySessionID[session.id] ?? ConnectorTaskScope(harness: session.harness)
        return ComposerConnectorEnvironment(
            records: center?.connectors ?? [],
            taskState: { record in center?.state(of: record, inTask: session.id, scope: scope) ?? .on },
            standInServerNames: Set(scope.leftOutNativeServers.map(\.name)),
            setOn: center.map { center in { id, on in center.setConnector(id, on: on, inTask: session.id) } },
            // A service that needs the user's client or a new token is set up in Settings.
            reconnect: center.map { center in { id in
                if let record = center.record(id),
                   record.needsSetupBeforeConnecting || (record.authorization == .token && record.status == .signInRequired) {
                    presentSettings(.connectors)
                } else {
                    center.reconnect(id)
                }
            } },
            openSettings: { presentSettings(.connectors) },
            addConnector: center.map { _ in { presentConnectorDirectory() } },
            target: .init(center: center.map(ObjectIdentifier.init), taskID: session.id, scope: scope))
    }

    /// What a task's composer can ask of the app model, bound to the task. Whether the task has a
    /// follow-up queue, which submit its drafts take, and where its controls read their choices
    /// comes from the composer's wiring; the queue's actions are the same for every provider.
    private func composerActions(for session: SessionRecord) -> ComposerActions {
        let wiring = ComposerSessionOptionsProjection.wiring(for: session.harness)
        var actions = ComposerActions(
            send: { input in Task { await model.send(input, to: session) } },
            interrupt: { Task { await model.interrupt(session) } },
            refreshProviderStatus: {
                await model.refreshConversationStatus(for: session)
            },
            prepareProviderSettings: {
                switch wiring.settings {
                case .codexModels: await model.loadCodexModels(for: session)
                case .providerCapabilities: await model.loadProviderCapabilities(for: session)
                }
            },
            setProviderOption: { id, value in
                Task { await model.setProviderOption(id, value: value, for: session) }
            },
            selectCodexModel: { selection in
                Task { await model.selectCodexModel(selection, for: session) }
            },
            selectCodexRunLocation: { location in
                Task { await model.selectCodexRunLocation(location, for: session) }
            },
            refreshConnectors: { await model.refreshMCPServers(for: session) },
            prepareCodexCommands: { await model.prepareCodexComposerCommands(for: session) }
        )
        if wiring.submission == .codexDraft {
            actions.submitCodex = { draft, action in
                Task { await model.submitCodex(draft, action: action, to: session) }
            }
        }
        if wiring.followUpQueue != nil {
            actions.submitFollowUp = { input, action in
                Task { await model.submitFollowUp(input, action: action, to: session) }
            }
            actions.sendQueuedNow = { itemID in
                Task { await model.sendQueuedNow(itemID, for: session) }
            }
            actions.stopAndSendQueued = { itemID in
                Task { await model.stopAndSendQueued(itemID, for: session) }
            }
            actions.removeQueued = { itemID in
                Task { await model.removeQueued(itemID, for: session) }
            }
            actions.retryQueued = { itemID in model.retryQueued(itemID, for: session) }
            actions.moveQueued = { itemID, index in model.moveQueued(itemID, in: session, to: index) }
            actions.editQueued = { itemID in model.editQueued(itemID, for: session) }
            actions.resumeQueue = { model.resumeQueue(for: session) }
        }
        if wiring.runsCodexCommands {
            actions.runCodexCommand = { command in
                switch command {
                case .rename: presentTaskRename(session)
                // A side chat's own composer has no Side command; the parent opens it.
                case .sideChat: openSideChat(for: session)
                default: Task { await model.runCodexComposerCommand(command, in: session) }
                }
            }
        }
        return actions
    }

    private var newTaskHome: some View { newTaskHome(takesDraftWorkspace: false) }

    /// The new-task screen in the tab that shows it, with the panels a task's screen has; the task it
    /// starts takes them over. An empty split pane shows the screen without them (13.47).
    private var newTaskWorkspace: some View {
        NewTaskWorkspace(
            draft: newTaskDraft,
            workspaceState: model.taskWorkspaces.draft,
            focusedSurface: $focusedTaskSurface,
            sidePanelTasks: draftSidePanelTaskServices,
            home: { newTaskHome(takesDraftWorkspace: true) }
        )
        .environment(\.taskKeyboardFocus, homeKeyboardFocus)
    }

    private func newTaskHome(takesDraftWorkspace: Bool) -> some View {
        NewTaskHome(
            recentSessions: Array(model.store.sessions.prefix(6)),
            projects: projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project),
            draft: newTaskDraft,
            runtimeSelections: model.runtimeSelections,
            connections: model.connections,
            models: NewTaskModelSource(catalogs: model.modelCatalogs) {
                await model.loadNewTaskModels(harness: $0, runtimeURL: $1, connection: $2, workspaceURL: $3)
            },
            onSelectSession: { activateTask($0.id) },
            onChooseWorkspace: { projects.ensureProject(forRoot: $0) },
            onShowHarnesses: presentHarnesses,
            onManageAccounts: { presentAccounts($0) },
            onAddAccount: { presentAccounts($0, add: true) },
            onConnectAccount: { presentAccounts($0.harness, connect: $0) },
            onCreate: { submission in
                var submission = submission
                submission.takesDraftWorkspace = takesDraftWorkspace
                return try await model.createTask(submission)
            },
            onReadCommands: { workspace, runtime, connection in
                try await model.readHomeComposerCommands(workspaceURL: workspace, runtimeURL: runtime, connection: connection)
            },
            onImportConversation: { rememberShellFocus(); isPresentingImport = true },
            onImportFromOtherApps: { rememberShellFocus(); isPresentingOtherAppImport = true },
            projectName: { projects.displayName(for: $0) },
            activity: NewTaskHomeActivity(
                sessions: sidebarSessions, details: model.taskAttentionDetails,
                shellBusy: model.shellBusySessionIDs, placeName: model.taskPlaceNames(),
                groups: projects.visibleGroups(sessions: sidebarSessions),
                chats: projects.chats(sessions: sidebarSessions),
                agents: { model.railAgentRuns(hostedBy: $0).filter { !$0.state.isFinished }.count },
                schedules: model.scheduledTasks.schedules.compactMap { schedule in
                    model.scheduledTasks.nextRun(of: schedule).map { (schedule, $0) }
                },
                stoppedSchedules: model.scheduledTasks.schedules.filter(\.hasStoppedItself),
                isSuggestionOpen: { model.taskSuggestions.resolution(of: $0.id, in: $1) == nil },
                notices: NewTaskHomeListsProjection.usageNotices(
                    choices: model.connections.menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id))),
                now: model.scheduledTasks.displayNow,
                windowHeight: windowSize.height > 0 ? windowSize.height : nil,
                onMarkRead: { ids in Task { await model.store.markRead(ids: ids) } },
                onOpenSchedule: showSchedule,
                onSetAside: { projects.setAside($0, through: $1) },
                answerLine: { model.answerLineBySessionID[$0] }),
            reply: NewTaskHomeReplyServices(
                content: { session, hooks in AnyView(homeReplyContent(session, hooks: hooks)) },
                isShownElsewhere: { model.splits.activeSplit?.pane(hosting: $0) != nil },
                focus: { model.taskWorkspaces.state(for: $0).keyboardFocus.move(to: .chat) })
        )
        // The lists read the pull requests the sidebar rows read.
        .environment(model.pullRequests)
        // A pane without a session keeps the shell's home focus path, not the focused task's.
        .environment(\.taskKeyboardFocus, homeKeyboardFocus)
        // Its nearly spent limits are the Usage lines' readings.
        .task { await model.checkUsageAccounts() }
    }

    /// A task the home answers in its composer's place: its conversation and composer as a side-panel
    /// tab draws them, its saved conversation read as hovering its sidebar row would (nothing resumes,
    /// and a turn a restart cut off that waits for the task to be opened keeps waiting).
    private func homeReplyContent(_ session: SessionRecord, hooks: NewTaskHomeReplyHooks) -> some View {
        TaskObservationScope {
            taskContent(for: session, conversationOnly: true, filePanelOwnerID: TaskWorkspaceStore.draftID,
                        homeReply: hooks)
        }
        .task(id: session.id) { model.prefetchSavedConversation(of: session.id) }
    }

    private func openSideChat(for parent: SessionRecord) {
        let workspace = model.taskWorkspaces.state(for: parent.id)
        var panels = workspace.panels
        panels.trailingSurfaceID = "sideChat"
        workspace.setPanels(panels)
        workspace.keyboardFocus.move(to: .sideChat)
        Task { await model.branch(parent, placement: .sidePanel) }
    }

    private func sideChatContent(for parent: SessionRecord) -> some View {
        let workspace = model.taskWorkspaces.state(for: parent.id)
        let child = model.store.sessions.first { $0.id == workspace.sideChatSessionID && $0.id != parent.id }
        return SideChatPanel(
            workspaceURL: parent.workspaceURL,
            harness: child?.harness ?? parent.harness,
            childID: child?.id,
            isLoading: model.openingSideChats.contains(parent.id),
            errorMessage: model.sideChatErrors[parent.id],
            parentFocus: workspace.keyboardFocus,
            childFocus: child.map { model.taskWorkspaces.state(for: $0.id).keyboardFocus },
            onCreate: { openSideChat(for: parent) },
            onClose: {
                workspace.setPanels(TaskSurfaceNavigationProjection.closingTrailingTab("sideChat", in: workspace.panels))
                workspace.keyboardFocus.move(to: .visibleContent(in: workspace.panels))
            },
            content: child.map { child in
                AnyView(TaskObservationScope { taskContent(for: child, conversationOnly: true, filePanelOwnerID: parent.id) })
            }
        )
        .task(id: child?.hasUnreadUpdate) {
            if let child, child.hasUnreadUpdate { await model.store.markRead(id: child.id) }
        }
    }

    /// The split view the tab shows, whose header the title bar is: its sidebar row's name and actions.
    private var titleBarSplitHeader: SplitViewHeader? {
        guard !schedulesWindow.isShowing, let split = model.splits.activeSplit else { return nil }
        var isVertical = false
        if case let .branch(axis, _, _) = split.root { isVertical = axis == .vertical }
        return SplitViewHeader(
            title: split.customName ?? splitMembers(split).map(\.title).joined(separator: " + "),
            isPinned: split.isPinned,
            isVertical: isVertical,
            rename: { presentSplitRename(split) },
            togglePinned: { model.splits.togglePinned(split.id) },
            dissolve: { model.splits.dissolve(split.id) },
            archive: { presentSplitArchive(split) }
        )
    }

    /// The task the View menu's rail key, Find and the palette's task commands act on: the shown task
    /// (the focused pane's in a split view), none while scheduled tasks are shown in its place.
    private var commandTaskID: UUID? {
        schedulesWindow.isShowing || sidebarSection != .tasks ? nil : model.store.selectedSessionID
    }

    /// The panels the View menu's ⌘J and ⌘⌥B, the palette and "Open in Side Panel" act on: the shown
    /// task's, or the new-task screen's while the tab shows it.
    private var panelOwnerID: UUID? {
        guard sidebarSection == .tasks else { return nil }
        if let commandTaskID { return commandTaskID }
        return !schedulesWindow.isShowing && model.splits.selection == .home ? TaskWorkspaceStore.draftID : nil
    }

    private var windowContent: some View {
        HStack(spacing: 0) {
                if isSidebarVisible, sidebarSection == .personalAgents {
                    SidebarColumn(state: sidebarWidth, windowWidth: knownWindowWidth) {
                        VStack(spacing: 0) {
                            sidebarTitleBar
                            PersonalAgentsSidebar(center: personalAgents, accounts: personalAccounts,
                                accountID: $personalAccountID, accountMenu: accountMenu,
                                onBack: closePersonalAgents,
                                onAccounts: { presentSettings(.harnesses) },
                                onRefresh: reconnectPersonalAgents)
                        }
                    }
                } else if isSidebarVisible, schedulesWindow.isShowing {
                    SidebarColumn(state: sidebarWidth, windowWidth: knownWindowWidth) {
                        VStack(spacing: 0) {
                            sidebarTitleBar
                            ScheduledTasksSidebar(model: model, state: schedulesWindow, onBack: closeSchedules,
                                                  actions: scheduleActions)
                        }
                    }
                } else if isSidebarVisible, isShowingArchivedTasks {
                    SidebarColumn(state: sidebarWidth, windowWidth: knownWindowWidth) {
                    VStack(spacing: 0) {
                    sidebarTitleBar
                    ArchivedTaskList(
                        archived: model.store.archivedSessions,
                        errorMessage: model.archivedTaskError,
                        restoringIDs: model.unarchivingSessionIDs,
                        searchText: $archivedSearchText,
                        projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) },
                        onBack: closeArchivedTasks,
                        onUnarchive: { record in Task { await model.unarchive(record) } }
                    )
                    .task { await model.loadArchivedTasks() }
                    }
                    }
                } else if isSidebarVisible {
                    SidebarColumn(state: sidebarWidth, windowWidth: knownWindowWidth) {
                    VStack(spacing: 0) {
                    sidebarTitleBar
                    TaskSidebar(
                        layout: sidebarLayout,
                        allGroups: allVisibleGroups,
                        isRestoring: model.isRestoringIndex,
                        selection: SidebarProjection.row(for: model.splits.selection, in: sidebarLayout)
                            ?? model.splits.selection,
                        searchText: $searchText,
                        onNewTask: showNewTask,
                        onShowSchedules: showSchedules,
                        onShowPersonalAgents: showPersonalAgents,
                        onActivate: activateRow,
                        onNewTaskInProject: { workspaceURL in
                            let project = projects.ensureProject(forRoot: workspaceURL)
                            newTaskDraft.projectID = project.id
                            newTaskDraft.workspaceURL = project.primaryRoot
                            showNewTask()
                        },
                        onAddProject: addProject,
                        projects: projects,
                        onEditProject: { group in
                            guard let id = group.project?.id else { return }
                            rememberShellFocus()
                            projectToEdit = id
                        },
                        onArchiveProjectChats: { rememberShellFocus(); projectToArchive = $0 },
                        onRemoveProject: { rememberShellFocus(); projectToRemove = $0 },
                        onTogglePinned: { session in Task { await model.togglePinned(session) } },
                        onArchive: { session in Task { await model.archive(session) } },
                        onDelete: { session in rememberShellFocus(); sessionToDelete = session },
                        onRename: presentTaskRename,
                        onMarkRead: { session in Task { await model.store.markRead(id: session.id) } },
                        onMarkUnread: { session in Task { await model.store.markUnread(id: session.id) } },
                        onMoveToProject: moveTask,
                        onDetachFromParent: { session in Task { await model.detachFromParent(session) } },
                        splitActions: SidebarSplitActions(
                            togglePinned: { model.splits.togglePinned($0.id) },
                            rename: presentSplitRename,
                            dissolve: { model.splits.dissolve($0.id) },
                            archive: presentSplitArchive,
                            combine: { dropped, target in
                                shellFocusBookmark = nil
                                model.splits.combine(dropped, with: target, pinned: sessionRecord(target)?.isPinned ?? false)
                            },
                            add: { dropped, split in
                                shellFocusBookmark = nil
                                model.splits.add(dropped, to: split.id)
                            }
                        ),
                        accountMenu: accountMenu,
                        disclosure: sidebarDisclosure,
                        activity: sidebarActivity,
                        onListAtTopChange: { atTop in
                            isSidebarListAtTop = atTop
                            holdSidebarOrder()
                        }
                    )
                    .environment(\.shellBusyTaskIDs, model.shellBusySessionIDs)
                    .environment(\.openWindowItemInNewTab, WindowItemNewTabAction(open: openInNewTab))
                    .environment(\.openTaskInSplitView, TaskSplitViewAction(open: openInSplitView))
                    .environment(\.openTaskInSidePanel, TaskSidePanelAction(open: openInSidePanel))
                    .environment(\.prefetchTaskConversation, TaskConversationPrefetch(model: model))
                    .environment(\.taskAttentionDetails, model.taskAttentionDetails)
                    .environment(\.scheduledTaskIDs, model.scheduledTasks.scheduledTaskIDs)
                    .environment(model.resourceMonitor)
                    .environment(model.pullRequests)
                    .environment(model.accountAssignments)
                    .environment(\.sidebarHoverCard, sidebarHoverCard)
                    .onChange(of: model.splits.selection, initial: true) { holdSidebarOrder() }
                    }
                    }
                }

                Group {
                    if sidebarSection == .personalAgents {
                        VStack(spacing: 0) {
                            titleBar(for: nil)
                            PersonalAgentsContent(center: personalAgents,
                                                  accountTitle: personalAccounts.first { $0.id == personalAccountID }?.title,
                                                  onRetry: reconnectPersonalAgents,
                                                  onAccounts: { presentSettings(.harnesses) })
                        }
                    } else if model.isRestoringIndex {
                        VStack(spacing: 0) {
                            titleBar(for: nil)
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.string("Restoring tasks…"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if schedulesWindow.isShowing {
                        VStack(spacing: 0) {
                            titleBar(for: nil)
                            ScheduledTasksMain(model: model, state: schedulesWindow, actions: scheduleActions,
                                               projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) })
                        }
                    } else {
                        windowItemContent
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                            // The side panel's default width reads the window's height, as the Codex app's does.
                            .environment(\.taskWindowHeight, windowSize.height > 0 ? windowSize.height : nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
                .focusSection()
                #if DEBUG
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.usesVisualFixture && CommandLine.arguments.contains("--ui-fixture=workspace") {
                        HStack {
                            Text("Workspace fixture · No provider")
                            Spacer()
                            Button("Grow latest") { model.updateWorkspaceReadingFixture(addTurn: false) }
                            Button("Add turn") { model.updateWorkspaceReadingFixture(addTurn: true) }
                        }.font(.caption).buttonStyle(.borderless).padding(8)
                    }
                }
                #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        .coordinateSpace(.named(SidebarHoverCardMetrics.space))
        .overlay(alignment: .topLeading) {
            if isSidebarVisible, sidebarSection == .tasks, !schedulesWindow.isShowing, !isShowingArchivedTasks {
                SidebarHoverCardLayer(state: sidebarHoverCard)
            }
        }
        // The label that follows a window drag, over everything.
        .overlay { WindowDragPreviewLayer(drag: windowDrag) }
        .environment(\.windowDrag, windowDrag)
        .onAppear { windowDrag.perform = { subject, target in performWindowDrop(subject, on: target) } }
        // The window's buttons stay centred on the title bar's row.
        .background(WindowChromeAlignmentAnchor())
        .background { SessionRailStorage(state: sessionRail) }
        .task(id: personalLoadKey) {
            if sidebarSection == .personalAgents { await connectPersonalAgents() }
            else { await personalAgents.disconnect() }
        }
        .onDisappear { Task { await personalAgents.disconnect() } }
        // Only the task on screen is looked up, when it comes into view and while it stays.
        .onChange(of: model.pullRequestTargets(), initial: true) { _, targets in
            model.pullRequests.show(targets)
        }
    }

    /// The title bar's part over the sidebar.
    private var sidebarTitleBar: some View {
        TitleBarSidebarPart(
            isSidebarVisible: true,
            width: sidebarWidth.shown(inWindowWidth: knownWindowWidth),
            onToggleSidebar: toggleSidebar,
            onNewTask: showNewTask,
            activityToggle: ActivityViewToggle(
                isOn: isShowingActivity && !isShowingArchivedTasks,
                needsAttention: model.attentionBadgeCount > 0,
                toggle: toggleActivity
            )
        )
    }

    private func reportTaskSurface() {
        model.setShowsTasks(sidebarSection == .tasks, inWindow: windowID)
        if sidebarSection == .tasks, let current = model.store.selectedSessionID {
            Task { await model.store.markRead(id: current) }
        }
    }

    private var personalAccounts: [AccountChoice] { model.connections.choices(for: [.codex]) }

    private var personalLoadKey: String {
        guard sidebarSection == .personalAgents else { return "tasks" }
        return personalDraftKey + "|" + (model.runtimeSelections.selectedURL(for: .codex)?.path() ?? "")
    }

    private var personalDraftKey: String {
        let home = personalAccounts.first { $0.id == personalAccountID }?.connection?.homePath
            ?? model.codexEnvironmentManager?.paths.nativeHomeURL.path()
            ?? CodexEnvironmentPaths.live().nativeHomeURL.path()
        return personalAccountID + "|" + home
    }

    private func connectPersonalAgents() async {
        guard sidebarSection == .personalAgents, !Task.isCancelled else { return }
        if let personalAgentReader {
            return await personalAgents.connect(sourceKey: personalLoadKey, makeClient: personalAgentReader)
        }
        guard let runtime = model.runtimeSelections.selectedURL(for: .codex) else {
            await personalAgents.disconnect()
            guard !Task.isCancelled else { return }
            personalAgents.showUnavailable(.runtimeUnavailable)
            return
        }
        guard let account = personalAccounts.first(where: { $0.id == personalAccountID }) else {
            if let first = personalAccounts.first { personalAccountID = first.id }
            return
        }
        let key = personalLoadKey
        await personalAgents.connect(sourceKey: key, draftSourceKey: personalDraftKey) {
            DotsService(executable: runtime, environmentManager: model.codexEnvironmentManager,
                        connection: account.connection)
        }
    }

    private func reconnectPersonalAgents() {
        if personalAgents.failure == .accountChanged { personalAgents.forgetReadings() }
        Task { await connectPersonalAgents() }
    }

    /// The title bar beside the sidebar for what the tab shows: `item` is the window's item the title bar
    /// heads (the shown task, the split view or the new-task screen), nil for a screen in its place
    /// (scheduled tasks, restoring), which shows neither a task's header nor the tabs.
    private func titleBar(for item: WindowItem?) -> IntegratedTitleBar {
        let session = item.flatMap { item -> SessionRecord? in
            guard case let .session(id) = item else { return nil }
            return sessionRecord(id)
        }
        let isSplit: Bool = if case .split = item { true } else { false }
        return IntegratedTitleBar(
            session: session,
            isSidebarVisible: isSidebarVisible,
            isAttached: session.map { model.isAttached($0.id) } ?? false,
            showsSessionRail: false,
            onToggleSessionRail: toggleSessionRail,
            sessionRail: sessionRail,
            panelState: taskPanelState,
            focusedSurface: $focusedTaskSurface,
            onToggleSidebar: toggleSidebar,
            onNewTask: showNewTask,
            onResume: { session in Task { await model.resume(session) } },
            onRename: presentTaskRename,
            onTogglePinned: { session in Task { await model.togglePinned(session) } },
            onArchive: { session in Task { await model.archive(session) } },
            onBackToConversation: returnToConversation,
            projectName: { model.project(for: $0)?.name ?? projects.displayName(for: $0.workspaceURL) },
            projectMoveOptions: projectMoveOptions(for:),
            onMoveToProject: moveTask,
            onChooseAccount: { session in rememberShellFocus(); accountSwitchSession = session },
            canOpenOriginalConversation: { model.canOpenOriginalConversation(in: $0) },
            onOpenOriginalConversation: { session in Task { await model.openOriginalClaudeConversation(from: session) } },
            pullRequest: session.flatMap { model.pullRequests.pullRequest(for: $0.id) },
            servers: { model.resourceMonitor.servers(of: $0.id) },
            onOpenServer: openServer,
            splitHeader: isSplit ? titleBarSplitHeader : nil,
            draftPanels: item == .home ? taskPanelState : nil,
            tabs: item != nil && model.splits.tabs.count > 1 ? TitleBarTabs(
                tabs: windowTabs,
                selection: model.splits.selection,
                onSelect: selectTab,
                onClose: closeTab,
                onCloseOthers: { model.splits.closeOtherTabs(than: $0) },
                onNewTab: newTab,
                onOpenTask: openInOwnTab
            ) : nil
        )
    }

    /// A task dragged onto the tab bar gets a tab of its own there, which shows.
    private func openInOwnTab(_ id: UUID, before: WindowItem?) {
        guard sessionRecord(id) != nil else { return }
        sidebarSection = .tasks
        shellFocusBookmark = nil
        closeSchedules()
        model.splits.openInOwnTab(id, before: before)
        focusCurrentContent()
    }

    /// Carries out a drag in the window (`WindowDragState`): a tab along the tab bar or a side panel's
    /// strip, a task beside a pane, a pane onto another's middle, a task onto the tab bar. Another task's
    /// conversation dragged out of a side panel leaves the panel for where it went.
    private func performWindowDrop(_ subject: WindowDragSubject, on target: WindowDropTarget) {
        let geometry = windowDrag.geometry
        switch target {
        case let .windowTabs(index):
            let before = geometry.windowTabs?.id(before: index) as? WindowItem
            if case let .windowTab(item) = subject {
                // The dragged tab shows, as Safari shows a tab once it is pressed.
                model.splits.moveTab(item, before: before)
                return selectTab(item)
            }
            guard let task = subject.task else { return }
            closeDraggedPanelTab(subject)
            openInOwnTab(task, before: before)
        case let .pane(paneID, direction):
            guard let task = subject.task else { return }
            closeDraggedPanelTab(subject)
            placeDroppedTask(task, beside: paneID, direction: direction)
        case let .swapPane(paneID):
            guard case let .pane(task) = subject else { return }
            shellFocusBookmark = nil
            model.splits.swap(task, withPane: paneID)
        case let .panelTabs(owner, index):
            guard case let .panelTab(_, tab) = subject else { return }
            let before = geometry.panelStrips[owner]?.id(before: index) as? String
            let workspace = panelWorkspace(owner)
            // The dragged tab shows, as a dragged window tab does.
            let moved = TaskSurfaceNavigationProjection.movingTab(tab, before: before, in: workspace.panels)
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(tab, in: moved))
        }
    }

    private func closeDraggedPanelTab(_ subject: WindowDragSubject) {
        guard case let .panelTab(owner, tab) = subject else { return }
        let workspace = panelWorkspace(owner)
        workspace.setPanels(TaskSurfaceNavigationProjection.closingTrailingTab(tab, in: workspace.panels))
    }

    /// The title bar as the header of the area that shows the tab's task or new-task screen.
    private func titleBarHeader(for item: WindowItem) -> TaskAreaHeader {
        TaskAreaHeader(height: ParityTheme.titleBarHeight, isTitleBar: true, content: AnyView(titleBar(for: item)))
    }

    /// The title bar's rail button, the View menu and ⌃⌘I: the shown task's rail (the focused pane's
    /// in split view) goes away, or comes back beside the conversation or raised over it.
    private func toggleSessionRail() {
        sessionRail.toggle(for: model.store.selectedSessionID)
    }

    /// What the window gives a task's rail.
    private func sessionRailServices(for session: SessionRecord) -> SessionRailServices {
        SessionRailServices(
            window: sessionRail,
            preferences: model.sessionRailPreferences,
            projectName: model.project(for: session)?.name ?? projects.displayName(for: session.workspaceURL),
            instructionSources: { model.instructionSources(for: session) },
            account: { [connections = model.connections] in
                connections.choices(for: [session.harness])
                    .first { $0.connection?.id == session.connection?.id }
                    .map(SessionRailAccount.init(choice:))
            },
            chooseAccount: TaskAccountSwitch.supports(session.harness) ? {
                rememberShellFocus()
                accountSwitchSession = session
            } : nil,
            pullRequest: model.pullRequests.pullRequest(for: session.id),
            details: model.pullRequestDetails,
            agents: railAgentServices(for: session))
    }

    /// A `run_agent` card reads its subagent's live line and conversation, and stops it; its
    /// conversation opens beside the task, or in a sheet where the task's panels are not shown.
    private func agentRunActions(for session: SessionRecord, opensInPanel: Bool) -> AgentRunActions {
        var actions = AgentRunActions(
            run: { model.sessionTools.run(agentID: $0, prompt: $1, hostTaskID: session.id) },
            stop: { run in Task { await model.stopAgentRun(run) } })
        if opensInPanel {
            let workspaces = model.taskWorkspaces
            actions.open = { run in
                workspaces.state(for: session.id).showPanelDetail(.agentRun(run.id, title: run.name))
            }
        }
        return actions
    }

    /// What the rail's Agents, Background tasks and Preview cards read from the app for a task.
    private func railAgentServices(for session: SessionRecord) -> SessionRailAgentServices {
        var services = SessionRailAgentServices()
        services.agentRuns = { model.railAgentRuns(hostedBy: session.id) }
        services.childTasks = { model.railChildTasks(of: session.id) }
        services.childRequests = { id in childRequestActions(id) }
        services.browserPreviewTab = { Self.browserPreviewTab(for: session.id) }
        services.openTask = { id in openTaskFromRail(id) }
        services.agentRun = { model.sessionTools.run($0) }
        services.keptAgentRun = { model.keptAgentRun($0, hostTaskID: session.id) }
        services.stopAgentRun = { run in Task { await model.stopAgentRun(run) } }
        services.readCodexThread = { threadID in try await model.readCodexChildThread(threadID, of: session) }
        services.readTaskOutput = { activity in await model.readClaudeTaskOutput(activity, of: session) }
        if session.harness == .claudeCode { services.sessionJobs = { model.sessionJobs(of: session.id) } }
        if session.harness == .codex {
            services.readBackgroundTerminals = { await model.codexBackgroundTerminals(of: session) }
            services.stopTerminal = { terminal in try await model.stopCodexBackgroundTerminal(terminal.processID, of: session) }
            services.stopAllTerminals = { try await model.stopAllCodexBackgroundTerminals(of: session) }
        }
        return services
    }

    /// The task's browser tab the agent drives in its running turn, and the page's title.
    private static func browserPreviewTab(for session: UUID) -> SessionRailBrowserTab? {
        guard MacBrowserHost.isAvailable, let id = BrowserAgentUse.shared.tabs[session],
              let tab = MacBrowserHost.shared.client.tabs(forSession: session).first(where: { $0.id == id })
        else { return nil }
        return SessionRailBrowserTab(tab: id, title: tab.title, key: tab.key)
    }

    /// What a child task's row in the Agents card answers for it, as its own conversation does: its
    /// requests, and a Codex question's answer into its running turn, or as its next message once the
    /// turn ended and it can start one.
    private func childRequestActions(_ id: UUID) -> ConversationActions {
        guard let child = sessionRecord(id) else { return ConversationActions() }
        let own = conversationActions(for: child)
        var actions = own.answeringRequestsOnly
        let isWorking = child.status == .running || child.status == .waitingForApproval
            || model.codexPresentationBySessionID[id]?.activeTurnID != nil
        if isWorking {
            actions.answerQuestionWhileWorking = own.answerQuestionWhileWorking
        } else if model.composerDrafts.tasks.draft(for: id).editState == nil, model.followUps.queue(for: id).isEmpty {
            actions.answerQuestion = own.answerQuestion
        }
        return actions
    }

    /// A child task's row in the Agents card: that task, in a new tab on ⌘-click as a sidebar row opens.
    private func openTaskFromRail(_ id: UUID) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            openInNewTab(.session(id))
        } else {
            show(.session(id))
        }
    }

    private var draftManagedContent: some View {
        windowContent
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = model.composerDrafts.storageFailure {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(L10n.string(failure == .restore
                        ? "Drafts could not be restored. Copy your current input before closing."
                        : "Drafts could not be saved. Copy your input before closing."))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.string("Retry")) { model.composerDrafts.retry() }
                        .buttonStyle(.borderless)
                        .fixedSize()
                }
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.primary)
                .padding(12)
                .background(.bar)
            }
        }
    }

    private var shellPresentedContent: some View {
        draftManagedContent
        .environment(\.taskKeyboardFocus, model.store.selectedSessionID.map {
            model.taskWorkspaces.state(for: $0).keyboardFocus
        } ?? homeKeyboardFocus)
        .frame(minWidth: 760, minHeight: 560)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .background(ParityTheme.canvas)
        .background(WindowInitialFocusReset().allowsHitTesting(false))
        .background(MouseNavigationMonitor(goBack: hasPresentedModal ? nil : goBack,
                                           goForward: hasPresentedModal ? nil : goForward))
        // Keep ordinary shell controls monochrome. Semantic status, links, and the primary send
        // action opt into Yardlet's accent explicitly at their point of use.
        .tint(Color.primary)
        .sheet(item: $model.pendingCodexReview, onDismiss: finishShellModal) { request in
            CodexReviewTargetSheet(request: request, onCancel: { model.pendingCodexReview = nil }, onReview: { target in
                model.pendingCodexReview = nil
                Task { await model.startCodexReview(target, in: request.session, submittedDraft: request.draft) }
            })
        }
        .sheet(item: $accountSwitchSession, onDismiss: finishShellModal) { session in
            TaskAccountSelectionView(session: session, store: model.connections, runtimeSelections: model.runtimeSelections) { connection in
                accountSwitchSession = nil
                Task { await model.switchAccount(to: connection, for: session) }
            }
        }
        .sheet(item: $connectionPresentation, onDismiss: finishShellModal) { presentation in
            HarnessCenterView(
                runtimeSelections: model.runtimeSelections,
                connections: model.connections,
                initialTab: presentation.tab,
                initialHarness: presentation.harness,
                addsAccount: presentation.addsAccount,
                initialChoice: presentation.choice,
                fixtureSnapshots: accountFixtureSnapshots,
                fixtureLoginHarness: accountFixtureLogin?.0,
                fixtureLoginCommand: accountFixtureLogin?.1,
                localSessionUsage: selectedLocalSessionUsage,
                codexEnvironmentManager: model.codexEnvironmentManager
            )
        }
        .sheet(isPresented: $isPresentingSettings, onDismiss: {
            settingsRoute = nil
            finishShellModal()
        }) {
            SettingsCenterView(
                size: SettingsCenterView.fittingSize(in: windowSize),
                initialSection: settingsRoute?.section.rawValue ?? model.initialSettingsSection,
                notificationCenter: model.systemNotificationCenter,
                // The connectors the composers and the rail read (the app's own, unless a visual fixture
                // put its own in place).
                connectors: model.connectorCenter ?? MacAgentToolService.shared.connectors,
                vault: MacAgentToolService.shared.vault,
                accounts: SettingsAccountsContext(
                    runtimeSelections: model.runtimeSelections, connections: model.connections,
                    initialHarness: settingsRoute?.harness,
                    harnessUsage: AccountHarnessScope.Usage(withTasks: Set(model.store.sessions.map(\.harness)),
                        chosenForNewTask: newTaskDraft.harness),
                    codexEnvironmentManager: model.codexEnvironmentManager,
                    localSessionUsage: selectedLocalSessionUsage,
                    tasksUsingAccount: { connection in
                        model.store.sessions.filter { $0.connection?.id == connection.id }.count
                    },
                    fixtureSnapshots: accountFixtureSnapshots, fixtureLogin: accountFixtureLogin),
                remote: model.remoteControl,
                cliUpdates: model.cliUpdates,
                instructions: model.yardletInstructions,
                evaluation: model.routingEvaluation,
                lidHelper: model.lidSleepHelper
            )
        }
        .sheet(item: $connectorAddStart, onDismiss: finishShellModal) { start in
            if let center = model.connectorCenter {
                ConnectorAddSheet(center: center, start: start) { connectorAddStart = nil }
            }
        }
        .sheet(isPresented: $isPresentingCommandPalette, onDismiss: finishCommandPalette) {
            CommandPaletteView(items: commandPaletteItems, tasks: commandPaletteTasks, onSelect: { pendingCommand = $0 })
        }
        .sheet(isPresented: $isPresentingImport, onDismiss: finishShellModal) {
            ImportConversationSheet(model: model,
                projects: projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project),
                initialWorkspace: newTaskDraft.workspaceURL,
                // The DEBUG history fixture opens on Codex's search; launches leave both nil.
                initialHarness: model.initialCodexHistoryQuery == nil ? nil : .codex,
                initialSearchTerm: model.initialCodexHistoryQuery,
                onDismiss: { isPresentingImport = false })
        }
        .sheet(isPresented: $isPresentingOtherAppImport, onDismiss: finishShellModal) {
            OtherAppImportSheet(model: model, onDismiss: { isPresentingOtherAppImport = false })
        }
        .focusedSceneValue(\.yardletSettingsPresented, modalBinding($isPresentingSettings))
        .focusedSceneValue(\.yardletCommandPalettePresented, modalBinding($isPresentingCommandPalette))
        .focusedSceneValue(\.yardletImportPresented, modalBinding($isPresentingImport))
        .focusedSceneValue(\.yardletOtherAppImportPresented, modalBinding($isPresentingOtherAppImport))
        .focusedSceneValue(\.yardletRefreshFromOtherApps, refreshFromOtherApps)
        .focusedSceneValue(\.yardletSplitCommands, splitCommands)
        .focusedSceneValue(\.yardletTaskCommands, taskCommands)
        .focusedSceneValue(\.yardletConversationFind, conversationFind)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshVisibleProviderTitles() }
        }
        .onChange(of: model.store.selectedSessionID) { previous, current in
            sessionRail.dismissRaised()
            if let previous { model.taskWorkspaces.state(for: previous).keyboardFocus.cancel() }
            else { homeKeyboardFocus.cancel() }
            shellFocusBookmark = nil
            if !model.isRestoringIndex { model.taskWorkspaces.rememberSelection(model.store.selectedSessionID) }
            focusedTaskSurface = nil
            if let current {
                keepActivityPlace(of: current)
                if sidebarSection == .tasks { Task { await model.store.markRead(id: current) } }
            }
        }
        // Only a window showing Tasks shows the selected task; coming back to them reads it.
        .onAppear(perform: reportTaskSurface)
        .onChange(of: sidebarSection) { _, _ in reportTaskSurface() }
        .onDisappear { model.setShowsTasks(false, inWindow: windowID) }
        .onChange(of: model.store.workspaceGroups.map(\.workspaceURL), initial: true) { _, _ in
            projects.ensureProjects(forTasks: model.store.sessions)
        }
        // A notification led to a task archived since: the archived list is where it is restored.
        .onChange(of: model.archivedTasksRevealRequest) { _, _ in showArchivedTasks() }
        .onChange(of: model.taskSurfaceRevealRequest) { _, _ in
            sidebarSection = .tasks
            shellFocusBookmark = nil
            closeSchedules()
            focusCurrentContent()
        }
        // A notification or the menu bar menu opens the window again once it was closed.
        .onAppear { TaskResourceUsageWindow.reopenMainWindow = { openWindow(id: "main") } }
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.mainWindow)
#endif
        shellPresentedContent
        .sheet(item: Binding(
            get: { projectToEdit.map { ProjectEditPresentation(id: $0) } },
            set: { if $0 == nil { projectToEdit = nil } }
        ), onDismiss: finishShellModal) { presentation in
            ProjectEditSheet(projects: projects, projectID: presentation.id, instructions: model.yardletInstructions)
        }
        .sheet(item: $harnessSettingsSession, onDismiss: restoreTaskModalFocus) { session in
            let actions = HarnessSettingsActions(model: model, session: session,
                                                 dismiss: { harnessSettingsSession = nil })
            let source = HarnessSettingsSource(harness: session.harness)
            HarnessSettingsSheet(
                session: session,
                content: model.harnessSettings(for: session),
                onRefresh: { Task { await actions.refresh(source) } },
                onCommand: { actions.perform($0) },
                onDismiss: { harnessSettingsSession = nil },
                initialSection: model.initialCodexCapabilitySection
            )
            .task {
                if !model.hasLoadedHarnessSettings(for: session) {
                    await actions.refresh(source)
                }
            }
        }
        .onChange(of: hasManagementAlert) { _, isPresented in
            if !isPresented { finishShellModal() }
        }
        .alert(L10n.string("Rename task"), isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField(L10n.string("Task title"), text: $renameTitle)
                .id(taskRenamePresentationID)
            Button(L10n.string("Cancel"), role: .cancel) { sessionToRename = nil }
            Button(L10n.string("Rename")) {
                guard let session = sessionToRename else { return }
                let title = renameTitle
                sessionToRename = nil
                Task { await model.rename(session, to: title) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L10n.string("Delete task?"), isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { sessionToDelete = nil }
            Button(L10n.string("Delete task"), role: .destructive) {
                guard let session = sessionToDelete else { return }
                sessionToDelete = nil
                Task { await model.delete(session) }
            }
        } message: {
            if let session = sessionToDelete {
                Text(L10n.format(
                    session.harness == .codex && model.isAttached(session.id)
                        ? "Delete attached Codex task confirmation" : "Delete task confirmation",
                    session.title
                ))
            }
        }
        .alert(L10n.string("Archive project chats?"), isPresented: Binding(
            get: { projectToArchive != nil },
            set: { if !$0 { projectToArchive = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { projectToArchive = nil }
            Button(L10n.string("Archive chats"), role: .destructive) {
                guard let group = projectToArchive else { return }
                projectToArchive = nil
                Task { await model.archive(group.sessions) }
            }
        } message: {
            if let group = projectToArchive {
                Text(L10n.format("Archive project chats confirmation",
                                 group.displayName, group.sessions.count))
                if group.sessions.contains(where: { $0.harness == .codex && model.isAttached($0.id) }) {
                    Text(L10n.string("Archive attached Codex tasks confirmation"))
                }
            }
        }
        .alert(L10n.string("Remove project?"), isPresented: Binding(
            get: { projectToRemove != nil },
            set: { if !$0 { projectToRemove = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { projectToRemove = nil }
            Button(L10n.string("Remove project"), role: .destructive) {
                guard let group = projectToRemove else { return }
                projectToRemove = nil
                if let id = group.project?.id { projects.hide(id) }
                if newTaskDraft.workspaceURL?.standardizedFileURL == group.workspaceURL.standardizedFileURL {
                    newTaskDraft.workspaceURL = nil
                }
                if model.store.selectedSession?.workspaceURL == group.workspaceURL {
                    model.store.selectedSessionID = nil
                }
            }
        } message: {
            if let group = projectToRemove {
                Text(L10n.format("Remove project confirmation", group.displayName))
            }
        }
        .alert(L10n.string("Rename split view"), isPresented: Binding(
            get: { splitToRename != nil },
            set: { if !$0 { splitToRename = nil } }
        )) {
            TextField(L10n.string("Split view name"), text: $splitRenameTitle)
            Button(L10n.string("Cancel"), role: .cancel) { splitToRename = nil }
            Button(L10n.string("Save")) {
                guard let split = splitToRename else { return }
                splitToRename = nil
                model.splits.rename(split.id, to: splitRenameTitle)
            }
        } message: {
            Text(L10n.string("Leave the name empty to show the tasks' titles."))
        }
        .alert(L10n.string("Archive the split view's tasks?"), isPresented: Binding(
            get: { splitToArchive != nil },
            set: { if !$0 { splitToArchive = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { splitToArchive = nil }
            Button(L10n.string("Archive tasks"), role: .destructive) {
                guard let split = splitToArchive else { return }
                splitToArchive = nil
                let members = splitMembers(split)
                Task { await model.archive(members) }
            }
        } message: {
            if let split = splitToArchive {
                Text(L10n.format("Archive split view confirmation", Int64(splitMembers(split).count)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let worktreeNotice = model.worktreeNotice {
                WorktreeNoticeBar(message: worktreeNotice, onDismiss: model.dismissWorktreeNotice)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let cliUpdates = model.cliUpdates, let notice = cliUpdates.notice {
                WorktreeNoticeBar(message: notice.message, systemImage: "arrow.uturn.backward.circle",
                                  onDismiss: cliUpdates.dismissNotice)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let bootstrapError = model.bootstrapError {
                Label(bootstrapError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
        }
        .task {
            if automaticallyShowsHarnessFixture {
                presentHarnesses()
            }
            if model.initialCodexHistoryQuery != nil {
                isPresentingImport = true
            }
            if model.initialSettingsSection != nil {
                isPresentingSettings = true
            }
        }
    }

    private var automaticallyShowsHarnessFixture: Bool {
#if DEBUG
        CommandLine.arguments.contains("--ui-fixture=account")
            || CommandLine.arguments.contains("--ui-fixture=account-login")
#else
        false
#endif
    }

    private var accountFixtureSnapshots: [HarnessAccountSnapshot]? {
#if DEBUG
        if model.usesVisualFixture { return VisualFixtureScenario.harnessCenterSnapshots }
        guard CommandLine.arguments.contains("--ui-fixture=account")
                || CommandLine.arguments.contains("--ui-fixture=account-login") else { return nil }
        return VisualFixtureScenario.accountSnapshots
#else
        return nil
#endif
    }

    private var accountFixtureLogin: (HarnessKind, AccountInteractiveCommand)? {
#if DEBUG
        guard CommandLine.arguments.contains("--ui-fixture=account-login") else { return nil }
        return (
            .grokBuild,
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Open https://example.com/device\\n'; "
                        + "printf 'Verification code: ABCD-EFGH\\n'; /bin/sleep 120"
                ],
                initialInput: nil
            )
        )
#else
        return nil
#endif
    }

    private var selectedLocalSessionUsage: LocalSessionUsageOverview? {
        guard let session = model.store.selectedSession else { return nil }
        return LocalSessionUsageProjection.overview(
            session: session,
            state: model.codexPresentationBySessionID[session.id]
        )
    }

    /// The window layer has no toolbar of its own, so the palette mirrors the Split View menu.
    private var splitPaletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        for direction in [SplitDirection.right, .down] where canSplit(direction) {
            items.append(
                CommandPaletteItem(
                    id: "split-\(direction.rawValue)",
                    title: SplitCommandTitle.split(direction),
                    subtitle: L10n.string("Show another task beside the focused pane."),
                    systemName: direction == .right
                        ? "rectangle.righthalf.inset.filled"
                        : "rectangle.bottomhalf.inset.filled",
                    action: { splitFocusedPane(direction) }
                )
            )
        }
        if let split = model.splits.activeSplit {
            items.append(
                CommandPaletteItem(
                    id: "close-pane",
                    title: L10n.string("Close pane"),
                    subtitle: L10n.string("Take the task out of the split view; it keeps its own row."),
                    systemName: "rectangle.badge.xmark",
                    action: { model.splits.closePane() }
                )
            )
            for direction in PaneFocusDirection.allCases {
                items.append(
                    CommandPaletteItem(
                        id: "focus-pane-\(direction.rawValue)",
                        title: SplitCommandTitle.focus(direction),
                        subtitle: L10n.string("Move the pane focus inside this split view."),
                        systemName: SplitCommandTitle.focusSymbol(direction),
                        action: { model.splits.moveFocus(direction) }
                    )
                )
            }
            items.append(
                CommandPaletteItem(
                    id: "end-split",
                    title: L10n.string("End split view"),
                    subtitle: L10n.string("Return each task to its own sidebar row."),
                    systemName: "rectangle.split.2x1",
                    action: { model.splits.dissolve(split.id) }
                )
            )
            items.append(
                CommandPaletteItem(
                    id: "rename-split",
                    title: L10n.string("Rename split view…"),
                    subtitle: split.customName ?? splitMembers(split).map(\.title).joined(separator: " + "),
                    systemName: "pencil",
                    action: { presentSplitRename(split) }
                )
            )
        }
        return items
    }

    /// The tasks ⌘K finds: those the sidebar lists, most recent first, without the one on screen, each
    /// opening as its sidebar row does.
    private var commandPaletteTasks: [CommandPaletteItem] {
        model.sidebarSessions
            .filter { $0.id != model.store.selectedSessionID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { session in
                CommandPaletteItem(
                    id: "task-\(session.id)",
                    title: session.title,
                    subtitle: model.project(for: session)?.name ?? projects.displayName(for: session.workspaceURL),
                    systemName: "text.bubble",
                    isTask: true,
                    action: { activateTask(session.id) }
                )
            }
    }

    private var commandPaletteItems: [CommandPaletteItem] {
        var items = [
            CommandPaletteItem(
                id: "new-task",
                title: L10n.string("New task"),
                subtitle: L10n.string("Choose a project and harness to start a task."),
                systemName: "square.and.pencil",
                action: showNewTask
            ),
            CommandPaletteItem(
                id: "toggle-sidebar",
                title: isSidebarVisible
                    ? L10n.string("Hide sidebar")
                    : L10n.string("Show sidebar"),
                subtitle: L10n.string("Change the task navigation layout."),
                systemName: "sidebar.left",
                action: toggleSidebar
            ),
            CommandPaletteItem(
                id: "toggle-activity",
                title: L10n.string("Toggle activity view"),
                subtitle: L10n.string("Turn the sidebar activity view on or off"),
                systemName: "bell",
                action: toggleActivity
            ),
            CommandPaletteItem(
                id: "archived-tasks",
                title: L10n.string("Archived tasks"),
                subtitle: L10n.string("Show archived tasks and restore them."),
                systemName: "archivebox",
                action: showArchivedTasks
            ),
            CommandPaletteItem(
                id: "task-resource-usage",
                title: L10n.string("Task Resource Usage"),
                subtitle: L10n.string("See how much CPU and memory each task's processes use."),
                systemName: "cpu",
                action: { openWindow(id: TaskResourceUsageWindow.sceneID) }
            ),
            CommandPaletteItem(
                id: "import-conversation",
                title: L10n.string("Import conversation…"),
                subtitle: L10n.string("Continue a conversation started in the Claude or Codex app or in Antigravity CLI."),
                systemName: "square.and.arrow.down",
                action: { isPresentingImport = true }
            ),
            CommandPaletteItem(
                id: "import-other-apps",
                title: L10n.string("Import Conversations from Other Apps…"),
                subtitle: L10n.string("Bring in the conversations open in the Claude and Codex apps."),
                systemName: "square.and.arrow.down.on.square",
                action: { isPresentingOtherAppImport = true }
            ),
            CommandPaletteItem(
                id: "harnesses",
                title: L10n.string("Harnesses"),
                subtitle: L10n.string("Connect harnesses and check account status."),
                systemName: "square.grid.2x2",
                action: presentHarnesses
            ),
            CommandPaletteItem(
                id: "settings",
                title: L10n.string("Settings"),
                subtitle: L10n.string("Change appearance, notifications, and app preferences."),
                systemName: "gearshape.2",
                action: { presentSettings() }
            )
        ]
        items.append(contentsOf: splitPaletteItems)
        if panelOwnerID != nil {
            let panels = taskPanelState.wrappedValue
            var panelItems = [
                CommandPaletteItem(
                    id: "toggle-side-panel",
                    title: TaskCommandTitle.sidePanel(isShown: panels.trailingSurfaceID != nil),
                    subtitle: L10n.string("Review, browser, files and side chat beside the conversation."),
                    systemName: "sidebar.right",
                    action: { toggleTaskPanel(TaskSurfaceNavigationProjection.sidePanelToggleID) }
                ),
                CommandPaletteItem(
                    id: "toggle-terminal",
                    title: TaskCommandTitle.terminal(isShown: panels.isTerminalPresented),
                    subtitle: L10n.string("A shell in the task's folder below the conversation."),
                    systemName: "rectangle.bottomthird.inset.filled",
                    action: { toggleTaskPanel(TaskSurface.terminal.rawValue) }
                )
            ]
            // The new-task screen has no task for a rail.
            if commandTaskID != nil {
                panelItems.insert(CommandPaletteItem(
                    id: "toggle-session-rail",
                    title: sessionRail.toggleTitle(for: model.store.selectedSessionID),
                    subtitle: L10n.string("The task's environment, settings, context, changes and progress beside the conversation."),
                    systemName: "sidebar.squares.right",
                    action: toggleSessionRail
                ), at: 0)
            }
            items.insert(contentsOf: panelItems, at: min(3, items.count))
        }
        if let session = model.store.selectedSession {
            if session.status == .running || session.status == .waitingForApproval {
                items.append(
                    CommandPaletteItem(
                        id: "interrupt-\(session.id)",
                        title: L10n.string("Stop active task"),
                        subtitle: session.title,
                        systemName: "stop.circle",
                        action: { Task { await model.interrupt(session) } }
                    )
                )
            } else if !model.isAttached(session.id) {
                items.append(
                    CommandPaletteItem(
                        id: "resume-\(session.id)",
                        title: L10n.string("Resume task"),
                        subtitle: session.title,
                        systemName: "play.circle",
                        action: { Task { await model.resume(session) } }
                    )
                )
            }
            items.append(
                CommandPaletteItem(
                    id: "mark-read-\(session.id)",
                    title: L10n.string("Mark task as read"),
                    subtitle: session.title,
                    systemName: "checkmark.circle",
                    action: { Task { await model.store.markRead(id: session.id) } }
                )
            )
            if !session.hasUnreadUpdate {
                items.append(
                    CommandPaletteItem(
                        id: "mark-unread-\(session.id)",
                        title: L10n.string("Mark task as unread"),
                        subtitle: session.title,
                        systemName: "circlebadge",
                        action: { Task { await model.store.markUnread(id: session.id) } }
                    )
                )
            }
            if model.canBranch(session) {
                items.append(
                    CommandPaletteItem(
                        id: "fork-\(session.id)",
                        title: L10n.string("Fork task"),
                        subtitle: L10n.string("Create a new task from this conversation."),
                        systemName: "arrow.triangle.branch",
                        action: { Task { await model.branch(session) } }
                    )
                )
            }
            if model.canOpenOriginalConversation(in: session) {
                items.append(CommandPaletteItem(id: "original-\(session.id)",
                    title: L10n.string("Open original conversation"), subtitle: session.title,
                    systemName: "arrow.uturn.backward",
                    action: { Task { await model.openOriginalClaudeConversation(from: session) } }))
            }
            items.append(
                CommandPaletteItem(
                    id: "finder-\(session.id)",
                    title: L10n.string("Show in Finder"),
                    subtitle: session.workspaceURL.path(percentEncoded: false),
                    systemName: "folder",
                    action: {
                        NSWorkspace.shared.activateFileViewerSelecting([session.workspaceURL])
                    }
                )
            )
            // The palette lists commands, not submenus: one per project the task can move to.
            for command in TaskProjectMove.commands(projectMoveOptions(for: session)) {
                items.append(
                    CommandPaletteItem(
                        id: "\(command.id)-\(session.id)",
                        title: command.title,
                        subtitle: session.title,
                        systemName: command.destination == nil ? "folder.badge.minus" : "folder",
                        action: { moveTask(session, to: command.destination) }
                    )
                )
            }
        }
        return items
    }
}





extension HarnessKind {
    var shortDisplayName: String {
        HarnessCatalog.descriptor(for: self)?.shortName ?? displayName
    }
}

extension HarnessTransportKind {
    var displayName: String {
        switch self {
        case .codexAppServer: L10n.string("Codex App Server")
        case .claudeStreamJSON: L10n.string("Claude streaming JSON")
        case .msp: L10n.string("Muse Session Protocol")
        case .acp: L10n.string("Agent Client Protocol")
        case .piRPC: L10n.string("Pi JSONL RPC")
        case .cursorStreamJSON: L10n.string("Cursor streaming JSON")
        case .antigravityStreamJSON: L10n.string("Antigravity streaming JSON")
        }
    }
}
