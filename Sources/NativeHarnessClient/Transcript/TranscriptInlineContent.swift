import Foundation
import Markdown

/// Retain the parsed characters and their semantics without a lossy Markdown round trip.
struct TranscriptInlineContent: Equatable, Sendable, ExpressibleByStringLiteral {
    let attributed: AttributedString
    var plainText: String { String(attributed.characters) }

    init(plainText: String) {
        attributed = AttributedString(plainText)
    }

    init(stringLiteral value: String) {
        self.init(markup: Document(parsing: value, options: [.disableSmartOpts]))
    }

    init(markup: any Markup) {
        attributed = TranscriptAutolink.apply(to: Self.render([markup]))
    }

    /// Some of a paragraph's inline children, as `init(markup:)` reads the whole paragraph; white space and
    /// line breaks at either end, where a picture stood, are left out.
    init(inlines: [any Markup]) {
        var rendered = Self.render(inlines)
        while let first = rendered.characters.first, first.isWhitespace {
            rendered.removeSubrange(rendered.startIndex..<rendered.characters.index(after: rendered.startIndex))
        }
        while let last = rendered.characters.last, last.isWhitespace {
            rendered.removeSubrange(rendered.characters.index(before: rendered.endIndex)..<rendered.endIndex)
        }
        attributed = TranscriptAutolink.apply(to: rendered)
    }

    /// One line of Markdown as a summary or a card shows it: its words with their inline styles and
    /// links, without the marks that start a heading, quote or list item. A line that is no words to
    /// Markdown, a fence or a rule, stays as written.
    init(line: String) {
        let content = Self(markup: Document(parsing: line, options: [.disableSmartOpts]))
        self = content.attributed.characters.isEmpty ? Self(plainText: line) : content
    }

    func resolved(relativeTo workspace: URL?) -> AttributedString {
        guard let workspace else { return attributed }
        var result = attributed
        let directory = URL(filePath: workspace.path(percentEncoded: false), directoryHint: .isDirectory)
        for run in attributed.runs {
            if run.link == nil, run.inlinePresentationIntent?.contains(.code) == true {
                // A file named in code, as Claude Code and Codex write one, opens as the apps open it.
                if let file = TranscriptFileReference.url(for: String(attributed[run.range].characters), in: directory) {
                    result[run.range].link = file
                }
                continue
            }
            // An anchor alone (`#…`) names no file: a heading, or a task (`TaskLink`).
            guard let link = run.link, link.scheme == nil, !link.relativeString.hasPrefix("#") else { continue }
            // `~/…` is under the home folder, as an inline code path is.
            let base = link.relativeString.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser : directory
            let relative = link.relativeString.hasPrefix("~/") ? String(link.relativeString.dropFirst(2)) : link.relativeString
            guard let resolved = URL(string: relative, relativeTo: base)?.absoluteURL else { continue }
            result[run.range].link = resolved
        }
        return result
    }

    /// The words of `markups` with their styles and links. They are gathered as one string and the
    /// stretches each style or link covers, and the attributed string is made once from them: making
    /// one for every piece of text and joining them, level by level, took several times as long, and a
    /// long answer has thousands of pieces.
    private static func render(_ markups: [any Markup]) -> AttributedString {
        var builder = InlineBuilder()
        for markup in markups { builder.add(markup, style: InlineBuilder.Style(), depth: 0) }
        return builder.attributedString()
    }

    private struct InlineBuilder {
        struct Style: Equatable {
            var intent: InlinePresentationIntent = []
            /// Set inside a link: its address, or nil when it is none.
            var link: URL?? = nil
        }

        private var text = ""
        /// The stretches of `text` one after another, in Unicode scalars, each with its style.
        private var stretches: [(length: Int, style: Style)] = []

