import Darwin
import Foundation
import Security

// Yardlet Agents: how Yardlet starts the agents it runs (harnesses, and the MCP servers it starts for them), so that
// macOS's privacy system (TCC) asks for their permissions in a name of their own instead of giving them Yardlet's.
// macOS holds the app that started a process responsible for it, so without this every agent would use what the
// person allowed Yardlet itself (README "Permissions").
//
//   Yardlet Agents --own <program> [arguments…]
//       The program becomes responsible for itself, in this same process: it asks in its own name, as a program whose
//       own signature lets it ask does (Claude Code), and as it does in its maker's app.
//   Yardlet Agents --host
//       A copy of this helper, responsible for itself, takes over this process, asks Yardlet what to run, and runs it as
//       its child. macOS holds the copy responsible for the program and what it runs, so they ask as "Yardlet Agents",
//       with the entitlements and usage descriptions this bundle carries. Signals go on to the program, and its exit
//       becomes this process's.
//
// The copy lives outside Yardlet's bundle, in the user's cache folder, where macOS lists it as an app of its own. It
// runs nothing it was not given by Yardlet itself, over a socket Yardlet listens on (AgentHostLaunches): Yardlet
// answers only for a helper process it started, and a copy signed by a team answers only to Yardlet signed by the same
// team. So no other program can run a command with what the person allowed "Yardlet Agents".

/// The exit status of a command that could not be started, as a shell reports it.
let cannotRun: Int32 = 126

func fail(_ message: String) -> Never {
    fputs("Yardlet Agents: \(message)\n", stderr)
    exit(cannotRun)
}

// `responsibility_spawnattrs_setdisclaim` and `responsibility_get_pid_responsible_for_pid` are libSystem's, unexported
// in its headers; macOS has had both since 10.14.
let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
typealias Responsible = @convention(c) (pid_t) -> pid_t
let disclaim = dlsym(defaultHandle, "responsibility_spawnattrs_setdisclaim").map { unsafeBitCast($0, to: Disclaim.self) }
let responsible = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: Responsible.self) }

/// Starts `path`, or, with `replacing`, becomes it in this same process. `disclaimed` makes it responsible for itself.
/// Only the three standard descriptors go on, with default signal handling and none blocked; `environment` (this
/// process's when nil) and `directory` are the program's.
func spawn(_ path: String, _ arguments: [String], environment: [String: String]? = nil, directory: String? = nil,
           replacing: Bool, disclaimed: Bool) -> pid_t {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    posix_spawnattr_init(&attributes)
    posix_spawn_file_actions_init(&actions)
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    if replacing { flags |= POSIX_SPAWN_SETEXEC }
    posix_spawnattr_setflags(&attributes, Int16(flags))
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attributes, &none)
    var all = sigset_t()
    sigfillset(&all)
    posix_spawnattr_setsigdefault(&attributes, &all)
    if disclaimed {
        guard let disclaim, disclaim(&attributes, 1) == 0 else {
            fail("this macOS cannot start a process responsible for itself")
        }
    }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        posix_spawn_file_actions_addinherit_np(&actions, descriptor)
    }
    if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { $0.map { strdup("\($0.key)=\($0.value)") } + [nil] }
    var child: pid_t = 0
    let status = if let envp {
        posix_spawn(&child, path, &actions, &attributes, argv, envp)
    } else {
        posix_spawn(&child, path, &actions, &attributes, argv, environ)
    }
    // Reached only when the process was not replaced.
    argv.forEach { free($0) }
    envp?.forEach { free($0) }
    posix_spawnattr_destroy(&attributes)
    posix_spawn_file_actions_destroy(&actions)
    guard status == 0 else { fail("cannot run \(path): \(String(cString: strerror(status)))") }
    return child
}

func ownStaticCode() -> SecStaticCode {
    var code: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { fail("cannot read its own signature") }
    return staticCode
}

