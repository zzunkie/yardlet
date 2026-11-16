import Foundation
import UWP
import WinUI

/// A message's Markdown drawn as XAML from the engine's reading of it (`TranscriptMarkdownDocument`), as the Mac
/// draws it (`TranscriptProse`, `TranscriptCodeBlock`): paragraphs at 14 with the Mac's spacing between lines and
/// 15 between blocks; headings at 17, 15 and 13; bold, italic, code, struck and linked words, code in Windows' code
/// font at the size of its line; lists with their marks in the secondary tone; quotes in the secondary tone beside a
/// bar; code blocks in a ringed box under a header with their language and Copy, colored as the Mac colors them
/// (`TranscriptCodeSyntax`), the first 40 lines shown until "View full code"; tables and rules. What only the Codex
/// app's cards show (a suggested task, review comments, a visualization) is left out; a disclosure shows its summary
/// and what it holds.
@MainActor
enum MarkdownView {
    static func element(_ markdown: String, dialect: TranscriptMarkdownDialect = .standard) -> StackPanel {
        stack(TranscriptMarkdownDocument(markdown, dialect: dialect).blocks, tone: .primary)
    }

    private static func stack(_ blocks: [TranscriptMarkdownBlock], tone: ConversationStyle.Tone,
                              spacing: Double = WindowsTheme.proseBlockSpacing) -> StackPanel {
        let panel = StackPanel()
        panel.spacing = spacing
        for block in blocks {
            if let element = element(block, tone: tone) { panel.children.append(element) }
        }
        return panel
    }

    private static func element(_ block: TranscriptMarkdownBlock, tone: ConversationStyle.Tone) -> UIElement? {
        switch block {
        case let .paragraph(content):
            return text(content, tone: tone)
        case let .heading(level, content):
            let (size, weight): (Double, UInt16) = switch level {
            case 1: (17, 600)
            case 2: (15, 600)
            case 3: (13, 700)
            default: (13, 600)
            }
            let heading = text(content, size: size, tone: tone)
            heading.fontWeight = UWP.FontWeight(weight: weight)
            if level <= 2 { heading.margin = Thickness(left: 0, top: 3, right: 0, bottom: 0) }
            return heading
        case let .unorderedList(items, isLoose):
            return list(items.map { ($0.checked.map { $0 ? "☑" : "☐" } ?? "•", $0) }, isLoose: isLoose, tone: tone)
        case let .orderedList(start, items, isLoose):
            return list(items.enumerated().map { ("\(start + $0.offset).", $0.element) }, isLoose: isLoose, tone: tone)
        case let .blockQuote(blocks):
            let quote = Border()
            quote.borderThickness = Thickness(left: 2, top: 0, right: 0, bottom: 0)
            quote.borderBrush = WindowsTheme.strongSeparator.brush
            quote.padding = Thickness(left: 12, top: 0, right: 0, bottom: 0)
            quote.child = stack(blocks, tone: .secondary)
            return quote
        case let .code(language, code):
            return codeBlock(language: language, code: code)
        case let .table(headers, rows, _):
            return table(headers: headers, rows: rows, tone: tone)
        case .divider:
            let rule = Border()
            rule.height = 1
            rule.background = WindowsTheme.separator.brush
            return rule
        case let .details(summary, _, blocks):
            let panel = StackPanel()
            panel.spacing = 6
            panel.children.append(ConversationStyle.text(summary, tone: tone, semibold: true))
            panel.children.append(stack(blocks, tone: tone))
            return panel
        case .suggestedTask, .reviewComments, .visualization:
            return nil
        }
    }

