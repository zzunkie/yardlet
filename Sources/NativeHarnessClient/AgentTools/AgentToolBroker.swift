import Foundation
import YardletAgentTools

/// The task a connector tool list or call is for, and what Yardlet knew of its harness when the
/// task was injected (`ConnectorTaskScope`; nil for a stand-in task).
struct ConnectorToolContext: Equatable, Sendable {
    var taskID: UUID?
    var scope: ConnectorTaskScope?
    /// The task's folders, primary first, where a mail attachment may come from.
    var workspaceRoots: [URL] = []
}

/// Tools of the services the user connected in Yardlet (docs/CONNECTORS.md).
@MainActor
protocol ConnectorToolProviding: AnyObject {
    /// True when a new session would get at least one connector's tools.
    var offersTools: Bool { get }
    /// MCP `tools/list` entries under Yardlet's names, for one task: less the connectors turned
    /// off there and those whose server the task's harness loads itself.
    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON]
    /// Runs a connector's tool; nil when no connector has a tool of this name.
    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult?
    /// The kinds of services whose tools the task's list holds ("Gmail", "Linear"), each once and
    /// without accounts, for the server's instructions.
    func serviceNames(for context: ConnectorToolContext) -> [String]
    /// What Yardlet's approvals weigh about a connector's tool; nil when no connector has one of this name.
    func connectorToolFacts(named name: String, for context: ConnectorToolContext) -> ConnectorToolFacts?
}

/// What Yardlet's approvals weigh about one connector tool (`AgentToolBroker+Approvals`).
struct ConnectorToolFacts: Equatable, Sendable {
    /// The kind of service the tool acts in, without an account ("Gmail", "Slack"): a task's first read of
    /// each is asked once.
    var service: String
    /// The tool's title, or its name when it has none.
    var title: String
    /// The tool changes nothing (`readOnlyHint` true). Anything else counts as a write.
    var readOnly: Bool
    /// The account a connector of one account acts in; nil for a tool its service's accounts share, whose call
    /// names the account (`ConnectorToolNaming.accountArgument`).
    var account: String? = nil
}

extension ConnectorToolProviding {
    func serviceNames(for context: ConnectorToolContext) -> [String] { [] }
    func connectorToolFacts(named name: String, for context: ConnectorToolContext) -> ConnectorToolFacts? { nil }
}

/// Yardlet's task suggestion tools (`spawn_task`, `dismiss_task`), answered by the app, which keeps
/// what became of each chip with the task that suggested it.
@MainActor
protocol TaskSuggestionToolHandling: AnyObject {
    func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult
}

/// Yardlet's simulator tools (`SimulatorToolCatalog`), answered by the app against its simulator center
/// (docs/SIMULATOR.md, "Agent tools"). A task has them when Settings › General › Simulator was on as it started or
/// resumed, as "Agent browser tools" works, while a platform's devices can be used.
@MainActor
protocol SimulatorToolHandling: AnyObject {
    /// Settings › General › Simulator, read when a task starts or resumes and kept for it.
    var simulatorSwitchIsOn: Bool { get }
    /// A platform's devices can be listed and started now.
    var simulatorPlatformIsUsable: Bool { get }
    func callSimulatorTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult
}

/// Yardlet's session tools (`SessionToolCatalog`), answered by the app: reading the person's other
/// tasks, messaging one, starting a child task and running a subagent. A call may wait for the
/// person's approval or for another task's turn.
@MainActor
protocol SessionToolHandling: AnyObject {
    func callSessionTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult
    /// Whether the task's browser tools may open a file outside its folders (`BrowserAgentTools.allowsFileOutsideFolders`).
    func allowsBrowserFile(_ path: String, callerID: UUID) async -> Bool
}

/// What the app knows of the task or subagent that made a call, which Yardlet's own approvals turn on
/// (`AgentToolBroker+Approvals`).
struct AgentToolCallerPolicy: Equatable, Sendable {
    /// The task whose cards the caller's approvals go on; a subagent shares its task's.
    var hostTaskID: UUID
    /// The caller may only read (Claude Code's or Antigravity's Plan, Codex's read-only).
    var readOnly: Bool
    /// The caller asks the person before what it does beyond its own reach (`AppModel.sessionToolAsksPerson`).
    var asksPerson: Bool
    /// The caller is a Claude Code task in Default or Accept edits, whose CLI asks the person before each direct
    /// call of a Yardlet tool it was not told to allow (`AgentToolServerLaunch.claudeAllowedTools`), offering
    /// no lasting allow for a write (`ClaudeAdapter`).
    var harnessAsksBeforeDirectCalls: Bool
}

/// The app side of Yardlet's own approvals for agent tool calls: who made a call, and the request card that
/// asks the person in the caller's task.
@MainActor
protocol AgentToolApprovalHandling: AnyObject {
    func agentToolPolicy(callerID: UUID) -> AgentToolCallerPolicy?
    /// Asks the person on the caller's task's request card; true to go ahead.
    func askPerson(title: String, detail: String, callerID: UUID) async -> Bool
}

/// How a call reached the broker: from the harness under the tool's own name, or from inside a wrapper
/// (`run_yardlet_script`, `call_connector_tool`), whose calls the harness never saw.
enum AgentToolCallOrigin: Equatable, Sendable {
    case direct
    case wrapped
}

