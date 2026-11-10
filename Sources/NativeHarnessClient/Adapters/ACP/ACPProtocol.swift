import Foundation

struct ACPRawFrame: Sendable {
    let value: JSONValue
    let data: Data
}

struct ACPWireCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func decodeLine(_ data: Data) throws -> JSONValue {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D })
        return try decoder.decode(JSONValue.self, from: Data(trimmed))
    }
}

enum ACPProtocol {
    static func initialize(id: Int64) -> JSONValue {
        request(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false)
                    ]),
                    "terminal": .bool(false)
                ]),
                "clientInfo": .object([
                    "name": .string(YardletProduct.name),
                    "version": .string("0.1.0")
                ])
            ])
        )
    }

    /// `mcpServers` holds only the Yardlet MCP server (ACP stdio form) when the task has one; the
    /// agent's own configured servers stay the agent's. `meta` is the agent's own `_meta` session
    /// options (Grok's `rules` or Antigravity's `systemPrompt` for Yardlet instructions); nil leaves
    /// the field out.
    static func newSession(id: Int64, workspaceURL: URL, mcpServers: [JSONValue] = [],
                           meta: JSONValue? = nil) -> JSONValue {
        var params = sessionParams(workspaceURL: workspaceURL, mcpServers: mcpServers).objectValue ?? [:]
        if let meta { params["_meta"] = meta }
        return request(id: id, method: "session/new", params: .object(params))
    }

    static func loadSession(
        id: Int64,
        providerSessionID: String,
        workspaceURL: URL,
        mcpServers: [JSONValue] = [],
        meta: JSONValue? = nil
    ) -> JSONValue {
        var params = sessionParams(workspaceURL: workspaceURL, mcpServers: mcpServers).objectValue ?? [:]
        params["sessionId"] = .string(providerSessionID)
        if let meta { params["_meta"] = meta }
        return request(id: id, method: "session/load", params: .object(params))
    }

    /// Lets the agent's process drop a session it serves (`sessionCapabilities.close`). The
    /// conversation stays saved, and another process can load it.
    static func closeSession(id: Int64, providerSessionID: String) -> JSONValue {
        request(id: id, method: "session/close", params: .object(["sessionId": .string(providerSessionID)]))
    }

    /// The agent's saved sessions in `workspaceURL`, a page at a time from `cursor`
    /// (`sessionCapabilities.list`). The folder is its real path, as `getcwd` gives it to a CLI
    /// started there and as the CLI saves a session started in a terminal (`/private/tmp/…` for
    /// `/tmp/…`, links resolved), since the agent compares the two character for character.
    static func listSessions(id: Int64, workspaceURL: URL, cursor: String? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(CanonicalPath.resolve(cwd(workspaceURL)) ?? cwd(workspaceURL))]
        if let cursor { params["cursor"] = .string(cursor) }
        return request(id: id, method: "session/list", params: .object(params))
    }

    static func prompt(id: Int64, providerSessionID: String, text: String) -> JSONValue {
        prompt(id: id, providerSessionID: providerSessionID, text: text, images: [])
    }

    /// ACP prompts are a content-block array. Images are only appended for an agent that
    /// advertised `promptCapabilities.image`; the adapter, not this builder, enforces that.
    /// A prompt without images keeps its single text block, including when the text is empty.
    static func prompt(
        id: Int64,
        providerSessionID: String,
        text: String,
        images: [HarnessUserInput.EncodedImage]
    ) -> JSONValue {
        var blocks: [JSONValue] = []
        if images.isEmpty || !text.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(text)
            ]))
        }
        for image in images {
            blocks.append(.object([
                "type": .string("image"),
                "mimeType": .string(image.mimeType),
                "data": .string(image.base64Data)
            ]))
        }
        return request(
            id: id,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(providerSessionID),
                "prompt": .array(blocks)
            ])
        )
    }

    static func cancel(providerSessionID: String) -> JSONValue {
        notification(
            method: "session/cancel",
            params: .object(["sessionId": .string(providerSessionID)])
        )
    }

    static func permissionResponse(id: JSONValue, optionID: String?) -> JSONValue {
        let outcome: JSONValue
        if let optionID {
            outcome = .object([
                "outcome": .string("selected"),
                "optionId": .string(optionID)
            ])
        } else {
            outcome = .object(["outcome": .string("cancelled")])
        }
        return response(id: id, result: .object(["outcome": outcome]))
    }

    static func methodNotFound(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .integer(-32601),
                "message": .string("Method not supported by Yardlet")
            ])
        ])
    }

    /// A folder as ACP's `cwd`: its absolute path without a trailing slash, as a shell's `pwd` gives
    /// it. An agent can compare it with the folder it saved a session in character for character
    /// (OpenCode's `session/list` lists nothing for `/project/` when its sessions are in `/project`).
    static func cwd(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func sessionParams(workspaceURL: URL, mcpServers: [JSONValue]) -> JSONValue {
        .object([
            "cwd": .string(cwd(workspaceURL)),
            "mcpServers": .array(mcpServers)
        ])
    }

    /// ACP requires every agent to take stdio MCP servers; `mcpCapabilities` advertises only the
    /// optional HTTP and SSE transports. An agent that nonetheless answers `stdio: false`, or
    /// `mcpCapabilities: false`, is taken at its word.
    static func acceptsStdioMCPServers(initializeResult result: JSONValue) -> Bool {
        let capabilities = result["agentCapabilities"]?["mcpCapabilities"]
        if capabilities == .bool(false) { return false }
        return capabilities?["stdio"] != .bool(false)
    }

    static func request(id: Int64, method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params
        ])
    }

    private static func notification(method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
    }

    private static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
    }
}

