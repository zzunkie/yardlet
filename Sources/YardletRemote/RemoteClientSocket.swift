import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client's side of one v2 connection (docs/REMOTE_PROTOCOL.md §11–§13), as a phone has it: a
/// WebSocket to the host, directly or through the relay, the Noise IK handshake as the initiator, then
/// JSON messages encrypted and cut into chunks both ways. Yardlet on another computer uses it to follow
/// a host's tasks.
public final class RemoteClientSocket: @unchecked Sendable {
    /// Why the connection ended.
    public struct Closing: Equatable, Sendable {
        /// The WebSocket close code, when the host or the relay sent one.
        public var code: Int?
        public var reason: String

        public init(code: Int?, reason: String) {
            self.code = code
            self.reason = reason
        }

        /// The host removed this device, or never knew its key (§3.4, §13.1).
        public var isRevoked: Bool { code == Int(RemoteCloseCode.revoked.rawValue) }
    }

    public struct Failure: Error, Equatable, Sendable {
        public var reason: String
        /// The host's answer in message 2, when it refused.
        public var error: RemoteError?
        public var closeCode: Int?

        public init(_ reason: String, error: RemoteError? = nil, closeCode: Int? = nil) {
            self.reason = reason
            self.error = error
            self.closeCode = closeCode
        }
    }

