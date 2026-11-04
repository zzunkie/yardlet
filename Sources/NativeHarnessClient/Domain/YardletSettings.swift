import Foundation

/// The Settings sections in sidebar order, following the Claude app and the ChatGPT app (which holds
/// Codex): the Yardlet account first, as both put the account at the top of their list, then three
/// groups under a heading each, as the ChatGPT app's Personal, Integrations and Coding. Personal holds
/// Yardlet's own settings (Yardlet Instructions where the Codex app has Personalization's custom
/// instructions); Integrations what agents reach outside Yardlet (Connectors, the Vault agents fill
/// sign-ins from, and Remote, the phone remote, as the ChatGPT app keeps passwords and connections
/// there); Harnesses the coding tools with their accounts, the limits those accounts show, and the
/// CLI updates for their runtimes. Each section owns its page; General holds only its own controls
/// rather than links to the others.
enum SettingsSection: String, CaseIterable, Identifiable {
    case yardletAccount
    case general
    case appearance
    case notifications
    case instructions
    case connectors
    case vault
    case remote
    case harnesses
    case accounts
    case usage
    case cliUpdates

    /// The headings the sections sit under; the Yardlet account sits above them.
    enum Group: CaseIterable {
        case personal
        case integrations
        case harnesses

        var title: String {
            switch self {
            case .personal: L10n.string("Personal")
            case .integrations: L10n.string("Integrations")
            case .harnesses: L10n.string("Harnesses")
            }
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .yardletAccount: L10n.string("Yardlet Account")
        case .general: L10n.string("General")
        case .appearance: L10n.string("Appearance")
        case .notifications: L10n.string("Notifications")
        case .instructions: L10n.string("Yardlet Instructions")
        case .accounts: L10n.string("Harness Accounts")
        case .usage: L10n.string("Usage")
        case .harnesses: L10n.string("Harnesses")
        case .connectors: L10n.string("Connectors")
        case .vault: L10n.string("Passwords")
        case .remote: L10n.string("Remote")
        case .cliUpdates: L10n.string("CLI Updates")
        }
    }

    var systemName: String {
        switch self {
        case .yardletAccount: "person.crop.circle"
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell"
        case .instructions: "text.quote"
        case .accounts: "person.2"
        case .usage: "chart.bar.xaxis"
        case .harnesses: "square.stack.3d.up"
        case .connectors: "powerplug"
        case .vault: "key"
        case .remote: "iphone.radiowaves.left.and.right"
        case .cliUpdates: "arrow.triangle.2.circlepath"
        }
    }

    /// The heading it sits under; nil for the Yardlet account above the headings.
    var group: Group? {
        switch self {
        case .yardletAccount: nil
        case .general, .appearance, .notifications, .instructions: .personal
        case .connectors, .vault, .remote: .integrations
        case .harnesses, .accounts, .usage, .cliUpdates: .harnesses
        }
    }

    /// Accounts and Harnesses share one Account Center and fill the page with their own lists.
    var isConnectionSection: Bool { self == .accounts || self == .harnesses }

    /// The sections a window offers: Accounts and Harnesses need the app's account stores,
    /// Connectors needs a build with connectors, Vault the app's vault, Remote the app's remote, the
    /// Yardlet account a remote with a Yardlet server to sign in to, CLI Updates the app's CLI update
    /// center, Yardlet Instructions the app's instruction store, and Usage the app's token counts.
    static func available(hasAccounts: Bool, hasConnectors: Bool, hasVault: Bool = false, hasRemote: Bool = false,
                          hasYardletAccount: Bool = false, hasCLIUpdates: Bool = false, hasInstructions: Bool = false,
                          hasUsage: Bool = false) -> [SettingsSection] {
        allCases.filter { section in
            switch section {
            case .yardletAccount: hasYardletAccount
            case .accounts, .harnesses: hasAccounts
            case .usage: hasUsage
            case .connectors: hasConnectors
            case .vault: hasVault
            case .remote: hasRemote
            case .cliUpdates: hasCLIUpdates
            case .instructions: hasInstructions
            default: true
            }
        }
    }

