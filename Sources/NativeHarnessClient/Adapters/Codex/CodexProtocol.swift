import Foundation

enum CodexProtocol {
    static func readConfig(
        id: Int64,
        workspaceURL: URL?,
        includeLayers: Bool = true
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "includeLayers": .bool(includeLayers)
        ]
        params["cwd"] = workspaceURL.map {
            .string($0.standardizedFileURL.path(percentEncoded: false))
        } ?? .null
        return CodexRPCRequest(id: id, method: "config/read", params: .object(params))
    }

    static func accountRateLimits(id: Int64) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "account/rateLimits/read", params: .null)
    }

    /// Uses one banked reset of the account's plan limits. `idempotencyKey` names one attempt: a
    /// retry after an answer that did not arrive sends the same key, so the reset is used once.
    /// Without `creditID` the service picks the reset.
    static func consumeRateLimitResetCredit(id: Int64, idempotencyKey: String, creditID: String?) -> CodexRPCRequest {
        var params: [String: JSONValue] = ["idempotencyKey": .string(idempotencyKey)]
        if let creditID { params["creditId"] = .string(creditID) }
        return CodexRPCRequest(id: id, method: "account/rateLimitResetCredit/consume", params: .object(params))
    }

    static func accountUsage(id: Int64) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "account/usage/read", params: .null)
    }

    static func readConfigRequirements(id: Int64) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "configRequirements/read", params: .null)
    }

    static func initialize(id: Int64, clientVersion: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("native-harness-client"),
                    "title": .string(YardletProduct.name),
                    "version": .string(clientVersion)
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                    "requestAttestation": .bool(false)
                ])
            ])
        )
    }

    /// The project's other roots ride along as `runtimeWorkspaceRoots`, with the cwd first.
    /// A task with no extra roots sends exactly the request it always sent.
    private static func runtimeWorkspaceRoots(
        cwd: URL,
        additionalRoots: [URL]
    ) -> JSONValue? {
        guard !additionalRoots.isEmpty else { return nil }
        let roots = [cwd] + additionalRoots
        return .array(roots.map { .string($0.standardizedFileURL.path(percentEncoded: false)) })
    }

    /// `config` is the thread's configuration override (the Yardlet MCP server's `mcp_servers`
    /// entry). Codex merges it into the user's configuration for this thread only; nil sends the
    /// request exactly as before. `ephemeral` threads are never written to disk (App Server
    /// `Thread.ephemeral`: "should not be materialized on disk"), so they are in no thread list.
    /// `developerInstructions` carries Yardlet instructions, with the configuration's own developer
    /// instructions ahead of it; nil leaves the field out.
    static func startThread(
        id: Int64,
        workspaceURL: URL,
        additionalRoots: [URL] = [],
        config: JSONValue? = nil,
        ephemeral: Bool = false,
        developerInstructions: String? = nil,
        runLocation: CodexRunLocation = .automatic
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "cwd": .string(workspaceURL.standardizedFileURL.path(percentEncoded: false)),
            "approvalPolicy": .string(runLocation.threadApprovalPolicy),
            "sandbox": .string(runLocation.threadSandbox),
            "ephemeral": .bool(ephemeral)
        ]
        if let roots = runtimeWorkspaceRoots(cwd: workspaceURL, additionalRoots: additionalRoots) {
            params["runtimeWorkspaceRoots"] = roots
        }
        if let config { params["config"] = config }
        if let developerInstructions { params["developerInstructions"] = .string(developerInstructions) }
        return CodexRPCRequest(id: id, method: "thread/start", params: .object(params))
    }

    static func resumeThread(
        id: Int64,
        threadID: String,
        workspaceURL: URL,
        excludeTurns: Bool = false,
        initialTurnsPage: JSONValue? = nil,
        additionalRoots: [URL] = [],
        config: JSONValue? = nil,
        developerInstructions: String? = nil,
        runLocation: CodexRunLocation = .automatic
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(workspaceURL.standardizedFileURL.path(percentEncoded: false)),
            "approvalPolicy": .string(runLocation.threadApprovalPolicy),
            "sandbox": .string(runLocation.threadSandbox)
        ]
        if let roots = runtimeWorkspaceRoots(cwd: workspaceURL, additionalRoots: additionalRoots) {
            params["runtimeWorkspaceRoots"] = roots
        }
        if let config { params["config"] = config }
        if let developerInstructions { params["developerInstructions"] = .string(developerInstructions) }
        if excludeTurns {
            params["excludeTurns"] = .bool(true)
        }
        if let initialTurnsPage {
            params["initialTurnsPage"] = initialTurnsPage
        }
        return CodexRPCRequest(id: id, method: "thread/resume", params: .object(params))
    }

    static func readThread(
        id: Int64,
        threadID: String,
        includeTurns: Bool = true
    ) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID),
                "includeTurns": .bool(includeTurns)
            ])
        )
    }

    static func listTurns(
        id: Int64,
        threadID: String,
        cursor: String? = nil,
        limit: Int64? = nil,
        sortDirection: String = "asc",
        itemsView: String = "full"
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "sortDirection": .string(sortDirection),
            "itemsView": .string(itemsView)
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        if let limit { params["limit"] = .integer(limit) }
        return CodexRPCRequest(id: id, method: "thread/turns/list", params: .object(params))
    }

    static func listItems(
        id: Int64,
        threadID: String,
        turnID: String? = nil,
        cursor: String? = nil,
        limit: Int64? = nil,
        sortDirection: String = "asc"
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "sortDirection": .string(sortDirection)
        ]
        if let turnID { params["turnId"] = .string(turnID) }
        if let cursor { params["cursor"] = .string(cursor) }
        if let limit { params["limit"] = .integer(limit) }
        return CodexRPCRequest(id: id, method: "thread/items/list", params: .object(params))
    }

    static func startTurn(
        id: Int64,
        threadID: String,
        prompt: String,
        collaborationPreset: CodexCollaborationPreset? = nil,
        runLocation: CodexRunLocation = .automatic,
        modelSelection: CodexModelSelection? = nil
    ) -> CodexRPCRequest {
        startTurn(
            id: id,
            threadID: threadID,
            input: [.text(prompt)],
            collaborationPreset: collaborationPreset,
            runLocation: runLocation,
            modelSelection: modelSelection
        )
    }

    static func startTurn(
        id: Int64,
        threadID: String,
        input: [CodexUserInput],
        collaborationPreset: CodexCollaborationPreset? = nil,
        runLocation: CodexRunLocation = .automatic,
        modelSelection: CodexModelSelection? = nil,
        turnTrigger: String? = nil
    ) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input.map(\.jsonValue))
        ]
        if let turnTrigger { params["turnTrigger"] = .string(turnTrigger) }
        if let modelSelection {
            params["model"] = .string(modelSelection.model)
            if let effort = modelSelection.reasoningEffort { params["effort"] = .string(effort) }
            if let tier = modelSelection.serviceTier { params["serviceTier"] = .string(tier) }
        }
        // `settings.model` is required and the mode takes precedence over the turn's model and
        // effort. The Codex app fills both from the chat's current model settings, not from the
        // preset, so a Plan turn runs on the model the chat already uses.
        if let collaborationPreset, let model = modelSelection?.model ?? collaborationPreset.model {
            var settings: [String: JSONValue] = ["model": .string(model)]
            if let reasoningEffort = modelSelection?.reasoningEffort ?? collaborationPreset.reasoningEffort {
                settings["reasoning_effort"] = .string(reasoningEffort)
            }
            params["collaborationMode"] = .object([
                "mode": .string(collaborationPreset.mode),
                "settings": .object(settings)
            ])
        }
        if let sandboxPolicy = runLocation.sandboxPolicy {
            params["sandboxPolicy"] = sandboxPolicy
        }
        if let approvalPolicy = runLocation.approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        return CodexRPCRequest(
            id: id,
            method: "turn/start",
            params: .object(params)
        )
    }

    static func steerTurn(
        id: Int64,
        threadID: String,
        expectedTurnID: String,
        input: [CodexUserInput]
    ) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "turn/steer",
            params: .object([
                "threadId": .string(threadID),
                "expectedTurnId": .string(expectedTurnID),
                "input": .array(input.map(\.jsonValue))
            ])
        )
    }

    static func interruptTurn(id: Int64, threadID: String, turnID: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }
}

