import AppKit
import SwiftUI

// A message's prose — its paragraphs, headings, lists, quotes, code blocks and rules — drawn as one
// text, so a drag selects across them and copying gives the words as they read, as in the Claude and
// Codex apps. Tables and the Codex cards are drawn on their own between such texts.

extension TranscriptMarkdownBlock {
    /// Drawn in a message's one text: everything but tables and the Codex cards, and lists and quotes
    /// that hold nothing else.
    var isProse: Bool {
        switch self {
        case .paragraph, .heading, .code, .divider: true
        case let .unorderedList(items, _), let .orderedList(_, items, _):
            items.allSatisfy { $0.blocks.allSatisfy(\.isProse) }
        case let .blockQuote(blocks): blocks.allSatisfy(\.isProse)
        case .table, .suggestedTask, .details, .reviewComments, .visualization: false
        }
    }
}

/// A top-level prose block and its path in the message, which find's keys use.
struct TranscriptProseBlock: Equatable {
    let block: TranscriptMarkdownBlock
    let path: [Int]
}

/// What the text's look depends on beyond its blocks.
struct TranscriptProseStyle: Equatable {
    var scale: CGFloat = 1
    var isDark = false
    var workspaceURL: URL?
}

extension NSAttributedString.Key {
    /// What a copy of this range gives instead of its characters: a list marker and its tab give
    /// "1. ", a rule gives nothing.
    static let transcriptCopyText = NSAttributedString.Key("YardletTranscriptCopyText")
    /// A paragraph's drawing beyond its text (`TranscriptProseDecoration`), on its first character.
    static let transcriptDecoration = NSAttributedString.Key("YardletTranscriptDecoration")
}

/// The sizes of a code block's frame and a quote's bar, which the builder leaves room for and the
/// layout fragment draws in.
enum TranscriptProseMetrics {
    /// The language and Copy row above the code, with the rule under it.
    static let codeHeaderHeight: CGFloat = 35
    /// Around the code inside its frame.
    static let codePadding: CGFloat = 12
    /// The "View full code" row under a long block's first lines, with the rule above it.
    static let codeFooterHeight: CGFloat = 35
    static let codeCornerRadius: CGFloat = 9
    static let quoteIndent: CGFloat = 13
    static let quoteBarWidth: CGFloat = 3
    static let listMarkerSpacing: CGFloat = 9
}

/// What a paragraph's layout fragment draws besides its text.
final class TranscriptProseDecoration: NSObject {
    struct QuoteBar: Equatable {
        let x: CGFloat
        /// The quote starts at this paragraph: the bar starts at its first line.
        var startsHere: Bool
        /// The quote ends at this paragraph: the bar ends at its last line, not its spacing.
        var endsHere: Bool
    }

    struct Code: Equatable {
        let language: String
        let isTruncated: Bool
    }

    /// Where the paragraph's frame starts: its list's and quotes' indent.
    let indent: CGFloat
    var quoteBars: [QuoteBar] = []
    var code: Code?
    var isRule = false

    init(indent: CGFloat) {
        self.indent = indent
    }

    var isEmpty: Bool { quoteBars.isEmpty && code == nil && !isRule }
}

/// A top-level block drawn as text, with what find, the code blocks' controls and copying need.
struct TranscriptProsePiece {
    struct Segment {
        let key: ConversationFindSegmentKey
        /// In the piece's text.
        let range: NSRange
        /// The text find searched (`ConversationFindEngine.markdownSegments`), which counts its hits.
        let text: String
    }

    struct CodeBlock {
        /// The code's paragraph, in the piece's text.
        let range: NSRange
        let language: String?
        let path: [Int]
        let isTruncated: Bool
    }

    let text: NSAttributedString
    let segments: [Segment]
    let codeBlocks: [CodeBlock]
    /// The last paragraph is a code block whose frame reaches below its text.
    let trailingInset: CGFloat
}

/// Builds the text of prose blocks, block by block, so a streaming message builds again only the
/// blocks that changed.
@MainActor
struct TranscriptProseBuilder {
    let style: TranscriptProseStyle
    /// What the items of the message's top-level lists were last built into, kept and replaced as
    /// this builder builds them.
    var listItems: ListItems? = nil

    fileprivate struct Context: Equatable {
        var indent: CGFloat = 0
        var color: NSColor = .labelColor
        var listDepth = 0
        /// The marker the next paragraph starts with: a list item's first.
        var marker: Marker?
    }

