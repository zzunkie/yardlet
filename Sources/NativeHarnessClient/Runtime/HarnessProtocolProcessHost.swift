import Foundation

struct HarnessProtocolAdapterLaunchConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let workspaceURL: URL
    let environmentOverrides: [String: String]

    init(
        executableURL: URL,
        arguments: [String] = [],
        workspaceURL: URL,
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.environmentOverrides = environmentOverrides
    }
}

struct HarnessProtocolProcessSession: Equatable, Sendable {
    let manifest: HarnessAdapterManifest
    let version: HarnessProtocolVersion
    let processID: Int32
}

struct HarnessProtocolProcessDiagnostics: Equatable, Sendable {
    let phase: HarnessProtocolHostPhase
    let processID: Int32?
    let stderr: String
    let terminalError: HarnessProtocolProcessHostError?
}

enum HarnessProtocolProcessHostError: Error, Equatable, Sendable {
    case alreadyStarted
    case restartNotSupported
    case processLaunchFailed(String)
    case protocolViolation(HarnessProtocolHostError)
    case unexpectedInboundFrame(String)
    case invalidFrame
    case lineTooLarge(limit: Int)
    case emptyRequestID
    case duplicateRequestID(String)
    case requestNotAdmitted(HarnessProtocolMethodAdmissionError)
    case invalidRequest(HarnessProtocolRequestSchemaError)
    case invalidResponseShape(String)
    case unexpectedResponse(String)
    case adapterError(id: String, error: HarnessProtocolResponseError)
    case requestTimedOut(String)
    case cancelled
    case writeFailed(String)
    case processExited(code: Int32, message: String)
    case stopped
}

