import Foundation

// The message the Codex app sends for the person (Codex desktop app 26.1007, bundle `com.openai.codex`).
// Its composer writes what it attached as context
// sections, then `## My request:`, then what the person typed (`Ccn`, `Icn` in `app-shared`); the IDE
// extension writes `## My request for Codex:`. The Codex app shows the request in the bubble
// (`zp`: the text after the marker), draws some sections as attachments above it and some as words
// under it, and leaves the rest out (`owr`, the `user-message` case in `sites-end-resource`). Copy copies
// the request; an edit edits the request and sends it again after the same context (`zae`).

/// A sent message the Codex app wrote around the person's request.
struct CodexUserPrompt: Equatable, Sendable {
    /// What the person typed: what the bubble shows, "Copy message" copies and an edit edits.
    let request: String
    /// The sent text up to the request, as an edit sends it again (`zae`): the context, then the
    /// line that opens the request.
    let requestPrefix: String
    /// The sections the Codex app draws.
    let attachments: CodexPromptAttachments

    /// The text read as the Codex app reads a sent message, or nil when it is no such message.
    ///
    /// The request follows the last `## My request:` (or `## My request for Codex:`) line, as the
    /// Codex app splits the text on the marker and keeps the last part (`zp`); a message that joins
    /// several prompts shows its last request, as there. A marker quoted inside a code block of the
    /// request does not count: the Codex app cuts such a request at it, Yardlet keeps it whole. The
    /// attachments are those of the context before the first marker, as the app reads them (`Mp`).
    /// - A Codex thread reads every message this way; when the text does not open with one of the
    ///   app's sections, a marker inside a code block from its start does not count either.
    /// - Any other harness reads only the exact shape: text that opens with one of the app's
    ///   sections, and markers alone on their lines. Text that merely holds `## My request` is its
    ///   own text. Diff comments there read only as Yardlet writes them (`DiffCommentPrompt.parse`),
    ///   so a message Yardlet sent with comments shows as it would in a Codex task.
    static func parse(_ text: String, harness: HarnessKind) -> Self? {
        guard text.contains("## My request") else { return nil }
        if let pageComment = pageCommentForm(text) { return pageComment }
        if harness == .codex, let untrusted = untrustedContextForm(text) { return untrusted }
        let lines = Line.split(text)
        let opensWithSection = lines.first { !$0.text.allSatisfy(\.isWhitespace) }
            .map { line in appSectionOpeners.contains { line.text.hasPrefix($0) } } ?? false
        guard harness == .codex || opensWithSection else { return nil }
        // Diff and browser comments Yardlet wrote read the same in every harness, but outside Codex
        // only in the exact shape it writes them (`DiffCommentPrompt`).
        if harness != .codex,
           lines.contains(where: { $0.text == DiffCommentPrompt.header || $0.text == BrowserCommentPrompt.header }),
           DiffCommentPrompt.parse(text) == nil { return nil }
        // Every marker line, and whether a code block opened from the start of the text holds it.
        var candidates: [(index: Int, isInCodeBlock: Bool)] = []
        var fence = FenceState()
        for (index, line) in lines.enumerated() {
            if let found = markers.first(where: { line.text.hasPrefix($0) }),
               harness == .codex || line.text.dropFirst(found.count).allSatisfy(\.isWhitespace) {
                candidates.append((index, fence.isOpen))
            }
            fence.read(line.text)
        }
        if !opensWithSection { candidates.removeAll { $0.isInCodeBlock } }
        guard let first = candidates.first else { return nil }
        // The last marker that is not inside a code block of the request after it.
        let markerLines = Set(candidates.map(\.index))
        let chosen = candidates.first { candidate in
            var fence = FenceState()
            for index in (candidate.index + 1)..<lines.count {
                if markerLines.contains(index), !fence.isOpen { return false }
                fence.read(lines[index].text)
            }
            return true
        } ?? first
        let markerLine = lines[chosen.index]
        let found = markers.first { markerLine.text.hasPrefix($0) } ?? marker
        let rest = markerLine.text.dropFirst(found.count)
        let requestStart = rest.allSatisfy(\.isWhitespace) ? markerLine.next : rest.startIndex
        var context = String(text[..<markerLine.start])
        while context.last?.isWhitespace == true { context.removeLast() }
        return Self(
            request: text[requestStart...].trimmingCharacters(in: .whitespacesAndNewlines),
            requestPrefix: context + "\n" + marker + "\n",
            attachments: CodexPromptAttachments(context: String(text[..<lines[first.index].start]))
        )
    }

