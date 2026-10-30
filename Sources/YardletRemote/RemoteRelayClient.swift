import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mac's side of the relay (docs/REMOTE_PROTOCOL.md §14.2): one outgoing WebSocket that opens the
/// Mac's room with a signature, then carries every phone that comes in through the relay as numbered
/// binary frames, each phone a `RemoteSecureConnection`. The relay never sees inside a frame. It also
/// sends pushes. It reconnects on its own, with backoff, until stopped.
public final class RemoteRelayClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        case connecting
        case connected
        /// Why the last attempt failed; it tries again.
        case failed(String)
    }

    private let server: RemoteServer
    private let identity: RemoteIdentity
    private let baseURL: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "yardlet.remote.relay")
    private var task: URLSessionWebSocketTask?
    /// Bumped on every new socket, so callbacks from an old one are ignored.
    private var generation = 0
    private var streams: [UInt32: RemoteRelayStream] = [:]
    private var outbox: [URLSessionWebSocketTask.Message] = []
    private var isSending = false
    private var pushWaiters: [String: CheckedContinuation<RemotePushResult, Never>] = [:]
    private var pushCounter = 0
    private var attempt = 0
    private var lastHeard = Date()
    private var keepalive: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var running = false
    private var state = State.off
    /// Told on the client's queue whenever its state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public static let pingInterval: TimeInterval = 30
    public static let silenceLimit: TimeInterval = 90

    public init(server: RemoteServer, identity: RemoteIdentity, baseURL: URL, session: URLSession = .shared) {
        self.server = server
        self.identity = identity
        self.baseURL = baseURL
        self.session = session
    }

    /// The room's address for phones, which message 2 and the QR code name.
    public var relayInfo: RemoteHandshakeReply.Relay {
        RemoteHandshakeReply.Relay(url: baseURL.absoluteString, room: identity.room)
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempt = 0
            connect()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            retry?.cancel()
            retry = nil
            drop(reason: nil)
            update(.off)
        }
    }

    /// The network changed: try now rather than when the backoff says.
    public func reconnectSoon() {
        queue.async { [self] in
            guard running, state != .connected else { return }
            retry?.cancel()
            attempt = 0
            connect()
        }
    }

    public var currentState: State {
        queue.sync { state }
    }

    // MARK: - Socket

    private func connect() {
        drop(reason: nil)
        generation += 1
        let current = generation
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.scheme == "https" { components?.scheme = "wss" }
        if components?.scheme == "http" { components?.scheme = "ws" }
        let base = components?.url ?? baseURL
        let url = base.appending(path: "v1/rooms/\(identity.room)/host")
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = RemoteNoise.maxMessageLength + 4 + 64 * 1024
        self.task = task
        update(.connecting)
        task.resume()
        lastHeard = Date()
        receive(on: task, generation: current)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick(generation: current) }
        timer.resume()
        keepalive = timer
    }

    private func tick(generation current: Int) {
        guard current == generation, let task else { return }
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            fail("The relay stopped answering")
            return
        }
        if state == .connected { enqueue(.string("ping"), on: task) }
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation else { return }
                switch result {
                case let .failure(error):
                    self.fail(error.localizedDescription)
                case let .success(message):
                    self.lastHeard = Date()
                    self.handle(message, on: task)
                    if current == self.generation { self.receive(on: task, generation: current) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        switch message {
        case let .data(data):
            guard state == .connected, data.count >= 4 else { return }
            let id = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            streams[id]?.secure?.receive(Data(data.dropFirst(4)))
        case let .string(text):
            guard text != "pong" else { return }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = object["t"] as? String else { return }
            switch type {
            case "challenge":
                guard let nonce = object["nonce"] as? String,
                      let signature = try? identity.signRelayChallenge(room: identity.room, nonce: nonce) else {
                    fail("Could not answer the relay's challenge")
                    return
                }
                let auth: [String: String] = ["t": "auth", "key": RemoteEncoding.base64url(identity.relayPublicKey),
                                              "sig": RemoteEncoding.base64url(signature)]
                enqueue(.string(Self.json(auth)), on: task)
            case "ready":
                attempt = 0
                update(.connected)
            case "open":
                guard let number = object["c"] as? NSNumber else { return }
                let id = number.uint32Value
                let stream = RemoteRelayStream(id: id, client: self)
                stream.secure = RemoteSecureConnection(transport: stream, server: server, staticKey: identity.noise, path: .relay)
                streams[id] = stream
            case "closed":
                guard let number = object["c"] as? NSNumber else { return }
                streams.removeValue(forKey: number.uint32Value)?.secure?.transportClosed()
            case "pushed":
                guard let id = object["id"] as? String, let waiter = pushWaiters.removeValue(forKey: id) else { return }
                let ok = object["ok"] as? Bool ?? false
                let error = object["error"] as? String
                waiter.resume(returning: ok ? .sent : error == "unregistered" ? .unregistered : .failed)
            default:
                return
            }
        @unknown default:
            return
        }
    }

    private func fail(_ reason: String) {
        drop(reason: reason)
        guard running else { return }
        update(.failed(reason))
        attempt += 1
        let delay = min(60, pow(2, Double(min(attempt, 6) - 1))) * Double.random(in: 0.8...1.2)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Ends the socket and every phone on it.
    private func drop(reason: String?) {
        keepalive?.cancel()
        keepalive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        outbox = []
        isSending = false
        for stream in streams.values { stream.secure?.transportClosed() }
        streams = [:]
        for waiter in pushWaiters.values { waiter.resume(returning: .failed) }
        pushWaiters = [:]
    }

    private func update(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: - Sending (in order, one at a time)

    private func enqueue(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        outbox.append(message)
        pump(task)
    }

    private func pump(_ task: URLSessionWebSocketTask) {
        guard !isSending, task === self.task, !outbox.isEmpty else { return }
        isSending = true
        let message = outbox.removeFirst()
        let current = generation
        task.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation else { return }
                self.isSending = false
                if let error {
                    self.fail(error.localizedDescription)
                } else {
                    self.pump(task)
                }
            }
        }
    }

    fileprivate func sendFrame(_ frame: Data, on id: UInt32) {
        queue.async { [self] in
            guard state == .connected, streams[id] != nil, let task else { return }
            var data = Data([UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)])
            data.append(frame)
            enqueue(.data(data), on: task)
        }
    }

    fileprivate func close(_ id: UInt32, code: RemoteCloseCode) {
        queue.async { [self] in
            guard streams.removeValue(forKey: id) != nil, let task else { return }
            enqueue(.string(Self.json(["t": "close", "c": Int(id), "code": Int(code.rawValue)])), on: task)
        }
    }

    // MARK: - Push

    /// Sends a push through the relay (§14.2) and says how it went.
    public func push(_ request: RemotePushRequest) async -> RemotePushResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<RemotePushResult, Never>) in
            queue.async { [self] in
                guard state == .connected, let task else {
                    continuation.resume(returning: .failed)
                    return
                }
                pushCounter += 1
                let id = "p\(pushCounter)"
                pushWaiters[id] = continuation
                let message: [String: Any] = [
                    "t": "push", "id": id, "to": request.token, "urgent": request.urgent, "collapse": request.collapse,
                    "ttl": 3600, "data": ["v": "1", "k": request.keyID, "y": request.sealed]
                ]
                enqueue(.string(Self.json(message)), on: task)
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.pushWaiters.removeValue(forKey: id)?.resume(returning: .failed)
                }
            }
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One phone on the relay socket, as its secure connection's transport.
final class RemoteRelayStream: RemoteFrameChannel, @unchecked Sendable {
    let id: UInt32
    private weak var client: RemoteRelayClient?
    var secure: RemoteSecureConnection?

    init(id: UInt32, client: RemoteRelayClient) {
        self.id = id
        self.client = client
    }

    func sendFrame(_ frame: Data) {
        client?.sendFrame(frame, on: id)
    }

    func close(_ code: RemoteCloseCode) {
        client?.close(id, code: code)
    }
}
