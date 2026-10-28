import Foundation

struct PiRPCLaunchConfiguration: Sendable {
    let arguments: [String]
    let workspaceURL: URL
}

protocol PiRPCTransport: Actor {
    func start(_ configuration: PiRPCLaunchConfiguration) async throws
    func request(_ value: JSONValue, id: String) async throws -> JSONValue
    func send(_ value: JSONValue) async throws
    func messages() async -> AsyncStream<PiRPCRawFrame>
    func stop() async
}

actor PiRPCProcessTransport: PiRPCTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let environmentOverrides: [String: String]
    private let requestTimeout: Duration
    private let codec = PiRPCWireCodec()
    private let messageStream: AsyncStream<PiRPCRawFrame>
    private let messageContinuation: AsyncStream<PiRPCRawFrame>.Continuation

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

    init(executableURL: URL, environmentOverrides: [String: String] = [:], requestTimeout: Duration = .seconds(60)) {
        self.executableURL = executableURL.standardizedFileURL
        self.environmentOverrides = environmentOverrides
        self.requestTimeout = requestTimeout
        let messages = AsyncStream<PiRPCRawFrame>.makeStream()
        messageStream = messages.stream
        messageContinuation = messages.continuation
    }

    func start(_ configuration: PiRPCLaunchConfiguration) async throws {
        if let process, process.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: L10n.string("Pi RPC transport cannot restart after being stopped")
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workspaceURL.standardizedFileURL
        process.environment = RuntimeProcessEnvironment.values(executableURL: executableURL, overrides: environmentOverrides)
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

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        try requireRunning()
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
        try requireRunning()
        try stdinHandle?.write(contentsOf: codec.encodeLine(value))
    }

    func messages() async -> AsyncStream<PiRPCRawFrame> { messageStream }

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
            HarnessAdapterError.processExited(
                code: exitCode,
                message: L10n.string("Pi RPC transport stopped")
            )
        )
        messageContinuation.finish()
    }

    private func acceptStdoutChunk(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            do {
                let value = try codec.decodeLine(line)
                accept(value, rawData: line)
            } catch {
                messageContinuation.yield(
                    PiRPCRawFrame(
                        value: .object([
                            "type": .string("transport_error"),
                            "error": .string(error.localizedDescription)
                        ]),
                        data: line
                    )
                )
            }
        }
    }

    private func accept(_ value: JSONValue, rawData: Data) {
        if value["type"]?.stringValue == "response",
           let id = value["id"]?.stringValue,
           let request = pending.removeValue(forKey: id) {
            request.timeoutTask.cancel()
            if value["success"]?.boolValue == false {
                request.continuation.resume(
                    throwing: HarnessAdapterError.invalidProviderEvent(
                        value["error"]?.stringValue ?? L10n.string("Pi RPC request failed")
                    )
                )
            } else {
                request.continuation.resume(returning: value)
            }
            return
        }
        messageContinuation.yield(PiRPCRawFrame(value: value, data: rawData))
    }

    private func requireRunning() throws {
        guard process?.isRunning == true else {
            throw HarnessAdapterError.processExited(
                code: process?.terminationStatus ?? -1,
                message: stderrText.isEmpty ? L10n.string("Pi RPC agent is not running") : stderrText
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

    private func timeoutRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                L10n.string("Pi RPC request timed out")
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
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
