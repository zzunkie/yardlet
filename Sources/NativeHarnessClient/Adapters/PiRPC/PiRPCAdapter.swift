import Foundation

actor PiRPCAdapter: HarnessAdapter, ProviderCapabilityProviding, HarnessWorkspaceRootsConfiguring,
    HarnessHistoryFreeSessionConfiguring, HarnessYardletInstructionsConfiguring {
    private struct PermissionContext: Sendable {
        let localSessionID: UUID
        let providerRequestID: String
    }

    nonisolated let kind: HarnessKind

    private let executableURL: URL
    private let launchArguments: [String]
    private let transportFactory: @Sendable (UUID) -> any PiRPCTransport
    private let projector = PiRPCEventProjector()

    private var nextRequestNumber: UInt64 = 1
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var transports: [UUID: any PiRPCTransport] = [:]
    private var messageTasks: [UUID: Task<Void, Never>] = [:]
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private var statsTasks: [UUID: Task<Void, Never>] = [:]
    private var runningSessionIDs: Set<UUID> = []
    private var permissions: [String: PermissionContext] = [:]
    private var activities: [UUID: [String: HarnessActivity]] = [:]
    private var eventChannel = HarnessEventChannel()
    private var additionalRootsByLocalSessionID: [UUID: [URL]] = [:]
    private var yardletInstructionsByLocalSessionID: [UUID: String] = [:]
    private let environmentOverrides: [String: String]
    /// Sessions whose process saves no session file (`--no-session`, `run_agent`).
    private var historyFreeSessionIDs = Set<UUID>()

    /// The flag that keeps a session in memory only: Pi's `--no-session` ("Don't save session
    /// (ephemeral)", `pi --help` 0.84.1).
    static func historyFreeArguments(for kind: HarnessKind) -> [String]? {
        kind == .pi ? ["--no-session"] : nil
    }

    init(
        kind: HarnessKind,
        executableURL: URL,
        launchArguments: [String]? = nil,
        environmentOverrides: [String: String] = [:],
        transportFactory: (@Sendable (UUID) -> any PiRPCTransport)? = nil
    ) {
        let executableURL = executableURL.standardizedFileURL
        self.kind = kind
        self.executableURL = executableURL
        self.environmentOverrides = environmentOverrides
        self.launchArguments = launchArguments
            ?? HarnessCatalog.descriptor(for: kind)?.launchArguments
            ?? ["--mode", "rpc"]
        self.transportFactory = transportFactory ?? { _ in
            PiRPCProcessTransport(executableURL: executableURL, environmentOverrides: environmentOverrides)
        }
    }

    /// The project's other roots, held for this session's own process. The Pi RPC request has no
    /// field for them, so they would have to reach the agent as a launch flag its executable
    /// documents — `pi` has none, so the launch stays what it was.
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
        if roots.isEmpty {
            additionalRootsByLocalSessionID.removeValue(forKey: localSessionID)
        } else {
            additionalRootsByLocalSessionID[localSessionID] = roots.map(\.standardizedFileURL)
        }
    }

    /// Yardlet instructions for this session's own process, passed as Pi's `--append-system-prompt`. Oh My
    /// Pi is not installed here to check, so it receives nothing.
    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) {
        yardletInstructionsByLocalSessionID[localSessionID] = instructions?.text
    }

    /// The instruction flags for this session's launch in `workspaceURL` (`YardletInstructionsLaunch`).
    func instructionArguments(for localSessionID: UUID, workspaceURL: URL) -> [String] {
        guard YardletInstructionsRoute.route(for: kind) == .piAppendSystemPrompt else { return [] }
        return YardletInstructionsLaunch.piArguments(
            yardletInstructionsByLocalSessionID[localSessionID], workspaceURL: workspaceURL,
            environment: ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new })
    }

    /// The catalog's arguments, plus the extra-root flag when this CLI documents one. A task with
    /// no extra roots, and every CLI without such a flag, launches exactly as before.
    func launchArguments(for localSessionID: UUID) -> [String] {
        launchArguments + HarnessWorkspaceRootLaunchArguments.arguments(
            for: additionalRootsByLocalSessionID[localSessionID] ?? [],
            harness: kind
        ) + (historyFreeSessionIDs.contains(localSessionID) ? Self.historyFreeArguments(for: kind) ?? [] : [])
    }

    /// The session's own process starts with `--no-session`, so Pi writes no session file for it.
    /// False for a runtime without the flag, and for a session whose process already runs.
    func keepNoHistory(for localSessionID: UUID) -> Bool {
        guard Self.historyFreeArguments(for: kind) != nil, transports[localSessionID] == nil else { return false }
        historyFreeSessionIDs.insert(localSessionID)
        return true
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
                hasPlans: false,
                // The prompt command carries `images`.
                acceptsImages: true,
                // No Pi RPC projection carries subagent activity.
                hasSubagents: false
            ),
            fingerprint: fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        let transport = transportFactory(request.localSessionID)
        do {
            try await start(
                transport: transport,
                localSessionID: request.localSessionID,
                workspaceURL: request.workspaceURL
            )
            let state = try await getState(transport: transport)
            let providerSessionID: String
            if let sessionFile = state["data"]?["sessionFile"]?.stringValue {
                providerSessionID = sessionFile
            } else if historyFreeSessionIDs.contains(request.localSessionID) {
                // A session in memory has no file to name it; it is never resumed.
                providerSessionID = state["data"]?["sessionId"]?.stringValue ?? request.localSessionID.uuidString
            } else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("Pi RPC session persistence is unavailable")
                )
            }
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: request.localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: request.workspaceURL.standardizedFileURL
            )
            handles[handle.localSessionID] = handle
            emit(.sessionStarted(handle), for: handle.localSessionID)
            emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
            if let prompt = request.initialPrompt, !prompt.isEmpty {
                try await send(prompt, to: handle)
            }
            return handle
        } catch {
            await detach(localSessionID: request.localSessionID)
            throw error
        }
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        let transport = transportFactory(localSessionID)
        do {
            try await start(
                transport: transport,
                localSessionID: localSessionID,
                workspaceURL: workspaceURL
            )
            let requestID = takeRequestID(prefix: "switch")
            let response = try await transport.request(
                PiRPCProtocol.switchSession(
                    id: requestID,
                    sessionPath: providerSessionID
                ),
                id: requestID
            )
            guard response["data"]?["cancelled"]?.boolValue != true else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("Pi RPC session switch was cancelled")
                )
            }
            let state = try await getState(transport: transport)
            guard state["data"]?["sessionFile"]?.stringValue == providerSessionID else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Pi RPC resumed a different session")
                )
            }
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: workspaceURL.standardizedFileURL
            )
            handles[localSessionID] = handle
            emit(.sessionStarted(handle), for: localSessionID)
            emit(.sessionStatusChanged(.ready), for: localSessionID)
            return handle
        } catch {
            await detach(localSessionID: localSessionID)
            throw error
        }
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await sendPrompt(text: prompt, images: [], to: session)
    }

    /// pi's RPC prompt already carries `images`; the composer's attachment reaches it as an
    /// image, not as a path pasted into the message.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        try await sendPrompt(
            text: input.promptText,
            images: try input.encodedImages(),
            to: session
        )
    }

    private func sendPrompt(
        text: String,
        images: [HarnessUserInput.EncodedImage],
        to session: HarnessSessionHandle
    ) async throws {
        let transport = try transport(for: session)
        guard !runningSessionIDs.contains(session.localSessionID) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("A Pi RPC prompt is already running")
            )
        }
        runningSessionIDs.insert(session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        let requestID = takeRequestID(prefix: "prompt")
        promptTasks[session.localSessionID] = Task { [weak self] in
            do {
                let response = try await transport.request(
                    PiRPCProtocol.prompt(id: requestID, text: text, images: images),
                    id: requestID
                )
                await self?.acknowledgePrompt(response, for: session.localSessionID)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failTurn(error, for: session.localSessionID)
            }
        }
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        let transport = try transport(for: session)
        let pendingRequestIDs = permissions.compactMap { requestID, context in
            context.localSessionID == session.localSessionID ? requestID : nil
        }
        for requestID in pendingRequestIDs {
            guard let context = permissions[requestID] else { continue }
            try await transport.send(
                PiRPCProtocol.cancelExtensionUI(id: context.providerRequestID)
            )
            permissions.removeValue(forKey: requestID)
        }
        let id = takeRequestID(prefix: "abort")
        _ = try await transport.request(PiRPCProtocol.abort(id: id), id: id)
        finishTurn(for: session.localSessionID)
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        let transport = try transport(for: session)
        guard let context = permissions.removeValue(forKey: permissionRequestID),
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Unknown or already-resolved Pi RPC permission request")
            )
        }
        try await transport.send(
            PiRPCProtocol.extensionConfirmation(
                id: context.providerRequestID,
                confirmed: decision == .allow
            )
        )
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        eventChannel.subscribe(to: session.localSessionID)
    }

    func providerCapabilities(for session: HarnessSessionHandle) async throws
        -> ProviderCapabilityState {
        let transport = try transport(for: session)
        let state = try await getState(transport: transport)
        let modelsID = takeRequestID(prefix: "models")
        let models = try await transport.request(
            PiRPCProtocol.availableModels(id: modelsID),
            id: modelsID
        )
        let thinkingID = takeRequestID(prefix: "thinking")
        let thinking = try await transport.request(
            PiRPCProtocol.availableThinkingLevels(id: thinkingID),
            id: thinkingID
        )
        return piCapabilityState(state: state, models: models, thinking: thinking)
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let transport = try transport(for: session)
        let requestID = takeRequestID(prefix: "config")
        let request: JSONValue
        switch id {
        case "model":
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw HarnessAdapterError.invalidProviderEvent("Invalid Pi model selection")
            }
            request = PiRPCProtocol.setModel(
                id: requestID,
                provider: parts[0],
                modelID: parts[1]
            )
        case "thinking":
            request = PiRPCProtocol.setThinkingLevel(id: requestID, level: value)
        case "autoCompaction":
            request = PiRPCProtocol.setAutoCompaction(id: requestID, enabled: value == "true")
        default:
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Pi does not expose that setting")
            )
        }
        _ = try await transport.request(request, id: requestID)
        var result = try await providerCapabilities(for: session)
        result.actionMessage = L10n.string("Pi session setting updated")
        return result
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let transport = try transport(for: session)
        guard id == ProviderCapabilityActionID.compact else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Pi does not expose that action")
            )
        }
        let requestID = takeRequestID(prefix: "compact")
        _ = try await transport.request(PiRPCProtocol.compact(id: requestID), id: requestID)
        var result = try await providerCapabilities(for: session)
        result.actionMessage = L10n.string("Conversation compacted")
        return result
    }

    func close(_ session: HarnessSessionHandle) async {
        handles.removeValue(forKey: session.localSessionID)
        runningSessionIDs.remove(session.localSessionID)
        promptTasks.removeValue(forKey: session.localSessionID)?.cancel()
        permissions = permissions.filter { $0.value.localSessionID != session.localSessionID }
        activities.removeValue(forKey: session.localSessionID)
        eventChannel.close(session.localSessionID)
        additionalRootsByLocalSessionID.removeValue(forKey: session.localSessionID)
        yardletInstructionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        historyFreeSessionIDs.remove(session.localSessionID)
        await detach(localSessionID: session.localSessionID)
    }

    private func start(
        transport: any PiRPCTransport,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws {
        transports[localSessionID] = transport
        try await transport.start(
            PiRPCLaunchConfiguration(
                arguments: launchArguments(for: localSessionID)
                    + instructionArguments(for: localSessionID, workspaceURL: workspaceURL),
                workspaceURL: workspaceURL
            )
        )
        let stream = await transport.messages()
        messageTasks[localSessionID] = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.accept(frame, for: localSessionID)
            }
        }
    }

    private func getState(transport: any PiRPCTransport) async throws -> JSONValue {
        let requestID = takeRequestID(prefix: "state")
        return try await transport.request(PiRPCProtocol.getState(id: requestID), id: requestID)
    }

    private func piCapabilityState(
        state: JSONValue,
        models: JSONValue,
        thinking: JSONValue
    ) -> ProviderCapabilityState {
        let data = state["data"] ?? .object([:])
        let currentModel = data["model"]
        let modelChoices = (models["data"]?["models"]?.arrayValue ?? []).compactMap {
            model -> ProviderCapabilityChoice? in
            guard let provider = model["provider"]?.stringValue,
                  let id = model["id"]?.stringValue else { return nil }
            return ProviderCapabilityChoice(
                value: "\(provider)|\(id)",
                name: model["name"]?.stringValue ?? id,
                description: provider
            )
        }
        let thinkingLevels = thinking["data"]?["levels"]?.arrayValue?.compactMap(\.stringValue)
            ?? ["off"]
        var selectors: [ProviderCapabilitySelector] = []
        if !modelChoices.isEmpty {
            let provider = currentModel?["provider"]?.stringValue ?? ""
            let modelID = currentModel?["id"]?.stringValue ?? ""
            selectors.append(ProviderCapabilitySelector(
                id: "model",
                name: L10n.string("Model"),
                description: L10n.string("Configured models exposed by the Pi runtime."),
                category: "model",
                currentValue: "\(provider)|\(modelID)",
                choices: modelChoices
            ))
        }
        selectors.append(ProviderCapabilitySelector(
            id: "thinking",
            name: L10n.string("Thinking level"),
            description: nil,
            category: "thought_level",
            currentValue: data["thinkingLevel"]?.stringValue ?? "off",
            choices: thinkingLevels.map {
                ProviderCapabilityChoice(value: $0, name: $0.capitalized, description: nil)
            }
        ))
        selectors.append(ProviderCapabilitySelector(
            id: "autoCompaction",
            name: L10n.string("Automatic compaction"),
            description: L10n.string("Compact context automatically when it approaches the limit."),
            category: "context",
            currentValue: data["autoCompactionEnabled"]?.boolValue == false ? "false" : "true",
            choices: [
                ProviderCapabilityChoice(value: "true", name: L10n.string("On"), description: nil),
                ProviderCapabilityChoice(value: "false", name: L10n.string("Off"), description: nil)
            ]
        ))
        return ProviderCapabilityState(
            selectors: selectors,
            actions: [ProviderCapabilityAction(
                id: ProviderCapabilityActionID.compact,
                title: L10n.string("Compact conversation"),
                description: L10n.string("Summarize older context while preserving the active session."),
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )],
            notes: [L10n.string("Models and thinking levels come from the active Pi RPC session.")]
        )
    }

    private func accept(_ frame: PiRPCRawFrame, for localSessionID: UUID) async {
        let value = frame.value
        switch value["type"]?.stringValue {
        case "agent_start":
            runningSessionIDs.insert(localSessionID)
            emit(.sessionStatusChanged(.running), for: localSessionID, rawData: frame.data)
            return

        case "agent_settled":
            finishTurn(for: localSessionID, rawData: frame.data)
            return

        case "agent_end":
            let terminal = value["isTerminal"]?.boolValue != false
                && value["willRetry"]?.boolValue != true
            if terminal { finishTurn(for: localSessionID, rawData: frame.data) }
            return

        case "prompt_result":
            if value["agentInvoked"]?.boolValue == false {
                finishTurn(for: localSessionID, rawData: frame.data)
            }
            return

        case "extension_ui_request":
            await acceptExtensionUI(value, for: localSessionID, rawData: frame.data)
            return

        case "transport_error":
            failTurn(
                HarnessAdapterError.invalidProviderEvent(
                    value["error"]?.stringValue ?? L10n.string("Pi RPC transport error")
                ),
                for: localSessionID
            )
            return

        default:
            break
        }

        if ["tool_execution_start", "tool_execution_update", "tool_execution_end"]
            .contains(value["type"]?.stringValue),
           let toolCallID = value["toolCallId"]?.stringValue {
            let fallback = activities[localSessionID]?[toolCallID]
            if let activity = projector.activity(from: value, fallback: fallback) {
                activities[localSessionID, default: [:]][toolCallID] = activity
                for payload in projector.payloads(from: value, fallback: activity) {
                    emit(payload, for: localSessionID, rawData: frame.data)
                }
            }
            return
        }
        for payload in projector.payloads(from: value) {
            emit(payload, for: localSessionID, rawData: frame.data)
        }
    }

    private func acceptExtensionUI(
        _ value: JSONValue,
        for localSessionID: UUID,
        rawData: Data
    ) async {
        guard let providerRequestID = value["id"]?.stringValue else { return }
        guard value["method"]?.stringValue == "confirm" else {
            if let transport = transports[localSessionID] {
                try? await transport.send(
                    PiRPCProtocol.cancelExtensionUI(id: providerRequestID)
                )
            }
            emit(
                .error(
                    message: L10n.string("This Pi extension dialog is not supported"),
                    recoverable: true
                ),
                for: localSessionID,
                rawData: rawData
            )
            return
        }
        let requestID = "pi-permission-\(providerRequestID)"
        permissions[requestID] = PermissionContext(
            localSessionID: localSessionID,
            providerRequestID: providerRequestID
        )
        emit(
            .permissionRequested(
                PermissionRequest(
                    id: requestID,
                    title: value["title"]?.stringValue ?? L10n.string("Confirm action"),
                    detail: value["message"]?.stringValue,
                    command: nil
                )
            ),
            for: localSessionID,
            rawData: rawData
        )
        emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
    }

    private func finishTurn(for localSessionID: UUID, rawData: Data? = nil) {
        guard runningSessionIDs.remove(localSessionID) != nil else { return }
        emit(.turnCompleted, for: localSessionID, rawData: rawData)
        emit(.sessionStatusChanged(.ready), for: localSessionID, rawData: rawData)
        requestSessionStats(for: localSessionID)
    }

    /// Pi publishes token and cost totals on request rather than on the event stream, so the
    /// finished turn asks once. A runtime without the command simply reports nothing.
    private func requestSessionStats(for localSessionID: UUID) {
        guard let transport = transports[localSessionID] else { return }
        let requestID = takeRequestID(prefix: "stats")
        statsTasks.removeValue(forKey: localSessionID)?.cancel()
        statsTasks[localSessionID] = Task { [weak self] in
            let response = try? await transport.request(
                PiRPCProtocol.sessionStats(id: requestID),
                id: requestID
            )
            guard !Task.isCancelled, let response else { return }
            await self?.acceptSessionStats(response, for: localSessionID)
        }
    }

    private func acceptSessionStats(_ response: JSONValue, for localSessionID: UUID) {
        statsTasks.removeValue(forKey: localSessionID)
        guard handles[localSessionID] != nil,
              let usage = projector.usage(from: response["data"] ?? response) else { return }
        emit(.usageUpdated(usage), for: localSessionID)
    }

    private func acknowledgePrompt(_ response: JSONValue, for localSessionID: UUID) {
        promptTasks.removeValue(forKey: localSessionID)
        if response["data"]?["agentInvoked"]?.boolValue == false {
            finishTurn(for: localSessionID)
        }
    }

    private func failTurn(_ error: Error, for localSessionID: UUID) {
        promptTasks.removeValue(forKey: localSessionID)
        runningSessionIDs.remove(localSessionID)
        emit(.error(message: error.localizedDescription, recoverable: true), for: localSessionID)
        emit(.sessionStatusChanged(.failed), for: localSessionID)
    }

    private func transport(for session: HarnessSessionHandle) throws -> any PiRPCTransport {
        guard handles[session.localSessionID] == session,
              let transport = transports[session.localSessionID] else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Pi RPC session is not attached")
            )
        }
        return transport
    }

    private func detach(localSessionID: UUID) async {
        statsTasks.removeValue(forKey: localSessionID)?.cancel()
        messageTasks.removeValue(forKey: localSessionID)?.cancel()
        if let transport = transports.removeValue(forKey: localSessionID) {
            await transport.stop()
        }
    }

    private func takeRequestID(prefix: String) -> String {
        defer { nextRequestNumber += 1 }
        return "nhc-\(prefix)-\(nextRequestNumber)"
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }

    private func readVersion() throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL, inheritsAppEnvironment: true)
    }
}
