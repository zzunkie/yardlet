import Foundation
import UWP
import WinUI

/// Import conversation, as the Mac's sheet (`ImportConversationSheet`) continues a conversation another app or CLI
/// started: a Yardlet task with the same session, whose history stays where the harness keeps it. The list is one
/// folder's history under the chosen account, read by the engine as the Mac reads it (`importableConversations`):
/// Claude Code's, Codex's, Antigravity CLI's, and that of each other ACP agent installed whose history
/// `ACPSessionHistory` reads. The folders are the projects' and one chosen in Windows' folder dialog; the account is
/// the one the harness's new tasks start on, with a menu when there are others. Choosing a conversation imports it,
/// or finds the task that already continues it, and the window shows that task. Codex's history search is the Mac's
/// alone so far.
@MainActor
final class ImportConversationPane {
    let view = ScrollViewer()
    /// Called once the model has chosen the imported task, or the one that already continued the conversation.
    var onImported: (() -> Void)?

    private let model: AppModel
    private let log: QAEventLog
    /// The window's handle, which owns the folder dialog.
    private let windowHandle: () -> UInt64
    private let stack = StackPanel()
    private let harnessList = ListView()
    private let folderBox = ComboBox()
    private let chooseFolderButton = Button()
    private let accountBox = ComboBox()
    private let list = StackPanel()
    private let loadMoreButton = Button()
    private let status = TextBlock()

    /// The harnesses the list shows, in its order, and the one chosen.
    private var harnesses: [HarnessKind] = []
    private var harness = HarnessKind.claudeCode
    /// What the folder menu lists, in its order, and the chosen one's key.
    private var folders: [Folder] = []
    private var folderKey: String?
    /// A folder chosen in Windows' folder dialog that no project holds, listed after the projects' folders.
    private var chosenFolder: URL?
    /// What the account menu lists, and the chosen one.
    private var accounts: [AccountChoice] = []
    private var accountID = ""
    private var page = ImportableConversationPage(conversations: [])
    private var isLoading = false
    private var isLoadingMore = false
    private var importingID: String?
    /// Ends a read of the list that a newer one replaced.
    private var listGeneration = 0
    /// Set while the controls are filled, whose selection changes are then not the person's.
    private var isFilling = false
    private var lookedForRuntimes = false

    private struct Folder {
        let name: String
        let url: URL
        var key: String { ProjectSidebarPresentation.folderKey(for: url) }
    }

    init(model: AppModel, log: QAEventLog, windowHandle: @escaping () -> UInt64) {
        self.model = model
        self.log = log
        self.windowHandle = windowHandle
        make()
    }

    private var account: AccountChoice? { accounts.first { $0.id == accountID } ?? accounts.first }

    private var folder: Folder? { folders.first { $0.key == folderKey } }

    private func make() {
        stack.spacing = 12
        stack.padding = Thickness(left: 28, top: 28, right: 28, bottom: 28)
        stack.maxWidth = 640
        stack.horizontalAlignment = .left
        let title = TextBlock()
        title.text = L10n.string("Import conversation")
        title.fontSize = 20
        stack.children.append(title)
        let explanation = Self.text(L10n.string("Continue a conversation started in another app or CLI. Its history stays where it is."))
        explanation.opacity = 0.7
        stack.children.append(explanation)

        let harnessTitle = Self.text(L10n.string("Harness"))
        harnessTitle.opacity = 0.7
        stack.children.append(harnessTitle)
        harnessList.selectionMode = .single
        harnessList.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isFilling else { return }
            let index = Int(self.harnessList.selectedIndex)
            guard self.harnesses.indices.contains(index), self.harnesses[index] != self.harness else { return }
            self.harness = self.harnesses[index]
            self.log.write("import harness: \(self.harness.displayName)")
            self.selectAccount()
            self.showAccounts()
            self.load()
            self.checkAccounts()
        }
        stack.children.append(harnessList)

