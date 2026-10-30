import Foundation

/// The words of one status line: what was done (`verb`, drawn muted) and what it was done to, before
/// and after it. The provider apps word a line as a sentence with the verb marked — Codex's
/// `<verb>Read</verb> {path}`, and in Korean the path first and the verb after it — so a localized template marks
/// the verb the same way and the words fall where the language puts them.
struct ConversationLineWords: Equatable, Sendable {
    var leading: String
    var verb: String
    var trailing: String

    init(leading: String = "", verb: String, trailing: String = "") {
        self.leading = leading
        self.verb = verb
        self.trailing = trailing
    }

    /// The line read as one sentence, as assistive apps and tests read it.
    var text: String {
        [leading, verb, trailing].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Fills `template`'s `%@` (or positional `%1$@`) with `arguments`. The template marks its verb
    /// with `<verb>…</verb>`; one without the mark is all verb. Each part is filled on its own, so
    /// an argument that happens to contain the mark stays text.
    static func filling(_ template: String, _ arguments: [String] = []) -> ConversationLineWords {
        let open = "<verb>", close = "</verb>"
        guard let start = template.range(of: open),
              let end = template.range(of: close, range: start.upperBound..<template.endIndex) else {
            return ConversationLineWords(verb: fill(template, arguments))
        }
        // A part with an unnumbered `%@` takes the arguments in order, after any the parts before it
        // took; numbered ones name theirs.
        var used = 0
        func part(_ text: Substring) -> String {
            let text = String(text)
            let unnumbered = text.components(separatedBy: "%@").count - 1
            let filled = fill(text, Array(arguments.dropFirst(text.contains("$@") ? 0 : used)))
            used += unnumbered
            return filled.trimmingCharacters(in: .whitespaces)
        }
        return ConversationLineWords(
            leading: part(template[..<start.lowerBound]),
            verb: part(template[start.upperBound..<end.lowerBound]),
            trailing: part(template[end.upperBound...])
        )
    }

    private static func fill(_ text: String, _ arguments: [String]) -> String {
        guard text.contains("%") else { return text }
        return String(format: text, arguments: arguments.map { $0 as NSString })
    }
}

/// What the Codex App Server parsed a command into (`CommandAction`): a file it read, files it
/// listed or searched, or a command it did not recognize. Each names the part of the command it
/// came from; the server already took that part out of its `/bin/zsh -lc '…'` wrapper.
enum ConversationCommandAction: Equatable, Sendable {
    case read(name: String, path: String?, command: String)
    case listFiles(path: String?, command: String)
    case search(query: String?, path: String?, command: String)
    case unknown(command: String)

    /// `commandActions`, in order; an action of a type Yardlet does not know is an unknown one.
    static func actions(from values: [JSONValue]) -> [ConversationCommandAction] {
        values.compactMap { value in
            let command = value["command"]?.stringValue ?? ""
            let path = value["path"]?.stringValue
            switch value["type"]?.stringValue {
            case "read":
                return .read(name: value["name"]?.stringValue ?? path ?? "", path: path, command: command)
            case "listFiles":
                return .listFiles(path: path, command: command)
            case "search":
                return .search(query: value["query"]?.stringValue, path: path, command: command)
            case nil:
                return nil
            default:
                return .unknown(command: command)
            }
        }
    }

    /// The Codex app reads, searches and lists files as exploring.
    var isExploration: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// The command a Codex command item ran, without the login-shell wrapper Codex puts around it.
enum CodexShellCommand {
    /// The shells whose `-lc` wrapper the Codex app takes off (`/bin/zsh`, `/bin/bash`, `zsh`, `bash`).
    private static let shells = ["/bin/zsh", "/bin/bash", "zsh", "bash"]

    /// The script inside `<shell> -lc <one shell word>`, exactly that shape: one of the four shells,
    /// one space, `-lc`, one space, and a single word that is all literal text — single-quoted,
    /// double-quoted without expansions, or plain characters, in any concatenation. Anything else
    /// (another flag, a second word, an unclosed quote, `$`, a backtick) is not the wrapper and has
    /// no inner command.
    static func innerScript(of command: String) -> String? {
        for shell in shells {
            let prefix = shell + " -lc "
            guard command.hasPrefix(prefix) else { continue }
            return literalWord(command.dropFirst(prefix.count))
        }
        return nil
    }

    /// What a line shows of a command: its inner script when it has the wrapper, else itself.
    static func displayed(_ command: String) -> String {
        innerScript(of: command) ?? command
    }

