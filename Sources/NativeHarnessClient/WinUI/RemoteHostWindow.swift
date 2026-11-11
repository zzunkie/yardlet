import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Another computer's Yardlet in a window of its own (docs/REMOTE_PROTOCOL.md §18), as the Mac opens one from
/// File › Connect to Mac…: the host's tasks in the sidebar as the host lists them, the chosen task's
/// conversation as it streams, and the composer, which sends to the host. The window follows its
/// `RemoteHostModel` through Observation; closing it ends the connection.
@MainActor
final class RemoteHostWindow {
    private let model: RemoteHostModel
    private let log: QAEventLog
    private let window = Window()
    private let navigation = NavigationView()
    private let status = TextBlock()
    private let timeline = ConversationTimeline()
    private let composer = TextBox()
    private var items: [(item: NavigationViewItem, taskID: String)] = []
    /// What the sidebar draws, by section: its name, then each task's ID, title and harness.
    private var shownRows: [String]?
    private var shownTaskID: String?
    var onClose: (() -> Void)?

    init(model: RemoteHostModel, log: QAEventLog) {
        self.model = model
        self.log = log
    }

    func open() {
        window.title = model.name
        try? window.appWindow.resize(SizeInt32(width: 1000, height: 680))
        window.closed.addHandler { [weak self] _, _ in self?.onClose?() }

        navigation.paneDisplayMode = .left
        navigation.isSettingsVisible = false
        navigation.isBackButtonVisible = .collapsed
        navigation.isPaneToggleButtonVisible = false
        navigation.openPaneLength = 300
        navigation.selectionChanged.addHandler { [weak self] _, args in
            guard let self, let container = args?.selectedItemContainer,
                  let taskID = self.items.first(where: { $0.item == container })?.taskID else { return }
            self.model.select(.task(taskID))
        }

        let grid = Grid()
        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                       GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            grid.rowDefinitions.append(row)
        }
        status.fontSize = 12
        status.opacity = 0.6
        status.margin = Thickness(left: 28, top: 12, right: 28, bottom: 0)
        grid.children.append(status)
        try? Grid.setRow(timeline.view, 1)
        grid.children.append(timeline.view)
        composer.textWrapping = .wrap
        composer.margin = Thickness(left: 28, top: 8, right: 28, bottom: 20)
        try? Grid.setRow(composer, 2)
        grid.children.append(composer)
        composer.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter else { return }
            args.handled = true
            self.send()
        }
        navigation.content = grid
        window.content = navigation
        try? window.activate()
        timeline.loadEarlier = { [weak self] in
            guard let self, let taskID = self.selectedTaskID else { return }
            self.model.loadOlder(taskID)
        }

        followConnection()
        followTasks()
        followConversation()
    }

    func bringForward() {
        try? window.activate()
    }

    /// Closes the window, as its close button does.
    func close() {
        try? window.close()
    }

    private func followConnection() {
        let connection = withObservationTracking {
            model.connection
        } onChange: { [weak self] in
            Task { @MainActor in self?.followConnection() }
        }
        let line = RemoteConnectionText.line(connection)
        status.text = line
        log.write("remote connection: \(line)")
    }

    private func followTasks() {
        let sidebar = withObservationTracking {
            model.hasSnapshot ? model.sidebar : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTasks() }
        }
        guard let sidebar else { return }
        // A task's marks and times change as it streams; the sidebar is drawn again only when what it shows does.
        let sections = Self.sections(of: sidebar)
        let rows = sections.flatMap { name, sessions in [name] + sessions.map { "\($0.id)\n\($0.title)\n\($0.harness.rawValue)" } }
        guard rows != shownRows else { return }
        shownRows = rows
        showSidebar(sections)
    }

    private static func sections(of sidebar: RemoteSidebarMirror) -> [(name: String, sessions: [SessionRecord])] {
        sidebar.groups.map { ($0.displayName, $0.sessions) }
            + (sidebar.chats.isEmpty ? [] : [(L10n.string("Chats"), sidebar.chats)])
    }

    /// The host's projects with their tasks, then its chats, as the host's sidebar lists them.
    private func showSidebar(_ sections: [(name: String, sessions: [SessionRecord])]) {
        let taskIDs = Dictionary(model.tasks.map { (RemoteSidebarMirror.sessionID(for: $0.id), $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        let selected: String? = if case let .task(id) = model.selection { id } else { nil }
        navigation.menuItems.clear()
        items = []
        var selectedItem: NavigationViewItem?
        for (name, sessions) in sections {
            let header = NavigationViewItemHeader()
            header.content = name
            navigation.menuItems.append(header)
            for session in sessions {
                guard let taskID = taskIDs[session.id] else { continue }
                let item = NavigationViewItem()
                item.content = Self.label(title: session.title, detail: session.harness.displayName)
                navigation.menuItems.append(item)
                items.append((item: item, taskID: taskID))
                if taskID == selected { selectedItem = item }
            }
        }
        log.write("remote tasks: \(items.count)")
        navigation.selectedItem = selectedItem
    }

    private static func label(title: String, detail: String) -> StackPanel {
        let titleText = TextBlock()
        titleText.text = title
        let detailText = TextBlock()
        detailText.text = detail
        detailText.fontSize = 12
        detailText.opacity = 0.6
        let label = StackPanel()
        label.children.append(titleText)
        label.children.append(detailText)
        return label
    }

    private var selectedTaskID: String? {
        if case let .task(id) = model.selection { id } else { nil }
    }

    private func followConversation() {
        let (taskID, presentation, hasSnapshot) = withObservationTracking {
            let taskID = selectedTaskID
            return (taskID, taskID.flatMap { model.conversations[$0]?.presentation }, model.hasSnapshot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followConversation() }
        }
        let placeholder = hasSnapshot ? L10n.string("Choose a task") : L10n.format("Connecting to %@…", model.name)
        timeline.show(presentation, conversationID: taskID, placeholder: taskID == nil ? placeholder : nil,
                      requestNote: L10n.format("Answer this on %@.", model.name))
        if let taskID, let task = model.task(taskID) {
            composer.placeholderText = L10n.format("Ask %@…", task.harnessName)
            if taskID != shownTaskID { log.write("remote showing: \(task.title)") }
            if let answer = presentation?.turns.last?.answers.last, case let .answer(text, isStreaming) = answer.kind {
                log.write("remote answer\(isStreaming ? " streaming" : ""): \(text.prefix(80))")
            }
        } else {
            composer.placeholderText = L10n.string("Choose a task")
        }
        shownTaskID = taskID
    }

    private func send() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let taskID = selectedTaskID else { return }
        log.write("remote sent: \(text)")
        composer.text = ""
        Task {
            guard await model.perform(.sendMessage(taskID: taskID, text: text)) else {
                // What did not go stays in the composer, with why.
                if composer.text.isEmpty { composer.text = text }
                status.text = model.commandError ?? RemoteConnectionText.line(model.connection)
                return
            }
        }
    }
}
