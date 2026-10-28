import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A running task learns of changed connector tools: the Yardlet MCP server announces
/// `listChanged`, asks the app to wait for a change (`tools/watch`), and tells its client
/// `notifications/tools/list_changed`; the app answers only between the task's turns. Claude Code
/// lists again when told (2.1.304, checked against a fake model endpoint: the next request has the
/// new tools); Codex 0.163 only logs it, so its tasks follow when they are next opened.
@MainActor
final class ConnectorLiveToolsTests: XCTestCase {
    // MARK: - The MCP server, with a fake client

    func testTheServerTellsItsClientWhenTheAppSaysTheListChangedAndOnceUntilTheClientListsAgain() async throws {
        let app = FakeApp()
        let client = FakeMCPClient(relists: false)
        await client.connect(MCPServer(version: "1", invoker: app))
        let initialized = await client.initialize()
        XCTAssertEqual(initialized["result"]?["capabilities"]?["tools"]?["listChanged"], .bool(true))
        try await Task.sleep(for: .milliseconds(150))
        let askedBeforeListing = await app.askedAbout
        XCTAssertTrue(askedBeforeListing.isEmpty, "Nothing is watched before the client lists")

        let first = await client.list()
        XCTAssertEqual(first, ["tool_1"])
        // The app's hold runs out a few times with nothing to tell; the server asks again each time.
        try await waitUntil { await app.askedAbout.count >= 2 }
        let asked = await app.askedAbout
        XCTAssertGreaterThanOrEqual(asked.count, 2, "\(asked)")
        XCTAssertTrue(asked.allSatisfy { $0 == FakeApp.fingerprint(1) }, "It asks about the list its client has")
        let quiet = await client.listChangedCount
        XCTAssertEqual(quiet, 0)

        await app.change()
        let told = await eventually { await client.listChangedCount == 1 }
        XCTAssertTrue(told)
        // The client has not listed again (Codex only logs the notification): it is told once.
        await app.change()
        try await Task.sleep(for: .milliseconds(400))
        let toldOnce = await client.listChangedCount
        XCTAssertEqual(toldOnce, 1)

        let relisted = await client.list()
        XCTAssertEqual(relisted, ["tool_1", "tool_2", "tool_3"])
        await app.change()
        let toldAgain = await eventually { await client.listChangedCount == 2 }
        XCTAssertTrue(toldAgain, "After listing again, the next change is told too")
        let lastAsked = await app.askedAbout.last
        XCTAssertEqual(lastAsked, FakeApp.fingerprint(3))
        await client.close()
    }

    func testAToolCallRunningWhenTheListChangesStillAnswers() async throws {
        let app = FakeApp()
        let client = FakeMCPClient(relists: true)
        await client.connect(MCPServer(version: "1", invoker: app))
        _ = await client.initialize()
        _ = await client.list()
        try await Task.sleep(for: .milliseconds(80))
        async let call = client.request("tools/call", .object(["name": .string("slow"), "arguments": .object([:])]))
        try await Task.sleep(for: .milliseconds(100))
        await app.change()
        let reply = await call
        XCTAssertEqual(reply["result"]?["content"]?.arrayValue?.first?["text"], .string("ran slow"))
        XCTAssertEqual(reply["result"]?["isError"], .bool(false))
        let relisted = await eventually { await client.tools == ["tool_1", "tool_2"] }
        XCTAssertTrue(relisted, "The client that follows the notification lists the new tools")
        await client.close()
    }

    func testWithoutTheAppTheServerListsItsOwnToolsAndSaysNothing() async throws {
        let client = FakeMCPClient(relists: true)
        await client.connect(MCPServer(version: "1", invoker: NoApp()))
        _ = await client.initialize()
        let tools = await client.list()
        XCTAssertEqual(tools.count, AgentToolCatalog.builtInTools.count)
        try await Task.sleep(for: .milliseconds(250))
        let told = await client.listChangedCount
        XCTAssertEqual(told, 0)
        await client.close()  // Returns: the watch, waiting to ask again, does not hold the server.
    }

