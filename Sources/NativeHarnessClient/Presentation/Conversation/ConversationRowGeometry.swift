import Foundation

/// Where a conversation's rows are in its row list (`ConversationRowList`): their order, their heights
/// and the place being read among them, as numbers. A row is a turn or a part of one
/// (`ConversationTurnRows`), with the space above it (its lead), and below it for the last.
///
/// Every height is one its row was measured at, at the list's width: a row is put in once it is
/// measured, never at an estimate. A lazy stack's estimates of the rows it had not laid out moved by
/// thousands of points as a working conversation's rows changed, and lost the rows in view.
///
/// The place being read is an anchor (`Anchor`): the end, while following the latest output, or a row
/// and how far into it the viewport's top is. A change to the rows (rows arriving or leaving, a row
/// growing or shrinking, a new width) reads the anchor before it and puts the viewport back at it after
/// it, so what the reader sees moves only when they scroll or are taken somewhere.
///
/// Finding the rows in a stretch of the list is a binary search over the rows' tops, and a row's new
/// height moves only the rows below it: a scroll's frame and a streamed line cost the same in a long
/// conversation as in a short one.
struct ConversationRowGeometry: Equatable, Sendable {
    /// A place in the list.
    enum Anchor: Equatable, Sendable {
        /// The end of the conversation, which following keeps in view.
        case end
        /// The viewport's top is `into` points below the top of row `id`'s content, below its lead, and
        /// the row was `height` tall then (negative: the content starts below the viewport's top). The
        /// lead is left out: it changes as rows arrive above (the conversation's top gives way to the
        /// space between turns), and the content stays where it was.
        case row(id: String, into: CGFloat, height: CGFloat)
    }

    private(set) var ids: [String] = []
    private(set) var heights: [CGFloat] = []
    /// The space above each row's content, inside its height.
    private(set) var leads: [CGFloat] = []
    /// Each row's top, and after them the end of the last row.
    private(set) var tops: [CGFloat] = [0]
    private var indexByID: [String: Int] = [:]

    init() {}

    init(ids: [String], heights: [CGFloat], leads: [CGFloat]? = nil) {
        setRows(ids, heights: heights, leads: leads)
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    /// The rows' height together: the list's.
    var contentHeight: CGFloat { tops[ids.count] }

    func index(of id: String) -> Int? { indexByID[id] }

    func top(ofRow index: Int) -> CGFloat { tops[index] }

    func bottom(ofRow index: Int) -> CGFloat { tops[index + 1] }

    /// The list's rows are now `ids`, `heights` tall with `leads` of space above their content (none when
    /// nil). Rows that keep their place and height do not move.
    mutating func setRows(_ ids: [String], heights: [CGFloat], leads: [CGFloat]? = nil) {
        precondition(ids.count == heights.count, "a height for each row")
        precondition(leads.map { $0.count == ids.count } ?? true, "a lead for each row")
        self.leads = leads ?? [CGFloat](repeating: 0, count: ids.count)
        if ids != self.ids {
            self.ids = ids
            indexByID = Dictionary(ids.enumerated().map { ($1, $0) }) { first, _ in first }
            self.heights = heights
            restack(from: 0)
            return
        }
        guard let first = heights.indices.first(where: { heights[$0] != self.heights[$0] }) else { return }
        self.heights = heights
        restack(from: first)
    }

    /// Row `index` is now `height` tall: it and the rows below it move, the ones above stay.
    mutating func setHeight(_ height: CGFloat, ofRow index: Int) {
        guard heights[index] != height else { return }
        heights[index] = height
        restack(from: index)
    }

    private mutating func restack(from first: Int) {
        if tops.count != ids.count + 1 { tops = [CGFloat](repeating: 0, count: ids.count + 1) }
        for index in first..<ids.count { tops[index + 1] = tops[index] + heights[index] }
    }

    /// The rows that cross the stretch of the list from `minY` to `maxY`.
    func rows(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard !ids.isEmpty, maxY > minY else { return 0..<0 }
        // The first row whose end is below the stretch's top, and the first whose top is at its bottom.
        let first = firstIndex { tops[$0 + 1] > minY }
        let end = firstIndex { tops[$0] >= maxY }
        return first..<max(first, end)
    }

    /// The first row for which `isPast`, which turns from false to true down the rows, holds.
    private func firstIndex(where isPast: (Int) -> Bool) -> Int {
        var low = 0, high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if isPast(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    // MARK: - The place being read

    /// The furthest the viewport's top goes in a viewport `viewportHeight` tall.
    func maximumOffset(viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    /// How far below the viewport's bottom the list ends.
    func distanceFromEnd(offset: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - offset - viewportHeight)
    }

    /// The place the viewport at `offset` shows: the end while `following`, otherwise the row at the
    /// viewport's top.
    func anchor(offset: CGFloat, following: Bool) -> Anchor {
        guard !following, !ids.isEmpty else { return .end }
        let row = min(firstIndex { tops[$0 + 1] > offset }, ids.count - 1)
        return .row(id: ids[row], into: offset - tops[row] - leads[row], height: heights[row] - leads[row])
    }

    /// Where the viewport's top goes to show `anchor`, in a viewport `viewportHeight` tall. A row that
    /// changed height keeps the point the viewport's top was at in it when `scales` (the width changed
    /// and the row's lines moved with it), and the points above it otherwise (the row grew below the
    /// viewport's top). An anchor whose row left the list keeps `fallback`.
    func offset(for anchor: Anchor, viewportHeight: CGFloat, scales: Bool = false, fallback: CGFloat) -> CGFloat {
        let maximum = maximumOffset(viewportHeight: viewportHeight)
        switch anchor {
        case .end:
            return maximum
        case let .row(id, into, height):
            guard let row = indexByID[id] else { return min(max(0, fallback), maximum) }
            let now = heights[row] - leads[row]
            let point = scales && height > 0 && now != height && into > 0 ? into * now / height : into
            return min(max(0, tops[row] + leads[row] + point), maximum)
        }
    }
}