    /// The section a window opens on: the requested one when it is offered, otherwise General.
    static func initial(_ rawValue: String?, available: [SettingsSection]) -> SettingsSection {
        guard let rawValue, let section = SettingsSection(rawValue: rawValue), available.contains(section) else {
            return .general
        }
        return section
    }
}

/// The headings General's rows sit under, in order: the app itself, how tasks run and reply, the
/// browser agents use, and the terminal.
enum GeneralSettingsGroup: CaseIterable {
    case app
    case tasks
    case browser
    case terminal

    var title: String {
        switch self {
        case .app: L10n.string("App")
        case .tasks: L10n.string("Tasks")
        case .browser: L10n.string("Browser")
        case .terminal: L10n.string("Terminal")
        }
    }
}

/// A switch the app keeps outside Yardlet's defaults and objects, read and set as its Settings control
/// does: Sparkle's automatic update checks in a public build.
struct YardletSettingSwitch {
    var get: @MainActor () -> Bool
    var set: @MainActor (Bool) -> Void
}

/// What the settings kept in the app's objects are read and written through: Settings fills it with what
/// its window has, the agent's settings tools with what the app has (`AppModel.settingsContext`). A
/// missing object leaves its settings out, as Settings leaves its section or row out.
@MainActor
struct YardletSettingsContext {
    var defaults: UserDefaults = .yardlet
    var vault: VaultCenter?
    var remote: RemoteControlService?
    var cliUpdates: CLIUpdateCenter?
    var instructions: YardletInstructionsStore?
    var evaluation: RoutingEvaluationStore?
    var connections: ProviderConnectionStore?
    var hasConnectors = false
    /// Whether this copy counts token usage (Settings › Usage).
    var hasUsage = false
    var lidHelper: LidSleepHelper?
    var updateChecks: YardletSettingSwitch?
}

/// One setting Settings offers, described once for its row and for the agent's settings tools
/// (`list_settings`, `update_setting`; docs/AGENT_BROWSER_TOOLS.md, "Settings tools"): where it is, its
/// words in the person's language, its values, and where its value lives. A row reads its words here and
/// changes the value where the rest of the app reads it, and so does the tool, so turning a setting off
/// either way leaves the same behind.
@MainActor
struct YardletSetting: Identifiable {
    static let on = "on"
    static let off = "off"

    struct Choice: Equatable {
        let value: String
        let title: String
        var detail: String?
    }

    enum Values {
        /// A switch, "on" or "off".
        case onOff
        case choices([Choice])
    }

    enum Storage {
        /// A switch in Yardlet's defaults.
        case flag(key: String, defaultValue: Bool)
        /// A choice in Yardlet's defaults, kept as the chosen value.
        case choice(key: String, defaultValue: String)
        /// Kept by one of the app's objects and changed through the same call as its Settings control. `read` is nil
        /// where the object is missing; `write` answers why it changed nothing, or nil once it went through.
        case app(read: @MainActor (YardletSettingsContext) -> String?,
                 write: @MainActor (YardletSettingsContext, String) async -> String?)
    }

    let id: String
    let section: SettingsSection
    /// The heading a General row sits under; nil in the other sections.
    var generalGroup: GeneralSettingsGroup?
    /// The row's symbol.
    var symbol = ""
    let title: String
    /// The line under the title, and a second line some rows have.
    var detail: String?
    var note: String?
    /// The control's tooltip, where a row has one instead of a line.
    var hint: String?
    /// The control's accessibility label, where it differs from the title.
    var controlLabel: String?
    let values: Values
    let storage: Storage
    /// Changing it asks the person every time, whatever the calling task may do without asking: it lowers a
    /// protection, reaches sign-ins, remote access or what agents may use, or deletes something kept.
    var asksEveryTime = false
    /// The switch whose row it shows under, only while that one is on.
    var shownWhileOn: String?
    /// Whether this copy of Yardlet offers it at all, beyond the object its value lives in.
    var offered: (@MainActor (YardletSettingsContext) -> Bool)?

