import Foundation

enum YHPCanceledTurnProjection: Sendable {
    case omit
    case complete
}

/// Product-facing adapter for a built-in harness that has moved onto the Yardlet Harness
/// Protocol boundary. The wrapped legacy adapter still owns the provider process while this
/// adapter proves that AppModel can depend on YHP requests and canonical events exclusively.
actor YHPCompatibilityAdapter: VersionedHarnessAdapter {
    nonisolated let kind: HarnessKind
    nonisolated let protocolManifest: HarnessAdapterManifest

    private let bridge: LegacyHarnessProtocolBridge
    private let canceledTurnProjection: YHPCanceledTurnProjection
    private let payloadCodec = HarnessProtocolPayloadCodec()

    private var requestSequence: UInt64 = 0
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var relayTasks: [UUID: Task<Void, Never>] = [:]
    private var endedSessionIDs: Set<UUID> = []
    private var histories: [UUID: [HarnessEventEnvelope]] = [:]
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    private var protocolHistories: [UUID: HarnessProtocolEventHistory] = [:]
    private var protocolContinuations: [
        UUID: AsyncStream<HarnessProtocolEventEnvelope>.Continuation
    ] = [:]
    private var nextEventSequence: [UUID: UInt64] = [:]
    private var activityStatuses: [UUID: [String: HarnessProtocolToolCallStatus]] = [:]
    private var permissionActions: [UUID: [String: [HarnessProtocolPermissionAction]]] = [:]

    init(
        adapter: any HarnessAdapter,
        manifest: HarnessAdapterManifest,
        interruptEventPolicy: LegacyHarnessInterruptEventPolicy = .awaitLegacyTerminal,
        canceledTurnProjection: YHPCanceledTurnProjection = .omit
    ) {
        precondition(adapter.kind == manifest.harness)
        self.kind = adapter.kind
        self.protocolManifest = manifest
        self.canceledTurnProjection = canceledTurnProjection
        self.bridge = LegacyHarnessProtocolBridge(
            adapter: adapter,
            manifest: manifest,
            interruptEventPolicy: interruptEventPolicy
        )
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        let runtime: HarnessProtocolRuntimeInfo = try await perform(
            .runtimeProbe,
            params: HarnessProtocolEmptyParams()
        )
        return HarnessRuntimeDescriptor(
            harness: runtime.harness,
            executableURL: URL(filePath: runtime.executablePath).standardizedFileURL,
            version: runtime.version,
            capabilities: HarnessCapabilities(
                canResume: runtime.capabilities.contains(.sessionResume),
                canInterrupt: runtime.capabilities.contains(.turnInterrupt),
                hasStructuredPermissions: runtime.capabilities.contains(.structuredPermissions),
                hasStructuredActivities: runtime.capabilities.contains(.structuredActivities),
                hasPlans: runtime.capabilities.contains(.plans),
                acceptsImages: runtime.capabilities.contains(.images),
                hasSubagents: runtime.capabilities.contains(.subagents)
            ),
            fingerprint: runtime.fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let descriptor: HarnessProtocolSessionDescriptor = try await perform(
            .sessionCreate,
            params: HarnessProtocolCreateSessionParams(
                localSessionID: request.localSessionID,
                config: sessionConfig(workspaceURL: request.workspaceURL),
                initialPrompt: request.initialPrompt.map { [.text($0)] } ?? []
            )
        )
        let handle = handle(from: descriptor)
        handles[handle.localSessionID] = handle
        startRelay(for: handle.localSessionID)
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        let descriptor: HarnessProtocolSessionDescriptor = try await perform(
            .sessionResume,
            params: HarnessProtocolResumeSessionParams(
                localSessionID: localSessionID,
                providerSessionID: providerSessionID,
                config: sessionConfig(workspaceURL: workspaceURL)
            )
        )
        let handle = handle(from: descriptor)
        handles[localSessionID] = handle
        startRelay(for: localSessionID)
        return handle
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await submit([.text(prompt)], to: session)
    }

    /// Attachments cross YHP as content blocks. Mentions have no block of their own, so they
    /// travel inside the prompt exactly as `HarnessUserInput` projects them, and an adapter
    /// family whose manifest withholds `.images` refuses before anything is transmitted.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        guard input.images.isEmpty || protocolManifest.supports(.images) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("%@ cannot send image attachments", kind.displayName)
            )
        }
        try await submit(
            [.text(input.promptText)] + (try input.images.map { image in
                if image.url.scheme == "data" {
                    guard let encoded = InlineImageInput.image(from: image.url), encoded.mimeType == image.mimeType else {
                        throw HarnessAdapterError.capabilityUnavailable(L10n.string("The saved image attachment is unavailable."))
                    }
                    return .inlineData(mimeType: encoded.mimeType, base64Data: encoded.base64Data)
                }
                return .file(path: image.url.path(percentEncoded: false), mimeType: image.mimeType)
            }),
            to: session
        )
    }

    private func submit(
        _ content: [HarnessProtocolContentBlock],
        to session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await perform(
            .sessionSend,
            params: HarnessProtocolTurnSubmitParams(
                localSessionID: session.localSessionID,
                clientMessageID: "yardlet-turn-\(nextRequestID())",
                content: content
            )
        )
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        let _: HarnessProtocolAcknowledgement = try await perform(
            .sessionInterrupt,
            params: HarnessProtocolSessionReference(localSessionID: session.localSessionID)
        )
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        guard protocolManifest.supports(.structuredPermissions) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("This headless runtime does not expose structured permission responses")
            )
        }
        let behavior: HarnessProtocolPermissionBehavior = decision == .allow ? .allow : .deny
        let candidates = permissionActions[session.localSessionID]?[permissionRequestID]?
            .filter { $0.behavior == behavior } ?? []
        guard let action = PermissionActionPreference.preferred(
            from: candidates,
            id: \.id,
            intent: \.intent
        ) else {
            throw HarnessAdapterError.invalidProviderEvent(
                "YHP permission request \(permissionRequestID) has no \(behavior.rawValue) action"
            )
        }
        try await respond(
            to: permissionRequestID,
            selectedActionID: action.id,
            behavior: behavior,
            in: session
        )
    }

    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws {
        guard let action = permissionActions[session.localSessionID]?[permissionRequestID]?.first(where: {
            $0.id == selectedActionID
        }) else {
            throw HarnessAdapterError.invalidProviderEvent(
                "YHP permission request \(permissionRequestID) has no action \(selectedActionID)"
            )
        }
        try await respond(
            to: permissionRequestID,
            selectedActionID: selectedActionID,
            behavior: action.behavior,
            in: session
        )
    }

    /// Carries an answer to a provider question or plan across YHP. The behavior still picks one
    /// of the request's own actions, so a family that offered several keeps its narrowest choice.
    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: HarnessSessionHandle
    ) async throws {
        guard protocolManifest.supports(.structuredPermissions) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("This headless runtime does not expose structured permission responses")
            )
        }
        let behavior: HarnessProtocolPermissionBehavior =
            answer.decision == .allow ? .allow : .deny
        let candidates = permissionActions[session.localSessionID]?[permissionRequestID]?
            .filter { $0.behavior == behavior } ?? []
        guard let action = PermissionActionPreference.preferred(
            from: candidates,
            id: \.id,
            intent: \.intent
        ) else {
            throw HarnessAdapterError.invalidProviderEvent(
                "YHP permission request \(permissionRequestID) has no \(behavior.rawValue) action"
            )
        }
        let updatedInput: JSONValue?
        let message: String?
        switch answer {
        case let .questions(answers):
            updatedInput = PermissionStructureCoding.updatedInput(for: answers)
            message = nil
        case let .denial(reason):
            updatedInput = nil
            message = reason
        }
        try await respond(
            to: permissionRequestID,
            selectedActionID: action.id,
            behavior: behavior,
            updatedInput: updatedInput,
            message: message,
            in: session
        )
    }

    func readProviderCapabilities(
        for session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let options: HarnessProtocolSessionOptionCatalog = try await perform(
            .compatibilityOptionsRead,
            params: HarnessProtocolSessionOptionsReadParams(
                localSessionID: session.localSessionID
            )
        )
        let actions: HarnessProtocolSessionActionCatalog = try await perform(
            .compatibilityActionsRead,
            params: HarnessProtocolSessionActionsReadParams(
                localSessionID: session.localSessionID
            )
        )
        return providerState(options: options, actions: actions)
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let options: HarnessProtocolSessionOptionCatalog = try await perform(
            .compatibilityOptionsSet,
            params: HarnessProtocolSessionOptionSetParams(
                localSessionID: session.localSessionID,
                optionID: id,
                value: value
            )
        )
        let actions: HarnessProtocolSessionActionCatalog = try await perform(
            .compatibilityActionsRead,
            params: HarnessProtocolSessionActionsReadParams(
                localSessionID: session.localSessionID
            )
        )
        return providerState(options: options, actions: actions)
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let actions: HarnessProtocolSessionActionCatalog = try await perform(
            .compatibilityActionPerform,
            params: HarnessProtocolSessionActionPerformParams(
                localSessionID: session.localSessionID,
                actionID: id
            )
        )
        let options: HarnessProtocolSessionOptionCatalog = try await perform(
            .compatibilityOptionsRead,
            params: HarnessProtocolSessionOptionsReadParams(
                localSessionID: session.localSessionID
            )
        )
        return providerState(options: options, actions: actions)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = AsyncStream<HarnessEventEnvelope>.makeStream()
        for event in histories[session.localSessionID] ?? [] {
            stream.continuation.yield(event)
        }
        continuations[session.localSessionID]?.finish()
        continuations[session.localSessionID] = stream.continuation
        if endedSessionIDs.contains(session.localSessionID) { stream.continuation.finish() }
        return stream.stream
    }

    func protocolEvents(
        for localSessionID: UUID
    ) -> AsyncStream<HarnessProtocolEventEnvelope> {
        let stream = AsyncStream<HarnessProtocolEventEnvelope>.makeStream()
        for event in protocolHistories[localSessionID]?.events ?? [] {
            stream.continuation.yield(event)
        }
        protocolContinuations[localSessionID]?.finish()
        protocolContinuations[localSessionID] = stream.continuation
        if endedSessionIDs.contains(localSessionID) { stream.continuation.finish() }
        return stream.stream
    }

    func attachReturnedSession(
        _ descriptor: HarnessProtocolSessionDescriptor
    ) -> HarnessSessionHandle {
        let handle = handle(from: descriptor)
        handles[handle.localSessionID] = handle
        startRelay(for: handle.localSessionID)
        return handle
    }

    func close(_ session: HarnessSessionHandle) async {
        do {
            let _: HarnessProtocolAcknowledgement = try await perform(
                .sessionClose,
                params: HarnessProtocolSessionReference(localSessionID: session.localSessionID)
            )
        } catch {
            // The legacy close contract is non-throwing. Cleanup must still be deterministic.
        }
        relayTasks.removeValue(forKey: session.localSessionID)?.cancel()
        handles.removeValue(forKey: session.localSessionID)
        activityStatuses.removeValue(forKey: session.localSessionID)
        permissionActions.removeValue(forKey: session.localSessionID)
        continuations.removeValue(forKey: session.localSessionID)?.finish()
        protocolContinuations.removeValue(forKey: session.localSessionID)?.finish()
        histories.removeValue(forKey: session.localSessionID)
        protocolHistories.removeValue(forKey: session.localSessionID)
        nextEventSequence.removeValue(forKey: session.localSessionID)
    }

    private func startRelay(for localSessionID: UUID) {
        endedSessionIDs.remove(localSessionID)
        relayTasks.removeValue(forKey: localSessionID)?.cancel()
        relayTasks[localSessionID] = Task { [weak self, bridge] in
            for await event in await bridge.events(for: localSessionID) {
                guard !Task.isCancelled else { return }
                await self?.accept(event)
            }
            guard !Task.isCancelled else { return }
            await self?.endEventStream(for: localSessionID)
        }
    }

    private func endEventStream(for localSessionID: UUID) {
        endedSessionIDs.insert(localSessionID)
        continuations[localSessionID]?.finish()
        protocolContinuations[localSessionID]?.finish()
    }

    private func accept(_ event: HarnessProtocolEventEnvelope) {
        protocolHistories[event.localSessionID, default: HarnessProtocolEventHistory()].append(event)
        protocolContinuations[event.localSessionID]?.yield(event)

        if event.payload.kind == .turnCompleted,
           let usage = event.payload.usage {
            appendProjected(
                .usageUpdated(usage),
                source: event
            )
        }
        guard let payload = project(event.payload, localSessionID: event.localSessionID) else {
            return
        }
        appendProjected(payload, source: event)
    }

    private func appendProjected(
        _ payload: HarnessEventPayload,
        source event: HarnessProtocolEventEnvelope
    ) {
        let envelope = HarnessEventEnvelope(
            localSessionID: event.localSessionID,
            timestamp: event.timestamp,
            sequence: nextSequence(for: event.localSessionID),
            payload: payload,
            rawProviderEvent: event.rawProviderEvent
        )
        histories[event.localSessionID, default: []].appendKeepingLast(envelope, limit: 500)
        continuations[event.localSessionID]?.yield(envelope)
    }

    private func project(
        _ payload: HarnessProtocolEventPayload,
        localSessionID: UUID
    ) -> HarnessEventPayload? {
        switch payload.kind {
        case .sessionStarted:
            guard let descriptor = payload.session else { return nil }
            let session = handle(from: descriptor)
            handles[localSessionID] = session
            return .sessionStarted(session)

        case .sessionStatusChanged:
            return payload.status.map(HarnessEventPayload.sessionStatusChanged)

        case .turnStarted, .permissionResolved, .subagentUpdated:
            return nil

        case .reasoningDelta:
            return payload.text.map(HarnessEventPayload.reasoningDelta)

        case .usageUpdated:
            return payload.usage.map(HarnessEventPayload.usageUpdated)

        case .turnCanceled:
            return canceledTurnProjection == .complete ? .turnCompleted : nil

        case .assistantDelta:
            return payload.text.map(HarnessEventPayload.assistantDelta)

        case .messageCompleted:
            guard payload.message?.role == .assistant,
                  let content = payload.message?.content else { return nil }
            return .assistantMessageCompleted(text(from: content))

        case .toolCallUpdated:
            guard let toolCall = payload.toolCall else { return nil }
            let activity = HarnessActivity(
                id: toolCall.id,
                kind: toolCall.kind,
                title: toolCall.title,
                detail: toolCall.extensionValues["yardlet.compat.activityDetail"]?.stringValue
                    ?? toolCall.input?.stringValue ?? toolCall.output?.stringValue,
                outcome: toolCall.status == .failed ? .failed
                    : toolCall.extensionValues["yardlet.compat.activityOutcome"]?.stringValue
                        .flatMap(HarnessActivityOutcome.init(rawValue:)),
                input: toolCall.input?.stringValue,
                output: toolCall.output?.stringValue,
                diff: Self.activityDiff(
                    from: toolCall.extensionValues["yardlet.compat.activityDiff"]
                ),
                isBackground: toolCall.extensionValues["yardlet.compat.activityBackground"]?.boolValue,
                subtask: HarnessSubtaskReference(json: toolCall.extensionValues["yardlet.compat.activitySubtask"]),
                answeredQuestions: PermissionStructureCoding.answeredQuestions(
                    from: toolCall.extensionValues["yardlet.compat.activityAnsweredQuestions"]
                )
            )
            let previous = activityStatuses[localSessionID]?[toolCall.id]
            var statuses = activityStatuses[localSessionID] ?? [:]
            statuses[toolCall.id] = toolCall.status
            activityStatuses[localSessionID] = statuses
            switch toolCall.status {
            case .pending, .running:
                return previous == nil ? .activityStarted(activity) : .activityUpdated(activity)
            case .completed, .failed:
                return .activityCompleted(activity)
            }

        case .permissionRequested:
            guard let permission = payload.permission else { return nil }
            var sessionActions = permissionActions[localSessionID] ?? [:]
            sessionActions[permission.id] = permission.actions
            permissionActions[localSessionID] = sessionActions
            let outwardActions = isCompatibilityFallback(permission.actions)
                ? []
                : permission.actions.map { action in
                    PermissionRequestAction(
                        id: action.id,
                        label: action.label,
                        decision: action.behavior == .allow ? .allow : .deny,
                        kind: action.intent
                    )
                }
            return .permissionRequested(PermissionRequest(
                id: permission.id,
                title: permission.title,
                detail: permission.description,
                command: permission.input?.stringValue,
                actions: outwardActions,
                structured: PermissionStructureCoding.structure(
                    from: permission.extensionValues
                ),
                toolCallID: PermissionStructureCoding.toolCallID(from: permission.extensionValues),
                preview: PermissionStructureCoding.preview(from: permission.extensionValues),
                requiresInAppAnswer: PermissionStructureCoding.requiresInAppAnswer(from: permission.extensionValues)
            ))

        case .planUpdated:
            guard let plan = payload.plan else { return nil }
            let itemText = plan.items.map(\.text).joined(separator: "\n")
            return .planUpdated(plan.explanation ?? itemText)

        case .turnCompleted:
            return .turnCompleted

        case .turnFailed:
            guard let failure = payload.failure else { return nil }
            return .error(message: failure.message, recoverable: failure.recoverable, transient: failure.transient)

        case .extension:
            if payload.extensionEvent?.namespace == "yardlet.compat",
               payload.extensionEvent?.name == "permission.expired",
               let requestID = payload.extensionEvent?.payload["requestID"]?.stringValue {
                return .permissionExpired(requestID)
            }
            if payload.extensionEvent?.namespace == "yardlet.compat",
               payload.extensionEvent?.name == "message.reasoning_completed",
               let text = payload.extensionEvent?.payload["text"]?.stringValue {
                return payload.extensionEvent?.payload["progressUpdate"]?.boolValue == true
                    ? .progressUpdateCompleted(text) : .reasoningCompleted(text)
            }
            if payload.extensionEvent?.namespace == "yardlet.compat",
               payload.extensionEvent?.name == "session.options_changed" {
                return .providerCapabilitiesChanged
            }
            if payload.extensionEvent?.namespace == "yardlet.compat",
               let event = payload.extensionEvent,
               let status = LegacyProviderStatusExtension.payload(name: event.name, value: event.payload) {
                return status
            }
            guard payload.extensionEvent?.namespace == "yardlet.compat",
                  payload.extensionEvent?.name == "session.provider_identity_updated",
                  let providerSessionID = payload.extensionEvent?.payload.objectValue?["providerSessionID"]?.stringValue,
                  let current = handles[localSessionID],
                  providerSessionID != current.providerSessionID else { return nil }
            let updated = HarnessSessionHandle(
                harness: current.harness,
                localSessionID: current.localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: current.workspaceURL
            )
            handles[localSessionID] = updated
            return .sessionStarted(updated)
        }
    }

    func perform<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: HarnessProtocolMethodID,
        params: Params
    ) async throws -> Result {
        let response = try await bridge.handle(
            HarnessProtocolRequest(
                id: nextRequestID(),
                method: method,
                typedParams: params,
                codec: payloadCodec
            )
        )
        if let error = response.error {
            throw HarnessAdapterError.invalidProviderEvent(error.message)
        }
        guard let result = response.result else {
            throw HarnessAdapterError.invalidProviderEvent(
                "YHP response for \(method.rawValue) did not include a result"
            )
        }
        return try payloadCodec.decode(Result.self, from: result)
    }

    private func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        behavior: HarnessProtocolPermissionBehavior,
        updatedInput: JSONValue? = nil,
        message: String? = nil,
        in session: HarnessSessionHandle
    ) async throws {
        let _: HarnessProtocolAcknowledgement = try await perform(
            .permissionRespond,
            params: HarnessProtocolPermissionResponseParams(
                localSessionID: session.localSessionID,
                requestID: permissionRequestID,
                selectedActionID: selectedActionID,
                behavior: behavior,
                updatedInput: updatedInput,
                message: message,
                interrupt: false
            )
        )
        permissionActions[session.localSessionID]?.removeValue(forKey: permissionRequestID)
        if permissionActions[session.localSessionID]?.isEmpty == true {
            permissionActions.removeValue(forKey: session.localSessionID)
        }
    }

    private func nextRequestID() -> String {
        defer { requestSequence += 1 }
        return "yardlet-host-\(requestSequence)"
    }

    private func nextSequence(for localSessionID: UUID) -> UInt64 {
        let sequence = nextEventSequence[localSessionID] ?? 0
        nextEventSequence[localSessionID] = sequence + 1
        return sequence
    }

    private func sessionConfig(workspaceURL: URL) -> HarnessProtocolSessionConfig {
        HarnessProtocolSessionConfig(
            workspacePath: workspaceURL.standardizedFileURL.path(percentEncoded: false),
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )
    }

    private func handle(from descriptor: HarnessProtocolSessionDescriptor) -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: descriptor.localSessionID,
            providerSessionID: descriptor.providerSessionID,
            workspaceURL: URL(filePath: descriptor.workspacePath).standardizedFileURL
        )
    }

    private func text(from content: [HarnessProtocolContentBlock]) -> String {
        content.compactMap { block in
            guard case let .text(value) = block else { return nil }
            return value
        }.joined()
    }

    private func providerState(
        options: HarnessProtocolSessionOptionCatalog,
        actions: HarnessProtocolSessionActionCatalog
    ) -> ProviderCapabilityState {
        ProviderCapabilityState(
            selectors: options.options.map { option in
                ProviderCapabilitySelector(
                    id: option.id,
                    name: option.displayName,
                    description: option.description,
                    category: option.category,
                    currentValue: option.currentValue,
                    choices: option.choices.map { choice in
                        ProviderCapabilityChoice(
                            value: choice.id,
                            name: choice.label,
                            description: choice.description
                        )
                    }
                )
            },
            actions: actions.actions.map { action in
                ProviderCapabilityAction(
                    id: action.id,
                    title: action.title,
                    description: action.description,
                    systemImage: action.iconName ?? "bolt"
                )
            },
            notes: options.notes + actions.notes.filter { !options.notes.contains($0) },
            actionMessage: actions.message ?? options.message,
            composerCommands: options.composerCommands ?? []
        )
    }

    static func activityDiff(from value: JSONValue?) -> HarnessActivityDiff? {
        guard let path = value?["path"]?.stringValue else { return nil }
        return HarnessActivityDiff(
            path: path,
            oldText: value?["oldText"]?.stringValue,
            newText: value?["newText"]?.stringValue,
            unified: value?["unified"]?.stringValue
        )
    }

    private func isCompatibilityFallback(
        _ actions: [HarnessProtocolPermissionAction]
    ) -> Bool {
        guard actions.count == 2,
              let allow = actions.first(where: { $0.id == "allow" }),
              let deny = actions.first(where: { $0.id == "deny" }) else { return false }
        return allow.label == "Allow"
            && allow.behavior == .allow
            && allow.intent == nil
            && deny.label == "Deny"
            && deny.behavior == .deny
            && deny.intent == nil
    }
}