struct CodexEventProjector: Sendable {
    func project(
        _ message: CodexRPCIncomingMessage,
        rawData: Data,
        localSessionID: UUID,
        sequence: UInt64
    ) -> HarnessEventEnvelope? {
        let payload: HarnessEventPayload

        switch message.method {
        case "item/agentMessage/delta":
            guard let delta = message.params?["delta"]?.stringValue else { return nil }
            payload = .assistantDelta(delta)

        case "turn/plan/updated":
            guard let plan = planText(from: message.params) else { return nil }
            payload = .planUpdated(plan)

        case "turn/completed":
            payload = .turnCompleted

        case "error":
            // A retrying error is the provider reconnecting inside the running turn. The turn
            // shows that status; only the final error ends the task.
            guard message.params?["willRetry"]?.boolValue != true else { return nil }
            let error = CodexTurnErrorPresentation(
                CodexTurnErrorPresentation.notificationError(message.params)
            )
            payload = .error(message: error?.text ?? "Codex reported an error", recoverable: false)

        default:
            return nil
        }

        return HarnessEventEnvelope(
            localSessionID: localSessionID,
            sequence: sequence,
            payload: payload,
            rawProviderEvent: rawData
        )
    }

    private func planText(from params: JSONValue?) -> String? {
        let steps = params?["plan"]?.arrayValue ?? []
        let lines = steps.compactMap { value -> String? in
            guard let step = value["step"]?.stringValue else { return nil }
            let marker = switch value["status"]?.stringValue {
            case "completed": "[x]"
            case "inProgress": "[~]"
            default: "[ ]"
            }
            return "\(marker) \(step)"
        }
        let explanation = params?["explanation"]?.stringValue
        let components = [explanation, lines.isEmpty ? nil : lines.joined(separator: "\n")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: "\n\n")
    }
}

