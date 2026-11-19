import WinUI

/// The oldest pending request and up to two edges behind it, above the task's composer. Keeping its
/// scroll view separate from the transcript lets a person read older turns while the form stays put.
@MainActor
final class ConversationRequestDock {
    let view = Grid()
    private let frame = Border()
    private let scroll = ScrollViewer()
    private let slot = StackPanel()
    private let outline = Border()
    private let edges = [Border(), Border()]
    private var edgeCount = 0
    private var front: RequestCard?
    private var needsInitialScroll = false
    private var layoutCheckPending = false

    init() {
        view.visibility = .collapsed
        view.maxWidth = WindowsTheme.contentWidth
        view.margin = Thickness(left: 24, top: 0, right: 24, bottom: 8)
        for (index, edge) in edges.enumerated().reversed() {
            edge.height = 40
            edge.verticalAlignment = .top
            edge.cornerRadius = ConversationStyle.corners(12)
            edge.background = WindowsTheme.elevated.brush
            edge.borderBrush = WindowsTheme.strongSeparator.brush
            edge.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
            edge.opacity = 1 - Double(index + 1) * 0.25
            edge.isHitTestVisible = false
            view.children.append(edge)
        }
        scroll.horizontalScrollBarVisibility = .disabled
        scroll.verticalScrollBarVisibility = .auto
        scroll.horizontalContentAlignment = .stretch
        scroll.content = slot
        frame.cornerRadius = ConversationStyle.corners(12)
        let clipped = Grid()
        frame.child = clipped
        clipped.children.append(scroll)
        outline.cornerRadius = ConversationStyle.corners(12)
        outline.borderBrush = WindowsTheme.strongSeparator.brush
        outline.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        outline.isHitTestVisible = false
        outline.visibility = .collapsed
        clipped.children.append(outline)
        view.children.append(frame)
        view.sizeChanged.addHandler { [weak self] _, _ in self?.positionEdges() }
        scroll.sizeChanged.addHandler { [weak self] _, _ in self?.scheduleLayoutCheck() }
        slot.sizeChanged.addHandler { [weak self] _, _ in self?.scheduleLayoutCheck() }
    }

    func fit(height: Double) {
        view.maxHeight = max(0, height * 0.6 - view.margin.bottom)
    }

    func show(_ card: RequestCard?, count: Int) {
        let nextCount = min(edges.count, max(0, count - 1))
        if edgeCount != nextCount || front == nil && card != nil {
            edgeCount = nextCount
            positionEdges()
        }
        guard front !== card else { return }
        front = card
        slot.children.clear()
        needsInitialScroll = card != nil
        view.visibility = card == nil ? .collapsed : .visible
        if let card {
            card.place(in: slot)
            // Defer until the new card and its capped viewport have both been measured.
            scheduleLayoutCheck()
        }
    }

    private func positionEdges() {
        for (index, edge) in edges.enumerated() {
            let depth = index + 1
            edge.visibility = depth <= edgeCount ? .visible : .collapsed
            let inset = view.actualWidth * 0.015 * Double(depth)
            edge.margin = Thickness(left: inset, top: Double(max(0, edgeCount - depth)) * 6,
                                    right: inset, bottom: 0)
        }
        frame.margin = Thickness(left: 0, top: Double(edgeCount) * 6, right: 0, bottom: 0)
    }

    /// Open a tall card at its buttons once. A streaming update must leave the person's scroll and
    /// any text they have started entering alone.
    private func scheduleLayoutCheck() {
        guard front != nil, !layoutCheckPending else { return }
        layoutCheckPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.layoutCheckPending = false }
            guard self.front != nil else { return }
            try? self.scroll.updateLayout()
            self.outline.visibility = self.scroll.scrollableHeight > 0 ? .visible : .collapsed
            guard self.needsInitialScroll, self.scroll.viewportHeight > 0, self.slot.actualHeight > 0 else { return }
            self.needsInitialScroll = false
            _ = try? self.scroll.changeView(nil, self.scroll.scrollableHeight, nil, true)
        }
    }
}
