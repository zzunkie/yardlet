import Foundation

/// What a run of calls reads as folded, in its provider's words:
/// - Codex as the Codex app's activity summary (`localConversation.agentActivity.summary.*`): no
///   counts, in its fixed order — "Edited a file, read files, ran commands" — and, while a command
///   in it runs, that command's line ("Reading Parser.swift", "Running swift test");
/// - Claude Code as its turn summary (`TurnStatus`): counted, most first — "Ran 2 commands, read a
///   file" — and past three kinds, "…, and 3 more tools";
/// - any other harness in Yardlet's words: commands run, files read, files edited, searches and
///   other tools, in the order they first appear.
enum ConversationWorkSummary {
    typealias Localize = ConversationLineWording.Localize

    enum Category: Equatable {
        case command, read, edit, search, other
    }

    /// The kind of call an item is, for folding calls together; nil for anything that is not a call.
    static func category(of item: ConversationItem) -> Category? {
        switch item.kind {
        case .command: .command
        case .fileChange: .edit
        case let .tool(tool):
            switch tool.kind {
            case let .activity(kind) where ["Read", "View", "NotebookRead", "read"].contains(kind): .read
            case let .activity(kind) where ["Grep", "Glob", "LS", "search"].contains(kind): .search
            case .webSearch: .search
            default: .other
            }
        default: nil
        }
    }

    static func phase(of items: [ConversationItem]) -> ConversationItemPhase {
        items.contains { $0.phase == .running } ? .running
            : items.contains { $0.phase == .failed } ? .failed
            : items.contains { $0.phase == .stopped } ? .stopped : .completed
    }

    /// The group's line: Codex's running command while one runs, else the summary.
    static func header(
        for items: [ConversationItem], harness: HarnessKind, localize: Localize = { L10n.string($0) }
    ) -> ConversationLineWords {
        if harness == .codex, let active = codexActiveLine(items, localize: localize) { return active }
        return ConversationLineWords(verb: title(for: items, harness: harness, localize: localize))
    }

    static func title(
        for items: [ConversationItem], harness: HarnessKind, localize: Localize = { L10n.string($0) }
    ) -> String {
        switch harness {
        case .codex: codexTitle(items, localize: localize)
        case .claudeCode: claudeTitle(items, localize: localize)
        default: plainTitle(items, localize: localize)
        }
    }

    // MARK: Codex

    /// The Codex app's group header while its latest running call is a command, a file change or a
    /// web search (`localConversation.agentActivity.running*`, the active tool activity label).
    static func codexActiveLine(_ items: [ConversationItem], localize: Localize) -> ConversationLineWords? {
        guard let running = items.last(where: { $0.phase == .running }) else { return nil }
        switch running.kind {
        case let .command(command):
            return ConversationLineWording.command(command, phase: .running, harness: .codex, localize: localize).last
        case .fileChange:
            return ConversationLineWords(verb: localize("codex.summary.editingFiles"))
        case let .tool(tool) where tool.kind == .webSearch:
            return ConversationLineWords(verb: localize("codex.summary.searchingWeb"))
        default:
            return nil
        }
    }

    /// `localConversation.agentActivity.summary`: tools called, files edited, files explored (read,
    /// searched or listed), commands run, the web searched — in that order, the first in its leading
    /// form, joined as a list. Nothing it names reads "Worked".
    static func codexTitle(_ items: [ConversationItem], localize: Localize) -> String {
        var calledTools = 0, editedFiles = 0, commands = 0
        var explored = false, searchedWeb = false
        for item in items {
            switch item.kind {
            case let .command(command):
                for action in command.actions.isEmpty ? [.unknown(command: command.command)] : command.actions {
                    if action.isExploration { explored = true } else { commands += 1 }
                }
            case let .fileChange(change):
                editedFiles += max(change.rows.count, 1)
            case let .tool(tool):
                switch tool.kind {
                case .mcp, .dynamic: calledTools += 1
                case .webSearch: searchedWeb = true
                default: break
                }
            default:
                break
            }
        }
        var parts: [String] = []
        if calledTools > 0 { parts.append(calledTools == 1 ? "codex.summary.calledTool" : "codex.summary.calledTools") }
        if editedFiles > 0 { parts.append(editedFiles == 1 ? "codex.summary.editedFile" : "codex.summary.editedFiles") }
        if explored { parts.append("codex.summary.readFiles") }
        if commands > 0 { parts.append(commands == 1 ? "codex.summary.ranCommand" : "codex.summary.ranCommands") }
        if searchedWeb { parts.append("codex.summary.searchedWeb") }
        guard !parts.isEmpty else { return localize("codex.summary.worked") }
        return parts.enumerated().map { index, key in localize(index == 0 ? key + ".leading" : key) }
            .joined(separator: ", ")
    }

