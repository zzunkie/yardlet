import AppKit
import SwiftUI

/// The line between the sidebar and the window's content. Dragging it sets the sidebar's width,
/// as the Codex and Claude apps let their sidebars be dragged wider or narrower. The line stays
/// 1 pt; the area that takes the drag is a little wider and reaches over both sides.
struct SidebarResizeDivider: View {
    /// The width the sidebar has now.
    let width: CGFloat
    /// Called as the line moves, with the width it asks for (`SidebarWidth.clamped` keeps it in
    /// bounds).
    let onResize: (CGFloat) -> Void
    /// Called once the drag ends, to keep the width.
    let onCommit: () -> Void
    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    /// The width of the area that takes the drag, centred on the line.
    static let hitWidth: CGFloat = 7

    var body: some View {
        Rectangle()
            .fill(ParityTheme.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: Self.hitWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHovering else { return }
                        isHovering = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // Global coordinates: the line itself moves with the width it sets.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = start }
                                onResize(start + value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                onCommit()
                            }
                    )
                    // A double click returns the sidebar to its standard width, as the Codex and
                    // Claude apps' sidebar lines return theirs to their default.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        onResize(SidebarWidth.standard)
                        onCommit()
                    })
            }
            .onDisappear {
                if isHovering { NSCursor.pop() }
                isHovering = false
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.string("Resize sidebar"))
            .accessibilityAdjustableAction { direction in
                onResize(width + (direction == .increment ? SidebarWidth.adjustmentStep : -SidebarWidth.adjustmentStep))
                onCommit()
            }
            // Over the content beside it, so the wider area takes the drag on both sides.
            .zIndex(1)
    }
}

/// The sidebar (or the archived tasks in its place) at the width set, and the line after it. Only
/// this view and the title bar read the width, so dragging the line lays the window out again
/// without rebuilding it.
struct SidebarColumn<Content: View>: View {
    let state: SidebarWidthState
    /// The window's width once known (`SidebarWidth.fitting`).
    let windowWidth: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        let width = state.shown(inWindowWidth: windowWidth)
        content
            .frame(width: width)
        SidebarResizeDivider(width: width, onResize: { state.resize(to: $0) }, onCommit: { state.commit() })
    }
}
