import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a client finds a host (docs/REMOTE_PROTOCOL.md §11.4): its static key, the direct addresses it
/// last named, and its room on the relay.
public struct RemoteHostTarget: Equatable, Sendable {
    public var hostKey: Data
    /// `host:port`, an IPv6 host in brackets.
    public var direct: [String]
    public var relayURL: String?
    public var room: String?

    public init(hostKey: Data, direct: [String], relayURL: String? = nil, room: String? = nil) {
        self.hostKey = hostKey
        self.direct = direct
        self.relayURL = relayURL
        self.room = room
    }

    /// The WebSocket for a direct address.
    public static func directURL(_ host: String) -> URL? {
        URL(string: "ws://\(host)/")
    }

    /// The WebSocket a client opens on the relay for `room` (§14.3).
    public static func relayURL(base: String, room: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/v1/rooms/\(room)/connect"
        return components.url
    }
}

/// The path a connection took.
public enum RemoteClientPath: Equatable, Sendable {
    case direct(String)
    case relay
}

/// One host as a client follows it: it races the addresses found on the network, the direct addresses and
/// the relay, keeps the connection alive with `ping`, moves from the relay to a direct path when one
/// completes, and connects again with backoff when the connection drops (§11.4, §13.3). What arrives comes
/// out of `inbound` in the order it arrived, responses and events together, so a client applies them in that
/// order (§5.3).
public actor RemoteHostConnection {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        /// Message 2's answer: the host's name and version, the device ID, its addresses now.
        case connected(RemoteClientPath, RemoteHandshakeReply)
        /// The last attempt failed; the next starts at `retryAt`.
        case waiting(retryAt: Date, reason: String)
        /// The host removed this device or does not know its key. Nothing more is tried.
        case revoked
        case stopped
    }

    public enum Inbound: Sendable {
        case state(State)
        case response(RemoteResponse)
        case event(RemoteEvent)
    }

    public struct Timing: Sendable {
        public var directTimeout: TimeInterval = 3
        public var relayDelay: TimeInterval = 0.7
        public var relayTimeout: TimeInterval = 10
        public var pingInterval: TimeInterval = 25
        /// A connection that has heard nothing for this long is taken for gone.
        public var silenceLimit: TimeInterval = 60
        public var backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        /// While on the relay, a direct path is tried again this often.
        public var directRetryInterval: TimeInterval = 60

        public init() {}
    }

    public nonisolated let inbound: AsyncStream<Inbound>
    private let continuation: AsyncStream<Inbound>.Continuation
    private var target: RemoteHostTarget
    private let clientKey: RemoteKeyPair
    private let hello: RemoteHandshakeHello
    private let session: URLSession
    private let timing: Timing
    private var socket: RemoteClientSocket?
    private var path: RemoteClientPath?
    /// Bumped for every socket, so the close of one let go is not taken for the current one's.
    private var generation = 0
    private var running = false
    private var attempt = 0
    private var loop: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var upgrade: Task<Void, Never>?
    private var pingCounter = 0
    /// What Bonjour resolved for the host now (§11.3), tried before the addresses it named; never saved.
    private var discovered: [String] = []
    /// An attempt is racing; an address found or a retry asked for meanwhile is tried as soon as it ends.
    private var racing = false
    private var retryAfterRace = false

    public init(target: RemoteHostTarget, clientKey: RemoteKeyPair, hello: RemoteHandshakeHello,
                session: URLSession = .shared, timing: Timing = Timing()) {
        self.target = target
        self.clientKey = clientKey
        self.hello = hello
        self.session = session
        self.timing = timing
        (inbound, continuation) = AsyncStream.makeStream(of: Inbound.self)
    }

    public func start() {
        guard !running else { return }
        running = true
        connectSoon(after: 0)
    }

    /// Closes the connection and stops trying; `inbound` ends.
    public func stop() {
        running = false
        loop?.cancel()
        keepalive?.cancel()
        upgrade?.cancel()
        generation += 1
        socket?.close()
        socket = nil
        path = nil
        continuation.yield(.state(.stopped))
        continuation.finish()
    }

    /// The network changed, or the person asked: try now rather than at the backoff's time, and try a
    /// direct path while on the relay.
    public func reconnectNow() {
        guard running else { return }
        if socket == nil {
            // An attempt under way goes on rather than starting over; should it fail, the next starts at once.
            if racing {
                retryAfterRace = true
                return
            }
            attempt = 0
            connectSoon(after: 0)
        } else if path == .relay {
            tryDirectUpgrade()
        }
    }

    /// The addresses the host named in its latest message 2, for the next attempt.
    public func update(target: RemoteHostTarget) {
        self.target = target
    }

    /// The addresses Bonjour resolved for the host, each time they change (§11.3): they go first among the
    /// direct candidates. A new one is tried at once (§11.4): from the relay, and in place of waiting out
    /// a backoff.
    public func discovered(_ addresses: [String]) {
        let added = !Set(addresses).isSubset(of: discovered)
        discovered = addresses
        guard running, added else { return }
        if path == .relay {
            tryDirectUpgrade()
        } else if socket == nil {
            if racing {
                retryAfterRace = true
            } else {
                attempt = 0
                connectSoon(after: 0)
            }
        }
    }

    /// Sends a request under `id` (unique among the client's requests). False when no connection is open:
    /// no response will come for it.
    public func send(id: String, _ request: RemoteRequest) -> Bool {
        guard let socket else { return false }
        socket.send(RemoteRequestEnvelope(id: id, request: request).encoded())
        return true
    }

    // MARK: - Connecting

    private func connectSoon(after delay: TimeInterval) {
        loop?.cancel()
        loop = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        guard running, socket == nil else { return }
        continuation.yield(.state(.connecting))
        racing = true
        retryAfterRace = false
        let result = await Self.race(Self.candidates(target, discovered: discovered, includeRelay: true, timing: timing),
                                     clientKey: clientKey, hostKey: target.hostKey, hello: hello, session: session)
        racing = false
        guard running, !Task.isCancelled else {
            if case let .success(won) = result { won.socket.close() }
            return
        }
        switch result {
        case let .success(won):
            adopt(won)
            if retryAfterRace { tryDirectUpgrade() }
        case let .failure(failure):
            if Self.isRevoked(failure) {
                running = false
                continuation.yield(.state(.revoked))
                return
            }
            let delay = retryAfterRace ? 0 : timing.backoff[min(attempt, timing.backoff.count - 1)]
            attempt += 1
            continuation.yield(.state(.waiting(retryAt: Date().addingTimeInterval(delay), reason: failure.reason)))
            connectSoon(after: delay)
        }
    }

    private func adopt(_ won: RaceWinner) {
        generation += 1
        let current = generation
        socket?.close()
        socket = won.socket
        path = won.path
        attempt = 0
        continuation.yield(.state(.connected(won.path, won.reply)))
        let continuation = continuation
        won.socket.start(onMessage: { data in
            // Yielded here, on the socket's own thread, so messages leave in the order they arrived.
            if let inbound = Self.decode(data) { continuation.yield(inbound) }
        }, onClose: { [weak self] closing in
            Task { await self?.closed(current, closing) }
        })
        startKeepalive(current)
        upgrade?.cancel()
        upgrade = nil
        if won.path == .relay {
            upgrade = Task { [weak self, interval = timing.directRetryInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    await self?.tryDirectUpgrade()
                }
            }
        }
    }

    private func closed(_ current: Int, _ closing: RemoteClientSocket.Closing) {
        guard current == generation else { return }
        socket = nil
        path = nil
        keepalive?.cancel()
        upgrade?.cancel()
        guard running else { return }
        if closing.isRevoked {
            running = false
            continuation.yield(.state(.revoked))
            return
        }
        let delay = timing.backoff[min(attempt, timing.backoff.count - 1)]
        attempt += 1
        continuation.yield(.state(.waiting(retryAt: Date().addingTimeInterval(delay), reason: closing.reason)))
        connectSoon(after: delay)
    }

    private func startKeepalive(_ current: Int) {
        keepalive?.cancel()
        keepalive = Task { [weak self, interval = timing.pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.ping(current)
            }
        }
    }

    private func ping(_ current: Int) {
        guard current == generation, let socket else { return }
        if Date().timeIntervalSince(socket.lastReceived) > timing.silenceLimit {
            // Nothing came back, not even a pong: the path is gone without a close.
            socket.close()
            return
        }
        pingCounter += 1
        socket.send(RemoteRequestEnvelope(id: "ping-\(pingCounter)", request: .ping).encoded())
    }

    /// While on the relay: a direct path that completes takes over (§11.4).
    private func tryDirectUpgrade() {
        let candidates = Self.candidates(target, discovered: discovered, includeRelay: false, timing: timing)
        guard path == .relay, !candidates.isEmpty else { return }
        let hostKey = target.hostKey, clientKey = clientKey, hello = hello, session = session
        Task { [weak self] in
            let result = await Self.race(candidates, clientKey: clientKey, hostKey: hostKey, hello: hello, session: session)
            guard case let .success(won) = result else { return }
            await self?.upgradeTo(won)
        }
    }

    private func upgradeTo(_ won: RaceWinner) {
        guard running, path == .relay else {
            won.socket.close()
            return
        }
        adopt(won)
    }

    // MARK: - Racing paths

    struct Candidate: Sendable {
        var url: URL
        var path: RemoteClientPath
        var delay: TimeInterval
        var timeout: TimeInterval
    }

    struct RaceWinner: Sendable {
        var socket: RemoteClientSocket
        var reply: RemoteHandshakeReply
        var path: RemoteClientPath
    }

    /// The addresses found on the network first, then the ones the host named, each once, at once; the
    /// relay after them.
    static func candidates(_ target: RemoteHostTarget, discovered: [String] = [], includeRelay: Bool,
                           timing: Timing) -> [Candidate] {
        let direct = Array(NSOrderedSet(array: discovered + target.direct)).compactMap { $0 as? String }
        var candidates = direct.compactMap { host in
            RemoteHostTarget.directURL(host).map {
                Candidate(url: $0, path: .direct(host), delay: 0, timeout: timing.directTimeout)
            }
        }
        if includeRelay, let base = target.relayURL, let room = target.room,
           let url = RemoteHostTarget.relayURL(base: base, room: room) {
            candidates.append(Candidate(url: url, path: .relay, delay: candidates.isEmpty ? 0 : timing.relayDelay,
                                        timeout: timing.relayTimeout))
        }
        return candidates
    }

    /// Starts every candidate after its delay; the first handshake that completes wins and the others are
    /// let go. A refusal that names this device (removed, or never paired) or the pairing ends the race at
    /// once, since every path reaches the same host.
    static func race(_ candidates: [Candidate], clientKey: RemoteKeyPair, hostKey: Data, hello: RemoteHandshakeHello,
                     session: URLSession) async -> Result<RaceWinner, RemoteClientSocket.Failure> {
        guard !candidates.isEmpty else { return .failure(RemoteClientSocket.Failure("No address to try")) }
        return await withTaskGroup(of: Result<RaceWinner, RemoteClientSocket.Failure>.self) { group in
            for candidate in candidates {
                group.addTask {
                    if candidate.delay > 0 { try? await Task.sleep(for: .seconds(candidate.delay)) }
                    guard !Task.isCancelled else { return .failure(RemoteClientSocket.Failure("Cancelled")) }
                    do {
                        let (socket, reply) = try await RemoteClientSocket.open(
                            url: candidate.url, clientKey: clientKey, hostKey: hostKey, hello: hello, session: session,
                            timeout: candidate.timeout)
                        return .success(RaceWinner(socket: socket, reply: reply, path: candidate.path))
                    } catch let failure as RemoteClientSocket.Failure {
                        return .failure(failure)
                    } catch {
                        return .failure(RemoteClientSocket.Failure(error.localizedDescription))
                    }
                }
            }
            var winner: RaceWinner?
            var failures: [RemoteClientSocket.Failure] = []
            for await result in group {
                switch result {
                case let .success(won):
                    if winner == nil {
                        winner = won
                        group.cancelAll()
                    } else {
                        won.socket.close()
                    }
                case let .failure(failure):
                    failures.append(failure)
                    if winner == nil, isDefinitive(failure) { group.cancelAll() }
                }
            }
            if let winner { return .success(winner) }
            return .failure(failures.first(where: isDefinitive) ?? failures.last ?? RemoteClientSocket.Failure("No address answered"))
        }
    }

    /// A refusal every path would give alike.
    static func isDefinitive(_ failure: RemoteClientSocket.Failure) -> Bool {
        if isRevoked(failure) { return true }
        switch failure.error?.code {
        case .pairingInvalid?, .pairingUnavailable?, .unsupportedVersion?: return true
        default: return false
        }
    }

    static func isRevoked(_ failure: RemoteClientSocket.Failure) -> Bool {
        failure.error?.code == .unknownDevice || failure.closeCode == Int(RemoteCloseCode.revoked.rawValue)
    }

    // MARK: - Pairing

    /// Pairs with the host a pairing link names (§12): the client's key becomes a device of that host.
    /// The connection that paired is closed; the host's answer names its addresses and the device.
    public static func pair(_ link: RemoteSecurePairingURL, clientKey: RemoteKeyPair, hello: RemoteHandshakeHello,
                            session: URLSession = .shared, timing: Timing = Timing()) async throws -> RemoteHandshakeReply {
        var hello = hello
        hello.pair = RemoteEncoding.base64url(link.secret)
        let target = RemoteHostTarget(hostKey: link.macKey, direct: link.hosts, relayURL: link.relayURL, room: link.room)
        switch await race(candidates(target, includeRelay: true, timing: timing), clientKey: clientKey, hostKey: link.macKey,
                          hello: hello, session: session) {
        case let .success(won):
            won.socket.close()
            return won.reply
        case let .failure(failure):
            throw failure
        }
    }

    // MARK: - Reading

    private struct Probe: Decodable {
        var re: String?
        var event: String?
    }

    static func decode(_ data: Data) -> Inbound? {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return nil }
        if probe.re != nil {
            return (try? JSONDecoder().decode(RemoteResponse.self, from: data)).map(Inbound.response)
        }
        if probe.event != nil {
            return (try? JSONDecoder().decode(RemoteEvent.self, from: data)).map(Inbound.event)
        }
        return nil
    }
}
