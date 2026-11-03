import SwiftUI

/// The composer's session controls, in the one bottom row every harness shares (plan A6.2):
///
///     [+][@][mode | Plan][permissions][skills] … [context ring][model][queue/steer][Send | Stop]
///
/// `leading` draws what follows `+` and `@`; `trailing` what precedes the queue and Send. Which
/// controls appear, their choices, names and current values come from `ComposerSessionOptions`;
/// a choice goes back through `onChoose` in the form its provider applies. Each control is its
/// own subview of the row, so the row wraps them like the controls around them.
struct ComposerSessionControls: View {
    enum Placement {
        case leading
        case trailing
    }

    let options: ComposerSessionOptions
    let placement: Placement
    var isDisabled = false
    /// The Model and Reasoning slash commands open the model menu at their own list.
    var modelOpenRequest: CodexModelPickerRequest? = nil
    /// Whether its model control answers the task's keyboard requests (Tab order, ⌃⇧M); a copy
    /// elsewhere in the task, such as a suggestion's Options, leaves them to the composer's.
    var registersTaskFocus = true
    let onChoose: (ComposerSessionChoice) -> Void
    /// Reads choices a control does not have yet: a detached task's settings or a model list.
    let onPrepare: () async -> Void
    /// Turns Codex's Plan mode off. Without it the Plan indicator is not drawn.
    var onTurnOffPlanMode: (() -> Void)? = nil
    var onInsertSkill: (CodexSkillSummary) -> Void = { _ in }
    /// The context window's "Compact session", where the task's composer can compact.
    var compact: ComposerContextUsageDetails.Compact? = nil

    @State private var isPreparing = false

    var body: some View {
        switch placement {
        case .leading: leading
        case .trailing: trailing
        }
    }

    @ViewBuilder private var leading: some View {
        switch options.mode {
        case .planIndicator?:
            if let onTurnOffPlanMode { ComposerPlanIndicator(onTurnOff: onTurnOffPlanMode) }
        case let .selector(selector, canChoose, apply)?:
            ComposerModeControl(selector: selector, canChoose: canChoose, isPreparing: $isPreparing,
                                isDisabled: isDisabled, onPrepare: onPrepare) { id, value in
                if let choice = apply.choice(id: id, value: value) { onChoose(choice) }
            }
        case nil:
            EmptyView()
        }
        if let permission = options.permission {
            ComposerPermissionControl(slot: permission, isPreparing: $isPreparing, isDisabled: isDisabled,
                                      onChoose: onChoose, onPrepare: onPrepare)
        }
        if let skills = options.skills {
            ComposerSkillsControl(skills: skills.skills, onInsert: onInsertSkill)
        }
        if options.isLoadingSettings || isPreparing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .accessibilityLabel(L10n.string("Loading"))
        }
        if let error = options.settingsError {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityLabel(error)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let summary = ComposerContextSummary.make(usage: options.contextUsage,
                                                     reportsContextWindow: options.reportsContextWindow) {
            ComposerContextUsageIndicator(summary: summary, usage: options.contextUsage,
                                          breakdowns: options.usageBreakdowns, compact: compact)
        }
        // Beside Send, as both reference apps place it.
        if let model = options.model {
            ComposerModelControl(menu: model.menu, onPrepare: onPrepare, onSetOption: { id, value in
                if let choice = model.apply.choice(id: id, value: value) { onChoose(choice) }
            }, openRequest: modelOpenRequest, isDisabled: isDisabled, registersTaskFocus: registersTaskFocus)
        }
    }
}

/// The Codex app's footer indicator: Plan mode is on for the next turn, and clicking it turns
/// Plan mode off.
private struct ComposerPlanIndicator: View {
    let onTurnOff: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTurnOff) {
            ParityComposerControl(title: L10n.string("Plan mode indicator"),
                                  systemName: isHovered ? "xmark" : "list.bullet.clipboard")
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovered = $0 }
        .help(L10n.string("Create a plan"))
        .accessibilityLabel(L10n.string("Plan mode indicator"))
        .accessibilityHint(L10n.string("Turn plan mode off"))
    }
}

