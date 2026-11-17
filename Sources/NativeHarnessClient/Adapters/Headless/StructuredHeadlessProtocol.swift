import Foundation

enum StructuredHeadlessFlavor: Equatable, Sendable {
    case cursor

    init?(harness: HarnessKind) {
        switch harness {
        case .cursorAgent: self = .cursor
        default: return nil
        }
    }

    func arguments(
        prompt: String,
        providerSessionID: String,
        options: StructuredHeadlessSessionOptions = .init()
    ) -> [String] {
        // The prompt is one argument among the CLI's options. One that began with "-" would be read as an
        // option, so it goes behind a line break, which changes nothing in what it asks.
        let prompt = prompt.hasPrefix("-") ? "\n" + prompt : prompt
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
        }
    }
}

struct StructuredHeadlessSessionOptions: Equatable, Sendable {
    var model: String?
    /// Cursor's `--mode`.
    var mode: String?
    var reviewPolicy: String?
    var sandbox: String?
}

/// The option names Cursor's and Antigravity's tasks keep their choices under (Antigravity's over ACP,
/// `AntigravityACPOptions`).
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
}
