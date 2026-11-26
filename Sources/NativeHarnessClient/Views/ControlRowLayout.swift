import SwiftUI

/// Wraps the existing controls without replacing them, so open menus and focus keep their identity.
/// Composer actions can stay at the trailing edge; approval choices retain their reading order.
struct ControlRowLayout: Layout {
    var spacing: CGFloat = 7
    var rowSpacing: CGFloat = 4
    var pinsTrailingActions = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = idealSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, idealSizes.count - 1))
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth)
        let sizes = measuredSizes(subviews, width: width)
        let rows = rows(for: sizes, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measuredSizes(subviews, width: bounds.width)
        let rows = rows(for: sizes, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes[index]
                let width = min(size.width, bounds.width)
                if pinsTrailingActions, index == subviews.count - 1 {
                    x = max(x, bounds.maxX - width)
                }
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                x += width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Nested provider controls may themselves wrap. Measure them at the same constrained
    /// width used for placement so narrow composers reserve their actual height.
    private func measuredSizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        var sizes = subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            return ideal.width > width
                ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
        // Actions that can shorten (the composer's model control drops its effort, then shortens its name)
        // take the room the row leaves them before anything wraps: a wrap left the first control, the
        // composer's "+", alone on a row of its own. Given less than half their width, they wrap instead.
        if pinsTrailingActions, sizes.count > 1, let actions = sizes.last {
            let leading = sizes.dropLast().reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1)
            let room = width - leading
            if leading + actions.width > width, room >= actions.width / 2 {
                let shortened = subviews[subviews.count - 1].sizeThatFits(ProposedViewSize(width: room, height: nil))
                if shortened.width <= room { sizes[sizes.count - 1] = shortened }
            }
        }
        return sizes
    }

    private func rows(for sizes: [CGSize], width: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()
        for index in sizes.indices {
            let size = sizes[index]
            let itemWidth = min(size.width, width)
            var requiredWidth = itemWidth
            // When possible, keep the last input control beside the actions instead of
            // leaving only a send button on a second row.
            if pinsTrailingActions, index == sizes.count - 2, let actions = sizes.last,
               itemWidth + spacing + actions.width <= width {
                requiredWidth += spacing + actions.width
            }
            if !row.indices.isEmpty, row.width + spacing + requiredWidth > width {
                result.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }
}