struct CodexActivityProjector: Sendable {
    func project(_ item: JSONValue?) -> HarnessActivity? {
        guard let item,
              let id = item["id"]?.stringValue,
              let kind = item["type"]?.stringValue
        else { return nil }

        let title: String
        let detail: String?
        switch kind {
        case "commandExecution":
            title = "Run command"
            detail = item["command"]?.stringValue
        case "fileChange":
            title = "Change files"
            let paths = item["changes"]?.arrayValue?.compactMap { change in
                change["path"]?.stringValue
            } ?? []
            detail = paths.isEmpty ? nil : paths.joined(separator: ", ")
        case "mcpToolCall":
            let server = item["server"]?.stringValue
            let tool = item["tool"]?.stringValue
            title = [server, tool].compactMap { $0 }.joined(separator: " · ")
            detail = item["pluginId"]?.stringValue
        case "dynamicToolCall":
            title = item["tool"]?.stringValue ?? "Use tool"
            detail = item["namespace"]?.stringValue
        case "collabAgentToolCall":
            title = item["tool"]?.stringValue ?? "Coordinate agent"
            detail = item["prompt"]?.stringValue
        case "subAgentActivity":
            title = item["kind"]?.stringValue ?? "Subagent activity"
            detail = item["agentPath"]?.stringValue
        case "webSearch":
            title = "Search the web"
            detail = item["query"]?.stringValue
        case "imageGeneration":
            title = "Generate image"
            detail = nil
        case "imageView":
            title = "View image"
            detail = nil
        case "contextCompaction":
            title = "Compact context"
            detail = nil
        case "enteredReviewMode":
            title = "Start review"
            detail = item["review"]?["prompt"]?.stringValue
        case "exitedReviewMode":
            title = "Finish review"
            detail = nil
        case "sleep":
            title = "Wait"
            detail = nil
        default:
            return nil
        }

        return HarnessActivity(
            id: id,
            kind: kind,
            title: title.isEmpty ? kind : title,
            detail: detail
        )
    }
}
