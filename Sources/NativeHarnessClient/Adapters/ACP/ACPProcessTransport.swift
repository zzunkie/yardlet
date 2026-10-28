import Foundation

struct ACPLaunchConfiguration: Sendable {
    let arguments: [String]
    let workspaceURL: URL
    let environmentOverrides: [String: String]

    init(
        arguments: [String],
        workspaceURL: URL,
        environmentOverrides: [String: String] = [:]
    ) {
        self.arguments = arguments
        self.workspaceURL = workspaceURL
        self.environmentOverrides = environmentOverrides
    }
}

protocol ACPTransport: Actor {
    func start(_ configuration: ACPLaunchConfiguration) async throws
    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue
    func requestWithoutTimeout(_ value: JSONValue, id: Int64) async throws -> JSONValue
    func send(_ value: JSONValue) async throws
    func messages() async -> AsyncStream<ACPRawFrame>
    func stop() async
}

extension ACPTransport {
    func requestWithoutTimeout(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        try await request(value, id: id)
    }
}

actor ACPProcessTransport: ACPTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>?
    }

    private let executableURL: URL
    private let requestTimeout: Duration
    private let codec = ACPWireCodec()
    private let messageStream: AsyncStream<ACPRawFrame>
    private let messageContinuation: AsyncStream<ACPRawFrame>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var pending: [Int64: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stopped = false

    init(executableURL: URL, requestTimeout: Duration = .seconds(300)) {
        self.executableURL = executableURL.standardizedFileURL
        self.requestTimeout = requestTimeout
        let messages = AsyncStream<ACPRawFrame>.makeStream()
        self.messageStream = messages.stream
        self.messageContinuation = messages.continuation
    }

    func start(_ configuration: ACPLaunchConfiguration) async throws {
        if let process, process.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: L10n.string("ACP transport cannot restart after being stopped")
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workspaceURL.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environmentOverrides {
            environment[key] = value
        }
        process.environment = RuntimeProcessEnvironment.accountScoped(environment)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let chunks = AsyncStream<Data>.makeStream()
        chunkContinuation = chunks.continuation
        stdoutPipe.fileHandleForReading.readChunks(into: chunks.continuation)
        stderrPipe.fileHandleForReading.readChunks { [weak self] data in
            Task { await self?.appendStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidTerminate(code: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

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

    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        try await request(value, id: id, timeout: requestTimeout)
    }

    func requestWithoutTimeout(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        try await request(value, id: id, timeout: nil)
    }

    private func request(
        _ value: JSONValue,
        id: Int64,
        timeout: Duration?
    ) async throws -> JSONValue {
        try requireRunning()
        let data = try codec.encodeLine(value)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = timeout.map { timeout in
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutRequest(id)
                }
            }
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
            do {
                try stdinHandle?.write(contentsOf: data)
            } catch {
                timeoutTask?.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ value: JSONValue) async throws {
        try requireRunning()
        try stdinHandle?.write(contentsOf: codec.encodeLine(value))
    }

    func messages() async -> AsyncStream<ACPRawFrame> { messageStream }

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
        } else {
            exitCode = 0
        }
        failPending(
            HarnessAdapterError.processExited(code: exitCode, message: "ACP transport stopped")
        )
        messageContinuation.finish()
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
                    ACPRawFrame(
                        value: .object([
                            "method": .string("transport/error"),
                            "params": .object(["message": .string(error.localizedDescription)])
                        ]),
                        data: line
                    )
                )
            }
        }
    }

    private func accept(_ value: JSONValue, rawData: Data) {
        if let id = value["id"]?.integerValue,
           value["method"] == nil,
           let pendingRequest = pending.removeValue(forKey: id) {
            pendingRequest.timeoutTask?.cancel()
            if let error = value["error"] {
                pendingRequest.continuation.resume(
                    throwing: HarnessAdapterError.invalidProviderEvent(
                        error["message"]?.stringValue ?? L10n.string("ACP request failed")
                    )
                )
            } else {
                pendingRequest.continuation.resume(returning: value["result"] ?? .object([:]))
            }
            return
        }
        messageContinuation.yield(ACPRawFrame(value: value, data: rawData))
    }

    private func requireRunning() throws {
        guard process?.isRunning == true else {
            throw HarnessAdapterError.processExited(
                code: process?.terminationStatus ?? -1,
                message: stderrText.isEmpty ? L10n.string("ACP agent is not running") : stderrText
            )
        }
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > 64 * 1024 {
            stderrBuffer = Data(stderrBuffer.suffix(64 * 1024))
        }
    }

    private var stderrText: String {
        String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timeoutRequest(_ id: Int64) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                L10n.string("ACP request timed out")
            )
        )
    }

    private func processDidTerminate(code: Int32) {
        failPending(HarnessAdapterError.processExited(code: code, message: stderrText))
        messageContinuation.finish()
    }

    private func failPending(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
