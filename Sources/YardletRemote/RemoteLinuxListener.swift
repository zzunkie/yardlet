#if os(Linux)
import Foundation
import Glibc

/// The v2 listener for direct paths on Linux (§11.1), shaped as `RemoteWinsockListener` is on Windows, for the Linux
/// host (docs/LINUX_HOST.md, "Direct paths"). It speaks the WebSocket itself (`RemoteWebSocket`), with the same rules as
/// the Windows listener: an opening request read up to 8 KB and answered only when it is a WebSocket upgrade without
/// Origin, frames RFC 6455 does not allow closed with 1002, text with 1003 and a message over 65,535 bytes with 1009, and
/// each whole binary message handed to the connection's `RemoteSecureConnection`, which serves nothing before its Noise
/// handshake with a paired key. Connections that have not finished their handshakes are held as the Mac holds them
/// (`RemoteHandshakeAdmission`). One thread serves every socket with `poll`; other threads queue frames and wake it.
///
/// A server often holds a public address, so by default it listens on loopback, the same network's private IPv4
/// addresses and Tailscale's alone (`RemoteAddressSelection.isPrivateListeningAddress`), one socket for each, and binds
/// the new ones and closes those gone as interfaces change (`RemoteNetlinkWatch`): a Tailscale that comes up after the
/// host is reached without a restart. With `.everyAddress`, which the person chooses, it listens on every interface, as
/// the Mac and Windows listeners do. There is no DNS-SD advertisement: a device reaches it at the addresses the pairing
/// link names. Its sockets close when Yardlet starts a program, and every one closes before `stop()` returns.
public final class RemoteLinuxListener: RemoteDirectListening, @unchecked Sendable {
    public typealias State = RemoteDirectListenerState

    public enum Reach: String, Sendable, Codable {
        /// Loopback, private IPv4 addresses and Tailscale's.
        case privateNetworks = "private"
        /// Every address, public ones too.
        case everyAddress = "all"
    }

    private let server: RemoteServer
    private let staticKey: RemoteKeyPair
    private let preferredPort: UInt16
    private let reach: Reach
    private let interfaces: @Sendable () -> [RemoteInterfaceAddress]
    private let lock = NSLock()
    private var serving: RemoteLinuxServing?
    private var state = State.stopped
    /// Told whenever its state changes: on the thread that starts or stops it, or on its own when it fails.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(server: RemoteServer, staticKey: RemoteKeyPair, port: UInt16 = RemoteProtocol.securePort,
                reach: Reach = .privateNetworks,
                interfaces: @escaping @Sendable () -> [RemoteInterfaceAddress] = RemoteAddressSelection.systemInterfaces) {
        self.server = server
        self.staticKey = staticKey
        preferredPort = port
        self.reach = reach
        self.interfaces = interfaces
    }

    public func start() {
        lock.withLock {
            guard serving == nil else { return }
            update(.starting)
            var opened = RemoteLinuxServing.open(port: preferredPort, reach: reach, interfaces: interfaces)
            // The preferred port is taken (another Yardlet, an old process): any free port, which message 2 names.
            if case let .failure(failure) = opened, failure.code == EADDRINUSE, preferredPort != 0 {
                opened = RemoteLinuxServing.open(port: 0, reach: reach, interfaces: interfaces)
            }
            switch opened {
            case let .success(serving):
                serving.start(server: server, staticKey: staticKey) { [weak self] message in self?.fail(serving, message) }
                self.serving = serving
                update(.ready(port: serving.port))
            case let .failure(failure):
                update(.failed(failure.message))
            }
        }
    }

    public func stop() {
        let serving = lock.withLock { () -> RemoteLinuxServing? in
            defer { self.serving = nil }
            return self.serving
        }
        serving?.stop()
        lock.withLock { update(.stopped) }
    }

    public var currentState: State {
        lock.withLock { state }
    }

    /// The addresses it listens on now, for the host's status.
    public var listeningAddresses: [String] {
        lock.withLock { serving }?.addresses ?? []
    }

    /// The thread's own socket failed: the listener stops, and says why.
    private func fail(_ failed: RemoteLinuxServing, _ message: String) {
        lock.withLock {
            guard serving === failed else { return }
            serving = nil
            update(.failed(message))
        }
    }

    /// Under `lock`.
    private func update(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }
}

/// A socket call that failed, by its `errno`.
struct RemoteSocketFailure: Error {
    var code: Int32
    var message: String

