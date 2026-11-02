import AppKit
import SwiftUI

/// What is dragged inside the window: a window tab, a split pane (by its header), or a side panel's tab.
/// These drags stay in the window and use no pasteboard; a sidebar row's drag is the system's
/// (`TaskDragItem`), which panes and sidebar rows also accept.
enum WindowDragSubject: Equatable {
    case windowTab(WindowItem)
    /// A split pane's task.
    case pane(sessionID: UUID)
    /// A tab of the side panel of `owner` (a task, or the new-task screen's `TaskWorkspaceStore.draftID`).
    case panelTab(owner: UUID, tab: String)

    /// The task the drag carries, which a pane edge or the tab bar takes: a task's window tab, a pane's
    /// task, another task's conversation in a side panel.
    var task: UUID? {
        switch self {
        case let .windowTab(.session(id)): id
        case .windowTab: nil
        case let .pane(id): id
        case let .panelTab(_, tab): TaskSurfaceNavigationProjection.taskID(inTab: tab)
        }
    }
}

/// Where a drag would land.
enum WindowDropTarget: Equatable {
    /// Before the window tab at `index`; the tabs' count is after the last.
    case windowTabs(index: Int)
    /// One side of a pane: a split pane (`pane`), or the task a tab shows alone (nil).
    case pane(UUID?, SplitDirection)
    /// The middle of another split pane: the dragged pane and that one change places (the Claude app's
    /// Swap).
    case swapPane(UUID)
    /// Before the tab at `index` of `owner`'s side panel.
    case panelTabs(owner: UUID, index: Int)
}

/// The floating label that follows the pointer while something is dragged.
struct WindowDragPreview: Equatable {
    var title: String
    var systemName: String? = nil
    var harness: HarnessKind? = nil
}

/// Where the window's drop targets are, in the window's coordinates.
struct WindowDropGeometry {
    struct Strip {
        var frame: CGRect
        /// The strip's tabs' frames, in order.
        var tabs: [CGRect]
        /// The tabs, in the same order: a window tab's `WindowItem`, a side panel tab's ID.
        var ids: [AnyHashable] = []

        /// The tab a drop at `index` goes before; nil after the last.
        func id(before index: Int) -> AnyHashable? { ids.indices.contains(index) ? ids[index] : nil }
    }

    struct Pane {
        /// Nil for the task a tab shows alone.
        var paneID: UUID?
        var sessionID: UUID?
        var frame: CGRect
    }

    var windowTabs: Strip?
    var panes: [Pane] = []
    var panelStrips: [UUID: Strip] = [:]

    /// Where `subject` would land at `point`. A window tab moves along the tab bar, and a task's goes
    /// beside a pane; a pane moves beside another pane or to the tab bar as its own tab; a side panel's
    /// tab moves along its strip, and another task's conversation goes beside a pane or to the tab bar.
    func target(for subject: WindowDragSubject, at point: CGPoint) -> WindowDropTarget? {
        if let strip = windowTabs, strip.frame.contains(point) {
            switch subject {
            case .windowTab, .pane:
                return .windowTabs(index: Self.index(at: point.x, in: strip))
            case .panelTab:
                return subject.task.map { _ in .windowTabs(index: Self.index(at: point.x, in: strip)) }
            }
        }
        if case let .panelTab(owner, _) = subject {
            if let strip = panelStrips[owner], strip.frame.contains(point) {
                return .panelTabs(owner: owner, index: Self.index(at: point.x, in: strip))
            }
            if panelStrips.values.contains(where: { $0.frame.contains(point) }) { return nil }
        }
        guard let task = subject.task,
              let pane = panes.first(where: { $0.frame.contains(point) }),
              pane.sessionID != task else { return nil }
        let local = CGPoint(x: point.x - pane.frame.minX, y: point.y - pane.frame.minY)
        if case .pane = subject, let paneID = pane.paneID, Self.isMiddle(local, of: pane.frame.size) {
            return .swapPane(paneID)
        }
        return .pane(pane.paneID, PaneDropEdge.edge(for: local, in: pane.frame.size))
    }

