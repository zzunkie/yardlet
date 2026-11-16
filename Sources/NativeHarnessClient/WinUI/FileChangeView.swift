import Foundation
import UWP
import WinUI

/// A file's change as the Mac draws it (`CodexFileDiffBox`, `CodexDiffPreviewLines`): the file's name and its lines
/// added and removed over the diff, in a box with a one-point ring, the diff's lines in the code font at a fixed
/// height, each with its number and its mark, added lines tinted green and removed ones red. Up to 14 lines show as
/// they are; more scroll inside a box of that height, and a long line scrolls sideways. The lines are the engine's
/// (`CodexFileChangeCardProjection.Row`, `PermissionRequestPreviewProjection`), as the Mac reads them. A change's line
/// in the conversation opens into this box (`ConversationWorkLines`), and so does an approval card's preview of an
/// edit (`RequestCard`).
@MainActor
enum FileChangeView {
    /// The lines a diff shows before it scrolls.
    static let visibleLineLimit = 14
    /// A diff line's height, about the Mac's 17 for the code size here.
    private static let lineHeight: Double = 18

    /// A file change's box: its `title` and counts over its lines, or why there are none to show.
    static func diffBox(_ row: CodexFileChangeCardProjection.Row, title: String) -> UIElement {
        var content: [UIElement] = []
        switch row.preview {
        case .missing:
            break
        case .tooLarge:
            content.append(notice(L10n.string("Diff too large to preview")))
        case .available:
            let preview = row.previewLines
            if preview.lines.isEmpty {
                content.append(notice(L10n.string(row.kind == .delete ? "Contents deleted" : "No changes")))
            } else {
                content.append(lines(preview.lines))
                if preview.hiddenLineCount > 0 {
                    content.append(rule())
                    content.append(notice(L10n.format("%lld more lines", Int64(preview.hiddenLineCount))))
                }
            }
        }
        var summary: [UIElement] = []
        if let lineCounts = row.lineCounts { summary.append(counts(lineCounts, size: ConversationStyle.captionSize)) }
        return box(title: title, summary: summary, content: content)
    }

    /// A box with `title` and `summary` over `content`, divided by a rule: the frame a file's diff and an approval
    /// card's preview share.
    static func box(title: String, summary: [UIElement], content: [UIElement]) -> UIElement {
        let name = ConversationStyle.text(title, size: ConversationStyle.captionSize, wraps: false)
        name.textTrimming = .characterEllipsis
        name.verticalAlignment = .center
        try? ToolTipService.setToolTip(name, title)
        let header = ConversationStyle.row([name] + summary, spacing: 8)
        header.margin = Thickness(left: 10, top: 5, right: 10, bottom: 5)
        let stack = StackPanel()
        stack.children.append(header)
        if !content.isEmpty { stack.children.append(rule()) }
        for element in content { stack.children.append(element) }
        let frame = Border()
        frame.background = WindowsTheme.subtleFill.brush
        frame.borderBrush = WindowsTheme.separator.brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.cornerRadius = ConversationStyle.corners(8)
        frame.child = stack
        try? AutomationProperties.setName(frame, title)
        return frame
    }

    /// "+n −n", green and red (the Mac's `CodexLineCountsText`).
    static func counts(_ counts: CodexFileChangeCardProjection.LineCounts, size: Double) -> UIElement {
        let added = ConversationStyle.text("+\(counts.additions)", size: size, selectable: false, wraps: false)
        added.foreground = ConversationStyle.green.solid.brush
        let removed = ConversationStyle.text("−\(counts.deletions)", size: size, selectable: false, wraps: false)
        removed.foreground = ConversationStyle.red.solid.brush
        let row = ConversationStyle.row([added, removed], spacing: 4)
        row.verticalAlignment = .center
        try? AutomationProperties.setName(row, "+\(counts.additions) −\(counts.deletions)")
        return row
    }

