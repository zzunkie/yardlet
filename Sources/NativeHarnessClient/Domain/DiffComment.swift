import Foundation

// Line comments on a diff, the Codex app's local diff comments (ChatGPT.app 26.1007, `com.openai.codex`).
// The review's diff takes a comment on a line or a range (`use-diff-annotations`
// `Vt`, `code.diffComment.*`); the comments wait with the task (`diff_comments`, per conversation) and
// show as one "N comments" chip in the composer (`commentAttachments.numComments`); the next message
// writes them before the request (`Icn` and `Vcn` in `app-shared`) and they leave once it is sent (`kL`).

/// One comment on a diff's line or range, waiting for the task's next message.
struct DiffComment: Codable, Equatable, Identifiable, Sendable {
    /// The diff's two sides, as the Codex app names them (`position.side`): left holds the old file's
    /// lines (a deleted line), right the new file's (an added or unchanged line).
    enum Side: String, Codable, Sendable {
        case left, right

        /// `L` or `R` (`vcn`).
        var letter: String { self == .left ? "L" : "R" }
    }

    /// A line on one side of the diff.
    struct Anchor: Codable, Equatable, Hashable, Sendable {
        var side: Side
        var line: Int
    }

    var id: UUID
    /// The file as the diff names it, relative to `workspaceRoot` (`File:`).
    var path: String
    /// The folder the diff's paths are relative to (`Workspace:`).
    var workspaceRoot: String?
    /// The first line of the range; the last line for a comment on one line.
    var start: Anchor
    /// The line the comment shows under (`position.line`).
    var end: Anchor
    /// The hunks the lines are in, as the diff shows them (`localDiffHunk`).
    var diffHunk: String?
    var body: String

    init(id: UUID = UUID(), path: String, workspaceRoot: String?, start: Anchor, end: Anchor,
         diffHunk: String?, body: String) {
        self.id = id
        self.path = path
        self.workspaceRoot = workspaceRoot
        self.start = start
        self.end = end
        self.diffHunk = diffHunk
        self.body = body
    }

    /// The range two chosen lines make, in the order the diff shows them. On one side it runs from
    /// the lower line to the higher; across the sides it keeps the order it was chosen in (the Codex
    /// app's line selection, `kt` in `code-diff`).
    static func range(from first: Anchor, to last: Anchor) -> (start: Anchor, end: Anchor) {
        guard first.side == last.side else { return (first, last) }
        return (Anchor(side: first.side, line: min(first.line, last.line)),
                Anchor(side: first.side, line: max(first.line, last.line)))
    }

    var isSingleLine: Bool { start == end }

    /// `Side:` (`Vcn`): `R`, `L`, or `L-R` for a range that crosses the sides.
    var sideLabel: String {
        start.side == end.side ? end.side.letter : "\(start.side.letter)-\(end.side.letter)"
    }

    /// `Lines:` (`_cn`): `12`, `10-12`, or `L10-R12` across the sides.
    var linesLabel: String {
        if start.side != end.side {
            return "\(start.side.letter)\(start.line)-\(end.side.letter)\(end.line)"
        }
        let low = min(start.line, end.line), high = max(start.line, end.line)
        return low == high ? String(high) : "\(low)-\(high)"
    }

    /// The card's line under the author (`code.diffComment.lineBySource`, `lineRangeBySource`):
    /// "Local comment on line R12", "Local comment on lines R10 to R12".
    var lineTitle: String {
        isSingleLine
            ? L10n.format("Local comment on line %@", "\(end.side.letter)\(end.line)")
            : L10n.format("Local comment on lines %@ to %@", "\(start.side.letter)\(start.line)",
                          "\(end.side.letter)\(end.line)")
    }

    /// The same comment, apart from its identity.
    func hasSameContent(as other: DiffComment) -> Bool {
        var copy = other
        copy.id = id
        return copy == self
    }
}