    /// Its help as one text: the lines under the title, then the tooltip.
    var help: String {
        [detail, note, hint].compactMap(\.self).joined(separator: " ")
    }

    var choices: [Choice] {
        switch values {
        case .onOff: [Choice(value: Self.on, title: L10n.string("On")), Choice(value: Self.off, title: L10n.string("Off"))]
        case let .choices(choices): choices
        }
    }

    /// The words Settings shows for a value.
    func title(of value: String) -> String {
        choices.first { $0.value == value }?.title ?? value
    }

    /// Whether Settings shows it here now: offered, its object present, and the switch it shows under on.
    func isShown(in context: YardletSettingsContext) -> Bool {
        guard offered?(context) ?? true else { return false }
        if case let .app(read, _) = storage, read(context) == nil { return false }
        guard let parent = shownWhileOn else { return true }
        return YardletSettingCatalog.setting(parent)?.value(in: context) == Self.on
    }

    /// Its value now, one of `choices`, or nil where Settings does not show it.
    func value(in context: YardletSettingsContext) -> String? {
        guard isShown(in: context) else { return nil }
        switch storage {
        case let .flag(key, defaultValue):
            return Self.onOff(context.defaults.object(forKey: key) as? Bool ?? defaultValue)
        case let .choice(key, defaultValue):
            let stored = context.defaults.string(forKey: key)
            return stored.flatMap { value in choices.contains { $0.value == value } ? value : nil } ?? defaultValue
        case let .app(read, _):
            return read(context)
        }
    }

    /// Sets it to one of `choices` where its Settings control does; why nothing changed, or nil.
    func set(_ value: String, in context: YardletSettingsContext) async -> String? {
        switch storage {
        case let .flag(key, _):
            context.defaults.set(value == Self.on, forKey: key)
            return nil
        case let .choice(key, _):
            context.defaults.set(value, forKey: key)
            return nil
        case let .app(_, write):
            return await write(context, value)
        }
    }

    private static func onOff(_ isOn: Bool) -> String { isOn ? on : off }

    /// A switch kept by one of the app's objects.
    private static func appSwitch(_ read: @escaping @MainActor (YardletSettingsContext) -> Bool?,
                                  _ write: @escaping @MainActor (YardletSettingsContext, Bool) async -> String?) -> Storage {
        .app(read: { read($0).map(onOff) }, write: { context, value in await write(context, value == on) })
    }

    private static func choices<Option: CaseIterable & RawRepresentable>(
        _ type: Option.Type, title: (Option) -> String, detail: (Option) -> String? = { _ in nil }
    ) -> Values where Option.RawValue == String {
        .choices(type.allCases.map { Choice(value: $0.rawValue, title: title($0), detail: detail($0)) })
    }
}

// MARK: - General

extension YardletSetting {
    static let language = YardletSetting(
        id: "language", section: .general, generalGroup: .app, symbol: "character.bubble", title: L10n.string("Language"),
        detail: L10n.string("Applies the next time you open Yardlet"),
        values: choices(AppLanguagePreference.self, title: \.title),
        storage: .app(read: { AppLanguagePreference.stored(in: $0.defaults).rawValue },
                      write: { context, value in
                          if let language = AppLanguagePreference(rawValue: value) {
                              AppLanguagePreference.store(language, in: context.defaults)
                          }
                          return nil
                      }))

    static let showInMenuBar = YardletSetting(
        id: "show_in_menu_bar", section: .general, generalGroup: .app, symbol: "menubar.rectangle", title: L10n.string("Show in menu bar"),
        detail: L10n.string("Keep Yardlet in the macOS menu bar when the main window is closed"),
        controlLabel: L10n.string("Show Yardlet in the menu bar"),
        values: .onOff, storage: .flag(key: MenuBarPreference.key, defaultValue: true))

