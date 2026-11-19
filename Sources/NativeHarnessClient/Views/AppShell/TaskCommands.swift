import AppKit
import SwiftUI

/// The task actions the shell exposes to the menu bar. `targets` decides what each command acts
/// on; the closures carry it out the way the matching sidebar action does.
struct YardletTaskCommandSet {
    var targets = TaskCommandTargets()
    var isSidebarVisible = true
    var activate: (WindowItem) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    /// Whether the sidebar shows the activity view, which the Task menu's item names.
    var isActivityShown = false
    /// Turns the sidebar's activity view on or off, as its bell button does.
    var toggleActivity: () -> Void = {}
    /// Task › Stop: stops the shown task's turn, as the composer's Stop does. Nil while nothing runs.
    var stop: (() -> Void)? = nil
    var togglePinned: (TaskCommandTargets.PinTarget) -> Void = { _ in }
    var markUnread: (UUID) -> Void = { _ in }
    var archive: (UUID) -> Void = { _ in }
    /// Nil where the window has no archived list (another Mac's window).
    var showArchivedTasks: (() -> Void)? = {}
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

    /// The bell's tooltip, the Task menu and the command palette name the activity view the same
    /// way, in the Codex app's words (`sidebarElectron.priorityThreads.*`).
    static func activity(isShown: Bool) -> String {
        L10n.string(isShown ? "Turn off activity view" : "View activity")
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

/// The Codex app's Open Terminal key, `Control+\``, beside the View menu's ⌘J, which the menu cannot
/// give one item twice. Its window takes it before the focused view does, as it takes a menu's key, so it
/// works with the terminal focused (whose shell would read it as Control-@). Off while a sheet is up.
struct TerminalToggleKey: NSViewRepresentable {
    let isEnabled: Bool
    let toggle: () -> Void

    /// Control and the key left of 1, whatever character the keyboard's layout gives it.
    static func matches(_ event: NSEvent) -> Bool {
        MacShortcut.terminalAlternate.matches(MacShortcutEvent(event))
    }

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.toggle = isEnabled ? toggle : nil
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopWatching()
    }

    final class KeyView: NSView {
        var toggle: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !event.isARepeat,
                      let toggle = self.toggle, TerminalToggleKey.matches(event) else { return event }
                toggle()
                return nil
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct YardletTaskCommands: Commands {
    @FocusedValue(\.yardletTaskCommands) private var task
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // As the Codex app's File menu: New task takes ⌘N, and New Window stays without a shortcut.
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New task")) { task?.newTask?() }
                .keyboardShortcut(MacShortcut.newTask.binding)
                .disabled(task?.newTask == nil)
            Button(L10n.string("New Window")) { openWindow(id: "main") }
        }
        CommandGroup(replacing: .sidebar) {
            Button(TaskCommandTitle.sidebar(isVisible: task?.isSidebarVisible ?? true)) {
                task?.toggleSidebar()
            }
            .keyboardShortcut(MacShortcut.toggleSidebar.binding)
            .disabled(task == nil)
            Button(task?.sessionRail?.toggleTitle(for: task?.shownTaskID) ?? L10n.string("Show session rail")) {
                task?.toggleSessionRail()
            }
            .keyboardShortcut(MacShortcut.toggleSessionRail.binding)
            .disabled(task?.shownTaskID == nil)
            Button(TaskCommandTitle.sidePanel(isShown: task?.panels?.trailingSurfaceID != nil)) {
                task?.toggleSidePanel()
            }
            .keyboardShortcut(MacShortcut.toggleSidePanel.binding)
            .disabled(task?.panels == nil)
            Button(TaskCommandTitle.terminal(isShown: task?.panels?.showsTerminal == true)) {
                task?.toggleTerminal()
            }
            .keyboardShortcut(MacShortcut.toggleTerminal.binding)
            .disabled(task?.panels == nil)

            Divider()

            Button(L10n.string("Back")) { task?.goBack?() }
                .keyboardShortcut(MacShortcut.back.binding)
                .disabled(task?.goBack == nil)
            Button(L10n.string("Forward")) { task?.goForward?() }
                .keyboardShortcut(MacShortcut.forward.binding)
                .disabled(task?.goForward == nil)
        }
        CommandMenu(Text(L10n.string("Task"))) {
            Button(L10n.string("Previous task")) {
                if let row = task?.targets.previousRow { task?.activate(row) }
            }
            .keyboardShortcut(MacShortcut.previousTask.binding)
            .disabled(task?.targets.previousRow == nil)
            Button(L10n.string("Next task")) {
                if let row = task?.targets.nextRow { task?.activate(row) }
            }
            .keyboardShortcut(MacShortcut.nextTask.binding)
            .disabled(task?.targets.nextRow == nil)
            Button(L10n.string("Next task needing attention")) {
                if let id = task?.targets.sessionNeedingAttention { task?.activate(.session(id)) }
            }
            .keyboardShortcut(MacShortcut.nextTaskNeedingAttention.binding)
            .disabled(task?.targets.sessionNeedingAttention == nil)
            Button(TaskCommandTitle.activity(isShown: task?.isActivityShown ?? false)) { task?.toggleActivity() }
                .keyboardShortcut(MacShortcut.toggleActivityView.binding)
                .disabled(task == nil)
            Button(L10n.string("Select model")) { task?.openModelMenu?() }
                .keyboardShortcut(MacShortcut.openModelMenu.binding)
                .disabled(task?.openModelMenu == nil)
            // No key: Escape stops a turn from the composer, and the window's other views keep theirs.
            Button(L10n.string("Stop")) { task?.stop?() }
                .disabled(task?.stop == nil)

            Divider()

            Button(TaskCommandTitle.pin(task?.targets.pin)) {
                if let target = task?.targets.pin { task?.togglePinned(target) }
            }
            .keyboardShortcut(MacShortcut.togglePinned.binding)
            .disabled(task?.targets.pin == nil)
            Button(L10n.string("Mark task as unread")) {
                if let id = task?.targets.markUnread { task?.markUnread(id) }
            }
            .keyboardShortcut(MacShortcut.markUnread.binding)
            .disabled(task?.targets.markUnread == nil)
            Button(L10n.string("Archive task")) {
                if let id = task?.targets.archive { task?.archive(id) }
            }
            .keyboardShortcut(MacShortcut.archive.binding)
            .disabled(task?.targets.archive == nil)

            Divider()

            Button(L10n.string("Archived tasks")) { task?.showArchivedTasks?() }
                .disabled(task?.showArchivedTasks == nil)
        }
    }
}