    /// The middle of a pane, where a dragged pane swaps with it: half its width and a third of its height,
    /// as the Claude app's split view keeps its pane's middle for Swap.
    static func isMiddle(_ point: CGPoint, of size: CGSize) -> Bool {
        let x = point.x / max(size.width, 1), y = point.y / max(size.height, 1)
        return (0.25...0.75).contains(x) && (1.0 / 3...2.0 / 3).contains(y)
    }

    /// The gap the pointer is nearest: before the first tab whose middle is right of it.
    static func index(at x: CGFloat, in strip: Strip) -> Int {
        strip.tabs.firstIndex { x < $0.midX } ?? strip.tabs.count
    }
}

/// The window's drag: what is dragged, where the pointer is and where it would land. Draggable views
/// start and move it (`windowDraggable`); the window performs the drop (`perform`). The targets'
/// frames are kept unobserved, so registering them does not redraw.
@MainActor
@Observable
final class WindowDragState {
    private(set) var subject: WindowDragSubject?
    private(set) var preview: WindowDragPreview?
    /// Where the drag started and where the pointer is, in the window.
    private(set) var start: CGPoint = .zero
    private(set) var location: CGPoint = .zero
    private(set) var target: WindowDropTarget?

    @ObservationIgnored var geometry = WindowDropGeometry()
    /// Carries out a drop; set by the window.
    @ObservationIgnored var perform: (WindowDragSubject, WindowDropTarget) -> Void = { _, _ in }
    /// A drag cancelled with Esc stays cancelled until the pointer is let go.
    @ObservationIgnored private var cancelled: WindowDragSubject?
    @ObservationIgnored private var escapeMonitor: Any?

    func move(_ subject: WindowDragSubject, preview: WindowDragPreview, from start: CGPoint, to point: CGPoint) {
        guard cancelled != subject else { return }
        if self.subject != subject {
            self.subject = subject
            self.preview = preview
            self.start = start
            watchEscape()
        }
        location = point
        let target = geometry.target(for: subject, at: point)
        if self.target != target { self.target = target }
    }

    func end(_ subject: WindowDragSubject, at point: CGPoint) {
        if cancelled == subject { cancelled = nil }
        guard self.subject == subject else { return }
        let target = geometry.target(for: subject, at: point)
        cancel()
        if let target { perform(subject, target) }
    }

