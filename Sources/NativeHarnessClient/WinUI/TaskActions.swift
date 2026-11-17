import Foundation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI

/// What a task's and a project's menus do, as the Mac's sidebar, task header and Task menu do it: the same model calls,
/// and the Mac's questions before what cannot be undone, in its words, as Windows' own dialogs. The sidebar's row
/// menus, the task header's title menu and the window's keys all act through it, so a task's actions are the same
/// wherever they are chosen. The Mac's items that open a task elsewhere (a new tab, a split view, the side panel) and
/// those for worktrees and nesting are the Mac's alone.
@MainActor
final class TaskActions {
    private let model: AppModel
    private let log: QAEventLog
    /// The window's content, whose root a dialog shows over.
    private let host: () -> UIElement?
    /// The window's handle, which owns the folder dialog.
    private let windowHandle: () -> UInt64

    init(model: AppModel, log: QAEventLog, host: @escaping () -> UIElement?, windowHandle: @escaping () -> UInt64) {
        self.model = model
        self.log = log
        self.host = host
        self.windowHandle = windowHandle
    }

    private func session(_ id: UUID) -> SessionRecord? {
        model.store.sessions.first { $0.id == id }
    }

    // MARK: A task's menu

    /// A task row's menu, as the Mac's row menu lists it: Pin, Rename…, Mark as read or unread, Archive and Delete.
    func rowMenu(for id: UUID) -> MenuFlyout {
        menu { [weak self] menu in
            guard let self, let session = self.session(id) else { return }
            menu.items.append(Self.item(L10n.string(session.isPinned ? "Unpin" : "Pin")) { [weak self] in
                self?.togglePinned(id)
            })
            menu.items.append(Self.item(L10n.string("Rename…")) { [weak self] in self?.rename(id) })
            if session.hasUnreadUpdate {
                menu.items.append(Self.item(L10n.string("Mark task as read")) { [weak self] in self?.markRead(id) })
            } else {
                menu.items.append(Self.item(L10n.string("Mark task as unread")) { [weak self] in self?.markUnread(id) })
            }
            menu.items.append(MenuFlyoutSeparator())
            menu.items.append(Self.item(L10n.string("Archive")) { [weak self] in self?.archive(id) })
            menu.items.append(Self.item(L10n.string("Delete task")) { [weak self] in self?.delete(id) })
        }
    }

    /// The task header's title menu, as the Mac's title menu lists it: the account the task runs on, Rename task, Pin,
    /// Archive, and the task's folder in File Explorer.
    func titleMenu(for id: UUID) -> MenuFlyout {
        menu { [weak self] menu in
            guard let self, let session = self.session(id) else { return }
            if let name = session.connection?.name {
                let account = Self.item(L10n.format("Account: %@", name)) {}
                account.isEnabled = false
                menu.items.append(account)
                menu.items.append(MenuFlyoutSeparator())
            }
            menu.items.append(Self.item(L10n.string("Rename task")) { [weak self] in self?.rename(id) })
            menu.items.append(Self.item(L10n.string(session.isPinned ? "Unpin" : "Pin")) { [weak self] in
                self?.togglePinned(id)
            })
            menu.items.append(Self.item(L10n.string("Archive")) { [weak self] in self?.archive(id) })
            menu.items.append(MenuFlyoutSeparator())
            let folder = session.workspaceURL
            menu.items.append(Self.item(L10n.string("Show in File Explorer")) { WindowsFileExplorer.reveal(folder) })
        }
    }

    /// A menu whose items are made again as it opens, from the task or project as it is then. It holds them from the
    /// start too: Windows does not open a menu with no items, so one filled only as it opens would never open.
    private func menu(_ fill: @escaping @MainActor (MenuFlyout) -> Void) -> MenuFlyout {
        let menu = MenuFlyout()
        fill(menu)
        menu.opening.addHandler { [weak menu] _, _ in
            guard let menu else { return }
            menu.items.clear()
            fill(menu)
        }
        return menu
    }

    static func item(_ title: String, action: @escaping @MainActor () -> Void) -> MenuFlyoutItem {
        let item = MenuFlyoutItem()
        item.text = title
        item.click.addHandler { _, _ in action() }
        return item
    }

    // MARK: A task's actions

    func togglePinned(_ id: UUID) {
        guard let session = session(id) else { return }
        log.write("\(session.isPinned ? "unpinned" : "pinned"): \(session.title)")
        Task { await model.togglePinned(session) }
    }

    func markRead(_ id: UUID) {
        log.write("marked read: \(session(id)?.title ?? "")")
        Task { await model.store.markRead(id: id) }
    }

