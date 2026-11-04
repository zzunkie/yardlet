import Foundation
import YardletRemote

extension RemoteHostModel {
    var canEditHostSettings: Bool {
        hostAccountsState?.editable == true
    }

    var remoteAccountsNote: String {
        if canEditHostSettings {
            return L10n.format("Sign in, add, remove, or share accounts on %@.", name)
        }
        return L10n.format(
            "Sign in, add, remove, or share accounts on %@. To choose accounts or change settings from here, allow Change settings for this device in Settings › Remote › Paired devices on %@.",
            name, name
        )
    }

    var remoteHarnessesNote: String {
        if canEditHostSettings {
            return L10n.format("Sign in or connect providers on %@.", name)
        }
        return L10n.format(
            "Sign in or connect providers on %@. To choose runtimes from here, allow Change settings for this device in Settings › Remote › Paired devices on %@.",
            name, name
        )
    }

    var remoteConnectorsNote: String {
        if canEditHostSettings {
            return L10n.format("Connect services, sign in, or edit connectors on %@.", name)
        }
        return L10n.format(
            "Connect services, sign in, or edit connectors on %@. To turn connectors on or off from here, allow Change settings for this device in Settings › Remote › Paired devices on %@.",
            name, name
        )
    }

    var remoteAccountHarnessUsage: AccountHarnessScope.Usage {
        let withTasks = Set((hostAccountsState?.harnessesWithTasks ?? tasks.map(\.harness)).map(HarnessKind.init(rawValue:)))
        let withSubagents = Set((hostAccountsState?.harnessesWithSubagents ?? []).map(HarnessKind.init(rawValue:)))
        let chosen = (hostAccountsState?.newTaskHarness ?? newTask?.harness).map(HarnessKind.init(rawValue:))
        return AccountHarnessScope.Usage(
            withTasks: withTasks,
            chosenForNewTask: chosen,
            withSubagents: withSubagents
        )
    }

    func makeRemoteConnectionsStore() -> ProviderConnectionStore {
        let store = ProviderConnectionStore()
        store.isRemoteStore = true
        store.onRemoteChoose = { [weak self] choice in
            self?.chooseHostAccount(choice)
        }
        store.onRemoteChooseAutomatic = { [weak self] harness in
            self?.chooseAutomaticHostAccount(for: harness)
        }
        store.onRemoteSetPicksNewTaskAccount = { [weak self] picks in
            self?.setHostAccountSetting(YardletSetting.newTaskAccountAutomatically.id, enabled: picks)
        }
        store.onRemoteSetAutomaticAssignment = { [weak self] choice, included in
            self?.setHostAutomaticAssignment(included, for: choice)
        }
        store.onRemoteCheck = { [weak self] (harnesses: Set<HarnessKind>, policy: AccountCheckPolicy) in
            guard let self else { return }
            switch policy {
            case .refresh, .restart:
                let list = harnesses.count == HarnessCatalog.builtIns.count
                    ? ["*"]
                    : harnesses.map { $0.rawValue }.sorted()
                await self.loadHostAccounts(refreshHarnesses: list)
            case .ifStale, .ifOlderThan:
                if self.hostAccountsState == nil {
                    await self.loadHostAccounts()
                }
            }
        }
        return store
    }

    func makeRemoteRuntimeSelectionsStore() -> RuntimeSelectionStore {
        let suite = UserDefaults(suiteName: "com.yardlet.remote.runtime.\(id).\(UUID().uuidString)") ?? .standard
        let store = RuntimeSelectionStore(
            defaults: suite,
            discoversRuntimes: false,
            loadsPersistedSelections: false,
            candidates: { _ in [] }
        )
        store.remoteRuntimes = [:]
        store.canSelectRemoteRuntime = canEditHostSettings
        store.onSelectRemoteRuntime = { [weak self] harness, choiceID in
            self?.selectHostHarnessRuntime(harness, choiceID: choiceID)
        }
        return store
    }