    func cancel() {
        subject = nil
        preview = nil
        target = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// The pointer let go of a drag the view lost or Esc cancelled.
    func release(_ subject: WindowDragSubject) {
        if cancelled == subject { cancelled = nil }
        if self.subject == subject { cancel() }
    }

    /// Esc cancels the drag, as it does the Claude app's: the thing stays where it was.
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let subject = self.subject else { return event }
            self.cancelled = subject
            self.cancel()
            return nil
        }
    }

    /// A tab dragged along its own strip moves itself; the label is for anywhere else.
    var slidesInStrip: Bool {
        switch (subject, target) {
        case (.windowTab?, .windowTabs?): true
        case let (.panelTab(owner, _)?, .panelTabs(target, _)?): owner == target
        default: false
        }
    }

    /// The offset a tab of a strip takes while one of its own tabs is dragged along it: the dragged tab
    /// follows the pointer within the strip's tabs (`tabs`, the strip's tabs' frames), and the tabs between
    /// its place and the gap move aside by its width, as the two apps' tab strips make room.
    func slide(index: Int, dragged from: Int?, gap: Int?, width: CGFloat, tabs: [CGRect]) -> CGFloat {
        guard let from else { return 0 }
        if index == from {
            guard gap != nil, tabs.indices.contains(from), let first = tabs.first, let last = tabs.last else { return 0 }
            let low = first.minX - tabs[from].minX, high = last.maxX - tabs[from].maxX
            return min(max(location.x - start.x, low), high)
        }
        guard let gap else { return 0 }
        if from < gap, index > from, index < gap { return -width }
        if gap <= from, index >= gap, index < from { return width }
        return 0
    }

    // MARK: Targets

    /// What each target view registered, by the view's token, latest last. A view drawn anew for another
    /// item registers before the one it replaces goes away, and that one may register once more on its way
    /// out; the latest registration of a view still there counts.
    @ObservationIgnored private var windowTabStrips: [(token: UUID, strip: WindowDropGeometry.Strip)] = []
    @ObservationIgnored private var paneEntries: [(token: UUID, pane: WindowDropGeometry.Pane)] = []
    @ObservationIgnored private var panelStripEntries: [(token: UUID, owner: UUID, strip: WindowDropGeometry.Strip)] = []

    func setWindowTabs(_ strip: WindowDropGeometry.Strip, token: UUID) {
        windowTabStrips.removeAll { $0.token == token }
        windowTabStrips.append((token, strip))
        geometry.windowTabs = strip
    }

    func removeWindowTabs(token: UUID) {
        windowTabStrips.removeAll { $0.token == token }
        geometry.windowTabs = windowTabStrips.last?.strip
    }

    func setPane(_ pane: WindowDropGeometry.Pane, token: UUID) {
        paneEntries.removeAll { $0.token == token }
        paneEntries.append((token, pane))
        updatePanes()
    }

    func removePane(token: UUID) {
        paneEntries.removeAll { $0.token == token }
        updatePanes()
    }

    func setPanelStrip(_ strip: WindowDropGeometry.Strip, owner: UUID, token: UUID) {
        panelStripEntries.removeAll { $0.token == token }
        panelStripEntries.append((token, owner, strip))
        geometry.panelStrips[owner] = strip
    }

    func removePanelStrip(owner: UUID, token: UUID) {
        panelStripEntries.removeAll { $0.token == token }
        geometry.panelStrips[owner] = panelStripEntries.last { $0.owner == owner }?.strip
    }

    /// One frame for each pane, the latest.
    private func updatePanes() {
        var seen = Set<UUID?>()
        geometry.panes = paneEntries.reversed().compactMap { entry in
            seen.insert(entry.pane.paneID).inserted ? entry.pane : nil
        }
    }
}

private struct WindowDragKey: EnvironmentKey {
    static let defaultValue: WindowDragState? = nil
}

extension EnvironmentValues {
    /// The window's drag; nil outside the main window, where nothing drags.
    var windowDrag: WindowDragState? {
        get { self[WindowDragKey.self] }
        set { self[WindowDragKey.self] = newValue }
    }
}

/// The side of a pane nearest a point in it, where a task dropped there goes.
enum PaneDropEdge {
    static func edge(for location: CGPoint, in size: CGSize) -> SplitDirection {
        guard size.width > 0, size.height > 0 else { return .right }
        let x = location.x / size.width
        let y = location.y / size.height
        let distances: [(SplitDirection, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }
}

/// Makes a view the handle of a window drag: past a few points of movement it drags `subject`, the
/// window shows where it would land, and letting go there moves it. A click stays a click.
struct WindowDraggable: ViewModifier {
    let subject: WindowDragSubject
    let preview: WindowDragPreview
    @Environment(\.windowDrag) private var drag
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        if let drag {
            content
                // Dragged along its own strip it moves itself; dragged anywhere else, a label follows the pointer.
                .opacity(drag.subject == subject && !drag.slidesInStrip ? 0.45 : 1)
                .simultaneousGesture(
                    // Past 4 points, as the Claude app's strips and panes start a drag (the Codex app's at 6).
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { value in
                            drag.move(subject, preview: preview, from: value.startLocation, to: value.location)
                        }
                        .onEnded { value in drag.end(subject, at: value.location) }
                )
                // A drag the view lost without ending (it went away under the pointer) leaves nothing behind.
                .onChange(of: isDragging) { _, dragging in
                    if !dragging { drag.release(subject) }
                }
        } else {
            content
        }
    }
}

extension View {
    func windowDraggable(_ subject: WindowDragSubject, preview: WindowDragPreview) -> some View {
        modifier(WindowDraggable(subject: subject, preview: preview))
    }

