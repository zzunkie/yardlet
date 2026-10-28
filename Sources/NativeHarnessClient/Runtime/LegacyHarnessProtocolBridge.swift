import Foundation

enum LegacyHarnessProtocolBridgeError: Error, Equatable, Sendable {
    case missingSession(UUID)
    case unsupportedContent
    case invalidPermissionAction(String)
}

enum HarnessProtocolCompatibilityManifest {
    static func structuredHeadless(_ kind: HarnessKind) -> HarnessAdapterManifest {
        precondition(kind == .cursorAgent || kind == .antigravityCLI)
        var capabilities = Array(HarnessAdapterManifestValidator.requiredCapabilities)
        // Antigravity's stream-json carries `init`, `step_update` and `result` events with no
        // plan payload, so no headless flavor declares plans.
        capabilities += [.sessionResume, .turnInterrupt, .structuredActivities]
        return HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.structured-headless.\(kind.rawValue)",
            harness: kind,
            displayName: "\(kind.displayName) compatibility adapter",
            protocolVersions: [.v1],
            capabilities: capabilities,
            extensionNamespaces: ["yardlet.compat", "yardlet.provider"]
        )
    }

    static func acp(_ kind: HarnessKind) -> HarnessAdapterManifest {
        precondition(HarnessCatalog.descriptor(for: kind)?.transport == .acp)
        return HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.acp.\(kind.rawValue)",
            harness: kind,
            displayName: "\(kind.displayName) ACP compatibility adapter",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities) + [
                .sessionResume,
                .turnInterrupt,
                .structuredPermissions,
                .structuredActivities,
                .plans,
                .reasoning,
                .usage,
                // The family can carry an image block; whether a given agent accepts one is
                // negotiated in `initialize` and reported by the runtime probe.
                .images
            ],
            extensionNamespaces: ["yardlet.compat", "yardlet.provider"]
        )
    }

    static func msp(_ kind: HarnessKind) -> HarnessAdapterManifest {
        precondition(HarnessCatalog.descriptor(for: kind)?.transport == .msp)
        return HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.msp.\(kind.rawValue)",
            harness: kind,
            displayName: "\(kind.displayName) MSP compatibility adapter",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities) + [
                .sessionResume,
                .turnInterrupt,
                .structuredPermissions,
                .structuredActivities,
                .reasoning,
                // `session/tokenUsage` and `session/contextUsage` in the stable MSP v1 surface.
                .usage,
                // `turn/start` takes an `image` input part in the stable MSP v1 surface.
                .images
            ],
            extensionNamespaces: ["yardlet.compat", "yardlet.provider"]
        )
    }

    static func piRPC(_ kind: HarnessKind) -> HarnessAdapterManifest {
        precondition(kind == .pi)
        return HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.pi-rpc.\(kind.rawValue)",
            harness: kind,
            displayName: "\(kind.displayName) Pi RPC compatibility adapter",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities) + [
                .sessionResume,
                .turnInterrupt,
                .structuredPermissions,
                .structuredActivities,
                .reasoning,
                .usage,
                .images
            ],
            extensionNamespaces: ["yardlet.compat", "yardlet.provider"]
        )
    }

    static func claude() -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.claude-stream-json",
            harness: .claudeCode,
            displayName: "Claude Code stream-JSON compatibility adapter",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities) + [
                .sessionResume,
                .turnInterrupt,
                .structuredPermissions,
                .structuredActivities,
                .reasoning,
                .usage,
                .images,
                .plans
            ],
            extensionNamespaces: ["yardlet.compat", "yardlet.provider"]
        )
    }

    static func codex() -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.compat.codex-app-server",
            harness: .codex,
            displayName: "Codex app-server compatibility adapter",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities) + [
                .sessionResume,
                .turnSteer,
                .turnInterrupt,
                .structuredPermissions,
                .structuredActivities,
                .plans,
                .images,
                .codexPresentationPatches
            ],
            extensionNamespaces: ["yardlet.compat", "yardlet.codex"]
        )
    }
}

/// The `yardlet.compat` extension events that carry a provider's plan limits, retries,
/// compaction, follow-up deliveries and suggested next message across the protocol bridge.
enum LegacyProviderStatusExtension {
    static let rateLimit = "provider.rate_limit"
    static let usageLimit = "provider.usage_limit"
    static let retry = "provider.retry"
    static let compaction = "session.compaction"
    static let followUp = "session.follow_up"
    static let nextMessageSuggestion = "session.next_message_suggestion"
    static let providerTurn = "session.provider_turn"
    static let turnCut = "session.turn_cut"

    static func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) -> Value? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func payload(name: String, value: JSONValue) -> HarnessEventPayload? {
        switch name {
        case rateLimit: decode(HarnessRateLimit.self, from: value).map(HarnessEventPayload.rateLimitUpdated)
        case usageLimit: decode(HarnessRateLimit.self, from: value).map(HarnessEventPayload.usageLimitReached)
        case retry: decode(HarnessProviderRetry.self, from: value).map(HarnessEventPayload.providerRetrying)
        case compaction: decode(HarnessContextCompaction.self, from: value).map(HarnessEventPayload.contextCompaction)
        case followUp: decode(HarnessFollowUpDelivery.self, from: value).map(HarnessEventPayload.followUpDelivery)
        case nextMessageSuggestion: value["text"]?.stringValue.map(HarnessEventPayload.nextMessageSuggestion)
        case providerTurn: .providerStartedTurn(messageID: value["messageID"]?.stringValue)
        case turnCut: value["cut"]?.stringValue.flatMap(TurnCut.init(rawValue:)).map(HarnessEventPayload.turnCutOff)
        default: nil
        }
    }
}

enum LegacyHarnessInterruptEventPolicy: Sendable {
    case synthesizeCanceled
    case awaitLegacyTerminal
}

