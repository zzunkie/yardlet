import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A task dragged from the sidebar. Only Yardlet reads it; it carries the local task ID.
    static let yardletTaskReference = UTType(exportedAs: "com.zzunkie.yardlet.task-reference")
}

/// The payload of a sidebar task drag.
struct TaskDragItem: Codable, Transferable {
    let sessionID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .yardletTaskReference)
    }
}

enum SplitLayoutMetrics {
    static let minimumPaneWidth: CGFloat = 320
    static let minimumPaneHeight: CGFloat = 200
    static let handleThickness: CGFloat = 6
    /// A pane's header, which heads its task's area (`SplitPaneHeader`).
    static let paneHeaderHeight: CGFloat = 36

    /// Whether a pane of `size` has room for two panes along `direction`.
    static func canSplit(_ size: CGSize?, _ direction: SplitDirection) -> Bool {
        guard let size else { return true }
        return direction.axis == .horizontal
            ? size.width >= minimumPaneWidth * 2 + handleThickness
            : size.height >= minimumPaneHeight * 2 + handleThickness
    }
}

/// Renders a split tree. Each pane's content comes from `pane`; the handle between two
/// children resizes their shares of the branch.
struct SplitNodeView<Pane: View>: View {
    let node: SplitNode
    let path: [Int]
    let pane: (SplitPane) -> Pane
    let onResize: ([Int], [Double]) -> Void

    var body: some View {
        switch node {
        case let .pane(splitPane):
            pane(splitPane)
        case let .branch(axis, children, fractions):
            SplitBranchView(
                axis: axis,
                fractions: fractions.count == children.count
                    ? fractions
                    : Array(repeating: 1 / Double(children.count), count: children.count),
                onCommit: { onResize(path, $0) }
            ) { index in
                AnyView(SplitNodeView(node: children[index], path: path + [index], pane: pane, onResize: onResize))
            }
        }
    }
}

private struct SplitBranchView: View {
    let axis: SplitAxis
    let fractions: [Double]
    let onCommit: ([Double]) -> Void
    let child: (Int) -> AnyView
    @State private var liveFractions: [Double]?
    @State private var dragStart: [Double]?

    private var isHorizontal: Bool { axis == .horizontal }

