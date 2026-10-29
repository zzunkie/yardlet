import Foundation
import Markdown

enum TranscriptMarkdownBlock: Equatable, Sendable {
    case paragraph(TranscriptInlineContent)
    case heading(level: Int, text: TranscriptInlineContent)
    case unorderedList([TranscriptMarkdownListItem], isLoose: Bool = false)
    case orderedList(start: Int, items: [TranscriptMarkdownListItem], isLoose: Bool = false)
    case blockQuote([TranscriptMarkdownBlock])
    case code(language: String?, text: String)
    case table(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]], alignments: [TranscriptTableAlignment] = [])
    case divider
    // The cards a Codex message's directives draw (`CodexMessageDirectives`).
    case suggestedTask(CodexSuggestedTask)
    /// A disclosure: its summary, whether it starts open, and the Markdown inside it.
    case details(summary: String, isOpen: Bool, blocks: [TranscriptMarkdownBlock])
    case reviewComments([CodexReviewComment])
    case visualization(CodexVisualization)
}

/// How a message's Markdown is read. A Codex message also holds the directives the Codex app draws.
enum TranscriptMarkdownDialect: Equatable, Sendable {
    case standard
    case codex
}

struct TranscriptMarkdownListItem: Equatable, Sendable, ExpressibleByStringLiteral {
    let blocks: [TranscriptMarkdownBlock]
    let checked: Bool?

    init(blocks: [TranscriptMarkdownBlock], checked: Bool? = nil) {
        self.blocks = blocks
        self.checked = checked
    }

    init(stringLiteral value: String) {
        self.init(blocks: [.paragraph(TranscriptInlineContent(stringLiteral: value))])
    }
}

enum TranscriptTableAlignment: Equatable, Sendable {
    case leading, center, trailing
}

/// The blocks a message's Markdown was last read into, by the source each was read from: its top-level
/// blocks and the items of its top-level lists. Reading the message again, as it streams, keeps those
/// whose source is unchanged as the very same values instead of building them anew. Besides the
/// building, that spares every comparison after it: SwiftUI and the text view compare a message's
/// blocks with the ones they drew, and two equal `AttributedString`s compare in an instant when they
/// share storage, but character by character, at about 140 ns a character, when they do not.
///
/// A block's reading depends on its own source alone, except where a link reference definition
/// elsewhere in the message resolves a link; a message that may hold one is read whole.
final class TranscriptMarkdownReadings {
    fileprivate var blocks: [Substring: TranscriptMarkdownBlock] = [:]
    fileprivate var items: [Substring: TranscriptMarkdownListItem] = [:]

    init() {}
}

struct TranscriptMarkdownDocument: Equatable, Sendable {
    let blocks: [TranscriptMarkdownBlock]

    /// - Parameter readings: what an earlier reading of the same message kept, which this reading
    ///   reuses and then replaces.
    init(_ source: String, dialect: TranscriptMarkdownDialect = .standard, readings: TranscriptMarkdownReadings? = nil) {
        let reading = readings.flatMap { source.contains("]:") ? nil : Reading(earlier: $0) }
        switch dialect {
        case .standard: blocks = Self.blocks(source, reading: reading)
        case .codex: blocks = Self.codexBlocks(source, depth: 0, reading: reading)
        }
        if let readings {
            readings.blocks = reading?.blocks ?? [:]
            readings.items = reading?.items ?? [:]
        }
    }

    /// One reading's blocks by their source, and the earlier reading's it takes from.
    private final class Reading {
        let earlier: TranscriptMarkdownReadings
        var blocks: [Substring: TranscriptMarkdownBlock] = [:]
        var items: [Substring: TranscriptMarkdownListItem] = [:]

        init(earlier: TranscriptMarkdownReadings) { self.earlier = earlier }

        func block(_ source: Substring, read: () -> TranscriptMarkdownBlock) -> TranscriptMarkdownBlock {
            let block = blocks[source] ?? earlier.blocks[source] ?? read()
            blocks[source] = block
            return block
        }

        func item(_ source: Substring, read: () -> TranscriptMarkdownListItem) -> TranscriptMarkdownListItem {
            let item = items[source] ?? earlier.items[source] ?? read()
            items[source] = item
            return item
        }
    }

