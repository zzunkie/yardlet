import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network

/// A WebSocket for v2 frames on Apple's platforms (docs/REMOTE_PROTOCOL.md §11.1), with the calls of the
/// `URLSessionWebSocketTask` it stands for elsewhere. v2 uses no extensions, so this is Network.framework's WebSocket,
/// as on the host's listener: it has none, and ends a connection whose response or frames use one.
final class RemoteClientWebSocket: @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    /// How the connection ended, in a reader's words.
    struct Ending: LocalizedError {
        var description: String
        var errorDescription: String? { description }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "yardlet.remote.websocket")
    private let lock = NSLock()
    private var code = CloseCode.invalid
    private var reason: Data?
    /// Why the connection ended. What is pending then fails with only "cancelled".
    private var ending: Ending?
    private var isOpen = false
    private var isClosing = false

    /// `timeout` limits reaching the peer; what comes after is the caller's to watch.
    static func connecting(to url: URL, maximumMessageSize: Int, timeout: TimeInterval = 60) -> RemoteClientWebSocket {
        RemoteClientWebSocket(url: url, maximumMessageSize: maximumMessageSize, timeout: timeout)
    }

    private init(url: URL, maximumMessageSize: Int, timeout: TimeInterval) {
        let websocket = NWProtocolWebSocket.Options()
        websocket.maximumMessageSize = maximumMessageSize
        websocket.autoReplyPing = true
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        // Keystrokes and requests sent together leave at once, not after the one before them is acknowledged.
        tcp.noDelay = true
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    var closeCode: CloseCode { lock.withLock { code } }
    var closeReason: Data? { lock.withLock { reason } }

    func resume() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                lock.withLock { isOpen = true }
            case let .waiting(error), let .failed(error):
                // Waiting is for the network to change; the caller's own retry decides when to try again.
                end("\(error)")
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel(with code: CloseCode, reason: Data?) {
        let (open, first) = lock.withLock { () -> (Bool, Bool) in
            defer { isClosing = true }
            if self.code == .invalid { self.code = code }
            return (isOpen, !isClosing)
        }
        guard first else { return }
        end("Cancelled")
        if open { sendClose(code.rawValue, reason: reason) } else { connection.cancel() }
    }

    func send(_ message: Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let content: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch message {
        case let .data(data): (content, opcode) = (data, .binary)
        case let .string(text): (content, opcode) = (Data(text.utf8), .text)
        @unknown default: return completionHandler(Ending(description: "Unknown message"))
        }
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: content, contentContext: context, isComplete: true, completion: .contentProcessed { [self] error in
            completionHandler(error.map(failure))
        })
    }

    func send(_ message: Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(message) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func receive(completionHandler: @escaping @Sendable (Result<Message, Error>) -> Void) {
        connection.receiveMessage { [self] data, context, _, error in
            if let error { return completionHandler(.failure(failure(error))) }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .binary?:
                completionHandler(.success(.data(data ?? Data())))
            case .text?:
                completionHandler(.success(.string(String(decoding: data ?? Data(), as: UTF8.self))))
            case .close?:
                closed(metadata?.closeCode, reason: data)
                completionHandler(.failure(end("The peer closed the connection")))
            case nil:
                // The stream ended without a close frame.
                connection.cancel()
                completionHandler(.failure(end("The connection ended")))
            default:
                receive(completionHandler: completionHandler)
            }
        }
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            receive { continuation.resume(with: $0) }
        }
    }

    /// The first reason the connection ended stands.
    @discardableResult
    private func end(_ reason: String) -> Ending {
        lock.withLock {
            let first = ending ?? Ending(description: reason)
            ending = first
            return first
        }
    }

    private func failure(_ error: Error) -> Error {
        end("\(error)")
    }

    /// The peer's close frame: it is answered, and the connection ends.
    private func closed(_ closeCode: NWProtocolWebSocket.CloseCode?, reason: Data?) {
        let first = lock.withLock { () -> Bool in
            defer { isClosing = true }
            code = closeCode.flatMap { CloseCode(rawValue: Self.rawValue($0)) } ?? .noStatusReceived
            self.reason = reason
            return !isClosing
        }
        if first { sendClose(CloseCode.normalClosure.rawValue, reason: nil) }
    }

    private func sendClose(_ raw: Int, reason: Data?) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = UInt16(exactly: raw).flatMap { try? NWProtocolWebSocket.CloseCode(rawValue: $0) } ?? .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: reason, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        // A peer that stopped reading never takes the close frame.
        queue.asyncAfter(deadline: .now() + Self.closeLimit) { [connection] in connection.forceCancel() }
    }

    private static let closeLimit: TimeInterval = 5

    private static func rawValue(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case let .protocolCode(defined): Int(defined.rawValue)
        case let .applicationCode(value), let .privateCode(value): Int(value)
        @unknown default: CloseCode.invalid.rawValue
        }
    }
}
#elseif !os(Linux)

/// Foundation here offers no extensions and has no other WebSocket. Linux has its own (`RemoteCurlWebSocket.swift`).
typealias RemoteClientWebSocket = URLSessionWebSocketTask

extension URLSessionWebSocketTask {
    static func connecting(to url: URL, maximumMessageSize: Int, timeout: TimeInterval = 60) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: timeout))
        task.maximumMessageSize = maximumMessageSize
        return task
    }
}
#endif