    /// The diff's lines, scrolling past `visibleLineLimit`, as the Mac's preview lines.
    static func lines(_ lines: [CodexFileChangeCardProjection.Preview.Line]) -> UIElement {
        let largest = lines.compactMap(\.number).max()
        let gutter = largest.map { Double(max(String($0).count, 2)) * 7.5 + 10 } ?? 6
        let stack = StackPanel()
        for line in lines { stack.children.append(lineView(line, gutter: gutter)) }
        let scroller = ScrollViewer()
        scroller.horizontalScrollBarVisibility = .auto
        scroller.horizontalScrollMode = .enabled
        if lines.count > visibleLineLimit {
            scroller.height = Double(visibleLineLimit) * lineHeight
            scroller.verticalScrollBarVisibility = .auto
        } else {
            scroller.verticalScrollBarVisibility = .disabled
            scroller.verticalScrollMode = .disabled
        }
        scroller.content = stack
        return scroller
    }

    private static func lineView(_ line: CodexFileChangeCardProjection.Preview.Line, gutter: Double) -> UIElement {
        let frame = Border()
        frame.height = lineHeight
        frame.horizontalAlignment = .stretch
        if line.kind == .separator {
            // A hunk's caption (an approval's edit), or a rule between hunks.
            guard !line.text.isEmpty else {
                let separator = rule()
                separator.margin = Thickness(left: 10, top: 0, right: 10, bottom: 0)
                separator.verticalAlignment = .center
                frame.child = separator
                return frame
            }
            let caption = ConversationStyle.text(line.text, size: ConversationStyle.captionSize, tone: .secondary,
                                                 wraps: false)
            caption.margin = Thickness(left: 10, top: 0, right: 10, bottom: 0)
            caption.verticalAlignment = .center
            frame.child = caption
            if line.id > 0 {
                frame.borderBrush = WindowsTheme.separator.brush
                frame.borderThickness = Thickness(left: 0, top: 1, right: 0, bottom: 0)
            }
            return frame
        }
        switch line.kind {
        case .addition: frame.background = ConversationStyle.green.opacity(0.1).brush
        case .deletion: frame.background = ConversationStyle.red.opacity(0.1).brush
        case .context, .separator: break
        }
        let number = code(line.number.map(String.init) ?? "", tone: .tertiary)
        number.width = gutter
        number.textAlignment = .right
        let mark = code(line.kind == .addition ? "+" : line.kind == .deletion ? "-" : "", tone: .primary)
        mark.width = 16
        mark.textAlignment = .center
        switch line.kind {
        case .addition: mark.foreground = ConversationStyle.green.solid.brush
        case .deletion: mark.foreground = ConversationStyle.red.solid.brush
        case .context, .separator: break
        }
        let text = code(line.text.isEmpty ? " " : line.text, tone: line.kind == .context ? .secondary : .primary)
        text.isTextSelectionEnabled = true
        text.margin = Thickness(left: 0, top: 0, right: 10, bottom: 0)
        let row = ConversationStyle.row([number, mark, text], spacing: 0)
        row.verticalAlignment = .center
        frame.child = row
        return frame
    }

    private static func code(_ string: String, tone: ConversationStyle.Tone) -> TextBlock {
        let block = ConversationStyle.text(string, size: ConversationStyle.smallCodeSize, tone: tone, selectable: false,
                                           wraps: false)
        block.textTrimming = .none
        block.fontFamily = ConversationStyle.codeFont()
        block.verticalAlignment = .center
        return block
    }

    private static func notice(_ text: String) -> UIElement {
        let block = ConversationStyle.text(text, size: ConversationStyle.captionSize, tone: .secondary)
        block.margin = Thickness(left: 10, top: 8, right: 10, bottom: 8)
        return block
    }

    private static func rule() -> Border {
        let rule = Border()
        rule.height = 1
        rule.background = WindowsTheme.separator.brush
        return rule
    }
}