    fileprivate struct Marker: Equatable {
        let text: String
        /// Where the marker starts, so markers of one list end at one column.
        let start: CGFloat
        let contentIndent: CGFloat
        let copyText: String
    }

    fileprivate struct Paragraph {
        let text: NSMutableAttributedString
        let style: NSMutableParagraphStyle
        let decoration: TranscriptProseDecoration

        /// Another paragraph alike, whose text and style can be changed apart from this one's.
        func copy() -> Paragraph {
            Paragraph(text: NSMutableAttributedString(attributedString: text),
                      style: style.mutableCopy() as! NSMutableParagraphStyle, decoration: decoration)
        }
    }

    private final class Output {
        var paragraphs: [Paragraph] = []
        var segments: [(key: ConversationFindSegmentKey, paragraph: Int, range: NSRange, text: String)] = []
        var codeBlocks: [(paragraph: Int, language: String?, path: [Int], isTruncated: Bool)] = []

        /// A list item built earlier, after what is here.
        func append(_ item: ListItems.Item) {
            let first = paragraphs.count
            paragraphs += item.paragraphs.map { $0.copy() }
            segments += item.segments.map { ($0.key, $0.paragraph + first, $0.range, $0.text) }
            codeBlocks += item.codeBlocks.map { ($0.paragraph + first, $0.language, $0.path, $0.isTruncated) }
        }
    }

    /// The paragraphs each item of a message's top-level lists was last built into, by the item's
    /// path. A list being written changes in its last item; the items before it, the same values
    /// under the same marker, take their paragraphs from here instead of being built again.
    final class ListItems {
        fileprivate struct Item {
            let item: TranscriptMarkdownListItem
            let context: Context
            let spacing: CGFloat
            /// Numbered from the item's first paragraph.
            let paragraphs: [Paragraph]
            let segments: [(key: ConversationFindSegmentKey, paragraph: Int, range: NSRange, text: String)]
            let codeBlocks: [(paragraph: Int, language: String?, path: [Int], isTruncated: Bool)]
        }

        private var earlier: [[Int]: Item] = [:]
        private var built: [[Int]: Item] = [:]
        /// Each list marker's width in the text's marker font.
        fileprivate var markerWidths: [String: CGFloat] = [:]

        init() {}

        /// Starts a build: what the last one built is what this one may keep.
        func begin() {
            earlier = built
            built = [:]
        }

        fileprivate func item(at path: [Int], _ item: TranscriptMarkdownListItem, context: Context,
                              spacing: CGFloat) -> Item? {
            guard let kept = earlier[path], kept.spacing == spacing, kept.context == context, kept.item == item
            else { return nil }
            built[path] = kept
            return kept
        }

        fileprivate func keep(_ item: Item, at path: [Int]) {
            built[path] = item
        }
    }

    // MARK: - Fonts

    var bodySize: CGFloat { 14 * style.scale }
    var codeSize: CGFloat { 12.5 * style.scale }

