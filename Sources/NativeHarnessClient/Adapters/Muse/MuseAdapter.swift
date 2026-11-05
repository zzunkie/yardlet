import Foundation

actor MuseAdapter:
    HarnessAdapter,
    HarnessPermissionActionResponding,
    HarnessStructuredPermissionResponding,
    ProviderCapabilityProviding
{
    private struct ModelSelection: Sendable {
        let providerID: String
        let profileID: String?
        let modelID: String
        let displayLabel: String
        let description: String?
        /// The reasoning tiers the catalog row offers, in its order. Nil when the row does not
        /// say: an older host sends no `variants`, and a current one may answer `unknown`.
        let reasoningEfforts: [String]?

        var optionValue: String {
            [providerID, profileID ?? "", modelID]
                .map { Data($0.utf8).base64EncodedString() }
                .joined(separator: ".")
        }
    }

    private struct PermissionContext: Sendable {
        let localSessionID: UUID
        let approvalID: String
        let sourceIndex: Int64
        let decisionsByChoiceID: [String: PermissionDecision]
        /// The provider's own order, kept so a plain allow or deny resolves the same way on
        /// every run instead of following dictionary order.
        let actions: [PermissionRequestAction]
    }

    private struct UserInputContext: Sendable {
        let localSessionID: UUID
        let prompt: MuseUserInputPrompt
    }

    nonisolated let kind: HarnessKind

    private let executableURL: URL
    private let launchArguments: [String]
    private let transport: any MuseTransport
    private let projector = MuseEventProjector()
    private let subscriptionUsageStore: MuseSubscriptionUsageStore

    private var initialized = false
    /// The `usage/read` in flight, so reads for several finished turns do not pile up.
    private var subscriptionUsageRead: Task<Void, Never>?
    /// Set when this host answered `usage/read` with an error, which a host without the method
    /// or one that gates it does; the next connection asks again.
    private var subscriptionUsageUnavailable = false
    private var nextRequestID: Int64 = 1
    private var commandIDMint = MuseCommandIDMint()
    private var messageTask: Task<Void, Never>?
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var localSessionIDByProviderID: [String: UUID] = [:]
    private var activeTurnIDByLocalSessionID: [UUID: String] = [:]
    private var itemKindsByLocalSessionID: [UUID: [String: String]] = [:]
    /// The summary part each open reasoning item last streamed, so a new part starts a new
    /// paragraph instead of running into the previous one.
    private var reasoningPartsByLocalSessionID: [UUID: [String: Int]] = [:]
    private var activitiesByLocalSessionID: [UUID: [String: HarnessActivity]] = [:]
    private var permissions: [String: PermissionContext] = [:]
    /// Open `userInput/request` prompts by `userInputId`, until answered, cancelled, settled, or
    /// their turn ends.
    private var userInputs: [String: UserInputContext] = [:]
    /// Prompts already reported as unpresentable, by their session, so a re-issued one does not
    /// repeat the notice.
    private var unpresentableUserInputs: [String: UUID] = [:]
    private var modelSelectionsByLocalSessionID: [UUID: [String: ModelSelection]] = [:]
    private var selectedModelByLocalSessionID: [UUID: String] = [:]
    private var approvalModeByLocalSessionID: [UUID: String] = [:]
    private var reasoningEffortByLocalSessionID: [UUID: String] = [:]
    private var eventChannel = HarnessEventChannel()

    init(
        kind: HarnessKind = .museCode,
        executableURL: URL,
        launchArguments: [String] = ["serve"],
        transport: (any MuseTransport)? = nil,
        subscriptionUsageStore: MuseSubscriptionUsageStore = .shared
    ) {
        self.kind = kind
        self.executableURL = executableURL.standardizedFileURL
        self.launchArguments = launchArguments
        self.transport = transport ?? MuseProcessTransport(executableURL: executableURL)
        self.subscriptionUsageStore = subscriptionUsageStore
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
                acceptsImages: true,
                hasSubagents: false
            ),
            fingerprint: fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        try await ensureInitialized(workspaceURL: request.workspaceURL)
        var registeredHandle: HarnessSessionHandle?
        do {
            let id = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.startSession(
                    id: id,
                    commandID: takeCommandID(),
                    workspaceURL: request.workspaceURL
                ),
                id: id
            )
            guard let providerSessionID = result["session"]?["sessionId"]?.stringValue else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "MSP session/start response is missing session.sessionId"
                )
            }
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: request.localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: request.workspaceURL.standardizedFileURL
            )
            register(handle, providerSession: result["session"])
            registeredHandle = handle
            if let prompt = request.initialPrompt, !prompt.isEmpty {
                try await send(prompt, to: handle)
            }
            return handle
        } catch {
            if let registeredHandle {
                await close(registeredHandle)
            } else {
                await stopTransportIfUnused()
            }
            throw error
        }
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        try await ensureInitialized(workspaceURL: workspaceURL)
        do {
            let id = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.resumeSession(
                    id: id,
                    commandID: takeCommandID(),
                    providerSessionID: providerSessionID
                ),
                id: id
            )
            guard result["session"]?["sessionId"]?.stringValue == providerSessionID else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "MSP session/resume response did not preserve session identity"
                )
            }
            let handle = HarnessSessionHandle(
                harness: kind,
                localSessionID: localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: workspaceURL.standardizedFileURL
            )
            register(handle, providerSession: result["session"])
            return handle
        } catch {
            await stopTransportIfUnused()
            throw error
        }
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await startTurn(prompt: prompt, images: [], to: session)
    }

    /// MSP `turn/start` carries an image as its own input part, so a composer attachment
    /// reaches Muse as an image instead of as a path pasted into the prompt.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        try await startTurn(
            prompt: input.promptText,
            images: try input.encodedImages(),
            to: session
        )
    }

    private func startTurn(
        prompt: String,
        images: [HarnessUserInput.EncodedImage],
        to session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard activeTurnIDByLocalSessionID[session.localSessionID] == nil else {
            throw HarnessAdapterError.capabilityUnavailable(
                "A Muse turn is already running"
            )
        }
        let id = takeRequestID()
        let result = try await transport.request(
            MuseProtocol.startTurn(
                id: id,
                commandID: takeCommandID(),
                providerSessionID: session.providerSessionID,
                prompt: prompt,
                images: images,
                reasoningEffort: effectiveReasoningEffort(for: session.localSessionID)
            ),
            id: id
        )
        guard result["status"]?.stringValue == "accepted",
              let turnID = result["turnId"]?.stringValue else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP turn/start response did not accept a turn"
            )
        }
        activeTurnIDByLocalSessionID[session.localSessionID] = turnID
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        try requireRegistered(session)
        let id = takeRequestID()
        let expectedTurnID = activeTurnIDByLocalSessionID[session.localSessionID]
        let result = try await transport.request(
            MuseProtocol.interruptTurn(
                id: id,
                commandID: takeCommandID(),
                providerSessionID: session.providerSessionID,
                turnID: expectedTurnID
            ),
            id: id
        )
        guard result["status"]?.stringValue == "accepted",
              let interruptedTurnID = result["turnId"]?.stringValue,
              expectedTurnID == nil || interruptedTurnID == expectedTurnID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP turn/interrupt response did not accept the active turn"
            )
        }
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        if let context = userInputs[permissionRequestID] {
            try await respondToUserInput(context, decision: decision, in: session)
            return
        }
        guard let context = permissions[permissionRequestID],
              context.localSessionID == session.localSessionID,
              let action = PermissionActionPreference.preferred(
                  from: context.actions,
                  decision: decision
              ) else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown, already-resolved, or unsupported MSP approval decision"
            )
        }
        try await respond(to: permissionRequestID, selectedActionID: action.id, in: session)
    }

    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        if let context = userInputs[permissionRequestID] {
            // A prompt lists no actions of its own; the YHP route answers one with its plain
            // allow or deny fallback ids.
            let decision: PermissionDecision? = switch selectedActionID {
            case "allow": .allow
            case "deny": .deny
            default: nil
            }
            guard let decision else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "MSP user-input prompt has no action \(selectedActionID)"
                )
            }
            try await respondToUserInput(context, decision: decision, in: session)
            return
        }
        guard let context = permissions[permissionRequestID],
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-resolved MSP approval request"
            )
        }
        guard context.decisionsByChoiceID[selectedActionID] != nil else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP approval action is not available"
            )
        }
        let id = takeRequestID()
        let result = try await transport.request(
            MuseProtocol.decideApproval(
                id: id,
                commandID: takeCommandID(),
                providerSessionID: session.providerSessionID,
                approvalID: context.approvalID,
                sourceIndex: context.sourceIndex,
                choiceID: selectedActionID
            ),
            id: id
        )
        guard result["status"]?.stringValue == "accepted",
              result["approvalId"]?.stringValue == context.approvalID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP approval/decide response did not accept the decision"
            )
        }
        if result["terminal"]?.boolValue == true {
            permissions.removeValue(forKey: permissionRequestID)
            emit(.sessionStatusChanged(.running), for: session.localSessionID)
        } else {
            emit(.sessionStatusChanged(.waitingForApproval), for: session.localSessionID)
        }
    }

    /// Answers a `userInput/request` prompt with the card's picks through `userInput/answer`. A
    /// denial carries its reason to `userInput/cancel`, which the model sees as a cancelled call.
    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: HarnessSessionHandle
    ) async throws {
        try requireRegistered(session)
        guard let context = userInputs[permissionRequestID],
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-settled MSP user-input prompt"
            )
        }
        switch answer {
        case let .questions(answers):
            guard let wireAnswers = context.prompt.wireAnswers(for: answers) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("Answer every question before submitting.")
                )
            }
            let id = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.answerUserInput(
                    id: id,
                    commandID: takeCommandID(),
                    providerSessionID: session.providerSessionID,
                    userInputID: context.prompt.userInputID,
                    answers: wireAnswers
                ),
                id: id
            )
            try requireAcceptedUserInput(result, context: context, operation: "userInput/answer")
            settleUserInput(context)
        case let .denial(reason):
            try await cancelUserInput(context, reason: reason, in: session)
        }
    }

    /// A plain decision on a prompt: deny declines it, and allow has nothing to send without the
    /// answers MSP requires.
    private func respondToUserInput(
        _ context: UserInputContext,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        guard context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-settled MSP user-input prompt"
            )
        }
        guard decision == .deny else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Answer every question before submitting.")
            )
        }
        try await cancelUserInput(context, reason: "The user declined to answer.", in: session)
    }

    private func cancelUserInput(
        _ context: UserInputContext,
        reason: String,
        in session: HarnessSessionHandle
    ) async throws {
        let id = takeRequestID()
        let result = try await transport.request(
            MuseProtocol.cancelUserInput(
                id: id,
                commandID: takeCommandID(),
                providerSessionID: session.providerSessionID,
                userInputID: context.prompt.userInputID,
                reason: reason
            ),
            id: id
        )
        try requireAcceptedUserInput(result, context: context, operation: "userInput/cancel")
        settleUserInput(context)
    }

    /// The acknowledgement admits the command; `userInput/settled` carries the outcome. When the
    /// result names the prompt it settled, it must be this one.
    private func requireAcceptedUserInput(
        _ result: JSONValue,
        context: UserInputContext,
        operation: String
    ) throws {
        let settledID = result["userInputId"]?.stringValue
        guard result["status"]?.stringValue == "accepted",
              settledID == nil || settledID == context.prompt.userInputID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP \(operation) response did not accept the prompt"
            )
        }
    }

    private func settleUserInput(_ context: UserInputContext) {
        guard userInputs.removeValue(forKey: context.prompt.userInputID) != nil else { return }
        emit(.sessionStatusChanged(.running), for: context.localSessionID)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        eventChannel.subscribe(to: session.localSessionID)
    }

    func providerCapabilities(
        for session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        var catalogError: String?
        do {
            let id = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.listModels(id: id, providerSessionID: session.providerSessionID),
                id: id
            )
            adoptModelCatalog(result, for: session.localSessionID)
        } catch {
            catalogError = L10n.format("Model catalog unavailable: %@", error.localizedDescription)
        }
        return capabilityState(for: session.localSessionID, catalogError: catalogError)
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        switch id {
        case "model":
            if modelSelectionsByLocalSessionID[session.localSessionID]?[value] == nil {
                _ = try await providerCapabilities(for: session)
            }
            guard let selection = modelSelectionsByLocalSessionID[session.localSessionID]?[value]
            else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That model is not available in the current Muse catalog")
                )
            }
            let requestID = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.setModel(
                    id: requestID,
                    commandID: takeCommandID(),
                    providerSessionID: session.providerSessionID,
                    providerID: selection.providerID,
                    profileID: selection.profileID,
                    modelID: selection.modelID,
                    displayLabel: selection.displayLabel
                ),
                id: requestID
            )
            try requireAccepted(result, operation: "session/setModel")
            selectedModelByLocalSessionID[session.localSessionID] = value

        case "approvalMode":
            guard Self.approvalModes.contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That Muse approval mode is not available")
                )
            }
            let requestID = takeRequestID()
            let result = try await transport.request(
                MuseProtocol.setApprovalMode(
                    id: requestID,
                    commandID: takeCommandID(),
                    providerSessionID: session.providerSessionID,
                    mode: value
                ),
                id: requestID
            )
            try requireAccepted(result, operation: "session/setApprovalMode")
            approvalModeByLocalSessionID[session.localSessionID] =
                result["effectiveMode"]?["mode"]?.stringValue ?? value

        case "reasoningEffort":
            // Any tier of the vocabulary is kept, so a choice saved under another model is not
            // refused on restore; the turn carries it only while the current model offers it.
            guard value == "default" || Self.reasoningEffortTiers.contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That Muse reasoning effort is not available")
                )
            }
            if value == "default" {
                reasoningEffortByLocalSessionID.removeValue(forKey: session.localSessionID)
            } else {
                reasoningEffortByLocalSessionID[session.localSessionID] = value
            }

        default:
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Muse Code does not expose that setting")
            )
        }
        var state = try await providerCapabilities(for: session)
        state.actionMessage = L10n.string("Muse Code session setting updated")
        return state
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        guard id == ProviderCapabilityActionID.compact else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Muse Code does not expose that action")
            )
        }
        let requestID = takeRequestID()
        let result = try await transport.request(
            MuseProtocol.compactSession(
                id: requestID,
                commandID: takeCommandID(),
                providerSessionID: session.providerSessionID
            ),
            id: requestID
        )
        guard let status = result["status"]?.stringValue,
              status == "accepted" || status == "noop" else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP session/compact did not accept the command"
            )
        }
        var state = try await providerCapabilities(for: session)
        state.actionMessage = status == "noop"
            ? L10n.string("Muse Code had no conversation context to compact")
            : L10n.string("Muse Code started compacting this conversation")
        return state
    }

    func close(_ session: HarnessSessionHandle) async {
        handles.removeValue(forKey: session.localSessionID)
        localSessionIDByProviderID.removeValue(forKey: session.providerSessionID)
        activeTurnIDByLocalSessionID.removeValue(forKey: session.localSessionID)
        itemKindsByLocalSessionID.removeValue(forKey: session.localSessionID)
        reasoningPartsByLocalSessionID.removeValue(forKey: session.localSessionID)
        activitiesByLocalSessionID.removeValue(forKey: session.localSessionID)
        permissions = permissions.filter { $0.value.localSessionID != session.localSessionID }
        // An open prompt stays pending on the host, which re-issues it when the session resumes;
        // closing the task is not an answer, so nothing is sent for it.
        forgetUserInputs(of: session.localSessionID)
        modelSelectionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        selectedModelByLocalSessionID.removeValue(forKey: session.localSessionID)
        approvalModeByLocalSessionID.removeValue(forKey: session.localSessionID)
        reasoningEffortByLocalSessionID.removeValue(forKey: session.localSessionID)
        eventChannel.close(session.localSessionID)
        await stopTransportIfUnused()
    }

    private func ensureInitialized(workspaceURL: URL) async throws {
        guard !initialized else { return }
        do {
            try await transport.start(
                MuseLaunchConfiguration(
                    arguments: launchArguments,
                    workspaceURL: workspaceURL
                )
            )
            if messageTask == nil {
                let stream = await transport.messages()
                messageTask = Task { [weak self] in
                    for await frame in stream {
                        guard !Task.isCancelled else { break }
                        await self?.accept(frame)
                    }
                }
            }
            let id = takeRequestID()
            let result = try await transport.request(MuseProtocol.initialize(id: id), id: id)
            guard result["schema"]?["version"]?.integerValue == 1 else {
                throw HarnessAdapterError.unsupportedRuntime(
                    version: "MSP \(result["schema"]?["version"]?.integerValue ?? -1)"
                )
            }
            try await transport.send(MuseProtocol.initialized)
            initialized = true
            subscriptionUsageUnavailable = false
            refreshSubscriptionUsage()
        } catch {
            messageTask?.cancel()
            messageTask = nil
            await transport.stop()
            initialized = false
            throw error
        }
    }

    private func register(_ handle: HarnessSessionHandle, providerSession: JSONValue?) {
        handles[handle.localSessionID] = handle
        localSessionIDByProviderID[handle.providerSessionID] = handle.localSessionID
        if let modelID = providerSession?["modelId"]?.stringValue {
            selectedModelByLocalSessionID[handle.localSessionID] = modelID
        }
        if let approvalMode = providerSession?["approvalMode"]?["mode"]?.stringValue {
            approvalModeByLocalSessionID[handle.localSessionID] = approvalMode
        }
        if let activeTurnID = providerSession?["activeTurnId"]?.stringValue {
            activeTurnIDByLocalSessionID[handle.localSessionID] = activeTurnID
        }
        emit(.sessionStarted(handle), for: handle.localSessionID)
        let status: SessionStatus = providerSession?["status"]?.stringValue == "running"
            ? .running
            : .ready
        emit(.sessionStatusChanged(status), for: handle.localSessionID)
    }

    private func accept(_ frame: MuseRawFrame) async {
        let value = frame.value
        guard let method = value["method"]?.stringValue else { return }
        if let rpcID = value["id"] {
            switch method {
            case "approval/request":
                await acceptApprovalRequest(
                    params: value["params"] ?? .object([:]),
                    rpcID: rpcID,
                    rawData: frame.data
                )
            case "userInput/request":
                await acceptUserInputRequest(
                    params: value["params"] ?? .object([:]),
                    rpcID: rpcID,
                    rawData: frame.data
                )
            default:
                try? await transport.send(MuseProtocol.methodNotFound(id: rpcID))
            }
            return
        }
        if method == "usage/changed" {
            // Host-wide, with the same shape as `usage/read`'s `usage`; it names no session.
            if let usage = MuseSubscriptionUsage(value["params"]) {
                await subscriptionUsageStore.record(usage, for: kind)
            }
            return
        }
        guard let params = value["params"],
              let providerSessionID = params["sessionId"]?.stringValue,
              let localSessionID = localSessionIDByProviderID[providerSessionID] else {
            return
        }

        switch method {
        case "turn/started":
            if let turnID = params["turnId"]?.stringValue {
                activeTurnIDByLocalSessionID[localSessionID] = turnID
            }
            emit(.sessionStatusChanged(.running), for: localSessionID, rawData: frame.data)

        case "item/started", "item/updated":
            guard let item = params["item"],
                  let itemID = item["itemId"]?.stringValue else { return }
            if let kind = item["kind"]?.stringValue {
                itemKindsByLocalSessionID[localSessionID, default: [:]][itemID] = kind
            }
            let fallback = activitiesByLocalSessionID[localSessionID]?[itemID]
            if let activity = projector.activity(from: item, fallback: fallback) {
                activitiesByLocalSessionID[localSessionID, default: [:]][itemID] = activity
                emit(
                    method == "item/started"
                        ? .activityStarted(activity)
                        : .activityUpdated(activity),
                    for: localSessionID,
                    rawData: frame.data
                )
            }

        case "item/delta":
            guard let itemID = params["itemId"]?.stringValue else { return }
            let itemKind = itemKindsByLocalSessionID[localSessionID]?[itemID]
            if let delta = projector.reasoningDelta(from: params, itemKind: itemKind),
               !delta.text.isEmpty {
                emit(
                    .reasoningDelta(
                        reasoningText(delta, itemID: itemID, in: localSessionID)
                    ),
                    for: localSessionID,
                    rawData: frame.data
                )
            } else if let delta = projector.assistantDelta(from: params, itemKind: itemKind),
               !delta.isEmpty {
                emit(.assistantDelta(delta), for: localSessionID, rawData: frame.data)
            } else if let fallback = activitiesByLocalSessionID[localSessionID]?[itemID],
                      let activity = projector.updatedActivity(from: params, fallback: fallback) {
                activitiesByLocalSessionID[localSessionID, default: [:]][itemID] = activity
                emit(.activityUpdated(activity), for: localSessionID, rawData: frame.data)
            }

        case "item/completed":
            guard let item = params["item"],
                  let itemID = item["itemId"]?.stringValue else { return }
            if let text = projector.reasoningCompletion(from: item) {
                emit(.reasoningCompleted(text), for: localSessionID, rawData: frame.data)
            } else if let text = projector.assistantCompletion(from: item) {
                emit(.assistantMessageCompleted(text), for: localSessionID, rawData: frame.data)
            } else if let activity = projector.activity(
                from: item,
                fallback: activitiesByLocalSessionID[localSessionID]?[itemID]
            ) {
                activitiesByLocalSessionID[localSessionID, default: [:]][itemID] = activity
                emit(.activityCompleted(activity), for: localSessionID, rawData: frame.data)
            }
            itemKindsByLocalSessionID[localSessionID]?.removeValue(forKey: itemID)
            reasoningPartsByLocalSessionID[localSessionID]?.removeValue(forKey: itemID)

        case "session/tokenUsage":
            if let usage = projector.usage(fromTokenUsage: params) {
                emit(.usageUpdated(usage), for: localSessionID, rawData: frame.data)
            }

        case "session/contextUsage":
            if let usage = projector.usage(fromContextUsage: params) {
                emit(.usageUpdated(usage), for: localSessionID, rawData: frame.data)
            }

        case "approval/resolved":
            if let approvalID = params["approvalId"]?.stringValue {
                permissions.removeValue(forKey: approvalID)
            }
            emit(.sessionStatusChanged(.running), for: localSessionID, rawData: frame.data)

        case "userInput/settled":
            // Settled here, elsewhere, by timeout, or by an interrupt: the prompt is no longer
            // answerable, whatever its outcome.
            if let userInputID = params["userInputId"]?.stringValue,
               let context = userInputs[userInputID],
               context.localSessionID == localSessionID {
                settleUserInput(context)
            }

        case "turn/completed":
            activeTurnIDByLocalSessionID.removeValue(forKey: localSessionID)
            // A prompt belongs to its turn's tool call, so it is not answerable once the turn ends.
            forgetUserInputs(of: localSessionID)
            refreshSubscriptionUsage()
            itemKindsByLocalSessionID[localSessionID] = [:]
            reasoningPartsByLocalSessionID[localSessionID] = [:]
            activitiesByLocalSessionID[localSessionID] = [:]
            let terminal = params["terminal"]?.stringValue
            if terminal == "failed" {
                emit(
                    .error(
                        message: params["error"]?["message"]?.stringValue
                            ?? params["reason"]?.stringValue
                            ?? "Muse turn failed",
                        recoverable: params["error"]?["retryable"]?.boolValue ?? true
                    ),
                    for: localSessionID,
                    rawData: frame.data
                )
            } else if terminal != "completed" && terminal != "cancelled" {
                emit(
                    .error(
                        message: params["reason"]?.stringValue
                            ?? "Muse turn ended with terminal state \(terminal ?? "unknown")",
                        recoverable: true
                    ),
                    for: localSessionID,
                    rawData: frame.data
                )
            }
            emit(.turnCompleted, for: localSessionID, rawData: frame.data)
            emit(
                .sessionStatusChanged(terminal == "failed" ? .failed : .ready),
                for: localSessionID,
                rawData: frame.data
            )

        default:
            break
        }
    }

    /// Joins summary parts the way the completed item does, so the finished thought block reads
    /// the same as the one that streamed.
    private func reasoningText(
        _ delta: MuseReasoningDelta,
        itemID: String,
        in localSessionID: UUID
    ) -> String {
        guard let part = delta.summaryPart else { return delta.text }
        let previous = reasoningPartsByLocalSessionID[localSessionID]?[itemID]
        reasoningPartsByLocalSessionID[localSessionID, default: [:]][itemID] = part
        guard let previous, previous != part else { return delta.text }
        return MuseReasoningDelta.partSeparator + delta.text
    }

    private func acceptApprovalRequest(
        params: JSONValue,
        rpcID: JSONValue,
        rawData: Data
    ) async {
        do {
            // The server request is only a delivery acknowledgement. The user's decision travels
            // separately through the idempotent `approval/decide` command.
            try await transport.send(MuseProtocol.acknowledgeServerRequest(id: rpcID))
        } catch {
            return
        }
        guard let providerSessionID = params["sessionId"]?.stringValue,
              let localSessionID = localSessionIDByProviderID[providerSessionID],
              let approvalID = params["approvalId"]?.stringValue,
              let sourceIndex = params["currentRequirementId"]?["sourceIndex"]?.integerValue,
              let request = projector.permissionRequest(from: params) else { return }
        let decisions = Dictionary(
            uniqueKeysWithValues: request.actions.map { ($0.id, $0.decision) }
        )
        permissions[approvalID] = PermissionContext(
            localSessionID: localSessionID,
            approvalID: approvalID,
            sourceIndex: sourceIndex,
            decisionsByChoiceID: decisions,
            actions: request.actions
        )
        emit(.permissionRequested(request), for: localSessionID, rawData: rawData)
        emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
    }

    /// `userInput/request` asks the user a question on behalf of a tool call, and the turn waits
    /// for the answer. The response is only a presentation receipt; the answer travels as
    /// `userInput/answer`. A prompt the card cannot present gets an error receipt instead, which
    /// leaves it pending on the host, and the session says why the turn is waiting.
    private func acceptUserInputRequest(
        params: JSONValue,
        rpcID: JSONValue,
        rawData: Data
    ) async {
        let localSessionID = params["sessionId"]?.stringValue
            .flatMap { localSessionIDByProviderID[$0] }
        guard let localSessionID, let prompt = projector.userInputPrompt(from: params) else {
            try? await transport.send(MuseProtocol.cannotPresent(id: rpcID))
            if let localSessionID,
               let userInputID = params["userInputId"]?.stringValue,
               unpresentableUserInputs.updateValue(localSessionID, forKey: userInputID) == nil {
                emit(
                    .error(
                        message: L10n.string(
                            "Muse Code asked a question Yardlet cannot show. Stop the turn to continue."
                        ),
                        recoverable: true
                    ),
                    for: localSessionID,
                    rawData: rawData
                )
            }
            return
        }
        do {
            try await transport.send(MuseProtocol.acknowledgeServerRequest(id: rpcID))
        } catch {
            return
        }
        // The host re-issues an open prompt on resume and on a new subscription; one card is
        // enough for it.
        guard userInputs[prompt.userInputID] == nil else { return }
        userInputs[prompt.userInputID] = UserInputContext(
            localSessionID: localSessionID,
            prompt: prompt
        )
        emit(.permissionRequested(prompt.permissionRequest), for: localSessionID, rawData: rawData)
        emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
    }

    private func forgetUserInputs(of localSessionID: UUID) {
        userInputs = userInputs.filter { $0.value.localSessionID != localSessionID }
        unpresentableUserInputs = unpresentableUserInputs.filter { $0.value != localSessionID }
    }

    private func requireRegistered(_ session: HarnessSessionHandle) throws {
        guard handles[session.localSessionID] == session else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Muse session is not attached"
            )
        }
    }

    private static let approvalModes = [
        "promptUnmatched", "onRequest", "denyUnmatched"
    ]

    /// Offered when the catalog does not say which tiers the current model takes.
    private static let reasoningEfforts = [
        "default", "none", "minimal", "low", "medium", "high", "xhigh", "ultra"
    ]

    /// MSP's `ReasoningEffort`, the closed vocabulary `turn/start` accepts.
    private static let reasoningEffortTiers = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]

    private func adoptModelCatalog(_ result: JSONValue, for localSessionID: UUID) {
        var selections: [String: ModelSelection] = [:]
        var activeOptionValue: String?
        for row in result["models"]?.arrayValue ?? [] {
            guard let modelID = row["modelId"]?.stringValue,
                  let providerID = row["providerId"]?.stringValue else { continue }
            let selection = ModelSelection(
                providerID: providerID,
                profileID: row["profileId"]?.stringValue,
                modelID: modelID,
                displayLabel: row["displayLabel"]?.stringValue ?? modelID,
                description: row["description"]?.stringValue,
                reasoningEfforts: row["variants"]?.arrayValue?
                    .compactMap(\.stringValue)
                    .filter(Self.reasoningEffortTiers.contains)
            )
            selections[selection.optionValue] = selection
            if row["isActive"]?.boolValue == true {
                activeOptionValue = selection.optionValue
            }
        }
        modelSelectionsByLocalSessionID[localSessionID] = selections
        if let activeOptionValue {
            selectedModelByLocalSessionID[localSessionID] = activeOptionValue
        }
    }

    /// The catalog in the model selector's order.
    private static func ordered(_ selections: [String: ModelSelection]) -> [ModelSelection] {
        selections.values.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
    }

    /// The model the selector shows: the session's own when the catalog lists it, otherwise the
    /// catalog's first row.
    private func currentModel(for localSessionID: UUID) -> ModelSelection? {
        let selections = modelSelectionsByLocalSessionID[localSessionID] ?? [:]
        if let selected = selectedModelByLocalSessionID[localSessionID],
           let selection = selections[selected] {
            return selection
        }
        return Self.ordered(selections).first
    }

    /// The current model's own tiers in the catalog's order, or the fixed list when the catalog
    /// does not say.
    private func offeredReasoningEfforts(for localSessionID: UUID) -> [String] {
        guard let tiers = currentModel(for: localSessionID)?.reasoningEfforts else {
            return Self.reasoningEfforts
        }
        return ["default"] + tiers
    }

    /// The tier the next turn carries: the chosen one, while the current model offers it.
    private func effectiveReasoningEffort(for localSessionID: UUID) -> String? {
        guard let effort = reasoningEffortByLocalSessionID[localSessionID],
              offeredReasoningEfforts(for: localSessionID).contains(effort) else { return nil }
        return effort
    }

    private func capabilityState(
        for localSessionID: UUID,
        catalogError: String?
    ) -> ProviderCapabilityState {
        let modelSelections = modelSelectionsByLocalSessionID[localSessionID] ?? [:]
        var selectors: [ProviderCapabilitySelector] = []
        if let current = currentModel(for: localSessionID) {
            let labelCounts = Dictionary(
                grouping: modelSelections.values,
                by: \.displayLabel
            ).mapValues(\.count)
            let choices = Self.ordered(modelSelections).map {
                ProviderCapabilityChoice(
                    value: $0.optionValue,
                    name: labelCounts[$0.displayLabel, default: 0] > 1
                        ? "\($0.displayLabel) · \($0.providerID)"
                        : $0.displayLabel,
                    description: $0.description
                )
            }
            selectors.append(ProviderCapabilitySelector(
                id: "model",
                name: L10n.string("Model"),
                description: L10n.string("Choose a model from Muse Code's live catalog."),
                category: "model",
                currentValue: current.optionValue,
                choices: choices
            ))
        }
        selectors.append(ProviderCapabilitySelector(
            id: "approvalMode",
            name: L10n.string("Approval policy"),
            description: L10n.string("Choose Muse Code's preconfigured approval policy."),
            category: "mode",
            currentValue: approvalModeByLocalSessionID[localSessionID] ?? "onRequest",
            choices: [
                ProviderCapabilityChoice(
                    value: "onRequest", name: L10n.string("On request"), description: nil
                ),
                ProviderCapabilityChoice(
                    value: "promptUnmatched", name: L10n.string("Prompt unmatched"), description: nil
                ),
                ProviderCapabilityChoice(
                    value: "denyUnmatched", name: L10n.string("Deny unmatched"), description: nil
                )
            ]
        ))
        selectors.append(ProviderCapabilitySelector(
            id: "reasoningEffort",
            name: L10n.string("Reasoning effort"),
            description: L10n.string("Applied to each subsequent Muse turn."),
            category: "thought_level",
            currentValue: effectiveReasoningEffort(for: localSessionID) ?? "default",
            choices: offeredReasoningEfforts(for: localSessionID).map {
                ProviderCapabilityChoice(
                    value: $0,
                    name: $0 == "default" ? L10n.string("Default") : $0.capitalized,
                    description: nil
                )
            }
        ))
        return ProviderCapabilityState(
            selectors: selectors,
            actions: [ProviderCapabilityAction(
                id: ProviderCapabilityActionID.compact,
                title: L10n.string("Compact conversation"),
                description: L10n.string("Ask Muse Code to compact this session's context."),
                systemImage: "arrow.down.right.and.arrow.up.left"
            )],
            notes: [
                L10n.string("These controls come from the installed MSP v1 runtime."),
                L10n.string("Yardlet does not offer Muse Code's allow-all approval mode.")
            ],
            errors: catalogError.map { [$0] } ?? []
        )
    }

    private func requireAccepted(_ result: JSONValue, operation: String) throws {
        guard result["status"]?.stringValue == "accepted" else {
            throw HarnessAdapterError.invalidProviderEvent(
                "MSP \(operation) did not accept the command"
            )
        }
    }

    private func stopTransportIfUnused() async {
        guard handles.isEmpty else { return }
        messageTask?.cancel()
        messageTask = nil
        subscriptionUsageRead?.cancel()
        subscriptionUsageRead = nil
        await transport.stop()
        initialized = false
    }

    /// Reads the host's last-observed subscription usage for the Account Center: once the
    /// connection is up, since the host may already hold an observation, and after each turn,
    /// whose model calls are where the host observes it. `usage/read` makes no model call.
    private func refreshSubscriptionUsage() {
        guard initialized, !subscriptionUsageUnavailable, subscriptionUsageRead == nil else { return }
        subscriptionUsageRead = Task { [weak self] in
            await self?.readSubscriptionUsage()
        }
    }

    private func readSubscriptionUsage() async {
        // A read cancelled with its connection leaves the next connection's read in place.
        defer { if !Task.isCancelled { subscriptionUsageRead = nil } }
        let id = takeRequestID()
        do {
            let result = try await transport.request(MuseProtocol.readUsage(id: id), id: id)
            // `usage` is omitted, never null, while the host has observed nothing.
            if let usage = MuseSubscriptionUsage(result["usage"]) {
                await subscriptionUsageStore.record(usage, for: kind)
            }
        } catch {
            guard !Task.isCancelled else { return }
            subscriptionUsageUnavailable = true
        }
    }

    private func takeRequestID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func takeCommandID() -> String {
        commandIDMint.next()
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }

    private func readVersion() throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        try NativeProcessTree.run(process)
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw HarnessAdapterError.processExited(
                code: process.terminationStatus,
                message: output
            )
        }
        return output
    }
}
