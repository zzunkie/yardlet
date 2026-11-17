import Foundation
import UWP
import WinSDK
import WinUI

/// The Mac's Task menu keys (`TaskCommandShortcut`) in the Windows window, with Ctrl in place of ⌘ and Alt in place
/// of ⌥: Ctrl+N New task, Ctrl+Shift+[ and ] the previous and next task, Ctrl+Alt+A the next task needing attention,
/// Ctrl+Alt+P Pin, Ctrl+Shift+U Mark as unread and Ctrl+Shift+A Archive, Ctrl+Shift+M the model menu, which the Mac
/// gives Control+Shift+M, and F2 Rename, Windows' own key for renaming what is chosen. What each acts on is the Mac's (`TaskCommandTargets`): a key with nothing to act on does nothing.
/// The keys are read on their way down to the focused element (PreviewKeyDown), as the Mac's menu keys come before the
/// field being typed in: a keyboard accelerator comes after the field, which keeps Ctrl+Shift+A for itself, and
/// Ctrl+Shift with [ or ] never reaches one.
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

    /// Reads the keys on `element`, the window's content, where they work wherever the focus is in the window.
    func install(on element: UIElement) {
        element.previewKeyDown.addHandler { [weak self] _, args in
            guard let self, let args, let action = self.action(for: args.key) else { return }
            args.handled = true
            action()
        }
    }

    /// What `key` does with the modifiers held now, or nil for a key that is not one of these.
    private func action(for key: UWP.VirtualKey) -> (@MainActor () -> Void)? {
        let control = Self.isDown(VK_CONTROL), shift = Self.isDown(VK_SHIFT), alt = Self.isDown(VK_MENU)
        // AltGr reaches Windows as Ctrl and the right Alt; with it the keys type, not act.
        if alt, Self.isDown(VK_RMENU) { return nil }
        switch (key.rawValue, control, shift, alt) {
        case (UWP.VirtualKey.n.rawValue, true, false, false):
            return { [weak self] in self?.newTask() }
        case (219, true, true, false):
            return { [weak self] in self?.go(\.previousRow) }
        case (221, true, true, false):
            return { [weak self] in self?.go(\.nextRow) }
        case (UWP.VirtualKey.a.rawValue, true, false, true):
            return { [weak self] in
                guard let self, let id = self.targets().sessionNeedingAttention else { return }
                self.activate(.session(id))
            }
        case (UWP.VirtualKey.p.rawValue, true, false, true):
            return { [weak self] in
                guard let self, case let .session(id, _)? = self.targets().pin else { return }
                self.actions.togglePinned(id)
            }
        case (UWP.VirtualKey.u.rawValue, true, true, false):
            return { [weak self] in
                guard let self, let id = self.targets().markUnread else { return }
                self.actions.markUnread(id)
            }
        case (UWP.VirtualKey.a.rawValue, true, true, false):
            return { [weak self] in
                guard let self, let id = self.targets().archive else { return }
                self.actions.archive(id)
            }
        case (UWP.VirtualKey.m.rawValue, true, true, false):
            return { [weak self] in
                guard let self, self.shown().session != nil else { return }
                self.openModelMenu()
            }
        case (UWP.VirtualKey.f2.rawValue, false, false, false):
            return { [weak self] in
                guard let self, let id = self.targets().archive else { return }
                self.actions.rename(id)
            }
        default:
            return nil
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

    private static func isDown(_ key: Int32) -> Bool {
        GetKeyState(key) < 0
    }
}
