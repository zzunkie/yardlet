import Foundation

// The directives the Codex app draws in a message as something other than their text (Codex desktop
// app 26.1007, bundle `com.openai.codex`). Its conversation
// Markdown reads remark-directive syntax — `:name[label]{attributes}` in a line, `::name[label]{…}` as
// a line of its own, `:::name{…}` … `:::` around lines — and draws each name its table knows
// (`$ol` in `app-initial`, overridden for a local conversation's message by `xx` in
// `sites-end-resource`):
// - `:codex-file-citation{path=… line_range_start=…}` and `【F:path†L3-L5】` as a link to the file
//   at its line, named "file (line 3)" (`zol`, `wol`, `CGn`);
// - `:codex-followup[phrase]{prompt=…}` as its phrase (`hx`, while its clickable form is switched off);
// - `::code-comment{…}` lines, consecutive ones together, as a card of review comments (`bb`, `rb`);
// - `:::task-stub{title=…}` as a "Suggested task" card whose "Use suggestion" opens a new task with
//   its prompt (`qol`);
// - `:::github-details{summary=… open=…}` as a disclosure of its Markdown (`Hol`);
// - `::codex-inline-vis{file=…}` as an inline visualization (`Erl`), which Yardlet cannot run and
//   draws as a card that says so, as the Codex CLI does.
// The directives it acts on rather than draws are `CodexDirectiveMarkup`'s. Everything here applies to
// a Codex message only; code blocks and code spans stay literal, and a name the app does not draw
// stays as its text.

extension TranscriptMarkdownDialect {
    /// How a harness's messages read: a Codex message also holds the directives the Codex app draws.
    init(messagesOf harness: HarnessKind) {
        self = harness == .codex ? .codex : .standard
    }

    /// What "Copy response" copies of a message read this way: a Codex message as the app copies it.
    func copyText(_ text: String) -> String {
        self == .codex ? CodexMessageDirectives.copyText(text) : text
    }
}

/// A directive's name, label and attributes as remark-directive writes them.
struct CodexDirectiveSyntax: Equatable, Sendable {
    let name: String
    /// The `[label]`; nil when there is none.
    let label: String?
    let attributes: [String: String]
    /// Where the directive ends in the text it was read from.
    let end: String.Index