    func markUnread(_ id: UUID) {
        log.write("marked unread: \(session(id)?.title ?? "")")
        Task { await model.store.markUnread(id: id) }
    }

    func archive(_ id: UUID) {
        guard let session = session(id) else { return }
        log.write("archived: \(session.title)")
        Task { await model.archive(session) }
    }

    /// The Mac's rename: the title in a field, chosen whole, saved by Rename.
    func rename(_ id: UUID) {
        guard let session = session(id) else { return }
        let field = TextBox()
        field.text = session.title
        field.placeholderText = L10n.string("Task title")
        try? AutomationProperties.setName(field, L10n.string("Task title"))
        field.loaded.addHandler { [weak field] _, _ in
            try? field?.selectAll()
            _ = try? field?.focus(.programmatic)
        }
        ask(title: L10n.string("Rename task"), content: field, confirm: L10n.string("Rename"),
            isDefault: true) { [weak self] in
            let title = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !title.isEmpty, let session = self.session(id) else { return }
            self.log.write("renamed: \(title)")
            await self.model.rename(session, to: title)
        }
    }

    /// The Mac's question before a task is deleted, which says more for a Codex task still attached to the Codex app.
    func delete(_ id: UUID) {
        guard let session = session(id) else { return }
        let key = session.harness == .codex && model.isAttached(session.id)
            ? "Delete attached Codex task confirmation" : "Delete task confirmation"
        ask(title: L10n.string("Delete task?"), content: Self.text(L10n.format(key, session.title)),
            confirm: L10n.string("Delete task")) { [weak self] in
            guard let self, let session = self.session(id) else { return }
            self.log.write("deleted: \(session.title)")
            await self.model.delete(session)
        }
    }

    // MARK: A project's menu and actions

    /// A project's menu, as the Mac's project menu lists it, with New task in project, which the Mac shows beside the
    /// project's name.
    func projectMenu(for group: @escaping @MainActor () -> WorkspaceGroup?, newTask: @escaping @MainActor () -> Void) -> MenuFlyout {
        menu { [weak self] menu in
            guard let self, let group = group() else { return }
            let isPinned = group.project?.isPinned ?? false
            let pin = Self.item(L10n.string(isPinned ? "Unpin project" : "Pin project")) { [weak self] in
                self?.togglePinned(group)
            }
            pin.isEnabled = group.project != nil
            menu.items.append(pin)
            let edit = Self.item(L10n.string("Edit project")) { [weak self] in self?.edit(group) }
            edit.isEnabled = group.project != nil
            menu.items.append(edit)
            menu.items.append(Self.item(L10n.string("New task in project"), action: newTask))
            menu.items.append(MenuFlyoutSeparator())
            let folder = group.workspaceURL
            menu.items.append(Self.item(L10n.string("Show in File Explorer")) { WindowsFileExplorer.reveal(folder) })
            menu.items.append(MenuFlyoutSeparator())
            let archive = Self.item(L10n.string("Archive chats")) { [weak self] in self?.archiveChats(group) }
            archive.isEnabled = !group.sessions.isEmpty
            menu.items.append(archive)
            menu.items.append(MenuFlyoutSeparator())
            let remove = Self.item(L10n.string("Remove project")) { [weak self] in self?.remove(group) }
            remove.isEnabled = group.project != nil
            menu.items.append(remove)
        }
    }

    func togglePinned(_ group: WorkspaceGroup) {
        guard let id = group.project?.id else { return }
        model.projects.togglePinned(id)
    }

    func archiveChats(_ group: WorkspaceGroup) {
        let content = StackPanel()
        content.spacing = 8
        content.children.append(Self.text(L10n.format("Archive project chats confirmation", group.displayName,
                                                      group.sessions.count)))
        if group.sessions.contains(where: { $0.harness == .codex && model.isAttached($0.id) }) {
            content.children.append(Self.text(L10n.string("Archive attached Codex tasks confirmation")))
        }
        ask(title: L10n.string("Archive project chats?"), content: content, confirm: L10n.string("Archive chats")) {
            [weak self] in
            guard let self else { return }
            self.log.write("archived chats: \(group.displayName)")
            _ = await self.model.archive(group.sessions)
        }
    }

    /// The Mac's removal: the project leaves the sidebar and New task, and its tasks stay where they are saved.
    func remove(_ group: WorkspaceGroup) {
        ask(title: L10n.string("Remove project?"),
            content: Self.text(L10n.format("Remove project confirmation", group.displayName)),
            confirm: L10n.string("Remove project")) { [weak self] in
            guard let self, let id = group.project?.id else { return }
            self.log.write("removed project: \(group.displayName)")
            self.model.projects.hide(id)
            let draft = self.model.composerDrafts.home
            if draft.workspaceURL?.standardizedFileURL == group.workspaceURL.standardizedFileURL {
                draft.workspaceURL = nil
            }
            if self.model.store.selectedSession?.workspaceURL == group.workspaceURL {
                self.model.store.selectedSessionID = nil
            }
        }
    }