    /// Draggable when there is something to drag.
    @ViewBuilder
    func windowDraggable(_ subject: WindowDragSubject?, preview: WindowDragPreview?) -> some View {
        if let subject, let preview {
            modifier(WindowDraggable(subject: subject, preview: preview))
        } else {
            self
        }
    }
}

/// What the shown tab of a tab strip is pressed on, under what the tab shows: a button that does nothing, as the
/// strip's other tabs are buttons. In the title bar's height AppKit takes a press on SwiftUI content that no button
/// takes to move the window, at every press while the window is not the active app's key window, so the window moved
/// in place of the tab. What the tab shows over the handle lets presses through to it.
struct TabDragHandle: View {
    var body: some View {
        Button {} label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(TabDragHandleStyle())
            .focusable(false)
            .accessibilityHidden(true)
    }
}

/// The tab looks the same while it is pressed and dragged.
private struct TabDragHandleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// A sidebar task dragged over a tab strip (the window's tab bar, a side panel's tabs): the gap it would
/// open in, and opening it there.
struct TaskDropOnStrip: DropDelegate {
    let strip: () -> CGRect
    let tabs: () -> [CGRect]
    @Binding var index: Int?
    let onDrop: (UUID, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.yardletTaskReference]) }

    func dropEntered(info: DropInfo) { index = gap(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        index = gap(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { index = nil }

    func performDrop(info: DropInfo) -> Bool {
        let at = gap(info)
        index = nil
        guard let provider = info.itemProviders(for: [.yardletTaskReference]).first else { return false }
        Task { @MainActor in
            let sessionID: UUID? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: TaskDragItem.self) { result in
                    continuation.resume(returning: try? result.get().sessionID)
                }
            }
            if let sessionID { onDrop(sessionID, at) }
        }
        return true
    }

    /// The drop's location is in the strip; the tabs' frames are in the window.
    private func gap(_ info: DropInfo) -> Int {
        let frame = strip()
        return WindowDropGeometry.index(at: frame.minX + info.location.x,
                                        in: WindowDropGeometry.Strip(frame: frame, tabs: tabs()))
    }
}

/// The line between two tabs where a dragged tab would go.
struct TabInsertionMark: View {
    var height: CGFloat = 22

    var body: some View {
        Capsule()
            .fill(ParityTheme.accent)
            .frame(width: 2.5, height: height)
            .accessibilityHidden(true)
    }
}

/// The half of a pane a dropped task takes, shown while a task is dragged over the pane, or the whole
/// pane where a dragged pane would swap with it (nil).
struct PaneDropHighlight: View {
    let edge: SplitDirection?
    let size: CGSize

    var body: some View {
        let horizontal = edge?.axis == .horizontal
        let alignment: Alignment = switch edge {
        case .left: .leading
        case .right: .trailing
        case .up: .top
        case .down: .bottom
        case nil: .center
        }
        RoundedRectangle(cornerRadius: 6)
            .fill(ParityTheme.accent.opacity(0.12))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ParityTheme.accent.opacity(0.6), lineWidth: 1.5) }
            .frame(
                width: edge != nil && horizontal ? size.width / 2 : size.width,
                height: edge != nil && !horizontal ? size.height / 2 : size.height
            )
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .animation(.easeOut(duration: 0.12), value: edge)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The label that follows the pointer during a window drag.
struct WindowDragPreviewLayer: View {
    let drag: WindowDragState

    var body: some View {
        GeometryReader { proxy in
            if drag.subject != nil, !drag.slidesInStrip, let preview = drag.preview {
                let origin = proxy.frame(in: .global).origin
                HStack(spacing: 7) {
                    if let harness = preview.harness {
                        HarnessIdentityIcon(harness: harness, size: 14)
                    } else if let systemName = preview.systemName {
                        Image(systemName: systemName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(preview.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: 260)
                .fixedSize()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ParityTheme.separator) }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                .position(x: drag.location.x - origin.x + 12, y: drag.location.y - origin.y + 18)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
