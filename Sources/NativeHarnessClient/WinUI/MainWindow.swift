import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The Windows app's main window: the sidebar (`TaskSidebar`), and beside it the chosen task's conversation and its
/// composer (`TaskComposer`), New task (the Mac's home), or Settings. The composer sends through the model as the
/// Mac's does. Choosing a task reads its saved history as the Mac does (`refreshConversationStatus`, which starts no
/// turn), and its conversation draws through `ConversationTimeline` from the same projection the Mac's timeline reads.
/// Import conversation, a link on New task as on the Mac's home, continues a conversation a harness's own CLI or app
/// started, in a dialog over the window (`ImportConversationPane`). Settings
/// (`SettingsPane`) holds Settings › Remote, which lets another computer or a phone follow this one's tasks, and
/// Connect to a Mac, which pairs with another computer's Yardlet from the link it copies; each paired host opens in a
/// window of its own (`RemoteHostWindow`).
@MainActor
final class MainWindow {
    private let model: AppModel
    private let directory: RemoteHostDirectory
    private let log = QAEventLog.shared
    private let window = Window()
    /// The sidebar beside the content.
    private let root = Grid()
    /// What the sidebar chose: on Windows' layer over the window's Mica, rounded where it meets the sidebar and the title
    /// bar, as Windows 11's own apps set their content apart.
    private let content = Border()
    private var sidebar: TaskSidebar?
    private var actions: TaskActions?
    /// A task's header above its conversation and composer (`taskPane`), as the Mac's title bar heads a task.
    private let taskFrame = Grid()
    private var header: TaskHeader?
    private var keys: TaskKeys?
    private let timeline = ConversationTimeline()
    /// The shown task's composer, as the Mac's.
    private let composer: TaskComposer
    private var projectionCaches: [SessionRecord.ID: ConversationProjectionCache] = [:]
    /// The tasks whose saved history was read since the window opened.
    private var preparedSessionIDs: Set<SessionRecord.ID> = []
    /// Ends the observation of a conversation no longer shown.
    private var conversationGeneration = 0
    private var shownSessionID: SessionRecord.ID?
    private var loggedAnswer: String?
    private let taskPane = Grid()
    private var newTask: NewTaskPane?
    /// Signing in to a harness: under the harness chosen for a new task, and where a turn failed for its sign-in.
    private let signIn: HarnessSignIn
    private var importPane: ImportConversationPane?
    private var hostWindows: [String: RemoteHostWindow] = [:]
    private var settings: SettingsPane?
    /// What the window shows beside the sidebar. The model learns whether it shows a task, which decides, as on the
    /// Mac, whether a task's news is a notification.
    private enum Shown { case task, newTask, other }
    private var shown = Shown.task {
        didSet { model.setShowsTasks(shown == .task, inWindow: windowID) }
    }
    private let windowID = UUID()

    init(model: AppModel, directory: RemoteHostDirectory) {
        self.model = model
        self.directory = directory
        signIn = HarnessSignIn(model: model)
        composer = TaskComposer(model: model, log: QAEventLog.shared)
    }

