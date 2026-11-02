import Foundation

/// An ACP agent's saved conversations, read over a connection of their own: `session/list` names a
/// folder's sessions and `session/load` has the agent replay one as session updates. Each read
/// starts the agent's process with the arguments and environment a task of that account starts it
/// with (`ACPLaunchConfiguration.arguments(for:connection:)`), so an account's folder
/// (`KIMI_CODE_HOME`, `GROK_HOME`, `HERMES_HOME`, OpenCode's XDG folders) is the one read, and stops
/// it when the read is over. No prompt is sent, no session joins a task's adapter, and no sign-in
/// changes.
struct ACPSessionHistory: Sendable {
    /// The transport one read runs on: the agent's own process unless a test gives its own.
    var makeTransport: @Sendable (URL) -> any ACPTransport
    /// How long one read may take before its process is stopped.
    var timeout: Duration

    static let live = ACPSessionHistory(makeTransport: { ACPProcessTransport(executableURL: $0) }, timeout: .seconds(60))

    /// The harnesses whose conversations are listed and replayed this way: every ACP agent but
    /// Antigravity CLI, whose own index and log are read instead (`AntigravityConversationStore`).
    static func reads(_ harness: HarnessKind) -> Bool {
        harness != .antigravityCLI && HarnessCatalog.descriptor(for: harness)?.transport == .acp
    }

    /// The agent's sessions in `workspaceURL`, a page at a time from `cursor`, most recent first as the
    /// agent lists them. The folder is asked of the agent (`cwd`) and checked again here, since an
    /// agent may list every folder's.
    func sessions(
        of harness: HarnessKind, executableURL: URL, connection: ProviderConnection?,
        in workspaceURL: URL, cursor: String?
    ) async throws -> ImportableConversationPage {
        try await read(harness, executableURL: executableURL, connection: connection, in: workspaceURL) { link, capabilities in
            guard capabilities["sessionCapabilities"]?["list"]?.objectValue != nil else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.format("%@ does not list its conversations over ACP", harness.displayName))
            }
            let (result, _) = try await link.call {
                ACPProtocol.listSessions(id: $0, workspaceURL: workspaceURL, cursor: cursor)
            }
            let conversations = (result["sessions"]?.arrayValue ?? []).compactMap {
                Self.conversation($0, harness: harness, in: workspaceURL)
            }
            return ImportableConversationPage(conversations: conversations, nextCursor: result["nextCursor"]?.stringValue)
        }
    }

    /// The conversation the agent keeps under `providerSessionID`, as the agent replays it when the
    /// session loads, in Yardlet's entries (`ACPReplayTranscript`).
    func conversation(
        of harness: HarnessKind, executableURL: URL, connection: ProviderConnection?,
        providerSessionID: String, workspaceURL: URL
    ) async throws -> [TranscriptEntry] {
        try await read(harness, executableURL: executableURL, connection: connection, in: workspaceURL) { link, capabilities in
            guard capabilities["loadSession"]?.boolValue == true else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.format("%@ does not advertise ACP session loading", harness.displayName))
            }
            let (_, updates) = try await link.call(updatesOf: providerSessionID) {
                ACPProtocol.loadSession(id: $0, providerSessionID: providerSessionID, workspaceURL: workspaceURL)
            }
            return ACPReplayTranscript.entries(from: updates)
        }
    }

    /// Starts the agent, has it answer `initialize`, runs `body` with its capabilities and stops it,
    /// however the read ends; past `timeout` the process is stopped and the read fails.
    private func read<Result: Sendable>(
        _ harness: HarnessKind, executableURL: URL, connection: ProviderConnection?, in workspaceURL: URL,
        _ body: (inout ACPReadLink, JSONValue) async throws -> Result
    ) async throws -> Result {
        let transport = makeTransport(executableURL)
        let timeout = self.timeout
        let deadline = ContinuousClock.now + timeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await transport.stop()
        }
        do {
            try await transport.start(ACPLaunchConfiguration(
                arguments: ACPLaunchConfiguration.arguments(for: harness, connection: connection),
                workspaceURL: workspaceURL,
                environmentOverrides: connection?.environment ?? [:]))
            var link = ACPReadLink(transport: transport, frames: await transport.messages().makeAsyncIterator())
            let (initialized, _) = try await link.call { ACPProtocol.initialize(id: $0) }
            guard initialized["protocolVersion"]?.integerValue == 1 else {
                throw HarnessAdapterError.unsupportedRuntime(
                    version: "ACP \(initialized["protocolVersion"]?.integerValue ?? -1)")
            }
            let result = try await body(&link, initialized["agentCapabilities"] ?? .object([:]))
            timer.cancel()
            await transport.stop()
            return result
        } catch {
            timer.cancel()
            await transport.stop()
            if ContinuousClock.now >= deadline {
                throw HarnessAdapterError.invalidProviderEvent(L10n.string("ACP request timed out"))
            }
            throw error
        }
    }

    /// One session of `session/list` as a conversation to import, when it is `workspaceURL`'s.
    static func conversation(_ session: JSONValue, harness: HarnessKind, in workspaceURL: URL) -> ImportableConversation? {
        guard let id = session["sessionId"]?.stringValue, !id.isEmpty else { return nil }
        let folder = session["cwd"]?.stringValue.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? workspaceURL
        guard path(of: folder) == path(of: workspaceURL) else { return nil }
        let title = session["title"]?.stringValue?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return ImportableConversation(harness: harness, providerSessionID: id,
            title: title.isEmpty ? L10n.string("Untitled task") : title,
            workspaceURL: workspaceURL, updatedAt: date(session["updatedAt"]) ?? .distantPast, isOpenElsewhere: false)
    }

    /// ACP's `updatedAt` is an ISO 8601 time; seconds since 1970 are taken too.
    private static func date(_ value: JSONValue?) -> Date? {
        if let text = value?.stringValue {
            return (try? Date(text, strategy: .iso8601))
                ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return value?.doubleValue.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1_000 : $0) }
    }

    private static func path(of folder: URL) -> String {
        ProjectSidebarPresentation.normalizedPath(for: folder.resolvingSymlinksInPath())
    }
}

