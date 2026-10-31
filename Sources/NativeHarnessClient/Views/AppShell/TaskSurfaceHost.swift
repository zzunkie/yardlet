import AppKit
import SwiftUI

/// The task a window shows alone, drawn in a hosting view of its own that the window keeps for the
/// tasks it showed last (`TaskSurfaceHostings`). Opening one of them again puts its views back as they
/// were instead of building them anew; building them is most of a switch, and while an assistive app
/// or a window manager is attached every accessibility element built looks through the whole window
/// for the focused view. The task's own hosting view also keeps that search to the task's views.
///
/// A task's views out of the window are a task that is not shown: SwiftUI calls their `onDisappear`,
/// ends their `task`s and draws nothing for them until they are back in the window, where they appear
/// again with the values they are given then. Only their state stays: each task keeps its own, and no
/// view shows one task's state for another.
///
/// The hosting view reads its appearance, scale and accessibility from its window as any hosting view
/// does. What the window sets above the task for its views is given again here, each value read so
/// that a change updates the task.
struct TaskSurfaceHost: NSViewRepresentable {
    let taskID: UUID
    let hostings: TaskSurfaceHostings
    let content: AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let window = context.environment
        let hosting = hostings.hosting(for: taskID)
        hosting.rootView = AnyView(content
            .environment(\.yardletInterfaceScale, window.yardletInterfaceScale)
            .dynamicTypeSize(window.dynamicTypeSize)
            .environment(\.windowDrag, window.windowDrag)
            .environment(\.taskWindowHeight, window.taskWindowHeight)
            .environment(\.openImageViewer, window.openImageViewer)
            // The shell's controls are monochrome (`MainWindow`).
            .tint(Color.primary))
        guard hosting.superview !== container else { return }
        // The task shown before leaves the window; its hosting view stays with the window's kept ones.
        for shown in container.subviews { shown.removeFromSuperview() }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for shown in container.subviews { shown.removeFromSuperview() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// The hosting views of the tasks a window showed last, the latest last. A window keeps as many as
/// the conversations keep turns for (`ConversationRenderState.recentLimit`) and lets older ones go.
@MainActor
final class TaskSurfaceHostings {
    private var kept: [(taskID: UUID, hosting: NSHostingView<AnyView>)] = []

    func hosting(for taskID: UUID) -> NSHostingView<AnyView> {
        let hosting = kept.first { $0.taskID == taskID }?.hosting ?? Self.makeHosting()
        kept.removeAll { $0.taskID == taskID }
        kept.append((taskID, hosting))
        if kept.count > ConversationRenderState.recentLimit {
            kept.removeFirst(kept.count - ConversationRenderState.recentLimit)
        }
        return hosting
    }

    private static func makeHosting() -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // The window gives the task its size, with the title bar's safe area already laid out.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        return hosting
    }
}

/// The keyboard focus of the title bar's panel buttons, in the view graph of the task's own hosting
/// view: a focus state moves focus only among the views of the graph it belongs to.
struct TaskSurfaceFocusScope<Content: View>: View {
    @FocusState private var focusedSurface: TaskSurface?
    @ViewBuilder let content: (FocusState<TaskSurface?>.Binding) -> Content

    var body: some View { content($focusedSurface) }
}