    /// One paragraph's words, each run with its styles: code in the code font, links in the accent.
    static func text(_ content: TranscriptInlineContent, size: Double = ConversationStyle.bodySize,
                     tone: ConversationStyle.Tone = .primary) -> TextBlock {
        let block = ConversationStyle.text("", size: size, tone: tone)
        block.lineHeight = ConversationStyle.lineHeight(size)
        let attributed = content.attributed
        for run in attributed.runs {
            let words = Run()
            words.text = String(attributed[run.range].characters)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { words.fontWeight = UWP.FontWeight(weight: 700) }
                if intent.contains(.emphasized) { words.fontStyle = .italic }
                if intent.contains(.code) { words.fontFamily = ConversationStyle.codeFont() }
                if intent.contains(.strikethrough) { words.textDecorations = .strikethrough }
            }
            if run.link != nil {
                words.foreground = WindowsTheme.accent.brush
                words.textDecorations = .underline
            }
            block.inlines.append(words)
        }
        return block
    }

    /// Items beside their marks: a column for the marks, one for what each item holds.
    private static func list(_ items: [(mark: String, item: TranscriptMarkdownListItem)], isLoose: Bool,
                             tone: ConversationStyle.Tone) -> Grid {
        let grid = Grid()
        grid.rowSpacing = isLoose ? WindowsTheme.proseBlockSpacing : ConversationStyle.proseLineSpacing
        let markColumn = ColumnDefinition()
        markColumn.width = GridLength(value: 0, gridUnitType: .auto)
        let itemColumn = ColumnDefinition()
        itemColumn.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(markColumn)
        grid.columnDefinitions.append(itemColumn)
        for (index, entry) in items.enumerated() {
            let row = RowDefinition()
            row.height = GridLength(value: 0, gridUnitType: .auto)
            grid.rowDefinitions.append(row)
            let mark = ConversationStyle.text(entry.mark, tone: .secondary, selectable: false, wraps: false)
            mark.lineHeight = ConversationStyle.lineHeight(ConversationStyle.bodySize)
            mark.margin = Thickness(left: 4, top: 0, right: 10, bottom: 0)
            try? Grid.setRow(mark, Int32(index))
            grid.children.append(mark)
            let content = stack(entry.item.blocks, tone: tone, spacing: ConversationStyle.proseLineSpacing)
            try? Grid.setRow(content, Int32(index))
            try? Grid.setColumn(content, 1)
            grid.children.append(content)
        }
        return grid
    }

    private static func table(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]],
                              tone: ConversationStyle.Tone) -> UIElement {
        let grid = Grid()
        grid.columnSpacing = 16
        grid.rowSpacing = 6
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        for _ in 0..<columns {
            let column = ColumnDefinition()
            column.width = GridLength(value: 0, gridUnitType: .auto)
            grid.columnDefinitions.append(column)
        }
        for (rowIndex, cells) in ([headers] + rows).enumerated() {
            let row = RowDefinition()
            row.height = GridLength(value: 0, gridUnitType: .auto)
            grid.rowDefinitions.append(row)
            for (column, cell) in cells.enumerated() {
                let text = text(cell, tone: tone)
                if rowIndex == 0 { text.fontWeight = UWP.FontWeight(weight: 600) }
                try? Grid.setRow(text, Int32(rowIndex))
                try? Grid.setColumn(text, Int32(column))
                grid.children.append(text)
            }
        }
        // A table wider than the message scrolls sideways.
        let scroller = ScrollViewer()
        scroller.horizontalScrollBarVisibility = .auto
        scroller.horizontalScrollMode = .enabled
        scroller.verticalScrollBarVisibility = .disabled
        scroller.verticalScrollMode = .disabled
        scroller.content = grid
        return scroller
    }

    // MARK: - Code blocks

    /// A code block as the Mac's (`TranscriptCodeBlock`): its language, or "Code", and Copy over the code, which
    /// scrolls sideways, in a box with a one-point ring and 9-point corners. Past its first 40 lines (or 6,000
    /// characters, `TranscriptCodeWindow`) it shows those and "View full code", which shows the rest in place.
    static func codeBlock(language: String?, code: String) -> UIElement {
        let title = ConversationStyle.text(language ?? L10n.string("Code"), size: ConversationStyle.captionSize,
                                           tone: .secondary, selectable: false, wraps: false)
        title.fontFamily = ConversationStyle.codeFont()
        title.verticalAlignment = .center
        let copy = ConversationStyle.copyButton(L10n.string("Copy code")) { code }
        let header = Grid()
        header.background = WindowsTheme.subtleFill.brush
        header.padding = Thickness(left: 12, top: 6, right: 8, bottom: 6)
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            header.columnDefinitions.append(column)
        }
        header.children.append(title)
        try? Grid.setColumn(copy, 1)
        header.children.append(copy)

        let window = TranscriptCodeWindow(code)
        let body = highlighted(window.text, language: language)
        let scroller = ScrollViewer()
        scroller.horizontalScrollBarVisibility = .auto
        scroller.horizontalScrollMode = .enabled
        scroller.verticalScrollBarVisibility = .disabled
        scroller.verticalScrollMode = .disabled
        scroller.padding = Thickness(left: 12, top: 12, right: 12, bottom: 12)
        scroller.content = body

        let stack = StackPanel()
        stack.children.append(header)
        stack.children.append(rule())
        stack.children.append(scroller)
        if window.isTruncated {
            let more = HyperlinkButton()
            more.content = L10n.string("View full code")
            more.fontSize = ConversationStyle.captionSize
            more.margin = Thickness(left: 6, top: 2, right: 6, bottom: 6)
            more.click.addHandler { sender, _ in
                scroller.content = highlighted(code, language: language)
                (sender as? HyperlinkButton)?.visibility = .collapsed
            }
            stack.children.append(rule())
            stack.children.append(more)
        }
        let frame = Border()
        frame.background = WindowsTheme.subtleFill.brush
        frame.borderBrush = WindowsTheme.separator.brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.cornerRadius = ConversationStyle.corners(9)
        frame.child = stack
        try? AutomationProperties.setName(frame, language ?? L10n.string("Code"))
        return frame
    }

    /// Code in the code font, its comments, strings, keywords and numbers colored as the Mac colors them.
    private static func highlighted(_ code: String, language: String?) -> TextBlock {
        let block = ConversationStyle.text("", size: ConversationStyle.codeSize, wraps: false)
        block.textTrimming = .none
        block.fontFamily = ConversationStyle.codeFont()
        block.lineHeight = (ConversationStyle.codeSize * 1.45).rounded()
        let tokens = TranscriptCodeSyntax.tokens(in: code, language: language)
        var cursor = code.startIndex
        func append(_ words: Substring, color: SolidColorBrush?) {
            guard !words.isEmpty else { return }
            let run = Run()
            run.text = String(words)
            if let color { run.foreground = color }
            block.inlines.append(run)
        }
        for token in tokens {
            guard let range = Range(token.range, in: code), range.lowerBound >= cursor else { continue }
            append(code[cursor..<range.lowerBound], color: nil)
            append(code[range], color: color(token.kind))
            cursor = range.upperBound
        }
        append(code[cursor...], color: nil)
        return block
    }

    private static func color(_ kind: TranscriptCodeSyntax.Kind) -> SolidColorBrush {
        switch kind {
        case .comment: WindowsTheme.secondaryText.brush
        case .string: ConversationStyle.codeString.brush
        case .keyword: ConversationStyle.codeKeyword.brush
        case .number: ConversationStyle.codeNumber.brush
        }
    }

    private static func rule() -> Border {
        let rule = Border()
        rule.height = 1
        rule.background = WindowsTheme.separator.brush
        return rule
    }
}