/// Adds the optional product-control protocols only for families whose YHP manifest actually
/// exposes the corresponding provider extension methods. Keeping this wrapper separate prevents
/// structured-headless adapters from appearing to have selectors merely because they use YHP.
actor YHPProviderCompatibilityAdapter:
    VersionedHarnessAdapter,
    ProviderCapabilityProviding,
    HarnessPermissionActionResponding,
    HarnessStructuredPermissionResponding,
    WrappedAdapterLaunchForwarding,
    HarnessImageInputReporting,
    HarnessSubtaskControlling,
    HarnessSessionForkConfiguring,
    HarnessNewSessionConfiguring,
    HarnessConversationQuiescing,
    HarnessFileRewinding,
    HarnessFollowUpQueueing,
    HarnessModelCatalogReporting,
    HarnessSessionBranching,
    HarnessMCPServerStatusReading,
    HarnessInterruptedTurnContinuing
{
    nonisolated let kind: HarnessKind
    nonisolated let protocolManifest: HarnessAdapterManifest
    /// The wrapped adapter's answer: the fork source it needs at launch crosses this wrapper to it.
    nonisolated let sessionBranchMethod: HarnessSessionBranchMethod?

    private let core: YHPCompatibilityAdapter
    /// Launch flags, extra roots, the Yardlet MCP server (`--mcp-config`, ACP `mcpServers`) and
    /// the loaded instruction files belong to the wrapped adapter.
    nonisolated let launchFacets: WrappedAdapterLaunchFacets
    /// The YHP option and action catalogs describe selectors, not what the agent negotiated for
    /// image input, so that answer would stop at this wrapper unless it is read from the
    /// wrapped adapter and laid back onto every capability state this wrapper returns.
    private let imageInputReporting: (any HarnessImageInputReporting)?
    private let subtaskControlling: (any HarnessSubtaskControlling)?
    private let sessionForkConfiguring: (any HarnessSessionForkConfiguring)?
    private let newSessionConfiguring: (any HarnessNewSessionConfiguring)?
    private let conversationQuiescing: (any HarnessConversationQuiescing)?
    private let fileRewinding: (any HarnessFileRewinding)?
    /// A follow-up carries its own message ID and priority, which a YHP send has no place for, so
    /// it goes to the wrapped adapter directly. What became of it returns on the event stream.
    private let followUpQueueing: (any HarnessFollowUpQueueing)?
    /// The YHP option catalog carries the current model's effort levels only; the whole list the
    /// runtime advertised stays with the wrapped adapter.
    private let modelCatalogReporting: (any HarnessModelCatalogReporting)?
    /// The session's MCP servers have no place in YHP's catalogs; they are read from the wrapped
    /// adapter and laid back onto every capability state, like the image answer.
    private let mcpStatusReading: (any HarnessMCPServerStatusReading)?
    /// A restart continuation carries its own provenance (Claude Code's `origin`), which a YHP send
    /// has no place for, so it goes to the wrapped adapter directly, as a follow-up does.
    private let interruptedTurnContinuing: (any HarnessInterruptedTurnContinuing)?

    init(
        adapter: any HarnessAdapter,
        manifest: HarnessAdapterManifest,
        interruptEventPolicy: LegacyHarnessInterruptEventPolicy = .awaitLegacyTerminal,
        canceledTurnProjection: YHPCanceledTurnProjection = .complete
    ) {
        self.kind = adapter.kind
        self.protocolManifest = manifest
        self.sessionBranchMethod = (adapter as? any HarnessSessionBranching)?.sessionBranchMethod
        self.modelCatalogReporting = adapter as? any HarnessModelCatalogReporting
        self.launchFacets = WrappedAdapterLaunchFacets(wrapping: adapter)
        self.imageInputReporting = adapter as? any HarnessImageInputReporting
        self.subtaskControlling = adapter as? any HarnessSubtaskControlling
        self.sessionForkConfiguring = adapter as? any HarnessSessionForkConfiguring
        self.newSessionConfiguring = adapter as? any HarnessNewSessionConfiguring
        self.conversationQuiescing = adapter as? any HarnessConversationQuiescing
        self.fileRewinding = adapter as? any HarnessFileRewinding
        self.followUpQueueing = adapter as? any HarnessFollowUpQueueing
        self.mcpStatusReading = adapter as? any HarnessMCPServerStatusReading
        self.interruptedTurnContinuing = adapter as? any HarnessInterruptedTurnContinuing
        self.core = YHPCompatibilityAdapter(
            adapter: adapter,
            manifest: manifest,
            interruptEventPolicy: interruptEventPolicy,
            canceledTurnProjection: canceledTurnProjection
        )
    }

    func acceptsImageInput(for localSessionID: UUID) async -> Bool? {
        await imageInputReporting?.acceptsImageInput(for: localSessionID) ?? nil
    }

    func mcpServers(for session: HarnessSessionHandle) async throws -> [HarnessMCPServerStatus] {
        guard let mcpStatusReading else {
            throw HarnessAdapterError.capabilityUnavailable("MCP server status is unavailable")
        }
        return try await mcpStatusReading.mcpServers(for: session)
    }

    func reportedMCPServers(for localSessionID: UUID) async -> [HarnessMCPServerStatus]? {
        await mcpStatusReading?.reportedMCPServers(for: localSessionID) ?? nil
    }

    func advertisedModels(for localSessionID: UUID) async -> [HarnessModelOption]? {
        await modelCatalogReporting?.advertisedModels(for: localSessionID) ?? nil
    }

    func stopSubtask(activityID: String, in session: HarnessSessionHandle) async throws {
        guard let subtaskControlling else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Task control is unavailable."))
        }
        try await subtaskControlling.stopSubtask(activityID: activityID, in: session)
    }

    func setNewSessionID(_ providerSessionID: String?, for localSessionID: UUID) async throws {
        guard let newSessionConfiguring else {
            if providerSessionID == nil { return }
            throw HarnessAdapterError.capabilityUnavailable("New native session preparation is unavailable")
        }
        try await newSessionConfiguring.setNewSessionID(providerSessionID, for: localSessionID)
    }

    func setSessionForkSource(_ source: HarnessSessionForkSource?, for localSessionID: UUID) async throws {
        guard let sessionForkConfiguring else {
            if source == nil { return }
            throw HarnessAdapterError.capabilityUnavailable("Native session fork is unavailable")
        }
        try await sessionForkConfiguring.setSessionForkSource(source, for: localSessionID)
    }

    func requireReadyForRewind(in session: HarnessSessionHandle) async throws {
        guard let conversationQuiescing else { throw HarnessAdapterError.capabilityUnavailable("Conversation rewind is unavailable") }
        try await conversationQuiescing.requireReadyForRewind(in: session)
    }

    func previewFileRewind(userMessageID: String, in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        guard let fileRewinding else { throw HarnessAdapterError.capabilityUnavailable("File restore is unavailable") }
        return try await fileRewinding.previewFileRewind(userMessageID: userMessageID, in: session)
    }

    func restoreFiles(userMessageID: String, expecting preview: HarnessFileRewindResult,
        in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        guard let fileRewinding else { throw HarnessAdapterError.capabilityUnavailable("File restore is unavailable") }
        return try await fileRewinding.restoreFiles(userMessageID: userMessageID, expecting: preview, in: session)
    }

    func sendFollowUp(
        _ input: HarnessUserInput,
        messageID: String,
        priority: HarnessFollowUpPriority,
        to session: HarnessSessionHandle
    ) async throws {
        guard let followUpQueueing else { throw HarnessAdapterError.capabilityUnavailable("Queued messages are unavailable") }
        try await followUpQueueing.sendFollowUp(input, messageID: messageID, priority: priority, to: session)
    }

    func cancelFollowUp(messageID: String, in session: HarnessSessionHandle) async throws -> Bool {
        guard let followUpQueueing else { throw HarnessAdapterError.capabilityUnavailable("Queued messages are unavailable") }
        return try await followUpQueueing.cancelFollowUp(messageID: messageID, in: session)
    }

    func canSendFollowUpNow(in session: HarnessSessionHandle) async -> Bool {
        await followUpQueueing?.canSendFollowUpNow(in: session) ?? false
    }

    func sendFollowUpNow(messageID: String, in session: HarnessSessionHandle) async throws -> HarnessFollowUpSendNow? {
        guard let followUpQueueing else { throw HarnessAdapterError.capabilityUnavailable("Queued messages are unavailable") }
        return try await followUpQueueing.sendFollowUpNow(messageID: messageID, in: session)
    }

    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool {
        guard let interruptedTurnContinuing else {
            throw HarnessAdapterError.capabilityUnavailable("Continuing a cut-off turn is unavailable")
        }
        return try await interruptedTurnContinuing.continueInterruptedTurn(in: session, after: cut)
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        try await core.probeRuntime()
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        try await core.createSession(request)
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        try await core.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: localSessionID,
            workspaceURL: workspaceURL
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try await core.send(prompt, to: session)
    }

    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        try await core.send(input, to: session)
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        try await core.interrupt(session)
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        try await core.respond(to: permissionRequestID, decision: decision, in: session)
    }

    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws {
        try await core.respond(
            to: permissionRequestID,
            selectedActionID: selectedActionID,
            in: session
        )
    }

    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: HarnessSessionHandle
    ) async throws {
        try await core.respond(to: permissionRequestID, answer: answer, in: session)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        await core.events(for: session)
    }

    func providerCapabilities(
        for session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        await carryingNegotiatedImageInput(
            try await core.readProviderCapabilities(for: session),
            for: session
        )
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        await carryingNegotiatedImageInput(
            try await core.setProviderOption(id: id, value: value, in: session),
            for: session
        )
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        await carryingNegotiatedImageInput(
            try await core.performProviderAction(id: id, in: session),
            for: session
        )
    }

    /// The catalogs YHP returns are rebuilt from option and action lists, so the agent's own
    /// image answer, and the MCP servers its session reported, have to be laid back on rather
    /// than surviving on their own.
    private func carryingNegotiatedImageInput(
        _ state: ProviderCapabilityState,
        for session: HarnessSessionHandle
    ) async -> ProviderCapabilityState {
        var state = state
        if let mcpStatusReading {
            state.mcpServers = await mcpStatusReading.reportedMCPServers(for: session.localSessionID)
        }
        guard let imageInputReporting else { return state }
        state.acceptsImageInput = await imageInputReporting.acceptsImageInput(
            for: session.localSessionID
        )
        return state
    }

    func close(_ session: HarnessSessionHandle) async {
        await core.close(session)
    }
}