/// A provider's own session mode selector, in the composer's row and the session rail's Settings card.
struct ComposerModeControl: View {
    let selector: ProviderCapabilitySelector
    let canChoose: Bool
    @Binding var isPreparing: Bool
    let isDisabled: Bool
    let onPrepare: () async -> Void
    let onSelect: (String, String) -> Void

    @State private var isPresented = false
    @FocusState private var isTriggerFocused: Bool

    private var title: String { ProviderCapabilityAccessibility.selectedChoiceName(for: selector) }

    var body: some View {
        Button {
            guard canChoose else {
                // A detached task reads its settings first; nothing is changed by opening.
                isPreparing = true
                Task { @MainActor in
                    await onPrepare()
                    isPreparing = false
                    isPresented = true
                }
                return
            }
            isPresented = true
        } label: {
            ParityComposerControl(title: title, systemName: nil, showsChevron: true, isActive: isPresented)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(isPreparing || isDisabled)
        .focused($isTriggerFocused)
        .accessibilityLabel(selector.name)
        .accessibilityValue(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ComposerProviderOptionMenu(selector: selector, isEnabled: canChoose, onSelect: onSelect,
                                       onDismiss: { isPresented = false })
                .frame(width: 264)
                .onExitCommand { isPresented = false }
        }
        .onChange(of: isPresented) { _, shown in
            guard !shown, ParityInteraction.currentEventIsKeyboard else { return }
            DispatchQueue.main.async { if !isPresented { isTriggerFocused = true } }
        }
    }
}

/// The policy the next turn runs with, and the provider's choices of it. A choice the provider
/// asks about first (Codex's Full access) is confirmed in the provider's words before it applies.
struct ComposerPermissionControl: View {
    let slot: ComposerPermissionSlot
    @Binding var isPreparing: Bool
    let isDisabled: Bool
    let onChoose: (ComposerSessionChoice) -> Void
    let onPrepare: () async -> Void
    /// The composer's control takes the task's permissions focus; the session rail's copy does not.
    var registersTaskFocus = true

    @State private var isPresented = false
    @State private var opensFromKeyboard = false
    @State private var returnsFocus = false
    @State private var confirming: ConfirmationRequest?
    @FocusState private var isTriggerFocused: Bool
    @FocusState private var focusedChoice: String?

    private struct ConfirmationRequest: Equatable {
        let choice: ComposerSessionChoice
        let confirmation: ComposerPermissionSlot.Confirmation
    }

