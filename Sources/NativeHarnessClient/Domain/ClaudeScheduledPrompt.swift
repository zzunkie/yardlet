import Foundation

/// A prompt Claude Code's own schedule sent in the person's place (CLI 2.1.299):
/// - a `CronCreate` job or a `/loop` wakeup the CLI fired: a `user` record with `isMeta`,
///   `promptSource` "system" and `turnOrigin` "scheduled" (the CLI marks every queued prompt that
///   has a `wakeupSource` so), its text the job's prompt. The live stream sends no `user` frame for
///   it, only `command_lifecycle` under the record's uuid, unless the CLI replays user messages;
/// - a Claude app scheduled task: `origin` `{kind: "task-notification", subkind: "scheduled-trigger"}`,
///   its text one `<scheduled-task name="…" file="…/SKILL.md">` block around the task's instructions.
/// Neither is the person's. Its turn reads as a turn of its own, so what Claude answered before it
/// stays that turn's answer, and it is no message to edit or restore files to. The Claude app draws
/// it as an event, "Scheduled check-in", or "Scheduled task: {name}" for a named task, not as a
/// sent message.
struct ClaudeScheduledPrompt: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A `CronCreate` job or a `/loop` wakeup.
        case checkIn
        /// A Claude app scheduled task, by its name.
        case task(name: String)

        /// The Claude app's words for what its schedule sent: "Scheduled check-in" for a `CronCreate` job or a
        /// `/loop` wakeup, "Scheduled task: {name}" for a named scheduled task.
        var label: String {
            switch self {
            case .checkIn: L10n.string("Scheduled check-in")
            case let .task(name): L10n.format("Scheduled task: %@", name)
            }
        }
    }

    let kind: Kind
    /// What it asked for: the job's prompt, or the task's instructions.
    let instructions: String

    /// The prompt's text when a saved `user` record is one, else nil. A compaction's summary that
    /// carries the turn's origin on, a cut-off note (`turnCompanion`, the same prompt ID as the
    /// prompt it continues), a subagent's record and tool results are none: they stay where they are.
    static func text(of record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "user", record["isSidechain"]?.boolValue != true,
              record["isCompactSummary"]?.boolValue != true, record["isVisibleInTranscriptOnly"]?.boolValue != true,
              record["turnCompanion"]?.boolValue != true,
              record["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return nil }
        let origin = record["origin"]
        let isClaudeAppTask = origin?["kind"]?.stringValue == "task-notification"
            && origin?["subkind"]?.stringValue == "scheduled-trigger"
        guard record["turnOrigin"]?.stringValue == "scheduled" || isClaudeAppTask else { return nil }
        let content = record["message"]?["content"]
        let blocks = content?.arrayValue ?? []
        guard !blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) else { return nil }
        let text = content?.stringValue ?? blocks.compactMap {
            $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
        }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The prompt as the Claude app reads it: a `<scheduled-task name="…" file="…">` block from the
    /// text's first character to its last is the named task's instructions (the app's `yc`: a name of
    /// 1–64 of `a-z0-9_-`, the tag on a line of its own); any other text is a check-in's prompt.
    static func reading(_ text: String) -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let close = "</scheduled-task>"
        guard trimmed.hasPrefix("<scheduled-task "), trimmed.hasSuffix(close),
              let tagEnd = trimmed.range(of: ">\n"),
              let name = attribute("name", in: trimmed[..<tagEnd.lowerBound]),
              (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }),
              trimmed.range(of: "<scheduled-task", range: trimmed.index(after: trimmed.startIndex)..<trimmed.endIndex) == nil
        else { return Self(kind: .checkIn, instructions: text) }
        let body = trimmed[tagEnd.upperBound..<trimmed.index(trimmed.endIndex, offsetBy: -close.count)]
        return Self(kind: .task(name: name), instructions: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
