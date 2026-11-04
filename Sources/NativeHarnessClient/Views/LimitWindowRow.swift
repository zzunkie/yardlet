import AppKit
import SwiftUI

/// One limit window, drawn the same way wherever limits show (Codex's `/status`, the account
/// list and its limits popover, a limit card): its name, a bar of what is left, the share left and,
/// quieter, when it resets. The words are the place's own; the row is not.
///
/// The row is three cells of a `LimitWindowGrid` (name, bar, value), so names, bars and values line
/// up with the rows around it.
struct LimitWindowRow: View {
    let name: String
    /// The share left, 0 to 100, which fills the bar; nil leaves the bar empty.
    let remainingPercent: Double?
    /// The share left in the place's words: `64% left`, `64% remaining`.
    let value: String
    /// When the window resets in the place's words, after the value.
    let reset: String?
    /// The grid row the three cells belong to.
    let row: Int
    /// The row's text size, which the bar's glyphs follow.
    let fontSize: CGFloat
    /// Whether a nearly spent window turns orange. Codex's `/status` never colours its rows.
    var marksNearlySpent = true

    init(name: String, remainingPercent: Double?, value: String, reset: String?, row: Int, fontSize: CGFloat,
         marksNearlySpent: Bool = true) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.value = value
        self.reset = reset
        self.row = row
        self.fontSize = fontSize
        self.marksNearlySpent = marksNearlySpent
    }

    init(_ window: AccountLimitWindow, value: String, reset: String?, row: Int, fontSize: CGFloat,
         marksNearlySpent: Bool = true) {
        self.init(name: window.name, remainingPercent: window.remainingPercent, value: value, reset: reset,
                  row: row, fontSize: fontSize, marksNearlySpent: marksNearlySpent)
    }

    var body: some View {
        // As wide as the grid's label column, which is the widest name's unless the grid shortens it.
        Text(name)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .limitWindowCell(.label, row: row)
        LimitWindowBar(percent: remainingPercent, fontSize: fontSize, tint: isNearlySpent ? .orange : nil)
            .limitWindowCell(.bar, row: row)
        valueText
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .limitWindowCell(.rateValue, row: row)
    }

    private var isNearlySpent: Bool {
        marksNearlySpent && (remainingPercent ?? 100) <= 10
    }

    private var valueText: Text {
        var text = Text(value).foregroundStyle(isNearlySpent ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        if let reset { text = text + Text(verbatim: " ") + Text(reset).foregroundStyle(.secondary) }
        return text
    }
}

/// The Codex app's text bar: `█` for the share left and `░` for the rest, twelve to forty-eight
/// cells as wide as its column allows. A column narrower than twelve cells clips it.
struct LimitWindowBar: View {
    let percent: Double?
    let fontSize: CGFloat
    /// The filled cells' colour, when not the text's own.
    var tint: Color? = nil
    @State private var cells = 24

    var body: some View {
        let filled = Int((min(max(percent ?? 0, 0), 100) / 100 * Double(cells)).rounded())
        // A hidden glyph gives the row its line height and baseline; the bar draws over it, so
        // the column's width decides the cells and the cells never decide the column.
        Text(verbatim: "█")
            .font(font)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if percent != nil {
                    (Text(verbatim: String(repeating: "█", count: filled)).foregroundStyle(tint.map(AnyShapeStyle.init)
                        ?? AnyShapeStyle(.primary))
                        + Text(verbatim: String(repeating: "░", count: max(cells - filled, 0))))
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .clipped()
            .onGeometryChange(for: Int.self) { geometry in
                let glyph = ("█" as NSString).size(withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
                ]).width
                guard geometry.size.width.isFinite, geometry.size.width > 0, glyph > 0 else { return 12 }
                return min(48, max(12, Int(geometry.size.width / glyph)))
            } action: { cells = $0 }
            // The value beside it reads the same share.
            .accessibilityHidden(true)
    }

    private var font: Font { .system(size: fontSize, weight: .semibold, design: .monospaced) }
}