    /// The marker the Codex app writes before a request (`Pp`).
    static let marker = "## My request:"
    /// The markers it reads (`Kae`): its own, and the IDE extension's.
    static let markers = ["## My request:", "## My request for Codex:"]

    // MARK: - Forms

    /// `<page-comment-context>` … `</page-comment-context>` then `## My request:` (`Bae`, `Nae`): a
    /// comment left on a page, whose context the app hides.
    private static func pageCommentForm(_ text: String) -> Self? {
        let open = "<page-comment-context>\n", close = "\n</page-comment-context>\n", request = marker + "\n"
        guard text.hasPrefix(open),
              let end = text.range(of: close, range: text.index(text.startIndex, offsetBy: open.count)..<text.endIndex),
              text[end.upperBound...].hasPrefix(request) else { return nil }
        let start = text.index(end.upperBound, offsetBy: request.count)
        return Self(request: text[start...].trimmingCharacters(in: .whitespacesAndNewlines),
                    requestPrefix: String(text[..<start]), attachments: CodexPromptAttachments())
    }

    /// A JSON object of untrusted context, a blank line, then `## My request:` (`xNi`): the context
    /// is the app's to read, not the person's words.
    private static func untrustedContextForm(_ text: String) -> Self? {
        let separator = "\n\n" + marker + "\n"
        guard text.hasPrefix("{"), let found = text.range(of: separator),
              let object = try? JSONSerialization.jsonObject(with: Data(text[..<found.lowerBound].utf8)),
              object is [String: Any] else { return nil }
        return Self(request: text[found.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines),
                    requestPrefix: String(text[..<found.upperBound]), attachments: CodexPromptAttachments())
    }

    /// The first lines of the sections the Codex app (and its IDE extension) writes.
    static let appSectionOpeners: [String] = CodexPromptAttachments.sectionHeaders.keys.sorted()
        + [CodexPromptAttachments.browserContextOpen, CodexPromptAttachments.responseAnnotationsHeader]

    /// A line of the text: where it starts, its words, and where the next line starts.
    private struct Line {
        let start: String.Index
        let text: Substring
        let next: String.Index

        static func split(_ text: String) -> [Line] {
            var lines: [Line] = []
            var start = text.startIndex
            while start < text.endIndex {
                let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
                let next = end < text.endIndex ? text.index(after: end) : end
                lines.append(Line(start: start, text: text[start..<end], next: next))
                start = next
            }
            return lines
        }
    }

    /// Fenced code blocks as CommonMark opens and closes them: up to three spaces, then three or more
    /// backticks or tildes; a block closes on a run as long of the same character.
    private struct FenceState {
        private var open: (character: Character, length: Int)?

        var isOpen: Bool { open != nil }

        mutating func read(_ line: Substring) {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { return }
            let body = line.dropFirst(indent.count)
            guard let first = body.first, first == "`" || first == "~" else { return }
            let run = body.prefix { $0 == first }
            guard run.count >= 3 else { return }
            let rest = body.dropFirst(run.count)
            if let current = open {
                if first == current.character, run.count >= current.length, rest.allSatisfy(\.isWhitespace) { open = nil }
            } else if first == "~" || !rest.contains("`") {
                open = (first, run.count)
            }
        }
    }
}

extension CodexComposerDraft {
    /// What editing a Codex request puts in the composer, as the Codex app's edit does: a message the
    /// app wrote around a request reads as the request alone, and `requestPrefix` is what an edit
    /// sends again before the edited request (`zae`). Nil for any other message.
    var codexRequestForEditing: (draft: CodexComposerDraft, requestPrefix: String)? {
        guard let index = inputs.firstIndex(where: { if case .text = $0 { true } else { false } }),
              case let .text(value, _) = inputs[index],
              ConversationScheduledTaskMessage.parse(value) == nil,
              let prompt = CodexUserPrompt.parse(value, harness: .codex) else { return nil }
        var draft = self
        draft.inputs[index] = .text(prompt.request)
        return (draft, prompt.requestPrefix)
    }

    /// The edited request sent again after the context it was sent with (`zae`).
    func sendingCodexRequest(after requestPrefix: String) -> CodexComposerDraft {
        var draft = self
        if let index = inputs.firstIndex(where: { if case .text = $0 { true } else { false } }),
           case let .text(value, _) = inputs[index] {
            draft.inputs[index] = .text(requestPrefix + value + "\n")
        } else {
            draft.inputs.insert(.text(requestPrefix + "\n"), at: 0)
        }
        return draft
    }
}

