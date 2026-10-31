import SwiftUI

/// The sidebar's families as last drawn, which a task row reads only when the person acts on it:
/// its menu reads the moves as it opens, and a drag reads them as it passes over the row
/// (`TaskNesting`). So the other rows of a list are no part of what a row compares to decide whether
/// to draw again, and a drag draws again only the row it is over.
@MainActor
@Observable
final class SidebarNesting {
    /// The sidebar as last drawn. A row's open menu redraws itself alone when it changes.
    var layout = SidebarProjection.Layout()
    /// Moves a task under another (nil: to the top level).
    @ObservationIgnored var nest: (UUID, UUID?) -> Void = { _, _ in }

    /// The task whose row is being dragged, from the moment its drag starts: a drag's own item can be
    /// read only once dropped, and a row it passes over shows whether and where it would go.
    private(set) static var draggedTaskID: UUID?

    /// What a task row's drag carries, read by SwiftUI when the drag starts.
    static func dragging(_ taskID: UUID) -> TaskDragItem {
        draggedTaskID = taskID
        return TaskDragItem(sessionID: taskID)
    }
}

/// A task row's moves in the sidebar's families, in its menu: "Move up one level" for a task listed
/// under one that is itself nested, "Detach to top level" for any nested task, and "Move under
/// task" with the tasks of its list it can go under.
struct SidebarNestMenuItems: View {
    let taskID: UUID
    let nesting: SidebarNesting

    var body: some View {
        let options = TaskNesting.options(for: taskID, in: nesting.layout)
        if let levelUp = options.levelUp {
            Button(L10n.string("Move up one level")) { nesting.nest(taskID, levelUp) }
        }
        // The Claude app's row menu item for a session another started (`XP5vxiZixk`).
        if options.isNested {
            Button(L10n.string("Detach to top level")) { nesting.nest(taskID, nil) }
        }
        if !options.parents.isEmpty {
            Menu(L10n.string("Move under task")) {
                ForEach(options.parents) { parent in
                    Button(parent.title) { nesting.nest(taskID, parent.id) }
                }
            }
        }
    }
}

/// A task dragged over a task row of the sidebar's families: on the row it would go under the row's
/// task, on the row's top or bottom edge beside it (`TaskNesting.Drop`). The row shows where while it
/// can go there, and a drop moves it.
struct SidebarRowDrop: DropDelegate {
    let target: UUID
    let rowHeight: CGFloat
    let nesting: SidebarNesting
    @Binding var place: TaskNesting.Drop?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.yardletTaskReference]) }

    func dropEntered(info: DropInfo) { show(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: show(info) == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { place = nil }

    func performDrop(info: DropInfo) -> Bool {
        let drop = TaskNesting.drop(at: info.location.y, height: rowHeight)
        place = nil
        guard let provider = info.itemProviders(for: [.yardletTaskReference]).first else { return false }
        let nesting = nesting, target = target
        Task { @MainActor in
            let taskID: UUID? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: TaskDragItem.self) { result in
                    continuation.resume(returning: try? result.get().sessionID)
                }
            }
            // The item dropped, which may have come from another window's sidebar.
            if let taskID, let parent = TaskNesting.parent(of: taskID, dropped: drop, on: target, in: nesting.layout) {
                nesting.nest(taskID, parent)
            }
        }
        return true
    }

    /// Shows where the dragged task would go, if it can go there.
    @discardableResult
    private func show(_ info: DropInfo) -> TaskNesting.Drop? {
        let drop = TaskNesting.drop(at: info.location.y, height: rowHeight)
        let shown = SidebarNesting.draggedTaskID.flatMap {
            TaskNesting.parent(of: $0, dropped: drop, on: target, in: nesting.layout)
        } == nil ? nil : drop
        if place != shown { place = shown }
        return shown
    }
}

/// Where a task dragged over a row would go: the row outlined for under it, as a pane shows a drop
/// (`PaneDropHighlight`), or a line along the row's top or bottom edge from the row's level for beside
/// it, as a tab strip shows the gap a tab would go to (`TabInsertionMark`).
struct SidebarNestDropMark: View {
    let place: TaskNesting.Drop
    /// The level of the row it is shown on, where the line starts.
    let depth: Int

    var body: some View {
        switch place {
        case .under:
            SidebarMetrics.rowShape()
                .fill(ParityTheme.accent.opacity(0.12))
                .overlay { SidebarMetrics.rowShape().strokeBorder(ParityTheme.accent.opacity(0.6), lineWidth: 1.5) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .above, .below:
            Capsule()
                .fill(ParityTheme.accent)
                .frame(height: 2.5)
                .padding(.leading, SidebarRowLeading<EmptyView>.indent(nestingDepth: depth) + SidebarMetrics.gutterWidth / 4)
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity, alignment: place == .above ? .top : .bottom)
                .offset(y: place == .above ? -1.75 : 1.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
