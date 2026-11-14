import Foundation
import Markdown
import YardletRemote

/// The files a task's conversation names, which a paired device opens wherever they are (docs/REMOTE_PROTOCOL.md
/// §15.22), as the Mac's window opens them from that conversation: the files the agent's own messages link or name in
/// code, the files its calls read, wrote, edited or looked at and the files its changes touched, the pictures and files
/// attached to the conversation, and the files an MCP result links. A path that only a tool's output holds (a command's
/// output, a page's text) is none of these, so what a page says cannot make a file readable.
///
/// Kept by turn: an update reads again only the turns the projection did not keep as they were
/// (`ConversationTurn.isUnchanged(from:)`), off the main actor, so a long conversation costs a request one comparison a
/// turn and the turns that changed. One update runs at a time; the next waits for it and starts from what it left.
@MainActor
final class RemoteNamedFileIndex {
    private struct Entry {
        var turn: ConversationTurn
        var paths: [String]
    }

    private var entries: [String: Entry] = [:]
    private(set) var files = RemoteNamedFiles()
    /// How many turns were read so far: an update reads only the turns that changed.
    private(set) var turnsRead = 0
    private var updating: Task<Void, Never>?

    /// The files `presentation` names, the task's working folder `folder` reading a relative path and `home` a `~`.
    func files(of presentation: ConversationPresentation, folder: URL, home: String) async -> RemoteNamedFiles {
        while let updating { await updating.value }
        var changed: [ConversationTurn] = []
        for turn in presentation.turns {
            if let entry = entries[turn.id], turn.isUnchanged(from: entry.turn) { continue }
            changed.append(turn)
        }
        let known = presentation.turns.count - changed.count(where: { entries[$0.id] == nil })
        guard !changed.isEmpty || known != entries.count else { return files }
        let ids = Set(presentation.turns.map(\.id))
        let reading = Task.detached(priority: .userInitiated) { [changed, harness = presentation.harness,
                                                                 folder = folder.path(percentEncoded: false)] in
            changed.map { ($0, RemoteConversationFileNames.paths(in: $0, harness: harness, folder: folder, home: home)) }
        }
        let task = Task { [weak self] in
            let read = await reading.value
            self?.apply(read, keeping: ids)
        }
        updating = task
        await task.value
        if updating == task { updating = nil }
        return files
    }

    private func apply(_ read: [(ConversationTurn, [String])], keeping ids: Set<String>) {
        for (id, entry) in entries where !ids.contains(id) {
            entry.paths.forEach { files.remove($0) }
            entries[id] = nil
        }
        turnsRead += read.count
        for (turn, paths) in read {
            entries[turn.id]?.paths.forEach { files.remove($0) }
            paths.forEach { files.insert($0) }
            entries[turn.id] = Entry(turn: turn, paths: paths)
        }
    }
}

/// What one turn of a conversation names (`RemoteNamedFileIndex`), each path as `RemoteNamedFiles` keeps it.
enum RemoteConversationFileNames {
    /// The tool arguments that name the one file a call reads, writes or edits: Claude Code's (and the harnesses that
    /// name their calls' arguments as it does), Gemini CLI's `read_file` and OpenCode's.
    static let targetArguments = ["file_path", "notebook_path", "absolute_path", "filePath"]

    static func paths(in turn: ConversationTurn, harness: HarnessKind, folder: String, home: String) -> [String] {
        var named: [String] = []
        for item in turn.prompt + turn.notices + turn.work + turn.answers {
            switch item.kind {
            case let .userMessage(_, images):
                // The pictures the message carries as its own inputs. Files a Codex message lists in its text
                // (`promptAttachments`) are the sender's words, which a paired device writes as freely as anyone.
                named += files(images)
            case let .answer(text, _), let .commentary(text, _), let .proposedPlan(text, _):
                named += links(in: text, harness: harness, folder: URL(filePath: folder, directoryHint: .isDirectory))
            case let .fileChange(change):
                for row in change.rows {
                    named.append(row.id)
                    if let moved = row.change["kind"]?["move_path"]?.stringValue { named.append(moved) }
                }
                named += change.handoffs.compactMap { $0.verifiedURL?.path(percentEncoded: false) }
            case let .tool(tool):
                named += targets(of: tool)
            default:
                break
            }
        }
        return Array(Set(named.compactMap { RemoteNamedFiles.path($0, folder: folder, home: home) }))
    }

