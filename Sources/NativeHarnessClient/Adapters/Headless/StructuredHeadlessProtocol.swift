import Foundation

enum StructuredHeadlessFlavor: Equatable, Sendable {
    case cursor
    case antigravity

    init?(harness: HarnessKind) {
        switch harness {
        case .cursorAgent: self = .cursor
        case .antigravityCLI: self = .antigravity
        default: return nil
        }
    }

    func arguments(
        prompt: String,
        providerSessionID: String,
        isFirstTurn: Bool,
        options: StructuredHeadlessSessionOptions = .init(),
        catalog: AntigravityModelCatalog? = nil
    ) -> [String] {
        switch self {
        case .cursor:
            var arguments = [
                "--print",
                "--output-format", "stream-json",
                "--stream-partial-output",
                "--resume=\(providerSessionID)"
            ]
            if let model = options.model { arguments += ["--model", model] }
            if let mode = options.mode { arguments += ["--mode", mode] }
            if options.reviewPolicy == "auto-review" { arguments.append("--auto-review") }
            if let sandbox = options.sandbox { arguments += ["--sandbox", sandbox] }
            arguments.append(prompt)
            return arguments
        case .antigravity:
            var arguments = [
                "--print", prompt,
                "--output-format", "stream-json"
            ]
            // The CLI refuses `--effort` beside a model whose name already carries one, or one
            // that takes none, so the effort travels as the model's own variant where it can.
            let launch = AntigravityModelCatalog.launchModel(
                model: options.model, effort: options.reasoningEffort, catalog: catalog)
            if let model = launch.model { arguments += ["--model", model] }
            if let effort = launch.effort { arguments += ["--effort", effort] }
            if let agent = options.agent { arguments += ["--agent", agent] }
            arguments += AntigravityPermissionMode.launchArguments(options.mode)
            if options.sandbox == "enabled" { arguments.append("--sandbox") }
            if !isFirstTurn {
                arguments.append("--conversation=\(providerSessionID)")
            }
            return arguments
        }
    }
}

struct StructuredHeadlessSessionOptions: Equatable, Sendable {
    var model: String?
    /// Cursor's `--mode`; Antigravity's permission mode (`AntigravityPermissionMode`).
    var mode: String?
    var reasoningEffort: String?
    var agent: String?
    var reviewPolicy: String?
    var sandbox: String?
}

enum StructuredHeadlessOptionID {
    static let model = "model"
    static let executionMode = "executionMode"
    static let reasoningEffort = "reasoningEffort"
    static let agent = "agent"
    static let reviewPolicy = "reviewPolicy"
    static let sandbox = "sandbox"
    /// Antigravity's permission mode. Tasks saved before it kept the same values under
    /// `executionMode`, which is still read.
    static let permissionMode = AntigravityPermissionMode.optionID
}

/// How Antigravity CLI runs tools when Yardlet starts it. A headless run cannot ask: an action that
/// needs approval under the account's own permission setting is refused and listed in the result's
/// `denied_actions`. The modes are the CLI's `--mode` values and, after the person confirms, its
/// `--dangerously-skip-permissions` (the counterpart of Claude Code's Bypass permissions).
enum AntigravityPermissionMode {
    static let optionID = "permissionMode"
    static let standard = "default"
    static let acceptEdits = "accept-edits"
    static let plan = "plan"
    /// Offered only where the CLI says this account has it.
    static let auto = "auto"
    static let bypass = "bypass"

    static func values(includesAuto: Bool) -> [String] {
        includesAuto ? [standard, acceptEdits, auto, plan, bypass] : [standard, acceptEdits, plan, bypass]
    }

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

    static func launchArguments(_ value: String?) -> [String] {
        switch value {
        case bypass: ["--dangerously-skip-permissions"]
        case acceptEdits, plan, auto: ["--mode", value ?? standard]
        default: []
        }
    }

    static func selector(current: String?, includesAuto: Bool) -> ProviderCapabilitySelector {
        let values = values(includesAuto: includesAuto || current == auto)
        return ProviderCapabilitySelector(
            id: optionID,
            name: L10n.string("Permission mode"),
            description: L10n.string("Antigravity CLI cannot ask for approval when Yardlet runs it, so actions that need approval are not run unless the mode allows them."),
            category: "mode",
            currentValue: current.flatMap { values.contains($0) ? $0 : nil } ?? standard,
            choices: values.compactMap { value in
                displayName(value).map { ProviderCapabilityChoice(value: value, name: $0, description: nil) }
            })
    }

