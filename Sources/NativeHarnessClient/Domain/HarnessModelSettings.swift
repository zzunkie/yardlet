import Foundation

/// A model a harness runtime advertised, with the reasoning-effort levels it takes. Yardlet keeps
/// the last list per account so a composer can name and offer models before its task connects;
/// the runtime still decides what is valid when the task starts.
struct HarnessModelOption: Codable, Equatable, Sendable, Identifiable {
    let value: String
    let name: String
    var description: String?
    /// The levels the model takes, as the runtime spells them. Empty: the model takes none.
    var effortLevels: [String] = []
    /// The full model ID the runtime resolves `value` to, when it says (Claude Code's
    /// `resolvedModel`: `opus` → `claude-opus-5-5`), so a full ID a task keeps names its alias row.
    var resolvedModel: String? = nil

    var id: String { value }
}

/// What a harness uses when a task chooses nothing itself, read from the account's own settings
/// files. A nil field is left to the runtime's built-in default.
struct HarnessModelDefaults: Equatable, Sendable {
    var model: String?
    var effort: String?
    var serviceTier: String?
    /// What Codex's `config.toml` changes in its permission menu.
    var codexPermissions = CodexPermissionConfig()
}

/// Reads the model settings a harness keeps in its own files. Only those files are read: no CLI
/// starts, nothing is written, and no credential is touched.
enum HarnessModelDefaultsReader {
    /// Claude Code's `model` and `effortLevel`, layered the way the CLI layers its settings: the
    /// account's user settings, then the project's shared and local settings. `ANTHROPIC_MODEL`
    /// takes precedence over every settings file, as it does for the CLI.
    static func claude(
        configDirectory: URL,
        workspaceURL: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HarnessModelDefaults {
        var files = [configDirectory.appending(path: "settings.json")]
        if let workspaceURL {
            files.append(workspaceURL.appending(path: ".claude/settings.json"))
            files.append(workspaceURL.appending(path: ".claude/settings.local.json"))
        }
        var defaults = HarnessModelDefaults()
        for file in files {
            guard let settings = readJSON(file) else { continue }
            if let model = nonEmpty(settings["model"]?.stringValue) { defaults.model = model }
            if let effort = nonEmpty(settings["effortLevel"]?.stringValue) { defaults.effort = effort }
        }
        if let model = nonEmpty(environment["ANTHROPIC_MODEL"]) { defaults.model = model }
        return defaults
    }

    /// Codex's `model`, `model_reasoning_effort` and `service_tier` from `config.toml`'s top
    /// level, with the profile it selects laid over them, and what the file changes in the
    /// permission menu.
    static func codex(home: URL) -> HarnessModelDefaults {
        let file = home.appending(path: "config.toml")
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1_048_576,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return HarnessModelDefaults() }
        let tables = TOMLStringTables.parse(text)
        let top = tables[""] ?? [:]
        var defaults = HarnessModelDefaults(model: nonEmpty(top["model"]), effort: nonEmpty(top["model_reasoning_effort"]),
                                            serviceTier: nonEmpty(top["service_tier"]))
        if let profile = nonEmpty(top["profile"]), let table = tables["profiles.\(profile)"] {
            if let model = nonEmpty(table["model"]) { defaults.model = model }
            if let effort = nonEmpty(table["model_reasoning_effort"]) { defaults.effort = effort }
            if let tier = nonEmpty(table["service_tier"]) { defaults.serviceTier = tier }
        }
        defaults.codexPermissions = CodexPermissionConfig(tables: tables)
        return defaults
    }

    private static func readJSON(_ url: URL) -> JSONValue? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The values of a TOML file, by table, as text. Only what the model and permission defaults need is
/// understood: `[table]` headers (dotted, with quoted parts), `key = "string"` or `key = 'string'`
/// lines, and any other value as written up to a comment (`true`, `{ granular = … }`). Anything else
/// is skipped rather than guessed.
enum TOMLStringTables {
    static func parse(_ text: String) -> [String: [String: String]] {
        var tables: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                // `[[array]]` tables hold no model defaults; their keys must not land on the last table.
                guard !line.hasPrefix("[["), let end = line.lastIndex(of: "]") else { current = "\u{0}"; continue }
                current = String(line[line.index(after: line.startIndex)..<end])
                    .split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .joined(separator: ".")
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let quote = rest.first, quote == "\"" || quote == "'" else {
                let value = rest.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { tables[current, default: [:]][key] = value }
                continue
            }
            let body = rest.dropFirst()
            guard let close = body.firstIndex(of: quote) else { continue }
            tables[current, default: [:]][key] = String(body[..<close])
        }
        return tables
    }
}

/// The model and effort a Claude task shows before Claude Code reports its own: the task's own
/// choice, else the account's settings, else Claude Code's default. Names and effort levels come
/// from the list Claude Code last advertised, so a model shows as Claude Code names it.
enum ClaudeComposerModelProjection {
    static let defaultModel = "default"