    // MARK: - The broker, over the socket

    func testAWatchCrossesTheSocketAndTheBrokerAnswersBetweenTurnsOnly() async throws {
        let rig = try BrokerRig()
        defer { rig.tearDown() }
        let task = UUID()
        let invoker = try rig.invoker(for: task)
        let first = try XCTUnwrapAsync(await invoker.listTools())
        XCTAssertEqual(first.fingerprint, AgentToolListWatching.fingerprint(of: first.tools),
                       "The list carries the app's fingerprint of itself")
        let stale = await invoker.waitForToolListChange(from: "stale")
        XCTAssertEqual(stale, .changed, "A client with another list is told at once")

        // In a turn, a change waits for the turn's end.
        rig.turns.running.insert(task)
        let watching = Task { await invoker.waitForToolListChange(from: first.fingerprint) }
        let held = await eventually { rig.broker.heldToolListWatchCount(for: task) == 1 }
        XCTAssertTrue(held)
        rig.connectors.set([Self.tool("notion_search", "Search pages")])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.broker.heldToolListWatchCount(for: task), 1, "Not told during the turn")
        rig.turns.running.remove(task)
        rig.broker.taskTurnEnded(task)
        let afterTurn = await watching.value
        XCTAssertEqual(afterTurn, .changed)

