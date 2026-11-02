import SwiftUI

/// What the mailbox's buttons do, given by the window.
struct MailActions {
    enum ComposeKind: Hashable { case reply, replyAll, forward }

    var compose: (MailThread, MailMessage, ComposeKind) -> Void = { _, _, _ in }
    var editDraft: (MailThread, MailMessage) -> Void = { _, _ in }
    var sendDraft: (MailThread, MailMessage) -> Void = { _, _ in }
    var discardDraft: (MailThread, MailMessage) -> Void = { _, _ in }
    /// Starts a task with the thread named in its composer.
    var askAgent: (MailThread) -> Void = { _ in }
    /// The thread on the service's web mail, in the built-in browser.
    var openOriginal: (URL) -> Void = { _ in }
    /// A link chosen in a message.
    var openLink: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
}

/// The mailbox beside its list: the chosen thread, or what to do when there is none.
struct MailContent: View {
    let center: MailboxCenter
    @Bindable var window: MailWindowState
    let actions: MailActions

    var body: some View {
        Group {
            if center.accounts.isEmpty {
                placeholder(systemName: "envelope", title: L10n.string("No accounts in the mailbox"),
                            detail: L10n.string("Connect Gmail in Settings › Connectors, and its inbox shows here.")) {
                    Button(L10n.string("Open Connectors"), action: actions.openSettings)
                }
            } else if let thread = window.thread, let account = center.account(thread.summary.id.accountID) {
                MailThreadView(thread: thread, account: account,
                               role: window.searchResults == nil ? center.folder(window.mailbox)?.role ?? .inbox : .inbox,
                               actions: actions, apply: { window.apply($0, in: center) })
                    .id(thread.summary.id)
            } else if window.isOpening {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = window.failure {
                placeholder(systemName: "exclamationmark.triangle", title: L10n.string("This message could not be read"),
                            detail: failure.message) {
                    Button(L10n.string("Try again")) { window.select(window.selection, in: center) }
                }
            } else {
                placeholder(systemName: "envelope", title: L10n.string("Mail"),
                            detail: L10n.string("Choose a message on the left.")) { EmptyView() }
            }
        }
        .background(ParityTheme.canvas)
    }

    private func placeholder<Actions: View>(systemName: String, title: String, detail: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemName).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            actions()
        }
        .font(.system(size: 13))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An opened thread: its account and actions on a bar, then the subject and each message, the latest
/// open and the earlier ones folded to a line, with reply, reply all and forward under the last.
struct MailThreadView: View {
    let thread: MailThread
    let account: MailAccount
    /// The folder the thread is read from: spam and the trash offer to take it out instead of filing it,
    /// and do not hand it to an agent.
    var role: MailFolderRole = .inbox
    let actions: MailActions
    let apply: (MailThreadChange) -> Void
    @State private var expanded: Set<String> = []
    @Environment(\.yardletInterfaceScale) private var scale