/// Supervises one independently installed Yardlet Harness Protocol adapter.
///
/// The adapter owns stdout and must send exactly one `hello` JSONL frame first.
/// After Yardlet replies with `ready`, Yardlet sends requests while the adapter
/// may send only responses and events. Any other direction fails the connection
/// and terminates the app-owned process tree.
actor HarnessProtocolProcessHost {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let hostVersions: [HarnessProtocolVersion]
    private let handshakeTimeout: TimeInterval
    private let requestTimeout: Duration
    private let maximumLineBytes: Int
    private let maximumStderrBytes: Int
    private let codec = HarnessProtocolJSONLCodec()
    private let eventStream: AsyncStream<HarnessProtocolEventEnvelope>
    private let eventContinuation: AsyncStream<HarnessProtocolEventEnvelope>.Continuation

    private var connection: HarnessProtocolHostConnection
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var handshakeContinuation: CheckedContinuation<HarnessProtocolProcessSession, Error>?
    private var pending: [String: PendingRequest] = [:]
    private var submittedRequestIDs: Set<String> = []
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var launched = false
    private var stopped = false
    private var terminalError: HarnessProtocolProcessHostError?

    init(
        hostVersions: [HarnessProtocolVersion] = HarnessProtocolVersion.hostSupported,
        handshakeTimeout: TimeInterval = 5,
        requestTimeout: Duration = .seconds(60),
        maximumLineBytes: Int = 1_048_576,
        maximumStderrBytes: Int = 65_536
    ) {
        self.hostVersions = hostVersions
        self.handshakeTimeout = max(0, handshakeTimeout)
        self.requestTimeout = requestTimeout
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumStderrBytes = max(1, maximumStderrBytes)
        self.connection = HarnessProtocolHostConnection(
            hostVersions: hostVersions,
            handshakeTimeout: handshakeTimeout
        )
        let events = AsyncStream<HarnessProtocolEventEnvelope>.makeStream()
        self.eventStream = events.stream
        self.eventContinuation = events.continuation
    }

    func start(
        _ configuration: HarnessProtocolAdapterLaunchConfiguration
    ) async throws -> HarnessProtocolProcessSession {
        guard !launched else {
            throw stopped
                ? HarnessProtocolProcessHostError.restartNotSupported
                : HarnessProtocolProcessHostError.alreadyStarted
        }
        launched = true
        connection = HarnessProtocolHostConnection(
            hostVersions: hostVersions,
            handshakeTimeout: handshakeTimeout
        )

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workspaceURL
        process.environment = RuntimeProcessEnvironment.values(
            executableURL: configuration.executableURL,
            overrides: configuration.environmentOverrides
        )
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
            let hostError = HarnessProtocolProcessHostError.processLaunchFailed(
                error.localizedDescription
            )
            terminalError = hostError
            eventContinuation.finish()
            throw hostError
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
        handshakeTimeoutTask = Task { [weak self, handshakeTimeout] in
            try? await Task.sleep(for: .seconds(handshakeTimeout))
            guard !Task.isCancelled else { return }
            await self?.handshakeDidTimeOut()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshakeContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelHandshake() }
        }
    }

    func request(_ request: HarnessProtocolRequest) async throws -> JSONValue {
        guard terminalError == nil, !stopped else {
            throw terminalError ?? .stopped
        }
        guard case let .active(manifest, version) = connection.phase else {
            throw HarnessProtocolProcessHostError.protocolViolation(.connectionClosed)
        }
        guard !request.id.isEmpty else {
            throw HarnessProtocolProcessHostError.emptyRequestID
        }
        guard submittedRequestIDs.insert(request.id).inserted else {
            throw HarnessProtocolProcessHostError.duplicateRequestID(request.id)
        }
        do {
            try HarnessProtocolMethodAdmission.validate(request.method, manifest: manifest)
        } catch let error as HarnessProtocolMethodAdmissionError {
            submittedRequestIDs.remove(request.id)
            throw HarnessProtocolProcessHostError.requestNotAdmitted(error)
        }
        do {
            try HarnessProtocolRequestSchema.validate(request, manifest: manifest)
        } catch let error as HarnessProtocolRequestSchemaError {
            submittedRequestIDs.remove(request.id)
            throw HarnessProtocolProcessHostError.invalidRequest(error)
        }

        let data: Data
        do {
            data = try codec.encodeLine(.request(version: version, request))
        } catch {
            submittedRequestIDs.remove(request.id)
            throw HarnessProtocolProcessHostError.writeFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self, requestTimeout] in
                    try? await Task.sleep(for: requestTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.requestDidTimeOut(request.id)
                }
                pending[request.id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try stdinHandle?.write(contentsOf: data)
                } catch {
                    timeoutTask.cancel()
                    pending.removeValue(forKey: request.id)
                    continuation.resume(
                        throwing: HarnessProtocolProcessHostError.writeFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(request.id) }
        }
    }

    func events() -> AsyncStream<HarnessProtocolEventEnvelope> { eventStream }

    func diagnostics() -> HarnessProtocolProcessDiagnostics {
        HarnessProtocolProcessDiagnostics(
            phase: connection.phase,
            processID: process?.processIdentifier,
            stderr: stderrText,
            terminalError: terminalError
        )
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if terminalError == nil {
            terminalError = .stopped
        }
        connection.close()
        finishIO()
        resumeHandshake(throwing: .stopped)
        failPending(.stopped)
        terminateProcessIfNeeded()
        eventContinuation.finish()
    }

    private func acceptStdoutChunk(_ chunk: Data) {
        guard terminalError == nil else { return }
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineByteCount = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: newline)
            guard lineByteCount <= maximumLineBytes else {
                fail(.lineTooLarge(limit: maximumLineBytes))
                return
            }
            var line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            do {
                try accept(codec.decodeLine(line))
            } catch let error as HarnessProtocolProcessHostError {
                fail(error)
                return
            } catch let error as HarnessProtocolHostError {
                fail(.protocolViolation(error))
                return
            } catch {
                fail(.invalidFrame)
                return
            }
        }
        if stdoutBuffer.count > maximumLineBytes {
            fail(.lineTooLarge(limit: maximumLineBytes))
        }
    }

    private func accept(_ frame: HarnessProtocolFrame) throws {
        switch connection.phase {
        case .awaitingHello:
            let action = try connection.accept(frame)
            guard case let .send(readyFrame) = action,
                  case let .active(manifest, version) = connection.phase,
                  let process
            else {
                throw HarnessProtocolProcessHostError.invalidFrame
            }
            do {
                try stdinHandle?.write(contentsOf: codec.encodeLine(readyFrame))
            } catch {
                throw HarnessProtocolProcessHostError.writeFailed(error.localizedDescription)
            }
            resumeHandshake(
                returning: HarnessProtocolProcessSession(
                    manifest: manifest,
                    version: version,
                    processID: process.processIdentifier
                )
            )

        case .active:
            switch frame {
            case .hello, .ready, .request:
                throw HarnessProtocolProcessHostError.unexpectedInboundFrame(frame.kindName)
            case .response:
                let action = try connection.accept(frame)
                guard case let .acceptedResponse(response) = action else {
                    throw HarnessProtocolProcessHostError.invalidFrame
                }
                try accept(response)
            case .event:
                let action = try connection.accept(frame)
                guard case let .acceptedEvent(event) = action else {
                    throw HarnessProtocolProcessHostError.invalidFrame
                }
                eventContinuation.yield(event)
            }

        case let .failed(error):
            throw HarnessProtocolProcessHostError.protocolViolation(error)
        case .closed:
            throw HarnessProtocolProcessHostError.stopped
        }
    }

    private func accept(_ response: HarnessProtocolResponse) throws {
        guard (response.result == nil) != (response.error == nil) else {
            throw HarnessProtocolProcessHostError.invalidResponseShape(response.id)
        }
        guard let request = pending.removeValue(forKey: response.id) else {
            throw HarnessProtocolProcessHostError.unexpectedResponse(response.id)
        }
        request.timeoutTask.cancel()
        if let error = response.error {
            request.continuation.resume(
                throwing: HarnessProtocolProcessHostError.adapterError(
                    id: response.id,
                    error: error
                )
            )
        } else if let result = response.result {
            request.continuation.resume(returning: result)
        }
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > maximumStderrBytes {
            stderrBuffer = Data(stderrBuffer.suffix(maximumStderrBytes))
        }
    }

    private var stderrText: String {
        String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handshakeDidTimeOut() {
        guard case .awaitingHello = connection.phase else { return }
        do {
            try connection.checkHandshakeDeadline(at: .distantFuture)
        } catch let error as HarnessProtocolHostError {
            fail(.protocolViolation(error))
        } catch {
            fail(.invalidFrame)
        }
    }

    private func requestDidTimeOut(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: HarnessProtocolProcessHostError.requestTimedOut(id)
        )
    }

    private func cancelHandshake() {
        guard handshakeContinuation != nil else { return }
        fail(.cancelled)
    }

    private func cancelRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(
            throwing: HarnessProtocolProcessHostError.cancelled
        )
    }

    private func processDidTerminate(code: Int32) {
        guard terminalError == nil else { return }
        do {
            try connection.adapterExited(code: code)
        } catch let error as HarnessProtocolHostError {
            fail(.protocolViolation(error), terminateProcess: false)
            return
        } catch {
            fail(.invalidFrame, terminateProcess: false)
            return
        }
        fail(
            .processExited(code: code, message: stderrText),
            terminateProcess: false
        )
    }

    private func fail(
        _ error: HarnessProtocolProcessHostError,
        terminateProcess: Bool = true
    ) {
        guard terminalError == nil else { return }
        terminalError = error
        finishIO()
        resumeHandshake(throwing: error)
        failPending(error)
        if terminateProcess {
            terminateProcessIfNeeded()
        }
        eventContinuation.finish()
    }

    private func finishIO() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        readerTask?.cancel()
        readerTask = nil
        try? stdinHandle?.close()
    }

    private func terminateProcessIfNeeded() {
        guard let process, process.isRunning else { return }
        _ = NativeProcessTree.terminate(process: process)
    }

    private func resumeHandshake(returning session: HarnessProtocolProcessSession) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        continuation?.resume(returning: session)
    }

    private func resumeHandshake(throwing error: HarnessProtocolProcessHostError) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func failPending(_ error: HarnessProtocolProcessHostError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

private extension HarnessProtocolFrame {
    var kindName: String {
        switch self {
        case .hello: "hello"
        case .ready: "ready"
        case .request: "request"
        case .response: "response"
        case .event: "event"
        }
    }
}