/// The text a message carries its diff comments in, the Codex app's own (`Icn`, `Vcn`, `Ccn`):
///
///     \n# Diff comments:\n
///     \n## User Comment 1\nFile: path\nWorkspace: root\nSide: R\nLines: 10-12\n
///     Diff hunk:\n```diff\n@@ … @@\n…\n```\nComment:\nwords\n
///     … each comment, numbered from 1 …
///     \n## My request:\nthe request\n
///
/// `Workspace:` is written when the comment knows its folder and `Diff hunk:` when it has one. Elements
/// picked in the task's browser follow under `# Browser comments:` (`BrowserCommentPrompt`), numbered
/// on from the diff comments, as the Codex app writes both kinds (`Bun`, `Gun`). Every harness is sent
/// this text; the conversation reads it back as the request and the comment and annotation chips
/// (`CodexUserPrompt`).
enum DiffCommentPrompt {
    static let header = "# Diff comments:"
    private static let commentHeader = "## User Comment "
    private static let requestMarker = "\n" + CodexUserPrompt.marker + "\n"

    /// The comments section (`Icn`): its header, then each comment (`Vcn`).
    static func section(_ comments: [DiffComment]) -> String {
        var text = "\n\(header)\n"
        for (index, comment) in comments.enumerated() {
            text += "\n\(commentHeader)\(index + 1)\n"
            text += "File: \(comment.path)\n"
            if let root = comment.workspaceRoot { text += "Workspace: \(root)\n" }
            text += "Side: \(comment.sideLabel)\n"
            text += "Lines: \(comment.linesLabel)\n"
            if let hunk = comment.diffHunk, !hunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += "Diff hunk:\n```diff\n\(hunk)\n```\n"
            }
            text += "Comment:\n\(comment.body)\n"
        }
        return text
    }

    /// The message (`Ccn`): the diff comments, the browser comments, `## My request:`, the request and
    /// a closing newline. `browserImageNumbers` gives each browser comment's capture its place among the
    /// message's images. A message without comments is its request alone.
    static func message(comments: [DiffComment], browserComments: [BrowserComment] = [],
                        browserImageNumbers: [Int?] = [], request: String) -> String {
        guard !comments.isEmpty || !browserComments.isEmpty else { return request }
        var text = comments.isEmpty ? "" : section(comments)
        if !browserComments.isEmpty {
            text += BrowserCommentPrompt.section(browserComments, firstNumber: comments.count + 1,
                                                 imageNumbers: browserImageNumbers)
        }
        return text + requestMarker + request + "\n"
    }

    /// The comments and request of a message `message` wrote, or nil for any other text. Outer
    /// whitespace does not count, as a send that trims its text keeps the shape. A browser comment's
    /// capture is the message's image its number names, out of `images` in order.
    static func parse(_ text: String, images: [URL] = [])
        -> (comments: [DiffComment], browserComments: [BrowserComment], request: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(header + "\n") || trimmed.hasPrefix(BrowserCommentPrompt.header + "\n") else { return nil }
        var rest = Substring("\n" + trimmed + "\n")
        var comments: [DiffComment] = []
        if rest.hasPrefix("\n\(header)\n") { rest = rest.dropFirst(header.count + 2) }
        while rest.hasPrefix("\n\(commentHeader)\(comments.count + 1)\nFile: ") {
            rest = rest.dropFirst("\n\(commentHeader)\(comments.count + 1)\n".count)
            guard let path = take("File: ", from: &rest) else { return nil }
            let root = take("Workspace: ", from: &rest)
            guard let side = take("Side: ", from: &rest), let lines = take("Lines: ", from: &rest),
                  let (start, end) = anchors(side: side, lines: lines) else { return nil }
            var hunk: String?
            if rest.hasPrefix("Diff hunk:\n```diff\n") {
                rest = rest.dropFirst("Diff hunk:\n```diff\n".count)
                guard let close = rest.range(of: "\n```\nComment:\n") else { return nil }
                hunk = String(rest[..<close.lowerBound])
                rest = rest[close.lowerBound...].dropFirst("\n```\n".count)
            }
            guard rest.hasPrefix("Comment:\n") else { return nil }
            rest = rest.dropFirst("Comment:\n".count)
            // The words end where the next comment, the browser comments or the request starts.
            let ends = ["\n\n\(commentHeader)\(comments.count + 2)\n", "\n\n\(BrowserCommentPrompt.header)\n", "\n" + requestMarker]
            guard let bodyEnd = ends.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
            else { return nil }
            let body = rest[..<bodyEnd.lowerBound]
            guard !body.split(separator: "\n").contains(where: startsBlock) else { return nil }
            comments.append(DiffComment(path: path, workspaceRoot: root, start: start, end: end,
                                        diffHunk: hunk, body: String(body)))
            rest = rest[bodyEnd.lowerBound...].dropFirst()
        }
        let browser = BrowserCommentPrompt.read(from: &rest, firstNumber: comments.count + 1) ?? []
        guard !comments.isEmpty || !browser.isEmpty, rest.hasPrefix(requestMarker) else { return nil }
        let request = String(rest.dropFirst(requestMarker.count).dropLast())
        // Only what this writer writes: anything it would write differently is someone else's text.
        guard message(comments: comments, browserComments: browser.map(\.comment), browserImageNumbers: browser.map(\.imageNumber),
                      request: request).trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return nil }
        let browserComments = browser.map { read in
            var comment = read.comment
            if let number = read.imageNumber, images.indices.contains(number - 1) { comment.image = images[number - 1] }
            return comment
        }
        return (comments, browserComments, request)
    }

    /// A line the Codex app's reader would start a comment, a section or the request at (`zCr`, `Mp`),
    /// which a comment's words cannot hold if the text is to read back as this writer wrote it.
    private static func startsBlock(_ line: Substring) -> Bool {
        line.hasPrefix("## Comment") || line.hasPrefix("## User Comment") || line.hasPrefix("## Requested annotation")
            || CodexUserPrompt.markers.contains { line.hasPrefix($0) }
            || CodexUserPrompt.appSectionOpeners.contains(line.trimmingCharacters(in: .whitespaces))
    }

    /// The value of a `key` line at the start of `rest`, which then moves past it.
    private static func take(_ key: String, from rest: inout Substring) -> String? {
        guard rest.hasPrefix(key), let end = rest.firstIndex(of: "\n") else { return nil }
        let value = String(rest[rest.index(rest.startIndex, offsetBy: key.count)..<end])
        rest = rest[rest.index(after: end)...]
        return value
    }

    /// The range a `Side:` and `Lines:` pair names.
    private static func anchors(side: String, lines: String) -> (DiffComment.Anchor, DiffComment.Anchor)? {
        func named(_ letter: Substring) -> DiffComment.Side? {
            letter == "L" ? .left : letter == "R" ? .right : nil
        }
        if let crossing = lines.wholeMatch(of: /([LR])(\d+)-([LR])(\d+)/) {
            guard let first = named(crossing.1), let last = named(crossing.3), first != last,
                  side == "\(crossing.1)-\(crossing.3)",
                  let from = Int(crossing.2), let to = Int(crossing.4) else { return nil }
            return (.init(side: first, line: from), .init(side: last, line: to))
        }
        guard let one = named(Substring(side)) else { return nil }
        if let range = lines.wholeMatch(of: /(\d+)-(\d+)/), let low = Int(range.1), let high = Int(range.2), low < high {
            return (.init(side: one, line: low), .init(side: one, line: high))
        }
        guard let line = Int(lines), line > 0 else { return nil }
        return (.init(side: one, line: line), .init(side: one, line: line))
    }
}

extension DiffComment {
    /// The comments a message carries, named by their count: "1 attached comment", "3 attached comments".
    static func countTitle(_ count: Int) -> String {
        count == 1 ? L10n.string("1 attached comment") : L10n.format("%lld attached comments", count)
    }
}
