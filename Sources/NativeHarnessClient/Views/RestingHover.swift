import SwiftUI

/// Whether a scroll view is being scrolled, for the hover of the rows it scrolls (`onRestingHover`).
///
/// Rows scrolling under a pointer at rest each have the pointer for a frame or two. A row that draws
/// its hover then (a fill, its buttons, another padding) is drawn and laid out twice for every row
/// that passes, and the window is hit-tested again each time: work on every frame of a scroll for a
/// hover no one is pointing with. So a row takes the pointer once the scroll rests, as a web page's
/// content does, and loses it at once, since the row the pointer was on moves away.
///
/// Rows do not observe this: a scroll starting or ending draws none of them again, only the row the
/// pointer ends on.
@MainActor
final class ScrollHoverRest {
    private(set) var isScrolling = false
    /// What takes the pointer when the scroll rests, by the row that waits.
    private var waiting: [ObjectIdentifier: (Bool) -> Void] = [:]

    /// The scroll view started or stopped scrolling.
    func scrolls(_ isScrolling: Bool) {
        guard isScrolling != self.isScrolling else { return }
        self.isScrolling = isScrolling
        guard !isScrolling, !waiting.isEmpty else { return }
        let resting = waiting.values
        waiting = [:]
        for hover in resting { hover(true) }
    }

    /// The pointer came onto `row` or left it; `hover` draws that.
    func pointer(isOver: Bool, _ row: AnyObject, hover: @escaping (Bool) -> Void) {
        if isOver, isScrolling {
            waiting[ObjectIdentifier(row)] = hover
        } else {
            waiting[ObjectIdentifier(row)] = nil
            hover(isOver)
        }
    }

    /// `row` is gone.
    func forget(_ row: AnyObject) {
        waiting[ObjectIdentifier(row)] = nil
    }
}

private struct ScrollHoverRestKey: EnvironmentKey {
    static let defaultValue: ScrollHoverRest? = nil
}

extension EnvironmentValues {
    /// The scroll view the view is in, when its rows' hover waits for its scroll to rest.
    var scrollHoverRest: ScrollHoverRest? {
        get { self[ScrollHoverRestKey.self] }
        set { self[ScrollHoverRestKey.self] = newValue }
    }
}

private struct RestsHoverWhileScrolling: ViewModifier {
    @State private var rest = ScrollHoverRest()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in rest.scrolls(phase != .idle) }
            .onDisappear { rest.scrolls(false) }
            .environment(\.scrollHoverRest, rest)
    }
}

private struct RestingHover: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.scrollHoverRest) private var rest
    @State private var row = Row()

    private final class Row {}

    func body(content: Content) -> some View {
        content
            .onHover { isOver in
                if let rest {
                    rest.pointer(isOver: isOver, row, hover: action)
                } else {
                    action(isOver)
                }
            }
            .onDisappear { rest?.forget(row) }
    }
}

extension View {
    /// On a scroll view: the rows it scrolls take hover once its scroll rests (`onRestingHover`).
    func restsHoverWhileScrolling() -> some View {
        modifier(RestsHoverWhileScrolling())
    }

    /// `onHover` for a row of a scroll view: the pointer coming onto the row while the view scrolls
    /// is told once the scroll rests, if it is still there (`ScrollHoverRest`). Outside such a scroll
    /// view it is `onHover`.
    func onRestingHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(RestingHover(action: action))
    }
}
