import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The Windows app's main window: the engine's tasks in the sidebar, the chosen task's conversation,
/// and the composer. The sidebar follows the model's `SessionStore` through Observation, and the
/// composer sends through the model as the Mac's does. The conversation shows what this window sent
/// and the task's error until the Windows app reads transcripts. Below the tasks, Connect to a Mac pairs with
/// another computer's Yardlet from the link it copies, and each paired host opens in a window of its own
/// (`RemoteHostWindow`).
@MainActor
final class MainWindow {
    private let model: AppModel
    private let directory: RemoteHostDirectory
    private let log = QAEventLog.shared
    private let window = Window()
    private let navigation = NavigationView()
    private let conversation = StackPanel()
    private let scroller = ScrollViewer()
    private let composer = TextBox()
    private var items: [(item: NavigationViewItem, id: SessionRecord.ID)] = []
    private var sentBySessionID: [SessionRecord.ID: [String]] = [:]
    private let taskPane = Grid()
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
            if container == self.connectItem {
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
        conversation.spacing = 16
        scroller.padding = Thickness(left: 28, top: 20, right: 28, bottom: 12)
        scroller.content = conversation
        grid.children.append(scroller)
        composer.textWrapping = .wrap
        composer.margin = Thickness(left: 28, top: 8, right: 28, bottom: 20)
        try? Grid.setRow(composer, 1)
        grid.children.append(composer)
        observeComposer()
        navigation.content = grid
        makeConnectPane()
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
        items = []
        var selectedItem: NavigationViewItem?
        for session in ordered {
            let title = TextBlock()
            title.text = session.title
            let detail = TextBlock()
            detail.text = "\(session.harness.displayName) · \(Self.activityText(session.updatedAt, now: now))"
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
        showConversation()
    }

    private var selectedSession: SessionRecord? {
        model.store.selectedSessionID.flatMap { id in model.store.sessions.first { $0.id == id } }
    }

    private func showConversation() {
        let session = selectedSession
        if let session { log.write("showing: \(session.title)") }
        composer.placeholderText = session.map { L10n.format("Ask %@…", $0.harness.displayName) }
            ?? L10n.string("Choose a task")
        conversation.children.clear()
        guard let session else {
            if model.store.sessions.isEmpty { appendMessage(role: nil, text: L10n.string("No tasks")) }
            return
        }
        for text in sentBySessionID[session.id] ?? [] {
            appendMessage(role: L10n.string("You"), text: text)
        }
        if let error = model.errorBySessionID[session.id] {
            appendMessage(role: nil, text: error)
        }
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
        sentBySessionID[session.id, default: []].append(text)
        showConversation()
        Task {
            await model.send(text, to: session)
            showConversation()
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

    private func appendMessage(role: String?, text: String) {
        let block = StackPanel()
        block.spacing = 4
        if let role {
            let roleText = TextBlock()
            roleText.text = role
            roleText.fontSize = 12
            roleText.opacity = 0.6
            block.children.append(roleText)
        }
        let body = TextBlock()
        body.text = text
        body.fontSize = 14
        body.textWrapping = .wrap
        body.isTextSelectionEnabled = true
        block.children.append(body)
        conversation.children.append(block)
        _ = try? scroller.changeView(nil, 1_000_000, nil)
    }
}
