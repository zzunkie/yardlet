import Foundation

actor ACPAdapter:
    HarnessAdapter,
    ProviderCapabilityProviding,
    HarnessPermissionActionResponding,
    HarnessWorkspaceRootsConfiguring,
    HarnessImageInputReporting,
    HarnessAgentToolConfiguring,
    HarnessYardletInstructionsConfiguring,
    HarnessModelCatalogReporting,
    HarnessInterruptedTurnContinuing,
    HarnessLaunchOptionConfiguring {
    private struct PermissionContext: Sendable {
        let localSessionID: UUID
        /// The process that asked, which takes the answer.
        let transport: any ACPTransport
        let rpcID: JSONValue
        let allowOptionID: String?
        let denyOptionID: String?
        let optionIDs: Set<String>
    }

    private struct AssistantStreamState: Sendable {
        var messageID: String?
        var text: String
    }

    nonisolated let kind: HarnessKind

    private let executableURL: URL
    private let launchArguments: [String]
    private let launchEnvironmentOverrides: [String: String]
    private let transportFactory: @Sendable () -> any ACPTransport
    /// The processes the open sessions share, one per lane (`ACPProcessLane`), each started by the
    /// first session that needs it. A stopped transport cannot start again, so a lane whose process
    /// stopped starts a new one for its next session.
    private var processes: [ACPProcessLane: ACPAgentProcess] = [:]
    private var laneByLocalSessionID: [UUID: ACPProcessLane] = [:]
    /// A session's move to another lane in progress (`moveToItsLane`), which its next prompt and
    /// option wait for.
    private var laneMoves: [UUID: Task<Void, Error>] = [:]
    /// Antigravity's copies of the tool schemas, which go once the process that wrote them has
    /// exited (`AntigravitySchemaCopies`); nil for the other agents.
    private let schemaCopies: AntigravitySchemaCopies?
    private let projector = ACPEventProjector()
    private let capabilityProjector = ACPCapabilityProjector()

    private var canLoadSession = false
    /// The agent's `initialize` answer on stdio MCP servers; ACP makes them mandatory.
    private var acceptsStdioMCPServers = true
    /// nil until the agent has answered `initialize`.
    private var advertisesImagePrompts: Bool?
    private var nextRequestID: Int64 = 1
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var localSessionIDByProviderID: [String: UUID] = [:]
    private var permissions: [String: PermissionContext] = [:]
    private var activities: [UUID: [String: ACPToolCallState]] = [:]
    /// Order of terminal (`.completed` / `.failed`) tool call IDs per session for bounded pruning.
    private var terminalActivityOrder: [UUID: [String]] = [:]
    private static let maxRetainedTerminalActivities = 128
    private var eventChannel = HarnessEventChannel()
    private var capabilityStateByLocalSessionID: [UUID: ProviderCapabilityState] = [:]
    private var capabilitySourceByLocalSessionID: [UUID: JSONValue] = [:]
    private var usesLegacyModeByLocalSessionID: Set<UUID> = []
    private var usesSessionModelByLocalSessionID: Set<UUID> = []
    private var usesGrokMetadataEffortByLocalSessionID: Set<UUID> = []
    private var assistantStreamByLocalSessionID: [UUID: AssistantStreamState] = [:]
    private var additionalRootsByLocalSessionID: [UUID: [URL]] = [:]
    private var agentToolServerByLocalSessionID: [UUID: AgentToolServerLaunch] = [:]
    private var yardletInstructionsByLocalSessionID: [UUID: YardletInstructionsDelivery] = [:]
    /// Antigravity: the permission mode, which picks the session's lane and how Yardlet answers
    /// approvals, and the models the session listed (`AntigravityACPOptions`).
    private var antigravityPermissionModeByLocalSessionID: [UUID: String] = [:]
    private var antigravityModelsByLocalSessionID: [UUID: [ProviderCapabilityChoice]] = [:]
    /// Sessions loaded since their last prompt. `session/load` replays the conversation as session
    /// updates, some of which can reach `accept` after the load's answer registered the session; the
    /// task already shows that history (its read cache, or the replay `ACPSessionHistory` read), so
    /// what the agent says of its messages, thinking, tool calls and plan before the next prompt is
    /// not a turn of this task.
    private var replayingProviderSessionIDs: Set<String> = []
    /// Antigravity: the conversations' store, for the turns the agent starts between prompts, which
    /// `agy acp` does not stream (`AntigravityAgentTurnFollower`); nil for the other agents.
    private let conversationStore: AntigravityConversationStore?
    private let agentTurnReadInterval: Duration
    private var agentTurnFollowers: [UUID: AntigravityAgentTurnFollower] = [:]
    private var agentTurnReadTasks: [UUID: Task<Void, Never>] = [:]
    private var redeliveries: [UUID: AntigravityRedelivery] = [:]
    /// Antigravity: the CLI's latest notice of the prompt running (`AntigravityNotice`) while nothing
    /// the agent did has followed it. A prompt that ends there failed with its words; a step after it
    /// shows it as the words it was.
    private var heldNotices: [UUID: HeldNotice] = [:]

    private struct HeldNotice {
        let chunk: String
        let messageID: String?
        let words: String
    }

    init(
        kind: HarnessKind,
        executableURL: URL,
        launchArguments: [String]? = nil,
        launchEnvironmentOverrides: [String: String]? = nil,
        schemaCopies: AntigravitySchemaCopies? = nil,
        conversationStore: AntigravityConversationStore? = nil,
        agentTurnReadInterval: Duration = .seconds(2),
        transportFactory: (@Sendable () -> any ACPTransport)? = nil
    ) {
        self.kind = kind
        self.executableURL = executableURL.standardizedFileURL
        self.launchArguments = launchArguments
            ?? HarnessCatalog.descriptor(for: kind)?.launchArguments
            ?? []
        self.launchEnvironmentOverrides = launchEnvironmentOverrides ?? [:]
        self.schemaCopies = schemaCopies
        self.conversationStore = conversationStore
        self.agentTurnReadInterval = agentTurnReadInterval
        self.transportFactory = transportFactory ?? { ACPProcessTransport(executableURL: executableURL) }
    }

    /// Antigravity's saved permission mode, before its session starts, so a session in Bypass
    /// permissions starts on the process that approves for itself (`ACPProcessLane`).
    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) {
        guard kind == .antigravityCLI else { return }
        let saved = options[AntigravityPermissionMode.optionID] ?? options[StructuredHeadlessOptionID.executionMode]
        antigravityPermissionModeByLocalSessionID[localSessionID] = saved
    }

    /// The project's other roots, held for the launch this session triggers. ACP `session/new`
    /// has no field for them and Yardlet adds no private one, so they reach the agent only
    /// through a flag its own executable documents — today none of the ACP CLIs has one, and
    /// the process then starts with exactly the catalog's arguments.
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
        if roots.isEmpty {
            additionalRootsByLocalSessionID.removeValue(forKey: localSessionID)
        } else {
            additionalRootsByLocalSessionID[localSessionID] = roots.map(\.standardizedFileURL)
        }
    }

    /// The Yardlet MCP server for the session this task creates or loads, sent in `mcpServers`.
    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) {
        agentToolServerByLocalSessionID[localSessionID] = server
    }

    /// Yardlet instructions for the session this task creates or loads, as Grok's `_meta.rules` on the
    /// session request, or Antigravity's `_meta.antigravity.systemPrompt` on `session/new` only, since
    /// the CLI keeps that text with the conversation (`YardletInstructionsRoute`). The other ACP agents
    /// document no per-session route and receive nothing.
    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) {
        yardletInstructionsByLocalSessionID[localSessionID] = instructions
    }

    private func sessionMeta(for localSessionID: UUID, loading: Bool) -> JSONValue? {
        let text = yardletInstructionsByLocalSessionID[localSessionID]?.text
        switch YardletInstructionsRoute.route(for: kind) {
        case .grokSessionRules: return YardletInstructionsLaunch.grokSessionMeta(text)
        case .antigravitySystemPrompt: return loading ? nil : YardletInstructionsLaunch.antigravitySessionMeta(text)
        default: return nil
        }
    }

    /// Only after `initialize`, so an agent that turned stdio MCP servers down gets none.
    private func mcpServers(for localSessionID: UUID) -> [JSONValue] {
        guard acceptsStdioMCPServers, let server = agentToolServerByLocalSessionID[localSessionID] else { return [] }
        return [server.acpServer]
    }

    /// What this agent answered for `promptCapabilities.image` during `initialize`, or nil while
    /// the handshake has not happened. The value belongs to the connection, so every session on
    /// this adapter reads the same answer.
    func acceptsImageInput(for localSessionID: UUID) -> Bool? {
        advertisesImagePrompts
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        guard ExecutableLookup.current.isProgram(executableURL) else {
            throw HarnessAdapterError.runtimeNotFound(executableURL)
        }
        let version = try readVersion()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: executableURL.path(percentEncoded: false)
        )
        let fingerprint = [
            executableURL.path(percentEncoded: false),
            version,
            (attributes[.size] as? NSNumber)?.stringValue ?? "unknown-size",
            (attributes[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) }
                ?? "unknown-mtime"
        ].joined(separator: "|")
        return HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: executableURL,
            version: version,
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                // Image input is the agent's own answer to `initialize`, for every ACP agent
                // alike; until it has answered, none is claimed on its behalf.
                acceptsImages: advertisesImagePrompts ?? false,
                // No ACP projection carries subagent activity, whatever the agent documents.
                hasSubagents: false
            ),
            fingerprint: fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        let lane = lane(for: request.localSessionID)
        let transport = try await ensureInitialized(
            lane,
            workspaceURL: request.workspaceURL,
            localSessionID: request.localSessionID
        )
        do {
            let id = takeRequestID()
            let result = try await transport.request(
                ACPProtocol.newSession(
                    id: id,
                    workspaceURL: request.workspaceURL,
                    mcpServers: mcpServers(for: request.localSessionID),
                    meta: sessionMeta(for: request.localSessionID, loading: false)
                ),
                id: id
            )
            guard let providerSessionID = result["sessionId"]?.stringValue else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("ACP session/new response is missing sessionId")
                )
            }
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: request.localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: request.workspaceURL.standardizedFileURL
            )
            rememberCapabilities(result, for: handle)
            register(handle, on: lane)
            if let prompt = request.initialPrompt, !prompt.isEmpty {
                try await send(prompt, to: handle)
            }
            return handle
        } catch {
            await stopProcessIfUnused(lane, used: transport)
            throw error
        }
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        // A print-mode Antigravity task that never ran a turn has no conversation to load yet.
        if kind == .antigravityCLI,
           AntigravityACPOptions.isPrintModePlaceholder(providerSessionID, localSessionID: localSessionID) {
            return try await createSession(CreateHarnessSessionRequest(
                localSessionID: localSessionID, workspaceURL: workspaceURL, initialPrompt: nil))
        }
        let lane = lane(for: localSessionID)
        let transport = try await ensureInitialized(lane, workspaceURL: workspaceURL, localSessionID: localSessionID)
        guard canLoadSession else {
            await stopProcessIfUnused(lane, used: transport)
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format(
                    "%@ does not advertise ACP session loading",
                    kind.displayName
                )
            )
        }
        replayingProviderSessionIDs.insert(providerSessionID)
        do {
            let id = takeRequestID()
            let result = try await transport.request(
                ACPProtocol.loadSession(
                    id: id,
                    providerSessionID: providerSessionID,
                    workspaceURL: workspaceURL,
                    mcpServers: mcpServers(for: localSessionID),
                    meta: sessionMeta(for: localSessionID, loading: true)
                ),
                id: id
            )
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: workspaceURL.standardizedFileURL
            )
            rememberCapabilities(result, for: handle)
            register(handle, on: lane)
            return handle
        } catch {
            replayingProviderSessionIDs.remove(providerSessionID)
            await stopProcessIfUnused(lane, used: transport)
            throw error
        }
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await sendPrompt(text: prompt, images: [], to: session)
    }

    /// An ACP agent only receives image blocks it advertised room for. Refusing here keeps the
    /// attachment in the composer instead of sending a prompt the agent never agreed to read.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        let images = input.images.isEmpty ? [] : try requireAdvertisedImages(input)
        try await sendPrompt(text: input.promptText, images: images, to: session)
    }

    private func requireAdvertisedImages(
        _ input: HarnessUserInput
    ) throws -> [HarnessUserInput.EncodedImage] {
        guard advertisesImagePrompts == true else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("%@ does not advertise ACP image prompts", kind.displayName)
            )
        }
        return try input.encodedImages()
    }

    private func sendPrompt(
        text: String,
        images: [HarnessUserInput.EncodedImage],
        to session: HarnessSessionHandle
    ) async throws {
        await waitForLaneMove(of: session.localSessionID)
        try requireRegistered(session)
        guard promptTasks[session.localSessionID] == nil else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("An ACP prompt is already running")
            )
        }
        replayingProviderSessionIDs.remove(session.providerSessionID)
        stopFollowingAgentTurns(of: session.localSessionID)
        // Any assistant stream or notice left over from an autonomous turn was already shown as deltas
        // and finalized when the new request was appended; drop it so it cannot flush into the new turn.
        heldNotices.removeValue(forKey: session.localSessionID)
        assistantStreamByLocalSessionID.removeValue(forKey: session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        let id = takeRequestID()
        let transport = transport(of: session.localSessionID)
        promptTasks[session.localSessionID] = Task { [weak self] in
            do {
                let result = try await transport.requestWithoutTimeout(
                    ACPProtocol.prompt(
                        id: id,
                        providerSessionID: session.providerSessionID,
                        text: text,
                        images: images
                    ),
                    id: id
                )
                if let usage = ACPEventProjector().usage(from: result) {
                    await self?.emit(.usageUpdated(usage), for: session.localSessionID)
                }
                // ACP notifications and the prompt response share stdout, but the transport
                // hands notifications to an AsyncStream. Give the ordered notification queue a
                // brief chance to drain before closing the turn so the final text cannot arrive
                // after turnCompleted on a busy UI thread.
                try? await Task.sleep(for: .milliseconds(20))
                await self?.finishPrompt(for: session, stopReason: result["stopReason"]?.stringValue)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failPrompt(error, for: session)
            }
        }
    }

    /// Continues a turn Yardlet's quit cut off, on the session loaded again: the Claude app's words go
    /// as the next prompt (`RestartContinuation`), since ACP has no request for it and none of these
    /// agents' own clients continues such a turn (`RestartResumePolicy`). Nothing goes while a prompt
    /// runs.
    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool {
        try requireRegistered(session)
        guard promptTasks[session.localSessionID] == nil else { return false }
        try await sendPrompt(text: RestartContinuation.claudeText(after: cut), images: [], to: session)
        return true
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        let pendingRequestIDs = permissions.compactMap { requestID, context in
            context.localSessionID == session.localSessionID ? requestID : nil
        }
        for requestID in pendingRequestIDs {
            guard let context = permissions[requestID] else { continue }
            try await context.transport.send(
                ACPProtocol.permissionResponse(id: context.rpcID, optionID: nil)
            )
            permissions.removeValue(forKey: requestID)
        }
        try await transport(of: session.localSessionID).send(
            ACPProtocol.cancel(providerSessionID: session.providerSessionID)
        )
        // A prompt's turn ends with its answer; an agent's own turn has no answer to wait for.
        emitAgentTurnPayloads(agentTurnFollowers[session.localSessionID]?.stop() ?? [], for: session.localSessionID)
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard let context = permissions.removeValue(forKey: permissionRequestID),
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Unknown or already-resolved ACP permission request")
            )
        }
        let optionID = decision == .allow ? context.allowOptionID : context.denyOptionID
        try await context.transport.send(
            ACPProtocol.permissionResponse(id: context.rpcID, optionID: optionID)
        )
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard let context = permissions.removeValue(forKey: permissionRequestID),
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Unknown or already-resolved ACP permission request")
            )
        }
        guard context.optionIDs.contains(selectedActionID) else {
            permissions[permissionRequestID] = context
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("ACP permission action is not available")
            )
        }
        try await context.transport.send(
            ACPProtocol.permissionResponse(id: context.rpcID, optionID: selectedActionID)
        )
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = eventChannel.subscribe(to: session.localSessionID)
        // A session that ended with its process before anyone listened ends at once, after its events.
        if handles[session.localSessionID] != session { eventChannel.finish(session.localSessionID) }
        return stream
    }

    func providerCapabilities(for session: HarnessSessionHandle) async throws
        -> ProviderCapabilityState {
        try requireRegistered(session)
        var state = capabilityStateByLocalSessionID[session.localSessionID]
            ?? capabilityProjector.state(from: .object([:]), harness: kind)
        state.acceptsImageInput = advertisesImagePrompts
        return presented(state, for: session.localSessionID)
    }

    /// The session's controls as Yardlet shows them: Antigravity's under the names its tasks keep and
    /// Yardlet's menus use, with its permission mode (`AntigravityACPOptions`).
    private func presented(_ state: ProviderCapabilityState, for localSessionID: UUID) -> ProviderCapabilityState {
        guard kind == .antigravityCLI else { return state }
        return AntigravityACPOptions.project(state, permissionMode: antigravityPermissionModeByLocalSessionID[localSessionID])
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        await waitForLaneMove(of: session.localSessionID)
        try requireRegistered(session)
        guard kind == .antigravityCLI else {
            return try await setSessionOption(id: id, value: value, in: session)
        }
        let current = capabilityStateByLocalSessionID[session.localSessionID]
            ?? capabilityProjector.state(from: .object([:]), harness: kind)
        var state = current
        switch try AntigravityACPOptions.step(id: id, value: value, selectors: current.selectors,
                                              models: antigravityModelsByLocalSessionID[session.localSessionID] ?? []) {
        case let .permission(mode, sessionMode):
            let previous = antigravityPermissionModeByLocalSessionID[session.localSessionID]
            antigravityPermissionModeByLocalSessionID[session.localSessionID] = mode
            do {
                // The session's own mode changes at once, as in the CLI, also for a prompt running. A
                // move to another lane loads the conversation with it.
                if let sessionMode {
                    state = try await setSessionOption(
                        id: AntigravityACPOptions.sessionModeConfigID, value: sessionMode, in: session)
                }
                // A prompt running finishes where it started, and the session moves when it ends.
                if promptTasks[session.localSessionID] == nil { try await moveToItsLane(session) }
            } catch {
                antigravityPermissionModeByLocalSessionID[session.localSessionID] = previous
                throw error
            }
            state = capabilityStateByLocalSessionID[session.localSessionID] ?? state
        case let .send(values):
            for config in values {
                state = try await setSessionOption(id: config.id, value: config.value, in: session)
            }
        case .none:
            break
        }
        state.acceptsImageInput = advertisesImagePrompts
        return presented(state, for: session.localSessionID)
    }

    private func setSessionOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let requestID = takeRequestID()
        let request: JSONValue
        if id == "model",
           usesSessionModelByLocalSessionID.contains(session.localSessionID) {
            request = ACPProtocol.setModel(
                id: requestID,
                providerSessionID: session.providerSessionID,
                modelID: value
            )
        } else if id == "reasoning_effort",
                  usesGrokMetadataEffortByLocalSessionID.contains(session.localSessionID),
                  let modelID = capabilityStateByLocalSessionID[session.localSessionID]?
                    .selectors.first(where: { $0.id == "model" })?.currentValue {
            request = ACPProtocol.setModel(
                id: requestID,
                providerSessionID: session.providerSessionID,
                modelID: modelID,
                reasoningEffort: value
            )
        } else if usesLegacyModeByLocalSessionID.contains(session.localSessionID) && id == "mode" {
            request = ACPProtocol.setMode(
                id: requestID,
                providerSessionID: session.providerSessionID,
                modeID: value
            )
        } else {
            request = ACPProtocol.setConfigOption(
                id: requestID,
                providerSessionID: session.providerSessionID,
                configID: id,
                value: value
            )
        }
        let result = try await transport(of: session.localSessionID).request(request, id: requestID)
        var state = capabilityStateByLocalSessionID[session.localSessionID]
            ?? capabilityProjector.state(from: .object([:]), harness: kind)
        let projected = capabilityProjector.configOptions(from: result)
        if !projected.isEmpty {
            state.selectors = projected
            usesLegacyModeByLocalSessionID.remove(session.localSessionID)
        } else if id == "model",
                  let source = capabilitySourceByLocalSessionID[session.localSessionID] {
            let currentEffort = state.selectors.first(where: {
                $0.id == "reasoning_effort"
            })?.currentValue
            state.selectors = capabilityProjector.selectors(
                from: source,
                harness: kind,
                selectedModelID: value,
                selectedReasoningEffort: currentEffort
            )
        } else if let index = state.selectors.firstIndex(where: { $0.id == id }) {
            state.selectors[index].currentValue = value
        }
        state.actionMessage = L10n.format("%@ updated", state.selectors.first {
            $0.id == id
        }?.name ?? id)
        state.acceptsImageInput = advertisesImagePrompts
        capabilityStateByLocalSessionID[session.localSessionID] = state
        return state
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.string("This ACP session does not expose that action")
        )
    }

    func close(_ session: HarnessSessionHandle) async {
        let lane = laneByLocalSessionID[session.localSessionID]
        let wasOpen = forget(session)
        eventChannel.close(session.localSessionID)
        // Closing the last open session of a process ends it, and closing one of several tells the
        // process (`release`); closing a session again, or one whose process already ended, leaves
        // alone a process started since.
        if wasOpen, let lane, let process = processes[lane] {
            await release(session.providerSessionID, on: lane, from: process.transport)
        }
    }

    /// Lets `transport`, `lane`'s process, drop `providerSessionID`, which no open session holds there
    /// any more: a process no open session uses ends, and one that goes on serving others is told with
    /// `session/close` if it advertised it, so the agent can let go of what it keeps for that session,
    /// such as its MCP servers. Without that the agent keeps the session for as long as its process runs.
    /// The request is written before anything sent after it, so a later `session/load` of the same
    /// conversation reaches the agent after it, and no one waits for its answer, which `accept` drops:
    /// a slow or failed one holds up neither the close nor the next session.
    private func release(_ providerSessionID: String, on lane: ACPProcessLane, from transport: any ACPTransport) async {
        guard let process = processes[lane], process.transport === transport else { return }
        guard laneByLocalSessionID.values.contains(lane) else {
            await stopProcess(lane)
            return
        }
        guard process.canCloseSession else { return }
        let id = takeRequestID()
        try? await transport.send(ACPProtocol.closeSession(id: id, providerSessionID: providerSessionID))
    }

    /// Drops what the adapter holds for `session`, and returns whether it was open.
    private func forget(_ session: HarnessSessionHandle) -> Bool {
        let wasOpen = handles.removeValue(forKey: session.localSessionID) != nil
        laneByLocalSessionID.removeValue(forKey: session.localSessionID)
        localSessionIDByProviderID.removeValue(forKey: session.providerSessionID)
        replayingProviderSessionIDs.remove(session.providerSessionID)
        promptTasks.removeValue(forKey: session.localSessionID)?.cancel()
        agentTurnReadTasks.removeValue(forKey: session.localSessionID)?.cancel()
        agentTurnFollowers.removeValue(forKey: session.localSessionID)
        redeliveries.removeValue(forKey: session.localSessionID)
        heldNotices.removeValue(forKey: session.localSessionID)
        permissions = permissions.filter { $0.value.localSessionID != session.localSessionID }
        activities.removeValue(forKey: session.localSessionID)
        terminalActivityOrder.removeValue(forKey: session.localSessionID)
        capabilityStateByLocalSessionID.removeValue(forKey: session.localSessionID)
        capabilitySourceByLocalSessionID.removeValue(forKey: session.localSessionID)
        usesLegacyModeByLocalSessionID.remove(session.localSessionID)
        usesSessionModelByLocalSessionID.remove(session.localSessionID)
        usesGrokMetadataEffortByLocalSessionID.remove(session.localSessionID)
        assistantStreamByLocalSessionID.removeValue(forKey: session.localSessionID)
        additionalRootsByLocalSessionID.removeValue(forKey: session.localSessionID)
        agentToolServerByLocalSessionID.removeValue(forKey: session.localSessionID)
        yardletInstructionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        antigravityPermissionModeByLocalSessionID.removeValue(forKey: session.localSessionID)
        antigravityModelsByLocalSessionID.removeValue(forKey: session.localSessionID)
        return wasOpen
    }

    /// The catalog's arguments, plus the extra-root flag when this CLI documents one. A task with
    /// no extra roots, and every CLI without such a flag, launches exactly as before.
    func launchArguments(for localSessionID: UUID) -> [String] {
        launchArguments + HarnessWorkspaceRootLaunchArguments.arguments(
            for: additionalRootsByLocalSessionID[localSessionID] ?? [],
            harness: kind
        )
    }

    /// The lane `localSessionID` belongs on: Antigravity's Bypass permissions on the process that
    /// approves for itself, every other session on the standard one.
    private func lane(for localSessionID: UUID) -> ACPProcessLane {
        kind == .antigravityCLI
            && antigravityPermissionModeByLocalSessionID[localSessionID] == AntigravityPermissionMode.bypass
            ? .approvesItself : .standard
    }

    /// The process `lane` uses, a new one when it has none running.
    private func transport(for lane: ACPProcessLane) -> any ACPTransport {
        if let process = processes[lane] { return process.transport }
        let transport = transportFactory()
        processes[lane] = ACPAgentProcess(transport: transport)
        return transport
    }

    /// The process serving an open session.
    private func transport(of localSessionID: UUID) -> any ACPTransport {
        transport(for: laneByLocalSessionID[localSessionID] ?? .standard)
    }

    /// Starts `lane`'s process and runs `initialize` on it once, and returns the transport the
    /// session's requests go to.
    private func ensureInitialized(
        _ lane: ACPProcessLane,
        workspaceURL: URL,
        localSessionID: UUID
    ) async throws -> any ACPTransport {
        let transport = transport(for: lane)
        guard processes[lane]?.initialized != true else { return transport }
        do {
            // A new process could write a copy again under a name a sweep is deciding about.
            if schemaCopies != nil { await AntigravitySchemaCopies.waitForSweeps() }
            try await transport.start(
                ACPLaunchConfiguration(
                    arguments: launchArguments(for: localSessionID) + lane.launchArguments,
                    workspaceURL: workspaceURL,
                    environmentOverrides: launchEnvironmentOverrides
                )
            )
            let stream = await transport.messages()
            // Another call may have started reading this process, or stopped it, while this one waited.
            if processes[lane]?.transport === transport, processes[lane]?.messageTask == nil {
                processes[lane]?.messageTask = Task { [weak self] in
                    for await frame in stream {
                        guard !Task.isCancelled else { break }
                        await self?.accept(frame, from: transport)
                    }
                    // Stopping cancels this first; otherwise the process ended on its own.
                    guard !Task.isCancelled else { return }
                    await self?.transportEnded(transport)
                }
            }
            let id = takeRequestID()
            let result = try await transport.request(ACPProtocol.initialize(id: id), id: id)
            guard result["protocolVersion"]?.integerValue == 1 else {
                throw HarnessAdapterError.unsupportedRuntime(
                    version: "ACP \(result["protocolVersion"]?.integerValue ?? -1)"
                )
            }
            guard processes[lane]?.transport === transport else {
                throw HarnessAdapterError.processExited(code: -1, message: "ACP transport stopped")
            }
            canLoadSession = result["agentCapabilities"]?["loadSession"]?.boolValue == true
            processes[lane]?.canCloseSession = result["agentCapabilities"]?["sessionCapabilities"]?["close"]?
                .objectValue != nil
            acceptsStdioMCPServers = ACPProtocol.acceptsStdioMCPServers(initializeResult: result)
            // Image prompts belong to the agent, not to the ACP family. Record what this agent
            // advertised so a turn is never sent with a block it did not ask for.
            advertisesImagePrompts = result["agentCapabilities"]?["promptCapabilities"]?["image"]?
                .boolValue == true
            processes[lane]?.initialized = true
            return transport
        } catch {
            // One stopped while this call waited is gone already; a new one in its lane is not this call's.
            if processes[lane]?.transport === transport { await stopProcess(lane) }
            throw error
        }
    }

    private func register(_ handle: HarnessSessionHandle, on lane: ACPProcessLane) {
        handles[handle.localSessionID] = handle
        laneByLocalSessionID[handle.localSessionID] = lane
        localSessionIDByProviderID[handle.providerSessionID] = handle.localSessionID
        emit(.sessionStarted(handle), for: handle.localSessionID)
        emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
    }

    /// Serves `session` from the lane its permission mode calls for, between prompts: the
    /// conversation is loaded on that lane's process with the model and settings it had, then
    /// closed on the one that served it, so the turns the agent starts on its own run there too.
    /// `agy acp` has no session mode that approves every step (`auto` still asks before what it
    /// cannot undo), and its `--dangerously-skip-permissions` holds for a whole process.
    /// One move runs at a time, and a prompt or option for the session waits for it.
    private func moveToItsLane(_ session: HarnessSessionHandle) async throws {
        await waitForLaneMove(of: session.localSessionID)
        let move = Task {
            defer { laneMoves.removeValue(forKey: session.localSessionID) }
            try await performLaneMove(session)
        }
        laneMoves[session.localSessionID] = move
        try await move.value
    }

    private func waitForLaneMove(of localSessionID: UUID) async {
        while let move = laneMoves[localSessionID] { _ = await move.result }
    }

    private func performLaneMove(_ session: HarnessSessionHandle) async throws {
        let id = session.localSessionID
        let lane = lane(for: id)
        guard handles[id] == session, let current = laneByLocalSessionID[id], current != lane else { return }
        let target = try await ensureInitialized(lane, workspaceURL: session.workspaceURL, localSessionID: id)
        let previous = capabilityStateByLocalSessionID[id]
        let wasReplaying = replayingProviderSessionIDs.contains(session.providerSessionID)
        replayingProviderSessionIDs.insert(session.providerSessionID)
        let result: JSONValue
        do {
            let requestID = takeRequestID()
            result = try await target.request(
                ACPProtocol.loadSession(
                    id: requestID,
                    providerSessionID: session.providerSessionID,
                    workspaceURL: session.workspaceURL,
                    mcpServers: mcpServers(for: id),
                    meta: sessionMeta(for: id, loading: true)
                ),
                id: requestID
            )
        } catch {
            if !wasReplaying { replayingProviderSessionIDs.remove(session.providerSessionID) }
            await stopProcessIfUnused(lane, used: target)
            throw error
        }
        // Closed, or ended with its process, while the conversation loaded.
        guard handles[id] == session, laneByLocalSessionID[id] == current else {
            await release(session.providerSessionID, on: lane, from: target)
            return
        }
        let source = transport(for: current)
        laneByLocalSessionID[id] = lane
        agentTurnFollowers[id]?.stepsWaitForApproval = lane.stepsWaitForApproval
        rememberCapabilities(result, for: session)
        // A loaded session starts on the agent's defaults; it keeps what the task had chosen.
        for selector in previous?.selectors ?? [] {
            guard let loaded = capabilityStateByLocalSessionID[id]?.selectors.first(where: { $0.id == selector.id }),
                  loaded.currentValue != selector.currentValue,
                  loaded.choices.contains(where: { $0.value == selector.currentValue }) else { continue }
            _ = try? await setSessionOption(id: selector.id, value: selector.currentValue, in: session)
        }
        capabilityStateByLocalSessionID[id]?.actionMessage = previous?.actionMessage
        await release(session.providerSessionID, on: current, from: source)
    }

    private func accept(_ frame: ACPRawFrame, from transport: any ACPTransport) async {
        let value = frame.value
        if value["method"]?.stringValue == "session/request_permission",
           let rpcID = value["id"] {
            if let providerSessionID = value["params"]?["sessionId"]?.stringValue,
               let localSessionID = localSessionIDByProviderID[providerSessionID] {
                releaseHeldNotice(of: localSessionID, rawData: frame.data)
                completeAssistantIfNeeded(for: localSessionID, rawData: frame.data)
            }
            await acceptPermissionRequest(value, rpcID: rpcID, rawData: frame.data, from: transport)
            return
        }
        if value["id"] != nil, value["method"] != nil {
            try? await transport.send(ACPProtocol.methodNotFound(id: value["id"] ?? .null))
            return
        }
        guard ["session/update", "_x.ai/session/update"].contains(
            value["method"]?.stringValue
        ),
              let providerSessionID = value["params"]?["sessionId"]?.stringValue,
              let localSessionID = localSessionIDByProviderID[providerSessionID],
              let update = value["params"]?["update"] else { return }

        let updateKind = update["sessionUpdate"]?.stringValue
        if replayingProviderSessionIDs.contains(providerSessionID), ACPReplayTranscript.conversationUpdates.contains(updateKind ?? "") {
            return
        }
        if redeliveries[localSessionID]?.absorbs(update) == true { return }
        if promptTasks[localSessionID] == nil,
           ACPReplayTranscript.conversationUpdates.contains(updateKind ?? ""),
           updateKind != "user_message_chunk",
           let payloads = agentTurnFollowers[localSessionID]?.noteLiveStream() {
            for payload in payloads { emit(payload, for: localSessionID, rawData: frame.data) }
        }
        if updateKind == "turn_completed",
           let usage = projector.usage(from: update) {
            emit(.usageUpdated(usage), for: localSessionID, rawData: frame.data)
            return
        }
        if updateKind == "usage_update" {
            if let usage = projector.contextUsage(fromUsageUpdate: update) {
                emit(.usageUpdated(usage), for: localSessionID, rawData: frame.data)
            }
            return
        }
        if updateKind == "agent_message_chunk",
           update["content"]?["type"]?.stringValue == "text",
           let text = update["content"]?["text"]?.stringValue {
            let messageID = update["messageId"]?.stringValue
            releaseHeldNotice(of: localSessionID, rawData: frame.data)
            // Antigravity's plan limit ends the turn with a notice of the CLI's own, not the model's
            // answer (`AntigravityPlanLimit`): the turn shows the limit card Claude Code's limit shows.
            // Its other notices but a retry wait for what follows them: the turn's end makes one its
            // error, and any step after it shows it as it came.
            if kind == .antigravityCLI, let words = AntigravityNotice.words(in: text) {
                if let limit = AntigravityPlanLimit.limit(inNotice: text, receivedAt: Date()) {
                    completeAssistantIfNeeded(for: localSessionID, rawData: frame.data)
                    emit(.usageLimitReached(limit), for: localSessionID, rawData: frame.data)
                    return
                }
                if !AntigravityNotice.isRetry(words) {
                    heldNotices[localSessionID] = HeldNotice(chunk: text, messageID: messageID, words: words)
                    return
                }
            }
            acceptAssistantChunk(
                text,
                messageID: messageID,
                for: localSessionID,
                rawData: frame.data
            )
            return
        }

        if ["agent_thought_chunk", "tool_call", "plan"].contains(updateKind) {
            releaseHeldNotice(of: localSessionID, rawData: frame.data)
            completeAssistantIfNeeded(for: localSessionID, rawData: frame.data)
        }

        if updateKind == "config_option_update" {
            let previous = capabilityStateByLocalSessionID[localSessionID] ?? .empty
            var state = previous
            let selectors = capabilityProjector.configOptions(from: update)
            if !selectors.isEmpty { state.selectors = selectors }
            capabilityStateByLocalSessionID[localSessionID] = state
            if state != previous {
                emit(.providerCapabilitiesChanged, for: localSessionID, rawData: frame.data)
            }
            return
        }
        if updateKind == "current_mode_update",
           let modeID = update["modeId"]?.stringValue {
            let previous = capabilityStateByLocalSessionID[localSessionID] ?? .empty
            var state = previous
            if let index = state.selectors.firstIndex(where: { $0.id == "mode" }) {
                state.selectors[index].currentValue = modeID
            }
            capabilityStateByLocalSessionID[localSessionID] = state
            if state != previous {
                emit(.providerCapabilitiesChanged, for: localSessionID, rawData: frame.data)
            }
            return
        }

        if ["tool_call", "tool_call_update"].contains(updateKind),
           let toolCallID = update["toolCallId"]?.stringValue {
            let previous = updateKind == "tool_call" ? nil : activities[localSessionID]?[toolCallID]
            if let state = projector.toolCall(from: update, previous: previous) {
                activities[localSessionID, default: [:]][toolCallID] = state
                recordActivityLifecycle(toolCallID, status: state.status, for: localSessionID)
                emit(state.payload(isStart: updateKind == "tool_call"), for: localSessionID, rawData: frame.data)
            }
            return
        }
        for payload in projector.payloads(from: update) {
            emit(payload, for: localSessionID, rawData: frame.data)
        }
    }

    private func rememberCapabilities(_ result: JSONValue, for handle: HarnessSessionHandle) {
        var state = capabilityProjector.state(from: result, harness: kind)
        // The handshake has already settled by the time a session exists, so the composer can
        // stop offering a control this agent would refuse.
        state.acceptsImageInput = advertisesImagePrompts
        capabilityStateByLocalSessionID[handle.localSessionID] = state
        capabilitySourceByLocalSessionID[handle.localSessionID] = result
        if kind == .antigravityCLI {
            antigravityModelsByLocalSessionID[handle.localSessionID] = AntigravityACPOptions.availableModels(in: result)
        }
        if result["configOptions"]?.arrayValue == nil && result["modes"] != nil {
            usesLegacyModeByLocalSessionID.insert(handle.localSessionID)
        }
        let configIDs = Set(
            capabilityProjector.configOptions(from: result).map(\.id)
        )
        if result["models"] != nil, !configIDs.contains("model") {
            usesSessionModelByLocalSessionID.insert(handle.localSessionID)
        }
        if kind == .grokBuild,
           state.selectors.contains(where: { $0.id == "reasoning_effort" }),
           !configIDs.contains("reasoning_effort") {
            usesGrokMetadataEffortByLocalSessionID.insert(handle.localSessionID)
        }
    }

    private func acceptPermissionRequest(
        _ value: JSONValue,
        rpcID: JSONValue,
        rawData: Data,
        from transport: any ACPTransport
    ) async {
        guard let providerSessionID = value["params"]?["sessionId"]?.stringValue,
              let localSessionID = localSessionIDByProviderID[providerSessionID] else {
            // Every request gets its answer: one for a session no task holds is cancelled, so the
            // agent does not wait on it for good.
            try? await transport.send(ACPProtocol.permissionResponse(id: rpcID, optionID: nil))
            return
        }
        let options = value["params"]?["options"]?.arrayValue ?? []
        let actions = permissionActions(from: options)
        // A plain allow or deny takes the narrowest option the provider offered, never the
        // one that happens to come first in its list.
        let allow = PermissionActionPreference.preferred(from: actions, decision: .allow)?.id
        let deny = PermissionActionPreference.preferred(from: actions, decision: .deny)?.id
        let toolCall = value["params"]?["toolCall"] ?? .object([:])
        // An Antigravity task in Plan has Yardlet answer no for it. One in Bypass permissions runs on
        // a process that approves for itself; anything it still asks while a prompt runs is answered yes.
        if kind == .antigravityCLI {
            switch antigravityPermissionModeByLocalSessionID[localSessionID] {
            case AntigravityPermissionMode.bypass?:
                try? await transport.send(ACPProtocol.permissionResponse(id: rpcID, optionID: allow))
                return
            case AntigravityPermissionMode.plan?:
                try? await transport.send(ACPProtocol.permissionResponse(id: rpcID, optionID: deny))
                return
            default:
                break
            }
        }
        let requestID = "acp-permission-\(rpcID.stringValue ?? String(rpcID.integerValue ?? 0))"
        permissions[requestID] = PermissionContext(
            localSessionID: localSessionID,
            transport: transport,
            rpcID: rpcID,
            allowOptionID: allow,
            denyOptionID: deny,
            optionIDs: Set(options.compactMap { $0["optionId"]?.stringValue })
        )
        emit(
            .permissionRequested(
                PermissionRequest(
                    id: requestID,
                    title: toolCall["title"]?.stringValue
                        ?? L10n.string("Approve tool call"),
                    detail: toolCall["kind"]?.stringValue,
                    command: toolCall["rawInput"]?["command"]?.stringValue,
                    actions: actions
                )
            ),
            for: localSessionID,
            rawData: rawData
        )
        emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
    }

    private func permissionActions(from options: [JSONValue]) -> [PermissionRequestAction] {
        options.compactMap { option in
            guard let id = option["optionId"]?.stringValue,
                  let kind = option["kind"]?.stringValue else { return nil }
            let decision: PermissionDecision
            if kind == "allow_once" || kind == "allow_always" {
                decision = .allow
            } else if kind == "reject_once" || kind == "reject_always" {
                decision = .deny
            } else {
                return nil
            }
            return PermissionRequestAction(
                id: id,
                label: option["name"]?.stringValue ?? id,
                decision: decision,
                kind: kind
            )
        }
    }

    /// Called from the prompt's own task. One cancelled by closing its session or by its process
    /// ending has been accounted for there, and reports nothing more. A permission mode chosen
    /// while it ran takes the session to its lane first, before another prompt can start.
    /// An Antigravity prompt that ended its turn on a notice of the CLI's own (`AntigravityNotice`)
    /// failed, with the notice's words as its error, as one whose request failed.
    private func finishPrompt(for session: HarnessSessionHandle, stopReason: String?) async {
        guard !Task.isCancelled else { return }
        try? await moveToItsLane(session)
        guard !Task.isCancelled else { return }
        let localSessionID = session.localSessionID
        promptTasks.removeValue(forKey: localSessionID)
        pruneTerminalActivities(for: localSessionID)
        followAgentTurns(of: localSessionID)
        if stopReason == "end_turn", let notice = heldNotices.removeValue(forKey: localSessionID) {
            completeAssistantIfNeeded(for: localSessionID)
            emit(.error(message: notice.words, recoverable: true), for: localSessionID)
            emit(.sessionStatusChanged(.failed), for: localSessionID)
            return
        }
        releaseHeldNotice(of: localSessionID)
        completeAssistantIfNeeded(for: localSessionID)
        emit(.turnCompleted, for: localSessionID)
        emit(.sessionStatusChanged(.ready), for: localSessionID)
    }

    private func failPrompt(_ error: Error, for session: HarnessSessionHandle) async {
        guard !Task.isCancelled else { return }
        // The process ended under the turn; its end, which follows, reports the turn with the session.
        if case HarnessAdapterError.processExited = error { return }
        try? await moveToItsLane(session)
        guard !Task.isCancelled else { return }
        let localSessionID = session.localSessionID
        promptTasks.removeValue(forKey: localSessionID)
        pruneTerminalActivities(for: localSessionID)
        followAgentTurns(of: localSessionID)
        releaseHeldNotice(of: localSessionID)
        completeAssistantIfNeeded(for: localSessionID)
        emit(.error(message: error.localizedDescription, recoverable: true), for: localSessionID)
        emit(.sessionStatusChanged(.failed), for: localSessionID)
    }

    private func recordActivityLifecycle(
        _ toolCallID: String,
        status: ACPToolCallState.Status,
        for localSessionID: UUID
    ) {
        var order = terminalActivityOrder[localSessionID] ?? []
        order.removeAll { $0 == toolCallID }
        if status == .completed || status == .failed {
            order.append(toolCallID)
        }
        terminalActivityOrder[localSessionID] = order
    }

    /// Keeps every non-terminal tool call and the most recent terminal ones so late ACP
    /// `tool_call_update` patches with omitted `status` do not reopen a completed tool while long
    /// sessions cannot accumulate unbounded activity state.
    private func pruneTerminalActivities(for localSessionID: UUID) {
        guard var order = terminalActivityOrder[localSessionID],
              order.count > Self.maxRetainedTerminalActivities else { return }
        let excess = order.count - Self.maxRetainedTerminalActivities
        let evicted = order.prefix(excess)
        order.removeFirst(excess)
        for toolCallID in evicted {
            if let status = activities[localSessionID]?[toolCallID]?.status,
               status == .completed || status == .failed {
                activities[localSessionID]?.removeValue(forKey: toolCallID)
            }
        }
        terminalActivityOrder[localSessionID] = order
    }

    /// From the end of a prompt until the next, reads what the agent does on its own, which `agy acp`
    /// does not stream (`AntigravityAgentTurnFollower`). The log is looked at as a detached task's is:
    /// its size, and the new lines when it has grown.
    private func followAgentTurns(of localSessionID: UUID) {
        guard let conversationStore, let handle = handles[localSessionID] else { return }
        agentTurnFollowers[localSessionID] = AntigravityAgentTurnFollower(
            store: conversationStore,
            conversationID: handle.providerSessionID,
            redelivery: redeliveries.removeValue(forKey: localSessionID) ?? AntigravityRedelivery(),
            stepsWaitForApproval: (laneByLocalSessionID[localSessionID] ?? .standard).stepsWaitForApproval
        )
        let interval = agentTurnReadInterval
        agentTurnReadTasks[localSessionID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.readAgentTurn(of: localSessionID)
            }
        }
    }

    private func readAgentTurn(of localSessionID: UUID) {
        emitAgentTurnPayloads(agentTurnFollowers[localSessionID]?.read() ?? [], for: localSessionID)
    }

    private func emitAgentTurnPayloads(_ payloads: [HarnessEventPayload], for localSessionID: UUID) {
        for payload in payloads {
            switch payload {
            case .turnCompleted, .sessionStatusChanged(.ready):
                releaseHeldNotice(of: localSessionID)
                completeAssistantIfNeeded(for: localSessionID)
            default:
                break
            }
            emit(payload, for: localSessionID)
        }
    }

    /// A prompt takes over: its stream carries what the agent does from here, and first repeats what
    /// the log showed. A turn of the agent's still running goes on as part of the prompt's.
    private func stopFollowingAgentTurns(of localSessionID: UUID) {
        agentTurnReadTasks.removeValue(forKey: localSessionID)?.cancel()
        redeliveries[localSessionID] = agentTurnFollowers.removeValue(forKey: localSessionID)?.redelivery
    }

    private func requireRegistered(_ session: HarnessSessionHandle) throws {
        guard handles[session.localSessionID] == session else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("ACP session is not attached")
            )
        }
    }

    /// A shared process ended on its own: it exited or was killed. Its sessions end with it, a
    /// turn in progress with an error, as a crashed runtime's do, and the next session or prompt
    /// starts a new process instead of reaching the one that ended.
    private func transportEnded(_ ended: any ACPTransport) async {
        guard let lane = processes.first(where: { $0.value.transport === ended })?.key else { return }
        let message = L10n.format("Connection to %@ ended.", kind.displayName)
        for session in handles.values where laneByLocalSessionID[session.localSessionID] == lane {
            let id = session.localSessionID
            if let prompt = promptTasks.removeValue(forKey: id) {
                prompt.cancel()
                releaseHeldNotice(of: id)
                completeAssistantIfNeeded(for: id)
                emit(.error(message: message, recoverable: true), for: id)
                emit(.sessionStatusChanged(.failed), for: id)
            }
            _ = forget(session)
            eventChannel.finish(id)
        }
        await stopProcess(lane)
    }

    /// Ends `lane`'s process if no open session uses it. `used`, when given, is the transport a
    /// request went to: one stopped and replaced while the request waited leaves the new process
    /// to the sessions after it.
    private func stopProcessIfUnused(_ lane: ACPProcessLane, used: (any ACPTransport)? = nil) async {
        guard let process = processes[lane], !laneByLocalSessionID.values.contains(lane) else { return }
        if let used, used !== process.transport { return }
        await stopProcess(lane)
    }

    /// Ends `lane`'s process, so its next session starts one of its own. Antigravity's schema copies
    /// the process leaves go once it has exited, in the background; the next process waits for that.
    private func stopProcess(_ lane: ACPProcessLane) async {
        guard let process = processes.removeValue(forKey: lane) else { return }
        process.messageTask?.cancel()
        let stopping = process.transport
        guard let schemaCopies else {
            await stopping.stop()
            return
        }
        let stopped = Task { await stopping.stop() }
        schemaCopies.sweep(after: stopped)
        await stopped.value
    }

    private func takeRequestID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func acceptAssistantChunk(
        _ text: String,
        messageID: String?,
        for localSessionID: UUID,
        rawData: Data?
    ) {
        guard !text.isEmpty else { return }
        if let current = assistantStreamByLocalSessionID[localSessionID],
           let currentMessageID = current.messageID,
           let messageID,
           currentMessageID != messageID {
            completeAssistantIfNeeded(for: localSessionID, rawData: rawData)
        }
        var stream = assistantStreamByLocalSessionID[localSessionID]
            ?? AssistantStreamState(messageID: messageID, text: "")
        if stream.messageID == nil { stream.messageID = messageID }
        stream.text += text
        assistantStreamByLocalSessionID[localSessionID] = stream
        emit(.assistantDelta(text), for: localSessionID, rawData: rawData)
    }

    /// A held notice of the CLI's own that something followed: its words, as they came.
    private func releaseHeldNotice(of localSessionID: UUID, rawData: Data? = nil) {
        guard let notice = heldNotices.removeValue(forKey: localSessionID) else { return }
        acceptAssistantChunk(notice.chunk, messageID: notice.messageID, for: localSessionID, rawData: rawData)
    }

    private func completeAssistantIfNeeded(for localSessionID: UUID, rawData: Data? = nil) {
        guard let stream = assistantStreamByLocalSessionID.removeValue(
            forKey: localSessionID
        ), !stream.text.isEmpty else { return }
        emit(.assistantMessageCompleted(stream.text), for: localSessionID, rawData: rawData)
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }

    /// Antigravity's models as the session listed them; the other ACP agents report none here.
    func advertisedModels(for localSessionID: UUID) -> [HarnessModelOption]? {
        guard kind == .antigravityCLI else { return nil }
        return AntigravityACPOptions.catalog(from: antigravityModelsByLocalSessionID[localSessionID] ?? [])
    }

    private func readVersion() throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL, inheritsAppEnvironment: true)
    }
}

/// Which of an adapter's processes serves a session. Every agent's sessions share the standard one.
/// Antigravity's in Bypass permissions run on a second, `agy acp --dangerously-skip-permissions`:
/// `agy acp` sends `session/request_permission` only while a prompt streams, so a step of a turn the
/// agent starts on its own (a subagent's result) that needs approval would wait for good on the
/// standard process, whatever Yardlet would have answered.
enum ACPProcessLane: Hashable, Sendable {
    case standard
    case approvesItself

    var launchArguments: [String] {
        switch self {
        case .standard: []
        case .approvesItself: ["--dangerously-skip-permissions"]
        }
    }

    /// Whether a step can wait for an approval no client hears of between prompts.
    var stepsWaitForApproval: Bool { self == .standard }
}

/// One process of an ACP adapter: its transport, whether `initialize` has run on it, the task
/// reading its messages, and whether it advertised `sessionCapabilities.close`.
private struct ACPAgentProcess {
    let transport: any ACPTransport
    var initialized = false
    var messageTask: Task<Void, Never>?
    var canCloseSession = false
}
