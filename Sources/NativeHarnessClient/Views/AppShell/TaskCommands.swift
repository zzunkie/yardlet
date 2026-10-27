import SwiftUI

/// The task actions the shell exposes to the menu bar. `targets` decides what each command acts
/// on; the closures carry it out the way the matching sidebar action does.
struct YardletTaskCommandSet {
    var targets = TaskCommandTargets()
    var isSidebarVisible = true
    var activate: (WindowItem) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    /// Turns the sidebar's activity view on or off, as its bell button does.
    var toggleActivity: () -> Void = {}
    var togglePinned: (TaskCommandTargets.PinTarget) -> Void = { _ in }
    var markUnread: (UUID) -> Void = { _ in }
    var archive: (UUID) -> Void = { _ in }
    var showArchivedTasks: () -> Void = {}
    /// File › New task: the new-task screen, as the title bar's button opens it. Nil while a sheet
    /// or alert is up.
    var newTask: (() -> Void)? = nil
    /// The window's session rail and the task it would toggle for, which the View menu names.
    var sessionRail: SessionRailWindowState? = nil
    var shownTaskID: UUID? = nil
    var toggleSessionRail: () -> Void = {}
    /// The shown task's panels, which the View menu toggles as the Codex app's View menu does
    /// ("Toggle Changes Panel" ⌘⌥B, "Toggle Bottom Panel" ⌘J; the Claude app's terminal is ⌘J too).
    /// Nil while no task is shown or a sheet is up.
    var panels: TaskSurfaceNavigationProjection.PanelState? = nil
    var toggleSidePanel: () -> Void = {}
    var toggleTerminal: () -> Void = {}
    /// Opens the shown composer's model menu, the task's or the new-task screen's. Nil while a sheet
    /// or alert is up.
    var openModelMenu: (() -> Void)? = nil
    /// View › Back and Forward through what the window showed (`SplitStore.goBack`). Nil where there is
    /// nothing to go back or forward to.
    var goBack: (() -> Void)? = nil
    var goForward: (() -> Void)? = nil
}

private struct YardletTaskCommandsKey: FocusedValueKey {
    typealias Value = YardletTaskCommandSet
}

extension FocusedValues {
    var yardletTaskCommands: YardletTaskCommandSet? {
        get { self[YardletTaskCommandsKey.self] }
        set { self[YardletTaskCommandsKey.self] = newValue }
    }
}

enum TaskCommandTitle {
    static func pin(_ target: TaskCommandTargets.PinTarget?) -> String {
        switch target {
        case let .split(_, isPinned):
            L10n.string(isPinned ? "Unpin split view" : "Pin split view")
        case let .session(_, isPinned):
            L10n.string(isPinned ? "Unpin task" : "Pin task")
        case nil:
            L10n.string("Pin task")
        }
    }

    static func sidebar(isVisible: Bool) -> String {
        L10n.string(isVisible ? "Hide sidebar" : "Show sidebar")
    }

    /// The title bar's button, the View menu and the command palette name the side panel and the
    /// terminal the same way.
    static func sidePanel(isShown: Bool) -> String {
        L10n.string(isShown ? "Hide side panel" : "Show side panel")
    }

    /// The Claude app's "Show terminal" / "Hide terminal" (`EG6bUoWXTq`, `2H5K6Nbsaz`).
    static func terminal(isShown: Bool) -> String {
        L10n.string(isShown ? "Hide terminal" : "Show terminal")
    }
}

/// The Codex app's `defaultKeybindings` for these commands, where they do not clash with Yardlet's
/// own: `⌘⇧[` / `⌘⇧]` move between sidebar rows, `⌥⌘A` opens the next task needing attention, `⌥⌘U`
/// toggles the activity view (`togglePriorityFilter`), `⌘⇧S` toggles the sidebar, `⌥⌘P` pins, `⌘⇧U`
/// marks unread, and `⌘⇧A` archives. `⌘1`–`⌘4` stay with the task surfaces. The session rail has no
/// shortcut in either app; `⌃⌘I` is macOS's own for showing and hiding an inspector (SwiftUI's
/// `InspectorCommands`), the trailing column the rail is. The terminal is `⌘J` in both apps (the
/// Claude app's `toggle_terminal_pane`, the Codex app's `toggleBottomPanel`), and the side panel is
/// the Codex app's `toggleSidePanel` `⌘⌥B` (the Claude app has a key per pane instead). The model menu
/// opens with the Codex app's `composer.openModelPicker` `⌃⇧M`; the Claude app's `⌘⇧I` (model) and `⌘⇧E`
/// (effort) are the Codex app's personality settings and file tree, so they are left out. Back and
/// Forward are `⌘[` / `⌘]` in both apps (the Claude app's Go menu, the Codex app's `navigateBack` and
/// `navigateForward`), which also give them the mouse's back and forward buttons.
enum TaskCommandShortcut {
    static let toggleSidebar = KeyboardShortcut("s", modifiers: [.command, .shift])
    static let previousTask = KeyboardShortcut("[", modifiers: [.command, .shift])
    static let nextTask = KeyboardShortcut("]", modifiers: [.command, .shift])
    static let nextTaskNeedingAttention = KeyboardShortcut("a", modifiers: [.command, .option])
    static let toggleActivityView = KeyboardShortcut("u", modifiers: [.command, .option])
    static let togglePinned = KeyboardShortcut("p", modifiers: [.command, .option])
    static let markUnread = KeyboardShortcut("u", modifiers: [.command, .shift])
    static let archive = KeyboardShortcut("a", modifiers: [.command, .shift])
    static let toggleSessionRail = KeyboardShortcut("i", modifiers: [.command, .control])
    static let toggleSidePanel = KeyboardShortcut("b", modifiers: [.command, .option])
    static let toggleTerminal = KeyboardShortcut("j", modifiers: .command)
    static let openModelMenu = KeyboardShortcut("m", modifiers: [.control, .shift])
    static let back = KeyboardShortcut("[", modifiers: .command)
    static let forward = KeyboardShortcut("]", modifiers: .command)

