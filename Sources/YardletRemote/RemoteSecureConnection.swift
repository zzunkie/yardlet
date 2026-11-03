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
    /// Frames are handled one at a time, in order.
    private var inbox: [Data] = []
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

    /// A frame the transport received.
    public func receive(_ frame: Data) {
        let start = lock.withLock { () -> Bool? in
            switch state {
            case .closed:
                return false
            case .deciding:
                return nil
            case .awaitingHello where isDraining || !inbox.isEmpty:
                return nil
            case .awaitingHello, .open:
                break
            }
            inbox.append(frame)
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
        // A phone sends nothing but message 1 before message 2; nothing more is held for it.
        guard let start else { return fail(.unauthenticated) }
        if start { Task { await drain() } }
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
            let next = lock.withLock { () -> (Data, State)? in
                guard !inbox.isEmpty else {
                    isDraining = false
                    return nil
                }
                return (inbox.removeFirst(), state)
            }
            guard let (frame, current) = next else { return }
            switch current {
            case .awaitingHello:
                await handshake(frame)
            case .deciding:
                // A phone sends nothing before message 2.
                fail(.unauthenticated)
            case let .open(id):
                let message: Data?
                do {
                    message = try lock.withLock { () throws -> Data? in
                        guard var receiver else { return nil }
                        defer { self.receiver = receiver }
                        return try joiner.add(frame, with: &receiver)
                    }
                } catch is RemoteNoiseFraming.Joiner.TooLarge {
                    fail(.messageTooBig)
                    return
                } catch {
                    fail(.unauthenticated)
                    return
                }
                if let message { await server.receive(message, on: id) }
            case .closed:
                return
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
            defer { state = .closed; inbox = [] }
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