    var body: some View {
        Button(action: present) {
            ParityComposerControl(
                title: slot.title,
                systemName: slot.hasPendingRequest ? "exclamationmark.shield" : "checkmark.shield",
                showsChevron: true,
                tint: slot.hasPendingRequest || slot.isElevated ? .orange : .secondary,
                isActive: isPresented
            )
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .fixedSize()
        .disabled(isPreparing || isDisabled)
        .focused($isTriggerFocused)
        .taskFocus(.permissions, isFocused: $isTriggerFocused, enabled: registersTaskFocus)
        .accessibilityLabel(L10n.string("Permissions"))
        .accessibilityValue(slot.title)
        .accessibilityHint(slot.accessibilityHint)
        .modifier(ComposerControlHelp(text: slot.help))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { menu }
        .onChange(of: isPresented) { _, shown in
            guard !shown else { return }
            let returning = returnsFocus || ParityInteraction.currentEventIsKeyboard
            returnsFocus = false
            guard returning else { return }
            isTriggerFocused = false
            DispatchQueue.main.async {
                if !isPresented, confirming == nil { isTriggerFocused = true }
            }
        }
        .alert(confirming?.confirmation.title ?? "", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { request in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(request.confirmation.confirm, role: .destructive) { onChoose(request.choice) }
        } message: { request in
            Text(request.confirmation.message)
        }
    }

    private var menu: some View {
        ComposerPermissionMenu(slot: slot, focusedChoice: $focusedChoice) { choice, selector, isSelected in
            choose(choice, in: selector, isSelected: isSelected)
        }
        .onAppear {
            if opensFromKeyboard { focusedChoice = slot.selector?.choices.first?.value }
        }
        .onExitCommand { dismiss() }
    }

    private func present() {
        guard !isPreparing else { return }
        opensFromKeyboard = ParityInteraction.currentEventIsKeyboard
        guard slot.preparesBeforeOpening else {
            isPresented = true
            return
        }
        isPreparing = true
        Task { @MainActor in
            await onPrepare()
            isPreparing = false
            isPresented = true
        }
    }

    private func dismiss() {
        returnsFocus = true
        isPresented = false
    }

    private func choose(_ choice: ProviderCapabilityChoice, in selector: ProviderCapabilitySelector, isSelected: Bool) {
        dismiss()
        guard slot.canChoose, !isSelected,
              let applied = slot.apply.choice(id: selector.id, value: choice.value) else { return }
        if let confirmation = slot.confirmations[choice.value] {
            confirming = ConfirmationRequest(choice: applied, confirmation: confirmation)
        } else {
            onChoose(applied)
        }
    }
}

/// The permission control's menu: the policy now, then the provider's description and choices, or
/// what the session says about permissions without them.
struct ComposerPermissionMenu: View {
    let slot: ComposerPermissionSlot
    var focusedChoice: FocusState<String?>.Binding
    let onChoose: (ProviderCapabilityChoice, ProviderCapabilitySelector, _ isSelected: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerPermissionHeader(value: slot.title, hasPendingPermission: slot.hasPendingRequest)
            Divider()
            if slot.showsChoices, let selector = slot.selector {
                if let description = selector.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                ForEach(selector.choices) { choice in
                    let isSelected = choice.value == selector.currentValue
                    IntelligencePickerRow(isEnabled: slot.canChoose || isSelected) {
                        onChoose(choice, selector, isSelected)
                    } content: {
                        ComposerOptionChoiceLabel(choice: choice, isSelected: isSelected)
                    }
                    .focused(focusedChoice, equals: choice.value)
                }
                if !slot.canChoose { ComposerDetachedNotice() }
            } else if let explanation = slot.explanation {
                Label {
                    Text(explanation.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: explanation.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .padding(.vertical, 6)
        .background(ParityTheme.elevated)
        .frame(width: 264, alignment: .leading)
    }
}

/// Skills the next message can carry.
private struct ComposerSkillsControl: View {
    let skills: [CodexSkillSummary]
    let onInsert: (CodexSkillSummary) -> Void

    @State private var isPresented = false
    @State private var opensFromKeyboard = false
    @State private var returnsFocus = false
    @FocusState private var isTriggerFocused: Bool
    @FocusState private var focusedSkill: String?

    var body: some View {
        Button {
            opensFromKeyboard = ParityInteraction.currentEventIsKeyboard
            isPresented = true
        } label: {
            ParityComposerControl(title: L10n.string("Skills"), systemName: "wand.and.stars", showsChevron: true)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .focused($isTriggerFocused)
        .accessibilityLabel(L10n.string("Skills"))
        .help(L10n.string("Insert skill"))
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(skills) { skill in
                    Button(skill.displayName) {
                        dismiss()
                        onInsert(skill)
                    }
                    .parityPointer()
                    .focused($focusedSkill, equals: skill.id)
                }
            }
            .padding(8)
            .frame(minWidth: 170, alignment: .leading)
            .onAppear { if opensFromKeyboard { focusedSkill = skills.first?.id } }
            .onExitCommand { dismiss() }
        }
        .onChange(of: isPresented) { _, shown in
            guard !shown else { return }
            let returning = returnsFocus || ParityInteraction.currentEventIsKeyboard
            returnsFocus = false
            guard returning else { return }
            isTriggerFocused = false
            DispatchQueue.main.async { if !isPresented { isTriggerFocused = true } }
        }
    }

    private func dismiss() {
        returnsFocus = true
        isPresented = false
    }
}

/// A tooltip only where the provider's control has one.
private struct ComposerControlHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
