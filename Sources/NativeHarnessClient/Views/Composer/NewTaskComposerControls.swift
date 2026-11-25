import SwiftUI

struct NewTaskHarnessControl<Items: View>: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let harness: HarnessKind?
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 5) {
                if let harness {
                    HarnessIdentityLabel(harness: harness)
                } else {
                    Label(L10n.string("Choose harness"), systemImage: "square.stack.3d.up")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * interfaceScale, weight: .semibold))
            }
            .font(.system(size: 13 * interfaceScale, weight: .medium))
            .padding(.horizontal, 7)
            // The other composer controls' height (`ParityComposerControl`).
            .frame(height: 24 * interfaceScale)
            .contentShape(Rectangle())
            // One control for VoiceOver, named below, not one for each of its symbols and words.
            .accessibilityElement(children: .ignore)
        }
        // SwiftUI draws the label, so the control keeps the height above and its accessibility name: as an
        // AppKit pop-up button it took its symbol's description ("hdr") for a name.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .parityPointer()
        .layoutPriority(1)
        .help(harness?.displayName ?? L10n.string("No available harnesses"))
        .accessibilityLabel(L10n.string("Harness"))
        .accessibilityValue(harness?.displayName ?? L10n.string("No available harnesses"))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The same wrapping control row for a local or remote new task, laid out as the task composer's
/// (`ControlRowLayout`): what does not fit beside the rest moves to a row of its own, down to a split
/// pane's width, with the model and Start at the trailing edge of the last one. No control is replaced
/// as the row wraps, so an open menu or popover stays where it is.
struct NewTaskComposerControlRow<Primary: View, Secondary: View, Trailing: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ControlRowLayout(pinsTrailingActions: true) {
            ControlRowLayout { primary() }
            ControlRowLayout { secondary() }
            HStack(spacing: 7) { trailing() }
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }
}

struct NewTaskStartControl: View {
    let canStart: Bool
    let isStarting: Bool
    let commandMenuOpen: Bool
    let onStart: () -> Void

    var body: some View {
        if isStarting { ProgressView().controlSize(.small) }
        ParityIconButton(systemName: "arrow.up", help: L10n.string(isStarting ? "Starting task…" : "Start task"),
                         isProminent: true, shortcut: ComposerShortcut.start, action: onStart)
            .disabled(!canStart || commandMenuOpen)
            .keyboardShortcut(ComposerShortcut.start)
    }
}