    /// The text of `word` when it is one whole shell word without expansions.
    private static func literalWord(_ word: Substring) -> String? {
        guard !word.isEmpty else { return nil }
        var result = ""
        var index = word.startIndex
        while index < word.endIndex {
            let character = word[index]
            switch character {
            case "'":
                guard let close = word[word.index(after: index)...].firstIndex(of: "'") else { return nil }
                result += word[word.index(after: index)..<close]
                index = word.index(after: close)
            case "\"":
                var cursor = word.index(after: index)
                var closed = false
                while cursor < word.endIndex {
                    let inner = word[cursor]
                    if inner == "\"" {
                        closed = true
                        break
                    }
                    if inner == "$" || inner == "`" { return nil }
                    if inner == "\\" {
                        let next = word.index(after: cursor)
                        guard next < word.endIndex else { return nil }
                        let escaped = word[next]
                        switch escaped {
                        case "$", "`", "\"", "\\": result.append(escaped)
                        case "\n": break
                        default: result.append("\\"); result.append(escaped)
                        }
                        cursor = word.index(after: next)
                        continue
                    }
                    result.append(inner)
                    cursor = word.index(after: cursor)
                }
                guard closed else { return nil }
                index = word.index(after: cursor)
            case "\\":
                let next = word.index(after: index)
                guard next < word.endIndex else { return nil }
                if word[next] != "\n" { result.append(word[next]) }
                index = word.index(after: next)
            default:
                guard plainCharacters.contains(character) else { return nil }
                result.append(character)
                index = word.index(after: index)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static let plainCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    )
}

/// The status-line words of each kind of line, in the words each provider's own app uses: Codex's
/// command rows from what the App Server parsed a command into, Claude Code's tool rows from the
/// call's own arguments. Other harnesses keep Yardlet's words.
enum ConversationLineWording {
    typealias Localize = (String) -> String

    /// The most of a command a line holds: more is never seen in one line.
    private static let subjectLimit = 400

    // MARK: Commands

    /// One line's words for each thing the command did. A Codex command parsed into several (two
    /// files read in one `&&`) reads as one line each, as the Codex app splits it into rows.
    static func command(
        _ command: ConversationCommand,
        phase: ConversationItemPhase,
        harness: HarnessKind,
        localize: Localize = { L10n.string($0) }
    ) -> [ConversationLineWords] {
        switch harness {
        case .codex:
            let actions = command.actions.isEmpty ? [.unknown(command: command.command)] : command.actions
            return actions.map { codex($0, phase: phase, localize: localize) }
        case .claudeCode:
            return [claudeShell(command, phase: phase, localize: localize)]
        default:
            return [ConversationLineWords(verb: plainCommandVerb(phase, localize: localize),
                                          trailing: firstLine(command.command))]
        }
    }

    /// The line already shows the whole command, so its details need not repeat it.
    static func showsWholeCommand(_ command: ConversationCommand, words: [ConversationLineWords]) -> Bool {
        words.count == 1 && (words[0].trailing == command.command || words[0].leading == command.command)
    }

    /// A Codex command row (`toolSummaryForCmd`, `localConversation.toolActivity.active.read`). A
    /// read the app draws only once finished; running, it reads as the turn's active line does.
    static func codex(
        _ action: ConversationCommandAction,
        phase: ConversationItemPhase,
        localize: Localize = { L10n.string($0) }
    ) -> ConversationLineWords {
        let running = phase == .running
        func words(_ key: String, _ arguments: String...) -> ConversationLineWords {
            ConversationLineWords.filling(localize(key), arguments)
        }
        switch action {
        case let .read(name, path, _):
            let target = codexPath(name.isEmpty ? path ?? "" : name)
            return words(running ? "codex.row.reading" : "codex.row.read", target)
        case let .search(query, path, _):
            let query = query.flatMap { $0.isEmpty ? nil : $0 }
            let path = path.map(codexPath).flatMap { $0.isEmpty ? nil : $0 }
            switch (query, path) {
            case let (query?, path?):
                return words(running ? "codex.row.searchingForIn" : "codex.row.searchedForIn", query, path)
            case let (query?, nil):
                return words(running ? "codex.row.searchingFor" : "codex.row.searchedFor", query)
            default:
                return words(running ? "codex.row.searchingFiles" : "codex.row.searchedFiles")
            }
        case let .listFiles(path, _):
            if let path = path.map(codexPath), !path.isEmpty {
                return words(running ? "codex.row.listingIn" : "codex.row.listedIn", path)
            }
            return words(running ? "codex.row.listing" : "codex.row.listed")
        case let .unknown(command):
            // The App Server already unwrapped the command it parsed; a command it sent no actions
            // for, or one the model wrapped itself, comes off its wrapper here.
            let shown = oneLine(CodexShellCommand.displayed(command))
            switch (phase, shown.isEmpty) {
            case (.running, false): return words("codex.row.running", shown)
            case (.running, true): return words("codex.row.runningCommand")
            case (.stopped, false): return words("codex.row.stopped", shown)
            case (.stopped, true): return words("codex.row.stoppedCommand")
            case (_, false): return words("codex.row.ran", shown)
            case (_, true): return words("codex.row.ranCommand")
            }
        }
    }

    /// A path as a Codex row names it: trimmed, without a leading `./`, with forward slashes.
    static func codexPath(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("./") { text.removeFirst(2) }
        return text.replacingOccurrences(of: "\\", with: "/")
    }

    /// Claude Code's shell row: the call's description, its first verb conjugated ("Run tests" reads
    /// "Running tests", then "Ran tests"), or "Ran" and the command when it gave none.
    private static func claudeShell(
        _ command: ConversationCommand,
        phase: ConversationItemPhase,
        localize: Localize
    ) -> ConversationLineWords {
        if let description = command.description,
           let described = claudeDescribed(description, phase: phase, failedVerb: "claude.bash.failed",
                                           localize: localize) {
            return described
        }
        let shown = oneLine(firstLine(command.command))
        return ConversationLineWords(verb: localize("claude.bash.\(claudeState(phase))"),
                                     trailing: shown.isEmpty ? localize("claude.bash.aCommand") : shown)
    }

    /// A row Claude Code titles with the description its call gave (`runningLabel`, `doneLabel`,
    /// `failedLabel`): conjugated when it starts with a verb Claude Code knows, else as written. A
    /// failed one without such a verb reads its failed verb and the description.
    private static func claudeDescribed(
        _ description: String,
        phase: ConversationItemPhase,
        failedVerb: String,
        localize: Localize
    ) -> ConversationLineWords? {
        let description = oneLine(description)
        guard !description.isEmpty else { return nil }
        let forms = ClaudeDescriptionVerbs.forms(of: description)
        switch phase {
        case .running: return ConversationLineWords(verb: "", trailing: forms?.running ?? description)
        case .completed: return ConversationLineWords(verb: "", trailing: forms?.done ?? description)
        case .stopped: return ConversationLineWords(verb: "", trailing: description)
        case .failed:
            if let forms { return ConversationLineWords.filling(localize("claude.failedTo"), [forms.infinitive]) }
            return ConversationLineWords(verb: localize(failedVerb), trailing: description)
        }
    }

    /// A stopped call reads as a finished one; its line marks it stopped.
    private static func claudeState(_ phase: ConversationItemPhase) -> String {
        switch phase {
        case .running: "running"
        case .failed: "failed"
        case .completed, .stopped: "done"
        }
    }

    /// Yardlet's own words for a command of any other harness.
    private static func plainCommandVerb(_ phase: ConversationItemPhase, localize: Localize) -> String {
        switch phase {
        case .running: localize("Running")
        case .completed: localize("Ran")
        case .failed: localize("Failed to run")
        case .stopped: localize("Stopped")
        }
    }

    // MARK: Other calls

    /// A call's line: Claude Code's own words for its tools; for any other harness the kind of
    /// call and what it is about, a path read from the task's folder.
    static func tool(
        _ tool: ConversationTool,
        phase: ConversationItemPhase,
        harness: HarnessKind,
        workspaceURL: URL?,
        localize: Localize = { L10n.string($0) }
    ) -> ConversationLineWords {
        if harness == .claudeCode, let words = claudeTool(tool, phase: phase, localize: localize) {
            return words
        }
        let verb = tool.kind.label
        let subject = tool.name.isEmpty || tool.name == verb ? "" : relative(tool.name, to: workspaceURL)
        switch tool.kind {
        // The image itself shows at the line's end; the words say what Codex did with it, as the Codex
        // app's "Viewed an image" does.
        case .imageView:
            if subject.isEmpty { return ConversationLineWords(verb: localize("codex.row.viewedAnImage")) }
            return .filling(localize(phase == .running ? "codex.row.viewingImage" : "codex.row.viewedImage"), [subject])
        case .imageGeneration:
            if phase == .running { return ConversationLineWords(verb: localize("codex.row.generatingImage")) }
            return ConversationLineWords(verb: localize("codex.row.generatedImage"), trailing: subject)
        default:
            return ConversationLineWords(verb: verb, trailing: subject)
        }
    }

    /// A path inside the task's folder, from the folder.
    private static func relative(_ subject: String, to workspaceURL: URL?) -> String {
        guard let workspaceURL else { return subject }
        let root = workspaceURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return subject.hasPrefix(prefix) ? String(subject.dropFirst(prefix.count)) : subject
    }

    // MARK: Claude Code's tools

    /// A Claude Code tool row (`TurnStatusStep`): its verb for the call's state and what it names —
    /// the file's name, the search's pattern, the fetched URL, an MCP tool's `server: tool`. Nil for
    /// a call that is not one of Claude Code's tools.
    static func claudeTool(
        _ tool: ConversationTool,
        phase: ConversationItemPhase,
        localize: Localize = { L10n.string($0) }
    ) -> ConversationLineWords? {
        guard case let .activity(name) = tool.kind else { return nil }
        let arguments = ClaudeToolArguments(tool: name, input: tool.input)
        // Claude Code puts its verb before what the call names, in every language.
        func words(_ stem: String, _ target: String?) -> ConversationLineWords {
            ConversationLineWords(verb: localize("claude.\(stem).\(claudeState(phase))"),
                                  trailing: target.map(oneLine) ?? "")
        }
        switch name {
        case "Read":
            return words("read", arguments["file_path"].map(fileName))
        case "Write":
            return words("write", arguments["file_path"].map(fileName))
        case "Edit", "MultiEdit":
            return words("edit", arguments["file_path"].map(fileName))
        case "NotebookEdit":
            return words("edit", arguments["notebook_path"].map(fileName))
        case "Grep", "Glob":
            return words("search", arguments["pattern"])
        case "LS":
            return words("list", arguments["path"])
        case "WebFetch":
            return words("fetch", arguments["url"])
        case "WebSearch":
            return words("webSearch", arguments["query"])
        case "Task", "Agent":
            if let description = arguments["description"],
               let described = claudeDescribed(description, phase: phase, failedVerb: "claude.agent.failed",
                                               localize: localize) {
                return described
            }
            return words("agent", nil)
        case "Skill":
            return words("skill", arguments["skill"].map { "/" + $0 })
        case "TodoWrite":
            if phase != .running, arguments.isEmptyList("todos") {
                return ConversationLineWords(verb: localize("claude.todos.cleared"))
            }
            return words("todos", nil)
        default:
            let label = mcpLabel(name) ?? name
            return ConversationLineWords.filling(
                localize(phase == .running ? "claude.using" : "claude.used"), [label]
            )
        }
    }

    /// Claude Code's name for an MCP tool, `server: tool name` (`mcp__github__create_issue` reads
    /// "github: create issue"). A server named by an ID alone, as the Claude app names its claude.ai
    /// connectors, says nothing, so the tool's own name stands alone ("slack read channel").
    static func mcpLabel(_ name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        // A Yardlet connector's tool reads as the connector's: "Linear: create issue".
        if let label = ConnectorToolLabels.shared.label(forClaudeTool: name) {
            return "\(label.connector): \(ConnectorToolLabels.spaced(label.tool))"
        }
        var rest = String(name.dropFirst(5))
        while rest.hasSuffix("_") { rest.removeLast() }
        guard let split = rest.range(of: "__", options: .backwards), split.lowerBound > rest.startIndex else {
            return nil
        }
        let tool = String(rest[split.upperBound...])
        let server = String(rest[..<split.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !tool.isEmpty, !server.isEmpty else { return nil }
        func spaced(_ text: String) -> String {
            text.replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
        }
        if UUID(uuidString: server) != nil { return spaced(tool) }
        return "\(spaced(server)): \(spaced(tool))"
    }

    // MARK: Text

    /// A file's name from its path, as Claude Code names the file a call read.
    static func fileName(_ path: String) -> String {
        var trimmed = path
        if trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Text on one line, as a line that does not wrap shows it: each run of spaces and line breaks
    /// is one space.
    static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > subjectLimit else { return collapsed }
        return String(collapsed.prefix(subjectLimit)) + "…"
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}

/// A Claude Code call's arguments, read back from the text `ClaudeEventProjector` wrote for its
/// input: the leading field as it was, then `name: value` lines, or the whole object as JSON for a
/// tool without a known shape.
struct ClaudeToolArguments {
    private var values: [String: String] = [:]
    private var emptyLists: Set<String> = []

    /// `leadText`, when known (a Bash call's command), is the leading field exactly: the fields are
    /// read only after it.
    init(tool: String, input: String?, lead leadText: String? = nil) {
        guard let input, !input.isEmpty else { return }
        // A tool without a known shape, or a known one missing its leading field, is the whole
        // object as JSON.
        if let object = Self.jsonObject(input), !object.isEmpty {
            for (key, value) in object {
                if let text = value.stringValue { values[key] = text }
                if case let .array(items) = value, items.isEmpty { emptyLists.insert(key) }
            }
            return
        }
        guard let fields = ClaudeEventProjector.toolInputFields[tool], let lead = fields.first else { return }
        let blocks: [String]
        if let leadText, !leadText.isEmpty, input.hasPrefix(leadText) {
            values[lead] = ConversationLineWording.firstLine(leadText)
            blocks = String(input.dropFirst(leadText.count)).components(separatedBy: "\n\n").filter { !$0.isEmpty }
        } else {
            let all = input.components(separatedBy: "\n\n")
            values[lead] = all.first.map { ConversationLineWording.firstLine($0) }
            blocks = Array(all.dropFirst())
        }
        // The named fields close the text, a block of `name: value` lines and a `name:` block for
        // each value of several lines: read them from the end until a block is neither.
        for block in blocks.reversed() {
            let lines = block.components(separatedBy: "\n")
            if let first = lines.first, first.hasSuffix(":"), lines.count > 1, Self.isFieldName(first.dropLast()) {
                let name = String(first.dropLast())
                if values[name] == nil, name != lead { values[name] = lines.dropFirst().joined(separator: "\n") }
                continue
            }
            let named = lines.compactMap { line -> (String, String)? in
                guard let colon = line.range(of: ": "), Self.isFieldName(line[..<colon.lowerBound]) else { return nil }
                return (String(line[..<colon.lowerBound]), String(line[colon.upperBound...]))
            }
            guard named.count == lines.count else { break }
            for (name, value) in named where values[name] == nil && name != lead { values[name] = value }
        }
    }

    private static func isFieldName(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "_") }
    }

    subscript(_ name: String) -> String? { values[name] }

    func isEmptyList(_ name: String) -> Bool { emptyLists.contains(name) }

    /// A call's input read as JSON, kept once read when it is short: a running turn reads every
    /// call's input again each time it streams. Long inputs (a file `Write` gives) are read anew.
    private static func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard text.first == "{" else { return nil }
        let keeps = text.utf8.count <= ParsedInputs.longestKept
        if keeps, let kept = parsed.object(for: text) { return kept.object }
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            if keeps { parsed.keep(nil, for: text) }
            return nil
        }
        if keeps { parsed.keep(value.objectValue, for: text) }
        return value.objectValue
    }

    /// Inputs already read, at most `limit` of them; past that it starts over.
    private final class ParsedInputs: @unchecked Sendable {
        struct Entry { let object: [String: JSONValue]? }
        static let longestKept = 4_096
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private let limit = 2_048

        func object(for text: String) -> Entry? { lock.withLock { entries[text] } }

        func keep(_ object: [String: JSONValue]?, for text: String) {
            lock.withLock {
                if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
                entries[text] = Entry(object: object)
            }
        }
    }

    private static let parsed = ParsedInputs()
}

extension CodexNoticeItem {
    /// The notice's line, as the conversation shows it (and the phone remote reads it).
    var displayMessage: String {
        switch kind {
        case .modelRerouted: L10n.format("Your request was routed to %@.", message)
        case .warning, .configWarning, .deprecationNotice: message
        }
    }
}

extension ConversationTool.Kind {
    /// The badge beside a call's title: the provider's own tool kind, or what Codex calls the item.
    var label: String {
        switch self {
        case let .activity(kind): kind
        case .mcp: L10n.string("MCP tool")
        case .dynamic: L10n.string("Tool call")
        case .webSearch: L10n.string("Web search")
        case .imageView, .imageGeneration: L10n.string("Image")
        case .sleep: L10n.string("Sleep")
        case .review: L10n.string("Review")
        case .hook: L10n.string("Hook")
        case let .unknown(type): type ?? L10n.string("Unknown item")
        }
    }
}
