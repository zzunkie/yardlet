#if os(Windows)
import Foundation
import WinSDK

/// The v2 listener for direct paths on Windows (§11.1, §11.3), as `RemoteSecureListener` is on the Mac: one listener on
/// every interface, port 47616 or a free one when that is taken, advertised with DNS-SD (`DnsServiceRegister`, Windows'
/// own, Windows 10 1903 and later) under the computer's discovery id rather than its name. Winsock hands it bytes, so it
/// speaks the WebSocket itself (`RemoteWebSocket`): an opening request is read up to 8 KB and answered only when it is a
/// WebSocket upgrade without Origin (a browser must not reach the remote), with `X-Yardlet-Remote: 2`, and 400
/// otherwise; a frame RFC 6455 does not allow closes with 1002, a text frame with 1003 and a message over 65,535 bytes
/// with 1009; a ping is answered and a close answered and ended; and each whole binary message goes to the connection's
/// `RemoteSecureConnection`. Connections that have not finished their handshakes are held as the Mac holds them
/// (`RemoteHandshakeAdmission`). One thread serves every socket with `WSAPoll`; other threads queue frames for it and
/// wake it. Stopping closes the listening socket and every connection before it returns.
public final class RemoteWinsockListener: RemoteDirectListening, @unchecked Sendable {
    public typealias State = RemoteDirectListenerState
    public typealias Advertisement = RemoteDirectAdvertisement

    private let server: RemoteServer
    private let staticKey: RemoteKeyPair
    private let preferredPort: UInt16
    private let advertisement: Advertisement?
    private let lock = NSLock()
    private var serving: RemoteWinsockServing?
    private var registration: RemoteDNSServiceRegistration?
    private var state = State.stopped
    /// Told whenever its state changes: on the thread that starts or stops it, or on its own when it fails.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(server: RemoteServer, staticKey: RemoteKeyPair, port: UInt16 = RemoteProtocol.securePort,
                advertisement: Advertisement?) {
        self.server = server
        self.staticKey = staticKey
        preferredPort = port
        self.advertisement = advertisement
    }

    public func start() {
        lock.withLock {
            guard serving == nil else { return }
            update(.starting)
            guard RemoteWinsock.isStarted else { return update(.failed("Winsock did not start")) }
            var opened = RemoteWinsockServing.open(port: preferredPort)
            // The preferred port is taken (another Yardlet, an old process, a range Windows keeps for itself): any
            // free port, which DNS-SD and message 2 name.
            if case .failure = opened, preferredPort != 0 { opened = RemoteWinsockServing.open(port: 0) }
            switch opened {
            case let .success(serving):
                serving.start(server: server, staticKey: staticKey) { [weak self] message in self?.fail(serving, message) }
                self.serving = serving
                if let advertisement { registration = RemoteDNSServiceRegistration.register(advertisement, port: serving.port) }
                update(.ready(port: serving.port))
            case let .failure(failure):
                update(.failed(failure.message))
            }
        }
    }

    public func stop() {
        let (serving, registration) = lock.withLock { () -> (RemoteWinsockServing?, RemoteDNSServiceRegistration?) in
            defer { self.serving = nil; self.registration = nil }
            return (self.serving, self.registration)
        }
        registration?.remove()
        serving?.stop()
        lock.withLock { update(.stopped) }
    }

    public var currentState: State {
        lock.withLock { state }
    }

    /// The thread's own socket failed: the listener stops, and says why.
    private func fail(_ failed: RemoteWinsockServing, _ message: String) {
        let registration = lock.withLock { () -> RemoteDNSServiceRegistration? in
            guard serving === failed else { return nil }
            defer { serving = nil; self.registration = nil }
            update(.failed(message))
            return self.registration
        }
        registration?.remove()
    }

    /// Under `lock`.
    private func update(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }
}

/// A Winsock call that failed, by its error.
struct RemoteWinsockFailure: Error {
    var message: String

    init(_ call: String) {
        message = "\(call) failed with Winsock error \(WSAGetLastError())"
    }
}

/// One start of the listener: its sockets, served on a thread of its own until it stops.
private final class RemoteWinsockServing: @unchecked Sendable {
    let port: UInt16
    private let listening: SOCKET
    /// A socket on loopback that other threads send a byte to, to wake the thread's poll.
    private let wake: SOCKET
    private let wakeAddress: sockaddr_in
    private let lock = NSLock()
    private var stopping = false
    private var wakeClosed = false
    private let finished = DispatchSemaphore(value: 0)
    /// The connections, on the thread alone.
    private var channels: [RemoteWinsockChannel] = []