    func open() {
        model.setShowsTasks(true, inWindow: windowID)
        try? window.appWindow.resize(SizeInt32(width: 1000, height: 680))

        let grid = taskPane
        let conversationRow = RowDefinition()
        conversationRow.height = GridLength(value: 1, gridUnitType: .star)
        let noticeRow = RowDefinition()
        noticeRow.height = GridLength(value: 0, gridUnitType: .auto)
        let composerRow = RowDefinition()
        composerRow.height = GridLength(value: 0, gridUnitType: .auto)
        grid.rowDefinitions.append(conversationRow)
        grid.rowDefinitions.append(noticeRow)
        grid.rowDefinitions.append(composerRow)
        grid.children.append(timeline.view)
        // Above the composer: a message being edited, then the composer's notice.
        let aboveComposer = StackPanel()
        aboveComposer.children.append(composer.editBanner)
        aboveComposer.children.append(composer.noticeView)
        try? Grid.setRow(aboveComposer, 1)
        grid.children.append(aboveComposer)
        try? Grid.setRow(composer.view, 2)
        grid.children.append(composer.view)
        composer.windowHandle = { [weak self] in self?.windowHandle ?? 0 }
        let newTask = NewTaskPane(model: model, log: log, signIn: signIn) { [weak self] in self?.windowHandle ?? 0 }
        newTask.onStarted = { [weak self] in self?.showSelectedTask() }
        newTask.onOpenTask = { [weak self] id in self?.show(.task(id)) }
        newTask.onImportConversation = { [weak self] in
            guard let self else { return }
            self.importPane?.present(over: self.root.xamlRoot)
        }
        self.newTask = newTask
        timeline.respond = { [weak self] request, response in self?.answer(request, response) }
        timeline.retry = { [weak self] turnID in self?.retry(turnID) }
        timeline.restoreRequest = { [weak self] draft in self?.restoreRequest(draft) }
        timeline.editMessage = { [weak self] turn in self?.editMessage(turn) }
        timeline.signIn = signIn
        let importPane = ImportConversationPane(model: model, log: log) { [weak self] in self?.windowHandle ?? 0 }
        importPane.onImported = { [weak self] in self?.showSelectedTask() }
        self.importPane = importPane

        let actions = TaskActions(model: model, log: log, host: { [weak self] in self?.root },
                                  windowHandle: { [weak self] in self?.windowHandle ?? 0 })
        self.actions = actions
        let sidebar = TaskSidebar(model: model, actions: actions)
        sidebar.onChoose = { [weak self] place in self?.show(place) }
        sidebar.onNewTaskInProject = { [weak self] folder in self?.showNewTask(in: folder) }
        sidebar.onAddProject = { [weak self] in self?.addProject() }
        self.sidebar = sidebar
        let header = TaskHeader(actions: actions)
        self.header = header
        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let row = RowDefinition()
            row.height = height
            taskFrame.rowDefinitions.append(row)
        }
        taskFrame.children.append(header.view)
        try? Grid.setRow(taskPane, 1)
        taskFrame.children.append(taskPane)
        let keys = TaskKeys(model: model, sidebar: sidebar, actions: actions)
        keys.shown = { [weak self] in
            guard let self, self.shown == .task, let session = self.selectedSession else { return (.home, nil) }
            return (.session(session.id), session)
        }
        keys.activate = { [weak self] item in
            switch item {
            case .home: self?.showHome()
            case let .session(id): self?.show(.task(id))
            case .split: break
            }
        }
        keys.newTask = { [weak self] in self?.showHome() }
        keys.openModelMenu = { [weak self] in self?.composer.openModelMenu() }
        keys.install(on: root)
        self.keys = keys
        SidebarStyle.columns(root, [SidebarStyle.auto, SidebarStyle.star])
        root.children.append(sidebar.view)
        content.background = Self.layerFill.brush
        content.borderBrush = SettingsCard.stroke.brush
        content.borderThickness = Thickness(left: 1, top: 1, right: 0, bottom: 0)
        content.cornerRadius = CornerRadius(topLeft: 8, topRight: 0, bottomRight: 0, bottomLeft: 0)
        content.child = taskFrame
        try? Grid.setColumn(content, 1)
        root.children.append(content)
        WindowChrome.frame(window, title: YardletProduct.name, content: root)
        // As on the Mac, the shown task's folder is looked at again when the app comes to the front.
        window.activated.addHandler { [weak self] _, _ in self?.composer.refreshFolder() }
        try? window.activate()

