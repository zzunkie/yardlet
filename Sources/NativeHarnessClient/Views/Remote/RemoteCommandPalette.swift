import SwiftUI
import YardletRemote

/// ⌘K in another Mac's window (docs/REMOTE_PROTOCOL.md §18): the local palette's commands that this window carries out
/// through the host, read from the window's own Task and View menu commands (`YardletTaskCommandSet`), and the host's
/// tasks. What acts on this Mac alone (importing conversations, harnesses, task resource usage, Show in Finder, split
/// views) stays out, as the window's menus leave it out; so does an action the host does not advertise.
@MainActor
struct RemoteCommandPalette {
    let model: RemoteHostModel
    let commands: YardletTaskCommandSet
    /// Whether the shown task's session rail is on, which its item names.
    let showsRail: Bool

    private var shownSession: SessionRecord? {
        commands.shownTaskID.flatMap { id in model.sidebar.sessions.first { $0.id == id } }
    }

    var items: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        if let newTask = commands.newTask {
            items.append(CommandPaletteItem(
                id: "new-task", title: L10n.string("New task"),
                subtitle: L10n.string("Choose a project and harness to start a task."), systemName: "square.and.pencil",
                shortcut: MacShortcut.newTask.binding, action: newTask))
        }
        items.append(CommandPaletteItem(
            id: "toggle-sidebar", title: TaskCommandTitle.sidebar(isVisible: commands.isSidebarVisible),
            subtitle: L10n.string("Change the task navigation layout."), systemName: "sidebar.left",
            shortcut: MacShortcut.toggleSidebar.binding, action: commands.toggleSidebar))
        items.append(CommandPaletteItem(
            id: "toggle-activity", title: TaskCommandTitle.activity(isShown: commands.isActivityShown),
            subtitle: L10n.string("Turn the sidebar activity view on or off"), systemName: "bell",
            shortcut: MacShortcut.toggleActivityView.binding, action: commands.toggleActivity))
        if let panels = commands.panels {
            items.append(CommandPaletteItem(
                id: "toggle-session-rail", title: L10n.string(showsRail ? "Hide session rail" : "Show session rail"),
                subtitle: L10n.string("The task's environment, settings, context, changes and progress beside the conversation."),
                systemName: TaskPanelSymbol.sessionRail, shortcut: MacShortcut.toggleSessionRail.binding,
                action: commands.toggleSessionRail))
            items.append(CommandPaletteItem(
                id: "toggle-side-panel", title: TaskCommandTitle.sidePanel(isShown: panels.trailingSurfaceID != nil),
                subtitle: L10n.string("Review, browser, files and side chat beside the conversation."),
                systemName: TaskPanelSymbol.sidePanel, shortcut: MacShortcut.toggleSidePanel.binding,
                action: commands.toggleSidePanel))
            if model.offersTerminals {
                items.append(CommandPaletteItem(
                    id: "toggle-terminal", title: TaskCommandTitle.terminal(isShown: panels.showsTerminal),
                    subtitle: L10n.string(TerminalLocation.current() == .right ? "A shell in the task's folder in the side panel."
                                                                               : "A shell in the task's folder below the conversation."),
                    systemName: TaskPanelSymbol.terminal, shortcut: MacShortcut.toggleTerminal.binding,
                    action: commands.toggleTerminal))
            }
        }
        if let showArchivedTasks = commands.showArchivedTasks {
            items.append(CommandPaletteItem(
                id: "archived-tasks", title: L10n.string("Archived tasks"),
                subtitle: L10n.string("Show archived tasks, read them and restore them."), systemName: "archivebox",
                action: showArchivedTasks))
        }
        if model.offersHostSettings {
            items.append(CommandPaletteItem(
                id: "settings", title: L10n.string("Settings"), subtitle: L10n.format("Change %@'s settings.", model.name),
                systemName: "gearshape.2", shortcut: MacShortcut.settings.binding, action: { [model] in model.openSettings() }))
        }
        if let session = shownSession { items += taskItems(session) }
        return items
    }

    /// The shown task's commands, as the local palette lists them for its task.
    private func taskItems(_ session: SessionRecord) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        let header = model.taskHeaderActions
        let taskID = session.id.uuidString
        if let stop = commands.stop {
            items.append(CommandPaletteItem(id: "interrupt-\(session.id)", title: L10n.string("Stop"),
                                            subtitle: session.title, systemName: "stop.circle", action: stop))
        } else if model.taskActions, !header.isAttached(session) {
            items.append(CommandPaletteItem(id: "resume-\(session.id)", title: L10n.string("Resume task"),
                                            subtitle: session.title, systemName: "play.circle",
                                            action: { header.onResume(session) }))
        }
        items.append(CommandPaletteItem(id: "mark-read-\(session.id)", title: L10n.string("Mark task as read"),
                                        subtitle: session.title, systemName: "checkmark.circle",
                                        action: { [model] in model.send(.markRead(taskID: taskID)) }))
        if model.taskActions, !session.hasUnreadUpdate {
            items.append(CommandPaletteItem(id: "mark-unread-\(session.id)", title: L10n.string("Mark task as unread"),
                                            subtitle: session.title, systemName: "circlebadge",
                                            shortcut: MacShortcut.markUnread.binding,
                                            action: { commands.markUnread(session.id) }))
        }
        if model.taskControls {
            items.append(CommandPaletteItem(id: "fork-\(session.id)", title: L10n.string("Fork task"),
                                            subtitle: L10n.string("Create a new task from this conversation."),
                                            systemName: "arrow.triangle.branch",
                                            action: { [model] in model.fork(taskID, turnID: nil) }))
        }
        if model.taskActions, header.canOpenOriginalConversation(session), let open = header.onOpenOriginalConversation {
            items.append(CommandPaletteItem(id: "original-\(session.id)", title: L10n.string("Open original conversation"),
                                            subtitle: session.title, systemName: "arrow.uturn.backward",
                                            action: { open(session) }))
        }
        if model.taskActions {
            // One command per project the task can move to, as the local palette lists them.
            for command in TaskProjectMove.commands(header.projectMoveOptions(session)) {
                items.append(CommandPaletteItem(id: "\(command.id)-\(session.id)", title: command.title,
                                                subtitle: session.title,
                                                systemName: command.destination == nil ? "bubble.left" : "folder",
                                                action: { header.onMoveToProject(session, command.destination) }))
            }
        }
        return items
    }

    /// The host's tasks ⌘K finds: those its sidebar lists, most recent first, without the one on screen, each opening as
    /// its row does.
    var tasks: [CommandPaletteItem] {
        let mirror = model.sidebar
        let names = Dictionary(mirror.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        return mirror.sessions
            .filter { $0.id != commands.shownTaskID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { session in
                CommandPaletteItem(id: "task-\(session.id)", title: session.title,
                                   subtitle: names[session.id] ?? L10n.string("Chats"), systemName: "text.bubble",
                                   isTask: true, action: { commands.activate(.session(session.id)) })
            }
    }
}
