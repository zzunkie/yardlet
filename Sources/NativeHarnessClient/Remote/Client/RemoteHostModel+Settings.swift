import Foundation
import YardletRemote

extension RemoteHostModel {
    /// Opens the host's Settings sheet in this remote window, optionally on `section`.
    func openSettings(section: String? = nil) {
        guard offersHostSettings else { return }
        requestedSettingsSection = section
        showsSettings = true
        Task { await readHostSettings(watching: true) }
    }

    /// Closes the host's Settings sheet and stops following host settings changes.
    func closeSettings() {
        instructionsSaveTask?.cancel()
        instructionsSaveTask = nil
        showsSettings = false
        requestedSettingsSection = nil
        if offersHostSettings, isConnected {
            requestInOrder(.hostSettings(watching: false))
        }
    }

    /// Reads the host's Settings values and watches for changes while the sheet is open.
    func readHostSettings(watching: Bool = true) async {
        guard offersHostSettings, isConnected else { return }
        guard !readingHostSettings else {
            dirtyHostSettings = true
            return
        }
        readingHostSettings = true
        defer { readingHostSettings = false }
        repeat {
            dirtyHostSettings = false
            let answer: RemoteResponse = await withCheckedContinuation { continuation in
                requestInOrder(.hostSettings(watching: watching)) { continuation.resume(returning: $0) }
            }
            guard offersHostSettings else { return }
            if answer.ok, let page = answer.settingsPage, hostSettings != page {
                hostSettings = page
            } else if !answer.ok {
                commandError = Self.message(for: answer.error, host: name)
            }
        } while dirtyHostSettings && isConnected
    }

    @discardableResult
    func setHostSetting(_ id: String, value: String, confirmed: Bool = false) async -> Bool {
        let answer: RemoteResponse = await withCheckedContinuation { continuation in
            requestInOrder(.setHostSetting(setting: id, value: value, confirmed: confirmed)) {
                continuation.resume(returning: $0)
            }
        }
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name)
        return false
    }

    @discardableResult
    func saveHostInstructions(_ text: String) async -> Bool {
        let answer: RemoteResponse = await withCheckedContinuation { continuation in
            requestInOrder(.saveHostInstructions(text: text)) {
                continuation.resume(returning: $0)
            }
        }
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name)
        return false
    }

    func scheduleHostInstructionsSave(_ text: String) {
        hostSettings?.instructions?.text = text
        instructionsSaveTask?.cancel()
        instructionsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            _ = await self.saveHostInstructions(text)
        }
    }

    @discardableResult
    func performHostCLIUpdate(action: String, harness: String? = nil) async -> Bool {
        let answer: RemoteResponse = await withCheckedContinuation { continuation in
            requestInOrder(.hostCLIUpdate(action: action, harness: harness)) {
                continuation.resume(returning: $0)
            }
        }
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name)
        return false
    }

    func hostSettingValue(_ setting: YardletSetting) -> String {
        if let value = hostSettings?.values[setting.id] {
            return value
        }
        switch setting.storage {
        case let .flag(_, defaultValue):
            return defaultValue ? YardletSetting.on : YardletSetting.off
        case let .choice(_, defaultValue):
            return defaultValue
        case .app:
            return YardletSetting.off
        }
    }
}

@MainActor
enum RemoteHostSettingsProjection {
    struct Confirmation: Identifiable, Equatable {
        let settingID: String
        let title: String
        let message: String
        let value: String
        var id: String { settingID + ":" + value }
    }

    /// With `hostAccounts` (§15.37) the host's Accounts, Harnesses and Connectors sections show too.
    static func availableSections(_ settings: RemoteHostSettings?, offersAccounts: Bool = false) -> [SettingsSection] {
        SettingsSection.available(
            hasAccounts: offersAccounts,
            hasConnectors: offersAccounts,
            hasVault: false,
            hasRemote: false,
            hasCLIUpdates: settings?.cliUpdates != nil,
            hasInstructions: settings?.instructions != nil,
            hasUsage: settings?.usage != nil
        ).filter { $0 != .appearance && $0 != .notifications }
    }