        Task {
            await model.restoreIndex()
            log.write("tasks: \(model.store.sessions.count)")
            // The task chosen last, as the Mac opens on it; with no task, New task, as the Mac opens its home.
            if let id = model.store.selectedSessionID ?? model.store.listedSessions.first?.id {
                show(.task(id))
            } else {
                showHome()
            }
        }
    }

    /// Windows' layer fill for an app's content over Mica (`LayerFillColorDefault`).
    private static let layerFill = ThemeColor(light: .paper(0.5), dark: UWP.Color(a: 0x4C, r: 0x3A, g: 0x3A, b: 0x3A))

    /// Shows what the sidebar chose.
    private func show(_ place: SidebarPlace) {
        switch place {
        case .home:
            showHome()
        case let .task(id):
            // Showing a task reads it, as the Mac's window does when its selection changes or it comes back to Tasks;
            // choosing the task already shown leaves a mark the person put back with Mark as unread.
            let reads = shown != .task || shownSessionID != id
            newTask?.hide()
            content.child = taskFrame
            shown = .task
            choose(id)
            if reads { Task { await model.store.markRead(id: id) } }
        case .settings:
            newTask?.hide()
            let pane = settings ?? makeSettings()
            content.child = pane.view
            shown = .other
            pane.show()
            log.write("showing settings")
        }
    }

    /// New task, the Mac's home, with the harness and the message as they were left.
    private func showHome() {
        guard let newTask else { return }
        content.child = newTask.view
        shown = .newTask
        sidebar?.choose(.home)
        newTask.show()
    }

    /// New task in a project, from its menu in the sidebar, as the Mac's.
    private func showNewTask(in folder: URL) {
        let project = model.projects.ensureProject(forRoot: folder)
        let draft = model.composerDrafts.home
        draft.projectID = project.id
        draft.workspaceURL = project.primaryRoot
        showHome()
    }

    /// The + beside Projects: a folder from Windows' folder dialog becomes a project, and New task opens in it, as the
    /// Mac's Add project does.
    private func addProject() {
        // The dialog runs modally until it closes, so it opens after the click returns.
        Task { @MainActor in
            guard let folder = WindowsFolderPicker.chooseFolder(window: windowHandle, title: L10n.string("Add project"))
            else { return }
            showNewTask(in: folder.standardizedFileURL)
        }
    }

    private func choose(_ id: SessionRecord.ID) {
        if model.store.selectedSessionID != id { model.store.selectedSessionID = id }
        sidebar?.choose(.task(id))
        if let session = selectedSession, preparedSessionIDs.insert(id).inserted {
            Task { await model.refreshConversationStatus(for: session) }
        }
        showConversation()
    }

    private var selectedSession: SessionRecord? {
        model.store.selectedSessionID.flatMap { id in model.store.sessions.first { $0.id == id } }
    }

    /// The chosen task's conversation, followed through Observation until another is shown.
    private func showConversation() {
        conversationGeneration += 1
        let generation = conversationGeneration
        let (session, presentation, error, hasTasks, notices) = withObservationTracking {
            let session = selectedSession
            return (session, session.map(presentation(of:)), session.flatMap { model.errorBySessionID[$0.id] },
                    !model.store.sessions.isEmpty, session.flatMap { model.providerNotices(for: $0) })
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.conversationGeneration else { return }
                self.showConversation()
            }
        }
        // A task that goes while it is shown (archived, deleted) leaves the window on New task, as the store leaves
        // the Mac's on its home.
        if session == nil, shown == .task {
            Task { @MainActor [weak self] in
                guard let self, self.shown == .task, self.selectedSession == nil else { return }
                self.showHome()
            }
        }
        header?.show(session)
        if session?.id != shownSessionID {
            shownSessionID = session?.id
            if let session { log.write("showing: \(session.title)") }
            composer.show(session?.id)
        }
        let placeholder = session != nil ? error : hasTasks ? L10n.string("Choose a task") : L10n.string("No tasks")
        timeline.workspaceURL = session?.workspaceURL
        timeline.notices = notices
        timeline.show(presentation, conversationID: session?.id.uuidString, placeholder: placeholder)
        if let latest = presentation?.turns.last.flatMap({ Self.latestText(of: $0) }) {
            let line = "answer\(latest.isStreaming ? " streaming" : ""): \(latest.text.prefix(80))"
            if line != loggedAnswer {
                loggedAnswer = line
                log.write(line)
            }
        }
    }

    /// The words a turn last streamed, for the event log: its latest answer, or while it works, the commentary
    /// that may become one.
    private static func latestText(of turn: ConversationTurn) -> (text: String, isStreaming: Bool)? {
        for item in (turn.work + turn.answers).reversed() {
            switch item.kind {
            case let .answer(text, isStreaming), let .commentary(text, isStreaming): return (text, isStreaming)
            default: continue
            }
        }
        return nil
    }

    /// A task's conversation as the Mac's timeline reads it: the Codex thread once it has turns, otherwise the
    /// shared transcript.
    private func presentation(of session: SessionRecord) -> ConversationPresentation {
        let cache = projectionCaches[session.id] ?? ConversationProjectionCache()
        projectionCaches[session.id] = cache
        if let state = AppModelRemoteBridge.codexState(of: session, in: model) {
            return cache.codex(state, workspaceURL: session.workspaceURL, historySelection: nil)
        }
        return cache.transcript(model.transcriptBySessionID[session.id] ?? [], harness: session.harness,
                                status: session.status, latestTurnIsComplete: session.completionState == .completed,
                                latestTurnWasCutOff: session.completionState == .interrupted)
    }

    /// A request's answer from its card, carried out as the Mac's card does (`ConversationActions.respond`); a form's
    /// answer comes with the route the card made of what was entered.
    private func answer(_ request: ConversationRequest, _ response: ConversationRequestResponse) {
        guard let session = selectedSession else { return }
        log.write("answered: \(response.title)")
        Task {
            switch response.route {
            case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
            case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
            case let .answer(answer): await model.respond(to: request.id, answer: answer, in: session)
            case let .codex(reply): await model.respondCodex(to: request.id, response: reply, in: session)
            case .structured: break
            }
        }
    }

    /// Retries the turn a busy server, a rate limit or a lost connection ended, as the Mac's error card does
    /// (`AppModel.retryTurn`).
    private func retry(_ turnID: String) {
        guard let session = selectedSession else { return }
        log.write("retry: \(turnID)")
        Task { await model.retryTurn(turnID, in: session) }
    }

    /// Puts a failed turn's request back in the composer without sending it, as the Mac's error card's Edit request
    /// does: the composer follows the task's draft.
    private func restoreRequest(_ draft: CodexComposerDraft) {
        guard let session = selectedSession else { return }
        log.write("edit request")
        model.composerDrafts.tasks.draft(for: session.id).restore(draft)
        model.composerDrafts.persistNow()
    }

    /// Starts editing a turn's message in the composer, as the Mac's Edit message does (`AppModel.beginCodexEdit`,
    /// `AppModel.beginClaudeEdit`): Codex's request of its latest turn, Claude Code's latest message. Sending the
    /// composer then sends the edit in its place; its banner cancels it.
    private func editMessage(_ turn: ConversationTurn) {
        guard let session = selectedSession else { return }
        log.write("edit message: \(turn.id)")
        if session.harness == .codex,
           let codexTurn = model.codexPresentationBySessionID[session.id]?.thread?.turns.first(where: { $0.id == turn.id }) {
            model.beginCodexEdit(codexTurn, in: session)
        } else if let target = turn.actions.editLatest {
            Task { await model.beginClaudeEdit(target.text, in: session) }
        } else if let draft = turn.actions.editDraft {
            // A request the harness cannot rewind to goes back to the composer, as the Mac's does.
            restoreRequest(draft)
        }
    }

    // MARK: New task

    /// The window's handle (`HWND`, which a window's ID holds): the owner of the dialogs Windows itself shows, such
    /// as the folder dialog, and the window a notification's click brings forward.
    var windowHandle: UInt64 {
        window.appWindow.id.value
    }

    /// The task the model chose, shown with its row chosen: one New task started, or one a notification's click
    /// opened.
    func showSelectedTask() {
        guard let id = model.store.selectedSessionID else { return showHome() }
        show(.task(id))
    }

    // MARK: Settings and other computers

    private func makeSettings() -> SettingsPane {
        let pane = SettingsPane(remote: model.remoteControl, directory: directory, log: log)
        pane.onOpenHost = { [weak self] hostID in self?.openHost(hostID) }
        pane.onRemoveHost = { [weak self] hostID in self?.hostWindows[hostID]?.close() }
        settings = pane
        return pane
    }

    /// The host's window, opened or brought forward; the main window keeps what it shows.
    private func openHost(_ hostID: String) {
        if let open = hostWindows[hostID] {
            open.bringForward()
            return
        }
        guard let hostModel = directory.model(for: hostID) else { return }
        let hostWindow = RemoteHostWindow(model: hostModel, log: log)
        hostWindow.onClose = { [weak self] in
            self?.hostWindows[hostID] = nil
            self?.directory.close(hostID)
        }
        hostWindows[hostID] = hostWindow
        hostWindow.open()
    }
}
