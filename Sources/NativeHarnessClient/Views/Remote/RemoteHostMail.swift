import SwiftUI
import YardletRemote

/// The host's mailbox in its window (docs/REMOTE_PROTOCOL.md §15.38): the local mailbox's sidebar, threads and writing
/// over the host's accounts, a thread handed to an agent in a new chat on the host, links and the service's web mail in
/// this Mac's browser, and the host's Settings for a sign-in. A device without the Mail and Calendar permission is told
/// where to allow it.
extension RemoteHostView {
    /// The mailbox shows in the detail surface while the host's is on and the person chose it.
    var showsMail: Bool { shell.section == .mail && model.mailbox.isEnabled && !model.showsSchedules }

    @ViewBuilder var mailDetail: some View {
        if model.needsMailCalendarPermission {
            VStack(spacing: 0) {
                if titleBarContext.tabs == nil {
                    RemoteTitleBar(context: titleBarContext) { WindowDragRegion().frame(maxWidth: .infinity) }
                }
                RemoteConnectionBanner(model: model, directory: directory)
                RemotePermissionNote(text: permissionWords)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            MailWorkspace(
                center: model.mailbox, window: shell.mailWindow, actions: mailActions, panel: nil,
                onNewMessage: {
                    let mailbox = model.mailbox
                    guard let account = shell.mailWindow.mailbox.accountID.flatMap(mailbox.account)
                        ?? mailbox.accounts.first else { return }
                    shell.mailWindow.write(.new, account: account)
                },
                onRefresh: { Task { await model.mailbox.refresh() } }
            )
            .environment(\.taskAreaHeader, TaskAreaHeader(height: titleBarContext.rowHeight, isTitleBar: titleBarContext.tabs == nil,
                content: AnyView(VStack(spacing: 0) {
                    RemoteTitleBar(context: titleBarContext) {
                        HStack(spacing: 8) {
                            Text(L10n.string("Mail"))
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            WindowDragRegion().frame(maxWidth: .infinity)
                        }
                    }
                    RemoteConnectionBanner(model: model, directory: directory)
                })))
        }
    }

    /// The local mailbox's actions, through the host's mailbox; what opens a page opens it in this Mac's browser.
    private var mailActions: MailActions {
        let mailbox = model.mailbox
        let window = shell.mailWindow
        return MailActions(
            compose: { thread, message, kind in
                guard let account = mailbox.account(thread.summary.id.accountID) else { return }
                window.write(kind, account: account, message: message, in: thread)
            },
            editDraft: { thread, message in window.edit(message, in: thread, center: mailbox) },
            sendDraft: { thread, message in window.sendDraft(message, in: thread, center: mailbox) },
            discardDraft: { thread, message in window.discardDraft(message, in: thread, center: mailbox) },
            askAgent: { thread in
                guard let account = mailbox.account(thread.summary.id.accountID) else { return }
                askAgent(MailText.handoff(thread, account: account, accounts: mailbox.accounts))
            },
            openOriginal: { OutsideBrowser.open($0) },
            openLink: { OutsideBrowser.open($0) },
            openSettings: { model.openSettings(section: SettingsSection.connectors.rawValue) })
    }
}
