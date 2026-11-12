import Foundation
import Observation
import YardletRemote

extension AppModelRemoteBridge {
    typealias HostUsageRows = [String: [String: [RemoteHostSettings.Usage.Row]]]

    /// Settings that configure the client Mac itself or belong to sections not shown in the remote Settings sheet.
    private static let excludedRemoteSettingIDs: Set<String> = [
        YardletSetting.language.id,
        YardletSetting.checkForUpdates.id,
        YardletSetting.launchAtLogin.id,
        YardletSetting.sendShortcut.id
    ]

    static func isRemoteHostSetting(_ setting: YardletSetting) -> Bool {
        switch setting.section {
        case .general, .instructions, .usage, .cliUpdates:
            !excludedRemoteSettingIDs.contains(setting.id)
        case .yardletAccount, .appearance, .notifications, .accounts, .harnesses, .connectors, .vault, .remote:
            false
        }
    }

    func hostSettings() async -> Result<RemoteHostSettings, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        if model.cliUpdates != nil {
            let runtimes = model.runtimeSelections
            Task { await runtimes.findNewest() }
        }
        let page = buildHostSettings(in: model)
        answeredHostSettings = page
        if watchesHostSettings { startTrackingHostSettings() }
        return .success(page)
    }

    func setWatchesHostSettings(_ watching: Bool) async {
        guard watching != watchesHostSettings else { return }
        watchesHostSettings = watching
        if watching {
            installHostSettingsNotificationObservers()
            startTrackingHostSettings()
        } else {
            removeHostSettingsNotificationObservers()
            answeredHostSettings = nil
            builtHostUsageRows = nil
        }
    }

    func setHostSetting(setting: String, value: String, confirmed: Bool) async -> Result<RemoteHostSettings, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        guard let entry = YardletSettingCatalog.setting(setting), Self.isRemoteHostSetting(entry) else {
            return .failure(RemoteError(.notAllowed, "That setting cannot be changed remotely."))
        }
        let context = model.settingsContext
        guard entry.isShown(in: context) else {
            return .failure(RemoteError(.notAllowed, "That setting is not offered on this Mac."))
        }
        guard entry.choices.contains(where: { $0.value == value }) else {
            return .failure(RemoteError(.badRequest, "Invalid setting value"))
        }
        if entry.asksEveryTime, !confirmed {
            return .failure(RemoteError(.notAllowed, "Confirm this change first"))
        }
        if entry.id == YardletSetting.hideKeysAndTokens.id {
            if value == YardletSetting.off {
                return .failure(RemoteError(.notAllowed, L10n.string("Turn off “Hide keys and tokens” on the Mac itself.")))
            }
            guard context.vault?.isAllowedBuild == true else {
                return .failure(RemoteError(.notAllowed, L10n.string("Always on in a build that is not team-signed.")))
            }
        }
        if entry.id == YardletSetting.keepWorkingWithLidClosed.id, value == YardletSetting.on {
            guard let helper = context.lidHelper else {
                return .failure(RemoteError(.notAllowed, L10n.string("Not available in this copy of Yardlet")))
            }
            switch helper.status {
            case .unavailable:
                return .failure(RemoteError(.notAllowed, L10n.string("Not available in this copy of Yardlet")))
            case .off, .needsApproval:
                return .failure(RemoteError(.notAllowed, L10n.string("Allow Yardlet in the background in System Settings on the Mac itself.")))
            case .ready:
                break
            }
        }
        if let refusal = await entry.set(value, in: context) {
            return .failure(RemoteError(.notAllowed, refusal))
        }
        if entry.id == YardletSetting.tokenUsage.id {
            model.followTokenUsage(defaults: model.preferences)
        }
        let page = buildHostSettings(in: model)
        publishHostSettingsIfChanged(page)
        return .success(page)
    }

    func saveHostInstructions(text: String) async -> Result<RemoteHostSettings, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        guard text.utf8.count <= 65_536 else {
            return .failure(RemoteError(.tooLarge, "Instructions are too large."))
        }
        guard let store = model.yardletInstructions else {
            return .failure(RemoteError(.unavailable, "Yardlet instructions are not available on this Mac."))
        }
        store.text = text
        let page = buildHostSettings(in: model)
        publishHostSettingsIfChanged(page)
        return .success(page)
    }

    func hostCLIUpdate(action: String, harness: String?) async -> Result<RemoteHostSettings, RemoteError> {
        guard let model, let center = model.cliUpdates else {
            return .failure(RemoteError(.unavailable, "CLI updates are not available on this Mac."))
        }
        switch action {
        case "check":
            guard let raw = harness, !raw.isEmpty else {
                return .failure(RemoteError(.badRequest, "Unknown harness"))
            }
            let kind = HarnessKind(rawValue: raw)
            guard center.rows.contains(where: { $0.harness == kind }) else {
                return .failure(RemoteError(.badRequest, "Unknown harness"))
            }
            await center.check(kind)
        case "checkAll":
            await center.checkAll()
        case "useNewest":
            guard let raw = harness, !raw.isEmpty else {
                return .failure(RemoteError(.badRequest, "No newer install for harness"))
            }
            let kind = HarnessKind(rawValue: raw)
            guard model.runtimeSelections.newerInstalls[kind] != nil else {
                return .failure(RemoteError(.badRequest, "No newer install for harness"))
            }
            model.runtimeSelections.useNewest(for: kind)
            await center.check(kind)
        case "dismissNotice":
            center.dismissNotice()
        default:
            return .failure(RemoteError(.badRequest, "Invalid CLI update action"))
        }
        let page = buildHostSettings(in: model)
        publishHostSettingsIfChanged(page)
        return .success(page)
    }

    // MARK: - Projection

    func buildHostSettings(in model: AppModel) -> RemoteHostSettings {
        let context = model.settingsContext
        var values: [String: String] = [:]
        for setting in YardletSettingCatalog.all where Self.isRemoteHostSetting(setting) {
            if let value = setting.value(in: context) {
                values[setting.id] = value
            }
        }
        if values[YardletSetting.memorySaverLevel.id] == nil {
            let stored = context.defaults.string(forKey: MemorySaverPreference.levelKey)
            let valid = stored.flatMap { candidate in
                YardletSetting.memorySaverLevel.choices.contains { $0.value == candidate } ? candidate : nil
            }
            values[YardletSetting.memorySaverLevel.id] = valid ?? BrowserMemorySaver.Level.balanced.rawValue
        }

        let lidStatus: String? = context.lidHelper.map { helper in
            switch helper.status {
            case .unavailable: "unavailable"
            case .off: "off"
            case .needsApproval: "needsApproval"
            case .ready: "ready"
            }
        }

        let instructions = context.instructions.map { store in
            RemoteHostSettings.Instructions(
                text: store.text,
                hasEvaluation: context.evaluation != nil,
                lastEvaluationAt: context.evaluation?.state.lastRunAt.map(RemoteJSON.milliseconds)
            )
        }

        let cliUpdates = context.cliUpdates.map { center in
            let runtimes = model.runtimeSelections
            let rows = center.rows.map { row in
                let text = CLIUpdateRowPresentation(row: row, held: center.heldVersion(for: row.harness))
                let working = row.phase != .idle && row.phase != .waitingForTasks
                let newer = runtimes.newerInstalls[row.harness]
                return RemoteHostSettings.CLIUpdates.Row(
                    harness: row.harness.rawValue,
                    title: row.harness.displayName,
                    method: text.method,
                    versions: text.versions,
                    status: text.status,
                    isWarning: text.isWarning,
                    working: working,
                    newerVersion: newer?.version,
                    newerText: newer.map { CLIUpdateRowPresentation.newerInstallText($0, harness: row.harness) }
                )
            }
            return RemoteHostSettings.CLIUpdates(
                rows: rows,
                isChecking: rows.contains { $0.working },
                lastCheckedAt: center.lastCheckAll.map(RemoteJSON.milliseconds),
                notice: center.notice.map { RemoteHostSettings.CLIUpdates.Notice(text: $0.message, isWarning: true) }
            )
        }

        let usage: RemoteHostSettings.Usage? = (!model.usesVisualFixture && context.hasUsage) ? buildUsage(in: model) : nil

        return RemoteHostSettings(
            writable: false,
            values: values,
            credentialHidingAllowedBuild: context.vault?.isAllowedBuild,
            lidHelperStatus: lidStatus,
            instructions: instructions,
            cliUpdates: cliUpdates,
            usage: usage
        )
    }

    private func buildUsage(in model: AppModel) -> RemoteHostSettings.Usage {
        let overview = model.tokenUsageOverview()
        let days = overview.days.map {
            RemoteHostSettings.Usage.Day(
                start: RemoteJSON.milliseconds($0.start),
                amount: Self.encodeAmount($0.amount)
            )
        }
        let limits = overview.limits.map { line in
            RemoteHostSettings.Usage.LimitLine(
                id: line.id,
                account: line.account,
                address: line.address,
                harness: line.harness.rawValue,
                windows: line.windows.map { window in
                    RemoteHostSettings.Usage.LimitWindow(
                        id: window.id,
                        label: window.label,
                        usedFraction: window.usedFraction,
                        detail: window.detail,
                        resetsAt: window.resetsAt.map(RemoteJSON.milliseconds),
                        evidence: window.evidence.rawValue,
                        windowMinutes: window.windowMinutes,
                        model: window.model
                    )
                },
                runsOutAt: line.runsOutAt.mapValues(RemoteJSON.milliseconds)
            )
        }
        let limitsCheckedAt = MenuBarMenuProjection.limitAccounts(
            choices: model.connections.menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id))
        ).compactMap(\.checkedAt).max()
        return RemoteHostSettings.Usage(
            isCounting: model.tokenUsage.isEnabled,
            limitsCheckedAt: limitsCheckedAt.map(RemoteJSON.milliseconds),
            updatedAt: RemoteJSON.milliseconds(overview.updatedAt),
            days: days,
            limits: limits,
            rows: usageRows(of: overview, in: model)
        )
    }

    /// Every range grouped every way, which reads every counted session, while the page is built for any
    /// change of a setting or the vault: the rows stand until what they read changes.
    private func usageRows(of overview: TokenUsageOverview, in model: AppModel) -> HostUsageRows {
        let inputs = model.tokenUsageRowsInputs()
        if let built = builtHostUsageRows, built.inputs == inputs { return built.rows }
        var rows: HostUsageRows = [:]
        for range in TokenUsageRange.allCases {
            var byGrouping: [String: [RemoteHostSettings.Usage.Row]] = [:]
            for grouping in TokenUsageGrouping.allCases {
                byGrouping[grouping.rawValue] = overview.rows(range, grouping).map { row in
                    RemoteHostSettings.Usage.Row(
                        id: row.id,
                        title: row.title,
                        detail: row.detail,
                        harness: row.harness?.rawValue,
                        amount: Self.encodeAmount(row.amount)
                    )
                }
            }
            rows[range.rawValue] = byGrouping
        }
        builtHostUsageRows = (inputs, rows)
        hostUsageRowBuilds += 1
        return rows
    }

    private static func encodeAmount(_ amount: TokenUsageAmount) -> RemoteHostSettings.Usage.Amount {
        var kindCost: [String: Double] = [:]
        for (kind, cost) in amount.kindCost {
            let key: String = switch kind {
            case .cacheRead: "cacheRead"
            case .freshInput: "freshInput"
            case .cacheWrite: "cacheWrite"
            case .output: "output"
            }
            kindCost[key] = cost
        }
        return RemoteHostSettings.Usage.Amount(
            freshInput: amount.freshInput,
            cacheWrite: amount.cacheWrite,
            cacheRead: amount.cacheRead,
            output: amount.output,
            requests: amount.requests,
            kindCost: kindCost
        )
    }

    // MARK: - Watching

    private func installHostSettingsNotificationObservers() {
        removeHostSettingsNotificationObservers()
        guard let model else { return }
        let center = NotificationCenter.default
        hostSettingsObservers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: model.preferences, queue: nil) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.hostSettingsMayHaveChanged() }
            },
            center.addObserver(forName: VaultCenter.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.hostSettingsMayHaveChanged() }
            }
        ]
    }

    private func removeHostSettingsNotificationObservers() {
        let center = NotificationCenter.default
        for observer in hostSettingsObservers {
            center.removeObserver(observer)
        }
        hostSettingsObservers.removeAll()
    }

    private func startTrackingHostSettings() {
        guard watchesHostSettings, !trackingHostSettings, let model else { return }
        trackingHostSettings = true
        withObservationTracking {
            _ = model.yardletInstructions?.isEnabled
            _ = model.yardletInstructions?.text
            _ = model.routingEvaluation?.isEnabled
            _ = model.routingEvaluation?.state
            _ = model.cliUpdates?.isAutoUpdateEnabled
            _ = model.cliUpdates?.rows
            _ = model.cliUpdates?.lastCheckAll
            _ = model.cliUpdates?.notice
            _ = model.runtimeSelections.newerInstalls
            _ = model.lidSleepHelper?.status
            _ = model.tokenUsage.isEnabled
            _ = model.tokenUsage.summary
            _ = model.connections.connections
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trackingHostSettings = false
                self.hostSettingsMayHaveChanged()
                self.startTrackingHostSettings()
            }
        }
    }

    private func hostSettingsMayHaveChanged() {
        guard watchesHostSettings, let model else { return }
        let page = buildHostSettings(in: model)
        publishHostSettingsIfChanged(page)
    }

    private func publishHostSettingsIfChanged(_ page: RemoteHostSettings) {
        guard page != answeredHostSettings else { return }
        answeredHostSettings = page
        changeHandler?(.hostSettings)
    }
}