/// The context sections of a sent message that the Codex app draws (`owr`). Everything else it wrote
/// there (the IDE's open files and selection, the in-app browser's tabs, worktree and app
/// instructions, referenced conversations) is for the model and is not drawn.
struct CodexPromptAttachments: Equatable, Sendable {
    /// A file the person mentioned or pasted (`d8t`), drawn as a chip that opens it at its lines.
    struct File: Equatable, Sendable {
        var label: String
        /// An absolute path.
        var path: String
        var startLine: Int?
        var endLine: Int?
        /// Text the person pasted, which the app keeps as a file.
        var isPasted = false
        /// An attached image, which the message shows as its image instead.
        var isImage = false

        /// The chip's line note (`Fn`): "12" or "12-20", no punctuation.
        var lineInfo: String? {
            guard let startLine else { return nil }
            if let endLine, endLine != startLine { return "\(startLine)-\(endLine)" }
            return "\(startLine)"
        }

        /// The chip's name (`JB`): the label without a line note it already ends with.
        var name: String {
            guard lineInfo != nil else { return label }
            return label.replacing(/(?:\s+\(\s*\d+(?:-\d+)?\s*\)|\s+\d+(?:-\d+)?)(\s*)$/, with: "")
        }

        /// The file at its first line, for the task's file viewer (`#L12-L20`).
        var link: URL {
            var components = URLComponents(url: URL(filePath: path), resolvingAgainstBaseURL: false)
            if let lineInfo { components?.fragment = "L" + lineInfo.replacingOccurrences(of: "-", with: "-L") }
            return components?.url ?? URL(filePath: path)
        }
    }

    /// A comment the person attached (`_Cr`): on a diff, or on the in-app browser or a document.
    struct Comment: Equatable, Sendable {
        var path: String?
        var lines: String?
        var body: String
    }

    /// What the request was sent as, which the app writes under the bubble.
    enum Mode: Equatable, Sendable, CaseIterable {
        /// `## Code review guidelines:`: "Review mode".
        case review
        /// `## Pull request fix:`: "PR fix".
        case pullRequestFix
        /// `## Auto resolve merge:`: "Auto resolve conflicts".
        case autoResolveConflicts
    }

    var files: [File] = []
    /// Files uploaded from another surface, by name (`RCr`).
    var uploads: [String] = []
    /// `## Prior conversation with Codex:` outside review and PR fixes: "Previous context".
    var referencesPriorConversation = false
    /// `## Pull request merge task:` with its pull request: "PR #N".
    var mergeTaskPullRequest: Int?
    /// `# Failing PR checks:`, by check name.
    var failingChecks: [String] = []
    /// `# Pull request merge conflict:`; its pull request when it names one.
    var mergeConflict: MergeConflict?
    /// Browser, document and artifact comments, and the response annotations: "N annotations".
    var annotations: [Comment] = []
    var responseAnnotationCount = 0
    /// Diff comments: "N comments".
    var comments: [Comment] = []
    /// `# Selected text:`, each selection's text.
    var selections: [String] = []
    var modes: [Mode] = []

    struct MergeConflict: Equatable, Sendable {
        var pullRequest: Int?
    }

    /// Nothing to draw.
    var isEmpty: Bool { self == Self() }

    /// The files a message shows as chips: an image it also sent shows as that image (`bsn`).
    func shownFiles(imagePaths: [String]) -> [File] {
        guard !imagePaths.isEmpty else { return files }
        let images = Set(imagePaths.map { $0.lowercased() })
        return files.filter { !$0.isImage && !images.contains($0.path.lowercased()) }
    }

    // MARK: - Reading

    static let browserContextOpen = "<in-app-browser-context source=\"ambient-ui-state\">"
    static let browserContextClose = "</in-app-browser-context>"
    static let responseAnnotationsHeader = "# Response annotations:"

    fileprivate enum Section {
        case filesMentioned, filesPasted, diffComments, browserComments, selectedText, failingChecks
        case mergeConflict, mergeTask, priorConversation, review, pullRequestFix, autoResolve
        /// For the model only.
        case hidden
    }

    /// The section headers the Codex app writes, each a line of its own (`Bp`, `mH` in `app-shared`).
    fileprivate static let sectionHeaders: [String: Section] = [
        "# Files mentioned by the user:": .filesMentioned,
        "# Files pasted by the user:": .filesPasted,
        "# Context from my IDE setup:": .hidden,
        "# Worktree instructions:": .hidden,
        "# Diff comments:": .diffComments,
        "# Browser comments:": .browserComments,
        "# Selected text:": .selectedText,
        "# Failing PR checks:": .failingChecks,
        "# MCP app context:": .hidden,
        "# Pull request merge conflict:": .mergeConflict,
        "# In app browser:": .hidden,
        "# Chrome tabs:": .hidden,
        "# Applications mentioned by the user:": .hidden,
        "# Suggested artifact action target:": .hidden,
        "# Page context:": .hidden,
        "# Open LaTeX document": .hidden,
        "# Pull request repair instructions:": .hidden,
        "## Prior conversation with Codex:": .priorConversation,
        "## Referenced chats with Codex:": .hidden,
        "## Referenced ChatGPT conversation:": .hidden,
        "## Code review guidelines:": .review,
        "## Pull request fix:": .pullRequestFix,
        "## Pull request merge task:": .mergeTask,
        "## Auto resolve merge:": .autoResolve,
    ]

