import Foundation

struct CodexRawFrame: Equatable, Sendable {
    let message: CodexRPCIncomingMessage
    let data: Data
}

protocol CodexTransport: Actor {
    func start() async throws
    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage
    func sendResponse(_ response: CodexRPCResponse) async throws
    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws
    func notifications() async -> AsyncStream<CodexRawFrame>
    func stop() async
}

actor CodexProcessTransport: CodexTransport {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<CodexRPCIncomingMessage, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let requestTimeout: Duration
    private let environmentManager: CodexEnvironmentManager?
    private let environmentScope: SessionEnvironmentScope
    private let codec = CodexRPCCodec()
    private let notificationStream: AsyncStream<CodexRawFrame>
    private let notificationContinuation: AsyncStream<CodexRawFrame>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    /// The reader has seen the end of the process's stdout.
    private var stdoutReachedEnd = false
    private var pending: [Int64: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stopped = false
    /// The App Server row its process tree counts toward in Task Resource Usage, when it serves tasks.
    private let resourceOwner: TaskResourceOwner?
    private let processRegistry: TaskProcessRegistry

    init(
        executableURL: URL,
        requestTimeout: Duration = .seconds(30),
        environmentManager: CodexEnvironmentManager? = nil,
        environmentScope: SessionEnvironmentScope = .native,
        resourceOwner: TaskResourceOwner? = nil,
        processRegistry: TaskProcessRegistry = .shared
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.requestTimeout = requestTimeout
        self.environmentManager = environmentManager
        self.environmentScope = environmentScope
        self.resourceOwner = resourceOwner
        self.processRegistry = processRegistry
        let notifications = AsyncStream<CodexRawFrame>.makeStream()
        self.notificationStream = notifications.stream
        self.notificationContinuation = notifications.continuation
    }

    func start() async throws {
        if let process, process.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: "Codex transport cannot restart after being stopped"
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        if let environmentManager {
            process.environment = try await environmentManager.processEnvironment(
                scope: environmentScope
            ).values
        }
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
        stdoutReachedEnd = false
        readerTask = Task { [weak self] in
            for await chunk in chunks.stream {
                await self?.acceptStdoutChunk(chunk)
            }
            await self?.stdoutDidEnd()
        }
    }

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        try await start()
        guard case let .integer(id) = request.id else {
            throw HarnessAdapterError.invalidProviderEvent("Client request ID must be numeric")
        }
        let data = try codec.encodeLine(request)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(id)
            }
            pending[id] = PendingRequest(
                method: request.method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try stdinHandle?.write(contentsOf: data)
            } catch {
                timeoutTask.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {
        guard process?.isRunning == true else {
            throw HarnessAdapterError.processExited(
                code: process?.terminationStatus ?? -1,
                message: "Codex App Server is not running"
            )
        }
        try stdinHandle?.write(contentsOf: codec.encodeLine(response))
    }

    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {
        guard process?.isRunning == true else {
            throw HarnessAdapterError.processExited(
                code: process?.terminationStatus ?? -1,
                message: "Codex App Server is not running"
            )
        }
        try stdinHandle?.write(contentsOf: codec.encodeLine(response))
    }

    func notifications() async -> AsyncStream<CodexRawFrame> {
        notificationStream
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
            HarnessAdapterError.processExited(
                code: exitCode,
                message: "Codex transport stopped"
            )
        )
        notificationContinuation.finish()
    }

    private func acceptStdoutChunk(_ chunk: Data) {
        // Only the new chunk can hold the end of the line being read: a large response (a whole
        // thread with its turns) arrives in many chunks, and looking through everything buffered on
        // each of them made reading it grow with the square of its size.
        let scanned = stdoutBuffer.count
        stdoutBuffer.append(chunk)
        var searchStart = stdoutBuffer.startIndex + scanned

        while let newline = stdoutBuffer[searchStart...].firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            searchStart = stdoutBuffer.startIndex
            guard !line.isEmpty else { continue }

            do {
                let message = try codec.decodeLine(line)
                accept(message: message, rawData: line)
            } catch {
                notificationContinuation.yield(
                    CodexRawFrame(
                        message: CodexRPCIncomingMessage(
                            id: nil,
                            method: "transport/decodeError",
                            params: .object(["message": .string(error.localizedDescription)]),
                            result: nil,
                            error: nil,
                            emittedAtMs: nil
                        ),
                        data: line
                    )
                )
            }
        }
    }

    private func accept(message: CodexRPCIncomingMessage, rawData: Data) {
        if message.method == nil, case let .integer(id)? = message.id,
           let pendingRequest = pending.removeValue(forKey: id) {
            pendingRequest.timeoutTask.cancel()
            if let error = message.error {
                pendingRequest.continuation.resume(
                    throwing: CodexRPCRequestFailure(requestID: id, payload: error)
                )
            } else {
                pendingRequest.continuation.resume(returning: message)
            }
            return
        }

        notificationContinuation.yield(CodexRawFrame(message: message, data: rawData))
    }

    /// A request the App Server never answers ends with the request it was, so the task can say
    /// what did not happen rather than only that something timed out.
    private func timeoutRequest(_ id: Int64) {
        guard let pendingRequest = pending.removeValue(forKey: id) else { return }
        pendingRequest.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                L10n.format("Codex did not answer %@ within %lld seconds.",
                            pendingRequest.method, requestTimeout.components.seconds)
            )
        )
    }

    private func stdoutDidEnd() { stdoutReachedEnd = true }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        let limit = 16 * 1024
        if stderrBuffer.count > limit {
            stderrBuffer.removeFirst(stderrBuffer.count - limit)
        }
    }

    private func processDidTerminate(code: Int32) async {
        // A response written just before the process exits can still be in the pipe when the exit
        // is reported. Let the reader reach the pipe's end by itself, then drain buffered frames
        // before publishing notification EOF; a child holding the pipe open is given one second.
        for _ in 0..<100 where readerTask != nil && !stdoutReachedEnd {
            try? await Task.sleep(for: .milliseconds(10))
        }
        chunkContinuation?.finish()
        await readerTask?.value
        let message = String(data: stderrBuffer, encoding: .utf8) ?? ""
        failPending(HarnessAdapterError.processExited(code: code, message: message))
        notificationContinuation.finish()
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
