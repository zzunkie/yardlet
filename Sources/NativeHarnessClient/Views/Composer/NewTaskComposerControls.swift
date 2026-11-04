import SwiftUI

/// Shared copy and identity controls for a new task, whether its harness runs here or on a host.
enum NewTaskComposerText {
    static func placeholder(harnessName: String?) -> String {
        harnessName.map { L10n.format("Ask %@ to do anything", $0) } ?? L10n.string("Describe a task…")
    }
}

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
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 13 * interfaceScale, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 28 * interfaceScale)
        }
        .menuStyle(.borderlessButton)
        .parityPointer()
        .layoutPriority(1)
        .help(harness?.displayName ?? L10n.string("No available harnesses"))
        .accessibilityLabel(L10n.string("Harness"))
        .accessibilityValue(harness?.displayName ?? L10n.string("No available harnesses"))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The same wrapping control row for a local or remote new task. The model popover stays outside
/// the two arrangements, so loading longer model names never replaces the view presenting it.
struct NewTaskComposerControlRow<Primary: View, Secondary: View, Trailing: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .newTaskControlRow, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    primary()
                    secondary()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) { primary() }
                    HStack(spacing: 7) { secondary() }
                        .alignmentGuide(.newTaskControlRow) { $0[VerticalAlignment.center] }
                }
            }
            Spacer(minLength: 8)
            trailing()
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
                         isProminent: true, action: onStart)
            .disabled(!canStart || commandMenuOpen)
            .opacity(canStart ? 1 : 0.4)
            .keyboardShortcut(.return, modifiers: .command)
    }
}

/// Start and the model align with the second row when the primary controls wrap.
private enum NewTaskControlRowAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
}

private extension VerticalAlignment {
    static let newTaskControlRow = VerticalAlignment(NewTaskControlRowAlignment.self)
}
