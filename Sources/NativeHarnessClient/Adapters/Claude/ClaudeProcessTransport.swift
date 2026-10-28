import Foundation

protocol ClaudeTransport: Actor {
    func start(_ configuration: ClaudeLaunchConfiguration) async throws
    func request(_ value: JSONValue, id: String) async throws -> JSONValue
    func send(_ value: JSONValue) async throws
    func messages() async -> AsyncStream<ClaudeRawFrame>
    func stop() async
}

actor ClaudeProcessTransport: ClaudeTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let environmentOverrides: [String: String]
    private let requestTimeout: Duration
    private let codec = ClaudeWireCodec()
    private let messageStream: AsyncStream<ClaudeRawFrame>
    private let messageContinuation: AsyncStream<ClaudeRawFrame>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stopped = false
    /// The task the CLI runs for, whose resource use counts its process tree.
    private let resourceOwner: TaskResourceOwner?
    private let processRegistry: TaskProcessRegistry

    init(executableURL: URL, environmentOverrides: [String: String] = [:], requestTimeout: Duration = .seconds(60),
         resourceOwner: TaskResourceOwner? = nil, processRegistry: TaskProcessRegistry = .shared) {
        self.executableURL = executableURL.standardizedFileURL
        self.environmentOverrides = environmentOverrides
        self.requestTimeout = requestTimeout
        self.resourceOwner = resourceOwner
        self.processRegistry = processRegistry
        let messages = AsyncStream<ClaudeRawFrame>.makeStream()
        self.messageStream = messages.stream
        self.messageContinuation = messages.continuation
    }

    func start(_ configuration: ClaudeLaunchConfiguration) async throws {
        if let process, process.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: "Claude transport cannot restart after being stopped"
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = configuration.workspaceURL.standardizedFileURL
        process.arguments = Self.arguments(for: configuration)
        process.environment = environment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let chunks = AsyncStream<Data>.makeStream()
        chunkContinuation = chunks.continuation
        stdoutPipe.fileHandleForReading.readChunks(into: chunks.continuation)
        stderrPipe.fileHandleForReading.readChunks { [weak self] data in
            Task { await self?.appendStderr(data) }
        }
        let owner = resourceOwner
        let registry = processRegistry
        process.terminationHandler = { [weak self] process in
            if let owner { registry.unregister(process.processIdentifier, owner: owner) }
            Task { await self?.processDidTerminate(code: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        if let owner, process.isRunning { registry.register(process.processIdentifier, owner: owner) }

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            for await chunk in chunks.stream {
                await self?.acceptStdoutChunk(chunk)
            }
        }
    }

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        guard process?.isRunning == true else {
            throw exitError(fallback: "Claude CLI is not running")
        }
        let data = try codec.encodeLine(value)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(id)
            }
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
            do {
                try stdinHandle?.write(contentsOf: data)
            } catch {
                timeoutTask.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ value: JSONValue) async throws {
        guard process?.isRunning == true else {
            throw exitError(fallback: "Claude CLI is not running")
        }
        try stdinHandle?.write(contentsOf: codec.encodeLine(value))
    }

    func messages() async -> AsyncStream<ClaudeRawFrame> {
        messageStream
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        chunkContinuation?.finish()
        readerTask?.cancel()
        try? stdinHandle?.close()

        let exitCode: Int32
        if let process {
            if process.isRunning {
                exitCode = NativeProcessTree.terminate(process: process)
            } else {
                exitCode = process.terminationStatus
            }
            if let resourceOwner { processRegistry.unregister(process.processIdentifier, owner: resourceOwner) }
        } else {
            exitCode = 0
        }
        failPending(
            HarnessAdapterError.processExited(code: exitCode, message: "Claude transport stopped")
        )
        messageContinuation.finish()
    }

    static func arguments(for configuration: ClaudeLaunchConfiguration) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", ClaudePermissionMode.launchArgument(for: configuration.permissionMode),
            // Makes Bypass permissions a mode the running session can switch to. It does not turn
            // the bypass on; only `--permission-mode bypassPermissions` or a later switch does.
            "--allow-dangerously-skip-permissions",
            "--include-partial-messages",
            "--input-format", "stream-json"
        ]
        if let source = configuration.forkSource {
            arguments.append(contentsOf: ["--resume=\(source.providerSessionID)", "--fork-session",
                "--session-id=\(configuration.providerSessionID)", "--resume-session-at=\(source.throughMessageID)"])
        } else if configuration.resumesExistingSession {
            arguments.append("--resume=\(configuration.providerSessionID)")
        } else {
            arguments.append("--session-id=\(configuration.providerSessionID)")
        }
        // A project's other roots are the only reason to widen the CLI's directory access. A
        // single-folder task launches with exactly the arguments it always used.
        let additionalRoots = configuration.additionalRoots
            .map { $0.standardizedFileURL.path(percentEncoded: false) }
        if !additionalRoots.isEmpty {
            arguments.append("--add-dir")
            arguments.append(contentsOf: additionalRoots)
        }
        // Claude in Chrome is the CLI's own flag. Yardlet passes it when the session asked for it
        // and stays silent otherwise, leaving the CLI's default and its own refusal untouched.
        if configuration.chromeIntegration {
            arguments.append("--chrome")
        }
        // The model the task chose. Without one the CLI runs the account's own model, as before.
        if let model = ClaudeLaunchOption.launchModel(configuration.model) {
            arguments.append(contentsOf: ["--model", model])
        }
        // A subagent's session leaves no conversation file; a task's launches as it always did.
        if configuration.keepsNoHistory {
            arguments.append("--no-session-persistence")
        }
        // Yardlet instructions: the same text on every launch of the task until the person edits it, so the
        // CLI's recorded system prompt and its prompt cache stay as they were. CLAUDE.md still loads.
        arguments.append(contentsOf: YardletInstructionsLaunch.claudeArguments(configuration.appendSystemPrompt))
        // Merged over the account's own settings as one more source; only this process reads it.
        if let settings = configuration.settings {
            arguments.append(contentsOf: ["--settings", settings])
        }
        // `--mcp-config` takes several values, so it goes last, where nothing else can be read as
        // one of them. Without `--strict-mcp-config` the user's own servers still load. The
        // server's task suggestion tools only show a chip, so they run without asking.
        if let path = configuration.agentToolConfigPath {
            arguments.append("--allowedTools")
            arguments.append(contentsOf: AgentToolServerLaunch.claudeAllowedTools)
            arguments.append(contentsOf: ["--mcp-config", path])
        }
        return arguments
    }

    private func environment() -> [String: String] {
        Self.environment(base: ProcessInfo.processInfo.environment, overrides: environmentOverrides,
                         claudeAIConnectors: ClaudeAIConnectorPreference.isEnabled())
    }

    /// The longest a background Bash command may run, in milliseconds: the CLI's own ceiling
    /// (`Tae()` in 2.1.293 caps `BASH_MAX_TIMEOUT_MS` at 2^31 − 1, about 24.8 days).
    ///
    /// Run headless under any entrypoint but the Claude app's or VS Code's, the CLI stops a
    /// `run_in_background` command at a deadline: the command's `timeout`, else 30 minutes
    /// (`max(1800000, BASH_DEFAULT_TIMEOUT_MS)`), never past `max(2 h, BASH_MAX_TIMEOUT_MS)`. The
    /// Claude app's entrypoint has no deadline. `BASH_MAX_TIMEOUT_MS`, a documented Claude Code
    /// variable, raises that ceiling without the entrypoint, so the model can give a background
    /// command as long as it needs. The 30-minute default moves only with `BASH_DEFAULT_TIMEOUT_MS`,
    /// which is also the 2-minute point where a foreground command moves to the background, so it
    /// is left as it is. A value the user set in the environment wins.
    static let backgroundCommandCeilingMilliseconds = "2147483647"

    /// The CLI's environment: the app's own, the account's overrides, Yardlet's entrypoint and the
    /// variables the sessions rely on. Only the process Yardlet starts sees them; no settings file
    /// is written. Unless `claudeAIConnectors`, the account's claude.ai connectors stay out of the
    /// session (`ClaudeAIConnectorPreference`); turned on, the CLI's own default applies.
    static func environment(base: [String: String], overrides: [String: String],
                            claudeAIConnectors: Bool = false) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "CLAUDECODE")
        environment["CLAUDE_CODE_ENTRYPOINT"] = "native-harness-client"
        // The native desktop enables this too. The CLI owns snapshots and backup storage;
        // an older session without checkpoints is never synthesized from Git or cached text.
        var scoped = RuntimeProcessEnvironment.accountScoped(environment.merging(overrides) { _, new in new })
        scoped["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
        if scoped["BASH_MAX_TIMEOUT_MS"]?.isEmpty != false {
            scoped["BASH_MAX_TIMEOUT_MS"] = backgroundCommandCeilingMilliseconds
        }
        if !claudeAIConnectors {
            scoped[ClaudeAIConnectorPreference.environmentVariable] = "false"
        }
        return scoped
    }

    private func acceptStdoutChunk(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let value = try codec.decodeLine(line)
                accept(value, rawData: line)
            } catch {
                messageContinuation.yield(
                    ClaudeRawFrame(
                        value: .object([
                            "type": .string("transport_error"),
                            "message": .string(error.localizedDescription)
                        ]),
                        data: line
                    )
                )
            }
        }
    }

    private func accept(_ value: JSONValue, rawData: Data) {
        if value["type"]?.stringValue == "control_response",
           let response = value["response"],
           let requestID = response["request_id"]?.stringValue,
           let pendingRequest = pending.removeValue(forKey: requestID) {
            pendingRequest.timeoutTask.cancel()
            if response["subtype"]?.stringValue == "error" {
                pendingRequest.continuation.resume(
                    throwing: HarnessAdapterError.invalidProviderEvent(
                        response["error"]?.stringValue ?? "Claude control request failed"
                    )
                )
            } else {
                pendingRequest.continuation.resume(returning: response["response"] ?? .object([:]))
            }
            return
        }
        messageContinuation.yield(ClaudeRawFrame(value: value, data: rawData))
    }

    private func timeoutRequest(_ id: String) {
        guard let pendingRequest = pending.removeValue(forKey: id) else { return }
        pendingRequest.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                "Claude control request \(id) timed out"
            )
        )
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        let limit = 16 * 1024
        if stderrBuffer.count > limit {
            stderrBuffer.removeFirst(stderrBuffer.count - limit)
        }
    }

    /// Takes whatever the CLI wrote before it exited. A launch the CLI refuses — an unknown flag,
    /// a missing browser extension — says so on stderr and nowhere else, so the task reports those
    /// words rather than a guess about the cause.
    private func drainStderr() {
        guard let stderrHandle else { return }
        stderrHandle.readabilityHandler = nil
        if let remaining = try? stderrHandle.readToEnd(), !remaining.isEmpty {
            appendStderr(remaining)
        }
    }

    private func exitError(fallback: String) -> HarnessAdapterError {
        drainStderr()
        let detail = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HarnessAdapterError.processExited(
            code: process?.terminationStatus ?? -1,
            message: detail.isEmpty ? fallback : detail
        )
    }

    private func processDidTerminate(code: Int32) {
        chunkContinuation?.finish()
        drainStderr()
        let message = String(data: stderrBuffer, encoding: .utf8) ?? ""
        failPending(HarnessAdapterError.processExited(code: code, message: message))
        messageContinuation.finish()
    }

    private func failPending(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