        // The same tools read again (same names and descriptions) are no change.
        let second = try XCTUnwrapAsync(await invoker.listTools())
        XCTAssertNotEqual(second.fingerprint, first.fingerprint)
        let unchanged = Task { await invoker.waitForToolListChange(from: second.fingerprint) }
        _ = await eventually { rig.broker.heldToolListWatchCount(for: task) == 1 }
        rig.connectors.set([Self.tool("notion_search", "Search pages")])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.broker.heldToolListWatchCount(for: task), 1, "An identical list is not a change")

        // A hold that runs out is an unchanged answer; the server asks again.
        rig.broker.toolListWatchHold = .milliseconds(100)
        let expired = await invoker.waitForToolListChange(from: second.fingerprint)
        XCTAssertEqual(expired, .unchanged)

        // An archived task's watches end, and its token is refused.
        rig.broker.releaseAgentTools(for: task)
        let released = await unchanged.value
        XCTAssertEqual(released, .unchanged)
        let refused = await invoker.waitForToolListChange(from: second.fingerprint)
        XCTAssertEqual(refused, .unavailable)
    }

    func testConnectorChangesReachOnlyTheTasksWhoseListChanged() async throws {
        let server = FakeConnectorServer()
        let center = ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(), http: server,
            userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", refreshRetrySleep: { _ in }))
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        let broker = BrokerRig.makeBroker()
        broker.connectors = center
        broker.toolListWatchHold = .seconds(10)
        broker.toolListSettleDelay = .milliseconds(20)
        center.onToolsChanged = { [weak broker] in broker?.toolsMayHaveChanged() }
        let first = UUID(), second = UUID()
        func call(_ task: UUID, _ method: String, fingerprint: String? = nil) throws -> AgentToolCall {
            let token = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [])?.environment[AgentToolEnvironment.token])
            return AgentToolCall(token: token, session: task.uuidString, tool: "",
                                 arguments: .object(["fingerprint": fingerprint.map(ToolJSON.string) ?? .null]), method: method)
        }
        let firstList = try XCTUnwrapAsync(await broker.list(try call(first, AgentToolCall.listMethod)))
        let secondList = try XCTUnwrapAsync(await broker.list(try call(second, AgentToolCall.listMethod)))
        XCTAssertTrue(firstList.tools.contains { $0["name"] == .string("example_whoami") })
        let firstWatch = Task { await broker.watch(try call(first, AgentToolCall.watchMethod, fingerprint: firstList.fingerprint)) }
        let secondWatch = Task { await broker.watch(try call(second, AgentToolCall.watchMethod, fingerprint: secondList.fingerprint)) }
        let bothHeld = await eventually {
            broker.heldToolListWatchCount(for: first) == 1 && broker.heldToolListWatchCount(for: second) == 1
        }
        XCTAssertTrue(bothHeld)

        // Turned off in the first task: only that task's list changed.
        center.setConnector(record.id, on: false, inTask: first)
        let firstTold = try await firstWatch.value
        XCTAssertEqual(firstTold?.changed, true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(broker.heldToolListWatchCount(for: second), 1, "The other task's list is the same")
        let withoutExample = try XCTUnwrapAsync(await broker.list(try call(first, AgentToolCall.listMethod)))
        XCTAssertFalse(withoutExample.tools.contains { $0["name"]?.stringValue?.hasPrefix("example_") == true })

        // Disconnected: the second task's tools go too.
        center.disconnect(record.id)
        let secondTold = try await secondWatch.value
        XCTAssertEqual(secondTold?.changed, true)
        broker.releaseAgentTools(for: first)
        broker.releaseAgentTools(for: second)
    }

    // MARK: - Harnesses, end to end

    /// A client that lists again when told stands for Claude Code (2.1.304 lists again within a few
    /// milliseconds and its next request carries the new tools); one that does not, for Codex 0.163.
    func testAClaudeCodeLikeClientHasANewConnectorFromItsNextTurnAndACodexLikeOneWhenReopened() async throws {
        let rig = try BrokerRig()
        defer { rig.tearDown() }
        rig.broker.toolListWatchHold = .milliseconds(400)
        let claudeTask = UUID(), codexTask = UUID()
        let claude = FakeMCPClient(relists: true)
        await claude.connect(MCPServer(version: "1", invoker: try rig.invoker(for: claudeTask)))
        let codex = FakeMCPClient(relists: false)
        await codex.connect(MCPServer(version: "1", invoker: try rig.invoker(for: codexTask)))
        for client in [claude, codex] {
            _ = await client.initialize()
            _ = await client.list()
        }
        let builtIn = await claude.tools
        XCTAssertFalse(builtIn.contains("notion_search"))

        // Both are in a turn when the person connects Notion.
        rig.turns.running = [claudeTask, codexTask]
        try await Task.sleep(for: .milliseconds(100))
        rig.connectors.set([Self.tool("notion_search", "Search pages")])
        try await Task.sleep(for: .milliseconds(900))
        let duringTurn = await claude.tools
        let toldDuringTurn = await claude.listChangedCount
        XCTAssertFalse(duringTurn.contains("notion_search"), "The turn that is running keeps its tools")
        XCTAssertEqual(toldDuringTurn, 0)

        rig.turns.running = []
        rig.broker.taskTurnEnded(claudeTask)
        rig.broker.taskTurnEnded(codexTask)
        let claudeHasIt = await eventually { await claude.tools.contains("notion_search") }
        XCTAssertTrue(claudeHasIt, "Claude Code's next turn has the new tool")
        let codexTold = await eventually { await codex.listChangedCount == 1 }
        XCTAssertTrue(codexTold)
        let codexTools = await codex.tools
        XCTAssertFalse(codexTools.contains("notion_search"), "Codex keeps the list it read at the start")

        // Codex reads it when the task is opened again: a new server for the same task.
        await codex.close()
        let reopened = FakeMCPClient(relists: false)
        await reopened.connect(MCPServer(version: "1", invoker: try rig.invoker(for: codexTask)))
        _ = await reopened.initialize()
        let afterReopening = await reopened.list()
        XCTAssertTrue(afterReopening.contains("notion_search"))

        // A tool whose connector was turned off stops at once, in both, before any new list.
        rig.connectors.turnOff(in: codexTask)
        let refused = await reopened.request("tools/call", .object(["name": .string("notion_search"), "arguments": .object([:])]))
        XCTAssertEqual(refused["result"]?["isError"], .bool(true))
        rig.broker.releaseAgentTools(for: claudeTask)
        rig.broker.releaseAgentTools(for: codexTask)
        await claude.close()
        await reopened.close()
    }

    // MARK: - The app

    func testTheAppSaysWhenATasksTurnEnds() async throws {
        let adapter = StreamingAdapter()
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: VolatileDefaults()),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        let launches = TurnRecordingLaunches()
        model.agentTools = launches
        let created = await model.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/live-tools-workspace"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Live tools")
        let session = try XCTUnwrap(created)
        let attached = await eventually { await adapter.isStreaming(session.id) }
        XCTAssertTrue(attached)
        await adapter.emit(.sessionStatusChanged(.running), for: session.id)
        let running = await eventually { model.isInTurn(session.id) }
        XCTAssertTrue(running)
        XCTAssertTrue(launches.turnsEnded.isEmpty)
        await adapter.emit(.sessionStatusChanged(.ready), for: session.id)
        let ended = await eventually { launches.turnsEnded == [session.id] }
        XCTAssertTrue(ended, "\(launches.turnsEnded)")
        XCTAssertFalse(model.isInTurn(session.id))
        await model.shutdown()
    }

    // MARK: - What the composer and Settings say

    /// Only Claude Code tasks say their tool list follows from the next turn; Codex and the ACP
    /// harnesses read it when the task starts or resumes.
    func testTheComposerSaysWhenEachHarnessesToolListFollows() throws {
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let options = ComposerSessionOptionsProjection.make(harness: harness, session: nil, providerCapabilities: nil,
                                                                providerUsage: nil, isAttached: true)
            let follows = AgentToolInjectionRoute.route(for: harness) == .claudeMCPConfig
            XCTAssertEqual(options.connectors?.toolListFollowsNextTurn ?? false, follows, harness.rawValue)
        }
        XCTAssertEqual(ComposerConnectorsMenu.footnotes(list: try Self.list(for: .claudeCode), switches: true),
                       [L10n.string("A connector turned off here stops at once; the task's tool list follows from its next turn.")])
        XCTAssertEqual(ComposerConnectorsMenu.footnotes(list: try Self.list(for: .codex), switches: true),
                       [L10n.string("A connector turned off here stops at once; the task's tool list follows when it next starts or resumes.")])
    }

    func testTheComposerListsDrawForClaudeAndCodex() throws {
        let directory = try WindowlessRender.directory("connector-live-tools-qa")
        let size = NSSize(width: 360, height: 300)
        for harness in [HarnessKind.claudeCode, .codex] {
            let content = ComposerConnectorsMenu(list: try Self.list(for: harness), onManage: {},
                                                 onSwitch: { _, _ in }, onReconnect: { _ in })
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            let name = harness == .claudeCode ? "composer-connectors-claude" : "composer-connectors-codex"
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                content
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(ParityTheme.canvas)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        }
    }

    /// A task's list with Notion turned off here, as the composer makes it for the harness.
    private static func list(for harness: HarnessKind) throws -> ComposerConnectorList {
        let options = ComposerSessionOptionsProjection.make(harness: harness, session: nil, providerCapabilities: nil,
                                                            providerUsage: nil, isAttached: true)
        var slot = try XCTUnwrap(options.connectors)
        slot.sessionServers = [HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120)]
        return try XCTUnwrap(ComposerConnectorList.make(slot, connectors: ConnectorsRenderingTests.records,
                                                        taskState: { $0.name == "Notion" ? .off : .on }))
    }

    // MARK: - Helpers

    nonisolated static func tool(_ name: String, _ description: String) -> ToolJSON {
        .object(["name": .string(name), "description": .string(description), "inputSchema": .object(["type": .string("object")])])
    }

    private func eventually(timeout: Duration = testWaitLimit, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

/// The app as the server sees it: a list that grows when the test says, and a watch that answers
/// at once when the client's list is not the app's, or else waits up to its hold.
private actor FakeApp: AgentToolInvoking {
    private var version = 1
    private var waiters: [UUID: CheckedContinuation<AgentToolListWatch, Never>] = [:]
    private(set) var askedAbout: [String?] = []
    private let hold: Duration = .milliseconds(150)

    static func tools(_ version: Int) -> [ToolJSON] {
        (1...version).map { ConnectorLiveToolsTests.tool("tool_\($0)", "Tool \($0)") }
    }

    static func fingerprint(_ version: Int) -> String { AgentToolListWatching.fingerprint(of: tools(version)) }

    nonisolated func call(tool: String, arguments: ToolJSON) async -> AgentToolResult {
        if tool == "slow" { try? await Task.sleep(for: .milliseconds(400)) }
        return .text("ran \(tool)")
    }

    func listTools() async -> AgentToolList? {
        AgentToolList(tools: Self.tools(version), fingerprint: Self.fingerprint(version))
    }

    func waitForToolListChange(from fingerprint: String?) async -> AgentToolListWatch {
        askedAbout.append(fingerprint)
        guard fingerprint == Self.fingerprint(version) else { return .changed }
        let id = UUID()
        let hold = hold
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: hold)
                self.finish(id, .unchanged)
            }
        }
    }

    func change() {
        version += 1
        for id in Array(waiters.keys) { finish(id, .changed) }
    }

    private func finish(_ id: UUID, _ answer: AgentToolListWatch) {
        waiters.removeValue(forKey: id)?.resume(returning: answer)
    }
}

