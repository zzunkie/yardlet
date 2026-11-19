import Foundation

/// A plugin installed for an account, as its harness lists it, and whether the harness has it on.
struct HarnessAccountPlugin: Equatable, Identifiable, Sendable {
    /// The harness's own name for it: `name@marketplace` for Claude Code.
    let id: String
    let name: String
    let marketplace: String?
    let description: String?
    let isEnabled: Bool
}

/// A harness that lists the plugins installed for its account and turns them on and off with its
/// own command. The harness keeps the state; Yardlet keeps none of it, so removing Yardlet leaves
/// only what the harness would have after the same change in its own app.
protocol HarnessAccountPluginSwitching: Actor {
    /// Whether this adapter's harness lists and switches plugins. A wrapper answers for the adapter
    /// it wraps.
    nonisolated var switchesAccountPlugins: Bool { get }
    func accountPlugins() async throws -> [HarnessAccountPlugin]
    func setAccountPlugin(_ id: String, enabled: Bool) async throws
}

/// A harness that turns one of its account's skills on and off with its own request, by the skill
/// file's path (Codex `skills/config/write`).
protocol HarnessSkillSwitching: Actor {
    func setSkill(at path: String, enabled: Bool) async throws
}

/// Whose tasks a switch reaches. The harness writes the account's own settings file (Claude Code's
/// `settings.json`, Codex's `config.toml`), and an account folder Yardlet made reads the default
/// folder's through a link (docs/PROVIDER_CONNECTIONS.md, "Claude account folders: what stays per
/// account and what is shared"), so a change there reaches every account that shares the file.
enum HarnessSwitchReach: Equatable, Sendable {
    case account
    case sharedSettings

    /// `.sharedSettings` when another of `folders` reads the same `fileName` as `folder`, through a
    /// link either way.
    static func of(folder: URL, among folders: [URL], fileName: String) -> HarnessSwitchReach {
        let own = folder.standardizedFileURL
        let file = own.appending(path: fileName).resolvingSymlinksInPath()
        let shared = folders.map(\.standardizedFileURL).contains { other in
            other != own && other.appending(path: fileName).resolvingSymlinksInPath() == file
        }
        return shared ? .sharedSettings : .account
    }
}

/// What a task's harness settings sheet keeps for its switches: the account's plugins as the
/// harness last listed them (nil where it lists none, or before the sheet read them), whose tasks
/// a switch reaches, and what the last read or switch reported when it failed.
struct HarnessSwitchState: Equatable, Sendable {
    var accountPlugins: [HarnessAccountPlugin]?
    var reach = HarnessSwitchReach.account
    var errors: [String] = []
    var isLoading = false
}