    // MARK: Claude Code

    /// Claude Code's kinds of call (`JI` in its summary): what a tool's name reads as.
    static func claudeKind(of toolName: String) -> String? {
        var name = toolName
        if let mcp = mcpToolPart(toolName) { name = mcp }
        let snake = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased()
        let kinds: [String: String] = [
            "read": "read", "view": "read", "open_file": "read", "close_file": "read",
            "write": "write", "create_file": "write",
            "edit": "edit", "multi_edit": "edit", "str_replace": "edit", "str_replace_editor": "edit",
            "update_file": "edit", "delete_file": "delete_file", "notebook_edit": "notebook_edit",
            "glob": "glob", "file_search": "glob", "grep": "grep",
            "web_search": "web", "web_search_fast": "web", "web_fetch": "web_fetch",
            "bash": "bash", "bash_tool": "bash", "power_shell": "bash",
            "task": "task", "agent": "task", "skill": "skill", "todo_write": "plan", "kill_bash": "kill_bash",
            "exit_plan_mode": "exit_plan_mode", "tool_search": "tool_search"
        ]
        guard let kind = kinds[snake] else { return nil }
        // Its own tools only: an MCP server's `skill` or `tool_search` is just a tool.
        if toolName.hasPrefix("mcp__"), ["tool_search", "skill"].contains(snake) { return nil }
        return kind
    }

    private static func mcpToolPart(_ name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        var rest = String(name.dropFirst(5))
        while rest.hasSuffix("_") { rest.removeLast() }
        guard let split = rest.range(of: "__", options: .backwards), split.lowerBound > rest.startIndex else {
            return nil
        }
        let tool = rest[split.upperBound...].drop(while: { $0 == "_" })
        return tool.isEmpty ? nil : String(tool)
    }

    /// Claude Code's turn summary: each kind of call counted — files by their distinct paths — most
    /// first, ties in the order they came, calls of no known kind last as "Used a tool". Past three
    /// kinds it names two and counts the rest as tools.
    static func claudeTitle(_ items: [ConversationItem], localize: Localize) -> String {
        struct Group {
            let kind: String
            var calls = 0
            var paths: Set<String> = []
            var pathless = 0
            var count: Int { Self.fileKinds.contains(kind) ? paths.count + pathless : calls }
            static let fileKinds: Set<String> = ["read", "write", "edit", "delete_file", "notebook_edit"]
        }
        /// The calls counted so far: a group for each known kind, in the order the kinds came, and the
        /// calls of no known kind.
        struct Tally {
            var groups: [Group] = []
            var unknown = 0
            mutating func add(_ kind: String?, path: String?) {
                guard let kind else { unknown += 1; return }
                let index: Int
                if let known = groups.firstIndex(where: { $0.kind == kind }) {
                    index = known
                } else {
                    groups.append(Group(kind: kind))
                    index = groups.count - 1
                }
                groups[index].calls += 1
                if let path, !path.isEmpty { groups[index].paths.insert(path) } else { groups[index].pathless += 1 }
            }
        }
        var tally = Tally()
        for item in items {
            switch item.kind {
            case .command:
                tally.add("bash", path: nil)
            case let .fileChange(change):
                for row in change.rows {
                    let kind = switch row.kind {
                    case .add: "write"
                    case .delete: "delete_file"
                    case .update: "edit"
                    }
                    tally.add(kind, path: row.id)
                }
            case let .tool(tool):
                guard case let .activity(name) = tool.kind else { tally.add(nil, path: nil); continue }
                let arguments = ClaudeToolArguments(tool: name, input: tool.input)
                tally.add(claudeKind(of: name), path: arguments["file_path"] ?? arguments["notebook_path"])
            default:
                break
            }
        }
        var phrases = tally.groups.map {
            (phrase: claudePhrase($0.kind, count: $0.count, localize: localize), count: $0.count)
        }
        let unknown = tally.unknown
        if unknown > 0 {
            phrases.append((unknown == 1 ? localize("Used a tool")
                            : String(format: localize("Used %lld tools"), Int64(unknown)), unknown))
        }
        // A stable sort: most first, ties as they came.
        phrases = phrases.enumerated().sorted { lhs, rhs in
            lhs.element.count != rhs.element.count ? lhs.element.count > rhs.element.count : lhs.offset < rhs.offset
        }.map(\.element)
        let shown = phrases.count > 3 ? Array(phrases.prefix(2)) : phrases
        let words = shown.enumerated().map { index, phrase in index == 0 ? phrase.phrase : lowercasingFirst(phrase.phrase) }
            .joined(separator: ", ")
        let more = phrases.dropFirst(shown.count).reduce(0) { $0 + $1.count }
        guard more > 0 else { return words }
        return more == 1 ? String(format: localize("%@, and 1 more tool"), words)
            : String(format: localize("%@, and %lld more tools"), words, Int64(more))
    }