    /// Reads `name[label]{attributes}` from `start`, the character after the colons. A directive has
    /// a label or attributes or both; an unclosed label, quote or brace is no directive.
    static func read(_ text: String, from start: String.Index) -> Self? {
        var index = start
        guard index < text.endIndex, text[index].isASCII, text[index].isLetter else { return nil }
        while index < text.endIndex, isNameCharacter(text[index]) { index = text.index(after: index) }
        let name = String(text[start..<index])
        var label: String?
        if index < text.endIndex, text[index] == "[" {
            var cursor = text.index(after: index)
            var value = ""
            var closed = false
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "\n" { break }
                if character == "\\", text.index(after: cursor) < text.endIndex {
                    value.append(character)
                    cursor = text.index(after: cursor)
                    value.append(text[cursor])
                } else if character == "]" {
                    closed = true
                    break
                } else {
                    value.append(character)
                }
                cursor = text.index(after: cursor)
            }
            guard closed else { return nil }
            label = value
            index = text.index(after: cursor)
        }
        var attributes: [String: String] = [:]
        if index < text.endIndex, text[index] == "{" {
            guard let (parsed, close) = readAttributes(text, from: text.index(after: index)) else { return nil }
            attributes = parsed
            index = text.index(after: close)
        } else if label == nil {
            return nil
        }
        return Self(name: name, label: label, attributes: attributes, end: index)
    }

    /// The attributes up to the closing brace: `key="value"`, `key='value'`, `key=value`, a bare
    /// `key` (true), `#id` and `.class`, apart by spaces. A quoted value may hold braces and `\"`.
    private static func readAttributes(_ text: String, from start: String.Index) -> ([String: String], String.Index)? {
        var attributes: [String: String] = [:]
        var index = start
        func skipSpaces() { while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) } }
        while true {
            skipSpaces()
            guard index < text.endIndex, text[index] != "\n" else { return nil }
            if text[index] == "}" { return (attributes, index) }
            var key = ""
            if text[index] == "#" || text[index] == "." {
                key = text[index] == "#" ? "id" : "class"
                index = text.index(after: index)
                var value = ""
                while index < text.endIndex, !" \t\n}".contains(text[index]) { value.append(text[index]); index = text.index(after: index) }
                attributes[key] = value
                continue
            }
            while index < text.endIndex, !" \t\n=}".contains(text[index]) { key.append(text[index]); index = text.index(after: index) }
            guard !key.isEmpty else { return nil }
            guard index < text.endIndex, text[index] == "=" else {
                attributes[key] = "true"
                continue
            }
            index = text.index(after: index)
            guard index < text.endIndex else { return nil }
            var value = ""
            if text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                var closed = false
                while index < text.endIndex {
                    let character = text[index]
                    if character == "\n" { break }
                    if character == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                        value.append(text[index])
                    } else if character == quote {
                        closed = true
                        index = text.index(after: index)
                        break
                    } else {
                        value.append(character)
                    }
                    index = text.index(after: index)
                }
                guard closed else { return nil }
            } else {
                while index < text.endIndex, !" \t\n}".contains(text[index]) { value.append(text[index]); index = text.index(after: index) }
            }
            attributes[key] = value
        }
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }

    /// The directive a whole line is: up to three spaces, `colons` colons and no more, the directive,
    /// then nothing but spaces.
    static func wholeLine(_ line: String, colons: Int) -> Self? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let marker = String(repeating: ":", count: colons)
        let body = line.dropFirst(indent.count)
        guard body.hasPrefix(marker), !body.dropFirst(colons).hasPrefix(":") else { return nil }
        guard let directive = read(line, from: body.index(body.startIndex, offsetBy: colons)),
              line[directive.end...].allSatisfy(\.isWhitespace) else { return nil }
        return directive
    }

    /// A container's closing line: up to three spaces, three or more colons, then nothing but spaces.
    static func isContainerClose(_ line: String) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return false }
        let colons = body.prefix { $0 == ":" }
        return colons.count >= 3 && body.dropFirst(colons.count).allSatisfy(\.isWhitespace)
    }

    /// A container's opening line, `:::name…`, whether or not this reads it as a directive.
    static func opensContainer(_ line: String) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3, body.hasPrefix(":::") else { return false }
        let rest = body.drop { $0 == ":" }
        return rest.first.map { $0.isASCII && $0.isLetter } ?? false
    }
}

