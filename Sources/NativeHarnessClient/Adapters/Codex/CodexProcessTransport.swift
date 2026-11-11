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
        /// The App Server the request was written to, by `launches`; its exit ends the request.
        let launch: Int
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

    private var channel: LineDelimitedProcessChannel?
    /// How many App Servers this transport has started; `channel` is the last of them.
    private var launches = 0
    private var readerTask: Task<Void, Never>?
    private var pending: [Int64: PendingRequest] = [:]
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
        await LoginShellPath.ready()
        if let channel, channel.isRunning { return }
        try requireNotStopped()

        // Without a manager the App Server starts with Yardlet's own environment.
        let environment = try await environmentManager?.processEnvironment(scope: environmentScope).values
        // Another request may have started it, or `stop()` ended the transport, while this one waited.
        if let channel, channel.isRunning { return }
        try requireNotStopped()
        let channel = try LineDelimitedProcessChannel(
            .init(executableURL: executableURL,
                  arguments: ["app-server", "--stdio"],
                  environment: environment,
                  resourceOwner: resourceOwner,
                  processRegistry: processRegistry),
            stderrLimit: 16 * 1024
        )
        launches += 1
        let launch = launches
        self.channel = channel
        let events = channel.events
        readerTask = Task { [weak self] in
            for await event in events {
                await self?.accept(event, from: launch)
            }
        }
    }

    private func requireNotStopped() throws {
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: "Codex transport cannot restart after being stopped"
            )
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
                launch: launches,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try channel?.write(data)
            } catch {
                timeoutTask.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {
        try runningChannel().write(codec.encodeLine(response))
    }

    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {
        try runningChannel().write(codec.encodeLine(response))
    }

    func notifications() async -> AsyncStream<CodexRawFrame> {
        notificationStream
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        let exitCode = channel?.stop() ?? 0
        failPending(
            HarnessAdapterError.processExited(
                code: exitCode,
                message: "Codex transport stopped"
            )
        )
        notificationContinuation.finish()
    }

    private func runningChannel() throws -> LineDelimitedProcessChannel {
        guard let channel, channel.isRunning else {
            throw HarnessAdapterError.processExited(
                code: channel?.exitCode ?? -1,
                message: "Codex App Server is not running"
            )
        }
        return channel
    }

    private func accept(_ event: LineDelimitedProcessChannel.Event, from launch: Int) {
        switch event {
        case let .line(line):
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
        case let .exited(code, stderr):
            // The exit is reported once the App Server's output has been read, so a request may already
            // have started the next one: only what was sent to this one ends. The notifications end
            // either way, as when the exit comes first, since the connection they belong to has ended.
            failPending(HarnessAdapterError.processExited(code: code, message: stderr), sentTo: launch)
            notificationContinuation.finish()
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

    /// Ends the requests that wait on the App Server `launch` started, or on any App Server.
    private func failPending(_ error: Error, sentTo launch: Int? = nil) {
        let ended = pending.filter { launch == nil || $0.value.launch == launch }
        for id in ended.keys { pending.removeValue(forKey: id) }
        for request in ended.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
