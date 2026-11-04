import AppKit
import SwiftUI

/// The steps the person has opened or ticked in a setup assistant, kept across launches so the
/// checks stay while they work in the console (`ConnectorSetupAssistant`).
struct ConnectorSetupProgress {
    static let key = "YardletConnectorSetupOpened"

    static func decode(_ text: String) -> Set<ConnectorSetupAssistant.StepID> {
        Set(text.split(separator: ",").compactMap { ConnectorSetupAssistant.StepID(rawValue: String($0)) })
    }

    static func encode(_ steps: Set<ConnectorSetupAssistant.StepID>) -> String {
        steps.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// An assistant's heading: what it sets up and how far along it is.
struct ConnectorSetupHeader: View {
    let title: String
    let assistant: ConnectorSetupAssistant

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            Text(assistant.isComplete ? L10n.string("All set")
                 : L10n.format("%lld of %lld done", Int64(assistant.doneCount), Int64(assistant.steps.count)))
                .font(.caption.weight(.medium))
                .foregroundStyle(assistant.isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
    }
}

/// One step: a check (or its number) the person can tick, the title and a line of detail, the
/// button that opens its console page, copy buttons for what it asks to paste, and any fields.
struct ConnectorSetupStepRow<Content: View>: View {
    let number: Int
    let step: ConnectorSetupAssistant.Step
    let isCurrent: Bool
    /// Ticks or unticks a console step; nil for a step Yardlet decides itself.
    let onToggle: (() -> Void)?
    /// The step's console page was opened from here.
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.title)
                        .font(.callout.weight(isCurrent ? .semibold : .medium))
                        .foregroundStyle(step.isDone && !isCurrent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if let link = step.link {
                        Button {
                            onOpen()
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            Label(link.title, systemImage: "arrow.up.right.square")
                                .labelStyle(.titleAndIcon)
                        }
                        .controlSize(.small)
                        .help(link.url.absoluteString)
                    }
                }
                if let detail = step.detail, !step.isDone || isCurrent {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !step.copies.isEmpty, !step.isDone || isCurrent {
                    HStack(spacing: 6) {
                        ForEach(step.copies, id: \.label) { copy in
                            ConnectorCopyButton(label: copy.label, value: copy.value)
                        }
                    }
                }
                content()
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.title)
        .accessibilityValue(step.isDone ? L10n.string("Done") : L10n.string("Not done"))
    }

    private var marker: some View {
        Button {
            onToggle?()
        } label: {
            ZStack {
                Circle()
                    .fill(step.isDone ? Color.green : (isCurrent ? ParityTheme.accent : Color.clear))
                Circle()
                    .strokeBorder(step.isDone ? Color.green : (isCurrent ? ParityTheme.accent : ParityTheme.separator), lineWidth: 1)
                if step.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onToggle != nil)
        .help(onToggle == nil ? "" : (step.isDone ? L10n.string("Mark as not done") : L10n.string("Mark as done")))
        .accessibilityLabel(step.isDone ? L10n.string("Mark as not done") : L10n.string("Mark as done"))
    }
}

/// A small button that copies a value the person pastes into a console, and says it did.
struct ConnectorCopyButton: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            TranscriptClipboard.copy(value)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? L10n.string("Copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help(value.count > 120 ? String(value.prefix(120)) + "…" : value)
        .accessibilityLabel(L10n.format("Copy %@", label))
    }
}

/// A text field whose value is checked as it is typed: a red line says what is wrong, a green
/// check says it looks right.
struct ConnectorValidatedField: View {
    let title: String
    @Binding var text: String
    var secure = false
    let validation: ConnectorSetupAssistant.Validation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    if secure {
                        SecureField(title, text: $text)
                    } else {
                        TextField(title, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                Image(systemName: validation.isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(validation.isValid ? Color.green : Color.red)
                    .opacity(validation == .empty ? 0 : 1)
                    .accessibilityHidden(true)
            }
            if let message = validation.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