    func makeRemoteConnectorCenter() -> ConnectorCenter {
        let center = ConnectorCenter(environment: .init(
            repository: InMemoryConnectorRepository(),
            credentials: InMemoryConnectorCredentialStore(),
            http: URLSessionConnectorTransport(),
            userAgent: nil,
            sha256: { $0 },
            clientVersion: "remote"
        ))
        center.onRemoteSetConnectorEnabled = { [weak self] connectorID, isOn in
            self?.setHostConnector(connectorID.uuidString, enabled: isOn)
        }
        return center
    }

    func watchHostAccounts() async {
        watchingHostAccountsCount += 1
        await loadHostAccounts()
    }

    func unwatchHostAccounts() {
        guard watchingHostAccountsCount > 0 else { return }
        watchingHostAccountsCount -= 1
        if watchingHostAccountsCount == 0, offersHostAccounts, isConnected {
            requestInOrder(.hostAccounts(watching: false))
        }
    }

    func loadHostAccounts(refreshHarnesses: [String] = []) async {
        guard offersHostAccounts else { return }
        let watching = watchingHostAccountsCount > 0
        let answer = await response(to: .hostAccounts(watching: watching, refreshHarnesses: refreshHarnesses))
        guard answer.ok, let state = answer.hostAccountsState else {
            if !answer.ok { commandError = Self.message(for: answer.error, host: name) }
            return
        }
        applyHostAccountsState(state)
    }

    func chooseHostAccount(_ choice: AccountChoice) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostAccount(
                harness: choice.harness.rawValue,
                accountID: choice.id
            ))
        }
    }

    func chooseAutomaticHostAccount(for harness: HarnessKind) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostAccount(
                harness: harness.rawValue,
                accountID: AppModelRemoteBridge.automaticAccountID
            ))
        }
    }

    func setHostAutomaticAssignment(_ included: Bool, for choice: AccountChoice) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostAccount(
                harness: choice.harness.rawValue,
                accountID: choice.id,
                automaticAssignment: included
            ))
        }
    }

    func setHostAccountSetting(_ settingID: String, enabled: Bool) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostAccount(
                settingID: settingID,
                enabled: enabled
            ))
        }
    }

    func selectHostHarnessRuntime(_ harness: HarnessKind, choiceID: String) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostHarnessRuntime(
                harness: harness.rawValue,
                choiceID: choiceID
            ))
        }
    }

    func setHostConnector(_ id: String, enabled: Bool) {
        guard offersHostAccounts else { return }
        Task {
            await performHostAccountMutation(.setHostConnector(
                id: id,
                enabled: enabled
            ))
        }
    }

    @discardableResult
    func performHostAccountMutation(_ request: RemoteRequest) async -> Bool {
        let answer = await response(to: request)
        guard answer.ok else {
            commandError = Self.message(for: answer.error, host: name)
            return false
        }
        commandError = nil
        if let state = answer.hostAccountsState {
            applyHostAccountsState(state)
        }
        return true
    }

    func applyHostAccountsState(_ state: RemoteAccountsState) {
        hostAccountsState = state
        var accounts = state.accounts
        let checkingHarnesses = Set(state.harnesses.filter { $0.checkingDefault == true }.map(\.harness))
        if !checkingHarnesses.isEmpty {
            for index in accounts.indices {
                if let harness = accounts[index].harness,
                   checkingHarnesses.contains(harness),
                   accounts[index].connectionName == nil {
                    accounts[index].checking = true
                }
            }
        }
        remoteConnections.applyRemoteAccounts(accounts, picksNewTaskAccount: state.picksNewTaskAccount)
        var runtimesByHarness: [HarnessKind: RemoteHarnessRuntime] = [:]
        for runtime in state.harnesses {
            let kind = HarnessKind(rawValue: runtime.harness)
            runtimesByHarness[kind] = runtime
        }
        remoteRuntimeSelections.remoteRuntimes = runtimesByHarness
        remoteRuntimeSelections.canSelectRemoteRuntime = canEditHostSettings
        remoteConnectorCenter.applyRemoteConnectors(
            state.connectors,
            cannotRead: state.cannotReadConnectors == true,
            xcodeDescription: state.xcodeDescription
        )
    }
}
