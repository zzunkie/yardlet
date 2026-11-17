import Foundation
import UWP
import WinSDK
import WinUI

/// The Mac's Task menu keys (`TaskCommandShortcut`) in the Windows window, with Ctrl in place of ⌘ and Alt in place
/// of ⌥: Ctrl+N New task, Ctrl+Shift+[ and ] the previous and next task, Ctrl+Alt+A the next task needing attention,
/// Ctrl+Alt+P Pin, Ctrl+Shift+U Mark as unread and Ctrl+Shift+A Archive, Ctrl+Shift+M the model menu, which the Mac
/// gives Control+Shift+M, and F2 Rename, Windows' own key for renaming what is chosen. What each acts on is the Mac's (`TaskCommandTargets`): a key with nothing to act on does nothing.
/// The right Alt key is AltGr, which types characters on many keyboards, so Ctrl+Alt keys pressed with it are left to
/// the field being typed in.
@MainActor
final class TaskKeys {
    /// What the window shows: Home or a task, and the task it shows.
    var shown: () -> (selection: WindowItem, session: SessionRecord?) = { (.home, nil) }
    /// Shows a row of the sidebar.
    var activate: (WindowItem) -> Void = { _ in }
    var newTask: () -> Void = {}
    /// Opens the shown task's model menu.
    var openModelMenu: () -> Void = {}

    private let model: AppModel
    private let sidebar: TaskSidebar
    private let actions: TaskActions

    init(model: AppModel, sidebar: TaskSidebar, actions: TaskActions) {
        self.model = model
        self.sidebar = sidebar
        self.actions = actions
    }

    /// Puts the keys on `element`, the window's content, where they work wherever the focus is in the window.
    func install(on element: UIElement) {
        element.keyboardAcceleratorPlacementMode = .hidden
        let control = UWP.VirtualKeyModifiers.control
        let shift = UWP.VirtualKeyModifiers.shift
        let alt = UWP.VirtualKeyModifiers.menu
        add(.n, [control], to: element) { [weak self] in self?.newTask() }
        add(UWP.VirtualKey(rawValue: 219), [control, shift], to: element) { [weak self] in
            self?.go(\.previousRow)
        }
        add(UWP.VirtualKey(rawValue: 221), [control, shift], to: element) { [weak self] in
            self?.go(\.nextRow)
        }
        add(.a, [control, alt], to: element) { [weak self] in
            guard let self, let id = self.targets().sessionNeedingAttention else { return }
            self.activate(.session(id))
        }
        add(.p, [control, alt], to: element) { [weak self] in
            guard let self, case let .session(id, _)? = self.targets().pin else { return }
            self.actions.togglePinned(id)
        }
        add(.u, [control, shift], to: element) { [weak self] in
            guard let self, let id = self.targets().markUnread else { return }
            self.actions.markUnread(id)
        }
        add(.a, [control, shift], to: element) { [weak self] in
            guard let self, let id = self.targets().archive else { return }
            self.actions.archive(id)
        }
        add(.m, [control, shift], to: element) { [weak self] in
            guard let self, self.shown().session != nil else { return }
            self.openModelMenu()
        }
        add(.f2, [], to: element) { [weak self] in
            guard let self, let id = self.targets().archive else { return }
            self.actions.rename(id)
        }
    }

    /// What the Task menu would act on now, from the rows the sidebar lists.
    private func targets() -> TaskCommandTargets {
        let (selection, session) = shown()
        return TaskCommandTargets.make(
            layout: sidebar.layout, selection: selection, shownSession: session,
            sidebarSessions: model.sidebarSessions, splits: [], details: model.taskAttentionDetails,
            shellBusy: model.shellBusySessionIDs)
    }

    private func go(_ row: KeyPath<TaskCommandTargets, WindowItem?>) {
        guard let item = targets()[keyPath: row] else { return }
        activate(item)
    }

    private func add(_ key: UWP.VirtualKey, _ modifiers: [UWP.VirtualKeyModifiers], to element: UIElement,
                     action: @escaping @MainActor () -> Void) {
        let accelerator = KeyboardAccelerator()
        accelerator.key = key
        accelerator.modifiers = UWP.VirtualKeyModifiers(rawValue: modifiers.reduce(0) { $0 | $1.rawValue })
        let usesAlt = modifiers.contains { $0.rawValue == UWP.VirtualKeyModifiers.menu.rawValue }
        accelerator.invoked.addHandler { _, args in
            // AltGr reaches Windows as Ctrl and the right Alt; with it the keys type, not act.
            if usesAlt, GetKeyState(VK_RMENU) < 0 { return }
            args?.handled = true
            action()
        }
        element.keyboardAccelerators.append(accelerator)
    }
}
