import AppKit
import SwiftUI

extension View {
    /// Calls `action` as the pointer comes over this view and leaves it, as `onHover` does, from an
    /// AppKit tracking area of a view of its own. SwiftUI's `onHover` marks its hosting view for layout
    /// whenever the view moves in its window, as every row of a scrolling conversation does at every
    /// frame, and the window's SwiftUI then laid the whole window out again; a tracking area of the
    /// view's own follows the scroll without asking anything of SwiftUI.
    func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(PointerHoverTracking(action: action))
    }
}

private struct PointerHoverTracking: NSViewRepresentable {
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> PointerHoverView {
        let view = PointerHoverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: PointerHoverView, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: PointerHoverView, coordinator: ()) {
        // A view taken away under the pointer leaves it.
        if view.isHovering { view.action(false) }
    }
}

private final class PointerHoverView: NSView {
    var action: (Bool) -> Void = { _ in }
    private(set) var isHovering = false
    private var area: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    /// Tracks the view's bounds. Not its visible rect (`inVisibleRect`): a view that does not clip to its
    /// bounds, as none does by default since macOS 14, has a visible rect as large as what its
    /// ancestors show, and the pointer anywhere over the conversation would be over every message in view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Presses go to the views it is behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { set(false) }
    }

    private func set(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        action(hovering)
    }
}