    static let readingWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            if role.isSetAside { setAsideNote }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(MailText.subject(thread.summary.subject))
                        .font(.system(size: 20 * scale, weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.bottom, 14)
                    ForEach(thread.messages) { message in
                        let isLast = message.id == lastMessageID
                        if isLast || expanded.contains(message.id) || message.isDraft {
                            MailMessageView(message: message, thread: thread, me: account.address, actions: actions,
                                            fold: isLast || message.isDraft ? nil : { expanded.remove(message.id) })
                        } else {
                            MailFoldedMessage(message: message, me: account.address) { expanded.insert(message.id) }
                        }
                        Rectangle().fill(ParityTheme.separator).frame(height: 1)
                    }
                    replyButtons.padding(.top, 16)
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .padding(.horizontal, ParityTheme.conversationInset)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The newest message that is not a draft, open by default.
    private var lastMessageID: String? {
        thread.messages.last { !$0.isDraft }?.id ?? thread.messages.last?.id
    }

    private var bar: some View {
        HStack(spacing: 2) {
            Text("\(account.address) · \(account.provider.serviceName)")
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            switch role {
            case .spam:
                textButton(L10n.string("Not spam"), systemName: "tray.and.arrow.down") { apply(.notSpam) }
            case .trash:
                textButton(L10n.string("Move out of the Trash"), systemName: "arrow.uturn.backward") { apply(.untrash) }
            default:
                textButton(L10n.string("Ask an agent"), systemName: "sparkles") { actions.askAgent(thread) }
            }
            if role == .inbox {
                barButton(L10n.string("Archive"), systemName: "archivebox") { apply(.archived) }
            }
            barButton(L10n.string(thread.summary.isUnread ? "Mark as read" : "Mark as unread"),
                      systemName: thread.summary.isUnread ? "envelope.open" : "envelope.badge") {
                apply(.read(thread.summary.isUnread))
            }
            if role != .trash {
                barButton(L10n.string(thread.summary.isStarred ? "Remove star" : "Star"),
                          systemName: thread.summary.isStarred ? "star.fill" : "star") {
                    apply(.starred(!thread.summary.isStarred))
                }
            }
            if let url = thread.webURL {
                barButton(L10n.string(account.provider == .outlook ? "Open in Outlook" : "Open in Gmail"),
                          systemName: "arrow.up.right.square") { actions.openOriginal(url) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: ParityTheme.paneToolbarHeight)
    }

    private func barButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        ParityIconButton(systemName: systemName, help: title, action: action)
    }

    private func textButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ParityComposerControl(title: title, systemName: systemName, tint: .primary).fixedSize()
        }
        .buttonStyle(.plain)
        .parityPointer()
        .padding(.trailing, 4)
    }

    /// Spam and the trash say where the thread is, across the top of it.
    private var setAsideNote: some View {
        HStack(spacing: 8) {
            Image(systemName: role == .spam ? "exclamationmark.octagon" : "trash")
                .foregroundStyle(role == .spam ? Color.red : .secondary)
            Text(L10n.string(role == .spam
                             ? "This message is in Spam. Check who sent it before opening its links or files."
                             : "This message is in the Trash."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5 * scale))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(role == .spam ? Color.red.opacity(0.08) : ParityTheme.subtleFill)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    @ViewBuilder private var replyButtons: some View {
        if let last = thread.messages.last(where: { !$0.isDraft }) {
            HStack(spacing: 8) {
                replyButton(L10n.string("Mail reply"), systemName: "arrowshape.turn.up.left") {
                    actions.compose(thread, last, .reply)
                }
                if last.to.count + last.cc.count > 1 {
                    replyButton(L10n.string("Mail reply all"), systemName: "arrowshape.turn.up.left.2") {
                        actions.compose(thread, last, .replyAll)
                    }
                }
                replyButton(L10n.string("Mail forward"), systemName: "arrowshape.turn.up.right") {
                    actions.compose(thread, last, .forward)
                }
            }
        }
    }

    private func replyButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 13 * scale))
                .padding(.horizontal, 12)
                .frame(height: 30 * scale)
                .overlay(Capsule().strokeBorder(ParityTheme.strongSeparator))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .parityPointer()
    }
}