    init(_ call: String, code: Int32 = errno) {
        self.code = code
        message = "\(call) failed: \(String(cString: strerror(code)))"
    }
}

/// One start of the listener: its sockets, served on a thread of its own until it stops.
private final class RemoteLinuxServing: @unchecked Sendable {
    let port: UInt16
    private let reach: RemoteLinuxListener.Reach
    private let interfaces: @Sendable () -> [RemoteInterfaceAddress]
    /// A pipe other threads write a byte to, to wake the thread's poll.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var stopping = false
    private var wakeClosed = false
    private var interfacesChanged = false
    private var stopWatching: (() -> Void)?
    private let finished = DispatchSemaphore(value: 0)
    /// The listening sockets by the address each is bound to (under `lock`; only the thread changes them once it runs).
    private var listening: [String: Int32]
    /// The connections, on the thread alone.
    private var channels: [RemoteLinuxChannel] = []

    private init(port: UInt16, reach: RemoteLinuxListener.Reach, interfaces: @escaping @Sendable () -> [RemoteInterfaceAddress],
                 listening: [String: Int32], wake: (read: Int32, write: Int32)) {
        self.port = port
        self.reach = reach
        self.interfaces = interfaces
        self.listening = listening
        wakeRead = wake.read
        wakeWrite = wake.write
    }

    var addresses: [String] {
        lock.withLock { listening.keys.sorted() }
    }

    /// The addresses a listener that keeps to private networks binds now, loopback always among them.
    static func privateAddresses(_ interfaces: [RemoteInterfaceAddress]) -> [String] {
        let found = interfaces.map(\.address).filter {
            !$0.contains("%") && RemoteAddressSelection.isPrivateListeningAddress($0)
        }
        return Array(Set(found + ["127.0.0.1"])).sorted()
    }

