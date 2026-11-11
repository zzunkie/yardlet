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
/// - `permissionMode` is the one menu for approvals (`AntigravityPermissionMode.askingSelector`). The
///   CLI's own session modes (`mode`, from 1.5: `default`, `accept-edits`, and `auto` where the
///   account has it) are its choices and set the session's `mode`. Bypass permissions runs the
///   session on the CLI's own `agy acp --dangerously-skip-permissions` ("auto-approve all tool
///   permission requests", `ACPProcessLane`), and Plan has Yardlet answer no, as print mode refused
///   what it could not ask about; both keep the session on `default`. The menu shows the mode the
///   session reports, so a task that attaches sends its saved mode only when the session is on
///   another.
/// - Print mode's agent, sandbox and review choices have no counterpart and are left alone.
///
/// The models are the ones `agy acp` offers this client; Yardlet names itself and shows what it
/// is given.
enum AntigravityACPOptions {
    static let effortConfigID = "thought_level"
    static let sessionModeConfigID = "mode"

    /// One config option to set in the session.
    struct ConfigValue: Equatable, Sendable {
        let id: String
        let value: String
    }

    /// What a saved or chosen option becomes in the ACP session.
    enum Step: Equatable, Sendable {
        /// Set these config options, in order.
        case send([ConfigValue])
        /// Yardlet's permission mode, and the session mode to set for it (nil: the session is on it,
        /// or lists no modes).
        case permission(String, sessionMode: String?)
        /// Nothing to change.
        case none
    }

    /// `id` and `value` as the session takes them, against what it offers (`selectors`, in ACP's
    /// own names) and the models it listed (`models`, `models.availableModels`).
    static func step(id: String, value: String, selectors: [ProviderCapabilitySelector],
                     models: [ProviderCapabilityChoice]) throws -> Step {
        switch id {
        case AntigravityPermissionMode.optionID, StructuredHeadlessOptionID.executionMode:
            // A mode the session does not list (Auto kept from another account, say) asks, as Default.
            let wanted = AntigravityPermissionMode.sessionMode(for: value)
            let mode = offers(sessionModeConfigID, wanted, in: selectors) ? wanted : AntigravityPermissionMode.standard
            guard selectors.first(where: { $0.id == sessionModeConfigID })?.currentValue != mode,
                  offers(sessionModeConfigID, mode, in: selectors) else {
                return .permission(value, sessionMode: nil)
            }
            return .permission(value, sessionMode: mode)
        case StructuredHeadlessOptionID.agent, StructuredHeadlessOptionID.sandbox, StructuredHeadlessOptionID.reviewPolicy,
             sessionModeConfigID:
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

    /// The session's controls under Yardlet's names, with the permission mode: Bypass permissions or
    /// Plan when the task has it, otherwise the session's own mode. A session on the CLI's own `plan`,
    /// which the menu does not offer, shows Default.
    static func project(_ state: ProviderCapabilityState, permissionMode: String?) -> ProviderCapabilityState {
        var state = state
        let modes = state.selectors.first { $0.id == sessionModeConfigID }
        let current = permissionMode == AntigravityPermissionMode.bypass || permissionMode == AntigravityPermissionMode.plan
            ? permissionMode
            : modes?.currentValue == AntigravityPermissionMode.plan ? AntigravityPermissionMode.standard : modes?.currentValue
        state.selectors = state.selectors.map { selector in
            guard selector.id == effortConfigID else { return selector }
            return ProviderCapabilitySelector(
                id: StructuredHeadlessOptionID.reasoningEffort, name: selector.name, description: selector.description,
                category: selector.category, currentValue: selector.currentValue, choices: selector.choices)
        }
        state.selectors.removeAll { [AntigravityPermissionMode.optionID, sessionModeConfigID].contains($0.id) }
        state.selectors.append(AntigravityPermissionMode.askingSelector(current: current, offered: modes?.choices ?? []))
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
