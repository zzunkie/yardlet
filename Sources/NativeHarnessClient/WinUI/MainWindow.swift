import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The Windows app's main window: the engine's tasks in the sidebar, the chosen task's conversation,
/// and the composer. The sidebar follows the model's `SessionStore` through Observation, and the
/// composer sends through the model as the Mac's does. Choosing a task reads its saved history as the Mac does
/// (`refreshConversationStatus`, which starts no turn), and its conversation draws through `ConversationTimeline`
/// from the same projection the Mac's timeline reads. Below the tasks, Connect to a Mac pairs with
/// another computer's Yardlet from the link it copies, and each paired host opens in a window of its own
/// (`RemoteHostWindow`).
@MainActor
final class MainWindow {
    private let model: AppModel
    private let directory: RemoteHostDirectory
    private let log = QAEventLog.shared
    private let window = Window()
    private let navigation = NavigationView()
    private let timeline = ConversationTimeline()
    private let composer = TextBox()
    private var items: [(item: NavigationViewItem, id: SessionRecord.ID)] = []
    private var projectionCaches: [SessionRecord.ID: ConversationProjectionCache] = [:]
    /// The tasks whose saved history was read since the window opened.
    private var preparedSessionIDs: Set<SessionRecord.ID> = []
    /// Ends the observation of a conversation no longer shown.
    private var conversationGeneration = 0
    private var shownSessionID: SessionRecord.ID?
    private var loggedAnswer: String?
    private let taskPane = Grid()
    private let newTaskItem = NavigationViewItem()
    private let newTaskPane = StackPanel()
    private let harnessList = ListView()
    private let newTaskPrompt = TextBox()
    private let newTaskStatus = TextBlock()
    /// The harnesses the new task list shows, in its order.
    private var newTaskHarnesses: [HarnessKind] = []
    private var lookedForRuntimes = false
    private let connectItem = NavigationViewItem()
    private var hostItems: [(item: NavigationViewItem, id: String)] = []
    private var hostWindows: [String: RemoteHostWindow] = [:]
    private let connectPane = StackPanel()
    private let linkField = TextBox()
    private let connectButton = Button()
    private let connectStatus = TextBlock()

    init(model: AppModel, directory: RemoteHostDirectory) {
        self.model = model
        self.directory = directory
    }

    func open() {
        window.title = YardletProduct.name
        try? window.appWindow.resize(SizeInt32(width: 1000, height: 680))

        navigation.paneDisplayMode = .left
        navigation.isSettingsVisible = false
        navigation.isBackButtonVisible = .collapsed
        navigation.isPaneToggleButtonVisible = false
        navigation.openPaneLength = 300
        // XAML hands back a new Swift wrapper for an item, so the chosen one is found with the
        // bindings' ==, which compares the COM objects underneath.
        navigation.selectionChanged.addHandler { [weak self] _, args in
            guard let self, let container = args?.selectedItemContainer else { return }
            if container == self.newTaskItem {
                self.navigation.content = self.newTaskPane
                self.showNewTask()
            } else if container == self.connectItem {
                self.navigation.content = self.connectPane
            } else if let hostID = self.hostItems.first(where: { $0.item == container })?.id {
                self.openHost(hostID)
            } else if let id = self.items.first(where: { $0.item == container })?.id {
                self.navigation.content = self.taskPane
                self.choose(id)
            }
        }

        let grid = taskPane
        let conversationRow = RowDefinition()
        conversationRow.height = GridLength(value: 1, gridUnitType: .star)
        let composerRow = RowDefinition()
        composerRow.height = GridLength(value: 0, gridUnitType: .auto)
        grid.rowDefinitions.append(conversationRow)
        grid.rowDefinitions.append(composerRow)
        grid.children.append(timeline.view)
        composer.textWrapping = .wrap
        composer.margin = Thickness(left: 28, top: 8, right: 28, bottom: 20)
        try? Grid.setRow(composer, 1)
        grid.children.append(composer)
        observeComposer()
        navigation.content = grid
        makeConnectPane()
        makeNewTaskPane()
        newTaskItem.content = L10n.string("New task")
        timeline.respond = { [weak self] request, response in self?.answer(request, response) }
        connectItem.content = L10n.string("Connect to a Mac")
        navigation.footerMenuItems.append(connectItem)
        followHosts()
        window.content = navigation
        try? window.activate()

        Task {
            await model.restoreIndex()
            log.write("tasks: \(model.store.sessions.count)")
            followTasks()
        }
    }