/// Rows laid out as the Codex app's `/status` grid lays them out
/// (`grid-cols-[max-content_minmax(0,1fr)]`, and from its wide width
/// `[max-content_minmax(72px,1fr)_minmax(0,max-content)]`): labels as wide as the widest label;
/// then a value across the rest, or a limit window's bar and its value, the value as wide as the
/// widest one allows and the bar the remainder. Narrower than `wideWidth`, a limit window has no
/// bar. Cells of a row share their first baseline.
///
/// Given no width (inside `fixedSize`), the grid is as wide as its widest label, the bar's minimum
/// and its widest value.
struct LimitWindowGrid: Layout {
    enum Column { case label, bar, value, rateValue, fullRow }
    struct ColumnKey: LayoutValueKey { static let defaultValue = Column.fullRow }
    struct RowKey: LayoutValueKey { static let defaultValue = 0 }

    /// The Codex app's container query: from 400 points a limit window draws its bar.
    static let codexStatusWideWidth: CGFloat = 400

    /// From this width a limit window draws its bar.
    var wideWidth: CGFloat = 0
    var barMinimum: CGFloat = 72
    var columnSpacing: CGFloat = 16
    var rowSpacing: CGFloat = 4
    /// Set, the grid is never wider than it is given no width, and given less, a widest label longer
    /// than `longerThan` shortens first, to no less than `to`; given less still, the grid keeps that
    /// least width.
    var labelShortening: LabelShortening? = nil

    struct LabelShortening {
        var longerThan: CGFloat
        var to: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width proposed: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let columns = subviews.map { $0[ColumnKey.self] }
        func widest(_ column: Column) -> CGFloat {
            zip(subviews, columns).filter { $0.1 == column }.map { $0.0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        let widestLabel = widest(.label), rateValueWidth = widest(.rateValue)
        let valueWidth = widest(.value), fullRowWidth = widest(.fullRow)
        func gridWidth(labels: CGFloat) -> CGFloat {
            max(labels + columnSpacing + max(valueWidth, barMinimum + columnSpacing + rateValueWidth), fullRowWidth)
        }
        let fitting = gridWidth(labels: widestLabel)
        var labelWidth = widestLabel
        var width = proposed ?? fitting
        if let labelShortening {
            let shortest = widestLabel > labelShortening.longerThan ? min(widestLabel, labelShortening.to) : widestLabel
            width = min(max(width, gridWidth(labels: shortest)), fitting)
            labelWidth = max(shortest, widestLabel - (fitting - width))
        }
        let wide = width >= wideWidth
        let rest = max(0, width - labelWidth - columnSpacing)
        let valueX = labelWidth + columnSpacing
        let barWidth = wide ? max(barMinimum, rest - columnSpacing - min(rateValueWidth, max(0, rest - barMinimum - columnSpacing))) : 0
        let rateValueX = wide ? valueX + barWidth + columnSpacing : valueX
        let rateValueSpan = wide ? max(0, width - rateValueX) : rest

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var top: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let row = subviews[index][RowKey.self]
            var members: [Int] = []
            while index < subviews.count, subviews[index][RowKey.self] == row { members.append(index); index += 1 }
            var cells: [(index: Int, x: CGFloat, size: CGSize, baseline: CGFloat)] = []
            for member in members {
                let (x, cellWidth): (CGFloat, CGFloat) = switch columns[member] {
                case .label: (0, labelWidth)
                case .bar: (valueX, barWidth)
                case .value: (valueX, rest)
                case .rateValue: (rateValueX, rateValueSpan)
                case .fullRow: (0, width)
                }
                let proposal = ProposedViewSize(width: cellWidth, height: nil)
                let height = cellWidth > 0 ? subviews[member].sizeThatFits(proposal).height : 0
                let baseline = cellWidth > 0 ? subviews[member].dimensions(in: proposal)[.firstTextBaseline] : 0
                cells.append((member, x, CGSize(width: cellWidth, height: height), baseline))
            }
            let baseline = cells.map(\.baseline).max() ?? 0
            var bottom = top
            for cell in cells {
                let y = cell.size.height > 0 ? top + baseline - cell.baseline : top
                frames[cell.index] = CGRect(x: cell.x, y: y, width: cell.size.width, height: cell.size.height)
                bottom = max(bottom, y + cell.size.height)
            }
            top = bottom + (index < subviews.count ? rowSpacing : 0)
        }
        return (frames, CGSize(width: width, height: top))
    }
}

extension View {
    /// Places the view in `column` of grid row `row` of a `LimitWindowGrid`.
    func limitWindowCell(_ column: LimitWindowGrid.Column, row: Int) -> some View {
        layoutValue(key: LimitWindowGrid.ColumnKey.self, value: column)
            .layoutValue(key: LimitWindowGrid.RowKey.self, value: row)
    }
}

/// An account's limit windows one under another in the account list's words: the share left as
/// the check wrote it, and when each resets.
struct AccountLimitWindowList: View {
    enum Reset {
        /// `Resets Oct 9, 2026 at 3:00 PM`, where every limit is listed.
        case absolute
        /// `Resets 3:00 PM`, or with the day when it is not today, beside an account and on a limit card.
        case time
    }