struct ACPToolCallState: Sendable {
    enum Status: String, Sendable {
        case pending, inProgress = "in_progress", completed, failed
    }

    var activity: HarnessActivity
    let status: Status

    func payload(isStart: Bool) -> HarnessEventPayload {
        switch status {
        case .completed, .failed: .activityCompleted(activity)
        case .pending, .inProgress:
            isStart ? .activityStarted(activity) : .activityUpdated(activity)
        }
    }
}

struct ACPEventProjector: Sendable {
    func payloads(from update: JSONValue) -> [HarnessEventPayload] {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            guard update["content"]?["type"]?.stringValue == "text",
                  let text = update["content"]?["text"]?.stringValue else { return [] }
            return [.assistantDelta(text)]

        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue
                ?? update["content"]?.contentText else { return [] }
            return [.reasoningDelta(text)]

        case "tool_call", "tool_call_update":
            guard let state = toolCall(from: update) else { return [] }
            return [state.payload(isStart: update["sessionUpdate"]?.stringValue == "tool_call")]

        case "plan":
            let lines = update["entries"]?.arrayValue?.compactMap { entry -> String? in
                guard let content = entry["content"]?.stringValue else { return nil }
                let status = entry["status"]?.stringValue ?? "pending"
                return "[\(status)] \(content)"
            } ?? []
            return lines.isEmpty ? [] : [.planUpdated(lines.joined(separator: "\n"))]

        default:
            return []
        }
    }

    func toolCall(from update: JSONValue, previous: ACPToolCallState? = nil) -> ACPToolCallState? {
        guard var activity = activity(from: update, fallback: previous?.activity) else { return nil }
        // ACP updates are patches: an omitted status changes content, not lifecycle.
        // In particular, late background output must not reopen a completed tool.
        let status = update["status"]?.stringValue.flatMap(ACPToolCallState.Status.init(rawValue:))
            ?? previous?.status ?? .pending
        activity.outcome = status == .failed ? .failed : nil
        return ACPToolCallState(activity: activity, status: status)
    }

    func activity(from update: JSONValue, fallback: HarnessActivity? = nil) -> HarnessActivity? {
        guard let id = update["toolCallId"]?.stringValue ?? fallback?.id else { return nil }
        let title = update["title"]?.stringValue ?? fallback?.title ?? L10n.string("Tool call")
        let kind = update["kind"]?.stringValue ?? fallback?.kind ?? "other"
        let content = contentProjection(update["content"])
        return HarnessActivity(
            id: id,
            kind: kind,
            title: title,
            detail: detail(from: update) ?? fallback?.detail,
            input: inputText(from: update) ?? fallback?.input,
            output: content.output ?? fallback?.output,
            diff: content.diff ?? fallback?.diff
        )
    }

    /// ACP tool content is a list that mixes text, terminal output, and file changes. Yardlet
    /// keeps the file change as a diff and joins the readable blocks as the tool output.
    private func contentProjection(
        _ content: JSONValue?
    ) -> (output: String?, diff: HarnessActivityDiff?) {
        guard let items = content?.arrayValue else { return (nil, nil) }
        var chunks: [String] = []
        var diff: HarnessActivityDiff?
        for item in items {
            switch item["type"]?.stringValue {
            case "diff":
                guard let path = item["path"]?.stringValue else { continue }
                if diff == nil {
                    diff = HarnessActivityDiff(
                        path: path,
                        oldText: item["oldText"]?.stringValue,
                        newText: item["newText"]?.stringValue
                    )
                }
            default:
                // A terminal block only carries an identifier until the client hosts the
                // terminal, so it contributes nothing unless the provider inlined output.
                if let text = item["content"]?["text"]?.stringValue
                    ?? item["text"]?.stringValue
                    ?? item["output"]?.stringValue {
                    chunks.append(text)
                }
            }
        }
        let output = chunks.joined(separator: "\n")
        return (output.isEmpty ? nil : output, diff)
    }

    private func inputText(from update: JSONValue) -> String? {
        var sections: [String] = []
        if let rawInput = update["rawInput"] {
            let command = rawInput["command"]?.stringValue
            if case let .object(object) = rawInput, object.count > 1 || command == nil {
                if let command { sections.append(command) }
                if let rendered = rawInput.readableText { sections.append(rendered) }
            } else if let command {
                sections.append(command)
            } else if let rendered = rawInput.readableText {
                sections.append(rendered)
            }
        }
        let locations = update["locations"]?.arrayValue?.compactMap { location -> String? in
            guard let path = location["path"]?.stringValue else { return nil }
            guard let line = location["line"]?.doubleValue else { return path }
            return "\(path):\(Int(line))"
        } ?? []
        if !locations.isEmpty { sections.append(locations.joined(separator: "\n")) }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Grok publishes prompt usage on its `_x.ai/session/update` turn-completed extension.
    /// The same projector also accepts standard-looking `usage` / `_meta.usage` objects so
    /// future ACP providers can expose the canonical value without another UI-specific path.
    func usage(from value: JSONValue) -> HarnessProtocolUsage? {
        let usage = value["usage"] ?? value["_meta"]?["usage"] ?? value
        let inputTokens = unsigned(usage["inputTokens"] ?? usage["input_tokens"])
        let cachedInputTokens = unsigned(
            usage["cachedReadTokens"]
                ?? usage["cacheReadInputTokens"]
                ?? usage["cache_read_input_tokens"]
                ?? usage["cachedInputTokens"]
        )
        let outputTokens = unsigned(usage["outputTokens"] ?? usage["output_tokens"])
        let reasoningTokens = unsigned(usage["reasoningTokens"] ?? usage["reasoning_tokens"])
        let contextWindowTokens = unsigned(
            usage["contextWindowTokens"]
                ?? usage["context_window_tokens"]
                ?? usage["contextWindowSize"]
                ?? usage["context_window_size"]
        )
        let contextUsedTokens = unsigned(
            usage["contextUsedTokens"]
                ?? usage["context_used_tokens"]
                ?? usage["contextTokens"]
                ?? usage["context_tokens"]
        )
        let directCost = (usage["costUSD"] ?? usage["costUsd"] ?? usage["total_cost_usd"])?
            .doubleValue
        let costTicks = (usage["costUsdTicks"] ?? usage["total_cost_usd_ticks"])?
            .doubleValue
        let totalCostUSD = directCost ?? costTicks.map { $0 / 10_000_000_000 }

        guard inputTokens != nil || cachedInputTokens != nil || outputTokens != nil
                || reasoningTokens != nil || totalCostUSD != nil
                || contextWindowTokens != nil || contextUsedTokens != nil else {
            return nil
        }
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

    /// ACP's `usage_update` session update: `used` tokens in the context window of `size`, and the
    /// session's `cost` so far (`amount`, `currency`). OpenCode, Kimi Code and Hermes send it after
    /// a turn.
    func contextUsage(fromUsageUpdate update: JSONValue) -> HarnessProtocolUsage? {
        guard update["sessionUpdate"]?.stringValue == "usage_update",
              let used = unsigned(update["used"]), let size = unsigned(update["size"]), size > 0 else { return nil }
        let cost = update["cost"]
        let costUSD = cost?["currency"]?.stringValue?.uppercased() == "USD" ? cost?["amount"]?.doubleValue : nil
        return HarnessProtocolUsage(
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            totalCostUSD: costUSD,
            contextWindowTokens: size,
            contextUsedTokens: used,
            extensionValues: [:]
        )
    }

    private func detail(from update: JSONValue) -> String? {
        if let command = update["rawInput"]?["command"]?.stringValue {
            return command
        }
        if let text = update["content"]?.arrayValue?.compactMap({ item in
            item["content"]?["text"]?.stringValue ?? item["text"]?.stringValue
        }).joined(separator: "\n"), !text.isEmpty {
            return text
        }
        return nil
    }

    private func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
    }
}

extension JSONValue {
    var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}
