import Foundation

/// A task-owned handoff from a typed Codex item to a native work surface.
///
/// The provider may describe a path or command, but it never gets to choose a filesystem root or
/// execute a command implicitly. The shared shell receives only metadata plus a verified,
/// workspace-relative URL for file navigation.
struct CodexChangeHandoff: Equatable, Identifiable, Sendable {
    let id: String
    let turnID: String
    let itemID: String
    let relativePath: String
    /// The change's kind (`add`, `update`, `delete`).
    let status: String
    /// The patch reached the files (its item completed); not one declined, failed or still waiting.
    let isApplied: Bool
    let verifiedURL: URL?
    let line: Int64?
    let column: Int64?

    var isVerified: Bool { verifiedURL != nil }

    var locationLabel: String {
        guard let line else { return relativePath }
        if let column { return "\(relativePath):\(line):\(column)" }
        return "\(relativePath):\(line)"
    }
}

enum CodexEditorHandoffOutcome: Equatable, Sendable {
    case opened
    case failed
}

enum CodexEditorHandoffProjection {
    static func outcome(opened: Bool) -> CodexEditorHandoffOutcome {
        opened ? .opened : .failed
    }

    static func messageKey(for outcome: CodexEditorHandoffOutcome) -> String {
        switch outcome {
        case .opened:
            "Editor launch requested."
        case .failed:
            "Could not request editor launch."
        }
    }

    static func symbolName(for outcome: CodexEditorHandoffOutcome) -> String {
        switch outcome {
        case .opened:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        }
    }
}

/// A provider-item handoff that can be copied for inspection without dispatching a new
/// provider request or opening a task-owned process. The payload is a projection of the
/// already-hydrated item state, so it cannot grant a tool, credential, or filesystem access.
struct CodexItemHandoff: Equatable, Identifiable, Sendable {
    let id: String
    let turnID: String
    let itemID: String
    let typeName: String
    let payload: String
}

struct CodexWorkSurfaceProjection: Sendable {
    static func changes(
        from state: CodexTaskState,
        workspaceURL: URL
    ) -> [CodexChangeHandoff] {
        state.thread?.turns.flatMap { changes(in: $0, workspaceURL: workspaceURL) } ?? []
    }

    /// One turn's part of `changes(from:workspaceURL:)`.
    static func changes(in turn: CodexTurnState, workspaceURL: URL) -> [CodexChangeHandoff] {
        let root = workspaceURL.standardizedFileURL
        return turn.items.flatMap { item -> [CodexChangeHandoff] in
            guard case let .fileChange(change) = item.content else { return [] }
            let isApplied = CodexFileChangeCardProjection.state(for: change.status, isTurnFinished: false) == .applied
            return change.changes.enumerated().compactMap { index, value in
                guard let path = value["path"]?.stringValue else { return nil }
                return CodexChangeHandoff(
                    id: "\(turn.id):\(item.id):\(index)",
                    turnID: turn.id,
                    itemID: item.id,
                    relativePath: CodexFileChangeDiff.displayPath(path, workspaceURL: root),
                    status: value["kind"]?["type"]?.stringValue ?? value["kind"]?.stringValue ?? change.status,
                    isApplied: isApplied,
                    verifiedURL: verifiedURL(for: path, relativeTo: root),
                    line: value["line"]?.integerValue ?? value["lineNumber"]?.integerValue
                        ?? value["newLine"]?.integerValue,
                    column: value["column"]?.integerValue
                )
            }
        }
    }

