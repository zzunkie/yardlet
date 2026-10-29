#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// The local endpoint between the Yardlet MCP server and the app: a Unix domain socket in a
// directory only the user can open (0700), carrying one framed call and its result per
// connection. This is the POSIX platform layer; a Windows build would use a named pipe with the
// same framing.

package enum UnixSocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case unsafeDirectory(String)
    case system(String, Int32)
    case unsupportedPlatform
    case closed

    package var description: String {
        switch self {
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .unsafeDirectory(let path): "The socket directory is not private to this user: \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code))) (\(code))"
        case .unsupportedPlatform: "Local tool connections are not supported on this platform yet"
        case .closed: "The connection closed early"
        }
    }

    /// True when nothing is listening: the app is not running, or runs without this endpoint.
    package var meansNothingIsListening: Bool {
        if case .system(let call, let code) = self, call == "connect" {
            return code == ENOENT || code == ECONNREFUSED
        }
        return false
    }

    /// True when the call went out and no answer came: the peer did not answer in time, or closed the
    /// connection first. The call may have run.
    package var meansTheCallWentUnanswered: Bool {
        switch self {
        case .closed: true
        case .system(let call, let code): call == "recv" && (code == EAGAIN || code == EWOULDBLOCK || code == ECONNRESET)
        default: false
        }
    }
}

#if canImport(Darwin) || canImport(Glibc)

package enum UnixDomainSocket {
    /// Creates `path` as a directory with mode 0700, or checks that an existing one is a
    /// directory the current user owns that no one else can open.
    package static func preparePrivateDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else { throw UnixSocketError.system("mkdir", code) }
        }
        var status = stat()
        guard lstat(path, &status) == 0 else { throw UnixSocketError.system("lstat", errno) }
        guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid() else {
            throw UnixSocketError.unsafeDirectory(path)
        }
        if (status.st_mode & 0o077) != 0, chmod(path, 0o700) != 0 {
            throw UnixSocketError.unsafeDirectory(path)
        }
    }

    /// Connects, sends one framed call, and reads one framed result.
    package static func exchange(path: String, request: Data, timeout: TimeInterval,
                                 maximumReplyLength: Int) throws -> Data {
        let descriptor = try connect(path: path, timeout: timeout)
        defer { close(descriptor) }
        try writeAll(descriptor, AgentToolFraming.frame(body: request))
        return try readFrame(descriptor, maximumLength: maximumReplyLength)
    }

    static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system("socket", errno) }
        configure(descriptor, timeout: timeout)
        var address = try socketAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw UnixSocketError.system("connect", code)
        }
        return descriptor
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        #if canImport(Darwin)
        // A peer that went away must surface as an error, not a SIGPIPE that ends the process.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = send(descriptor, pointer, remaining, sendFlags)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("send", errno)
                }
                remaining -= written
                pointer += written
            }
        }
    }

    static func readFrame(_ descriptor: Int32, maximumLength: Int) throws -> Data {
        let header = try readExactly(descriptor, count: 4)
        let length = AgentToolFraming.length(ofHeader: header)
        guard length <= maximumLength else { throw UnixSocketError.system("frame length", EMSGSIZE) }
        return try readExactly(descriptor, count: length)
    }

    static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress! + offset, count - offset, 0)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.system("recv", errno)
            }
            guard received > 0 else { throw UnixSocketError.closed }
            offset += received
        }
        return data
    }

    /// True when the peer runs as the current user. The private directory already keeps other
    /// users out; this is the second check.
    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0 else { return false }
        return user == getuid()
        #else
        return true
        #endif
    }

    /// The process ID of the peer as it connected, or nil when the system does not say. The app checks it
    /// against the processes it started for the task a call names.
    static func peerProcessID(_ descriptor: Int32) -> Int32? {
        #if canImport(Darwin)
        var processID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &processID, &length) == 0, processID > 0 else { return nil }
        return processID
        #else
        return nil  // SO_PEERCRED, when a Linux build checks its peers.
        #endif
    }

    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    static let sendFlags: Int32 = 0
    static func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.connect(fd, address, length)
    }
    static func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.bind(fd, address, length)
    }
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    static func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.connect(fd, address, length)
    }
    static func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.bind(fd, address, length)
    }
    #endif
}

