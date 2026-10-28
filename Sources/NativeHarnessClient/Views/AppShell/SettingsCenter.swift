import SwiftUI

/// The Settings sections in sidebar order, following the Codex and Claude apps: personal settings
/// (Yardlet Instructions where the Codex app has Personalization's custom instructions) with the
/// account right after them, then integrations (Connectors, and the Vault agents fill sign-ins
/// from), then the coding tools
/// (Harnesses, where Claude has its Claude Code section, then CLI Updates for their runtimes).
/// Remote, the phone remote, sits with the integrations. Each section owns its page; General holds
/// only its own controls rather than links to the others.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case instructions
    case accounts
    case connectors
    case vault
    case remote
    case harnesses
    case cliUpdates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L10n.string("General")
        case .appearance: L10n.string("Appearance")
        case .notifications: L10n.string("Notifications")
        case .instructions: L10n.string("Yardlet Instructions")
        case .accounts: L10n.string("Accounts")
        case .harnesses: L10n.string("Harnesses")
        case .connectors: L10n.string("Connectors")
        case .vault: L10n.string("Passwords")
        case .remote: L10n.string("Remote")
        case .cliUpdates: L10n.string("CLI Updates")
        }
    }

    var systemName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell"
        case .instructions: "text.quote"
        case .accounts: "person.crop.circle"
        case .harnesses: "square.stack.3d.up"
        case .connectors: "powerplug"
        case .vault: "key"
        case .remote: "iphone.radiowaves.left.and.right"
        case .cliUpdates: "arrow.triangle.2.circlepath"
        }
    }

    /// Accounts and Harnesses share one Account Center and fill the page with their own lists.
    var isConnectionSection: Bool { self == .accounts || self == .harnesses }

    /// The sections a window offers: Accounts and Harnesses need the app's account stores,
    /// Connectors needs a build with connectors, Vault the app's vault, Remote the app's remote,
    /// CLI Updates the app's CLI update center, and Yardlet Instructions the app's instruction store.
    static func available(hasAccounts: Bool, hasConnectors: Bool, hasVault: Bool = false, hasRemote: Bool = false,
                          hasCLIUpdates: Bool = false, hasInstructions: Bool = false) -> [SettingsSection] {
        allCases.filter { section in
            switch section {
            case .accounts, .harnesses: hasAccounts
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

/// Where the window's account and harness entries open. Accounts and harnesses are Settings
/// sections; adding or connecting an account from a new task keeps its own sheet, which returns to
/// the task's draft when done.
enum ConnectionEntryRoute: Equatable {
    case settings(SettingsSection, harness: HarnessKind?)
    case accountSheet

    /// The sidebar's Connections entry and the account picker's Manage accounts.
    static func accounts(harness: HarnessKind? = nil, adds: Bool = false, connects: Bool = false) -> Self {
        adds || connects ? .accountSheet : .settings(.accounts, harness: harness)
    }

    static let harnesses = Self.settings(.harnesses, harness: nil)
}

/// What the Accounts and Harnesses sections need from the app.
struct SettingsAccountsContext {
    let runtimeSelections: RuntimeSelectionStore
    let connections: ProviderConnectionStore
    /// The harness the Accounts list opens filtered to.
    var initialHarness: HarnessKind? = nil
    var harnessUsage: AccountHarnessScope.Usage? = nil
    var codexEnvironmentManager: CodexEnvironmentManager? = nil
    var localSessionUsage: LocalSessionUsageOverview? = nil
    /// How many tasks run under a saved account, so removing one keeps a folder they use.
    var tasksUsingAccount: ((ProviderConnection) -> Int)? = nil
    var fixtureSnapshots: [HarnessAccountSnapshot]? = nil
    var fixtureLogin: (HarnessKind, AccountInteractiveCommand)? = nil
}

enum SettingsAccessibility {
    static func value(status: String, detail: String) -> String {
        [status, detail]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct SettingsCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let notificationCenter: any SystemNotificationCenter
    /// Nil where this build has no connectors; the section is then left out.
    let connectors: ConnectorCenter?
    /// Nil where the window has no vault for agents (tests, fixtures); the section is then left out.
    let vault: VaultCenter?
    /// Nil where the window has no account stores; Accounts and Harnesses are then left out.
    let accounts: SettingsAccountsContext?
    /// Nil where the app has no phone remote; Remote is then left out.
    let remote: RemoteControlService?
    /// Nil where the app does not check harness CLIs (tests, fixtures); CLI Updates is then left out.
    let cliUpdates: CLIUpdateCenter?
    /// Nil where the app has no Yardlet instructions (tests, fixtures); the section is then left out.
    let instructions: YardletInstructionsStore?
    /// The routing evaluation's switch, shown with Yardlet Instructions; nil leaves it out.
    let evaluation: RoutingEvaluationStore?
    /// Yardlet's lid helper; nil where the app has none (tests, fixtures), and General leaves its
    /// switch out.
    let lidHelper: LidSleepHelper?
    @State private var section: SettingsSection
    @State private var focusedSection: SettingsSection?
    /// The section list takes the keyboard when Settings opens, as the sidebar list it replaced did.
    @FocusState private var isSectionListFocused: Bool
    @State private var notifications: SystemNotificationSettingsModel
    /// One Account Center for both connection sections, so moving between them keeps its checks.
    @State private var accountCenter: AccountCenterModel
    @State private var hasShownConnectionSection = false
    @State private var addingAccount = false
    @State private var setupExpanded = false
    @AppStorage(YardletPreferenceKeys.appearance) private var appearanceRawValue =
        YardletAppearancePreference.system.rawValue
    @AppStorage(YardletPreferenceKeys.interfaceSize) private var interfaceSizeRawValue =
        YardletInterfaceSizePreference.standard.rawValue
    /// Read when a task starts or resumes, so a change applies from the next session on.
    @AppStorage(AgentToolPreference.browserToolsKey) private var agentBrowserTools = true
    @AppStorage(TaskServersPreference.key) private var showsTaskServers = true
    /// Read when a tab opens: its task's own profile, or the default profile every task shares.
    @AppStorage(BrowserTaskProfiles.storageKey) private var cookieStorage = BrowserTaskProfiles.Storage.perTask.rawValue
    /// Read as the person types in a browser panel's address field.
    @AppStorage(SearchSuggestionPreference.key) private var suggestsSearches = true
    /// What Return does while a Codex turn runs; read at each send.
    @AppStorage(CodexFollowUpMode.preferenceKey) private var codexFollowUpMode = CodexFollowUpMode.steer.rawValue
    /// Yardlet's menu bar item (`MenuBarStatusItem`), on unless turned off as in the Codex app.
    @AppStorage(MenuBarPreference.key) private var showsInMenuBar = true
    /// Read when Yardlet quits and when it opens again (`RestartResumePolicy`).
    @AppStorage(RestartResumePreference.key) private var continuesWorkAfterRestart = true
    @AppStorage(KeepScreenAwakePreference.key) private var keepsScreenAwake = false
    /// Read by the browser host client as it changes and by each memory check (`MemorySaverPreference`).
    @AppStorage(MemorySaverPreference.key) private var savesMemory = true
    /// `RunningWorkActivity` registers or removes the lid helper as it changes.
    @AppStorage(LidClosedWorkPreference.key) private var keepsWorkingWithLidClosed = false
    /// Asked of a Claude Code task's CLI when it starts or resumes; the composer reads it live.
    @AppStorage(NextMessageSuggestionPreference.key) private var suggestsNextMessage = true
    @AppStorage(PullRequestAutoFixPrompt.preferenceKey) private var autoFixPrompt = PullRequestAutoFixPrompt.ask.rawValue
    /// Not `@AppStorage`: System must remove the app's own `AppleLanguages`, not store a value.
    @State private var language = AppLanguagePreference.stored()
    /// Sparkle in a public build: General's automatic update check. Nil in a development build.
    @Environment(\.yardletSparkle) private var sparkle

    /// The sheet's size; it must fit inside the window it is shown on.
    let size: CGSize

    static let preferredSize = CGSize(width: 820, height: 620)

    /// The preferred size, made smaller to leave a margin inside a smaller window. The window's
    /// own minimum (760×560) still leaves a usable sheet.
    static func fittingSize(in window: CGSize, margin: CGFloat = 24) -> CGSize {
        guard window.width > 0, window.height > 0 else { return preferredSize }
        return CGSize(width: max(560, min(preferredSize.width, window.width - margin * 2)),
                      height: max(440, min(preferredSize.height, window.height - margin * 2)))
    }

    init(
        size: CGSize = SettingsCenterView.preferredSize,
        initialSection: String? = nil,
        notificationCenter: any SystemNotificationCenter = LocalSystemNotificationCenter(),
        connectors: ConnectorCenter? = nil,
        vault: VaultCenter? = nil,
        accounts: SettingsAccountsContext? = nil,
        remote: RemoteControlService? = nil,
        cliUpdates: CLIUpdateCenter? = nil,
        instructions: YardletInstructionsStore? = nil,
        evaluation: RoutingEvaluationStore? = nil,
        lidHelper: LidSleepHelper? = nil
    ) {
        self.size = size
        self.connectors = connectors
        self.vault = vault
        self.accounts = accounts
        self.remote = remote
        self.cliUpdates = cliUpdates
        self.instructions = instructions
        self.evaluation = evaluation
        self.lidHelper = lidHelper
        self.notificationCenter = notificationCenter
        _notifications = State(initialValue: SystemNotificationSettingsModel(center: notificationCenter))
        _section = State(initialValue: SettingsSection.initial(initialSection, available: SettingsSection.available(
            hasAccounts: accounts != nil, hasConnectors: connectors != nil, hasVault: vault != nil,
            hasRemote: remote != nil, hasCLIUpdates: cliUpdates != nil, hasInstructions: instructions != nil)))
        _accountCenter = State(initialValue: AccountCenterModel(
            connections: accounts?.connections ?? ProviderConnectionStore(),
            codexEnvironmentManager: accounts?.codexEnvironmentManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("Settings"))
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Button(L10n.string("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(accountCenter.loginController.isRunning)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: ParityTheme.toolbarHeight)

            Rectangle().fill(ParityTheme.separator).frame(height: 1)

            HStack(spacing: 0) {
                // The two apps' settings lists: the chosen section on a light fill with its words in
                // the text colour. A sidebar `List` drew its selection in the shell's monochrome tint, a
                // black bar the words disappeared into (2026-10-22).
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { item in
                            SettingsSectionRow(item: item, isSelected: item == section) { section = item }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .frame(width: 190)
                .background(ParityTheme.sidebar)
                .focusable()
                .focusEffectDisabled()
                .focused($isSectionListFocused)
                .accessibilityLabel(L10n.string("Settings sections"))
                .accessibilityValue(section.title)
                .onKeyPress(.downArrow) {
                    moveSection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSection(by: -1)
                    return .handled
                }

                Rectangle()
                    .fill(ParityTheme.separator)
                    .frame(width: 1)

                Group {
                    if section.isConnectionSection, let accounts {
                        // These pages scroll their own lists under a fixed search and filter row.
                        VStack(alignment: .leading, spacing: 0) {
                            detailHeader.padding(.horizontal, 20).padding(.top, 20)
                            connectionContent(accounts)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                detailHeader
                                detail
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(ParityTheme.canvas)
        .task {
            focusedSection = section
            isSectionListFocused = true
        }
        .task(id: section) {
            if section == .notifications { await notifications.refresh() }
        }
        .onChange(of: section, initial: true) { _, value in
            focusedSection = value
            if value.isConnectionSection { hasShownConnectionSection = true }
            // Adding an account is a step of the Accounts page; leaving the page ends it.
            if value != .accounts { addingAccount = false; setupExpanded = false }
        }
        .background {
            // The checks start when a connection section first shows and run while the window is
            // open, whichever section is selected.
            if let accounts {
                Color.clear.modifier(ConnectionCenterLifecycle(
                    model: accountCenter,
                    connections: accounts.connections,
                    runtimeSelections: accounts.runtimeSelections,
                    isActive: hasShownConnectionSection,
                    initialHarness: accounts.initialHarness,
                    fixtureSnapshots: accounts.fixtureSnapshots,
                    fixtureLogin: accounts.fixtureLogin
                ))
            }
        }
    }

    private var sections: [SettingsSection] {
        SettingsSection.available(hasAccounts: accounts != nil, hasConnectors: connectors != nil, hasVault: vault != nil,
                                  hasRemote: remote != nil, hasCLIUpdates: cliUpdates != nil,
                                  hasInstructions: instructions != nil)
    }

    private func connectionContent(_ accounts: SettingsAccountsContext) -> some View {
        ConnectionCenterContent(
            tab: section == .harnesses ? .harnesses : .accounts,
            model: accountCenter,
            runtimeSelections: accounts.runtimeSelections,
            connections: accounts.connections,
            harnessUsage: accounts.harnessUsage,
            initialHarness: accounts.initialHarness,
            addingAccount: $addingAccount,
            setupExpanded: $setupExpanded,
            isFixture: accounts.fixtureSnapshots != nil,
            localSessionUsage: accounts.localSessionUsage,
            tasksUsingAccount: accounts.tasksUsingAccount,
            // Settings stays open after an add or sign-in step; the list shows the result.
            onFinish: {}
        )
        .id(section)
    }

    private func moveSection(by offset: Int) {
        guard let targetID = SettingsSectionNavigationProjection.targetSectionID(
            in: sections.map(\.rawValue),
            focusedID: focusedSection?.rawValue,
            offset: offset
        ), let target = SettingsSection(rawValue: targetID) else { return }
        section = target
        focusedSection = target
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ParityTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 18, weight: .semibold))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general:
            VStack(spacing: 0) {
                // The Codex app's General rows (`settings.ide.language`, `settings.general.macMenuBar`),
                // first and in its order.
                HStack(spacing: 12) {
                    settingsControlIcon("character.bubble")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Language")).font(.callout.weight(.medium))
                        Text(L10n.string("Applies the next time you open Yardlet"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker(L10n.string("Language"), selection: Binding(
                        get: { language },
                        set: { language = $0; AppLanguagePreference.store($0) })) {
                        ForEach(AppLanguagePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("menubar.rectangle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Show in menu bar")).font(.callout.weight(.medium))
                        Text(L10n.string("Keep Yardlet in the macOS menu bar when the main window is closed"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Show Yardlet in the menu bar"), isOn: $showsInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("globe")
                    Text(L10n.string("Agent browser tools")).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Agent browser tools"), isOn: $agentBrowserTools)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("server.rack")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Show servers tasks start")).font(.callout.weight(.medium))
                        Text(L10n.string("Show the localhost address of a server a task's harness or terminal starts beside the task's title"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Show servers tasks start"), isOn: $showsTaskServers)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("person.2.badge.key")
                    Text(L10n.string("Keep cookies")).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Picker(L10n.string("Keep cookies"), selection: $cookieStorage) {
                        ForEach(BrowserTaskProfiles.Storage.allCases) { storage in
                            Text(storage.title).tag(storage.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .controlSize(.small)
                    .help(L10n.string("Each task keeps its own sign-ins and site data; sign-ins saved in the password manager work in every task"))
                    .accessibilityHint(L10n.string("Each task keeps its own sign-ins and site data; sign-ins saved in the password manager work in every task"))
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("magnifyingglass")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Autocomplete searches and URLs")).font(.callout.weight(.medium))
                        Text(L10n.string("Sends what you type in the address field to Google to suggest searches. Pages from your browsing history are suggested either way."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Autocomplete searches and URLs"), isOn: $suggestsSearches)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("arrow.clockwise")
                    Text(L10n.string("Continue running work after a restart")).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Continue running work after a restart"), isOn: $continuesWorkAfterRestart)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                        .help(L10n.string("Claude Code and Codex tasks continue where they left off after Yardlet quits or updates"))
                        .accessibilityHint(L10n.string("Claude Code and Codex tasks continue where they left off after Yardlet quits or updates"))
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("lock.open.display")
                    Text(L10n.string("Keep the screen unlocked while tasks work")).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Keep the screen unlocked while tasks work"), isOn: $keepsScreenAwake)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                if let lidHelper {
                    Divider().padding(.leading, Self.dividerLeading)
                    lidClosedWorkRow(lidHelper)
                }
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("memorychip")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Memory saver")).font(.callout.weight(.medium))
                        Text(L10n.string("Frees memory from tasks you haven't used in a while and brings them back when you return."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Memory saver"), isOn: $savesMemory)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("text.append")
                    Text(L10n.string("Follow-up behavior")).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Picker(L10n.string("Follow-up behavior"), selection: $codexFollowUpMode) {
                        ForEach(CodexFollowUpMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .controlSize(.small)
                    .help(L10n.string("While a turn runs, Return sends this way and Command-Return the other way"))
                    .accessibilityHint(L10n.string("While a turn runs, Return sends this way and Command-Return the other way"))
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                // The Claude app's "Prompt suggestions" and the Codex app's "Show predictions" in one
                // row, with the cost note.
                HStack(spacing: 12) {
                    settingsControlIcon("text.bubble")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Next message suggestions")).font(.callout.weight(.medium))
                        Text(L10n.string("After a reply, show a suggested next message as faint text in the empty message box. Claude Code and Codex make each one with one more model request, which adds a little to your usage."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.string("Next message suggestions"), isOn: $suggestsNextMessage)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                        .help(L10n.string("Codex tasks follow it from their next reply, Claude Code tasks from their next start or resume"))
                        .accessibilityHint(L10n.string("Codex tasks follow it from their next reply, Claude Code tasks from their next start or resume"))
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, Self.dividerLeading)
                HStack(spacing: 12) {
                    settingsControlIcon("wrench.and.screwdriver")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Auto-fix failing CI")).font(.callout.weight(.medium))
                        Text(L10n.string("When a task first has a pull request, ask whether to send it failing checks to fix. Auto-fix stays off until you turn it on for that task."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker(L10n.string("Auto-fix failing CI"), selection: $autoFixPrompt) {
                        ForEach(PullRequestAutoFixPrompt.allCases, id: \.self) { prompt in
                            Text(prompt.title).tag(prompt.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(.vertical, 14)
                if let sparkle {
                    Divider().padding(.leading, Self.dividerLeading)
                    HStack(spacing: 12) {
                        settingsControlIcon("arrow.down.circle")
                        Text(L10n.string("Automatically check for updates")).font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        Toggle(L10n.string("Automatically check for updates"), isOn: Binding(
                            get: { sparkle.checksAutomatically },
                            set: { sparkle.checksAutomatically = $0 }))
                            .labelsHidden()
                            .toggleStyle(.paritySwitch)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 12)
            .parityCard()
        case .appearance:
            appearanceDetail
        case .notifications:
            notificationDetail
        case .instructions:
            if let instructions { YardletInstructionsSettingsView(store: instructions, evaluation: evaluation) }
        case .connectors:
            if let connectors { ConnectorSettingsView(center: connectors) }
        case .vault:
            if let vault { VaultSettingsView(vault: vault) }
        case .remote:
            if let remote { RemoteSettingsView(service: remote) }
        case .cliUpdates:
            if let cliUpdates { CLIUpdateSettingsView(center: cliUpdates, runtimes: accounts?.runtimeSelections) }
        case .accounts, .harnesses:
            EmptyView()
        }
    }

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.string("Theme"), systemImage: "circle.lefthalf.filled")
                    .font(.callout.weight(.semibold))
                Picker(L10n.string("Theme"), selection: $appearanceRawValue) {
                    ForEach(YardletAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.string("Interface size"), systemImage: "textformat.size")
                    .font(.callout.weight(.semibold))
                Picker(L10n.string("Interface size"), selection: $interfaceSizeRawValue) {
                    ForEach(YardletInterfaceSizePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .labelsHidden().frame(width: 160)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .parityCard()
    }

    /// Where a General row's divider starts: under the words, past the 30 pt icon and the 12 pt
    /// gap, as Connectors' rows divide.
    static let dividerLeading: CGFloat = 30 + 12

    /// "Keep tasks working with the lid closed", with one line while it is on and macOS has not let
    /// the helper run yet.
    private func lidClosedWorkRow(_ helper: LidSleepHelper) -> some View {
        let note: String? = switch (keepsWorkingWithLidClosed, helper.status) {
        case (true, .needsApproval): L10n.string("Allow Yardlet in the background in System Settings")
        case (true, .off): L10n.string("macOS did not add Yardlet's helper")
        case (true, .unavailable): L10n.string("Not available in this copy of Yardlet")
        default: nil
        }
        return HStack(spacing: 12) {
            settingsControlIcon("laptopcomputer")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Keep tasks working with the lid closed")).font(.callout.weight(.medium))
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if keepsWorkingWithLidClosed, helper.status == .needsApproval || helper.status == .off {
                Button(L10n.string("Open System Settings")) { helper.openSystemSettings() }
                    .controlSize(.small)
            }
            Toggle(L10n.string("Keep tasks working with the lid closed"), isOn: $keepsWorkingWithLidClosed)
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
        }
        .padding(.vertical, 14)
    }

    private func settingsControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private var notificationDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(
                title: L10n.string("Background task notifications"),
                detail: notifications.authorization.isDeliverable
                    ? L10n.string("System notifications are delivered for background completion, failure, or approval.")
                    : L10n.string("System notifications are off until you allow them."),
                status: notifications.statusLabel,
                systemName: "bell"
            )
            HStack(spacing: 8) {
                Button(L10n.string("Enable notifications")) {
                    Task { await notifications.requestAuthorization() }
                }
                .disabled(notifications.isLoading || notifications.authorization.isDeliverable)
                if notifications.authorization == .denied {
                    Button(L10n.string("Open System Settings")) {
                        notifications.openSystemSettings()
                    }
                    .accessibilityHint(L10n.string("Allow notifications for Yardlet in macOS settings."))
                }
                Button(L10n.string("Refresh notification status")) {
                    Task { await notifications.refresh() }
                }
                .disabled(notifications.isLoading)
            }
            .controlSize(.small)
        }
    }

    private func settingRow(
        title: String,
        detail: String,
        status: String,
        systemName: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !status.isEmpty {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(SettingsAccessibility.value(status: status, detail: detail))
    }

}

/// One section in Settings' list: its symbol and name, filled when chosen and lighter on hover, as
/// the sidebar's rows are.
private struct SettingsSectionRow: View {
    let item: SettingsSection
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: item.systemName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isSelected ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
