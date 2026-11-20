import SwiftUI

/// An MCP elicitation's form on the request card (`CodexMCPElicitationForm`): each field under the
/// server's title and description, with what it takes (required, a format, a range, a length or a
/// count of choices) and, once something is entered, why it cannot be sent yet. Submit stays off
/// until every required field is filled in and every field is valid (`ConversationRequest.route`).
/// An answered form shows what was sent, read-only, and no default as if it had been sent.
struct CodexMCPElicitationFormView: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let form: CodexMCPElicitationForm
    @Binding var input: [String: CodexMCPElicitationFieldValue]
    let isAnswerable: Bool
    /// The choice under the pointer, drawn as a question's option is (`ConversationQuestionStepsView.rowFill`).
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s16) {
            ForEach(form.fields) { field in
                Group {
                    if form.recorded != nil {
                        sentRow(field)
                    } else {
                        fieldView(field)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(field.label)
            }
        }
        .disabled(!isAnswerable)
    }

    /// A field of an answered form: its title and the value sent, or that none was.
    private func sentRow(_ field: CodexMCPElicitationForm.Field) -> some View {
        let sent = form.sentText(of: field)
        return VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.parity(.caption, weight: .medium, scale: interfaceScale))
                .foregroundStyle(.secondary)
            Text(sent ?? L10n.string("Not answered"))
                .font(.parity(.control, scale: interfaceScale))
                .foregroundStyle(sent == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: CodexMCPElicitationForm.Field) -> some View {
        // The field's name and what it is for, then its control and what it takes.
        VStack(alignment: .leading, spacing: ParitySpace.s8) {
            VStack(alignment: .leading, spacing: 2) {
                if case .boolean = field.kind {
                    Toggle(isOn: flag(field)) {
                        Text(field.label).font(.parity(.control, weight: .medium, scale: interfaceScale))
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(field.label)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(field.label)
                            .font(.parity(.control, weight: .medium, scale: interfaceScale))
                        Text(field.isRequired ? L10n.string("Required") : L10n.string("Optional"))
                            .font(.parity(.caption, scale: interfaceScale))
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = field.description, !description.isEmpty {
                    Text(description)
                        .font(.parity(.caption, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            control(field)
            if let hint = CodexMCPElicitationForm.hint(field.kind) {
                Text(hint)
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
            }
            if let issue = form.shownIssue(of: field, in: input) {
                Text(issue.message)
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.red)
                    .accessibilityLabel(issue.message)
            }
        }
    }

    @ViewBuilder
    private func control(_ field: CodexMCPElicitationForm.Field) -> some View {
        switch field.kind {
        case .text, .number:
            TextField(CodexMCPElicitationForm.placeholder(field.kind), text: text(field))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.label)
        case .boolean:
            EmptyView()
        case let .choice(options):
            optionList(field, options, isMultiple: false)
        case let .choices(options, _, _):
            optionList(field, options, isMultiple: true)
        }
    }

    private func optionList(
        _ field: CodexMCPElicitationForm.Field, _ options: [CodexMCPElicitationForm.Option], isMultiple: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            ForEach(options, id: \.value) { option in
                let isSelected = picked(field).contains(option.value)
                let id = field.id + "\u{0}" + option.value
                Button {
                    toggle(option.value, in: field)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ParitySpace.s8) {
                        Image(systemName: isMultiple ? (isSelected ? "checkmark.square.fill" : "square")
                                                     : (isSelected ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(isSelected ? ParityTheme.accent : Color.secondary)
                            .accessibilityHidden(true)
                        Text(option.title)
                            .font(.parity(.control, weight: isSelected ? .medium : .regular, scale: interfaceScale))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, ConversationRequestSurface.optionInset)
                    .padding(.vertical, ParitySpace.s8)
                    .background(ConversationQuestionStepsView<EmptyView>.rowFill(
                        isSelected: isSelected, isHovered: hovered == id && isAnswerable),
                                in: RoundedRectangle(cornerRadius: ParityRadius.row))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    // MARK: - Values

    private func text(_ field: CodexMCPElicitationForm.Field) -> Binding<String> {
        Binding {
            if case let .text(text)? = form.value(of: field, in: input) { return text }
            return ""
        } set: {
            input[field.id] = .text($0)
        }
    }

    private func flag(_ field: CodexMCPElicitationForm.Field) -> Binding<Bool> {
        Binding {
            if case let .flag(flag)? = form.value(of: field, in: input) { return flag }
            return false
        } set: {
            input[field.id] = .flag($0)
        }
    }

    private func picked(_ field: CodexMCPElicitationForm.Field) -> Set<String> {
        form.picked(field, in: input)
    }

    private func toggle(_ value: String, in field: CodexMCPElicitationForm.Field) {
        input[field.id] = form.toggling(value, in: field, input: input)
    }
}
