import SwiftUI

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
    /// Nil where the app has no phone remote; Remote is then left out.
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
        self.usage = usage
        self.lidHelper = lidHelper
        self.notificationCenter = notificationCenter
        _notifications = State(initialValue: SystemNotificationSettingsModel(center: notificationCenter))
        _section = State(initialValue: SettingsSection.initial(initialSection, available: SettingsSection.available(
            hasAccounts: accounts != nil, hasConnectors: connectors != nil, hasVault: vault != nil,
            hasRemote: remote != nil, hasCLIUpdates: cliUpdates != nil, hasInstructions: instructions != nil,
            hasUsage: usage != nil)))
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
                                  hasInstructions: instructions != nil, hasUsage: usage != nil)
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
        switch section {
        case .general:
            // The rows come from the settings catalog, which the agent's settings tools list too.
            VStack(spacing: 0) {
                ForEach(Array(YardletSettingCatalog.rows(in: .general, context: settingsContext).enumerated()),
                        id: \.element.id) { index, setting in
                    if index > 0 { Divider().padding(.leading, Self.dividerLeading) }
                    generalRow(setting)
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
        case .usage:
            if let usage {
                // The page's counts, then its switch as the settings catalog draws it.
                TokenUsagePage(
                    overview: usage.overview, isCounting: usage.isCounting, limitsCheckedAt: usage.limitsCheckedAt,
                    switchRow: AnyView(VStack(spacing: 0) {
                        Divider()
                        ForEach(YardletSettingCatalog.rows(in: .usage, context: settingsContext)) { setting in
                            SettingsPreferenceRow(setting: setting, icon: settingsControlIcon(setting.symbol))
                        }
                    }))
            }
        case .accounts, .harnesses:
            EmptyView()
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

    /// One General row: the catalog's row for a setting in Yardlet's defaults, or the row of a setting kept
    /// elsewhere. The Codex app's General rows (`settings.ide.language`, `settings.general.macMenuBar`) come
    /// first and in its order.
    @ViewBuilder
    private func generalRow(_ setting: YardletSetting) -> some View {
        switch setting.id {
        case YardletSetting.language.id:
            languageRow(setting)
        case YardletSetting.hideKeysAndTokens.id:
            if let vault { CredentialHidingRow(vault: vault, setting: setting, icon: settingsControlIcon(setting.symbol)) }
        case YardletSetting.keepWorkingWithLidClosed.id:
            if let lidHelper { lidClosedWorkRow(lidHelper, setting: setting) }
        case YardletSetting.memorySaver.id:
            memorySaverRow(setting)
        case YardletSetting.checkForUpdates.id:
            if let sparkle { updateChecksRow(sparkle, setting: setting) }
        default:
            SettingsPreferenceRow(setting: setting, icon: settingsControlIcon(setting.symbol))
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

    /// "Memory saver", and while it is on Chrome's levels under it, each with its line, as Chrome's Memory page has them.
    private func memorySaverRow(_ setting: YardletSetting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                settingsControlIcon(setting.symbol)
                SettingsRowText(setting: setting)
                Spacer(minLength: 8)
                Toggle(setting.title, isOn: $savesMemory)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(.vertical, 14)
            if savesMemory {
                Picker(YardletSetting.memorySaverLevel.title, selection: $memorySaverLevel) {
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

/// General's switch for hiding keys and tokens from agents (`VaultCenter.hidesCredentials`), which follows the vault as
/// it changes; turning it off asks Touch ID or the login password.
private struct CredentialHidingRow<Icon: View>: View {
    @ObservedObject var vault: VaultCenter
    let setting: YardletSetting
    let icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.callout.weight(.medium))
                Text(setting.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !vault.isAllowedBuild {
                    Text(L10n.string("Always on in a build that is not team-signed."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(setting.title, isOn: Binding(
                get: { vault.hidesCredentials }, set: { hides in Task { await vault.setHidesCredentials(hides) } }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
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
        .pickerStyle(.segmented)
        .fixedSize()
        .controlSize(.small)
    }
}