        mutating func add(_ markup: any Markup, style: Style, depth: Int) {
            guard depth < 64 else {
                append((markup as? any InlineMarkup)?.plainText ?? "", style)
                return
            }
            switch markup {
            case let text as Markdown.Text: return append(text.string, style)
            case let code as InlineCode:
                var codeStyle = style
                codeStyle.intent.formUnion(.code)
                return append(code.code, codeStyle)
            case is SoftBreak, is LineBreak: return append("\n", style)
            case let html as InlineHTML: return append(html.rawHTML, style)
            default: break
            }
            var inner = style
            switch markup {
            case is Emphasis: inner.intent.formUnion(.emphasized)
            case is Strong: inner.intent.formUnion(.stronglyEmphasized)
            case let strikethrough as Strikethrough:
                // GFM strikes between one tilde as between two, but one more often writes a range
                // ("240~400ms") or "about" ("~5"). Only two strike, as cmark-gfm reads Markdown with
                // `CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE` and remark-gfm with `singleTilde: false`.
                guard strikethrough.openingTildes != 1 else {
                    append("~", style)
                    for child in markup.children { add(child, style: style, depth: depth + 1) }
                    append("~", style)
                    return
                }
                inner.intent.formUnion(.strikethrough)
            default: break
            }
            // A link covers all of its words; the outermost one wins, as it was set last.
            if style.link == nil, let link = markup as? Link, let destination = link.destination {
                inner.link = .some(Self.url(destination))
            }
            for child in markup.children { add(child, style: inner, depth: depth + 1) }
        }

        private mutating func append(_ piece: String, _ style: Style) {
            let length = piece.unicodeScalars.count
            guard length > 0 else { return }
            text += piece
            if let last = stretches.last, last.style == style {
                stretches[stretches.count - 1].length += length
            } else {
                stretches.append((length, style))
            }
        }

        func attributedString() -> AttributedString {
            var result = AttributedString(text)
            var start = result.startIndex
            for stretch in stretches {
                let end = result.unicodeScalars.index(start, offsetBy: stretch.length)
                if !stretch.style.intent.isEmpty { result[start..<end].inlinePresentationIntent = stretch.style.intent }
                if case let .some(link) = stretch.style.link { result[start..<end].link = link }
                start = end
            }
            return result
        }

        private static func url(_ destination: String) -> URL? {
            // Foundation can escape an existing %20 again when the same URL also
            // contains unescaped Unicode. Encode only the missing escapes first.
            let escaped = destination.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
            return escaped.addingPercentEncoding(withAllowedCharacters: linkCharacters).flatMap { URL(string: $0) }
        }

        private static let linkCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
    }
}

private extension Strikethrough {
    /// The tildes it opens with: the columns from its start to its first child's. Both are on one line,
    /// as the opening tildes are followed by no white space.
    var openingTildes: Int? {
        guard let start = range?.lowerBound, let first = child(at: 0)?.range?.lowerBound, first.line == start.line
        else { return nil }
        return first.column - start.column
    }
}

/// A file a code span names, as Claude Code (`file_path:line_number`) and Codex (a path in inline code,
/// with `:line` or `#Lline`) write one in an answer, and both apps open on a click: relative to the
/// task's folder, absolute, or under the home folder. Only a file or folder that is there links (a
/// folder opens in Finder); a word that merely looks like a path stays code.
enum TranscriptFileReference {
    /// Prepared once: a regex literal compiles its program again in every call that evaluates it, and a long
    /// answer asks about each of its code spans. A regex is immutable once made (its program is prepared under a
    /// lock), so sharing it across threads is safe though `Regex` is not marked `Sendable`.
    nonisolated(unsafe) private static let pathAndLine = /^(.+?)(?::([0-9]+)(?::[0-9]+)?|#L([0-9]+)(?:-L?[0-9]+)?)?$/
    /// The path a code span names and the line it names, if any, by the span's text alone: what `url(for:in:)` looks
    /// for on disk.
    static func path(in code: String) -> (path: String, line: Substring?)? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 1_024, !text.contains("\n"), !text.contains("://"),
              let match = text.wholeMatch(of: pathAndLine)
        else { return nil }
        let path = String(match.1)
        // A path, not a word: it has a folder or an extension.
        guard path.contains("/") || path.contains(".") else { return nil }
        return (path, match.2 ?? match.3)
    }

    static func url(for code: String, in workspace: URL) -> URL? {
        guard let (path, line) = path(in: code) else { return nil }
        let file: URL
        if PathRules.current.isAbsolute(path) {
            file = URL(filePath: path)
        } else if path.hasPrefix("~/") {
            file = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2)))
        } else {
            file = workspace.appending(path: path)
        }
        let standardized = file.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path(percentEncoded: false), isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue {
            // `/` alone is a slash, not the disk.
            return path.count > 1 && line == nil ? standardized : nil
        }
        guard let line = line.map(String.init) else { return standardized }
        var components = URLComponents(url: standardized, resolvingAgainstBaseURL: false)
        components?.fragment = "L" + line
        return components?.url ?? standardized
    }
}
