import SwiftUI
import YardletRemote

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

/// What Settings › Usage draws: the overview the app reads anew in the page's body, whether counting is
/// on, and when the limits were last read.
struct SettingsUsageContext {
    var overview: () -> TokenUsageOverview
    var isCounting: () -> Bool
    var limitsCheckedAt: () -> Date?
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
    /// The tasks on a saved account, archived ones included, so removing one keeps a folder they use.
    var tasksUsingAccount: ((ProviderConnection) -> AccountTaskCount)? = nil
    /// Moves a saved account's tasks to another folder of the same account, then removes it.
    var moveTasks: ((ProviderConnection, ProviderConnection) -> Void)? = nil
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
    /// Nil where the app has no phone remote; Remote is then left out, and so is the Yardlet account, which
    /// also needs a Yardlet server to sign in to.
    let remote: RemoteControlService?
    /// Nil where the app does not check harness CLIs (tests, fixtures); CLI Updates is then left out.
    let cliUpdates: CLIUpdateCenter?
    /// Nil where the app has no Yardlet instructions (tests, fixtures); the section is then left out.
    let instructions: YardletInstructionsStore?
    /// The routing evaluation's switch, shown with Yardlet Instructions; nil leaves it out.
    let evaluation: RoutingEvaluationStore?
    /// Nil where the window does not count token usage (tests, fixtures); Usage is then left out.
    let usage: SettingsUsageContext?
    /// Yardlet's lid helper; nil where the app has none (tests, fixtures), and General leaves its
    /// switch out.
    let lidHelper: LidSleepHelper?
    /// Non-nil when this sheet shows a remote Mac's Settings (§15.36).
    let remoteHost: RemoteHostModel?
    private let initialSectionRawValue: String?
    @State private var section: SettingsSection
    @State private var focusedSection: SettingsSection?
    @State private var appliedInitialRemoteSection = false
    @State private var pendingRemoteConfirmation: RemoteHostSettingsProjection.Confirmation?
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
    @AppStorage(PersonalAgentNotificationPreference.key) private var notifiesPersonalAgentMessages = true
    /// Followed by the app's mailbox as it changes (`AppModel.followMailbox`); off by default.
    @AppStorage(MailboxPreference.key) private var showsMailbox = false
    @AppStorage(MailboxPreference.notificationsKey) private var notifiesNewMail = true
    /// Read by the browser host client as it changes and by each memory check (`MemorySaverPreference`).
    @AppStorage(MemorySaverPreference.key) private var savesMemory = true
    @AppStorage(MemorySaverPreference.levelKey) private var memorySaverLevel = BrowserMemorySaver.Level.balanced
    /// `RunningWorkActivity` registers or removes the lid helper as it changes.
    @AppStorage(LidClosedWorkPreference.key) private var keepsWorkingWithLidClosed = false
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
        usage: SettingsUsageContext? = nil,
        lidHelper: LidSleepHelper? = nil,
        remoteHost: RemoteHostModel? = nil
    ) {
        self.size = size
        self.connectors = connectors
        self.vault = vault
        self.accounts = accounts
        self.remote = remote
        self.cliUpdates = cliUpdates
        self.instructions = instructions
        self.evaluation = evaluation
        self.usage = usage
        self.lidHelper = lidHelper
        self.remoteHost = remoteHost
        self.initialSectionRawValue = initialSection
        self.notificationCenter = notificationCenter
        _notifications = State(initialValue: SystemNotificationSettingsModel(center: notificationCenter))
        let available = remoteHost.map { RemoteHostSettingsProjection.availableSections($0.hostSettings, offersAccounts: $0.offersHostAccounts) }
            ?? SettingsSection.available(
                hasAccounts: accounts != nil, hasConnectors: connectors != nil, hasVault: vault != nil,
                hasRemote: remote != nil, hasYardletAccount: remote?.relayURL != nil, hasCLIUpdates: cliUpdates != nil,
                hasInstructions: instructions != nil, hasUsage: usage != nil)
        _section = State(initialValue: SettingsSection.initial(initialSection, available: available))
        _accountCenter = State(initialValue: AccountCenterModel(
            connections: accounts?.connections ?? ProviderConnectionStore(),
            codexEnvironmentManager: accounts?.codexEnvironmentManager))
    }

    private var isRemoteWritable: Bool {
        guard let remoteHost else { return true }
        return remoteHost.hostSettings?.writable == true
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
                    .help(accountCenter.loginController.isRunning ? L10n.string("Finish or cancel the sign-in first") : "")
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
                        // The Yardlet account above the headings, as both apps put the account first; then
                        // each heading over its sections, as the ChatGPT app's Personal, Integrations, Coding.
                        let sections = sections
                        if sections.contains(.yardletAccount), let remote {
                            SettingsAccountSectionRow(summary: YardletAccountSettingsView.summary(remote),
                                                      isSelected: section == .yardletAccount) { section = .yardletAccount }
                        }
                        ForEach(SettingsSection.Group.allCases, id: \.self) { group in
                            let members = sections.filter { $0.group == group }
                            if !members.isEmpty {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(members) { item in
                                    SettingsSectionRow(item: item, isSelected: item == section) { section = item }
                                }
                            }
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
                    } else if section.isConnectionSection, let remoteHost {
                        // Another Mac's Accounts and Harnesses, drawn by the same content from its values (§15.37).
                        VStack(alignment: .leading, spacing: 0) {
                            detailHeader.padding(.horizontal, 20).padding(.top, 20)
                            if section == .harnesses {
                                remoteHost.harnessesSettingsSectionView()
                            } else {
                                remoteHost.accountsSettingsSectionView()
                            }
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                detailHeader
                                if let remoteHost, let hostSettings = remoteHost.hostSettings, !hostSettings.writable {
                                    Text(RemoteHostSettingsProjection.permissionNote(hostName: remoteHost.name))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let error = remoteHost?.commandError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
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
        .onChange(of: remoteHost?.hostSettings != nil, initial: true) { _, hasSettings in
            guard hasSettings, !appliedInitialRemoteSection else { return }
            appliedInitialRemoteSection = true
            let requested = remoteHost?.requestedSettingsSection ?? initialSectionRawValue
            if let requested, let target = SettingsSection(rawValue: requested), sections.contains(target) {
                section = target
                focusedSection = target
            }
        }
        .alert(
            pendingRemoteConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingRemoteConfirmation != nil },
                set: { if !$0 { pendingRemoteConfirmation = nil } }
            ),
            presenting: pendingRemoteConfirmation
        ) { confirmation in
            Button(L10n.string("Cancel"), role: .cancel) {
                pendingRemoteConfirmation = nil
            }
            Button(L10n.string("Change")) {
                pendingRemoteConfirmation = nil
                guard let remoteHost else { return }
                Task { await remoteHost.setHostSetting(confirmation.settingID, value: confirmation.value, confirmed: true) }
            }
        } message: { confirmation in
            Text(confirmation.message)
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
        if let remoteHost {
            return RemoteHostSettingsProjection.availableSections(remoteHost.hostSettings, offersAccounts: remoteHost.offersHostAccounts)
        }
        return SettingsSection.available(hasAccounts: accounts != nil, hasConnectors: connectors != nil, hasVault: vault != nil,
                                         hasRemote: remote != nil, hasYardletAccount: remote?.relayURL != nil,
                                         hasCLIUpdates: cliUpdates != nil, hasInstructions: instructions != nil,
                                         hasUsage: usage != nil)
    }

    private var effectiveUsage: SettingsUsageContext? {
        if let usage { return usage }
        guard let remoteHost, let remoteUsage = remoteHost.hostSettings?.usage else { return nil }
        return SettingsUsageContext(
            overview: { RemoteHostSettingsProjection.tokenUsageOverview(remoteHost.hostSettings?.usage ?? remoteUsage) },
            isCounting: { (remoteHost.hostSettings?.usage ?? remoteUsage).isCounting },
            limitsCheckedAt: { (remoteHost.hostSettings?.usage ?? remoteUsage).limitsCheckedAt.map(RemoteHostSettingsProjection.date) }
        )
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
            moveTasks: accounts.moveTasks,
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
        if let remoteHost, remoteHost.hostSettings == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch section {
            case .yardletAccount:
                if let remote { YardletAccountSettingsView(service: remote) }
            case .general:
                let rows = remoteHost != nil
                    ? RemoteHostSettingsProjection.generalRows(remoteHost?.hostSettings)
                    : YardletSettingCatalog.rows(in: .general, context: settingsContext)
                // The rows come from the settings catalog, which the agent's settings tools list too, under
                // their headings.
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(GeneralSettingsGroup.allCases, id: \.self) { group in
                        let members = rows.filter { $0.generalGroup == group }
                        if !members.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.callout.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                VStack(spacing: 0) {
                                    ForEach(Array(members.enumerated()), id: \.element.id) { index, setting in
                                        if index > 0 { Divider().padding(.leading, Self.dividerLeading) }
                                        generalRow(setting)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .parityCard()
                            }
                        }
                    }
                }
                .disabled(!isRemoteWritable)
            case .appearance:
                appearanceDetail
            case .notifications:
                notificationDetail
            case .instructions:
                if let instructions {
                    YardletInstructionsSettingsView(store: instructions, evaluation: evaluation)
                } else if let remoteHost, let remoteInstructions = remoteHost.hostSettings?.instructions {
                    YardletInstructionsSettingsView(remote: .init(
                        state: remoteInstructions,
                        isEnabled: remoteHost.hostSettingValue(.yardletInstructions) == YardletSetting.on,
                        isEvaluationEnabled: remoteHost.hostSettingValue(.dailyEvaluation) == YardletSetting.on,
                        onSetEnabled: { requestRemoteSettingChange(.yardletInstructions, to: $0 ? YardletSetting.on : YardletSetting.off) },
                        onChangeText: { remoteHost.scheduleHostInstructionsSave($0) },
                        onSetEvaluationEnabled: { requestRemoteSettingChange(.dailyEvaluation, to: $0 ? YardletSetting.on : YardletSetting.off) }
                    ))
                    .disabled(!isRemoteWritable)
                }
            case .connectors:
                if let connectors {
                    ConnectorSettingsView(center: connectors)
                } else if let remoteHost {
                    remoteHost.connectorsSettingsSectionView()
                }
            case .vault:
                if let vault { VaultSettingsView(vault: vault) }
            case .remote:
                if let remote { RemoteSettingsView(service: remote) }
            case .cliUpdates:
                if let cliUpdates {
                    CLIUpdateSettingsView(center: cliUpdates, runtimes: accounts?.runtimeSelections)
                } else if let remoteHost, let remoteCLI = remoteHost.hostSettings?.cliUpdates {
                    CLIUpdateSettingsView(remote: .init(
                        state: remoteCLI,
                        isAutoUpdateEnabled: remoteHost.hostSettingValue(.cliAutomaticUpdates) == YardletSetting.on,
                        onSetAutoUpdate: { requestRemoteSettingChange(.cliAutomaticUpdates, to: $0 ? YardletSetting.on : YardletSetting.off) },
                        onCheck: { harness in Task { await remoteHost.performHostCLIUpdate(action: "check", harness: harness.rawValue) } },
                        onUseNewest: { harness in Task { await remoteHost.performHostCLIUpdate(action: "useNewest", harness: harness.rawValue) } }
                    ))
                    .disabled(!isRemoteWritable)
                }
            case .usage:
                if let usage = effectiveUsage {
                    let rows = remoteHost != nil
                        ? RemoteHostSettingsProjection.usageRows(remoteHost?.hostSettings)
                        : YardletSettingCatalog.rows(in: .usage, context: settingsContext)
                    // The page's counts, then its switch as the settings catalog draws it.
                    TokenUsagePage(
                        overview: usage.overview, isCounting: usage.isCounting, limitsCheckedAt: usage.limitsCheckedAt,
                        switchRow: AnyView(VStack(spacing: 0) {
                            Divider()
                            ForEach(rows) { setting in
                                preferenceRow(setting)
                            }
                        }.disabled(!isRemoteWritable)))
                }
            case .accounts, .harnesses:
                EmptyView()
            }
        }
    }

    /// What the settings catalog reads its rows' presence from: the objects this window has.
    private var settingsContext: YardletSettingsContext {
        YardletSettingsContext(
            vault: vault, remote: remote, cliUpdates: cliUpdates, instructions: instructions, evaluation: evaluation,
            connections: accounts?.connections, hasConnectors: connectors != nil, hasUsage: usage != nil,
            lidHelper: lidHelper,
            updateChecks: sparkle.map { sparkle in
                YardletSettingSwitch(get: { sparkle.checksAutomatically }, set: { sparkle.checksAutomatically = $0 })
            })
    }

    private func requestRemoteSettingChange(_ setting: YardletSetting, to value: String) {
        guard let remoteHost, remoteHost.hostSettings?.writable == true else { return }
        let current = remoteHost.hostSettingValue(setting)
        guard current != value else { return }
        remoteHost.commandError = nil
        if let confirmation = RemoteHostSettingsProjection.confirmation(for: setting, from: current, to: value) {
            pendingRemoteConfirmation = confirmation
        } else {
            Task { await remoteHost.setHostSetting(setting.id, value: value, confirmed: false) }
        }
    }

    @ViewBuilder
    private func preferenceRow(_ setting: YardletSetting) -> some View {
        if let remoteHost {
            SettingsPreferenceRow(
                setting: setting,
                icon: settingsControlIcon(setting.symbol),
                remoteValue: remoteHost.hostSettingValue(setting),
                onSelectRemote: { requestRemoteSettingChange(setting, to: $0) }
            )
        } else {
            SettingsPreferenceRow(setting: setting, icon: settingsControlIcon(setting.symbol))
        }
    }

    /// One General row: the catalog's row for a setting in Yardlet's defaults, or the row of a setting kept
    /// elsewhere. The Codex app's General rows (`settings.ide.language`, `settings.general.macMenuBar`) come
    /// first and in its order.
    @ViewBuilder
    private func generalRow(_ setting: YardletSetting) -> some View {
        switch setting.id {
        case YardletSetting.language.id:
            languageRow(setting)
        case YardletSetting.hideKeysAndTokens.id:
            if let vault {
                CredentialHidingRow(vault: vault, setting: setting, icon: settingsControlIcon(setting.symbol))
            } else if let remoteHost {
                let isAllowedBuild = remoteHost.hostSettings?.credentialHidingAllowedBuild ?? false
                CredentialHidingContentRow(
                    setting: setting,
                    icon: settingsControlIcon(setting.symbol),
                    hidesCredentials: remoteHost.hostSettingValue(setting) == YardletSetting.on,
                    isAllowedBuild: isAllowedBuild,
                    onToggle: { hides in
                        requestRemoteSettingChange(setting, to: hides ? YardletSetting.on : YardletSetting.off)
                    }
                )
            }
        case YardletSetting.keepWorkingWithLidClosed.id:
            if let lidHelper {
                lidClosedWorkRow(lidHelper, setting: setting)
            } else if let remoteHost {
                remoteLidClosedWorkRow(remoteHost, setting: setting)
            }
        case YardletSetting.memorySaver.id:
            memorySaverRow(setting)
        case YardletSetting.checkForUpdates.id:
            if let sparkle { updateChecksRow(sparkle, setting: setting) }
        default:
            preferenceRow(setting)
        }
    }

    private func languageRow(_ setting: YardletSetting) -> some View {
        HStack(spacing: 12) {
            settingsControlIcon(setting.symbol)
            SettingsRowText(setting: setting)
            Spacer(minLength: 8)
            Picker(setting.title, selection: Binding(
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
    }

    /// Sparkle's own switch, in a public build.
    private func updateChecksRow(_ sparkle: YardletSparkle, setting: YardletSetting) -> some View {
        HStack(spacing: 12) {
            settingsControlIcon(setting.symbol)
            SettingsRowText(setting: setting)
            Spacer(minLength: 8)
            Toggle(setting.title, isOn: Binding(
                get: { sparkle.checksAutomatically },
                set: { sparkle.checksAutomatically = $0 }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
        }
        .padding(.vertical, 14)
    }

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label(YardletSetting.theme.title, systemImage: YardletSetting.theme.symbol)
                    .font(.callout.weight(.semibold))
                Picker(YardletSetting.theme.title, selection: $appearanceRawValue) {
                    ForEach(YardletAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(YardletSetting.interfaceSize.title, systemImage: YardletSetting.interfaceSize.symbol)
                    .font(.callout.weight(.semibold))
                Picker(YardletSetting.interfaceSize.title, selection: $interfaceSizeRawValue) {
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

    private var savesMemoryBinding: Binding<Bool> {
        guard let remoteHost else { return $savesMemory }
        return Binding(
            get: { remoteHost.hostSettingValue(.memorySaver) == YardletSetting.on },
            set: { requestRemoteSettingChange(.memorySaver, to: $0 ? YardletSetting.on : YardletSetting.off) }
        )
    }

    private var memorySaverLevelBinding: Binding<BrowserMemorySaver.Level> {
        guard let remoteHost else { return $memorySaverLevel }
        return Binding(
            get: {
                BrowserMemorySaver.Level(rawValue: remoteHost.hostSettingValue(.memorySaverLevel)) ?? .balanced
            },
            set: { requestRemoteSettingChange(.memorySaverLevel, to: $0.rawValue) }
        )
    }

    /// "Memory saver", and while it is on Chrome's levels under it, each with its line, as Chrome's Memory page has them.
    private func memorySaverRow(_ setting: YardletSetting) -> some View {
        let isOn = savesMemoryBinding.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                settingsControlIcon(setting.symbol)
                SettingsRowText(setting: setting)
                Spacer(minLength: 8)
                Toggle(setting.title, isOn: savesMemoryBinding)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(.vertical, 14)
            if isOn {
                Picker(YardletSetting.memorySaverLevel.title, selection: memorySaverLevelBinding) {
                    ForEach(BrowserMemorySaver.Level.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title).font(.callout)
                            Text(level.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 6)
                        .tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .controlSize(.small)
                .padding(.leading, Self.dividerLeading)
                .padding(.bottom, 8)
            }
        }
    }

    /// "Keep tasks working with the lid closed", with one line while it is on and macOS has not let
    /// the helper run yet.
    private func lidClosedWorkRow(_ helper: LidSleepHelper, setting: YardletSetting) -> some View {
        let note: String? = switch (keepsWorkingWithLidClosed, helper.status) {
        case (true, .needsApproval): L10n.string("Allow Yardlet in the background in System Settings")
        case (true, .off): L10n.string("macOS did not add Yardlet's helper")
        case (true, .unavailable): L10n.string("Not available in this copy of Yardlet")
        default: nil
        }
        return HStack(spacing: 12) {
            settingsControlIcon(setting.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.callout.weight(.medium))
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
            Toggle(setting.title, isOn: $keepsWorkingWithLidClosed)
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
        }
        .padding(.vertical, 14)
    }

    private func remoteLidClosedWorkRow(_ remoteHost: RemoteHostModel, setting: YardletSetting) -> some View {
        let isOn = remoteHost.hostSettingValue(setting) == YardletSetting.on
        let status = remoteHost.hostSettings?.lidHelperStatus
        let note: String? = switch (isOn, status) {
        case (true, "needsApproval"?): L10n.string("Allow Yardlet in the background in System Settings")
        case (true, "off"?): L10n.string("macOS did not add Yardlet's helper")
        case (true, "unavailable"?): L10n.string("Not available in this copy of Yardlet")
        default: nil
        }
        return HStack(spacing: 12) {
            settingsControlIcon(setting.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.callout.weight(.medium))
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(setting.title, isOn: Binding(
                get: { isOn },
                set: { requestRemoteSettingChange(setting, to: $0 ? YardletSetting.on : YardletSetting.off) }
            ))
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
                detail: L10n.string("Notifies when a background task finishes, fails or needs approval."),
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
            Divider()
            HStack(spacing: 12) {
                settingsControlIcon(YardletSetting.personalAgentMessages.symbol)
                SettingsRowText(setting: .personalAgentMessages)
                Spacer(minLength: 8)
                Toggle(YardletSetting.personalAgentMessages.title, isOn: $notifiesPersonalAgentMessages)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(.vertical, 6)
            if showsMailbox {
                Divider()
                HStack(spacing: 12) {
                    settingsControlIcon(YardletSetting.newMail.symbol)
                    SettingsRowText(setting: .newMail)
                    Spacer(minLength: 8)
                    Toggle(YardletSetting.newMail.title, isOn: $notifiesNewMail)
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                .padding(.vertical, 6)
            }
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

/// The Yardlet account above the section list's headings, as macOS System Settings puts the Apple Account at
/// the top of its list: a person symbol, the section's name and the account or that nobody is signed in.
private struct SettingsAccountSectionRow: View {
    let summary: String
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SettingsSection.yardletAccount.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 46)
            .background(isSelected ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsSection.yardletAccount.title)
        .accessibilityValue(summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// General's switch for hiding keys and tokens from agents (`VaultCenter.hidesCredentials`), which follows the vault as
/// it changes; turning it off asks Touch ID or the login password.
private struct CredentialHidingRow<Icon: View>: View {
    @ObservedObject var vault: VaultCenter
    let setting: YardletSetting
    let icon: Icon

    var body: some View {
        CredentialHidingContentRow(
            setting: setting,
            icon: icon,
            hidesCredentials: vault.hidesCredentials,
            isAllowedBuild: vault.isAllowedBuild,
            onToggle: { hides in Task { await vault.setHidesCredentials(hides) } }
        )
    }
}

private struct CredentialHidingContentRow<Icon: View>: View {
    let setting: YardletSetting
    let icon: Icon
    let hidesCredentials: Bool
    let isAllowedBuild: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.callout.weight(.medium))
                Text(setting.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isAllowedBuild {
                    Text(L10n.string("Always on in a build that is not team-signed."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(setting.title, isOn: Binding(get: { hidesCredentials }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .disabled(!isAllowedBuild)
        }
        .padding(.vertical, 14)
    }
}

/// A settings row's words: the setting's title, with its line under it where it has one.
struct SettingsRowText: View {
    let setting: YardletSetting

    var body: some View {
        if let detail = setting.detail {
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(setting.title).font(.callout.weight(.medium))
        }
    }
}

/// A General row for a setting kept in Yardlet's defaults: its symbol and words, and a switch, or segments
/// for a choice, on the key the rest of the app reads, so a change the agent's settings tools make shows here.
private struct SettingsPreferenceRow<Icon: View>: View {
    let setting: YardletSetting
    let icon: Icon
    var remoteValue: String? = nil
    var onSelectRemote: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            icon
            SettingsRowText(setting: setting)
            Spacer(minLength: 8)
            control.modifier(SettingsHint(hint: setting.hint))
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private var control: some View {
        if let remoteValue, let onSelectRemote {
            let label = setting.controlLabel ?? setting.title
            switch setting.storage {
            case .flag:
                Toggle(label, isOn: Binding(
                    get: { remoteValue == YardletSetting.on },
                    set: { onSelectRemote($0 ? YardletSetting.on : YardletSetting.off) }
                ))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
            case .choice:
                Picker(label, selection: Binding(
                    get: { remoteValue },
                    set: { onSelectRemote($0) }
                )) {
                    ForEach(setting.choices, id: \.value) { choice in
                        Text(choice.title).tag(choice.value)
                    }
                }
                .labelsHidden()
                .settingsChoiceStyle(count: setting.choices.count)
                .fixedSize()
                .controlSize(.small)
            case .app:
                EmptyView()
            }
        } else {
            switch setting.storage {
            case let .flag(key, defaultValue):
                PreferenceSwitch(setting.controlLabel ?? setting.title, key: key, defaultValue: defaultValue)
            case let .choice(key, defaultValue):
                PreferenceSegments(setting.controlLabel ?? setting.title, key: key, defaultValue: defaultValue,
                                   choices: setting.choices)
            case .app:
                EmptyView()
            }
        }
    }
}

/// A control's tooltip and accessibility hint, where its setting has one.
private struct SettingsHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.help(hint).accessibilityHint(hint)
        } else {
            content
        }
    }
}

private struct PreferenceSwitch: View {
    let label: String
    @AppStorage private var isOn: Bool

    init(_ label: String, key: String, defaultValue: Bool) {
        self.label = label
        _isOn = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.paritySwitch)
            .controlSize(.small)
    }
}

private struct PreferenceSegments: View {
    let label: String
    let choices: [YardletSetting.Choice]
    @AppStorage private var value: String

    init(_ label: String, key: String, defaultValue: String, choices: [YardletSetting.Choice]) {
        self.label = label
        self.choices = choices
        _value = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        Picker(label, selection: $value) {
            ForEach(choices, id: \.value) { choice in
                Text(choice.title).tag(choice.value)
            }
        }
        .labelsHidden()
        .settingsChoiceStyle(count: choices.count)
        .fixedSize()
        .controlSize(.small)
    }
}

private extension View {
    /// Segments for up to three choices; a menu for more, as each segment is as wide as the longest one.
    @ViewBuilder func settingsChoiceStyle(count: Int) -> some View {
        if count > 3 { pickerStyle(.menu) } else { pickerStyle(.segmented) }
    }
}
