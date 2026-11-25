import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The Yardlet MCP server reaches each harness through that harness's own per-session request,
/// and through the YHP wrappers the app actually routes every harness through.
@MainActor
final class AgentToolInjectionTests: XCTestCase {
    private let workspace = URL(filePath: "/tmp/agent-tool-workspace")

    private func temporaryDefaults(_ purpose: String) -> UserDefaults {
        SuggestionVolatileDefaults()
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
        XCTAssertEqual(codex?["required"], .bool(true),
                       "Marks yardlet-mcp required so Codex's lazy stdio startup does not skip live tool updates or drop readOnlyHint")
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
        for harness in [HarnessKind.openCode, .antigravityCLI, .kimiCode, .grokBuild, .hermes, .kiroCLI] {
            XCTAssertEqual(AgentToolInjectionRoute.route(for: harness), .acpSessionMCPServers, "\(harness)")
        }
        for harness in [HarnessKind.museCode, .pi, .cursorAgent] {
            XCTAssertNil(AgentToolInjectionRoute.route(for: harness), "\(harness) has no per-session route")
        }
    }

    func testTheAdaptersTheAppRoutesThroughAcceptTheServer() async {
        let registry = HarnessRegistry()
        let executable = URL(filePath: "/tmp/yardlet-agent-tool-routing-fixture")
        for harness in [HarnessKind.codex, .claudeCode, .openCode, .antigravityCLI, .kimiCode, .grokBuild, .hermes, .kiroCLI] {
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
        XCTAssertEqual(Array(with.suffix(36)), ["--chrome", "--allowedTools", "mcp__yardlet__spawn_task",
                                               "mcp__yardlet__dismiss_task", "mcp__yardlet__list_tasks",
                                               "mcp__yardlet__read_task", "mcp__yardlet__send_message_to_task",
                                               "mcp__yardlet__wait_tasks", "mcp__yardlet__create_task",
                                               "mcp__yardlet__run_agent", "mcp__yardlet__archive_task",
                                               "mcp__yardlet__list_projects", "mcp__yardlet__create_project",
                                               "mcp__yardlet__hide_project", "mcp__yardlet__show_project", "mcp__yardlet__list_accounts",
                                               "mcp__yardlet__list_personal_agents", "mcp__yardlet__read_personal_agent",
                                               "mcp__yardlet__read_personal_agent_thread",
                                               "mcp__yardlet__list_settings", "mcp__yardlet__update_setting",
                                               "mcp__yardlet__read_terminal", "mcp__yardlet__list_task_runs",
                                               "mcp__yardlet__show_widget",
                                               "mcp__yardlet__run_yardlet_script", "mcp__yardlet__call_connector_tool",
                                               "mcp__yardlet__browser_batch", "mcp__yardlet__list_scheduled_tasks",
                                               "mcp__yardlet__search_yardlet_tools", "mcp__yardlet__list_connector_tools",
                                               "mcp__yardlet__list_simulator_tools", "mcp__yardlet__simulator_list",
                                               "mcp__yardlet__simulator_screenshot", "mcp__yardlet__simulator_snapshot",
                                               "--mcp-config", file.path(percentEncoded: false)],
                       "The variadic flag goes last so nothing else is read as a config; the chip tools run unasked, "
                           + "and of the scheduled-task tools only the two that list")
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
            adapter: ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode"), transportFactory: { transport }),
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
        let adapter = ACPAdapter(kind: .kimiCode, executableURL: URL(filePath: "/tmp/kimi"), transportFactory: { transport })
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

        // A permission request on the agent's page is the agent's to close while it works; closing it ends the tab's wait.
        connections[0].eventHandler?(.permissionPrompt(tab: tab.id, prompt: BrowserPermissionPrompt(
            id: 12, origin: "https://example.com", permissions: ["notifications"]
        )))
        XCTAssertEqual(client.personWait(of: tab), BrowserPersonWait(kind: .permission, id: "permission-12", agentLed: true))
        XCTAssertEqual(first.closePermission()?.id, 12)
        XCTAssertEqual(connections[0].sent.last, .permissionResult(tab: tab.id, prompt: 12, result: .dismiss))
        XCTAssertNil(tab.permissionPrompt, "The panel's bar goes with the agent's answer")
        XCTAssertNil(client.personWait(of: tab))

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

    // MARK: - Antigravity connector gateway

    @MainActor
    private final class FakeConnectorTools: ConnectorToolProviding {
        var tools: [ToolJSON]
        var services: [String]
        var calls: [(name: String, arguments: ToolJSON)] = []

        init(tools: [ToolJSON], services: [String]) {
            self.tools = tools
            self.services = services
        }

        var offersTools: Bool { !tools.isEmpty }
        func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] { tools }
        func serviceNames(for context: ConnectorToolContext) -> [String] { services }
        func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
            guard tools.contains(where: { $0["name"]?.stringValue == name }) else { return nil }
            calls.append((name, arguments))
            return .text("ran \(name)")
        }
    }