    static func selectors(
        model chosenModel: String?,
        effort chosenEffort: String?,
        defaults: HarnessModelDefaults?,
        catalog: [HarnessModelOption]
    ) -> [ProviderCapabilitySelector] {
        let configured = chosenModel ?? defaults?.model ?? defaultModel
        let listed = option(for: configured, in: catalog)
        let model = listed?.value ?? configured
        var choices = catalog.map { ProviderCapabilityChoice(value: $0.value, name: $0.name, description: $0.description) }
        if listed == nil {
            choices.insert(.init(value: model, name: displayName(model), description: nil), at: 0)
        }
        var selectors = [ProviderCapabilitySelector(
            id: "model", name: L10n.string("Model"), description: nil, category: "model",
            currentValue: model, choices: choices
        )]
        let effort = chosenEffort ?? defaults?.effort
        if let option = listed {
            guard !option.effortLevels.isEmpty else { return selectors }
            var levels = [ProviderCapabilityChoice(value: "default", name: L10n.string("Default"), description: nil)]
                + option.effortLevels.map { .init(value: $0, name: CodexReasoningLabel.name($0), description: nil) }
            let current = effort ?? "default"
            if !levels.contains(where: { $0.value == current }) {
                levels.append(.init(value: current, name: CodexReasoningLabel.name(current), description: nil))
            }
            selectors.append(effortSelector(current: current, choices: levels))
        } else if let effort, effort != "default" {
            // Nothing says which levels this model takes, so only the known value is shown.
            selectors.append(effortSelector(current: effort,
                choices: [.init(value: effort, name: CodexReasoningLabel.name(effort), description: nil)]))
        }
        return selectors
    }

    /// Whether a value can be chosen for a task before it connects: one the advertised list has,
    /// and for effort, a level that model takes or its default.
    static func accepts(id: String, value: String, model: String, catalog: [HarnessModelOption]) -> Bool {
        switch id {
        case "model": return catalog.contains { $0.value == value }
        case "effort":
            guard let option = option(for: model, in: catalog) else { return false }
            return value == "default" ? !option.effortLevels.isEmpty : option.effortLevels.contains(value)
        default: return false
        }
    }

    /// The model and effort after choosing `value` for `id` from the advertised list, or nil when
    /// the list does not offer it. An effort kept so far that the new model does not take goes
    /// back to that model's default.
    static func choosing(_ id: String, value: String, model: String, effort: String?,
                         catalog: [HarnessModelOption]) -> (model: String, effort: String?)? {
        guard accepts(id: id, value: value, model: model, catalog: catalog) else { return nil }
        if id == "effort" { return (model, value) }
        guard let effort, effort != "default",
              !accepts(id: "effort", value: effort, model: value, catalog: catalog) else { return (value, effort) }
        return (value, "default")
    }

    /// The listed model a value names. Claude Code lists the model an account is configured with
    /// under the name it was launched with: the alias (`fable`) in a new session, the full ID
    /// (`claude-fable-5-1`) once a session resumes. A full ID the list carries under its alias
    /// (`claude-opus-5-5` under `opus`) is that alias's row, as the row's `resolvedModel` says. The
    /// Default row is never one: it follows the account's default, which a full ID does not. An
    /// alias the list does not carry is the first model of that family the list names, the one the
    /// CLI resolves the alias to.
    static func option(for model: String, in catalog: [HarnessModelOption]) -> HarnessModelOption? {
        if let exact = catalog.first(where: { $0.value == model }) { return exact }
        if let aliasRow = catalog.first(where: { $0.value != defaultModel && $0.resolvedModel == model }) {
            return aliasRow
        }
        guard !model.isEmpty, !model.contains("-") else { return nil }
        return catalog.first { $0.value.hasPrefix("claude-\(model)-") }
    }

    /// A readable name for a model Claude Code has not listed: its alias capitalized, or a full
    /// ID such as `claude-opus-5-5` as "Opus 5.5".
    static func displayName(_ model: String) -> String {
        if model == defaultModel { return L10n.string("Default") }
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first, !family.isEmpty else { return model }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : name + " " + version.joined(separator: ".")
    }

    private static func effortSelector(current: String, choices: [ProviderCapabilityChoice]) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(id: "effort", name: L10n.string("Reasoning effort"), description: nil,
                                   category: "thought_level", currentValue: current, choices: choices)
    }
}

/// The Codex model catalog a composer shows: the live one, with what Yardlet already knows filled
/// in before the App Server reports — the models it last listed for this account, and the task's
/// own choice, else `config.toml`'s, else the catalog's default model.
enum CodexComposerModelProjection {
    static func catalog(
        live: CodexModelCatalog,
        stored: CodexModelSelection?,
        defaults: HarnessModelDefaults?,
        cached: [CodexModelOption]
    ) -> CodexModelCatalog {
        var catalog = live
        if catalog.models.isEmpty { catalog.models = cached }
        guard catalog.selection == nil else { return catalog }
        if let stored {
            catalog.selection = stored
        } else if let model = defaults?.model ?? catalog.models.first(where: \.isDefault)?.model {
            catalog.selection = CodexModelSelection(model: model, reasoningEffort: defaults?.effort,
                                                    serviceTier: defaults?.serviceTier)
        }
        return catalog
    }
}