    static func open(port: UInt16, reach: RemoteLinuxListener.Reach,
                     interfaces: @escaping @Sendable () -> [RemoteInterfaceAddress]) -> Result<RemoteLinuxServing, RemoteSocketFailure> {
        var bound: [String: Int32] = [:]
        var chosenPort = port
        func closeAll() { bound.values.forEach { _ = close($0) } }
        switch reach {
        case .everyAddress:
            // IPv6 and IPv4 on one socket where the computer has IPv6, IPv4 alone where it does not.
            switch listen(on: "::", port: port, dualStack: true) {
            case let .success(socket):
                bound["::"] = socket
            case .failure:
                switch listen(on: "0.0.0.0", port: port) {
                case let .success(socket): bound["0.0.0.0"] = socket
                case let .failure(failure): return .failure(failure)
                }
            }
            chosenPort = bound.values.first.flatMap(localPort(of:)) ?? port
        case .privateNetworks:
            // Loopback first, so the port is chosen where nothing else can hold it; the others then take that port.
            let addresses = privateAddresses(interfaces())
            for address in ["127.0.0.1"] + addresses.filter({ $0 != "127.0.0.1" }) {
                switch listen(on: address, port: chosenPort) {
                case let .success(socket):
                    bound[address] = socket
                    if chosenPort == 0 { chosenPort = localPort(of: socket) ?? 0 }
                case let .failure(failure) where bound.isEmpty || failure.code == EADDRINUSE:
                    closeAll()
                    return .failure(failure)
                case .failure:
                    // An address that went in the moment since it was read; the next change binds what is there.
                    continue
                }
            }
        }
        var pipe: [Int32] = [-1, -1]
        guard !bound.isEmpty, Glibc.pipe(&pipe) == 0 else {
            let failure = RemoteSocketFailure("pipe")
            closeAll()
            return .failure(failure)
        }
        for end in pipe {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        return .success(RemoteLinuxServing(port: chosenPort, reach: reach, interfaces: interfaces, listening: bound,
                                           wake: (pipe[0], pipe[1])))
    }

    /// A non-blocking listening socket on `address` and `port` that closes when Yardlet starts a program. Not shared
    /// beyond `SO_REUSEADDR`, which on Linux lets a restarted host bind while its last connections wait out TIME_WAIT
    /// but never beside another listener: a second Yardlet falls back to a free port instead.
    static func listen(on address: String, port: UInt16, dualStack: Bool = false) -> Result<Int32, RemoteSocketFailure> {
        let isIPv6 = address.contains(":")
        let type = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
        let socket = Glibc.socket(isIPv6 ? AF_INET6 : AF_INET, type, 0)
        guard socket >= 0 else { return .failure(RemoteSocketFailure("socket")) }
        func fail(_ call: String) -> Result<Int32, RemoteSocketFailure> {
            let failure = RemoteSocketFailure(call)
            _ = close(socket)
            return .failure(failure)
        }
        guard setOption(socket, SOL_SOCKET, SO_REUSEADDR, 1) else { return fail("SO_REUSEADDR") }
        let bound: Int32
        if isIPv6 {
            guard setOption(socket, Int32(IPPROTO_IPV6), IPV6_V6ONLY, dualStack ? 0 : 1) else { return fail("IPV6_V6ONLY") }
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, address, &socketAddress.sin6_addr) == 1 else { return fail("inet_pton") }
            bound = withUnsafePointer(to: socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var socketAddress = sockaddr_in()
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian
            guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else { return fail("inet_pton") }
            bound = withUnsafePointer(to: socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0 else { return fail("bind \(address):\(port)") }
        guard Glibc.listen(socket, SOMAXCONN) == 0 else { return fail("listen") }
        return .success(socket)
    }

    static func setOption(_ socket: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var value = value
        return setsockopt(socket, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func localPort(of socket: Int32) -> UInt16? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard read == 0 else { return nil }
        // The port sits at the same place in an IPv4 and an IPv6 address: after the family.
        return withUnsafeBytes(of: address) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
    }

    func start(server: RemoteServer, staticKey: RemoteKeyPair, onFailure: @escaping @Sendable (String) -> Void) {
        if reach == .privateNetworks {
            let stop = RemoteAddressSelection.watchSystemInterfaces { [weak self] in
                guard let self else { return }
                lock.withLock { interfacesChanged = true }
                poke()
            }
            lock.withLock { stopWatching = stop }
        }
        let thread = Thread { [self] in serve(server: server, staticKey: staticKey, onFailure: onFailure) }
        thread.name = "Yardlet remote listener"
        thread.start()
    }

    /// Closes every connection and the sockets, and waits for the thread to have.
    func stop() {
        let stopWatching = lock.withLock { () -> (() -> Void)? in
            stopping = true
            defer { self.stopWatching = nil }
            return self.stopWatching
        }
        stopWatching?()
        poke()
        _ = finished.wait(timeout: .now() + 5)
    }

    /// Wakes the thread, to send what was queued, to bind what the network now holds, or to stop.
    func poke() {
        lock.withLock {
            guard !wakeClosed else { return }
            var byte: UInt8 = 0
            _ = write(wakeWrite, &byte, 1)
        }
    }

    /// Binds the private addresses the computer holds now and closes the sockets of those it no longer does; on the
    /// thread, when the network watch said something changed.
    private func followInterfaces() {
        let wanted = Set(Self.privateAddresses(interfaces()))
        let current = lock.withLock { listening }
        for (address, socket) in current where !wanted.contains(address) {
            _ = close(socket)
            _ = lock.withLock { listening.removeValue(forKey: address) }
        }
        for address in wanted.subtracting(current.keys).sorted() {
            guard case let .success(socket) = Self.listen(on: address, port: port) else { continue }
            lock.withLock { listening[address] = socket }
        }
    }

    private func serve(server: RemoteServer, staticKey: RemoteKeyPair, onFailure: @Sendable (String) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !lock.withLock({ stopping }) {
            if lock.withLock({ () -> Bool in
                defer { interfacesChanged = false }
                return interfacesChanged
            }) {
                followInterfaces()
            }
            let now = Date()
            for channel in channels where channel.isOverdue(at: now) { channel.drop() }
            channels.removeAll { channel in
                guard !channel.flush() else { return false }
                end(channel)
                return true
            }
            let sockets = lock.withLock { listening.sorted { $0.key < $1.key } }
            var polled = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            polled += sockets.map { pollfd(fd: $0.value, events: Int16(POLLIN), revents: 0) }
            polled += channels.map {
                pollfd(fd: $0.socket, events: Int16(POLLIN) | ($0.isWaitingToSend ? Int16(POLLOUT) : 0), revents: 0)
            }
            // A handshake or a close not done in time ends its connection, so the thread looks every second while
            // one is under way.
            let timeout: Int32 = channels.contains { $0.isHandshaking || $0.isClosing } ? 1_000 : -1
            if poll(&polled, nfds_t(polled.count), timeout) < 0 {
                if errno == EINTR { continue }
                onFailure(RemoteSocketFailure("poll").message)
                break
            }
            if polled[0].revents != 0 {
                while Self.receive(wakeRead, into: &buffer, limit: buffer.count) > 0 {}
            }
            let served = channels
            for (index, channel) in served.enumerated() where polled[1 + sockets.count + index].revents != 0 {
                read(channel, into: &buffer, server: server, staticKey: staticKey)
            }
            for (index, (address, socket)) in sockets.enumerated() {
                let events = polled[1 + index].revents
                if events & Int16(POLLERR | POLLNVAL) != 0 {
                    _ = close(socket)
                    let left = lock.withLock { () -> Int in
                        _ = listening.removeValue(forKey: address)
                        return listening.count
                    }
                    if left == 0 {
                        onFailure("The listening socket on \(address) failed")
                        lock.withLock { stopping = true }
                    }
                } else if events != 0 {
                    acceptWaiting(on: socket)
                }
            }
        }
        for channel in channels {
            channel.drop()
            end(channel)
        }
        channels = []
        lock.withLock {
            listening.values.forEach { _ = close($0) }
            listening = [:]
            wakeClosed = true
            _ = close(wakeRead)
            _ = close(wakeWrite)
        }
        finished.signal()
    }

    /// Every connection waiting to be accepted. A listener holds at most a few that have not finished their
    /// handshakes from one address, and a few more in all (§7): the oldest goes for a new one.
    private func acceptWaiting(on listening: Int32) {
        while true {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let socket = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listening, $0, &length) }
            }
            guard socket >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // Out of descriptors or memory, the connection still waits and poll would wake at once for it again:
                // the thread rests before it next looks.
                if [EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(errno) { usleep(100_000) }
                return
            }
            let host = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    RemoteAddressSelection.numericHost($0, length: Int32(length))
                }
            } ?? "unknown"
            guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0, fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0 else {
                _ = close(socket)
                continue
            }
            // Each frame goes out whole at once: a small one does not wait for the last one's acknowledgement.
            _ = Self.setOption(socket, Int32(IPPROTO_TCP), TCP_NODELAY, 1)
            let waiting = channels.filter(\.isHandshaking).map { (id: ObjectIdentifier($0), host: $0.host, since: $0.acceptedAt) }
            let displaced = Set(RemoteHandshakeAdmission.displaced(waiting: waiting, host: host))
            for channel in channels where displaced.contains(ObjectIdentifier(channel)) { channel.drop() }
            channels.append(RemoteLinuxChannel(socket: socket, host: host, path: RemoteAddressSelection.path(ofPeer: host),
                                               poke: { [weak self] in self?.poke() }))
        }
    }

    private func read(_ channel: RemoteLinuxChannel, into buffer: inout [UInt8], server: RemoteServer, staticKey: RemoteKeyPair) {
        // The opening request is read no further than its limit and a byte, which is past it.
        let limit = channel.request.map { RemoteWebSocket.maxRequestBytes + 1 - $0.count } ?? buffer.count
        let count = Self.receive(channel.socket, into: &buffer, limit: limit)
        guard count > 0 else {
            // The phone closed (0), or the socket failed; nothing to read yet is not an end.
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { channel.drop() }
            return
        }
        var bytes = Data(buffer[..<count])
        if let request = channel.request {
            switch RemoteWebSocket.open(request + bytes) {
            case .incomplete:
                channel.request = request + bytes
                return
            case let .refused(response):
                channel.request = nil
                channel.refuse(with: response)
                return
            case let .accepted(response, rest):
                channel.request = nil
                channel.queue(response)
                channel.secure = RemoteSecureConnection(transport: channel, server: server, staticKey: staticKey, path: channel.path)
                bytes = rest
            }
        }
        // Refused: what follows is not read.
        guard let secure = channel.secure else { return }
        for event in channel.reader.read(bytes) {
            switch event {
            case let .binary(message):
                // A whole message: one that does not decrypt is refused.
                if !secure.receive(message) { secure.refuse() }
            case let .ping(payload):
                channel.queue(RemoteWebSocket.frame(.pong, payload))
            case .close:
                channel.close(.normal)
            case let .refused(code):
                channel.close(code)
            }
        }
    }

    /// What the socket holds, up to `limit` bytes, read into `buffer`, as `recv` returns it.
    private static func receive(_ socket: Int32, into buffer: inout [UInt8], limit: Int) -> Int {
        buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, min(limit, $0.count), 0) }
    }

    private func end(_ channel: RemoteLinuxChannel) {
        _ = close(channel.socket)
        channel.secure?.transportClosed()
    }
}