    /// The files a call chose: the file its arguments name, the files its change touched, the pictures it looked at or
    /// made, and the files its MCP result links. An MCP tool's arguments are its server's, not a file the call reads.
    static func targets(of tool: ConversationTool) -> [String] {
        var named: [String] = []
        if case let .activity(name) = tool.kind, !name.hasPrefix("mcp__") { named += target(of: name, input: tool.input) }
        if case .imageView = tool.kind { named.append(tool.name) }
        named += ([tool.diff].compactMap { $0 } + tool.diffs).map(\.path)
        named += files(tool.images)
        for block in tool.mcpResult?.blocks ?? [] {
            if case let .resourceLink(_, link) = block, let url = link.openableURL, url.isFileURL {
                named.append(url.path(percentEncoded: false))
            }
        }
        return named
    }

    /// The file a call's arguments name: a JSON object's file argument, or the leading line of Claude Code's own file
    /// tools' arguments, which name their file first (`ClaudeEventProjector.toolInputFields`). Nothing else of the
    /// arguments is read, so text a call writes into a file is not taken for its target.
    static func target(of tool: String, input: String?) -> [String] {
        guard let input, !input.isEmpty else { return [] }
        if input.first == "{", let data = input.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return targetArguments.compactMap { object[$0]?.stringValue }
        }
        guard ClaudeFileTouchScanner.editTools.union(ClaudeFileTouchScanner.readTools).contains(tool),
              let lead = ClaudeEventProjector.toolInputFields[tool]?.first, targetArguments.contains(lead),
              let line = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return [] }
        return [String(line)]
    }

    /// The files a message's Markdown opens, as the window reads it (`TranscriptMarkdownDocument`): its links and
    /// pictures that are files, and the paths its code spans name (`TranscriptFileReference`); in a Codex message also
    /// its file citations, review comments and visualizations. A link's line (`:12`, `#L12`) is taken off.
    static func links(in text: String, harness: HarnessKind, folder: URL, depth: Int = 0) -> [String] {
        guard TranscriptMarkdownDialect(messagesOf: harness) == .codex, depth < 8 else { return markdownLinks(in: text) }
        return CodexMessageDirectives.blocks(text).flatMap { block -> [String] in
            switch block {
            case let .markdown(markdown): markdownLinks(in: markdown)
            case let .details(_, _, body): links(in: body, harness: harness, folder: folder, depth: depth + 1)
            case let .reviewComments(comments): comments.compactMap { $0.link(relativeTo: folder)?.path(percentEncoded: false) }
            case let .visualization(visualization): [visualization.file]
            case .suggestedTask: []
            }
        }
    }

    private static func markdownLinks(in text: String) -> [String] {
        var named: [String] = []
        func visit(_ markup: any Markup, depth: Int) {
            guard depth < 64 else { return }
            switch markup {
            case let link as Markdown.Link:
                if let destination = link.destination { named += destinationPaths(destination) }
            case let image as Markdown.Image:
                if let source = image.source { named += destinationPaths(source) }
            case let code as InlineCode:
                if let reference = TranscriptFileReference.path(in: code.code) { named.append(reference.path) }
                return
            case is CodeBlock, is HTMLBlock:
                return
            default:
                break
            }
            for child in markup.children { visit(child, depth: depth + 1) }
        }
        visit(Document(parsing: text, options: [.disableSmartOpts]), depth: 0)
        return named
    }

    /// The file a link's destination opens, as the window resolves it (`TranscriptInlineContent`): a `file:` address,
    /// or a path (absolute, `~/…`, or relative to the task's folder), and the same without a line Codex writes after it
    /// (`file.swift:12`). An anchor in the message, a web page or another app's link is no file.
    static func destinationPaths(_ destination: String) -> [String] {
        let escaped = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        guard !escaped.hasPrefix("#"), let encoded = escaped.addingPercentEncoding(withAllowedCharacters: linkCharacters),
              let url = URL(string: encoded) else { return [] }
        let path: String
        switch url.scheme?.lowercased() {
        case nil: path = url.path(percentEncoded: false)
        case "file" where ["", "localhost"].contains(url.host()?.lowercased() ?? ""): path = url.path(percentEncoded: false)
        default: return []
        }
        guard !path.isEmpty else { return [] }
        guard let line = path.firstRange(of: /:[0-9]+(:[0-9]+)?$/) else { return [path] }
        return [path, String(path[..<line.lowerBound])]
    }

    private static let linkCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    private static func files(_ images: [TranscriptImageAttachment]) -> [String] {
        images.compactMap { $0.url?.isFileURL == true ? $0.url?.path(percentEncoded: false) : nil }
    }
}