/// Temporary in-process bridge used to migrate built-in adapters one family at a time.
/// It never changes the wrapped adapter's transport or provider process ownership.
actor LegacyHarnessProtocolBridge {
    nonisolated let manifest: HarnessAdapterManifest

    private let adapter: any HarnessAdapter
    private let interruptEventPolicy: LegacyHarnessInterruptEventPolicy
    private let payloadCodec = HarnessProtocolPayloadCodec()
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var relayTasks: [UUID: Task<Void, Never>] = [:]
    private var endedSessionIDs: Set<UUID> = []
    private var presentationRelayTasks: [UUID: Task<Void, Never>] = [:]
    private var histories: [UUID: HarnessProtocolEventHistory] = [:]
    private var continuations: [UUID: AsyncStream<HarnessProtocolEventEnvelope>.Continuation] = [:]
    private var nextSequence: [UUID: UInt64] = [:]
    private var activeTurnIDs: [UUID: String] = [:]
    private var validators: [UUID: HarnessProtocolEventContractValidator] = [:]
    private var permissionActions: [UUID: [String: [HarnessProtocolPermissionAction]]] = [:]
    private var interruptedTurnIDs: [UUID: String] = [:]
    /// Sessions whose host asked for live Codex presentation patches, and the presentation each
    /// last sent. Revisions are unique across the bridge's life, so a host never mistakes a
    /// reattached session's chain for an older one.
    private var codexPatchSessionIDs: Set<UUID> = []
    private var sentCodexPresentations: [UUID: SentCodexPresentation] = [:]
    private var nextCodexPresentationRevision: UInt64 = 1

    init(
        adapter: any HarnessAdapter,
        manifest: HarnessAdapterManifest,
        interruptEventPolicy: LegacyHarnessInterruptEventPolicy = .awaitLegacyTerminal
    ) {
        self.adapter = adapter
        self.manifest = manifest
        self.interruptEventPolicy = interruptEventPolicy
    }

    func handle(_ request: HarnessProtocolRequest) async throws -> HarnessProtocolResponse {
        try HarnessProtocolMethodAdmission.validate(request.method, manifest: manifest)
        try HarnessProtocolRequestSchema.validate(request, manifest: manifest)
        do {
            let result = try await dispatch(request)
            return HarnessProtocolResponse(id: request.id, result: result)
        } catch {
            return HarnessProtocolResponse(
                id: request.id,
                error: HarnessProtocolResponseError(
                    code: "yardlet.compat.adapter_error",
                    message: error.localizedDescription,
                    data: nil
                )
            )
        }
    }

    func events(for localSessionID: UUID) -> AsyncStream<HarnessProtocolEventEnvelope> {
        let stream = AsyncStream<HarnessProtocolEventEnvelope>.makeStream()
        for event in histories[localSessionID]?.events ?? [] {
            stream.continuation.yield(event)
        }
        continuations[localSessionID]?.finish()
        continuations[localSessionID] = stream.continuation
        if endedSessionIDs.contains(localSessionID) { stream.continuation.finish() }
        return stream.stream
    }

    private func dispatch(_ request: HarnessProtocolRequest) async throws -> JSONValue {
        if request.method == .compatibilityOptionsRead {
            let params = try request.decodeParams(HarnessProtocolSessionOptionsReadParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any ProviderCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose session options"
                )
            }
            return try payloadCodec.encode(
                optionCatalog(try await provider.providerCapabilities(for: handle))
            )
        }
        if request.method == .compatibilityOptionsSet {
            let params = try request.decodeParams(HarnessProtocolSessionOptionSetParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any ProviderCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose session options"
                )
            }
            return try payloadCodec.encode(
                optionCatalog(
                    try await provider.setProviderOption(
                        id: params.optionID,
                        value: params.value,
                        in: handle
                    )
                )
            )
        }
        if request.method == .compatibilityActionsRead {
            let params = try request.decodeParams(HarnessProtocolSessionActionsReadParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any ProviderCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose session actions"
                )
            }
            return try payloadCodec.encode(
                actionCatalog(try await provider.providerCapabilities(for: handle))
            )
        }
        if request.method == .compatibilityActionPerform {
            let params = try request.decodeParams(HarnessProtocolSessionActionPerformParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any ProviderCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose session actions"
                )
            }
            return try payloadCodec.encode(
                actionCatalog(
                    try await provider.performProviderAction(
                        id: params.actionID,
                        in: handle
                    )
                )
            )
        }
        if request.method == .codexComposerSubmit {
            let params = try request.decodeParams(HarnessProtocolCodexComposerSubmitParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let composer = adapter as? any CodexComposerProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose the Codex composer"
                )
            }
            let inputs = params.inputs.compactMap(CodexUserInput.decode)
            guard inputs.count == params.inputs.count else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "A Codex composer input could not be decoded losslessly"
                )
            }
            switch params.submission {
            case .start:
                activeTurnIDs[params.localSessionID] = params.clientTurnID
                try emit(
                    .turnStarted(HarnessProtocolTurnDescriptor(
                        id: params.clientTurnID,
                        localSessionID: params.localSessionID
                    )),
                    localSessionID: params.localSessionID
                )
                do {
                    try await composer.submit(
                        CodexComposerDraft(inputs: inputs),
                        submission: .start,
                        to: handle
                    )
                } catch {
                    activeTurnIDs.removeValue(forKey: params.localSessionID)
                    try emit(
                        .turnFailed(
                            turnID: params.clientTurnID,
                            failure: HarnessProtocolFailure(
                                code: "yardlet.codex.composer_failed",
                                message: error.localizedDescription,
                                diagnostic: nil,
                                recoverable: true
                            )
                        ),
                        localSessionID: params.localSessionID
                    )
                    throw error
                }
            case .steer:
                guard let expectedTurnID = params.expectedTurnID else {
                    throw HarnessAdapterError.invalidProviderEvent(
                        "Codex steer requires an expected provider turn ID"
                    )
                }
                try await composer.submit(
                    CodexComposerDraft(inputs: inputs),
                    submission: .steer(expectedTurnID: expectedTurnID),
                    to: handle
                )
            }
            return try payloadCodec.encode(HarnessProtocolCodexComposerState(
                activeTurnID: await composer.activeTurnID(for: handle)
            ))
        }
        if request.method == .codexPresentationRead {
            let params = try request.decodeParams(HarnessProtocolCodexPresentationReadParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexPresentationProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex presentation state"
                )
            }
            if params.livePatches == true, manifest.supports(.codexPresentationPatches) {
                // The next live update starts the chain again with a complete snapshot.
                codexPatchSessionIDs.insert(params.localSessionID)
                sentCodexPresentations.removeValue(forKey: params.localSessionID)
            }
            let state = params.refresh
                ? try await provider.refreshPresentationState(for: handle)
                : try await provider.presentationState(for: handle)
            return try payloadCodec.encode(
                await codexSnapshot(
                    state,
                    localSessionID: params.localSessionID,
                    handle: handle
                )
            )
        }
        if request.method == .codexTurnsLoad {
            let params = try request.decodeParams(HarnessProtocolCodexTurnsLoadParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexPresentationProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex turn pagination"
                )
            }
            return try payloadCodec.encode(
                codexTurnPage(
                    try await provider.loadTurns(
                        for: handle,
                        cursor: params.cursor,
                        limit: params.limit
                    )
                )
            )
        }
        if request.method == .codexItemsLoad {
            let params = try request.decodeParams(HarnessProtocolCodexItemsLoadParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexPresentationProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex item pagination"
                )
            }
            return try payloadCodec.encode(
                codexItemPage(
                    try await provider.loadItems(
                        for: handle,
                        turnID: params.turnID,
                        cursor: params.cursor,
                        limit: params.limit
                    )
                )
            )
        }
        if request.method == .codexThreadRead {
            let params = try request.decodeParams(HarnessProtocolCodexThreadReadParams.self)
            guard let reader = adapter as? any CodexThreadReading else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not read saved Codex threads"
                )
            }
            let state = try await reader.readThreadPresentation(threadID: params.threadID,
                                                                newestTurns: params.newestTurns)
            guard let thread = state.thread else {
                throw HarnessAdapterError.invalidProviderEvent("thread/read response is missing thread")
            }
            return try payloadCodec.encode(
                HarnessProtocolCodexThreadReadResult(thread: CodexPresentationWire.thread(thread))
            )
        }
        if request.method == .codexThreadTurnsRead {
            let params = try request.decodeParams(HarnessProtocolCodexThreadTurnsReadParams.self)
            guard let reader = adapter as? any CodexThreadReading else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not read saved Codex threads"
                )
            }
            return try payloadCodec.encode(codexTurnPage(
                try await reader.readThreadTurns(threadID: params.threadID, cursor: params.cursor, limit: params.limit)
            ))
        }
        if request.method == .codexHistoryRecent {
            let params = try request.decodeParams(HarnessProtocolCodexHistoryParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex history"
                )
            }
            let page = try await provider.recentThreadsPage(
                in: URL(filePath: params.workspacePath),
                cursor: params.cursor,
                limit: params.limit
            )
            return try payloadCodec.encode(HarnessProtocolCodexRecentThreadsPage(
                threads: page.threads.map(codexThreadSummary),
                nextCursor: page.nextCursor
            ))
        }
        if request.method == .codexHistoryInteractive {
            let params = try request.decodeParams(HarnessProtocolCodexHistoryPageParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex history"
                )
            }
            let page = params.archived == true
                ? try await provider.archivedInteractiveThreadsPage(cursor: params.cursor, limit: params.limit)
                : try await provider.interactiveThreadsPage(cursor: params.cursor, limit: params.limit)
            return try payloadCodec.encode(HarnessProtocolCodexRecentThreadsPage(
                threads: page.threads.map(codexThreadSummary),
                nextCursor: page.nextCursor
            ))
        }
        if request.method == .codexAccountRateLimitsRead {
            _ = try request.decodeParams(HarnessProtocolEmptyParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex rate limits"
                )
            }
            return try payloadCodec.encode(try await provider.accountRateLimits())
        }
        if request.method == .codexSkillsRead {
            let params = try request.decodeParams(HarnessProtocolCodexWorkspaceParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex skills"
                )
            }
            return try payloadCodec.encode(HarnessProtocolCodexSkillsCatalog(
                skills: try await provider.skills(
                    in: URL(filePath: params.workspacePath)
                ).map { skill in
                    HarnessProtocolCodexSkill(
                        name: skill.name,
                        displayName: skill.displayName,
                        description: skill.description,
                        enabled: skill.enabled,
                        scope: skill.scope,
                        path: skill.path
                    )
                }
            ))
        }
        if request.method == .codexPluginsRead {
            let params = try request.decodeParams(HarnessProtocolCodexWorkspaceParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex plugins"
                )
            }
            return try payloadCodec.encode(HarnessProtocolCodexPluginsCatalog(
                plugins: try await provider.plugins(
                    in: URL(filePath: params.workspacePath)
                ).map { plugin in
                    HarnessProtocolCodexPlugin(
                        id: plugin.id,
                        name: plugin.name,
                        displayName: plugin.displayName,
                        description: plugin.description,
                        installed: plugin.installed,
                        enabled: plugin.enabled,
                        availability: plugin.availability,
                        marketplace: plugin.marketplace
                    )
                }
            ))
        }
        if request.method == .codexHistorySearch {
            let params = try request.decodeParams(HarnessProtocolCodexHistorySearchParams.self)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex history search"
                )
            }
            let page = try await provider.searchThreads(
                in: URL(filePath: params.workspacePath),
                searchTerm: params.query,
                cursor: params.cursor,
                limit: params.limit
            )
            return try payloadCodec.encode(HarnessProtocolCodexThreadSearchPage(
                matches: page.matches.map { match in
                    HarnessProtocolCodexThreadSearchMatch(
                        thread: codexThreadSummary(match.thread),
                        snippet: match.snippet
                    )
                },
                nextCursor: page.nextCursor
            ))
        }
        if request.method == .codexHistoryOccurrences {
            let params = try request.decodeParams(
                HarnessProtocolCodexHistoryOccurrencesParams.self
            )
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex history occurrences"
                )
            }
            let page = try await provider.searchOccurrences(
                threadID: params.providerSessionID,
                searchTerm: params.query,
                cursor: params.cursor,
                limit: params.limit
            )
            return try payloadCodec.encode(HarnessProtocolCodexSearchOccurrencesPage(
                occurrences: page.occurrences.map { occurrence in
                    HarnessProtocolCodexSearchOccurrence(
                        turnID: occurrence.turnID,
                        itemID: occurrence.itemID,
                        snippet: occurrence.snippet,
                        snippetMatchRange: occurrence.snippetMatchRange,
                        turnCursor: occurrence.turnCursor
                    )
                },
                nextCursor: page.nextCursor
            ))
        }
        if request.method == .codexModelsRead {
            let params = try request.decodeParams(HarnessProtocolSessionReference.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable("Codex model catalog is unavailable")
            }
            return try payloadCodec.encode(try await provider.modelCatalog(for: handle))
        }
        if request.method == .codexModelSet {
            let params = try request.decodeParams(HarnessProtocolCodexModelSetParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable("Codex model selection is unavailable")
            }
            return try payloadCodec.encode(try await provider.selectModel(params.selection, for: handle))
        }
        if request.method == .codexControlsRead {
            let params = try request.decodeParams(HarnessProtocolCodexControlsReadParams.self)
            _ = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex controls"
                )
            }
            return try payloadCodec.encode(HarnessProtocolCodexControlsCatalog(
                collaborationModes: try await provider.collaborationModes().map { mode in
                    HarnessProtocolCodexCollaborationMode(
                        id: mode.id,
                        name: mode.name,
                        mode: mode.mode,
                        model: mode.model,
                        reasoningEffort: mode.reasoningEffort
                    )
                },
                runLocations: CodexRunLocation.allCases.map { location in
                    HarnessProtocolCodexRunLocation(
                        id: location.id,
                        displayName: location.displayName
                    )
                }
            ))
        }
        if request.method == .codexCollaborationSet {
            let params = try request.decodeParams(HarnessProtocolCodexCollaborationSetParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex collaboration controls"
                )
            }
            let selected: CodexCollaborationPreset?
            if let modeID = params.modeID {
                selected = try await provider.collaborationModes().first { $0.id == modeID }
                guard selected != nil else {
                    throw HarnessAdapterError.invalidProviderEvent(
                        "Unknown Codex collaboration mode"
                    )
                }
            } else {
                selected = nil
            }
            try await provider.selectCollaborationMode(selected, for: handle)
            return try acknowledgement()
        }
        if request.method == .codexRunLocationSet {
            let params = try request.decodeParams(HarnessProtocolCodexRunLocationSetParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding,
                  let location = CodexRunLocation(rawValue: params.runLocationID) else {
                throw HarnessAdapterError.invalidProviderEvent("Unknown Codex run location")
            }
            try await provider.selectRunLocation(location, for: handle)
            return try acknowledgement()
        }
        if request.method == .codexConversationEdit {
            let params = try request.decodeParams(HarnessProtocolCodexConversationEditParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let editing = adapter as? any CodexConversationEditing else {
                throw HarnessAdapterError.capabilityUnavailable("Conversation editing is unavailable")
            }
            try await editing.prepareConversationEdit(params.edit, in: handle)
            return try acknowledgement()
        }
        if request.method == .codexTurnRetry {
            let params = try request.decodeParams(HarnessProtocolCodexTurnRetryParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let recovery = adapter as? any CodexTurnRecovering,
                  let composer = adapter as? any CodexComposerProviding else {
                throw HarnessAdapterError.capabilityUnavailable("Codex turn recovery is unavailable")
            }
            try await recovery.retryFailedTurn(params.expectedTurnID, in: handle)
            return try payloadCodec.encode(HarnessProtocolCodexComposerState(activeTurnID: await composer.activeTurnID(for: handle)))
        }
        if request.method == .codexTurnContinue {
            let params = try request.decodeParams(HarnessProtocolCodexTurnContinueParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let continuing = adapter as? any HarnessInterruptedTurnContinuing,
                  let composer = adapter as? any CodexComposerProviding else {
                throw HarnessAdapterError.capabilityUnavailable("Codex turn continuation is unavailable")
            }
            let started = try await continuing.continueInterruptedTurn(in: handle, after: params.cut ?? .quit)
            return try payloadCodec.encode(HarnessProtocolCodexTurnContinueResult(
                started: started, activeTurnID: await composer.activeTurnID(for: handle)))
        }
        if request.method == .codexSessionFork {
            let params = try request.decodeParams(HarnessProtocolCodexForkParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex fork"
                )
            }
            let forked = try await provider.fork(
                handle,
                newLocalSessionID: params.newLocalSessionID,
                throughTurnID: params.throughTurnID
            )
            try attach(forked)
            return try payloadCodec.encode(descriptor(for: forked))
        }
        if request.method == .codexCompactStart {
            let params = try request.decodeParams(HarnessProtocolCodexCompactParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable("Codex context compaction is unavailable")
            }
            try await provider.compactConversation(in: handle)
            return try acknowledgement()
        }
        if request.method == .codexReviewStart {
            let params = try request.decodeParams(HarnessProtocolCodexReviewStartParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex review"
                )
            }
            activeTurnIDs[params.localSessionID] = params.clientTurnID
            try emit(
                .turnStarted(HarnessProtocolTurnDescriptor(
                    id: params.clientTurnID,
                    localSessionID: params.localSessionID
                )),
                localSessionID: params.localSessionID
            )
            do {
                try await provider.startReview(params.target ?? .uncommittedChanges, in: handle)
            } catch {
                activeTurnIDs.removeValue(forKey: params.localSessionID)
                try emit(
                    .turnFailed(
                        turnID: params.clientTurnID,
                        failure: HarnessProtocolFailure(
                            code: "yardlet.codex.review_failed",
                            message: error.localizedDescription,
                            diagnostic: nil,
                            recoverable: true
                        )
                    ),
                    localSessionID: params.localSessionID
                )
                throw error
            }
            return try acknowledgement()
        }
        if request.method == .codexThreadRename {
            let params = try request.decodeParams(HarnessProtocolCodexThreadRenameParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any HarnessSessionLifecycleProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex thread naming"
                )
            }
            try await provider.renameProviderSession(handle, to: params.name)
            return try acknowledgement()
        }
        if request.method == .codexThreadUnarchive {
            let params = try request.decodeParams(HarnessProtocolCodexThreadReference.self)
            guard let provider = adapter as? any HarnessSessionLifecycleProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex thread actions"
                )
            }
            try await provider.unarchiveProviderSession(providerSessionID: params.providerSessionID)
            return try acknowledgement()
        }
        if request.method == .codexThreadArchive || request.method == .codexThreadDelete {
            let params = try request.decodeParams(HarnessProtocolSessionReference.self)
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any HarnessSessionLifecycleProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex thread actions"
                )
            }
            if request.method == .codexThreadArchive {
                try await provider.archiveProviderSession(handle)
            } else {
                try await provider.deleteProviderSession(handle)
            }
            return try acknowledgement()
        }
        if request.method == .codexServerRequestRespond {
            let params = try request.decodeParams(
                HarnessProtocolCodexServerRequestRespondParams.self
            )
            let handle = try requireHandle(params.localSessionID)
            guard let provider = adapter as? any CodexPresentationProviding else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose Codex server requests"
                )
            }
            try await provider.respond(
                to: params.requestID,
                response: try codexServerResponse(params.response),
                in: handle
            )
            return try acknowledgement()
        }

        switch request.method {
        case .runtimeProbe:
            let runtime = try await adapter.probeRuntime()
            return try payloadCodec.encode(
                HarnessProtocolRuntimeInfo(
                    harness: runtime.harness,
                    executablePath: runtime.executableURL.path(percentEncoded: false),
                    version: runtime.version,
                    // The manifest says what this adapter family can carry. Image input is the
                    // one capability an agent decides for itself, so it is only reported when
                    // the wrapped runtime confirms it.
                    capabilities: manifest.capabilities.filter {
                        $0 != .images || runtime.capabilities.acceptsImages
                    },
                    fingerprint: runtime.fingerprint
                )
            )

        case .sessionCreate:
            let params = try request.decodeParams(HarnessProtocolCreateSessionParams.self)
            let handle = try await adapter.createSession(
                CreateHarnessSessionRequest(
                    localSessionID: params.localSessionID,
                    workspaceURL: URL(filePath: params.config.workspacePath),
                    initialPrompt: nil
                )
            )
            try attach(handle)
            if !params.initialPrompt.isEmpty {
                try await submit(
                    params.initialPrompt,
                    clientMessageID: "initial-\(request.id)",
                    localSessionID: handle.localSessionID
                )
            }
            return try payloadCodec.encode(descriptor(for: handle))

        case .sessionResume:
            let params = try request.decodeParams(HarnessProtocolResumeSessionParams.self)
            let handle = try await adapter.resumeSession(
                providerSessionID: params.providerSessionID,
                localSessionID: params.localSessionID,
                workspaceURL: URL(filePath: params.config.workspacePath)
            )
            try attach(handle)
            return try payloadCodec.encode(descriptor(for: handle))

        case .sessionSend:
            let params = try request.decodeParams(HarnessProtocolTurnSubmitParams.self)
            try await submit(
                params.content,
                clientMessageID: params.clientMessageID,
                localSessionID: params.localSessionID
            )
            return try acknowledgement()

        case .sessionSteer:
            let params = try request.decodeParams(HarnessProtocolTurnSteerParams.self)
            guard activeTurnIDs[params.localSessionID] == params.expectedTurnID else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "YHP active turn changed before steer"
                )
            }
            let handle = try requireHandle(params.localSessionID)
            guard let composer = adapter as? any CodexComposerProviding,
                  let providerTurnID = await composer.activeTurnID(for: handle) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    "This compatibility adapter does not expose typed turn steering"
                )
            }
            try await composer.submit(
                CodexComposerDraft(inputs: try codexInputs(from: params.content)),
                submission: .steer(expectedTurnID: providerTurnID),
                to: handle
            )
            return try acknowledgement()

        case .sessionInterrupt:
            let params = try request.decodeParams(HarnessProtocolSessionReference.self)
            let handle = try requireHandle(params.localSessionID)
            let turnID = activeTurnIDs.removeValue(forKey: params.localSessionID)
            if let turnID {
                switch interruptEventPolicy {
                case .synthesizeCanceled:
                    break
                case .awaitLegacyTerminal:
                    interruptedTurnIDs[params.localSessionID] = turnID
                }
            }
            do {
                try await adapter.interrupt(handle)
            } catch {
                interruptedTurnIDs.removeValue(forKey: params.localSessionID)
                if let turnID { activeTurnIDs[params.localSessionID] = turnID }
                throw error
            }
            if let turnID {
                switch interruptEventPolicy {
                case .synthesizeCanceled:
                    try emit(
                        .turnCanceled(turnID: turnID, reason: "interrupted"),
                        localSessionID: params.localSessionID
                    )
                case .awaitLegacyTerminal:
                    break
                }
            }
            return try acknowledgement()

        case .permissionRespond:
            let params = try request.decodeParams(HarnessProtocolPermissionResponseParams.self)
            let handle = try requireHandle(params.localSessionID)
            guard let action = permissionActions[params.localSessionID]?[params.requestID]?.first(where: {
                $0.id == params.selectedActionID && $0.behavior == params.behavior
            }) else {
                throw LegacyHarnessProtocolBridgeError.invalidPermissionAction(
                    params.selectedActionID
                )
            }
            // A response that carries an answer the provider asked for must reach the wrapped
            // adapter as that answer, not as a bare allow or deny that would discard it.
            let structuredAnswer = structuredAnswer(from: params)
            if let structuredAnswer,
               let responder = adapter as? any HarnessStructuredPermissionResponding {
                try await responder.respond(
                    to: params.requestID,
                    answer: structuredAnswer,
                    in: handle
                )
            } else if let responder = adapter as? any HarnessPermissionActionResponding {
                try await responder.respond(
                    to: params.requestID,
                    selectedActionID: action.id,
                    in: handle
                )
            } else {
                let decision: PermissionDecision = action.behavior == .allow ? .allow : .deny
                try await adapter.respond(
                    to: params.requestID,
                    decision: decision,
                    in: handle
                )
            }
            permissionActions[params.localSessionID]?.removeValue(forKey: params.requestID)
            if permissionActions[params.localSessionID]?.isEmpty == true {
                permissionActions.removeValue(forKey: params.localSessionID)
            }
            try emit(
                .permissionResolved(
                    turnID: activeTurnIDs[params.localSessionID],
                    resolution: HarnessProtocolPermissionResolution(
                        requestID: params.requestID,
                        selectedActionID: params.selectedActionID,
                        behavior: params.behavior
                    )
                ),
                localSessionID: params.localSessionID
            )
            return try acknowledgement()

        case .sessionClose:
            let params = try request.decodeParams(HarnessProtocolSessionReference.self)
            let handle = try requireHandle(params.localSessionID)
            await adapter.close(handle)
            relayTasks.removeValue(forKey: params.localSessionID)?.cancel()
            presentationRelayTasks.removeValue(forKey: params.localSessionID)?.cancel()
            codexPatchSessionIDs.remove(params.localSessionID)
            sentCodexPresentations.removeValue(forKey: params.localSessionID)
            handles.removeValue(forKey: params.localSessionID)
            activeTurnIDs.removeValue(forKey: params.localSessionID)
            interruptedTurnIDs.removeValue(forKey: params.localSessionID)
            permissionActions.removeValue(forKey: params.localSessionID)
            continuations.removeValue(forKey: params.localSessionID)?.finish()
            histories.removeValue(forKey: params.localSessionID)
            nextSequence.removeValue(forKey: params.localSessionID)
            validators.removeValue(forKey: params.localSessionID)
            return try acknowledgement()

        default:
            throw HarnessProtocolMethodAdmissionError.undeclaredExtensionMethod(request.method)
        }
    }

    private func attach(_ handle: HarnessSessionHandle) throws {
        endedSessionIDs.remove(handle.localSessionID)
        handles[handle.localSessionID] = handle
        if histories[handle.localSessionID] == nil {
            try emit(.sessionStarted(descriptor(for: handle)), localSessionID: handle.localSessionID)
        }
        relayTasks.removeValue(forKey: handle.localSessionID)?.cancel()
        relayTasks[handle.localSessionID] = Task { [weak self, adapter] in
            for await event in await adapter.events(for: handle) {
                guard !Task.isCancelled else { return }
                await self?.accept(event)
            }
            guard !Task.isCancelled else { return }
            await self?.endEventStream(for: handle.localSessionID)
        }
        presentationRelayTasks.removeValue(forKey: handle.localSessionID)?.cancel()
        if let provider = adapter as? any CodexPresentationProviding {
            presentationRelayTasks[handle.localSessionID] = Task { [weak self] in
                guard let stream = try? await provider.presentationStates(for: handle) else {
                    return
                }
                for await state in stream {
                    guard !Task.isCancelled else { break }
                    await self?.acceptPresentation(state, for: handle)
                }
            }
        }
    }

    private func endEventStream(for localSessionID: UUID) {
        endedSessionIDs.insert(localSessionID)
        presentationRelayTasks.removeValue(forKey: localSessionID)?.cancel()
        continuations[localSessionID]?.finish()
    }

    private func acceptPresentation(
        _ state: CodexTaskState,
        for handle: HarnessSessionHandle
    ) async {
        let localSessionID = handle.localSessionID
        guard handles[localSessionID] != nil else { return }
        let answerable = await answerableServerRequestIDs(in: state, handle: handle)
        // Nothing below suspends, so a read that restarts the patch chain cannot fall between
        // the presentation this compares against and the one it records.
        guard handles[localSessionID] != nil else { return }
        do {
            guard codexPatchSessionIDs.contains(localSessionID) else {
                try emitPresentation(
                    HarnessProtocolCodexPresentationEvent.updated,
                    CodexPresentationWire.snapshot(
                        state,
                        localSessionID: localSessionID,
                        answerableServerRequestIDs: answerable
                    ),
                    localSessionID: localSessionID
                )
                return
            }
            let revision = nextCodexPresentationRevision
            if let sent = sentCodexPresentations[localSessionID], sent.hasUniqueIDs {
                switch CodexPresentationDiff.outcome(
                    from: sent.state,
                    baseAnswerableServerRequestIDs: sent.answerableServerRequestIDs,
                    to: state,
                    answerableServerRequestIDs: answerable,
                    localSessionID: localSessionID,
                    baseRevision: sent.revision,
                    revision: revision
                ) {
                case .unchanged:
                    return
                case let .patch(patch):
                    try emitPresentation(
                        HarnessProtocolCodexPresentationEvent.patched,
                        patch,
                        localSessionID: localSessionID
                    )
                    nextCodexPresentationRevision += 1
                    sentCodexPresentations[localSessionID] = SentCodexPresentation(
                        revision: revision,
                        state: state,
                        answerableServerRequestIDs: answerable,
                        hasUniqueIDs: true
                    )
                    return
                case .needsSnapshot:
                    break
                }
            }
            var snapshot = CodexPresentationWire.snapshot(
                state,
                localSessionID: localSessionID,
                answerableServerRequestIDs: answerable
            )
            snapshot.revision = revision
            try emitPresentation(
                HarnessProtocolCodexPresentationEvent.updated,
                snapshot,
                localSessionID: localSessionID
            )
            nextCodexPresentationRevision += 1
            sentCodexPresentations[localSessionID] = SentCodexPresentation(
                revision: revision,
                state: state,
                answerableServerRequestIDs: answerable,
                hasUniqueIDs: CodexPresentationDiff.hasUniqueIDs(state)
            )
        } catch {
            // Presentation projection must not terminate the canonical lifecycle stream.
        }
    }

    private func emitPresentation<Value: Encodable & Sendable>(
        _ name: String,
        _ value: Value,
        localSessionID: UUID
    ) throws {
        try emit(
            .extensionEvent(HarnessProtocolExtensionEvent(
                namespace: "yardlet.codex",
                name: name,
                payload: try payloadCodec.encode(value)
            )),
            localSessionID: localSessionID
        )
    }

    private func submit(
        _ content: [HarnessProtocolContentBlock],
        clientMessageID: String,
        localSessionID: UUID
    ) async throws {
        let handle = try requireHandle(localSessionID)
        activeTurnIDs[localSessionID] = clientMessageID
        try emit(
            .turnStarted(
                HarnessProtocolTurnDescriptor(
                    id: clientMessageID,
                    localSessionID: localSessionID
                )
            ),
            localSessionID: localSessionID
        )
        do {
            if let composer = adapter as? any CodexComposerProviding {
                try await composer.submit(
                    CodexComposerDraft(inputs: try codexInputs(from: content)),
                    submission: .start,
                    to: handle
                )
            } else {
                try await adapter.send(try userInput(from: content), to: handle)
            }
        } catch {
            activeTurnIDs.removeValue(forKey: localSessionID)
            try emit(
                .turnFailed(
                    turnID: clientMessageID,
                    failure: HarnessProtocolFailure(
                        code: "yardlet.compat.send_failed",
                        message: error.localizedDescription,
                        diagnostic: nil,
                        recoverable: true
                    )
                ),
                localSessionID: localSessionID
            )
            throw error
        }
    }

    private func accept(_ event: HarnessEventEnvelope) {
        let localSessionID = event.localSessionID
        do {
            switch event.payload {
            case let .sessionStarted(handle):
                let prior = handles[localSessionID]
                handles[localSessionID] = handle
                guard prior?.providerSessionID != handle.providerSessionID else { return }
                try emit(
                    .extensionEvent(
                        HarnessProtocolExtensionEvent(
                            namespace: "yardlet.compat",
                            name: "session.provider_identity_updated",
                            payload: .object([
                                "providerSessionID": .string(handle.providerSessionID)
                            ])
                        )
                    ),
                    source: event
                )

            case let .assistantDelta(text):
                let turnID = activeTurnIDs[localSessionID]
                try emit(
                    .assistantDelta(
                        turnID: turnID,
                        messageID: "assistant-\(turnID ?? "session")",
                        text: text
                    ),
                    source: event
                )

            case let .reasoningDelta(text):
                guard manifest.supports(.reasoning) else { return }
                try emit(
                    .reasoningDelta(turnID: activeTurnIDs[localSessionID], text: text),
                    source: event
                )

            case let .reasoningCompleted(text), let .progressUpdateCompleted(text):
                // YHP streams reasoning as deltas. The completed block is the provider's own
                // final text, so it travels as a declared compatibility extension rather than
                // being replayed as another delta the transcript would append. A block that is
                // what the model wrote between tool calls says so.
                guard manifest.supports(.reasoning) else { return }
                var payload: [String: JSONValue] = ["text": .string(text)]
                if case .progressUpdateCompleted = event.payload { payload["progressUpdate"] = .bool(true) }
                try emit(
                    .extensionEvent(
                        HarnessProtocolExtensionEvent(
                            namespace: "yardlet.compat",
                            name: "message.reasoning_completed",
                            payload: .object(payload)
                        )
                    ),
                    source: event
                )

            case let .assistantMessageCompleted(text):
                let turnID = activeTurnIDs[localSessionID]
                try emit(
                    .messageCompleted(
                        turnID: turnID,
                        message: HarnessProtocolMessage(
                            id: "assistant-\(turnID ?? "session")",
                            role: .assistant,
                            content: [.text(text)]
                        )
                    ),
                    source: event
                )

            case let .activityStarted(activity):
                try emit(.toolCallUpdated(
                    turnID: activeTurnIDs[localSessionID],
                    toolCall: toolCall(activity, status: .running)
                ), source: event)
            case let .activityUpdated(activity):
                try emit(.toolCallUpdated(
                    turnID: activeTurnIDs[localSessionID],
                    toolCall: toolCall(activity, status: .running)
                ), source: event)
            case let .activityCompleted(activity):
                try emit(.toolCallUpdated(
                    turnID: activeTurnIDs[localSessionID],
                    toolCall: toolCall(activity, status: .completed)
                ), source: event)

            case let .permissionRequested(permission):
                let actions = protocolPermissionActions(permission.actions)
                var sessionActions = permissionActions[localSessionID] ?? [:]
                sessionActions[permission.id] = actions
                permissionActions[localSessionID] = sessionActions
                try emit(
                    .permissionRequested(
                        HarnessProtocolPermissionRequest(
                            id: permission.id,
                            localSessionID: localSessionID,
                            turnID: activeTurnIDs[localSessionID],
                            kind: PermissionStructureCoding.kind(for: permission.structured),
                            name: "legacy.permission",
                            title: permission.title,
                            description: permission.detail,
                            input: permission.command.map(JSONValue.string),
                            suggestions: [],
                            actions: actions,
                            extensionValues: PermissionStructureCoding.extensionValues(for: permission)
                        )
                    ),
                    source: event
                )

            case let .permissionExpired(requestID):
                permissionActions[localSessionID]?.removeValue(forKey: requestID)
                try emit(.extensionEvent(HarnessProtocolExtensionEvent(
                    namespace: "yardlet.compat", name: "permission.expired",
                    payload: .object(["requestID": .string(requestID)])
                )), source: event)

            case let .planUpdated(plan):
                try emit(
                    .planUpdated(
                        turnID: activeTurnIDs[localSessionID],
                        plan: HarnessProtocolPlan(explanation: plan, items: [])
                    ),
                    source: event
                )

            case let .usageUpdated(usage):
                try emit(
                    .usageUpdated(
                        turnID: activeTurnIDs[localSessionID],
                        usage: usage
                    ),
                    source: event
                )

            case .turnCompleted:
                if let turnID = interruptedTurnIDs.removeValue(forKey: localSessionID) {
                    try emit(
                        .turnCanceled(turnID: turnID, reason: "interrupted"),
                        source: event
                    )
                } else {
                    let turnID = activeTurnIDs.removeValue(forKey: localSessionID)
                        ?? "legacy-\(event.sequence)"
                    try emit(.turnCompleted(turnID: turnID, usage: nil), source: event)
                }

            case let .sessionStatusChanged(status):
                try emit(.sessionStatusChanged(status), source: event)

            case .providerCapabilitiesChanged:
                // YHP reads session options on request, so a change the provider made on its
                // own travels as a signal to read them again rather than as a copy of them.
                try emit(
                    .extensionEvent(
                        HarnessProtocolExtensionEvent(
                            namespace: "yardlet.compat",
                            name: "session.options_changed",
                            payload: .object([:])
                        )
                    ),
                    source: event
                )

            case let .rateLimitUpdated(limit):
                try emitStatusExtension(LegacyProviderStatusExtension.rateLimit, limit, source: event)
            case let .usageLimitReached(limit):
                try emitStatusExtension(LegacyProviderStatusExtension.usageLimit, limit, source: event)
            case let .providerRetrying(retry):
                try emitStatusExtension(LegacyProviderStatusExtension.retry, retry, source: event)
            case let .contextCompaction(compaction):
                try emitStatusExtension(LegacyProviderStatusExtension.compaction, compaction, source: event)
            case let .followUpDelivery(delivery):
                try emitStatusExtension(LegacyProviderStatusExtension.followUp, delivery, source: event)
            case let .nextMessageSuggestion(text):
                try emit(.extensionEvent(HarnessProtocolExtensionEvent(
                    namespace: "yardlet.compat", name: LegacyProviderStatusExtension.nextMessageSuggestion,
                    payload: .object(["text": .string(text)])
                )), source: event)
            case let .providerStartedTurn(messageID):
                try emit(.extensionEvent(HarnessProtocolExtensionEvent(
                    namespace: "yardlet.compat", name: LegacyProviderStatusExtension.providerTurn,
                    payload: .object(messageID.map { ["messageID": .string($0)] } ?? [:])
                )), source: event)
            case let .turnCutOff(cut):
                try emit(.extensionEvent(HarnessProtocolExtensionEvent(
                    namespace: "yardlet.compat", name: LegacyProviderStatusExtension.turnCut,
                    payload: .object(["cut": .string(cut.rawValue)])
                )), source: event)

            case let .error(message, recoverable, transient):
                let turnID = activeTurnIDs.removeValue(forKey: localSessionID)
                try emit(
                    .turnFailed(
                        turnID: turnID,
                        failure: HarnessProtocolFailure(
                            code: "yardlet.compat.legacy_error",
                            message: message,
                            diagnostic: nil,
                            recoverable: recoverable,
                            transient: transient
                        )
                    ),
                    source: event
                )
            }
        } catch {
            continuations.removeValue(forKey: localSessionID)?.finish()
        }
    }

    /// Plan limits, retries, compaction and follow-up deliveries have no YHP event of their own.
    /// Each travels as a declared compatibility extension carrying the typed value, which the
    /// compatibility adapter reads back unchanged; it never ends or fails the turn on the protocol
    /// side.
    private func emitStatusExtension<Value: Encodable>(
        _ name: String,
        _ value: Value,
        source: HarnessEventEnvelope
    ) throws {
        try emit(
            .extensionEvent(
                HarnessProtocolExtensionEvent(
                    namespace: "yardlet.compat",
                    name: name,
                    payload: try LegacyProviderStatusExtension.encode(value)
                )
            ),
            source: source
        )
    }

    private func emit(
        _ payload: HarnessProtocolEventPayload,
        source: HarnessEventEnvelope
    ) throws {
        try emit(
            payload,
            localSessionID: source.localSessionID,
            timestamp: source.timestamp,
            rawProviderEvent: source.rawProviderEvent
        )
    }

    private func emit(
        _ payload: HarnessProtocolEventPayload,
        localSessionID: UUID,
        timestamp: Date = Date(),
        rawProviderEvent: Data? = nil
    ) throws {
        let sequence = nextSequence[localSessionID] ?? 0
        let event = HarnessProtocolEventEnvelope(
            localSessionID: localSessionID,
            timestamp: timestamp,
            sequence: sequence,
            payload: payload,
            rawProviderEvent: rawProviderEvent
        )
        var validator = validators[localSessionID]
            ?? HarnessProtocolEventContractValidator(
                localSessionID: localSessionID,
                manifest: manifest
            )
        try validator.accept(event)
        validators[localSessionID] = validator
        nextSequence[localSessionID] = sequence + 1
        // Kept for a subscriber that attaches late; long sessions keep the newest events.
        histories[localSessionID, default: HarnessProtocolEventHistory(limit: 2_000)].append(event)
        continuations[localSessionID]?.yield(event)
    }

    private func acknowledgement() throws -> JSONValue {
        try payloadCodec.encode(HarnessProtocolAcknowledgement(accepted: true))
    }

    private func requireHandle(_ localSessionID: UUID) throws -> HarnessSessionHandle {
        guard let handle = handles[localSessionID] else {
            throw LegacyHarnessProtocolBridgeError.missingSession(localSessionID)
        }
        return handle
    }

    /// Content blocks for an adapter that is not the Codex composer. Text joins the prompt and
    /// a file block becomes a local image attachment; anything else has no neutral home, so the
    /// turn fails instead of arriving with part of the submission missing.
    private func userInput(
        from content: [HarnessProtocolContentBlock]
    ) throws -> HarnessUserInput {
        var parts: [String] = []
        var images: [HarnessUserInput.ImageAttachment] = []
        for block in content {
            switch block {
            case let .text(text):
                parts.append(text)
            case let .file(path, mimeType):
                let url = URL(filePath: path).standardizedFileURL
                guard let type = mimeType ?? HarnessUserInput.imageMIMEType(for: url),
                      type.hasPrefix("image/") else {
                    throw LegacyHarnessProtocolBridgeError.unsupportedContent
                }
                images.append(HarnessUserInput.ImageAttachment(url: url, mimeType: type))
            case let .inlineData(mimeType, base64Data):
                guard let url = InlineImageInput.url(mimeType: mimeType, base64: base64Data) else {
                    throw LegacyHarnessProtocolBridgeError.unsupportedContent
                }
                images.append(.init(url: url, mimeType: mimeType))
            case .remoteURL:
                throw LegacyHarnessProtocolBridgeError.unsupportedContent
            }
        }
        return HarnessUserInput(text: parts.joined(), images: images)
    }

    private func codexInputs(
        from content: [HarnessProtocolContentBlock]
    ) throws -> [CodexUserInput] {
        try content.map { block in
            switch block {
            case let .text(text):
                return .text(text)
            case let .file(path, mimeType):
                let url = URL(filePath: path).standardizedFileURL
                guard mimeType?.hasPrefix("image/") == true
                        || CodexUserInput.localAttachmentKind(for: url) == .image else {
                    throw LegacyHarnessProtocolBridgeError.unsupportedContent
                }
                return .localImage(url, detail: .auto)
            case let .remoteURL(url, mimeType):
                guard mimeType?.hasPrefix("image/") == true,
                      let image = CodexUserInput.remoteAttachment(for: url.absoluteString, kind: .image)
                else {
                    throw LegacyHarnessProtocolBridgeError.unsupportedContent
                }
                return image
            case .inlineData:
                throw LegacyHarnessProtocolBridgeError.unsupportedContent
            }
        }
    }

    private func descriptor(for handle: HarnessSessionHandle) -> HarnessProtocolSessionDescriptor {
        HarnessProtocolSessionDescriptor(
            localSessionID: handle.localSessionID,
            providerSessionID: handle.providerSessionID,
            workspacePath: handle.workspaceURL.path(percentEncoded: false)
        )
    }

    private func toolCall(
        _ activity: HarnessActivity,
        status: HarnessProtocolToolCallStatus
    ) -> HarnessProtocolToolCall {
        var extensionValues: [String: JSONValue] = [:]
        if let outcome = activity.outcome {
            extensionValues["yardlet.compat.activityOutcome"] = .string(outcome.rawValue)
        }
        if let detail = activity.detail {
            extensionValues["yardlet.compat.activityDetail"] = .string(detail)
        }
        if let isBackground = activity.isBackground {
            extensionValues["yardlet.compat.activityBackground"] = .bool(isBackground)
        }
        if let subtask = activity.subtask {
            extensionValues["yardlet.compat.activitySubtask"] = subtask.json
        }
        if let answered = activity.answeredQuestions {
            extensionValues["yardlet.compat.activityAnsweredQuestions"] = PermissionStructureCoding.encode(answered)
        }
        if let diff = activity.diff {
            var object: [String: JSONValue] = ["path": .string(diff.path)]
            if let oldText = diff.oldText { object["oldText"] = .string(oldText) }
            if let newText = diff.newText { object["newText"] = .string(newText) }
            if let unified = diff.unified { object["unified"] = .string(unified) }
            extensionValues["yardlet.compat.activityDiff"] = .object(object)
        }
        return HarnessProtocolToolCall(
            id: activity.id,
            name: activity.kind,
            title: activity.title,
            kind: activity.kind,
            status: activity.outcome == .failed ? .failed : status,
            input: activity.input.map(JSONValue.string),
            output: activity.output.map(JSONValue.string),
            extensionValues: extensionValues
        )
    }

    private func optionCatalog(
        _ state: ProviderCapabilityState
    ) -> HarnessProtocolSessionOptionCatalog {
        HarnessProtocolSessionOptionCatalog(
            options: state.selectors.map { selector in
                HarnessProtocolSessionOption(
                    id: selector.id,
                    displayName: selector.name,
                    description: selector.description,
                    category: selector.category,
                    currentValue: selector.currentValue,
                    choices: selector.choices.map { choice in
                        HarnessProtocolSessionOptionChoice(
                            id: choice.value,
                            label: choice.name,
                            description: choice.description
                        )
                    }
                )
            },
            notes: state.notes,
            message: state.actionMessage,
            composerCommands: state.composerCommands.isEmpty ? nil : state.composerCommands
        )
    }

    private func actionCatalog(
        _ state: ProviderCapabilityState
    ) -> HarnessProtocolSessionActionCatalog {
        HarnessProtocolSessionActionCatalog(
            actions: state.actions.map { action in
                HarnessProtocolSessionAction(
                    id: action.id,
                    title: action.title,
                    description: action.description,
                    iconName: action.systemImage
                )
            },
            notes: state.notes,
            message: state.actionMessage
        )
    }

    private func codexSnapshot(
        _ state: CodexTaskState,
        localSessionID: UUID,
        handle: HarnessSessionHandle
    ) async -> HarnessProtocolCodexPresentationSnapshot {
        CodexPresentationWire.snapshot(
            state,
            localSessionID: localSessionID,
            answerableServerRequestIDs: await answerableServerRequestIDs(in: state, handle: handle)
        )
    }

    private func answerableServerRequestIDs(
        in state: CodexTaskState,
        handle: HarnessSessionHandle
    ) async -> [String] {
        guard let validator = adapter as? any CodexPendingServerRequestValidating else { return [] }
        // Only a pending request can be answerable; resolved ones accumulate over a long thread.
        let requests = state.serverRequestsByID.values
            .filter { $0.resolution == .pending }
            .map(CodexPendingServerRequest.init)
        guard !requests.isEmpty else { return [] }
        return await validator.answerablePendingServerRequestIDs(requests, for: handle).sorted()
    }

    private func codexTurnPage(_ page: CodexTurnPage) -> HarnessProtocolCodexTurnPage {
        HarnessProtocolCodexTurnPage(
            turns: page.turns.map { CodexPresentationWire.turn($0) },
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func codexItemPage(_ page: CodexItemPage) -> HarnessProtocolCodexItemPage {
        HarnessProtocolCodexItemPage(
            entries: page.entries.map { entry in
                HarnessProtocolCodexItemPageEntry(
                    turnID: entry.turnID,
                    item: CodexPresentationWire.item(entry.item)
                )
            },
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func codexThreadSummary(
        _ thread: CodexThreadSummary
    ) -> HarnessProtocolCodexThreadSummary {
        HarnessProtocolCodexThreadSummary(
            id: thread.id,
            title: thread.title,
            preview: thread.preview,
            workspacePath: thread.workspaceURL.path(percentEncoded: false),
            updatedAt: thread.updatedAt,
            forkedFromID: thread.forkedFromID,
            recencyAt: thread.recencyAt
        )
    }

    private func codexServerResponse(
        _ response: HarnessProtocolCodexServerResponse
    ) throws -> CodexServerRequestResponse {
        switch response.kind {
        case .command:
            return .command(try codexCommandDecision(response.decision))
        case .fileChange:
            guard let raw = response.decision?.stringValue,
                  let decision = CodexFileChangeApprovalDecision(rawValue: raw) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Invalid Codex file-change decision"
                )
            }
            return .fileChange(decision)
        case .permissions:
            guard let permissions = response.permissions,
                  let rawScope = response.scope,
                  let scope = CodexPermissionGrantScope(rawValue: rawScope) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Invalid Codex permission grant"
                )
            }
            return .permissions(
                permissions: permissions,
                scope: scope,
                strictAutoReview: response.strictAutoReview
            )
        case .toolUserInput:
            guard let answers = response.answers else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex tool input answers are required"
                )
            }
            return .toolUserInput(answers: answers)
        case .mcpElicitation:
            guard let rawAction = response.action,
                  let action = CodexMCPElicitationAction(rawValue: rawAction) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Invalid Codex MCP elicitation action"
                )
            }
            return .mcpElicitation(action: action, content: response.content, meta: response.meta)
        case .dynamicToolCall:
            guard let contentItems = response.contentItems,
                  let success = response.success else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex dynamic tool result is incomplete"
                )
            }
            return .dynamicToolCall(contentItems: contentItems, success: success)
        case .legacyReview:
            return .legacyReview(try codexLegacyReviewDecision(response.decision))
        }
    }

    private func codexCommandDecision(_ value: JSONValue?) throws
        -> CodexCommandApprovalDecision {
        if let raw = value?.stringValue {
            switch raw {
            case "accept": return .accept
            case "acceptForSession": return .acceptForSession
            case "decline": return .decline
            case "cancel": return .cancel
            default: break
            }
        }
        if let amendment = value?["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"]?
            .arrayValue?.compactMap(\.stringValue) {
            return .acceptWithExecpolicyAmendment(amendment)
        }
        if let policy = value?["applyNetworkPolicyAmendment"]?["network_policy_amendment"],
           let host = policy["host"]?.stringValue,
           let rawAction = policy["action"]?.stringValue,
           let action = CodexNetworkPolicyAction(rawValue: rawAction) {
            return .applyNetworkPolicyAmendment(host: host, action: action)
        }
        throw HarnessAdapterError.invalidProviderEvent("Invalid Codex command decision")
    }

    private func codexLegacyReviewDecision(_ value: JSONValue?) throws
        -> CodexLegacyReviewDecision {
        if let raw = value?.stringValue {
            switch raw {
            case "approved": return .approved
            case "approved_for_session": return .approvedForSession
            case "approved_mcp_policy_amendment": return .approvedMCPPolicyAmendment
            case "timed_out": return .timedOut
            case "abort": return .abort
            default: break
            }
        }
        let amendmentValue = value?["approved_execpolicy_amendment"]
        if let amendment = amendmentValue?["proposed_execpolicy_amendment"]?
            .arrayValue?.compactMap(\.stringValue) {
            return .approvedExecpolicyAmendment(amendment)
        }
        if let policy = value?["network_policy_amendment"]?["network_policy_amendment"],
           let host = policy["host"]?.stringValue,
           let rawAction = policy["action"]?.stringValue,
           let action = CodexNetworkPolicyAction(rawValue: rawAction) {
            return .networkPolicyAmendment(host: host, action: action)
        }
        if let rejection = value?["denied"]?["rejection"]?.stringValue {
            return .denied(rejection: rejection)
        }
        throw HarnessAdapterError.invalidProviderEvent("Invalid Codex legacy review decision")
    }

    /// The answer a permission response carries beyond its behavior. Question answers ride on
    /// `updatedInput`; a denial reason rides on `message`, which is empty for a plain deny.
    private func structuredAnswer(
        from params: HarnessProtocolPermissionResponseParams
    ) -> PermissionStructuredAnswer? {
        if let answers = PermissionStructureCoding.answers(from: params.updatedInput) {
            return .questions(answers)
        }
        guard params.behavior == .deny,
              let message = params.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return .denial(reason: message)
    }

    private func protocolPermissionActions(
        _ actions: [PermissionRequestAction]
    ) -> [HarnessProtocolPermissionAction] {
        let source = actions.isEmpty
            ? [
                PermissionRequestAction(
                    id: "allow",
                    label: "Allow",
                    decision: .allow,
                    kind: nil
                ),
                PermissionRequestAction(
                    id: "deny",
                    label: "Deny",
                    decision: .deny,
                    kind: nil
                )
            ]
            : actions
        return source.map { action in
            let role: HarnessProtocolPermissionActionRole
            switch action.kind {
            case "allow_once": role = .primary
            case "allow_always": role = .secondary
            case "reject_once", "reject_always": role = .destructive
            default: role = action.decision == .allow ? .primary : .destructive
            }
            return HarnessProtocolPermissionAction(
                id: action.id,
                label: action.label,
                behavior: action.decision == .allow ? .allow : .deny,
                role: role,
                intent: action.kind
            )
        }
    }
}

/// The live Codex presentation a bridge last sent for a patch-chain session.
private struct SentCodexPresentation: Sendable {
    let revision: UInt64
    let state: CodexTaskState
    let answerableServerRequestIDs: [String]
    /// A presentation with repeated turn or item IDs cannot be the base of a patch.
    let hasUniqueIDs: Bool
}
