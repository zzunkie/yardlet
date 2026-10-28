import Foundation
import YardletAgentTools

/// A stdio MCP server Yardlet started: it writes newline-delimited JSON-RPC to the server's
/// standard input and reads the server's lines back.
protocol MCPStdioChannel: AnyObject, Sendable {
    /// The server's standard output, a line at a time; it ends when the server exits.
    var lines: AsyncStream<String> { get }
    /// Writes one message followed by a newline.
    func send(_ message: Data) throws
    /// The end of what the server wrote to standard error, which says why it stopped.
    func errorTail() -> String
    func terminate()
}

/// Starts the server, once per connection.
protocol MCPStdioLaunching: Sendable {
    func launch() throws -> any MCPStdioChannel
}

enum MCPStdioError: Error, Equatable, LocalizedError {
    case cannotStart(String)
    /// The server exited; what it wrote to standard error, if anything.
    case exited(String)
    case rpc(code: Int64, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cannotStart(let reason): "The server could not start: \(reason)"
        case .exited(let reason): reason.isEmpty ? "The server stopped." : reason
        case .rpc(_, let message): message
        case .invalidResponse: "The server's answer could not be read."
        }
    }
}

/// An MCP client over a server's standard input and output (MCP "stdio" transport): Xcode's
/// `mcpbridge`. Requests run concurrently and meet their replies by ID. The server starts on the
/// first request and again on the first request after it exits; nothing restarts it otherwise. A
/// request the caller cancels is cancelled at the server too. Requests have no time limit of their
/// own, since a build or a test run takes minutes; the harness's limit for a tool call applies.
actor MCPStdioClient {
    private let launcher: any MCPStdioLaunching
    private let clientVersion: String
    private var channel: (any MCPStdioChannel)?
    private var reader: Task<Void, Never>?
    private var pending: [Int64: CheckedContinuation<ToolJSON, Error>] = [:]
    private var initialized = false
    private var initialization: Task<Void, Error>?
    private var nextID: Int64 = 1
    /// Why the last server stopped, for a request that finds it gone.
    private var lastReason = ""

    init(launcher: any MCPStdioLaunching, clientVersion: String) {
        self.launcher = launcher
        self.clientVersion = clientVersion
    }

    func listTools() async throws -> [ToolJSON] {
        var tools: [ToolJSON] = []
        var cursor: String?
        repeat {
            let params: ToolJSON = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await request("tools/list", params)
            tools += result["tools"]?.arrayValue ?? []
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && tools.count < 2_000
        return tools
    }

    /// The server's `CallToolResult` as sent.
    func callTool(name: String, arguments: ToolJSON) async throws -> ToolJSON {
        try await request("tools/call", .object(["name": .string(name), "arguments": arguments]))
    }

    /// Ends the server; the next request starts it again.
    func close() {
        let channel = channel
        stop(MCPStdioError.exited(""))
        channel?.terminate()
    }

    private func request(_ method: String, _ params: ToolJSON) async throws -> ToolJSON {
        try await initializeIfNeeded()
        return try await send(method, params)
    }

    /// Concurrent first requests share one start and one `initialize`.
    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        if let initialization { return try await initialization.value }
        let task = Task { try await self.start() }
        initialization = task
        defer { initialization = nil }
        try await task.value
    }

    private func start() async throws {
        if channel == nil {
            let channel: any MCPStdioChannel
            do {
                channel = try launcher.launch()
            } catch {
                throw MCPStdioError.cannotStart((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.channel = channel
            reader = Task { [weak self] in
                for await line in channel.lines {
                    await self?.receive(line)
                }
                await self?.serverExited(channel)
            }
        }
        _ = try await send("initialize", .object([
            "protocolVersion": .string(MCPHTTPClient.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("yardlet"),
                "title": .string("Yardlet"),
                "version": .string(clientVersion)
            ])
        ]))
        try write(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        initialized = true
    }

    private func send(_ method: String, _ params: ToolJSON) async throws -> ToolJSON {
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                pending[id] = continuation
                do {
                    try write(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .integer(id),
                        "method": .string(method),
                        "params": params
                    ]))
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int64) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        try? write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .integer(id), "reason": .string("The caller cancelled the request.")])
        ]))
        continuation.resume(throwing: CancellationError())
    }

    private func write(_ message: ToolJSON) throws {
        guard let channel else { throw MCPStdioError.exited(lastReason) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            try channel.send(encoder.encode(message))
        } catch {
            throw MCPStdioError.exited(Self.reason(channel.errorTail()))
        }
    }

    /// A reply meets its request; a request from the server gets an answer (`ping`) or a refusal,
    /// since Yardlet offers it nothing; a notification is let pass.
    private func receive(_ line: String) {
        guard let message = try? JSONDecoder().decode(ToolJSON.self, from: Data(line.utf8)) else { return }
        let id: Int64? = if case .integer(let value) = message["id"] { value } else { nil }
        if let method = message["method"]?.stringValue {
            guard let requestID = message["id"], requestID != .null else { return }
            let reply: ToolJSON = method == "ping"
                ? .object(["jsonrpc": .string("2.0"), "id": requestID, "result": .object([:])])
                : .object(["jsonrpc": .string("2.0"), "id": requestID,
                           "error": .object(["code": .integer(-32601), "message": .string("Method not found")])])
            try? write(reply)
            return
        }
        guard let id, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            let code: Int64 = if case .integer(let value) = error["code"] { value } else { 0 }
            continuation.resume(throwing: MCPStdioError.rpc(code: code, message: error["message"]?.stringValue ?? "Error \(code)"))
        } else if let result = message["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: MCPStdioError.invalidResponse)
        }
    }

    private func serverExited(_ exited: any MCPStdioChannel) {
        guard channel === exited else { return }
        lastReason = Self.reason(exited.errorTail())
        stop(MCPStdioError.exited(lastReason))
    }

    /// Forgets the server and fails what waits on it.
    private func stop(_ failure: Error) {
        channel = nil
        reader = nil
        initialized = false
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: failure) }
    }

    /// The server's last words, without the `error:` a command-line tool puts first.
    static func reason(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return "" }
        for prefix in ["error: ", "Error: "] where last.hasPrefix(prefix) { return String(last.dropFirst(prefix.count)) }
        return last
    }
}

