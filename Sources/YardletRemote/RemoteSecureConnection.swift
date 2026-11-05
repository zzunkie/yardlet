import Foundation

/// A transport under a v2 connection (§11.1): binary frames out, and closing. The direct listener and
/// the relay client each give one per phone.
public protocol RemoteFrameChannel: AnyObject, Sendable {
    func sendFrame(_ frame: Data)
    func close(_ code: RemoteCloseCode)
}

/// The Mac's side of one v2 connection: it answers the Noise handshake (§13.1), asks the server who the
/// phone is, then carries the server's JSON messages encrypted and chunked (§13.2). To the server it is
/// an ordinary `RemoteChannel`.
public final class RemoteSecureConnection: RemoteChannel, @unchecked Sendable {
    private enum State {
        case awaitingHello
        case deciding
        /// Message 2 is out; the server's messages go encrypted.
        case open(UUID)
        case closed
    }

    private let lock = NSLock()
    private let transport: any RemoteFrameChannel
    private let server: RemoteServer
    private let staticKey: RemoteKeyPair
    private let path: RemotePath
    private var state = State.awaitingHello
    private var sender: RemoteNoiseCipher?
    private var receiver: RemoteNoiseCipher?
    private var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxSecureClientMessageBytes)
    /// What the server sent before message 2 went out (it should not, but order is kept if it does).
    private var held: [String] = []
    /// Message 1, then the messages decrypted from the phone's frames, handled one at a time, in order; at most
    /// `maxInboxFrames` and `maxInboxBytes` wait (§7).
    private enum Inbound {
        case hello(Data)
        case message(Data, UUID)
    }
    private var inbox: [Inbound] = []
    private var inboxBytes = 0
    static let maxInboxFrames = 512
    static let maxInboxBytes = 16 * 1024 * 1024
    private var isDraining = false
    private var helloTimer: Task<Void, Never>?

    public init(transport: any RemoteFrameChannel, server: RemoteServer, staticKey: RemoteKeyPair, path: RemotePath,
                helloTimeout: TimeInterval = 10) {
        self.transport = transport
        self.server = server
        self.staticKey = staticKey
        self.path = path
        helloTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(helloTimeout))
            guard !Task.isCancelled else { return }
            self?.expireHello()
        }
    }

    /// A frame the transport received. False for a frame of the open connection that does not decrypt, which changes
    /// nothing: the transport joins the next piece to it (`RemoteFramePieces`) or calls `refuse()`.
    @discardableResult
    public func receive(_ frame: Data) -> Bool {
        enum Next { case drain, wait, undecryptable, refuse(RemoteCloseCode) }
        let next = lock.withLock { () -> Next in
            let item: Inbound
            switch state {
            case .closed:
                return .wait
            case .deciding:
                // A phone sends nothing but message 1 before message 2.
                return .refuse(.unauthenticated)
            case .awaitingHello where isDraining || !inbox.isEmpty:
                return .refuse(.unauthenticated)
            case .awaitingHello:
                item = .hello(frame)
            case let .open(id):
                // Decrypted as it comes, so the next frame is read against the cipher as it then is.
                guard var receiver else { return .wait }
                let message: Data?
                do {
                    message = try joiner.add(frame, with: &receiver)
                } catch let failure as RemoteNoise.Failure where failure == .undecryptable {
                    return .undecryptable
                } catch is RemoteNoiseFraming.Joiner.TooLarge {
                    return .refuse(.messageTooBig)
                } catch {
                    return .refuse(.unauthenticated)
                }
                self.receiver = receiver
                guard let message else { return .wait }
                item = .message(message, id)
            }
            // A phone that sends faster than its messages are handled is closed rather than held without end.
            let bytes: Int
            switch item {
            case let .hello(data), let .message(data, _): bytes = data.count
            }
            guard inbox.count < Self.maxInboxFrames, inboxBytes + bytes <= Self.maxInboxBytes else { return .refuse(.rateLimited) }
            inbox.append(item)
            inboxBytes += bytes
            guard !isDraining else { return .wait }
            isDraining = true
            return .drain
        }
        switch next {
        case .drain: Task { await drain() }
        case .wait: break
        case .undecryptable: return false
        case let .refuse(code): fail(code)
        }
        return true
    }

    /// Closes the connection over a frame that does not decrypt, or that grew past the limit in pieces.
    public func refuse(_ code: RemoteCloseCode = .unauthenticated) {
        fail(code)
    }

    /// Message 2 has not gone out, nor has the connection closed.
    public var isHandshaking: Bool {
        lock.withLock {
            switch state {
            case .awaitingHello, .deciding: true
            case .open, .closed: false
            }
        }
    }

    /// The transport saw the connection end.
    public func transportClosed() {
        let id = lock.withLock { () -> UUID? in
            helloTimer?.cancel()
            defer { state = .closed }
            if case let .open(id) = state { return id }
            return nil
        }
        if let id { Task { await server.closed(id) } }
    }

    private func drain() async {
        while true {
            let next = lock.withLock { () -> Inbound? in
                guard !inbox.isEmpty else {
                    isDraining = false
                    return nil
                }
                let item = inbox.removeFirst()
                switch item {
                case let .hello(data), let .message(data, _): inboxBytes -= data.count
                }
                return item
            }
            switch next {
            case nil:
                return
            case let .hello(frame):
                await handshake(frame)
            case let .message(message, id):
                await server.receive(message, on: id)
            }
        }
    }

    private func handshake(_ frame: Data) async {
        var noise: RemoteNoiseHandshake
        let hello: RemoteHandshakeHello
        let phoneKey: Data
        do {
            noise = try RemoteNoiseHandshake(role: .responder, localStatic: staticKey)
            let payload = try noise.readMessage1(frame)
            guard let key = noise.remoteStatic else { throw RemoteNoise.Failure("No initiator key") }
            phoneKey = key
            hello = (try? JSONDecoder().decode(RemoteHandshakeHello.self, from: payload)) ?? RemoteHandshakeHello(v: 0)
        } catch {
            // Not for this Mac's key, or damaged: nothing to answer.
            fail(.unauthenticated)
            return
        }
        lock.withLock { state = .deciding }
        let outcome = await server.acceptHandshake(hello, publicKey: phoneKey, channel: self, path: path)
        let reply: RemoteHandshakeReply
        var opened: UUID?
        var closing: RemoteCloseCode?
        switch outcome {
        case let .accepted(id, answer), let .pending(id, answer):
            reply = answer
            opened = id
        case let .refused(answer, code):
            reply = answer
            closing = code
        }
        let message2: Data
        do {
            message2 = try noise.writeMessage2(payload: Data(RemoteJSON.string(reply).utf8))
        } catch {
            if let opened { Task { await server.closed(opened) } }
            fail(.unauthenticated)
            return
        }
        let (outgoing, incoming) = noise.split()
        let pending = lock.withLock { () -> [String] in
            helloTimer?.cancel()
            sender = outgoing
            receiver = incoming
            transport.sendFrame(message2)
            if let opened, closing == nil {
                state = .open(opened)
                defer { held = [] }
                return held
            }
            return []
        }
        if let closing {
            fail(closing)
            return
        }
        for text in pending { send(text) }
    }

    private func expireHello() {
        let waiting = lock.withLock { () -> Bool in
            if case .awaitingHello = state { return true }
            return false
        }
        if waiting { fail(.idle) }
    }

    private func fail(_ code: RemoteCloseCode) {
        let id = lock.withLock { () -> UUID? in
            helloTimer?.cancel()
            defer { state = .closed; inbox = []; inboxBytes = 0 }
            if case let .open(id) = state { return id }
            return nil
        }
        RemoteLog.notice("Remote: closing a connection over \(path.rawValue) with code \(code.rawValue)"
            + (id == nil ? ", before it was a device's" : ""))
        transport.close(code)
        if let id { Task { await server.closed(id) } }
    }

    // MARK: - RemoteChannel

    public func send(_ text: String) {
        lock.withLock {
            switch state {
            case .open:
                guard var sender else { return }
                defer { self.sender = sender }
                let message = Data(text.utf8)
                guard message.count <= RemoteProtocol.maxServerMessageBytes,
                      let frames = try? RemoteNoiseFraming.seal(message, with: &sender) else { return }
                for frame in frames { transport.sendFrame(frame) }
            case .awaitingHello, .deciding:
                held.append(text)
            case .closed:
                return
            }
        }
    }

    public func close(_ code: RemoteCloseCode) {
        lock.withLock {
            helloTimer?.cancel()
            state = .closed
            inbox = []
        }
        transport.close(code)
    }
}