    private func followTasks() {
        let sessions = withObservationTracking {
            model.store.sessions
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTasks() }
        }
        showSidebar(sessions)
    }

    private func showSidebar(_ sessions: [SessionRecord]) {
        let ordered = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        let selected = model.store.selectedSessionID ?? ordered.first?.id
        navigation.menuItems.clear()
        navigation.menuItems.append(newTaskItem)
        items = []
        var selectedItem: NavigationViewItem?
        for session in ordered {
            // As the Mac's rows show a title Yardlet made: without the folder name it starts with, which a chat's
            // (`new-chat`) does not need and a project task's shows beside the harness instead.
            let folder = session.workspaceURL.lastPathComponent
            let title = TextBlock()
            title.text = SessionTitleProjection.titleUnderProject(session, projectNames: [folder])
            let detail = TextBlock()
            detail.text = ((model.projects.isChatFolder(session.workspaceURL) ? [] : [folder])
                + [session.harness.displayName, Self.activityText(session.updatedAt, now: now)]).joined(separator: " · ")
            detail.fontSize = 12
            detail.opacity = 0.6
            let label = StackPanel()
            label.children.append(title)
            label.children.append(detail)
            let item = NavigationViewItem()
            item.content = label
            navigation.menuItems.append(item)
            items.append((item: item, id: session.id))
            if session.id == selected { selectedItem = item }
        }
        navigation.selectedItem = selectedItem
        if let selected { choose(selected) } else { showConversation() }
    }

    private static func activityText(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? RelativeTime.now() : RelativeTime.ago(date, relativeTo: now)
    }

    private func choose(_ id: SessionRecord.ID) {
        if model.store.selectedSessionID != id { model.store.selectedSessionID = id }
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
        let (session, presentation, error, hasTasks) = withObservationTracking {
            let session = selectedSession
            return (session, session.map(presentation(of:)), session.flatMap { model.errorBySessionID[$0.id] },
                    !model.store.sessions.isEmpty)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.conversationGeneration else { return }
                self.showConversation()
            }
        }
        if session?.id != shownSessionID {
            shownSessionID = session?.id
            if let session { log.write("showing: \(session.title)") }
            composer.placeholderText = session.map { L10n.format("Ask %@…", $0.harness.displayName) }
                ?? L10n.string("Choose a task")
        }
        let placeholder = session != nil ? error : hasTasks ? L10n.string("Choose a task") : L10n.string("No tasks")
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
                                status: session.status, latestTurnIsComplete: session.completionState == .completed)
    }

    // Enter sends what the composer shows, the syllable being composed included: with the Microsoft
    // Korean IME the composer's text already holds it when Enter comes in, and no composition end
    // follows (Windows/scripts/check-window.ps1 types through the IME to check this).
    private func observeComposer() {
        composer.loaded.addHandler { [weak self] _, _ in
            guard let self else { return }
            _ = try? self.composer.focus(.programmatic)
            self.log.write("ready")
        }
        composer.textCompositionStarted.addHandler { [weak self] _, _ in
            self?.log.write("composition started")
        }
        composer.textCompositionChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.log.write("composition changed: \(self.composer.text)")
        }
        composer.textCompositionEnded.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.log.write("composition ended: \(self.composer.text)")
        }
        composer.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter else { return }
            args.handled = true
            self.send()
        }
    }

    private func send() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        log.write("sent: \(text)")
        composer.text = ""
        guard let session = selectedSession else { return }
        Task { await model.send(text, to: session) }
    }

    /// A request's answer from its card, carried out as the Mac's card does (`ConversationActions.respond`).
    private func answer(_ request: ConversationRequest, _ response: ConversationRequestResponse) {
        guard let session = selectedSession else { return }
        log.write("answered: \(response.title)")
        Task {
            switch response.route {
            case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
            case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
            case let .codex(reply): await model.respondCodex(to: request.id, response: reply, in: session)
            case .answer, .structured: break
            }
        }
    }

    // MARK: New task

    /// The harnesses whose CLI Yardlet found on this computer, and the message the task starts with. A new task
    /// is a chat, in a folder made for it, until the Windows app can choose a project.
    private func makeNewTaskPane() {
        newTaskPane.spacing = 12
        newTaskPane.padding = Thickness(left: 28, top: 28, right: 28, bottom: 28)
        newTaskPane.maxWidth = 560
        newTaskPane.horizontalAlignment = .left
        let title = TextBlock()
        title.text = L10n.string("New task")
        title.fontSize = 20
        newTaskPane.children.append(title)
        let harnessTitle = TextBlock()
        harnessTitle.text = L10n.string("Harness")
        harnessTitle.opacity = 0.7
        newTaskPane.children.append(harnessTitle)
        harnessList.selectionMode = .single
        harnessList.selectionChanged.addHandler { [weak self] _, _ in self?.showNewTaskPrompt() }
        newTaskPane.children.append(harnessList)
        newTaskPrompt.textWrapping = .wrap
        newTaskPrompt.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter else { return }
            args.handled = true
            self.startTask()
        }
        newTaskPane.children.append(newTaskPrompt)
        newTaskStatus.textWrapping = .wrap
        newTaskStatus.opacity = 0.7
        newTaskPane.children.append(newTaskStatus)
    }

    private func showNewTask() {
        let descriptors = model.runtimeSelections.connectedDescriptors
        newTaskHarnesses = descriptors.map(\.id)
        harnessList.items.clear()
        for descriptor in descriptors { harnessList.items.append(descriptor.displayName) }
        harnessList.selectedIndex = descriptors.isEmpty ? -1 : 0
        newTaskStatus.text = descriptors.isEmpty ? L10n.string("Choose or install a runtime first.") : ""
        log.write("new task harnesses: \(descriptors.map(\.displayName).joined(separator: ", "))")
        showNewTaskPrompt()
        // The installs are looked for once, when the list first comes up empty.
        guard descriptors.isEmpty, !lookedForRuntimes else { return }
        lookedForRuntimes = true
        Task {
            await model.runtimeSelections.findNewest()
            if !model.runtimeSelections.connectedDescriptors.isEmpty { showNewTask() }
        }
    }

    private var chosenHarness: HarnessKind? {
        let index = Int(harnessList.selectedIndex)
        return newTaskHarnesses.indices.contains(index) ? newTaskHarnesses[index] : nil
    }

    private func showNewTaskPrompt() {
        newTaskPrompt.placeholderText = chosenHarness.map { L10n.format("What should %@ work on?", $0.displayName) } ?? ""
    }

    private func startTask() {
        let text = newTaskPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let harness = chosenHarness else { return }
        guard let runtime = model.runtimeSelections.selectedURL(for: harness) else {
            newTaskStatus.text = L10n.format("%@ is not available in Yardlet.", harness.displayName)
            return
        }
        newTaskPrompt.text = ""
        newTaskStatus.text = ""
        log.write("new task: \(harness.displayName)")
        let submission = NewTaskDraft.Submission(originalText: text, attachments: [], harness: harness, workspaceURL: nil,
                                                 projectID: nil, runtimeURL: runtime)
        let previousError = model.bootstrapError
        Task {
            do {
                if try await model.createTask(submission) != nil {
                    navigation.content = taskPane
                    log.write("new task started")
                } else {
                    newTaskStatus.text = (model.bootstrapError != previousError ? model.bootstrapError : nil)
                        ?? L10n.string("The task could not start.")
                }
            } catch {
                newTaskStatus.text = error.localizedDescription
            }
        }
    }

    // MARK: Other computers

    /// The hosts paired before, one footer item each, as the Mac lists them under File › Connect to Mac….
    private func followHosts() {
        let hosts = withObservationTracking {
            directory.hosts
        } onChange: { [weak self] in
            Task { @MainActor in self?.followHosts() }
        }
        for (item, _) in hostItems {
            var index: UInt32 = 0
            if navigation.footerMenuItems.indexOf(item, &index) { navigation.footerMenuItems.removeAt(index) }
        }
        hostItems = hosts.map { host in
            let item = NavigationViewItem()
            item.content = host.name
            navigation.footerMenuItems.append(item)
            return (item: item, id: host.id)
        }
    }

    private func makeConnectPane() {
        connectPane.spacing = 12
        connectPane.padding = Thickness(left: 28, top: 28, right: 28, bottom: 28)
        connectPane.maxWidth = 560
        connectPane.horizontalAlignment = .left
        let title = TextBlock()
        title.text = L10n.string("Connect to a Mac")
        title.fontSize = 20
        connectPane.children.append(title)
        let explanation = TextBlock()
        explanation.text = L10n.string("Follow and drive another Mac's tasks here. On that Mac, open Settings › Remote, choose Pair…, then Copy link, and paste the link below.")
        explanation.textWrapping = .wrap
        explanation.opacity = 0.7
        connectPane.children.append(explanation)
        linkField.placeholderText = L10n.string("Connection link")
        connectPane.children.append(linkField)
        connectButton.content = L10n.string("Connect")
        connectButton.click.addHandler { [weak self] _, _ in self?.connect() }
        connectPane.children.append(connectButton)
        connectStatus.textWrapping = .wrap
        connectStatus.opacity = 0.7
        connectPane.children.append(connectStatus)
    }

    /// Pairs with the host the pasted link names; nothing pairs until Connect is chosen.
    private func connect() {
        let link = linkField.text
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connectButton.isEnabled = false
        connectStatus.text = L10n.string("Connecting…")
        log.write("remote pairing")
        Task {
            defer { connectButton.isEnabled = true }
            do {
                let host = try await directory.pair(link: link)
                log.write("remote paired: \(host.name)")
                linkField.text = ""
                connectStatus.text = ""
                openHost(host.id)
            } catch let failure as RemoteHostDirectory.PairingFailure {
                log.write("remote pairing failed: \(failure.message)")
                connectStatus.text = failure.message
            } catch {
                connectStatus.text = error.localizedDescription
            }
        }
    }

    /// The host's window, opened or brought forward; the sidebar keeps the task it showed.
    private func openHost(_ hostID: String) {
        navigation.selectedItem = items.first { $0.id == model.store.selectedSessionID }?.item
        navigation.content = taskPane
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
