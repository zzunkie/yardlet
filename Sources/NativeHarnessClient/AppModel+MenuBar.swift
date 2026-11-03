import Foundation

/// The menu bar item's menu (`MenuBarMenu`) and what choosing its items does. The menu reads the
/// same tasks, attention and account readings the window does, when it opens; choosing a task goes
/// the way a notification click goes (`handleNotificationResponse`).
extension AppModel {
    /// The menu as it is now, for the menu bar item to show as it opens.
    func menuBarMenu(now: Date = Date()) -> MenuBarMenu {
        var menu = MenuBarMenuProjection.menu(
            sessions: sidebarSessions,
            pinnedIDs: pinnedSidebarSessionIDs,
            details: taskAttentionDetails,
            shellBusy: shellBusySessionIDs,
            place: taskPlaceNames(),
            usage: connections.usageLines(now: now)
        )
        menu.usageToday = tokenUsage.todayLine
        menu.keepsScreenAwake = keepsScreenAwake
        menu.screenAwakePausedForBattery = screenAwakePausedForBattery
        menu.keepsAwakeWithLidClosed = keepsAwakeWithLidClosed
        menu.lidAwakePause = lidAwakePause
        return menu
    }

    /// A task chosen in the menu: Yardlet comes forward and opens it, in its split pane when it is in
    /// a split view, or shows the archived tasks when it was archived since the menu opened.
    func openTaskFromMenuBar(_ sessionID: UUID) async {
        await handleNotificationResponse(SystemNotificationResponse(
            target: SystemNotificationTarget(sessionID: sessionID), action: .open))
    }

    /// Checks the accounts the Usage lines show, for a menu or screen that shows them as it opens.
    func checkUsageAccounts() async {
        await connections.checkUsageAccounts(runtimeSelections: runtimeSelections)
    }

    /// "New task": Yardlet comes forward on the new task screen.
    func showNewTaskFromMenuBar() {
        applicationAttention?.bringForward()
        revealNewTask()
    }

    /// "Open Yardlet".
    func bringForwardFromMenuBar() {
        applicationAttention?.bringForward()
    }

    /// The tasks under Pinned in the sidebar: pinned tasks and the tasks of pinned split views.
    var pinnedSidebarSessionIDs: Set<UUID> {
        sidebarLists.pinnedSessionIDs
    }

    /// The sidebar's lists as the window lays them out with no search and every row shown: what the
    /// menu bar menu and the phone read of it.
    var sidebarLists: SidebarProjection.Layout {
        let groups = projects.visibleGroups(sessions: store.listedSessions)
        return SidebarProjection.layout(
            visibleGroups: groups, allGroups: groups, chats: projects.chats(sessions: store.listedSessions),
            splits: splits.splits, isFiltering: false, archivedParents: store.archivedParentIDs)
    }

    /// The line under a task's title where tasks are listed apart from their project (the activity
    /// view, the menu bar menu): the project's name, or "Chats" for a chat.
    func taskPlaceNames() -> (SessionRecord) -> String {
        let groups = projects.visibleGroups(sessions: store.sessions)
        let chatIDs = Set(projects.chats(sessions: store.sessions).map(\.id))
        let names = Dictionary(
            groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
            uniquingKeysWith: { first, _ in first })
        return { session in
            chatIDs.contains(session.id)
                ? L10n.string("Chats")
                : names[session.id] ?? session.workspaceURL.lastPathComponent
        }
    }
}

extension ProviderConnectionStore {
    /// The accounts Usage lists: every account of every harness, as the person moves between several
    /// by what is left of each.
    func menuBarUsageChoices(for harnesses: [HarnessKind]) -> [AccountChoice] {
        choices(for: harnesses)
    }

    /// The Usage lines as the readings stand now, a failed check said on its line.
    func usageLines(now: Date = Date()) -> [MenuBarMenu.UsageAccount] {
        MenuBarMenuProjection.usage(choices: menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id)),
            status: readingStatus(for:), isChecking: isChecking(_:), now: now)
    }

    /// Checks the accounts the Usage lines show, as an account list checks its rows when it appears:
    /// a reading confirmed within the last minute is kept and a check already running is joined.
    /// The lists that check default logins open only now and then, so without this a line kept the
    /// reading of the last time one did (Codex's default login, two days old, on 2026-10-25).
    func checkUsageAccounts(runtimeSelections: RuntimeSelectionStore) async {
        let shown = menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id)).filter { !$0.quotas.isEmpty }
        let saved = shown.compactMap(\.connection)
        guard !shown.isEmpty else { return }
        await check(defaultsOf: shown.filter { $0.connection == nil }.map(\.harness),
            savedOf: Array(Set(saved.map(\.harness))), connectionIDs: Set(saved.map(\.id)),
            runtimeSelections: runtimeSelections)
    }
}
