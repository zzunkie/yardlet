import Darwin
import Foundation

/// Yardlet started from inside a Claude Code session (a terminal `swift run`, or an agent that opened
/// the app) inherits that session's variables. They describe the parent host, not Yardlet, and would
/// make every task Yardlet starts behave as that host's child (its config folder, its disabled
/// connectors, its messaging socket), so they are dropped once at launch.
///
/// Yardlet opened from an SSH shell (`open` hands the shell's variables to the app) likewise carries
/// that connection's variables, though its tasks run in the person's own login session. A CLI that
/// sees them takes itself to be remote: Antigravity CLI then leaves the macOS keychain alone and
/// finds no sign-in. They are dropped too.
enum HostSessionEnvironment {
    private static let names: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "ENABLE_CLAUDEAI_MCP_SERVERS",
        "DISABLE_AUTOUPDATER", "DISABLE_MICROCOMPACT", "MCP_CONNECTION_NONBLOCKING", "MCP_SERVER_CONNECTION_BATCH_SIZE",
        "USE_STAGING_OAUTH", "USE_LOCAL_OAUTH", "AI_AGENT", "API_TIMEOUT_MS"
    ]
    private static let prefixes = ["CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "CLAUDE_PREVIEW_"]
    private static let remoteShellNames: Set<String> = ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]

    static func hostVariables(in environment: [String: String]) -> [String] {
        let inClaudeSession = environment["CLAUDECODE"] != nil || environment["CLAUDE_CODE_ENTRYPOINT"] != nil
        return environment.keys.filter { key in
            remoteShellNames.contains(key)
                || inClaudeSession && (names.contains(key) || prefixes.contains { key.hasPrefix($0) })
        }.sorted()
    }

    static func detachFromHostSession() {
        for key in hostVariables(in: ProcessInfo.processInfo.environment) { unsetenv(key) }
    }
}
