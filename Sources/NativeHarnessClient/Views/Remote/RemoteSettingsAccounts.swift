import SwiftUI

/// The remote window's Settings › Harness Accounts section (§15.37), drawing the local `ConnectionCenterContent`
/// (`AccountList` in `.manage` mode) fed by the host's accounts and settings.
struct RemoteSettingsAccountsSection: View {
    @Bindable var model: RemoteHostModel
    var initialHarness: HarnessKind? = nil
    @State private var addingAccount = false
    @State private var setupExpanded = false

    var body: some View {
        ConnectionCenterContent(
            tab: .accounts,
            model: model.remoteAccountCenterModel,
            runtimeSelections: model.remoteRuntimeSelections,
            connections: model.remoteConnections,
            harnessUsage: model.remoteAccountHarnessUsage,
            initialHarness: initialHarness,
            addingAccount: $addingAccount,
            setupExpanded: $setupExpanded,
            allowsAccountManagement: false,
            canChooseAccounts: model.canEditHostSettings,
            remoteNote: model.remoteAccountsNote,
            continuesAtUsageLimit: Binding(
                get: { model.hostAccountsState?.continuesAtUsageLimit ?? true },
                set: { model.setHostAccountSetting(YardletSetting.continueAtUsageLimit.id, enabled: $0) }
            ),
            movesTasksToAccountWithRoom: Binding(
                get: { model.hostAccountsState?.movesTasksToAccountWithRoom ?? true },
                set: { model.setHostAccountSetting(YardletSetting.moveTasksToAccountsWithRoom.id, enabled: $0) }
            ),
            onFinish: {}
        )
        .task {
            await model.watchHostAccounts()
        }
        .onDisappear {
            model.unwatchHostAccounts()
        }
    }
}

/// The remote window's Settings › Harnesses section (§15.37), drawing the local `ConnectionCenterContent`
/// (`.harnesses` tab) fed by the host's harness runtimes and default logins.
struct RemoteSettingsHarnessesSection: View {
    @Bindable var model: RemoteHostModel
    var initialSelectedHarness: HarnessKind? = nil
    var showsInitialConnectionDetails = false
    @State private var addingAccount = false
    @State private var setupExpanded = false

    var body: some View {
        ConnectionCenterContent(
            tab: .harnesses,
            model: model.remoteAccountCenterModel,
            runtimeSelections: model.remoteRuntimeSelections,
            connections: model.remoteConnections,
            harnessUsage: model.remoteAccountHarnessUsage,
            initialHarness: nil,
            addingAccount: $addingAccount,
            setupExpanded: $setupExpanded,
            allowsAccountManagement: false,
            canChooseAccounts: model.canEditHostSettings,
            remoteNote: model.remoteHarnessesNote,
            initialSelectedHarness: initialSelectedHarness,
            showsInitialConnectionDetails: showsInitialConnectionDetails,
            onFinish: {}
        )
        .task {
            await model.watchHostAccounts()
        }
        .onDisappear {
            model.unwatchHostAccounts()
        }
    }
}

/// The remote window's Settings › Connectors section (§15.37), drawing the local `ConnectorSettingsView`
/// fed by the host's connectors and `claude.ai` connector setting.
struct RemoteSettingsConnectorsSection: View {
    @Bindable var model: RemoteHostModel

    var body: some View {
        ConnectorSettingsView(
            center: model.remoteConnectorCenter,
            isRemote: true,
            canEditSettings: model.canEditHostSettings,
            remoteNote: model.remoteConnectorsNote,
            claudeAIConnectorsOverride: Binding(
                get: { model.hostAccountsState?.claudeAIConnectors ?? false },
                set: { model.setHostConnector(YardletSetting.claudeAIConnectors.id, enabled: $0) }
            )
        )
        .task {
            await model.watchHostAccounts()
        }
        .onDisappear {
            model.unwatchHostAccounts()
        }
    }
}

extension RemoteHostModel {
    /// Hook for the remote Settings sheet: the host's Accounts section.
    func accountsSettingsSectionView(initialHarness: HarnessKind? = nil) -> some View {
        RemoteSettingsAccountsSection(model: self, initialHarness: initialHarness)
    }

    /// Hook for the remote Settings sheet: the host's Harnesses section.
    func harnessesSettingsSectionView(
        initialSelectedHarness: HarnessKind? = nil,
        showsInitialConnectionDetails: Bool = false
    ) -> some View {
        RemoteSettingsHarnessesSection(
            model: self,
            initialSelectedHarness: initialSelectedHarness,
            showsInitialConnectionDetails: showsInitialConnectionDetails
        )
    }

    /// Hook for the remote Settings sheet: the host's Connectors section.
    func connectorsSettingsSectionView() -> some View {
        RemoteSettingsConnectorsSection(model: self)
    }

    /// The `SettingsAccountsContext` backed by this remote host model, for a `SettingsCenterView`
    /// that embeds the host's stores directly.
    func settingsAccountsContext(initialHarness: HarnessKind? = nil) -> SettingsAccountsContext {
        SettingsAccountsContext(
            runtimeSelections: remoteRuntimeSelections,
            connections: remoteConnections,
            initialHarness: initialHarness,
            harnessUsage: remoteAccountHarnessUsage
        )
    }
}
