import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The Yardlet MCP server reaches each harness through that harness's own per-session request,
/// and through the YHP wrappers the app actually routes every harness through.
@MainActor
final class AgentToolInjectionTests: XCTestCase {
    private let workspace = URL(filePath: "/tmp/agent-tool-workspace")

    /// Preferences held in memory. A suite on disk leaves a file in ~/Library/Preferences even
    /// after its domain is removed, since the preferences daemon writes the emptied domain back.
    private final class VolatileDefaults: UserDefaults {
        private var values: [String: Any] = [:]

        init() { super.init(suiteName: nil)! }

        override func object(forKey defaultName: String) -> Any? { values[defaultName] }
        override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
        override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
        override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
        override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    }

    private func temporaryDefaults(_ purpose: String) -> UserDefaults {
        VolatileDefaults()
    }

    private func launch(session: UUID = UUID(), directory: URL? = nil) -> AgentToolServerLaunch {
        AgentToolServerLaunch(
            command: "/Applications/Yardlet.app/Contents/Helpers/yardlet-mcp",
            environment: [
                AgentToolEnvironment.endpoint: "/tmp/Yardlet-tools-1/tools.sock",
                AgentToolEnvironment.token: "secret-\(session.uuidString.prefix(4))",
                AgentToolEnvironment.session: session.uuidString
            ],
            privateDirectory: directory
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Shapes

    func testEachHarnessGetsTheServerInItsOwnConfigurationShape() {
        let server = launch()
        XCTAssertEqual(server.claudeConfig["mcpServers"]?["yardlet"]?["type"], .string("stdio"))
        XCTAssertEqual(server.claudeConfig["mcpServers"]?["yardlet"]?["command"], .string(server.command))
        XCTAssertEqual(server.claudeConfig["mcpServers"]?["yardlet"]?["env"]?[AgentToolEnvironment.token],
                       .string(server.environment[AgentToolEnvironment.token]!))

        let codex = server.codexConfig["mcp_servers"]?["yardlet"]
        XCTAssertEqual(codex?["command"], .string(server.command))
        XCTAssertEqual(codex?["args"], .array([]))
        XCTAssertEqual(codex?["tool_timeout_sec"], .integer(1_800))
        XCTAssertNil(codex?["tools"], "Whether Codex asks follows the task's approval setting, not a per-tool mode of Yardlet's")
        XCTAssertEqual(codex?["env"]?[AgentToolEnvironment.session], .string(server.environment[AgentToolEnvironment.session]!))
        XCTAssertEqual(server.codexConfig.objectValue?.keys.sorted(), ["mcp_servers"],
                       "The override adds one entry and touches no other setting")

        XCTAssertEqual(server.acpServer["name"], .string("yardlet"))
        XCTAssertEqual(server.acpServer["args"], .array([]))
        XCTAssertEqual(server.acpServer["env"]?.arrayValue?.compactMap { $0["name"]?.stringValue },
                       [AgentToolEnvironment.session, AgentToolEnvironment.endpoint, AgentToolEnvironment.token],
                       "ACP takes the environment as a name/value list, here in name order")
    }

    func testOnlyClaudeCodexAndACPHaveARoute() {
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .claudeCode), .claudeMCPConfig)
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .codex), .codexThreadConfig)
        for harness in [HarnessKind.openCode, .kimiCode, .grokBuild, .hermes] {
            XCTAssertEqual(AgentToolInjectionRoute.route(for: harness), .acpSessionMCPServers, "\(harness)")
        }
        for harness in [HarnessKind.museCode, .pi, .cursorAgent, .antigravityCLI] {
            XCTAssertNil(AgentToolInjectionRoute.route(for: harness), "\(harness) has no per-session route")
        }
    }

    func testTheAdaptersTheAppRoutesThroughAcceptTheServer() async {
        let registry = HarnessRegistry()
        let executable = URL(filePath: "/tmp/yardlet-agent-tool-routing-fixture")
        for harness in [HarnessKind.codex, .claudeCode, .openCode, .kimiCode, .grokBuild, .hermes] {
            let routed = await registry.adapter(for: harness, executableURL: executable)
            XCTAssertNotNil(routed as? any HarnessAgentToolConfiguring,
                            "\(harness) reaches the app through a wrapper that has to carry the server")
        }
    }

    // MARK: - Claude

    func testClaudeReadsTheServerFromAPrivateConfigFileGivenLast() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let server = launch(session: sessionID, directory: directory)
        let file = try server.writeClaudeConfig(for: sessionID)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "The token is readable by the user only")
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(written, server.claudeConfig)

        let without = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "s", workspaceURL: workspace, resumesExistingSession: false
        ))
        XCTAssertFalse(without.contains("--mcp-config"))
        let with = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "s", workspaceURL: workspace, resumesExistingSession: true, chromeIntegration: true,
            agentToolConfigPath: file.path(percentEncoded: false)
        ))
        XCTAssertEqual(Array(with.suffix(18)), ["--chrome", "--allowedTools", "mcp__yardlet__spawn_task",
                                               "mcp__yardlet__dismiss_task", "mcp__yardlet__list_tasks",
                                               "mcp__yardlet__read_task", "mcp__yardlet__send_message_to_task",
                                               "mcp__yardlet__wait_tasks", "mcp__yardlet__create_task",
                                               "mcp__yardlet__run_agent", "mcp__yardlet__archive_task",
                                               "mcp__yardlet__list_projects", "mcp__yardlet__hide_project",
                                               "mcp__yardlet__show_project", "mcp__yardlet__list_accounts",
                                               "mcp__yardlet__list_task_runs",
                                               "--mcp-config", file.path(percentEncoded: false)],
                       "The variadic flag goes last so nothing else is read as a config; the chip tools run unasked, "
                           + "and of the scheduled-task tools only list_task_runs, as in the Claude app")
        XCTAssertFalse(without.contains("--allowedTools"), "Without the server nothing is allowed ahead")
        XCTAssertFalse(with.contains("--strict-mcp-config"), "The user's own MCP servers keep loading")
        XCTAssertFalse(with.contains { $0.contains(server.environment[AgentToolEnvironment.token]!) },
                       "The token stays out of the process arguments")
    }

    func testTheClaudeRouteTheAppShipsLaunchesWithTheServer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeClaudeTransport()
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let sessionID = UUID()
        let configurable = try XCTUnwrap(routed as? any HarnessAgentToolConfiguring)
        await configurable.setAgentToolServer(launch(session: sessionID, directory: directory), for: sessionID)
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(localSessionID: sessionID, workspaceURL: workspace, initialPrompt: nil)
        )
        let configuration = await transport.configuration
        let path = try XCTUnwrap(configuration?.agentToolConfigPath, "The server has to survive the protocol wrapper")
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: path)))
        XCTAssertEqual(written["mcpServers"]?["yardlet"]?["env"]?[AgentToolEnvironment.session], .string(sessionID.uuidString))
        await routed.close(handle)

        let offTransport = FakeClaudeTransport()
        let off: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in offTransport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        await (off as? any HarnessAgentToolConfiguring)?.setAgentToolServer(nil, for: sessionID)
        _ = try await off.createSession(
            CreateHarnessSessionRequest(localSessionID: sessionID, workspaceURL: workspace, initialPrompt: nil)
        )
        let offConfiguration = await offTransport.configuration
        XCTAssertNil(offConfiguration?.agentToolConfigPath, "Without a server the launch is unchanged")
    }

    // MARK: - Codex

    func testTheCodexRouteTheAppShipsSendsTheServerOnStartResumeAndFork() async throws {
        func routedCodex(_ transport: FakeCodexTransport) -> YHPCodexCompatibilityAdapter {
            YHPCodexCompatibilityAdapter(
                adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
                manifest: HarnessProtocolCompatibilityManifest.codex()
            )
        }
        func session(in method: String, of requests: [CodexRPCRequest]) -> String? {
            requests.first { $0.method == method }?
                .params["config"]?["mcp_servers"]?["yardlet"]?["env"]?[AgentToolEnvironment.session]?.stringValue
        }
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-a")])])],
            "thread/fork": [.object(["thread": .object(["id": .string("thread-b")])])]
        ])
        let routed = routedCodex(transport)
        let source = UUID()
        let fork = UUID()
        await routed.setAgentToolServer(launch(session: source), for: source)
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(localSessionID: source, workspaceURL: workspace, initialPrompt: nil)
        )
        await routed.setAgentToolServer(launch(session: fork), for: fork)
        _ = try? await routed.fork(handle, newLocalSessionID: fork)
        let requests = await transport.requests
        XCTAssertEqual(session(in: "thread/start", of: requests), source.uuidString)
        XCTAssertEqual(session(in: "thread/fork", of: requests), fork.uuidString, "A fork is its own task with its own tab")

        let resumeTransport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object(["thread": .object(["id": .string("thread-a")])])]
        ])
        let resumer = routedCodex(resumeTransport)
        let resumed = UUID()
        await resumer.setAgentToolServer(launch(session: resumed), for: resumed)
        _ = try? await resumer.resumeSession(providerSessionID: "thread-a", localSessionID: resumed, workspaceURL: workspace)
        let resumeRequests = await resumeTransport.requests
        XCTAssertEqual(session(in: "thread/resume", of: resumeRequests), resumed.uuidString)

        let plain = CodexProtocol.startThread(id: 1, workspaceURL: workspace)
        XCTAssertNil(plain.params["config"], "Without a server the request is what it always was")
    }

    // MARK: - ACP

    private actor MCPRecordingACPTransport: ACPTransport {
        private let channel = AsyncStream<ACPRawFrame>.makeStream()
        let mcpCapabilities: JSONValue?
        private(set) var requests: [JSONValue] = []

        init(mcpCapabilities: JSONValue? = nil) { self.mcpCapabilities = mcpCapabilities }

        func start(_ configuration: ACPLaunchConfiguration) {}
        func send(_ value: JSONValue) {}
        func messages() -> AsyncStream<ACPRawFrame> { channel.stream }
        func stop() { channel.continuation.finish() }

        func request(_ value: JSONValue, id: Int64) throws -> JSONValue {
            requests.append(value)
            switch value["method"]?.stringValue {
            case "initialize":
                var capabilities: [String: JSONValue] = ["loadSession": .bool(true)]
                if let mcpCapabilities { capabilities["mcpCapabilities"] = mcpCapabilities }
                return .object(["protocolVersion": .integer(1), "agentCapabilities": .object(capabilities)])
            case "session/new":
                return .object(["sessionId": .string("acp-1")])
            default:
                return .object([:])
            }
        }

        func servers(in method: String) -> JSONValue? {
            requests.first { $0["method"]?.stringValue == method }?["params"]?["mcpServers"]
        }
    }

    func testTheACPRouteTheAppShipsSendsTheServerOnNewAndLoad() async throws {
        let transport = MCPRecordingACPTransport(mcpCapabilities: .object(["http": .bool(false), "sse": .bool(false)]))
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.acp(.openCode)
        )
        let configurable = try XCTUnwrap(routed as? any HarnessAgentToolConfiguring)
        let created = UUID()
        let loaded = UUID()
        await configurable.setAgentToolServer(launch(session: created), for: created)
        await configurable.setAgentToolServer(launch(session: loaded), for: loaded)
        _ = try await routed.createSession(CreateHarnessSessionRequest(localSessionID: created, workspaceURL: workspace, initialPrompt: nil))
        _ = try await routed.resumeSession(providerSessionID: "acp-0", localSessionID: loaded, workspaceURL: workspace)

        let newServers = await transport.servers(in: "session/new")
        XCTAssertEqual(newServers, .array([launch(session: created).acpServer]))
        let loadServers = await transport.servers(in: "session/load")
        XCTAssertEqual(loadServers?.arrayValue?.first?["env"]?.arrayValue?.first { $0["name"] == .string(AgentToolEnvironment.session) }?["value"],
                       .string(loaded.uuidString))
    }

    func testAnACPAgentThatTurnsDownStdioServersGetsNone() async throws {
        XCTAssertTrue(ACPProtocol.acceptsStdioMCPServers(initializeResult: .object(["agentCapabilities": .object([:])])),
                      "ACP makes stdio servers mandatory, so silence means yes")
        let transport = MCPRecordingACPTransport(mcpCapabilities: .object(["stdio": .bool(false)]))
        let adapter = ACPAdapter(kind: .kimiCode, executableURL: URL(filePath: "/tmp/kimi"), transport: transport)
        let sessionID = UUID()
        await adapter.setAgentToolServer(launch(session: sessionID), for: sessionID)
        _ = try await adapter.createSession(CreateHarnessSessionRequest(localSessionID: sessionID, workspaceURL: workspace, initialPrompt: nil))
        let servers = await transport.servers(in: "session/new")
        XCTAssertEqual(servers, .array([]))
    }

    // MARK: - Broker and setting

    private func broker(enabled: Bool = true, executable: URL? = URL(filePath: "/bin/sh"),
                        page: BrowserAgentPage? = nil) -> AgentToolBroker {
        let page = page ?? BrowserAgentPage(cdp: ScriptedCDP())
        return AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: executable,
                endpoint: "/tmp/Yardlet-tools-test/tools.sock",
                privateDirectory: URL(filePath: "/tmp/Yardlet-tools-test"),
                isEnabled: { enabled }
            ),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in page })
        )
    }

    func testTheSettingAndAMissingServerExecutableMeanNoInjection() {
        XCTAssertNil(broker(enabled: false).agentToolServer(for: UUID(), workspaceRoots: []), "Turned off, the next session starts without it")
        XCTAssertNil(broker(executable: URL(filePath: "/nonexistent/yardlet-mcp")).agentToolServer(for: UUID(), workspaceRoots: []))
        let defaults = temporaryDefaults("AgentToolPreference")
        XCTAssertTrue(AgentToolPreference.isEnabled(in: defaults), "On unless the user turns it off")
        defaults.set(false, forKey: AgentToolPreference.browserToolsKey)
        XCTAssertFalse(AgentToolPreference.isEnabled(in: defaults))
    }

    /// Each injection makes sure the endpoint listens (the platform starts it once, and again when its socket is
    /// gone), and a failed start leaves the task without tools.
    func testEachInjectionChecksTheEndpointAndAFailedStartLeavesTheTaskWithoutTools() {
        let failing = broker()
        failing.startEndpoint = { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertNil(failing.agentToolServer(for: UUID(), workspaceRoots: []))

        let working = broker()
        var starts = 0
        working.startEndpoint = { starts += 1 }
        let first = UUID()
        let a = working.agentToolServer(for: first, workspaceRoots: [])
        let b = working.agentToolServer(for: first, workspaceRoots: [])
        _ = working.agentToolServer(for: UUID(), workspaceRoots: [])
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(a?.environment[AgentToolEnvironment.appProcess], String(ProcessInfo.processInfo.processIdentifier),
                       "The server can tell whether the app run that started it ended")
        XCTAssertEqual(a?.environment[AgentToolEnvironment.token], b?.environment[AgentToolEnvironment.token],
                       "A task keeps one token for the app run, so a server kept across a resume still works")
        XCTAssertEqual(a?.environment[AgentToolEnvironment.token]?.count, 64)
    }

    func testACallRunsOnlyWithItsOwnTasksToken() async throws {
        let cdp = ScriptedCDP()
        let broker = broker(page: BrowserAgentPage(cdp: cdp))
        let taskA = UUID()
        let taskB = UUID()
        let tokenA = try XCTUnwrap(broker.agentToolServer(for: taskA, workspaceRoots: [])?.environment[AgentToolEnvironment.token])
        let tokenB = try XCTUnwrap(broker.agentToolServer(for: taskB, workspaceRoots: [])?.environment[AgentToolEnvironment.token])
        XCTAssertNotEqual(tokenA, tokenB)

        for (token, session) in [("wrong", taskA.uuidString), (tokenB, taskA.uuidString), (tokenA, "not-a-uuid"), (tokenA, UUID().uuidString)] {
            let refused = await broker.handle(AgentToolCall(token: token, session: session, tool: "browser_snapshot", arguments: .object([:])))
            XCTAssertTrue(refused.isError)
            XCTAssertTrue(refused.text.contains("does not recognise this task's tool token"), refused.text)
        }
        XCTAssertTrue(cdp.sent.isEmpty, "A refused call never reaches the browser")

        let accepted = await broker.handle(AgentToolCall(token: tokenA, session: taskA.uuidString, tool: "browser_console_messages", arguments: .object([:])))
        XCTAssertFalse(accepted.isError, accepted.text)

        broker.releaseAgentTools(for: taskA)
        let released = await broker.handle(AgentToolCall(token: tokenA, session: taskA.uuidString, tool: "browser_snapshot", arguments: .object([:])))
        XCTAssertTrue(released.isError, "An archived task's token stops working")

        let garbled = await broker.respond(to: Data("{".utf8))
        let decoded = try JSONDecoder().decode(AgentToolResult.self, from: garbled)
        XCTAssertTrue(decoded.isError)
    }

    func testTheSocketRefusesACallWithAnotherTasksTokenEndToEnd() async throws {
        let broker = broker()
        let directory = FileManager.default.temporaryDirectory.appending(path: "ytb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        let listener = try UnixSocketListener(path: path) { body, peer in await broker.respond(to: body, peer: peer) }
        defer { listener.stop() }
        let taskA = UUID()
        let server = try XCTUnwrap(broker.agentToolServer(for: taskA, workspaceRoots: []))
        var environment = server.environment
        environment[AgentToolEnvironment.endpoint] = path
        let good = await UnixSocketToolInvoker(environment: environment).call(tool: "browser_console_messages", arguments: .object([:]))
        XCTAssertFalse(good.isError, good.text)
        environment[AgentToolEnvironment.token] = String(repeating: "0", count: 64)
        let forged = await UnixSocketToolInvoker(environment: environment).call(tool: "browser_console_messages", arguments: .object([:]))
        XCTAssertTrue(forged.isError)
        XCTAssertTrue(forged.text.contains("does not recognise"), forged.text)

        // The right token from a process that is not under the task's harness is refused too.
        environment = server.environment
        environment[AgentToolEnvironment.endpoint] = path
        var asked: [(UUID, Int32?)] = []
        broker.callerProcessCheck = { session, process in
            asked.append((session, process))
            return false
        }
        let foreign = await UnixSocketToolInvoker(environment: environment).call(tool: "browser_console_messages", arguments: .object([:]))
        XCTAssertTrue(foreign.isError)
        XCTAssertTrue(foreign.text.contains("did not come from the tool server"), foreign.text)
        XCTAssertEqual(asked.first?.0, taskA)
        XCTAssertEqual(asked.first?.1, ProcessInfo.processInfo.processIdentifier, "The check gets the caller's process")
        broker.callerProcessCheck = { _, _ in true }
        let admitted = await UnixSocketToolInvoker(environment: environment).call(tool: "browser_console_messages", arguments: .object([:]))
        XCTAssertFalse(admitted.isError, admitted.text)
    }

    // MARK: - AppModel

    private actor RecordingToolAdapter: HarnessAdapter, HarnessAgentToolConfiguring {
        nonisolated let kind: HarnessKind
        private(set) var configured: [UUID: AgentToolServerLaunch?] = [:]

        init(kind: HarnessKind) { self.kind = kind }

        func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) {
            configured[localSessionID] = .some(server)
        }

        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }

        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: "stub-\(request.localSessionID)", workspaceURL: request.workspaceURL)
        }

        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                 workspaceURL: workspaceURL)
        }

        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
        func close(_ session: HarnessSessionHandle) async {}
    }

    private final class RecordingLaunches: AgentToolLaunchProviding {
        var enabled = true
        private(set) var requested: [UUID] = []
        private(set) var roots: [UUID: [URL]] = [:]
        private(set) var released: [UUID] = []

        func agentToolServer(for localSessionID: UUID, workspaceRoots: [URL],
                             connectorScope: ConnectorTaskScope?) -> AgentToolServerLaunch? {
            requested.append(localSessionID)
            roots[localSessionID] = workspaceRoots
            guard enabled else { return nil }
            return AgentToolServerLaunch(command: "/tmp/yardlet-mcp", environment: [AgentToolEnvironment.session: localSessionID.uuidString])
        }

        func releaseAgentTools(for localSessionID: UUID) { released.append(localSessionID) }
    }

    private func model(adapter: RecordingToolAdapter) -> AppModel {
        AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: temporaryDefaults("AgentTools")),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
    }

    func testStartingATaskHandsItsAdapterTheServerOnlyWhereTheHarnessHasARoute() async throws {
        let claude = RecordingToolAdapter(kind: .claudeCode)
        let claudeModel = model(adapter: claude)
        let launches = RecordingLaunches()
        claudeModel.agentTools = launches
        let created = await claudeModel.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                      runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Tools")
        let session = try XCTUnwrap(created)
        let configured = await claude.configured
        XCTAssertEqual(configured[session.id]??.environment[AgentToolEnvironment.session], session.id.uuidString)
        XCTAssertEqual(launches.roots[session.id], [session.workspaceURL], "File uploads are limited to the task's folders")

        launches.enabled = false
        let second = await claudeModel.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                     runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Off")
        let secondID = try XCTUnwrap(second?.id)
        let afterOff = await claude.configured
        XCTAssertEqual(afterOff[secondID], .some(nil), "With the setting off the session starts without the server")
        await claudeModel.shutdown()

        let pi = RecordingToolAdapter(kind: .pi)
        let piModel = model(adapter: pi)
        let piLaunches = RecordingLaunches()
        piModel.agentTools = piLaunches
        let piSession = await piModel.createSession(harness: .pi, workspaceURL: workspace,
                                                    runtimeExecutableURL: URL(filePath: "/tmp/pi"), title: "Pi")
        let piID = try XCTUnwrap(piSession?.id)
        let piConfigured = await pi.configured
        XCTAssertEqual(piConfigured[piID], .some(nil))
        XCTAssertTrue(piLaunches.requested.isEmpty, "No token is issued for a harness that cannot take the server")
        await piModel.shutdown()
    }

    // MARK: - Tabs

    private final class FakeHostConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() { eventHandler?(.terminated(reason: "signal 15")) }
    }

    func testTheAgentDrivesTheTasksOwnTabAndKeepsItAliveWhileItWorks() throws {
        var connections: [FakeHostConnection] = []
        let client = BrowserHostClient(idleGrace: .seconds(60)) {
            let connection = FakeHostConnection()
            connections.append(connection)
            return connection
        }
        let tabs = BrowserAgentTabs { client }
        let taskA = UUID()
        let taskB = UUID()
        let first = try tabs.page(for: taskA, tabID: nil)
        let tab = try XCTUnwrap(client.tab(forSession: taskA), "The agent's tab is the task's tab, the one its panel shows")
        var activity = 0
        tab.onAgentActivity = { activity += 1 }
        let again = try tabs.page(for: taskA, tabID: nil)
        XCTAssertTrue(first === again, "A task keeps its tab")
        XCTAssertEqual(activity, 1, "Every tool call tells the host the agent is using the tab")
        _ = try tabs.page(for: taskB, tabID: nil)
        XCTAssertEqual(client.openTabCount, 2)
        XCTAssertEqual(connections.count, 1, "Tabs share the one browser host")
        guard case .open(_, let url, let viewport, _) = connections[0].sent.first else {
            return XCTFail("No tab was opened")
        }
        XCTAssertEqual(url, "about:blank")
        XCTAssertEqual(viewport, .offscreenDefault, "Opened in the background, without a panel")

        // Dialogs reach the tools through an observer, whoever holds the panel's event handler.
        tab.eventHandler = { _ in }
        connections[0].eventHandler?(.javaScriptDialog(tab: tab.id, dialog: BrowserJavaScriptDialog(
            id: 7, kind: .confirm, message: "Leave?", defaultPrompt: "", origin: "https://example.com", isReload: false
        )))
        XCTAssertEqual(first.dialog?.id, 7)
        XCTAssertEqual(first.answerDialog(accept: true, text: nil)?.id, 7)
        XCTAssertEqual(connections[0].sent.last, .javaScriptDialogResult(tab: tab.id, dialog: 7, accepted: true, text: nil))

        connections[0].eventHandler?(.terminated(reason: "signal 9"))
        let reopened = try tabs.page(for: taskA, tabID: nil)
        XCTAssertFalse(reopened === first, "After the host ended, the next call opens a fresh tab")
        XCTAssertEqual(connections.count, 2)

        tabs.closeAll(for: taskA)
        XCTAssertNil(client.tab(forSession: taskA), "An archived task's tab closes")

        let noEngine = BrowserAgentTabs { nil }
        XCTAssertThrowsError(try noEngine.page(for: taskA, tabID: nil)) { error in
            XCTAssertTrue((error as? BrowserAgentToolError)?.message.contains("no browser engine") == true)
        }
    }
}
