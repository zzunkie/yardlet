import Foundation
import Observation

/// The mailbox follows Settings › Mailbox and the mail accounts connected in Settings › Connectors:
/// turned on, it shows each connected Gmail account and reads its inbox; turned off, it forgets all
/// it read.
extension AppModel {
    func startMailbox(defaults: UserDefaults = .yardlet) {
        guard mailboxPreferenceObserver == nil else { return }
        nonisolated(unsafe) let preferences = defaults
        mailbox.announce = { [weak self] threads in
            Task { await self?.postMailNotifications(threads, defaults: preferences) }
        }
        nonisolated(unsafe) let watched = defaults
        mailboxPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                // Any setting posts this; only the mailbox's own changes anything here.
                guard let self, MailboxPreference.isOn(in: watched) != self.mailbox.isEnabled else { return }
                self.followMailbox(defaults: watched)
            }
        }
        followMailbox(defaults: defaults)
    }

    /// Shows the accounts the setting and the connectors say, reading an inbox only when its account
    /// is new to the mailbox. While it is on, the next change to the connectors is followed again.
    func followMailbox(defaults: UserDefaults = .yardlet) {
        let isOn = MailboxPreference.isOn(in: defaults)
        mailbox.setEnabled(isOn)
        if !isOn { closeMailBrowser() }
        guard isOn, let connectorCenter else { return }
        let entries: [(MailAccount, any MailAccountTransport)]
        if mailboxFollowsConnectors {
            entries = connectorCenter.mailAccounts()
        } else {
            mailboxFollowsConnectors = true
            nonisolated(unsafe) let defaults = defaults
            entries = withObservationTracking {
                connectorCenter.mailAccounts()
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.mailboxFollowsConnectors = false
                    self?.followMailbox(defaults: defaults)
                }
            }
        }
        defer { mailbox.startWatching() }
        guard entries.map(\.0) != mailbox.accounts else { return }
        mailbox.setAccounts(entries)
        Task { await mailbox.refresh() }
    }

    /// New mail as system notifications, through the same permission as task notifications: each
    /// thread's sender and subject, or one count for more than three at once. Nothing is told while
    /// a window shows the mailbox and Yardlet is the active app, or with Settings › Notifications ›
    /// New mail off.
    func postMailNotifications(_ threads: [MailThreadSummary], defaults: UserDefaults = .yardlet) async {
        guard MailboxPreference.notifies(in: defaults), let newest = threads.first,
              !(mailbox.isShown && applicationAttention?.isActive == true),
              (await systemNotificationCenter.authorization()).isDeliverable else { return }
        if threads.count > Self.mailNotificationsAtOnce {
            await systemNotificationCenter.post(SystemNotification(
                title: L10n.format("%lld new messages", threads.count),
                body: threads.prefix(4).map { MailText.senders($0) }.joined(separator: ", "),
                identifier: "yardlet-mail-batch", target: SystemNotificationTarget(mailThread: newest.id)))
            return
        }
        for thread in threads {
            let account = mailbox.account(thread.id.accountID)
            let sender = MailText.senders(thread, me: account?.address)
            let title = mailbox.accounts.count > 1 ? "\(sender) · \(account?.shortName ?? "")" : sender
            await systemNotificationCenter.post(SystemNotification(
                title: title, body: MailText.subject(thread.subject) + "\n" + thread.snippet,
                identifier: "yardlet-mail-\(thread.id.accountID.uuidString)-\(thread.id.threadID)",
                target: SystemNotificationTarget(mailThread: thread.id)))
        }
    }

    static let mailNotificationsAtOnce = 3

    /// A new mail's notification was clicked: Yardlet comes forward and a window shows the thread.
    func revealMailThread(_ thread: MailThreadKey) {
        applicationAttention?.bringForward()
        mailReveal = thread
    }
}