/// A server Yardlet did not start: no app to list, call or watch.
private struct NoApp: AgentToolInvoking {
    func call(tool: String, arguments: ToolJSON) async -> AgentToolResult { .error("no app") }
}

/// A harness's MCP client over the server's stdio loop: initialize, list, call, and on
/// `notifications/tools/list_changed` list again if it is one that does.
private actor FakeMCPClient {
    let relists: Bool
    private let lines: AsyncStream<String>
    private let input: AsyncStream<String>.Continuation
    private var pending: [Int64: CheckedContinuation<ToolJSON, Never>] = [:]
    private var nextID: Int64 = 0
    private var serving: Task<Void, Never>?
    private(set) var listChangedCount = 0
    private(set) var tools: [String] = []

    init(relists: Bool) {
        self.relists = relists
        (lines, input) = AsyncStream<String>.makeStream()
    }

    func connect(_ server: MCPServer) {
        let lines = lines
        // Holds the client until its input ends (`close`).
        serving = Task {
            await MCPStdioLoop.serve(server, lines: lines, watchFirstDelay: .milliseconds(20)) { data in
                await self.receive(data)
            }
        }
    }

    func request(_ method: String, _ params: ToolJSON = .object([:])) async -> ToolJSON {
        nextID += 1
        let id = nextID
        let message: ToolJSON = .object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method), "params": params])
        let line = String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self)
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            input.yield(line)
        }
    }

    func initialize() async -> ToolJSON {
        let reply = await request("initialize", .object(["protocolVersion": .string("2025-06-18")]))
        input.yield(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return reply
    }

    @discardableResult
    func list() async -> [String] {
        let reply = await request("tools/list")
        tools = reply["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        return tools
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(ToolJSON.self, from: data) else { return }
        if case .integer(let id)? = message["id"], let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: message)
            return
        }
        guard message["method"] == .string("notifications/tools/list_changed") else { return }
        XCTAssertNil(message["id"], "A notification has no id")
        listChangedCount += 1
        if relists { Task { await self.list() } }
    }

    func close() async {
        input.finish()
        await serving?.value
    }
}