    static let mailbox = YardletSetting(
        id: "mailbox", section: .general, generalGroup: .app, symbol: "envelope", title: L10n.string("Mailbox"),
        detail: L10n.string("Show the inboxes of the mail accounts connected in Connectors (Gmail, Outlook and accounts over IMAP) beside your tasks. Mail is read from the service and kept in memory only."),
        values: .onOff, storage: .flag(key: MailboxPreference.key, defaultValue: false))

    static let agentBrowserTools = YardletSetting(
        id: "agent_browser_tools", section: .general, generalGroup: .browser, symbol: "globe", title: L10n.string("Agent browser tools"),
        values: .onOff, storage: .flag(key: AgentToolPreference.browserToolsKey, defaultValue: true),
        asksEveryTime: true)

    static let shareTerminal = YardletSetting(
        id: "share_terminal", section: .general, generalGroup: .terminal, symbol: "terminal", title: L10n.string("Share the terminal with agents"),
        detail: L10n.string("A task's agent can read the task's terminal tabs, without typing in them, and a selection in the terminal can be attached to your message (⌘⇧L)."),
        values: .onOff, storage: .flag(key: TerminalSharingPreference.key, defaultValue: true), asksEveryTime: true)

    static let terminalLocation = YardletSetting(
        id: "terminal_location", section: .general, generalGroup: .terminal, symbol: "rectangle.split.2x1", title: L10n.string("Terminal location"),
        detail: L10n.string("Where the terminal opens: below the conversation, or as a tab of the side panel."),
        values: .choices([Choice(value: TerminalLocation.bottom.rawValue, title: L10n.string("Bottom")),
                          Choice(value: TerminalLocation.right.rawValue, title: L10n.string("Right"))]),
        storage: .choice(key: TerminalLocation.key, defaultValue: TerminalLocation.bottom.rawValue))

    /// Turning it off asks Touch ID or the login password as well (`VaultCenter.setHidesCredentials`).
    static let hideKeysAndTokens = YardletSetting(
        id: "hide_keys_and_tokens", section: .general, generalGroup: .browser, symbol: "eye.slash", title: L10n.string("Hide keys and tokens"),
        detail: L10n.string("Hides values that look like API keys, access tokens or private keys in what agents read in the browser. Turned off, agents read them as the page shows them, and they stay in the task's history."),
        values: .onOff,
        storage: appSwitch({ $0.vault?.hidesCredentials }, { context, hides in
            guard let vault = context.vault, vault.isAllowedBuild else {
                return L10n.string("Always on in a build that is not team-signed.")
            }
            await vault.setHidesCredentials(hides)
            return nil
        }),
        asksEveryTime: true)

    static let showTaskServers = YardletSetting(
        id: "show_task_servers", section: .general, generalGroup: .tasks, symbol: "server.rack", title: L10n.string("Show servers tasks start"),
        detail: L10n.string("Show the localhost address of a server a task's harness or terminal starts beside the task's title"),
        values: .onOff, storage: .flag(key: TaskServersPreference.key, defaultValue: true))

    static let keepCookies = YardletSetting(
        id: "keep_cookies", section: .general, generalGroup: .browser, symbol: "person.2.badge.key", title: L10n.string("Keep cookies"),
        hint: L10n.string("Tasks share your sign-ins. A task whose agent signs in to a site itself keeps that sign-in to itself. Sign-ins saved in the password manager work in every task"),
        values: choices(BrowserTaskProfiles.Storage.self, title: \.title),
        storage: .choice(key: BrowserTaskProfiles.storageKey, defaultValue: BrowserTaskProfiles.Storage.perTask.rawValue),
        asksEveryTime: true)

    static let searchSuggestions = YardletSetting(
        id: "search_suggestions", section: .general, generalGroup: .browser, symbol: "magnifyingglass",
        title: L10n.string("Autocomplete searches and URLs"),
        detail: L10n.string("Sends what you type in the address field to Google to suggest searches. Pages from your browsing history are suggested either way."),
        values: .onOff, storage: .flag(key: SearchSuggestionPreference.key, defaultValue: true))

