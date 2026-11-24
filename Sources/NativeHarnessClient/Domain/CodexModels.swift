import Foundation

struct CodexServiceTier: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
}

struct CodexModelOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [String]
    let isDefault: Bool
    var serviceTiers: [CodexServiceTier]? = nil
    var defaultServiceTier: String? = nil
}

struct CodexModelSelection: Codable, Equatable, Sendable {
    let model: String
    let reasoningEffort: String?
    var serviceTier: String? = nil

    static let storageKey = "codex.modelSelection"

    var storedValue: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func restored(from options: [String: String]) -> Self? {
        guard let data = options[storageKey]?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct CodexModelCatalog: Codable, Equatable, Sendable {
    var models: [CodexModelOption] = []
    var selection: CodexModelSelection?

    var selectedModel: CodexModelOption? {
        models.first { $0.model == selection?.model }
    }

    var displayName: String {
        selectedModel?.displayName ?? selection?.model ?? L10n.string("Model")
    }

    var effort: String? { selection?.reasoningEffort ?? selectedModel?.defaultReasoningEffort }
    var serviceTier: String? { selection?.serviceTier ?? selectedModel?.defaultServiceTier }
    /// Every non-default speed tier the selected model advertises, in the catalog's order.
    var availableServiceTiers: [CodexServiceTier] {
        var seen = Set<String>()
        return (selectedModel?.serviceTiers ?? []).filter { tier in
            !tier.id.isEmpty && tier.id != "default" && seen.insert(tier.id).inserted
        }
    }
    /// The non-default speed tier currently selected, or nil when running at standard speed.
    var activeServiceTier: CodexServiceTier? {
        guard let serviceTier, serviceTier != "default" else { return nil }
        return availableServiceTiers.first { $0.id == serviceTier }
    }
    var fastTier: CodexServiceTier? {
        availableServiceTiers.first { $0.id == "priority" || $0.id == "fast" }
    }
    var isFast: Bool {
        guard let fastTier else { return false }
        return serviceTier == fastTier.id
    }

    func selectingServiceTier(_ tier: String) -> CodexModelSelection? {
        guard var selection, tier == "default" || selectedModel?.serviceTiers?.contains(where: { $0.id == tier }) == true else { return nil }
        selection.serviceTier = tier
        return selection
    }

    func selecting(_ model: CodexModelOption) -> CodexModelSelection {
        CodexModelSelection(
            model: model.model,
            reasoningEffort: effort.flatMap { model.supportedReasoningEfforts.contains($0) ? $0 : nil }
                ?? model.defaultReasoningEffort,
            serviceTier: serviceTier.flatMap { tier in
                tier == "default" || model.serviceTiers?.contains(where: { $0.id == tier }) == true ? tier : "default"
            }
        )
    }
}

enum CodexReasoningLabel {
    static func name(_ effort: String) -> String {
        switch effort {
        case "none": L10n.string("None")
        case "minimal": L10n.string("Minimal")
        case "low": L10n.string("Low")
        case "medium": L10n.string("Medium")
        case "high": L10n.string("High")
        case "xhigh": L10n.string("Extra high")
        case "max": L10n.string("Max")
        case "ultra": L10n.string("Ultra")
        default: effort
        }
    }
}

struct HarnessProtocolCodexModelSetParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let selection: CodexModelSelection
}