    static func itemHandoff(for item: CodexItemState, turnID: String) -> CodexItemHandoff? {
        let body: String?
        switch item.content {
        case let .userMessage(message):
            body = stringValues(message.content)
        case let .hookPrompt(fragments):
            body = jsonString(.array(fragments))
        case let .agentMessage(message):
            body = message.text
        case let .plan(text):
            body = text
        case let .reasoning(summary, content):
            let values = [stringValues(summary), stringValues(content)].compactMap { $0 }
            body = values.isEmpty ? jsonString(.array(summary + content)) : values.joined(separator: "\n")
        case let .commandExecution(command):
            body = [
                command.command,
                command.aggregatedOutput,
                command.exitCode.map { "exitCode: \($0)" }
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case let .fileChange(change):
            let paths = change.changes.compactMap { $0["path"]?.stringValue }
            body = paths.isEmpty ? jsonString(.array(change.changes)) : paths.joined(separator: "\n")
        case let .mcpToolCall(tool):
            body = [
                "\(tool.server) · \(tool.tool)",
                "status: \(tool.status)",
                "arguments: \(jsonString(tool.arguments) ?? String(describing: tool.arguments))",
                tool.result.map { "result: \(jsonString($0) ?? String(describing: $0))" },
                tool.error.map { "error: \(jsonString($0) ?? String(describing: $0))" },
                tool.pluginID.map { "pluginID: \($0)" },
                tool.durationMilliseconds.map { "durationMilliseconds: \($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case let .dynamicToolCall(tool):
            body = [
                tool.tool,
                tool.namespace.map { "namespace: \($0)" },
                "status: \(tool.status)",
                "arguments: \(jsonString(tool.arguments) ?? String(describing: tool.arguments))",
                tool.contentItems.isEmpty
                    ? nil
                    : "contentItems: \(jsonString(.array(tool.contentItems)) ?? String(describing: tool.contentItems))",
                tool.succeeded.map { "succeeded: \($0)" },
                tool.durationMilliseconds.map { "durationMilliseconds: \($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case let .collaboration(collaboration):
            body = [
                collaboration.tool,
                "status: \(collaboration.status)",
                collaboration.prompt,
                collaboration.receiverThreadIDs.isEmpty
                    ? nil
                    : "childThreads: \(collaboration.receiverThreadIDs.joined(separator: ", "))",
                childResults(collaboration)
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case let .subagentActivity(activity):
            body = [activity.kind, activity.agentPath, activity.agentThreadID]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .webSearch(query, action, results):
            body = [
                query,
                action.map { "action: \(jsonString($0) ?? String(describing: $0))" },
                results.map { "results: \(jsonString(.array($0)) ?? String(describing: $0))" }
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case let .imageView(path):
            body = path
        case let .sleep(durationMilliseconds):
            body = "durationMilliseconds: \(durationMilliseconds)"
        case let .imageGeneration(image):
            body = [
                image.result,
                image.revisedPrompt.map { "revisedPrompt: \($0)" },
                image.savedPath.map { "savedPath: \($0)" },
                image.failure.map { "failure: \(jsonString($0) ?? String(describing: $0))" }
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case let .enteredReviewMode(review), let .exitedReviewMode(review):
            body = review
        case .contextCompaction:
            body = "contextCompaction"
        case let .notice(notice):
            body = [
                "\(notice.kind.rawValue): \(notice.message)",
                notice.fromModel.map { "fromModel: \($0)" },
                notice.reason.map { "reason: \($0)" },
                notice.details,
                notice.path.map { "path: \($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case let .unknown(_, raw):
            body = jsonString(raw)
        }

        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CodexItemHandoff(
            id: "\(turnID):\(item.id)",
            turnID: turnID,
            itemID: item.id,
            typeName: item.content.typeName,
            payload: "itemId: \(item.id)\ntype: \(item.content.typeName)\n\(body)"
        )
    }

    /// Each child's `agentsStates` entry, the child's own status and the message it ended with: the
    /// receivers in their order, then any other child the provider reported. A child with no
    /// message, or a blank one, is its status alone. The call's own status is not part of it. Nil
    /// when the provider reported no child. The subagent card's output and the copied details.
    static func childResults(_ collaboration: CodexCollaborationItem) -> String? {
        let states = collaboration.agentStates
        let receivers = collaboration.receiverThreadIDs.filter { states[$0] != nil }
        let others = states.keys.filter { !collaboration.receiverThreadIDs.contains($0) }.sorted()
        let lines = (receivers + others).flatMap { threadID -> [String] in
            let state = states[threadID]
            let status = state?["status"]?.stringValue
            let message = state?["message"]?.stringValue
            return [
                status.map { "\(threadID): \($0)" } ?? threadID,
                message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? message : nil
            ].compactMap { $0 }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func stringValues(_ values: [JSONValue]) -> String? {
        let strings = values.compactMap(\.stringValue).filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    private static func jsonString(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// App Server paths are absolute, so an absolute path inside the task's folder is the task's
    /// own file; anything else stays unverified. The same check as the file change card's.
    private static func verifiedURL(for path: String, relativeTo root: URL) -> URL? {
        CodexFileChangeCardProjection.fileURL(for: path, workspaceURL: root)
    }
}

/// The review panel's Last turn for a Codex task: the most recent turn's changes.
struct CodexLastTurnDiff: Equatable, Sendable {
    let turnID: String
    /// A git-style unified diff; empty when the turn changed no file.
    let text: String
    let isRunning: Bool
    var isTruncated: Bool = false

    /// Changes whenever the diff does, so the panel reloads only then.
    var revision: String { "\(turnID):\(text.utf8.count):\(text.hashValue)" }
}

extension CodexWorkSurfaceProjection {
    /// The live turn's own diff when Codex sent one (`turn/diff/updated`); otherwise, as after
    /// reopening a task, the applied file changes of that turn in order. A file changed twice in
    /// the turn then appears twice, where the live diff shows it once.
    static func lastTurnDiff(from state: CodexTaskState, workspaceURL: URL) -> CodexLastTurnDiff? {
        guard let turn = state.thread?.turns.last else { return nil }
        let text: String
        if let diff = turn.diff, !diff.isEmpty {
            text = diff
        } else {
            let changes = turn.items.flatMap { item -> [JSONValue] in
                guard case let .fileChange(change) = item.content, wasApplied(change.status) else { return [] }
                return change.changes
            }
            text = CodexFileChangeDiff.unifiedDiff(for: changes, workspaceURL: workspaceURL)
        }
        return CodexLastTurnDiff(turnID: turn.id, text: text, isRunning: !turn.status.isTerminal)
    }

    /// A declined or failed patch never reached the files.
    private static func wasApplied(_ status: String) -> Bool {
        !["declined", "failed", "rejected"].contains(status.lowercased())
    }
}
