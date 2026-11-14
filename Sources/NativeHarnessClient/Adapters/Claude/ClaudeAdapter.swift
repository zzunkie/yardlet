import Foundation

/// Claude Code session options the CLI reads at launch. Claude in Chrome is only a launch flag;
/// the permission mode is also changed in session, and its saved value is the mode a restarted
/// task launches in.
enum ClaudeLaunchOption {
    static let chromeIntegration = "chromeIntegration"
    static let permissionMode = "permissionMode"
    /// The model and effort a task chose, kept as the selectors' own values. The model is also a
    /// launch flag, so a task chosen before it connects starts on it.
    static let model = "model"
    static let effort = "effort"
    /// `off` for a session no one types into (a `run_agent` subagent), whose suggested next message
    /// would be a model request no one reads. Absent, Yardlet's "Next message suggestions" decides.
    static let nextMessageSuggestions = "nextMessageSuggestions"
    /// The task's title when its CLI starts, the name its other sessions see (`launchSessionName`).
    /// Never saved with the task: each launch takes the title of the moment.
    static let sessionName = "sessionName"
    /// The task's own context limit, in tokens. Absent, the task takes the one in Settings
    /// (`ClaudeContextLimitPreference`) when its CLI starts, which is the CLI's own unless the person
    /// set one. It is the task's alone: `AppModel.inheritedOptions` leaves it behind.
    static let contextLimit = "contextLimit"
    /// The limits a task, or Settings, can choose; `defaultContextLimit` is the task's without one.
    static let contextLimits: [UInt64] = [200_000, 400_000, 600_000]
    static let defaultContextLimit = "default"
    static let on = "on"
    static let off = "off"

    static func isEnabled(_ value: String?) -> Bool { value == on }

    /// The `--model` value for a saved model choice. Claude Code's own default needs no flag, and
    /// anything that could be read as another flag or argument is not passed.
    static func launchModel(_ value: String?) -> String? {
        guard let value, value != "default", !value.isEmpty, !value.hasPrefix("-"),
              value.allSatisfy({ !$0.isWhitespace && !$0.isNewline }) else { return nil }
        return value
    }

    /// The title on one line, or nil when nothing is left. The CLI drops control characters rather than
    /// turning them into spaces, and keeps the first 200 characters itself.
    static func launchSessionName(_ value: String?) -> String? {
        guard let name = value?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
              !name.isEmpty else { return nil }
        return name
    }

    /// The tokens a saved context limit stands for, or nil for anything the menu does not offer.
    static func contextLimitTokens(_ value: String?) -> UInt64? {
        value.flatMap(UInt64.init).flatMap { contextLimits.contains($0) ? $0 : nil }
    }
}