/// One phone's socket on the Linux listener, a WebSocket carrying binary frames, as `RemoteWinsockChannel` is on
/// Windows. Only the listener's thread reads, writes and closes the socket; any thread may queue frames, which it sends.
final class RemoteLinuxChannel: RemoteFrameChannel, @unchecked Sendable {
    private enum Ending {
        case afterSending
        case now
    }

    let socket: Int32
    let host: String
    let path: RemotePath
    let acceptedAt = Date()
    /// The opening request as it comes in, until it is answered; on the listener's thread, as are the two below.
    var request: Data? = Data()
    var reader = RemoteWebSocketReader()
    var secure: RemoteSecureConnection?
    private let poke: @Sendable () -> Void
    private let lock = NSLock()
    /// What waits for the socket, in order, and how much of the first it has taken (under `lock`).
    private var outbox: [Data] = []
    private var sentOfFirst = 0
    private var unsent = 0
    private var ending: Ending?
    /// When a close began to wait for the socket to take its last bytes.
    private var closingSince: Date?

    init(socket: Int32, host: String, path: RemotePath, poke: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.host = host
        self.path = path
        self.poke = poke
    }

    /// Not yet past message 2: the WebSocket is still opening or the Noise handshake is not done.
    var isHandshaking: Bool { secure?.isHandshaking ?? true }

