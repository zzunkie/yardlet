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

    private var channel: LineDelimitedProcessChannel?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: PendingRequest] = [:]
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
        await LoginShellPath.ready()
        if let channel, channel.isRunning { return }
        guard !stopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: L10n.string("Pi RPC transport cannot restart after being stopped")
            )
        }

        let channel = try LineDelimitedProcessChannel(
            .init(executableURL: executableURL,
                  arguments: configuration.arguments,
                  currentDirectoryURL: configuration.workspaceURL.standardizedFileURL,
                  environment: RuntimeProcessEnvironment.values(executableURL: executableURL,
                                                                overrides: environmentOverrides)),
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

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        let channel = try runningChannel()
        let data = try codec.encodeLine(value)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(id)
            }
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
            do {
                try channel.write(data)
            } catch {
                timeoutTask.cancel()
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ value: JSONValue) async throws {
        try runningChannel().write(codec.encodeLine(value))
    }

    func messages() async -> AsyncStream<PiRPCRawFrame> { messageStream }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        let exitCode = channel?.stop() ?? 0
        failPending(
            HarnessAdapterError.processExited(
                code: exitCode,
                message: L10n.string("Pi RPC transport stopped")
            )
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
                    PiRPCRawFrame(
                        value: .object([
                            "type": .string("transport_error"),
                            "error": .string(error.localizedDescription)
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

    private func runningChannel() throws -> LineDelimitedProcessChannel {
        guard let channel, channel.isRunning else {
            let stderrText = channel?.stderrText ?? ""
            throw HarnessAdapterError.processExited(
                code: channel?.exitCode ?? -1,
                message: stderrText.isEmpty ? L10n.string("Pi RPC agent is not running") : stderrText
            )
        }
        return channel
    }

    private func timeoutRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: HarnessAdapterError.invalidProviderEvent(
                L10n.string("Pi RPC request timed out")
            )
        )
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
