import Foundation
import UWP
import WinUI

/// A message's Markdown drawn as XAML from the engine's reading of it (`TranscriptMarkdownDocument`), as the Mac
/// draws it: paragraphs and headings with their bold, italic, code, struck and linked words, lists, quotes, code
/// blocks, tables and rules. What only the Codex app's cards show (a suggested task, review comments, a
/// visualization) is left out; a disclosure shows its summary and what it holds.
@MainActor
enum MarkdownView {
    static func element(_ markdown: String) -> StackPanel {
        stack(TranscriptMarkdownDocument(markdown).blocks)
    }

    private static func stack(_ blocks: [TranscriptMarkdownBlock]) -> StackPanel {
        let panel = StackPanel()
        panel.spacing = 8
        for block in blocks {
            if let element = element(block) { panel.children.append(element) }
        }
        return panel
    }

    private static func element(_ block: TranscriptMarkdownBlock) -> UIElement? {
        switch block {
        case let .paragraph(content):
            return text(content)
        case let .heading(level, content):
            let heading = text(content)
            heading.fontSize = level <= 1 ? 20 : level == 2 ? 17 : 15
            heading.fontWeight = UWP.FontWeight(weight: 600)
            return heading
        case let .unorderedList(items, _):
            return list(items.map { ($0.checked.map { $0 ? "☑" : "☐" } ?? "•", $0) })
        case let .orderedList(start, items, _):
            return list(items.enumerated().map { ("\(start + $0.offset).", $0.element) })
        case let .blockQuote(blocks):
            let quote = Border()
            quote.borderThickness = Thickness(left: 3, top: 0, right: 0, bottom: 0)
            quote.borderBrush = subtle(alpha: 0x60)
            quote.padding = Thickness(left: 12, top: 0, right: 0, bottom: 0)
            quote.child = stack(blocks)
            quote.opacity = 0.8
            return quote
        case let .code(_, code):
            let block = TextBlock()
            block.text = code
            block.fontFamily = FontFamily("Consolas")
            block.fontSize = 13
            block.textWrapping = .wrap
            block.isTextSelectionEnabled = true
            let box = Border()
            box.background = subtle(alpha: 0x18)
            box.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
            box.padding = Thickness(left: 12, top: 8, right: 12, bottom: 8)
            box.child = block
            return box
        case let .table(headers, rows, _):
            return table(headers: headers, rows: rows)
        case .divider:
            let rule = Border()
            rule.height = 1
            rule.background = subtle(alpha: 0x40)
            return rule
        case let .details(summary, _, blocks):
            let panel = StackPanel()
            panel.spacing = 6
            let title = TextBlock()
            title.text = summary
            title.fontWeight = UWP.FontWeight(weight: 600)
            title.textWrapping = .wrap
            panel.children.append(title)
            panel.children.append(stack(blocks))
            return panel
        case .suggestedTask, .reviewComments, .visualization:
            return nil
        }
    }

    /// One paragraph's words, each run with its styles.
    static func text(_ content: TranscriptInlineContent) -> TextBlock {
        let block = TextBlock()
        block.fontSize = 14
        block.textWrapping = .wrap
        block.isTextSelectionEnabled = true
        let attributed = content.attributed
        for run in attributed.runs {
            let words = Run()
            words.text = String(attributed[run.range].characters)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { words.fontWeight = UWP.FontWeight(weight: 600) }
                if intent.contains(.emphasized) { words.fontStyle = .italic }
                if intent.contains(.code) { words.fontFamily = FontFamily("Consolas") }
                if intent.contains(.strikethrough) { words.textDecorations = .strikethrough }
            }
            if run.link != nil { words.textDecorations = .underline }
            block.inlines.append(words)
        }
        return block
    }

    /// Items beside their marks: a column for the marks, one for what each item holds.
    private static func list(_ items: [(mark: String, item: TranscriptMarkdownListItem)]) -> Grid {
        let grid = Grid()
        grid.rowSpacing = 4
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
            let mark = TextBlock()
            mark.text = entry.mark
            mark.fontSize = 14
            mark.margin = Thickness(left: 0, top: 0, right: 8, bottom: 0)
            try? Grid.setRow(mark, Int32(index))
            grid.children.append(mark)
            let content = stack(entry.item.blocks)
            try? Grid.setRow(content, Int32(index))
            try? Grid.setColumn(content, 1)
            grid.children.append(content)
        }
        return grid
    }

    private static func table(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]]) -> Grid {
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
                let text = text(cell)
                if rowIndex == 0 { text.fontWeight = UWP.FontWeight(weight: 600) }
                try? Grid.setRow(text, Int32(rowIndex))
                try? Grid.setColumn(text, Int32(column))
                grid.children.append(text)
            }
        }
        return grid
    }

    /// A gray that reads on a light and a dark window alike.
    private static func subtle(alpha: UInt8) -> SolidColorBrush {
        SolidColorBrush(UWP.Color(a: alpha, r: 0x80, g: 0x80, b: 0x80))
    }
}
