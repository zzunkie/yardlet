import Foundation
import Observation
import YardletRemote

extension AppModelRemoteBridge {
    static let automaticAccountID = "automatic"
    static let automaticRuntimeChoiceID = "automatic"
    static let runtimeChoiceInstallPrefix = "install:"

    func setWatchingHostAccounts(_ watching: Bool) {
        watchesHostAccounts = watching
        if watching {
            if hostAccountsDefaultsObserver == nil, let model {
                hostAccountsDefaultsObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: model.preferences,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.hostAccountsMayHaveChanged() }
                }
            }
        } else {
            if let observer = hostAccountsDefaultsObserver {
                NotificationCenter.default.removeObserver(observer)
                hostAccountsDefaultsObserver = nil
            }
            answeredHostAccounts = nil
            isObservingHostAccounts = false
        }
    }

    func hostAccounts(refreshHarnesses: [String]) async -> Result<RemoteAccountsState, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }
        // Refresh rereads accounts as the local button does, at most once a minute per harness, so a paired
        // device cannot keep the host probing its CLIs and providers.
        let now = Date()
        let requested = Set(refreshHarnesses.contains("*")
            ? HarnessCatalog.builtIns.map(\.id)
            : refreshHarnesses.compactMap { HarnessCatalog.descriptor(for: HarnessKind(rawValue: $0))?.id })
        let harnesses = requested.filter { now.timeIntervalSince(hostAccountsRefreshedAt[$0] ?? .distantPast) >= 60 }
            .sorted { $0.rawValue < $1.rawValue }
        for harness in harnesses { hostAccountsRefreshedAt[harness] = now }
        if !harnesses.isEmpty {
            await RemoteServer.waitAtMost(15) { @MainActor in
                await model.connections.check(
                    defaultsOf: harnesses,
                    savedOf: harnesses,
                    policy: .refresh,
                    runtimeSelections: model.runtimeSelections
                )
            }
        }
        guard let model = self.model else { return .failure(RemoteError(.unavailable)) }
        let state = readAndWatchHostAccounts(in: model)
        return .success(state)
    }

    func setHostAccount(
        harness: String?,
        accountID: String?,
        automaticAssignment: Bool?,
        settingID: String?,
        enabled: Bool?
    ) async -> Result<RemoteAccountsState, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }

        if let settingID {
            let allowedSettings: Set<String> = [
                YardletSetting.newTaskAccountAutomatically.id,
                YardletSetting.continueAtUsageLimit.id,
                YardletSetting.moveTasksToAccountsWithRoom.id
            ]
            guard let enabled,
                  allowedSettings.contains(settingID),
                  let setting = YardletSettingCatalog.setting(settingID),
                  setting.value(in: model.settingsContext) != nil else {
                return .failure(RemoteError(.notAllowed))
            }
            if let refusal = await setting.set(enabled ? YardletSetting.on : YardletSetting.off, in: model.settingsContext) {
                return .failure(RemoteError(.notAllowed, refusal))
            }
            return .success(readAndWatchHostAccounts(in: model))
        }

        guard let harnessRaw = harness,
              let kind = HarnessCatalog.descriptor(for: HarnessKind(rawValue: harnessRaw))?.id,
              let accountID else {
            return .failure(RemoteError(.badRequest))
        }

        if let included = automaticAssignment {
            let choices = Self.allHostAccountChoices(for: kind, in: model.connections)
            guard let choice = choices.first(where: { $0.id == accountID }) else {
                return .failure(RemoteError(.notFound))
            }
            model.connections.setInAutomaticAssignment(included, for: choice)
            return .success(readAndWatchHostAccounts(in: model))
        }

        if accountID == Self.automaticAccountID {
            guard model.connections.offersAutomaticNewTaskAccount(for: kind) else {
                return .failure(RemoteError(.notAllowed))
            }
            model.connections.chooseAutomaticNewTaskAccount(for: kind)
            return .success(readAndWatchHostAccounts(in: model))
        }

        let choices = model.connections.choices(for: [kind])
        guard let choice = choices.first(where: { $0.id == accountID }),
              AccountListProjection.canChoose(choice, mode: .manage) else {
            return .failure(RemoteError(.notAllowed))
        }
        model.connections.choose(choice)
        return .success(readAndWatchHostAccounts(in: model))
    }

    func setHostHarnessRuntime(
        harness: String,
        choiceID: String
    ) async -> Result<RemoteAccountsState, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }
        guard let kind = HarnessCatalog.descriptor(for: HarnessKind(rawValue: harness))?.id else {
            return .failure(RemoteError(.notFound))
        }

        if choiceID == Self.automaticRuntimeChoiceID {
            guard model.runtimeSelections.automaticURL(for: kind) != nil else {
                return .failure(RemoteError(.notAllowed))
            }
            model.runtimeSelections.selectAutomatic(for: kind)
        } else if choiceID.hasPrefix(Self.runtimeChoiceInstallPrefix),
                  let index = Int(choiceID.dropFirst(Self.runtimeChoiceInstallPrefix.count)) {
            let installs = model.runtimeSelections.discoveredInstalls(for: kind)
            guard installs.indices.contains(index) else {
                return .failure(RemoteError(.notFound))
            }
            model.runtimeSelections.select(installs[index], for: kind)
        } else {
            return .failure(RemoteError(.notAllowed))
        }

        Task { @MainActor [weak model] in
            guard let model else { return }
            await model.connections.check(
                defaultsOf: [kind],
                savedOf: [kind],
                policy: .restart,
                runtimeSelections: model.runtimeSelections
            )
        }
        return .success(readAndWatchHostAccounts(in: model))
    }

    func setHostConnector(
        id: String,
        enabled: Bool
    ) async -> Result<RemoteAccountsState, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }

        if id == YardletSetting.claudeAIConnectors.id || id == "claude.ai" {
            guard let setting = YardletSettingCatalog.setting(YardletSetting.claudeAIConnectors.id),
                  setting.value(in: model.settingsContext) != nil else {
                return .failure(RemoteError(.notAllowed))
            }
            if let refusal = await setting.set(enabled ? YardletSetting.on : YardletSetting.off, in: model.settingsContext) {
                return .failure(RemoteError(.notAllowed, refusal))
            }
            return .success(readAndWatchHostAccounts(in: model))
        }

        guard let center = model.connectorCenter,
              let uuid = UUID(uuidString: id),
              let record = center.connectors.first(where: { $0.id == uuid }) else {
            return .failure(RemoteError(.notFound))
        }
        guard record.status == .connected || !center.isOn(uuid) else {
            return .failure(RemoteError(.notAllowed))
        }
        center.setConnector(uuid, on: enabled)
        return .success(readAndWatchHostAccounts(in: model))
    }

    // MARK: - Projection & Observation

    func readAndWatchHostAccounts(in model: AppModel) -> RemoteAccountsState {
        let state = observeHostAccountsIfNeeded(in: model)
        if watchesHostAccounts {
            answeredHostAccounts = state
        }
        return state
    }

    private func observeHostAccountsIfNeeded(in model: AppModel) -> RemoteAccountsState {
        guard watchesHostAccounts, !isObservingHostAccounts else {
            return hostAccountsState(in: model)
        }
        isObservingHostAccounts = true
        return withObservationTracking {
            hostAccountsState(in: model)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservingHostAccounts = false
                self.hostAccountsMayHaveChanged()
            }
        }
    }

    func hostAccountsMayHaveChanged() {
        guard watchesHostAccounts, let model else { return }
        let next = observeHostAccountsIfNeeded(in: model)
        guard next != answeredHostAccounts else { return }
        answeredHostAccounts = next
        changeHandler?(.hostAccounts)
    }

    func hostAccountsState(in model: AppModel) -> RemoteAccountsState {
        let store = model.connections
        let catalog = HarnessCatalog.builtIns.map(\.id)
        let accounts = catalog.flatMap { harness in
            Self.allHostAccountChoices(for: harness, in: store).map { choice in
                Self.remoteHostAccount(choice, store: store)
            }
        }
        let harnesses = HarnessCatalog.builtIns.map { descriptor in
            remoteHarnessRuntime(for: descriptor, in: model)
        }
        let connectors = (model.connectorCenter?.connectors ?? []).map { record in
            Self.remoteConnector(record, in: model.connectorCenter)
        }
        let withTasks = Set(model.store.sessions.map(\.harness))
        let withSubagents = AccountHarnessScope.SubagentUse.harnesses(in: model.preferences)
        let newTaskHarness = model.composerDrafts.home.harness
        return RemoteAccountsState(
            accounts: accounts,
            harnesses: harnesses,
            connectors: connectors,
            picksNewTaskAccount: store.picksNewTaskAccount,
            continuesAtUsageLimit: UsageLimitAutoContinuePreference.isOn(in: model.preferences),
            movesTasksToAccountWithRoom: AccountMovePreference.isOn(in: model.preferences),
            claudeAIConnectors: ClaudeAIConnectorPreference.isEnabled(in: model.preferences),
            cannotReadConnectors: model.connectorCenter?.cannotReadSavedSettings == true ? true : nil,
            xcodeDescription: model.connectorCenter?.xcodeDescription,
            harnessesWithTasks: withTasks.map(\.rawValue).sorted(),
            harnessesWithSubagents: withSubagents.map(\.rawValue).sorted(),
            newTaskHarness: newTaskHarness?.rawValue
        )
    }

    static func allHostAccountChoices(for harness: HarnessKind, in store: ProviderConnectionStore) -> [AccountChoice] {
        let labels = store.knownAccountLabels
        let defaultKey = AccountChoice.nativeID(for: harness)
        let native = AccountChoice(
            harness: harness,
            connection: nil,
            snapshot: store.defaultSnapshots[harness],
            knownLabel: labels[defaultKey]
        )
        let saved = store.connections.filter { $0.harness == harness }.map { connection in
            AccountChoice(
                harness: harness,
                connection: connection,
                snapshot: store.snapshots[connection.id],
                knownLabel: labels[connection.id]
            )
        }
        return [native] + saved
    }

    static func remoteHostAccount(_ choice: AccountChoice, store: ProviderConnectionStore) -> RemoteAccount {
        let snapshot = choice.snapshot
        let usage: [RemoteAccount.Usage] = (snapshot?.usage ?? [])
            .filter { !$0.id.hasPrefix(HarnessAccountBroker.dailyUsageIDPrefix) }
            .map { metric in
                let window = AccountLimitWindow(metric: metric)
                return RemoteAccount.Usage(
                    label: metric.label,
                    usedPercent: window.remainingPercent.map { Int((100 - $0).rounded()) },
                    resetsAt: window.resetsAt.map(RemoteJSON.milliseconds),
                    detail: metric.detail,
                    evidence: metric.evidence.rawValue
                )
            }
        let isSelectedForNewTasks = AccountListProjection.isSelected(choice, mode: .manage, store: store)
        let isDefaultSelected = store.selection[choice.harness] == choice.connection?.id
        let canChoose = AccountListProjection.canChoose(choice, mode: .manage) && !(choice.connection.map(store.isMovingAway) ?? false)

        var account = RemoteAccount(
            id: choice.id,
            name: choice.title,
            detail: snapshot?.detail ?? AccountListProjection.accountLine(choice),
            usage: usage,
            current: isSelectedForNewTasks ? true : nil,
            available: canChoose ? true : nil
        )
        account.state = snapshot.flatMap { RemoteAccount.State(rawValue: $0.state.rawValue) }
        account.checkedAt = snapshot.map { RemoteJSON.milliseconds($0.checkedAt) }
        account.harness = choice.harness.rawValue
        account.connectionName = choice.connection?.name
        account.providerId = choice.connection?.providerID ?? snapshot?.providerID
        account.organization = snapshot?.accountOrganization
        account.plan = snapshot?.accountPlan
        account.credentialOwner = snapshot?.credentialOwner
        account.readingStatus = store.readingStatus(for: choice)?.rawValue
        account.checking = store.isChecking(choice) ? true : nil
        account.automaticAssignment = store.isInAutomaticAssignment(choice)
        account.defaultSelected = isDefaultSelected ? true : nil
        return account
    }

    private func remoteHarnessRuntime(for descriptor: HarnessDescriptor, in model: AppModel) -> RemoteHarnessRuntime {
        let selections = model.runtimeSelections
        let selectedURL = selections.selectedURL(for: descriptor.id)
        let automaticURL = selections.automaticURL(for: descriptor.id)
        let isExplicit = selections.isChosen(descriptor.id)
        let installs = selections.discoveredInstalls(for: descriptor.id)

        var choices: [RemoteHarnessRuntime.Choice] = []
        if let autoURL = automaticURL {
            let autoTitle = Self.runtimeChoiceLabel(
                prefix: L10n.string("Automatic"),
                harness: descriptor.id,
                url: autoURL,
                selections: selections
            )
            choices.append(RemoteHarnessRuntime.Choice(
                id: Self.automaticRuntimeChoiceID,
                label: autoTitle,
                selected: !isExplicit && selectedURL == autoURL
            ))
        }
        for (index, installURL) in installs.enumerated() {
            let title = Self.runtimeChoiceLabel(
                prefix: nil,
                harness: descriptor.id,
                url: installURL,
                selections: selections
            )
            let isSelected = isExplicit && selectedURL == installURL
            choices.append(RemoteHarnessRuntime.Choice(
                id: "\(Self.runtimeChoiceInstallPrefix)\(index)",
                label: title,
                selected: isSelected
            ))
        }

        let label: String?
        if let selectedURL {
            label = Self.runtimeSummaryLabel(
                descriptor: descriptor,
                url: selectedURL,
                isAutomatic: !isExplicit,
                selections: selections
            )
        } else {
            label = nil
        }

        var versionNote: String?
        var versionVerified: Bool?
        if let selectedURL, let compatibility = HarnessRuntimeVersionNote.compatibility(for: descriptor.id) {
            if let cached = runtimeVersionNotes[selectedURL] {
                versionNote = cached.note
                versionVerified = cached.verified
            } else if let version = selections.cachedVersion(of: selectedURL),
                      let note = HarnessRuntimeVersionNote.note(versionOutput: version, compatibility: compatibility) {
                let entry = (note: note.text, verified: note.standing == .verified)
                runtimeVersionNotes[selectedURL] = entry
                versionNote = entry.note
                versionVerified = entry.verified
            } else {
                Task.detached(priority: .utility) { [weak self] in
                    guard let note = HarnessRuntimeVersionNote.read(executableURL: selectedURL, compatibility: compatibility) else {
                        return
                    }
                    await MainActor.run {
                        guard let self else { return }
                        self.runtimeVersionNotes[selectedURL] = (note: note.text, verified: note.standing == .verified)
                        self.hostAccountsMayHaveChanged()
                    }
                }
            }
        }

        return RemoteHarnessRuntime(
            harness: descriptor.id.rawValue,
            installed: selectedURL != nil,
            label: label,
            versionNote: versionNote,
            versionVerified: versionVerified,
            checkingDefault: model.connections.isCheckingDefault(descriptor.id) ? true : nil,
            choices: choices
        )
    }

    private static func runtimeSummaryLabel(
        descriptor: HarnessDescriptor,
        url: URL,
        isAutomatic: Bool,
        selections: RuntimeSelectionStore
    ) -> String {
        var parts = [url.lastPathComponent]
        let method = CLIInstallDetector.detect(harness: descriptor.id, executable: url)
        if method != .manual {
            parts.append(method.displayText)
        } else if isAutomatic {
            parts.append(L10n.string("Automatic"))
        } else {
            parts.append(L10n.string("Custom runtime"))
        }
        if let version = selections.cachedVersion(of: url), !version.isEmpty {
            parts.append(version)
        }
        return parts.joined(separator: " · ")
    }

    private static func runtimeChoiceLabel(
        prefix: String?,
        harness: HarnessKind,
        url: URL,
        selections: RuntimeSelectionStore
    ) -> String {
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        parts.append(url.lastPathComponent)
        let method = CLIInstallDetector.detect(harness: harness, executable: url)
        parts.append(method.displayText)
        if let version = selections.cachedVersion(of: url), !version.isEmpty {
            parts.append(version)
        }
        return parts.joined(separator: " · ")
    }

    static func remoteConnector(_ record: ConnectorRecord, in center: ConnectorCenter?) -> RemoteConnectorInfo {
        let activity: String? = switch center?.activity[record.id] {
        case .connecting?: "connecting"
        case .waitingForBrowser?: "waitingForBrowser"
        case nil: nil
        }
        let failure = center?.failures[record.id]
        let enabled = center?.isOn(record.id) ?? true
        let serverHost: String? = if record.preset == nil, record.localService == nil, record.program == nil {
            record.serverURL.host() ?? "remote"
        } else {
            nil
        }
        let accountOrHost: String? = if record.localService == .imapMail {
            [record.account, record.mailServer?.imapHost].compactMap { $0 }.joined(separator: " · ")
        } else {
            record.account
        }
        return RemoteConnectorInfo(
            id: record.id.uuidString,
            name: record.name,
            slug: record.slug,
            status: record.status.rawValue,
            authorization: record.authorization.rawValue,
            toolCount: record.offeredTools.count,
            presetId: record.presetID,
            localService: record.localService?.rawValue,
            account: accountOrHost,
            // A local program's command line and a failure's text can name host paths or secrets.
            programSummary: record.program.map { scheduleText($0.summary, root: nil) },
            serverHost: serverHost,
            usesRegisteredClient: record.usesRegisteredClient ? true : nil,
            activity: activity,
            failure: failure.map { scheduleText($0, root: nil) },
            enabled: enabled
        )
    }
}