    static func generalRows(_ settings: RemoteHostSettings?) -> [YardletSetting] {
        YardletSettingCatalog.all.filter { setting in
            setting.section == .general
                && setting.shownWhileOn.flatMap(YardletSettingCatalog.setting)?.section != .general
                && settings?.values[setting.id] != nil
        }
    }

    static func usageRows(_ settings: RemoteHostSettings?) -> [YardletSetting] {
        YardletSettingCatalog.all.filter { setting in
            setting.section == .usage && settings?.values[setting.id] != nil
        }
    }

    static func confirmation(for setting: YardletSetting, from current: String, to value: String) -> Confirmation? {
        guard setting.asksEveryTime, current != value else { return nil }
        return Confirmation(
            settingID: setting.id,
            title: AppModel.settingCardTitle(setting),
            message: AppModel.settingCardDetail(setting, from: current, to: value),
            value: value
        )
    }

    static func permissionNote(hostName: String) -> String {
        L10n.format("To change settings here, allow it in %@'s Settings › Remote › Paired devices.", hostName)
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    nonisolated static func tokenUsageOverview(_ usage: RemoteHostSettings.Usage?) -> TokenUsageOverview {
        guard let usage else {
            return TokenUsageOverview(days: [], limits: [], updatedAt: Date())
        }
        let days = usage.days.map {
            TokenUsageDay(start: Date(timeIntervalSince1970: Double($0.start) / 1000), amount: decodeAmount($0.amount))
        }
        let limits = usage.limits.map { line -> TokenUsageLimitLine in
            let harness = HarnessKind(rawValue: line.harness)
            let windows = line.windows.map { window in
                AccountUsageMetric(
                    id: window.id,
                    label: window.label,
                    usedFraction: window.usedFraction,
                    detail: window.detail,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    evidence: UsageEvidenceKind(rawValue: window.evidence) ?? .notExposed,
                    windowMinutes: window.windowMinutes,
                    model: window.model
                )
            }
            let runsOutAt = line.runsOutAt.mapValues { Date(timeIntervalSince1970: Double($0) / 1000) }
            return TokenUsageLimitLine(
                id: line.id,
                account: line.account,
                address: line.address,
                harness: harness,
                windows: windows,
                runsOutAt: runsOutAt
            )
        }
        let rowsByRangeAndGroup = usage.rows
        return TokenUsageOverview(
            days: days,
            limits: limits,
            updatedAt: Date(timeIntervalSince1970: Double(usage.updatedAt) / 1000),
            rows: { range, grouping in
                (rowsByRangeAndGroup[range.rawValue]?[grouping.rawValue] ?? []).map { row in
                    TokenUsageRow(
                        id: row.id,
                        title: row.title,
                        detail: row.detail,
                        harness: row.harness.map(HarnessKind.init(rawValue:)),
                        amount: decodeAmount(row.amount)
                    )
                }
            }
        )
    }

    nonisolated private static func decodeAmount(_ amount: RemoteHostSettings.Usage.Amount) -> TokenUsageAmount {
        var kindCost: [TokenUsageKind: Double] = [:]
        for (raw, cost) in amount.kindCost {
            let kind: TokenUsageKind? = switch raw {
            case "cacheRead": .cacheRead
            case "freshInput": .freshInput
            case "cacheWrite": .cacheWrite
            case "output": .output
            default: nil
            }
            if let kind { kindCost[kind] = cost }
        }
        return TokenUsageAmount(
            freshInput: amount.freshInput,
            cacheWrite: amount.cacheWrite,
            cacheRead: amount.cacheRead,
            output: amount.output,
            requests: amount.requests,
            kindCost: kindCost
        )
    }
}
