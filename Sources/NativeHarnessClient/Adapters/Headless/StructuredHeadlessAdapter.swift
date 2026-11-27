import Foundation

/// Cursor Agent's print mode: one `cursor-agent --print --output-format stream-json` per turn.
actor StructuredHeadlessAdapter: HarnessAdapter, ProviderCapabilityProviding {
    nonisolated let kind: HarnessKind

    private let executableURL: URL
    private let flavor: StructuredHeadlessFlavor
    private let projector: StructuredHeadlessEventProjector
    private let cursorChatTimeout: Duration

    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var processes: [UUID: Process] = [:]
    private var readerTasks: [UUID: Task<Void, Never>] = [:]
    private var stderrReaderTasks: [UUID: Task<Void, Never>] = [:]
    private var eventChannel = HarnessEventChannel()
    private var hasAssistantText: Set<UUID> = []
    private var terminalSessionIDs: Set<UUID> = []
    private var stderrBySessionID: [UUID: Data] = [:]
    private var interruptedSessionIDs: Set<UUID> = []
    private var activitiesBySessionID: [UUID: [String: HarnessActivity]] = [:]
    private var optionsByLocalSessionID: [UUID: StructuredHeadlessSessionOptions] = [:]
    private var modelChoicesByLocalSessionID: [UUID: [ProviderCapabilityChoice]] = [:]
    /// Each session's last prompt, run again once the person trusts the folder.
    private var promptsBySessionID: [UUID: String] = [:]
    /// The trust question each session waits on (`workspaceTrustRequest`).
    private var trustRequestsBySessionID: [UUID: String] = [:]

    init(
        kind: HarnessKind,
        executableURL: URL,
        cursorChatTimeout: Duration = .seconds(30)
    ) {
        guard let flavor = StructuredHeadlessFlavor(harness: kind) else {
            preconditionFailure("Unsupported structured headless harness: \(kind.rawValue)")
        }
        self.kind = kind
        self.executableURL = executableURL.standardizedFileURL
        self.flavor = flavor
        self.projector = StructuredHeadlessEventProjector(flavor: flavor)
        self.cursorChatTimeout = cursorChatTimeout
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
                // Its one request is Cursor's own folder trust question.
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: false,
                acceptsImages: false,
                hasSubagents: false
            ),
            fingerprint: fingerprint
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        let providerSessionID = try await createCursorChat(in: request.workspaceURL)
        let handle = HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: request.workspaceURL.standardizedFileURL
        )
        handles[handle.localSessionID] = handle
        optionsByLocalSessionID[handle.localSessionID] = .init()
        emit(.sessionStarted(handle), for: handle.localSessionID)
        emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
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
            harness: kind,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL.standardizedFileURL
        )
        handles[localSessionID] = handle
        optionsByLocalSessionID[localSessionID] = .init()
        emit(.sessionStarted(handle), for: localSessionID)
        emit(.sessionStatusChanged(.ready), for: localSessionID)
        return handle
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        // A new message stands in for the one waiting on the trust question; it asks again if it must.
        if let request = trustRequestsBySessionID.removeValue(forKey: session.localSessionID) {
            emit(.permissionExpired(request), for: session.localSessionID)
        }
        try await startTurn(prompt, in: session, trustsWorkspace: false)
    }

    private func startTurn(_ prompt: String, in session: HarnessSessionHandle, trustsWorkspace: Bool) async throws {
        await LoginShellPath.ready()
        guard handles[session.localSessionID] != nil else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Headless session is not attached")
            )
        }
        // A turn reports its result before its process exits. A prompt sent in between, such as a
        // queued follow-up released by that result, waits briefly for the exit instead of failing.
        if let finishing = processes[session.localSessionID], terminalSessionIDs.contains(session.localSessionID) {
            for _ in 0..<100 where processes[session.localSessionID] === finishing {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        guard processes[session.localSessionID] == nil else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("A headless prompt is already running")
            )
        }

        hasAssistantText.remove(session.localSessionID)
        terminalSessionIDs.remove(session.localSessionID)
        stderrBySessionID.removeValue(forKey: session.localSessionID)
        completeOwnedActivities(for: session.localSessionID)
        promptsBySessionID[session.localSessionID] = prompt

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let providerSessionID = handles[session.localSessionID]?.providerSessionID
            ?? session.providerSessionID
        process.executableURL = executableURL
        process.currentDirectoryURL = session.workspaceURL
        process.arguments = flavor.arguments(
            prompt: prompt,
            providerSessionID: providerSessionID,
            options: optionsByLocalSessionID[session.localSessionID] ?? .init(),
            trustsWorkspace: trustsWorkspace
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = RuntimeProcessEnvironment.values(
            executableURL: executableURL,
            overrides: [
                "NO_COLOR": "1",
                "PAGER": "cat",
                "GIT_PAGER": "cat"
            ]
        )

        let chunks = AsyncStream<Data>.makeStream()
        let stderrChunks = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readChunks(into: chunks.continuation)
        stderrPipe.fileHandleForReading.readChunks(into: stderrChunks.continuation)
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidTerminate(process, for: session.localSessionID) }
        }

        try NativeProcessTree.run(process)
        processes[session.localSessionID] = process
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        readerTasks[session.localSessionID] = Task { [weak self] in
            var buffer = Data()
            for await chunk in chunks.stream {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty { await self?.accept(line, for: session.localSessionID) }
                }
            }
            if !buffer.isEmpty { await self?.accept(buffer, for: session.localSessionID) }
        }
        stderrReaderTasks[session.localSessionID] = Task { [weak self] in
            for await chunk in stderrChunks.stream {
                await self?.appendStderr(chunk, for: session.localSessionID)
            }
        }
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        if let request = trustRequestsBySessionID.removeValue(forKey: session.localSessionID) {
            emit(.permissionExpired(request), for: session.localSessionID)
            emit(.sessionStatusChanged(.ready), for: session.localSessionID)
            return
        }
        guard let process = processes[session.localSessionID], process.isRunning else { return }
        interruptedSessionIDs.insert(session.localSessionID)
        // A print-mode turn is the process itself and has no cancel request of its own.
        NativeProcessTree.interrupt(process: process)
    }

    /// Answers Cursor's folder trust question: trusted, the same message runs again with `--trust` (Cursor then
    /// records the folder, as its own app does when the person trusts it there); not trusted, it does not run.
    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        if trustRequestsBySessionID[session.localSessionID] == permissionRequestID {
            trustRequestsBySessionID.removeValue(forKey: session.localSessionID)
            guard decision == .allow, let prompt = promptsBySessionID[session.localSessionID] else {
                // As when the person quits Cursor's own question: the message does not run, and the card says why.
                emit(.sessionStatusChanged(.ready), for: session.localSessionID)
                return
            }
            try await startTurn(prompt, in: session, trustsWorkspace: true)
            return
        }
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.string("This headless runtime does not expose structured permission responses")
        )
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        eventChannel.subscribe(to: session.localSessionID)
    }

    func providerCapabilities(
        for session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        let localSessionID = session.localSessionID
        var errors: [String] = []
        do {
            let choices = try await catalogChoices(
                arguments: ["--list-models"],
                workspaceURL: session.workspaceURL
            )
            if handles[localSessionID] == session {
                modelChoicesByLocalSessionID[localSessionID] = choices
            }
        } catch {
            if handles[localSessionID] == session {
                modelChoicesByLocalSessionID.removeValue(forKey: localSessionID)
            }
            errors.append(L10n.format("Model catalog unavailable: %@", error.localizedDescription))
        }
        return capabilityState(for: localSessionID, errors: errors)
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        var options = optionsByLocalSessionID[session.localSessionID] ?? .init()
        switch (flavor, id) {
        case (.cursor, StructuredHeadlessOptionID.model):
            if value == "default" {
                options.model = nil
                break
            }
            if modelChoicesByLocalSessionID[session.localSessionID]?.isEmpty != false {
                _ = try await providerCapabilities(for: session)
            }
            guard modelChoicesByLocalSessionID[session.localSessionID]?.contains(where: {
                $0.value == value
            }) == true else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That model is not available from the current runtime")
                )
            }
            options.model = value

        case (.cursor, StructuredHeadlessOptionID.executionMode):
            guard ["default", "plan", "ask"].contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That Cursor execution mode is not available")
                )
            }
            options.mode = value == "default" ? nil : value

        case (.cursor, StructuredHeadlessOptionID.reviewPolicy):
            guard ["default", "auto-review"].contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That Cursor review policy is not available")
                )
            }
            options.reviewPolicy = value == "default" ? nil : value

        case (.cursor, StructuredHeadlessOptionID.sandbox):
            guard ["default", "enabled"].contains(value) else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("That Cursor sandbox mode is not available")
                )
            }
            options.sandbox = value == "default" ? nil : value

        default:
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("This headless runtime does not expose that setting")
            )
        }
        optionsByLocalSessionID[session.localSessionID] = options
        var state = capabilityState(for: session.localSessionID, errors: [])
        state.actionMessage = L10n.string("The setting will apply to the next prompt")
        return state
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        try requireRegistered(session)
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.string("This headless runtime does not expose session actions")
        )
    }

    func close(_ session: HarnessSessionHandle) async {
        // Foundation owns the turn process and reports its exit to `terminationHandler`, so
        // close stops the tree without reaping the root itself.
        if let process = processes.removeValue(forKey: session.localSessionID), process.isRunning {
            NativeProcessTree.terminate(process: process)
        }
        readerTasks.removeValue(forKey: session.localSessionID)?.cancel()
        stderrReaderTasks.removeValue(forKey: session.localSessionID)?.cancel()
        handles.removeValue(forKey: session.localSessionID)
        hasAssistantText.remove(session.localSessionID)
        terminalSessionIDs.remove(session.localSessionID)
        stderrBySessionID.removeValue(forKey: session.localSessionID)
        interruptedSessionIDs.remove(session.localSessionID)
        activitiesBySessionID.removeValue(forKey: session.localSessionID)
        optionsByLocalSessionID.removeValue(forKey: session.localSessionID)
        modelChoicesByLocalSessionID.removeValue(forKey: session.localSessionID)
        promptsBySessionID.removeValue(forKey: session.localSessionID)
        trustRequestsBySessionID.removeValue(forKey: session.localSessionID)
        eventChannel.close(session.localSessionID)
    }

    private func accept(_ data: Data, for localSessionID: UUID) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let projection = projector.project(
            value,
            hasAssistantText: hasAssistantText.contains(localSessionID)
        )
        if let providerSessionID = projection.providerSessionID,
           let oldHandle = handles[localSessionID],
           providerSessionID != oldHandle.providerSessionID {
            let newHandle = HarnessSessionHandle(
                harness: oldHandle.harness,
                localSessionID: oldHandle.localSessionID,
                providerSessionID: providerSessionID,
                workspaceURL: oldHandle.workspaceURL
            )
            handles[localSessionID] = newHandle
            emit(.sessionStarted(newHandle), for: localSessionID, rawData: data)
        }
        // A stopped run still reports a result, as an error ("interrupted"), before it exits. The
        // person asked for the stop, so it is not a failure: the exit returns the task to ready.
        let stoppedByRequest = projection.isTerminal && interruptedSessionIDs.contains(localSessionID)
        for payload in projection.payloads {
            if stoppedByRequest {
                if case .error = payload { continue }
                if case .turnCompleted = payload { continue }
            }
            if case .assistantDelta = payload { hasAssistantText.insert(localSessionID) }
            remember(payload, for: localSessionID)
            emit(payload, for: localSessionID, rawData: data)
        }
        if stoppedByRequest {
            completeOwnedActivities(for: localSessionID, rawData: data)
            terminalSessionIDs.insert(localSessionID)
            return
        }
        if projection.isTerminal {
            completeOwnedActivities(for: localSessionID, rawData: data)
            terminalSessionIDs.insert(localSessionID)
            let failed = projection.payloads.contains {
                if case .error = $0 { return true }
                return false
            }
            emit(.sessionStatusChanged(failed ? .failed : .ready), for: localSessionID, rawData: data)
        }
    }

    private func processDidTerminate(_ process: Process, for localSessionID: UUID) async {
        processes.removeValue(forKey: localSessionID)
        let readerTask = readerTasks.removeValue(forKey: localSessionID)
        let stderrReaderTask = stderrReaderTasks.removeValue(forKey: localSessionID)
        await readerTask?.value
        await stderrReaderTask?.value
        guard handles[localSessionID] != nil else {
            interruptedSessionIDs.remove(localSessionID)
            terminalSessionIDs.remove(localSessionID)
            stderrBySessionID.removeValue(forKey: localSessionID)
            activitiesBySessionID.removeValue(forKey: localSessionID)
            return
        }
        completeOwnedActivities(for: localSessionID)
        if interruptedSessionIDs.remove(localSessionID) != nil {
            stderrBySessionID.removeValue(forKey: localSessionID)
            emit(.sessionStatusChanged(.ready), for: localSessionID)
            return
        }
        let detail = String(
            decoding: stderrBySessionID.removeValue(forKey: localSessionID) ?? Data(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 {
            guard terminalSessionIDs.remove(localSessionID) == nil else { return }
            emit(
                .error(
                    message: detail.isEmpty
                        ? L10n.string("Harness process exited without a terminal result")
                        : detail,
                    recoverable: true
                ),
                for: localSessionID
            )
            emit(.sessionStatusChanged(.failed), for: localSessionID)
            return
        }
        terminalSessionIDs.remove(localSessionID)
        if Self.asksForWorkspaceTrust(detail), let folder = handles[localSessionID]?.workspaceURL {
            let request = "cursor-workspace-trust-\(UUID().uuidString.lowercased())"
            trustRequestsBySessionID[localSessionID] = request
            emit(.permissionRequested(Self.workspaceTrustRequest(id: request, folder: folder)), for: localSessionID)
            emit(.sessionStatusChanged(.waitingForApproval), for: localSessionID)
            return
        }
        emit(
            .error(
                message: detail.isEmpty
                    ? L10n.format("Harness process exited (%d)", process.terminationStatus)
                    : detail,
                recoverable: true
            ),
            for: localSessionID
        )
        emit(.sessionStatusChanged(.failed), for: localSessionID)
    }

    /// Cursor's print mode refuses a folder the person has not trusted, before any model request, with the
    /// question its interactive mode would ask ("Workspace Trust Required", 2026.11.13).
    nonisolated static func asksForWorkspaceTrust(_ stderr: String) -> Bool {
        stderr.contains("Workspace Trust Required")
    }

    /// Cursor's own question on Yardlet's card. Cursor's terminal offers "Trust this workspace" and "Quit";
    /// trusting here is the same answer, and Cursor keeps it for the folder.
    nonisolated static func workspaceTrustRequest(id: String, folder: URL) -> PermissionRequest {
        PermissionRequest(
            id: id,
            title: L10n.string("Trust this folder in Cursor?"),
            detail: L10n.format(
                "Cursor Agent can run code and access files in %@. It runs there only once you trust the folder's contents, and remembers your answer for the folder.",
                folder.path(percentEncoded: false)),
            command: nil,
            actions: [
                PermissionRequestAction(id: "trust", text: LocalizedText("Trust this folder"), decision: .allow, kind: nil),
                PermissionRequestAction(id: "quit", text: LocalizedText("Don't trust"), decision: .deny, kind: "reject_once")
            ],
            requiresInAppAnswer: true
        )
    }

    private func remember(_ payload: HarnessEventPayload, for localSessionID: UUID) {
        switch payload {
        case let .activityStarted(activity), let .activityUpdated(activity):
            activitiesBySessionID[localSessionID, default: [:]][activity.id] = activity
        case let .activityCompleted(activity):
            activitiesBySessionID[localSessionID]?.removeValue(forKey: activity.id)
        default:
            break
        }
    }

    private func completeOwnedActivities(for localSessionID: UUID, rawData: Data? = nil) {
        let remaining = activitiesBySessionID.removeValue(forKey: localSessionID) ?? [:]
        for var activity in remaining.values.sorted(by: { $0.id < $1.id }) {
            activity.outcome = .stopped
            emit(.activityCompleted(activity), for: localSessionID, rawData: rawData)
        }
    }

    private func appendStderr(_ data: Data, for localSessionID: UUID) {
        var buffer = stderrBySessionID[localSessionID] ?? Data()
        buffer.append(data)
        if buffer.count > 16 * 1024 { buffer.removeFirst(buffer.count - 16 * 1024) }
        stderrBySessionID[localSessionID] = buffer
    }

    private enum CursorChatCreation: Sendable {
        case exited(status: Int32, output: Data)
        case timedOut
    }

    /// `create-chat` prints the new chat's ID and exits. The ID can arrive late or across
    /// several writes, so the whole output is read until the process closes it and exits.
    /// The wait is bounded so a stalled runtime cannot hold session creation open.
    private func createCursorChat(in workspaceURL: URL) async throws -> String {
        await LoginShellPath.ready()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL.standardizedFileURL
        process.arguments = ["create-chat"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = RuntimeProcessEnvironment.values(
            executableURL: executableURL,
            overrides: [
                "NO_COLOR": "1",
                "PAGER": "cat",
                "GIT_PAGER": "cat"
            ]
        )

        let chunks = AsyncStream<Data>.makeStream()
        let exitStatus = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exitStatus.continuation.yield(process.terminationStatus)
            exitStatus.continuation.finish()
        }
        try NativeProcessTree.run(process)
        pipe.fileHandleForReading.readChunks(into: chunks.continuation)

        let timeout = cursorChatTimeout
        let creation = await withTaskGroup(of: CursorChatCreation?.self) { group in
            group.addTask {
                var output = Data()
                for await chunk in chunks.stream { output.append(chunk) }
                var status: Int32?
                for await code in exitStatus.stream { status = code }
                guard let status else { return nil }
                return CursorChatCreation.exited(status: status, output: output)
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                return .timedOut
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timedOut
        }

        switch creation {
        case .timedOut:
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { NativeProcessTree.terminate(process: process) }
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Cursor did not create a chat in time")
            )
        case let .exited(status, output):
            let text = String(decoding: output, as: UTF8.self)
            guard status == 0 else {
                throw HarnessAdapterError.processExited(
                    code: status,
                    message: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard let chatID = text.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first(where: { UUID(uuidString: $0) != nil }) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Cursor did not return a chat identifier")
                )
            }
            return chatID
        }
    }

    private func requireRegistered(_ session: HarnessSessionHandle) throws {
        guard handles[session.localSessionID] == session else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Headless session is not attached")
            )
        }
    }

    private func capabilityState(
        for localSessionID: UUID,
        errors: [String]
    ) -> ProviderCapabilityState {
        let options = optionsByLocalSessionID[localSessionID] ?? .init()
        var selectors: [ProviderCapabilitySelector] = []
        if let models = modelChoicesByLocalSessionID[localSessionID], !models.isEmpty {
            let choices = [choice("default", L10n.string("Default"))] + models
            let current = options.model ?? "default"
            selectors.append(ProviderCapabilitySelector(
                id: StructuredHeadlessOptionID.model,
                name: L10n.string("Model"),
                description: L10n.string("Choose a model reported by the installed runtime."),
                category: "model",
                currentValue: choices.contains(where: { $0.value == current })
                    ? current : "default",
                choices: choices
            ))
        }
        switch flavor {
        case .cursor:
            selectors.append(contentsOf: [
                ProviderCapabilitySelector(
                    id: StructuredHeadlessOptionID.executionMode,
                    name: L10n.string("Execution mode"),
                    description: L10n.string("Applied to each subsequent Cursor invocation."),
                    category: "mode",
                    currentValue: options.mode ?? "default",
                    choices: [
                        choice("default", L10n.string("Default")),
                        choice("plan", L10n.string("Plan")),
                        choice("ask", L10n.string("Ask"))
                    ]
                ),
                ProviderCapabilitySelector(
                    id: StructuredHeadlessOptionID.reviewPolicy,
                    name: L10n.string("Review policy"),
                    description: L10n.string("Smart Auto reviews tool calls before they run."),
                    category: "mode",
                    currentValue: options.reviewPolicy ?? "default",
                    choices: [
                        choice("default", L10n.string("Default")),
                        choice("auto-review", L10n.string("Smart Auto"))
                    ]
                ),
                sandboxSelector(currentValue: options.sandbox)
            ])
        }
        return ProviderCapabilityState(
            selectors: selectors,
            notes: [
                L10n.string("Headless settings are passed as official CLI flags on the next prompt."),
                L10n.string("Yardlet never offers force or dangerously-skip-permissions modes.")
            ],
            errors: errors
        )
    }

    private func sandboxSelector(currentValue: String?) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(
            id: StructuredHeadlessOptionID.sandbox,
            name: L10n.string("Sandbox mode"),
            description: L10n.string("Use the runtime default or explicitly enable its sandbox."),
            category: "mode",
            currentValue: currentValue ?? "default",
            choices: [
                choice("default", L10n.string("Default")),
                choice("enabled", L10n.string("Enabled"))
            ]
        )
    }

    private func choice(_ value: String, _ name: String) -> ProviderCapabilityChoice {
        ProviderCapabilityChoice(value: value, name: name, description: nil)
    }

    private func catalogChoices(
        arguments: [String],
        workspaceURL: URL
    ) async throws -> [ProviderCapabilityChoice] {
        await LoginShellPath.ready()
        let output = try await Self.runCatalogCommand(
            executableURL,
            arguments,
            workspaceURL: workspaceURL
        ).get()
        return Self.catalogChoices(in: output.stdout)
    }

    struct CatalogOutput: Sendable {
        let stdout: String
        let stderr: String
    }

    /// One listing command run off the actor, so several can run side by side.
    nonisolated static func runCatalogCommand(
        _ executableURL: URL, _ arguments: [String], workspaceURL: URL, environment: [String: String] = [:]
    ) async -> Result<CatalogOutput, any Error> {
        await Task.detached {
            Result { try runCatalogCommandSync(executableURL, arguments, workspaceURL: workspaceURL, environment: environment) }
        }.value
    }

    nonisolated static func runCatalogCommandSync(
        _ executableURL: URL, _ arguments: [String], workspaceURL: URL, environment: [String: String] = [:]
    ) throws -> CatalogOutput {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL.standardizedFileURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // A listing command left holding an inherited input waits on it (CLI 1.1.23).
        process.standardInput = FileHandle.childNullDevice()
        process.environment = RuntimeProcessEnvironment.values(executableURL: executableURL, overrides: environment)
        let exit = try ProcessExit(running: process)
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let ended = exit.waitBlockingThread(timeout: .seconds(10))
        let output = String(decoding: outputData, as: UTF8.self)
        let error = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ended else {
            NativeProcessTree.terminate(process: process)
            throw HarnessAdapterError.processExited(code: -1, message: error.isEmpty ? output : error)
        }
        guard process.terminationStatus == 0 else {
            throw HarnessAdapterError.processExited(
                code: process.terminationStatus,
                message: error.isEmpty ? output : error
            )
        }
        return CatalogOutput(stdout: output, stderr: error)
    }

    /// `id<TAB>name` lines, or space-separated ones, without the progress and heading lines.
    nonisolated static func catalogChoices(in output: String) -> [ProviderCapabilityChoice] {
        var seen: Set<String> = []
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
                .replacingOccurrences(
                    of: "\u{001B}\\[[0-9;]*[A-Za-z]",
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let columns = line.split(whereSeparator: { $0 == "\t" }).map(String.init)
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // A line without a tab is `id name…`, split at the first space.
            guard let value = columns.count > 1 ? columns.first : words.first,
                  value != "Fetching", value != "Available", value.lowercased() != "model",
                  seen.insert(value).inserted else { return nil }
            let name: String
            if columns.count > 1 {
                name = columns.dropFirst().joined(separator: " ")
            } else {
                name = words.dropFirst().joined(separator: " ")
            }
            return ProviderCapabilityChoice(
                value: value,
                name: name.isEmpty ? value : name,
                description: nil
            )
        }
    }

    private func readVersion() throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL, inheritsAppEnvironment: true)
    }

    private func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawData: Data? = nil
    ) {
        eventChannel.emit(payload, for: localSessionID, rawProviderEvent: rawData)
    }
}
