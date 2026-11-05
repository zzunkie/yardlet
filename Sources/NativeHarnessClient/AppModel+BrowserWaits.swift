import Foundation

/// A task's browser tab that waits on the person (`BrowserPersonWait`), and the tab it is.
struct BrowserTaskWait: Equatable, Sendable {
    var wait: BrowserPersonWait
    /// The tab's side-panel key.
    var tabKey: UUID
    /// The page's host, for the words that name it.
    var site: String?
}

/// Browser tabs that wait on the person (docs/BROWSER_HOST.md, section 3, "Tabs that wait on the person"): a passkey or a site's sign-in,
/// a JavaScript dialog, a file chooser, a permission, another app to open, the agent's handoff. The window or dialog
/// waits in its tab and shows where a panel shows the tab; meanwhile the task's sidebar row says "Waiting in the
/// browser" (`TaskAttentionDetail.browserWait`), the tab is marked in the task's panel, and one notification says so,
/// whose click opens the task with its panel on the tab. A task whose panel is not on screen has its panel left on the
/// tab, so the person finds it there. Yardlet never moves the person's screen to it: the person goes when they choose,
/// as the Codex app keeps a browser request for the conversation it belongs to.
///
/// A dialog, file chooser or permission request the agent's own input led to is the agent's to answer while its turn
/// runs (`BrowserPersonWait.agentLed`; a permission request it can only close): its tool results say so. Once the turn
/// ends with it still open, it waits on the person like the others.
extension AppModel {
    func followBrowserWaits(of client: BrowserHostClient) {
        browserWaitSource = client
        client.onPersonWaitsChange = { [weak self] in self?.refreshBrowserWaits() }
        refreshBrowserWaits()
    }

    /// Reads every task's browser waits again, and marks, tells and withdraws what changed. The mailbox's panel is
    /// no task's: what its pages wait on shows over the panel and on its tab, where the person who opened them looks.
    func refreshBrowserWaits() {
        guard let client = browserWaitSource else { return }
        var next: [UUID: BrowserTaskWait] = [:]
        for session in client.sessionsWithTabs where session != TaskWorkspaceStore.mailID {
            let waits = client.tabs(forSession: session).compactMap { tab -> (BrowserTab, BrowserPersonWait)? in
                guard let wait = client.personWait(of: tab), !(wait.agentLed && isInTurn(session)) else { return nil }
                return (tab, wait)
            }
            guard let best = waits.min(by: { Self.order($0.1.kind) < Self.order($1.1.kind) }) else { continue }
            let (tab, wait) = best
            next[session] = BrowserTaskWait(wait: wait, tabKey: tab.key, site: tab.currentURL.flatMap { URL(string: $0)?.host() })
        }
        let previous = browserWaits
        guard next != previous else { return }
        browserWaits = next
        for session in Set(previous.keys).union(next.keys) where previous[session] != next[session] {
            refreshAttentionDetail(for: session)
            if let ended = previous[session], ended.wait.kind != .handoff, next[session]?.wait != ended.wait {
                systemNotificationCenter.removeNotifications(identifiers: [Self.notice(ended)])
            }
            guard let wait = next[session], previous[session]?.wait != wait.wait,
                  let tab = client.tab(key: wait.tabKey, forSession: session) else { continue }
            // Where the person will look when they come to the task; the screen in front stays theirs.
            if !client.tabs(forSession: session).contains(where: { $0.visiblePanelCount > 0 }) {
                showBrowserTab(wait.tabKey, under: session)
            }
            // The handoff has its own notification; a tab the person sees in front needs none.
            let seen = tab.visiblePanelCount > 0 && applicationAttention?.isActive == true
            if wait.wait.kind != .handoff, !seen { announce(wait, in: session) }
        }
    }

    /// The order a task's waits are named in: what only the person can do first.
    private static func order(_ kind: BrowserPersonWait.Kind) -> Int {
        switch kind {
        case .handoff: 0
        case .passkey: 1
        case .signIn: 2
        case .permission: 3
        case .externalApp: 4
        case .javaScriptDialog: 5
        case .fileChooser: 6
        }
    }

    static func notice(_ wait: BrowserTaskWait) -> String {
        "yardlet-browser-wait-\(wait.tabKey.uuidString)-\(wait.wait.id)"
    }

    private func announce(_ wait: BrowserTaskWait, in session: UUID) {
        let title = store.sessions.first { $0.id == session }?.title ?? ""
        let what = BrowserPersonWaitText.describe(wait.wait, site: wait.site)
        let notice = Self.notice(wait)
#if DEBUG
        browserWaitAnnouncements.append(notice)
#endif
        Task {
            guard (await systemNotificationCenter.authorization()).isDeliverable,
                  browserWaits[session] == wait else { return }
            await systemNotificationCenter.post(SystemNotification(
                title: L10n.string("Waiting for you in the browser"),
                body: title.isEmpty ? what : "\(title): \(what)",
                identifier: notice, target: SystemNotificationTarget(sessionID: session, browserTab: wait.tabKey)))
            // The wait may have ended while the notification was on its way.
            if browserWaits[session] != wait { systemNotificationCenter.removeNotifications(identifiers: [notice]) }
        }
    }
}
