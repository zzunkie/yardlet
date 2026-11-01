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
/// view shows one task's state for another. SwiftUI still updates views out of a window when what they
/// read changes, so a task out of the window reads nothing (`TaskSurfacePresence`).
///
/// The hosting view reads its appearance, scale and accessibility from its window as any hosting view
/// does. What the window sets above the task for its views is given again here, each value read so
/// that a change updates the task.
struct TaskSurfaceHost: NSViewRepresentable {
    let taskID: UUID
    let hostings: TaskSurfaceHostings
    let content: AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> TaskSurfaceHostings { hostings }

    func updateNSView(_ container: NSView, context: Context) {
        let window = context.environment
        let (hosting, presence) = hostings.hosting(for: taskID)
        // Before the task's views are given anew, so they read the task as it is now.
        hostings.show(taskID)
        hosting.rootView = AnyView(content
            .environment(\.taskSurfacePresence, presence)
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

    static func dismantleNSView(_ container: NSView, coordinator: TaskSurfaceHostings) {
        for shown in container.subviews { shown.removeFromSuperview() }
        coordinator.show(nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// The hosting views of the tasks a window showed last, the latest last. A window keeps as many as
/// the conversations keep turns for (`ConversationRenderState.recentLimit`) and lets older ones go.
@MainActor
final class TaskSurfaceHostings {
    private var kept: [(taskID: UUID, hosting: NSHostingView<AnyView>, presence: TaskSurfacePresence)] = []

    func hosting(for taskID: UUID) -> (NSHostingView<AnyView>, TaskSurfacePresence) {
        let found = kept.first { $0.taskID == taskID }
        let hosting = found?.hosting ?? Self.makeHosting()
        let presence = found?.presence ?? TaskSurfacePresence()
        kept.removeAll { $0.taskID == taskID }
        kept.append((taskID, hosting, presence))
        if kept.count > ConversationRenderState.recentLimit {
            kept.removeFirst(kept.count - ConversationRenderState.recentLimit)
        }
        return (hosting, presence)
    }

    /// The task the window shows alone, whose views are in the window; the others' are out of it.
    func show(_ taskID: UUID?) {
        for kept in kept {
            let isInWindow = kept.taskID == taskID
            if kept.presence.isInWindow != isInWindow { kept.presence.isInWindow = isInWindow }
        }
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

/// Whether a task's views that a window keeps (`TaskSurfaceHostings`) are in the window. Out of it,
/// the task's views read nothing of the model (`TaskObservationScope`).
@MainActor
@Observable
final class TaskSurfacePresence {
    var isInWindow = true
}

private struct TaskSurfacePresenceKey: EnvironmentKey {
    static let defaultValue: TaskSurfacePresence? = nil
}

extension EnvironmentValues {
    /// Whether the task these views are of is in the window; nil where the task is not drawn in views the
    /// window keeps (a split view's pane), which are in the window while they are drawn.
    var taskSurfacePresence: TaskSurfacePresence? {
        get { self[TaskSurfacePresenceKey.self] }
        set { self[TaskSurfacePresenceKey.self] = newValue }
    }
}
