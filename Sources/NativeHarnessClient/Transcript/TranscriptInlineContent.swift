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
        attributed = TranscriptAutolink.apply(to: Self.render(markup))
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

    private static func render(_ markup: any Markup, depth: Int = 0) -> AttributedString {
        guard depth < 64 else {
            return AttributedString((markup as? any InlineMarkup)?.plainText ?? "")
        }
        switch markup {
        case let text as Markdown.Text: return AttributedString(text.string)
        case let code as InlineCode:
            var result = AttributedString(code.code)
            result.inlinePresentationIntent = .code
            return result
        case is SoftBreak, is LineBreak: return AttributedString("\n")
        case let html as InlineHTML: return AttributedString(html.rawHTML)
        default: break
        }
        var result = AttributedString()
        for child in markup.children { result += render(child, depth: depth + 1) }
        let intent: InlinePresentationIntent
        switch markup {
        case is Emphasis: intent = .emphasized
        case is Strong: intent = .stronglyEmphasized
        case let strikethrough as Strikethrough:
            // GFM strikes between one tilde as between two, but one more often writes a range
            // ("240~400ms") or "about" ("~5"). Only two strike, as cmark-gfm reads Markdown with
            // `CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE` and remark-gfm with `singleTilde: false`.
            guard strikethrough.openingTildes != 1 else { return AttributedString("~") + result + AttributedString("~") }
            intent = .strikethrough
        default: intent = []
        }
        if !intent.isEmpty {
            for run in result.runs {
                result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
            }
        }
        if let link = markup as? Link, let destination = link.destination {
            // Foundation can escape an existing %20 again when the same URL also
            // contains unescaped Unicode. Encode only the missing escapes first.
            let escaped = destination.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
            result.link = escaped.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
        }
        return result
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
    static func url(for code: String, in workspace: URL) -> URL? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 1_024, !text.contains("\n"), !text.contains("://"),
              let match = text.wholeMatch(of: /^(.+?)(?::([0-9]+)(?::[0-9]+)?|#L([0-9]+)(?:-L?[0-9]+)?)?$/)
        else { return nil }
        let path = String(match.1)
        // A path, not a word: it has a folder or an extension.
        guard path.contains("/") || path.contains(".") else { return nil }
        let file: URL
        if path.hasPrefix("/") {
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
            return path.count > 1 && match.2 == nil && match.3 == nil ? standardized : nil
        }
        guard let line = (match.2 ?? match.3).map(String.init) else { return standardized }
        var components = URLComponents(url: standardized, resolvingAgainstBaseURL: false)
        components?.fragment = "L" + line
        return components?.url ?? standardized
    }
}
