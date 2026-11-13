#if os(Linux)
import Foundation
import FoundationNetworking
import Glibc

/// A WebSocket for v2 frames on Linux (docs/REMOTE_PROTOCOL.md §11.1), with the calls of the `URLSessionWebSocketTask`
/// it stands for elsewhere. Foundation on Linux has a WebSocket only when it was built against libcurl 7.86 or later
/// and the system's libcurl was built with WebSocket support, which curl turned on by default in 8.11; the toolchain
/// the Linux host is built with (Ubuntu 22.04's, curl 7.81) has none. So libcurl here only opens the connection
/// (`CURLOPT_CONNECT_ONLY`: the TCP connection, TLS checked against the system's certificates, a proxy the environment
/// names), which every libcurl does, and the WebSocket on it is RFC 6455's opening handshake and frames. v2 uses no
/// extensions, and an answer that agrees one ends the connection. A thread of its own owns each socket's libcurl
/// handle; the calls hand it frames and take its messages under a lock.
final class RemoteClientWebSocket: @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    /// How the connection ended, in a reader's words.
    struct Ending: LocalizedError, CustomStringConvertible {
        var description: String
        var errorDescription: String? { description }
    }

    private let url: URL
    private let maximumMessageSize: Int
    private let timeout: TimeInterval
    private let callbacks = DispatchQueue(label: "yardlet.remote.websocket")
    /// Wakes the socket's thread when a frame is queued.
    private let wake: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var code = CloseCode.invalid
    private var reason: Data?
    /// Why the connection ended. What is pending then fails with it.
    private var ending: Ending?
    private var isResumed = false
    private var isOpen = false
    private var isClosing = false
    /// Whether a close frame is queued; nothing is sent after it.
    private var closeQueued = false
    /// A frame to send, what to call once it is sent, and whether it is the close frame.
    private typealias Outgoing = (bytes: Data, sent: (@Sendable (Error?) -> Void)?, isClose: Bool)
    private var outgoing: [Outgoing] = []
    private var messages: [Message] = []
    private var receivers: [@Sendable (Result<Message, Error>) -> Void] = []

    /// `timeout` limits reaching the peer and its answer to the opening handshake; what comes after is the caller's to
    /// watch.
    static func connecting(to url: URL, maximumMessageSize: Int, timeout: TimeInterval = 60) -> RemoteClientWebSocket {
        RemoteClientWebSocket(url: url, maximumMessageSize: maximumMessageSize, timeout: timeout)
    }

    private init(url: URL, maximumMessageSize: Int, timeout: TimeInterval) {
        self.url = url
        self.maximumMessageSize = maximumMessageSize
        self.timeout = timeout
        var ends: [Int32] = [-1, -1]
        if pipe(&ends) == 0 {
            for end in ends {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            }
        } else {
            ends = [-1, -1]
        }
        wake = (ends[0], ends[1])
    }

    deinit {
        // Only here: a descriptor closed while another thread may still write to it could be someone else's by then.
        if wake.read >= 0 {
            close(wake.read)
            close(wake.write)
        }
    }

    var closeCode: CloseCode { lock.withLock { code } }
    var closeReason: Data? { lock.withLock { reason } }

    func resume() {
        let first = lock.withLock { () -> Bool in
            defer { isResumed = true }
            return !isResumed
        }
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "yardlet.remote.websocket"
        thread.start()
    }

    func cancel(with code: CloseCode, reason: Data?) {
        let (open, first) = lock.withLock { () -> (Bool, Bool) in
            defer { isClosing = true }
            if self.code == .invalid { self.code = code }
            return (isOpen, !isClosing)
        }
        guard first else { return }
        end("Cancelled")
        if open { queueClose(code.rawValue, reason: reason) } else { wakeUp() }
    }

    func send(_ message: Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let frame: Data
        switch message {
        case let .data(data): frame = Self.frame(.binary, data)
        case let .string(text): frame = Self.frame(.text, Data(text.utf8))
        @unknown default: return callbacks.async { completionHandler(Ending(description: "Unknown message")) }
        }
        let refused = lock.withLock { () -> Ending? in
            if let ending { return ending }
            outgoing.append((frame, completionHandler, false))
            return nil
        }
        if let refused { return callbacks.async { completionHandler(refused) } }
        wakeUp()
    }

    func send(_ message: Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(message) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func receive(completionHandler: @escaping @Sendable (Result<Message, Error>) -> Void) {
        let ready = lock.withLock { () -> Result<Message, Error>? in
            if !messages.isEmpty { return .success(messages.removeFirst()) }
            if let ending { return .failure(ending) }
            receivers.append(completionHandler)
            return nil
        }
        if let ready { callbacks.async { completionHandler(ready) } }
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            receive { continuation.resume(with: $0) }
        }
    }

    // MARK: - The socket's thread

    private static let closeLimit: TimeInterval = 5

    private func run() {
        guard let curl = LinuxCurl.shared else { return finish("libcurl could not be loaded") }
        guard let handle = curl.easyInit() else { return finish("libcurl could not start a connection") }
        let errors = UnsafeMutablePointer<CChar>.allocate(capacity: LinuxCurl.errorSize)
        errors.initialize(repeating: 0, count: LinuxCurl.errorSize)
        defer {
            curl.cleanup(handle)
            errors.deallocate()
        }
        guard let address = Self.connectionAddress(url) else { return finish("Not a WebSocket address: \(url)") }
        _ = curl.setPointer(handle, LinuxCurl.errorBuffer, errors)
        _ = address.withCString { curl.setPointer(handle, LinuxCurl.address, $0) }
        _ = curl.setLong(handle, LinuxCurl.connectOnly, 1)
        // The request is HTTP/1.1's upgrade, so TLS offers only HTTP/1.1.
        _ = curl.setLong(handle, LinuxCurl.httpVersion, LinuxCurl.http11)
        _ = curl.setLong(handle, LinuxCurl.noSignal, 1)
        // Keystrokes and requests sent together leave at once, not after the one before them is acknowledged.
        _ = curl.setLong(handle, LinuxCurl.tcpNoDelay, 1)
        _ = curl.setLong(handle, LinuxCurl.connectTimeout, Int((timeout * 1000).rounded(.up)))
        let connected = curl.perform(handle)
        guard connected == LinuxCurl.ok else { return finish(curl.message(connected, errors)) }
        var socket: Int32 = -1
        guard curl.socket(handle, LinuxCurl.activeSocket, &socket) == LinuxCurl.ok, socket >= 0 else {
            return finish("libcurl has no socket for the connection")
        }
        let connection = Connection(curl: curl, handle: handle, socket: socket, errors: errors)
        do {
            let rest = try open(connection)
            try serve(connection, rest: rest)
            finish(nil)
        } catch {
            finish("\(error)")
        }
    }

    /// The opening handshake (RFC 6455 §4.1): what the server sent after its answer, the start of its first frame.
    private func open(_ connection: Connection) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        guard let target = Self.requestTarget(url), let host = Self.hostHeader(url) else {
            throw Ending(description: "Not a WebSocket address: \(url)")
        }
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        var unsent = [UInt8](request.utf8)[...]
        let late = Ending(description: "The server did not answer in time")
        while !unsent.isEmpty {
            guard Date() < deadline else { throw late }
            guard try wait(connection, for: Int16(POLLOUT), until: deadline) else { continue }
            unsent = unsent.dropFirst(try connection.send(unsent))
        }
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let end = Self.headEnd(received) {
                try Self.checkAnswer(String(decoding: received[..<end], as: UTF8.self), key: key)
                let opened = lock.withLock { () -> Bool in
                    guard !isClosing else { return false }
                    isOpen = true
                    return true
                }
                guard opened else { throw Ending(description: "Cancelled") }
                return Array(received[(end + 4)...])
            }
            guard received.count < 16 * 1024 else { throw Ending(description: "The server's answer is too long") }
            guard Date() < deadline else { throw late }
            guard try wait(connection, for: Int16(POLLIN), until: deadline) else { continue }
            guard let count = try connection.receive(into: &buffer) else { continue }
            guard count > 0 else { throw Ending(description: "The server closed the connection before answering") }
            received += buffer[..<count]
        }
    }

    /// Moves frames both ways until the connection closes: the peer's close, our close answered or not answered
    /// within `closeLimit`, or the connection's end.
    private func serve(_ connection: Connection, rest: [UInt8]) throws {
        var reader = Reader(limit: maximumMessageSize)
        var sending: (bytes: ArraySlice<UInt8>, sent: (@Sendable (Error?) -> Void)?, isClose: Bool)?
        var closeSent: Date?
        var peerClosed = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        handle(reader.read(rest[...]), peerClosed: &peerClosed)
        while true {
            if sending == nil, let next = lock.withLock({ () -> Outgoing? in outgoing.isEmpty ? nil : outgoing.removeFirst() }) {
                sending = ([UInt8](next.bytes)[...], next.sent, next.isClose)
            }
            if let closeSent, peerClosed || Date().timeIntervalSince(closeSent) > Self.closeLimit { return }
            if peerClosed, sending == nil, closeSent == nil, !lock.withLock({ closeQueued }) { return }
            var events = peerClosed ? 0 : Int16(POLLIN)
            if sending != nil { events |= Int16(POLLOUT) }
            let deadline = closeSent.map { $0.addingTimeInterval(Self.closeLimit) } ?? Date().addingTimeInterval(1)
            guard try wait(connection, for: events, until: deadline) else { continue }
            if var current = sending {
                current.bytes = current.bytes.dropFirst(try connection.send(current.bytes))
                if current.bytes.isEmpty {
                    if let done = current.sent { callbacks.async { done(nil) } }
                    if current.isClose { closeSent = Date() }
                    sending = nil
                } else {
                    sending = current
                }
            }
            // Everything libcurl has, TLS's buffered records too, before waiting again.
            while !peerClosed, let count = try connection.receive(into: &buffer) {
                guard count > 0 else { throw Ending(description: "The connection ended") }
                handle(reader.read(buffer[..<count]), peerClosed: &peerClosed)
            }
        }
    }

    private func handle(_ events: [Reader.Event], peerClosed: inout Bool) {
        for event in events {
            switch event {
            case let .message(message):
                deliver(message)
            case let .ping(payload):
                lock.withLock {
                    if !closeQueued { outgoing.append((Self.frame(.pong, payload), nil, false)) }
                }
            case let .close(closeCode, closeReason):
                peerClosed = true
                lock.withLock {
                    code = closeCode.flatMap { CloseCode(rawValue: Int($0)) } ?? .noStatusReceived
                    reason = closeReason
                }
                end("The peer closed the connection")
                queueClose(CloseCode.normalClosure.rawValue, reason: nil)
            case let .refused(closeCode, description):
                end(description)
                queueClose(closeCode.rawValue, reason: nil)
            }
        }
    }

    /// Waits until the socket is ready for `events` or a frame is queued; false when `deadline` passes first.
    private func wait(_ connection: Connection, for events: Int16, until deadline: Date) throws -> Bool {
        var descriptors = [pollfd(fd: connection.socket, events: events, revents: 0),
                           pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
        let milliseconds = max(0, Int32(min(deadline.timeIntervalSinceNow, 60) * 1000))
        let ready = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
        if ready < 0 {
            guard errno == EINTR else { throw Ending(description: "poll failed: \(String(cString: strerror(errno)))") }
            return false
        }
        if descriptors[1].revents != 0 {
            var drained = [UInt8](repeating: 0, count: 64)
            while read(wake.read, &drained, drained.count) > 0 {}
            if lock.withLock({ ending != nil && !isOpen }) { throw Ending(description: "Cancelled") }
        }
        // An error or a hang-up shows in the next read.
        return descriptors[0].revents != 0 || (ready > 0 && descriptors[1].revents != 0)
    }

    // MARK: - Ending

    private func wakeUp() {
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
    }

    private func queueClose(_ rawCode: Int, reason: Data?) {
        let queued = lock.withLock { () -> Bool in
            guard isOpen, !closeQueued else { return false }
            closeQueued = true
            var payload = Data([UInt8(truncatingIfNeeded: rawCode >> 8), UInt8(truncatingIfNeeded: rawCode)])
            payload += (reason ?? Data()).prefix(123)
            outgoing.append((Self.frame(.close, payload), nil, true))
            return true
        }
        if queued { wakeUp() }
    }

    /// The first reason the connection ended stands; whatever waits for a message then fails with it.
    @discardableResult
    private func end(_ description: String) -> Ending {
        let (first, waiting) = lock.withLock { () -> (Ending, [@Sendable (Result<Message, Error>) -> Void]) in
            let first = ending ?? Ending(description: description)
            ending = first
            defer { receivers = [] }
            return (first, receivers)
        }
        if !waiting.isEmpty { callbacks.async { for receiver in waiting { receiver(.failure(first)) } } }
        return first
    }

    /// The thread's last step: the reason stands, and what is still queued fails with it.
    private func finish(_ description: String?) {
        let ended = end(description ?? "The connection ended")
        let unsent = lock.withLock { () -> [@Sendable (Error?) -> Void] in
            defer { outgoing = [] }
            isOpen = false
            isClosing = true
            return outgoing.compactMap { $0.sent }
        }
        if !unsent.isEmpty { callbacks.async { for sent in unsent { sent(ended) } } }
    }

    private func deliver(_ message: Message) {
        let receiver = lock.withLock { () -> (@Sendable (Result<Message, Error>) -> Void)? in
            guard ending == nil else { return nil }
            if receivers.isEmpty {
                messages.append(message)
                return nil
            }
            return receivers.removeFirst()
        }
        if let receiver { callbacks.async { receiver(.success(message)) } }
    }

    // MARK: - Frames and addresses

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// A client's frame: whole, its length in the fewest bytes, and masked (RFC 6455 §5.3).
    static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ...0xFFFF:
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            frame.append(0x80 | 127)
            frame += stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: payload.count >> $0) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame += mask
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= mask[index & 3] }
        return frame + masked
    }

    /// The address libcurl connects to: `http` for `ws`, `https` for `wss`.
    static func connectionAddress(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: return nil
        }
        return components.string
    }

    static func requestTarget(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    static func hostHeader(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.percentEncodedHost, !host.isEmpty else { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return host + (components.port.map { ":\($0)" } ?? "")
    }

    /// Where the answer's head ends: the index of its blank line's `\r\n\r\n`.
    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        return (0...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }
    }

    /// A server's answer accepts the upgrade (RFC 6455 §4.1, the client's checks), and agrees no extension or
    /// subprotocol, which the request offered none of.
    private static func checkAnswer(_ head: String, key: String) throws {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), status[1] == "101" else {
            throw Ending(description: "The server answered \(lines[0].prefix(120)) rather than switching to a WebSocket")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        func tokens(_ name: String) -> [String] {
            (headers[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        guard tokens("upgrade").contains("websocket"), tokens("connection").contains("upgrade"),
              headers["sec-websocket-accept"] == RemoteWebSocket.acceptValue(for: key) else {
            throw Ending(description: "The server's answer does not accept the WebSocket")
        }
        guard headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil else {
            throw Ending(description: "The server agreed an extension or subprotocol the request did not offer")
        }
    }

    /// A server's frames read back into whole messages (RFC 6455 §5): unmasked, text or binary, a message perhaps in
    /// fragments with control frames between them, and the bytes cut wherever the socket's reads cut them. A message
    /// over `limit` closes with 1009 before anything of it is kept.
    struct Reader {
        enum Event {
            case message(Message)
            case ping(Data)
            /// The peer closed, with the code and reason its frame named.
            case close(UInt16?, Data?)
            /// The connection is to close with this code, for this reason. Nothing is read after it.
            case refused(CloseCode, String)
        }

        let limit: Int
        private var buffer: [UInt8] = []
        private var message: (isText: Bool, data: Data)?
        private var ended = false

        init(limit: Int) {
            self.limit = limit
        }

        mutating func read(_ bytes: ArraySlice<UInt8>) -> [Event] {
            guard !ended else { return [] }
            buffer += bytes
            var events: [Event] = []
            var start = 0
            while let frame = next(at: start) {
                start += frame.length
                guard let event = frame.event else { continue }
                events.append(event)
                switch event {
                case .close, .refused:
                    ended = true
                    buffer = []
                    return events
                case .message, .ping:
                    break
                }
            }
            buffer.removeFirst(start)
            return events
        }

        private mutating func next(at start: Int) -> (event: Event?, length: Int)? {
            let available = buffer.count - start
            guard available >= 2 else { return nil }
            let first = buffer[start], second = buffer[start + 1]
            let isFinal = first & 0x80 != 0
            let shortLength = Int(second & 0x7F)
            // No extension is agreed, so the reserved bits are clear, and a server masks nothing.
            guard first & 0x70 == 0, second & 0x80 == 0, let opcode = Opcode(rawValue: first & 0x0F) else {
                return (.refused(.protocolError, "The server sent a frame WebSocket does not allow"), 0)
            }
            switch opcode {
            case .close, .ping, .pong:
                // A control frame is never in fragments, and its length fits the first byte.
                guard isFinal, shortLength <= 125 else {
                    return (.refused(.protocolError, "The server sent a control frame WebSocket does not allow"), 0)
                }
            case .text, .binary:
                guard message == nil else { return (.refused(.protocolError, "The server began a message inside another"), 0) }
            case .continuation:
                guard message != nil else { return (.refused(.protocolError, "The server continued no message"), 0) }
            }
            var length = shortLength
            var header = 2
            if shortLength == 126 {
                guard available >= 4 else { return nil }
                length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                header = 4
            } else if shortLength == 127 {
                guard available >= 10 else { return nil }
                let wide = (2..<10).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[start + $1]) }
                guard wide <= UInt64(limit) else { return (.refused(.messageTooBig, "The server's message is too big"), 0) }
                length = Int(wide)
                header = 10
            }
            if opcode == .text || opcode == .binary || opcode == .continuation, (message?.data.count ?? 0) + length > limit {
                return (.refused(.messageTooBig, "The server's message is too big"), 0)
            }
            let total = header + length
            guard available >= total else { return nil }
            let payload = Data(buffer[start + header..<start + total])
            switch opcode {
            case .text, .binary, .continuation:
                let isText = opcode == .continuation ? message?.isText ?? false : opcode == .text
                let data = (message?.data ?? Data()) + payload
                guard isFinal else {
                    message = (isText, data)
                    return (nil, total)
                }
                message = nil
                return (.message(isText ? .string(String(decoding: data, as: UTF8.self)) : .data(data)), total)
            case .ping:
                return (.ping(payload), total)
            case .close:
                let code = payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil
                return (.close(code, payload.count > 2 ? payload.dropFirst(2) : nil), total)
            case .pong:
                return (nil, total)
            }
        }
    }

    /// libcurl's handle on one connection, and its socket.
    private struct Connection {
        let curl: LinuxCurl
        let handle: OpaquePointer
        let socket: Int32
        let errors: UnsafeMutablePointer<CChar>

        /// How many of `bytes` libcurl took; 0 when the socket takes nothing now.
        func send(_ bytes: ArraySlice<UInt8>) throws -> Int {
            var sent = 0
            let result = bytes.withUnsafeBytes { curl.send(handle, $0.baseAddress, $0.count, &sent) }
            if result == LinuxCurl.again { return 0 }
            guard result == LinuxCurl.ok else { throw Ending(description: curl.message(result, errors)) }
            return sent
        }

        /// How many bytes arrived, 0 when the connection ended, nil when none are there now.
        func receive(into buffer: inout [UInt8]) throws -> Int? {
            var count = 0
            let result = buffer.withUnsafeMutableBytes { curl.receive(handle, $0.baseAddress, $0.count, &count) }
            if result == LinuxCurl.again { return nil }
            guard result == LinuxCurl.ok else { throw Ending(description: curl.message(result, errors)) }
            return count
        }
    }
}

/// The calls of the system's libcurl (`libcurl.so.4`, which Foundation on Linux needs too) that open a connection and
/// move bytes on it, loaded once. `curl_easy_setopt` and `curl_easy_getinfo` take a variable argument, which Linux's
/// x86_64 and aarch64 calling conventions pass as they pass a fixed one of its type, so each is called through a fixed
/// type for the one kind of value it is given. The constants are curl.h's, the same since curl 7.45.
struct LinuxCurl: @unchecked Sendable {
    static let ok: Int32 = 0
    static let again: Int32 = 81
    static let errorSize = 256
    static let address: Int32 = 10002
    static let errorBuffer: Int32 = 10010
    static let httpVersion: Int32 = 84
    static let http11 = 2
    static let noSignal: Int32 = 99
    static let tcpNoDelay: Int32 = 121
    static let connectOnly: Int32 = 141
    static let connectTimeout: Int32 = 156
    static let activeSocket: Int32 = 0x500000 + 44

    let easyInit: @convention(c) () -> OpaquePointer?
    let setLong: @convention(c) (OpaquePointer?, Int32, Int) -> Int32
    let setPointer: @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?) -> Int32
    let perform: @convention(c) (OpaquePointer?) -> Int32
    let socket: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    let send: @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?) -> Int32
    let receive: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?) -> Int32
    let cleanup: @convention(c) (OpaquePointer?) -> Void
    let describe: @convention(c) (Int32) -> UnsafePointer<CChar>?

    static let shared: LinuxCurl? = {
        guard let library = dlopen("libcurl.so.4", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        typealias SetLong = @convention(c) (OpaquePointer?, Int32, Int) -> Int32
        typealias SetPointer = @convention(c) (OpaquePointer?, Int32, UnsafeRawPointer?) -> Int32
        typealias Info = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
        typealias Send = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?) -> Int32
        typealias Receive = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?) -> Int32
        guard let easyInit = symbol("curl_easy_init", as: (@convention(c) () -> OpaquePointer?).self),
              let setLong = symbol("curl_easy_setopt", as: SetLong.self),
              let setPointer = symbol("curl_easy_setopt", as: SetPointer.self),
              let perform = symbol("curl_easy_perform", as: (@convention(c) (OpaquePointer?) -> Int32).self),
              let socket = symbol("curl_easy_getinfo", as: Info.self),
              let send = symbol("curl_easy_send", as: Send.self),
              let receive = symbol("curl_easy_recv", as: Receive.self),
              let cleanup = symbol("curl_easy_cleanup", as: (@convention(c) (OpaquePointer?) -> Void).self),
              let describe = symbol("curl_easy_strerror", as: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self)
        else { return nil }
        return LinuxCurl(easyInit: easyInit, setLong: setLong, setPointer: setPointer, perform: perform, socket: socket,
                         send: send, receive: receive, cleanup: cleanup, describe: describe)
    }()

    /// libcurl's own words for a failure: the error buffer's detail when it has one.
    func message(_ code: Int32, _ errors: UnsafeMutablePointer<CChar>) -> String {
        let detail = String(cString: errors)
        if !detail.isEmpty { return detail }
        return describe(code).map { String(cString: $0) } ?? "libcurl error \(code)"
    }
}
#endif
