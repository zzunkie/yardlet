import Foundation

/// A browser tab the agent hands to the person (`browser_handoff`, docs/AGENT_BROWSER_TOOLS.md, "Tools"): the task's side panel shows the
/// tab, with the agent's reason and Done and Decline in a bar above the page, and a notification tells the person; a
/// click opens the task with its panel on the tab. The notification goes when the handoff ends.
extension AppModel: BrowserHandoffPresenting {
    func handoffStarted(session: UUID, tabKey: UUID?, reason: String, notice: String) {
        if let tabKey {
            let workspace = taskWorkspaces.state(for: session)
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(
                TaskSurfaceNavigationProjection.browserTabID(tabKey), in: workspace.panels))
        }
        let title = store.sessions.first { $0.id == session }?.title ?? ""
        BrowserHandoffNotices.pending.insert(notice)
        browserHandoffWaits[session, default: []].append(BrowserHandoffWait(notice: notice, tabKey: tabKey, reason: reason))
        Task {
            guard (await systemNotificationCenter.authorization()).isDeliverable,
                  BrowserHandoffNotices.pending.contains(notice) else { return }
            await systemNotificationCenter.post(SystemNotification(
                title: L10n.string("The agent needs you in the browser"),
                body: title.isEmpty ? reason : "\(title): \(reason)",
                identifier: notice, target: SystemNotificationTarget(sessionID: session, browserTab: tabKey)))
            // The handoff may have ended while the notification was on its way.
            if !BrowserHandoffNotices.pending.contains(notice) {
                systemNotificationCenter.removeNotifications(identifiers: [notice])
            }
        }
    }

    func handoffEnded(notice: String) {
        BrowserHandoffNotices.pending.remove(notice)
        systemNotificationCenter.removeNotifications(identifiers: [notice])
        for (session, waits) in browserHandoffWaits where waits.contains(where: { $0.notice == notice }) {
            let left = waits.filter { $0.notice != notice }
            browserHandoffWaits[session] = left.isEmpty ? nil : left
        }
    }

    /// The person's answer to a handoff from elsewhere than the tab's bar (the phone remote): the bar's own answer, to
    /// the tab it is over, which ends the wait and its notification as the bar does. False when the tab is gone or
    /// already answered.
    func answerBrowserHandoff(_ notice: String, done: Bool, in session: UUID) -> Bool {
        guard let wait = browserHandoffWaits[session]?.first(where: { $0.notice == notice }),
              let tab = handoffTab(wait, in: session), tab.handoff?.answer == nil else { return false }
        tab.answerHandoff(done ? .done : .declined)
        handoffEnded(notice: notice)
        return true
    }

    /// The site the handed-over tab shows, by its host.
    func browserHandoffSite(_ wait: BrowserHandoffWait, in session: UUID) -> String? {
        handoffTab(wait, in: session).flatMap { URL(string: $0.lastPageURL ?? "")?.host() }
    }

    private func handoffTab(_ wait: BrowserHandoffWait, in session: UUID) -> BrowserTab? {
        let tabs = taskWorkspaces.state(for: session).browserClient?.tabs(forSession: session) ?? []
        return tabs.first { $0.key == wait.tabKey } ?? (wait.tabKey == nil ? tabs.first { $0.handoff != nil } : nil)
    }

    func handoffWaitCeiling(for session: UUID) -> Duration {
        let harness = store.sessions.first { $0.id == session }?.harness ?? .claudeCode
        return sessionToolWaitCeiling(for: harness)
    }
}

extension AppModel {
    /// A task's panel shows its browser tab `tabKey`: a tab that waits on the person while the task's panel is not on
    /// screen, so the person finds its window or dialog when they come to the task, as `browser_handoff` leaves it;
    /// and a click on such a tab's notification. The task in front stays.
    func showBrowserTab(_ tabKey: UUID, under session: UUID) {
        let workspace = taskWorkspaces.state(for: session)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(
            TaskSurfaceNavigationProjection.browserTabID(tabKey), in: workspace.panels))
    }
}

/// A tab the agent handed to the person and waits on: its notification's name, the tab, and the agent's reason.
struct BrowserHandoffWait: Equatable, Sendable {
    let notice: String
    let tabKey: UUID?
    let reason: String
}

/// The handoffs whose notification may still be shown.
@MainActor
enum BrowserHandoffNotices {
    static var pending: Set<String> = []
}
