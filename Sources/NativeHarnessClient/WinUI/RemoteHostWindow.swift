import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Another computer's Yardlet in a window of its own (docs/REMOTE_PROTOCOL.md §18), as the Mac's host window
/// (`RemoteHostWindow`): its title the host's name, with how the host is reached beside it (`RemoteConnectionText`), the
/// host's tasks in the sidebar as the host lists them, under Home, New task on the host, where the host can start one;
/// and beside them a line while the host cannot be reached (`RemoteConnectionBanner`) over the chosen task
/// (`RemoteTaskPane`), New task on the host (`RemoteNewTaskPane`), or while neither is chosen, that the window is
/// connecting or what to choose. A host this computer no longer pairs with leaves the window saying so. The window
/// follows its `RemoteHostModel` through Observation; closing it ends the connection.
@MainActor
final class RemoteHostWindow {
    private let model: RemoteHostModel
    private let directory: RemoteHostDirectory
    private let log: QAEventLog
    private let window = Window()
    private let navigation = NavigationView()
    /// How the host is reached, after the window's title.
    private let connectionLine = TextBlock()
    /// Beside the sidebar: the task's header (not drawn yet), the connection's banner, and the task or the placeholder.
    private let detail = Grid()
    private let body = Border()
    private let banner: RemoteConnectionBanner
    private let pane: RemoteTaskPane
    private let newTask: RemoteNewTaskPane
    /// Each task's unsent words and the message it edits, kept in the host's cache folder.
    private let drafts = RemoteComposerDrafts()
    private let placeholder = StackPanel()
    private let placeholderText = TextBlock()
    private let placeholderRefusal = TextBlock()
    /// New task, under the placeholder's words while the host can start one, as the Mac's.
    private var placeholderNewTask = Button()
    private let unpaired = StackPanel()
    /// What the detail shows now.
    private var showing: Showing?
    private enum Showing { case task, newTask, placeholder, unpaired }
    private var items: [(item: NavigationViewItem, taskID: String)] = []
    /// New task on the host, at the top of the list while the host can start one. The sidebar's own Home takes its
    /// place once the window draws the Mac's sidebar.
    private var homeItem: NavigationViewItem?
    /// What the sidebar draws, by section: its name, then each task's ID, title and harness.
    private var shownRows: [String]?
    var onClose: (() -> Void)?

    init(model: RemoteHostModel, directory: RemoteHostDirectory, log: QAEventLog) {
        self.model = model
        self.directory = directory
        self.log = log
        banner = RemoteConnectionBanner(model: model, directory: directory, log: log)
        pane = RemoteTaskPane(model: model, drafts: drafts, log: log)
        newTask = RemoteNewTaskPane(model: model, drafts: drafts, log: log)
    }

