import XCTest
@testable import NativeHarnessClient

/// Listing and replaying an ACP agent's saved conversations over a connection of their own:
/// `session/list` and `session/load`, under the account's own folder, with no prompt.
final class ACPSessionHistoryTests: XCTestCase {
    private let workspace = URL(filePath: "/tmp/acp-history-project", directoryHint: .isDirectory)

    func testListAndReplayReadTheAccountsSessionsWithoutATurn() async throws {
        let kimi = ProviderConnection(id: "kimi-work", name: "Kimi work", harness: .kimiCode, providerID: nil,
                                      homePath: "/tmp/kimi-work", credentialSelector: nil)
        let agent = ScriptedACPAgent(
            sessions: [
                Self.session("s-2", "Fix the importer\nwith details", in: workspace, updatedAt: "2026-11-02T09:30:00Z"),
                Self.session("s-other", "Another folder's", in: URL(filePath: "/tmp/elsewhere"), updatedAt: nil),
                Self.session("s-1", nil, in: workspace, updatedAt: "2026-11-01T08:00:00.250Z")
            ],
            replays: ["s-2": Self.replay])
        let history = ACPSessionHistory(makeTransport: { _ in agent.transport() }, timeout: .seconds(10))

        let page = try await history.sessions(of: .kimiCode, executableURL: URL(filePath: "/tmp/kimi"),
                                              connection: kimi, in: workspace, cursor: "page-1")
        XCTAssertEqual(page.conversations.map(\.providerSessionID), ["s-2", "s-1"], "Only this folder's sessions")
        XCTAssertEqual(page.conversations.map(\.title), ["Fix the importer", L10n.string("Untitled task")])
        XCTAssertEqual(page.conversations.first?.updatedAt, try Date("2026-11-02T09:30:00Z", strategy: .iso8601))
        XCTAssertEqual(page.conversations.last?.updatedAt,
                       try Date("2026-11-01T08:00:00Z", strategy: .iso8601).addingTimeInterval(0.25))
        XCTAssertEqual(page.conversations.first?.workspaceURL, workspace)
        XCTAssertEqual(page.nextCursor, "page-2")

        let entries = try await history.conversation(of: .kimiCode, executableURL: URL(filePath: "/tmp/kimi"),
            connection: kimi, providerSessionID: "s-2", workspaceURL: workspace)
        XCTAssertEqual(entries.count, 6)
        guard entries.count == 6 else { return }
        XCTAssertEqual(entries[0].content, .user(text: "Read the importer", images: nil), "One request from its chunks")
        XCTAssertEqual(entries[1].content, .reasoning(text: "Looking at the sheet", isStreaming: false))
        guard case let .activity(tool, state) = entries[2].content else { return XCTFail("\(entries[2].content)") }
        XCTAssertEqual([tool.id, tool.kind, tool.title, tool.output], ["tool-1", "read", "Read ImportConversationSheet.swift",
                                                                      "struct ImportConversationSheet"])
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(entries[3].content, .assistant(text: "It lists one folder.", isStreaming: false))
        XCTAssertEqual(entries[4].content, .user(text: "Thanks", images: nil))
        XCTAssertEqual(entries[5].content, .assistant(text: "You're welcome.", isStreaming: false))

        let connections = agent.connections
        XCTAssertEqual(connections.count, 2, "One process a read")
        for connection in connections {
            let configuration = await connection.configuration
            XCTAssertEqual(configuration?.arguments, ["acp"])
            XCTAssertEqual(configuration?.environmentOverrides["KIMI_CODE_HOME"], "/tmp/kimi-work")
            XCTAssertEqual(configuration?.workspaceURL, workspace)
            let stopped = await connection.stopped
            XCTAssertTrue(stopped, "The read's process ends with it")
        }
        let methods = await connections[0].methods + connections[1].methods
        XCTAssertEqual(methods, ["initialize", "session/list", "initialize", "session/load"])
        let list = await connections[0].sent.first { $0["method"]?.stringValue == "session/list" }
        XCTAssertEqual(list?["params"]?["cwd"]?.stringValue, workspace.path(percentEncoded: false))
        XCTAssertEqual(list?["params"]?["cursor"]?.stringValue, "page-1")
        let load = await connections[1].sent.first { $0["method"]?.stringValue == "session/load" }
        XCTAssertEqual(load?["params"]?["mcpServers"], .array([]))
        let declined = await connections[1].sent.contains {
            $0["id"]?.stringValue == "agent-request" && $0["error"]?["code"]?.integerValue == -32601
        }
        XCTAssertTrue(declined, "What the agent asks during a read is declined")
    }

