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
    HarnessInterruptedTurnContinuing {
    private struct PermissionContext: Sendable {
        let localSessionID: UUID
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
    /// The process every open session shares. A stopped transport cannot start again, so stopping
    /// it puts a new one in its place for the next session.
    private var transport: any ACPTransport
    /// Antigravity's copies of the tool schemas, which go once the process that wrote them has
    /// exited (`AntigravitySchemaCopies`); nil for the other agents.
    private let schemaCopies: AntigravitySchemaCopies?
    private let projector = ACPEventProjector()
    private let capabilityProjector = ACPCapabilityProjector()

    private var initialized = false
    private var canLoadSession = false
    /// The agent's `initialize` answer on stdio MCP servers; ACP makes them mandatory.
    private var acceptsStdioMCPServers = true
    /// nil until the agent has answered `initialize`.
    private var advertisesImagePrompts: Bool?
    private var nextRequestID: Int64 = 1
    private var messageTask: Task<Void, Never>?
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var localSessionIDByProviderID: [String: UUID] = [:]
    private var permissions: [String: PermissionContext] = [:]
    private var activities: [UUID: [String: ACPToolCallState]] = [:]
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
    /// Antigravity: the permission mode Yardlet answers approvals by, and the models the session
    /// listed (`AntigravityACPOptions`).
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
        let transportFactory = transportFactory ?? { ACPProcessTransport(executableURL: executableURL) }
        self.transportFactory = transportFactory
        self.transport = transportFactory()
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
        let transport = try await ensureInitialized(
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
            register(handle)
            if let prompt = request.initialPrompt, !prompt.isEmpty {
                try await send(prompt, to: handle)
            }
            return handle
        } catch {
            await stopTransportIfUnused(transport)
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
        let transport = try await ensureInitialized(workspaceURL: workspaceURL, localSessionID: localSessionID)
        guard canLoadSession else {
            await stopTransportIfUnused(transport)
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
            register(handle)
            return handle
        } catch {
            replayingProviderSessionIDs.remove(providerSessionID)
            await stopTransportIfUnused(transport)
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
        try requireRegistered(session)
        guard promptTasks[session.localSessionID] == nil else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("An ACP prompt is already running")
            )
        }
        replayingProviderSessionIDs.remove(session.providerSessionID)
        stopFollowingAgentTurns(of: session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        let id = takeRequestID()
        promptTasks[session.localSessionID] = Task { [weak self] in
            do {
                let result = try await self?.transport.requestWithoutTimeout(
                    ACPProtocol.prompt(
                        id: id,
                        providerSessionID: session.providerSessionID,
                        text: text,
                        images: images
                    ),
                    id: id
                )
                if let result,
                   let usage = ACPEventProjector().usage(from: result) {
                    await self?.emit(.usageUpdated(usage), for: session.localSessionID)
                }
                // ACP notifications and the prompt response share stdout, but the transport
                // hands notifications to an AsyncStream. Give the ordered notification queue a
                // brief chance to drain before closing the turn so the final text cannot arrive
                // after turnCompleted on a busy UI thread.
                try? await Task.sleep(for: .milliseconds(20))
                await self?.finishPrompt(for: session.localSessionID)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failPrompt(error, for: session.localSessionID)
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
            try await transport.send(
                ACPProtocol.permissionResponse(id: context.rpcID, optionID: nil)
            )
            permissions.removeValue(forKey: requestID)
        }
        try await transport.send(
            ACPProtocol.cancel(providerSessionID: session.providerSessionID)
        )
        // A prompt's turn ends with its answer; an agent's own turn has no answer to wait for.
        for payload in agentTurnFollowers[session.localSessionID]?.stop() ?? [] {
            emit(payload, for: session.localSessionID)
        }
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
        try await transport.send(
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
        try await transport.send(
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

    /// The session's controls as Yardlet shows them: Antigravity's under the names its print mode
    /// and Yardlet's menus use, with its permission mode (`AntigravityACPOptions`).
    private func presented(_ state: ProviderCapabilityState, for localSessionID: UUID) -> ProviderCapabilityState {
        guard kind == .antigravityCLI else { return state }
        return AntigravityACPOptions.project(state, permissionMode: antigravityPermissionModeByLocalSessionID[localSessionID])
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        guard kind == .antigravityCLI else {
            return try await setSessionOption(id: id, value: value, in: session)
        }
        let current = capabilityStateByLocalSessionID[session.localSessionID]
            ?? capabilityProjector.state(from: .object([:]), harness: kind)
        var state = current
        switch try AntigravityACPOptions.step(id: id, value: value, selectors: current.selectors,
                                              models: antigravityModelsByLocalSessionID[session.localSessionID] ?? []) {
        case let .permission(mode):
            antigravityPermissionModeByLocalSessionID[session.localSessionID] = mode
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
        let result = try await transport.request(request, id: requestID)
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
        let wasOpen = forget(session)
        eventChannel.close(session.localSessionID)
        // Closing the last open session ends the process; closing a session again, or one whose
        // process already ended, leaves alone a process started since.
        if wasOpen, handles.isEmpty {
            await stopTransport()
        }
    }

    /// Drops what the adapter holds for `session`, and returns whether it was open.
    private func forget(_ session: HarnessSessionHandle) -> Bool {
        let wasOpen = handles.removeValue(forKey: session.localSessionID) != nil
        localSessionIDByProviderID.removeValue(forKey: session.providerSessionID)
        replayingProviderSessionIDs.remove(session.providerSessionID)
        promptTasks.removeValue(forKey: session.localSessionID)?.cancel()
        agentTurnReadTasks.removeValue(forKey: session.localSessionID)?.cancel()
        agentTurnFollowers.removeValue(forKey: session.localSessionID)
        redeliveries.removeValue(forKey: session.localSessionID)
        permissions = permissions.filter { $0.value.localSessionID != session.localSessionID }
        activities.removeValue(forKey: session.localSessionID)
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

    /// Starts the shared process and runs `initialize` on it once, and returns the transport the
    /// session's requests go to.
    private func ensureInitialized(workspaceURL: URL, localSessionID: UUID) async throws -> any ACPTransport {
        let transport = transport
        guard !initialized else { return transport }
        do {
            // A new process could write a copy again under a name a sweep is deciding about.
            if schemaCopies != nil { await AntigravitySchemaCopies.waitForSweeps() }
            try await transport.start(
                ACPLaunchConfiguration(
                    arguments: launchArguments(for: localSessionID),
                    workspaceURL: workspaceURL,
                    environmentOverrides: launchEnvironmentOverrides
                )
            )
            let stream = await transport.messages()
            // Another call may have started reading this process, or stopped it, while this one waited.
            if messageTask == nil, transport === self.transport {
                messageTask = Task { [weak self] in
                    for await frame in stream {
                        guard !Task.isCancelled else { break }
                        await self?.accept(frame)
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
            guard transport === self.transport else {
                throw HarnessAdapterError.processExited(code: -1, message: "ACP transport stopped")
            }
            canLoadSession = result["agentCapabilities"]?["loadSession"]?.boolValue == true
            acceptsStdioMCPServers = ACPProtocol.acceptsStdioMCPServers(initializeResult: result)
            // Image prompts belong to the agent, not to the ACP family. Record what this agent
            // advertised so a turn is never sent with a block it did not ask for.
            advertisesImagePrompts = result["agentCapabilities"]?["promptCapabilities"]?["image"]?
                .boolValue == true
            initialized = true
            return transport
        } catch {
            // One stopped while this call waited has been replaced already; the new one is not this call's.
            if transport === self.transport { await stopTransport() }
            throw error
        }
    }

    private func register(_ handle: HarnessSessionHandle) {
        handles[handle.localSessionID] = handle
        localSessionIDByProviderID[handle.providerSessionID] = handle.localSessionID
        emit(.sessionStarted(handle), for: handle.localSessionID)
        emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
    }

    private func accept(_ frame: ACPRawFrame) async {
        let value = frame.value
        if value["method"]?.stringValue == "session/request_permission",
           let rpcID = value["id"] {
            if let providerSessionID = value["params"]?["sessionId"]?.stringValue,
               let localSessionID = localSessionIDByProviderID[providerSessionID] {
                completeAssistantIfNeeded(for: localSessionID, rawData: frame.data)
            }
            await acceptPermissionRequest(value, rpcID: rpcID, rawData: frame.data)
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
            acceptAssistantChunk(
                text,
                messageID: update["messageId"]?.stringValue,
                for: localSessionID,
                rawData: frame.data
            )
            return
        }

        if ["agent_thought_chunk", "tool_call", "plan"].contains(updateKind) {
            completeAssistantIfNeeded(for: localSessionID, rawData: frame.data)
        }

        if updateKind == "config_option_update" {
            var state = capabilityStateByLocalSessionID[localSessionID] ?? .empty
            let selectors = capabilityProjector.configOptions(from: update)
            if !selectors.isEmpty { state.selectors = selectors }
            capabilityStateByLocalSessionID[localSessionID] = state
            return
        }
        if updateKind == "current_mode_update",
           let modeID = update["modeId"]?.stringValue {
            var state = capabilityStateByLocalSessionID[localSessionID] ?? .empty
            if let index = state.selectors.firstIndex(where: { $0.id == "mode" }) {
                state.selectors[index].currentValue = modeID
            }
            capabilityStateByLocalSessionID[localSessionID] = state
            return
        }

        if ["tool_call", "tool_call_update"].contains(updateKind),
           let toolCallID = update["toolCallId"]?.stringValue {
            let previous = updateKind == "tool_call" ? nil : activities[localSessionID]?[toolCallID]
            if let state = projector.toolCall(from: update, previous: previous) {
                activities[localSessionID, default: [:]][toolCallID] = state
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
        rawData: Data
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
        // An Antigravity task in Bypass permissions or Plan has Yardlet answer for it.
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
    /// ending has been accounted for there, and reports nothing more.
    private func finishPrompt(for localSessionID: UUID) {
        guard !Task.isCancelled else { return }
        promptTasks.removeValue(forKey: localSessionID)
        followAgentTurns(of: localSessionID)
        completeAssistantIfNeeded(for: localSessionID)
        emit(.turnCompleted, for: localSessionID)
        emit(.sessionStatusChanged(.ready), for: localSessionID)
    }

    private func failPrompt(_ error: Error, for localSessionID: UUID) {
        guard !Task.isCancelled else { return }
        // The process ended under the turn; its end, which follows, reports the turn with the session.
        if case HarnessAdapterError.processExited = error { return }
        promptTasks.removeValue(forKey: localSessionID)
        followAgentTurns(of: localSessionID)
        completeAssistantIfNeeded(for: localSessionID)
        emit(.error(message: error.localizedDescription, recoverable: true), for: localSessionID)
        emit(.sessionStatusChanged(.failed), for: localSessionID)
    }

    /// From the end of a prompt until the next, reads what the agent does on its own, which `agy acp`
    /// does not stream (`AntigravityAgentTurnFollower`). The log is looked at as a detached task's is:
    /// its size, and the new lines when it has grown.
    private func followAgentTurns(of localSessionID: UUID) {
        guard let conversationStore, let handle = handles[localSessionID] else { return }
        agentTurnFollowers[localSessionID] = AntigravityAgentTurnFollower(
            store: conversationStore,
            conversationID: handle.providerSessionID,
            redelivery: redeliveries.removeValue(forKey: localSessionID) ?? AntigravityRedelivery()
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
        for payload in agentTurnFollowers[localSessionID]?.read() ?? [] {
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

    /// The shared process ended on its own: it exited or was killed. Its sessions end with it, a
    /// turn in progress with an error, as a crashed runtime's do, and the next session or prompt
    /// starts a new process instead of reaching the one that ended.
    private func transportEnded(_ ended: any ACPTransport) async {
        guard ended === transport else { return }
        let message = L10n.format("Connection to %@ ended.", kind.displayName)
        for session in handles.values {
            let id = session.localSessionID
            if let prompt = promptTasks.removeValue(forKey: id) {
                prompt.cancel()
                completeAssistantIfNeeded(for: id)
                emit(.error(message: message, recoverable: true), for: id)
                emit(.sessionStatusChanged(.failed), for: id)
            }
            _ = forget(session)
            eventChannel.finish(id)
        }
        await stopTransport()
    }

    /// After a failed session request, ends the process if no session uses it. `used` is the
    /// transport the request went to: one stopped and replaced while the request waited leaves the
    /// new process to the sessions after it.
    private func stopTransportIfUnused(_ used: any ACPTransport) async {
        guard handles.isEmpty, used === transport else { return }
        await stopTransport()
    }

    /// Ends the shared process and puts a new transport in its place, so the next session starts
    /// one of its own. Antigravity's schema copies the process leaves go once it has exited, in the
    /// background; the next process waits for that.
    private func stopTransport() async {
        messageTask?.cancel()
        messageTask = nil
        initialized = false
        let stopping = transport
        transport = transportFactory()
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
        rawData: Data
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