    var isWaitingToSend: Bool { lock.withLock { !outbox.isEmpty } }

    var isClosing: Bool { lock.withLock { ending != nil } }

    /// Not past its handshakes, or not done sending its close, in the time either may take: a phone that stops reading
    /// cannot hold the socket.
    func isOverdue(at now: Date) -> Bool {
        let since = lock.withLock { closingSince } ?? (isHandshaking ? acceptedAt : nil)
        return since.map { now.timeIntervalSince($0) > RemoteHandshakeAdmission.handshakeTimeout } ?? false
    }

    func sendFrame(_ frame: Data) {
        let queued = lock.withLock { () -> Bool in
            guard ending == nil else { return false }
            // A phone that asks and never reads would leave every answer here: past the limit the connection goes,
            // with what it held (§7).
            guard unsent + frame.count <= RemoteProtocol.maxUnsentBytes else {
                ending = .now
                return true
            }
            append(RemoteWebSocket.frame(.binary, frame))
            return true
        }
        if queued { poke() }
    }

    func close(_ code: RemoteCloseCode) {
        let queued = lock.withLock { () -> Bool in
            guard ending == nil else { return false }
            append(RemoteWebSocket.closeFrame(code.rawValue))
            ending = .afterSending
            closingSince = Date()
            return true
        }
        if queued { poke() }
    }

    /// Bytes besides the frames the connection sends: the handshake's answer, a pong. On the listener's thread,
    /// which sends them before it next waits.
    func queue(_ bytes: Data) {
        lock.withLock {
            if ending == nil { append(bytes) }
        }
    }

    /// The opening refused: its answer, then the end.
    func refuse(with response: Data) {
        lock.withLock {
            guard ending == nil else { return }
            append(response)
            ending = .afterSending
            closingSince = Date()
        }
    }

    /// Ends the connection at the listener's next turn, with whatever waits.
    func drop() {
        lock.withLock { ending = .now }
    }

    /// Under `lock`.
    private func append(_ bytes: Data) {
        outbox.append(bytes)
        unsent += bytes.count
    }

    /// Hands the socket what waits until it takes no more; on the listener's thread. False once the connection is to
    /// end: dropped, its last bytes sent after a close, or the socket failed.
    func flush() -> Bool {
        while true {
            let next = lock.withLock { () -> Data? in
                guard ending != .now, let first = outbox.first else { return nil }
                return first.dropFirst(sentOfFirst)
            }
            guard let next else { return lock.withLock { ending == nil } }
            let sent = next.withUnsafeBytes { send(socket, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            guard sent >= 0 else { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
            lock.withLock {
                unsent -= sent
                sentOfFirst += sent
                if sentOfFirst == outbox[0].count {
                    outbox.removeFirst()
                    sentOfFirst = 0
                }
            }
        }
    }
}
#endif