    /// Turned off, each task's saved pages go.
    static let pageSuggestions = YardletSetting(
        id: "page_suggestions", section: .general, generalGroup: .browser, symbol: "clock.arrow.circlepath",
        title: L10n.string("Suggest pages on new tabs"),
        detail: L10n.string("Shows the pages this task opened and the sites you visit most on a new tab and in the side panel. Turned off, tasks keep no list of the pages they opened."),
        values: .onOff, storage: .flag(key: BrowserPageSuggestionPreference.key, defaultValue: true), asksEveryTime: true)

    static let continueAfterRestart = YardletSetting(
        id: "continue_after_restart", section: .general, generalGroup: .tasks, symbol: "arrow.clockwise",
        title: L10n.string("Continue running work after a restart"),
        hint: L10n.string("Claude Code and Codex tasks continue where they left off after Yardlet quits or updates"),
        values: .onOff, storage: .flag(key: RestartResumePreference.key, defaultValue: true))

    static let keepScreenUnlocked = YardletSetting(
        id: "keep_screen_unlocked", section: .general, generalGroup: .tasks, symbol: "lock.open.display",
        title: L10n.string("Keep the screen unlocked while tasks work"),
        values: .onOff, storage: .flag(key: KeepScreenAwakePreference.key, defaultValue: false), asksEveryTime: true)

    /// Turning it on asks macOS to allow a helper of Yardlet's that keeps the Mac awake.
    static let keepWorkingWithLidClosed = YardletSetting(
        id: "keep_working_with_lid_closed", section: .general, generalGroup: .tasks, symbol: "laptopcomputer",
        title: L10n.string("Keep tasks working with the lid closed"),
        values: .onOff, storage: .flag(key: LidClosedWorkPreference.key, defaultValue: false), asksEveryTime: true,
        offered: { $0.lidHelper != nil })

    static let memorySaver = YardletSetting(
        id: "memory_saver", section: .general, generalGroup: .browser, symbol: "memorychip", title: L10n.string("Memory saver"),
        detail: L10n.string("Frees memory from tasks you haven't used in a while and brings them back when you return."),
        values: .onOff, storage: .flag(key: MemorySaverPreference.key, defaultValue: true))

    static let memorySaverLevel = YardletSetting(
        id: "memory_saver_level", section: .general, generalGroup: .browser, title: L10n.string("Memory saver level"),
        values: choices(BrowserMemorySaver.Level.self, title: \.title, detail: { $0.detail }),
        storage: .choice(key: MemorySaverPreference.levelKey, defaultValue: BrowserMemorySaver.Level.balanced.rawValue),
        shownWhileOn: memorySaver.id)

    static let followUpBehavior = YardletSetting(
        id: "follow_up_behavior", section: .general, generalGroup: .tasks, symbol: "text.append", title: L10n.string("Follow-up behavior"),
        hint: L10n.string("While a turn runs, Return sends this way and Command-Return the other way"),
        values: choices(FollowUpMode.self, title: \.title),
        storage: .choice(key: FollowUpMode.preferenceKey, defaultValue: FollowUpMode.steer.rawValue))

    static let nextMessageSuggestions = YardletSetting(
        id: "next_message_suggestions", section: .general, generalGroup: .tasks, symbol: "text.bubble",
        title: L10n.string("Next message suggestions"),
        detail: L10n.string("After a reply, show a suggested next message as faint text in the empty message box. Claude Code and Codex make each one with one more model request, which adds a little to your usage."),
        hint: L10n.string("Codex tasks follow it from their next reply, Claude Code tasks from their next start or resume"),
        values: .onOff, storage: .flag(key: NextMessageSuggestionPreference.key, defaultValue: true))

    static let autoFixFailingCI = YardletSetting(
        id: "auto_fix_failing_ci", section: .general, generalGroup: .tasks, symbol: "wrench.and.screwdriver",
        title: L10n.string("Auto-fix failing CI"),
        detail: L10n.string("When a task first has a pull request, ask whether to send it failing checks to fix. Auto-fix stays off until you turn it on for that task."),
        values: choices(PullRequestAutoFixPrompt.self, title: \.title),
        storage: .choice(key: PullRequestAutoFixPrompt.preferenceKey, defaultValue: PullRequestAutoFixPrompt.ask.rawValue))

