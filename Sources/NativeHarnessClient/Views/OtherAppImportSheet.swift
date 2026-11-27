import SwiftUI

/// Imports the conversations open in the Claude and Codex apps all at once. The list is grouped by
/// where each one goes in Yardlet (a project, or Chats), each row with a checkbox; one Import brings
/// in the selection without opening any task and stays until it is done. Each conversation keeps
/// its session and history where the other app left them. The per-folder import sheet stays the
/// place for searching Codex history.
struct OtherAppImportSheet: View {
    let model: AppModel
    let onDismiss: () -> Void

    @State private var claudeAccountID: String
    @State private var codexAccountID: String
    @State private var listing = OtherAppConversations()
    /// The list as shown: where each conversation goes, worked out once per reading.
    @State private var groups: [Group] = []
    @State private var isLoading = true
    @State private var selection = Set<String>()
    @State private var failures: [String: String] = [:]
    @State private var progress: (done: Int, total: Int)?

    init(model: AppModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        _claudeAccountID = State(initialValue: model.connections.defaultImportChoice(for: .claudeCode)?.id ?? "")
        _codexAccountID = State(initialValue: model.connections.defaultImportChoice(for: .codex)?.id ?? "")
    }

    private var isImporting: Bool { progress != nil }

    // MARK: Accounts

    /// Each harness's accounts, then its folders found with a login or history that are not saved
    /// (importing under one saves it). Each starts on the account its new tasks start on.
    private var claudeAccounts: [AccountChoice] { model.connections.importChoices(for: .claudeCode) }
    private var codexAccounts: [AccountChoice] { model.connections.importChoices(for: .codex) }

    private var claudeConnection: ProviderConnection? {
        (claudeAccounts.first { $0.id == claudeAccountID } ?? claudeAccounts.first)?.connection
    }

    private var codexConnection: ProviderConnection? {
        (codexAccounts.first { $0.id == codexAccountID } ?? codexAccounts.first)?.connection
    }

    // MARK: Rows

    private struct Group: Identifiable {
        let destination: ConversationImportDestination
        let conversations: [ImportableConversation]
        var id: String { destination.id }
    }

    /// Projects by their most recent conversation, then Chats; each group most recent first.
    private func grouped(_ conversations: [ImportableConversation]) -> [Group] {
        Dictionary(grouping: conversations) { model.importDestination(for: $0) }
            .map { destination, conversations in
                Group(destination: destination, conversations: conversations.sorted { $0.updatedAt > $1.updatedAt })
            }
            .sorted { lhs, rhs in
                if lhs.destination.isChats != rhs.destination.isChats { return !lhs.destination.isChats }
                let lhsLatest = lhs.conversations.first?.updatedAt ?? .distantPast
                let rhsLatest = rhs.conversations.first?.updatedAt ?? .distantPast
                return lhsLatest == rhsLatest ? lhs.destination.name < rhs.destination.name : lhsLatest > rhsLatest
            }
    }

    private func existingTask(for conversation: ImportableConversation) -> SessionRecord? {
        let connection: ProviderConnection? = switch conversation.harness {
        case .claudeCode: claudeConnection
        case .codex: codexConnection
        default: nil
        }
        return model.existingTask(for: conversation, connection: connection)
    }

    /// The conversations not yet in Yardlet, which the checkboxes choose among.
    private var importable: [ImportableConversation] {
        listing.all.filter { existingTask(for: $0) == nil }
    }

