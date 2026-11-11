import Foundation
import UWP
import WinUI

/// A change to files in the conversation, as the Mac's line shows it: what was done to which files, with the lines
/// added and removed, and opened, each file's diff from the engine's rows (`CodexFileChangeCardProjection.Row`), its
/// added and removed lines tinted. A diff is drawn when its line first opens, so a long conversation does not draw
/// every diff it holds.
@MainActor
enum FileChangeView {
    /// A file change's line (`ConversationItemKind.fileChange`).
    static func element(_ item: ConversationItem, change: ConversationFileChange, harness: HarnessKind,
                        workspaceURL: URL?) -> UIElement? {
        let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: workspaceURL) } : change.rows
        var words = ConversationLiveWork.words(for: item, harness: harness, workspaceURL: workspaceURL)?.text
            ?? rows.map(\.fileName).joined(separator: ", ")
        if rows.count == 1, let counts = rows[0].lineCounts { words += "  " + countText(counts) }
        if item.phase == .failed, rows.allSatisfy({ $0.state != .rejected }) { words += " · " + L10n.string("Failed") }
        return element(words: words, rows: rows, error: change.errorMessage.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A call's line that changed files (an edit tool's `diff`, or a worded line's `diffs`), with `words` as its line.
    static func element(words: String, diffs: [HarnessActivityDiff], phase: ConversationItemPhase,
                        workspaceURL: URL?) -> UIElement {
        let rows = diffs.map { ConversationFileChangeProjection.row(for: $0, phase: phase, workspaceURL: workspaceURL) }
        return element(words: words, rows: rows, error: nil)
    }

    private static func element(words: String, rows: [CodexFileChangeCardProjection.Row], error: String?) -> UIElement {
        let header = text(words, muted: true)
        let shown = rows.filter(\.canExpand)
        guard !shown.isEmpty || error != nil else { return header }
        let expander = Expander()
        expander.header = header
        expander.horizontalAlignment = .stretch
        expander.horizontalContentAlignment = .stretch
        expander.expanding.addHandler { [weak expander] _, _ in
            guard let expander, expander.content == nil else { return }
            expander.content = details(shown, error: error)
        }
        return expander
    }

    private static func details(_ rows: [CodexFileChangeCardProjection.Row], error: String?) -> UIElement {
        let panel = StackPanel()
        panel.spacing = 10
        for row in rows {
            let title = row.lineCounts.map { "\(row.displayPath)  \(countText($0))" } ?? row.displayPath
            let name = text(title, size: 12)
            name.fontWeight = UWP.FontWeight(weight: 600)
            panel.children.append(name)
            panel.children.append(diff(row))
        }
        if let error {
            let line = text(error, size: 12)
            line.foreground = SolidColorBrush(UWP.Color(a: 0xFF, r: 0xC4, g: 0x2B, b: 0x1C))
            panel.children.append(line)
        }
        return panel
    }

    /// The file's lines as the Mac's diff box draws them: a number, the change's mark and the line, in a box that
    /// scrolls sideways for long lines.
    private static func diff(_ row: CodexFileChangeCardProjection.Row) -> UIElement {
        guard row.preview == .available else { return text(L10n.string("Diff too large to preview"), muted: true, size: 12) }
        let preview = row.previewLines
        guard !preview.lines.isEmpty else {
            return text(L10n.string(row.kind == .delete ? "Contents deleted" : "No changes"), muted: true, size: 12)
        }
        let width = String(preview.lines.compactMap(\.number).max() ?? 0).count
        let lines = StackPanel()
        for line in preview.lines {
            let box = Border()
            box.padding = Thickness(left: 8, top: 0, right: 8, bottom: 0)
            switch line.kind {
            case .separator:
                box.height = 1
                box.margin = Thickness(left: 0, top: 4, right: 0, bottom: 4)
                box.background = tint(r: 0x80, g: 0x80, b: 0x80, alpha: 0x40)
                lines.children.append(box)
                continue
            case .addition: box.background = tint(r: 0x2E, g: 0xA0, b: 0x43, alpha: 0x30)
            case .deletion: box.background = tint(r: 0xD1, g: 0x24, b: 0x2F, alpha: 0x30)
            case .context: break
            }
            let mark = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " "
            let number = line.number.map(String.init) ?? ""
            let words = text(String(repeating: " ", count: max(0, width - number.count)) + number + " " + mark + " " + line.text,
                             size: 12)
            words.fontFamily = FontFamily("Consolas")
            words.textWrapping = .noWrap
            box.child = words
            lines.children.append(box)
        }
        if preview.hiddenLineCount > 0 {
            let more = text(L10n.format("%lld more lines", Int64(preview.hiddenLineCount)), muted: true, size: 12)
            more.margin = Thickness(left: 8, top: 4, right: 8, bottom: 0)
            lines.children.append(more)
        }
        let scroller = ScrollViewer()
        scroller.horizontalScrollBarVisibility = .auto
        scroller.horizontalScrollMode = .enabled
        scroller.verticalScrollBarVisibility = .disabled
        scroller.verticalScrollMode = .disabled
        scroller.content = lines
        let frame = Border()
        frame.background = tint(r: 0x80, g: 0x80, b: 0x80, alpha: 0x14)
        frame.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        frame.padding = Thickness(left: 0, top: 6, right: 0, bottom: 6)
        frame.child = scroller
        return frame
    }

    private static func countText(_ counts: CodexFileChangeCardProjection.LineCounts) -> String {
        "+\(counts.additions) −\(counts.deletions)"
    }

    private static func tint(r: UInt8, g: UInt8, b: UInt8, alpha: UInt8) -> SolidColorBrush {
        SolidColorBrush(UWP.Color(a: alpha, r: r, g: g, b: b))
    }

    private static func text(_ string: String, muted: Bool = false, size: Double = 14) -> TextBlock {
        let block = TextBlock()
        block.text = string
        block.fontSize = size
        block.textWrapping = .wrap
        block.isTextSelectionEnabled = true
        if muted { block.opacity = 0.6 }
        return block
    }
}
