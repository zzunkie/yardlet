import SwiftUI

/// Continues a conversation another app or CLI started, as a Yardlet task with the same session.
/// The list is one project folder's history under the chosen account: Claude Code's, Codex's,
/// Antigravity CLI's, and that of each other ACP agent installed (`ACPSessionHistory`). Codex's can
/// be searched; a conversation opened from a search shows its match.
struct ImportConversationSheet: View {
    let model: AppModel
    let projects: [Project]
    let initialWorkspace: URL?
    let onDismiss: () -> Void

    @State private var harness: HarnessKind
    @State private var workspacePath: String
    @State private var accountID: String
    @State private var page = ImportableConversationPage(conversations: [])
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var error: String?
    @State private var importingID: String?
    /// What the search field holds, and the search the list shows (submitted with Return or Search).
    @State private var searchTerm: String
    @State private var search: String
    @State private var selectedID: String?

    /// - Parameters:
    ///   - initialHarness: the harness the sheet opens on; Claude Code unless named.
    ///   - initialSearchTerm: for Codex, a search the list shows at once.
    init(model: AppModel, projects: [Project], initialWorkspace: URL?, initialHarness: HarnessKind? = nil,
         initialSearchTerm: String? = nil, onDismiss: @escaping () -> Void) {
        self.model = model
        self.projects = projects
        self.initialWorkspace = initialWorkspace
        self.onDismiss = onDismiss
        let harness = initialHarness ?? .claudeCode
        let search = harness == .codex ? (initialSearchTerm ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Everything the list is read for is set before the sheet first draws, so opening it reads
        // the provider once rather than again when the first values arrive.
        let folders = Self.folders(in: projects)
        _harness = State(initialValue: harness)
        _workspacePath = State(initialValue:
            (initialWorkspace.flatMap { url in folders.first { $0.url == url } } ?? folders.first)?.id ?? "")
        _accountID = State(initialValue: Self.accountID(for: harness, in: model.connections))
        _searchTerm = State(initialValue: search)
        _search = State(initialValue: search)
    }

    private struct Folder: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.standardizedFileURL.path(percentEncoded: false) }
    }

    private var folders: [Folder] { Self.folders(in: projects) }

    private static func folders(in projects: [Project]) -> [Folder] {
        var seen = Set<String>()
        return projects.flatMap { project in
            project.roots.map { root in
                Folder(name: project.roots.count > 1 ? "\(project.name) · \(root.lastPathComponent)" : project.name, url: root)
            }
        }.filter { seen.insert($0.id).inserted }
    }

    private var accounts: [AccountChoice] { Self.accounts(for: harness, in: model.connections) }

    /// Claude Code, Codex and Antigravity CLI, then the other ACP agents installed, in the catalog's order.
    private var harnesses: [HarnessKind] {
        [.claudeCode, .codex, .antigravityCLI] + HarnessCatalog.builtIns.map(\.id).filter {
            ACPSessionHistory.reads($0) && model.runtimeSelections.selectedURL(for: $0) != nil
        }
    }

    /// The harness's accounts, then its folders found with a login or history that are not saved
    /// (importing under one saves it).
    private static func accounts(for harness: HarnessKind, in connections: ProviderConnectionStore) -> [AccountChoice] {
        connections.importChoices(for: harness)
    }

    /// The account the harness's new tasks start on, else its first.
    private static func accountID(for harness: HarnessKind, in connections: ProviderConnectionStore) -> String {
        let accounts = accounts(for: harness, in: connections)
        let selected = connections.selection[harness]
        return accounts.first { $0.connection?.id == selected }?.id ?? accounts.first?.id ?? ""
    }

    private var account: AccountChoice? { accounts.first { $0.id == accountID } ?? accounts.first }

    /// Only Codex can search its history; its App Server does it.
    private var searches: Bool { harness == .codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string("Import conversation")).font(.headline)
                Spacer()
                Button(L10n.string("Done"), action: onDismiss).keyboardShortcut(.cancelAction)
            }
            Text(L10n.string("Continue a conversation started in another app or CLI. Its history stays where it is."))
                .font(.callout).foregroundStyle(.secondary)
            Picker(L10n.string("Harness"), selection: $harness) {
                ForEach(harnesses) { harness in
                    Text(harnesses.count > 3 ? harness.shortDisplayName : harness.displayName).tag(harness)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: harnesses.count > 3 ? nil : 420)
            HStack(spacing: 12) {
                Picker(L10n.string("Project"), selection: $workspacePath) {
                    ForEach(folders) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 320)
                Picker(L10n.string("Account"), selection: $accountID) {
                    ForEach(accounts) { Text($0.title).tag($0.id) }
                }
                .frame(maxWidth: 280)
            }
            if searches { searchField }
            list
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            if harness == .claudeCode {
                Text(L10n.string("A conversation still open in another app can be read here, and continues here once you close it there."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 660, height: 540)
        .onChange(of: harness) { _, _ in
            selectAccount()
            searchTerm = ""
            search = ""
        }
        .task(id: "\(harness.rawValue)|\(workspacePath)|\(accountID)|\(search)") { await load() }
        .task(id: harness) {
            await model.connections.findUnsavedAccountHomes()
            // The default login and the saved accounts: one without a login gives way to a
            // signed-in account once both have answered.
            await model.connections.check(defaultsOf: [harness], savedOf: [harness],
                runtimeSelections: model.runtimeSelections)
            if !accounts.contains(where: { $0.id == accountID }) || accountID == "native:\(harness.rawValue)" {
                selectAccount()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("Search Codex history"), text: $searchTerm)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.string("Search Codex history"))
                .accessibilityHint(L10n.string("Searches Codex history when submitted."))
                .onSubmit(submitSearch)
            Button(L10n.string("Search"), action: submitSearch)
                .disabled(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines) == search)
        }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if isLoading && page.conversations.isEmpty {
                    ProgressView().padding(24)
                } else if page.conversations.isEmpty {
                    Text(search.isEmpty ? L10n.string("No conversations in this folder.")
                         : L10n.string("No matching Codex history"))
                        .foregroundStyle(.secondary).padding(24)
                }
                ForEach(page.conversations) { conversation in
                    row(conversation)
                }
                if page.nextCursor != nil {
                    Button(L10n.string("Load more history")) { Task { await loadMore() } }
                        .disabled(isLoadingMore)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(ParityTheme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .focusable()
        .accessibilityLabel(L10n.string("Import conversation"))
        .accessibilityHint(L10n.string("Use the arrow keys to select a history result, then press Return."))
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.return) {
            guard let conversation = page.conversations.first(where: { $0.id == selectedID }), canImport(conversation)
            else { return .ignored }
            Task { await importConversation(conversation) }
            return .handled
        }
    }

    private func row(_ conversation: ImportableConversation) -> some View {
        let imported = model.existingTask(for: conversation, connection: account?.connection) != nil
        let isSelected = selectedID == conversation.id
        return Button { Task { await importConversation(conversation) } } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let snippet = conversation.snippet, !snippet.isEmpty, snippet != conversation.title {
                        highlighted(snippet).font(.system(size: 11.5)).lineLimit(2)
                    }
                    // An ACP agent may list a session without its time.
                    if conversation.updatedAt != .distantPast {
                        Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if importingID == conversation.id {
                    ProgressView().controlSize(.small)
                } else if imported {
                    Text(L10n.string("Open")).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if conversation.isOpenElsewhere {
                    Text(L10n.string("Open in another app")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(isSelected ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canImport(conversation))
        .accessibilityLabel(CodexHistorySearchProjection.accessibleSummary(title: conversation.title,
            snippet: conversation.snippet, updatedLabel: conversation.updatedAt.formatted(.relative(presentation: .named))))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(conversation.title)
    }

    /// The search's words marked in the matching text, as Codex's own history search shows them.
    private func highlighted(_ text: String) -> Text {
        CodexHistorySearchProjection.segments(text, query: search).reduce(into: Text("")) { result, segment in
            let part = Text(segment.text).foregroundStyle(segment.isMatch ? ParityTheme.accent : .secondary)
            result = result + (segment.isMatch ? part.bold() : part)
        }
    }

    /// One still open in another app comes in too, followed read-only until that app lets it go.
    private func canImport(_ conversation: ImportableConversation) -> Bool {
        importingID == nil
    }

    private func selectAccount() {
        accountID = Self.accountID(for: harness, in: model.connections)
    }

    private func submitSearch() {
        search = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func moveSelection(by offset: Int) {
        selectedID = CodexHistorySearchProjection.targetID(in: page.conversations.map(\.id), selectedID: selectedID,
                                                           offset: offset)
    }

    private func load() async {
        guard let folder = folders.first(where: { $0.id == workspacePath }) else {
            page = ImportableConversationPage(conversations: [])
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let found = try await model.importableConversations(harness: harness, workspaceURL: folder.url,
                connection: account?.connection, searchTerm: searches ? search : "")
            guard !Task.isCancelled else { return }
            page = found
            if !found.conversations.contains(where: { $0.id == selectedID }) { selectedID = nil }
        } catch {
            guard !Task.isCancelled else { return }
            page = ImportableConversationPage(conversations: [])
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let cursor = page.nextCursor, let folder = folders.first(where: { $0.id == workspacePath }),
              !isLoadingMore else { return }
        let request = (harness, workspacePath, accountID, search)
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await model.importableConversations(harness: harness, workspaceURL: folder.url,
                connection: account?.connection, searchTerm: searches ? search : "", cursor: cursor)
            // A list that changed meanwhile keeps its own rows.
            guard request == (harness, workspacePath, accountID, search) else { return }
            page = page.appending(next)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importConversation(_ conversation: ImportableConversation) async {
        importingID = conversation.id
        defer { importingID = nil }
        let selection = search.isEmpty ? nil
            : CodexHistorySearchSelection(query: search, snippet: conversation.snippet,
                                          threadID: conversation.providerSessionID)
        if let task = await model.importConversation(conversation, connection: account?.connection,
                                                     historySelection: selection) {
            // The imported task opens even when the window was showing another sidebar section.
            model.revealTask(task.id)
            onDismiss()
        } else {
            error = model.bootstrapError ?? L10n.string("The conversation could not be imported.")
        }
    }
}