    private let lock = NSLock()
    private let task: RemoteClientWebSocket
    private var sender: RemoteNoiseCipher
    private var receiver: RemoteNoiseCipher
    private var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxServerMessageBytes)
    private var pieces = RemoteFramePieces(limit: RemoteNoise.maxMessageLength)
    /// Frames waiting for the socket, in order: a message's chunks never interleave with another's.
    private var outbox: [Data] = []
    private var isSending = false
    private var closed = false
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (Closing) -> Void)?
    /// Messages and the close that came before the handlers were set.
    private var early: [Data] = []
    private var earlyClose: Closing?
    private var received = Date()

    private init(task: RemoteClientWebSocket, sender: RemoteNoiseCipher, receiver: RemoteNoiseCipher) {
        self.task = task
        self.sender = sender
        self.receiver = receiver
    }

    /// Opens a WebSocket to `url` and shakes hands with the host whose static key is `hostKey`. Fails
    /// when the socket, the handshake or message 2 does not complete within `timeout`, or when the host
    /// refuses (`Failure.error`).
    public static func open(url: URL, clientKey: RemoteKeyPair, hostKey: Data, hello: RemoteHandshakeHello,
                            timeout: TimeInterval) async throws -> (RemoteClientSocket, RemoteHandshakeReply) {
        let task = RemoteClientWebSocket.connecting(to: url, maximumMessageSize: RemoteNoise.maxMessageLength + 1, timeout: timeout)
        task.resume()
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await handshake(task: task, clientKey: clientKey, hostKey: hostKey, hello: hello)
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func handshake(task: RemoteClientWebSocket, clientKey: RemoteKeyPair, hostKey: Data,
                                  hello: RemoteHandshakeHello) async throws -> (RemoteClientSocket, RemoteHandshakeReply) {
        do {
            var noise = try RemoteNoiseHandshake(role: .initiator, localStatic: clientKey, remoteStatic: hostKey)
            try await task.send(.data(noise.writeMessage1(payload: Data(RemoteJSON.string(hello).utf8))))
            // Message 2 too may come in pieces (`RemoteFramePieces`); each try reads on a copy of the handshake.
            var pieces = RemoteFramePieces(limit: RemoteNoise.maxMessageLength)
            var payload: Data?
            while payload == nil {
                guard case let .data(piece) = try await task.receive() else { throw Failure("Expected a binary frame") }
                let outcome = try pieces.add(piece) { bytes in
                    var trial = noise
                    guard let read = try? trial.readMessage2(bytes) else { return false }
                    noise = trial
                    payload = read
                    return true
                }
                // Refused: read again for the handshake's own error.
                if outcome == .unreadable { _ = try noise.readMessage2(piece) }
            }
            let reply = try JSONDecoder().decode(RemoteHandshakeReply.self, from: payload ?? Data())
            let (sender, receiver) = noise.split()
            let socket = RemoteClientSocket(task: task, sender: sender, receiver: receiver)
            guard reply.ok || reply.pending == true else {
                task.cancel(with: .normalClosure, reason: nil)
                throw Failure(reply.error?.message ?? "Refused", error: reply.error)
            }
            socket.receive()
            return (socket, reply)
        } catch let failure as Failure {
            throw failure
        } catch {
            let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
            task.cancel(with: .normalClosure, reason: nil)
            throw Failure(error.localizedDescription, closeCode: code)
        }
    }

    /// Sets what receives each whole message, in order, and the close. Messages that came before are
    /// handed over first.
    public func start(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Closing) -> Void) {
        let (pending, close) = lock.withLock { () -> ([Data], Closing?) in
            self.onMessage = onMessage
            self.onClose = onClose
            defer { early = []; earlyClose = nil }
            return (early, earlyClose)
        }
        for message in pending { onMessage(message) }
        if let close { onClose(close) }
    }

    /// When the host last sent anything.
    public var lastReceived: Date { lock.withLock { received } }

    /// Sends one JSON message. Nothing is sent once the connection has closed.
    public func send(_ message: Data) {
        let start = lock.withLock { () -> Bool in
            guard !closed, var sender = Optional(self.sender),
                  let frames = try? RemoteNoiseFraming.seal(message, with: &sender) else { return false }
            self.sender = sender
            outbox += frames
            guard !isSending else { return false }
            isSending = true
            return true
        }
        if start { sendNext() }
    }

    public func close() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true; outbox = [] }
            return !closed
        }
        guard wasOpen else { return }
        task.cancel(with: .normalClosure, reason: nil)
        finish(Closing(code: nil, reason: "Closed"))
    }

    private func sendNext() {
        let frame = lock.withLock { () -> Data? in
            guard !closed, !outbox.isEmpty else {
                isSending = false
                return nil
            }
            return outbox.removeFirst()
        }
        guard let frame else { return }
        task.send(.data(frame)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.end(reason: error.localizedDescription)
            } else {
                self.sendNext()
            }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.data(piece)):
                var message: Data?
                let outcome: RemoteFramePieces.Outcome
                do {
                    outcome = try self.lock.withLock { () throws -> RemoteFramePieces.Outcome in
                        self.received = Date()
                        return try self.pieces.add(piece) { frame in
                            var receiver = self.receiver
                            do {
                                message = try self.joiner.add(frame, with: &receiver)
                            } catch let failure as RemoteNoise.Failure where failure == .undecryptable {
                                return false
                            }
                            self.receiver = receiver
                            return true
                        }
                    }
                } catch is RemoteFramePieces.TooLong {
                    self.task.cancel(with: .messageTooBig, reason: nil)
                    self.end(reason: "Message too long")
                    return
                } catch {
                    self.task.cancel(with: .normalClosure, reason: nil)
                    self.end(reason: "Unreadable message")
                    return
                }
                guard outcome != .unreadable else {
                    self.task.cancel(with: .normalClosure, reason: nil)
                    self.end(reason: "Unreadable message")
                    return
                }
                if let message { self.deliver(message) }
                self.receive()
            case .success:
                // A text frame is not v2 (§11.1).
                self.task.cancel(with: .normalClosure, reason: nil)
                self.end(reason: "Text frame")
            case let .failure(error):
                self.end(reason: error.localizedDescription)
            }
        }
    }

    private func deliver(_ message: Data) {
        let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            if onMessage == nil { early.append(message) }
            return onMessage
        }
        handler?(message)
    }

    private func end(reason: String) {
        lock.withLock {
            closed = true
            outbox = []
        }
        let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
        finish(Closing(code: code, reason: reason))
    }

    private func finish(_ closing: Closing) {
        let handler = lock.withLock { () -> (@Sendable (Closing) -> Void)? in
            guard let onClose else {
                if earlyClose == nil { earlyClose = closing }
                return nil
            }
            self.onClose = nil
            onMessage = nil
            return onClose
        }
        handler?(closing)
    }
}
