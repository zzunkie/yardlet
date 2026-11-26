import SwiftUI

/// Prose in messages, including the hidden copy used to measure a folded message.
struct ConversationText: View {
    private let content: Text
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 4

    init(_ text: String, opensFiles: Bool = false) {
        content = Text(MarkdownView.inline(text, opensFiles: opensFiles))
    }

    init(verbatim text: String) {
        content = Text(verbatim: text)
    }

    var body: some View {
        content.lineSpacing(lineSpacing)
    }
}

/// An answer's Markdown (CommonMark and GFM tables, docs/REMOTE_PROTOCOL.md §6.3), drawn in blocks: paragraphs and
/// lists with their inline styles and hanging indents, inline and standalone images, headings, quotes, code blocks and
/// tables that scroll sideways with their scroll bar shown. Selectable, so a part can be copied. Links in the link
/// color and underlined, and with `opensFiles` a code span that names a file links it too (`ConversationLinks`); the
/// screen's `openURL` decides what a link opens.
struct MarkdownView: View {
    let text: String
    var font: Font = .body
    var opensFiles = false
    @ScaledMetric(relativeTo: .body) var blockSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .paragraph(text):
            ConversationText(text, opensFiles: opensFiles).font(font).textSelection(.enabled)
        case let .heading(level, text):
            ConversationText(text, opensFiles: opensFiles)
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .textSelection(.enabled)
                .padding(.top, 4)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(YardletPalette.outline).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.splitParagraph(text).enumerated()), id: \.offset) { _, subBlock in
                        switch subBlock {
                        case let .pictures(pictures):
                            MarkdownPicturesView(pictures: pictures, opensFiles: opensFiles)
                        case let .paragraph(part):
                            ConversationText(part, opensFiles: opensFiles)
                                .font(font)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .textSelection(.enabled)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        case let .pictures(pictures):
            MarkdownPicturesView(pictures: pictures, opensFiles: opensFiles)
        case let .list(items):
            MarkdownListView(items: items, font: font, opensFiles: opensFiles)
        case let .code(code):
            SidewaysBlock {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(YardletPalette.onSurface)
                    .textSelection(.enabled)
                    .padding(12)
                    .padding(.trailing, 8)
            }
        case let .table(table):
            SidewaysBlock(fitsContent: true) {
                MarkdownTableView(table: table, opensFiles: opensFiles)
            }
        case .rule:
            Divider()
        }
    }

    /// A Markdown image `![alt](source)` or linked image `[![alt](source)](link)`.
    struct Picture: Equatable, Sendable {
        let alt: String
        let source: String
        var link: String? = nil

        /// Label shown on chips and accessibility: alt text, or the last path component of the source.
        var label: String {
            let trimmedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAlt.isEmpty { return trimmedAlt }
            if source.lowercased().hasPrefix("data:") { return String(localized: "Image") }
            let path = source.split(separator: "?", maxSplits: 1).first.map(String.init) ?? source
            let last = path.split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? source
            return last.isEmpty ? String(localized: "Image") : last
        }
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case quote(String)
        case pictures([Picture])
        case list([ListItem])
        case code(String)
        case table(Table)
        case rule
    }

    /// One item of a list: how deep it is, its marker ("•", "3.", "☐") and its words, continuation lines included.
    struct ListItem: Equatable {
        let depth: Int
        let marker: String
        var text: String
    }

    /// A GFM table: its header row, its rows, and each column's alignment from the delimiter row.
    struct Table: Equatable {
        let header: [String]
        let rows: [[String]]
        let alignments: [HorizontalAlignment]

        static func == (lhs: Table, rhs: Table) -> Bool {
            lhs.header == rhs.header && lhs.rows == rhs.rows
                && lhs.alignments.map(Self.name) == rhs.alignments.map(Self.name)
        }

        private static func name(_ alignment: HorizontalAlignment) -> String {
            alignment == .center ? "center" : alignment == .trailing ? "trailing" : "leading"
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(contentsOf: splitParagraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !list.isEmpty {
                blocks.append(.list(list))
                list = []
            }
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let level = heading(trimmed) {
                flush()
                blocks.append(.heading(level, String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next.trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.table(table(rows)))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(next.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else if let item = listItem(line) {
                if !paragraph.isEmpty {
                    blocks.append(contentsOf: splitParagraph(paragraph.joined(separator: "\n")))
                    paragraph = []
                }
                list.append(item)
            } else if !list.isEmpty {
                // A line under an item, indented or not, goes on with it.
                list[list.count - 1].text += "\n" + trimmed
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: - Inline & standalone Markdown image extraction

    /// Splits any `![alt](source)` or `[![alt](source)](link)` occurrences out of a paragraph into `.pictures` blocks,
    /// grouping images separated only by whitespace and leaving inline code spans untouched.
    static func splitParagraph(_ text: String) -> [Block] {
        guard text.contains("![") else { return [.paragraph(text)] }

        var blocks: [Block] = []
        var pendingText = ""
        var pendingPictures: [Picture] = []
        var foundAnyPicture = false
        var afterPicture = false

        func flushText(beforePicture: Bool) {
            let cleaned = cleanTextSegment(pendingText, trimLeadingFirstLine: afterPicture, trimTrailingLastLine: beforePicture)
            pendingText = ""
            afterPicture = false
            if !cleaned.isEmpty {
                blocks.append(.paragraph(cleaned))
            }
        }

        func flushPictures() {
            guard !pendingPictures.isEmpty else { return }
            blocks.append(.pictures(pendingPictures))
            pendingPictures = []
            afterPicture = true
        }

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]

            // Skip backslash escapes.
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    let after = text.index(after: next)
                    if !pendingPictures.isEmpty { flushPictures() }
                    pendingText.append(contentsOf: text[index..<after])
                    index = after
                    continue
                }
            }

            // Skip inline code spans so `![alt](src)` inside backticks stays literal code.
            if ch == "`" {
                let runEnd = advanceWhile(text, from: index, matching: "`")
                let tickCount = text.distance(from: index, to: runEnd)
                if let closeEnd = findClosingBackticks(text, from: runEnd, count: tickCount) {
                    if !pendingPictures.isEmpty { flushPictures() }
                    pendingText.append(contentsOf: text[index..<closeEnd])
                    index = closeEnd
                    continue
                } else {
                    if !pendingPictures.isEmpty { flushPictures() }
                    pendingText.append(contentsOf: text[index..<runEnd])
                    index = runEnd
                    continue
                }
            }

            // Try linked image: `[![alt](src)](link)`
            if ch == "[", let parsed = parseLinkedImage(text, from: index) {
                foundAnyPicture = true
                if !pendingText.allSatisfy(\.isWhitespace) {
                    flushPictures()
                    flushText(beforePicture: true)
                } else {
                    pendingText = ""
                }
                pendingPictures.append(parsed.picture)
                index = parsed.nextIndex
                continue
            }

            // Try standalone/inline image: `![alt](src)`
            if ch == "!", let parsed = parseImage(text, from: index) {
                foundAnyPicture = true
                if !pendingText.allSatisfy(\.isWhitespace) {
                    flushPictures()
                    flushText(beforePicture: true)
                } else {
                    pendingText = ""
                }
                pendingPictures.append(parsed.picture)
                index = parsed.nextIndex
                continue
            }

            // While accumulating consecutive images, buffer whitespace in case another image follows immediately.
            if !pendingPictures.isEmpty && !ch.isWhitespace {
                flushPictures()
            }
            pendingText.append(ch)
            index = text.index(after: index)
        }

        if !foundAnyPicture {
            return [.paragraph(text)]
        }

        flushPictures()
        flushText(beforePicture: false)
        return blocks
    }

    /// Trims leading/trailing blank lines, cleans spaces adjacent to a split image, and removes a trailing standalone
    /// bullet marker (e.g. `• `) left behind when a list item contains only an image.
    private static func cleanTextSegment(_ raw: String, trimLeadingFirstLine: Bool, trimTrailingLastLine: Bool) -> String {
        var lines = raw.components(separatedBy: "\n")
        var hadLeadingNewline = false
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
            hadLeadingNewline = true
        }
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "•" || trimmed == "☐" || trimmed == "☑" {
                lines.removeLast()
            } else {
                break
            }
        }
        guard !lines.isEmpty else { return "" }
        if trimLeadingFirstLine && !hadLeadingNewline {
            lines[0] = String(lines[0].drop(while: { $0 == " " || $0 == "\t" }))
        }
        if trimTrailingLastLine {
            let lastIndex = lines.count - 1
            lines[lastIndex] = lines[lastIndex].replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        }
        return lines.joined(separator: "\n")
    }

    private static func parseLinkedImage(_ text: String, from start: String.Index) -> (picture: Picture, nextIndex: String.Index)? {
        guard text[start] == "[" else { return nil }
        let afterOpen = text.index(after: start)
        guard afterOpen < text.endIndex, text[afterOpen] == "!" else { return nil }
        guard let inner = parseImage(text, from: afterOpen) else { return nil }
        let closeBracket = inner.nextIndex
        guard closeBracket < text.endIndex, text[closeBracket] == "]" else { return nil }
        let openParen = text.index(after: closeBracket)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        guard let dest = parseParenDestination(text, from: openParen) else { return nil }
        let picture = Picture(alt: inner.picture.alt, source: inner.picture.source, link: dest.destination)
        return (picture, dest.nextIndex)
    }

    private static func parseImage(_ text: String, from start: String.Index) -> (picture: Picture, nextIndex: String.Index)? {
        guard text[start] == "!" else { return nil }
        let openBracket = text.index(after: start)
        guard openBracket < text.endIndex, text[openBracket] == "[" else { return nil }

        // Parse alt text until matching unescaped `]`.
        var cursor = text.index(after: openBracket)
        var bracketDepth = 1
        var alt = ""
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\\" {
                let next = text.index(after: cursor)
                if next < text.endIndex {
                    alt.append(text[next])
                    cursor = text.index(after: next)
                    continue
                }
            }
            if ch == "[" {
                bracketDepth += 1
                alt.append(ch)
            } else if ch == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 {
                    break
                }
                alt.append(ch)
            } else {
                alt.append(ch)
            }
            cursor = text.index(after: cursor)
        }
        guard bracketDepth == 0, cursor < text.endIndex else { return nil }

        let openParen = text.index(after: cursor)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        guard let dest = parseParenDestination(text, from: openParen), !dest.destination.isEmpty else { return nil }

        return (Picture(alt: alt, source: dest.destination), dest.nextIndex)
    }

    /// Parses `(destination "optional title")` starting at `(`. Supports `<...>` destinations and balanced parentheses.
    private static func parseParenDestination(_ text: String, from openParen: String.Index) -> (destination: String, nextIndex: String.Index)? {
        guard text[openParen] == "(" else { return nil }
        var cursor = text.index(after: openParen)
        while cursor < text.endIndex && text[cursor].isWhitespace && text[cursor] != "\n" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }

        let destination: String
        if text[cursor] == "<" {
            cursor = text.index(after: cursor)
            var raw = ""
            while cursor < text.endIndex, text[cursor] != ">" {
                if text[cursor] == "\n" { return nil }
                if text[cursor] == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex {
                        raw.append(text[next])
                        cursor = text.index(after: next)
                        continue
                    }
                }
                raw.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == ">" else { return nil }
            cursor = text.index(after: cursor)
            destination = raw.trimmingCharacters(in: .whitespaces)
        } else {
            var raw = ""
            var parenDepth = 0
            while cursor < text.endIndex {
                let ch = text[cursor]
                if ch == "\n" { return nil }
                if ch == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex {
                        raw.append(text[next])
                        cursor = text.index(after: next)
                        continue
                    }
                }
                if ch == "(" {
                    parenDepth += 1
                    raw.append(ch)
                } else if ch == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                    raw.append(ch)
                } else if ch.isWhitespace && parenDepth == 0 {
                    break
                } else {
                    raw.append(ch)
                }
                cursor = text.index(after: cursor)
            }
            guard parenDepth == 0 else { return nil }
            destination = raw
        }

        // Skip whitespace and optional quoted/parenthesized title before closing `)`.
        while cursor < text.endIndex && text[cursor].isWhitespace && text[cursor] != "\n" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }

        if text[cursor] == "\"" || text[cursor] == "'" || text[cursor] == "(" {
            let quote = text[cursor]
            let closing: Character = quote == "(" ? ")" : quote
            cursor = text.index(after: cursor)
            while cursor < text.endIndex && text[cursor] != closing {
                if text[cursor] == "\n" { return nil }
                if text[cursor] == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex {
                        cursor = text.index(after: next)
                        continue
                    }
                }
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == closing else { return nil }
            cursor = text.index(after: cursor)
            while cursor < text.endIndex && text[cursor].isWhitespace && text[cursor] != "\n" {
                cursor = text.index(after: cursor)
            }
        }

        guard cursor < text.endIndex, text[cursor] == ")" else { return nil }
        return (destination, text.index(after: cursor))
    }

    private static func advanceWhile(_ text: String, from start: String.Index, matching char: Character) -> String.Index {
        var cursor = start
        while cursor < text.endIndex && text[cursor] == char {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func findClosingBackticks(_ text: String, from start: String.Index, count: Int) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor] == "`" {
                let runEnd = advanceWhile(text, from: cursor, matching: "`")
                if text.distance(from: cursor, to: runEnd) == count {
                    return runEnd
                }
                cursor = runEnd
            } else {
                cursor = text.index(after: cursor)
            }
        }
        return nil
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// A list item's line: "- ", "* " or "+ " as "•", a task box as "☐" or "☑", "1. " or "1) " as "1.", and how deep
    /// its indent puts it (two spaces a level, a tab as four).
    static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(indent.count)
        if rest.hasPrefix("- [ ] ") { return ListItem(depth: depth, marker: "☐", text: String(rest.dropFirst(6))) }
        if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") {
            return ListItem(depth: depth, marker: "☑", text: String(rest.dropFirst(6)))
        }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return ListItem(depth: depth, marker: "•", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.hasPrefix(". ") || after.hasPrefix(") ") else { return nil }
        return ListItem(depth: depth, marker: digits + ".", text: String(after.dropFirst(2)))
    }

    /// A GFM table: its first row the header, and the row under it, when every cell is dashes with optional colons,
    /// the delimiter that sets each column's alignment. Any other row, a body row of dashes included, is a row.
    static func table(_ rows: [String]) -> Table {
        var cells = rows.map(tableCells).filter { !$0.isEmpty }
        var alignments: [HorizontalAlignment] = []
        if cells.count > 1, cells[1].allSatisfy(isDelimiterCell) {
            alignments = cells[1].map { cell in
                cell.hasPrefix(":") && cell.hasSuffix(":") ? .center : cell.hasSuffix(":") ? .trailing : .leading
            }
            cells.remove(at: 1)
        }
        return Table(header: cells.first ?? [], rows: Array(cells.dropFirst()), alignments: alignments)
    }

    /// "---", ":--", "--:" or ":-:": at least one dash, a colon only at either end.
    private static func isDelimiterCell(_ cell: String) -> Bool {
        let core = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
        return !core.isEmpty && core.allSatisfy { $0 == "-" }
    }

    /// A table row's cells, split at its pipes but not at an escaped one (`\|`, kept as "|") or one inside a code
    /// span; the row's outer pipes are left out.
    static func tableCells(_ row: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var index = row.startIndex
        while index < row.endIndex {
            let ch = row[index]
            if ch == "\\", row.index(after: index) < row.endIndex, row[row.index(after: index)] == "|" {
                cell.append("|")
                index = row.index(index, offsetBy: 2)
            } else if ch == "`" {
                let runEnd = advanceWhile(row, from: index, matching: "`")
                let end = findClosingBackticks(row, from: runEnd, count: row.distance(from: index, to: runEnd)) ?? runEnd
                cell.append(contentsOf: row[index..<end])
                index = end
            } else if ch == "|" {
                cells.append(cell)
                cell = ""
                index = row.index(after: index)
            } else {
                cell.append(ch)
                index = row.index(after: index)
            }
        }
        cells.append(cell)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.first == "" { trimmed.removeFirst() }
        if trimmed.last == "" { trimmed.removeLast() }
        return trimmed
    }

    static func inline(_ text: String, opensFiles: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        // Code in a sentence: monospaced a size smaller, so it sits in the line as the Mac draws it.
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = .system(.callout, design: .monospaced)
            if opensFiles, run.link == nil, let path = ConversationLinks.path(String(parsed[run.range].characters)) {
                parsed[run.range].link = ConversationLinks.fileLink(path)
            }
        }
        // In the link color and underlined: the app's tint is its monochrome primary, which tells a link from the
        // words around it by the underline alone.
        for run in parsed.runs where run.link != nil {
            parsed[run.range].underlineStyle = .single
            parsed[run.range].foregroundColor = YardletPalette.link
        }
        return parsed
    }
}

