import Foundation

/// What a composer's model menu shows: the harness's own model, effort and speed choices, in the
/// one shape every harness uses. Values and choice names are the harness's; only the frame is shared.
struct ComposerModelMenu: Equatable {
    var model: ProviderCapabilitySelector?
    var effort: ProviderCapabilitySelector?
    var speed: ProviderCapabilitySelector?
    /// Whether the choices can be made now: the runtime is attached, or the list it last gave
    /// stands in for it before a task connects. Otherwise opening the menu loads the list first.
    var canChoose = true

    var isEmpty: Bool { model == nil && effort == nil }

    /// The model, then the effort, then the speed when it is on, as the Claude app's Code composer
    /// labels its model button ("Opus 5.5 · High · Fast").
    var title: String {
        let parts = labelParts
        return parts.isEmpty ? L10n.string("Model") : parts.joined(separator: " · ")
    }

    /// What the button shows first: the model, or "Model" before one is known.
    var triggerTitle: String { labelParts.first ?? L10n.string("Model") }

    /// What follows it, dimmer, as the Claude app dims the effort after the model's name.
    var triggerDetail: String? {
        let rest = labelParts.dropFirst()
        return rest.isEmpty ? nil : rest.joined(separator: " · ")
    }

    var accessibilityValue: String { labelParts.joined(separator: ", ") }

    private var labelParts: [String] {
        [model.map(ProviderCapabilityAccessibility.selectedChoiceName(for:)),
         effort.map(ProviderCapabilityAccessibility.selectedChoiceName(for:)),
         speedLabel].compactMap { $0 }
    }

    private var speedLabel: String? {
        guard let speed else { return nil }
        if speed.isBinarySpeedSwitch {
            return speed.currentValue == "on" ? speed.name : nil
        }
        guard !speed.currentValue.isEmpty, speed.currentValue != "default", speed.currentValue != "off" else {
            return nil
        }
        return ProviderCapabilityAccessibility.selectedChoiceName(for: speed)
    }

    /// A provider's own selectors, as Claude Code and the ACP harnesses report them.
    static func provider(_ selectors: [ProviderCapabilitySelector], speed: ProviderCapabilitySelector?,
                         canChoose: Bool) -> ComposerModelMenu {
        ComposerModelMenu(
            model: selectors.first { ConversationSessionStatusProjection.role(for: $0) == .model },
            effort: selectors.first { ConversationSessionStatusProjection.role(for: $0) == .reasoning },
            speed: speed, canChoose: canChoose)
    }

    /// Codex's typed catalog. Before the list has loaded the model still shows by its ID, and
    /// opening the menu loads the list.
    static func codex(_ catalog: CodexModelCatalog) -> ComposerModelMenu {
        guard !catalog.models.isEmpty else {
            let model = catalog.selection.map { selection in
                ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil, category: "model",
                    currentValue: selection.model, choices: [.init(value: selection.model, name: catalog.displayName, description: nil)])
            }
            let effort = catalog.effort.map { effort in
                ProviderCapabilitySelector(id: "reasoningEffort", name: L10n.string("Reasoning effort"), description: nil,
                    category: "thought_level", currentValue: effort,
                    choices: [.init(value: effort, name: CodexReasoningLabel.name(effort), description: nil)])
            }
            return ComposerModelMenu(model: model, effort: effort, speed: nil, canChoose: false)
        }
        return ComposerModelMenu(model: CodexModelMenuProjection.model(catalog),
                                 effort: CodexModelMenuProjection.reasoning(catalog),
                                 speed: CodexModelMenuProjection.speed(catalog), canChoose: true)
    }
}
