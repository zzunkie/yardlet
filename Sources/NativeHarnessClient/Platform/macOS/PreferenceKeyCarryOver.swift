import Foundation

/// The keys of the preferences a view reads with `@AppStorage`, which have no dots, and the keys they had
/// before. SwiftUI observes an `@AppStorage` key by key-value observation, which reads a dot as a key path;
/// for a key with one it follows every change of the store instead, so each write of any key, as Yardlet
/// makes them saving its state, evaluated each view reading such a key again: the main window, the task's
/// views around its conversation, the session rail and Settings among them.
///
/// As Yardlet starts, before anything reads them, a value saved under a key's earlier name is copied to its
/// name now, once: while that name holds no value. The earlier name keeps its value for a build from before
/// the change, which shares these preferences (a development bundle has the installed app's identifier), as
/// the Application Support copy of the session index stays when it moves (`YardletProduct.storageRootURL`).
@MainActor
enum PreferenceKeyCarryOver {
    static let earlierKeys: KeyValuePairs<String, String> = [
        "Yardlet.appearance": YardletPreferenceKeys.appearance,
        "Yardlet.interfaceSize": YardletPreferenceKeys.interfaceSize,
        "Yardlet.sidebar.grouping": SidebarGrouping.defaultsKey,
        "Yardlet.terminalLocation": TerminalLocation.key,
        "Yardlet.codexFollowUpMode": FollowUpMode.preferenceKey,
        "Yardlet.nextMessageSuggestions": NextMessageSuggestionPreference.key,
        "Yardlet.showsTaskServers": TaskServersPreference.key,
        "Yardlet.pullRequestAutoFix.prompt": PullRequestAutoFixPrompt.preferenceKey,
        "Yardlet.terminalSharing": TerminalSharingPreference.key,
        "Yardlet.browser.pageSuggestions": BrowserPageSuggestionPreference.key,
        "Yardlet.browser.searchSuggestions": SearchSuggestionPreference.key,
        "Yardlet.browser.cookieStorage": BrowserTaskProfiles.storageKey,
        "Yardlet.agentBrowserTools": AgentToolPreference.browserToolsKey,
        "Yardlet.memorySaver": MemorySaverPreference.key,
        "Yardlet.memorySaverLevel": MemorySaverPreference.levelKey,
        "Yardlet.personalAgentNotifications": PersonalAgentNotificationPreference.key,
        "Yardlet.mailbox": MailboxPreference.key,
        "Yardlet.mailNotifications": MailboxPreference.notificationsKey,
        "Yardlet.showInMenuBar": MenuBarPreference.key,
        "Yardlet.continueWorkAfterRestart": RestartResumePreference.key,
        "Yardlet.keepScreenAwakeWhileWorking": KeepScreenAwakePreference.key,
        "Yardlet.keepWorkingWithLidClosed": LidClosedWorkPreference.key,
        "Yardlet.continueAtUsageLimit": UsageLimitAutoContinuePreference.key,
        "Yardlet.movesTasksToAccountsWithRoom": AccountMovePreference.key,
        "Yardlet.tokenUsage": TokenUsagePreference.key,
        "Yardlet.claudeAIConnectors": ClaudeAIConnectorPreference.key,
        "Yardlet.connectorImportDismissed": ConnectorSettingsView.importDismissedKey,
        "Yardlet.connectorSetup.opened": ConnectorSetupProgress.key,
    ]

    static func run(in defaults: UserDefaults = .yardlet) {
        for (earlier, key) in earlierKeys where defaults.object(forKey: key) == nil {
            if let value = defaults.object(forKey: earlier) { defaults.set(value, forKey: key) }
        }
    }
}