/// Connectors whose tools the test changes, telling the broker as `ConnectorCenter` does.
@MainActor
private final class ChangingConnectors: ConnectorToolProviding {
    private var shared: [ToolJSON] = []
    private var offIn: Set<UUID> = []
    var onChange: (() -> Void)?
    var offersTools: Bool { !shared.isEmpty }

    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] {
        context.taskID.map(offIn.contains) == true ? [] : shared
    }

    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
        guard shared.contains(where: { $0["name"] == .string(name) }) else { return nil }
        if context.taskID.map(offIn.contains) == true { return .error("Turned off for this task") }
        return .text("ran \(name)")
    }

    func set(_ tools: [ToolJSON]) {
        shared = tools
        onChange?()
    }

    func turnOff(in task: UUID) {
        offIn.insert(task)
        onChange?()
    }
}

@MainActor
private final class TurnState {
    var running: Set<UUID> = []
}

/// A broker behind a real socket, with connectors the test changes.
@MainActor
private struct BrokerRig {
    let broker: AgentToolBroker
    let connectors = ChangingConnectors()
    let turns = TurnState()
    let directory: URL
    let path: String
    let listener: UnixSocketListener

    static func makeBroker() -> AgentToolBroker {
        AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: URL(filePath: "/bin/sh"), endpoint: "/tmp/Yardlet-tools-live/tools.sock",
                privateDirectory: URL(filePath: "/tmp/Yardlet-tools-live"), isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) }))
    }

    init() throws {
        let broker = Self.makeBroker()
        self.broker = broker
        broker.connectors = connectors
        // Every task has the task suggestion tools, so the broker injects its server.
        broker.suggestions = AlwaysSuggestions.shared
        broker.toolListWatchHold = .seconds(5)
        broker.toolListSettleDelay = .milliseconds(20)
        let turns = turns
        broker.isTaskInTurn = { turns.running.contains($0) }
        connectors.onChange = { [weak broker] in broker?.toolsMayHaveChanged() }
        directory = FileManager.default.temporaryDirectory.appending(path: "ylt-\(UUID().uuidString.prefix(8))")
        path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        listener = try UnixSocketListener(path: path) { body, peer in await broker.respond(to: body, peer: peer) }
    }

    /// The server's side of one task, as `yardlet-mcp` reads it from its environment.
    func invoker(for task: UUID) throws -> UnixSocketToolInvoker {
        var environment = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [])).environment
        environment[AgentToolEnvironment.endpoint] = path
        return UnixSocketToolInvoker(environment: environment)
    }

    func tearDown() {
        listener.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Task suggestions answered by nobody, so the broker has a reason to inject its server.
@MainActor
private final class AlwaysSuggestions: TaskSuggestionToolHandling {
    static let shared = AlwaysSuggestions()
    func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult {
        .text("noted")
    }
}

private final class TurnRecordingLaunches: AgentToolLaunchProviding {
    private(set) var turnsEnded: [UUID] = []

    func agentToolServer(for localSessionID: UUID, workspaceRoots: [URL],
                         connectorScope: ConnectorTaskScope?) -> AgentToolServerLaunch? {
        AgentToolServerLaunch(command: "/tmp/yardlet-mcp", environment: [AgentToolEnvironment.session: localSessionID.uuidString])
    }

    func releaseAgentTools(for localSessionID: UUID) {}
    func taskTurnEnded(_ localSessionID: UUID) { turnsEnded.append(localSessionID) }
}

/// A harness whose events the test sends.
private actor StreamingAdapter: HarnessAdapter, HarnessAgentToolConfiguring {
    nonisolated let kind = HarnessKind.claudeCode
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    private var sequence: UInt64 = 0

    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) {}

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

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
        continuations[session.localSessionID] = continuation
        return stream
    }

    func close(_ session: HarnessSessionHandle) async {
        continuations.removeValue(forKey: session.localSessionID)?.finish()
    }

    func isStreaming(_ id: UUID) -> Bool { continuations[id] != nil }

    func emit(_ payload: HarnessEventPayload, for id: UUID) {
        sequence += 1
        continuations[id]?.yield(HarnessEventEnvelope(localSessionID: id, sequence: sequence, payload: payload))
    }
}

/// Preferences held in memory, so no suite is written to disk.
private final class VolatileDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