/// This helper's signing: its identifier and team; no team for a build no team signed.
func ownSigning() -> (identifier: String, team: String?) {
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(ownStaticCode(), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let information = information as? [String: Any],
          let identifier = information[kSecCodeInfoIdentifier as String] as? String else { fail("cannot read its own signature") }
    return (identifier, information[kSecCodeInfoTeamIdentifier as String] as? String)
}

/// The helper's identifier is the app's with this suffix (scripts/build-app.sh).
let identifierSuffix = ".agents"

func path(of buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// A folder of this user's that macOS names with `confstr`, ending in a slash.
func userFolder(_ name: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard confstr(name, &buffer, buffer.count) > 0 else { fail("cannot find the user's folders") }
    return path(of: buffer)
}

func ownExecutable() -> URL {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { fail("cannot find its own executable") }
    return URL(filePath: path(of: buffer))
}

/// The bundle an executable is in (`<bundle>/Contents/MacOS/<executable>`), and how many app bundles hold it.
func bundle(of executable: URL) -> (url: URL, depth: Int) {
    let url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (url, executable.pathComponents.filter { $0.hasSuffix(".app") }.count)
}

func hash(_ text: String) -> String {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return String(value, radix: 16)
}

/// A copy of this helper's bundle, or of its executable when it is in none (a test's), in the user's cache folder,
/// outside Yardlet's bundle and the folders macOS protects, checked against this helper's own signature. It is made
/// once for each build of the helper at each place, under a lock, so agents starting together share it; a new build
/// replaces the copy the same place made before.
func copyOutsideTheApp() -> URL {
    let executable = ownExecutable()
    let inBundle = bundle(of: executable).depth > 0
    let source = inBundle ? bundle(of: executable).url : executable
    var status = stat()
    guard stat(executable.path(percentEncoded: false), &status) == 0 else { fail("cannot read its own executable") }
    let place = hash(source.path(percentEncoded: false))
    let build = hash("\(status.st_size)|\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)")
    let copies = URL(filePath: userFolder(_CS_DARWIN_USER_CACHE_DIR), directoryHint: .isDirectory)
        .appending(path: "Yardlet Agents", directoryHint: .isDirectory)
    let folder = copies.appending(path: "\(place)-\(build)", directoryHint: .isDirectory)
    let copy = folder.appending(path: source.lastPathComponent, directoryHint: inBundle ? .isDirectory : .notDirectory)
    let copiedExecutable = inBundle ? copy.appending(path: "Contents/MacOS").appending(path: executable.lastPathComponent) : copy

    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(ownStaticCode(), [], &requirement) == errSecSuccess, let requirement else {
        fail("cannot read its own signature")
    }
    func isValid() -> Bool {
        var attributes = stat()
        // The copy itself, not a link to elsewhere.
        guard lstat(folder.path(percentEncoded: false), &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
    let files = FileManager.default
    do {
        try files.createDirectory(at: copies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
        fail("cannot make \(copies.path(percentEncoded: false)): \(error.localizedDescription)")
    }
    let lock = open(copies.appending(path: "\(place).lock").path(percentEncoded: false), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { fail("cannot lock its copy") }
    defer { close(lock) }
    if isValid() { return copiedExecutable }
    let staging = copies.appending(path: ".\(place)-\(build).\(getpid())", directoryHint: .isDirectory)
    try? files.removeItem(at: staging)
    try? files.removeItem(at: folder)
    do {
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        try files.copyItem(at: source, to: staging.appending(path: source.lastPathComponent))
        try files.moveItem(at: staging, to: folder)
    } catch {
        try? files.removeItem(at: staging)
        fail("cannot copy itself to \(folder.path(percentEncoded: false)): \(error.localizedDescription)")
    }
    guard isValid() else { fail("its copy in \(folder.path(percentEncoded: false)) does not match its signature") }
    // Earlier builds' copies from the same place.
    for name in (try? files.contentsOfDirectory(atPath: copies.path(percentEncoded: false))) ?? []
    where name.hasPrefix("\(place)-") && name != folder.lastPathComponent {
        try? files.removeItem(at: copies.appending(path: name))
    }
    return copiedExecutable
}

/// What Yardlet gives the copy to run (AgentHostLaunches).
struct Launch: Decodable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var directory: String
}

/// Asks the Yardlet that started this process what to run, over the socket it listens on, named for its process.
func launchFromYardlet() -> Launch {
    let socketPath = "\(userFolder(_CS_DARWIN_USER_TEMP_DIR))Yardlet Agents \(getppid()).socket"
    let connection = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard connection >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("only Yardlet starts agents this way") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { fail("only Yardlet starts agents this way") }
    // A Yardlet that does not answer closes the connection: an error to report, not a signal that ends this process.
    var on: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // Signed by a team, the copy takes its program only from Yardlet signed by the same team. A build no team signed
    // holds its permissions under its identifier alone, which any program can be signed with, so it checks nothing.
    let signing = ownSigning()
    if let team = signing.team {
        guard signing.identifier.hasSuffix(identifierSuffix) else { fail("unexpected identifier \(signing.identifier)") }
        let app = String(signing.identifier.dropLast(identifierSuffix.count))
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(app)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary,
                                             [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { fail("only Yardlet starts agents this way") }
    }
    // Yardlet answers once asked, which keeps the connection open while the copy checks who listens.
    var ask: UInt8 = 1
    guard write(connection, &ask, 1) == 1 else { fail("only Yardlet starts agents this way") }
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(connection, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        answer.append(contentsOf: buffer[..<count])
        guard answer.count <= 16 << 20 else { fail("Yardlet's answer is too long") }
    }
    close(connection)
    guard let launch = try? JSONDecoder().decode(Launch.self, from: answer), launch.executable.hasPrefix("/") else {
        fail("only Yardlet starts agents this way")
    }
    return launch
}

/// The program's process, for the signal handlers.
nonisolated(unsafe) var program: pid_t = 0
let forwarded = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2]

/// Runs the program as this process's child until it ends, then ends the same way.
func host(_ launch: Launch) -> Never {
    // Held until the handlers are in place, so a signal that comes before the program starts still reaches it.
    var blocked = sigset_t()
    sigemptyset(&blocked)
    forwarded.forEach { sigaddset(&blocked, $0) }
    sigprocmask(SIG_BLOCK, &blocked, nil)
    program = spawn(launch.executable, launch.arguments, environment: launch.environment, directory: launch.directory,
                    replacing: false, disclaimed: false)
    for signalNumber in forwarded {
        signal(signalNumber) { _ = kill(program, $0) }
    }
    sigprocmask(SIG_UNBLOCK, &blocked, nil)
    // The program has the pipes; Yardlet sees them end with it, not with this process.
    let null = open("/dev/null", O_RDWR)
    dup2(null, STDIN_FILENO)
    dup2(null, STDOUT_FILENO)
    var status: Int32 = 0
    while waitpid(program, &status, 0) == -1 {
        guard errno == EINTR else { fail("lost the program: \(String(cString: strerror(errno)))") }
    }
    // Its process ID may name another process now.
    sigprocmask(SIG_BLOCK, &blocked, nil)
    let ended = status & 0x7f
    guard ended != 0 else { exit((status >> 8) & 0xff) }
    // Ended by a signal: end by the same one, so Yardlet reads the program's end. A crash's signal becomes a status
    // instead, which leaves the crash report to the program that crashed.
    guard [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGKILL, SIGPIPE, SIGUSR1, SIGUSR2, SIGALRM].contains(ended) else {
        exit(128 + ended)
    }
    signal(ended, SIG_DFL)
    var unblocked = sigset_t()
    sigemptyset(&unblocked)
    sigaddset(&unblocked, ended)
    sigprocmask(SIG_UNBLOCK, &unblocked, nil)
    kill(getpid(), ended)
    exit(128 + ended)
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "--own" where arguments.count >= 3 && arguments[2].hasPrefix("/"):
    _ = spawn(arguments[2], Array(arguments.dropFirst(3)), replacing: true, disclaimed: true)
case "--host":
    // The copy, responsible for itself, takes over this process.
    _ = spawn(copyOutsideTheApp().path(percentEncoded: false), ["--hosting"], replacing: true, disclaimed: true)
case "--hosting":
    // Anything can start this step, and start it responsible for itself: it runs only as the copy, and only what
    // Yardlet gives it.
    guard responsible.map({ $0(getpid()) == getpid() }) == true else { fail("not responsible for itself") }
    guard bundle(of: ownExecutable()).depth <= 1 else { fail("runs only as its copy") }
    host(launchFromYardlet())
default:
    fail("usage: --own <program path> [arguments…] | --host")
}
fail("cannot replace itself")
