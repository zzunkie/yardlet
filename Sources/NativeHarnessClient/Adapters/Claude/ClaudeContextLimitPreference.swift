import Foundation

/// "Context limit for Claude Code tasks" in Yardlet's General settings: the limit a Claude Code task
/// that chose none of its own in its context window takes. It is read when a task's CLI starts and
/// reaches it as the task's own limit does (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`), so it is never
/// copied into a task: a task without its own follows a change from its next start, and Claude
/// Code's default, the value it ships with, leaves the variable unset.
enum ClaudeContextLimitPreference {
    static let key = "YardletClaudeContextLimit"

    /// The tokens a task without its own limit starts with, or nil for Claude Code's own.
    static func tokens(in defaults: UserDefaults = .yardlet) -> UInt64? {
        ClaudeLaunchOption.contextLimitTokens(defaults.string(forKey: key))
    }
}