    private init(listening: SOCKET, port: UInt16, wake: SOCKET, wakeAddress: sockaddr_in) {
        self.listening = listening
        self.port = port
        self.wake = wake
        self.wakeAddress = wakeAddress
    }

    /// Listens on every interface at `port`: IPv6 and IPv4 on one socket where the computer has IPv6, IPv4 alone where
    /// it does not. Not shared (`SO_EXCLUSIVEADDRUSE`): a second Yardlet (a QA build) must not take half of this one's
    /// phones; it falls back to a free port instead.
    static func open(port: UInt16) -> Result<RemoteWinsockServing, RemoteWinsockFailure> {
        var listening = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP.rawValue)
        let dualStack = listening != INVALID_SOCKET
        if !dualStack { listening = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue) }
        guard listening != INVALID_SOCKET else { return .failure(RemoteWinsockFailure("socket")) }
        func fail(_ call: String) -> Result<RemoteWinsockServing, RemoteWinsockFailure> {
            let failure = RemoteWinsockFailure(call)
            closesocket(listening)
            return .failure(failure)
        }
        guard setOption(listening, SOL_SOCKET, ~SO_REUSEADDR, 1) else { return fail("SO_EXCLUSIVEADDRUSE") }
        if dualStack, !setOption(listening, IPPROTO_IPV6.rawValue, IPV6_V6ONLY, 0) { return fail("IPV6_V6ONLY") }
        let bound: Int32
        if dualStack {
            var address = sockaddr_in6()
            address.sin6_family = ADDRESS_FAMILY(AF_INET6)
            address.sin6_port = port.bigEndian
            bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, Int32(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = ADDRESS_FAMILY(AF_INET)
            address.sin_port = port.bigEndian
            bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0 else { return fail("bind") }
        guard listen(listening, SOMAXCONN) == 0 else { return fail("listen") }
        guard setNonBlocking(listening), let listeningPort = localPort(of: listening) else { return fail("ioctlsocket") }
        // The wake socket: UDP on loopback, which other devices cannot reach.
        let wake = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP.rawValue)
        guard wake != INVALID_SOCKET else { return fail("socket") }
        var loopback = sockaddr_in()
        loopback.sin_family = ADDRESS_FAMILY(AF_INET)
        _ = inet_pton(AF_INET, "127.0.0.1", &loopback.sin_addr)
        let wakeBound = withUnsafePointer(to: loopback) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(wake, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard wakeBound == 0, setNonBlocking(wake), let wakePort = localPort(of: wake) else {
            let failure = RemoteWinsockFailure("bind")
            closesocket(wake)
            closesocket(listening)
            return .failure(failure)
        }
        loopback.sin_port = wakePort.bigEndian
        return .success(RemoteWinsockServing(listening: listening, port: listeningPort, wake: wake, wakeAddress: loopback))
    }

    private static func setOption(_ socket: SOCKET, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        withUnsafeBytes(of: value) {
            setsockopt(socket, level, name, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) == 0
        }
    }

    static func setNonBlocking(_ socket: SOCKET) -> Bool {
        var nonBlocking: u_long = 1
        return ioctlsocket(socket, FIONBIO, &nonBlocking) == 0
    }

    private static func localPort(of socket: SOCKET) -> UInt16? {
        var address = sockaddr_storage()
        var length = Int32(MemoryLayout<sockaddr_storage>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard read == 0 else { return nil }
        // The port sits at the same place in an IPv4 and an IPv6 address: after the family.
        return withUnsafeBytes(of: address) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
    }

    func start(server: RemoteServer, staticKey: RemoteKeyPair, onFailure: @escaping @Sendable (String) -> Void) {
        let thread = Thread { [self] in serve(server: server, staticKey: staticKey, onFailure: onFailure) }
        thread.name = "Yardlet remote listener"
        thread.start()
    }

    /// Closes every connection and the sockets, and waits for the thread to have.
    func stop() {
        lock.withLock { stopping = true }
        poke()
        _ = finished.wait(timeout: .now() + 5)
    }

    /// Wakes the thread, to send what was queued or to stop.
    func poke() {
        lock.withLock {
            guard !wakeClosed else { return }
            var byte: CChar = 0
            withUnsafePointer(to: wakeAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(wake, &byte, 1, 0, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func serve(server: RemoteServer, staticKey: RemoteKeyPair, onFailure: @Sendable (String) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !lock.withLock({ stopping }) {
            let now = Date()
            for channel in channels where channel.isOverdue(at: now) { channel.drop() }
            channels.removeAll { channel in
                guard !channel.flush() else { return false }
                end(channel)
                return true
            }
            var polled = [WSAPOLLFD(fd: listening, events: SHORT(POLLRDNORM), revents: 0),
                          WSAPOLLFD(fd: wake, events: SHORT(POLLRDNORM), revents: 0)]
            polled += channels.map {
                WSAPOLLFD(fd: $0.socket, events: SHORT(POLLRDNORM) | ($0.isWaitingToSend ? SHORT(POLLWRNORM) : 0), revents: 0)
            }
            // A handshake or a close not done in time ends its connection, so the thread looks every second while
            // one is under way.
            let timeout: Int32 = channels.contains { $0.isHandshaking || $0.isClosing } ? 1_000 : -1
            guard WSAPoll(&polled, ULONG(polled.count), timeout) != SOCKET_ERROR else {
                onFailure(RemoteWinsockFailure("WSAPoll").message)
                break
            }
            if polled[0].revents & SHORT(POLLERR | POLLNVAL) != 0 {
                onFailure("The listening socket failed")
                break
            }
            if polled[1].revents != 0 {
                while Self.receive(wake, into: &buffer, limit: buffer.count) > 0 {}
            }
            let served = channels
            for (index, channel) in served.enumerated() where polled[index + 2].revents != 0 {
                read(channel, into: &buffer, server: server, staticKey: staticKey)
            }
            if polled[0].revents != 0 { acceptWaiting() }
        }
        for channel in channels {
            channel.drop()
            end(channel)
        }
        channels = []
        closesocket(listening)
        lock.withLock {
            wakeClosed = true
            closesocket(wake)
        }
        finished.signal()
    }

    /// Every connection waiting to be accepted. A listener holds at most a few that have not finished their
    /// handshakes from one address, and a few more in all (§7): the oldest goes for a new one.
    private func acceptWaiting() {
        while true {
            var address = sockaddr_storage()
            var length = Int32(MemoryLayout<sockaddr_storage>.size)
            let socket = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listening, $0, &length) }
            }
            guard socket != INVALID_SOCKET else { return }
            let host = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { RemoteAddressSelection.numericHost($0, length: length) }
            } ?? "unknown"
            guard Self.setNonBlocking(socket) else {
                closesocket(socket)
                continue
            }
            // Each frame goes out whole at once: a small one does not wait for the last one's acknowledgement.
            _ = Self.setOption(socket, IPPROTO_TCP.rawValue, TCP_NODELAY, 1)
            let waiting = channels.filter(\.isHandshaking).map { (id: ObjectIdentifier($0), host: $0.host, since: $0.acceptedAt) }
            let displaced = Set(RemoteHandshakeAdmission.displaced(waiting: waiting, host: host))
            for channel in channels where displaced.contains(ObjectIdentifier(channel)) { channel.drop() }
            channels.append(RemoteWinsockChannel(socket: socket, host: host, path: RemoteAddressSelection.path(ofPeer: host),
                                                 poke: { [weak self] in self?.poke() }))
        }
    }

    private func read(_ channel: RemoteWinsockChannel, into buffer: inout [UInt8], server: RemoteServer, staticKey: RemoteKeyPair) {
        // The opening request is read no further than its limit and a byte, which is past it.
        let limit = channel.request.map { RemoteWebSocket.maxRequestBytes + 1 - $0.count } ?? buffer.count
        let count = Self.receive(channel.socket, into: &buffer, limit: limit)
        guard count > 0 else {
            // The phone closed (0), or the socket failed; nothing to read yet is not an end.
            if count == 0 || WSAGetLastError() != WSAEWOULDBLOCK { channel.drop() }
            return
        }
        var bytes = Data(buffer[..<Int(count)])
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
    private static func receive(_ socket: SOCKET, into buffer: inout [UInt8], limit: Int) -> Int32 {
        buffer.withUnsafeMutableBytes {
            recv(socket, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(min(limit, $0.count)), 0)
        }
    }

    private func end(_ channel: RemoteWinsockChannel) {
        closesocket(channel.socket)
        channel.secure?.transportClosed()
    }
}

/// One phone's socket on the Windows listener, a WebSocket carrying binary frames, as `RemoteNWFrameChannel` is on the
/// Mac. Only the listener's thread reads, writes and closes the socket; any thread may queue frames, which it sends.
final class RemoteWinsockChannel: RemoteFrameChannel, @unchecked Sendable {
    private enum Ending {
        case afterSending
        case now
    }

    let socket: SOCKET
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

    init(socket: SOCKET, host: String, path: RemotePath, poke: @escaping @Sendable () -> Void) {
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
            let sent = next.withUnsafeBytes {
                send(socket, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
            }
            guard sent != SOCKET_ERROR else { return WSAGetLastError() == WSAEWOULDBLOCK }
            lock.withLock {
                unsent -= Int(sent)
                sentOfFirst += Int(sent)
                if sentOfFirst == outbox[0].count {
                    outbox.removeFirst()
                    sentOfFirst = 0
                }
            }
        }
    }
}

/// The listener's DNS-SD service (§11.3), registered with Windows on every interface until the listener stops. Windows
/// may read the request and the service until it has reported the registration and its removal done, so they are let
/// go once both reports have come.
private final class RemoteDNSServiceRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private let request: UnsafeMutablePointer<DNS_SERVICE_REGISTER_REQUEST>
    private let instance: PDNS_SERVICE_INSTANCE
    /// Reports still to come.
    private var reports = 0
    private var isRemoving = false

    private init(instance: PDNS_SERVICE_INSTANCE) {
        self.instance = instance
        request = .allocate(capacity: 1)
        request.initialize(to: DNS_SERVICE_REGISTER_REQUEST())
    }

    /// Registers `Yardlet-<discovery id>._yardlet._tcp.local` on `port`, at this computer's own `.local` name; nil when
    /// Windows refuses at once.
    static func register(_ advertisement: RemoteDirectAdvertisement, port: UInt16) -> RemoteDNSServiceRegistration? {
        let keys = advertisement.txt.keys.sorted()
        let texts = ["\(advertisement.name).\(RemoteProtocol.bonjourType).local", "\(hostName()).local"]
            + keys + keys.map { advertisement.txt[$0] ?? "" }
        let strings = texts.map { text -> UnsafeMutablePointer<WCHAR> in
            let units = Array(text.utf16) + [0]
            let pointer = UnsafeMutablePointer<WCHAR>.allocate(capacity: units.count)
            pointer.initialize(from: units, count: units.count)
            return pointer
        }
        defer { strings.forEach { $0.deallocate() } }
        var keyStrings = strings[2..<2 + keys.count].map { PCWSTR?(UnsafePointer($0)) }
        var valueStrings = strings[(2 + keys.count)...].map { PCWSTR?(UnsafePointer($0)) }
        guard let instance = DnsServiceConstructInstance(strings[0], strings[1], nil, nil, port, 0, 0, DWORD(keys.count),
                                                         &keyStrings, &valueStrings) else { return nil }
        let registration = RemoteDNSServiceRegistration(instance: instance)
        registration.request.pointee.Version = ULONG(DNS_QUERY_REQUEST_VERSION1)
        registration.request.pointee.InterfaceIndex = 0
        registration.request.pointee.pServiceInstance = instance
        registration.request.pointee.pRegisterCompletionCallback = { _, context, copy in
            // Each report hands over a copy of the service, which is the receiver's to free.
            if let copy { DnsServiceFreeInstance(copy) }
            if let context { Unmanaged<RemoteDNSServiceRegistration>.fromOpaque(context).takeUnretainedValue().reported() }
        }
        // Kept until both reports have come.
        registration.request.pointee.pQueryContext = Unmanaged.passRetained(registration).toOpaque()
        registration.reports = 1
        guard DnsServiceRegister(registration.request, nil) == DWORD(DNS_REQUEST_PENDING) else {
            registration.reports = 0
            registration.letGo()
            return nil
        }
        return registration
    }

    /// Takes the service off the network.
    func remove() {
        lock.withLock {
            isRemoving = true
            reports += 1
        }
        if DnsServiceDeRegister(request, nil) != DWORD(DNS_REQUEST_PENDING) { reported() }
    }

    private func reported() {
        let done = lock.withLock { () -> Bool in
            reports -= 1
            return reports == 0 && isRemoving
        }
        if done { letGo() }
    }

    private func letGo() {
        DnsServiceFreeInstance(instance)
        let context = request.pointee.pQueryContext
        request.deinitialize(count: 1)
        request.deallocate()
        if let context { Unmanaged<RemoteDNSServiceRegistration>.fromOpaque(context).release() }
    }

    /// The computer's DNS host name, whose `.local` name Windows answers for itself.
    private static func hostName() -> String {
        var size = DWORD(256)
        var name = [WCHAR](repeating: 0, count: Int(size))
        guard GetComputerNameExW(ComputerNameDnsHostname, &name, &size) else { return ProcessInfo.processInfo.hostName }
        return String(decoding: name.prefix(Int(size)), as: UTF16.self)
    }
}
#endif
