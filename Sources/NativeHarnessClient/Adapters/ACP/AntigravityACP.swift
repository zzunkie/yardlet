import Foundation

/// Yardlet runs Antigravity CLI's turns only over the Agent Client Protocol (`agy acp`), which the CLI
/// serves from 1.4.11. An earlier version starts no conversation and the person is asked to update it;
/// a version that could not be read runs over ACP, whose own error shows if the CLI cannot serve it.
/// The version is the one the runtime reported, read again only when its file changes
/// (`RuntimeVersionCache`).
enum AntigravityTransport {
    static let acpMinimum = "1.4.11"

    /// Whether `version` is known to come before `acpMinimum`; one that could not be read or parsed is not.
    static func isTooOld(_ version: String?) -> Bool {
        guard let version, let parsed = HarnessRuntimeVersion(version),
              let minimum = HarnessRuntimeVersion(acpMinimum) else { return false }
        return !parsed.isAtLeast(minimum)
    }

    /// What a task on a version before `acpMinimum` is told instead of starting.
    static func updateMessage(version: String) -> String {
        L10n.format("Antigravity CLI %1$@ is older than Yardlet supports. Update it to %2$@ or later in Settings › CLI Updates or with agy update.",
                    version, acpMinimum)
    }
}

/// Antigravity over ACP in the option names Yardlet's menus use, which are also the ones the print mode
/// Yardlet once ran it in saved, so a task keeps its model, effort and permission mode:
///
/// - `model` is the model as `agy acp` names it in `configOptions` (`gemini-3.8-flash`); a variant a
///   task saved (`gemini-3.8-flash-low`) is that model with that effort.
/// - `reasoningEffort` is `agy acp`'s `thought_level`.
/// - `permissionMode` is the one menu for approvals (`AntigravityPermissionMode.askingSelector`). The
///   CLI's own session modes (`mode`, from 1.5: `default`, `accept-edits`, and `auto` where the
///   account has it) are its choices and set the session's `mode`. Bypass permissions runs the
///   session on the CLI's own `agy acp --dangerously-skip-permissions` ("auto-approve all tool
///   permission requests", `ACPProcessLane`), and Plan has Yardlet answer no; both keep the session
///   on `default`. The menu shows the mode the
///   session reports, so a task that attaches sends its saved mode only when the session is on
///   another.
/// - The agent, sandbox and review choices print mode saved have no counterpart and are left alone.
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

    /// The models the session listed, folded into models and their efforts as `agy models` is
    /// (`AntigravityModelCatalog`).
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

    /// The local stand-in print mode saved for a task until its first turn named the conversation.
    static func isPrintModePlaceholder(_ providerSessionID: String, localSessionID: UUID) -> Bool {
        providerSessionID == localSessionID.uuidString.lowercased()
    }

    private static func offers(_ id: String, _ value: String, in selectors: [ProviderCapabilitySelector]) -> Bool {
        selectors.first { $0.id == id }?.choices.contains { $0.value == value } == true
    }
}

/// Antigravity CLI's permission modes as Yardlet's menus name them: Default, the CLI's own session modes
/// (Accept edits, and Auto where the account has it), Plan (read-only, Yardlet answers no) and, after the
/// person confirms, Bypass permissions, the counterpart of Claude Code's (`agy acp
/// --dangerously-skip-permissions`).
enum AntigravityPermissionMode {
    static let optionID = "permissionMode"
    static let standard = "default"
    static let acceptEdits = "accept-edits"
    static let plan = "plan"
    /// Offered only where the CLI says this account has it.
    static let auto = "auto"
    static let bypass = "bypass"

    static func displayName(_ value: String) -> String? {
        switch value {
        case standard: L10n.string("Default")
        case acceptEdits: L10n.string("Accept edits")
        case plan: L10n.string("Plan")
        case auto: L10n.string("Auto")
        case bypass: L10n.string("Bypass permissions")
        default: nil
        }
    }

    static func isElevated(_ value: String?) -> Bool { value == bypass }

    /// Over ACP (`agy acp`) the agent asks before what needs approval, and its session mode (`mode`)
    /// decides what it approves without asking: Default asks for each step the person's settings do
    /// not allow, and Accept edits and Auto, where the CLI offers them, approve some steps themselves.
    /// Bypass permissions runs on a process that approves for itself (`ACPProcessLane`), and Plan,
    /// kept by read-only runs and by tasks print mode saved, has Yardlet answer no; both keep the
    /// session on `default`. This is the session mode `permission` runs on.
    static func sessionMode(for permission: String) -> String {
        permission == bypass || permission == plan ? standard : permission
    }