    /// File › New task, the Codex app's `newThread` (⌘N). Its New Window has no shortcut.
    static let newTask = KeyboardShortcut("n", modifiers: .command)

    static let all = [toggleSidebar, previousTask, nextTask, nextTaskNeedingAttention, toggleActivityView,
                      togglePinned, markUnread, archive, toggleSessionRail, toggleSidePanel, toggleTerminal, openModelMenu,
                      back, forward]
}

struct YardletTaskCommands: Commands {
    @FocusedValue(\.yardletTaskCommands) private var task
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // As the Codex app's File menu: New task takes ⌘N, and New Window stays without a shortcut.
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New task")) { task?.newTask?() }
                .keyboardShortcut(TaskCommandShortcut.newTask)
                .disabled(task?.newTask == nil)
            Button(L10n.string("New Window")) { openWindow(id: "main") }
        }
        CommandGroup(replacing: .sidebar) {
            Button(TaskCommandTitle.sidebar(isVisible: task?.isSidebarVisible ?? true)) {
                task?.toggleSidebar()
            }
            .keyboardShortcut(TaskCommandShortcut.toggleSidebar)
            .disabled(task == nil)
            Button(task?.sessionRail?.toggleTitle(for: task?.shownTaskID) ?? L10n.string("Show session rail")) {
                task?.toggleSessionRail()
            }
            .keyboardShortcut(TaskCommandShortcut.toggleSessionRail)
            .disabled(task?.shownTaskID == nil)
            Button(TaskCommandTitle.sidePanel(isShown: task?.panels?.trailingSurfaceID != nil)) {
                task?.toggleSidePanel()
            }
            .keyboardShortcut(TaskCommandShortcut.toggleSidePanel)
            .disabled(task?.panels == nil)
            Button(TaskCommandTitle.terminal(isShown: task?.panels?.isTerminalPresented == true)) {
                task?.toggleTerminal()
            }
            .keyboardShortcut(TaskCommandShortcut.toggleTerminal)
            .disabled(task?.panels == nil)

            Divider()

            Button(L10n.string("Back")) { task?.goBack?() }
                .keyboardShortcut(TaskCommandShortcut.back)
                .disabled(task?.goBack == nil)
            Button(L10n.string("Forward")) { task?.goForward?() }
                .keyboardShortcut(TaskCommandShortcut.forward)
                .disabled(task?.goForward == nil)
        }
        CommandMenu(Text(L10n.string("Task"))) {
            Button(L10n.string("Previous task")) {
                if let row = task?.targets.previousRow { task?.activate(row) }
            }
            .keyboardShortcut(TaskCommandShortcut.previousTask)
            .disabled(task?.targets.previousRow == nil)
            Button(L10n.string("Next task")) {
                if let row = task?.targets.nextRow { task?.activate(row) }
            }
            .keyboardShortcut(TaskCommandShortcut.nextTask)
            .disabled(task?.targets.nextRow == nil)
            Button(L10n.string("Next task needing attention")) {
                if let id = task?.targets.sessionNeedingAttention { task?.activate(.session(id)) }
            }
            .keyboardShortcut(TaskCommandShortcut.nextTaskNeedingAttention)
            .disabled(task?.targets.sessionNeedingAttention == nil)
            Button(L10n.string("Toggle activity view")) { task?.toggleActivity() }
                .keyboardShortcut(TaskCommandShortcut.toggleActivityView)
                .disabled(task == nil)
            Button(L10n.string("Select model")) { task?.openModelMenu?() }
                .keyboardShortcut(TaskCommandShortcut.openModelMenu)
                .disabled(task?.openModelMenu == nil)

            Divider()

            Button(TaskCommandTitle.pin(task?.targets.pin)) {
                if let target = task?.targets.pin { task?.togglePinned(target) }
            }
            .keyboardShortcut(TaskCommandShortcut.togglePinned)
            .disabled(task?.targets.pin == nil)
            Button(L10n.string("Mark task as unread")) {
                if let id = task?.targets.markUnread { task?.markUnread(id) }
            }
            .keyboardShortcut(TaskCommandShortcut.markUnread)
            .disabled(task?.targets.markUnread == nil)
            Button(L10n.string("Archive task")) {
                if let id = task?.targets.archive { task?.archive(id) }
            }
            .keyboardShortcut(TaskCommandShortcut.archive)
            .disabled(task?.targets.archive == nil)

            Divider()

            Button(L10n.string("Archived tasks")) { task?.showArchivedTasks() }
                .disabled(task == nil)
        }
    }
}