actor ClaudeAdapter:
    HarnessAdapter,
    ProviderCapabilityProviding,
    HarnessWorkspaceRootsConfiguring,
    HarnessPermissionActionResponding,
    HarnessStructuredPermissionResponding,
    HarnessLaunchOptionConfiguring,
    HarnessAgentToolConfiguring,
    HarnessYardletInstructionsConfiguring,
    HarnessMCPServerStatusReading,
    HarnessSubtaskControlling,
    HarnessSessionForkConfiguring,
    HarnessNewSessionConfiguring,
    HarnessConversationQuiescing,
    HarnessFileRewinding,
    HarnessFollowUpQueueing,
    HarnessModelCatalogReporting,
    HarnessSessionBranching,
    HarnessInterruptedTurnContinuing,
    HarnessHistoryFreeSessionConfiguring,
    HarnessIdleCompacting {
    private struct PermissionContext: Sendable {
        let localSessionID: UUID
        let originalInput: JSONValue
        /// The CLI's own "don't ask again" offer, when the request carried one the card shows.
        let suggestionOffer: ClaudePermissionSuggestionOffer?
    }

    nonisolated let kind = HarnessKind.claudeCode
    /// A fork is read from the saved conversation and launched with `--resume … --fork-session`.
    nonisolated let sessionBranchMethod: HarnessSessionBranchMethod? = .savedConversation

    private let executableURL: URL
    private let runtimeCompatibility: ClaudeRuntimeCompatibility
    private let transportFactory: @Sendable (UUID) -> any ClaudeTransport
    /// Yardlet's "Next message suggestions", read as each session's CLI starts.
    private let asksForNextMessageSuggestions: @Sendable () -> Bool
    /// The context limit a task without its own starts with (`ClaudeContextLimitPreference`).
    private let defaultContextLimit: @Sendable () -> UInt64?
    /// The account's variables the CLI starts with, besides the app's own.
    private let environmentOverrides: [String: String]
    /// Sessions launched with `nextMessageSuggestions: off`, which never ask whatever the setting.
    private var sessionsWithoutNextMessageSuggestions = Set<UUID>()

    private var nextRequestNumber: UInt64 = 1
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var transports: [UUID: any ClaudeTransport] = [:]
    private var messageTasks: [UUID: Task<Void, Never>] = [:]
    private var permissions: [String: PermissionContext] = [:]
    private var projections: [UUID: ClaudeSessionProjection] = [:]
    private var foregroundSessions: Set<UUID> = []
    private var eventChannel = HarnessEventChannel()
    private var providerStateByLocalSessionID: [UUID: ProviderCapabilityState] = [:]
    /// A mode the CLI announced before its `initialize` answer built the session's state.
    private var earlyPermissionModeByLocalSessionID: [UUID: String] = [:]
    private var earlyCommandInitByLocalSessionID: [UUID: JSONValue] = [:]
    private var additionalRootsByLocalSessionID: [UUID: [URL]] = [:]
    private var chromeIntegrationByLocalSessionID: [UUID: Bool] = [:]
    private var contextLimitByLocalSessionID: [UUID: UInt64] = [:]
    /// The permission mode a task last chose, passed at launch so a restart resumes in it.
    private var permissionModeByLocalSessionID: [UUID: String] = [:]
    /// The model a task chose, passed at launch so its first turn already runs on it.
    private var launchModelByLocalSessionID: [UUID: String] = [:]
    /// The task's title at its next launch, the CLI's session name (`ClaudeLaunchOption.sessionName`).
    private var sessionNameByLocalSessionID: [UUID: String] = [:]
    /// The model this session was last asked to run: the launch flag, then each `set_model`.
    /// Settings report the account's configured model as effective even while another runs.
    private var requestedModelByLocalSessionID: [UUID: String] = [:]
    /// Sessions launched on a task's model whose first model restore has not come yet.
    private var unrestoredLaunchModels = Set<UUID>()
    /// The latest context-usage request per session; an older answer arriving late is dropped.
    private var contextUsageRequestIDs: [UUID: String] = [:]
    /// What each session's last main request left in the prompt cache (`recordPromptCache`), and the
    /// sessions set to another model since.
    private var promptCaches: [UUID: ClaudePromptCacheState] = [:]
    private var modelChangedSinceRequest = Set<UUID>()
    private var agentToolServerByLocalSessionID: [UUID: AgentToolServerLaunch] = [:]
    private var yardletInstructionsByLocalSessionID: [UUID: String] = [:]
    /// Sessions the CLI keeps no conversation file for (`run_agent`).
    private var historyFreeSessionIDs = Set<UUID>()
    private var forkSources: [UUID: HarnessSessionForkSource] = [:]
    private var newSessionIDs: [UUID: String] = [:]
    private var initialResponses: [UUID: JSONValue] = [:]
    private var flagSettings: [UUID: JSONValue] = [:]
    private var fileRewindsInFlight = Set<UUID>()
    private var uncertainFileRewinds = Set<UUID>()
    /// Follow-ups written under a uuid that the CLI has not taken into a turn yet, in send order.
    private var unreadFollowUps: [UUID: [String]] = [:]
    /// Follow-ups being withdrawn. The CLI may report them cancelled before it answers the
    /// request, and only the answer says the withdrawal was this one.
    private var followUpsBeingCancelled = Set<String>()
    /// Sessions whose CLI has sent a `command_lifecycle` frame. One that never does reads a
    /// follow-up without saying so; its turn's end is taken as the read instead.
    private var lifecycleReportingSessions = Set<UUID>()
    /// Sessions whose CLI reports no lifecycle and was taken to have read follow-ups at its last
    /// turn's end: the next turn it starts by itself may be theirs, which they already opened.
    private var followUpsTakenAtTurnEnd = Set<UUID>()
    /// What the CLI said it supports, from `initialize` and each main `system/init`.
    private var capabilitiesByLocalSessionID: [UUID: Set<String>] = [:]
    /// Sessions whose CLI asked for next-message suggestions at `initialize`, and those of them Yardlet
    /// has paused while their task is off screen (`setUnseen`).
    private var sessionsAskingForSuggestions = Set<UUID>()
    private var pausedSuggestionSessions = Set<UUID>()
    /// Follow-ups the CLI reported `queued`: in its queue, where Send now can find them.
    private var queuedFollowUps: [UUID: Set<String>] = [:]
    /// Send now requests waiting for the CLI to report their message's first lifecycle state.
    private var followUpLifecycleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Running turns Yardlet asked the CLI to stop. The aborted turn's result ends the turn as
    /// stopped rather than failed; the next main result settles the request either way.
    private var turnStopRequests: [UUID: TurnStopRequest] = [:]

    private enum TurnStopRequest: Equatable {
        /// Stop, or a Send now the CLI answered by stopping the turn.
        case requested
        /// A Send now the CLI has not answered yet or is delivering without a stop, or a message
        /// sent with priority `now`: the CLI may still stop the turn for it. Only a result that
        /// says the turn was aborted counts.
        case possible
    }

    init(
        executableURL: URL,
        runtimeCompatibility: ClaudeRuntimeCompatibility = .restorationBaseline,
        environmentOverrides: [String: String] = [:],
        transportFactory: (@Sendable (UUID) -> any ClaudeTransport)? = nil,
        asksForNextMessageSuggestions: @escaping @Sendable () -> Bool = { NextMessageSuggestionPreference.isOn() },
        defaultContextLimit: @escaping @Sendable () -> UInt64? = { ClaudeContextLimitPreference.tokens() }
    ) {
        let executableURL = executableURL.standardizedFileURL
        self.executableURL = executableURL
        self.runtimeCompatibility = runtimeCompatibility
        self.asksForNextMessageSuggestions = asksForNextMessageSuggestions
        self.defaultContextLimit = defaultContextLimit
        self.environmentOverrides = environmentOverrides
        // Each task's CLI counts toward that task in Task Resource Usage, with everything it starts.
        self.transportFactory = transportFactory ?? { localSessionID in
            ClaudeProcessTransport(executableURL: executableURL, environmentOverrides: environmentOverrides,
                                   resourceOwner: .task(localSessionID))
        }
    }

    /// The project's other roots, applied to the next launch as `--add-dir`. The cwd is always
    /// the task's own primary folder and is never repeated here.
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
        if roots.isEmpty {
            additionalRootsByLocalSessionID.removeValue(forKey: localSessionID)
        } else {
            additionalRootsByLocalSessionID[localSessionID] = roots.map(\.standardizedFileURL)
        }
    }

    /// The session's CLI runs with `--no-session-persistence`: Claude Code writes no conversation
    /// file, so it is not in the account's history, the Claude app's list or an import. Only a
    /// session not yet attached can be kept out of history.
    func keepNoHistory(for localSessionID: UUID) -> Bool {
        guard handles[localSessionID] == nil else { return false }
        historyFreeSessionIDs.insert(localSessionID)
        return true
    }

    func setNewSessionID(_ providerSessionID: String?, for localSessionID: UUID) throws {
        guard handles[localSessionID] == nil else {
            throw HarnessAdapterError.invalidProviderEvent("Cannot change an attached session identity")
        }
        if let providerSessionID, UUID(uuidString: providerSessionID) == nil {
            throw HarnessAdapterError.invalidProviderEvent("Invalid new native session identity")
        }
        newSessionIDs[localSessionID] = providerSessionID
    }

    func setSessionForkSource(_ source: HarnessSessionForkSource?, for localSessionID: UUID) throws {
        guard handles[localSessionID] == nil else {
            throw HarnessAdapterError.invalidProviderEvent("Cannot change the origin of an attached session")
        }
        if let source {
            guard UUID(uuidString: source.providerSessionID) != nil,
                  UUID(uuidString: source.throughMessageID) != nil else {
                throw HarnessAdapterError.invalidProviderEvent("Invalid native fork boundary")
            }
        }
        forkSources[localSessionID] = source
    }

    /// Saved options the CLI reads when it starts, applied to the next launch: Claude in Chrome,
    /// the task's context limit, and the permission mode the task last chose, so a restarted task
    /// resumes in that mode rather than in Manual. The in-session settings keep going through
    /// `setProviderOption`.
    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) {
        if ClaudeLaunchOption.isEnabled(options[ClaudeLaunchOption.chromeIntegration]) {
            chromeIntegrationByLocalSessionID[localSessionID] = true
        } else {
            chromeIntegrationByLocalSessionID.removeValue(forKey: localSessionID)
        }
        contextLimitByLocalSessionID[localSessionID] =
            ClaudeLaunchOption.contextLimitTokens(options[ClaudeLaunchOption.contextLimit])
        if let mode = options[ClaudeLaunchOption.permissionMode],
           ClaudePermissionMode.selectable.contains(mode) {
            permissionModeByLocalSessionID[localSessionID] = mode
        } else {
            permissionModeByLocalSessionID.removeValue(forKey: localSessionID)
        }
        launchModelByLocalSessionID[localSessionID] = ClaudeLaunchOption.launchModel(options[ClaudeLaunchOption.model])
        sessionNameByLocalSessionID[localSessionID] = ClaudeLaunchOption.launchSessionName(options[ClaudeLaunchOption.sessionName])
        if options[ClaudeLaunchOption.nextMessageSuggestions] == ClaudeLaunchOption.off {
            sessionsWithoutNextMessageSuggestions.insert(localSessionID)
        } else {
            sessionsWithoutNextMessageSuggestions.remove(localSessionID)
        }
    }

    /// The models Claude Code listed when this session connected, with each one's effort levels.
    func advertisedModels(for localSessionID: UUID) -> [HarnessModelOption]? {
        guard let models = initialResponses[localSessionID]?["models"]?.arrayValue else { return nil }
        return models.compactMap { model in
            guard let value = model["value"]?.stringValue ?? model["id"]?.stringValue, !value.isEmpty else { return nil }
            let levels = model["supportsEffort"]?.boolValue == true
                ? model["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? [] : []
            return HarnessModelOption(value: value,
                name: model["displayName"]?.stringValue ?? model["name"]?.stringValue ?? value,
                description: model["description"]?.stringValue, effortLevels: levels,
                resolvedModel: model["resolvedModel"]?.stringValue)
        }
    }

    /// The Yardlet MCP server for the next launch, passed as `--mcp-config`.
    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) {
        agentToolServerByLocalSessionID[localSessionID] = server
    }

    /// Yardlet instructions for the next launch, passed as `--append-system-prompt`.
    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) {
        yardletInstructionsByLocalSessionID[localSessionID] = instructions?.text
    }

    /// Writes the server's config file for this launch. A file that cannot be written leaves the
    /// launch as it was rather than failing the task.
    private func agentToolConfigPath(for localSessionID: UUID) -> String? {
        guard let server = agentToolServerByLocalSessionID[localSessionID] else { return nil }
        return (try? server.writeClaudeConfig(for: localSessionID))?.path(percentEncoded: false)
    }

    /// The `--settings` document for this launch: the servers Yardlet's connectors stand in for.
    private func launchSettings(for localSessionID: UUID) -> String? {
        guard let settings = agentToolServerByLocalSessionID[localSessionID]?.claudeSettings else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) }
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        guard ExecutableLookup.current.isProgram(executableURL) else {
            throw HarnessAdapterError.runtimeNotFound(executableURL)
        }
        let versionOutput = try readVersion()
        guard runtimeCompatibility.accepts(versionOutput: versionOutput) else {
            throw HarnessAdapterError.unsupportedRuntime(version: versionOutput)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: executableURL.path(percentEncoded: false)
        )
        let fingerprint = [
            executableURL.path(percentEncoded: false),
            versionOutput,
            (attributes[.size] as? NSNumber)?.stringValue ?? "unknown-size",
            (attributes[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) }
                ?? "unknown-mtime"
        ].joined(separator: "|")

        return HarnessRuntimeDescriptor(
            harness: .claudeCode,
            executableURL: executableURL,
            version: versionOutput,
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                acceptsImages: true,
                // Task cards expose correlated read-only child logs and task-specific stop.
                // Independent child-session discovery/resume/input is not the stream-json
                // timeline.subagents contract, so that broader capability remains withheld.
                hasSubagents: false
            ),
            fingerprint: fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let providerSessionID = UUID().uuidString.lowercased()
        let handle = HarnessSessionHandle(
            harness: .claudeCode,
            localSessionID: request.localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: request.workspaceURL.standardizedFileURL
        )
        try await attach(handle, resumesExistingSession: false)
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
        let handle = HarnessSessionHandle(
            harness: .claudeCode,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL.standardizedFileURL
        )
        try await attach(handle, resumesExistingSession: true)
        return handle
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        guard !fileRewindsInFlight.contains(session.localSessionID), !uncertainFileRewinds.contains(session.localSessionID) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is still running."))
        }
        try ClaudeComposerCommands.validateSubmission(
            prompt, commands: providerStateByLocalSessionID[session.localSessionID]?.composerCommands ?? []
        )
        let transport = try transport(for: session)
        try await transport.send(
            ClaudeProtocol.userMessage(prompt, sessionID: session.providerSessionID)
        )
        foregroundSessions.insert(session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    /// stream-json carries an image as a base64 `image` block beside the text block, so the
    /// composer's attachment reaches Claude Code as an attachment rather than as a path.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        guard !fileRewindsInFlight.contains(session.localSessionID), !uncertainFileRewinds.contains(session.localSessionID) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is still running."))
        }
        try ClaudeComposerCommands.validateSubmission(
            input.promptText, commands: providerStateByLocalSessionID[session.localSessionID]?.composerCommands ?? []
        )
        let transport = try transport(for: session)
        try await transport.send(
            ClaudeProtocol.userMessage(
                text: input.promptText,
                images: try input.encodedImages(),
                sessionID: session.providerSessionID
            )
        )
        foregroundSessions.insert(session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    /// Writes the Claude app's continuation for the cut into the resumed conversation. The CLI itself
    /// closes the cut-off tool calls on resume (an unanswered call reads as "[Tool call interrupted: …]"),
    /// so whether the turn had ended is the model's to judge, as it is in the Claude app.
    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool {
        guard !fileRewindsInFlight.contains(session.localSessionID), !uncertainFileRewinds.contains(session.localSessionID) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is still running."))
        }
        let transport = try transport(for: session)
        try await transport.send(ClaudeProtocol.restartContinuation(sessionID: session.providerSessionID, after: cut))
        foregroundSessions.insert(session.localSessionID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        return true
    }

    /// Writes a message the CLI queues while its turn runs. It is read at the turn's next step
    /// (`next`) or stops the turn (`now`), and the CLI's `command_lifecycle` frames say when, so
    /// the session's running state is left to them rather than set here.
    func sendFollowUp(
        _ input: HarnessUserInput,
        messageID: String,
        priority: HarnessFollowUpPriority,
        to session: HarnessSessionHandle
    ) async throws {
        guard UUID(uuidString: messageID) != nil else {
            throw HarnessAdapterError.invalidProviderEvent("Invalid queued message identity")
        }
        guard !fileRewindsInFlight.contains(session.localSessionID), !uncertainFileRewinds.contains(session.localSessionID) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is still running."))
        }
        try ClaudeComposerCommands.validateSubmission(
            input.promptText, commands: providerStateByLocalSessionID[session.localSessionID]?.composerCommands ?? []
        )
        let transport = try transport(for: session)
        let message = ClaudeProtocol.userMessage(
            text: input.promptText,
            images: try input.encodedImages(),
            sessionID: session.providerSessionID,
            uuid: messageID,
            priority: priority
        )
        // Known before the write: the CLI can take it before the write returns.
        unreadFollowUps[session.localSessionID, default: []].append(messageID)
        // A message sent with priority `now` stops the running turn at its next step.
        let mayStopTurn = priority == .now && markPossibleTurnStop(in: session.localSessionID)
        do {
            try await transport.send(message)
        } catch {
            unreadFollowUps[session.localSessionID]?.removeAll { $0 == messageID }
            if mayStopTurn { withdrawPossibleTurnStop(in: session.localSessionID) }
            throw error
        }
    }

    func cancelFollowUp(messageID: String, in session: HarnessSessionHandle) async throws -> Bool {
        let transport = try transport(for: session)
        guard unreadFollowUps[session.localSessionID]?.contains(messageID) == true,
              followUpsBeingCancelled.insert(messageID).inserted else { return false }
        defer { followUpsBeingCancelled.remove(messageID) }
        let requestID = takeRequestID(prefix: "cancel-message")
        let response = try await transport.request(
            ClaudeProtocol.cancelAsyncMessage(id: requestID, messageUUID: messageID), id: requestID
        )
        guard response["cancelled"]?.boolValue == true else { return false }
        unreadFollowUps[session.localSessionID]?.removeAll { $0 == messageID }
        queuedFollowUps[session.localSessionID]?.remove(messageID)
        return true
    }

    func canSendFollowUpNow(in session: HarnessSessionHandle) -> Bool {
        handles[session.localSessionID] == session
            && capabilitiesByLocalSessionID[session.localSessionID]?.contains(ClaudeProtocol.sendNowCapability) == true
    }

    /// Send now as the CLI defines it (`interrupt` with `send_now` and the message's uuid): the CLI
    /// moves a running command to the background so the running turn reads the message at once,
    /// or stops the turn when it cannot, and answers which. The message must already be in its
    /// queue, or the request finds nothing, so one just written is pressed once the CLI reports it
    /// queued (or after a short wait for a CLI that is slow to say so).
    func sendFollowUpNow(messageID: String, in session: HarnessSessionHandle) async throws -> HarnessFollowUpSendNow? {
        let transport = try transport(for: session)
        guard canSendFollowUpNow(in: session) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Claude Code cannot send this message now."))
        }
        let localSessionID = session.localSessionID
        guard unreadFollowUps[localSessionID]?.contains(messageID) == true else { return .nothingWaiting }
        if queuedFollowUps[localSessionID]?.contains(messageID) != true {
            await waitForFollowUpLifecycle(messageID, timeout: .seconds(2))
            guard unreadFollowUps[localSessionID]?.contains(messageID) == true else { return .nothingWaiting }
        }
        let requestID = takeRequestID(prefix: "send-now")
        // Marked before the request: a turn the CLI stops for the message writes its result after
        // the answer, but that result can reach this actor first.
        let mayStopTurn = markPossibleTurnStop(in: localSessionID)
        let response: JSONValue
        do {
            response = try await transport.request(
                ClaudeProtocol.sendNow(id: requestID, messageUUID: messageID), id: requestID
            )
        } catch {
            if mayStopTurn { withdrawPossibleTurnStop(in: localSessionID) }
            throw error
        }
        let answer = response["send_now"]?.stringValue.flatMap(HarnessFollowUpSendNow.init(rawValue:))
        switch answer {
        case .stopped?:
            // The CLI aborted the turn for the message. A result already read settled the mark.
            if turnStopRequests[localSessionID] != nil { turnStopRequests[localSessionID] = .requested }
        case .nothingWaiting?:
            if mayStopTurn { withdrawPossibleTurnStop(in: localSessionID) }
        case .delivering?, nil:
            // Nothing stopped yet; the CLI may still stop the turn if moving its command fails.
            break
        }
        return answer
    }

    /// Notes that the CLI may stop the running turn for a message Yardlet sent. False when no turn
    /// is running, or one is already being stopped.
    private func markPossibleTurnStop(in localSessionID: UUID) -> Bool {
        guard foregroundSessions.contains(localSessionID), turnStopRequests[localSessionID] == nil else { return false }
        turnStopRequests[localSessionID] = .possible
        return true
    }

    private func withdrawPossibleTurnStop(in localSessionID: UUID) {
        if turnStopRequests[localSessionID] == .possible { turnStopRequests.removeValue(forKey: localSessionID) }
    }

    private func waitForFollowUpLifecycle(_ messageID: String, timeout: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resumeFollowUpLifecycleWaiters(for: messageID)
        }
        defer { timer.cancel() }
        await withCheckedContinuation { continuation in
            followUpLifecycleWaiters[messageID, default: []].append(continuation)
        }
    }

    private func resumeFollowUpLifecycleWaiters(for messageID: String) {
        for waiter in followUpLifecycleWaiters.removeValue(forKey: messageID) ?? [] { waiter.resume() }
    }

    /// Stop. The CLI aborts the running turn and still ends it with a result, as an error; that
    /// result ends the turn as stopped. It is marked before the request, since the CLI can write
    /// the result before its answer reaches this actor.
    func interrupt(_ session: HarnessSessionHandle) async throws {
        let transport = try transport(for: session)
        let localSessionID = session.localSessionID
        let stopsRunningTurn = foregroundSessions.contains(localSessionID)
        let earlier = turnStopRequests[localSessionID]
        if stopsRunningTurn { turnStopRequests[localSessionID] = .requested }
        let requestID = takeRequestID(prefix: "interrupt")
        do {
            _ = try await transport.request(ClaudeProtocol.interrupt(id: requestID), id: requestID)
        } catch {
            if stopsRunningTurn, turnStopRequests[localSessionID] == .requested {
                turnStopRequests[localSessionID] = earlier
            }
            throw error
        }
    }

    func requireReadyForRewind(in session: HarnessSessionHandle) throws {
        _ = try transport(for: session)
        guard !foregroundSessions.contains(session.localSessionID),
              !fileRewindsInFlight.contains(session.localSessionID),
              !uncertainFileRewinds.contains(session.localSessionID),
              projections[session.localSessionID]?.hasLiveTasks != true,
              !permissions.values.contains(where: { $0.localSessionID == session.localSessionID }) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop active work before rewinding this conversation."))
        }
    }

    func previewFileRewind(userMessageID: String, in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        try requireReadyForRewind(in: session)
        return try await fileRewind(userMessageID: userMessageID, dryRun: true, in: session)
    }

    func restoreFiles(userMessageID: String, expecting preview: HarnessFileRewindResult,
        in session: HarnessSessionHandle, authorizing: HarnessFileRestoreAuthorization? = nil) async throws -> HarnessFileRewindResult {
        try requireReadyForRewind(in: session)
        guard preview.canRewind, preview.filesChanged != nil,
              fileRewindsInFlight.insert(session.localSessionID).inserted else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is unavailable."))
        }
        defer { fileRewindsInFlight.remove(session.localSessionID) }
        let fresh = try await fileRewind(userMessageID: userMessageID, dryRun: true, in: session)
        guard fresh == preview else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The file changes have changed. Review them again."))
        }
        // The fresh dry run suspended. A remote device may have lost permission or disconnected meanwhile.
        // Check before the dispatch, outside the uncertain-write catch: refusal has not sent a mutation.
        try authorizing?()
        do {
            let result = try await fileRewind(userMessageID: userMessageID, dryRun: false, in: session)
            if result.inFlight == true { uncertainFileRewinds.insert(session.localSessionID) }
            return result
        } catch {
            // The CLI may already be writing. Reconnect before permitting another mutation.
            uncertainFileRewinds.insert(session.localSessionID)
            throw error
        }
    }

    private func fileRewind(userMessageID: String, dryRun: Bool,
        in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        guard UUID(uuidString: userMessageID) != nil else {
            throw HarnessAdapterError.invalidProviderEvent("Invalid file checkpoint identity")
        }
        let transport = try transport(for: session)
        let id = takeRequestID(prefix: "rewind-files")
        let response = try await transport.request(ClaudeProtocol.rewindFiles(
            id: id, userMessageID: userMessageID, dryRun: dryRun), id: id)
        let decoded = try JSONDecoder().decode(HarnessFileRewindResult.self, from: JSONEncoder().encode(response))
        guard decoded.filesChanged?.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) != false,
              [decoded.insertions, decoded.deletions, decoded.skippedLinks].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw HarnessAdapterError.invalidProviderEvent("Invalid file rewind result")
        }
        return decoded
    }

    func stopSubtask(activityID: String, in session: HarnessSessionHandle) async throws {
        guard handles[session.localSessionID] == session,
              let taskID = projections[session.localSessionID]?.activeTaskID(for: activityID) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This task is no longer running."))
        }
        let transport = try transport(for: session)
        let requestID = takeRequestID(prefix: "stop-task")
        _ = try await transport.request(ClaudeProtocol.stopTask(id: requestID, taskID: taskID), id: requestID)
        // Acknowledgement is not a terminal event. The CLI's task notification/patch owns the
        // card outcome; stopping a child must not complete or interrupt its parent's turn.
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        let context = try permissionContext(permissionRequestID, in: session)
        try await send(
            ClaudeProtocol.permissionResponse(
                requestID: permissionRequestID,
                decision: decision,
                originalInput: context.originalInput
            ),
            resolving: permissionRequestID,
            in: session
        )
    }

    /// Answers with one of the card's choices. Allow and deny are the plain answers; the offer's
    /// own choice allows and returns the CLI's suggestions as `updatedPermissions`, which is how
    /// Claude Code applies them. The plain ids are also what the YHP route sends for a request
    /// that listed no choices, so they are accepted for every request.
    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws {
        let context = try permissionContext(permissionRequestID, in: session)
        switch selectedActionID {
        case ClaudePermissionSuggestions.ActionID.allow:
            try await respond(to: permissionRequestID, decision: .allow, in: session)
        case ClaudePermissionSuggestions.ActionID.deny:
            try await respond(to: permissionRequestID, decision: .deny, in: session)
        case let id where id == context.suggestionOffer?.action.id:
            try await send(
                ClaudeProtocol.permissionResponse(
                    requestID: permissionRequestID,
                    decision: .allow,
                    originalInput: context.originalInput,
                    updatedPermissions: context.suggestionOffer?.updates
                ),
                resolving: permissionRequestID,
                in: session
            )
        default:
            throw HarnessAdapterError.invalidProviderEvent(
                "Claude permission request \(permissionRequestID) has no action \(selectedActionID)"
            )
        }
    }

    /// Answers a request whose provider asked a question or submitted a plan. Question answers
    /// travel as the allow branch's `updatedInput`; a declined plan carries the reason the user
    /// wrote as the deny message, which is where Claude Code reads it from.
    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: HarnessSessionHandle
    ) async throws {
        let context = try permissionContext(permissionRequestID, in: session)
        let value: JSONValue = switch answer {
        case let .questions(answers):
            ClaudeProtocol.permissionResponse(
                requestID: permissionRequestID,
                decision: .allow,
                originalInput: context.originalInput,
                answers: answers
            )
        case let .denial(reason):
            ClaudeProtocol.permissionResponse(
                requestID: permissionRequestID,
                decision: .deny,
                originalInput: context.originalInput,
                denialMessage: reason
            )
        }
        try await send(value, resolving: permissionRequestID, in: session)
    }

    private func permissionContext(
        _ permissionRequestID: String,
        in session: HarnessSessionHandle
    ) throws -> PermissionContext {
        _ = try transport(for: session)
        guard let context = permissions[permissionRequestID],
              context.localSessionID == session.localSessionID else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Unknown or already-resolved Claude permission request"
            )
        }
        return context
    }

    private func send(
        _ value: JSONValue,
        resolving permissionRequestID: String,
        in session: HarnessSessionHandle
    ) async throws {
        let transport = try transport(for: session)
        try await transport.send(value)
        permissions.removeValue(forKey: permissionRequestID)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        eventChannel.subscribe(to: session.localSessionID)
    }

    func providerCapabilities(for session: HarnessSessionHandle) async throws
        -> ProviderCapabilityState {
        _ = try transport(for: session)
        await refreshFlagSelectors(in: session)
        return providerStateByLocalSessionID[session.localSessionID]
            ?? claudeCapabilityState(
                initializeResponse: .object([:]),
                chromeIntegration: chromeIntegrationByLocalSessionID[session.localSessionID] ?? false
            )
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let transport = try transport(for: session)
        let requestID = takeRequestID(prefix: "config")
        var appliesAtNextStart = false
        switch id {
        case "effort", "fastMode":
            let selector = providerStateByLocalSessionID[session.localSessionID]?.selectors.first(where: { $0.id == id })
            // A model that takes no effort has none to reset, so its default is already in place.
            if selector == nil, id == "effort", value == "default" {
                return providerStateByLocalSessionID[session.localSessionID]
                    ?? claudeCapabilityState(initializeResponse: .object([:]),
                        chromeIntegration: chromeIntegrationByLocalSessionID[session.localSessionID] ?? false)
            }
            guard let selector, selector.choices.contains(where: { $0.value == value }) else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("Claude Code does not expose that setting"))
            }
            let settings: JSONValue = id == "effort"
                ? .object(["effortLevel": value == "default" ? .null : .string(value)])
                : .object(["fastMode": .bool(value == "on")])
            _ = try await transport.request(ClaudeProtocol.flagSettings(id: requestID, settings: settings), id: requestID)
            guard await refreshFlagSelectors(in: session) else {
                throw HarnessAdapterError.invalidProviderEvent("Claude settings were applied but their current values could not be read")
            }
        case "model":
            // Restoring the model a task just launched on asks nothing: it is already running it.
            let launchedOnIt = unrestoredLaunchModels.remove(session.localSessionID) != nil
                && requestedModelByLocalSessionID[session.localSessionID] == value
            if !launchedOnIt {
                _ = try await transport.request(
                    ClaudeProtocol.setModel(id: requestID, model: value), id: requestID
                )
                if requestedModelByLocalSessionID[session.localSessionID] != value {
                    modelChangedSinceRequest.insert(session.localSessionID)
                }
                requestedModelByLocalSessionID[session.localSessionID] = value
            }
        case ClaudeLaunchOption.permissionMode:
            // Only the selector's modes are set, so none other is ever kept with the task.
            guard ClaudePermissionMode.selectable.contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("Claude Code does not expose that setting"))
            }
            // A restored task already launched in its saved mode; asking again changes nothing.
            let current = providerStateByLocalSessionID[session.localSessionID]?.selectors
                .first { $0.id == id }?.currentValue
            if current != value {
                _ = try await transport.request(
                    ClaudeProtocol.setPermissionMode(id: requestID, mode: value), id: requestID
                )
            }
        case ClaudeLaunchOption.chromeIntegration:
            // The CLI reads `--chrome` at launch, so the running process keeps the integration it
            // started with and the saved choice takes effect when this task next starts or resumes.
            // Restoring the value this session already launched with changes nothing to announce.
            let requested = ClaudeLaunchOption.isEnabled(value)
            appliesAtNextStart =
                requested != (chromeIntegrationByLocalSessionID[session.localSessionID] ?? false)
            chromeIntegrationByLocalSessionID[session.localSessionID] = requested
        case ClaudeLaunchOption.contextLimit:
            // Saved options are restored here after a launch, which already took this one.
            return providerStateByLocalSessionID[session.localSessionID]
                ?? claudeCapabilityState(initializeResponse: .object([:]),
                    chromeIntegration: chromeIntegrationByLocalSessionID[session.localSessionID] ?? false)
        default:
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Claude Code does not expose that setting")
            )
        }
        var state = providerStateByLocalSessionID[session.localSessionID]
            ?? claudeCapabilityState(
                initializeResponse: .object([:]),
                chromeIntegration: chromeIntegrationByLocalSessionID[session.localSessionID] ?? false
            )
        if id == "model" {
            showRequestedModel(value, in: &state, for: session.localSessionID)
        } else if let index = state.selectors.firstIndex(where: { $0.id == id }) {
            if id != "effort", id != "fastMode" { state.selectors[index].currentValue = value }
        }
        state.actionMessage = appliesAtNextStart
            ? L10n.string("Claude Code applies this setting the next time the task starts")
            : L10n.string("Claude Code session setting updated")
        providerStateByLocalSessionID[session.localSessionID] = state
        if id == "model" { await refreshFlagSelectors(in: session) }
        return providerStateByLocalSessionID[session.localSessionID] ?? state
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        _ = try transport(for: session)
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.string("Claude Code does not expose that action in this session protocol")
        )
    }

    /// The session's MCP servers as `mcp_status` reports them now; the composer shows them too.
    func mcpServers(for session: HarnessSessionHandle) async throws -> [HarnessMCPServerStatus] {
        let transport = try transport(for: session)
        let requestID = takeRequestID(prefix: "mcp")
        let response = try await transport.request(ClaudeMCPServers.mcpStatusRequest(id: requestID), id: requestID)
        guard let servers = ClaudeMCPServers.fromStatus(response) else {
            throw HarnessAdapterError.invalidProviderEvent("Claude mcp_status answered without servers")
        }
        acceptMCPServers(servers, for: session)
        return servers
    }

    func reportedMCPServers(for localSessionID: UUID) async -> [HarnessMCPServerStatus]? {
        providerStateByLocalSessionID[localSessionID]?.mcpServers
    }

    func close(_ session: HarnessSessionHandle) async {
        handles.removeValue(forKey: session.localSessionID)
        messageTasks.removeValue(forKey: session.localSessionID)?.cancel()
        if let transport = transports.removeValue(forKey: session.localSessionID) {
            await transport.stop()
        }
        permissions = permissions.filter { $0.value.localSessionID != session.localSessionID }
        projections.removeValue(forKey: session.localSessionID)
        promptCaches.removeValue(forKey: session.localSessionID)
        modelChangedSinceRequest.remove(session.localSessionID)
        foregroundSessions.remove(session.localSessionID)
        providerStateByLocalSessionID.removeValue(forKey: session.localSessionID)
        earlyPermissionModeByLocalSessionID.removeValue(forKey: session.localSessionID)
        earlyCommandInitByLocalSessionID.removeValue(forKey: session.localSessionID)
        additionalRootsByLocalSessionID.removeValue(forKey: session.localSessionID)
        chromeIntegrationByLocalSessionID.removeValue(forKey: session.localSessionID)
        contextLimitByLocalSessionID.removeValue(forKey: session.localSessionID)
        permissionModeByLocalSessionID.removeValue(forKey: session.localSessionID)
        launchModelByLocalSessionID.removeValue(forKey: session.localSessionID)
        sessionNameByLocalSessionID.removeValue(forKey: session.localSessionID)
        requestedModelByLocalSessionID.removeValue(forKey: session.localSessionID)
        unrestoredLaunchModels.remove(session.localSessionID)
        contextUsageRequestIDs.removeValue(forKey: session.localSessionID)
        agentToolServerByLocalSessionID.removeValue(forKey: session.localSessionID)
        yardletInstructionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        historyFreeSessionIDs.remove(session.localSessionID)
        sessionsAskingForSuggestions.remove(session.localSessionID)
        pausedSuggestionSessions.remove(session.localSessionID)
        forkSources.removeValue(forKey: session.localSessionID)
        newSessionIDs.removeValue(forKey: session.localSessionID)
        initialResponses.removeValue(forKey: session.localSessionID)
        flagSettings.removeValue(forKey: session.localSessionID)
        fileRewindsInFlight.remove(session.localSessionID)
        uncertainFileRewinds.remove(session.localSessionID)
        for messageID in unreadFollowUps.removeValue(forKey: session.localSessionID) ?? [] {
            resumeFollowUpLifecycleWaiters(for: messageID)
        }
        lifecycleReportingSessions.remove(session.localSessionID)
        followUpsTakenAtTurnEnd.remove(session.localSessionID)
        capabilitiesByLocalSessionID.removeValue(forKey: session.localSessionID)
        queuedFollowUps.removeValue(forKey: session.localSessionID)
        turnStopRequests.removeValue(forKey: session.localSessionID)
        eventChannel.close(session.localSessionID)
    }

    private func attach(
        _ handle: HarnessSessionHandle,
        resumesExistingSession: Bool
    ) async throws {
        guard handles[handle.localSessionID] == nil else {
            throw HarnessAdapterError.invalidProviderEvent("Claude session is already attached")
        }
        guard forkSources[handle.localSessionID]?.providerSessionID != handle.providerSessionID else {
            throw HarnessAdapterError.invalidProviderEvent("A native fork must have a new session identity")
        }
        if let planned = newSessionIDs[handle.localSessionID] {
            guard planned == handle.providerSessionID, forkSources[handle.localSessionID] == nil else {
                throw HarnessAdapterError.invalidProviderEvent("The new native session identity has changed")
            }
        }
        let transport = transportFactory(handle.localSessionID)
        handles[handle.localSessionID] = handle
        transports[handle.localSessionID] = transport

        do {
            try await transport.start(
                ClaudeLaunchConfiguration(
                    providerSessionID: handle.providerSessionID,
                    workspaceURL: handle.workspaceURL,
                    resumesExistingSession: resumesExistingSession && newSessionIDs[handle.localSessionID] == nil,
                    additionalRoots: additionalRootsByLocalSessionID[handle.localSessionID] ?? [],
                    chromeIntegration: chromeIntegrationByLocalSessionID[handle.localSessionID] ?? false,
                    contextLimit: contextLimitByLocalSessionID[handle.localSessionID] ?? defaultContextLimit(),
                    sessionName: sessionNameByLocalSessionID[handle.localSessionID],
                    agentToolConfigPath: agentToolConfigPath(for: handle.localSessionID),
                    forkSource: forkSources[handle.localSessionID],
                    permissionMode: permissionModeByLocalSessionID[handle.localSessionID],
                    model: launchModelByLocalSessionID[handle.localSessionID],
                    keepsNoHistory: historyFreeSessionIDs.contains(handle.localSessionID),
                    appendSystemPrompt: yardletInstructionsByLocalSessionID[handle.localSessionID],
                    settings: launchSettings(for: handle.localSessionID)
                )
            )
            requestedModelByLocalSessionID[handle.localSessionID] = launchModelByLocalSessionID[handle.localSessionID]
            if launchModelByLocalSessionID[handle.localSessionID] != nil {
                unrestoredLaunchModels.insert(handle.localSessionID)
            } else {
                unrestoredLaunchModels.remove(handle.localSessionID)
            }
            let stream = await transport.messages()
            messageTasks[handle.localSessionID] = Task { [weak self] in
                for await frame in stream {
                    guard !Task.isCancelled else { break }
                    await self?.accept(frame, for: handle.localSessionID)
                }
                guard !Task.isCancelled else { return }
                await self?.transportStreamEnded(for: handle.localSessionID)
            }
            let requestID = takeRequestID(prefix: "initialize")
            let asksForSuggestions = !sessionsWithoutNextMessageSuggestions.contains(handle.localSessionID)
                && asksForNextMessageSuggestions()
            let response = try await transport.request(
                ClaudeProtocol.initialize(id: requestID, promptSuggestions: asksForSuggestions),
                id: requestID
            )
            guard response.objectValue != nil else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Claude initialize response must be an object"
                )
            }
            initialResponses[handle.localSessionID] = response
            // A new process suggests until it is paused.
            pausedSuggestionSessions.remove(handle.localSessionID)
            if asksForSuggestions {
                sessionsAskingForSuggestions.insert(handle.localSessionID)
            } else {
                sessionsAskingForSuggestions.remove(handle.localSessionID)
            }
            // The members already settled at connect time; the rest arrive on `system/init`.
            if let settled = response["capabilities"]?.arrayValue {
                capabilitiesByLocalSessionID[handle.localSessionID, default: []]
                    .formUnion(settled.compactMap(\.stringValue))
            }
            providerStateByLocalSessionID[handle.localSessionID] = claudeCapabilityState(
                initializeResponse: response,
                chromeIntegration: chromeIntegrationByLocalSessionID[handle.localSessionID] ?? false,
                // A resumed session can come back in the mode it was left in, which the CLI
                // may announce before it answers the handshake.
                permissionMode: earlyPermissionModeByLocalSessionID
                    .removeValue(forKey: handle.localSessionID)
            )
            _ = await refreshFlagSelectors(in: handle)
            if let frame = earlyCommandInitByLocalSessionID.removeValue(forKey: handle.localSessionID) {
                acceptComposerCommands(frame, for: handle.localSessionID)
            }
            emit(.sessionStarted(handle), for: handle.localSessionID)
            emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
            // A resumed conversation already fills part of its window.
            if resumesExistingSession { refreshContextUsage(for: handle.localSessionID) }
        } catch {
            handles.removeValue(forKey: handle.localSessionID)
            transports.removeValue(forKey: handle.localSessionID)
            projections.removeValue(forKey: handle.localSessionID)
            earlyPermissionModeByLocalSessionID.removeValue(forKey: handle.localSessionID)
            earlyCommandInitByLocalSessionID.removeValue(forKey: handle.localSessionID)
            messageTasks.removeValue(forKey: handle.localSessionID)?.cancel()
            await transport.stop()
            throw error
        }
    }

    private func accept(_ frame: ClaudeRawFrame, for localSessionID: UUID) async {
        let value = frame.value
        if value["type"]?.stringValue == "control_cancel_request",
           let requestID = value["request_id"]?.stringValue,
           permissions[requestID]?.localSessionID == localSessionID {
            permissions.removeValue(forKey: requestID)
            emit(.permissionExpired(requestID), for: localSessionID, rawData: frame.data)
            let status: SessionStatus = permissions.values.contains { $0.localSessionID == localSessionID }
                ? .waitingForApproval : foregroundSessions.contains(localSessionID) ? .running : .ready
            emit(.sessionStatusChanged(status), for: localSessionID, rawData: frame.data)
            return
        }
        if let lifecycle = ClaudeProtocol.commandLifecycle(in: value) {
            acceptCommandLifecycle(messageID: lifecycle.messageID, state: lifecycle.state,
                                   for: localSessionID, rawData: frame.data)
            return
        }
        // A turn the CLI starts by itself with no lifecycle frame opens here: its answer to a
        // background task's notice, which it queues under no uuid (2.1.299 sends
        // `system/task_notification`, `system/init` and the answer, with no `command_lifecycle` and
        // no `user` frame, even with `--replay-user-messages`). What Claude answered before stays
        // that turn's answer, and the turn is running until its result. A CLI that reports no
        // lifecycle may instead be starting the turn of a follow-up it was handed, already open.
        if !foregroundSessions.contains(localSessionID), ClaudeProtocol.startsMainResponse(value) {
            foregroundSessions.insert(localSessionID)
            if followUpsTakenAtTurnEnd.remove(localSessionID) == nil {
                emit(.providerStartedTurn(messageID: nil), for: localSessionID, rawData: frame.data)
            }
            emit(.sessionStatusChanged(.running), for: localSessionID)
        }
        if value["type"]?.stringValue == "system", value["subtype"]?.stringValue == "init",
           value["parent_tool_use_id"]?.stringValue?.isEmpty != false {
            acceptComposerCommands(value, for: localSessionID)
            if let capabilities = ClaudeProtocol.initCapabilities(in: value) {
                capabilitiesByLocalSessionID[localSessionID, default: []].formUnion(capabilities)
            }
        }
        if value["type"]?.stringValue == "control_request",
           value["request"]?["subtype"]?.stringValue == "can_use_tool",
           let requestID = value["request_id"]?.stringValue {
            let request = value["request"] ?? .object([:])
            let input = request["input"] ?? .object([:])
            let structured = ClaudeProtocol.structure(
                toolName: request["tool_name"]?.stringValue,
                input: input
            )
            // A question or a plan is answered on its own card, which has no approval scope to
            // choose, so only a plain tool request shows the CLI's "don't ask again" offer.
            let isAnswerableTool = request["tool_name"]?.stringValue
                .map(ClaudeAnswerableTool.names.contains) ?? false
            // A scheduled-task change, and a Google write (a Gmail send, draft deletion, or label
            // change, a Calendar event, a Drive file), is asked each time, with no "always allow", as
            // the Claude app asks before its own (`ScheduleToolApproval`, `GoogleToolApproval`). A
            // mail draft to send (or a Gmail draft to delete) is read first, so its card shows what
            // it holds; the session's later frames wait for it.
            let toolName = request["tool_name"]?.stringValue
            var mailDraft: MailDraftPreview?
            if GmailToolApproval.readsDraft(toolName: toolName) {
                mailDraft = await GmailToolApproval.draft(toolName: toolName, input: input)
            }
            let schedule = ScheduleToolApproval.request(toolName: toolName, input: input)
                ?? GoogleToolApproval.request(toolName: toolName, input: input, mailDraft: mailDraft)
            let suggestionOffer = structured == nil && !isAnswerableTool && schedule == nil
                ? ClaudePermissionSuggestions.offer(from: request)
                : nil
            permissions[requestID] = PermissionContext(
                localSessionID: localSessionID,
                originalInput: input,
                suggestionOffer: suggestionOffer
            )
            emit(
                .permissionRequested(
                    PermissionRequest(
                        id: requestID,
                        title: schedule?.title
                            ?? request["title"]?.stringValue
                            ?? request["display_name"]?.stringValue
                            ?? "Use \(request["tool_name"]?.stringValue ?? "Claude tool")",
                        detail: schedule?.detail
                            ?? request["description"]?.stringValue
                            ?? request["decision_reason"]?.stringValue
                            // A question call carries the provider's own heading on its input.
                            ?? questionHeading(for: structured, input: input),
                        command: input["command"]?.stringValue,
                        actions: suggestionOffer.map(ClaudePermissionSuggestions.actions) ?? [],
                        structured: structured,
                        toolCallID: request["tool_use_id"]?.stringValue,
                        preview: structured == nil
                            ? ClaudeProtocol.preview(toolName: request["tool_name"]?.stringValue, input: input)
                            : nil,
                        // A question or plan is answered on its card even when its content could
                        // not be read, and a call a safety check holds is approved there by hand.
                        requiresInAppAnswer: isAnswerableTool
                            || request["classifier_approvable"]?.boolValue == false
                    )
                ),
                for: localSessionID,
                rawData: frame.data
            )
            emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
            return
        }

        // The same status frame can also report a compaction, which the projection reads.
        if let mode = ClaudeProtocol.announcedPermissionMode(in: value) {
            acceptAnnouncedPermissionMode(mode, for: localSessionID, rawData: frame.data)
        }

        recordPromptCache(from: value, for: localSessionID)
        let endsMainTurn = value["type"]?.stringValue == "result"
            && value["parent_tool_use_id"]?.stringValue?.isEmpty != false
        // The results the CLI writes after a Stop Yardlet sent, for the calls the stop ended.
        let endsCallsByStop = value["type"]?.stringValue == "user" && turnStopRequests[localSessionID] == .requested
        // A turn Yardlet asked the CLI to stop still ends with an error result. It ends here as
        // stopped: no error card, the text it streamed stays, and the task is ready again.
        let stoppedByRequest = endsMainTurn && turnStopRequests.removeValue(forKey: localSessionID).map {
            ClaudeProtocol.endsAbortedTurn(value, allowingUnstatedReason: $0 == .requested)
        } == true
        let payloads = projections[localSessionID, default: ClaudeSessionProjection()].payloads(from: value)
        if stoppedByRequest { emit(.turnStopped, for: localSessionID, rawData: frame.data) }
        for payload in payloads {
            if stoppedByRequest {
                if case .error = payload { continue }
                if case .usageLimitReached = payload { continue }
            }
            emit(endsCallsByStop ? ClaudeProtocol.endedByStop(payload) : payload, for: localSessionID, rawData: frame.data)
        }
        if endsMainTurn {
            foregroundSessions.remove(localSessionID)
            followUpsTakenAtTurnEnd.remove(localSessionID)
            if !lifecycleReportingSessions.contains(localSessionID) {
                // A CLI that reports no lifecycle has read what it was sent by the end of the
                // turn, or starts the next turn with it. Either way it sits here in the chat.
                let taken = unreadFollowUps.removeValue(forKey: localSessionID) ?? []
                for messageID in taken {
                    emit(.followUpDelivery(.init(messageID: messageID, state: .read)), for: localSessionID)
                }
                if !taken.isEmpty { followUpsTakenAtTurnEnd.insert(localSessionID) }
            }
            let status: SessionStatus = value["is_error"]?.boolValue == true && !stoppedByRequest ? .failed : .ready
            // A turn the CLI ended on its own connection error says so before it ends.
            if !stoppedByRequest, let cut = ClaudeProtocol.turnCut(ofResult: value) {
                emit(.turnCutOff(cut), for: localSessionID, rawData: frame.data)
            }
            emit(.sessionStatusChanged(status), for: localSessionID, rawData: frame.data)
            refreshContextUsage(for: localSessionID)
            refreshMCPServerStatus(for: localSessionID)
        }
    }

    /// After a turn, `mcp_status` reports the servers that finished connecting since its
    /// `system/init`, from the CLI's own connections and without a turn; a CLI that does not answer
    /// leaves the list `system/init` gave. Before the first turn the list is read when the
    /// composer's connector list opens (`mcpServers(for:)`), so a session that is only looked at
    /// asks nothing.
    private func refreshMCPServerStatus(for localSessionID: UUID) {
        guard let handle = handles[localSessionID], let transport = transports[localSessionID] else { return }
        let requestID = takeRequestID(prefix: "mcp")
        Task { [weak self] in
            guard let response = try? await transport.request(ClaudeMCPServers.mcpStatusRequest(id: requestID),
                                                              id: requestID),
                  let servers = ClaudeMCPServers.fromStatus(response) else { return }
            await self?.acceptMCPServers(servers, for: handle)
        }
    }

    private func acceptMCPServers(_ servers: [HarnessMCPServerStatus], for handle: HarnessSessionHandle) {
        guard handles[handle.localSessionID] == handle,
              var state = providerStateByLocalSessionID[handle.localSessionID],
              state.mcpServers != servers else { return }
        state.mcpServers = servers
        providerStateByLocalSessionID[handle.localSessionID] = state
        emit(.providerCapabilitiesChanged, for: handle.localSessionID)
    }

    // MARK: - Idle compaction

    /// The main conversation's requests as the stream reports them: a response's start says what the
    /// request read and wrote in the prompt cache, its delta what it wrote out, and a compaction
    /// leaves nothing cached of what came before it, as the CLI forgets its last request then (`umn`).
    /// A subagent's frames carry its `parent_tool_use_id` and are its own.
    private func recordPromptCache(from value: JSONValue, for localSessionID: UUID) {
        guard value["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return }
        switch value["type"]?.stringValue {
        case "system" where value["subtype"]?.stringValue == "compact_boundary":
            promptCaches.removeValue(forKey: localSessionID)
        case "stream_event":
            let event = value["event"]
            switch event?["type"]?.stringValue {
            case "message_start":
                if let cache = ClaudePromptCacheState(responseStart: event?["message"]?["usage"], at: Date(),
                                                      previous: promptCaches[localSessionID]) {
                    promptCaches[localSessionID] = cache
                    modelChangedSinceRequest.remove(localSessionID)
                }
            case "message_delta":
                if let output = ClaudeEventProjector.unsigned(event?["usage"]?["output_tokens"]) {
                    promptCaches[localSessionID]?.outputTokens = output
                }
            default:
                break
            }
        default:
            break
        }
    }

    func promptCache(for localSessionID: UUID) -> ClaudePromptCacheState? {
        promptCaches[localSessionID]
    }

    /// The CLI's own answers, without a turn: whether it compacts automatically at all
    /// (`get_context_usage`'s `isAutoCompactEnabled`, which counts its settings and environment) and
    /// its effective settings (`get_settings`) for `idleCompaction` and the variable that sets how
    /// long a conversation must be. Nothing is written.
    func idleCompactionFacts(for localSessionID: UUID) async -> IdleCompactionFacts {
        var settings: ClaudeCompactionSettings?
        if let transport = transports[localSessionID] {
            let usageID = takeRequestID(prefix: "context")
            let settingsID = takeRequestID(prefix: "settings")
            if let usage = try? await transport.request(ClaudeProtocol.contextUsage(id: usageID), id: usageID),
               let autoCompact = usage["isAutoCompactEnabled"]?.boolValue,
               let answer = try? await transport.request(ClaudeProtocol.settings(id: settingsID), id: settingsID),
               let effective = answer["effective"] {
                let variable = IdleCompaction.minimumTokensVariable
                let minimum = effective["env"]?[variable]?.stringValue ?? environmentOverrides[variable]
                    ?? RuntimeProcessEnvironment.app[variable]
                settings = ClaudeCompactionSettings(
                    autoCompact: autoCompact, idleCompaction: effective["idleCompaction"]?.boolValue != false,
                    minimumContextTokens: IdleCompaction.minimumContextTokens(variable: minimum))
            }
        }
        // Read after the answers: a request the CLI made meanwhile is the newer one.
        return IdleCompactionFacts(cache: promptCaches[localSessionID],
                                   rateLimit: projections[localSessionID]?.rateLimitStatus,
                                   modelChanged: modelChangedSinceRequest.contains(localSessionID), settings: settings)
    }

    /// The result carries the turn's token counts but not how full the context window is, so the
    /// CLI's own context numbers are read once each turn ends. A CLI that does not answer the
    /// request leaves the window unknown, as it was before.
    private func refreshContextUsage(for localSessionID: UUID) {
        guard let handle = handles[localSessionID], let transport = transports[localSessionID] else { return }
        let requestID = takeRequestID(prefix: "context")
        contextUsageRequestIDs[localSessionID] = requestID
        Task { [weak self] in
            guard let response = try? await transport.request(
                ClaudeProtocol.contextUsage(id: requestID), id: requestID
            ), let usage = ClaudeProtocol.contextUsage(from: response) else { return }
            await self?.publishContextUsage(usage, requestID: requestID, for: handle)
        }
    }

    private func publishContextUsage(
        _ usage: HarnessProtocolUsage,
        requestID: String,
        for handle: HarnessSessionHandle
    ) {
        guard handles[handle.localSessionID] == handle,
              contextUsageRequestIDs[handle.localSessionID] == requestID else { return }
        emit(.usageUpdated(usage), for: handle.localSessionID)
    }

    @discardableResult
    private func refreshFlagSelectors(in session: HarnessSessionHandle) async -> Bool {
        guard let initial = initialResponses[session.localSessionID],
              let advertised = initial["models"]?.arrayValue,
              advertised.contains(where: { $0["supportsEffort"]?.boolValue == true }),
              let transport = transports[session.localSessionID] else { return false }
        let id = takeRequestID(prefix: "settings")
        guard let response = try? await transport.request(ClaudeProtocol.settings(id: id), id: id),
              let effective = response["effective"], let applied = response["applied"],
              var state = providerStateByLocalSessionID[session.localSessionID] else { return false }
        flagSettings[session.localSessionID] = response
        // Settings report the account's configured model, as effective and applied, even after
        // `--model` or `set_model` chose another, so the model this session was asked to run wins
        // whether the list carries it or not. Only a session asked for none shows the settings':
        // a new session lists the alias it was given ("fable"), a resumed one the session's full
        // model ID ("claude-fable-5-1"), and settings report the alias as effective and the full ID
        // as applied, so either may be the one the list carries.
        if let requested = requestedModelByLocalSessionID[session.localSessionID] {
            showRequestedModel(requested, in: &state, for: session.localSessionID)
        } else if let index = state.selectors.firstIndex(where: { $0.id == "model" }) {
            let catalog = advertisedModels(for: session.localSessionID) ?? []
            if let model = [effective["model"]?.stringValue, applied["model"]?.stringValue].compactMap({ $0 })
                .lazy.compactMap({ ClaudeComposerModelProjection.option(for: $0, in: catalog)?.value }).first {
                state.selectors[index].currentValue = model
            }
        }
        let selected = state.selectors.first(where: { $0.id == "model" })?.currentValue
        guard let model = advertised.first(where: { $0["value"]?.stringValue == selected }) else { return false }
        state.selectors.removeAll { $0.id == "effort" || $0.id == "fastMode" }
        if model["supportsEffort"]?.boolValue == true, var levels = model["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue), !levels.isEmpty {
            if let cap = effective["maxEffortLevel"]?.stringValue, let index = levels.firstIndex(of: cap) { levels = Array(levels.prefix(index + 1)) }
            state.selectors.append(.init(id: "effort", name: L10n.string("Reasoning effort"), description: nil, category: "thought_level",
                currentValue: applied["effort"]?.stringValue ?? effective["effortLevel"]?.stringValue ?? "default",
                choices: [.init(value: "default", name: L10n.string("Default"), description: nil)] + levels.map {
                    .init(value: $0, name: CodexReasoningLabel.name($0), description: nil)
                }))
        }
        if model["supportsFastMode"]?.boolValue == true, initial["fast_mode_disabled_reason"] == nil || initial["fast_mode_disabled_reason"] == .null {
            state.selectors.append(.init(id: "fastMode", name: L10n.string("Fast"), description: nil, category: "speed",
                currentValue: effective["fastMode"]?.boolValue == true ? "on" : "off",
                choices: [.init(value: "off", name: L10n.string("Off"), description: nil), .init(value: "on", name: L10n.string("On"), description: nil)]))
        }
        providerStateByLocalSessionID[session.localSessionID] = state
        return true
    }

    /// A top-level `system/init` lists the turn's commands and the MCP servers the session loaded.
    private func acceptComposerCommands(_ frame: JSONValue, for localSessionID: UUID) {
        guard var state = providerStateByLocalSessionID[localSessionID] else {
            earlyCommandInitByLocalSessionID[localSessionID] = frame
            return
        }
        var changed = false
        if let commands = ClaudeComposerCommands.refreshed(state.composerCommands, from: frame),
           commands != state.composerCommands {
            state.composerCommands = commands
            changed = true
        }
        if let servers = ClaudeMCPServers.fromInit(frame), servers != state.mcpServers {
            state.mcpServers = servers
            changed = true
        }
        guard changed else { return }
        providerStateByLocalSessionID[localSessionID] = state
        emit(.providerCapabilitiesChanged, for: localSessionID)
    }

    /// The permission-mode selector shows the mode the CLI announced, not only the one Yardlet
    /// last asked for, so a mode an approval switched to, or one the CLI changed itself, is what
    /// the selector reads. A mode it already shows changes nothing.
    private func acceptAnnouncedPermissionMode(
        _ mode: String,
        for localSessionID: UUID,
        rawData: Data
    ) {
        guard var state = providerStateByLocalSessionID[localSessionID] else {
            earlyPermissionModeByLocalSessionID[localSessionID] = mode
            return
        }
        guard let index = state.selectors.firstIndex(where: { $0.id == "permissionMode" }),
              state.selectors[index].currentValue != mode else { return }
        state.selectors[index].currentValue = mode
        providerStateByLocalSessionID[localSessionID] = state
        emit(.providerCapabilitiesChanged, for: localSessionID, rawData: rawData)
    }

    /// A follow-up is read when a turn takes it in: the running one at its next step, or the turn
    /// the CLI starts on its own for it once the last one ended, which is running again. Another
    /// uuid is a command the CLI queued itself — a schedule's prompt (`CronCreate`, a `/loop`
    /// wakeup), a background task's notice, another session's message. One it starts a turn with
    /// while none runs opens that turn, which is running (2.1.299 sends `command_lifecycle` `started`,
    /// then `system/init` and the answer; no `user` frame, even with `--replay-user-messages`).
    private func acceptCommandLifecycle(
        messageID: String,
        state: String,
        for localSessionID: UUID,
        rawData: Data
    ) {
        lifecycleReportingSessions.insert(localSessionID)
        defer { resumeFollowUpLifecycleWaiters(for: messageID) }
        guard unreadFollowUps[localSessionID]?.contains(messageID) == true else {
            if state == "started", foregroundSessions.insert(localSessionID).inserted {
                emit(.providerStartedTurn(messageID: messageID), for: localSessionID, rawData: rawData)
                emit(.sessionStatusChanged(.running), for: localSessionID)
            }
            return
        }
        if state != "queued" { queuedFollowUps[localSessionID]?.remove(messageID) }
        switch state {
        case "queued":
            queuedFollowUps[localSessionID, default: []].insert(messageID)
        case "started", "completed":
            // `completed` without `started` is one the CLI settled without a turn of its own. A turn
            // still running took the message in at its next step; otherwise the CLI starts a turn
            // with it.
            unreadFollowUps[localSessionID]?.removeAll { $0 == messageID }
            let joinsRunningTurn = foregroundSessions.contains(localSessionID)
            emit(.followUpDelivery(.init(messageID: messageID, state: .read, joinsRunningTurn: joinsRunningTurn)),
                 for: localSessionID, rawData: rawData)
            if state == "started", foregroundSessions.insert(localSessionID).inserted {
                emit(.sessionStatusChanged(.running), for: localSessionID)
            }
        case "cancelled", "discarded", "refused":
            unreadFollowUps[localSessionID]?.removeAll { $0 == messageID }
            // A withdrawal Yardlet asked for is settled by the CLI's answer to that request.
            guard !followUpsBeingCancelled.contains(messageID) else { return }
            emit(.followUpDelivery(.init(messageID: messageID, state: .dropped)), for: localSessionID, rawData: rawData)
        default:
            break
        }
    }

    /// `AskUserQuestion` may carry a single-line heading for the whole form. It is the
    /// provider's own text, shown only when the request sent no description of its own.
    private func questionHeading(
        for structured: PermissionRequestStructure?,
        input: JSONValue
    ) -> String? {
        guard case .questions = structured else { return nil }
        return input["title"]?.stringValue
    }

    private func transport(for session: HarnessSessionHandle) throws -> any ClaudeTransport {
        guard handles[session.localSessionID] == session,
              let transport = transports[session.localSessionID] else {
            throw HarnessAdapterError.invalidProviderEvent("Claude session is not attached")
        }
        return transport
    }

    private func transportStreamEnded(for localSessionID: UUID) {
        guard handles[localSessionID] != nil else { return }
        for payload in projections[localSessionID]?.processEnded() ?? [] { emit(payload, for: localSessionID) }
        emit(
            .error(
                message: L10n.string("Claude Code transport ended unexpectedly"),
                recoverable: true
            ),
            for: localSessionID
        )
        emit(.sessionStatusChanged(.failed), for: localSessionID)
    }

    private func takeRequestID(prefix: String) -> String {
        defer { nextRequestNumber += 1 }
        return "nhc-\(prefix)-\(nextRequestNumber)"
    }

    private func claudeCapabilityState(
        initializeResponse: JSONValue,
        chromeIntegration: Bool,
        permissionMode: String? = nil
    ) -> ProviderCapabilityState {
        let models = modelChoices(initializeResponse: initializeResponse)
        let permissionModes = ClaudePermissionMode.selectable.compactMap { mode in
            ClaudePermissionMode.displayName(mode).map {
                ProviderCapabilityChoice(value: mode, name: $0, description: nil)
            }
        }
        return ProviderCapabilityState(
            selectors: [
                ProviderCapabilitySelector(
                    id: "model",
                    name: L10n.string("Model"),
                    description: L10n.string("Change the model for the active Claude Code session."),
                    category: "model",
                    currentValue: ClaudeProtocol.initialModel(in: initializeResponse)
                        ?? models[0].value,
                    choices: models
                ),
                ProviderCapabilitySelector(
                    id: "permissionMode",
                    name: L10n.string("Permission mode"),
                    description: L10n.string("Controls how Claude Code asks before using tools."),
                    category: "mode",
                    currentValue: permissionMode
                        ?? ClaudeProtocol.initialPermissionMode(in: initializeResponse) ?? "manual",
                    choices: permissionModes
                ),
                ProviderCapabilitySelector(
                    id: ClaudeLaunchOption.chromeIntegration,
                    name: L10n.string("Claude in Chrome"),
                    description: L10n.string(
                        "Claude Code takes this as a launch flag, so it applies the next time this task starts. The Chrome extension and any refusal stay with the CLI."
                    ),
                    category: "mode",
                    currentValue: chromeIntegration
                        ? ClaudeLaunchOption.on
                        : ClaudeLaunchOption.off,
                    choices: [
                        ProviderCapabilityChoice(
                            value: ClaudeLaunchOption.off,
                            name: L10n.string("Off"),
                            description: nil
                        ),
                        ProviderCapabilityChoice(
                            value: ClaudeLaunchOption.on,
                            name: L10n.string("On"),
                            description: nil
                        )
                    ]
                )
            ],
            notes: [
                L10n.string("Skills, agents, plugins, hooks, and MCP remain owned by Claude Code settings.")
            ],
            composerCommands: ClaudeComposerCommands.initial(initializeResponse)
        )
    }

    /// The model selector's rows: the models Claude Code listed when the session connected, or the
    /// three aliases when it listed none.
    private func modelChoices(initializeResponse: JSONValue) -> [ProviderCapabilityChoice] {
        let exposedModels: [ProviderCapabilityChoice] = initializeResponse["models"]?.arrayValue?.compactMap {
            model -> ProviderCapabilityChoice? in
            let value = model["value"]?.stringValue ?? model["id"]?.stringValue
            guard let value else { return nil }
            return ProviderCapabilityChoice(
                value: value,
                name: model["displayName"]?.stringValue ?? model["name"]?.stringValue ?? value,
                description: model["description"]?.stringValue
            )
        } ?? []
        return exposedModels.isEmpty ? [
            ProviderCapabilityChoice(value: "sonnet", name: "Sonnet", description: nil),
            ProviderCapabilityChoice(value: "opus", name: "Opus", description: nil),
            ProviderCapabilityChoice(value: "fable", name: "Fable", description: nil)
        ] : exposedModels
    }

    /// The model selector shows the model this session was asked to run (its launch flag, then each
    /// `set_model`) under the row Claude Code lists it as: a full ID such as `claude-opus-5-5` under
    /// its `opus` row. One the list does not carry is shown under its own name, as before the task
    /// connects, never as whichever listed model the account's settings name. Display only: what
    /// runs and what the task keeps are left as they are.
    private func showRequestedModel(_ model: String, in state: inout ProviderCapabilityState, for localSessionID: UUID) {
        guard let index = state.selectors.firstIndex(where: { $0.id == "model" }) else { return }
        let listed = ClaudeComposerModelProjection.option(for: model, in: advertisedModels(for: localSessionID) ?? [])
        let value = listed?.value ?? model
        var choices = modelChoices(initializeResponse: initialResponses[localSessionID] ?? .object([:]))
        if !choices.contains(where: { $0.value == value }) {
            choices.insert(.init(value: value, name: ClaudeComposerModelProjection.displayName(value), description: nil), at: 0)
        }
        let selector = state.selectors[index]
        state.selectors[index] = ProviderCapabilitySelector(
            id: selector.id, name: selector.name, description: selector.description,
            category: selector.category, currentValue: value, choices: choices
        )
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }

    private func readVersion() throws -> String {
        try ClaudeRuntimeCompatibility.readVersionOutput(executableURL: executableURL)
    }
}

extension ClaudeAdapter: HarnessTaskSightReceiving {
    /// Pauses a CLI that asks for suggestions while its task is off screen, as Claude Code's terminal
    /// suggests only while it has focus, and resumes it when the task is back. A CLI with the pause not
    /// enabled yet acknowledges and goes on; the answer is not waited for.
    func setUnseen(since date: Date?, for localSessionID: UUID) {
        let paused = date != nil
        guard sessionsAskingForSuggestions.contains(localSessionID), let transport = transports[localSessionID],
              paused != pausedSuggestionSessions.contains(localSessionID) else { return }
        if paused {
            pausedSuggestionSessions.insert(localSessionID)
        } else {
            pausedSuggestionSessions.remove(localSessionID)
        }
        let requestID = takeRequestID(prefix: "suggestions")
        Task {
            _ = try? await transport.request(
                ClaudeProtocol.setPromptSuggestionsPaused(id: requestID, paused: paused), id: requestID)
        }
    }
}
