import AppKit
import SwiftUI

/// Lays a Markdown table's cells out in columns, measuring each cell at its column's final width
/// before setting the row heights.
///
/// Offered a width, the columns fit it as a browser fits a table, their cells wrapping: each column
/// as wide as its content when all fit. Otherwise, while every column can keep its longest word
/// whole and be at least `minimumColumnWidth` wide, the narrow columns keep their content's width
/// and the wide ones share the rest. With less room the words break, and the columns share it down
/// to `minimumColumnWidth`, or a column's content when that is narrower: the table's narrowest.
///
/// Offered no width, in a scroller or asked its ideal size (`ViewThatFits`), each column takes its
/// content up to `maximumColumnWidth`, its longest word whole, or, without one, the table takes its
/// narrowest.
struct TranscriptTableLayout: Layout {
    let columns: Int
    var maximumColumnWidth: CGFloat?
    var minimumColumnWidth: CGFloat = 120
    private let columnSpacing: CGFloat = 18
    private let rowSpacing: CGFloat = 8

    /// A cell's longest word (`longestWord(in:size:weight:)`).
    struct LongestWord: LayoutValueKey {
        static let defaultValue: CGFloat = 0
    }

    struct Measurements {
        let widths: [CGFloat]
        let heights: [CGFloat]
    }

    /// What one layout pass, and the passes after it until the cells change, measure again otherwise: SwiftUI
    /// asks a table's size several times for one proposal, and a resize asks again at widths that leave many
    /// columns as they were. `updateCache` empties it whenever the cells or the layout change.
    struct Cache {
        /// Each column's widest content on one line and longest word.
        var columns: (content: [CGFloat], words: [CGFloat])?
        var measurements: [CGFloat?: Measurements] = [:]
        /// A cell's height at a width, by its index.
        var heights: [Int: [CGFloat: CGFloat]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = measure(subviews, width: proposal.width, cache: &cache)
        return CGSize(
            width: sizes.widths.reduce(0, +) + spacing(sizes.widths.count),
            height: sizes.heights.reduce(0, +) + CGFloat(max(0, sizes.heights.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = measure(subviews, width: proposal.width, cache: &cache)
        guard columns > 0 else { return }
        var y = bounds.minY
        for row in sizes.heights.indices {
            var x = bounds.minX
            for column in sizes.widths.indices {
                let index = row * columns + column
                if subviews.indices.contains(index) {
                    subviews[index].place(
                        at: CGPoint(x: x, y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: sizes.widths[column], height: sizes.heights[row])
                    )
                }
                x += sizes.widths[column] + columnSpacing
            }
            y += sizes.heights[row] + rowSpacing
        }
    }

    private func spacing(_ count: Int) -> CGFloat {
        CGFloat(max(0, count - 1)) * columnSpacing
    }

    private func measure(_ subviews: Subviews, width: CGFloat?, cache: inout Cache) -> Measurements {
        guard columns > 0, !subviews.isEmpty else { return Measurements(widths: [], heights: []) }
        if let measured = cache.measurements[width] { return measured }
        let content: [CGFloat], words: [CGFloat]
        if let columns = cache.columns {
            (content, words) = columns
        } else {
            var widest = Array(repeating: CGFloat.zero, count: columns)
            var longest = Array(repeating: CGFloat.zero, count: columns)
            for index in subviews.indices {
                widest[index % columns] = max(widest[index % columns], subviews[index].sizeThatFits(.unspecified).width)
                longest[index % columns] = max(longest[index % columns], subviews[index][LongestWord.self])
            }
            (content, words) = (widest, longest)
            cache.columns = (widest, longest)
        }
        let widths = if let width {
            Self.columnWidths(content: content, words: words, available: width - spacing(columns),
                              minimum: minimumColumnWidth)
        } else if let maximumColumnWidth {
            zip(content, words).map { min($0, max($1, maximumColumnWidth)) }
        } else {
            content.map { min($0, minimumColumnWidth) }
        }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for index in subviews.indices {
            let cellWidth = widths[index % columns]
            let height = cache.heights[index]?[cellWidth] ?? {
                let height = subviews[index].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
                if cache.heights[index]?.count ?? 0 >= 8 { cache.heights[index] = [:] }
                cache.heights[index, default: [:]][cellWidth] = height
                return height
            }()
            heights[index / columns] = max(heights[index / columns], height)
        }
        let measured = Measurements(widths: widths, heights: heights)
        // A live resize proposes a new width at every step; keep a few rather than every one.
        if cache.measurements.count >= 8 { cache.measurements.removeAll() }
        cache.measurements[width] = measured
        return measured
    }

    /// The columns' widths in `available` points, from each column's widest content on one line and
    /// its longest word.
    static func columnWidths(content: [CGFloat], words: [CGFloat], available: CGFloat,
                             minimum: CGFloat) -> [CGFloat] {
        guard content.reduce(0, +) > available else { return content }
        let whole = zip(content, words).map { min($0, max($1, minimum)) }
        if whole.reduce(0, +) <= available { return level(from: whole, to: content, filling: available) }
        let narrowest = content.map { min($0, minimum) }
        guard narrowest.reduce(0, +) < available else { return narrowest }
        return level(from: narrowest, to: content, filling: available)
    }

    /// Each width at one level, held between its floor and its ceiling, where they add up to `total`:
    /// the columns whose ceiling is under the level keep it, the others share the rest evenly.
    private static func level(from floors: [CGFloat], to ceilings: [CGFloat], filling total: CGFloat) -> [CGFloat] {
        func widths(at level: CGFloat) -> [CGFloat] {
            zip(floors, ceilings).map { floor, ceiling in min(ceiling, max(floor, level)) }
        }
        var low: CGFloat = 0
        var high = ceilings.max() ?? 0
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if widths(at: middle).reduce(0, +) > total { high = middle } else { low = middle }
        }
        return widths(at: low)
    }

    /// The widest run of `text` between white space, in the fonts a cell draws it in: the width a
    /// column needs to keep the word on one line.
    static func longestWord(in text: AttributedString, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let string = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let runWeight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : weight
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: runWeight)
                : NSFont.systemFont(ofSize: size, weight: runWeight)
            if intent.contains(.emphasized) {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
            }
            string.append(NSAttributedString(string: String(text[run.range].characters), attributes: [.font: font]))
        }
        let characters = string.string as NSString
        guard characters.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(string)
        var longest: CGFloat = 0
        var start: Int?
        for index in 0...characters.length {
            let isSpace = index == characters.length
                || (UnicodeScalar(characters.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false)
            if isSpace, let wordStart = start {
                longest = max(longest, CTLineGetOffsetForStringIndex(line, index, nil)
                    - CTLineGetOffsetForStringIndex(line, wordStart, nil))
                start = nil
            } else if !isSpace, start == nil {
                start = index
            }
        }
        // A word measured a hair narrower than the cell draws it would break before its last letter.
        return ceil(longest) + 1
    }
}