/// A message read in full: who sent it to whom and when, the words, and the attached files. A draft
/// says so and offers to send, edit or discard it.
struct MailMessageView: View {
    let message: MailMessage
    let thread: MailThread
    /// The account's address, named "me".
    let me: String
    let actions: MailActions
    /// Folds it back to a line; nil for the message that stays open.
    var fold: (() -> Void)?
    @Environment(\.yardletInterfaceScale) private var scale
    @State private var htmlHeight: CGFloat = 40
    @State private var showsRemoteContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                MailSenderInitial(address: message.from)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(MailText.name(message.from, me: me)).font(.system(size: 13 * scale, weight: .semibold))
                        if message.from.name != nil {
                            Text(message.from.address).font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if message.isDraft {
                            Text(L10n.string("Draft")).font(.system(size: 12 * scale, weight: .medium)).foregroundStyle(.orange)
                        }
                        Text(MailText.messageTime(message.date))
                            .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Text(recipients).font(.system(size: 12 * scale)).foregroundStyle(.secondary).lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { fold?() }
            }
            body(of: message)
                .padding(.leading, MailSenderInitial.size + 10)
            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                            Text(attachment.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12.5 * scale))
                    }
                }
                .padding(.leading, MailSenderInitial.size + 10)
            }
            if message.isDraft {
                HStack(spacing: 8) {
                    Button(L10n.string("Send")) { actions.sendDraft(thread, message) }
                        .buttonStyle(MailPrimaryButtonStyle())
                    Button { actions.editDraft(thread, message) } label: {
                        ParityComposerControl(title: L10n.string("Mail edit draft"), tint: .primary).fixedSize()
                    }
                    .buttonStyle(.plain)
                    Button { actions.discardDraft(thread, message) } label: {
                        ParityComposerControl(title: L10n.string("Mail discard draft"), tint: .primary).fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, MailSenderInitial.size + 10)
            }
        }
        .padding(.vertical, 16)
    }

    /// The HTML as sent, or the text when the message has no HTML.
    @ViewBuilder private func body(of message: MailMessage) -> some View {
        if let html = message.html, !html.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !showsRemoteContent, MailHTMLBody.hasRemoteContent(html) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                        Text(L10n.string("Images in this message are not loaded, so its sender cannot tell it was read."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.string("Show images")) { showsRemoteContent = true }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 12 * scale))
                }
                MailHTMLBody(html: html, allowsRemoteContent: showsRemoteContent, openLink: actions.openLink,
                             height: $htmlHeight)
                    .frame(height: htmlHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else {
            Text(message.text)
                .font(.system(size: 13.5 * scale))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recipients: String {
        let names = { (addresses: [MailAddress]) in addresses.map { MailText.name($0, me: me) }.joined(separator: ", ") }
        let to = L10n.format("Mail to %@", names(message.to))
        guard !message.cc.isEmpty else { return to }
        return to + "  " + L10n.format("Mail cc %@", names(message.cc))
    }
}

/// An earlier message folded to one line: sender, first words and time. Choosing it opens it.
struct MailFoldedMessage: View {
    let message: MailMessage
    let me: String
    let open: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                MailSenderInitial(address: message.from)
                Text(MailText.name(message.from, me: me)).font(.system(size: 13 * scale, weight: .semibold)).lineLimit(1)
                Text(message.snippet).font(.system(size: 13 * scale)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(MailText.listTime(message.date)).font(.system(size: 12 * scale)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(message.from.displayName)
        .accessibilityValue(message.snippet)
    }
}

/// The sender's first letter in a circle, tinted by the address so one sender keeps one tint.
struct MailSenderInitial: View {
    let address: MailAddress
    static let size: CGFloat = 28

    var body: some View {
        let letter = address.displayName.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).first
            .map { String($0).uppercased() } ?? "?"
        Text(letter)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(Self.tint(for: address.address), in: Circle())
            .accessibilityHidden(true)
    }

    private static let tints: [Color] = [.blue, .teal, .indigo, .green, .orange, .pink, .purple, .brown]

    static func tint(for address: String) -> Color {
        let sum = address.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[sum % tints.count].opacity(0.85)
    }
}

struct MailPrimaryButtonStyle: ButtonStyle {
    @Environment(\.yardletInterfaceScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5 * scale, weight: .medium))
            .foregroundStyle(ParityTheme.primaryActionForeground)
            .padding(.horizontal, 12)
            .frame(minHeight: 26 * scale)
            .background(ParityTheme.primaryActionFill.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .parityPointer()
    }
}

extension MailProvider {
    /// The service's name as people know it.
    var serviceName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .imap: "IMAP"
        }
    }
}