    func testAnAgentThatDoesNotListSaysSo() async throws {
        let agent = ScriptedACPAgent(sessions: [], replays: [:], listsSessions: false)
        let history = ACPSessionHistory(makeTransport: { _ in agent.transport() }, timeout: .seconds(10))
        do {
            _ = try await history.sessions(of: .hermes, executableURL: URL(filePath: "/tmp/hermes"), connection: nil,
                                           in: workspace, cursor: nil)
            XCTFail("Listing should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           L10n.format("%@ does not list its conversations over ACP", HarnessKind.hermes.displayName))
        }
        let methods = await agent.connections[0].methods
        XCTAssertEqual(methods, ["initialize"])
        let stopped = await agent.connections[0].stopped
        XCTAssertTrue(stopped)
    }

    /// Installed agents' own lists and replays, with no prompt. `NHC_ACP_HISTORY_LIVE` names
    /// `harness=executable@folder` entries separated by `;`; set `NHC_ACP_HISTORY_REPLAY` to also
    /// replay each folder's most recent conversation.
    func testLiveAgentsListAndReplayTheirConversations() async throws {
        guard let spec = ProcessInfo.processInfo.environment["NHC_ACP_HISTORY_LIVE"] else {
            throw XCTSkip("Set NHC_ACP_HISTORY_LIVE to harness=executable@folder entries")
        }
        let replays = ProcessInfo.processInfo.environment["NHC_ACP_HISTORY_REPLAY"] != nil
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            let location = parts.last?.split(separator: "@", maxSplits: 1) ?? []
            guard parts.count == 2, location.count == 2 else { return XCTFail("Malformed entry \(entry)") }
            let harness = HarnessKind(rawValue: String(parts[0]))
            let executable = URL(filePath: String(location[0]))
            let folder = URL(filePath: String(location[1]), directoryHint: .isDirectory)
            let page = try await ACPSessionHistory.live.sessions(of: harness, executableURL: executable, connection: nil,
                                                                 in: folder, cursor: nil)
            print("acp-live", harness.rawValue, "sessions", page.conversations.count, "next", page.nextCursor ?? "-")
            for item in page.conversations.prefix(3) {
                print("acp-live", harness.rawValue, item.providerSessionID.prefix(12), item.updatedAt, item.title.prefix(40))
            }
            guard replays, let latest = page.conversations.first else { continue }
            let entries = try await ACPSessionHistory.live.conversation(of: harness, executableURL: executable,
                connection: nil, providerSessionID: latest.providerSessionID, workspaceURL: folder)
            let kinds = entries.map { entry -> String in
                switch entry.content {
                case .user: "user"
                case .assistant: "assistant"
                case .reasoning: "reasoning"
                case .activity: "tool"
                default: "other"
                }
            }
            print("acp-live", harness.rawValue, "replayed", entries.count, kinds.prefix(12).joined(separator: ","))
            XCTAssertFalse(entries.isEmpty)
        }
    }

    // MARK: - Fixtures

    static func session(_ id: String, _ title: String?, in folder: URL, updatedAt: String?) -> JSONValue {
        var session: [String: JSONValue] = ["sessionId": .string(id), "cwd": .string(folder.path(percentEncoded: false))]
        if let title { session["title"] = .string(title) }
        if let updatedAt { session["updatedAt"] = .string(updatedAt) }
        return .object(session)
    }