/// Yardlet's scheduled-task tools (`ScheduleToolCatalog`), answered by the app against its scheduler
/// (docs/AGENT_BROWSER_TOOLS.md, "Scheduled-task tools"): an agent creates, lists, changes, deletes and runs the person's schedules.
@MainActor
protocol ScheduleToolHandling: AnyObject {
    func callScheduleTool(named name: String, arguments: ToolJSON, callerID: UUID,
                          origin: AgentToolCallOrigin) async -> AgentToolResult
}

/// The app side of the Yardlet MCP server. It issues each task a random token when the task's
/// harness session is injected, and runs a call only when its token and task match. The local
/// endpoint that carries calls here is platform code; this type only sees decoded calls.
///
/// A task gets the server when the app answers the task suggestion tools, which every task has,
/// or else when the browser or simulator tools are on or a connector is connected. Whether the browser tools
/// were on is kept per task from that moment, like the rest of the injection.
///
/// A running task's server learns when the task's list changes by asking here (`tools/watch`):
/// the request is held until the list differs from the one the server's client last listed and
/// the task is between turns, and the server then tells its client
/// `notifications/tools/list_changed`. Holding the change until the turn ends is the Claude app's
/// rule for a connector switched during a session (3.1623.3 `applyMcpServersIfIdle`: "an enabled
/// connector's tools are available from your NEXT turn"); a call to a connector turned off is
/// refused at once regardless.
@MainActor
final class AgentToolBroker: AgentToolLaunchProviding {
    struct Environment {
        /// `yardlet-mcp`; nil when this build does not carry it.
        var executableURL: URL?
        /// The endpoint the server connects to (a socket path on macOS).
        var endpoint: String
        /// A directory only the user can open.
        var privateDirectory: URL
        var isEnabled: @MainActor () -> Bool = { AgentToolPreference.isEnabled() }
    }

    private let environment: Environment
    private let tools: BrowserAgentTools
    private var tokens: [UUID: String] = [:]
    private var workspaceRoots: [UUID: [URL]] = [:]
    private var browserToolsByTask: [UUID: Bool] = [:]
    /// Whether the Simulator switch was on when each task was injected.
    private var simulatorToolsByTask: [UUID: Bool] = [:]
    /// What each task's harness was found to load itself when the task was injected.
    private var connectorScopes: [UUID: ConnectorTaskScope] = [:]
    var connectors: (any ConnectorToolProviding)?
    /// The app, which answers `spawn_task` and `dismiss_task`. Nil, as in tests, offers neither.
    weak var suggestions: (any TaskSuggestionToolHandling)?
    /// The app, which answers the session tools. Nil, as in tests, offers none.
    weak var sessions: (any SessionToolHandling)?
    /// Whether the person shares the task's terminal with its agent (`TerminalSharingPreference`): the
    /// session tools then include `read_terminal`. Read at every list, so a change reaches a running task
    /// once its harness is told the list changed (`toolsMayHaveChanged`).
    var sharesTerminal: @MainActor () -> Bool = { TerminalSharingPreference.isOn() }
    /// Whether Yardlet's native MCP Code Mode is enabled (`CodeModePreference`): exposes
    /// `search_yardlet_tools` and `run_yardlet_script` and collapses flat connector schemas.
    var codeModeEnabled: @MainActor () -> Bool = { CodeModePreference.isOn() }
    /// The app, which answers the scheduled-task tools. Nil, as in tests, offers none.
    weak var schedules: (any ScheduleToolHandling)?
    /// The app, which says who made a call and asks the person where Yardlet's own approvals ask
    /// (`AgentToolBroker+Approvals`). Nil, as in tests, asks nothing.
    weak var approvals: (any AgentToolApprovalHandling)?
    /// The services each task's person allowed it to read from, by task (`AgentToolCallerPolicy.hostTaskID`).
    var approvedReadServices: [UUID: Set<String>] = [:]
    /// A first read's question in flight, by task and service, which calls made meanwhile wait on.
    var pendingReadApprovals: [String: PendingReadApproval] = [:]
    /// The app, which answers the simulator tools. Nil, as in tests and on other platforms, offers none.
    weak var simulators: (any SimulatorToolHandling)?
    /// The vault for agents. A task with the browser tools also gets `browser_fill_credential` while
    /// it offers the tool (on, with an item); nil, as in tests, offers none.
    var vault: VaultCenter? {
        didSet {
            tools.vault = vault
            vault?.onTurnedOff = { [weak tools] in Task { await tools?.disarmAllPasskeys() } }
        }
    }
    /// The app, which shows a tab the agent hands to the person and tells them (`browser_handoff`).
    weak var handoffs: (any BrowserHandoffPresenting)? {
        didSet { tools.handoffs = handoffs }
    }
    /// Makes sure the endpoint listens, each time a task is injected: the platform starts it the first time, and
    /// again when it is gone (the socket's file was cleared away), which a task's server cannot reach. A failure
    /// leaves the task without tools.
    var startEndpoint: @MainActor () throws -> Void = {}
    /// Whether a call naming a task may come from the process that sent it (its ID; nil when the endpoint
    /// could not tell). A task's token is in its harness's configuration, which other processes of the same
    /// user can read, so on macOS the app also asks that the caller run under the process Yardlet started
    /// for that task's harness (`AppModel.agentToolHarnessProcesses`). Nil, as in tests, takes the token alone.
    var callerProcessCheck: (@MainActor (_ session: UUID, _ process: Int32?) -> Bool)?
    /// Whether a task is in a turn (running, or waiting for an approval). A change to its tools
    /// is told when the turn ends. The app sets it; tests leave it saying no task is in one.
    var isTaskInTurn: @MainActor (UUID) -> Bool = { _ in false }
    /// How long one `tools/watch` is held at most, and how long a burst of connector changes is
    /// let settle before the lists are compared.
    var toolListWatchHold: Duration = AgentToolListWatching.hold
    var toolListSettleDelay: Duration = .milliseconds(300)

