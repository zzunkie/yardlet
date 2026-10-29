import Foundation
import YardletAgentTools

/// A suggested task: Yardlet's `spawn_task` call, once Yardlet answered it, drawn as a chip where
/// the call happened (`TaskSuggestionCard`), as the Claude app draws its `spawn_task` call.
struct ConversationTaskSuggestion: Identifiable, Equatable, Sendable {
    /// The task ID Yardlet answered the call with (`task_1a2b3c4d`), under which the task keeps what
    /// became of the suggestion.
    var id: String
    var title: String?
    /// The one or two sentences under the title.
    var tldr: String?
    /// The new task's first message.
    var prompt: String
    /// The agent asked for the new task to start in a fresh worktree.
    var startsInNewWorktree: Bool
    /// Another project's folder the agent named (`cwd`), as written.
    var cwd: String? = nil
    /// The task the agent named for the new one to nest under (`parent_task_id`); nil is the task
    /// that suggested it.
    var parentTaskID: UUID? = nil
    /// The agent asked for a chat with no project (`chat`).
    var startsAsChat = false
}

/// Which calls are suggested tasks, whatever the harness. Every harness that loads Yardlet's MCP
/// server records the call in its own shape: Claude Code as `mcp__yardlet__spawn_task` with JSON
/// input, Codex as an MCP call to the `yardlet` server, an ACP agent as a tool call titled in its
/// own words. What they share is the arguments and Yardlet's answer, which names the task ID with
/// words only Yardlet's answer has (`TaskSuggestionToolCatalog.taskID(inResult:)`), so a call the
/// Claude app's own `spawn_task` answered, in a conversation imported from it, stays a tool line.
enum ConversationTaskSuggestionProjection {
    /// A shared-transcript call (Claude Code, ACP) that Yardlet answered as a suggestion. The session
    /// rail asks this of every finished call in the conversation each time it updates, so a call is
    /// passed over by its answer, which is short when it is Yardlet's, before its input is decoded.
    static func suggestion(from activity: HarnessActivity) -> ConversationTaskSuggestion? {
        guard activity.outcome != .failed, activity.subtask == nil, activity.diff == nil,
              let result = activity.output, result.utf8.count <= longestAnswer,
              TaskSuggestionToolCatalog.taskID(inResult: result) != nil else { return nil }
        return suggestion(arguments: ConversationAgentRunProjection.arguments(in: activity.input), result: result)
    }

    /// Longer than any answer Yardlet gives a suggestion (`TaskSuggestionToolCatalog.notedResult`),
    /// however a harness wraps it.
    private static let longestAnswer = 16_384

    /// A Codex MCP call to the `yardlet` server's `spawn_task`.
    static func suggestion(from tool: CodexMCPToolItem) -> ConversationTaskSuggestion? {
        guard tool.server == AgentToolEnvironment.serverName, tool.tool == TaskSuggestionToolCatalog.spawnTask,
              tool.error == nil || tool.error == .null else { return nil }
        let result = CodexMCPResultProjection(result: tool.result).blocks.compactMap { block -> String? in
            if case let .text(_, text) = block { return text }
            return nil
        }.joined(separator: "\n")
        return suggestion(arguments: tool.arguments, result: result)
    }

    /// A task's suggestions in the order its conversation made them, each once: the calls its chips
    /// are drawn from, for the session rail.
    static func suggestions(in entries: [TranscriptEntry], codexState: CodexTaskState?) -> [ConversationTaskSuggestion] {
        var seen = Set<String>()
        var result: [ConversationTaskSuggestion] = []
        func add(_ suggestion: ConversationTaskSuggestion?) {
            if let suggestion, seen.insert(suggestion.id).inserted { result.append(suggestion) }
        }
        for entry in entries {
            if case let .activity(activity, .completed) = entry.content { add(suggestion(from: activity)) }
        }
        for turn in codexState?.thread?.turns ?? [] {
            for item in turn.items {
                if case let .mcpToolCall(tool) = item.content, tool.status == "completed", tool.errorMessage == nil {
                    add(suggestion(from: tool))
                }
            }
        }
        return result
    }

    static func suggestion(arguments: JSONValue?, result: String?) -> ConversationTaskSuggestion? {
        guard let id = TaskSuggestionToolCatalog.taskID(inResult: result), let arguments,
              case let .success(suggestion) = TaskSuggestionToolCall.suggestion(from: arguments) else { return nil }
        return ConversationTaskSuggestion(
            id: id, title: suggestion.title, tldr: suggestion.tldr, prompt: suggestion.prompt,
            startsInNewWorktree: suggestion.startsInNewWorktree, cwd: suggestion.cwd,
            parentTaskID: suggestion.parentTaskReference.flatMap { UUID(uuidString: $0) },
            startsAsChat: suggestion.startsAsChat
        )
    }
}
