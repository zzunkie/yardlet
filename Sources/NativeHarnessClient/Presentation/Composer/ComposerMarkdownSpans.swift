import Foundation

/// What a composer draws differently in its Markdown, line by line, while the text stays as typed:
/// the marks are kept and only dimmed. Ranges are UTF-16.
struct ComposerMarkdownSpans: Equatable {
    enum Kind: Equatable {
        /// `**`, `*`, `` ` ``, `#` and the like: kept, dimmed.
        case syntax
        case strong
        case emphasis
        case code
        /// A line inside a fenced code block.
        case codeBlock
        /// A fence line (```` ``` ````).
        case fence
        case heading
        /// A quote's text, after its `>`.
        case quote
        /// A list item's marker: `-`, `1.`.
        case listMarker
    }

    struct Run: Equatable {
        var range: NSRange
        var kind: Kind
    }

    /// A line's paragraph: what its wrapped lines line up under.
    struct Line: Equatable {
        /// Without the line break.
        var range: NSRange
        /// From the line's start to where its text starts (a list item's or a quote's prefix), which wrapped
        /// lines line up under. Zero for other lines.
        var hangingPrefix: NSRange?
        /// Leading spaces of a list item or quote, drawn wider so each level reads as a step.
        var indent: NSRange?
        var isCode = false
    }

    var lines: [Line] = []
    var runs: [Run] = []

    /// The spans of the lines `range` touches, in `text`. Fences are read from the start of the text,
    /// so a line inside a code block is known as one wherever the range starts.
    init(text: NSString, range: NSRange) {
        let fenced = Self.fencedLines(in: text, through: NSMaxRange(range))
        var location = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0)).location
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let content = ComposerMarkdown.lineContent(lineRange, in: text)
            switch fenced[content.location] {
            case .fence?:
                lines.append(Line(range: content, isCode: true))
                runs.append(Run(range: content, kind: .fence))
            case .inside?:
                lines.append(Line(range: content, isCode: true))
                if content.length > 0 { runs.append(Run(range: content, kind: .codeBlock)) }
            case nil:
                read(line: content, in: text)
            }
            location = NSMaxRange(lineRange)
        } while location < NSMaxRange(range) && location < text.length
    }

    private enum Fenced { case fence, inside }

    /// The fence lines and the lines between them, of the blocks that open before `end`, keyed by their
    /// start. Only lines that hold ```` ``` ```` are looked at outside a block.
    private static func fencedLines(in text: NSString, through end: Int) -> [Int: Fenced] {
        var result: [Int: Fenced] = [:]
        var openedAt: Int?
        var search = 0
        while search < text.length {
            let found = text.range(of: "```", options: [], range: NSRange(location: search, length: text.length - search))
            guard found.location != NSNotFound else { break }
            let line = text.lineRange(for: NSRange(location: found.location, length: 0))
            if openedAt == nil, line.location >= end { break }
            search = NSMaxRange(line)
            guard isFence(ComposerMarkdown.lineContent(line, in: text), in: text) else { continue }
            result[line.location] = .fence
            if let start = openedAt {
                markInside(from: start, to: line.location, in: text, into: &result)
                openedAt = nil
            } else {
                openedAt = NSMaxRange(line)
            }
        }
        if let start = openedAt { markInside(from: start, to: text.length, in: text, into: &result) }
        return result
    }

    private static func markInside(from start: Int, to end: Int, in text: NSString, into result: inout [Int: Fenced]) {
        var location = start
        while location < end {
            result[location] = .inside
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
        }
    }

    private static func isFence(_ line: NSRange, in text: NSString) -> Bool {
        let content = text.substring(with: line)
        let trimmed = content.drop { $0 == " " }
        return content.count - trimmed.count < 4 && trimmed.hasPrefix("```")
    }

    private mutating func read(line content: NSRange, in text: NSString) {
        let string = text.substring(with: content)
        var line = Line(range: content)
        var textStart = content.location
        if let prefix = ComposerMarkdown.prefix(of: Substring(string)) {
            let spaces = (string.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
            if spaces > 0 { line.indent = NSRange(location: content.location, length: spaces) }
            line.hangingPrefix = NSRange(location: content.location, length: prefix.length)
            let marker = NSRange(location: content.location + spaces, length: prefix.length - spaces)
            textStart = content.location + prefix.length
            if prefix.isList {
                runs.append(Run(range: marker, kind: .listMarker))
            } else {
                runs.append(Run(range: marker, kind: .syntax))
                let rest = NSRange(location: textStart, length: NSMaxRange(content) - textStart)
                if rest.length > 0 { runs.append(Run(range: rest, kind: .quote)) }
            }
        } else if let level = Self.headingLevel(string) {
            let marker = NSRange(location: content.location, length: level)
            runs.append(Run(range: marker, kind: .syntax))
            runs.append(Run(range: NSRange(location: content.location + level, length: content.length - level),
                            kind: .heading))
            textStart = content.location + level
        }
        lines.append(line)
        inline(NSRange(location: textStart, length: NSMaxRange(content) - textStart), in: text)
    }

    /// `#` to `######` and the space after them.
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes + 1
    }

    // MARK: - Inline

    private static let codeSpan = try! NSRegularExpression(pattern: "(`+)(?!`)(.+?)(?<!`)\\1(?!`)")
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(
        pattern: "(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])|(?<![_\\w])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![_\\w])")

    private mutating func inline(_ range: NSRange, in text: NSString) {
        guard range.length > 1 else { return }
        var taken: [NSRange] = []
        func free(_ candidate: NSRange) -> Bool {
            !taken.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
        for match in Self.codeSpan.matches(in: text as String, range: range) {
            let ticks = match.range(at: 1).length
            runs.append(Run(range: NSRange(location: match.range.location, length: ticks), kind: .syntax))
            runs.append(Run(range: match.range(at: 2), kind: .code))
            runs.append(Run(range: NSRange(location: NSMaxRange(match.range) - ticks, length: ticks), kind: .syntax))
            taken.append(match.range)
        }
        for match in Self.strong.matches(in: text as String, range: range) where free(match.range) {
            runs.append(Run(range: NSRange(location: match.range.location, length: 2), kind: .syntax))
            runs.append(Run(range: match.range(at: 2), kind: .strong))
            runs.append(Run(range: NSRange(location: NSMaxRange(match.range) - 2, length: 2), kind: .syntax))
            taken.append(NSRange(location: match.range.location, length: 2))
            taken.append(NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
        for match in Self.emphasis.matches(in: text as String, range: range) where free(match.range) {
            let inner = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            runs.append(Run(range: NSRange(location: match.range.location, length: 1), kind: .syntax))
            runs.append(Run(range: inner, kind: .emphasis))
            runs.append(Run(range: NSRange(location: NSMaxRange(match.range) - 1, length: 1), kind: .syntax))
        }
    }
}
