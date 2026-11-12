import Foundation
import YardletAgentTools

// The settings tools (`SettingsToolCatalog`, docs/AGENT_BROWSER_TOOLS.md, "Settings tools"): an agent reads
// Yardlet's settings and changes one when the person asks, from the catalog Settings draws its rows from
// (`YardletSettingCatalog`) and through the same objects and keys its controls change. Which change waits for
// the person is decided here: a setting that lowers a protection or reaches sign-ins, remote access, what agents
// may use or kept data asks on the task's approval card every time; any other asks only where the calling task
// asks, as the other session tools do.
extension AppModel {
    /// The settings as the app holds them: the objects and defaults Settings binds.
    var settingsContext: YardletSettingsContext {
        YardletSettingsContext(defaults: preferences, vault: settingsVault, remote: remoteControl, cliUpdates: cliUpdates,
                               instructions: yardletInstructions, evaluation: routingEvaluation, connections: connections,
                               hasConnectors: connectorCenter != nil, hasUsage: true, lidHelper: lidSleepHelper,
                               updateChecks: settingsUpdateChecks, launchAtLogin: launchAtLogin)
    }

    private struct SettingEntry: Encodable {
        var id: String
        var section: String
        var title: String
        var help: String?
        var kind: String
        var value: String
        var choices: [SettingChoice]?
        var asksThePerson: Bool
    }

    private struct SettingChoice: Encodable {
        var value: String
        var title: String
        var detail: String?
    }

    private struct SettingListing: Encodable {
        var settings: [SettingEntry]
        var note: String
    }

    /// `list_settings`: what Settings shows now, in its order, and whether changing each asks this caller's person.
    func listSettings(caller: SessionToolCaller) -> AgentToolResult {
        let context = settingsContext
        let asks = sessionToolAsksPerson(caller)
        let entries = YardletSettingCatalog.all.compactMap { setting -> SettingEntry? in
            guard let value = setting.value(in: context) else { return nil }
            let isSwitch = if case .onOff = setting.values { true } else { false }
            return SettingEntry(
                id: setting.id, section: setting.section.title, title: setting.title,
                help: setting.help.isEmpty ? nil : setting.help, kind: isSwitch ? "switch" : "choice", value: value,
                choices: isSwitch ? nil : setting.choices.map { SettingChoice(value: $0.value, title: $0.title, detail: $0.detail) },
                asksThePerson: setting.asksEveryTime || asks)
        }
        return .text(SessionToolText.json(SettingListing(
            settings: entries,
            note: "The settings Settings shows now; one that shows only while another is on is listed while it is. A "
                + "switch's value is on or off, a choice's one of its choices' values. asksThePerson: update_setting "
                + "waits for the person's approval card.")))
    }

    /// `update_setting`: one setting to one of its values, after the person's card where it asks.
    func updateSetting(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        let name = arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let setting = Self.setting(named: name) else {
            return .failure("Not changed: Yardlet has no setting \(name.isEmpty ? "without an id" : "with the id \(name)"); "
                + "list_settings lists them.", .notFound, retry: .withChanges)
        }
        guard let current = setting.value(in: settingsContext) else {
            let parent = setting.shownWhileOn.flatMap(YardletSettingCatalog.setting)
            let why = parent.map { " while “\($0.title)” is off" } ?? " in this copy of Yardlet now"
            return .failure("Not changed: Settings does not show “\(setting.title)”\(why).", .refused, retry: .no)
        }
        guard let value = Self.settingValue(arguments["value"], of: setting) else {
            let allowed = setting.choices.map(\.value).joined(separator: ", ")
            return .failure("Not changed: “\(setting.title)” takes \(allowed).", .invalidArguments, retry: .withChanges,
                            details: ["values": .array(setting.choices.map { .string($0.value) })])
        }
        guard value != current else {
            return .text("“\(setting.title)” is already \(setting.title(of: value)); nothing changed.")
        }
        if setting.asksEveryTime || sessionToolAsksPerson(caller) {
            let allowed = await askPerson(title: Self.settingCardTitle(setting),
                                          detail: Self.settingCardDetail(setting, from: current, to: value), caller: caller)
            guard allowed else {
                return .failure("Not changed: the person did not allow changing “\(setting.title)”.", .refused, retry: .no)
            }
        }
        // Read again: the value may have moved while the card waited.
        let before = setting.value(in: settingsContext) ?? current
        guard before != value else {
            return .text("“\(setting.title)” is already \(setting.title(of: value)); nothing changed.")
        }
        if let refusal = await setting.set(value, in: settingsContext) {
            return .failure("Not changed: \(refusal)", .refused, retry: .no)
        }
        let after = setting.value(in: settingsContext)
        guard after == value else {
            // Turning off "Hide keys and tokens" also asks Touch ID or the login password, which can be declined.
            return .failure("Not changed: “\(setting.title)” is still \(after.map(setting.title(of:)) ?? "off").",
                            .refused, retry: .no)
        }
        let line = SettingsToolCatalog.changedLine(title: setting.title, from: setting.title(of: before),
                                                   to: setting.title(of: value), id: setting.id)
        return .text(setting.help.isEmpty ? line : line + "\n" + setting.help)
    }

    static func settingCardTitle(_ setting: YardletSetting) -> String {
        L10n.format("Change “%@”?", setting.title)
    }

    /// A card's lines: where the setting is in Settings, the change, and the setting's help.
    static func settingCardDetail(_ setting: YardletSetting, from current: String, to value: String) -> String {
        [L10n.format("%@ › %@", L10n.string("Settings"), setting.section.title),
         L10n.format("%@ → %@", setting.title(of: current), setting.title(of: value)),
         setting.help].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A setting by its id, or by its title as Settings shows it.
    private static func setting(named name: String) -> YardletSetting? {
        let id = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return YardletSettingCatalog.setting(id)
            ?? YardletSettingCatalog.all.first { $0.title.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    /// The value asked for as one of the setting's: its value or its words in either case, and for a switch
    /// true or false too.
    private static func settingValue(_ value: JSONValue?, of setting: YardletSetting) -> String? {
        let text: String
        switch value {
        case let .bool(isOn)?: text = isOn ? YardletSetting.on : YardletSetting.off
        case let .string(string)?: text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return nil
        }
        if case .onOff = setting.values {
            switch text.lowercased() {
            case "true": return YardletSetting.on
            case "false": return YardletSetting.off
            default: break
            }
        }
        return setting.choices.first { choice in
            [choice.value, choice.title].contains { $0.compare(text, options: [.caseInsensitive]) == .orderedSame }
        }?.value
    }
}