    /// A `tools/watch` held for a task: the fingerprint of the list its server's client has.
    private struct ToolListWatch {
        let fingerprint: String?
        let continuation: CheckedContinuation<AgentToolListWatchReply, Never>
        let expiry: Task<Void, Never>
    }
    private var toolListWatches: [UUID: [UUID: ToolListWatch]] = [:]
    /// Tokens explicitly released by `releaseAgentTools(for:)`, bounded FIFO so late `tools/watch`
    /// probes from a lingering `yardlet-mcp` still receive `released: true` and exit cleanly.
    private var releasedTokens: [String: UUID] = [:]
    private var releasedTokenOrder: [String] = []
    private static let maximumReleasedTokens = 512
    private var pendingToolListCheck: Task<Void, Never>?

    init(environment: Environment, tools: BrowserAgentTools) {
        self.environment = environment
        self.tools = tools
        tools.workspaceRoots = { [weak self] in self?.workspaceRoots[$0] ?? [] }
        tools.uploadFolder = environment.privateDirectory.appending(path: "uploads", directoryHint: .isDirectory)
        tools.allowsFileOutsideFolders = { [weak self] session, path in
            await self?.sessions?.allowsBrowserFile(path, callerID: session) ?? false
        }
    }

    func agentToolServer(for localSessionID: UUID, workspaceRoots roots: [URL],
                         connectorScope: ConnectorTaskScope?) -> AgentToolServerLaunch? {
        let browserTools = environment.isEnabled()
        let simulatorTools = simulators?.simulatorSwitchIsOn ?? false
        guard browserTools || simulatorTools || suggestions != nil || sessions != nil || schedules != nil
                || connectors?.offersTools == true,
              let executable = environment.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
        else { return nil }
        do {
            try startEndpoint()
        } catch {
            return nil
        }
        // One token per task for this app run: a harness that keeps its server across a resume
        // keeps working, and a new app run issues new ones.
        let token = tokens[localSessionID] ?? Self.newToken()
        tokens[localSessionID] = token
        workspaceRoots[localSessionID] = roots
        browserToolsByTask[localSessionID] = browserTools
        simulatorToolsByTask[localSessionID] = simulatorTools
        connectorScopes[localSessionID] = connectorScope
        var launchEnvironment = [
            AgentToolEnvironment.endpoint: environment.endpoint,
            AgentToolEnvironment.token: token,
            AgentToolEnvironment.session: localSessionID.uuidString,
            AgentToolEnvironment.appProcess: String(ProcessInfo.processInfo.processIdentifier)
        ]
        // Antigravity persists the session's `mcpServers` spec in its conversation database and
        // hashes differing specs into separate servers on `session/load`. Keeping its launch
        // environment free of the mutable connected-services list prevents duplicate `yardlet`
        // servers when connectors change before a resume within the same Yardlet run; connected
        // services are still advertised dynamically in `list_connector_tools`.
        if connectorScope?.harness != .antigravityCLI {
            let services = connectors?.serviceNames(for: connectorContext(localSessionID)) ?? []
            if !services.isEmpty { launchEnvironment[AgentToolEnvironment.services] = services.joined(separator: "\n") }
        }
        return AgentToolServerLaunch(
            command: executable.path(percentEncoded: false),
            environment: launchEnvironment,
            privateDirectory: environment.privateDirectory,
            leftOutServerURLs: connectorScope?.leftOutNativeServers.map(\.url) ?? []
        )
    }

    /// Values the vault filled for the person in a tab the agent may read: no result carries them.
    func noteVaultValues(_ values: [String?]) {
        values.forEach { tools.vaultScrub.add($0) }
    }

    /// Text from a page scrubbed as tool results are (`BrowserAgentTools.scrub(_:)`).
    func scrubPageText(_ text: String) -> String {
        tools.scrub(text)
    }

    /// Whether a page's keys and tokens are covered in a picture of it (`BrowserAgentTools.hidesCredentials`).
    var hidesCredentials: Bool { tools.hidesCredentials }

    /// Whether text (an address, a title) carries a value the vault filled lately, in any spelling it scrubs.
    func carriesVaultValue(_ text: String) -> Bool {
        tools.vaultScrub.carries(text)
    }

    /// Ends a task's token, tells any running `yardlet-mcp` watch that the task was released, and
    /// closes its browser tab.
    func releaseAgentTools(for localSessionID: UUID) {
        if let token = tokens.removeValue(forKey: localSessionID) {
            recordReleasedToken(token, for: localSessionID)
        }
        for id in Array((toolListWatches[localSessionID] ?? [:]).keys) {
            finishToolListWatch(id, of: localSessionID, reply: AgentToolListWatchReply(changed: false, released: true))
        }
        workspaceRoots.removeValue(forKey: localSessionID)
        browserToolsByTask.removeValue(forKey: localSessionID)
        simulatorToolsByTask.removeValue(forKey: localSessionID)
        connectorScopes.removeValue(forKey: localSessionID)
        approvedReadServices.removeValue(forKey: localSessionID)
        tools.closeTab(for: localSessionID)
    }

