import Foundation
import YardletAgentTools

/// The task a connector tool list or call is for, and what Yardlet knew of its harness when the
/// task was injected (`ConnectorTaskScope`; nil for a stand-in task).
struct ConnectorToolContext: Equatable, Sendable {
    var taskID: UUID?
    var scope: ConnectorTaskScope?
    /// The task's folders, primary first, where a Gmail attachment may come from.
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
}

/// Yardlet's task suggestion tools (`spawn_task`, `dismiss_task`), answered by the app, which keeps
/// what became of each chip with the task that suggested it.
@MainActor
protocol TaskSuggestionToolHandling: AnyObject {
    func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult
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

/// Yardlet's scheduled-task tools (`ScheduleToolCatalog`), answered by the app against its scheduler
/// (docs/AGENT_BROWSER_TOOLS.md, "Scheduled-task tools"): an agent creates, lists, changes, deletes and runs the person's schedules.
@MainActor
protocol ScheduleToolHandling: AnyObject {
    func callScheduleTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult
}

/// The app side of the Yardlet MCP server. It issues each task a random token when the task's
/// harness session is injected, and runs a call only when its token and task match. The local
/// endpoint that carries calls here is platform code; this type only sees decoded calls.
///
/// A task gets the server when the app answers the task suggestion tools, which every task has,
/// or else when the browser tools are on or a connector is connected. Whether the browser tools
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
    /// What each task's harness was found to load itself when the task was injected.
    private var connectorScopes: [UUID: ConnectorTaskScope] = [:]
    var connectors: (any ConnectorToolProviding)?
    /// The app, which answers `spawn_task` and `dismiss_task`. Nil, as in tests, offers neither.
    weak var suggestions: (any TaskSuggestionToolHandling)?
    /// The app, which answers the session tools. Nil, as in tests, offers none.
    weak var sessions: (any SessionToolHandling)?
    /// The app, which answers the scheduled-task tools. Nil, as in tests, offers none.
    weak var schedules: (any ScheduleToolHandling)?
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
        let continuation: CheckedContinuation<Bool, Never>
        let expiry: Task<Void, Never>
    }
    private var toolListWatches: [UUID: [UUID: ToolListWatch]] = [:]
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
        guard browserTools || suggestions != nil || sessions != nil || schedules != nil || connectors?.offersTools == true,
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
        connectorScopes[localSessionID] = connectorScope
        return AgentToolServerLaunch(
            command: executable.path(percentEncoded: false),
            environment: [
                AgentToolEnvironment.endpoint: environment.endpoint,
                AgentToolEnvironment.token: token,
                AgentToolEnvironment.session: localSessionID.uuidString,
                AgentToolEnvironment.appProcess: String(ProcessInfo.processInfo.processIdentifier)
            ],
            privateDirectory: environment.privateDirectory,
            leftOutServerURLs: connectorScope?.leftOutNativeServers.map(\.url) ?? []
        )
    }

    /// Values the vault filled for the person in a tab the agent may read: no result carries them.
    func noteVaultValues(_ values: [String?]) {
        values.forEach { tools.vaultScrub.add($0) }
    }

    /// Text from a page with the values the vault filled lately taken out, as tool results have them.
    func scrubVaultValues(_ text: String) -> String {
        tools.vaultScrub.scrub(text)
    }

    /// Whether text (an address, a title) carries a value the vault filled lately, in any spelling it scrubs.
    func carriesVaultValue(_ text: String) -> Bool {
        tools.vaultScrub.carries(text)
    }

    /// Ends a task's token and closes its browser tab.
    func releaseAgentTools(for localSessionID: UUID) {
        for id in Array((toolListWatches[localSessionID] ?? [:]).keys) {
            finishToolListWatch(id, of: localSessionID, changed: false)
        }
        tokens.removeValue(forKey: localSessionID)
        workspaceRoots.removeValue(forKey: localSessionID)
        browserToolsByTask.removeValue(forKey: localSessionID)
        connectorScopes.removeValue(forKey: localSessionID)
        tools.closeTab(for: localSessionID)
    }

    /// A stand-in task's launch, with no harness to scope its connectors (QA, tests).
    func agentToolServer(for localSessionID: UUID, workspaceRoots roots: [URL]) -> AgentToolServerLaunch? {
        agentToolServer(for: localSessionID, workspaceRoots: roots, connectorScope: nil)
    }

    /// The scope recorded for a task when it was last injected.
    func connectorScope(for localSessionID: UUID) -> ConnectorTaskScope? {
        connectorScopes[localSessionID]
    }

    private func connectorContext(_ sessionID: UUID) -> ConnectorToolContext {
        ConnectorToolContext(taskID: sessionID, scope: connectorScopes[sessionID],
                             workspaceRoots: workspaceRoots[sessionID] ?? [])
    }

    func handle(_ call: AgentToolCall) async -> AgentToolResult {
        guard let sessionID = authorizedSession(call) else { return Self.unrecognizedToken }
        // Yardlet's own tools are checked against the schemas they are listed with before they run; a
        // connector's are checked where its tools are known (`ConnectorCenter.callConnectorTool`).
        if let definition = Self.ownDefinition(named: call.tool),
           let failure = AgentToolArgumentCheck.failure(tool: call.tool, arguments: call.arguments,
                                                        schema: definition.inputSchema) {
            return failure
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
        if SessionToolCatalog.definition(named: call.tool) != nil, let sessions {
            return await sessions.callSessionTool(named: call.tool, arguments: call.arguments, callerID: sessionID)
        }
        if ScheduleToolCatalog.definition(named: call.tool) != nil, let schedules {
            return await schedules.callScheduleTool(named: call.tool, arguments: call.arguments, callerID: sessionID)
        }
        if let result = await connectors?.callConnectorTool(named: call.tool, arguments: call.arguments,
                                                             for: connectorContext(sessionID)) {
            return result
        }
        return await unknownTool(call.tool, for: sessionID)
    }

    private static func ownDefinition(named name: String) -> AgentToolDefinition? {
        AgentToolCatalog.definition(named: name) ?? VaultToolCatalog.definition(named: name)
            ?? TaskSuggestionToolCatalog.definition(named: name) ?? SessionToolCatalog.definition(named: name)
            ?? ScheduleToolCatalog.definition(named: name)
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

    /// The task's tools: the browser catalog when it was on, the task suggestion tools, the session
    /// tools, the scheduled-task tools, then connected connectors' tools, less any whose name is one of Yardlet's own (a
    /// connector slug and tool can spell `spawn_task`), with their fingerprint. Nil when the
    /// call's token does not match.
    func list(_ call: AgentToolCall) async -> AgentToolList? {
        guard let sessionID = authorizedSession(call) else { return nil }
        let tools = await tools(for: sessionID)
        return AgentToolList(tools: tools, fingerprint: AgentToolListWatching.fingerprint(of: tools))
    }

    private func tools(for sessionID: UUID) async -> [ToolJSON] {
        let browserOn = browserToolsByTask[sessionID] != false
        let browser = browserOn ? AgentToolCatalog.browserTools.map(\.json) : []
        let vaultTools = browserOn && vault?.offersTool == true ? [VaultToolCatalog.tool.json] : []
        let suggestionTools = suggestions == nil ? [] : TaskSuggestionToolCatalog.tools.map(\.json)
        let sessionTools = sessions == nil ? [] : SessionToolCatalog.tools.map(\.json)
        let scheduleTools = schedules == nil ? [] : ScheduleToolCatalog.tools.map(\.json)
        let ownNames = Set((TaskSuggestionToolCatalog.tools + SessionToolCatalog.tools + ScheduleToolCatalog.tools
            + [VaultToolCatalog.tool]).map(\.name))
        let connectorTools = (await connectors?.connectorTools(for: connectorContext(sessionID)) ?? []).filter {
            !ownNames.contains($0["name"]?.stringValue ?? "")
        }
        return browser + vaultTools + suggestionTools + sessionTools + scheduleTools + connectorTools
    }

    // MARK: Tool list changes

    /// Holds a `tools/watch` until the task's list differs from `arguments.fingerprint` while the
    /// task is between turns (`true`), or until `toolListWatchHold` passes (`false`). Nil when the
    /// call's token does not match.
    func watch(_ call: AgentToolCall) async -> AgentToolListWatchReply? {
        guard let sessionID = authorizedSession(call) else { return nil }
        let fingerprint = call.arguments["fingerprint"]?.stringValue
        let id = UUID()
        let hold = toolListWatchHold
        let changed = await withCheckedContinuation { continuation in
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                self?.finishToolListWatch(id, of: sessionID, changed: false)
            }
            toolListWatches[sessionID, default: [:]][id] = ToolListWatch(
                fingerprint: fingerprint, continuation: continuation, expiry: expiry)
            Task { [weak self] in await self?.tellToolListChanges(to: sessionID) }
        }
        return AgentToolListWatchReply(changed: changed)
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
        let current = AgentToolListWatching.fingerprint(of: await tools(for: sessionID))
        // A turn may have begun while the list was made.
        guard !isTaskInTurn(sessionID) else { return }
        for (id, watch) in toolListWatches[sessionID] ?? [:] where watch.fingerprint != current {
            finishToolListWatch(id, of: sessionID, changed: true)
        }
    }

    private func finishToolListWatch(_ id: UUID, of sessionID: UUID, changed: Bool) {
        guard let watch = toolListWatches[sessionID]?.removeValue(forKey: id) else { return }
        if toolListWatches[sessionID]?.isEmpty == true { toolListWatches.removeValue(forKey: sessionID) }
        watch.expiry.cancel()
        watch.continuation.resume(returning: changed)
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
