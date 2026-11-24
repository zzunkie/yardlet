import Foundation

/// Presentation-only bridge into the common model menu. Selection stays in Codex's typed
/// model/effort contract; these IDs never become another harness's session options.
enum CodexModelMenuProjection {
    static func model(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil,
            category: "model", currentValue: catalog.selection?.model ?? catalog.selectedModel?.model ?? "",
            choices: catalog.models.map {
                ProviderCapabilityChoice(value: $0.model, name: $0.displayName, description: nil)
            })
    }

    static func reasoning(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector? {
        guard let model = catalog.selectedModel, !model.supportedReasoningEfforts.isEmpty else { return nil }
        return ProviderCapabilitySelector(id: "reasoningEffort", name: L10n.string("Reasoning effort"),
            description: nil, category: "thought_level", currentValue: catalog.effort ?? "",
            choices: model.supportedReasoningEfforts.map {
                ProviderCapabilityChoice(value: $0, name: CodexReasoningLabel.name($0), description: nil)
            })
    }

    /// The model's speed tiers as the shared menu's speed row, named and described as Codex names them.
    /// A model with one tier uses an Off/On toggle (the same shape as Claude Code's Fast switch); a model
    /// with multiple tiers (such as Fast and Ultrafast) offers Default and every advertised tier by its ID.
    static func speed(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector? {
        let tiers = catalog.availableServiceTiers
        guard !tiers.isEmpty else { return nil }
        if tiers.count == 1, let tier = tiers.first {
            return ProviderCapabilitySelector(
                id: "fastMode", name: tier.name,
                description: tier.description.isEmpty ? nil : tier.description, category: "speed",
                currentValue: catalog.serviceTier == tier.id ? "on" : "off",
                choices: [.init(value: "off", name: L10n.string("Off"), description: nil),
                          .init(value: "on", name: L10n.string("On"), description: nil)])
        }
        let current = catalog.activeServiceTier?.id ?? "default"
        let choices = [ProviderCapabilityChoice(value: "default", name: L10n.string("Default"), description: nil)]
            + tiers.map { tier in
                ProviderCapabilityChoice(
                    value: tier.id, name: tier.name,
                    description: tier.description.isEmpty ? nil : tier.description)
            }
        return ProviderCapabilitySelector(
            id: "serviceTier", name: L10n.string("Speed"), description: nil, category: "speed",
            currentValue: current, choices: choices)
    }

    static func selection(id: String, value: String, catalog: CodexModelCatalog) -> CodexModelSelection? {
        switch id {
        case "fastMode":
            if value == "off" || value == "default" {
                return catalog.selectingServiceTier("default")
            }
            if value == "on" {
                guard let tier = catalog.fastTier ?? catalog.availableServiceTiers.first else { return nil }
                return catalog.selectingServiceTier(tier.id)
            }
            return catalog.selectingServiceTier(value)
        case "serviceTier":
            return catalog.selectingServiceTier(value)
        case "model":
            guard let model = catalog.models.first(where: { $0.model == value }) else { return nil }
            return catalog.selecting(model)
        case "reasoningEffort":
            guard let model = catalog.selectedModel, model.supportedReasoningEfforts.contains(value) else { return nil }
            return CodexModelSelection(model: model.model, reasoningEffort: value, serviceTier: catalog.selection?.serviceTier)
        default: return nil
        }
    }
}
