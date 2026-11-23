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
        case "thinking":
            let subtype = value["subtype"]?.stringValue
            if subtype == "completed" {
                let text = value["text"]?.stringValue ?? value["thinking"]?.stringValue ?? ""
                return StructuredHeadlessProjection(
                    providerSessionID: sessionID,
                    payloads: text.isEmpty ? [] : [.reasoningCompleted(text)],
                    isTerminal: false
                )
            }
            let delta = value["text"]?.stringValue
                ?? value["delta"]?.stringValue
                ?? value["thinking"]?.stringValue
                ?? ""
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: delta.isEmpty ? [] : [.reasoningDelta(delta)],
                isTerminal: false
            )
        case "assistant":
            var payloads: [HarnessEventPayload] = []
            let thinking = thinkingContent(in: value["message"]?["content"])
            if !thinking.isEmpty { payloads.append(.reasoningDelta(thinking)) }
            let text = textContent(in: value["message"]?["content"])
            if !text.isEmpty { payloads.append(.assistantDelta(text)) }
            return StructuredHeadlessProjection(
                providerSessionID: sessionID,
                payloads: payloads,
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
            if let usage = usage(from: value) {
                payloads.append(.usageUpdated(usage))
            }
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

    private func thinkingContent(in value: JSONValue?) -> String {
        value?.arrayValue?.compactMap { block in
            guard block["type"]?.stringValue == "thinking" else { return nil }
            return block["thinking"]?.stringValue ?? block["text"]?.stringValue
        }.joined() ?? ""
    }

    private func usage(from value: JSONValue) -> HarnessProtocolUsage? {
        let usage = value["usage"]
        let inputTokens = unsigned(
            usage?["inputTokens"] ?? usage?["input_tokens"] ?? usage?["input"]
        )
        let cachedInputTokens = unsigned(
            usage?["cacheReadTokens"] ?? usage?["cache_read_tokens"]
                ?? usage?["cache_read_input_tokens"] ?? usage?["cacheReadInputTokens"]
                ?? usage?["cachedInputTokens"] ?? usage?["cached_input_tokens"]
        )
        let outputTokens = unsigned(
            usage?["outputTokens"] ?? usage?["output_tokens"] ?? usage?["output"]
        )
        let reasoningTokens = unsigned(
            usage?["reasoningTokens"] ?? usage?["reasoning_tokens"]
                ?? usage?["thinkingTokens"] ?? usage?["thinking_tokens"]
        )
        let totalCostUSD = (
            value["total_cost_usd"] ?? value["totalCostUSD"] ?? value["totalCostUsd"]
                ?? value["cost_usd"] ?? value["costUsd"] ?? usage?["cost"]
        )?.doubleValue
        let contextWindowTokens = unsigned(
            usage?["contextWindowTokens"] ?? usage?["contextWindow"] ?? usage?["context_window"]
        )
        let contextUsedTokens = unsigned(
            usage?["contextUsedTokens"] ?? usage?["contextUsed"] ?? usage?["context_used"]
        )
        guard inputTokens != nil || cachedInputTokens != nil || outputTokens != nil
                || reasoningTokens != nil || totalCostUSD != nil
                || contextWindowTokens != nil || contextUsedTokens != nil else { return nil }
        return HarnessProtocolUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalCostUSD: totalCostUSD,
            contextWindowTokens: contextWindowTokens,
            contextUsedTokens: contextUsedTokens,
            extensionValues: [:]
        )
    }

    private func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
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