    let windows: [(window: AccountLimitWindow, value: String)]
    var reset: Reset = .time
    var fontSize: CGFloat = 11
    var rowSpacing: CGFloat = 4

    /// Whether long names shorten when the list is given less than its width (`nameShortening`).
    var shortensLongNames = false

    init(metrics: [AccountUsageMetric], reset: Reset = .time, fontSize: CGFloat = 11, rowSpacing: CGFloat = 4,
         shortensLongNames: Bool = false) {
        self.init(windows: metrics.map { (AccountLimitWindow(metric: $0), $0.detail) }, reset: reset,
                  fontSize: fontSize, rowSpacing: rowSpacing)
        self.shortensLongNames = shortensLongNames
    }

    init(windows: [AccountLimitWindow], reset: Reset = .time, fontSize: CGFloat = 11, rowSpacing: CGFloat = 4) {
        self.init(windows: windows.map { ($0, $0.accountRemainingText) }, reset: reset, fontSize: fontSize,
                  rowSpacing: rowSpacing)
    }

    private init(windows: [(window: AccountLimitWindow, value: String)], reset: Reset, fontSize: CGFloat,
                 rowSpacing: CGFloat) {
        self.windows = windows
        self.reset = reset
        self.fontSize = fontSize
        self.rowSpacing = rowSpacing
    }

    var body: some View {
        LimitWindowGrid(barMinimum: Self.barMinimum(fontSize: fontSize), columnSpacing: 10, rowSpacing: rowSpacing,
                        labelShortening: shortensLongNames ? Self.nameShortening(fontSize: fontSize) : nil) {
            ForEach(Array(windows.enumerated()), id: \.offset) { index, entry in
                LimitWindowRow(entry.window, value: entry.value, reset: resetText(entry.window.resetsAt), row: index,
                               fontSize: fontSize)
            }
        }
        .font(.system(size: fontSize))
        .monospacedDigit()
    }

    /// Twelve cells of the bar, its fewest.
    static func barMinimum(fontSize: CGFloat) -> CGFloat {
        let glyph = ("█" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        ]).width
        return (glyph * 12).rounded(.up)
    }

    /// Given less than its width, a name longer than six ems (a model group's window, "Claude and GPT ·
    /// 7 day limit") shortens to four and a half; a window's own name ("5 hour limit", "Weekly limit")
    /// is never cut.
    static func nameShortening(fontSize: CGFloat) -> LimitWindowGrid.LabelShortening {
        LimitWindowGrid.LabelShortening(longerThan: fontSize * 6, to: fontSize * 4.5)
    }

    private func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return switch reset {
        case .absolute: L10n.format("Resets %@", date.formatted(date: .abbreviated, time: .shortened))
        case .time: L10n.format("Resets %@", ProviderNoticeText.resetTime(date))
        }
    }
}
