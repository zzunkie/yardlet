import Foundation

// MARK: - What a message presents

/// The Codex app's directive syntax and code-block rules, read here for what a dot's messages and
/// tasks present as results; the conversation's own drawing of them is untouched.
enum PersonalAgentPresentedReferences {
    /// A file or page a message points to, as the Codex app collects a turn's results from it: a
    /// `:codex-file-citation`, with the purpose and the page (`page_id`) it names, or a Markdown link
    /// with its destination.
    enum PresentedReference: Equatable, Sendable {
        case citation(CodexFileCitation, purpose: String?, pageID: String?)
        case link(label: String?, destination: String)
    }

    /// The citations and links of `text` outside code blocks, code spans, inline HTML and images, in
    /// order. A citation inside a link's text is the link's, as Markdown reads it.
    static func references(_ text: String) -> [PresentedReference] {
        guard text.contains(":codex-") || text.contains("](") else { return [] }
        var found: [PresentedReference] = []
        var fence: CodexMessageDirectives.Fence?
        var html: HTMLBlock?
        for line in text.components(separatedBy: "\n") {
            if let open = fence {
                if open.closes(line) { fence = nil }
                continue
            }
            if let open = html {
                if open.closes(line) { html = nil }
                continue
            }
            if let opened = CodexMessageDirectives.Fence(opening: line) {
                fence = opened
                continue
            }
            if let opened = HTMLBlock(opening: line) {
                if !opened.closes(line) || opened.end == .blankLine { html = opened }
                continue
            }
            found += references(inLine: line)
        }
        return found
    }

    private static func references(inLine line: String) -> [PresentedReference] {
        var found: [PresentedReference] = []
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "`" {
                let run = line[index...].prefix { $0 == "`" }
                if let close = line[run.endIndex...].range(of: String(run)),
                   close.upperBound == line.endIndex || line[close.upperBound] != "`" {
                    index = close.upperBound
                } else {
                    index = run.endIndex
                }
                continue
            }
            if character == "\\", line.index(after: index) < line.endIndex {
                index = line.index(index, offsetBy: 2)
                continue
            }
            // Inline HTML: a tag runs to its closing bracket and holds no reference.
            if character == "<", let next = line[line.index(after: index)...].first, next.isLetter || next == "/" || next == "!",
               let close = line[index...].firstIndex(of: ">") {
                index = line.index(after: close)
                continue
            }
            if character == ":", index == line.startIndex || line[line.index(before: index)] != ":",
               let directive = CodexDirectiveSyntax.read(line, from: line.index(after: index)),
               CodexMessageDirectives.inlineNames.contains(directive.name) {
                if directive.name == CodexMessageDirectives.fileCitation, let citation = CodexFileCitation(attributes: directive.attributes) {
                    let page = directive.attributes["page_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    found.append(.citation(citation, purpose: directive.attributes["purpose"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines), pageID: page?.isEmpty == false ? page : nil))
                }
                index = directive.end
                continue
            }
            if character == "!" || character == "[", let (label, destination, end) = link(in: line, at: index) {
                if character == "[" { found.append(.link(label: label, destination: destination)) }
                index = end
                continue
            }
            index = line.index(after: index)
        }
        return found
    }

    /// A block of raw HTML, which Markdown passes through as it is: from a line that begins with a tag,
    /// a comment or a declaration to its end, as CommonMark ends each kind.
    private struct HTMLBlock {
        enum End: Equatable { case closingTag(String), text(String), blankLine }
        let end: End

        init?(opening line: String) {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { return nil }
            let body = line.dropFirst(indent.count).lowercased()
            guard body.hasPrefix("<") else { return nil }
            if body.hasPrefix("<!--") { end = .text("-->"); return }
            if body.hasPrefix("<?") { end = .text("?>"); return }
            if body.hasPrefix("<![cdata[") { end = .text("]]>"); return }
            if body.hasPrefix("<!"), body.dropFirst(2).first?.isLetter == true { end = .text(">"); return }
            let name = body.dropFirst(body.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            guard let first = name.first, first.isLetter else { return nil }
            if ["script", "pre", "style", "textarea"].contains(String(name)), !body.hasPrefix("</") {
                end = .closingTag("</" + name)
            } else if Self.blockNames.contains(String(name))
                        || body.trimmingCharacters(in: .whitespaces).wholeMatch(of: /<\/?[a-z][a-z0-9-]*(\s[^<>]*)?\/?>/) != nil {
                // A block-level tag, or any tag alone on its line; a tag inside text is inline HTML.
                end = .blankLine
            } else {
                return nil
            }
        }

        /// CommonMark's block-level tag names, whose block runs to a blank line.
        static let blockNames: Set<String> = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
            "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
            "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
            "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
            "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
            "th", "thead", "title", "tr", "track", "ul"
        ]

        func closes(_ line: String) -> Bool {
            switch end {
            case let .closingTag(tag): line.lowercased().contains(tag)
            case let .text(marker): line.contains(marker)
            case .blankLine: line.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    /// `[label](destination)` or `![alt](destination)` from `start`: the label without its brackets, the
    /// destination without a title or angle brackets.
    private static func link(in line: String, at start: String.Index) -> (String?, String, String.Index)? {
        var index = start
        if line[index] == "!" {
            index = line.index(after: index)
            guard index < line.endIndex, line[index] == "[" else { return nil }
        }
        var depth = 0
        var cursor = line.index(after: index)
        var closeLabel: String.Index?
        while cursor < line.endIndex {
            let character = line[cursor]
            if character == "\\" {
                cursor = line.index(cursor, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                if depth == 0 { closeLabel = cursor; break }
                depth -= 1
            }
            cursor = line.index(after: cursor)
        }
        guard let closeLabel, line.index(after: closeLabel) < line.endIndex,
              line[line.index(after: closeLabel)] == "(" else { return nil }
        let label = String(line[line.index(after: index)..<closeLabel]).trimmingCharacters(in: .whitespaces)
        var position = line.index(closeLabel, offsetBy: 2)
        while position < line.endIndex, line[position] == " " { position = line.index(after: position) }
        var destination = ""
        if position < line.endIndex, line[position] == "<" {
            guard let close = line[position...].firstIndex(of: ">") else { return nil }
            destination = String(line[line.index(after: position)..<close])
            position = line.index(after: close)
        } else {
            var parens = 0
            while position < line.endIndex {
                let character = line[position]
                if character == " " { break }
                if character == "(" { parens += 1 }
                if character == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                destination.append(character)
                position = line.index(after: position)
            }
        }
        guard let close = line[position...].firstIndex(of: ")"), !destination.isEmpty else { return nil }
        return (label.isEmpty ? nil : label, destination, line.index(after: close))
    }
}