/// Accepts connections on a socket in a private directory and answers each framed call with
/// the handler's framed result, given the peer's process ID. Connections from another user are
/// dropped unread.
package final class UnixSocketListener: @unchecked Sendable {
    package typealias Handler = @Sendable (Data, Int32?) async -> Data

    package let path: String
    private let descriptor: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var isStopped = false

    package init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        let directory = (path as NSString).deletingLastPathComponent
        try UnixDomainSocket.preparePrivateDirectory(directory)
        var address = try UnixDomainSocket.socketAddress(path)
        unlink(path)  // A socket left by an earlier run of this process ID.
        let descriptor = socket(AF_UNIX, UnixDomainSocket.streamType, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                UnixDomainSocket.systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw UnixSocketError.system("bind", code)
        }
        self.descriptor = descriptor
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "Yardlet agent tool listener"
        thread.start()
    }

    deinit { stop() }

    /// Stops accepting and removes the socket. Calls already accepted still finish.
    package func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        isStopped = true
        shutdown(descriptor, Int32(SHUT_RDWR))
        close(descriptor)
        unlink(path)
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func acceptLoop() {
        while !stopped {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard UnixDomainSocket.peerIsCurrentUser(client) else {
                close(client)
                continue
            }
            UnixDomainSocket.configure(client, timeout: 30)
            let peer = UnixDomainSocket.peerProcessID(client)
            let handler = handler
            DispatchQueue.global(qos: .userInitiated).async {
                guard let call = try? UnixDomainSocket.readFrame(client, maximumLength: AgentToolFraming.maximumCallLength) else {
                    close(client)
                    return
                }
                Task.detached {
                    let reply = await handler(call, peer)
                    try? UnixDomainSocket.writeAll(client, AgentToolFraming.frame(body: reply))
                    close(client)
                }
            }
        }
    }
}

#endif