/// A block wider than the screen, in its box: it scrolls sideways, its scroll bar shows (and flashes as it appears),
/// and while more of it is out of view on the right that edge fades, so a cut-off edge reads as more to see.
private struct SidewaysBlock<Content: View>: View {
    /// The box as wide as what it holds when that is narrower than the screen (a table), rather than the screen's width.
    var fitsContent = false
    @ViewBuilder let content: Content
    @State private var contentWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var moreOnRight: Bool { contentWidth - offset > boxWidth + 1 }

    var body: some View {
        ScrollView(.horizontal) {
            content
                .padding(.bottom, fitsContent ? 0 : 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SidewaysOffset.self, value: -proxy.frame(in: .named(Self.space)).minX)
                })
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(SidewaysOffset.self) { value in MainActor.assumeIsolated { offset = value } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        .overlay(alignment: .trailing) {
            if moreOnRight {
                LinearGradient(colors: [YardletPalette.surfaceContainerLow.opacity(0), YardletPalette.surfaceContainerLow],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: moreOnRight)
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .background(YardletPalette.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: fitsContent && contentWidth > 0 ? contentWidth : nil, alignment: .leading)
    }

    private static var space: String { "sideways" }
}

/// How far a sideways block has scrolled.
private struct SidewaysOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A Markdown table as a table: a header band, rules between the rows and columns, and each cell's inline Markdown
/// (code, emphasis, links) drawn as in a sentence. Every cell fills its column's width and its row's height, so the
/// band and the rules run unbroken from edge to edge; a long cell wraps at a column's widest.
private struct MarkdownTableView: View {
    let table: MarkdownView.Table
    let opensFiles: Bool

    private var columns: Int { max(table.header.count, table.rows.map(\.count).max() ?? 0, 1) }

    var body: some View {
        let rows = [table.header] + table.rows
        TableLayout(columns: columns, maxColumnWidth: 264) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, cells in
                ForEach(0..<columns, id: \.self) { column in
                    cell(column < cells.count ? cells[column] : "", row: rowIndex, column: column)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func cell(_ text: String, row: Int, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return ConversationText(text, opensFiles: opensFiles)
            .font(row == 0 ? .footnote.weight(.semibold) : .footnote)
            .foregroundStyle(YardletPalette.onSurface)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .background(row == 0 ? YardletPalette.surfaceContainer : Color.clear)
            .overlay(alignment: .leading) {
                if column > 0 { Rectangle().fill(YardletPalette.outlineVariant).frame(width: 0.5) }
            }
            .overlay(alignment: .top) {
                if row > 0 { Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5) }
            }
    }
}

/// Lays a table's cells, given row by row, in columns as wide as their widest cell (up to `maxColumnWidth`, where a
/// cell wraps) and rows as tall as their tallest, offering each cell its column's width and its row's height.
private struct TableLayout: Layout {
    let columns: Int
    let maxColumnWidth: CGFloat

    struct Measure {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Measure { measure(subviews) }

    func updateCache(_ cache: inout Measure, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ subviews: Subviews) -> Measure {
        var widths = [CGFloat](repeating: 0, count: columns)
        for (index, cell) in subviews.enumerated() {
            let column = index % columns
            widths[column] = max(widths[column], min(cell.sizeThatFits(.unspecified).width, maxColumnWidth))
        }
        var heights = [CGFloat](repeating: 0, count: (subviews.count + columns - 1) / columns)
        for (index, cell) in subviews.enumerated() {
            let size = cell.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil))
            heights[index / columns] = max(heights[index / columns], size.height)
        }
        return Measure(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) {
        var y = bounds.minY
        for row in cache.heights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: cache.widths[column], height: cache.heights[row]))
                x += cache.widths[column]
            }
            y += cache.heights[row]
        }
    }
}

/// A Markdown list: each item's marker in a column of its own, so a line that wraps starts under the words rather
/// than under the marker, a nested item indented under its parent.
private struct MarkdownListView: View {
    let items: [MarkdownView.ListItem]
    let font: Font
    let opensFiles: Bool
    @ScaledMetric(relativeTo: .body) private var levelIndent: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.marker)
                        .font(font.monospacedDigit())
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .frame(minWidth: markerWidth, alignment: .trailing)
                        .fixedSize()
                    ConversationText(item.text, opensFiles: opensFiles)
                        .font(font)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * levelIndent)
            }
        }
    }
}
