import Foundation
import YardletAgentTools

/// Yardlet's `run_agent` call as the subagent card every harness draws for its own subagents:
/// the harness it ran on, the prompt, and what it answered. The card opens the subagent's
/// conversation from the app (`AgentRun`), which also gives its live line while it works. Every
/// harness records the call in its own shape — Claude Code as `mcp__yardlet__run_agent`, Codex as
/// an MCP call to the `yardlet` server, an ACP agent as a tool call — with the same arguments.
enum ConversationAgentRunProjection {
    /// The line `run_agent` answers with first, which names the subagent.
    static let agentIDLabel = "agent_id: "

    /// A shared-transcript call (Claude Code, ACP, Antigravity) to `run_agent`.
    static func subagent(from activity: HarnessActivity, phase: ConversationItemPhase,
                         isApproved: Bool) -> ConversationSubagent? {
        guard isRunAgentCall(activity) else { return nil }
        return subagent(arguments: arguments(in: activity.input), result: activity.output, isApproved: isApproved)
    }

    /// Whether a shared-transcript call is to `run_agent`, told by its name alone: its input, which
    /// holds the prompt, is not read.
    static func isRunAgentCall(_ activity: HarnessActivity) -> Bool {
        activity.subtask == nil && activity.diff == nil && (isRunAgent(activity.kind) || isRunAgent(activity.title))
    }

    /// A Codex MCP call to the `yardlet` server's `run_agent`.
    static func subagent(from tool: CodexMCPToolItem) -> ConversationSubagent? {
        guard tool.server == AgentToolEnvironment.serverName, tool.tool == SessionToolCatalog.runAgent else {
            return nil
        }
        let result = CodexMCPResultProjection(result: tool.result).blocks.compactMap { block -> String? in
            if case let .text(_, text) = block { return text }
            return nil
        }.joined(separator: "\n")
        return subagent(arguments: tool.arguments, result: result.isEmpty ? nil : result, isApproved: false)
    }

    static func subagent(arguments: JSONValue?, result: String?, isApproved: Bool) -> ConversationSubagent? {
        guard let prompt = arguments?["prompt"]?.stringValue, !prompt.isEmpty else { return nil }
        let harness = arguments?["harness"]?.stringValue.map(harness(named:))
        let model = arguments?["model"]?.stringValue
        // Named by what it was asked, as the rail's Agents card names it, with its harness and model.
        return ConversationSubagent(
            title: ConversationSubagent.name(asked: prompt) ?? AgentRun.label(harness: harness, model: model),
            status: nil, detail: nil,
            routes: [.yardletAgent(agentID: agentID(inResult: result), prompt: prompt)],
            isApproved: isApproved, kind: SessionToolCatalog.runAgent, input: prompt,
            output: result.map(answer(inResult:)), isBackground: false, model: model,
            harnessLabel: AgentRun.harnessLabel(harness: harness, model: model))
    }

    /// The harness a run_agent call named, as the tool read it: a name such as "Antigravity" is that
    /// harness, and one Yardlet does not know stays as written.
    static func harness(named name: String) -> HarnessKind {
        HarnessCatalog.harness(named: name) ?? HarnessKind(rawValue: name)
    }

    /// The subagent the answer names.
    static func agentID(inResult result: String?) -> String? {
        guard let result, let range = result.range(of: agentIDLabel) else { return nil }
        let id = result[range.upperBound...].prefix(36)
        return UUID(uuidString: String(id)) == nil ? nil : String(id)
    }

    /// The answer without its first line, which only names the agent.
    static func answer(inResult result: String) -> String {
        guard result.hasPrefix(agentIDLabel), let newline = result.firstIndex(of: "\n") else { return result }
        return String(result[result.index(after: newline)...])
    }

    private static func isRunAgent(_ name: String) -> Bool {
        name == "mcp__\(AgentToolEnvironment.serverName)__\(SessionToolCatalog.runAgent)"
            || name == SessionToolCatalog.runAgent
            || name.hasSuffix(": \(SessionToolCatalog.runAgent)")
    }

    /// The JSON object a transcript keeps as a call's input. An ACP agent's input may follow a line
    /// of its own; the object is then read from its first brace. Any call's input is read, a command
    /// with a lone `}` before its first `{` among them, so the braces must be in order.
    static func arguments(in input: String?) -> JSONValue? {
        guard let input, let start = input.firstIndex(of: "{"), let end = input.lastIndex(of: "}"), start < end else {
            return nil
        }
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(input[start...end].utf8))
        guard case .object = value else { return nil }
        return value
    }
}