    init() {}

    /// The attachments the context before a request holds.
    init(context: String) {
        var context = Substring(context)
        // A leading `# Response annotations:` block (`Mae`): its JSON lists the annotations.
        let annotationsOpen = "\n" + Self.responseAnnotationsHeader + "\n"
        if context.hasPrefix(annotationsOpen),
           let jsonStart = context.range(of: "\n<response-annotations>\n")?.upperBound,
           let jsonEnd = context.range(of: "\n</response-annotations>\n", range: jsonStart..<context.endIndex) {
            let json = try? JSONSerialization.jsonObject(with: Data(context[jsonStart..<jsonEnd.lowerBound].utf8))
            responseAnnotationCount = (json as? [Any])?.count ?? 0
            context = context[jsonEnd.upperBound...]
        }
        var section: Section?
        var lines: [Substring] = []
        var inBrowserContext = false
        func finish() {
            if let section { read(section, lines) }
            lines = []
        }
        for line in context.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBrowserContext {
                if trimmed == Self.browserContextClose { inBrowserContext = false }
                continue
            }
            if trimmed == Self.browserContextOpen {
                finish()
                section = .hidden
                inBrowserContext = true
            } else if let next = Self.sectionHeaders[trimmed] {
                finish()
                section = next
            } else {
                lines.append(line)
            }
        }
        finish()
        if modes.contains(.review) || modes.contains(.pullRequestFix) { referencesPriorConversation = false }
    }

    private mutating func read(_ section: Section, _ lines: [Substring]) {
        switch section {
        case .filesMentioned, .filesPasted:
            readFiles(lines, isPasted: section == .filesPasted)
        case .diffComments, .browserComments:
            for comment in Self.comments(in: lines) {
                if section == .browserComments || comment.isAnnotation {
                    annotations.append(comment.comment)
                } else {
                    comments.append(comment.comment)
                }
            }
        case .selectedText:
            selections += Self.blocks(in: lines, startingWith: { $0.hasPrefix("## Selection ") })
                .map { $0.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        case .failingChecks:
            failingChecks += lines.compactMap { line in
                line.firstMatch(of: /^## Check \d+:\s*(.+?)\s*$/).map { String($0.1) }
            }
        case .mergeConflict:
            mergeConflict = MergeConflict(pullRequest: Self.pullRequestNumber(in: lines))
        case .mergeTask:
            mergeTaskPullRequest = Self.pullRequestNumber(in: lines) ?? mergeTaskPullRequest
        case .priorConversation:
            referencesPriorConversation = true
        case .review:
            if !modes.contains(.review) { modes.append(.review) }
        case .pullRequestFix:
            if !modes.contains(.pullRequestFix) { modes.append(.pullRequestFix) }
        case .autoResolve:
            if !modes.contains(.autoResolveConflicts) { modes.append(.autoResolveConflicts) }
        case .hidden:
            break
        }
    }

    /// `## label: /path (lines 3-5)` lines (`u8t`), each perhaps followed by `Image attachment: true`
    /// or library metadata; the list ends at the first other line. `Uploaded file: {…}` lines name
    /// files uploaded elsewhere (`RCr`).
    private mutating func readFiles(_ lines: [Substring], isPasted: Bool) {
        var isListing = true
        for line in lines {
            let text = line.drop { $0.isWhitespace }
            guard !text.isEmpty else { continue }
            if let upload = text.firstMatch(of: /^Uploaded (?:pasted text|file): (.+)$/),
               let object = try? JSONSerialization.jsonObject(with: Data(upload.1.utf8)) as? [String: Any],
               let name = object["fileName"] as? String, !name.isEmpty {
                uploads.append(name)
                continue
            }
            guard isListing else { continue }
            if let file = Self.file(in: text, isPasted: isPasted) {
                files.append(file)
            } else if !isPasted, !files.isEmpty, text == "Image attachment: true" {
                files[files.count - 1].isImage = true
            } else if !isPasted, !files.isEmpty,
                      text.hasPrefix("Library file metadata: ") || text.hasPrefix("Shared thread metadata: ") {
                continue
            } else {
                isListing = false
            }
        }
    }

    /// `## label: path`, the path absolute, perhaps with ` (line 3)` or ` (lines 3-5)` after it; a
    /// pasted file's label is a JSON string. The label may hold `: `, so the split moves left until
    /// the rest is a path.
    static func file(in line: Substring, isPasted: Bool) -> File? {
        guard let heading = line.firstMatch(of: /^##\s+(.+)$/) else { return nil }
        let body = heading.1
        var split = body.range(of: ": ", options: .backwards)
        while let found = split, found.lowerBound > body.startIndex {
            var label = body[..<found.lowerBound].trimmingCharacters(in: .whitespaces)
            var path = body[found.upperBound...].trimmingCharacters(in: .whitespaces)
            var startLine: Int?, endLine: Int?
            if let lines = path.firstMatch(of: /\s+\((?:lines\s+(\d+)-(\d+)|line\s+(\d+))\)\s*$/) {
                startLine = Int(lines.1 ?? lines.3 ?? "")
                endLine = Int(lines.2 ?? lines.3 ?? "")
                path = String(path[..<lines.range.lowerBound])
            }
            if !label.isEmpty, isAbsolutePath(path) {
                if isPasted {
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(label.utf8)) else { return nil }
                    label = decoded
                }
                return File(label: label, path: path, startLine: startLine, endLine: endLine, isPasted: isPasted)
            }
            split = body.range(of: ": ", options: .backwards, range: body.startIndex..<found.lowerBound)
        }
        return nil
    }

    /// An absolute path (`VM`) on either kind of computer: POSIX's, or a Windows drive or share.
    private static func isAbsolutePath(_ path: String) -> Bool {
        PathRules.posix.isAbsolute(path) || PathRules.windows.isAbsolute(path)
    }

    private struct ReadComment {
        var comment: Comment
        /// A browser, PDF or artifact comment, which the app counts as an annotation.
        var isAnnotation: Bool
    }

    /// The comments of a comment section (`zCr`, `_Cr`): each from a `## Comment`, `## User Comment`
    /// or `## Requested annotation` line, its place on `File:` and `Lines:` lines, its words after
    /// `Comment:`.
    private static func comments(in lines: [Substring]) -> [ReadComment] {
        let starts = { (line: Substring) in
            line.hasPrefix("## Comment") || line.hasPrefix("## User Comment") || line.hasPrefix("## Requested annotation")
        }
        return blocks(in: lines, startingWith: starts).map { block in
            if let short = block[0].firstMatch(of: /^## Comment \d+ \((.*):([0-9-]+)\)$/) {
                let body = block.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return ReadComment(comment: Comment(path: String(short.1), lines: String(short.2), body: body),
                                   isAnnotation: isAnnotationPath(String(short.1)))
            }
            let bodyStart = block.firstIndex { $0 == "Comment:" }
            let metadata = block[..<(bodyStart ?? block.endIndex)]
            func value(_ key: String) -> String? {
                metadata.first { $0.hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
            }
            let isBrowser = metadata.count > 1 && metadata[metadata.startIndex + 1] == "Browser"
            let path = value("File:")
            let body = bodyStart.map { block[($0 + 1)...].joined(separator: "\n") }
                ?? block.dropFirst().joined(separator: "\n")
            return ReadComment(
                comment: Comment(path: isBrowser ? nil : path, lines: value("Lines:"),
                                 body: body.trimmingCharacters(in: .whitespacesAndNewlines)),
                isAnnotation: isBrowser || path.map(isAnnotationPath) == true
                    || value("Artifact path:") != nil || value("PDF path:") != nil
            )
        }
    }

    /// A comment on the in-app browser, a PDF or an artifact (`DCr`), not on a diff.
    private static func isAnnotationPath(_ path: String) -> Bool {
        path.hasPrefix("browser:") || path.hasPrefix("pdf:") || path.hasPrefix("artifact:")
    }

    /// The runs of lines from each line `starts` accepts to the next one.
    private static func blocks(in lines: [Substring], startingWith starts: (Substring) -> Bool) -> [[Substring]] {
        var blocks: [[Substring]] = []
        for line in lines {
            if starts(line) {
                blocks.append([line])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
    }

    /// `Pull request: #12` (`XCr`, `ZCr`).
    private static func pullRequestNumber(in lines: [Substring]) -> Int? {
        for line in lines {
            if let match = line.firstMatch(of: /^Pull request:\s*#(\d+)\s*$/) { return Int(match.1) }
        }
        return nil
    }
}