    private var selectAll: Binding<Bool> {
        Binding(get: {
            let ids = importable.map(\.id)
            return !ids.isEmpty && ids.allSatisfy(selection.contains)
        }, set: { value in
            selection = value ? Set(importable.map(\.id)) : []
        })
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string("Import Conversations from Other Apps")).font(.headline)
                Spacer()
                Button(L10n.string("Done"), action: onDismiss)
                    .keyboardShortcut(MacShortcut.dismiss.binding)
                    .disabled(isImporting)
            }
            Text(L10n.string("Conversations from the Claude and Codex apps, Claude Code and Codex run elsewhere, and Antigravity CLI. Their history stays where it is."))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Toggle(L10n.string("Select All"), isOn: selectAll)
                    .toggleStyle(.checkbox)
                    .disabled(importable.isEmpty || isImporting)
                Spacer()
                if claudeAccounts.count > 1 {
                    Picker(L10n.string("Claude account"), selection: $claudeAccountID) {
                        ForEach(claudeAccounts) { Text($0.title).tag($0.id) }
                    }
                    .frame(maxWidth: 300)
                    .disabled(isImporting)
                }
                if codexAccounts.count > 1 {
                    Picker(L10n.string("Codex account"), selection: $codexAccountID) {
                        ForEach(codexAccounts) { Text($0.title).tag($0.id) }
                    }
                    .frame(maxWidth: 300)
                    .disabled(isImporting)
                }
            }
            list
            ForEach([listing.codexError, listing.antigravityError].compactMap { $0 }, id: \.self) { error in
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            footer
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .interactiveDismissDisabled(isImporting)
        .task { await model.connections.findUnsavedAccountHomes() }
        .task(id: claudeAccountID + "|" + codexAccountID) { await load() }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if isLoading && listing.all.isEmpty {
                    ProgressView().padding(24).frame(maxWidth: .infinity)
                } else if listing.all.isEmpty {
                    Text(L10n.string("No conversations are open in the Claude or Codex app or Antigravity CLI."))
                        .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity)
                }
                ForEach(groups) { group in
                    Text(group.destination.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.conversations) { row($0) }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(ParityTheme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(L10n.string("Import Conversations from Other Apps"))
    }

    private func row(_ conversation: ImportableConversation) -> some View {
        let existing = existingTask(for: conversation)
        let updated = conversation.updatedAt.formatted(.relative(presentation: .named))
        let folder = ProjectSidebarPresentation.abbreviatedPath(for: conversation.workspaceURL)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(conversation.title, isOn: Binding(
                get: { existing != nil || selection.contains(conversation.id) },
                set: { value in
                    if value { selection.insert(conversation.id) } else { selection.remove(conversation.id) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(existing != nil || isImporting)
            HarnessIdentityIcon(harness: conversation.harness)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(folder) · \(updated)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let failure = failures[conversation.id] {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let existing {
                Button(L10n.string("Open in Yardlet")) {
                    model.revealTask(existing.id)
                    onDismiss()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(isImporting)
            } else if conversation.isOpenElsewhere {
                Text(L10n.string("Open in another app")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleSummary(conversation, folder: folder, updated: updated, imported: existing != nil))
        .help(conversation.title)
    }

    private func accessibleSummary(_ conversation: ImportableConversation, folder: String, updated: String,
                                   imported: Bool) -> String {
        var parts = [conversation.title, conversation.harness.displayName, folder, updated]
        if imported { parts.append(L10n.string("Already in Yardlet")) }
        else if conversation.isOpenElsewhere { parts.append(L10n.string("Open in another app")) }
        if let failure = failures[conversation.id] { parts.append(failure) }
        return parts.joined(separator: ", ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
                Text(L10n.format("Importing %lld of %lld", Int64(progress.done), Int64(progress.total)))
                    .font(.callout).foregroundStyle(.secondary)
            } else if !failures.isEmpty {
                Text(L10n.format("%lld could not be imported", Int64(failures.count)))
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Text(L10n.format("%lld selected", Int64(selection.count)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("Import")) { Task { await importSelection() } }
                .keyboardShortcut(MacShortcut.confirmDialog.binding)
                .disabled(selection.isEmpty || isImporting)
        }
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let found = await model.otherAppConversations(claudeConnection: claudeConnection, codexConnection: codexConnection)
        guard !Task.isCancelled else { return }
        listing = found
        groups = grouped(found.all)
        let ids = Set(found.all.map(\.id))
        selection.formIntersection(ids)
    }

    /// Imports the chosen conversations in the list's order and stays open until they are all done.
    /// The sheet closes when every one came in; otherwise it shows why each other one did not.
    private func importSelection() async {
        let chosen = groups.flatMap(\.conversations).filter { selection.contains($0.id) && existingTask(for: $0) == nil }
        guard !chosen.isEmpty else { return }
        failures = [:]
        progress = (0, chosen.count)
        let found = await model.importConversations(chosen, claudeConnection: claudeConnection,
                                                    codexConnection: codexConnection) { _ in
            progress = progress.map { ($0.done + 1, $0.total) }
        }
        progress = nil
        failures = found
        selection = Set(found.keys)
        if found.isEmpty { onDismiss() }
    }
}
