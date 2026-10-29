import Foundation

actor CodexAdapter: HarnessAdapter, CodexCapabilityProviding, CodexPresentationProviding, CodexThreadReading, CodexComposerProviding, CodexConversationEditing, CodexTurnRecovering, CodexPendingServerRequestValidating, HarnessWorkspaceRootsConfiguring, HarnessInstructionSourceReporting, HarnessAgentToolConfiguring, HarnessYardletInstructionsConfiguring, HarnessMCPServerStatusReading, HarnessInterruptedTurnContinuing, HarnessHistoryFreeSessionConfiguring, HarnessLaunchOptionConfiguring, CodexBackgroundTerminalControlling {
    private struct ApprovalContext: Sendable {
        let localSessionID: UUID
        let rpcID: CodexRPCID
        let method: String
        let requestedPermissions: JSONValue?
    }

    nonisolated let kind = HarnessKind.codex

    private let executableURL: URL
    private let runtimeCompatibility: CodexRuntimeCompatibility
    private let clientVersion: String
    private let transport: any CodexTransport
    private let projector = CodexEventProjector()
    private let activityProjector = CodexActivityProjector()
    private let capabilityProjector = CodexCapabilityProjector()
    private let taskDecoder = CodexTaskDecoder()
    private let taskReducer = CodexTaskReducer()

    private var transportEnded = false
    private var initialized = false
    /// The handshake in flight. The actor lets a second request in while the first awaits the
    /// runtime, so a request that finds one waits for it instead of sending `initialize` again.
    private var initialization: Task<Void, Error>?
    /// Moves on when the transport ends or stops, so a handshake answered after that is not used.
    private var initializationGeneration = 0
    private var reviewTurnIDByLocalSessionID: [UUID: String] = [:]
    private var notificationTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var localSessionIDByThreadID: [String: UUID] = [:]
    private var activeTurnIDByLocalSessionID: [UUID: String] = [:]
    private var retryingSessionIDs = Set<UUID>()
    private var collaborationPresetByLocalSessionID: [UUID: CodexCollaborationPreset] = [:]
    private var modelOptions: [CodexModelOption]?
    private var modelSelectionByLocalSessionID: [UUID: CodexModelSelection] = [:]
    private var runLocationByLocalSessionID: [UUID: CodexRunLocation] = [:]
    private var additionalRootsByLocalSessionID: [UUID: [URL]] = [:]
    private var agentToolServerByLocalSessionID: [UUID: AgentToolServerLaunch] = [:]
    private var yardletInstructionsByLocalSessionID: [UUID: String] = [:]
    /// Threads to start ephemeral, written nowhere (`run_agent`).
    private var historyFreeSessionIDs = Set<UUID>()
    private var instructionSourcesByLocalSessionID: [UUID: [String]] = [:]
    private var serverRequestContexts: [String: ApprovalContext] = [:]
    /// A closed session's events and numbering stay here; only its stream finishes.
    private var eventChannel = HarnessEventChannel()
    private var presentationStateByLocalSessionID: [UUID: CodexTaskState] = [:]
    private var runtimeNoticesAwaitingTask: [(method: String, params: JSONValue)] = []
    private var presentationContinuations: [
        UUID: AsyncStream<CodexTaskState>.Continuation
    ] = [:]
    private var presentationSequenceByLocalSessionID: [UUID: UInt64] = [:]
    private var pendingPresentationPublicationByLocalSessionID: [UUID: CodexTaskState] = [:]
    private var presentationFlushTasks: [UUID: Task<Void, Never>] = [:]

    private let namesNewThreads: Bool
    /// Threads this adapter started whose first request has not been sent yet.
    private var unnamedNewThreadSessionIDs = Set<UUID>()
    private var threadNamingTasks: [UUID: Task<Void, Never>] = [:]
    /// Final messages of the side turns that name threads, keyed by their ephemeral thread.
    private var titleTurns: [String: TitleTurn] = [:]

    private struct TitleTurn {
        var finalMessage: String?
        var result: String??
        var continuation: CheckedContinuation<String?, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    /// Next-message predictions after a turn (`CodexMessagePrediction`).
    private let predictsNextMessages: Bool
    private let asksForNextMessageSuggestions: @Sendable () -> Bool
    /// From `initialize`'s `userAgent`; the fork mode needs 0.162.0-alpha.20.
    private var appServerVersion: String?
    /// The runtime said it has no `thread/prediction/request`, so this process forks as the app does.
    private var predictionRequestUnavailable = false
    private var modelProviderByLocalSessionID: [UUID: String] = [:]
    /// The one prediction a task waits for: the turn it follows. A newer turn replaces it.
    private var predictionBySessionID: [UUID: PendingPrediction] = [:]
    /// The fork turns that make predictions, keyed by their ephemeral thread.
    private var predictionTurns: [String: PredictionTurn] = [:]

    private struct PendingPrediction: Equatable {
        let id = UUID()
        let sourceTurnID: String
    }

    private struct PredictionTurn {
        let localSessionID: UUID
        var turnID: String?
        var streamedText = ""
        var finalMessage: String?
        /// The turn ended by itself (no interrupt needed).
        var ended = false
        var result: String??
        var continuation: CheckedContinuation<String?, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    /// `namesNewThreads` and `predictsNextMessages` are on for the app's runtime adapters; a
    /// scripted transport leaves them off so each test sees only the requests it scripted.
    /// `asksForNextMessageSuggestions` is the "Next message suggestions" setting, read at each
    /// turn's end: off, no prediction is asked for at all.
    init(
        executableURL: URL,
        runtimeCompatibility: CodexRuntimeCompatibility = .restorationBaseline,
        clientVersion: String = "0.0.1",
        transport: (any CodexTransport)? = nil,
        environmentManager: CodexEnvironmentManager? = nil,
        environmentScope: SessionEnvironmentScope = .native,
        namesNewThreads: Bool = false,
        predictsNextMessages: Bool = false,
        asksForNextMessageSuggestions: @escaping @Sendable () -> Bool = { NextMessageSuggestionPreference.isOn() },
        resourceOwner: TaskResourceOwner? = nil
    ) {
        let executableURL = executableURL.standardizedFileURL
        self.executableURL = executableURL
        self.runtimeCompatibility = runtimeCompatibility
        self.clientVersion = clientVersion
        self.namesNewThreads = namesNewThreads
        self.predictsNextMessages = predictsNextMessages
        self.asksForNextMessageSuggestions = asksForNextMessageSuggestions
        self.transport = transport ?? CodexProcessTransport(
            executableURL: executableURL,
            environmentManager: environmentManager,
            environmentScope: environmentScope,
            resourceOwner: resourceOwner
        )
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)) else {
            throw HarnessAdapterError.runtimeNotFound(executableURL)
        }

        let versionOutput = try readVersion()
        guard runtimeCompatibility.accepts(versionOutput: versionOutput) else {
            throw HarnessAdapterError.unsupportedRuntime(version: versionOutput)
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: executableURL.path(percentEncoded: false)
        )
        let size = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date
        let fingerprint = [
            executableURL.path(percentEncoded: false),
            versionOutput,
            size?.stringValue ?? "unknown-size",
            modifiedAt.map { String($0.timeIntervalSince1970) } ?? "unknown-mtime"
        ].joined(separator: "|")

        return HarnessRuntimeDescriptor(
            harness: .codex,
            executableURL: executableURL,
            version: versionOutput,
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                acceptsImages: true,
                hasSubagents: true
            ),
            fingerprint: fingerprint
        )
    }

    /// The task's saved permission (`CodexRunLocation.storageKey`) and mode
    /// (`CodexCollaborationPreset.storageKey`), handed over before the thread starts or resumes so
    /// the thread carries them from its first request; the Default choice and a task without a
    /// mode send the requests as before.
    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) {
        let location = CodexRunLocation.restored(from: options)
        if location == .automatic {
            runLocationByLocalSessionID.removeValue(forKey: localSessionID)
        } else {
            runLocationByLocalSessionID[localSessionID] = location
        }
        collaborationPresetByLocalSessionID[localSessionID] = CodexCollaborationPreset.restored(from: options)
    }

    /// The project's other roots, handed over before the thread starts or resumes. An empty list
    /// leaves the request exactly as a single-folder task sends it.
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
        if roots.isEmpty {
            additionalRootsByLocalSessionID.removeValue(forKey: localSessionID)
        } else {
            additionalRootsByLocalSessionID[localSessionID] = roots.map(\.standardizedFileURL)
        }
    }

    /// The Yardlet MCP server for the thread this task starts, resumes, or forks into, sent as the
    /// thread's `config` override.
    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) {
        agentToolServerByLocalSessionID[localSessionID] = server
    }

    /// Yardlet instructions for the thread this task starts, resumes, or forks into, sent as the thread's
    /// `developerInstructions`.
    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) {
        yardletInstructionsByLocalSessionID[localSessionID] = instructions?.text
    }

    /// The thread's `developerInstructions`: the configuration's own `developer_instructions` for
    /// this folder (which the field would otherwise replace), then Yardlet's text. AGENTS.md is a
    /// separate message Codex keeps loading. When the configuration cannot be read nothing is
    /// sent, so the person's own developer instructions are never dropped.
    private func developerInstructions(for localSessionID: UUID, workspaceURL: URL) async -> String? {
        guard let text = yardletInstructionsByLocalSessionID[localSessionID] else { return nil }
        guard let response = try? await transport.request(
            CodexProtocol.readConfig(id: takeRequestID(), workspaceURL: workspaceURL, includeLayers: false)
        ), response.error == nil, let configuration = response.result?["config"] else { return nil }
        return YardletInstructionsLaunch.codexDeveloperInstructions(
            configured: configuration["developer_instructions"]?.stringValue, yardlet: text)
    }

    /// The thread this session starts is ephemeral: the App Server keeps it in memory only, so it
    /// is in neither the Codex app's list nor an import, and it is not named. Only a thread not
    /// started yet can be; a resumed or forked one is already saved.
    func keepNoHistory(for localSessionID: UUID) -> Bool {
        guard handles[localSessionID] == nil else { return false }
        historyFreeSessionIDs.insert(localSessionID)
        return true
    }

    /// The instruction files Codex reported loading for this thread. `nil` means the runtime
    /// said nothing, which must not be presented as an empty result.
    func instructionSources(for localSessionID: UUID) -> [String]? {
        instructionSourcesByLocalSessionID[localSessionID]
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        try await ensureInitialized()
        let developerInstructions = await developerInstructions(for: request.localSessionID,
                                                                workspaceURL: request.workspaceURL)
        let response = try await transport.request(
            CodexProtocol.startThread(
                id: takeRequestID(),
                workspaceURL: request.workspaceURL,
                additionalRoots: additionalRootsByLocalSessionID[request.localSessionID] ?? [],
                config: agentToolServerByLocalSessionID[request.localSessionID]?.codexConfig,
                ephemeral: historyFreeSessionIDs.contains(request.localSessionID),
                developerInstructions: developerInstructions,
                runLocation: runLocationByLocalSessionID[request.localSessionID] ?? .automatic
            )
        )
        let threadID = try threadID(from: response)
        captureInstructionSources(response.result, for: request.localSessionID)
        let handle = HarnessSessionHandle(
            harness: .codex,
            localSessionID: request.localSessionID,
            providerSessionID: threadID,
            workspaceURL: request.workspaceURL.standardizedFileURL
        )
        register(handle)
        captureModelSelection(response.result, for: request.localSessionID)
        applySnapshot(response.result?["thread"], for: request.localSessionID)
        emit(.sessionStarted(handle), for: request.localSessionID)
        emit(.sessionStatusChanged(.ready), for: request.localSessionID)
        // A thread kept nowhere is in no list, so it needs no name.
        if namesNewThreads, !historyFreeSessionIDs.contains(request.localSessionID) {
            unnamedNewThreadSessionIDs.insert(request.localSessionID)
        }

        if let prompt = request.initialPrompt, !prompt.isEmpty {
            try await send(prompt, to: handle)
        }
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        try await ensureInitialized()
        // The locked resume schema can return an initial `thread/turns/list` page and opaque
        // head cursors in the same response. Ask for a bounded, fully-renderable bootstrap page
        // while retaining a legacy retry for older compatible runtimes that reject the additive
        // fields. This keeps resume deterministic without making runtime compatibility depend on
        // one optional schema extension.
        let additionalRoots = additionalRootsByLocalSessionID[localSessionID] ?? []
        let config = agentToolServerByLocalSessionID[localSessionID]?.codexConfig
        let developerInstructions = await developerInstructions(for: localSessionID, workspaceURL: workspaceURL)
        let runLocation = runLocationByLocalSessionID[localSessionID] ?? .automatic
        let response: CodexRPCIncomingMessage
        do {
            do {
                response = try await transport.request(
                    CodexProtocol.resumeThread(
                        id: takeRequestID(),
                        threadID: providerSessionID,
                        workspaceURL: workspaceURL,
                        excludeTurns: true,
                        initialTurnsPage: .object([
                            "sortDirection": .string("desc"),
                            "itemsView": .string("full"),
                            "limit": .integer(3)
                        ]),
                        additionalRoots: additionalRoots,
                        config: config,
                        developerInstructions: developerInstructions,
                        runLocation: runLocation
                    )
                )
            } catch let failure as CodexRPCRequestFailure where !failure.isThreadWriterConflict {
                // Only a runtime that answered and refused the request is asked again without the
                // bootstrap fields. A timeout or an ended process would only fail again, and the
                // retry asks for the whole history, which a long thread makes very large.
                response = try await transport.request(
                    CodexProtocol.resumeThread(
                        id: takeRequestID(),
                        threadID: providerSessionID,
                        workspaceURL: workspaceURL,
                        additionalRoots: additionalRoots,
                        config: config,
                        developerInstructions: developerInstructions,
                        runLocation: runLocation
                    )
                )
            }
        } catch let failure as CodexRPCRequestFailure where failure.isThreadWriterConflict {
            throw CodexThreadHeldElsewhere(providerMessage: failure.localizedDescription)
        }
        let resumedThreadID = try threadID(from: response)
        captureInstructionSources(response.result, for: localSessionID)
        let handle = HarnessSessionHandle(
            harness: .codex,
            localSessionID: localSessionID,
            providerSessionID: resumedThreadID,
            workspaceURL: workspaceURL.standardizedFileURL
        )
        register(handle)
        captureModelSelection(response.result, for: localSessionID)
        applyResumeResult(response.result, for: localSessionID)
        await hydrateResumeItemHistory(for: handle)
        emit(.sessionStarted(handle), for: localSessionID)
        emit(
            .sessionStatusChanged(
                activeTurnIDByLocalSessionID[localSessionID] == nil ? .ready : .running
            ),
            for: localSessionID
        )
        return handle
    }

    /// `thread/resume` can return a renderable turn page that contains only narrative items.
    /// Merge the provider's item history as a best-effort supplement so completed command and
    /// tool cards survive a process restart. Older compatible runtimes may not implement the
    /// additive endpoint, so failure must not make an otherwise valid resume fail.
    private func hydrateResumeItemHistory(for session: HarnessSessionHandle) async {
        do {
            let response = try await transport.request(
                CodexProtocol.listItems(
                    id: takeRequestID(),
                    threadID: session.providerSessionID,
                    limit: 100
                )
            )
            let page = taskDecoder.itemPage(from: response.result)
            guard !page.entries.isEmpty else { return }
            var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
            let loadedTurnIDs = Set(state.thread?.turns.map(\.id) ?? [])
            let loadedPage = CodexItemPage(
                entries: page.entries.filter { loadedTurnIDs.contains($0.turnID) },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor
            )
            guard !loadedPage.entries.isEmpty else { return }
            // The unscoped item endpoint can include cards from turns outside the bounded resume
            // page. Do not invent placeholder in-progress turns for those orphaned entries; their
            // owning turns and items will arrive together if the user pages backwards.
            taskReducer.mergeItemPage(loadedPage, into: &state)
            publish(state, for: session.localSessionID)
        } catch {
            // Resume remains authoritative for thread identity even when item hydration is absent.
        }
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await submit(
            CodexComposerDraft(inputs: [.text(prompt)]),
            submission: .start,
            to: session
        )
    }

    func submit(
        _ draft: CodexComposerDraft,
        submission: CodexTurnSubmission,
        to session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard !draft.isEmpty else { return }
        switch submission {
        case .start:
            let response = try await transport.request(
                CodexProtocol.startTurn(
                    id: takeRequestID(),
                    threadID: session.providerSessionID,
                    input: draft.inputs,
                    collaborationPreset: collaborationPresetByLocalSessionID[session.localSessionID],
                    runLocation: runLocationByLocalSessionID[session.localSessionID] ?? .automatic,
                    modelSelection: modelSelectionByLocalSessionID[session.localSessionID]
                )
            )
            guard let turnID = response.result?["turn"]?["id"]?.stringValue else {
                throw HarnessAdapterError.invalidProviderEvent("turn/start response is missing turn.id")
            }
            activeTurnIDByLocalSessionID[session.localSessionID] = turnID
            if unnamedNewThreadSessionIDs.remove(session.localSessionID) != nil,
               let request = CodexThreadTitle.request(from: draft.inputs) {
                threadNamingTasks[session.localSessionID] = Task { [weak self] in
                    await self?.nameThread(from: request, for: session)
                }
            }
        case let .steer(expectedTurnID):
            guard resolvedActiveTurnID(for: session.localSessionID) == expectedTurnID else {
                throw HarnessAdapterError.invalidProviderEvent("Codex active turn changed before steer")
            }
            _ = try await transport.request(
                CodexProtocol.steerTurn(
                    id: takeRequestID(),
                    threadID: session.providerSessionID,
                    expectedTurnID: expectedTurnID,
                    input: draft.inputs
                )
            )
        }
        emitPostServerResponseStatus(for: session.localSessionID)
    }

    func activeTurnID(for session: HarnessSessionHandle) -> String? {
        resolvedActiveTurnID(for: session.localSessionID)
    }

    func answerablePendingServerRequestIDs(
        _ requests: [CodexPendingServerRequest],
        for session: HarnessSessionHandle
    ) -> Set<String> {
        Set(requests.compactMap { request in
            guard let context = serverRequestContexts[request.id],
                  context.localSessionID == session.localSessionID,
                  context.method == request.method,
                  let liveRequest = presentationStateByLocalSessionID[session.localSessionID]?
                    .serverRequestsByID[request.id],
                  liveRequest.method == request.method,
                  liveRequest.threadID == request.threadID,
                  liveRequest.turnID == request.turnID,
                  liveRequest.itemID == request.itemID,
                  case .pending = liveRequest.resolution else { return nil }
            return request.id
        })
    }

    /// Stops as the Codex app stops (26.1016 `interruptConversation`): every request still waiting
    /// on the task is answered no first, then the turn is interrupted. An MCP server that asked
    /// (Computer Use's "Allow … to use Whale?") hears decline rather than waiting on a card whose
    /// turn has ended, and the card reads as denied at once.
    func interrupt(_ session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        let declined = await declinePendingServerRequests(for: session.localSessionID)
        guard let turnID = resolvedActiveTurnID(for: session.localSessionID) else {
            if declined {
                emitPostServerResponseStatus(for: session.localSessionID)
                return
            }
            throw HarnessAdapterError.capabilityUnavailable("No active Codex turn to interrupt")
        }
        _ = try await transport.request(
            CodexProtocol.interruptTurn(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                turnID: turnID
            )
        )
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard let context = serverRequestContexts[permissionRequestID],
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-resolved permission request"
            )
        }

        let result: JSONValue
        switch context.method {
        case "item/permissions/requestApproval":
            result = .object([
                "permissions": decision == .allow
                    ? (context.requestedPermissions ?? .object([:]))
                    : .object([:]),
                "scope": .string("turn")
            ])
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "applyPatchApproval", "execCommandApproval":
            result = .object([
                "decision": .string(decision == .allow ? "accept" : "decline")
            ])
        default:
            throw HarnessAdapterError.capabilityUnavailable(
                "Codex request cannot be answered by the permission control"
            )
        }

        try await transport.sendResponse(
            CodexRPCResponse(id: context.rpcID, result: result)
        )
        serverRequestContexts.removeValue(forKey: permissionRequestID)
        var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        if taskReducer.resolveServerRequest(
            id: permissionRequestID,
            response: result,
            in: &state
        ) {
            publish(state, for: session.localSessionID)
        }
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func respond(
        to serverRequestID: String,
        response: CodexServerRequestResponse,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard let context = serverRequestContexts[serverRequestID],
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-resolved Codex server request"
            )
        }
        guard let result = response.result(for: context.method) else {
            throw HarnessAdapterError.capabilityUnavailable(
                "Response does not match Codex server request method (context.method)"
            )
        }
        try await transport.sendResponse(
            CodexRPCResponse(id: context.rpcID, result: result)
        )
        serverRequestContexts.removeValue(forKey: serverRequestID)
        var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        if taskReducer.resolveServerRequest(
            id: serverRequestID,
            response: result,
            in: &state
        ) {
            publish(state, for: session.localSessionID)
        }
        emitPostServerResponseStatus(for: session.localSessionID)
    }

    /// The answer stopping gives each kind of request, the Codex app's: decline, no permissions,
    /// no answers. Dynamic tool calls and older reviews are left to the turn's end, as there.
    static func stopAnswer(for method: String) -> CodexServerRequestResponse? {
        switch method {
        case "item/commandExecution/requestApproval": .command(.decline)
        case "item/fileChange/requestApproval": .fileChange(.decline)
        case "item/permissions/requestApproval":
            .permissions(permissions: .object([:]), scope: .turn, strictAutoReview: nil)
        case "item/tool/requestUserInput": .toolUserInput(answers: [:])
        case "mcpServer/elicitation/request": .mcpElicitation(action: .decline)
        default: nil
        }
    }

    /// Whether any request was answered.
    private func declinePendingServerRequests(for localSessionID: UUID) async -> Bool {
        let pending = serverRequestContexts
            .filter { $0.value.localSessionID == localSessionID }
            .sorted { $0.key < $1.key }
        var declined = false
        for (requestID, context) in pending {
            guard let result = Self.stopAnswer(for: context.method)?.result(for: context.method),
                  (try? await transport.sendResponse(CodexRPCResponse(id: context.rpcID, result: result))) != nil
            else { continue }
            serverRequestContexts.removeValue(forKey: requestID)
            var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
            if taskReducer.resolveServerRequest(id: requestID, response: result, in: &state) {
                publish(state, for: localSessionID)
            }
            declined = true
        }
        return declined
    }

    /// A restored approval can belong to a turn the provider already marked terminal while the
    /// prior app process shut down. Resolving that app-local card must not manufacture a running
    /// session when the resumed provider has no active turn.
    private func emitPostServerResponseStatus(for localSessionID: UUID) {
        emit(
            .sessionStatusChanged(
                resolvedActiveTurnID(for: localSessionID) == nil ? .ready : .running
            ),
            for: localSessionID
        )
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = eventChannel.subscribe(to: session.localSessionID)
        if transportEnded { eventChannel.finish(session.localSessionID) }
        return stream
    }

    func presentationState(for session: HarnessSessionHandle) throws -> CodexTaskState {
        try requireRegistered(session)
        return presentationStateByLocalSessionID[session.localSessionID] ?? .empty
    }

    func refreshPresentationState(
        for session: HarnessSessionHandle
    ) async throws -> CodexTaskState {
        try requireRegistered(session)
        let response = try await transport.request(
            CodexProtocol.readThread(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                includeTurns: true
            )
        )
        guard let thread = response.result?["thread"] else {
            throw HarnessAdapterError.invalidProviderEvent(
                "thread/read response is missing thread"
            )
        }
        applySnapshot(thread, for: session.localSessionID)
        return presentationStateByLocalSessionID[session.localSessionID] ?? .empty
    }

    /// A saved thread as `thread/read` gives it, with its newest turns from `thread/turns/list`
    /// (or every turn from `thread/read` when `newestTurns` is nil). Nothing is registered or
    /// published: the thread is not loaded or resumed and no session exists for it.
    func readThreadPresentation(threadID: String, newestTurns: Int64?) async throws -> CodexTaskState {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.readThread(id: takeRequestID(), threadID: threadID, includeTurns: newestTurns == nil)
        )
        var state = CodexTaskState.empty
        guard let thread = response.result?["thread"], thread["id"]?.stringValue == threadID,
              taskReducer.applySnapshot(thread, to: &state) else {
            throw HarnessAdapterError.invalidProviderEvent("thread/read response is missing thread")
        }
        guard let newestTurns else { return state }
        let page = try await readThreadTurns(threadID: threadID, cursor: nil, limit: newestTurns)
        taskReducer.mergeTurnPage(page, into: &state)
        return state
    }

    /// A page of a saved thread's turns, asked newest first with every item (`thread/turns/list`
    /// works on a thread no App Server has loaded), returned oldest first. Nothing is registered.
    func readThreadTurns(threadID: String, cursor: String?, limit: Int64) async throws -> CodexTurnPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.listTurns(id: takeRequestID(), threadID: threadID, cursor: cursor, limit: limit,
                                    sortDirection: "desc")
        )
        return chronologicalPage(fromDescending: taskDecoder.turnPage(from: response.result))
    }

    func loadTurns(
        for session: HarnessSessionHandle,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexTurnPage {
        try requireRegistered(session)
        let response = try await transport.request(
            CodexProtocol.listTurns(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                cursor: cursor,
                limit: limit,
                sortDirection: "desc"
            )
        )
        let page = chronologicalPage(fromDescending: taskDecoder.turnPage(from: response.result))
        var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        taskReducer.mergeTurnPage(page, prepending: cursor != nil, into: &state)
        syncActiveTurnID(from: state, for: session.localSessionID)
        publish(state, for: session.localSessionID)
        return page
    }

    func loadItems(
        for session: HarnessSessionHandle,
        turnID: String?,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexItemPage {
        try requireRegistered(session)
        let response = try await transport.request(
            CodexProtocol.listItems(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                turnID: turnID,
                cursor: cursor,
                limit: limit
            )
        )
        let page = taskDecoder.itemPage(from: response.result)
        var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        taskReducer.mergeItemPage(page, into: &state)
        publish(state, for: session.localSessionID)
        return page
    }

    func presentationStates(
        for session: HarnessSessionHandle
    ) async throws -> AsyncStream<CodexTaskState> {
        try requireRegistered(session)
        // These are complete snapshots. A busy renderer needs the newest state, not a
        // backlog of obsolete partial answers; lossless events use a separate stream.
        let pair = AsyncStream<CodexTaskState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(
            presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        )
        presentationContinuations[session.localSessionID]?.finish()
        presentationContinuations[session.localSessionID] = pair.continuation
        if transportEnded { pair.continuation.finish() }
        return pair.stream
    }

    private func captureModelSelection(_ result: JSONValue?, for sessionID: UUID) {
        if let provider = result?["modelProvider"]?.stringValue {
            modelProviderByLocalSessionID[sessionID] = provider
        }
        guard let model = result?["model"]?.stringValue else { return }
        modelSelectionByLocalSessionID[sessionID] = CodexModelSelection(
            model: model, reasoningEffort: result?["reasoningEffort"]?.stringValue,
            serviceTier: result?["serviceTier"]?.stringValue
        )
    }

    /// `thread/start` and `thread/resume` report the instruction files the thread actually
    /// loaded. A runtime that omits the field leaves the previous answer alone rather than
    /// asserting that nothing applies.
    private func captureInstructionSources(_ result: JSONValue?, for sessionID: UUID) {
        guard let values = result?["instructionSources"]?.arrayValue else { return }
        instructionSourcesByLocalSessionID[sessionID] = values.compactMap(\.stringValue)
    }

    func modelCatalog(for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        try requireRegistered(session)
        return CodexModelCatalog(
            models: try await loadModelOptions(),
            selection: modelSelectionByLocalSessionID[session.localSessionID]
        )
    }

    private func loadModelOptions() async throws -> [CodexModelOption] {
        if modelOptions == nil {
            var options: [CodexModelOption] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                var params: [String: JSONValue] = ["includeHidden": .bool(false), "limit": .integer(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let response = try await transport.request(CodexRPCRequest(
                    id: takeRequestID(), method: "model/list", params: .object(params)
                ))
                CodexModelList.append(page: response.result, to: &options)
                cursor = response.result?["nextCursor"]?.stringValue
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw HarnessAdapterError.invalidProviderEvent("Repeated Codex model catalog cursor")
                }
            } while cursor != nil
            modelOptions = options
        }
        return modelOptions ?? []
    }

    func selectModel(_ selection: CodexModelSelection, for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        var catalog = try await modelCatalog(for: session)
        guard let model = catalog.models.first(where: { $0.model == selection.model }),
              selection.reasoningEffort.map({ model.supportedReasoningEfforts.contains($0) }) ?? true,
              selection.serviceTier.map({ tier in tier == "default" || model.serviceTiers?.contains(where: { $0.id == tier }) == true }) ?? true else {
            throw HarnessAdapterError.invalidProviderEvent("Unsupported Codex model or reasoning effort")
        }
        modelSelectionByLocalSessionID[session.localSessionID] = selection
        // A model, effort or Fast choice leaves the mode alone: the next turn carries the mode
        // with this model and effort in its settings, as the Codex app keeps the two apart.
        catalog.selection = selection
        return catalog
    }

    func collaborationModes() async throws -> [CodexCollaborationPreset] {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.collaborationModes(id: takeRequestID())
        )
        return capabilityProjector.modes(from: response.result)
    }

    /// The thread's MCP servers, every page of `mcpServerStatus/list` for it. Reading starts no turn.
    func mcpServers(for session: HarnessSessionHandle) async throws -> [HarnessMCPServerStatus] {
        try requireRegistered(session)
        try await ensureInitialized()
        var servers: [HarnessMCPServerStatus] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let response = try await transport.request(CodexRPCRequest(
                id: takeRequestID(), method: "mcpServerStatus/list",
                params: CodexMCPServers.listParams(threadID: session.providerSessionID, cursor: cursor)
            ))
            let page = CodexMCPServers.decode(response.result ?? .null)
            servers += page.servers
            cursor = page.nextCursor
        } while cursor.map { seenCursors.insert($0).inserted } == true
        return servers
    }

    /// The App Server reports servers only when asked; the app keeps what it last read.
    func reportedMCPServers(for localSessionID: UUID) async -> [HarnessMCPServerStatus]? { nil }

    func skills(in workspaceURL: URL) async throws -> [CodexSkillSummary] {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.skills(id: takeRequestID(), workspaceURL: workspaceURL)
        )
        return capabilityProjector.skills(from: response.result)
    }

    func accountRateLimits() async throws -> CodexAccountRateLimits {
        try await ensureInitialized()
        let response = try await transport.request(CodexProtocol.accountRateLimits(id: takeRequestID()))
        return CodexAccountRateLimits(response: response.result)
    }

    func plugins(in workspaceURL: URL) async throws -> [CodexPluginSummary] {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.plugins(id: takeRequestID(), workspaceURL: workspaceURL)
        )
        return capabilityProjector.plugins(from: response.result)
    }

    func recentThreads(in workspaceURL: URL) async throws -> [CodexThreadSummary] {
        try await recentThreadsPage(in: workspaceURL, cursor: nil, limit: 30).threads
    }

    func recentThreadsPage(
        in workspaceURL: URL,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexRecentThreadsPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.recentThreads(
                id: takeRequestID(),
                workspaceURL: workspaceURL,
                cursor: cursor,
                limit: limit
            )
        )
        let page = capabilityProjector.recentThreadsPage(from: response.result)
        let workspacePath = workspaceURL.standardizedFileURL.path(percentEncoded: false)
        return CodexRecentThreadsPage(
            threads: page.threads.filter {
                $0.workspaceURL.standardizedFileURL.path(percentEncoded: false) == workspacePath
            },
            nextCursor: page.nextCursor
        )
    }

    func interactiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.interactiveThreads(id: takeRequestID(), cursor: cursor, limit: limit)
        )
        return capabilityProjector.interactiveThreadsPage(from: response.result)
    }

    func archivedInteractiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.interactiveThreads(id: takeRequestID(), cursor: cursor, limit: limit, archived: true)
        )
        return capabilityProjector.interactiveThreadsPage(from: response.result)
    }

    func searchThreads(
        in workspaceURL: URL,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.searchThreads(
                id: takeRequestID(),
                searchTerm: searchTerm,
                cursor: cursor,
                limit: limit
            )
        )
        let page = capabilityProjector.searchPage(from: response.result)
        let workspacePath = workspaceURL.standardizedFileURL.path(percentEncoded: false)
        return CodexThreadSearchPage(
            matches: page.matches.filter {
                $0.thread.workspaceURL.standardizedFileURL.path(percentEncoded: false) == workspacePath
            },
            nextCursor: page.nextCursor
        )
    }

    func searchOccurrences(
        threadID: String,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchOccurrencesPage {
        try await ensureInitialized()
        let response = try await transport.request(
            CodexProtocol.searchOccurrences(
                id: takeRequestID(),
                threadID: threadID,
                searchTerm: searchTerm,
                cursor: cursor,
                limit: limit
            )
        )
        return capabilityProjector.searchOccurrencesPage(from: response.result)
    }

    func setThreadName(_ name: String, for session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Task title cannot be empty")
            )
        }
        // The person's name wins over one still being generated.
        unnamedNewThreadSessionIDs.remove(session.localSessionID)
        threadNamingTasks.removeValue(forKey: session.localSessionID)?.cancel()
        try await ensureInitialized()
        _ = try await transport.request(
            CodexProtocol.setThreadName(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                name: trimmed
            )
        )
    }

    /// Runs beside the first request's own turn, as in the official app. A name the thread got
    /// meanwhile, from the person or from another client, is kept.
    private func nameThread(from request: String, for session: HarnessSessionHandle) async {
        defer { threadNamingTasks.removeValue(forKey: session.localSessionID) }
        guard let title = await generateThreadTitle(from: request, workspaceURL: session.workspaceURL),
              !Task.isCancelled, handles[session.localSessionID] == session,
              (presentationStateByLocalSessionID[session.localSessionID]?.thread?.name ?? "").isEmpty else { return }
        let rename = CodexProtocol.setThreadName(id: takeRequestID(), threadID: session.providerSessionID, name: title)
        guard (try? await transport.request(rename)) != nil else { return }
        // `thread/name/updated` reports the same name; applying it here does not depend on it.
        var state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        if taskReducer.applyNotification(
            method: "thread/name/updated",
            params: .object(["threadId": .string(session.providerSessionID), "threadName": .string(title)]),
            sequence: nextPresentationSequence(for: session.localSessionID),
            to: &state
        ) {
            publish(state, for: session.localSessionID)
        }
    }

    private func generateThreadTitle(from request: String, workspaceURL: URL) async -> String? {
        let offersPreferredModel = (try? await loadModelOptions())?
            .contains { $0.model == CodexThreadTitle.preferredModel } == true
        guard !Task.isCancelled,
              let response = try? await transport.request(CodexThreadTitle.startThread(
                id: takeRequestID(),
                workspaceURL: workspaceURL,
                model: offersPreferredModel ? CodexThreadTitle.preferredModel : nil
              )),
              let sideThreadID = try? threadID(from: response) else { return nil }
        titleTurns[sideThreadID] = TitleTurn()
        var finalMessage: String?
        if (try? await transport.request(CodexThreadTitle.startTurn(
            id: takeRequestID(), threadID: sideThreadID, request: request
        ))) != nil {
            finalMessage = await titleTurnResult(sideThreadID)
        }
        finishTitleTurn(sideThreadID, result: nil)
        titleTurns.removeValue(forKey: sideThreadID)
        _ = try? await transport.request(CodexThreadTitle.unsubscribe(id: takeRequestID(), threadID: sideThreadID))
        return CodexThreadTitle.title(fromFinalMessage: finalMessage)
    }

    private func titleTurnResult(_ threadID: String) async -> String? {
        if let result = titleTurns[threadID]?.result { return result }
        return await withCheckedContinuation { continuation in
            guard titleTurns[threadID] != nil else {
                continuation.resume(returning: nil)
                return
            }
            titleTurns[threadID]?.continuation = continuation
            titleTurns[threadID]?.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: CodexThreadTitle.timeout)
                guard !Task.isCancelled else { return }
                await self?.finishTitleTurn(threadID, result: nil)
            }
        }
    }

    private func acceptTitleTurnNotification(_ message: CodexRPCIncomingMessage, threadID: String) {
        switch message.method {
        case "item/completed":
            guard let item = message.params?["item"], item["type"]?.stringValue == "agentMessage" else { return }
            titleTurns[threadID]?.finalMessage = item["text"]?.stringValue
        case "turn/completed":
            let status = message.params?["turn"]?["status"]?.stringValue ?? "completed"
            finishTitleTurn(threadID, result: status == "completed" ? titleTurns[threadID]?.finalMessage : nil)
        default:
            return
        }
    }

    private func finishTitleTurn(_ threadID: String, result: String?) {
        guard var turn = titleTurns[threadID], turn.result == nil else { return }
        let continuation = turn.continuation
        turn.timeoutTask?.cancel()
        turn.result = .some(result)
        turn.continuation = nil
        turn.timeoutTask = nil
        titleTurns[threadID] = turn
        continuation?.resume(returning: result)
    }

    // MARK: - Next-message prediction

    /// After a turn of a saved thread ends, as the Codex app asks. Never for a thread kept nowhere
    /// (`run_agent`, whose fork mode the App Server refuses anyway), in Plan mode, or on another
    /// provider than OpenAI's (the app's own exclusions), and not at all with the setting off.
    private func schedulePrediction(after sourceTurnID: String, for localSessionID: UUID) {
        cancelPrediction(for: localSessionID)
        guard predictsNextMessages, asksForNextMessageSuggestions(),
              let session = handles[localSessionID],
              !historyFreeSessionIDs.contains(localSessionID),
              collaborationPresetByLocalSessionID[localSessionID]?.mode != "plan",
              (modelProviderByLocalSessionID[localSessionID] ?? "openai") == "openai" else { return }
        let prediction = PendingPrediction(sourceTurnID: sourceTurnID)
        predictionBySessionID[localSessionID] = prediction
        Task { [weak self] in await self?.predictNextMessage(prediction, for: session) }
    }

    private func isCurrent(_ prediction: PendingPrediction, for localSessionID: UUID) -> Bool {
        predictionBySessionID[localSessionID] == prediction
    }

    /// A new turn, a newer prediction, or the task closing lets the waiting one go; a fork turn
    /// still running is stopped.
    private func cancelPrediction(for localSessionID: UUID) {
        predictionBySessionID.removeValue(forKey: localSessionID)
        for (threadID, turn) in predictionTurns where turn.localSessionID == localSessionID {
            finishPredictionTurn(threadID, result: nil)
        }
    }

    private func predictNextMessage(_ prediction: PendingPrediction, for session: HarnessSessionHandle) async {
        let localSessionID = session.localSessionID
        if !predictionRequestUnavailable {
            do {
                // A runtime that implements it answers with `thread/prediction/updated`.
                _ = try await transport.request(CodexMessagePrediction.request(
                    id: takeRequestID(), threadID: session.providerSessionID, sourceTurnID: prediction.sourceTurnID))
                return
            } catch let failure as CodexRPCRequestFailure where CodexMessagePrediction.isUnimplemented(failure) {
                predictionRequestUnavailable = true
            } catch {
                if isCurrent(prediction, for: localSessionID) { predictionBySessionID.removeValue(forKey: localSessionID) }
                return
            }
        }
        guard isCurrent(prediction, for: localSessionID),
              CodexMessagePrediction.supportsForkMode(appServerVersion: appServerVersion),
              let forked = try? await transport.request(CodexMessagePrediction.forkThread(
                  id: takeRequestID(), threadID: session.providerSessionID)),
              let forkThreadID = try? threadID(from: forked) else {
            if isCurrent(prediction, for: localSessionID) { predictionBySessionID.removeValue(forKey: localSessionID) }
            return
        }
        predictionTurns[forkThreadID] = PredictionTurn(localSessionID: localSessionID)
        var finalMessage: String?
        if isCurrent(prediction, for: localSessionID) {
            let effort = await predictionEffort(for: localSessionID)
            if isCurrent(prediction, for: localSessionID),
               let started = try? await transport.request(CodexMessagePrediction.startTurn(
                   id: takeRequestID(), forkThreadID: forkThreadID, sourceThreadID: session.providerSessionID,
                   sourceTurnID: prediction.sourceTurnID, effort: effort)) {
                if predictionTurns[forkThreadID]?.turnID == nil {
                    predictionTurns[forkThreadID]?.turnID = started.result?["turn"]?["id"]?.stringValue
                }
                finalMessage = await predictionTurnResult(forkThreadID)
            }
        }
        finishPredictionTurn(forkThreadID, result: nil)
        let turn = predictionTurns.removeValue(forKey: forkThreadID)
        if turn?.ended != true, let turnID = turn?.turnID {
            _ = try? await transport.request(CodexProtocol.interruptTurn(
                id: takeRequestID(), threadID: forkThreadID, turnID: turnID))
        }
        _ = try? await transport.request(CodexThreadTitle.unsubscribe(id: takeRequestID(), threadID: forkThreadID))
        guard isCurrent(prediction, for: localSessionID) else { return }
        predictionBySessionID.removeValue(forKey: localSessionID)
        deliverPrediction(CodexMessagePrediction.suggestion(fromFinalMessage: finalMessage), for: localSessionID)
    }

    /// Only while nothing runs and the setting is still on; the app model drops a late one too.
    private func deliverPrediction(_ suggestion: String?, for localSessionID: UUID) {
        guard let suggestion, handles[localSessionID] != nil, asksForNextMessageSuggestions(),
              resolvedActiveTurnID(for: localSessionID) == nil else { return }
        emit(.nextMessageSuggestion(suggestion), for: localSessionID)
    }

    private func predictionEffort(for localSessionID: UUID) async -> String? {
        guard let model = modelSelectionByLocalSessionID[localSessionID]?.model,
              let options = try? await loadModelOptions() else { return nil }
        return CodexMessagePrediction.effort(for: options.first { $0.model == model })
    }

    /// `thread/prediction/updated` for the turn the task waits on. A failed result, an unknown one,
    /// or one for an older turn shows nothing and reports nothing.
    private func acceptPredictionUpdate(_ params: JSONValue?, for localSessionID: UUID) {
        guard let update = CodexMessagePrediction.update(from: params),
              update.threadID == handles[localSessionID]?.providerSessionID,
              predictionBySessionID[localSessionID]?.sourceTurnID == update.sourceTurnID else { return }
        predictionBySessionID.removeValue(forKey: localSessionID)
        guard case let .completed(text) = update.result else { return }
        deliverPrediction(NextMessageSuggestionText.normalized(text), for: localSessionID)
    }

    private func predictionTurnResult(_ threadID: String) async -> String? {
        if let result = predictionTurns[threadID]?.result { return result }
        return await withCheckedContinuation { continuation in
            guard predictionTurns[threadID] != nil else {
                continuation.resume(returning: nil)
                return
            }
            predictionTurns[threadID]?.continuation = continuation
            predictionTurns[threadID]?.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: CodexMessagePrediction.timeout)
                guard !Task.isCancelled else { return }
                await self?.finishPredictionTurn(threadID, result: nil)
            }
        }
    }

    private func acceptPredictionTurnNotification(_ message: CodexRPCIncomingMessage, threadID: String) {
        let params = message.params
        switch message.method {
        case "turn/started":
            predictionTurns[threadID]?.turnID = params?["turn"]?["id"]?.stringValue
        case "item/agentMessage/delta":
            predictionTurns[threadID]?.streamedText += params?["delta"]?.stringValue ?? ""
        case "item/started", "item/completed":
            guard let item = params?["item"], let type = item["type"]?.stringValue else { return }
            guard CodexMessagePrediction.quietItemTypes.contains(type) else {
                // The model acts instead of predicting: stop the turn, suggest nothing.
                finishPredictionTurn(threadID, result: nil)
                return
            }
            if message.method == "item/completed", type == "agentMessage" {
                predictionTurns[threadID]?.finalMessage = item["text"]?.stringValue
            }
        case "turn/completed":
            predictionTurns[threadID]?.ended = true
            let status = params?["turn"]?["status"]?.stringValue ?? "completed"
            let turn = predictionTurns[threadID]
            finishPredictionTurn(threadID, result: status == "completed" ? turn?.finalMessage ?? turn?.streamedText : nil)
        default:
            return
        }
    }

    private func finishPredictionTurn(_ threadID: String, result: String?) {
        guard var turn = predictionTurns[threadID], turn.result == nil else { return }
        let continuation = turn.continuation
        turn.timeoutTask?.cancel()
        turn.result = .some(result)
        turn.continuation = nil
        turn.timeoutTask = nil
        predictionTurns[threadID] = turn
        continuation?.resume(returning: result)
    }

    func archiveThread(_ session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        try await ensureInitialized()
        _ = try await transport.request(
            CodexProtocol.archiveThread(
                id: takeRequestID(),
                threadID: session.providerSessionID
            )
        )
    }

    func backgroundTerminals(in session: HarnessSessionHandle) async throws -> [CodexBackgroundTerminal] {
        try requireRegistered(session)
        try await ensureInitialized()
        var terminals: [CodexBackgroundTerminal] = []
        var cursor: String?
        // A few pages at most: a thread keeps a handful of commands running, not hundreds.
        for _ in 0..<4 {
            let response = try await transport.request(CodexProtocol.listBackgroundTerminals(
                id: takeRequestID(), threadID: session.providerSessionID, cursor: cursor))
            terminals += (response.result?["data"]?.arrayValue ?? []).compactMap(CodexBackgroundTerminal.init(json:))
            cursor = response.result?["nextCursor"]?.stringValue
            if cursor == nil { break }
        }
        return terminals
    }

    func terminateBackgroundTerminal(processID: String, in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        try await ensureInitialized()
        _ = try await transport.request(CodexProtocol.terminateBackgroundTerminal(
            id: takeRequestID(), threadID: session.providerSessionID, processID: processID))
    }

    func cleanBackgroundTerminals(in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        try await ensureInitialized()
        _ = try await transport.request(CodexProtocol.cleanBackgroundTerminals(
            id: takeRequestID(), threadID: session.providerSessionID))
    }

    func unarchiveThread(threadID: String) async throws {
        try await ensureInitialized()
        _ = try await transport.request(
            CodexProtocol.unarchiveThread(id: takeRequestID(), threadID: threadID)
        )
    }

    func deleteThread(_ session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        try await ensureInitialized()
        _ = try await transport.request(
            CodexProtocol.deleteThread(
                id: takeRequestID(),
                threadID: session.providerSessionID
            )
        )
    }

    func selectCollaborationMode(
        _ preset: CodexCollaborationPreset?,
        for session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        if let preset {
            guard preset.mode == "default" || preset.mode == "plan" else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "Unsupported Codex collaboration mode: \(preset.mode)"
                )
            }
            // The mode's turn needs a model; a preset without one uses the chat's, which the
            // thread reported when it started or resumed.
            guard preset.model != nil || modelSelectionByLocalSessionID[session.localSessionID] != nil else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "Codex has not reported this chat's model yet"
                )
            }
            collaborationPresetByLocalSessionID[session.localSessionID] = preset
        } else {
            collaborationPresetByLocalSessionID.removeValue(forKey: session.localSessionID)
        }
    }

    func selectRunLocation(
        _ location: CodexRunLocation,
        for session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        // The selection is applied to the next `turn/start`; `turn/steer` has no
        // sandboxPolicy field in the locked schema and therefore remains unchanged.
        if location == .automatic {
            runLocationByLocalSessionID.removeValue(forKey: session.localSessionID)
        } else {
            runLocationByLocalSessionID[session.localSessionID] = location
        }
    }

    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID
    ) async throws -> HarnessSessionHandle {
        try await fork(session, newLocalSessionID: newLocalSessionID, throughTurnID: nil)
    }

    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID,
        throughTurnID: String?
    ) async throws -> HarnessSessionHandle {
        try requireRegistered(session)
        guard handles[newLocalSessionID] == nil,
              throughTurnID == nil || (throughTurnID?.isEmpty == false
                && throughTurnID != activeTurnIDByLocalSessionID[session.localSessionID]) else {
            throw HarnessAdapterError.invalidProviderEvent("Invalid fork identity or active turn")
        }
        let developerInstructions = await developerInstructions(for: newLocalSessionID,
                                                                workspaceURL: session.workspaceURL)
        let response = try await transport.request(
            CodexProtocol.forkThread(
                id: takeRequestID(),
                threadID: session.providerSessionID,
                workspaceURL: session.workspaceURL,
                config: agentToolServerByLocalSessionID[newLocalSessionID]?.codexConfig,
                throughTurnID: throughTurnID,
                developerInstructions: developerInstructions
            )
        )
        let threadID = try threadID(from: response)
        guard threadID != session.providerSessionID,
              localSessionIDByThreadID[threadID] == nil else {
            throw HarnessAdapterError.invalidProviderEvent("Fork did not create a distinct thread")
        }
        let handle = HarnessSessionHandle(
            harness: .codex,
            localSessionID: newLocalSessionID,
            providerSessionID: threadID,
            workspaceURL: session.workspaceURL
        )
        register(handle)
        // Collaboration and run-location selections are app-local next-turn state. A whole-thread
        // fork keeps the source thread's intent, so carry those selections to the new local handle
        // without inventing any provider-side fork parameters.
        if let preset = collaborationPresetByLocalSessionID[session.localSessionID] {
            collaborationPresetByLocalSessionID[newLocalSessionID] = preset
        }
        if let location = runLocationByLocalSessionID[session.localSessionID] {
            runLocationByLocalSessionID[newLocalSessionID] = location
        }
        // `thread/fork` may return the newly-created thread envelope. Preserve that
        // provider-owned identity/provenance immediately when it is present instead of
        // leaving the forked presentation state empty until a later notification arrives.
        // The locked contract still permits a response containing only `thread.id`, so
        // this remains additive and does not invent a turn-scoped fork snapshot.
        captureModelSelection(response.result, for: newLocalSessionID)
        if let selection = modelSelectionByLocalSessionID[session.localSessionID] {
            modelSelectionByLocalSessionID[newLocalSessionID] = selection
        }
        applySnapshot(response.result?["thread"], for: newLocalSessionID)
        emit(.sessionStarted(handle), for: newLocalSessionID)
        emit(.sessionStatusChanged(.ready), for: newLocalSessionID)
        return handle
    }

    func prepareConversationEdit(_ edit: ConversationEditState, in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        guard edit.harness == .codex, edit.originalProviderSessionID == session.providerSessionID,
              resolvedActiveTurnID(for: session.localSessionID) == nil else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This message can no longer be edited."))
        }
        let page = try await loadTurns(for: session, cursor: nil, limit: 50)
        guard page.turns.allSatisfy({ $0.status.isTerminal }) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop the current turn before editing a message."))
        }
        let users = page.turns.filter(\.hasNativeUserMessage)
        guard users.last?.id == edit.targetID else {
            // Retry after a lost revert acknowledgement is safe only at the exact retained head.
            guard users.last?.id == edit.previousID, !page.turns.contains(where: { $0.id == edit.targetID }),
                  users.last != nil || (edit.previousID == nil && page.turns.isEmpty) else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("This message can no longer be edited."))
            }
            return
        }
        let response: CodexRPCIncomingMessage
        if presentationStateByLocalSessionID[session.localSessionID]?.thread?.raw["historyMode"]?.stringValue == "legacy" {
            guard let index = page.turns.firstIndex(where: { $0.id == edit.targetID }) else {
                throw HarnessAdapterError.invalidProviderEvent("Missing native edit boundary")
            }
            do {
                response = try await transport.request(.init(id: takeRequestID(), method: "thread/rollback", params: .object([
                    "threadId": .string(session.providerSessionID), "numTurns": .integer(Int64(page.turns.count - index))
                ])))
            } catch let failure as CodexRPCRequestFailure {
                let code = failure.payload["code"]
                let message = failure.payload["message"]?.stringValue ?? ""
                if code == .integer(-32601)
                    || (code == .integer(-32600) && message.contains("unknown variant `thread/rollback`")) {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string(
                        "This Codex runtime cannot edit legacy conversations. Your draft and conversation are preserved."))
                }
                throw failure
            }
        } else {
            response = try await transport.request(CodexProtocol.revertConversation(
                id: takeRequestID(), threadID: session.providerSessionID, beforeTurnID: edit.targetID))
        }
        guard response.result?["thread"]?["id"]?.stringValue == session.providerSessionID else {
            throw HarnessAdapterError.invalidProviderEvent("Revert returned another thread identity")
        }
        var fresh = CodexTaskState.empty
        guard taskReducer.applySnapshot(response.result?["thread"] ?? .null, to: &fresh) else {
            throw HarnessAdapterError.invalidProviderEvent("Invalid reverted conversation")
        }
        syncActiveTurnID(from: fresh, for: session.localSessionID)
        publish(fresh, for: session.localSessionID)
        // Revert is already durable. History read failure must not repeat the mutation on retry.
        _ = try? await loadTurns(for: session, cursor: nil, limit: 50)
    }

    func retryFailedTurn(_ turnID: String, in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        guard resolvedActiveTurnID(for: session.localSessionID) == nil,
              retryingSessionIDs.insert(session.localSessionID).inserted else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This turn can no longer be retried."))
        }
        defer { retryingSessionIDs.remove(session.localSessionID) }

        // Read the runtime status separately: paginated thread/read need not contain turns.
        let response = try await transport.request(CodexProtocol.readThread(
            id: takeRequestID(), threadID: session.providerSessionID, includeTurns: false))
        try requireRegistered(session)
        guard response.result?["thread"]?["id"]?.stringValue == session.providerSessionID,
              let status = taskDecoder.thread(from: response.result?["thread"] ?? .null)?.status,
              status.isSettled else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This turn can no longer be retried."))
        }
        if var state = presentationStateByLocalSessionID[session.localSessionID] {
            state.thread?.status = status
            publish(state, for: session.localSessionID)
        }
        let page = try await loadTurns(for: session, cursor: nil, limit: 1)
        try requireRegistered(session)
        guard let latest = page.turns.last, latest.id == turnID, latest.status == .failed,
              let trigger = CodexTurnRecoveryProjection.retryTrigger(latest.error),
              let state = presentationStateByLocalSessionID[session.localSessionID],
              resolvedActiveTurnID(for: session.localSessionID) == nil else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This turn can no longer be retried."))
        }
        guard CodexTurnRecoveryProjection.canRetry(turnID, in: state) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This turn can no longer be retried."))
        }
        let started = try await transport.request(CodexProtocol.startTurn(
            id: takeRequestID(), threadID: session.providerSessionID, input: [],
            collaborationPreset: collaborationPresetByLocalSessionID[session.localSessionID],
            runLocation: runLocationByLocalSessionID[session.localSessionID] ?? .automatic,
            modelSelection: modelSelectionByLocalSessionID[session.localSessionID],
            turnTrigger: trigger))
        try requireRegistered(session)
        guard let newTurnID = started.result?["turn"]?["id"]?.stringValue, !newTurnID.isEmpty else {
            throw HarnessAdapterError.invalidProviderEvent("turn/start response is missing turn.id")
        }
        // A terminal notification can arrive before the turn/start acknowledgement.
        if presentationStateByLocalSessionID[session.localSessionID]?.thread?.turns
            .first(where: { $0.id == newTurnID })?.status.isTerminal == true { return }
        activeTurnIDByLocalSessionID[session.localSessionID] = newTurnID
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    /// The Codex app's continuation of a cut-off turn: an empty `turn/start` on the resumed thread, once
    /// its runtime is idle. After a quit, its update continuation (`app_update_resume`), which Yardlet
    /// sends after any quit; unlike the app, the latest turn must also be the one the quit cut off
    /// (interrupted, or still in progress in the saved record). After a lost connection, its Resume
    /// (`resume_interrupted_task`), on a latest turn that failed on a connection error
    /// (`CodexTurnErrorPresentation.isConnectionCut`). Any other turn is left as it ended.
    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool {
        try requireRegistered(session)
        guard retryingSessionIDs.insert(session.localSessionID).inserted else { return false }
        defer { retryingSessionIDs.remove(session.localSessionID) }
        let response = try await transport.request(CodexProtocol.readThread(
            id: takeRequestID(), threadID: session.providerSessionID, includeTurns: false))
        try requireRegistered(session)
        guard response.result?["thread"]?["id"]?.stringValue == session.providerSessionID,
              taskDecoder.thread(from: response.result?["thread"] ?? .null)?.status.isSettled == true else { return false }
        let page = try await loadTurns(for: session, cursor: nil, limit: 1)
        try requireRegistered(session)
        guard let latest = page.turns.last else { return false }
        switch cut {
        case .quit:
            guard latest.status == .interrupted || latest.status == .inProgress else { return false }
        case .connection, .sleep:
            guard latest.status == .failed, CodexTurnErrorPresentation.isConnectionCut(latest.error) else { return false }
        }
        let started = try await transport.request(CodexProtocol.startTurn(
            id: takeRequestID(), threadID: session.providerSessionID, input: [],
            collaborationPreset: collaborationPresetByLocalSessionID[session.localSessionID],
            runLocation: runLocationByLocalSessionID[session.localSessionID] ?? .automatic,
            modelSelection: modelSelectionByLocalSessionID[session.localSessionID],
            turnTrigger: cut == .quit ? RestartContinuation.codexTurnTrigger : RestartContinuation.codexResumeTrigger))
        try requireRegistered(session)
        guard let newTurnID = started.result?["turn"]?["id"]?.stringValue, !newTurnID.isEmpty else {
            throw HarnessAdapterError.invalidProviderEvent("turn/start response is missing turn.id")
        }
        // A terminal notification can arrive before the turn/start acknowledgement.
        if presentationStateByLocalSessionID[session.localSessionID]?.thread?.turns
            .first(where: { $0.id == newTurnID })?.status.isTerminal == true { return true }
        activeTurnIDByLocalSessionID[session.localSessionID] = newTurnID
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        return true
    }

    func compactConversation(in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        guard resolvedActiveTurnID(for: session.localSessionID) == nil else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop active work before compacting this chat."))
        }
        let response = try await transport.request(CodexProtocol.readThread(id: takeRequestID(), threadID: session.providerSessionID, includeTurns: false))
        let state = presentationStateByLocalSessionID[session.localSessionID] ?? .empty
        try requireRegistered(session)
        guard taskDecoder.thread(from: response.result?["thread"] ?? .null)?.status.isSettled == true, state.activeTurnID == nil,
              !state.serverRequestsByID.values.contains(where: { $0.resolution == .pending }) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop active work before compacting this chat."))
        }
        _ = try await transport.request(CodexProtocol.compactConversation(id: takeRequestID(), threadID: session.providerSessionID))
        try requireRegistered(session)
        let updated = presentationStateByLocalSessionID[session.localSessionID]
        if updated?.lastAppliedSequence != state.lastAppliedSequence, updated?.thread?.status.isSettled == true,
           updated?.activeTurnID == nil { return }
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func startWorkingTreeReview(in session: HarnessSessionHandle) async throws {
        try await startReview(.uncommittedChanges, in: session)
    }

    func startReview(_ target: CodexReviewTarget, in session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        guard resolvedActiveTurnID(for: session.localSessionID) == nil else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop active work before starting a review."))
        }
        if case let .baseBranch(branch) = target, branch.isEmpty || branch.hasPrefix("-") || branch.contains("\0") {
            throw HarnessAdapterError.invalidProviderEvent("Invalid review branch")
        }
        let response = try await transport.request(
            CodexProtocol.reviewWorkingTree(
                id: takeRequestID(),
                threadID: session.providerSessionID, target: target
            )
        )
        guard let turnID = response.result?["turn"]?["id"]?.stringValue else {
            throw HarnessAdapterError.invalidProviderEvent(
                "review/start response is missing turn.id"
            )
        }
        if presentationStateByLocalSessionID[session.localSessionID]?.thread?.turns.contains(where: { $0.id == turnID && $0.status.isTerminal }) == true { return }
        reviewTurnIDByLocalSessionID[session.localSessionID] = turnID
        activeTurnIDByLocalSessionID[session.localSessionID] = turnID
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func close(_ session: HarnessSessionHandle) async {
        reviewTurnIDByLocalSessionID.removeValue(forKey: session.localSessionID)
        modelSelectionByLocalSessionID.removeValue(forKey: session.localSessionID)
        modelProviderByLocalSessionID.removeValue(forKey: session.localSessionID)
        cancelPrediction(for: session.localSessionID)
        unnamedNewThreadSessionIDs.remove(session.localSessionID)
        threadNamingTasks.removeValue(forKey: session.localSessionID)?.cancel()
        handles.removeValue(forKey: session.localSessionID)
        if localSessionIDByThreadID[session.providerSessionID] == session.localSessionID {
            localSessionIDByThreadID.removeValue(forKey: session.providerSessionID)
        }
        activeTurnIDByLocalSessionID.removeValue(forKey: session.localSessionID)
        collaborationPresetByLocalSessionID.removeValue(forKey: session.localSessionID)
        runLocationByLocalSessionID.removeValue(forKey: session.localSessionID)
        additionalRootsByLocalSessionID.removeValue(forKey: session.localSessionID)
        agentToolServerByLocalSessionID.removeValue(forKey: session.localSessionID)
        yardletInstructionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        historyFreeSessionIDs.remove(session.localSessionID)
        instructionSourcesByLocalSessionID.removeValue(forKey: session.localSessionID)
        serverRequestContexts = serverRequestContexts.filter {
            $0.value.localSessionID != session.localSessionID
        }
        eventChannel.finish(session.localSessionID)
        presentationStateByLocalSessionID.removeValue(forKey: session.localSessionID)
        presentationSequenceByLocalSessionID.removeValue(forKey: session.localSessionID)
        pendingPresentationPublicationByLocalSessionID.removeValue(forKey: session.localSessionID)
        presentationFlushTasks.removeValue(forKey: session.localSessionID)?.cancel()
        presentationContinuations.removeValue(forKey: session.localSessionID)?.finish()

        // As the Codex app lets a conversation go: the App Server unloads a thread no client follows, and ends with
        // the last task on its account below. Not waited for, so quitting Yardlet does not wait on each thread.
        if !handles.isEmpty, initialized, !transportEnded,
           !handles.values.contains(where: { $0.providerSessionID == session.providerSessionID }) {
            let request = CodexThreadTitle.unsubscribe(id: takeRequestID(), threadID: session.providerSessionID)
            Task { [transport] in _ = try? await transport.request(request) }
        }
        if handles.isEmpty {
            for threadID in titleTurns.keys { finishTitleTurn(threadID, result: nil) }
            for threadID in predictionTurns.keys { finishPredictionTurn(threadID, result: nil) }
            notificationTask?.cancel()
            notificationTask = nil
            endInitialization()
            await transport.stop()
            initialized = false
        }
    }

    private func notificationStreamEnded() {
        transportEnded = true
        initialized = false
        endInitialization()
        notificationTask = nil
        for id in handles.keys {
            var state = presentationStateByLocalSessionID[id] ?? .empty
            let interrupted = activeTurnIDByLocalSessionID[id] != nil || state.activeTurnID != nil
                || state.serverRequestsByID.values.contains { $0.resolution == .pending }
            taskReducer.endRuntime(in: &state)
            publish(state, for: id)
            activeTurnIDByLocalSessionID.removeValue(forKey: id)
            if interrupted { emit(.error(message: L10n.format("Connection to %@ ended.", "Codex"), recoverable: true), for: id) }
            eventChannel.finish(id)
            presentationContinuations[id]?.finish()
        }
        serverRequestContexts.removeAll()
        for threadID in titleTurns.keys { finishTitleTurn(threadID, result: nil) }
        predictionBySessionID.removeAll()
        for threadID in predictionTurns.keys { finishPredictionTurn(threadID, result: nil) }
    }

    private func ensureInitialized() async throws {
        guard !transportEnded else {
            throw HarnessAdapterError.invalidProviderEvent(L10n.format("Connection to %@ ended.", "Codex"))
        }
        guard !initialized else { return }
        if let initialization { return try await initialization.value }
        let generation = initializationGeneration
        let task = Task { try await initializeTransport(generation: generation) }
        initialization = task
        // Done or failed, the next request starts from `initialized`; a failure is tried again.
        defer { if initialization == task { initialization = nil } }
        try await task.value
    }

    private func initializeTransport(generation: Int) async throws {
        try await transport.start()
        try requireCurrentInitialization(generation)

        if notificationTask == nil {
            let stream = await transport.notifications()
            try requireCurrentInitialization(generation)
            notificationTask = Task { [weak self] in
                for await frame in stream {
                    guard !Task.isCancelled else { break }
                    await self?.accept(frame)
                }
                guard !Task.isCancelled else { return }
                await self?.notificationStreamEnded()
            }
        }

        let response = try await transport.request(
            CodexProtocol.initialize(
                id: takeRequestID(),
                clientVersion: clientVersion
            )
        )
        try requireCurrentInitialization(generation)
        guard response.result?["platformOs"]?.stringValue != nil else {
            throw HarnessAdapterError.invalidProviderEvent(
                "initialize response is missing platformOs"
            )
        }
        appServerVersion = CodexMessagePrediction.appServerVersion(
            fromUserAgent: response.result?["userAgent"]?.stringValue)
        // A new process may be a newer runtime that implements the request.
        predictionRequestUnavailable = false
        initialized = true
    }

    /// A handshake whose transport ended or stopped while it waited ends there, as a request on
    /// the ended connection does.
    private func requireCurrentInitialization(_ generation: Int) throws {
        guard generation == initializationGeneration, !transportEnded else {
            throw HarnessAdapterError.invalidProviderEvent(L10n.format("Connection to %@ ended.", "Codex"))
        }
    }

    private func endInitialization() {
        initialization?.cancel()
        initialization = nil
        initializationGeneration += 1
    }

    private func accept(_ frame: CodexRawFrame) async {
        let message = frame.message

        // A JSON-RPC message with both an id and method is a server request. Keep
        // it separate from notifications so unknown requests cannot disappear.
        if let rpcID = message.id, let method = message.method {
            let threadID = message.params?["threadId"]?.stringValue
            let localSessionID = threadID.flatMap { localSessionIDByThreadID[$0] }
            if let localSessionID {
                serverRequestContexts[rpcID.externalValue] = ApprovalContext(
                    localSessionID: localSessionID,
                    rpcID: rpcID,
                    method: method,
                    requestedPermissions: message.params?["permissions"]
                )
                var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
                if taskReducer.applyServerRequest(
                    id: rpcID,
                    method: method,
                    params: message.params,
                    sequence: nextPresentationSequence(for: localSessionID),
                    to: &state
                ) {
                    publish(state, for: localSessionID)
                }
            }

            if isApprovalMethod(method) {
                guard let localSessionID else {
                    await failClosed(
                        rpcID: rpcID,
                        method: method,
                        localSessionID: nil,
                        rawData: frame.data,
                        detail: "The request is not attached to a registered local thread"
                    )
                    return
                }
                acceptPermissionRequest(
                    rpcID: rpcID,
                    method: method,
                    params: message.params,
                    localSessionID: localSessionID,
                    rawData: frame.data
                )
                return
            }

            if method == "currentTime/read" {
                let result: JSONValue = .object([
                    "currentTimeAt": .integer(Int64(Date().timeIntervalSince1970))
                ])
                do {
                    try await transport.sendResponse(
                        CodexRPCResponse(id: rpcID, result: result)
                    )
                    if let localSessionID {
                        var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
                        if taskReducer.resolveServerRequest(
                            id: rpcID.externalValue,
                            response: result,
                            in: &state
                        ) {
                            publish(state, for: localSessionID)
                        }
                        serverRequestContexts.removeValue(forKey: rpcID.externalValue)
                    }
                } catch {
                    await failClosed(
                        rpcID: rpcID,
                        method: method,
                        localSessionID: localSessionID,
                        rawData: frame.data,
                        detail: error.localizedDescription
                    )
                }
                return
            }

            if supportsTypedResponse(method) {
                guard localSessionID != nil else {
                    await failClosed(
                        rpcID: rpcID,
                        method: method,
                        localSessionID: nil,
                        rawData: frame.data,
                        detail: "The request is not attached to a registered local thread"
                    )
                    return
                }
                // Keep the request pending for the Codex-specific presentation
                // surface. The typed response API is the only path that can
                // satisfy these schemas without weakening their shape.
                return
            }

            await failClosed(
                rpcID: rpcID,
                method: method,
                localSessionID: localSessionID,
                rawData: frame.data,
                detail: "No native response implementation is registered"
            )
            return
        }

        if let threadID = message.params?["threadId"]?.stringValue, titleTurns[threadID] != nil {
            acceptTitleTurnNotification(message, threadID: threadID)
            return
        }

        // A prediction's fork never reaches the task's timeline or events.
        if let threadID = message.params?["threadId"]?.stringValue, predictionTurns[threadID] != nil {
            acceptPredictionTurnNotification(message, threadID: threadID)
            return
        }

        if let method = message.method, CodexTaskReducer.noticeMethods.contains(method),
           message.params?["threadId"]?.stringValue == nil, let params = message.params {
            acceptRuntimeNotice(method: method, params: params)
            return
        }

        guard let threadID = message.params?["threadId"]?.stringValue,
              let localSessionID = localSessionIDByThreadID[threadID] else {
            return
        }

        if message.method == CodexMessagePrediction.updatedMethod {
            acceptPredictionUpdate(message.params, for: localSessionID)
            return
        }

        if (message.method == "item/started" || message.method == "item/completed"),
           message.params?["item"]?["type"]?.stringValue == "enteredReviewMode",
           let reviewID = message.params?["turnId"]?.stringValue {
            reviewTurnIDByLocalSessionID[localSessionID] = reviewID
        }

        if let method = message.method, let params = message.params {
            var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
            if taskReducer.applyNotification(
                method: method,
                params: params,
                sequence: nextPresentationSequence(for: localSessionID),
                to: &state
            ) {
                syncActiveTurnID(from: state, for: localSessionID)
                publish(
                    state,
                    for: localSessionID,
                    coalesce: CodexTaskReducer.streamingTextMethods.contains(method)
                )
            }
        }

        if message.method == "turn/started",
           let turnID = message.params?["turn"]?["id"]?.stringValue {
            activeTurnIDByLocalSessionID[localSessionID] = turnID
            // What was predicted after the last turn no longer fits (the app drops it here too).
            cancelPrediction(for: localSessionID)
            emit(.sessionStatusChanged(.running), for: localSessionID, rawData: frame.data)
            return
        }

        if message.method == "turn/completed" {
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
            if let reviewID = reviewTurnIDByLocalSessionID[localSessionID],
               message.params?["turn"]?["id"]?.stringValue == reviewID {
                reviewTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
                Task { [weak self] in await self?.refreshCompletedReview(reviewID, threadID: threadID, localSessionID: localSessionID) }
            }
            if let turnID = message.params?["turn"]?["id"]?.stringValue {
                schedulePrediction(after: turnID, for: localSessionID)
            }
            // A turn Codex ended on its own connection error says so before it ends.
            if message.params?["turn"]?["status"]?.stringValue == "failed",
               CodexTurnErrorPresentation.isConnectionCut(message.params?["turn"]?["error"]) {
                emit(.turnCutOff(.connection), for: localSessionID, rawData: frame.data)
            }
        }

        // A frame takes a number even when it projects to no event.
        if eventChannel.emit(for: localSessionID, projecting: { sequence in
            projector.project(message, rawData: frame.data, localSessionID: localSessionID, sequence: sequence)
        }) != nil {
            if message.method == "turn/completed" {
                emit(.sessionStatusChanged(.ready), for: localSessionID, rawData: frame.data)
            }
            return
        }

        if message.method == "item/started" || message.method == "item/completed",
           let activity = activityProjector.project(message.params?["item"]) {
            emit(
                message.method == "item/started"
                    ? .activityStarted(activity)
                    : .activityCompleted(activity),
                for: localSessionID,
                rawData: frame.data
            )
        }
    }

    private func refreshCompletedReview(_ reviewID: String, threadID: String, localSessionID: UUID) async {
        guard handles[localSessionID]?.providerSessionID == threadID else { return }
        let knownIDs = Set(presentationStateByLocalSessionID[localSessionID]?.thread?.turns.map(\.id) ?? [])
        do {
            let response = try await transport.request(CodexProtocol.listTurns(id: takeRequestID(), threadID: threadID,
                limit: 12, sortDirection: "desc"))
            let page = chronologicalPage(fromDescending: taskDecoder.turnPage(from: response.result))
            guard page.turns.last?.id == reviewID, page.turns.last?.status.isTerminal == true,
                  handles[localSessionID]?.providerSessionID == threadID,
                  var state = presentationStateByLocalSessionID[localSessionID],
                  state.thread?.turns.allSatisfy({ knownIDs.contains($0.id) }) == true else { return }
            let cursor = state.thread?.turnsNextCursor
            taskReducer.mergeTurnPage(page, into: &state)
            state.thread?.turnsNextCursor = cursor
            syncActiveTurnID(from: state, for: localSessionID)
            publish(state, for: localSessionID)
        } catch { /* Keep the completed review and cached history if optional hydration fails. */ }
    }

    private func isApprovalMethod(_ method: String) -> Bool {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval", "applyPatchApproval", "execCommandApproval":
            true
        default:
            false
        }
    }

    private func supportsTypedResponse(_ method: String) -> Bool {
        switch method {
        case "item/tool/requestUserInput", "mcpServer/elicitation/request", "item/tool/call":
            true
        default:
            false
        }
    }

    private func failClosed(
        rpcID: CodexRPCID,
        method: String,
        localSessionID: UUID?,
        rawData: Data,
        detail: String
    ) async {
        let message = "Unsupported Codex server request \(method): \(detail)"
        try? await transport.sendErrorResponse(
            CodexRPCErrorResponse(id: rpcID, code: -32001, message: message)
        )

        guard let localSessionID else { return }
        var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
        if taskReducer.rejectServerRequest(
            id: rpcID.externalValue,
            code: -32001,
            message: message,
            in: &state
        ) {
            publish(state, for: localSessionID)
        }
        serverRequestContexts.removeValue(forKey: rpcID.externalValue)
        emit(.error(message: message, recoverable: false), for: localSessionID, rawData: rawData)
    }

    private func acceptPermissionRequest(
        rpcID: CodexRPCID,
        method: String,
        params: JSONValue?,
        localSessionID: UUID,
        rawData: Data
    ) {
        guard params?["threadId"]?.stringValue != nil else { return }
        let requestID = rpcID.externalValue
        serverRequestContexts[requestID] = ApprovalContext(
            localSessionID: localSessionID,
            rpcID: rpcID,
            method: method,
            requestedPermissions: params?["permissions"]
        )
        let title: String
        switch method {
        case "item/commandExecution/requestApproval":
            title = "Run command"
        case "item/fileChange/requestApproval":
            title = "Change files"
        default:
            title = "Grant additional permissions"
        }
        emit(
            .permissionRequested(
                PermissionRequest(
                    id: requestID,
                    title: title,
                    detail: params?["reason"]?.stringValue,
                    command: params?["command"]?.stringValue
                )
            ),
            for: localSessionID,
            rawData: rawData
        )
        emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
    }

    private func register(_ handle: HarnessSessionHandle) {
        handles[handle.localSessionID] = handle
        localSessionIDByThreadID[handle.providerSessionID] = handle.localSessionID
        let notices = runtimeNoticesAwaitingTask
        runtimeNoticesAwaitingTask = []
        for notice in notices {
            applyRuntimeNotice(method: notice.method, params: notice.params, to: handle)
        }
    }

    /// `configWarning`, `deprecationNotice`, and a `warning` without a thread concern the whole
    /// runtime, so every attached task shows them in its current or next turn. One that arrives
    /// before any task is attached, as a configuration warning does after `initialize`, goes to
    /// the first task attached.
    private func acceptRuntimeNotice(method: String, params: JSONValue) {
        guard !handles.isEmpty else {
            runtimeNoticesAwaitingTask.append((method, params))
            return
        }
        for handle in handles.values {
            applyRuntimeNotice(method: method, params: params, to: handle)
        }
    }

    private func applyRuntimeNotice(method: String, params: JSONValue, to handle: HarnessSessionHandle) {
        var routed = params.objectValue ?? [:]
        routed["threadId"] = .string(handle.providerSessionID)
        var state = presentationStateByLocalSessionID[handle.localSessionID] ?? .empty
        guard taskReducer.applyNotification(
            method: method,
            params: .object(routed),
            sequence: nextPresentationSequence(for: handle.localSessionID),
            to: &state
        ) else { return }
        // Before its thread loads, a task only keeps the notice for its first turn.
        if state.thread == nil {
            presentationStateByLocalSessionID[handle.localSessionID] = state
        } else {
            publish(state, for: handle.localSessionID)
        }
    }

    private func applySnapshot(_ value: JSONValue?, for localSessionID: UUID) {
        guard let value else {
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
            publish(.empty, for: localSessionID)
            return
        }
        var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
        if taskReducer.applySnapshot(value, to: &state) {
            syncActiveTurnID(from: state, for: localSessionID)
            publish(state, for: localSessionID)
        } else {
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
            publish(.empty, for: localSessionID)
        }
    }

    private func applyResumeResult(_ result: JSONValue?, for localSessionID: UUID) {
        guard let result,
              let thread = result["thread"] else {
            applySnapshot(nil, for: localSessionID)
            return
        }
        var state = presentationStateByLocalSessionID[localSessionID] ?? .empty
        guard taskReducer.applySnapshot(thread, to: &state) else {
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
            publish(.empty, for: localSessionID)
            return
        }
        let initialPage = result["initialTurnsPage"]
            .map(taskDecoder.turnPage(from:))
            .map(chronologicalPage(fromDescending:))
        if let initialPage {
            let pageTurnIDs = Set(initialPage.turns.map(\.id))
            // `excludeTurns` plus `initialTurnsPage` defines the bounded resume window. Some
            // runtimes still include older snapshot turns, so keep only overlap with the page;
            // older history returns through explicit backwards pagination instead of inflating
            // launch or resurrecting stale activity.
            state.thread?.turns.removeAll { !pageTurnIDs.contains($0.id) }
        }
        let threadIsSettled = state.thread?.status.isSettled == true
        let newestInitialTimestamp = initialPage?.turns
            .compactMap { $0.completedAt ?? $0.startedAt }
            .max()
        state.thread?.turns.removeAll { turn in
            guard turn.status == .inProgress else { return false }
            if threadIsSettled { return true }
            guard let newestInitialTimestamp else { return false }
            // A resume snapshot can retain orphaned in-progress turns without timestamps even
            // when the bounded history page already proves newer completed work exists. Those
            // turns cannot establish a live provider execution, so fail closed and let a fresh
            // turn notification recreate any genuinely active work.
            guard let startedAt = turn.startedAt else { return true }
            return startedAt < newestInitialTimestamp
        }
        taskReducer.mergeResumePage(
            initialPage,
            turnsBackwardsCursor: result["turnsBackwardsCursor"]?.stringValue,
            itemsBackwardsCursor: result["itemsBackwardsCursor"]?.stringValue,
            into: &state
        )
        if let turns = state.thread?.turns,
           let newestTerminalIndex = turns.lastIndex(where: { $0.status.isTerminal }),
           newestTerminalIndex > turns.startIndex {
            let supersededTurnIDs = Set(
                turns[..<newestTerminalIndex]
                    .filter { $0.status == .inProgress }
                    .map(\.id)
            )
            // A genuinely active turn is chronologically last. If newer terminal turns already
            // exist, an earlier `inProgress` record is provider-history residue rather than live
            // work and must not resurrect a spinner after resume.
            state.thread?.turns.removeAll { supersededTurnIDs.contains($0.id) }
        }
        syncActiveTurnID(from: state, for: localSessionID)
        publish(state, for: localSessionID)
    }

    private func chronologicalPage(fromDescending page: CodexTurnPage) -> CodexTurnPage {
        CodexTurnPage(
            turns: Array(page.turns.reversed()),
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    /// Keep imperative composer actions and typed presentation state on the same provider-owned
    /// turn identity. Resume can return an in-progress turn before a new notification arrives;
    /// falling back to the reducer projection prevents the visible Steer affordance from getting
    /// ahead of the adapter's interrupt/steer guard.
    private func resolvedActiveTurnID(for localSessionID: UUID) -> String? {
        if let activeTurnID = activeTurnIDByLocalSessionID[localSessionID] {
            return activeTurnID
        }
        let projected = presentationStateByLocalSessionID[localSessionID]?.activeTurnID
        if let projected {
            activeTurnIDByLocalSessionID[localSessionID] = projected
        }
        return projected
    }

    private func syncActiveTurnID(from state: CodexTaskState, for localSessionID: UUID) {
        guard state.knowsActiveTurn(activeTurnIDByLocalSessionID[localSessionID]) else { return }
        if let activeTurnID = state.activeTurnID {
            activeTurnIDByLocalSessionID[localSessionID] = activeTurnID
        } else {
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
        }
    }

    private func publish(
        _ state: CodexTaskState,
        for localSessionID: UUID,
        coalesce: Bool = false
    ) {
        presentationStateByLocalSessionID[localSessionID] = state
        guard coalesce else {
            pendingPresentationPublicationByLocalSessionID.removeValue(forKey: localSessionID)
            presentationFlushTasks.removeValue(forKey: localSessionID)?.cancel()
            presentationContinuations[localSessionID]?.yield(state)
            return
        }

        pendingPresentationPublicationByLocalSessionID[localSessionID] = state
        guard presentationFlushTasks[localSessionID] == nil else { return }
        presentationFlushTasks[localSessionID] = Task { [weak self] in
            // Text snapshots cross the protocol bridge and re-layout both visible chats.
            // Coalesce token bursts; lifecycle/approval changes still publish immediately.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.flushPresentationPublication(for: localSessionID)
        }
    }

    private func flushPresentationPublication(for localSessionID: UUID) {
        presentationFlushTasks.removeValue(forKey: localSessionID)
        guard let state = pendingPresentationPublicationByLocalSessionID.removeValue(
            forKey: localSessionID
        ) else { return }
        presentationContinuations[localSessionID]?.yield(state)
    }

    private func requireRegistered(_ session: HarnessSessionHandle) throws {
        guard handles[session.localSessionID] == session else {
            throw HarnessAdapterError.invalidProviderEvent("Codex session is not attached")
        }
    }

    private func threadID(from response: CodexRPCIncomingMessage) throws -> String {
        guard let threadID = response.result?["thread"]?["id"]?.stringValue else {
            throw HarnessAdapterError.invalidProviderEvent(
                "thread response is missing thread.id"
            )
        }
        return threadID
    }

    private func takeRequestID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }

    private func nextPresentationSequence(for localSessionID: UUID) -> UInt64 {
        let sequence = presentationSequenceByLocalSessionID[localSessionID] ?? 0
        presentationSequenceByLocalSessionID[localSessionID] = sequence + 1
        return sequence
    }

    private func readVersion() throws -> String {
        try CodexRuntimeCompatibility.readVersionOutput(executableURL: executableURL)
    }
}

/// A Codex task forks its attached thread with `thread/fork`, through a completed turn when asked.
extension CodexAdapter: HarnessSessionBranching {
    nonisolated var sessionBranchMethod: HarnessSessionBranchMethod? { .attachedSession }
}

/// A Codex task's archive, unarchive, delete, and rename also act on its thread.
extension CodexAdapter: HarnessSessionLifecycleProviding {
    func archiveProviderSession(_ session: HarnessSessionHandle) async throws {
        try await archiveThread(session)
    }

    func unarchiveProviderSession(providerSessionID: String) async throws {
        try await unarchiveThread(threadID: providerSessionID)
    }

    func deleteProviderSession(_ session: HarnessSessionHandle) async throws {
        try await deleteThread(session)
    }

    func renameProviderSession(_ session: HarnessSessionHandle, to title: String) async throws {
        try await setThreadName(title, for: session)
    }
}

private extension CodexRPCID {
    var externalValue: String {
        switch self {
        case let .integer(value):
            "i:\(value)"
        case let .string(value):
            "s:\(value)"
        }
    }
}
