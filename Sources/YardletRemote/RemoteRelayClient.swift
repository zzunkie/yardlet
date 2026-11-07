import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mac's side of the relay (docs/REMOTE_PROTOCOL.md §14.2): one outgoing WebSocket that opens the
/// Mac's room with a signature, then carries every phone that comes in through the relay as numbered
/// binary frames, each phone a `RemoteSecureConnection`. The relay never sees inside a frame. It also
/// sends pushes. It reconnects on its own until stopped: at once when a room that stayed open drops, since
/// every phone on it is waiting, then with backoff. With a second address of the same relay, every attempt opens
/// a socket to each at once and keeps the first that answers.
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
    /// Another address of the same relay, raced against `baseURL` on every attempt (§14.2).
    private let alternateURL: URL?
    private let session: URLSession
    private let joinsPieces: Bool
    private let queue = DispatchQueue(label: "yardlet.remote.relay")
    private var task: URLSessionWebSocketTask?
    /// One of the attempt's sockets, the address it went to, and the piece of a relay message it holds: each socket
    /// is a stream of its own, so a piece joins only the next one from the same socket (`RemoteFramePieces`).
    private struct Entrant {
        let task: URLSessionWebSocketTask
        let address: URL
        var text: RemoteFramePieces
    }
    /// The attempt's sockets until one of them brings a whole relay message, the challenge.
    private var racing: [Entrant] = []
    /// Why the attempt's sockets ended so far, `baseURL`'s when it ended.
    private var raceFailure: (reason: String, detail: String)?
    /// Bumped on every new socket, so callbacks from an old one are ignored.
    private var generation = 0
    private var streams: [UInt32: RemoteRelayStream] = [:]
    /// The room's socket's frames and relay messages put back together where Foundation hands one over in pieces
    /// (`RemoteFramePieces`): a phone's frame is joined with the stream number that leads it, then read again.
    private var framePieces: RemoteFramePieces
    private var textPieces: RemoteFramePieces
    /// The phone whose frame is held for its next piece.
    private var heldStream: RemoteSecureConnection?
    static let textLimit = 64 * 1024
    /// What waits for the socket, in order, and the phone each message is for.
    private var outbox: [(message: URLSessionWebSocketTask.Message, stream: UInt32?, bytes: Int)] = []
    /// Bytes each phone has waiting in `outbox` or on its way into the socket.
    private var unsent: [UInt32: Int] = [:]
    private var isSending = false
    private var pushWaiters: [String: CheckedContinuation<RemotePushResult, Never>] = [:]
    private var pushCounter = 0
    /// Failures in a row; a room that stayed open for `stableAfter` starts the count again.
    private var attempt = 0
    private var startedAt = Date()
    /// When the relay said the room was open, for the socket now.
    private var readyAt: Date?
    private var lastHeard = Date()
    private var keepalive: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var running = false
    private var state = State.off
    /// Told on the client's queue whenever its state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    /// A way to the relay can die without a word: the next ping is what finds it, so pings come often
    /// enough that a phone waits seconds, not half a minute (§14.2).
    public static let pingInterval: TimeInterval = 15
    public static let silenceLimit: TimeInterval = 45
    static let stableAfter: TimeInterval = 10

    public init(server: RemoteServer, identity: RemoteIdentity, baseURL: URL, alternateURL: URL? = nil,
                session: URLSession = .shared, joinsPieces: Bool = RemoteFramePieces.platformSplitsFrames) {
        self.server = server
        self.identity = identity
        self.baseURL = baseURL
        self.alternateURL = alternateURL
        self.session = session
        self.joinsPieces = joinsPieces
        framePieces = RemoteFramePieces(limit: 4 + RemoteNoise.maxMessageLength, joinsPieces: joinsPieces)
        textPieces = RemoteFramePieces(limit: Self.textLimit, joinsPieces: joinsPieces)
    }

    /// The room's address for phones, which message 2 and the QR code name.
    public var relayInfo: RemoteHandshakeReply.Relay {
        RemoteHandshakeReply.Relay(url: baseURL.absoluteString, room: identity.room, alternate: alternateURL?.absoluteString)
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
            if running { RemoteLog.notice("Relay: stopped") }
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
            RemoteLog.notice("Relay: the network changed; opening the room now")
            connect()
        }
    }

    public var currentState: State {
        queue.sync { state }
    }

    // MARK: - Socket

    /// Opens a socket to every address at once. The first that brings the relay's challenge keeps the room; the
    /// others close before answering it, since an answered socket would replace the room's (§14.2).
    private func connect() {
        drop(reason: nil)
        generation += 1
        let current = generation
        framePieces = RemoteFramePieces(limit: 4 + RemoteNoise.maxMessageLength, joinsPieces: joinsPieces)
        textPieces = RemoteFramePieces(limit: Self.textLimit, joinsPieces: joinsPieces)
        heldStream = nil
        update(.connecting)
        racing = ([baseURL] + [alternateURL].compactMap { $0 }).map { address in
            let task = session.remoteWebSocketTask(with: Self.hostURL(base: address, room: identity.room))
            task.maximumMessageSize = RemoteNoise.maxMessageLength + 4 + 64 * 1024
            task.resume()
            return Entrant(task: task, address: address, text: RemoteFramePieces(limit: Self.textLimit, joinsPieces: joinsPieces))
        }
        startedAt = Date()
        readyAt = nil
        lastHeard = startedAt
        for entrant in racing { receive(on: entrant.task, generation: current) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick(generation: current) }
        timer.resume()
        keepalive = timer
    }

    /// The Mac's socket on the relay at `base`, a `ws` or `wss` address.
    static func hostURL(base: URL, room: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if components?.scheme == "https" { components?.scheme = "wss" }
        if components?.scheme == "http" { components?.scheme = "ws" }
        return (components?.url ?? base).appending(path: "v1/rooms/\(room)/host")
    }

    private func tick(generation current: Int) {
        guard current == generation, task != nil || !racing.isEmpty else { return }
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            fail("The relay stopped answering", detail: "nothing for \(RemoteLog.seconds(Self.silenceLimit))")
            return
        }
        if state == .connected, let task { enqueue(.string("ping"), on: task) }
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation else { return }
                switch result {
                case let .failure(error) where task === self.task:
                    self.fail(error.localizedDescription, detail: Self.ending(of: task, error: error))
                case let .failure(error):
                    self.leaveRace(task, error: error)
                case let .success(message):
                    if task === self.task {
                        self.lastHeard = Date()
                        self.handle(message, on: task)
                    } else {
                        switch self.race(task, message) {
                        case .gone:
                            return
                        case .holding:
                            break
                        case let .won(text):
                            self.lastHeard = Date()
                            if let text { self.handleRelayText(text, on: task) } else { self.handle(message, on: task) }
                        }
                    }
                    if current == self.generation { self.receive(on: task, generation: current) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        switch message {
        case let .data(piece):
            guard state == .connected else { return }
            var undecrypted: RemoteSecureConnection?
            let outcome: RemoteFramePieces.Outcome
            do {
                outcome = try framePieces.add(piece) { bytes in
                    guard bytes.count >= 4 else { return false }
                    let id = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    // A phone that has left has nothing to read its frame with.
                    guard let secure = streams[id]?.secure else { return true }
                    if secure.receive(Data(bytes.dropFirst(4))) { return true }
                    undecrypted = secure
                    return false
                }
            } catch {
                heldStream?.refuse(.messageTooBig)
                heldStream = nil
                return
            }
            heldStream = outcome == .held ? undecrypted : nil
            if outcome == .unreadable { undecrypted?.refuse(.unauthenticated) }
        case let .string(piece):
            var text: String?
            _ = try? textPieces.add(Data(piece.utf8)) { bytes in
                guard Self.readsAsRelayMessage(bytes) else { return false }
                text = String(decoding: bytes, as: UTF8.self)
                return true
            }
            if let text { handleRelayText(text, on: task) }
        @unknown default:
            return
        }
    }

    /// `pong`, or a JSON object: what the relay sends as text.
    static func readsAsRelayMessage(_ bytes: Data) -> Bool {
        bytes == Data("pong".utf8) || (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any]
    }

    /// A whole relay message the room's socket brought.
    private func handleRelayText(_ text: String, on task: URLSessionWebSocketTask) {
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
            readyAt = Date()
            RemoteLog.notice("Relay: the room is open, \(RemoteLog.seconds(Date().timeIntervalSince(startedAt))) after asking")
            update(.connected)
        case "open":
            guard let number = object["c"] as? NSNumber else { return }
            let id = number.uint32Value
            RemoteLog.notice("Relay: phone c\(id) came in")
            let stream = RemoteRelayStream(id: id, client: self)
            stream.secure = RemoteSecureConnection(transport: stream, server: server, staticKey: identity.noise, path: .relay)
            streams[id] = stream
        case "closed":
            guard let number = object["c"] as? NSNumber else { return }
            let id = number.uint32Value
            RemoteLog.notice("Relay: phone c\(id) left, code \((object["code"] as? NSNumber)?.intValue ?? 0)")
            outbox.removeAll { $0.stream == id }
            unsent[id] = nil
            streams.removeValue(forKey: id)?.secure?.transportClosed()
        case "pushed":
            guard let id = object["id"] as? String, let waiter = pushWaiters.removeValue(forKey: id) else { return }
            let ok = object["ok"] as? Bool ?? false
            let error = object["error"] as? String
            waiter.resume(returning: ok ? .sent : error == "unregistered" ? .unregistered : .failed)
        default:
            return
        }
    }

    private enum RaceStep {
        /// The socket is no longer in the race.
        case gone
        /// It holds a piece of a message and is read on.
        case holding
        /// It is the room's socket now, with the whole message it brought when that was text.
        case won(String?)
    }

    /// A message one of the attempt's sockets brought. The first socket whose message reads (the relay's challenge,
    /// pieces of it joined on that socket alone) becomes the room's socket and the others close.
    private func race(_ task: URLSessionWebSocketTask, _ message: URLSessionWebSocketTask.Message) -> RaceStep {
        guard let index = racing.firstIndex(where: { $0.task === task }) else { return .gone }
        var text: String?
        if case let .string(piece) = message {
            let outcome = try? racing[index].text.add(Data(piece.utf8)) { bytes in
                guard Self.readsAsRelayMessage(bytes) else { return false }
                text = String(decoding: bytes, as: UTF8.self)
                return true
            }
            if outcome == .held { return .holding }
        }
        let address = racing[index].address
        for other in racing where other.task !== task { other.task.cancel(with: .goingAway, reason: nil) }
        racing = []
        raceFailure = nil
        self.task = task
        if alternateURL != nil { RemoteLog.notice("Relay: \(address.host ?? address.absoluteString) answered first") }
        return .won(text)
    }

    /// One of the attempt's sockets ended. Once all have ended the attempt failed, for `baseURL`'s reason when it
    /// ended.
    private func leaveRace(_ task: URLSessionWebSocketTask, error: Error) {
        guard let index = racing.firstIndex(where: { $0.task === task }) else { return }
        let address = racing[index].address
        racing.remove(at: index)
        let detail = Self.ending(of: task, error: error)
        if raceFailure == nil || address == baseURL { raceFailure = (error.localizedDescription, detail) }
        if racing.isEmpty, let raceFailure {
            fail(raceFailure.reason, detail: raceFailure.detail)
        } else {
            RemoteLog.notice("Relay: \(address.host ?? address.absoluteString) did not answer: \(detail)")
        }
    }

    /// The socket ended or could not open; `reason` is what Settings shows, `detail` what the log adds.
    private func fail(_ reason: String, detail: String? = nil) {
        let openFor = readyAt.map { Date().timeIntervalSince($0) }
        let phones = streams.count
        drop(reason: reason)
        guard running else { return }
        update(.failed(reason))
        if let openFor, openFor >= Self.stableAfter { attempt = 0 }
        attempt += 1
        let delay = Self.retryDelay(afterFailures: attempt)
        let what = openFor.map { "the room closed after \(RemoteLog.seconds($0)) open, with \(phones) phone\(phones == 1 ? "" : "s") on it" }
            ?? "the room did not open, \(RemoteLog.seconds(Date().timeIntervalSince(startedAt))) after asking"
        RemoteLog.notice("Relay: \(what): \(detail ?? reason); trying again in \(RemoteLog.seconds(delay))")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The wait before trying again after `failures` failures in a row: next to none after the first, since every
    /// phone on the room waits for it to open again, then 1, 2, 4 … 32 s, each spread by a fifth.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 1 else { return Double.random(in: 0...0.25) }
        return pow(2, Double(min(failures, 7) - 2)) * Double.random(in: 0.8...1.2)
    }

    /// How a socket ended, for the log: the relay's close code and reason when it sent one, and the error.
    private static func ending(of task: URLSessionWebSocketTask, error: Error) -> String {
        let code = task.closeCode.rawValue
        guard code != URLSessionWebSocketTask.CloseCode.invalid.rawValue else { return RemoteLog.error(error) }
        let reason = task.closeReason.map { String(decoding: $0.prefix(123), as: UTF8.self) } ?? ""
        return "close code \(code) \"\(reason)\", \(RemoteLog.error(error))"
    }

    /// Ends the socket and every phone on it.
    private func drop(reason: String?) {
        keepalive?.cancel()
        keepalive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        for entrant in racing { entrant.task.cancel(with: .goingAway, reason: nil) }
        racing = []
        raceFailure = nil
        outbox = []
        unsent = [:]
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

    private func enqueue(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask,
                         stream: UInt32? = nil, bytes: Int = 0) {
        outbox.append((message, stream, bytes))
        pump(task)
    }

    private func pump(_ task: URLSessionWebSocketTask) {
        guard !isSending, task === self.task, !outbox.isEmpty else { return }
        isSending = true
        let next = outbox.removeFirst()
        let current = generation
        task.send(next.message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard current == self.generation, task === self.task else { return }
                self.isSending = false
                if let stream = next.stream, let left = self.unsent[stream] {
                    self.unsent[stream] = left > next.bytes ? left - next.bytes : nil
                }
                if let error {
                    self.fail(error.localizedDescription, detail: "sending: \(RemoteLog.error(error))")
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
            // A phone that asks and never reads would leave every answer here: past the limit its stream closes,
            // and what it had waiting goes (§7).
            let waiting = unsent[id, default: 0] + data.count
            guard waiting <= RemoteProtocol.maxUnsentBytes else {
                RemoteLog.notice("Relay: closing phone c\(id), which left \(waiting) bytes untaken")
                outbox.removeAll { $0.stream == id }
                unsent[id] = nil
                streams.removeValue(forKey: id)?.secure?.transportClosed()
                enqueue(.string(Self.json(["t": "close", "c": Int(id), "code": Int(RemoteCloseCode.rateLimited.rawValue)])),
                        on: task)
                return
            }
            unsent[id] = waiting
            enqueue(.data(data), on: task, stream: id, bytes: data.count)
        }
    }

    fileprivate func close(_ id: UInt32, code: RemoteCloseCode) {
        queue.async { [self] in
            guard streams.removeValue(forKey: id) != nil, let task else { return }
            RemoteLog.notice("Relay: closing phone c\(id) with code \(code.rawValue)")
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
                enqueue(.string(Self.pushMessage(request, id: id)), on: task)
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.pushWaiters.removeValue(forKey: id)?.resume(returning: .failed)
                }
            }
        }
    }

    /// The relay's `push` message (§14.2): the relay sends it through the provider the device registered with.
    static func pushMessage(_ request: RemotePushRequest, id: String) -> String {
        json([
            "t": "push", "id": id, "provider": request.provider, "to": request.token, "urgent": request.urgent,
            "collapse": request.collapse, "ttl": 3600, "data": ["v": "1", "k": request.keyID, "y": request.sealed]
        ])
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