    /// The modes over ACP: Default, the other modes the session lists (`offered`, its `mode` choices;
    /// none before a session has listed them), Plan for a task that has it, and Bypass permissions.
    /// A mode the CLI does not offer this account never shows, though a task's own mode stays in the
    /// menu until its session lists the modes. The CLI's `plan` ("Plan carefully before executing a
    /// task") is a way of working rather than of approving, and is left out: Plan here is the
    /// read-only one.
    static func askingSelector(current: String?, offered: [ProviderCapabilityChoice]) -> ProviderCapabilitySelector {
        var values = [standard]
        for choice in offered where ![standard, plan, bypass].contains(choice.value) && !values.contains(choice.value) {
            values.append(choice.value)
        }
        if let current, current != bypass, !values.contains(current), displayName(current) != nil {
            values.append(current)
        }
        values.append(bypass)
        return ProviderCapabilitySelector(
            id: optionID,
            name: L10n.string("Permission mode"),
            description: L10n.string("Antigravity asks before actions that need approval. Bypass permissions approves every request without asking."),
            category: "mode",
            currentValue: current.flatMap { values.contains($0) ? $0 : nil } ?? standard,
            choices: values.map { value in
                ProviderCapabilityChoice(
                    value: value, name: displayName(value) ?? offered.first { $0.value == value }?.name ?? value,
                    description: nil)
            })
    }
}

/// The model menu of an Antigravity task that has not listed its models in this run: its own
/// saved choice, named by its ID until the list is read.
enum AntigravityDetachedSelectors {
    static func model(options: [String: String]) -> [ProviderCapabilitySelector] {
        let saved = options[StructuredHeadlessOptionID.model].flatMap { $0 == "default" ? nil : $0 }
        let defaultChoice = ProviderCapabilityChoice(value: "default", name: L10n.string("Default"), description: nil)
        var selectors = [ProviderCapabilitySelector(
            id: StructuredHeadlessOptionID.model, name: L10n.string("Model"), description: nil, category: "model",
            currentValue: saved ?? "default",
            choices: [defaultChoice] + (saved.map { [ProviderCapabilityChoice(value: $0, name: $0, description: nil)] } ?? []))]
        if saved != nil, let effort = options[StructuredHeadlessOptionID.reasoningEffort], effort != "default" {
            selectors.append(ProviderCapabilitySelector(
                id: StructuredHeadlessOptionID.reasoningEffort, name: L10n.string("Reasoning effort"), description: nil,
                category: "thought_level", currentValue: effort,
                choices: [defaultChoice, ProviderCapabilityChoice(value: effort, name: effort, description: nil)]))
        }
        return selectors
    }
}

/// Antigravity CLI's model list (`agy models`, or the models a session lists), with the variants that only
/// differ in reasoning effort (`gemini-3.8-flash-high`, `-medium`, `-low`) folded into one model whose
/// efforts are those variants. Models that take no effort keep their own entry.
struct AntigravityModelCatalog: Equatable, Sendable {
    struct Effort: Equatable, Sendable {
        let value: String
        /// The variant's own model ID.
        let modelID: String
    }

    struct Model: Equatable, Sendable {
        let id: String
        let name: String
        let efforts: [Effort]
    }

    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    let models: [Model]

    init(models: [Model]) { self.models = models }

    init(choices: [ProviderCapabilityChoice]) {
        var groups: [String: [(effort: String, choice: ProviderCapabilityChoice)]] = [:]
        for choice in choices {
            guard let (base, effort) = Self.split(choice.value) else { continue }
            groups[base, default: []].append((effort, choice))
        }
        var models: [Model] = []
        var placed: Set<String> = []
        for choice in choices {
            let split = Self.split(choice.value)
            if let (base, _) = split, let variants = groups[base], variants.count > 1 {
                guard placed.insert(base).inserted else { continue }
                let efforts = variants.sorted {
                    (Self.effortLevels.firstIndex(of: $0.effort) ?? 0) < (Self.effortLevels.firstIndex(of: $1.effort) ?? 0)
                }.map { Effort(value: $0.effort, modelID: $0.choice.value) }
                models.append(Model(id: base, name: Self.baseName(choice.name, effort: variants.first { $0.choice == choice }?.effort),
                                    efforts: efforts))
            } else if groups[choice.value].map({ $0.count > 1 }) != true, placed.insert(choice.value).inserted {
                models.append(Model(id: choice.value, name: choice.name, efforts: []))
            }
        }
        self.models = models
    }

    /// The model a saved value names: a folded model by its own ID, or by one of its variants.
    func model(for value: String?) -> Model? {
        guard let value else { return nil }
        return models.first { $0.id == value } ?? models.first { $0.efforts.contains { $0.modelID == value } }
    }

    /// The effort a saved model value carries when it is one of a folded model's variants.
    func effort(carriedBy value: String?) -> String? {
        model(for: value)?.efforts.first { $0.modelID == value }?.value
    }

    private static func split(_ id: String) -> (base: String, effort: String)? {
        for level in effortLevels where id.hasSuffix("-\(level)") {
            let base = String(id.dropLast(level.count + 1))
            return base.isEmpty ? nil : (base, level)
        }
        return nil
    }

    /// "Gemini 3.8 Flash (High)" names the folded model "Gemini 3.8 Flash".
    private static func baseName(_ name: String, effort: String?) -> String {
        guard let effort, name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard inner.lowercased() == effort else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }
}