    private func recordReleasedToken(_ token: String, for sessionID: UUID) {
        if releasedTokens[token] == nil {
            releasedTokenOrder.append(token)
            if releasedTokenOrder.count > Self.maximumReleasedTokens {
                let evicted = releasedTokenOrder.removeFirst()
                releasedTokens.removeValue(forKey: evicted)
            }
        }
        releasedTokens[token] = sessionID
    }

    /// A stand-in task's launch, with no harness to scope its connectors (QA, tests).
    func agentToolServer(for localSessionID: UUID, workspaceRoots roots: [URL]) -> AgentToolServerLaunch? {
        agentToolServer(for: localSessionID, workspaceRoots: roots, connectorScope: nil)
    }

    /// The scope recorded for a task when it was last injected.
    func connectorScope(for localSessionID: UUID) -> ConnectorTaskScope? {
        connectorScopes[localSessionID]
    }

    func connectorContext(_ sessionID: UUID) -> ConnectorToolContext {
        ConnectorToolContext(taskID: sessionID, scope: connectorScopes[sessionID],
                             workspaceRoots: workspaceRoots[sessionID] ?? [])
    }

    func handle(_ call: AgentToolCall) async -> AgentToolResult {
        await handle(call, origin: .direct)
    }

    private func handle(_ call: AgentToolCall, origin: AgentToolCallOrigin) async -> AgentToolResult {
        guard let sessionID = authorizedSession(call) else { return Self.unrecognizedToken }
        if CodeModeToolCatalog.definition(named: call.tool) != nil, !codeModeEnabled() {
            return .failure("MCP Code Mode is off in Yardlet's settings. Turn it on in Settings → General.",
                            .refused, retry: .no)
        }
        // Yardlet's own tools are checked against the schemas they are listed with before they run; a
        // connector's are checked where its tools are known (`ConnectorCenter.callConnectorTool`).
        if let definition = Self.ownDefinition(named: call.tool),
           let failure = AgentToolArgumentCheck.failure(tool: call.tool, arguments: call.arguments,
                                                        schema: definition.inputSchema) {
            return failure
        }
        if Self.ownDefinition(named: call.tool) != nil,
           let refusal = await approvalRefusal(tool: call.tool, arguments: call.arguments, sessionID: sessionID,
                                               origin: origin) {
            return refusal
        }
        if AgentToolCatalog.definition(named: call.tool) != nil {
            guard browserToolsByTask[sessionID] != false else {
                return .error("The browser tools were off in Yardlet's settings when this task started. Turn them "
                    + "on in Yardlet Settings → General, then start or resume the task.")
            }
            return await tools.run(tool: call.tool, arguments: JSONValue(call.arguments), sessionID: sessionID)
        }
        if VaultToolCatalog.definition(named: call.tool) != nil {
            guard browserToolsByTask[sessionID] != false, vault?.offersTool == true else {
                return .error("Yardlet's password manager is off or empty, so nothing was filled.")
            }
            return await tools.run(tool: call.tool, arguments: JSONValue(call.arguments), sessionID: sessionID)
        }
        if TaskSuggestionToolCatalog.definition(named: call.tool) != nil, let suggestions {
            return await suggestions.callTaskSuggestionTool(named: call.tool, arguments: call.arguments, sessionID: sessionID)
        }
        if WidgetToolCatalog.definition(named: call.tool) != nil, offersWidget(to: sessionID) {
            return Self.showWidget(call.arguments)
        }
        if SessionToolCatalog.definition(named: call.tool) != nil || SettingsToolCatalog.definition(named: call.tool) != nil,
           let sessions {
            // Keys and tokens in another task's title, conversation or answer are hidden as the browser tools hide them.
            return await hidingCredentials(sessions.callSessionTool(named: call.tool, arguments: call.arguments,
                                                                    callerID: sessionID))
        }
        if TerminalToolCatalog.definition(named: call.tool) != nil, let sessions {
            guard sharesTerminal() else {
                return .error("The person stopped sharing the terminal in Yardlet's settings, so it was not read.")
            }
            // Keys and tokens a command printed are hidden as the browser tools hide them.
            return await hidingCredentials(sessions.callSessionTool(named: call.tool, arguments: call.arguments,
                                                                    callerID: sessionID))
        }
        if ScheduleToolCatalog.definition(named: call.tool) != nil, let schedules {
            return await schedules.callScheduleTool(named: call.tool, arguments: call.arguments, callerID: sessionID,
                                                    origin: origin)
        }
        if SimulatorToolCatalog.definition(named: call.tool) != nil, let simulators {
            guard simulatorToolsByTask[sessionID] == true else {
                return Self.simulatorFeatureOff
            }
            return await simulators.callSimulatorTool(named: call.tool, arguments: call.arguments, callerID: sessionID)
        }
        if SimulatorGatewayToolCatalog.definition(named: call.tool) != nil, let simulators {
            return await handleSimulatorGateway(call, for: sessionID, simulators: simulators)
        }
        if ConnectorGatewayToolCatalog.definition(named: call.tool) != nil {
            return await handleConnectorGateway(call, for: sessionID)
        }
        if CodeModeToolCatalog.definition(named: call.tool) != nil {
            return await handleCodeMode(call, for: sessionID)
        }
        if let refusal = await connectorApprovalRefusal(tool: call.tool, sessionID: sessionID, origin: origin,
                                                        arguments: call.arguments) {
            return refusal
        }
        if let result = await connectors?.callConnectorTool(named: call.tool, arguments: call.arguments,
                                                             for: connectorContext(sessionID)) {
            return result
        }
        return await unknownTool(call.tool, for: sessionID)
    }