        let folderRow = StackPanel()
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        folderBox.header = L10n.string("Project")
        folderBox.minWidth = 240
        try? AutomationProperties.setName(folderBox, L10n.string("Project"))
        folderBox.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isFilling else { return }
            let index = Int(self.folderBox.selectedIndex)
            guard self.folders.indices.contains(index), self.folders[index].key != self.folderKey else { return }
            self.folderKey = self.folders[index].key
            self.log.write("import folder: \(self.folders[index].name)")
            self.load()
        }
        folderRow.children.append(folderBox)
        chooseFolderButton.content = L10n.string("Choose project…")
        chooseFolderButton.verticalAlignment = .bottom
        // The dialog runs modally until it closes, so it opens after the click returns: a click that UI Automation
        // invokes (a screen reader, a check) would otherwise wait inside that call for the dialog to close.
        chooseFolderButton.click.addHandler { [weak self] _, _ in Task { @MainActor in self?.chooseFolder() } }
        folderRow.children.append(chooseFolderButton)
        stack.children.append(folderRow)

        accountBox.header = L10n.string("Account")
        accountBox.minWidth = 240
        accountBox.visibility = .collapsed
        try? AutomationProperties.setName(accountBox, L10n.string("Account"))
        accountBox.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isFilling else { return }
            let index = Int(self.accountBox.selectedIndex)
            guard self.accounts.indices.contains(index), self.accounts[index].id != self.accountID else { return }
            self.accountID = self.accounts[index].id
            self.load()
        }
        stack.children.append(accountBox)

        list.spacing = 2
        stack.children.append(list)
        loadMoreButton.content = L10n.string("Load more history")
        loadMoreButton.visibility = .collapsed
        loadMoreButton.click.addHandler { [weak self] _, _ in self?.loadMore() }
        stack.children.append(loadMoreButton)
        status.textWrapping = .wrap
        stack.children.append(status)
        view.content = stack
    }

    /// Fills the pane when Import conversation is chosen: the harnesses, the folders and the account, then the list
    /// read again.
    func show() {
        harnesses = [.claudeCode, .codex, .antigravityCLI] + HarnessCatalog.builtIns.map(\.id).filter {
            ACPSessionHistory.reads($0) && model.runtimeSelections.selectedURL(for: $0) != nil
        }
        if !harnesses.contains(harness) { harness = .claudeCode }
        isFilling = true
        harnessList.items.clear()
        for harness in harnesses { harnessList.items.append(Self.harnessItem(harness)) }
        harnessList.selectedIndex = Int32(harnesses.firstIndex(of: harness) ?? 0)
        isFilling = false
        log.write("import harnesses: \(harnesses.map(\.displayName).joined(separator: ", "))")
        // The folder New task last chose leads, as the Mac's sheet opens on it.
        showFolders(choosing: folderKey ?? model.composerDrafts.home.workspaceURL.map(ProjectSidebarPresentation.folderKey(for:)))
        selectAccount()
        showAccounts()
        load()
        checkAccounts()
        // The installs are looked for once, when none has been found yet, as New task does.
        guard model.runtimeSelections.connectedDescriptors.isEmpty, !lookedForRuntimes else { return }
        lookedForRuntimes = true
        Task {
            await model.runtimeSelections.findNewest()
            if !model.runtimeSelections.connectedDescriptors.isEmpty { show() }
        }
    }

    /// A harness's row: its mark and its name, which also names the row for UI Automation.
    private static func harnessItem(_ harness: HarnessKind) -> ListViewItem {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        if let icon = HarnessIcon.element(for: harness) {
            icon.verticalAlignment = .center
            row.children.append(icon)
        }
        let name = TextBlock()
        name.text = harness.displayName
        name.verticalAlignment = .center
        row.children.append(name)
        let item = ListViewItem()
        item.content = row
        try? AutomationProperties.setName(item, harness.displayName)
        return item
    }

    // MARK: Folder and account

    /// Each root of the projects the Mac's project menu lists, then a folder chosen directly; the one `key` names
    /// chosen, else the first.
    private func showFolders(choosing key: String?) {
        var seen = Set<String>()
        folders = model.projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project).flatMap { project in
            project.roots.map { root in
                Folder(name: project.roots.count > 1 ? "\(project.name) · \(root.lastPathComponent)" : project.name, url: root)
            }
        }.filter { seen.insert($0.key).inserted }
        if let chosenFolder, !seen.contains(ProjectSidebarPresentation.folderKey(for: chosenFolder)) {
            folders.append(Folder(name: chosenFolder.lastPathComponent, url: chosenFolder))
        }
        folderKey = (folders.first { $0.key == key } ?? folders.first)?.key
        isFilling = true
        folderBox.items.clear()
        for folder in folders { folderBox.items.append(folder.name) }
        folderBox.selectedIndex = Int32(folders.firstIndex { $0.key == folderKey } ?? -1)
        isFilling = false
    }

    /// Choose project…: a folder from Windows' own dialog, as New task's Choose project… chooses one.
    private func chooseFolder() {
        guard let chosen = WindowsFolderPicker.chooseFolder(window: windowHandle(), title: L10n.string("Choose project"))
        else { return }
        chosenFolder = chosen
        showFolders(choosing: ProjectSidebarPresentation.folderKey(for: chosen))
        log.write("import folder: \(folder?.name ?? chosen.lastPathComponent)")
        load()
    }

    /// The account the harness's new tasks start on, else its first, as the Mac's sheet chooses it.
    private func selectAccount() {
        accounts = model.connections.importChoices(for: harness)
        let selected = model.connections.selection[harness]
        accountID = accounts.first { $0.connection?.id == selected }?.id ?? accounts.first?.id ?? ""
    }

    /// The account menu, shown only when there is more than one account to choose.
    private func showAccounts() {
        accounts = model.connections.importChoices(for: harness)
        isFilling = true
        accountBox.items.clear()
        for choice in accounts { accountBox.items.append(choice.title) }
        accountBox.selectedIndex = Int32(accounts.firstIndex { $0.id == accountID } ?? -1)
        accountBox.visibility = accounts.count > 1 ? .visible : .collapsed
        isFilling = false
    }

    /// The harness's account folders looked for and its accounts read, as the Mac's sheet does when its harness
    /// changes: a default login without a sign-in gives way to a signed-in account once both have answered.
    private func checkAccounts() {
        let harness = self.harness
        Task {
            await model.connections.findUnsavedAccountHomes()
            await model.connections.check(defaultsOf: [harness], savedOf: [harness], runtimeSelections: model.runtimeSelections)
            guard harness == self.harness else { return }
            let before = accountID
            let choices = model.connections.importChoices(for: harness)
            if !choices.contains(where: { $0.id == accountID }) || accountID == AccountChoice.nativeID(for: harness) {
                selectAccount()
            }
            showAccounts()
            if accountID != before { load() }
        }
    }

    // MARK: The list

    /// The chosen folder's conversations under the chosen account, read again from the start.
    private func load() {
        listGeneration += 1
        let generation = listGeneration
        page = ImportableConversationPage(conversations: [])
        status.text = ""
        guard let folder else {
            isLoading = false
            showRows()
            return
        }
        isLoading = true
        showRows()
        let harness = self.harness
        let connection = account?.connection
        Task {
            do {
                let found = try await model.importableConversations(harness: harness, workspaceURL: folder.url,
                                                                    connection: connection)
                guard generation == listGeneration else { return }
                page = found
                log.write("import conversations: \(found.conversations.map(\.title).joined(separator: " | "))")
            } catch {
                guard generation == listGeneration else { return }
                status.text = error.localizedDescription
                log.write("import list failed: \(error.localizedDescription)")
            }
            isLoading = false
            showRows()
        }
    }

    /// The next page, after the rows shown; a list read again meanwhile keeps its own rows.
    private func loadMore() {
        guard let cursor = page.nextCursor, let folder, !isLoadingMore else { return }
        let generation = listGeneration
        isLoadingMore = true
        loadMoreButton.isEnabled = false
        let harness = self.harness
        let connection = account?.connection
        Task {
            defer {
                isLoadingMore = false
                loadMoreButton.isEnabled = true
            }
            do {
                let next = try await model.importableConversations(harness: harness, workspaceURL: folder.url,
                                                                   connection: connection, cursor: cursor)
                guard generation == listGeneration else { return }
                page = page.appending(next)
                showRows()
            } catch {
                guard generation == listGeneration else { return }
                status.text = error.localizedDescription
            }
        }
    }

    private func showRows() {
        list.children.clear()
        if isLoading {
            list.children.append(Self.detail(L10n.string("Loading…")))
        } else if folder != nil, page.conversations.isEmpty, status.text.isEmpty {
            list.children.append(Self.detail(L10n.string("No conversations in this folder.")))
        }
        let now = Date()
        for conversation in page.conversations { list.children.append(row(conversation, now: now)) }
        loadMoreButton.visibility = page.nextCursor != nil && !isLoading ? .visible : .collapsed
    }

    /// One conversation: its title and when it was last active, and whether it is a task already or still open in
    /// another app. Choosing it imports it, or opens the task that continues it.
    private func row(_ conversation: ImportableConversation, now: Date) -> Button {
        let words = StackPanel()
        words.spacing = 2
        let title = TextBlock()
        title.text = conversation.title
        title.maxLines = 1
        title.textTrimming = .characterEllipsis
        words.children.append(title)
        // An ACP agent may list a session without its time.
        if conversation.updatedAt != .distantPast {
            words.children.append(Self.detail(now.timeIntervalSince(conversation.updatedAt) < 60 ? RelativeTime.now()
                : RelativeTime.ago(conversation.updatedAt, relativeTo: now)))
        }
        let content = Grid()
        content.columnSpacing = 12
        let wordsColumn = ColumnDefinition()
        wordsColumn.width = GridLength(value: 1, gridUnitType: .star)
        let markColumn = ColumnDefinition()
        markColumn.width = GridLength(value: 0, gridUnitType: .auto)
        content.columnDefinitions.append(wordsColumn)
        content.columnDefinitions.append(markColumn)
        content.children.append(words)
        let imported = model.existingTask(for: conversation, connection: account?.connection) != nil
        let mark = importingID == conversation.id ? L10n.string("Loading…")
            : imported ? L10n.string("Open")
            : conversation.isOpenElsewhere ? L10n.string("Open in another app") : nil
        if let mark {
            let text = Self.detail(mark)
            text.verticalAlignment = .center
            try? Grid.setColumn(text, 1)
            content.children.append(text)
        }
        let button = Button()
        button.content = content
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        // A row of the list rather than a button among buttons: no fill or frame until the pointer is on it.
        button.background = SolidColorBrush(UWP.Color(a: 0, r: 0, g: 0, b: 0))
        button.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.padding = Thickness(left: 12, top: 8, right: 12, bottom: 8)
        button.isEnabled = importingID == nil
        try? AutomationProperties.setName(button, conversation.title)
        button.click.addHandler { [weak self] _, _ in self?.importConversation(conversation) }
        return button
    }

    /// Imports the conversation, or finds the task that already continues it, and has the window show it. Nothing
    /// starts: the task attaches when the person first sends.
    private func importConversation(_ conversation: ImportableConversation) {
        guard importingID == nil else { return }
        importingID = conversation.id
        status.text = ""
        showRows()
        let connection = account?.connection
        Task {
            let task = await model.importConversation(conversation, connection: connection)
            importingID = nil
            if let task {
                log.write("imported: \(task.title)")
                onImported?()
            } else {
                let failure = model.bootstrapError ?? L10n.string("The conversation could not be imported.")
                status.text = failure
                log.write("import failed: \(failure)")
            }
            showRows()
        }
    }

    private static func text(_ words: String) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.textWrapping = .wrap
        return block
    }

    private static func detail(_ words: String) -> TextBlock {
        let block = text(words)
        block.fontSize = 12
        block.opacity = 0.6
        return block
    }
}