    static let checkForUpdates = YardletSetting(
        id: "check_for_updates", section: .general, generalGroup: .app, symbol: "arrow.down.circle",
        title: L10n.string("Automatically check for updates"),
        values: .onOff,
        storage: appSwitch({ $0.updateChecks?.get() }, { context, checks in
            context.updateChecks?.set(checks)
            return nil
        }))
}

// MARK: - Appearance and Notifications

extension YardletSetting {
    static let theme = YardletSetting(
        id: "theme", section: .appearance, symbol: "circle.lefthalf.filled", title: L10n.string("Theme"),
        values: choices(YardletAppearancePreference.self, title: \.title),
        storage: .choice(key: YardletPreferenceKeys.appearance, defaultValue: YardletAppearancePreference.system.rawValue))

    static let interfaceSize = YardletSetting(
        id: "interface_size", section: .appearance, symbol: "textformat.size", title: L10n.string("Interface size"),
        values: choices(YardletInterfaceSizePreference.self, title: \.title),
        storage: .choice(key: YardletPreferenceKeys.interfaceSize,
                         defaultValue: YardletInterfaceSizePreference.standard.rawValue))

    static let personalAgentMessages = YardletSetting(
        id: "personal_agent_messages", section: .notifications, symbol: "circle.dotted",
        title: L10n.string("Personal agent messages"),
        detail: L10n.string("Notify when a dot replies or asks for input while you are elsewhere"),
        values: .onOff, storage: .flag(key: PersonalAgentNotificationPreference.key, defaultValue: true))

    static let newMail = YardletSetting(
        id: "new_mail", section: .notifications, symbol: "envelope.badge", title: L10n.string("New mail"),
        detail: L10n.string("Notify when new mail reaches an inbox in the mailbox: in Gmail its Primary tab, in Outlook its Focused inbox"),
        values: .onOff, storage: .flag(key: MailboxPreference.notificationsKey, defaultValue: true),
        shownWhileOn: mailbox.id)
}

// MARK: - Yardlet Instructions, Accounts and Connectors

extension YardletSetting {
    static let yardletInstructions = YardletSetting(
        id: "yardlet_instructions", section: .instructions, symbol: "text.quote",
        title: L10n.string("Use Yardlet instructions"),
        detail: L10n.string("Added when Yardlet starts or resumes a task; a task whose harness is already running keeps the instructions it started with until it resumes, for example after Yardlet reopens. Never written to a harness's own files."),
        note: L10n.string("Global instruction files such as AGENTS.md and CLAUDE.md also apply outside Yardlet; Yardlet instructions apply only to tasks Yardlet launches."),
        values: .onOff,
        storage: appSwitch({ $0.instructions?.isEnabled }, { context, isOn in
            context.instructions?.isEnabled = isOn
            return nil
        }),
        asksEveryTime: true)

    /// Shows excerpts of tasks to other harnesses' models, and turning it off removes its records.
    static let dailyEvaluation = YardletSetting(
        id: "daily_evaluation", section: .instructions, symbol: "arrow.triangle.branch",
        title: L10n.string("Choose harnesses and models by daily evaluation"),
        detail: L10n.string("Once a day, the models you use review the day's tasks, their own included, and the routing they settle on is added to these instructions."),
        note: L10n.string("It uses your plans, and excerpts of your tasks are shown to the other harnesses' models. Turning it off removes its records."),
        values: .onOff,
        storage: appSwitch({ $0.evaluation?.isEnabled }, { context, isOn in
            context.evaluation?.isEnabled = isOn
            return nil
        }),
        asksEveryTime: true)