/// One read's requests and the agent's answers in the order the agent wrote them. A request goes
/// out without the transport waiting for its answer, so the answer comes through the same stream
/// as the session updates before it: everything the agent replayed for a `session/load` has
/// arrived by the time its answer does.
struct ACPReadLink {
    let transport: any ACPTransport
    var frames: AsyncStream<ACPRawFrame>.AsyncIterator
    private var nextID: Int64 = 1

    init(transport: any ACPTransport, frames: AsyncStream<ACPRawFrame>.AsyncIterator) {
        self.transport = transport
        self.frames = frames
    }

    /// The result of the request `request` makes with its ID, and the updates of session `updatesOf`
    /// that came before it.
    mutating func call(
        updatesOf sessionID: String? = nil, _ request: (Int64) -> JSONValue
    ) async throws -> (result: JSONValue, updates: [JSONValue]) {
        let id = nextID
        nextID += 1
        try await transport.send(request(id))
        var updates: [JSONValue] = []
        while let frame = await frames.next() {
            let value = frame.value
            if value["method"] == nil, value["id"]?.integerValue == id {
                if let error = value["error"] {
                    throw HarnessAdapterError.invalidProviderEvent(
                        error["message"]?.stringValue ?? L10n.string("ACP request failed"))
                }
                return (value["result"] ?? .object([:]), updates)
            }
            if let requestID = value["id"], value["method"] != nil {
                // A read has nothing to grant or host: the agent's own requests are declined.
                try? await transport.send(ACPProtocol.methodNotFound(id: requestID))
                continue
            }
            if let sessionID, value["method"]?.stringValue == "session/update",
               value["params"]?["sessionId"]?.stringValue == sessionID,
               let update = value["params"]?["update"] {
                updates.append(update)
            }
        }
        throw HarnessAdapterError.processExited(code: -1, message: L10n.string("ACP agent is not running"))
    }
}