    private static func claudePhrase(_ kind: String, count: Int, localize: Localize) -> String {
        func counted(_ one: String, _ many: String) -> String {
            count == 1 ? localize(one) : String(format: localize(many), Int64(count))
        }
        switch kind {
        case "read": return counted("Read a file", "Read %lld files")
        case "write": return counted("Created a file", "Created %lld files")
        case "edit": return counted("Edited a file", "Edited %lld files")
        case "delete_file": return counted("Deleted a file", "Deleted %lld files")
        case "glob": return localize("Looked for files")
        case "grep": return localize("Searched files")
        case "web": return localize("Searched the web")
        case "web_fetch": return counted("Read a page", "Read %lld pages")
        case "bash": return counted("Ran a command", "Ran %lld commands")
        case "task": return counted("Ran an agent", "Ran %lld agents")
        case "notebook_edit": return counted("Edited a notebook", "Edited %lld notebooks")
        case "skill": return counted("Loaded a skill", "Loaded %lld skills")
        case "plan": return localize("Updated the plan")
        case "kill_bash": return counted("Stopped a command", "Stopped %lld commands")
        case "exit_plan_mode": return localize("Proposed a plan")
        case "tool_search": return localize("Loaded tools")
        default: return counted("Used a tool", "Used %lld tools")
        }
    }

    // MARK: Other harnesses

    /// Commands run, files read, files edited, searches and other tools, in the order they first
    /// appear: "Ran 2 commands, edited a file".
    static func plainTitle(_ items: [ConversationItem], localize: Localize) -> String {
        var order: [Category] = []
        var counts: [Category: Int] = [:]
        for category in items.compactMap(category(of:)) {
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += 1
        }
        return order.enumerated().map { index, category in
            let part = plainPhrase(for: category, count: counts[category] ?? 0, localize: localize)
            return index > 0 ? lowercasingFirst(part) : part
        }.joined(separator: ", ")
    }

    private static func plainPhrase(for category: Category, count: Int, localize: Localize) -> String {
        func counted(_ one: String, _ many: String) -> String {
            count == 1 ? localize(one) : String(format: localize(many), Int64(count))
        }
        switch category {
        case .command: return counted("Ran a command", "Ran %lld commands")
        case .read: return counted("Read a file", "Read %lld files")
        case .edit: return counted("Edited a file", "Edited %lld files")
        case .search: return localize("Searched files")
        case .other: return counted("Used a tool", "Used %lld tools")
        }
    }

    /// A later phrase continues the sentence: "Ran 2 commands, edited a file".
    private static func lowercasingFirst(_ phrase: String) -> String {
        guard let first = phrase.first, first.isUppercase, first.isASCII else { return phrase }
        return first.lowercased() + phrase.dropFirst()
    }
}
