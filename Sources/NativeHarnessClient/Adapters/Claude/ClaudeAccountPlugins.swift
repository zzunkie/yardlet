import Foundation

/// Claude Code's own plugin commands, run for one account (docs/PROVIDER_CONNECTIONS.md, "Skill and
/// plugin switches"). `claude plugin list --json` lists what the account installed, on or off, and
/// `claude plugin enable|disable --scope user` turns one on or off in the account's user settings
/// (`enabledPlugins` in its config folder's `settings.json`), the scope the Claude app's Manage
/// plugins changes. A plugin installed for a project (`project`, `local`) belongs to that
/// repository's `.claude/` files and is not listed.
///
/// A running session keeps the plugins it loaded until it reloads them, so a change reaches the
/// tasks that start after it.
enum ClaudeAccountPlugins {
    static let listArguments = ["plugin", "list", "--json"]

    static func switchArguments(id: String, enabled: Bool) -> [String] {
        ["plugin", enabled ? "enable" : "disable", "--scope", "user", "--json", "--", id]
    }

    private struct Listed: Decodable {
        let id: String
        let scope: String?
        let enabled: Bool?
        let installPath: String?
    }

    /// The account's own installs in `plugin list --json`'s answer, one per plugin, by name. The
    /// CLI's warnings share the output, so the array is read from its own lines.
    static func plugins(
        fromListOutput output: String,
        description: (_ installPath: String) -> String? = manifestDescription
    ) throws -> [HarnessAccountPlugin] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("[") }),
              let end = lines[start...].lastIndex(where: { $0.hasPrefix("]") }) ?? (lines[start].hasSuffix("]") ? start : nil),
              let listed = try? JSONDecoder().decode([Listed].self, from: Data(lines[start...end].joined(separator: "\n").utf8))
        else {
            throw HarnessAdapterError.invalidProviderEvent(L10n.string("Claude Code listed its plugins in a form Yardlet does not read"))
        }
        var seen = Set<String>()
        return listed
            .filter { $0.scope == "user" && seen.insert($0.id).inserted }
            .map { plugin in
                let parts = plugin.id.split(separator: "@", maxSplits: 1)
                return HarnessAccountPlugin(
                    id: plugin.id,
                    name: parts.first.map(String.init) ?? plugin.id,
                    marketplace: parts.count > 1 ? String(parts[1]) : nil,
                    description: plugin.installPath.flatMap(description),
                    isEnabled: plugin.enabled ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct SwitchResult: Decodable {
        let outcome: String?
        let message: String?
        let alreadyInGoalState: Bool?
    }

    /// Whether `plugin enable|disable --json` left the plugin as asked: its result line says `ok`,
    /// or that it already was. Otherwise the CLI's own message is the error. A CLI that prints no
    /// result line is read by its exit status.
    static func checkSwitch(_ result: AccountCommandResult) throws {
        let line = result.output.split(whereSeparator: \.isNewline)
            .compactMap { line -> SwitchResult? in
                guard line.hasPrefix("{") else { return nil }
                return try? JSONDecoder().decode(SwitchResult.self, from: Data(line.utf8))
            }
            .first
        if let line {
            if line.outcome == "ok" || line.alreadyInGoalState == true { return }
            throw HarnessAdapterError.capabilityUnavailable(line.message ?? result.output)
        }
        guard result.exitCode == 0 else {
            throw HarnessAdapterError.processExited(
                code: result.exitCode, message: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The `description` in the plugin's manifest (`.claude-plugin/plugin.json`), when it has one.
    static func manifestDescription(installPath: String) -> String? {
        let manifest = URL(filePath: installPath).appending(path: ".claude-plugin/plugin.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }
}
