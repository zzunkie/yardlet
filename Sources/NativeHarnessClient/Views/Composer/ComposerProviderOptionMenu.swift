import SwiftUI

/// The common menu geometry with the provider's actual option identity and wording.
struct ComposerProviderOptionMenu: View {
    let selector: ProviderCapabilitySelector
    let isEnabled: Bool
    let onSelect: (String, String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selector.name).font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
            ForEach(selector.choices) { choice in
                let selected = choice.value == selector.currentValue
                IntelligencePickerRow(isEnabled: isEnabled || selected, action: {
                    if isEnabled && !selected { onSelect(selector.id, choice.value) }
                    onDismiss()
                }) {
                    ComposerOptionChoiceLabel(choice: choice, isSelected: selected)
                }
            }
            if !isEnabled {
                Text(L10n.string("Resume the task to change live settings."))
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .padding(.vertical, 6).background(ParityTheme.elevated)
    }
}

struct ComposerOptionChoiceLabel: View {
    let choice: ProviderCapabilityChoice
    let isSelected: Bool
    var body: some View {
        let description = choice.description.flatMap { $0.isEmpty ? nil : $0 }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name).lineLimit(1)
                if let description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A described choice is taller than the row; this keeps it apart from the next one.
            .padding(.vertical, description == nil ? 0 : 5)
            Spacer(minLength: 8)
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                .opacity(isSelected ? 1 : 0)
        }
    }
}