    private static func blocks(_ source: String, reading: Reading?) -> [TranscriptMarkdownBlock] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let context = SourceContext(source)
        return document.children.map { context.topLevelBlock($0, reading: reading) }
    }

    /// A Codex message's Markdown with its directive cards in place; a disclosure's Markdown is read the
    /// same way, to a bounded depth.
    private static func codexBlocks(_ source: String, depth: Int, reading: Reading?) -> [TranscriptMarkdownBlock] {
        guard depth < 8 else { return blocks(source, reading: reading) }
        return CodexMessageDirectives.blocks(source).flatMap { block -> [TranscriptMarkdownBlock] in
            switch block {
            case let .markdown(text): blocks(text, reading: reading)
            case let .suggestedTask(task): [.suggestedTask(task)]
            case let .details(summary, isOpen, body):
                [.details(summary: summary, isOpen: isOpen, blocks: codexBlocks(body, depth: depth + 1, reading: reading))]
            case let .reviewComments(comments): [.reviewComments(comments)]
            case let .visualization(visualization): [.visualization(visualization)]
            }
        }
    }

    /// A path includes the item index between a list block and its child block.
    func block(at path: [Int]) -> TranscriptMarkdownBlock? {
        var children = blocks
        var cursor = 0
        while cursor < path.count {
            guard children.indices.contains(path[cursor]) else { return nil }
            let block = children[path[cursor]]
            cursor += 1
            if cursor == path.count { return block }
            switch block {
            case let .blockQuote(quoted), let .details(_, _, quoted): children = quoted
            case let .unorderedList(items, _), let .orderedList(_, items, _):
                guard items.indices.contains(path[cursor]) else { return nil }
                children = items[path[cursor]].blocks
                cursor += 1
            default: return nil
            }
        }
        return nil
    }

    private struct SourceContext {
        let source: String
        let lines: [Substring]
        let endings: [String]

        init(_ source: String) {
            self.source = source
            // CommonMark source positions count CR, LF and CRLF, not Unicode separators.
            let lines = source.split(omittingEmptySubsequences: false) {
                $0 == "\r" || $0 == "\n" || $0 == "\r\n"
            }
            self.lines = lines
            endings = lines.indices.map { index in
                let end = index + 1 < lines.count ? lines[index + 1].startIndex : source.endIndex
                return String(source[lines[index].endIndex..<end])
            }
        }

        /// A block of the document itself, kept from the earlier reading when its source is unchanged;
        /// a list's items likewise.
        func topLevelBlock(_ markup: any Markup, reading: Reading?) -> TranscriptMarkdownBlock {
            guard let reading, let key = text(of: markup) else { return block(markup, depth: 0) }
            return reading.block(key) {
                switch markup {
                case let list as UnorderedList:
                    .unorderedList(list.listItems.map { topLevelItem($0, reading: reading) }, isLoose: isLoose(list))
                case let list as OrderedList:
                    .orderedList(start: Int(list.startIndex), items: list.listItems.map { topLevelItem($0, reading: reading) },
                                 isLoose: isLoose(list))
                default:
                    block(markup, depth: 0)
                }
            }
        }

        private func topLevelItem(_ markup: ListItem, reading: Reading) -> TranscriptMarkdownListItem {
            guard let key = text(of: markup) else { return item(markup, depth: 0) }
            return reading.item(key) { item(markup, depth: 0) }
        }

        /// The whole lines `markup` was read from, with the line breaks between them.
        private func text(of markup: any Markup) -> Substring? {
            guard let range = markup.range else { return nil }
            let first = range.lowerBound.line - 1, last = min(lines.count, range.upperBound.line) - 1
            guard lines.indices.contains(first), first <= last else { return nil }
            return source[lines[first].startIndex..<lines[last].endIndex]
        }

        func block(_ markup: any Markup, depth: Int) -> TranscriptMarkdownBlock {
            // Bound the native view tree; unusually deep content remains readable as source.
            guard depth < 24 else { return .paragraph(TranscriptInlineContent(plainText: sourceText(markup))) }
            switch markup {
            case let paragraph as Paragraph:
                return .paragraph(inline(paragraph))
            case let heading as Heading:
                return .heading(level: heading.level, text: inline(heading))
            case let list as UnorderedList:
                return .unorderedList(list.listItems.map { item($0, depth: depth) }, isLoose: isLoose(list))
            case let list as OrderedList:
                return .orderedList(start: Int(list.startIndex), items: list.listItems.map { item($0, depth: depth) }, isLoose: isLoose(list))
            case let quote as BlockQuote:
                return .blockQuote(quote.children.map { block($0, depth: depth + 1) })
            case let code as CodeBlock:
                return .code(language: code.language, text: codeText(code))
            case let table as Table:
                let alignments: [TranscriptTableAlignment] = table.columnAlignments.map {
                    switch $0 {
                    case .center: .center
                    case .right: .trailing
                    default: .leading
                    }
                }
                return .table(headers: table.head.cells.map(inline), rows: table.body.rows.map { $0.cells.map(inline) }, alignments: alignments)
            case is ThematicBreak:
                return .divider
            default:
                return .paragraph(TranscriptInlineContent(plainText: sourceText(markup)))
            }
        }

        private func item(_ item: ListItem, depth: Int) -> TranscriptMarkdownListItem {
            TranscriptMarkdownListItem(
                blocks: item.children.map { block($0, depth: depth + 1) },
                checked: item.checkbox.map { $0 == .checked }
            )
        }

        private func inline(_ markup: any Markup) -> TranscriptInlineContent {
            TranscriptInlineContent(markup: markup)
        }

        private func sourceText(_ markup: any Markup) -> String {
            guard let range = markup.range else { return "" }
            let first = max(0, range.lowerBound.line - 1)
            let last = min(lines.count - 1, range.upperBound.line - 1)
            guard first <= last else { return "" }
            return (first...last).map { String(lines[$0]) }.joined(separator: "\n")
        }

        private func isLoose(_ list: any ListItemContainer) -> Bool {
            let items = Array(list.listItems)
            // cmark's Swift tree does not expose tightness; inspect gaps between direct blocks.
            for item in items where separatedByBlankLine(Array(item.children)) { return true }
            return zip(items, items.dropFirst()).contains { previous, next in
                guard let end = Array(previous.children).last?.range?.upperBound.line,
                      let start = next.range?.lowerBound.line else { return false }
                return hasBlankLine(after: end, before: start)
            }
        }

        private func separatedByBlankLine(_ blocks: [any Markup]) -> Bool {
            zip(blocks, blocks.dropFirst()).contains { previous, next in
                guard let end = previous.range?.upperBound.line,
                      let start = next.range?.lowerBound.line else { return false }
                return hasBlankLine(after: end, before: start)
            }
        }

        private func hasBlankLine(after end: Int, before start: Int) -> Bool {
            guard end < start - 1 else { return false }
            return (end..<start - 1).contains { index in
                lines.indices.contains(index) && lines[index].allSatisfy { $0.isWhitespace || $0 == ">" }
            }
        }

        private func codeText(_ code: CodeBlock) -> String {
            // cmark removes container markers/indentation and normalizes line endings. Restore
            // the original separators so copying code still preserves mixed LF/CRLF endings.
            var content = code.code.split(separator: "\n", omittingEmptySubsequences: false)
            if code.code.hasSuffix("\n") { content.removeLast() }
            guard let range = code.range else { return content.joined(separator: "\n") }
            let start = range.lowerBound.line - 1
            guard lines.indices.contains(start) else { return content.joined(separator: "\n") }
            let marker = String(decoding: lines[start].utf8.dropFirst(max(0, range.lowerBound.column - 1)), as: UTF8.self)
            let fenced = marker.hasPrefix("```") || marker.hasPrefix("~~~")
            let first = start + (fenced ? 1 : 0)
            return content.enumerated().map { offset, line in
                guard offset < content.count - 1 else { return String(line) }
                let index = first + offset
                let ending = endings.indices.contains(index) && !endings[index].isEmpty ? endings[index] : "\n"
                return String(line) + ending
            }.joined()
        }
    }
}