    func open() {
        try? window.appWindow.resize(SizeInt32(width: 1000, height: 680))
        window.closed.addHandler { [weak self] _, _ in
            self?.drafts.save()
            self?.onClose?()
        }

        navigation.paneDisplayMode = .left
        navigation.isSettingsVisible = false
        navigation.isBackButtonVisible = .collapsed
        navigation.isPaneToggleButtonVisible = false
        navigation.openPaneLength = 300
        navigation.selectionChanged.addHandler { [weak self] _, args in
            guard let self, let container = args?.selectedItemContainer else { return }
            if let home = self.homeItem, container == home {
                self.model.select(.newTask)
            } else if let taskID = self.items.first(where: { $0.item == container })?.taskID {
                self.model.select(.task(taskID))
            }
        }

        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 1, gridUnitType: .star)] {
            let row = RowDefinition()
            row.height = height
            detail.rowDefinitions.append(row)
        }
        try? Grid.setRow(banner.view, 1)
        detail.children.append(banner.view)
        try? Grid.setRow(body, 2)
        detail.children.append(body)
        makePlaceholders()
        navigation.content = detail
        pane.windowHandle = { [weak self] in self?.window.appWindow.id.value ?? 0 }
        newTask.windowHandle = { [weak self] in self?.window.appWindow.id.value ?? 0 }
        drafts.restore(from: model.cacheFolder)
        WindowChrome.frame(window, title: model.name, subtitle: connectionLine, content: navigation)
        try? window.activate()

        followConnection()
        followTasks()
        followDetail()
    }

    func bringForward() {
        try? window.activate()
    }

    /// Closes the window, as its close button does.
    func close() {
        try? window.close()
    }

    /// How the host is reached, beside the window's title as the Mac's window subtitle says it.
    private func followConnection() {
        let connection = withObservationTracking {
            model.connection
        } onChange: { [weak self] in
            Task { @MainActor in self?.followConnection() }
        }
        let line = RemoteConnectionText.line(connection)
        connectionLine.text = line
        log.write("remote connection: \(line)")
    }

    private func followTasks() {
        let (sidebar, startsTasks) = withObservationTracking {
            (model.hasSnapshot ? model.sidebar : nil, model.newTask != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTasks() }
        }
        guard let sidebar else { return }
        // A task's marks and times change as it streams; the sidebar is drawn again only when what it shows does.
        let sections = Self.sections(of: sidebar)
        let rows = [startsTasks ? "home" : ""]
            + sections.flatMap { name, sessions in [name] + sessions.map { "\($0.id)\n\($0.title)\n\($0.harness.rawValue)" } }
        guard rows != shownRows else { return }
        shownRows = rows
        showSidebar(sections, startsTasks: startsTasks)
    }

    private static func sections(of sidebar: RemoteSidebarMirror) -> [(name: String, sessions: [SessionRecord])] {
        sidebar.groups.map { ($0.displayName, $0.sessions) }
            + (sidebar.chats.isEmpty ? [] : [(L10n.string("Chats"), sidebar.chats)])
    }

    /// Home, while the host can start a task, then the host's projects with their tasks, then its chats, as the
    /// host's sidebar lists them.
    private func showSidebar(_ sections: [(name: String, sessions: [SessionRecord])], startsTasks: Bool) {
        let taskIDs = Dictionary(model.tasks.map { (RemoteSidebarMirror.sessionID(for: $0.id), $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        navigation.menuItems.clear()
        items = []
        homeItem = nil
        if startsTasks {
            let home = NavigationViewItem()
            let mark = FontIcon()
            mark.glyph = "\u{E80F}"
            home.icon = mark
            home.content = L10n.string("Home")
            try? AutomationProperties.setName(home, L10n.string("Home"))
            navigation.menuItems.append(home)
            homeItem = home
        }
        for (name, sessions) in sections {
            let header = NavigationViewItemHeader()
            header.content = name
            navigation.menuItems.append(header)
            for session in sessions {
                guard let taskID = taskIDs[session.id] else { continue }
                let item = NavigationViewItem()
                item.content = Self.label(title: session.title, detail: session.harness.displayName)
                try? AutomationProperties.setName(item, session.title)
                navigation.menuItems.append(item)
                items.append((item: item, taskID: taskID))
            }
        }
        log.write("remote tasks: \(items.count)")
        markSelection()
    }

    /// The list's chosen row is what the detail shows: Home for New task, else the task's row.
    private func markSelection() {
        let item: NavigationViewItem? = switch model.selection {
        case .newTask: homeItem
        case let .task(id): items.first { $0.taskID == id }?.item
        default: nil
        }
        navigation.selectedItem = item
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

    // MARK: Detail

    /// The chosen task, or with none, that the window connects or what to choose there, as the Mac's detail shows it;
    /// once the host is no longer paired, only that.
    private func followDetail() {
        let (taskID, isNewTask, isPaired, hasSnapshot, startsTasks, refusal) = withObservationTracking {
            let taskID = selectedTaskID.flatMap { model.conversations[$0] == nil ? nil : $0 }
            return (taskID, model.selection == .newTask, directory.host(model.id) != nil, model.hasSnapshot,
                    model.newTask != nil, model.commandError)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followDetail() }
        }
        guard isPaired else {
            if showing != .unpaired {
                if showing == .newTask { newTask.hide() }
                showing = .unpaired
                navigation.isPaneVisible = false
                navigation.content = unpaired
                pane.show(nil)
                log.write("remote unpaired: \(model.name)")
            }
            return
        }
        markSelection()
        if let taskID {
            if showing == .newTask { newTask.hide() }
            if showing != .task {
                showing = .task
                body.child = pane.view
            }
            pane.show(taskID)
        } else if isNewTask {
            // The new task draws what the host refused under its own composer.
            pane.show(nil)
            if showing != .newTask {
                showing = .newTask
                body.child = newTask.view
                newTask.show()
            }
        } else {
            pane.show(nil)
            if showing == .newTask { newTask.hide() }
            if showing != .placeholder {
                showing = .placeholder
                body.child = placeholder
            }
            placeholderText.text = hasSnapshot ? L10n.format("Choose a task on %@, or start a new one.", model.name)
                : L10n.format("Connecting to %@…", model.name)
            placeholderNewTask.visibility = hasSnapshot && startsTasks ? .visible : .collapsed
            placeholderRefusal.text = refusal ?? ""
            placeholderRefusal.visibility = (refusal ?? "").isEmpty ? .collapsed : .visible
        }
    }

    /// The detail with no task chosen, a monitor over what the window waits for, and the window once the host is no
    /// longer paired, as the Mac's draw them.
    private func makePlaceholders() {
        placeholder.spacing = 10
        placeholder.horizontalAlignment = .center
        placeholder.verticalAlignment = .center
        let mark = ConversationStyle.icon("\u{E7F4}", size: 22, brush: WindowsTheme.tertiaryText.brush)
        mark.horizontalAlignment = .center
        placeholder.children.append(mark)
        placeholderText.fontSize = ConversationStyle.calloutSize
        placeholderText.foreground = WindowsTheme.secondaryText.brush
        placeholderText.textAlignment = .center
        placeholder.children.append(placeholderText)
        placeholderNewTask = ConversationStyle.grayButton(L10n.string("New task")) { [weak self] in
            self?.model.select(.newTask)
        }
        placeholderNewTask.fontSize = 12
        placeholderNewTask.padding = Thickness(left: 10, top: 3, right: 10, bottom: 4)
        placeholderNewTask.horizontalAlignment = .center
        placeholderNewTask.visibility = .collapsed
        placeholder.children.append(placeholderNewTask)
        placeholderRefusal.fontSize = 12
        placeholderRefusal.foreground = ComposerParts.orange.brush
        placeholderRefusal.textWrapping = .wrap
        placeholderRefusal.textAlignment = .center
        placeholderRefusal.maxWidth = 420
        placeholderRefusal.visibility = .collapsed
        placeholder.children.append(placeholderRefusal)

        unpaired.spacing = 8
        unpaired.horizontalAlignment = .center
        unpaired.verticalAlignment = .center
        let warning = ConversationStyle.icon(ConversationStyle.Glyph.warning, size: 22, brush: WindowsTheme.tertiaryText.brush)
        warning.horizontalAlignment = .center
        unpaired.children.append(warning)
        let title = ConversationStyle.text(L10n.string("This Mac is no longer paired."), size: ConversationStyle.calloutSize,
                                           semibold: true)
        title.textAlignment = .center
        unpaired.children.append(title)
        let hint = ConversationStyle.text(L10n.string("Pair it again from Settings › Connect to a Mac."),
                                          size: ConversationStyle.captionSize, tone: .secondary)
        hint.textAlignment = .center
        unpaired.children.append(hint)
    }
}
