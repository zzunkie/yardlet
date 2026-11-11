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

    private var channel: LineDelimitedProcessChannel?
    private var readerTask: Task<Void, Never>?
    private var pending: [Int64: PendingRequest] = [:]
    private var stopped = false

    init(executableURL: URL, requestTimeout: Duration = .seconds(300)) {
        self.executableURL = executableURL.standardizedFileURL
        self.requestTimeout = requestTimeout
        let messages = AsyncStream<ACPRawFrame>.makeStream()
        self.messageStream = messages.stream
        self.messageContinuation = messages.continuation
    }

    func start(_ configuration: ACPLaunchConfiguration) async throws {
        await LoginShellPath.ready()
        if let channel, channel.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: L10n.string("ACP transport cannot restart after being stopped")
            )
        }

        var environment = RuntimeProcessEnvironment.app
        for (key, value) in configuration.environmentOverrides {
            environment[key] = value
        }
        let channel = try LineDelimitedProcessChannel(
            .init(executableURL: executableURL,
                  arguments: configuration.arguments,
                  currentDirectoryURL: configuration.workspaceURL.standardizedFileURL,
                  environment: RuntimeProcessEnvironment.accountScoped(environment)),
            stderrLimit: 64 * 1024
        )
        self.channel = channel
        let events = channel.events
        readerTask = Task { [weak self] in
            for await event in events {
                await self?.accept(event)
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
        let channel = try runningChannel()
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
                try channel.write(data)
            } catch {
                timeoutTask?.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ value: JSONValue) async throws {
        try runningChannel().write(codec.encodeLine(value))
    }

    func messages() async -> AsyncStream<ACPRawFrame> { messageStream }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        let exitCode = channel?.stop() ?? 0
        failPending(
            HarnessAdapterError.processExited(code: exitCode, message: "ACP transport stopped")
        )
        messageContinuation.finish()
    }

    private func accept(_ event: LineDelimitedProcessChannel.Event) {
        switch event {
        case let .line(line):
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
        case let .exited(code, stderr):
            failPending(HarnessAdapterError.processExited(code: code, message: stderr))
            messageContinuation.finish()
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

    private func runningChannel() throws -> LineDelimitedProcessChannel {
        guard let channel, channel.isRunning else {
            let stderrText = channel?.stderrText ?? ""
            throw HarnessAdapterError.processExited(
                code: channel?.exitCode ?? -1,
                message: stderrText.isEmpty ? L10n.string("ACP agent is not running") : stderrText
            )
        }
        return channel
    }

    private func timeoutRequest(_ id: Int64) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                L10n.string("ACP request timed out")
            )
        )
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