/// A server run as a child process of Yardlet, so macOS and the server see Yardlet as the one asking
/// (Xcode names the app that connects). Its standard input closing ends it when Yardlet quits.
struct ProcessMCPStdioLauncher: MCPStdioLaunching {
    let executable: URL
    var arguments: [String] = []
    /// The whole environment it starts with; nil for Yardlet's own.
    var environment: [String: String]? = nil
    var directory: URL? = nil

    func launch() throws -> any MCPStdioChannel {
        try ProcessMCPStdioChannel(executable: executable, arguments: arguments, environment: environment, directory: directory)
    }
}

final class ProcessMCPStdioChannel: MCPStdioChannel, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var errors = Data()
    /// Output read but not yet ended by a newline. Only the output handler, which runs one call at
    /// a time, touches it.
    private var partial = Data()
    /// The last of standard error kept, enough for the reason a server gives.
    private static let errorLimit = 4_096

    init(executable: URL, arguments: [String], environment: [String: String]? = nil, directory: URL? = nil) throws {
        let output = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lines = stream
        // The lines end once both outputs have, so the reason the server wrote last is kept by
        // the time its client reads it.
        let ends = Ends { continuation.finish() }
        // Split at newline bytes only: a JSON string may hold U+2028, which line readers also end
        // a line at, and the encoder escapes every real newline.
        output.fileHandleForReading.readChunks { [weak self] data in
            guard let self else { return }
            partial.append(data)
            while let newline = partial.firstIndex(of: 0x0A) {
                continuation.yield(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                partial.removeSubrange(partial.startIndex...newline)
            }
        } atEnd: {
            ends.reached()
        }
        errorPipe.fileHandleForReading.readChunks { [weak self] data in
            self?.keepError(data)
        } atEnd: {
            ends.reached()
        }
        try process.run()
    }

    func send(_ message: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: message + Data("\n".utf8))
    }

    func errorTail() -> String {
        lock.withLock { String(decoding: errors, as: UTF8.self) }
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func keepError(_ data: Data) {
        lock.withLock {
            errors.append(data)
            if errors.count > Self.errorLimit { errors = errors.suffix(Self.errorLimit) }
        }
    }

    deinit {
        terminate()
    }

    /// Calls `done` when standard output and standard error have both ended.
    private final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = 2
        private let done: @Sendable () -> Void

        init(_ done: @escaping @Sendable () -> Void) {
            self.done = done
        }

        func reached() {
            let last = lock.withLock {
                remaining -= 1
                return remaining == 0
            }
            if last { done() }
        }
    }
}
