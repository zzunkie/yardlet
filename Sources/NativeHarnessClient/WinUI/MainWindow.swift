import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// The Windows app's main window: the engine's tasks in the sidebar, the chosen task's conversation,
/// and the composer. The sidebar follows the model's `SessionStore` through Observation, and the
/// composer sends through the model as the Mac's does. The conversation shows what this window sent
/// and the task's error until the Windows app reads transcripts.
@MainActor
final class MainWindow {
    private let model: AppModel
    private let log = QAEventLog()
    private let window = Window()
    private let navigation = NavigationView()
    private let conversation = StackPanel()
    private let scroller = ScrollViewer()
    private let composer = TextBox()
    private var items: [(item: NavigationViewItem, id: SessionRecord.ID)] = []
    private var sentBySessionID: [SessionRecord.ID: [String]] = [:]

    init(model: AppModel) {
        self.model = model
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
            guard let self, let container = args?.selectedItemContainer,
                  let id = self.items.first(where: { $0.item == container })?.id else { return }
            self.choose(id)
        }

        let grid = Grid()
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