/// A file a message cites: `:codex-file-citation{…}` or `【F:path†L3-L5】`.
struct CodexFileCitation: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A file on this Mac, opened in the task's file viewer.
        case file
        /// A web address (a Google Drive document among them), opened as any web link is.
        case web(URL)
        /// A live document session of the Codex app, which Yardlet has no viewer for.
        case artifactSession
    }

    let path: String
    let target: Target
    /// The `label` or `title` the citation names itself by.
    let label: String?
    let lineStart: Int?
    let lineEnd: Int?
    /// Where in a document the citation points, as the Codex app names it ("page 3", "slide 2").
    let documentLocation: String?

    /// The Codex app's reading of the attributes (`Lxr`): a path, and lines or a document place.
    init?(attributes: [String: String]) {
        guard let path = attributes["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let label = Self.text(attributes["label"]) ?? Self.text(attributes["title"])
        let isWeb = path.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
        if attributes["mode"] == "live" {
            guard !isWeb, ["workbook", "presentation"].contains(attributes["artifact_kind"]) else { return nil }
            target = .artifactSession
        } else if isWeb {
            guard let url = URL(string: path) else { return nil }
            target = .web(url)
        } else {
            target = .file
        }
        self.path = path
        self.label = label
        lineStart = Self.positive(attributes["line_range_start"] ?? attributes["lineRangeStart"])
        lineEnd = Self.positive(attributes["line_range_end"] ?? attributes["lineRangeEnd"])
        documentLocation = Self.documentLocation(attributes, label: label)
    }

    /// `【F:path†L3】` or `【F:path†L3-L5】`; without `F:` the path must be absolute (`CGn`, `oGn`).
    init?(bracketPath: String, lineStart: Int, lineEnd: Int?) {
        let hasPrefix = bracketPath.hasPrefix("F:")
        let raw = (hasPrefix ? String(bracketPath.dropFirst(2)) : bracketPath).trimmingCharacters(in: .whitespaces)
        let path = raw.removingPercentEncoding ?? raw
        guard !path.isEmpty, hasPrefix || PathRules.current.isAbsolute(path) else { return nil }
        self.path = path
        target = .file
        label = nil
        self.lineStart = lineStart > 0 ? lineStart : nil
        self.lineEnd = lineEnd.flatMap { $0 > 0 ? $0 : nil }
        documentLocation = nil
    }

    /// The name drawn: "file (line 3)", "file (lines 3-5)", "file (page 2)", or the file alone (`Eol`).
    /// A web citation reads its label or address; a live document its label or path.
    var displayLabel: String {
        switch target {
        case .web: return label ?? path
        case .artifactSession: return label ?? path
        case .file: break
        }
        let fileName = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        guard let location = documentLocation ?? lineLabel else { return fileName }
        // The app writes the place in parentheses in every language (`markdown.fileCitation.lineLabelDisplay`).
        return "\(fileName) (\(location))"
    }

    /// "line 3" or "lines 3-5"; nothing for line 1 of a file that is not code (`jol`).
    private var lineLabel: String? {
        guard let lineStart else { return nil }
        if let lineEnd, lineEnd != lineStart { return L10n.format("lines %lld-%lld", lineStart, lineEnd) }
        if lineStart == 1, !Self.isCode(path) { return nil }
        return L10n.format("line %lld", lineStart)
    }

    /// The link the citation opens: the file with its line as `#L3` or `#L3-L5`, which the file viewer
    /// reads; a web address as it is; nil for a live document.
    var destination: String? {
        switch target {
        case let .web(url): return Self.encoded(url.absoluteString, keeping: Self.urlCharacters)
        case .artifactSession: return nil
        case .file:
            var fragment = ""
            if let lineStart {
                fragment = "#L\(lineStart)"
                if let lineEnd, lineEnd != lineStart { fragment += "-L\(lineEnd)" }
            }
            return Self.encoded(path, keeping: Self.pathCharacters) + fragment
        }
    }

    /// The citation as Markdown: a link, or the label alone where there is nothing to open.
    var markdown: String {
        let text = CodexMessageDirectives.escaped(displayLabel)
        guard let destination else { return text }
        return "[\(text)](\(destination))"
    }

    /// What "Copy response" puts in place of a bracket citation (`nSr`): `path:3-5`, `path:3`, or the
    /// path for line 1.
    var copyText: String {
        guard let lineStart else { return path }
        if let lineEnd, lineEnd != lineStart { return "\(path):\(lineStart)-\(lineEnd)" }
        return lineStart == 1 ? path : "\(path):\(lineStart)"
    }

    // MARK: - Reading

    private static func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive(_ value: String?) -> Int? {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return number
    }

    /// A document, slide or sheet the citation points into (`Uxr`, `Dol`).
    private static func documentLocation(_ attributes: [String: String], label: String?) -> String? {
        switch attributes["artifact_kind"]?.trimmingCharacters(in: .whitespaces) {
        case "document":
            return positive(attributes["page_number"]).map { L10n.format("page %lld", $0) }
        case "presentation":
            guard let slide = positive(attributes["slide_number"]) else { return nil }
            let slideLabel = L10n.format("slide %lld", slide)
            guard text(attributes["object_id"]) != nil, let label else { return slideLabel }
            return "\(slideLabel), \(label)"
        case "workbook":
            guard let sheet = text(attributes["sheet"]) else { return nil }
            if text(attributes["object_id"]) != nil {
                return label.map { "\(sheet), \($0)" }
            }
            return text(attributes["range"]).map { "\(sheet)!\($0)" }
        default:
            return nil
        }
    }

    /// The Codex app names line 1 only for code (`yol`, `Mol`).
    private static func isCode(_ path: String) -> Bool {
        let name = (path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path).lowercased()
        if codeNames.contains(name) { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return codeExtensions.contains(String(name[name.index(after: dot)...]))
    }

    private static let codeNames: Set<String> = [
        ".env", ".env.example", ".env.local", ".gitignore", ".npmrc", ".prettierignore", ".prettierrc", "cargo.lock",
        "cargo.toml", "dockerfile", "makefile", "package-lock.json", "package.json", "requirements.txt",
        "tsconfig.json", "yarn.lock"
    ]
    private static let codeExtensions: Set<String> = [
        "bash", "c", "cc", "cfg", "conf", "cpp", "css", "cxx", "go", "h", "har", "hh", "hpp", "htm", "html", "hxx",
        "ini", "ipynb", "java", "js", "json", "json5", "jsonl", "jsx", "less", "lock", "m", "mjs", "mts", "php",
        "phtml", "ps1", "py", "pyi", "rb", "rs", "sass", "scss", "sh", "sql", "toml", "ts", "tsx", "vue",
        "webmanifest", "xhtml", "xml", "yaml", "yml", "zsh"
    ]

    // MARK: - Links

    private static let pathCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/!$&'*+,;=:@")
    private static let urlCharacters = pathCharacters.union(CharacterSet(charactersIn: "?#%"))

    private static func encoded(_ text: String, keeping allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// One review comment a `::code-comment{…}` line leaves on the diff (`zii`): its title, its words, and
/// the file and lines it is about.
struct CodexReviewComment: Equatable, Sendable {
    /// The title without its `[P1]` mark.
    let title: String
    /// "P0" to "P9", from the title's mark or the `priority` attribute.
    let priority: String?
    let body: String
    let file: String
    let startLine: Int
    let endLine: Int

    init?(attributes: [String: String]) {
        func text(_ key: String) -> String? {
            let value = attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        func integer(_ key: String) -> Int? {
            guard let value = text(key), let number = Double(value), number.isFinite else { return nil }
            return Int(number.rounded(.towardZero))
        }
        guard let title = text("title"), let body = text("body"), let file = text("file") else { return nil }
        let start = max(1, integer("start") ?? 1)
        let end = max(1, integer("end") ?? start)
        startLine = start
        endLine = max(start, end)
        self.body = body
        self.file = file
        // The app marks the title with the priority, then reads the mark back off its first line.
        let marked = integer("priority").map { priority in
            Self.mark(in: title) == nil ? "[P\(priority)] \(title)" : title
        } ?? title
        if let (priority, rest) = Self.mark(in: marked) {
            self.priority = priority
            self.title = rest
        } else {
            priority = nil
            self.title = marked
        }
    }

    /// `path:12` or `path:10-14`, the place the card names (`ub`).
    func location(relativeTo workspace: URL?) -> String {
        let lines = startLine == endLine ? "\(endLine)" : "\(startLine)-\(endLine)"
        return "\(Self.displayPath(file, workspace: workspace)):\(lines)"
    }

    /// The file at its first line, for the task's file viewer: an absolute path, or a path in the
    /// task's folder, which may begin with the folder's own name.
    func link(relativeTo workspace: URL?) -> URL? {
        let url: URL
        if PathRules.current.isAbsolute(file) {
            url = URL(filePath: file)
        } else if let workspace {
            url = workspace.appending(path: Self.pathInWorkspace(file, workspace: workspace))
        } else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = startLine == endLine ? "L\(startLine)" : "L\(startLine)-L\(endLine)"
        return components?.url
    }

    /// `[P1] title`, with any `<sub>` around the mark: the priority and the rest (`Iii`, `lb`).
    private static func mark(in title: String) -> (String, String)? {
        guard let match = title.firstMatch(of: /^(?:<sub>\s*)*\[([pP]\d)\](?:\s*<\/sub>)*\s*(.*)$/) else { return nil }
        return (String(match.1).uppercased(), String(match.2).trimmingCharacters(in: .whitespaces))
    }

    private static func displayPath(_ file: String, workspace: URL?) -> String {
        guard let workspace else { return file }
        if PathRules.current.isAbsolute(file) {
            let relative = PathRules.current.relativePath(of: file, in: PathRules.current.path(of: workspace.standardizedFileURL))
            return relative.flatMap { $0.isEmpty ? nil : $0 } ?? file
        }
        return pathInWorkspace(file, workspace: workspace)
    }

    /// A relative path, without the task folder's own name when it begins with it.
    private static func pathInWorkspace(_ file: String, workspace: URL) -> String {
        let folder = workspace.standardizedFileURL.lastPathComponent
        let components = file.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1, components.first.map(String.init) == folder else { return file }
        return components.dropFirst().joined(separator: "/")
    }
}

/// A `task-stub` card: a follow-up task the model suggests, and the prompt it would start with.
struct CodexSuggestedTask: Equatable, Sendable {
    let title: String
    let prompt: String
}

/// A `codex-inline-vis` visualization: the HTML the Codex app runs in the conversation.
struct CodexVisualization: Equatable, Sendable {
    let title: String
    let file: String
}

/// The parts of a Codex message: Markdown, and the directive blocks drawn as cards.
enum CodexMessageBlock: Equatable, Sendable {
    /// Markdown, its inline directives already written as Markdown (`CodexMessageDirectives.inlineMarkdown`).
    case markdown(String)
    case suggestedTask(CodexSuggestedTask)
    /// A `github-details` disclosure: its summary, whether it starts open, and its Markdown.
    case details(summary: String, isOpen: Bool, body: String)
    /// Consecutive `code-comment` lines, as one card. Lines without a title, body or file are dropped.
    case reviewComments([CodexReviewComment])
    case visualization(CodexVisualization)
}

enum CodexMessageDirectives {
    static let fileCitation = "codex-file-citation"
    static let followUp = "codex-followup"
    static let codeComment = "code-comment"
    static let suggestedTask = "task-stub"
    static let details = "github-details"
    static let inlineVisualization = "codex-inline-vis"
    static let liveVisualization = "codex-live-vis"

    /// The names that are a line of their own (`::name{…}`) and draw as a card.
    static let lineNames: Set<String> = [codeComment, suggestedTask, details, inlineVisualization]
    /// The names whose `:::name{…}` … `:::` lines draw as a card.
    static let containerNames: Set<String> = [suggestedTask, details]
    /// The names drawn inside a line.
    static let inlineNames: Set<String> = [fileCitation, followUp]

    /// Whether `text` may hold anything this draws, so most messages skip the scan.
    static func mayHoldDirectives(_ text: String) -> Bool {
        text.contains(":") && (text.contains("::") || text.contains(":codex-")) || text.contains("【")
    }

    // MARK: - Blocks

    /// The message as Markdown and cards. A directive line inside a code block is text, as is a
    /// container whose closing line never comes.
    static func blocks(_ text: String) -> [CodexMessageBlock] {
        guard mayHoldDirectives(text) else { return [.markdown(text)] }
        let lines = text.components(separatedBy: "\n")
        var blocks: [CodexMessageBlock] = []
        var pending: [String] = []
        var fence: Fence?
        func flush() {
            guard !pending.isEmpty else { return }
            let markdown = pending.joined(separator: "\n")
            pending = []
            // Blank lines between cards draw nothing, and comments a blank line apart stay one card (the
            // app groups a run of them).
            guard !markdown.allSatisfy(\.isWhitespace) else { return }
            blocks.append(.markdown(inlineMarkdown(markdown)))
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                if open.closes(line) { fence = nil }
                pending.append(line)
                index += 1
                continue
            }
            if let opened = Fence(opening: line) {
                fence = opened
                pending.append(line)
                index += 1
                continue
            }
            if let directive = CodexDirectiveSyntax.wholeLine(line, colons: 3), containerNames.contains(directive.name),
               let close = containerClose(after: index, in: lines) {
                flush()
                let body = lines[(index + 1)..<close].joined(separator: "\n")
                blocks.append(container(directive, body: body))
                index = close + 1
                continue
            }
            if let directive = CodexDirectiveSyntax.wholeLine(line, colons: 2), lineNames.contains(directive.name) {
                if directive.name == codeComment {
                    flush()
                    let comment = CodexReviewComment(attributes: directive.attributes)
                    if case let .reviewComments(comments)? = blocks.last {
                        blocks[blocks.count - 1] = .reviewComments(comments + (comment.map { [$0] } ?? []))
                    } else {
                        blocks.append(.reviewComments(comment.map { [$0] } ?? []))
                    }
                } else if let block = leaf(directive) {
                    flush()
                    blocks.append(block)
                } else {
                    pending.append(line)
                }
                index += 1
                continue
            }
            pending.append(line)
            index += 1
        }
        flush()
        // A run of comments none of which could be read draws nothing.
        return blocks.filter { block in
            if case let .reviewComments(comments) = block { return !comments.isEmpty }
            return true
        }
    }

    /// The closing line of the container opened at `index`: containers inside it close first; lines in
    /// a code block do not count.
    private static func containerClose(after index: Int, in lines: [String]) -> Int? {
        var depth = 1
        var fence: Fence?
        for position in (index + 1)..<lines.count {
            let line = lines[position]
            if let open = fence {
                if open.closes(line) { fence = nil }
                continue
            }
            if let opened = Fence(opening: line) {
                fence = opened
                continue
            }
            if CodexDirectiveSyntax.opensContainer(line) {
                depth += 1
            } else if CodexDirectiveSyntax.isContainerClose(line) {
                depth -= 1
                if depth == 0 { return position }
            }
        }
        return nil
    }

    private static func container(_ directive: CodexDirectiveSyntax, body: String) -> CodexMessageBlock {
        if directive.name == suggestedTask {
            return .suggestedTask(CodexSuggestedTask(title: directive.attributes["title"] ?? "", prompt: body))
        }
        return .details(summary: directive.attributes["summary"] ?? "", isOpen: directive.attributes["open"] == "true",
                        body: body)
    }

    private static func leaf(_ directive: CodexDirectiveSyntax) -> CodexMessageBlock? {
        switch directive.name {
        case suggestedTask:
            return .suggestedTask(CodexSuggestedTask(title: directive.attributes["title"] ?? "",
                                                     prompt: directive.label ?? ""))
        case details:
            return .details(summary: directive.attributes["summary"] ?? "", isOpen: directive.attributes["open"] == "true",
                            body: directive.label ?? "")
        case inlineVisualization:
            guard let file = directive.attributes["path"] ?? directive.attributes["file"],
                  !file.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let title = directive.attributes["title"]?.trimmingCharacters(in: .whitespaces)
            let name = file.split(separator: "/").last.map(String.init) ?? file
            let fallback = name.hasSuffix(".html") ? String(name.dropLast(5)) : name
            return .visualization(CodexVisualization(title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, file: file))
        default:
            return nil
        }
    }

    // MARK: - Inside lines

    /// Markdown with its inline directives as Markdown: a file citation becomes a link to the file at
    /// its line, a follow-up its phrase. Code blocks and code spans stay as they are; a citation that
    /// cannot be read draws nothing, as in the app; any other name stays as its text.
    static func inlineMarkdown(_ text: String) -> String {
        rewritingInline(text) { kind in
            switch kind {
            case let .citation(citation): citation?.markdown ?? ""
            case let .bracketCitation(citation): citation.markdown
            case let .followUp(phrase): phrase
            }
        }
    }

    /// What "Copy response" copies of a Codex message, as the app copies it: a follow-up as its phrase,
    /// a bracket citation as `path:line`, and no visualization lines (`n` in `inline-followup-markdown`,
    /// `nSr`, `Orl`). Everything else is as the model wrote it.
    static func copyText(_ text: String) -> String {
        guard mayHoldDirectives(text) else { return text }
        var lines: [String] = []
        var fence: Fence?
        for line in text.components(separatedBy: "\n") {
            if let open = fence {
                if open.closes(line) { fence = nil }
                lines.append(line)
                continue
            }
            if let opened = Fence(opening: line) {
                fence = opened
                lines.append(line)
                continue
            }
            if let directive = CodexDirectiveSyntax.wholeLine(line, colons: 2),
               directive.name == inlineVisualization || directive.name == liveVisualization {
                continue
            }
            lines.append(line)
        }
        return rewritingInline(lines.joined(separator: "\n"), keepingCitations: true) { kind in
            switch kind {
            case let .bracketCitation(citation): citation.copyText
            case let .followUp(phrase): phrase
            case .citation: ""
            }
        }
    }

    enum InlineDirective {
        /// `:codex-file-citation{…}`; nil when its attributes name no file.
        case citation(CodexFileCitation?)
        case bracketCitation(CodexFileCitation)
        /// `:codex-followup[phrase]{…}`'s phrase, empty when it has none.
        case followUp(String)
    }

    /// `text` with each inline directive outside code replaced by `replacement`'s text.
    private static func rewritingInline(
        _ text: String, keepingCitations: Bool = false, _ replacement: (InlineDirective) -> String
    ) -> String {
        guard text.contains(":codex-") || text.contains("【") else { return text }
        var result = ""
        var fence: Fence?
        let lines = text.components(separatedBy: "\n")
        for (number, line) in lines.enumerated() {
            if number > 0 { result += "\n" }
            if let open = fence {
                if open.closes(line) { fence = nil }
                result += line
                continue
            }
            if let opened = Fence(opening: line) {
                fence = opened
                result += line
                continue
            }
            result += rewritingLine(line, keepingCitations: keepingCitations, replacement)
        }
        return result
    }

    private static func rewritingLine(
        _ line: String, keepingCitations: Bool, _ replacement: (InlineDirective) -> String
    ) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "`" {
                // A code span runs to the next run of as many backticks; without one the run is text.
                let run = line[index...].prefix { $0 == "`" }
                let after = run.endIndex
                if let close = line[after...].range(of: String(run)),
                   close.upperBound == line.endIndex || line[close.upperBound] != "`" {
                    result += line[index..<close.upperBound]
                    index = close.upperBound
                } else {
                    result += run
                    index = after
                }
                continue
            }
            if character == "\\", line.index(after: index) < line.endIndex {
                result += line[index...line.index(after: index)]
                index = line.index(index, offsetBy: 2)
                continue
            }
            if character == ":", index == line.startIndex || line[line.index(before: index)] != ":",
               let directive = CodexDirectiveSyntax.read(line, from: line.index(after: index)),
               inlineNames.contains(directive.name) {
                if directive.name == fileCitation {
                    if keepingCitations {
                        result += line[index..<directive.end]
                    } else {
                        result += replacement(.citation(CodexFileCitation(attributes: directive.attributes)))
                    }
                } else {
                    result += replacement(.followUp(directive.label ?? ""))
                }
                index = directive.end
                continue
            }
            if character == "【", let (citation, end) = bracketCitation(in: line, at: index) {
                result += replacement(.bracketCitation(citation))
                index = end
                continue
            }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

    /// `【path†L3】` or `【path†L3-L5】` from `start` (`CGn`, `wGn`).
    private static func bracketCitation(in line: String, at start: String.Index) -> (CodexFileCitation, String.Index)? {
        let rest = line[line.index(after: start)...]
        guard let dagger = rest.range(of: "†L"), let close = rest[dagger.upperBound...].firstIndex(of: "】") else {
            return nil
        }
        let path = String(rest[..<dagger.lowerBound]).trimmingCharacters(in: .whitespaces)
        let range = rest[dagger.upperBound..<close]
        guard let match = range.wholeMatch(of: /(\d+)(?:-L(\d+))?/), let lineStart = Int(match.1),
              let citation = CodexFileCitation(bracketPath: path, lineStart: lineStart,
                                               lineEnd: match.2.flatMap { Int($0) }) else { return nil }
        return (citation, line.index(after: close))
    }

    /// Text that reads literally in Markdown: every ASCII punctuation mark escaped.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isASCII, character.isPunctuation || character.isSymbol { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: - Code blocks

    /// A fenced code block's opening line, which the line that closes it must match.
    struct Fence {
        let marker: Character
        let length: Int

        init?(opening line: String) {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { return nil }
            let body = line.dropFirst(indent.count)
            guard let first = body.first, first == "`" || first == "~" else { return nil }
            let run = body.prefix { $0 == first }
            guard run.count >= 3, first == "~" || !body.dropFirst(run.count).contains("`") else { return nil }
            marker = first
            length = run.count
        }

        func closes(_ line: String) -> Bool {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { return false }
            let body = line.dropFirst(indent.count)
            let run = body.prefix { $0 == marker }
            return run.count >= length && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
        }
    }
}
