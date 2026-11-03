import Foundation
import YardletAgentTools

/// A Yardlet setting an agent changed with `update_setting`, drawn where the call happened as one row that
/// stays when the turn folds (`SettingChangedRow`): the setting, what it went from and to, and Open, which
/// shows its section in Settings.
struct ConversationSettingChange: Equatable, Sendable {
    var settingID: String
    var title: String
    var from: String
    var to: String
}

/// Which calls changed a setting, whatever the harness: Claude Code records `mcp__yardlet__update_setting`,
/// Codex an MCP call to the `yardlet` server, an ACP agent a tool call in its own words. What they share is
/// the first line of Yardlet's answer (`SettingsToolCatalog.changed(inResult:)`).
enum ConversationSettingProjection {
    /// A shared-transcript call (Claude Code, ACP).
    static func change(from activity: HarnessActivity) -> ConversationSettingChange? {
        guard activity.outcome != .failed, activity.subtask == nil, activity.diff == nil else { return nil }
        return change(result: activity.output)
    }

    /// A Codex MCP call to the `yardlet` server's `update_setting`.
    static func change(from tool: CodexMCPToolItem) -> ConversationSettingChange? {
        guard tool.server == AgentToolEnvironment.serverName, tool.tool == SettingsToolCatalog.update,
              tool.error == nil || tool.error == .null else { return nil }
        let result = CodexMCPResultProjection(result: tool.result).blocks.compactMap { block -> String? in
            if case let .text(_, text) = block { return text }
            return nil
        }.joined(separator: "\n")
        return change(result: result)
    }

    static func change(result: String?) -> ConversationSettingChange? {
        SettingsToolCatalog.changed(inResult: result).map {
            ConversationSettingChange(settingID: $0.id, title: $0.title, from: $0.from, to: $0.to)
        }
    }
}
