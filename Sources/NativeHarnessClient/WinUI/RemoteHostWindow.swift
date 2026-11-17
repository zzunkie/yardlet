import Foundation
import Observation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Another computer's Yardlet in a window of its own (docs/REMOTE_PROTOCOL.md §18), as the Mac's host window
/// (`RemoteHostWindow`): its title the host's name, with how the host is reached beside it (`RemoteConnectionText`); the
/// main window's sidebar (`TaskSidebar`) listing the host's tasks as the host lists them (`RemoteSidebarMirror`), with
/// Home, New task on the host, while the host can start one, row and project menus that act through the host, and the
/// host at its foot (`RemoteHostFooter`); and beside it the chosen task's header (`TaskHeader`), a line while the host
/// cannot be reached (`RemoteConnectionBanner`), and the task (`RemoteTaskPane`), New task on the host
/// (`RemoteNewTaskPane`), or while neither is chosen, that the window is connecting or what to choose. A host this
/// computer no longer pairs with leaves the window saying so. The window follows its `RemoteHostModel` through
/// Observation; closing it ends the connection. The Mac's schedules, archived tasks, activity view, tabs, splits and
/// host Settings there are the Mac's alone for now.
@MainActor
final class RemoteHostWindow {
    private let model: RemoteHostModel
    private let directory: RemoteHostDirectory
    private let log: QAEventLog
    private let window = Window()
    private let root = Grid()
    /// Beside the sidebar, as the main window's.
    private let content = Border()
    /// How the host is reached, after the window's title.
    private let connectionLine = TextBlock()
    /// The task's header, the connection's banner, and the task or the placeholder.
    private let detail = Grid()
    private let body = Border()
    private let banner: RemoteConnectionBanner
    private let pane: RemoteTaskPane
    private let newTask: RemoteNewTaskPane
    private let footer: RemoteHostFooter
    private var sidebar: TaskSidebar?
    private var header: TaskHeader?
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
    /// How many tasks the sidebar lists, as last logged.
    private var loggedTaskCount: Int?
    var onClose: (() -> Void)?

    init(model: RemoteHostModel, directory: RemoteHostDirectory, log: QAEventLog) {
        self.model = model
        self.directory = directory
        self.log = log
        banner = RemoteConnectionBanner(model: model, directory: directory, log: log)
        pane = RemoteTaskPane(model: model, drafts: drafts, log: log)
        newTask = RemoteNewTaskPane(model: model, drafts: drafts, log: log)
        footer = RemoteHostFooter(model: model, directory: directory, log: log)
    }

    func open() {
        try? window.appWindow.resize(SizeInt32(width: 1000, height: 680))
        window.closed.addHandler { [weak self] _, _ in
            self?.drafts.save()
            self?.onClose?()
        }
        let windowHandle: () -> UInt64 = { [weak self] in self?.window.appWindow.id.value ?? 0 }

        let actions = TaskActions(source: .remote(model), log: log, host: { [weak self] in self?.root },
                                  windowHandle: windowHandle)
        footer.onRemove = { [weak self] in self?.close() }
        let sidebar = TaskSidebar(source: .remote(model), actions: actions, footer: footer.view)
        sidebar.onChoose = { [weak self] place in self?.show(place) }
        sidebar.onNewTaskInProject = { [weak self] folder in self?.showNewTask(in: folder) }
        self.sidebar = sidebar
        let header = TaskHeader(actions: actions)
        self.header = header

        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 1, gridUnitType: .star)] {
            let row = RowDefinition()
            row.height = height
            detail.rowDefinitions.append(row)
        }
        detail.children.append(header.view)
        try? Grid.setRow(banner.view, 1)
        detail.children.append(banner.view)
        try? Grid.setRow(body, 2)
        detail.children.append(body)
        makePlaceholders()
        pane.windowHandle = windowHandle
        newTask.windowHandle = windowHandle
        drafts.restore(from: model.cacheFolder)

        SidebarStyle.columns(root, [SidebarStyle.auto, SidebarStyle.star])
        root.children.append(sidebar.view)
        WindowChrome.styleContent(content)
        content.child = detail
        try? Grid.setColumn(content, 1)
        root.children.append(content)
        WindowChrome.frame(window, title: model.name, subtitle: connectionLine, content: root)
        // The working dots follow Windows' animation effects setting, read again as the window comes to the front.
        window.activated.addHandler { _, _ in SidebarBlink.shared.refresh() }
        try? window.activate()

        followConnection()
        followTasks()
        followDetail()
        followHeader()
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

    /// How many tasks the host lists, logged as it changes once the host's list has come.
    private func followTasks() {
        let count = withObservationTracking {
            model.hasSnapshot ? model.sidebar.sessions.count : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTasks() }
        }
        guard let count, count != loggedTaskCount else { return }
        loggedTaskCount = count
        log.write("remote tasks: \(count)")
    }

    /// Shows what the sidebar chose: New task on the host, or a host's task, by the host's ID for it.
    private func show(_ place: SidebarPlace) {
        switch place {
        case .home:
            guard model.newTask != nil else { return }
            model.select(.newTask)
        case let .task(id):
            let taskID = model.tasks.first { RemoteSidebarMirror.sessionID(for: $0.id) == id }?.id ?? id.uuidString
            model.select(.task(taskID))
        case .settings:
            break
        }
    }

    /// New task in a project, from its menu: New task on the host with the project chosen, as the Mac's.
    private func showNewTask(in folder: URL) {
        guard model.newTask != nil else { return }
        drafts.newTaskProjectID = model.sidebar.projectIDs[folder.standardizedFileURL]
        if showing == .newTask {
            newTask.hide()
            newTask.show()
        } else {
            model.select(.newTask)
        }
    }

    /// The sidebar's chosen row is what the detail shows: Home for New task, else the task's row.
    private func markSelection() {
        let place: SidebarPlace? = switch model.selection {
        case .newTask: .home
        case let .task(id): .task(RemoteSidebarMirror.sessionID(for: id))
        default: nil
        }
        sidebar?.choose(place)
    }

    private var selectedTaskID: String? {
        if case let .task(id) = model.selection { id } else { nil }
    }

    /// The shown task's header: its title, which opens its menu, its harness, and its state.
    private func followHeader() {
        let session = withObservationTracking { () -> SessionRecord? in
            guard directory.host(model.id) != nil, let taskID = selectedTaskID, model.conversations[taskID] != nil
            else { return nil }
            let id = RemoteSidebarMirror.sessionID(for: taskID)
            return model.sidebar.sessions.first { $0.id == id }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followHeader() }
        }
        header?.show(session)
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
                sidebar?.view.visibility = .collapsed
                content.child = unpaired
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
