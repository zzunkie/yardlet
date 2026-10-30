import SwiftUI
import Observation

private struct TaskKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: TaskKeyboardFocus? = nil
}

extension EnvironmentValues {
    var taskKeyboardFocus: TaskKeyboardFocus? {
        get { self[TaskKeyboardFocusKey.self] }
        set { self[TaskKeyboardFocusKey.self] = newValue }
    }
}

private struct TaskFocusReceiver: ViewModifier {
    private struct Delivery: Equatable {
        let request: TaskKeyboardFocus.Request?
        let enabled: Bool
    }
    let target: TaskFocusTarget
    let isFocused: FocusState<Bool>.Binding
    let enabled: Bool
    @Environment(\.taskKeyboardFocus) private var focus

    func body(content: Content) -> some View {
        content.task(id: Delivery(request: focus?.request, enabled: enabled)) {
            guard enabled, let request = focus?.request, request.target == target else { return }
            // Wait for the newly opened panel's control to join the window's focus system.
            await Task.yield()
            guard !Task.isCancelled, focus?.consume(request) == true else { return }
            isFocused.wrappedValue = true
        }
    }
}

extension View {
    func taskFocus(_ target: TaskFocusTarget, isFocused: FocusState<Bool>.Binding, enabled: Bool = true) -> some View {
        modifier(TaskFocusReceiver(target: target, isFocused: isFocused, enabled: enabled))
    }
}
