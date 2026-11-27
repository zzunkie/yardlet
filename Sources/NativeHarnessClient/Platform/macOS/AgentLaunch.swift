import Darwin
import Foundation
import Security

/// How Yardlet starts an agent, a harness or a local MCP server it starts for one, so that macOS's privacy system (TCC)
/// asks for the agent's permissions in a name of its own rather than giving it Yardlet's: macOS holds the app that
/// started a process responsible for it and for everything it starts (README "Permissions"). The helper
/// `Yardlet Agents.app` in the bundle's Helpers does the starting (Sources/YardletAgentHost):
/// - A program whose own signature lets it ask, signed by a developer team with the Apple Events entitlement (Claude
///   Code), becomes responsible for itself and asks in its own name, as it does in its maker's app.
/// - Any other program runs under Yardlet Agents, which asks as "Yardlet Agents", with the entitlements and usage
///   descriptions agents need. The helper takes the program, its arguments, environment and folder from Yardlet over
///   `AgentHostLaunches`, never from its own command line.
///
/// The process Yardlet holds is the helper's: signals reach the program, and the program's exit is the process's. A
/// build without the helper (one run outside an app bundle) starts programs as before.
enum AgentLaunch {
    static let helperPath = "Contents/Helpers/Yardlet Agents.app/Contents/MacOS/Yardlet Agents"

    /// The helper in Yardlet's bundle; nil outside one.
    static let helper: URL? = {
        let helper = Bundle.main.bundleURL.appending(path: helperPath)
        return FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)) ? helper : nil
    }()

    /// Starts `process`'s program through `helper`. Without a helper, or with a program that cannot be run, the process
    /// starts as it is, so that starting it fails as it always has.
    static func run(_ process: Process, helper: URL?) throws {
        guard let helper, let program = process.executableURL,
              FileManager.default.isExecutableFile(atPath: program.path(percentEncoded: false)) else {
            try process.run()
            return
        }
        let path = program.path(percentEncoded: false)
        if asksInItsOwnName(program) {
            process.arguments = ["--own", path] + (process.arguments ?? [])
            process.executableURL = helper
            try process.run()
            return
        }
        let launch = try JSONEncoder().encode(AgentHostLaunches.Launch(
            executable: path, arguments: process.arguments ?? [],
            environment: process.environment ?? ProcessInfo.processInfo.environment,
            directory: (process.currentDirectoryURL ?? URL(filePath: FileManager.default.currentDirectoryPath))
                .path(percentEncoded: false)))
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw POSIXError(.EBADEXEC)
        }
        try AgentHostLaunches.shared.listen()
        // The helper itself needs neither: they are the program's, which the helper asks for.
        process.executableURL = helper
        process.arguments = ["--host"]
        process.environment = [:]
        process.currentDirectoryURL = URL(filePath: "/")
        try AgentHostLaunches.shared.start(launch, for: requirement) {
            try process.run()
            return process.processIdentifier
        }
    }

    /// Whether `program` is validly signed by a developer team with the Apple Events entitlement, so that under the
    /// hardened runtime it can ask for what agents ask for in its own name. A script asks in its interpreter's name, so
    /// it never is.
    static func asksInItsOwnName(_ program: URL) -> Bool {
        var code: SecStaticCode?
        var information: CFDictionary?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(program.resolvingSymlinksInPath() as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
                                            &information) == errSecSuccess,
              let information = information as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] is String,
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.automation.apple-events"] as? Bool == true
    }
}