    /// The Mac's project editor in a dialog: the name, saved by Done, and the folders, changed as they are chosen:
    /// one more from Windows' folder dialog, another made the primary one, or one removed.
    func edit(_ group: WorkspaceGroup) {
        guard let id = group.project?.id, let project = model.projects.project(id: id) else { return }
        let content = StackPanel()
        content.spacing = 12
        content.minWidth = 420
        let name = TextBox()
        name.header = L10n.string("Project name")
        name.text = project.name
        try? AutomationProperties.setName(name, L10n.string("Project name"))
        content.children.append(name)
        let foldersTitle = Self.text(L10n.string("Root folders"))
        foldersTitle.fontWeight = UWP.FontWeight(weight: 600)
        content.children.append(foldersTitle)
        let folders = StackPanel()
        folders.spacing = 4
        content.children.append(folders)
        let note = Self.text(L10n.string("A task runs in the primary folder. The other folders are passed to the harness."))
        note.foreground = WindowsTheme.secondaryText.brush
        note.fontSize = 12
        content.children.append(note)
        let add = Button()
        add.content = L10n.string("Add folder…")
        content.children.append(add)

        func showFolders() {
            folders.children.clear()
            guard let project = model.projects.project(id: id) else { return }
            for root in project.roots {
                folders.children.append(folderRow(root, isPrimary: root == project.primaryRoot, project: id,
                                                  changed: showFolders))
            }
        }
        add.click.addHandler { [weak self] _, _ in
            // The folder dialog runs modally until it closes, so it opens after the click returns.
            Task { @MainActor in
                guard let self, let folder = WindowsFolderPicker.chooseFolder(
                    window: self.windowHandle(), title: L10n.string("Add folder")) else { return }
                _ = self.model.projects.addRoot(folder.standardizedFileURL, to: id)
                showFolders()
            }
        }
        showFolders()
        ask(title: L10n.string("Edit project"), content: content, confirm: L10n.string("Done"), isDefault: true,
            cancels: false) { [weak self] in
            let words = name.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !words.isEmpty else { return }
            self.model.projects.rename(id, to: words)
        }
    }

    private func folderRow(_ root: URL, isPrimary: Bool, project id: UUID, changed: @escaping @MainActor () -> Void)
        -> UIElement {
        let row = Grid()
        row.columnSpacing = 8
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto),
                      GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let path = Self.text(root.nativePath)
        path.textWrapping = .noWrap
        path.textTrimming = .characterEllipsis
        path.verticalAlignment = .center
        row.children.append(path)
        if isPrimary {
            let primary = Self.text(L10n.string("Primary folder"))
            primary.foreground = WindowsTheme.secondaryText.brush
            primary.fontSize = 12
            primary.verticalAlignment = .center
            try? Grid.setColumn(primary, 1)
            row.children.append(primary)
        } else {
            let makePrimary = Button()
            makePrimary.content = L10n.string("Make primary")
            makePrimary.click.addHandler { [weak self] _, _ in
                _ = self?.model.projects.setPrimaryRoot(root, for: id)
                changed()
            }
            try? Grid.setColumn(makePrimary, 1)
            row.children.append(makePrimary)
            let remove = Button()
            remove.content = L10n.string("Remove folder")
            remove.click.addHandler { [weak self] _, _ in
                _ = self?.model.projects.removeRoot(root, from: id)
                changed()
            }
            try? Grid.setColumn(remove, 2)
            row.children.append(remove)
        }
        return row
    }

    // MARK: Dialogs

    /// A question in Windows' dialog, over the window: `confirm` carries out `action`, Cancel closes it. What cannot
    /// be undone does not take Enter; a rename does.
    private func ask(title: String, content: UIElement, confirm: String, isDefault: Bool = false, cancels: Bool = true,
                     action: @escaping @MainActor () async -> Void) {
        guard let root = host()?.xamlRoot else { return }
        let dialog = ContentDialog()
        dialog.title = title
        dialog.content = content
        dialog.primaryButtonText = confirm
        if cancels { dialog.closeButtonText = L10n.string("Cancel") }
        dialog.defaultButton = isDefault ? .primary : .close
        dialog.xamlRoot = root
        Task {
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else { return }
            await action()
        }
    }

    private static func text(_ words: String) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.textWrapping = .wrap
        return block
    }
}