    static let newTaskAccountAutomatically = YardletSetting(
        id: "new_task_account_automatically", section: .accounts,
        title: L10n.string("Choose the account for new tasks automatically"),
        detail: L10n.string("With more than one account in automatic assignment, a new task starts on the one with the most room left in its limits unless you choose an account."),
        values: .onOff,
        storage: appSwitch({ $0.connections?.picksNewTaskAccount }, { context, picks in
            context.connections?.setPicksNewTaskAccount(picks)
            return nil
        }))

    static let continueAtUsageLimit = YardletSetting(
        id: "continue_at_usage_limit", section: .accounts, title: L10n.string("Continue automatically at usage limit"),
        detail: L10n.string("When a usage limit stops a Claude Code task and resets within a day, the task picks up where it stopped once it resets. A limit that resets later, such as a weekly one, continues only if you turn it on on its card."),
        values: .onOff, storage: .flag(key: UsageLimitAutoContinuePreference.key, defaultValue: true))

    /// Shown once a Claude Code account is saved besides the default login, so there is one to move to.
    static let moveTasksToAccountsWithRoom = YardletSetting(
        id: "move_tasks_to_accounts_with_room", section: .accounts,
        title: L10n.string("Move tasks to an account with room"),
        detail: L10n.string("Moves Claude Code tasks on an account that is nearly out of its limit to an account with room once they have been idle for an hour. A task that hits its limit continues on another account, or waits and continues if the limit resets soon."),
        values: .onOff, storage: .flag(key: AccountMovePreference.key, defaultValue: true),
        offered: { $0.connections?.connections(for: .claudeCode).isEmpty == false })

    static let claudeAIConnectors = YardletSetting(
        id: "claude_ai_connectors", section: .connectors, symbol: "person.crop.circle",
        title: L10n.string("Use claude.ai account connectors"),
        detail: L10n.string("On: Claude tasks also load the connectors each Claude account connected on claude.ai, such as Gmail, Google Calendar, and Google Drive. They differ by account, and a service also connected here appears twice. Codex and ACP tasks are unaffected."),
        values: .onOff, storage: .flag(key: ClaudeAIConnectorPreference.key, defaultValue: false), asksEveryTime: true,
        offered: { $0.hasConnectors })
}

// MARK: - Usage

extension YardletSetting {
    /// Turning it off deletes the counts; the transcripts they came from stay.
    static let tokenUsage = YardletSetting(
        id: "token_usage", section: .usage, symbol: "chart.bar.xaxis", title: L10n.string("Count token usage"),
        detail: L10n.string("Reads only the new lines of Claude Code's and Codex's transcripts on this Mac and keeps the counts for a year. Turning it off deletes the counts; the transcripts stay as they are."),
        values: .onOff, storage: .flag(key: TokenUsagePreference.key, defaultValue: true),
        offered: { $0.hasUsage })
}

// MARK: - Passwords, Remote and CLI Updates

extension YardletSetting {
    static let passwordManager = YardletSetting(
        id: "password_manager", section: .vault, symbol: "lock.shield", title: L10n.string("Password manager for agents"),
        values: .onOff,
        storage: appSwitch({ context in context.vault.map { $0.isAllowedBuild && $0.isEnabled } }, { context, isOn in
            guard let vault = context.vault, vault.isAllowedBuild else {
                return L10n.string("Available in team-signed builds of Yardlet.")
            }
            vault.isEnabled = isOn
            return nil
        }),
        asksEveryTime: true)

    static let addressesAndCards = YardletSetting(
        id: "addresses_and_cards", section: .vault, symbol: "creditcard",
        title: L10n.string("Save and fill addresses and cards"),
        values: .onOff,
        storage: appSwitch({ $0.vault?.offersWallet }, { context, isOn in
            guard let vault = context.vault, vault.isAllowedBuild else {
                return L10n.string("Available in team-signed builds of Yardlet.")
            }
            vault.isWalletEnabled = isOn
            return nil
        }),
        asksEveryTime: true)