    /// Two turns as an ACP agent replays them: the request in two chunks, thinking, a tool call
    /// and its result, the answer, then a second request and answer.
    static let replay: [JSONValue] = [
        update(["sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Read the ")])]),
        update(["sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("importer")])]),
        update(["sessionUpdate": .string("agent_thought_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Looking at the sheet")])]),
        update(["sessionUpdate": .string("tool_call"), "toolCallId": .string("tool-1"),
                "title": .string("Read ImportConversationSheet.swift"), "kind": .string("read"),
                "status": .string("in_progress")]),
        update(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool-1"),
                "status": .string("completed"),
                "content": .array([.object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string("struct ImportConversationSheet")])])])]),
        update(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("It lists ")])]),
        update(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("one folder.")])]),
        update(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array([])]),
        update(["sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Thanks")])]),
        update(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("You're welcome.")])])
    ]

    private static func update(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
}

/// An ACP agent that answers through the message stream, in the order its process would write the
/// answers and updates: each read Yardlet makes gets a connection of its own.
final class ScriptedACPAgent: @unchecked Sendable {
    let sessions: [JSONValue]
    let replays: [String: [JSONValue]]
    let listsSessions: Bool
    private let lock = NSLock()
    private var made: [Connection] = []

    init(sessions: [JSONValue], replays: [String: [JSONValue]], listsSessions: Bool = true) {
        self.sessions = sessions
        self.replays = replays
        self.listsSessions = listsSessions
    }

    var connections: [Connection] { lock.withLock { made } }

    func transport() -> any ACPTransport {
        let connection = Connection(agent: self)
        lock.withLock { made.append(connection) }
        return connection
    }

    actor Connection: ACPTransport {
        let agent: ScriptedACPAgent
        private let stream: AsyncStream<ACPRawFrame>
        private let continuation: AsyncStream<ACPRawFrame>.Continuation
        private(set) var configuration: ACPLaunchConfiguration?
        private(set) var sent: [JSONValue] = []
        private(set) var stopped = false

        init(agent: ScriptedACPAgent) {
            self.agent = agent
            (stream, continuation) = AsyncStream<ACPRawFrame>.makeStream()
        }

        var methods: [String] { sent.compactMap { $0["method"]?.stringValue } }

        func start(_ configuration: ACPLaunchConfiguration) async throws { self.configuration = configuration }

        func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
            throw HarnessAdapterError.invalidProviderEvent("A read sends its requests without waiting on the transport")
        }

        func send(_ value: JSONValue) async throws {
            sent.append(value)
            guard let method = value["method"]?.stringValue, let id = value["id"] else { return }
            switch method {
            case "initialize":
                var sessionCapabilities: [String: JSONValue] = ["resume": .object([:])]
                if agent.listsSessions { sessionCapabilities["list"] = .object([:]) }
                answer(id, .object(["protocolVersion": .integer(1), "agentCapabilities": .object([
                    "loadSession": .bool(true), "sessionCapabilities": .object(sessionCapabilities)])]))
            case "session/list":
                answer(id, .object(["sessions": .array(agent.sessions), "nextCursor": .string("page-2")]))
            case "session/load":
                let sessionID = value["params"]?["sessionId"]?.stringValue ?? ""
                write(.object(["jsonrpc": .string("2.0"), "id": .string("agent-request"),
                               "method": .string("fs/read_text_file"), "params": .object([:])]))
                for update in agent.replays[sessionID] ?? [] {
                    write(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                                   "params": .object(["sessionId": .string(sessionID), "update": update])]))
                }
                answer(id, .object(["sessionId": .string(sessionID)]))
            default:
                write(.object(["jsonrpc": .string("2.0"), "id": id,
                               "error": .object(["code": .integer(-32601), "message": .string("Not here")])]))
            }
        }

        func messages() async -> AsyncStream<ACPRawFrame> { stream }

        func stop() async {
            stopped = true
            continuation.finish()
        }

        private func answer(_ id: JSONValue, _ result: JSONValue) {
            write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        }

        private func write(_ value: JSONValue) {
            continuation.yield(ACPRawFrame(value: value, data: Data()))
        }
    }
}
