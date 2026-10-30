import Foundation

/// The task suggestion tools Yardlet offers every harness that loads its MCP server, after the
/// Claude app's `spawn_task` and `dismiss_task` (its `ccd_session` server, desktop 2.37337.1).
/// `spawn_task` flags out-of-scope work: the app answers with a task ID and the conversation shows
/// the call as a chip whose Start starts the task under this one, as the Claude app's does. Neither
/// tool starts a model turn, and neither changes anything outside Yardlet's own record of the chip:
/// only the person's click does.
package enum TaskSuggestionToolCatalog {
    package static let spawnTask = "spawn_task"
    package static let dismissTask = "dismiss_task"
    /// `spawn_task`'s place arguments: another project's root, as the Claude app's `cwd`, or a task
    /// to nest under, named as the session tools name tasks.
    package static let cwd = "cwd"
    package static let parentTaskID = "parent_task_id"
    /// `spawn_task`'s choice of no project: the task starts as a chat, as New Task's "No project".
    package static let chat = "chat"
    package static let selfReference = SessionToolCatalog.selfReference

    /// The Claude app's limits: a prompt of at most 32,000 characters, a title kept to 200 and a
    /// summary to 2,000.
    package static let maximumPromptLength = 32_000
    package static let maximumTitleLength = 200
    package static let maximumSummaryLength = 2_000

    package static func definition(named name: String) -> AgentToolDefinition? {
        tools.first { $0.name == name }
    }

    /// `task_` and eight lowercase hex digits, as the Claude app issues them.
    package static func newTaskID() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: .min ... .max, using: &generator)
        let hex = String(value, radix: 16)
        return "task_" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    package static func isTaskID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 13, text.hasPrefix("task_") else { return false }
        let hexDigits = "0123456789abcdef".unicodeScalars
        return scalars.dropFirst(5).allSatisfy { hexDigits.contains($0) }
    }

    /// The marker every `spawn_task` result carries, which the conversation reads the chip's task ID
    /// from: `task_id: task_1a2b3c4d`.
    package static let taskIDLabel = "task_id: "
    /// Words only Yardlet's result has, so a conversation imported from the Claude app, whose own
    /// `spawn_task` answers much the same, does not draw Yardlet chips.
    package static let resultSignature = "A chip is showing for the user in Yardlet"

    /// The task ID a `spawn_task` result names, when the text is Yardlet's result. The session rail
    /// asks this of every finished call each time it updates, so the text is searched as UTF-8 bytes,
    /// which both markers are, with the C library's byte search rather than character by character.
    package static func taskID(inResult text: String?) -> String? {
        guard let text, byteOffset(of: resultSignature, in: text) != nil,
              let label = byteOffset(of: taskIDLabel, in: text) else { return nil }
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: label + taskIDLabel.utf8.count)
        let candidate = String(text[start...].prefix(13))
        return isTaskID(candidate) ? candidate : nil
    }

    /// Where `needle` first occurs in `text`, in UTF-8 bytes from its start.
    private static func byteOffset(of needle: String, in text: String) -> Int? {
        var text = text, needle = needle
        return text.withUTF8 { haystack in
            needle.withUTF8 { needle in
                guard let first = needle.first, let base = haystack.baseAddress, let wanted = needle.baseAddress,
                      needle.count <= haystack.count else { return nil }
                let last = haystack.count - needle.count
                var start = 0
                while start <= last {
                    guard let found = memchr(base + start, Int32(first), last - start + 1) else { return nil }
                    let offset = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    if memcmp(found, wanted, needle.count) == 0 { return offset }
                    start = offset + 1
                }
                return nil
            }
        }
    }

    /// `place` words where Start starts the task when the agent named a place ("in /path, nested under
    /// this one", "nested under task … in its project").
    package static func notedResult(taskID: String, place: String? = nil) -> String {
        "Noted (\(taskIDLabel)\(taskID)). \(resultSignature): one click starts it as a new task "
            + (place ?? "nested under this one")
            + ", or they ask for it here, in this conversation, or dismiss it. If this suggestion becomes "
            + "stale or superseded, call dismiss_task with this task_id. Continue your current work."
    }

    package static let tools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: spawnTask,
            title: "Suggest a separate task",
            description: """
                Flag an out-of-scope issue for a separate task.

                Call this when you notice something worth fixing that would bloat the current change \u{2014} \
                dead code, stale docs, missing coverage, a confirmed TODO, or a security issue spotted in \
                passing. Don't flag vague code-smell observations, trivial fixes you can do inline, or \
                low-confidence hunches. A chip appears for the user in this conversation; one click starts a \
                new task with your prompt as its first message, nested under this task, or the user asks for \
                it to be done here instead. Your current turn continues uninterrupted.

                The prompt must stand alone \u{2014} include file paths and enough context to act without this \
                conversation.

                The result includes a task_id; call dismiss_task with it if the suggestion later becomes stale.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Under 60 chars. Imperative action phrase (start with a verb), e.g. "
                            + "\"Fix stale README badge\", \"Remove dead config option\". Shown as the chip label "
                            + "and the new task's title.")
                    ]),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The first message for the new task. Self-contained \u{2014} include "
                            + "file paths and enough context to act without this conversation.")
                    ]),
                    "tldr": .object([
                        "type": .string("string"),
                        "description": .string("One or two plain-English sentences shown on the suggestion card "
                            + "under the title. Lead with why you are suggesting this now \u{2014} name what you "
                            + "noticed in this task \u{2014} then say what the new task will do. Keep it readable: "
                            + "no file paths or code.")
                    ]),
                    "useWorktree": .object([
                        "type": .string("boolean"),
                        "description": .string("Optional. true sets the new task to start in a fresh Git worktree "
                            + "of this project, so its changes don't share this task's checkout. Omit it to leave "
                            + "the choice to the user.")
                    ]),
                    cwd: .object([
                        "type": .string("string"),
                        "description": .string("Optional. Absolute path to a different project root than this task's, "
                            + "on this computer. The new task starts there \u{2014} in a fresh worktree under this path "
                            + "when it is a Git repository \u{2014} nested under this task. Defaults to this task's "
                            + "project \u{2014} only set this when the work clearly belongs in another repo. Not with "
                            + "parent_task_id.")
                    ]),
                    parentTaskID: .object([
                        "type": .string("string"),
                        "description": .string("Optional. A task id from list_tasks: the new task starts as that "
                            + "task's subtask, in its project and folder, on its harness, account, model, effort and "
                            + "permission mode. Defaults to this task. Not with cwd.")
                    ]),
                    chat: .object([
                        "type": .string("boolean"),
                        "description": .string("Optional. true starts the new task as a chat with no project, in a "
                            + "new folder of its own, as New Task's \"No project\" does, nested under this task. Not "
                            + "with cwd or parent_task_id.")
                    ])
                ]),
                "required": .array([.string("title"), .string("prompt"), .string("tldr")]),
                "additionalProperties": .bool(false)
            ]),
            readOnly: true,
            openWorld: false,
            alwaysLoad: true
        ),
        AgentToolDefinition(
            name: dismissTask,
            title: "Withdraw a task suggestion",
            description: """
                Withdraw a task chip you previously created with spawn_task.

                Call this when a suggestion you flagged is now stale, superseded, or irrelevant \u{2014} e.g. you \
                (or the user) already fixed it in this task, or you flagged a better-scoped replacement. To \
                replace a chip: call spawn_task with the new suggestion first, then dismiss the old task_id.

                Only chips the user hasn't started can be withdrawn. If the user already started or dismissed \
                the task, the result says so \u{2014} do not retry.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_id": .object([
                        "type": .string("string"),
                        "description": .string("The task_id returned by the spawn_task call that created the chip.")
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Optional one-line reason the suggestion is no longer needed, e.g. "
                            + "\"fixed in this task\" or \"superseded by task_ab12cd34\".")
                    ])
                ]),
                "required": .array([.string("task_id")]),
                "additionalProperties": .bool(false)
            ]),
            readOnly: true,
            openWorld: false,
            alwaysLoad: true
        )
    ]
}