/// Where the copies of Yardlet Agents that Yardlet starts ask what to run: a Unix socket in the user's temporary folder,
/// named for Yardlet's process. Yardlet answers each helper process it started once, with the launch it was started
/// for, and nothing else: a helper some other program started, or a process of Yardlet's running other code than the
/// helper's, gets no answer and runs nothing.
final class AgentHostLaunches: @unchecked Sendable {
    struct Launch: Codable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: String
    }

    static let shared = AgentHostLaunches()

    private let condition = NSCondition()
    /// The launches not yet asked for, by the helper's process, with the requirement the helper's code meets and when
    /// each was started.
    private var launches: [pid_t: (launch: Data, helper: SecRequirement, started: ContinuousClock.Instant)] = [:]
    /// Helpers being started, whose launch is not recorded yet.
    private var starting = 0
    private var listener: Int32 = -1
    /// How long a helper has to ask after it starts, and the longest an answer waits for its launch to be recorded.
    private let patience = Duration.seconds(10)

    /// The socket's path for the Yardlet process `process`; nil when macOS names no temporary folder for the user.
    static func socketPath(for process: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let folder = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(folder)Yardlet Agents \(process).socket"
    }

    /// Starts listening, once; throws when the socket cannot be made, which stops the launch.
    func listen() throws {
        condition.lock()
        defer { condition.unlock() }
        guard listener < 0 else { return }
        guard let path = Self.socketPath(for: getpid()) else { throw POSIXError(.ENOENT) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard descriptor >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            if descriptor >= 0 { close(descriptor) }
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 64) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        listener = descriptor
        let thread = Thread { [self] in accept(on: descriptor) }
        thread.name = "Yardlet Agents launches"
        thread.start()
        // Sockets of Yardlet processes that have ended.
        let folder = URL(filePath: path).deletingLastPathComponent()
        Task.detached(priority: .utility) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            where name.hasPrefix("Yardlet Agents ") && name.hasSuffix(".socket") {
                guard let process = pid_t(name.dropFirst("Yardlet Agents ".count).dropLast(".socket".count)),
                      process != getpid(), kill(process, 0) != 0, errno == ESRCH else { continue }
                unlink(folder.appending(path: name).path(percentEncoded: false))
            }
        }
    }

    /// Starts a helper with `start`, which returns its process, and records the launch it will ask for, given only to a
    /// process whose code meets `helper`.
    func start(_ launch: Data, for helper: SecRequirement, with start: () throws -> pid_t) throws {
        condition.lock()
        starting += 1
        condition.unlock()
        defer {
            condition.lock()
            starting -= 1
            condition.broadcast()
            condition.unlock()
        }
        let process = try start()
        condition.lock()
        let now = ContinuousClock.now
        launches = launches.filter { now - $0.value.started < patience }
        launches[process] = (launch, helper, now)
        condition.unlock()
    }

    private func accept(on listener: Int32) {
        while true {
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            DispatchQueue.global(qos: .userInitiated).async { [self] in answer(connection) }
        }
    }

    /// Answers a helper Yardlet started with its launch; anything else gets nothing.
    private func answer(_ connection: Int32) {
        defer { close(connection) }
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: Int(patience.components.seconds), tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var process: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        var info = proc_bsdinfo()
        // Yardlet's own child: a helper it started keeps its process and parent when it becomes its copy.
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &process, &length) == 0, process > 0,
              proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              pid_t(info.pbi_ppid) == getpid() else { return }
        // The helper can ask before `start` has recorded its launch.
        let deadline = Date.now.addingTimeInterval(TimeInterval(patience.components.seconds))
        condition.lock()
        while launches[process] == nil, starting > 0, condition.wait(until: deadline) {}
        let recorded = launches.removeValue(forKey: process)
        condition.unlock()
        guard let recorded, ContinuousClock.now - recorded.started < patience,
              runs(recorded.helper, connection) else { return }
        let launch = recorded.launch
        // The helper asks once it has checked who listens here; the connection stays open until then.
        var ask: UInt8 = 0
        guard read(connection, &ask, 1) == 1 else { return }
        launch.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(connection, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Whether the process on `connection` runs code that meets `requirement`, the helper's designated requirement.
    /// It is checked on the code the process runs, so a copy changed after the helper checked it gets nothing.
    private func runs(_ requirement: SecRequirement, _ connection: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary,
                                             [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