    func testAntigravityUsesCompactConnectorGatewayWhileOtherHarnessesListRawConnectorTools() async throws {
        let connectorTools: [ToolJSON] = [
            .object([
                "name": .string("gmail_search_messages"),
                "description": .string("[Gmail] Search messages in a mailbox."),
                "inputSchema": .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])])])
            ]),
            .object([
                "name": .string("linear_list_issues"),
                "description": .string("[Linear] List issues in a workspace."),
                "inputSchema": .object(["type": .string("object"), "properties": .object(["team": .object(["type": .string("string")])])])
            ])
        ]
        let connectors = FakeConnectorTools(tools: connectorTools, services: ["Gmail", "Linear"])
        let broker = broker()
        broker.connectors = connectors
        // With MCP Code Mode off: in Auto, Antigravity gets Code Mode instead (`CodeModeToolTests`).
        broker.codeModeSetting = { .off }

        let agyTask = UUID()
        let agyLaunch = try XCTUnwrap(broker.agentToolServer(
            for: agyTask, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .antigravityCLI, nativeServers: [])
        ))
        let agyToken = try XCTUnwrap(agyLaunch.environment[AgentToolEnvironment.token])
        let agyListRaw = await broker.list(AgentToolCall(
            token: agyToken, session: agyTask.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let agyList = try XCTUnwrap(agyListRaw)
        let agyNames = Set(agyList.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(agyNames.contains(ConnectorGatewayToolCatalog.listTools))
        XCTAssertTrue(agyNames.contains(ConnectorGatewayToolCatalog.callTool))
        XCTAssertFalse(agyNames.contains("gmail_search_messages"))
        XCTAssertFalse(agyNames.contains("linear_list_issues"))
        let listDesc = agyList.tools.first { $0["name"]?.stringValue == ConnectorGatewayToolCatalog.listTools }?["description"]?.stringValue ?? ""
        XCTAssertTrue(listDesc.contains("Gmail") && listDesc.contains("Linear"), listDesc)

        // Discovery filters by service and exact tool name.
        let filtered = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: ConnectorGatewayToolCatalog.listTools,
            arguments: .object(["service": .string("gmail")])
        ))
        XCTAssertFalse(filtered.isError, filtered.text)
        XCTAssertTrue(filtered.text.contains("gmail_search_messages"), filtered.text)
        XCTAssertFalse(filtered.text.contains("linear_list_issues"), filtered.text)

        // Dispatch calls through ConnectorToolProviding with exact arguments.
        let called = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: ConnectorGatewayToolCatalog.callTool,
            arguments: .object([
                "tool": .string("gmail_search_messages"),
                "arguments": .object(["query": .string("from:alice")])
            ])
        ))
        XCTAssertFalse(called.isError, called.text)
        XCTAssertEqual(called.text, "ran gmail_search_messages")
        XCTAssertEqual(connectors.calls.count, 1)
        XCTAssertEqual(connectors.calls[0].name, "gmail_search_messages")
        XCTAssertEqual(connectors.calls[0].arguments["query"], .string("from:alice"))

        // Unknown connector tool suggests similar names from the underlying catalog.
        let unknown = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: ConnectorGatewayToolCatalog.callTool,
            arguments: .object(["tool": .string("gmail_missing")])
        ))
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("gmail_search_messages"), unknown.text)

        // Non-Antigravity harnesses still receive raw connector tools directly.
        let claudeTask = UUID()
        let claudeLaunch = try XCTUnwrap(broker.agentToolServer(
            for: claudeTask, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .claudeCode, nativeServers: [])
        ))
        let claudeToken = try XCTUnwrap(claudeLaunch.environment[AgentToolEnvironment.token])
        let claudeListRaw = await broker.list(AgentToolCall(
            token: claudeToken, session: claudeTask.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let claudeList = try XCTUnwrap(claudeListRaw)
        let claudeNames = Set(claudeList.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(claudeNames.contains("gmail_search_messages"))
        XCTAssertTrue(claudeNames.contains("linear_list_issues"))
        XCTAssertFalse(claudeNames.contains(ConnectorGatewayToolCatalog.listTools))

        // When no connectors are connected, Antigravity does not list the gateway tools.
        connectors.tools = []
        connectors.services = []
        let emptyListRaw = await broker.list(AgentToolCall(
            token: agyToken, session: agyTask.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let emptyList = try XCTUnwrap(emptyListRaw)
        let emptyNames = Set(emptyList.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertFalse(emptyNames.contains(ConnectorGatewayToolCatalog.listTools))
        XCTAssertFalse(emptyNames.contains(ConnectorGatewayToolCatalog.callTool))

        // Antigravity's launch environment stays identical when connected services change within
        // the same Yardlet run, so `agy` does not hash a second `yardlet_<hex>` server on resume.
        connectors.services = ["Gmail"]
        let beforeChange = try XCTUnwrap(broker.agentToolServer(
            for: agyTask, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .antigravityCLI, nativeServers: [])
        ))
        connectors.services = ["Gmail", "Linear", "Slack"]
        let afterChange = try XCTUnwrap(broker.agentToolServer(
            for: agyTask, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .antigravityCLI, nativeServers: [])
        ))
        XCTAssertEqual(beforeChange.environment, afterChange.environment)
        XCTAssertNil(afterChange.environment[AgentToolEnvironment.services])
    }

    /// A released token's `tools/list` request over `respond` receives an empty released list so a
    /// stale `yardlet-mcp` (such as one restored by `agy` on `session/load`) advertises zero tools
    /// and exits instead of falling back to the 45-tool built-in catalog.
    func testReleasedTokenToolsListReturnsEmptyReleasedListOverBrokerRespond() async throws {
        let broker = broker()
        let task = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(
            for: task, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .antigravityCLI, nativeServers: [])
        ))
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
        broker.releaseAgentTools(for: task)

        let call = AgentToolCall(token: token, session: task.uuidString, tool: "",
                                 arguments: .object([:]), method: AgentToolCall.listMethod)
        let replyData = await broker.respond(to: try JSONEncoder().encode(call))
        let decoded = try JSONDecoder().decode(AgentToolList.self, from: replyData)
        XCTAssertEqual(decoded, AgentToolList(tools: [], fingerprint: nil, released: true))
    }

    @MainActor
    private final class StubSuggestionHandler: TaskSuggestionToolHandling {
        func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult { .text("ok") }
    }

    @MainActor
    private final class StubSessionHandler: SessionToolHandling {
        func callSessionTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult { .text("ok") }
        func allowsBrowserFile(_ path: String, callerID: UUID) async -> Bool { false }
    }

    @MainActor
    private final class StubScheduleHandler: ScheduleToolHandling {
        func callScheduleTool(named name: String, arguments: ToolJSON, callerID: UUID,
                              origin: AgentToolCallOrigin) async -> AgentToolResult { .text("ok") }
    }

    @MainActor
    private final class StubSimulatorHandler: SimulatorToolHandling {
        var simulatorSwitchIsOn = true
        var simulatorPlatformIsUsable = true
        var calls: [(name: String, arguments: ToolJSON)] = []

        func callSimulatorTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
            calls.append((name, arguments))
            return .text("sim \(name)")
        }
    }

    /// Antigravity routes simulator tools through a compact 2-tool gateway and compacts core tool
    /// prose while keeping every structural schema constraint intact and leaving Claude Code and
    /// Codex untouched. With every Yardlet feature enabled, Antigravity's full serialized
    /// `tools/list` stays well below `agy`'s ~54 KB eager MCP budget.
    func testAntigravityCompactToolSurfaceFitsEagerBudgetAndPreservesFullSchemasForOtherHarnesses() async throws {
        let broker = broker()
        let suggestions = StubSuggestionHandler()
        let sessions = StubSessionHandler()
        let schedules = StubScheduleHandler()
        let simulators = StubSimulatorHandler()
        let vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([:]),
            repository: InMemoryVaultRepository(items: [VaultItem(name: "Example", sites: ["example.com"], username: "ada")]),
            hmac: MacVault.hmac,
            isAllowedBuild: true,
            confirm: { _ in true },
            defaults: .vaultTests()
        ))
        let connectors = FakeConnectorTools(
            tools: [
                .object([
                    "name": .string("gmail_search_messages"),
                    "description": .string("[Gmail] Search messages."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
                ])
            ],
            services: ["Gmail", "Google Calendar", "Google Drive", "Slack", "Linear", "Notion", "GitHub", "Stripe", "Mail (IMAP)"]
        )
        broker.suggestions = suggestions
        broker.sessions = sessions
        broker.schedules = schedules
        broker.simulators = simulators
        broker.sharesTerminal = { true }
        broker.vault = vault
        broker.connectors = connectors
        broker.codeModeSetting = { .off }

        let agyTask = UUID()
        let agyLaunch = try XCTUnwrap(broker.agentToolServer(
            for: agyTask, workspaceRoots: [],
            connectorScope: ConnectorTaskScope(harness: .antigravityCLI, nativeServers: [])
        ))
        let agyToken = try XCTUnwrap(agyLaunch.environment[AgentToolEnvironment.token])
        let agyList = try XCTUnwrapAsync(await broker.list(AgentToolCall(
            token: agyToken, session: agyTask.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
        )))

        // Simulator tools go through the 2-tool gateway on Antigravity.
        let agyNames = Set(agyList.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(agyNames.contains(SimulatorGatewayToolCatalog.listTools))
        XCTAssertTrue(agyNames.contains(SimulatorGatewayToolCatalog.callTool))
        XCTAssertTrue(agyNames.contains(VaultToolCatalog.fillCredential))
        XCTAssertTrue(agyNames.contains(WidgetToolCatalog.showWidget))
        XCTAssertTrue(agyNames.contains(TerminalToolCatalog.readTerminal))
        XCTAssertTrue(agyNames.contains(ConnectorGatewayToolCatalog.listTools))
        XCTAssertFalse(agyNames.contains(SimulatorToolCatalog.list))
        XCTAssertFalse(agyNames.contains(SimulatorToolCatalog.attach))

        // Gateway discovery returns all 10 simulator schemas; dispatch validates and forwards.
        let simListed = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: SimulatorGatewayToolCatalog.listTools, arguments: .object([:])
        ))
        XCTAssertFalse(simListed.isError, simListed.text)
        for name in SimulatorToolCatalog.tools.map(\.name) {
            XCTAssertTrue(simListed.text.contains("\"\(name)\""), "Missing \(name) in simulator gateway list")
        }
        let invalidSwipe = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: SimulatorGatewayToolCatalog.callTool,
            arguments: .object(["tool": .string(SimulatorToolCatalog.swipe), "arguments": .object(["x": .integer(1)])])
        ))
        XCTAssertEqual(invalidSwipe.failure?.kind, .invalidArguments)
        XCTAssertTrue(simulators.calls.isEmpty)

        let simCalled = await broker.handle(AgentToolCall(
            token: agyToken, session: agyTask.uuidString,
            tool: SimulatorGatewayToolCatalog.callTool,
            arguments: .object(["tool": .string(SimulatorToolCatalog.attach), "arguments": .object(["device": .string("iPhone 17")])])
        ))
        XCTAssertFalse(simCalled.isError, simCalled.text)
        XCTAssertEqual(simCalled.text, "sim simulator_attach")
        XCTAssertEqual(simulators.calls.count, 1)
        XCTAssertEqual(simulators.calls[0].name, SimulatorToolCatalog.attach)
        XCTAssertEqual(simulators.calls[0].arguments["device"], .string("iPhone 17"))

        // Claude Code and Codex keep every full description and all 10 direct simulator tools untouched.
        for harness in [HarnessKind.claudeCode, .codex] {
            let task = UUID()
            let launch = try XCTUnwrap(broker.agentToolServer(
                for: task, workspaceRoots: [],
                connectorScope: ConnectorTaskScope(harness: harness, nativeServers: [])
            ))
            let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
            let list = try XCTUnwrapAsync(await broker.list(AgentToolCall(
                token: token, session: task.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
            )))
            let byName = Dictionary(uniqueKeysWithValues: list.tools.compactMap { entry in
                entry["name"]?.stringValue.map { ($0, entry) }
            })
            XCTAssertEqual(byName[SessionToolCatalog.createTask], SessionToolCatalog.definition(named: SessionToolCatalog.createTask)?.json,
                           "\(harness.rawValue) must keep uncompacted full tool definitions")
            XCTAssertEqual(byName[AgentToolCatalog.snapshot], AgentToolCatalog.definition(named: AgentToolCatalog.snapshot)?.json)
            for name in SimulatorToolCatalog.tools.map(\.name) {
                XCTAssertNotNil(byName[name], "\(harness.rawValue) lists direct \(name)")
            }
            XCTAssertNil(byName[SimulatorGatewayToolCatalog.listTools])
        }

        // Compact projection preserves every structural JSON Schema constraint and annotation.
        let fullCoreTools = AgentToolCatalog.browserTools + [VaultToolCatalog.tool] + TaskSuggestionToolCatalog.tools
            + [WidgetToolCatalog.tool] + SessionToolCatalog.tools + SettingsToolCatalog.tools
            + [TerminalToolCatalog.tool] + ScheduleToolCatalog.tools
        let agyByName = Dictionary(uniqueKeysWithValues: agyList.tools.compactMap { entry in
            entry["name"]?.stringValue.map { ($0, entry) }
        })
        for full in fullCoreTools {
            let compacted = try XCTUnwrap(agyByName[full.name], "Missing \(full.name) in Antigravity list")
            let fullJSON = full.json
            XCTAssertEqual(compacted["annotations"], fullJSON["annotations"], full.name)
            XCTAssertEqual(compacted["_meta"], fullJSON["_meta"], full.name)
            XCTAssertEqual(Self.stripSchemaDescriptions(compacted["inputSchema"] ?? .null),
                           Self.stripSchemaDescriptions(fullJSON["inputSchema"] ?? .null),
                           "Compacting \(full.name) must not alter any structural JSON Schema constraint")
        }

        // Budget pin: full serialized `tools/list` payload and `agy` declaration payload stay
        // comfortably under `agy`'s ~54 KB eager cap with every feature enabled.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fullPayloadBytes = try encoder.encode(ToolJSON.object(["tools": .array(agyList.tools)])).count
        let agyDeclarations: [ToolJSON] = agyList.tools.map { entry in
            .object([
                "name": entry["name"] ?? .null,
                "description": entry["description"] ?? .null,
                "parameters": entry["inputSchema"] ?? .object([:])
            ])
        }
        let agyDeclarationBytes = try agyDeclarations.reduce(0) { total, item in
            total + (try encoder.encode(item)).count
        }
        XCTAssertLessThan(fullPayloadBytes, 44_000,
                          "Antigravity full tools/list payload (\(fullPayloadBytes) B) must stay below 44,000 B")
        XCTAssertLessThan(agyDeclarationBytes, 38_000,
                          "Antigravity declaration payload (\(agyDeclarationBytes) B) must stay well below agy's ~54 KB eager cap")

        // In Auto, the default, Code Mode takes the connector gateway's place and fits the same budget.
        broker.codeModeSetting = { .auto }
        let autoList = try XCTUnwrapAsync(await broker.list(AgentToolCall(
            token: agyToken, session: agyTask.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod
        )))
        let autoNames = Set(autoList.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(autoNames.contains(CodeModeToolCatalog.runScript), CodeModePreference.isSupported)
        XCTAssertEqual(autoNames.contains(ConnectorGatewayToolCatalog.listTools), !CodeModePreference.isSupported)
        let autoPayloadBytes = try encoder.encode(ToolJSON.object(["tools": .array(autoList.tools)])).count
        XCTAssertLessThan(autoPayloadBytes, 44_000,
                          "Antigravity tools/list payload in Auto (\(autoPayloadBytes) B) must stay below 44,000 B")
    }

    private static func stripSchemaDescriptions(_ value: ToolJSON) -> ToolJSON {
        switch value {
        case .object(let fields):
            var cleaned: [String: ToolJSON] = [:]
            for (key, child) in fields where key != "description" {
                cleaned[key] = stripSchemaDescriptions(child)
            }
            return .object(cleaned)
        case .array(let items):
            return .array(items.map(stripSchemaDescriptions))
        default:
            return value
        }
    }
}