    private func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false,
                      monospaced: Bool = false) -> NSFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    private func markerFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: bodySize)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        ])
        return NSFont(descriptor: descriptor, size: bodySize) ?? base
    }

    // MARK: - Building

    /// `block` as text, ending in a newline unless it is the message's last.
    func piece(_ block: TranscriptProseBlock, isFirst: Bool, isLast: Bool) -> TranscriptProsePiece {
        let output = Output()
        append(block.block, path: block.path, context: Context(),
               spacingAfter: isLast ? 0 : ParityTheme.proseBlockSpacing, into: output)
        // TextKit 2 puts a paragraph's line spacing above its first line too, except for the text's
        // first paragraph. Every gap between paragraphs gives that much back, and a paragraph with less
        // line spacing (code, a rule) makes up the rest above itself, so a block can be built without
        // knowing what follows it.
        let leading = ParityTheme.proseLineSpacing * style.scale
        for (index, paragraph) in output.paragraphs.enumerated() {
            if !(isLast && index == output.paragraphs.count - 1) {
                paragraph.style.paragraphSpacing = max(0, paragraph.style.paragraphSpacing - leading)
            }
            if !(isFirst && index == 0) {
                paragraph.style.paragraphSpacingBefore += max(0, leading - paragraph.style.lineSpacing)
            }
        }
        let text = NSMutableAttributedString()
        var offsets: [Int] = []
        for (index, paragraph) in output.paragraphs.enumerated() {
            offsets.append(text.length)
            let range = NSRange(location: 0, length: paragraph.text.length)
            paragraph.text.addAttribute(.paragraphStyle, value: paragraph.style, range: range)
            if !paragraph.decoration.isEmpty, paragraph.text.length > 0 {
                paragraph.text.addAttribute(.transcriptDecoration, value: paragraph.decoration,
                                            range: NSRange(location: 0, length: 1))
            }
            text.append(paragraph.text)
            if !isLast || index < output.paragraphs.count - 1 {
                var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph.style, .font: font(size: bodySize)]
                // Blocks copy a blank line apart, as the apps' pages copy their paragraphs; a list's items
                // and a quote's lines a line apart.
                if index == output.paragraphs.count - 1 { attributes[.transcriptCopyText] = "\n\n" }
                text.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        let segments = output.segments.map { segment in
            TranscriptProsePiece.Segment(
                key: segment.key,
                range: NSRange(location: offsets[segment.paragraph] + segment.range.location, length: segment.range.length),
                text: segment.text)
        }
        let codeBlocks = output.codeBlocks.map { code in
            TranscriptProsePiece.CodeBlock(
                range: NSRange(location: offsets[code.paragraph], length: output.paragraphs[code.paragraph].text.length),
                language: code.language, path: code.path, isTruncated: code.isTruncated)
        }
        var trailingInset: CGFloat = 0
        if isLast, let last = output.paragraphs.last, let code = last.decoration.code {
            trailingInset = TranscriptProseMetrics.codePadding + (code.isTruncated ? TranscriptProseMetrics.codeFooterHeight : 0)
        }
        return TranscriptProsePiece(text: text, segments: segments, codeBlocks: codeBlocks, trailingInset: trailingInset)
    }

    private func append(_ block: TranscriptMarkdownBlock, path: [Int], context: Context, spacingAfter: CGFloat,
                        into output: Output) {
        switch block {
        case let .paragraph(text):
            inline(text, size: bodySize, weight: .regular, path: path, context: context, spacingAfter: spacingAfter,
                   into: output)

        case let .heading(level, text):
            let (size, weight): (CGFloat, NSFont.Weight) = switch level {
            case 1: (17, .semibold)
            case 2: (15, .semibold)
            case 3: (13, .bold)
            default: (13, .semibold)
            }
            inline(text, size: size * style.scale, weight: weight, path: path, context: context,
                   spacingAfter: spacingAfter, spacingBefore: level <= 2 ? 3 : 0, into: output)

        case let .unorderedList(items, isLoose):
            list(items, start: nil, isLoose: isLoose, path: path, context: context, spacingAfter: spacingAfter,
                 into: output)

        case let .orderedList(start, items, isLoose):
            list(items, start: start, isLoose: isLoose, path: path, context: context, spacingAfter: spacingAfter,
                 into: output)

        case let .blockQuote(blocks):
            var inner = context
            inner.indent += TranscriptProseMetrics.quoteIndent
            inner.color = .secondaryLabelColor
            let first = output.paragraphs.count
            if blocks.isEmpty {
                emptyParagraph(context: inner, spacingAfter: spacingAfter, into: output)
            }
            for (index, child) in blocks.enumerated() {
                append(child, path: path + [index], context: inner,
                       spacingAfter: index == blocks.count - 1 ? spacingAfter : ParityTheme.proseBlockSpacing,
                       into: output)
                inner.marker = nil
            }
            let end = output.paragraphs.count
            for index in first..<end {
                output.paragraphs[index].decoration.quoteBars.append(.init(
                    x: context.indent, startsHere: index == first, endsHere: index == end - 1))
            }

        case let .code(language, text):
            if context.marker != nil { markerParagraph(context: context, into: output) }
            code(language: language, text: text, path: path, context: context, spacingAfter: spacingAfter,
                 into: output)

        case .divider:
            if context.marker != nil { markerParagraph(context: context, into: output) }
            rule(context: context, spacingAfter: spacingAfter, into: output)

        case .table, .suggestedTask, .details, .reviewComments, .visualization:
            // Not prose (`isProse`); a run never holds one.
            break
        }
    }

    private func paragraphStyle(context: Context, spacingAfter: CGFloat, spacingBefore: CGFloat = 0,
                                lineSpacing: CGFloat? = nil) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing ?? ParityTheme.proseLineSpacing * style.scale
        paragraph.paragraphSpacing = spacingAfter
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.firstLineHeadIndent = context.indent
        paragraph.headIndent = context.indent
        return paragraph
    }

    /// A paragraph of inline Markdown, after its list item's marker when it is the item's first.
    private func inline(_ content: TranscriptInlineContent, size: CGFloat, weight: NSFont.Weight, path: [Int], context: Context,
                        spacingAfter: CGFloat, spacingBefore: CGFloat = 0, into output: Output) {
        let text = NSMutableAttributedString()
        let paragraph = paragraphStyle(context: context, spacingAfter: spacingAfter, spacingBefore: spacingBefore)
        if let marker = context.marker {
            text.append(markerText(marker))
            paragraph.firstLineHeadIndent = marker.start
            paragraph.headIndent = marker.contentIndent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: marker.contentIndent)]
        }
        let start = text.length
        let resolved = content.resolved(relativeTo: style.workspaceURL)
        for run in resolved.runs {
            let intent = run.inlinePresentationIntent ?? []
            let runFont = font(size: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight,
                               italic: intent.contains(.emphasized), monospaced: intent.contains(.code))
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: context.color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            // A soft or hard break stays in its paragraph, as the line it breaks reads.
            let characters = String(resolved[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            text.append(NSAttributedString(string: characters, attributes: attributes))
        }
        let index = output.paragraphs.count
        output.paragraphs.append(Paragraph(text: text, style: paragraph,
                                           decoration: TranscriptProseDecoration(indent: context.indent)))
        output.segments.append((.block(path), index, NSRange(location: start, length: text.length - start),
                                content.plainText))
    }

    private func markerText(_ marker: Marker) -> NSAttributedString {
        NSAttributedString(string: marker.text + "\t", attributes: [
            .font: markerFont(), .foregroundColor: NSColor.secondaryLabelColor,
            .transcriptCopyText: marker.copyText
        ])
    }

    /// A list item whose first block is not a paragraph has its marker on a line of its own.
    private func markerParagraph(context: Context, into output: Output) {
        guard let marker = context.marker else { return }
        let paragraph = paragraphStyle(context: context, spacingAfter: 0)
        paragraph.firstLineHeadIndent = marker.start
        paragraph.headIndent = marker.contentIndent
        output.paragraphs.append(Paragraph(text: NSMutableAttributedString(attributedString: markerText(marker)),
                                           style: paragraph, decoration: TranscriptProseDecoration(indent: context.indent)))
    }

    private func emptyParagraph(context: Context, spacingAfter: CGFloat, into output: Output) {
        if context.marker != nil {
            markerParagraph(context: context, into: output)
            output.paragraphs[output.paragraphs.count - 1].style.paragraphSpacing = spacingAfter
            return
        }
        output.paragraphs.append(Paragraph(
            text: NSMutableAttributedString(string: "", attributes: [.font: font(size: bodySize)]),
            style: paragraphStyle(context: context, spacingAfter: spacingAfter),
            decoration: TranscriptProseDecoration(indent: context.indent)))
    }

    private func list(_ items: [TranscriptMarkdownListItem], start: Int?, isLoose: Bool, path: [Int],
                      context: Context, spacingAfter: CGFloat, into output: Output) {
        let markers = items.enumerated().map { offset, item in
            item.checked.map { $0 ? "☑" : "☐" } ?? start.map { "\($0 + offset)." } ?? "•"
        }
        let markerFont = markerFont()
        // A list being written measures only the markers the message did not have yet.
        let widths = markers.map { marker in
            if let width = listItems?.markerWidths[marker] { return width }
            let width = (marker as NSString).size(withAttributes: [.font: markerFont]).width
            listItems?.markerWidths[marker] = width
            return width
        }
        let column = widths.max() ?? 0
        let contentIndent = context.indent + ceil(column) + TranscriptProseMetrics.listMarkerSpacing
        let itemSpacing = (isLoose ? 15 : 10) * style.scale
        // A top-level list's items keep what they were built into; a nested or quoted one is built with
        // the item around it.
        let kept = path.count == 1 ? listItems : nil
        for (offset, item) in items.enumerated() {
            let spacing = offset == items.count - 1 ? spacingAfter : itemSpacing
            var inner = context
            inner.indent = contentIndent
            inner.listDepth += 1
            inner.marker = Marker(
                text: markers[offset], start: context.indent + ceil(column) - widths[offset], contentIndent: contentIndent,
                copyText: String(repeating: "  ", count: context.listDepth) + markers[offset] + " ")
            let itemPath = path + [offset]
            if let built = kept?.item(at: itemPath, item, context: inner, spacing: spacing) {
                output.append(built)
                continue
            }
            let first = (paragraph: output.paragraphs.count, segment: output.segments.count, code: output.codeBlocks.count)
            let marker = inner
            if item.blocks.isEmpty {
                emptyParagraph(context: inner, spacingAfter: spacing, into: output)
            }
            for (index, child) in item.blocks.enumerated() {
                append(child, path: itemPath + [index], context: inner,
                       spacingAfter: index == item.blocks.count - 1 ? spacing : ParityTheme.proseBlockSpacing,
                       into: output)
                inner.marker = nil
            }
            kept?.keep(ListItems.Item(
                item: item, context: marker, spacing: spacing,
                paragraphs: output.paragraphs[first.paragraph...].map { $0.copy() },
                segments: output.segments[first.segment...].map { ($0.key, $0.paragraph - first.paragraph, $0.range, $0.text) },
                codeBlocks: output.codeBlocks[first.code...].map {
                    ($0.paragraph - first.paragraph, $0.language, $0.path, $0.isTruncated)
                }
            ), at: itemPath)
        }
    }

    /// A code block: its first lines (`TranscriptCodeWindow`), coloured, in one paragraph its frame
    /// is drawn around, with room above for its language and Copy and below for "View full code".
    private func code(language: String?, text: String, path: [Int], context: Context, spacingAfter: CGFloat,
                      into output: Output) {
        let window = TranscriptCodeWindow(text)
        let code = TranscriptCodeBlock.highlightedText(window.text, language: language, isDark: style.isDark)
        let range = NSRange(location: 0, length: code.length)
        code.addAttribute(.font, value: font(size: codeSize, monospaced: true), range: range)
        code.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            if value == nil { code.addAttribute(.foregroundColor, value: NSColor.labelColor, range: run) }
        }
        // One paragraph, so its frame is one rectangle; a copy gives its lines back.
        code.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: range)
        if code.length == 0 {
            code.append(NSAttributedString(string: " ", attributes: [
                .font: font(size: codeSize, monospaced: true), .transcriptCopyText: ""
            ]))
        }
        let inset = context.indent + TranscriptProseMetrics.codePadding
        let paragraph = paragraphStyle(
            context: context,
            spacingAfter: TranscriptProseMetrics.codePadding
                + (window.isTruncated ? TranscriptProseMetrics.codeFooterHeight : 0) + spacingAfter,
            spacingBefore: TranscriptProseMetrics.codeHeaderHeight + TranscriptProseMetrics.codePadding,
            lineSpacing: 0)
        paragraph.firstLineHeadIndent = inset
        paragraph.headIndent = inset
        paragraph.tailIndent = -TranscriptProseMetrics.codePadding
        let decoration = TranscriptProseDecoration(indent: context.indent)
        decoration.code = .init(language: language ?? L10n.string("Code"), isTruncated: window.isTruncated)
        let index = output.paragraphs.count
        output.paragraphs.append(Paragraph(text: code, style: paragraph, decoration: decoration))
        output.segments.append((.block(path), index, NSRange(location: 0, length: window.text.utf16.count), window.text))
        output.codeBlocks.append((index, language, path, window.isTruncated))
    }

    /// A thematic break: a hairline across the text, which copies as nothing.
    private func rule(context: Context, spacingAfter: CGFloat, into output: Output) {
        let paragraph = paragraphStyle(context: context, spacingAfter: spacingAfter, lineSpacing: 0)
        paragraph.minimumLineHeight = 1
        paragraph.maximumLineHeight = 1
        let decoration = TranscriptProseDecoration(indent: context.indent)
        decoration.isRule = true
        output.paragraphs.append(Paragraph(
            text: NSMutableAttributedString(string: "\u{00A0}", attributes: [
                .font: NSFont.systemFont(ofSize: 1), .transcriptCopyText: ""
            ]),
            style: paragraph, decoration: decoration))
    }
}