    static let remoteConnections = YardletSetting(
        id: "remote_connections", section: .remote, symbol: "iphone.radiowaves.left.and.right",
        title: L10n.string("Allow remote connections"),
        detail: L10n.string("Follow and drive this Mac's tasks from Yardlet on your phone or another computer."),
        values: .onOff,
        storage: appSwitch({ $0.remote?.isEnabled }, { context, isOn in
            context.remote?.setEnabled(isOn)
            return nil
        }),
        asksEveryTime: true)

    static let connectFromOutside = YardletSetting(
        id: "connect_from_outside", section: .remote, symbol: "cloud", title: L10n.string("Connect from outside"),
        detail: L10n.string("Through the Yardlet server. It is end-to-end encrypted, so the server can't read it."),
        values: .onOff,
        storage: appSwitch({ $0.remote?.isRelayEnabled }, { context, isOn in
            context.remote?.setRelayEnabled(isOn)
            return nil
        }),
        asksEveryTime: true, shownWhileOn: remoteConnections.id, offered: { $0.remote?.relayURL != nil })

    static let keepAwakeOnPower = YardletSetting(
        id: "keep_awake_on_power", section: .remote, symbol: "powerplug", title: L10n.string("Keep this Mac awake on power"),
        detail: L10n.string("While it's plugged in, this Mac doesn't sleep on its own, so your devices can still reach it. The display can still turn off."),
        values: .onOff,
        storage: appSwitch({ $0.remote?.keepsAwakeOnPower }, { context, keepsAwake in
            context.remote?.setKeepsAwakeOnPower(keepsAwake)
            return nil
        }),
        shownWhileOn: remoteConnections.id)

    /// Turning it off drops what Yardlet kept for going back to an earlier version.
    static let cliAutomaticUpdates = YardletSetting(
        id: "cli_automatic_updates", section: .cliUpdates, symbol: "arrow.triangle.2.circlepath",
        title: L10n.string("CLI automatic updates"),
        detail: L10n.string("Updates each harness CLI with its own updater while none of its tasks is running. Yardlet checks the CLI before and after, without a model turn, and goes back to the earlier version if the new one fails."),
        values: .onOff,
        storage: appSwitch({ $0.cliUpdates?.isAutoUpdateEnabled }, { context, isOn in
            context.cliUpdates?.setAutoUpdate(isOn)
            return nil
        }),
        asksEveryTime: true)
}

/// Every setting Settings offers as a switch or a choice, in Settings' order: what its rows draw and what
/// the agent's settings tools list. Signing in and out, editing text, pairing, and lists of items stay
/// Settings' own.
@MainActor
enum YardletSettingCatalog {
    static let all: [YardletSetting] = [
        .language, .showInMenuBar, .mailbox, .checkForUpdates,
        .followUpBehavior, .nextMessageSuggestions, .autoFixFailingCI, .showTaskServers, .continueAfterRestart,
        .keepScreenUnlocked, .keepWorkingWithLidClosed,
        .agentBrowserTools, .keepCookies, .searchSuggestions, .pageSuggestions, .memorySaver, .memorySaverLevel,
        .hideKeysAndTokens,
        .shareTerminal, .terminalLocation,
        .theme, .interfaceSize,
        .personalAgentMessages, .newMail,
        .yardletInstructions, .dailyEvaluation,
        .claudeAIConnectors,
        .passwordManager, .addressesAndCards,
        .remoteConnections, .connectFromOutside, .keepAwakeOnPower,
        .newTaskAccountAutomatically, .continueAtUsageLimit, .moveTasksToAccountsWithRoom,
        .tokenUsage,
        .cliAutomaticUpdates
    ]

    static func setting(_ id: String) -> YardletSetting? {
        all.first { $0.id == id }
    }

    /// The rows of a section that draws its settings in a list: those shown here, less the ones another
    /// row draws under itself.
    static func rows(in section: SettingsSection, context: YardletSettingsContext) -> [YardletSetting] {
        all.filter { $0.section == section && $0.shownWhileOn.flatMap(setting)?.section != section
            && $0.isShown(in: context) }
    }
}