/// The MCP server's side: forwards each call to the app named in the environment Yardlet gave
/// the server when it injected it into a harness session.
package struct UnixSocketToolInvoker: AgentToolInvoking {
    package let endpoint: String?
    package let token: String?
    package let session: String?
    /// The app run that started this server (`AgentToolEnvironment.appProcess`); nil from an earlier build.
    package let appProcess: Int32?
    /// Longer than any single browser tool and than a connector call (`AgentToolTimeLimits.connectorCall`),
    /// so the app's own time limits decide.
    package var timeout: TimeInterval = 180
    /// A session tool may wait for another task's turn or the person's approval, and a scheduled-task
    /// call from a scheduled run for the person's approval; the app answers
    /// before each caller harness's own limit on one call (at most 30 minutes), so this only
    /// catches an app that stopped answering.
    package var sessionToolTimeout: TimeInterval = 31 * 60

    package init(environment: [String: String]) {
        endpoint = environment[AgentToolEnvironment.endpoint].flatMap { $0.isEmpty ? nil : $0 }
        token = environment[AgentToolEnvironment.token].flatMap { $0.isEmpty ? nil : $0 }
        session = environment[AgentToolEnvironment.session].flatMap { $0.isEmpty ? nil : $0 }
        appProcess = environment[AgentToolEnvironment.appProcess].flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    package func call(tool: String, arguments: ToolJSON) async -> AgentToolResult {
        guard let endpoint, let token, let session else {
            return .failure("Yardlet did not start this MCP server, so it has no task to act on. "
                + "Yardlet's tools work in tasks that Yardlet starts.", .refused, retry: .no)
        }
        let call = AgentToolCall(token: token, session: session, tool: tool, arguments: arguments)
        guard let request = try? JSONEncoder().encode(call) else {
            return .error("The tool arguments could not be encoded.")
        }
        // A scheduled-task call from a scheduled run may wait for the person too, and a handed-over tab waits for them.
        let waits = SessionToolCatalog.definition(named: tool) != nil || ScheduleToolCatalog.definition(named: tool) != nil
            || tool == AgentToolCatalog.handoff
        let timeout = waits ? sessionToolTimeout : timeout
        let appProcess = appProcess
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.exchange(endpoint: endpoint, request: request, timeout: timeout,
                                                             appProcess: appProcess))
            }
        }
    }

    /// Asks the app for this task's tools. The app may read a connector's list from its server the
    /// first time, so this waits longer than a local answer needs; any failure leaves the list to
    /// the MCP server's own browser catalog.
    package func listTools() async -> AgentToolList? {
        guard let endpoint, let token, let session else { return nil }
        let request = AgentToolCall(token: token, session: session, tool: "", arguments: .object([:]),
                                    method: AgentToolCall.listMethod)
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        return await Self.exchange(endpoint: endpoint, body: body, timeout: 30)
            .flatMap { try? JSONDecoder().decode(AgentToolList.self, from: $0) }
    }

    /// Asks the app to wait until this task's list differs from `fingerprint`. The app answers
    /// within `AgentToolListWatching.hold`; this waits a little longer. A refusal (a token from
    /// an earlier run of the app) or no app at all is `unavailable`.
    package func waitForToolListChange(from fingerprint: String?) async -> AgentToolListWatch {
        guard let endpoint, let token, let session else { return .unavailable }
        let request = AgentToolCall(token: token, session: session, tool: "",
                                    arguments: .object(["fingerprint": fingerprint.map(ToolJSON.string) ?? .null]),
                                    method: AgentToolCall.watchMethod)
        guard let body = try? JSONEncoder().encode(request) else { return .unavailable }
        let timeout = TimeInterval(AgentToolListWatching.hold.components.seconds) + 30
        guard let reply = await Self.exchange(endpoint: endpoint, body: body, timeout: timeout),
              let answer = try? JSONDecoder().decode(AgentToolListWatchReply.self, from: reply)
        else { return .unavailable }
        return answer.changed ? .changed : .unchanged
    }

    /// One framed request and its reply off the caller's thread; nil on any failure.
    private static func exchange(endpoint: String, body: Data, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #if canImport(Darwin) || canImport(Glibc)
                continuation.resume(returning: try? UnixDomainSocket.exchange(
                    path: endpoint, request: body, timeout: timeout,
                    maximumReplyLength: AgentToolFraming.maximumResultLength
                ))
                #else
                continuation.resume(returning: nil)
                #endif
            }
        }
    }

    private static func exchange(endpoint: String, request: Data, timeout: TimeInterval,
                                 appProcess: Int32?) -> AgentToolResult {
        #if canImport(Darwin) || canImport(Glibc)
        do {
            let reply = try UnixDomainSocket.exchange(
                path: endpoint, request: request, timeout: timeout,
                maximumReplyLength: AgentToolFraming.maximumResultLength
            )
            guard let result = try? JSONDecoder().decode(AgentToolResult.self, from: reply) else {
                return .failure("Yardlet sent a reply this MCP server could not read, so whether the call took effect "
                    + "is unknown. Yardlet and yardlet-mcp may be from different builds.", .outcomeUnknown,
                    retry: .afterChecking)
            }
            return result
        } catch let error as UnixSocketError where error.meansNothingIsListening {
            return notListening(appProcess: appProcess)
        } catch let error as UnixSocketError where error.meansTheCallWentUnanswered {
            let what = error == .closed ? "Yardlet closed the connection before it answered"
                : "Yardlet did not answer within \(Int(timeout)) seconds"
            return .failure("\(what). The call may still have run there, so whether it took effect is unknown: check "
                + "before calling it again.", .outcomeUnknown, retry: .afterChecking)
        } catch {
            return .failure("Could not reach Yardlet: \(error)", .unreachable, retry: .later)
        }
        #else
        return .error(UnixSocketError.unsupportedPlatform.description)
        #endif
    }

    /// Nothing answers at the endpoint: the app run that started this server ended (Yardlet quit, or quit and
    /// opened again), or it runs and its endpoint went (the system clears old files from the temporary folder
    /// it is in), which the next task Yardlet starts or resumes sets up again. A server from an earlier build
    /// does not know its app run.
    private static func notListening(appProcess: Int32?) -> AgentToolResult {
        let tools = "its browser, task suggestion and connector tools are unavailable"
        guard let appProcess else {
            return .failure("Yardlet is not running, or this task's connection to it is gone, so \(tools). Open Yardlet "
                + "and resume this task to use them.", .unreachable, retry: .no)
        }
        #if canImport(Darwin) || canImport(Glibc)
        let running = kill(appProcess, 0) == 0 || errno == EPERM
        #else
        let running = false
        #endif
        guard running else {
            return .failure("The Yardlet that started this task's tools has quit, so \(tools). Open Yardlet and "
                + "resume this task to use them.", .unreachable, retry: .no)
        }
        return .failure("Yardlet is running, but this task's connection to it is gone, so \(tools) for now. Starting "
            + "or resuming a task in Yardlet connects them again.", .unreachable, retry: .no)
    }
}