    private static let simulatorFeatureOff = AgentToolResult.failure(
        "The Simulator feature was off in Yardlet's settings when this task started. The person "
            + "can turn it on in Settings → General → Simulator; the tools come once the task starts or resumes.",
        .refused, retry: .no
    )

    private func handleSimulatorGateway(
        _ call: AgentToolCall,
        for sessionID: UUID,
        simulators: any SimulatorToolHandling
    ) async -> AgentToolResult {
        guard simulatorToolsByTask[sessionID] == true else {
            return Self.simulatorFeatureOff
        }
        if call.tool == SimulatorGatewayToolCatalog.listTools {
            guard simulators.simulatorPlatformIsUsable else {
                return .text("No usable simulator or Android platform is available right now.")
            }
            return SimulatorGatewayToolCatalog.formatList(tool: call.arguments["tool"]?.stringValue)
        }
        let innerTool = (call.arguments["tool"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerTool.isEmpty else {
            return .failure("\(SimulatorGatewayToolCatalog.callTool) requires a non-empty tool name.",
                            .invalidArguments, retry: .withChanges)
        }
        guard let definition = SimulatorToolCatalog.definition(named: innerTool) else {
            let names = SimulatorToolCatalog.tools.map(\.name)
            return .failure("No simulator tool named \(innerTool). Available simulator tools: \(AgentToolNames.listed(names)).",
                            .unknownTool, retry: .withChanges,
                            details: ["tool": .string(innerTool), "similar": .array(names.map(ToolJSON.string))])
        }
        let innerArguments: ToolJSON
        if let raw = call.arguments["arguments"], raw != .null {
            guard case .object = raw else {
                return .failure("\(SimulatorGatewayToolCatalog.callTool) arguments must be a JSON object.",
                                .invalidArguments, retry: .withChanges)
            }
            innerArguments = raw
        } else {
            innerArguments = .object([:])
        }
        if let refusal = await approvalRefusal(tool: innerTool, arguments: innerArguments, sessionID: sessionID,
                                               origin: .wrapped) {
            return refusal
        }
        if let failure = AgentToolArgumentCheck.failure(tool: innerTool, arguments: innerArguments,
                                                        schema: definition.inputSchema) {
            return failure
        }
        return await simulators.callSimulatorTool(named: innerTool, arguments: innerArguments, callerID: sessionID)
    }

    private func handleConnectorGateway(_ call: AgentToolCall, for sessionID: UUID) async -> AgentToolResult {
        if call.tool == ConnectorGatewayToolCatalog.listTools {
            let connectorTools = await filteredConnectorTools(for: sessionID)
            return ConnectorGatewayToolCatalog.formatList(
                tools: connectorTools,
                service: call.arguments["service"]?.stringValue,
                query: call.arguments["query"]?.stringValue,
                exactTool: call.arguments["tool"]?.stringValue
            )
        }
        let innerTool = (call.arguments["tool"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerTool.isEmpty else {
            return .failure("\(ConnectorGatewayToolCatalog.callTool) requires a non-empty tool name.",
                            .invalidArguments, retry: .withChanges)
        }
        if Self.ownDefinition(named: innerTool) != nil {
            return .failure("\(innerTool) is a direct Yardlet tool, not a connector tool. Call \(innerTool) directly.",
                            .invalidArguments, retry: .withChanges)
        }
        let innerArguments: ToolJSON
        if let raw = call.arguments["arguments"], raw != .null {
            guard case .object = raw else {
                return .failure("\(ConnectorGatewayToolCatalog.callTool) arguments must be a JSON object.",
                                .invalidArguments, retry: .withChanges)
            }
            innerArguments = raw
        } else {
            innerArguments = .object([:])
        }
        if let refusal = await connectorApprovalRefusal(tool: innerTool, sessionID: sessionID, origin: .wrapped,
                                                        arguments: innerArguments) {
            return refusal
        }
        if let result = await connectors?.callConnectorTool(named: innerTool, arguments: innerArguments,
                                                             for: connectorContext(sessionID)) {
            return result
        }
        return await unknownConnectorTool(innerTool, for: sessionID)
    }

    private func handleCodeMode(_ call: AgentToolCall, for sessionID: UUID) async -> AgentToolResult {
        guard CodeModePreference.isSupported && codeModeEnabled() else {
            return .failure(
                "MCP Code Mode is off in Yardlet's settings. Turn it on in Settings → General to use \(call.tool).",
                .refused, retry: .no
            )
        }
        if call.tool == CodeModeToolCatalog.searchTools {
            let all = await searchableToolsForCodeMode(for: sessionID)
            return CodeModeToolCatalog.formatSearch(
                tools: all,
                query: call.arguments["query"]?.stringValue,
                category: call.arguments["category"]?.stringValue,
                exactTool: call.arguments["tool"]?.stringValue
            )
        }
        let code = call.arguments["code"]?.stringValue ?? ""
        let timeoutSeconds: Double? = switch call.arguments["timeoutSeconds"] {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
        let session = call.session
        let token = call.token
        let result = await CodeModeRunner.run(code: code, timeoutSeconds: timeoutSeconds) { [weak self] tool, arguments in
            guard let self else {
                return .failure("Yardlet tool broker is no longer available.", .unreachable, retry: .no)
            }
            let innerCall = AgentToolCall(token: token, session: session, tool: tool, arguments: arguments)
            return await self.handle(innerCall, origin: .wrapped)
        }
        return await hidingCredentials(result)
    }

    private func searchableToolsForCodeMode(for sessionID: UUID) async -> [ToolJSON] {
        let browserOn = browserToolsByTask[sessionID] != false
        let browserDefinitions = browserOn ? AgentToolCatalog.browserTools : []
        let vaultDefinitions = browserOn && vault?.offersTool == true ? [VaultToolCatalog.tool] : []
        let simulatorUsable = simulatorToolsByTask[sessionID] == true && simulators?.simulatorPlatformIsUsable == true
        let simulatorDefinitions = simulatorUsable ? SimulatorToolCatalog.tools : []
        let suggestionDefinitions = suggestions == nil ? [] : TaskSuggestionToolCatalog.tools
        let widgetDefinitions = offersWidget(to: sessionID) ? [WidgetToolCatalog.tool] : []
        let sessionDefinitions = sessions == nil ? [] : (SessionToolCatalog.tools + SettingsToolCatalog.tools)
        let terminalDefinitions = sessions != nil && sharesTerminal() ? [TerminalToolCatalog.tool] : []
        let scheduleDefinitions = schedules == nil ? [] : ScheduleToolCatalog.tools
        let core = (browserDefinitions + vaultDefinitions + simulatorDefinitions + suggestionDefinitions
            + widgetDefinitions + sessionDefinitions + terminalDefinitions + scheduleDefinitions).map(\.json)
        let connectorTools = await filteredConnectorTools(for: sessionID)
        return core + connectorTools
    }

    /// The result with the keys and tokens in its text hidden (`CredentialText`), unless the person turned that off.
    private func hidingCredentials(_ result: AgentToolResult) async -> AgentToolResult {
        guard vault?.hidesCredentials ?? true else { return result }
        return await Self.hidingCredentials(in: result)
    }

    /// Away from the main actor: a terminal or a conversation can be long.
    @concurrent private static func hidingCredentials(in result: AgentToolResult) async -> AgentToolResult {
        var hidden = result
        hidden.content = result.content.map { content in
            switch content {
            case let .text(text):
                return .text(CredentialText.scrub(text))
            case let .json(value):
                return .json(scrubJSON(value))
            case .image:
                return content
            }
        }
        if let structured = result.structuredContent {
            hidden.structuredContent = scrubJSON(structured)
        }
        return hidden
    }

    private nonisolated static func scrubJSON(_ value: ToolJSON) -> ToolJSON {
        switch value {
        case let .string(text):
            return .string(CredentialText.scrub(text))
        case let .array(items):
            return .array(items.map(scrubJSON))
        case let .object(map):
            return .object(map.mapValues(scrubJSON))
        case .integer, .number, .bool, .null:
            return value
        }
    }

    private static let ownDefinitionsByName: [String: AgentToolDefinition] = {
        var map: [String: AgentToolDefinition] = [:]
        let catalogs: [[AgentToolDefinition]] = [
            AgentToolCatalog.browserTools,
            [VaultToolCatalog.tool],
            TaskSuggestionToolCatalog.tools,
            SessionToolCatalog.tools,
            [TerminalToolCatalog.tool],
            SettingsToolCatalog.tools,
            ScheduleToolCatalog.tools,
            SimulatorToolCatalog.tools,
            SimulatorGatewayToolCatalog.tools,
            [WidgetToolCatalog.tool],
            ConnectorGatewayToolCatalog.staticTools,
            CodeModeToolCatalog.tools
        ]
        for catalog in catalogs {
            for definition in catalog {
                map[definition.name] = definition
            }
        }
        return map
    }()

    static func ownDefinition(named name: String) -> AgentToolDefinition? {
        ownDefinitionsByName[name]
    }

    /// `show_widget` for the harnesses other than Codex, whose model has the `visualize` skill and its own folder
    /// for it; only with the app, as the task suggestion tools.
    private func offersWidget(to sessionID: UUID) -> Bool {
        suggestions != nil && connectorScopes[sessionID]?.harness != .codex
    }

    /// `show_widget` answers at once: the conversation draws the view from the call (docs/CONVERSATION_MEDIA.md,
    /// "Views from other harnesses"), and nothing is kept.
    private static func showWidget(_ arguments: ToolJSON) -> AgentToolResult {
        let code = arguments[WidgetToolCatalog.widgetCode]?.stringValue ?? ""
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("widget_code is empty.", .invalidArguments, retry: .withChanges)
        }
        guard code.utf8.count <= WidgetToolCatalog.maximumCodeLength else {
            return .failure("widget_code is \(code.utf8.count) bytes; the limit is 1 MB. Draw less, or load a library "
                + "from a CDN instead of inlining it.", .invalidArguments, retry: .withChanges)
        }
        return .text(WidgetToolCatalog.result)
    }

    /// A call to a tool the task does not have, such as one its harness listed before a connector went off,
    /// or a name the model made up: the task's tools that share its first word, which it was most likely
    /// meant as.
    private func unknownTool(_ name: String, for sessionID: UUID) async -> AgentToolResult {
        let family = AgentToolNames.family(of: name, in: await tools(for: sessionID).compactMap { $0["name"]?.stringValue })
        let message = family.isEmpty
            ? "This task has no Yardlet tool named \(name); its Yardlet tools are the ones its harness lists."
            : "This task has no Yardlet tool named \(name). Its tools of that kind: \(AgentToolNames.listed(family))."
        return .failure(message, .unknownTool, retry: .withChanges,
                        details: ["tool": .string(name), "similar": .array(family.map(ToolJSON.string))])
    }

    private func unknownConnectorTool(_ name: String, for sessionID: UUID) async -> AgentToolResult {
        let names = await filteredConnectorTools(for: sessionID).compactMap { $0["name"]?.stringValue }
        let family = AgentToolNames.family(of: name, in: names)
        let message = family.isEmpty
            ? "This task has no connected connector tool named \(name). Call \(ConnectorGatewayToolCatalog.listTools) to list available tools."
            : "This task has no connected connector tool named \(name). Its tools of that kind: \(AgentToolNames.listed(family))."
        return .failure(message, .unknownTool, retry: .withChanges,
                        details: ["tool": .string(name), "similar": .array(family.map(ToolJSON.string))])
    }

    private func usesCompactToolSurface(for sessionID: UUID) -> Bool {
        connectorScopes[sessionID]?.harness == .antigravityCLI
    }

    private static let ownReservedNames: Set<String> = {
        var names: Set<String> = []
        let catalogs: [[AgentToolDefinition]] = [
            TaskSuggestionToolCatalog.tools,
            SessionToolCatalog.tools,
            SettingsToolCatalog.tools,
            ScheduleToolCatalog.tools,
            SimulatorToolCatalog.tools,
            SimulatorGatewayToolCatalog.tools,
            ConnectorGatewayToolCatalog.staticTools,
            CodeModeToolCatalog.tools,
            [VaultToolCatalog.tool, TerminalToolCatalog.tool, WidgetToolCatalog.tool]
        ]
        for catalog in catalogs {
            for definition in catalog {
                names.insert(definition.name)
            }
        }
        return names
    }()

    private func filteredConnectorTools(for sessionID: UUID) async -> [ToolJSON] {
        (await connectors?.connectorTools(for: connectorContext(sessionID)) ?? []).filter {
            !Self.ownReservedNames.contains($0["name"]?.stringValue ?? "")
        }
    }

    /// The task's tools: the browser catalog when it was on, the simulator tools when the Simulator switch was on and a
    /// platform's devices can be used, the task suggestion tools, the session tools and the settings tools,
    /// `read_terminal` while the terminal is shared, the scheduled-task tools, then connected connectors' tools, less any whose name is one of Yardlet's own (a
    /// connector slug and tool can spell `spawn_task`), with their fingerprint. Nil when the
    /// call's token does not match.
    func list(_ call: AgentToolCall) async -> AgentToolList? {
        guard let sessionID = authorizedSession(call) else { return nil }
        let tools = await tools(for: sessionID)
        return AgentToolList(tools: tools, fingerprint: await Self.fingerprint(of: tools))
    }

    /// Encoding a connector catalog can take hundreds of milliseconds; never run it on the UI actor.
    private nonisolated static func fingerprint(of tools: [ToolJSON]) async -> String {
        await Task.detached(priority: .utility) {
            AgentToolListWatching.fingerprint(of: tools)
        }.value
    }

    private func tools(for sessionID: UUID) async -> [ToolJSON] {
        let compact = usesCompactToolSurface(for: sessionID)
        let browserOn = browserToolsByTask[sessionID] != false
        let browserDefinitions = browserOn ? AgentToolCatalog.browserTools : []
        let vaultDefinitions = browserOn && vault?.offersTool == true ? [VaultToolCatalog.tool] : []
        let simulatorUsable = simulatorToolsByTask[sessionID] == true && simulators?.simulatorPlatformIsUsable == true
        let simulatorDefinitions: [AgentToolDefinition]
        if simulatorUsable {
            simulatorDefinitions = compact ? SimulatorGatewayToolCatalog.tools : SimulatorToolCatalog.tools
        } else {
            simulatorDefinitions = []
        }
        let suggestionDefinitions = suggestions == nil ? [] : TaskSuggestionToolCatalog.tools
        let widgetDefinitions = offersWidget(to: sessionID) ? [WidgetToolCatalog.tool] : []
        let sessionDefinitions = sessions == nil ? [] : (SessionToolCatalog.tools + SettingsToolCatalog.tools)
        let terminalDefinitions = sessions != nil && sharesTerminal() ? [TerminalToolCatalog.tool] : []
        let scheduleDefinitions = schedules == nil ? [] : ScheduleToolCatalog.tools
        let coreDefinitions = browserDefinitions + vaultDefinitions + simulatorDefinitions + suggestionDefinitions
            + widgetDefinitions + sessionDefinitions + terminalDefinitions + scheduleDefinitions
        let coreTools = compact ? AntigravityCompactTools.compact(coreDefinitions) : coreDefinitions.map(\.json)

        let codeMode = CodeModePreference.isSupported && codeModeEnabled()
        let codeModeTools = codeMode ? CodeModeToolCatalog.tools.map(\.json) : []

        let connectorTools = await filteredConnectorTools(for: sessionID)
        let exposedConnectorTools: [ToolJSON]
        if codeMode {
            // In Code Mode, connector tools are discovered via `search_yardlet_tools` and invoked
            // via `run_yardlet_script` (and remain directly callable by name), keeping upfront schemas small.
            exposedConnectorTools = []
        } else if compact, !connectorTools.isEmpty {
            let services = connectors?.serviceNames(for: connectorContext(sessionID)) ?? []
            exposedConnectorTools = ConnectorGatewayToolCatalog.tools(services: services).map(\.json)
        } else {
            exposedConnectorTools = connectorTools
        }
        return coreTools + codeModeTools + exposedConnectorTools
    }

    // MARK: Tool list changes

    /// Holds a `tools/watch` until the task's list differs from `arguments.fingerprint` while the
    /// task is between turns (`changed: true`), until the task is explicitly released (`released: true`),
    /// or until `toolListWatchHold` passes (`changed: false`). Nil when the call's token does not match.
    func watch(_ call: AgentToolCall) async -> AgentToolListWatchReply? {
        if let sessionID = UUID(uuidString: call.session), releasedTokens[call.token] == sessionID {
            return AgentToolListWatchReply(changed: false, released: true)
        }
        guard let sessionID = authorizedSession(call) else { return nil }
        let fingerprint = call.arguments["fingerprint"]?.stringValue
        let id = UUID()
        let hold = toolListWatchHold
        return await withCheckedContinuation { continuation in
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                self?.finishToolListWatch(id, of: sessionID, reply: AgentToolListWatchReply(changed: false))
            }
            toolListWatches[sessionID, default: [:]][id] = ToolListWatch(
                fingerprint: fingerprint, continuation: continuation, expiry: expiry)
            Task { [weak self] in await self?.tellToolListChanges(to: sessionID) }
        }
    }

    /// Something a task's tools are made from changed (`ConnectorCenter.onToolsChanged`). Once the
    /// burst settles, each watched task between turns whose list now differs is told.
    func toolsMayHaveChanged() {
        pendingToolListCheck?.cancel()
        let delay = toolListSettleDelay
        pendingToolListCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            for sessionID in Array(self.toolListWatches.keys) {
                await self.tellToolListChanges(to: sessionID)
            }
        }
    }

    /// The task's turn ended: what the agent set on its browser tabs for the turn goes, and a change to its tools
    /// held for the turn is told now.
    func taskTurnEnded(_ localSessionID: UUID) {
        Task { [tools] in await tools.taskTurnEnded(localSessionID) }
        guard toolListWatches[localSessionID] != nil else { return }
        Task { [weak self] in await self?.tellToolListChanges(to: localSessionID) }
    }

    /// Answers each of the task's watches whose list no longer matches, when the task is between
    /// turns; a task in a turn keeps them until `taskTurnEnded`.
    private func tellToolListChanges(to sessionID: UUID) async {
        guard toolListWatches[sessionID]?.isEmpty == false, tokens[sessionID] != nil, !isTaskInTurn(sessionID) else { return }
        let current = await Self.fingerprint(of: await tools(for: sessionID))
        // A turn may have begun while the list was made.
        guard !isTaskInTurn(sessionID) else { return }
        for (id, watch) in toolListWatches[sessionID] ?? [:] where watch.fingerprint != current {
            finishToolListWatch(id, of: sessionID, reply: AgentToolListWatchReply(changed: true))
        }
    }

    private func finishToolListWatch(_ id: UUID, of sessionID: UUID, reply: AgentToolListWatchReply) {
        guard let watch = toolListWatches[sessionID]?.removeValue(forKey: id) else { return }
        if toolListWatches[sessionID]?.isEmpty == true { toolListWatches.removeValue(forKey: sessionID) }
        watch.expiry.cancel()
        watch.continuation.resume(returning: reply)
    }

    /// Watches held now, per task (tests).
    func heldToolListWatchCount(for sessionID: UUID) -> Int {
        toolListWatches[sessionID]?.count ?? 0
    }

    /// The endpoint's entry: one framed call body in, from the process `peer`, one result body out.
    func respond(to body: Data, peer: Int32? = nil) async -> Data {
        guard let call = try? JSONDecoder().decode(AgentToolCall.self, from: body) else {
            return (try? JSONEncoder().encode(AgentToolResult.error("Yardlet could not read this tool call."))) ?? Data()
        }
        if let check = callerProcessCheck, let session = UUID(uuidString: call.session), tokens[session] != nil,
           !check(session, peer) {
            return (try? JSONEncoder().encode(Self.foreignCaller)) ?? Data()
        }
        if call.method == AgentToolCall.watchMethod {
            // A refused watch is an error result, which the server cannot read as an answer, so it
            // stops asking for a while.
            guard let reply = await watch(call) else { return (try? JSONEncoder().encode(Self.unrecognizedToken)) ?? Data() }
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
        if call.method == AgentToolCall.listMethod {
            if let sessionID = UUID(uuidString: call.session), releasedTokens[call.token] == sessionID {
                let empty = AgentToolList(tools: [], fingerprint: nil, released: true)
                return (try? JSONEncoder().encode(empty)) ?? Data()
            }
            // A refused list is an error result, which the server cannot read as a list, so the
            // harness sees the browser catalog and the first call explains the token.
            guard let list = await list(call) else { return (try? JSONEncoder().encode(Self.unrecognizedToken)) ?? Data() }
            return (try? JSONEncoder().encode(list)) ?? Data()
        }
        return (try? JSONEncoder().encode(await handle(call))) ?? Data()
    }

    private func authorizedSession(_ call: AgentToolCall) -> UUID? {
        guard let sessionID = UUID(uuidString: call.session),
              let expected = tokens[sessionID],
              Self.constantTimeEqual(expected, call.token)
        else { return nil }
        return sessionID
    }

    private static let foreignCaller = AgentToolResult.error(
        "Yardlet refused this call: it did not come from the tool server the task's harness started. Start or "
            + "resume the task in Yardlet to use its tools."
    )

    private static let unrecognizedToken = AgentToolResult.error(
        "Yardlet does not recognise this task's tool token. Start or resume the task in Yardlet again to use "
            + "its browser and connector tools."
    )

    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in
            let value = generator.next()
            let hex = String(value, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