    /// Over ACP (`agy acp`) the agent asks before what needs approval, and has no modes of its own:
    /// Default shows each request, Bypass permissions answers yes to all of them, and Plan, kept by
    /// read-only runs and by tasks from print mode, answers no. Accept edits and Auto have no
    /// counterpart there, so a task that kept one asks.
    static func askingValue(_ saved: String?) -> String {
        switch saved {
        case bypass: bypass
        case plan: plan
        default: standard
        }
    }

    /// The modes over ACP: Default and Bypass permissions, and Plan for a task that has it.
    static func askingSelector(current: String?) -> ProviderCapabilitySelector {
        let current = askingValue(current)
        let values = current == plan ? [standard, plan, bypass] : [standard, bypass]
        return ProviderCapabilitySelector(
            id: optionID,
            name: L10n.string("Permission mode"),
            description: L10n.string("Antigravity asks before actions that need approval. Bypass permissions approves every request without asking."),
            category: "mode",
            currentValue: current,
            choices: values.compactMap { value in
                displayName(value).map { ProviderCapabilityChoice(value: value, name: $0, description: nil) }
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

/// Antigravity CLI's model list (`agy models`), with the variants that only differ in reasoning
/// effort (`gemini-3.8-flash-high`, `-medium`, `-low`) folded into one model whose efforts are
/// those variants. Models that take no effort keep their own entry.
struct AntigravityModelCatalog: Equatable, Sendable {
    struct Effort: Equatable, Sendable {
        let value: String
        /// The variant's own model ID, which `--model` takes.
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

    /// What one invocation passes. Without a list (it could not be read), the saved values go as
    /// they are, as before the list was folded.
    static func launchModel(model: String?, effort: String?,
                            catalog: AntigravityModelCatalog?) -> (model: String?, effort: String?) {
        guard let model else { return (nil, effort) }
        guard let catalog, let entry = catalog.model(for: model) else { return (model, effort) }
        if entry.efforts.contains(where: { $0.modelID == model }) { return (model, nil) }
        guard !entry.efforts.isEmpty else { return (entry.id, nil) }
        if let effort, let variant = entry.efforts.first(where: { $0.value == effort }) {
            return (variant.modelID, nil)
        }
        return (entry.id, nil)
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

struct StructuredHeadlessProjection: Equatable, Sendable {
    let providerSessionID: String?
    let payloads: [HarnessEventPayload]
    let isTerminal: Bool
}

struct StructuredHeadlessEventProjector: Sendable {
    let flavor: StructuredHeadlessFlavor

    func project(_ value: JSONValue, hasAssistantText: Bool) -> StructuredHeadlessProjection {
        switch flavor {
        case .cursor:
            projectCursor(value, hasAssistantText: hasAssistantText)
        case .antigravity:
            projectAntigravity(value, hasAssistantText: hasAssistantText)
        }
    }

    private func projectCursor(
        _ value: JSONValue,
        hasAssistantText: Bool
    ) -> StructuredHeadlessProjection {
        let sessionID = value["session_id"]?.stringValue
        switch value["type"]?.stringValue {
        case "system" where value["subtype"]?.stringValue == "init":
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        case "assistant":
            let text = textContent(in: value["message"]?["content"])
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: text.isEmpty ? [] : [.assistantDelta(text)],
                isTerminal: false
            )
        case "tool_call":
            let callID = value["call_id"]?.stringValue ?? UUID().uuidString
            let toolObject = value["tool_call"]?.objectValue ?? [:]
            let name = toolObject.keys.sorted().first ?? L10n.string("Agent activity")
            let body = toolObject[name]
            let activity = HarnessActivity(
                id: callID,
                kind: name,
                title: humanize(name),
                detail: compactJSON(value["tool_call"]),
                input: body?["args"]?.readableText,
                // The card keeps the provider's whole result; only the legacy single-slot
                // detail stays truncated.
                output: body?["result"]?.readableText ?? value["tool_call"]?.readableText
            )
            let payload: HarnessEventPayload = value["subtype"]?.stringValue == "completed"
                ? .activityCompleted(activity)
                : .activityStarted(activity)
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [payload],
                isTerminal: false
            )
        case "result":
            var payloads: [HarnessEventPayload] = []
            let failed = value["is_error"]?.boolValue == true
            if failed {
                payloads.append(.error(
                    message: value["result"]?.stringValue ?? L10n.string("Agent reported an error"),
                    recoverable: true
                ))
            } else if !hasAssistantText, let result = value["result"]?.stringValue, !result.isEmpty {
                payloads.append(.assistantMessageCompleted(result))
            }
            if !failed { payloads.append(.turnCompleted) }
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: payloads,
                isTerminal: true
            )
        default:
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        }
    }

    private func projectAntigravity(
        _ value: JSONValue,
        hasAssistantText: Bool
    ) -> StructuredHeadlessProjection {
        if let event = value["event"]?.stringValue {
            return projectCurrentAntigravity(
                value,
                event: event,
                hasAssistantText: hasAssistantText
            )
        }
        return projectLegacyAntigravity(value, hasAssistantText: hasAssistantText)
    }

    private func projectCurrentAntigravity(
        _ value: JSONValue,
        event: String,
        hasAssistantText: Bool
    ) -> StructuredHeadlessProjection {
        let body = value[event]
        let sessionID = value["conversation_id"]?.stringValue
            ?? body?["conversation_id"]?.stringValue
        switch event {
        case "init":
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        case "step_update":
            guard let update = body else {
                return StructuredHeadlessProjection(
                    providerSessionID: sessionID,
                    payloads: [],
                    isTerminal: false
                )
            }
            if let toolInfo = update["tool_info"], toolInfo.objectValue != nil {
                return projectCurrentAntigravityActivity(
                    update,
                    detail: toolInfo,
                    sessionID: sessionID
                )
            }
            if let subagentInfo = update["subagent_info"], subagentInfo.objectValue != nil {
                return projectCurrentAntigravityActivity(
                    update,
                    detail: subagentInfo,
                    sessionID: sessionID
                )
            }
            let text = update["text_delta"]?.stringValue ?? ""
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: text.isEmpty ? [] : [.assistantDelta(text)],
                isTerminal: false
            )
        case "result":
            var payloads: [HarnessEventPayload] = []
            let status = body?["status"]?.stringValue?.uppercased()
            let resultText = body?["response"]?.stringValue
            if status != "SUCCESS" {
                payloads.append(.error(
                    message: body?["error"]?.stringValue
                        ?? resultText
                        ?? L10n.string("Agent reported an error"),
                    recoverable: true
                ))
            } else if !hasAssistantText, let resultText, !resultText.isEmpty {
                payloads.append(.assistantMessageCompleted(resultText))
            }
            // A turn that stopped at a refusal without a word (the CLI notes "no output produced" on
            // stderr) says what did not run and how to let it; an answer explains it otherwise, and
            // each refused call is already a failed row.
            if !hasAssistantText, (resultText ?? "").isEmpty,
               let denied = deniedActionsActivity(body?["denied_actions"], sessionID: sessionID) {
                payloads.append(.activityCompleted(denied))
            }
            if status == "SUCCESS" { payloads.append(.turnCompleted) }
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: payloads,
                isTerminal: true
            )
        default:
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        }
    }

    /// A command's own line where the call has one (`run_command`'s `CommandLine`), otherwise the
    /// arguments as JSON without the summary fields the CLI adds for its own display.
    static func antigravityToolInput(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let command = value["CommandLine"]?.stringValue, !command.isEmpty { return command }
        if case var .object(object) = value {
            object.removeValue(forKey: "toolAction")
            object.removeValue(forKey: "toolSummary")
            return JSONValue.object(object).readableText
        }
        return value.readableText
    }

    /// A headless run cannot ask, so the CLI refuses what needs approval and lists it in the
    /// result (`denied_actions: [{action, display_name}]`). The turn still ends normally; one
    /// failed row says what did not run and why.
    private func deniedActionsActivity(_ value: JSONValue?, sessionID: String?) -> HarnessActivity? {
        let names = (value?.arrayValue ?? []).compactMap { action -> String? in
            let name = (action["display_name"]?.stringValue ?? action["action"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }
        guard !names.isEmpty else { return nil }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return HarnessActivity(
            // Each turn's list is its own row.
            id: [sessionID, "denied-actions", UUID().uuidString].compactMap { $0 }.joined(separator: "-"),
            kind: "denied_actions",
            title: L10n.string("Not run without approval"),
            detail: unique.joined(separator: ", "),
            outcome: .failed,
            input: unique.joined(separator: "\n"),
            output: L10n.string("Antigravity CLI refused these without asking in this permission mode. To let it run commands, choose Bypass permissions.")
        )
    }

    private func projectCurrentAntigravityActivity(
        _ update: JSONValue,
        detail: JSONValue,
        sessionID: String?
    ) -> StructuredHeadlessProjection {
        let name = update["tool_name"]?.stringValue
            ?? detail["name"]?.stringValue
            ?? update["step_type"]?.stringValue
            ?? L10n.string("Agent activity")
        let stepIndex = update["step_index"]?.integerValue.map { String($0) }
        let activityID = [sessionID, stepIndex].compactMap { $0 }.joined(separator: "-")
        let errorMessage = structuredToolErrorMessage(in: detail)
        let state = update["state"]?.stringValue?.uppercased()
        let failed = errorMessage != nil || state == "ERROR" || state == "FAILED"
        let stopped = !failed && (state == "CANCELED" || state == "CANCELLED")
        // Current runs name the call's arguments `parameters` and its result `output`; earlier ones
        // used `args`/`input` and `result`.
        let input = detail["parameters"] ?? detail["args"] ?? detail["input"]
        let output = detail["output"] ?? detail["result"]
        let activity = HarnessActivity(
            id: activityID.isEmpty ? UUID().uuidString : activityID,
            kind: name,
            title: humanize(name),
            detail: errorMessage ?? compactJSON(detail),
            outcome: failed ? .failed : stopped ? .stopped : nil,
            input: Self.antigravityToolInput(input),
            output: errorMessage ?? output?.readableText ?? (input == nil ? detail.readableText : nil)
        )
        let completed = state == "DONE" || failed || stopped
        return StructuredHeadlessProjection(
            providerSessionID: sessionID,
            payloads: [completed ? .activityCompleted(activity) : .activityStarted(activity)],
            isTerminal: false
        )
    }

    private func projectLegacyAntigravity(
        _ value: JSONValue,
        hasAssistantText: Bool
    ) -> StructuredHeadlessProjection {
        let sessionID = value["conversation_id"]?.stringValue
            ?? value["session_id"]?.stringValue
        switch value["type"]?.stringValue {
        case "init":
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        case "step_update":
            if let toolInfo = value["tool_info"], toolInfo.objectValue != nil {
                let name = toolInfo["name"]?.stringValue
                    ?? toolInfo["tool_name"]?.stringValue
                    ?? value["step_type"]?.stringValue
                    ?? L10n.string("Agent activity")
                let errorMessage = structuredToolErrorMessage(in: toolInfo)
                let activity = HarnessActivity(
                    id: value["step_id"]?.stringValue ?? UUID().uuidString,
                    kind: name,
                    title: humanize(name),
                    detail: errorMessage ?? compactJSON(toolInfo),
                    outcome: errorMessage == nil ? nil : .failed,
                    input: toolInfo["args"]?.readableText ?? toolInfo["input"]?.readableText,
                    output: errorMessage
                        ?? toolInfo["result"]?.readableText
                        ?? toolInfo.readableText
                )
                let completed = ["completed", "complete", "tool_result"]
                    .contains(value["status"]?.stringValue ?? value["step_type"]?.stringValue ?? "")
                    || errorMessage != nil
                return StructuredHeadlessProjection(
                    providerSessionID: sessionID,
                    payloads: [completed ? .activityCompleted(activity) : .activityStarted(activity)],
                    isTerminal: false
                )
            }
            let text = value["delta"]?.stringValue
                ?? value["text"]?.stringValue
                ?? value["content"]?.stringValue
                ?? ""
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: text.isEmpty ? [] : [.assistantDelta(text)],
                isTerminal: false
            )
        case "result":
            var payloads: [HarnessEventPayload] = []
            let failed = value["is_error"]?.boolValue == true
                || value["status"]?.stringValue == "error"
            let resultText = value["result"]?.stringValue
                ?? value["output"]?.stringValue
                ?? value["text"]?.stringValue
            if failed {
                payloads.append(.error(
                    message: resultText ?? value["error"]?.stringValue
                        ?? L10n.string("Agent reported an error"),
                    recoverable: true
                ))
            } else if !hasAssistantText, let resultText, !resultText.isEmpty {
                payloads.append(.assistantMessageCompleted(resultText))
            }
            if !failed { payloads.append(.turnCompleted) }
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: payloads,
                isTerminal: true
            )
        default:
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: [],
                isTerminal: false
            )
        }
    }

    private func textContent(in value: JSONValue?) -> String {
        if let text = value?.stringValue { return text }
        return value?.arrayValue?.compactMap { block in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined() ?? ""
    }

    private func humanize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "ToolCall", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactJSON(_ value: JSONValue?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 360 ? String(text.prefix(360)) + "…" : text
    }

    /// Prefer the provider's structured tool error over truncated `tool_info` JSON so a large
    /// parameter blob cannot hide the failure that actually stopped the tool.
    private func structuredToolErrorMessage(in detail: JSONValue) -> String? {
        guard let error = detail["error"] else { return nil }
        switch error {
        case .null, .bool(false):
            return nil
        case let .string(message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .object(object):
            if object.isEmpty { return nil }
            if let message = error["message"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
            return compactJSON(error)
        case let .array(array):
            return array.isEmpty ? nil : compactJSON(error)
        default:
            return compactJSON(error)
        }
    }
}
