import Foundation

/// Which way Yardlet runs Antigravity CLI. From 1.4.11 the CLI serves the Agent Client Protocol
/// (`agy acp`, which `agy help acp` documents though `agy --help` does not list it); an earlier
/// version keeps print mode, one `agy --print --output-format stream-json` per turn
/// (`StructuredHeadlessAdapter`). The version is the one the runtime reported, read again only
/// when its file changes (`RuntimeVersionCache`).
enum AntigravityTransport {
    static let acpMinimum = "1.4.11"

    static func servesACP(version: String?) -> Bool {
        guard let version, let parsed = HarnessRuntimeVersion(version),
              let minimum = HarnessRuntimeVersion(acpMinimum) else { return false }
        return parsed.isAtLeast(minimum)
    }
}

/// Antigravity over ACP in the option names its print mode and Yardlet's menus use, so a task keeps
/// its model, effort and permission mode whichever way its runtime runs:
///
/// - `model` is the model as `agy acp` names it in `configOptions` (`gemini-3.8-flash`); a variant a
///   task saved (`gemini-3.8-flash-low`) is that model with that effort.
/// - `reasoningEffort` is `agy acp`'s `thought_level`.
/// - `permissionMode` is how Yardlet answers the approvals the agent asks for
///   (`AntigravityPermissionMode.askingValue`). Bypass permissions answers yes, as the CLI's own
///   `--dangerously-skip-permissions` ("auto-approve all tool permission requests") would; Plan
///   answers no, as print mode refused what it could not ask about.
/// - Print mode's agent, sandbox and review choices have no counterpart and are left alone.
///
/// The models are the ones `agy acp` offers this client; Yardlet names itself and shows what it
/// is given.
enum AntigravityACPOptions {
    static let effortConfigID = "thought_level"

    /// One config option to set in the session.
    struct ConfigValue: Equatable, Sendable {
        let id: String
        let value: String
    }

    /// What a saved or chosen option becomes in the ACP session.
    enum Step: Equatable, Sendable {
        /// Set these config options, in order.
        case send([ConfigValue])
        /// Yardlet's own answer to approvals.
        case permission(String)
        /// Nothing to change.
        case none
    }

    /// `id` and `value` as the session takes them, against what it offers (`selectors`, in ACP's
    /// own names) and the models it listed (`models`, `models.availableModels`).
    static func step(id: String, value: String, selectors: [ProviderCapabilitySelector],
                     models: [ProviderCapabilityChoice]) throws -> Step {
        switch id {
        case AntigravityPermissionMode.optionID, StructuredHeadlessOptionID.executionMode:
            return .permission(AntigravityPermissionMode.askingValue(value))
        case StructuredHeadlessOptionID.agent, StructuredHeadlessOptionID.sandbox, StructuredHeadlessOptionID.reviewPolicy:
            return .none
        case StructuredHeadlessOptionID.reasoningEffort:
            guard value != "default", offers(effortConfigID, value, in: selectors) else { return .none }
            return .send([ConfigValue(id: effortConfigID, value: value)])
        case StructuredHeadlessOptionID.model:
            guard value != "default", !value.isEmpty else { return .none }
            if offers("model", value, in: selectors) { return .send([ConfigValue(id: "model", value: value)]) }
            let catalog = AntigravityModelCatalog(choices: models)
            if let entry = catalog.model(for: value), offers("model", entry.id, in: selectors) {
                var steps = [ConfigValue(id: "model", value: entry.id)]
                if let effort = catalog.effort(carriedBy: value) { steps.append(ConfigValue(id: effortConfigID, value: effort)) }
                return .send(steps)
            }
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("Antigravity CLI does not offer %@ to Yardlet", value))
        default:
            return .send([ConfigValue(id: id, value: value)])
        }
    }

    /// The session's controls under Yardlet's names, with the permission mode.
    static func project(_ state: ProviderCapabilityState, permissionMode: String?) -> ProviderCapabilityState {
        var state = state
        state.selectors = state.selectors.map { selector in
            guard selector.id == effortConfigID else { return selector }
            return ProviderCapabilitySelector(
                id: StructuredHeadlessOptionID.reasoningEffort, name: selector.name, description: selector.description,
                category: selector.category, currentValue: selector.currentValue, choices: selector.choices)
        }
        state.selectors.removeAll { $0.id == AntigravityPermissionMode.optionID }
        state.selectors.append(AntigravityPermissionMode.askingSelector(current: permissionMode))
        return state
    }

    /// The models the session listed, folded into models and their efforts as print mode folds
    /// `agy models`.
    static func catalog(from models: [ProviderCapabilityChoice]) -> [HarnessModelOption]? {
        guard !models.isEmpty else { return nil }
        return AntigravityModelCatalog(choices: models).models.map {
            HarnessModelOption(value: $0.id, name: $0.name, effortLevels: $0.efforts.map(\.value))
        }
    }

    /// `models.availableModels` of a `session/new` or `session/load` answer.
    static func availableModels(in result: JSONValue) -> [ProviderCapabilityChoice] {
        (result["models"]?["availableModels"]?.arrayValue ?? []).compactMap { model in
            guard let id = model["modelId"]?.stringValue else { return nil }
            return ProviderCapabilityChoice(value: id, name: model["name"]?.stringValue ?? id, description: nil)
        }
    }

    /// The local stand-in print mode saves for a task until its first turn names the conversation.
    static func isPrintModePlaceholder(_ providerSessionID: String, localSessionID: UUID) -> Bool {
        providerSessionID == localSessionID.uuidString.lowercased()
    }

    private static func offers(_ id: String, _ value: String, in selectors: [ProviderCapabilitySelector]) -> Bool {
        selectors.first { $0.id == id }?.choices.contains { $0.value == value } == true
    }
}
