import CryptoKit
import Darwin
import Foundation
import IOSurface
import YardletSimulatorHostProtocol
import YardletSurfacePort

/// macOS transport for the simulator host: the helper runs as `Yardlet.app/Contents/Helpers/Yardlet Simulator Host.app`,
/// commands go to its standard input and events come back on its standard output (length-prefixed JSON), and frames
/// arrive as IOSurfaces over a Mach port checked in under a per-launch bootstrap name. Frames go from the pipe's queue
/// straight to the layers of the panels that show their device (`SimulatorFrameRouter`); the main thread gets every
/// other event.
///
/// The helper starts responsible for itself (`DisclaimedSpawn`): it holds none of the screen recording, accessibility
/// or automation permissions the person gave Yardlet, and needs none.
final class SimulatorHostProcess: @unchecked Sendable {
    static var bundledExecutable: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Helpers/Yardlet Simulator Host.app/Contents/MacOS/Yardlet Simulator Host")
    }

    let processIdentifier: Int32
    let frameRouter = SimulatorFrameRouter()
    /// Surface messages refused because they came from another process or carried a wrong token.
    var rejectedSurfaceMessages: Int { surfaces.rejectedMessages }

    private let input: FileHandle
    /// Commands are written here, off the caller's thread: a helper that stopped reading fills the pipe, and a full
    /// pipe must not hold up the main thread.
    private let writer = DispatchQueue(label: "Yardlet simulator host commands", qos: .userInteractive)
    private let output: FileHandle
    private let surfaces: SimulatorSurfaceReceiver
    private let exitSource: DispatchSourceProcess
    private let lock = NSLock()
    private var ended = false

    /// Starts the helper for the Xcode at `developerDirectory`. `events` gets every event but frames on the main
    /// thread, in order; `exited` gets the helper's end once, on the main thread, after its last event. Both name the
    /// helper's process, so a client that started another one since can tell them apart.
    init(executable: URL, developerDirectory: URL, log: URL?, idleExit: Duration? = nil,
         events: @escaping @MainActor (_ processID: Int32, _ events: [SimulatorHostEvent]) -> Void,
         exited: @escaping @MainActor (_ processID: Int32, _ reason: String) -> Void) throws {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<Int(YardletSurfaceTokenLength)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let portName = "\(Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier).simulator-host.\(getpid()).\(nonce)"
        var port: mach_port_t = 0
        let checkIn = yardlet_surface_port_check_in(portName, &port)
        guard checkIn == KERN_SUCCESS else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Mach bootstrap check-in failed (\(checkIn))"])
        }
        let surfaces = SimulatorSurfaceReceiver(port: port, token: token)
        self.surfaces = surfaces

        var arguments = ["--developer-dir", developerDirectory.path(percentEncoded: false)]
        if let idleExit {
            let (seconds, attoseconds) = idleExit.components
            arguments += ["--idle-exit", String(Double(seconds) + Double(attoseconds) / 1e18)]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["YARDLET_SIMULATOR_HOST_PORT"] = portName
        environment["YARDLET_SIMULATOR_HOST_TOKEN"] = token.map { String(format: "%02x", $0) }.joined()
        // Simulators belong to the person's account, wherever Yardlet keeps its own files (a QA run's home): CoreSimulator
        // finds the device set from the home folder.
        environment["CFFIXED_USER_HOME"] = nil
        if let home = getpwuid(getuid())?.pointee.pw_dir { environment["HOME"] = String(cString: home) }

        // A helper that died must surface as an error, not a SIGPIPE that ends Yardlet; the end of its commands,
        // Yardlet going away, ends the helper.
        let commands = Pipe.childInput()
        let eventPipe = Pipe()
        let logHandle = log.flatMap(Self.logHandle(at:))
        let child: pid_t
        do {
            child = try DisclaimedSpawn.run(
                executable: try DisclaimedSpawn.runnable(executable), arguments: arguments, environment: environment,
                standardInput: commands.fileHandleForReading.fileDescriptor,
                standardOutput: eventPipe.fileHandleForWriting.fileDescriptor,
                standardError: logHandle?.fileDescriptor)
        } catch {
            surfaces.close()
            throw error
        }
        try? commands.fileHandleForReading.close()
        try? eventPipe.fileHandleForWriting.close()
        try? logHandle?.close()
        processIdentifier = child
        surfaces.setHostProcessID(child)
        input = commands.fileHandleForWriting
        output = eventPipe.fileHandleForReading

        // Framing and decoding run on the pipe's own queue, and so do frames: each frame's surface is taken off the
        // Mach port and put into the layers of its device's displays right there.
        let router = frameRouter
        let decoder = EventDecoder()
        let end = EndOfHelper { reason in DispatchQueue.main.async { MainActor.assumeIsolated { exited(child, reason) } } }
        output.readChunks({ data in
            guard let decoded = try? decoder.decode(data) else { return }
            var forMain: [SimulatorHostEvent] = []
            for event in decoded {
                switch event {
                case .frame(let frame):
                    if let surface = surfaces.surface(for: frame) { router.route(frame, surface: surface) }
                    continue
                case .detached(let device, _), .deviceFailed(let device, _):
                    surfaces.forget(device: device)
                    router.forgetLatestFrame(of: device)
                default:
                    break
                }
                forMain.append(event)
            }
            guard !forMain.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { events(child, forMain) } }
        }, atEnd: { end.outputEnded() })

        exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self?.exitSource.cancel()
            self?.markEnded()
            end.exited((status & 0x7f) == 0 ? "exit status \((status >> 8) & 0xff)" : "signal \(status & 0x7f)")
        }
        exitSource.resume()
    }

    var isRunning: Bool { lock.withLock { !ended } }

    func send(_ command: SimulatorHostCommand) {
        guard isRunning, let data = try? SimulatorHostFraming.frame(command) else { return }
        writer.async { [self] in
            do {
                try input.write(contentsOf: data)
            } catch {
                terminate()
            }
        }
    }

    /// Ends the helper with SIGTERM, which it takes as the end, as it does the end of its input.
    func terminate() {
        guard isRunning else { return }
        kill(processIdentifier, SIGTERM)
    }

    private func markEnded() {
        lock.withLock { ended = true }
        frameRouter.removeAll()
        surfaces.close()
        writer.async { [input] in try? input.close() }
    }

    private static func logHandle(at url: URL) -> FileHandle? {
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000 {
            try? fileManager.removeItem(atPath: path)
        }
        if !fileManager.fileExists(atPath: path) { fileManager.createFile(atPath: path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// Reports the helper's end once it has exited and its last events have been read, whichever comes last.
    private final class EndOfHelper: @unchecked Sendable {
        private let lock = NSLock()
        private var outputDone = false
        private var reason: String?
        private let report: @Sendable (String) -> Void

        init(report: @escaping @Sendable (String) -> Void) {
            self.report = report
        }

        func outputEnded() {
            let reason: String? = lock.withLock {
                outputDone = true
                return self.reason
            }
            if let reason { report(reason) }
        }

        func exited(_ reason: String) {
            let done = lock.withLock {
                self.reason = reason
                return outputDone
            }
            if done { report(reason) }
        }
    }

    /// Used only on the event pipe's queue, which runs one handler at a time.
    private final class EventDecoder: @unchecked Sendable {
        private var reader = SimulatorHostFraming.Reader()
        private let decoder = JSONDecoder()

        func decode(_ data: Data) throws -> [SimulatorHostEvent] {
            try reader.append(data).compactMap { try? decoder.decode(SimulatorHostEvent.self, from: $0) }
        }
    }
}

/// Starts a process that is responsible for itself in macOS's privacy system (TCC): it inherits none of the
/// permissions the person gave Yardlet, and asks for any it needs in its own name. The helper asks for none.
/// `responsibility_spawnattrs_setdisclaim` is libSystem's, unexported in its headers; without it the process starts
/// as Yardlet's responsibility, as any other child does.
enum DisclaimedSpawn {
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }

    /// Whether processes start disclaimed on this macOS.
    static var isAvailable: Bool { disclaim != nil }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    /// The process macOS holds responsible for `process` in its privacy system: the process itself when it started
    /// disclaimed.
    static func responsibleProcess(for process: pid_t) -> pid_t? {
        responsible.map { $0(process) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The executable to start for `executable`. A process responsible for itself needs the person's permission to
    /// read inside the Desktop, Documents and Downloads folders, iCloud Drive and other volumes, its own executable
    /// included, and macOS would ask for it as the process starts: an executable there (a development build, or Yardlet
    /// itself kept in Downloads) starts from a copy in the temporary folder instead, its whole app bundle copied, made
    /// again when the original changes.
    static func runnable(_ executable: URL, fileManager: FileManager = .default) throws -> URL {
        let resolved = executable.resolvingSymlinksInPath()
        let path = resolved.path(percentEncoded: false)
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(home)/\($0)/" } + ["/Volumes/"]
        guard protected.contains(where: { path.hasPrefix($0) }) else { return executable }
        let components = resolved.pathComponents
        let bundleEnd = (components.lastIndex { $0.hasSuffix(".app") } ?? components.count - 1) + 1
        let source = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<bundleEnd])))
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let folder = fileManager.temporaryDirectory.appending(path: "Yardlet Simulator Host \(digest)", directoryHint: .isDirectory)
        let copy = folder.appending(path: source.lastPathComponent)
        let copiedExecutable = components[bundleEnd...].reduce(copy) { $0.appending(path: $1) }
        let stampFile = folder.appending(path: "source")
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let stamp = "\((attributes[.size] as? Int) ?? 0) \((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if (try? String(contentsOf: stampFile, encoding: .utf8)) != stamp
            || !fileManager.isExecutableFile(atPath: copiedExecutable.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: copy)
            try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        }
        return copiedExecutable
    }

    static func run(executable: URL, arguments: [String], environment: [String: String],
                    standardInput: Int32, standardOutput: Int32, standardError: Int32?) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        // Only the three standard descriptors go to the helper, with default signal handling and none blocked.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        guard let disclaim, disclaim(&attributes, 1) == 0 else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "this macOS cannot start a process responsible for itself"])
        }
        posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO)
        if let standardError {
            posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        let path = executable.path(percentEncoded: false)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return child
    }
}
