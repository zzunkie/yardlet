import Foundation

/// Notifications for the dots the person last opened in Personal agents, while the setting is on
/// (`PersonalAgentNotificationPreference`). The app keeps one watch (`PersonalAgentWatch`) on that
/// account's dots; a window's own conversation keeps its own connection. A click shows the dot in
/// Personal agents (`personalAgentReveal`); nothing in the background switches a window's section.
extension AppModel {
    /// Follows the setting and the account it names from now on.
    func startPersonalAgentWatch(defaults: UserDefaults = .yardlet) {
        guard personalAgentPreferenceObserver == nil else { return }
        let watch = personalAgentWatch
        watch.isActive = { [weak self] in self?.applicationAttention?.isActive ?? false }
        watch.announce = { [weak self] in await self?.postPersonalAgentNotification($0) }
        watch.withdraw = { [weak self] identity in
            self?.systemNotificationCenter.removeNotifications(identifiers: [false, true].map {
                PersonalAgentAnnouncement.identifier(roomID: identity.roomID, isRequest: $0)
            })
        }
        // Delivered on the writing thread and passed on without waiting, as the menu bar item's is.
        // `UserDefaults` is safe to use from any thread.
        nonisolated(unsafe) let watched = defaults
        personalAgentPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.followPersonalAgents(defaults: watched) }
        }
        followPersonalAgents(defaults: defaults, force: true)
    }

    /// A window read the dots of `accountChoiceID`: the watch follows that account while the setting
    /// is on, and none when the account has no dots. A watch whose login had ended starts again.
    func notePersonalAgentsRead(accountChoiceID: String, hasAgents: Bool, defaults: UserDefaults = .yardlet) {
        guard PersonalAgentNotificationPreference.isOn(in: defaults) else { return }
        let key = PersonalAgentNotificationPreference.accountKey
        if hasAgents {
            if defaults.string(forKey: key) != accountChoiceID { defaults.set(accountChoiceID, forKey: key) }
        } else if defaults.string(forKey: key) == accountChoiceID {
            defaults.removeObject(forKey: key)
        }
        followPersonalAgents(defaults: defaults, force: true)
        if hasAgents { personalAgentWatch.restart() }
    }

    /// Starts, moves or ends the watch as the setting, the account, its home and the runtime say. Only
    /// a change of the setting or the account is looked at further unless `force`.
    func followPersonalAgents(defaults: UserDefaults = .yardlet, force: Bool = false) {
        let isOn = PersonalAgentNotificationPreference.isOn(in: defaults)
        let accountKey = PersonalAgentNotificationPreference.accountKey
        let state = [isOn ? "on" : "off", defaults.string(forKey: accountKey)]
        guard force || state != personalAgentPreferenceState else { return }
        personalAgentPreferenceState = state
        guard isOn else {
            // Turned off, nothing of it stays: the connection, the unread marks and the account it followed.
            personalAgentWatch.stop()
            if defaults.object(forKey: accountKey) != nil { defaults.removeObject(forKey: accountKey) }
            return
        }
        guard !usesVisualFixture, let accountID = state[1],
              let account = connections.choices(for: [.codex]).first(where: { $0.id == accountID }),
              let runtime = runtimeSelections.selectedURL(for: .codex) else {
            return personalAgentWatch.stop()
        }
        let manager = codexEnvironmentManager
        let home = account.connection?.homePath ?? manager?.paths.nativeHomeURL.path()
            ?? CodexEnvironmentPaths.live().nativeHomeURL.path()
        let source = PersonalAgentWatch.Source(key: accountID + "|" + home + "|" + runtime.path(), accountChoiceID: accountID)
        personalAgentWatch.follow(source) {
            DotsService(executable: runtime, environmentManager: manager, connection: account.connection)
        }
    }

    /// Posts a dot's message: its name, and its words on one line, or what its request asks.
    func postPersonalAgentNotification(_ announcement: PersonalAgentAnnouncement) async {
        guard (await systemNotificationCenter.authorization()).isDeliverable else { return }
        let body: String
        if announcement.isRequest {
            body = announcement.preview.isEmpty ? L10n.string("Needs your input.")
                : L10n.format("Needs your input: %@", announcement.preview)
        } else {
            body = announcement.preview
        }
        await systemNotificationCenter.post(SystemNotification(
            title: announcement.agent.name, body: body, identifier: announcement.identifier,
            target: SystemNotificationTarget(personalAgent: PersonalAgentReveal(
                agent: announcement.agent.id, accountChoiceID: announcement.accountChoiceID))))
    }

    /// A dot's notification was clicked: Yardlet comes forward and a window shows that dot.
    func revealPersonalAgent(_ reveal: PersonalAgentReveal) {
        applicationAttention?.bringForward()
        personalAgentReveal = reveal
    }
}
