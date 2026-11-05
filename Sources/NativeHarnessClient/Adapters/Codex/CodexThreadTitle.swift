import Foundation

/// Names a new Codex thread the way the official Codex app does. The App Server does not title
/// threads itself; the app answers the first request with one short turn on an ephemeral,
/// read-only thread whose final message must match a small schema, then stores the result with
/// `thread/name/set`. The side thread is never written to the user's history, and the turn runs
/// on the account the task already uses.
enum CodexThreadTitle {
    /// The official app's default model for this kind of short generation. A catalog without it
    /// leaves the choice to the App Server's default model.
    static let preferredModel = "gpt-5.6-luna"
    static let requestCharacterLimit = 2_000
    static let timeout: Duration = .seconds(30)

    static func startThread(id: Int64, workspaceURL: URL, model: String?) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "cwd": .string(workspaceURL.standardizedFileURL.path(percentEncoded: false)),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true),
            // Only words are needed, so the side thread runs nothing the user configured.
            "config": .object([
                "model_reasoning_effort": .string("low"),
                "web_search": .string("disabled"),
                "features.apps": .bool(false),
                "features.hooks": .bool(false),
                "features.multi_agent": .bool(false),
                "features.plugins": .bool(false),
                "features.shell_snapshot": .bool(false)
            ])
        ]
        if let model { params["model"] = .string(model) }
        return CodexRPCRequest(id: id, method: "thread/start", params: .object(params))
    }

    /// The side thread that names a task from its recent conversation (`RecentConversationTitle`):
    /// the first-request thread in an empty folder, with a one-line system prompt in place of
    /// Codex's own instructions, without the skills list, memories and the context Codex adds about
    /// permissions, apps and the environment, and with the account's MCP servers turned off by name,
    /// since an empty `mcp_servers` table leaves them on. A name with a dot cannot be written as a key
    /// and stays. Codex 0.166 still sends the account's own AGENTS.md and its built-in tools, as on
    /// its first-request title thread; no setting leaves them out.
    static func startRecentConversationThread(id: Int64, folder: URL, model: String?,
                                              mcpServers: [String]) -> CodexRPCRequest {
        let thread = startThread(id: id, workspaceURL: folder, model: model)
        guard case var .object(params) = thread.params, case var .object(config) = params["config"] else { return thread }
        params["baseInstructions"] = .string(RecentConversationTitle.systemPrompt)
        for key in ["include_permissions_instructions", "include_apps_instructions",
                    "include_collaboration_mode_instructions", "include_environment_context"] {
            config[key] = .bool(false)
        }
        config["project_doc_max_bytes"] = .integer(0)
        config["skills.include_instructions"] = .bool(false)
        config["features.memories"] = .bool(false)
        for name in mcpServers where !name.contains(".") {
            config["mcp_servers.\(name).enabled"] = .bool(false)
        }
        params["config"] = .object(config)
        return CodexRPCRequest(id: id, method: "thread/start", params: .object(params))
    }

    /// The configuration a thread in `folder` would load, which names the MCP servers it would start.
    static func readConfig(id: Int64, folder: URL) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "config/read", params: .object([
            "cwd": .string(folder.standardizedFileURL.path(percentEncoded: false))
        ]))
    }

    /// The MCP servers `config/read` reports as on.
    static func mcpServerNames(fromConfig result: JSONValue?) -> [String] {
        guard case let .object(servers)? = result?["config"]?["mcp_servers"] else { return [] }
        return servers.filter { $0.value["enabled"]?.boolValue != false }.map(\.key).sorted()
    }

    static func startTurn(id: Int64, threadID: String, request: String) -> CodexRPCRequest {
        startTurn(id: id, threadID: threadID, prompt: prompt(for: request))
    }

    static func startTurn(id: Int64, threadID: String, prompt: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([CodexUserInput.text(prompt).jsonValue]),
                "outputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["title": .object(["type": .string("string")])]),
                    "required": .array([.string("title")]),
                    "additionalProperties": .bool(false)
                ])
            ])
        )
    }

    static func unsubscribe(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(
            id: id,
            method: "thread/unsubscribe",
            params: .object(["threadId": .string(threadID)])
        )
    }

    static func prompt(for request: String) -> String {
        """
        Name the coding task that begins with the request below. Answer only through the title \
        field: plain text in the language of the request, at most 36 characters and about five \
        words, leading with what is being done. Keep ticket references such as ABC-123 as written. \
        Leave out quotes, Markdown, and closing punctuation. Do not carry out the request.

        Request:
        \(request.prefix(requestCharacterLimit))
        """
    }

    /// The request text the user typed, without attachments, skills, or mentions; a message another
    /// task sent (`create_task`'s first message) is its body, without the envelope.
    static func request(from inputs: [CodexUserInput]) -> String? {
        let text = inputs.compactMap { input -> String? in
            guard case let .text(text, _) = input else { return nil }
            return text
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : TaskMessage.parse(text)?.body ?? text
    }

    static func title(fromFinalMessage message: String?) -> String? {
        guard let data = message?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return SessionTitleProjection.normalizedProviderTitle(value["title"]?.stringValue)
    }
}
