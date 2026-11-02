import SwiftUI

/// The mailbox in the sidebar, in the task list's place, under the same Home, Scheduled tasks and
/// section words. It shows one of two things, as Mail on a narrow screen does: the accounts and their
/// folders, or the list of the mailbox chosen there, every inbox together to begin with. Typing narrows
/// the list at once; a pause asks each service's own search, so older mail is found without being
/// kept here.
struct MailSidebar: View {
    let center: MailboxCenter
    @Bindable var window: MailWindowState
    let accountMenu: SidebarAccountMenuContext
    let onHome: () -> Void
    var onShowSchedules: (() -> Void)?
    let onSelectSection: (ShellSection) -> Void
    let onNewMessage: () -> Void
    let onRefresh: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            SidebarPlacesHeader(onHome: onHome, onShowSchedules: onShowSchedules, section: .mail,
                                onSelectSection: onSelectSection)

            SidebarSearchField(placeholder: L10n.string("Search mail"), text: $window.searchText)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 4)
                .onSubmit { window.showsFolders = false; window.runSearch(in: center) }
                .task(id: window.searchText) {
                    guard !window.searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
                        window.clearSearch()
                        return
                    }
                    window.showsFolders = false
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    window.runSearch(in: center)
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    if window.showsFolders {
                        MailFolderTree(center: center, window: window)
                    } else {
                        listHeading
                        let rows = window.rows(in: center)
                        let showsAccount = window.mailbox == .allInboxes && center.accounts.count > 1
                        let setAside = center.folder(window.mailbox)?.role.isSetAside == true
                        ForEach(rows) { thread in
                            MailThreadRow(thread: thread, me: center.account(thread.id.accountID)?.address,
                                          account: showsAccount ? center.account(thread.id.accountID) : nil,
                                          isSetAside: setAside, isSelected: window.selection == thread.id) {
                                window.select(thread.id, in: center)
                            }
                        }
                        if rows.isEmpty { emptyLine }
                        // The list goes on as its end comes into view.
                        if !rows.isEmpty, window.searchResults == nil, window.searchText.isEmpty,
                           center.hasMore(window.mailbox) {
                            HStack { Spacer(); ProgressView().controlSize(.mini); Spacer() }
                                .frame(height: 32)
                                .onAppear { Task { await center.loadMore(window.mailbox) } }
                                .accessibilityLabel(L10n.string("Loading mail…"))
                        }
                    }
                }
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            SidebarAccountButton(context: accountMenu).padding(.horizontal, 4).padding(.vertical, 5)
        }
        .background(ParityTheme.sidebar)
    }

    /// Back to the folders, the mailbox listed and its account, and for spam or the trash what happens
    /// to mail there.
    private var listHeading: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 8) {
                Button { window.showsFolders = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10 * scale, weight: .semibold))
                        Text(L10n.string("Mailboxes"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Mailboxes"))
                Spacer()
                headingButton(L10n.string("New message"), systemName: "square.and.pencil", action: onNewMessage)
                if center.isLoading || window.isSearching || center.loadingFolders.contains(window.mailbox) {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                } else {
                    headingButton(L10n.string("Refresh mail"), systemName: "arrow.clockwise") {
                        onRefresh()
                        Task { await center.load(window.mailbox) }
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            let folder = center.folder(window.mailbox)
            HStack(spacing: 6) {
                Image(systemName: MailFolderIcon.name(window.searchResults != nil ? nil : folder?.role, all: window.mailbox == .allInboxes))
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(folder?.role.isSetAside == true ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                Text(window.searchResults != nil ? L10n.string("Search results") : folder?.name ?? L10n.string("All inboxes"))
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let account = window.mailbox.accountID.flatMap(center.account) {
                    Text(account.shortName).font(.system(size: 11 * scale)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if window.searchResults == nil, let folder, folder.role.isSetAside,
               let account = window.mailbox.accountID.flatMap(center.account) {
                Text(MailFolderIcon.note(folder.role, provider: account.provider))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13 - SidebarMetrics.rowInset)
        .padding(.bottom, 6)
    }

    private func headingButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .help(title)
        .accessibilityLabel(title)
        .frame(width: 22, height: 22)
    }

    @ViewBuilder private var emptyLine: some View {
        let text: String? = if window.isSearching { L10n.string("Searching…") }
            else if window.searchResults != nil || !window.searchText.isEmpty { L10n.string("No messages found") }
            else if center.accounts.isEmpty { nil }
            else if center.isLoading || center.loadingFolders.contains(window.mailbox) { L10n.string("Loading mail…") }
            else if window.mailbox == .allInboxes || center.folder(window.mailbox)?.role == .inbox { L10n.string("No mail in the inbox") }
            else { L10n.string("No mail here") }
        if let text {
            Text(text).font(.system(size: 12 * scale)).foregroundStyle(.secondary).padding(10)
        }
    }
}

/// The accounts and their folders: every inbox together first, then each account's inbox, starred,
/// sent, drafts, all mail, spam and trash as its service names them, and its labels, each account and
/// its labels folding as the person leaves them.
struct MailFolderTree: View {
    let center: MailboxCenter
    @Bindable var window: MailWindowState
    @Environment(\.yardletInterfaceScale) private var scale

    /// One line of the tree. Folder IDs repeat across accounts (every Gmail account has `INBOX`), so a
    /// line is known by its account too.
    private enum Line: Identifiable {
        case account(MailAccount, folded: Bool)
        case folder(MailFolder, MailAccount, depth: Int)
        case labels(MailAccount, folded: Bool)
        case failure(MailAccount, String)
        case gap(MailAccount)

        var id: String {
            switch self {
            case let .account(account, _): "\(account.id)"
            case let .folder(folder, account, _): "\(account.id)/\(folder.id)"
            case let .labels(account, _): "\(account.id)/labels"
            case let .failure(account, _): "\(account.id)/failure"
            case let .gap(account): "\(account.id)/gap"
            }
        }
    }

    private var lines: [Line] {
        center.accounts.flatMap { account -> [Line] in
            let folded = window.foldedAccounts.contains(account.id)
            var lines: [Line] = [.account(account, folded: folded)]
            if !folded {
                let folders = center.folders[account.id] ?? []
                lines += folders.filter { $0.role != .label }.map { .folder($0, account, depth: 1) }
                let labels = folders.filter { $0.role == .label }
                if !labels.isEmpty {
                    let labelsFolded = window.foldedLabels.contains(account.id)
                    lines.append(.labels(account, folded: labelsFolded))
                    if !labelsFolded { lines += labels.map { .folder($0, account, depth: 2 + $0.depth) } }
                }
                if folders.isEmpty, let failure = center.failures[account.id] { lines.append(.failure(account, failure.message)) }
            }
            return lines + [.gap(account)]
        }
    }

    var body: some View {
        row(title: L10n.string("All inboxes"), systemName: MailFolderIcon.name(nil, all: true), depth: 0,
            count: center.unreadInInboxes, selection: .allInboxes)
            .padding(.bottom, 6)
        ForEach(lines) { line in
            switch line {
            case let .account(account, folded):
                disclosure(account.address, folded: folded, depth: 0) {
                    window.foldedAccounts.formSymmetricDifference([account.id])
                }
            case let .folder(folder, account, depth):
                row(folder, of: account, depth: depth)
            case let .labels(account, folded):
                disclosure(L10n.string("Labels"), folded: folded, depth: 1) {
                    window.foldedLabels.formSymmetricDifference([account.id])
                }
            case let .failure(_, message):
                Text(message).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                    .padding(.leading, 30).padding(.vertical, 4)
            case .gap:
                Spacer().frame(height: 6)
            }
        }
    }

    private func row(_ folder: MailFolder, of account: MailAccount, depth: Int) -> some View {
        row(title: folder.name, systemName: MailFolderIcon.name(folder.role, all: false), depth: depth,
            count: folder.unreadCount, tint: folder.role.isSetAside ? .red : nil,
            selection: .folder(accountID: account.id, folderID: folder.id), detail: account.address)
    }

    private func row(title: String, systemName: String, depth: Int, count: Int?, tint: Color? = nil,
                     selection: MailboxSelection, detail: String? = nil) -> some View {
        let isSelected = window.mailbox == selection
        return Button { window.show(selection, in: center) } label: {
            HStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .frame(width: 18 * scale)
                Text(title).font(.system(size: 13 * scale)).lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11.5 * scale)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.leading, 8 + CGFloat(depth) * 14)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.rowHeight * scale)
            .background(isSelected ? ParityTheme.selectedFill : .clear, in: SidebarMetrics.rowShape())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(title)
        .accessibilityValue([detail, count.flatMap { $0 > 0 ? L10n.format("%lld unread", $0) : nil }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// An account's or its labels' heading, which folds what is under it.
    private func disclosure(_ title: String, folded: Bool, depth: Int, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 12 * scale)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: SidebarMetrics.projectHeaderFontSize * scale, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .frame(height: SidebarMetrics.projectHeaderHeight * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(title)
        .accessibilityValue(L10n.string(folded ? "Collapsed" : "Expanded"))
    }
}

/// The symbols of the folders, as Mail draws them, and what the mailbox says about spam and the trash.
enum MailFolderIcon {
    static func name(_ role: MailFolderRole?, all: Bool) -> String {
        guard let role else { return all ? "tray.2" : "magnifyingglass" }
        return switch role {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        case .label: "tag"
        }
    }

    static func note(_ role: MailFolderRole, provider: MailProvider) -> String {
        switch (role, provider) {
        case (.spam, .gmail): L10n.string("Gmail deletes mail that has been in Spam for 30 days.")
        case (.trash, .gmail): L10n.string("Gmail deletes mail that has been in the Trash for 30 days.")
        case (.spam, _): L10n.string("Mail the service took for spam.")
        default: L10n.string("Mail moved to the trash.")
        }
    }
}

/// A thread in the list: its senders and time, the subject, and the account with the first words.
struct MailThreadRow: View {
    let thread: MailThreadSummary
    /// The address of the thread's account, named "me".
    let me: String?
    /// The thread's account, named when the list mixes several.
    let account: MailAccount?
    /// Spam or the trash: drawn dimmer, so the list reads as mail set aside.
    var isSetAside = false
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                Circle()
                    .fill(thread.isUnread ? ParityTheme.accent : .clear)
                    .frame(width: 7 * scale, height: 7 * scale)
                    .padding(.top, 5 * scale)
                    .frame(width: 16 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    HStack(spacing: 4) {
                        Text(MailText.senders(thread, me: me))
                            .font(.system(size: 13 * scale, weight: thread.isUnread ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if thread.hasAttachments {
                            Image(systemName: "paperclip").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                        }
                        Text(MailText.listTime(thread.date))
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        if thread.hasDraft {
                            Text(L10n.string("Draft")).foregroundStyle(.orange)
                        }
                        Text(MailText.subject(thread.subject)).lineLimit(1)
                    }
                    .font(.system(size: 12.5 * scale, weight: thread.isUnread ? .medium : .regular))
                    Text(account.map { "\($0.shortName) · \(thread.snippet)" } ?? thread.snippet)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(isSetAside ? 0.72 : 1)
            .padding(.vertical, 7 * scale)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ParityTheme.selectedFill : .clear, in: SidebarMetrics.rowShape())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MailText.senders(thread, me: me))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }
}

extension MailThreadRow {
    /// Unread, the subject, the account when named, and the time.
    fileprivate var accessibilityValue: String {
        var parts: [String] = []
        if thread.isUnread { parts.append(L10n.string("Unread")) }
        parts.append(MailText.subject(thread.subject))
        if let account { parts.append(account.address) }
        parts.append(MailText.listTime(thread.date))
        return parts.joined(separator: ", ")
    }
}

/// The mailbox the window's sidebar words read: the Mail word shows while it is on, with a mark for mail
/// that came since it was last shown.
private struct MailboxKey: EnvironmentKey {
    static let defaultValue: MailboxCenter? = nil
}

extension EnvironmentValues {
    var mailbox: MailboxCenter? {
        get { self[MailboxKey.self] }
        set { self[MailboxKey.self] = newValue }
    }
}

/// The dot after the Mail word. It reads the mailbox itself, so a new mark redraws only it.
struct MailUnseenMark: View {
    let mailbox: MailboxCenter
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        if mailbox.hasUnseenMail {
            Circle()
                .fill(ParityTheme.accent)
                .frame(width: 6 * scale, height: 6 * scale)
                .accessibilityHidden(true)
        }
    }
}