/// A conversation an ACP agent replayed (`session/load`) in Yardlet's entries, as the live route
/// shows a turn: the person's message chunks make one request, and the answer, thinking, tool calls
/// and plan after it go through the same projection as a running turn's (`ACPEventProjector`).
enum ACPReplayTranscript {
    /// The session updates that make up a conversation: the rest are the session's state (its
    /// options, commands, usage and title).
    static let conversationUpdates: Set<String> = [
        "user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"
    ]

    static func entries(from updates: [JSONValue]) -> [TranscriptEntry] {
        var builder = TranscriptBuilder(limit: TranscriptBuilder.maximumEntryLimit)
        let projector = ACPEventProjector()
        var request: (text: String, images: [TranscriptImageAttachment], messageID: String?)?
        var answer: (text: String, messageID: String?)?
        var tools: [String: ACPToolCallState] = [:]
        var answering = false

        func finishRequest() {
            guard let pending = request else { return }
            request = nil
            guard !pending.text.isEmpty || !pending.images.isEmpty else { return }
            builder.appendUser(pending.text, images: pending.images)
        }
        func finishAnswer() {
            guard let pending = answer else { return }
            answer = nil
            builder.apply(.assistantMessageCompleted(pending.text))
        }

        for update in updates {
            let kind = update["sessionUpdate"]?.stringValue
            let messageID = update["messageId"]?.stringValue
            switch kind {
            case "user_message_chunk":
                if answering {
                    finishAnswer()
                    builder.apply(.turnCompleted)
                    answering = false
                }
                // Another message of the person's, which a message ID tells apart, is a request of its own.
                if let pending = request, let messageID, let previous = pending.messageID, previous != messageID {
                    finishRequest()
                }
                var pending = request ?? ("", [], messageID)
                let content = update["content"]
                switch content?["type"]?.stringValue {
                case "text":
                    pending.text += content?["text"]?.stringValue ?? ""
                case "image":
                    if let data = content?["data"]?.stringValue, let mimeType = content?["mimeType"]?.stringValue,
                       let url = URL(string: "data:\(mimeType);base64,\(data)") {
                        pending.images.append(TranscriptImageAttachment(url: url, name: nil))
                    }
                default:
                    break
                }
                request = pending
            case "agent_message_chunk":
                finishRequest()
                answering = true
                guard update["content"]?["type"]?.stringValue == "text",
                      let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { continue }
                if let pending = answer, let messageID, let previous = pending.messageID, previous != messageID {
                    finishAnswer()
                }
                answer = ((answer?.text ?? "") + text, answer?.messageID ?? messageID)
                builder.apply(.assistantDelta(text))
            case "agent_thought_chunk", "tool_call", "tool_call_update", "plan":
                finishRequest()
                finishAnswer()
                answering = true
                if kind == "tool_call" || kind == "tool_call_update", let id = update["toolCallId"]?.stringValue {
                    let previous = kind == "tool_call" ? nil : tools[id]
                    guard let state = projector.toolCall(from: update, previous: previous) else { continue }
                    tools[id] = state
                    builder.apply(state.payload(isStart: kind == "tool_call"))
                } else {
                    for payload in projector.payloads(from: update) { builder.apply(payload) }
                }
            default:
                break
            }
        }
        finishRequest()
        finishAnswer()
        builder.apply(.turnCompleted)
        return builder.entries
    }
}

extension ACPLaunchConfiguration {
    /// The arguments a task of `connection` starts `harness`'s ACP agent with: the catalog's, then the
    /// account's own.
    static func arguments(for harness: HarnessKind, connection: ProviderConnection?) -> [String] {
        (HarnessCatalog.descriptor(for: harness)?.launchArguments ?? []) + (connection?.launchArguments ?? [])
    }
}
