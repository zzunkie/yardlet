import Foundation

/// How a harness's own CLI takes a workspace root besides the cwd.
///
/// A project's other folders reach a provider through that provider's own
/// means. Yardlet does not invent one. It adds no flag a CLI does not document, and it puts no
/// private field on a protocol request — ACP `session/new` carries `cwd` and `mcpServers` and
/// nothing else, so an ACP agent hears about extra roots only if its own executable accepts them.
/// A CLI with no such means starts with exactly the arguments the catalog already listed.
enum HarnessWorkspaceRootLaunchArguments {
    /// The repeatable launch flag a CLI documents for an extra workspace root, for the
    /// subcommand Yardlet actually launches, or nil when that subcommand has none.
    ///
    /// Read from each runtime's own `--help` on 2026-09-22:
    /// - `opencode acp` — `--cwd` only, which is the primary folder, not an addition.
    /// - `kimi acp` — only `--login`. The interactive `kimi` command does document
    ///   `--add-dir`, but the ACP subcommand neither advertises nor reads it: its
    ///   `session/new` builds the session from `params.cwd` alone. Passing the flag anyway
    ///   would let Yardlet claim a root the agent never receives.
    /// - `grok agent stdio` — debug and leader-socket options only.
    /// - `hermes acp` — auth and setup options only. `hermes project add-folder` exists, but it
    ///   rewrites the user's own profile state rather than configuring one launch.
    /// - `kiro-cli acp` (3.5.0) — engine, sign-in and v2-only model and trust options.
    /// - `pi --mode rpc` — no additional-directory option, and the RPC session request has no
    ///   field for one.
    static func flag(for harness: HarnessKind) -> String? {
        flagsByHarness[harness]
    }

    /// The arguments to append after the catalog's launch arguments. Empty whenever the task has
    /// no extra roots, and empty for a CLI with no documented means, so those launches are
    /// byte-for-byte the launch they always were.
    static func arguments(for roots: [URL], harness: HarnessKind) -> [String] {
        guard let flag = flag(for: harness) else { return [] }
        return arguments(for: roots, flag: flag)
    }

    /// The expansion itself: one flag/value pair per root, in the order the project lists them.
    static func arguments(for roots: [URL], flag: String) -> [String] {
        roots.flatMap { root in
            [flag, root.standardizedFileURL.path(percentEncoded: false)]
        }
    }

    /// Codex and Claude are deliberately absent: Codex carries its roots in `thread/start` and
    /// `thread/resume`, and Claude's own launch builder owns `--add-dir`. Neither reads this
    /// table, so listing them here could only create a second, conflicting source of truth.
    private static let flagsByHarness: [HarnessKind: String] = [:]
}
