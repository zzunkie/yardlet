import Foundation

/// Runs a tool somewhere else: in the app, reached over its local endpoint.
package protocol AgentToolInvoking: Sendable {
    func call(tool: String, arguments: ToolJSON) async -> AgentToolResult
    /// The tools this task may call as MCP `tools/list` entries, with the app's fingerprint of
    /// them, or nil when the app cannot say (it is not running, or this server was not started by
    /// Yardlet).
    func listTools() async -> AgentToolList?
    /// Waits for the app to say that the task's list no longer matches `fingerprint`, the one the
    /// client last listed (nil when the app gave none).
    func waitForToolListChange(from fingerprint: String?) async -> AgentToolListWatch
}

extension AgentToolInvoking {
    package func listTools() async -> AgentToolList? { nil }
    package func waitForToolListChange(from fingerprint: String?) async -> AgentToolListWatch { .unavailable }
}

/// What a `tools/watch` learned.
package enum AgentToolListWatch: Equatable, Sendable {
    /// The task's list differs from the client's: tell the client to list again.
    case changed
    /// The app's hold ran out with nothing to tell; ask again.
    case unchanged
    /// The app cannot be asked: it is not running, does not know this task's token, or did not
    /// start this server.
    case unavailable
}

/// The minimum of the Model Context Protocol a harness needs to list and call Yardlet's tools:
/// `initialize`, `ping`, `tools/list`, and `tools/call` over JSON-RPC 2.0, and
/// `notifications/tools/list_changed` when the task's tools change (`watchToolList`). One message
/// in gives at most one message out; the only session state is what its client last listed.
///
/// The app decides the list: the browser tools when they are on, the task suggestion tools, and
/// the tools of the connectors the user connected in Yardlet. When the app cannot answer, the list
/// is Yardlet's own tools, and calling one reports why the app is unreachable.
package struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it back; any other gets the newest. The
    /// server uses nothing that differs between them (tools only, no tasks or elicitation).
    package static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    package enum ErrorCode {
        package static let parseError: Int64 = -32700
        package static let invalidRequest: Int64 = -32600
        package static let methodNotFound: Int64 = -32601
        package static let invalidParams: Int64 = -32602
    }

    package let name: String
    package let version: String
    package let instructions: String?
    package let tools: [AgentToolDefinition]
    package let invoker: any AgentToolInvoking
    /// What the client last listed, for `watchToolList`.
    package let listing = MCPToolListing()

    package init(
        name: String = AgentToolEnvironment.serverName,
        version: String,
        instructions: String? = AgentToolCatalog.serverInstructions,
        tools: [AgentToolDefinition] = AgentToolCatalog.builtInTools,
        invoker: any AgentToolInvoking
    ) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.invoker = invoker
    }

    /// Answers one line of JSON-RPC. Nil means nothing is written back (a notification, or a
    /// response to a request this server never sends).
    package func handle(_ line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(ToolJSON.self, from: line) else {
            return encode(errorReply(id: .null, code: ErrorCode.parseError, message: "Parse error"))
        }
        if case .array(let messages) = message {
            guard !messages.isEmpty else {
                return encode(errorReply(id: .null, code: ErrorCode.invalidRequest, message: "Empty batch"))
            }
            var replies: [ToolJSON] = []
            for message in messages {
                if let reply = await reply(to: message) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : encode(.array(replies))
        }
        return await reply(to: message).map(encode)
    }

    private func reply(to message: ToolJSON) async -> ToolJSON? {
        guard case .object(let fields) = message else {
            return errorReply(id: .null, code: ErrorCode.invalidRequest, message: "Invalid request")
        }
        let id = fields["id"]
        guard let method = fields["method"]?.stringValue else {
            // A response from the client, or something with no method: answer only a request.
            if fields["result"] != nil || fields["error"] != nil { return nil }
            return errorReply(id: id ?? .null, code: ErrorCode.invalidRequest, message: "Invalid request")
        }
        guard let id, id != .null else { return nil }  // Notifications get no reply.
        let params = fields["params"] ?? .object([:])
        switch method {
        case "initialize":
            return resultReply(id: id, initializeResult(params))
        case "ping":
            return resultReply(id: id, .object([:]))
        case "tools/list":
            let app = await invoker.listTools()
            await listing.listed(fingerprint: app?.fingerprint)
            return resultReply(id: id, .object(["tools": .array(app?.tools ?? tools.map(\.json))]))
        case "tools/call":
            guard let toolName = params["name"]?.stringValue else {
                return errorReply(id: id, code: ErrorCode.invalidParams, message: "tools/call needs a tool name")
            }
            // Browser tool names are known here; connector tools, and the password manager's fill tool
            // the app lists only while it is on, are known only to the app, which answers an unknown
            // or switched-off one with an error result.
            if toolName.hasPrefix(AgentToolCatalog.browserToolPrefix), !tools.contains(where: { $0.name == toolName }),
               VaultToolCatalog.definition(named: toolName) == nil {
                let browserTools = AgentToolNames.family(of: toolName, in: tools.map(\.name))
                return errorReply(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(toolName). "
                    + "Yardlet's browser tools are \(AgentToolNames.listed(browserTools)).")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard case .object = arguments else {
                return errorReply(id: id, code: ErrorCode.invalidParams, message: "Tool arguments must be an object")
            }
            let result = await invoker.call(tool: toolName, arguments: arguments)
            return resultReply(id: id, Self.json(result))
        default:
            return errorReply(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: ToolJSON) -> ToolJSON {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        var result: [String: ToolJSON] = [
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
            "serverInfo": .object(["name": .string(name), "title": .string("Yardlet"), "version": .string(self.version)])
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    package static func json(_ result: AgentToolResult) -> ToolJSON {
        var fields: [String: ToolJSON] = [
            "content": .array(result.content.map { content in
                switch content {
                case .text(let text):
                    .object(["type": .string("text"), "text": .string(text)])
                case .image(let data, let mimeType):
                    .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mimeType)])
                case .json(let item):
                    item
                }
            }),
            "isError": .bool(result.isError)
        ]
        if let structured = result.structuredContent { fields["structuredContent"] = structured }
        return .object(fields)
    }

    private func resultReply(id: ToolJSON, _ result: ToolJSON) -> ToolJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func errorReply(id: ToolJSON, code: Int64, message: String) -> ToolJSON {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])
        ])
    }

    private func encode(_ value: ToolJSON) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The encoder escapes control characters, so a message never spans lines.
        return (try? encoder.encode(value)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

/// Reads newline-delimited JSON-RPC from standard input and writes each reply on its own line to
/// standard output. Calls run concurrently; a reply is written whole.
///
/// A `tools/call` whose client asked for progress (`_meta.progressToken`) gets a progress
/// notification every `keepAliveInterval` while it runs. A session tool may wait many minutes for
/// another task or the person, and Claude Code ends a stdio call that sends nothing for its idle
/// limit (30 minutes, `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`) while each progress notification starts
/// that limit again; the notifications carry no message.
package enum MCPStdioLoop {
    package static let keepAliveInterval: Duration = .seconds(20)

    package static func run(_ server: MCPServer) async {
        let writer = LineWriter()
        await serve(server, lines: standardInputLines()) { await writer.write($0) }
    }

    /// The loop itself, over any lines and any writer (tests).
    package static func serve(
        _ server: MCPServer,
        lines: AsyncStream<String>,
        keepAliveInterval: Duration = keepAliveInterval,
        watchFirstDelay: Duration = AgentToolListWatching.firstWatchDelay,
        write: @escaping @Sendable (Data) async -> Void
    ) async {
        // Not one of the group's tasks: when input ends, calls still running finish and the
        // server exits without waiting on a watch the app may be holding.
        let watch = Task { await server.watchToolList(firstDelay: watchFirstDelay, notify: write) }
        defer { watch.cancel() }
        await withDiscardingTaskGroup { group in
            for await line in lines {
                guard !line.allSatisfy(\.isWhitespace) else { continue }
                group.addTask {
                    let message = Data(line.utf8)
                    let keepAlive = MCPServer.progressToken(inToolCall: message).map { token in
                        Task {
                            var progress: Int64 = 0
                            while true {
                                try? await Task.sleep(for: keepAliveInterval)
                                guard !Task.isCancelled else { return }
                                progress += 1
                                await write(MCPServer.progressNotification(token: token, progress: progress))
                            }
                        }
                    }
                    let reply = await server.handle(message)
                    // A progress notification already being written finishes first: none may follow the reply.
                    keepAlive?.cancel()
                    await keepAlive?.value
                    if let reply { await write(reply) }
                }
            }
        }
    }

    private static func standardInputLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
    }

    private actor LineWriter {
        func write(_ message: Data) {
            var data = message
            data.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

extension MCPServer {
    /// The progress token a `tools/call` request asked for, if any.
    package static func progressToken(inToolCall line: Data) -> ToolJSON? {
        guard let message = try? JSONDecoder().decode(ToolJSON.self, from: line),
              message["method"]?.stringValue == "tools/call", let id = message["id"], id != .null,
              let token = message["params"]?["_meta"]?["progressToken"] else { return nil }
        switch token {
        case .string, .integer: return token
        default: return nil
        }
    }

    /// `notifications/progress` for a token, without a total or message.
    package static func progressNotification(token: ToolJSON, progress: Int64) -> Data {
        let value: ToolJSON = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object(["progressToken": token, "progress": .integer(progress)])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// What the server's client has listed: each `tools/list` answered, numbered, with the app's
/// fingerprint of the list (nil when the app could not say and the server listed its own tools).
package actor MCPToolListing {
    package struct Listed: Equatable, Sendable {
        package var number: Int
        package var fingerprint: String?
    }

    package private(set) var latest: Listed?
    private var waiters: [UUID: (after: Int, continuation: CheckedContinuation<Listed?, Never>)] = [:]

    package init() {}

    func listed(fingerprint: String?) {
        let listed = Listed(number: (latest?.number ?? 0) + 1, fingerprint: fingerprint)
        latest = listed
        for (id, waiter) in waiters where waiter.after < listed.number {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: listed)
        }
    }

    /// The first listing after `number`, once the client has made it; nil when the waiting task
    /// is cancelled first.
    package func next(after number: Int) async -> Listed? {
        if let latest, latest.number > number { return latest }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = (number, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }
}

extension MCPServer {
    /// `notifications/tools/list_changed`, which this server announces in `initialize`.
    package static let toolListChangedNotification = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)

    /// Tells the client, with `notifications/tools/list_changed`, when the app's list of the
    /// task's tools stops matching the one the client last listed, so a harness that follows the
    /// notification (Claude Code 2.1.291 and 2.1.304 list again at once) has the new tools without
    /// a restart. It starts after the client's first `tools/list` and `firstDelay`, asks the app
    /// to wait for a change, and after telling waits for the client to list again: a client that
    /// never does (Codex 0.163 only logs the notification) is told once. An app it cannot ask is
    /// asked again later, less often each time. The app decides when a change is told: between
    /// the task's turns (`AgentToolBroker.watch`).
    package func watchToolList(
        firstDelay: Duration = AgentToolListWatching.firstWatchDelay,
        retryDelay: Duration = .seconds(15),
        maximumRetryDelay: Duration = .seconds(300),
        minimumInterval: Duration = .seconds(2),
        notify: @escaping @Sendable (Data) async -> Void
    ) async {
        guard var listed = await listing.next(after: 0) else { return }
        try? await Task.sleep(for: firstDelay)
        var retry = retryDelay
        var lastTold: ContinuousClock.Instant?
        while !Task.isCancelled {
            if let latest = await listing.latest { listed = latest }
            switch await invoker.waitForToolListChange(from: listed.fingerprint) {
            case .changed:
                retry = retryDelay
                // The client listed again while the app waited: ask about what it has now.
                if let latest = await listing.latest, latest.number > listed.number { continue }
                if let lastTold, lastTold.duration(to: .now) < minimumInterval {
                    try? await Task.sleep(for: minimumInterval - lastTold.duration(to: .now))
                }
                guard !Task.isCancelled else { return }
                await notify(Self.toolListChangedNotification)
                lastTold = .now
                guard let next = await listing.next(after: listed.number) else { return }
                listed = next
            case .unchanged:
                retry = retryDelay
            case .unavailable:
                try? await Task.sleep(for: retry)
                retry = min(retry * 2, maximumRetryDelay)
            }
        }
    }
}