    var body: some View {
        GeometryReader { proxy in
            let total = isHorizontal ? proxy.size.width : proxy.size.height
            let handles = CGFloat(fractions.count - 1) * SplitLayoutMetrics.handleThickness
            let available = max(0, total - handles)
            let shares = liveFractions ?? fractions
            let layout = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(fractions.indices, id: \.self) { index in
                    if index > 0 {
                        handle(between: index - 1, available: available)
                    }
                    child(index)
                        .frame(
                            width: isHorizontal ? available * shares[index] : nil,
                            height: isHorizontal ? nil : available * shares[index]
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }

    private func handle(between index: Int, available: CGFloat) -> some View {
        Color.clear
            .frame(
                width: isHorizontal ? SplitLayoutMetrics.handleThickness : nil,
                height: isHorizontal ? nil : SplitLayoutMetrics.handleThickness
            )
            .overlay {
                Rectangle().fill(ParityTheme.separator)
                    .frame(width: isHorizontal ? 1 : nil, height: isHorizontal ? nil : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(
                // Measured in the window, as the sidebar's line is: the handle moves with the boundary.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? fractions
                        if dragStart == nil { dragStart = start }
                        let delta = Double((isHorizontal ? value.translation.width : value.translation.height) / max(available, 1))
                        liveFractions = Self.moving(start, boundary: index, by: delta, available: available, isHorizontal: isHorizontal)
                    }
                    .onEnded { _ in
                        if let liveFractions { onCommit(liveFractions) }
                        liveFractions = nil
                        dragStart = nil
                    }
            )
            // A double click gives the two panes beside the line equal room, as the Claude app's line
            // between tiles and the Codex app's between two content panes do; the side panel's, the
            // terminal's and the sidebar's lines return to their default size the same way.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard fractions.indices.contains(index + 1) else { return }
                let even = (fractions[index] + fractions[index + 1]) / 2
                onCommit(Self.moving(fractions, boundary: index, by: even - fractions[index],
                                     available: available, isHorizontal: isHorizontal))
            })
            .accessibilityElement()
            .accessibilityLabel(L10n.string("Resize panes"))
            .accessibilityAdjustableAction { direction in
                let step = Double(30 / max(available, 1))
                onCommit(Self.moving(
                    fractions, boundary: index, by: direction == .increment ? step : -step,
                    available: available, isHorizontal: isHorizontal
                ))
            }
    }

    /// Moves the boundary after child `boundary` by `delta` of the branch, keeping both
    /// neighbors at least their minimum size and the other children unchanged.
    static func moving(
        _ fractions: [Double],
        boundary: Int,
        by delta: Double,
        available: CGFloat,
        isHorizontal: Bool
    ) -> [Double] {
        guard fractions.indices.contains(boundary + 1) else { return fractions }
        let pair = fractions[boundary] + fractions[boundary + 1]
        let minimumSize = isHorizontal ? SplitLayoutMetrics.minimumPaneWidth : SplitLayoutMetrics.minimumPaneHeight
        let minimum = min(Double(minimumSize / max(available, 1)), pair / 2)
        var result = fractions
        result[boundary] = min(max(fractions[boundary] + delta, minimum), pair - minimum)
        result[boundary + 1] = pair - result[boundary]
        return result
    }
}

/// Accepts a task dragged from the sidebar, or dragged in the window (a window tab, another pane, a side
/// panel's conversation tab, `WindowDragState`), and shows which side of the pane it will take.
struct PaneDropTarget: ViewModifier {
    /// The split pane, or nil for the task a tab shows alone.
    var paneID: UUID? = nil
    /// The task the pane shows, which a drag of that same task does not split.
    var sessionID: UUID? = nil
    let onDrop: (UUID, SplitDirection) -> Void
    @State private var edge: SplitDirection?
    @State private var frame: CGRect = .zero
    @State private var token = UUID()
    @Environment(\.windowDrag) private var drag

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                self.frame = frame
                register()
            }
            .onChange(of: sessionID) { register() }
            .onDisappear { drag?.removePane(token: token) }
            .overlay {
                if let edge {
                    PaneDropHighlight(edge: edge, size: frame.size)
                } else if let shown = windowDragEdge {
                    PaneDropHighlight(edge: shown, size: frame.size)
                }
            }
            .onDrop(
                of: [.yardletTaskReference],
                delegate: PaneDropDelegate(size: frame.size, edge: $edge, onDrop: onDrop)
            )
    }

    private func register() {
        drag?.setPane(WindowDropGeometry.Pane(paneID: paneID, sessionID: sessionID, frame: frame), token: token)
    }

    /// The side a window drag would take while it is over this pane; the whole pane (nil) for a swap.
    private var windowDragEdge: SplitDirection?? {
        switch drag?.target {
        case let .pane(id, edge)? where id == paneID: edge
        case let .swapPane(id)? where id == paneID: .some(nil)
        default: nil
        }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var edge: SplitDirection?
    let onDrop: (UUID, SplitDirection) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.yardletTaskReference])
    }

    func dropEntered(info: DropInfo) { edge = Self.edge(for: info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = Self.edge(for: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let direction = Self.edge(for: info.location, in: size)
        edge = nil
        guard let provider = info.itemProviders(for: [.yardletTaskReference]).first else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            let sessionID: UUID? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: TaskDragItem.self) { result in
                    continuation.resume(returning: try? result.get().sessionID)
                }
            }
            if let sessionID { onDrop(sessionID, direction) }
        }
        return true
    }

    /// The side of the pane nearest the pointer.
    static func edge(for location: CGPoint, in size: CGSize) -> SplitDirection {
        PaneDropEdge.edge(for: location, in: size)
    }
}
