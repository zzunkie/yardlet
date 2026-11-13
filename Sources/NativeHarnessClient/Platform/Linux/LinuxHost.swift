import Dispatch
import Foundation
import Glibc
import YardletAgentTools
import YardletRemote

/// The running host, `yardlet host start` (docs/LINUX_HOST.md): the engine's model with the computer's tasks, the
/// remote serving them to paired devices, always on while the host runs, and the control socket the other commands
/// reach. It runs in the foreground until it is stopped (SIGTERM from systemd, Control-C in a terminal, SIGHUP when the
/// terminal closes), and then ends as the Mac app quits: what the stop cuts off is written down for the next start,
/// the remote's connections close and the harnesses end with what they started.
@MainActor
final class LinuxHost {
    let model: AppModel
    let remote: RemoteControlService
    let name: String
    private var control: UnixSocketListener?
    private var signalSources: [any DispatchSourceSignal] = []
    private var isStopping = false

    private init(name: String) {
        self.name = name
        model = AppModel.live()
        remote = RemoteControlService.live(model: model, name: name)
        model.remoteControl = remote
    }

    /// Starts the host and runs it until it is stopped; never returns.
    static func run(name: String?) -> Never {
        // A write to a harness or a device that has gone must fail as an error, not end the host.
        _ = signal(SIGPIPE, SIG_IGN)
        let lock: HostLock
        do {
            lock = try HostLock.acquire()
        } catch {
            HostOutput.error("\(error)")
            exit(1)
        }
        let host = LinuxHost(name: name ?? LinuxHostName.current)
        host.watchSignals()
        Task { await host.start(lock: lock) }
        // The engine's timers run on the main run loop, which also runs the main actor's work here; a timer that never
        // fires keeps the loop from returning while nothing else is scheduled.
        RunLoop.main.add(Timer(timeInterval: 86_400, repeats: true) { _ in }, forMode: .default)
        while true { RunLoop.main.run() }
    }

    private func start(lock: HostLock) async {
        if let problem = model.bootstrapError { HostOutput.error(problem) }
        let newestRuntimes = Task { await model.runtimeSelections.findNewest() }
        await model.restoreIndex()
        if model.hasRestoredIndex {
            // What the last stop cut off continues alongside the rest of the start.
            Task {
                await newestRuntimes.value
                await model.continueWorkInterruptedByRestart()
            }
            // Scheduled tasks run while the host runs; one missed meanwhile runs once now.
            Task {
                await newestRuntimes.value
                model.startScheduledTasks()
            }
        }
        await remote.start()
        // The host exists to be reached: its remote is on while it runs.
        remote.setEnabled(true)
        do {
            control = try UnixSocketListener(path: LinuxHostPaths.controlSocket()) { [self] call, _ in
                await answer(call)
            }
        } catch {
            HostOutput.error("The control socket could not open, so `yardlet host status` and `pair` cannot reach this host: \(error)")
        }
        await newestRuntimes.value
        HostOutput.line("Yardlet host \(LinuxHostVersion.current) is running as \(name) (process \(getpid())).")
        HostOutput.line("Data: \(LinuxHostPaths.dataRootLocation().path(percentEncoded: false))")
        let found = model.runtimeSelections.connectedDescriptors.map(\.displayName)
        HostOutput.line("Harnesses: \(found.isEmpty ? "none found on the PATH" : found.joined(separator: ", "))")
        if let reason = remote.relayUnavailableReason { HostOutput.line("Relay: off, since \(reason).") }
        HostOutput.line("Pair a device with `yardlet host pair`.")
        _ = lock
    }

    private func watchSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stop() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func stop() {
        guard !isStopping else { return }
        isStopping = true
        HostOutput.line("Stopping…")
        // A stop that does not finish in time still ends; systemd would end the unit's processes after 90 s anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { exit(1) }
        Task {
            // Before anything stops: which turns this stop cuts off, for the next start to continue.
            model.recordWorkForRestart(trigger: .quit)
            control?.stop()
            await remote.shutdown()
            await model.shutdown()
            exit(0)
        }
    }

    // MARK: - Control

    private func answer(_ call: Data) async -> Data {
        let reply: HostControlReply
        if let request = try? JSONDecoder.hostControl.decode(HostControlRequest.self, from: call) {
            reply = await answer(request)
        } else {
            reply = .failure("The request could not be read.")
        }
        return (try? JSONEncoder.hostControl.encode(reply)) ?? Data()
    }

    private func answer(_ request: HostControlRequest) async -> HostControlReply {
        switch request.command {
        case .status:
            return HostControlReply(status: status())
        case .pair:
            await remote.startPairing()
            let reach = remote.reach
            let relayUp = reach.relay == .connected || reach.relay == .connecting
            guard reach.direct || relayUp, let pairing = currentPairing, pairing.link != nil else {
                remote.cancelPairing()
                return .failure(reach.directFailure.map { "The remote cannot pair yet: \($0)" }
                    ?? "The remote cannot pair yet: neither a direct path nor the relay is ready.")
            }
            return HostControlReply(pairing: pairing)
        case .cancelPairing:
            remote.cancelPairing()
            return HostControlReply()
        case .addProject:
            guard let path = request.path, path.hasPrefix("/") else { return .failure("Give the project's folder.") }
            let folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else { return .failure("\(path) is not a folder.") }
            model.projects.ensureProject(forRoot: folder)
            model.projects.persistNow()
            return HostControlReply(projects: projects())
        case .projects:
            return HostControlReply(projects: projects())
        }
    }

    private var currentPairing: HostStatus.Pairing? {
        guard remote.pairing != nil || remote.pairedDeviceName != nil else { return nil }
        return HostStatus.Pairing(link: remote.pairing?.url?.absoluteString, expiresAt: remote.pairing?.expiresAt,
                                  pairedDevice: remote.pairedDeviceName)
    }

    private func projects() -> [HostStatus.Project] {
        model.projects.projects.filter { !$0.isHidden }.map {
            HostStatus.Project(name: $0.name, folder: $0.primaryRoot.path(percentEncoded: false))
        }
    }

    private func status() -> HostStatus {
        let reach = remote.reach
        let direct: String
        var port: UInt16?
        switch remote.secureState {
        case .stopped: direct = "stopped"
        case .starting: direct = "starting"
        case let .ready(ready):
            direct = "ready"
            port = ready
        case .failed: direct = "failed"
        }
        var relay: String?
        var relayFailure: String?
        switch reach.relay {
        case nil: relay = nil
        case .off?: relay = "off"
        case .connecting?: relay = "connecting"
        case .connected?: relay = "connected"
        case let .failed(message)?:
            relay = "failed"
            relayFailure = message
        }
        let devices = remote.devices.map { device in
            HostStatus.Device(name: device.name, platform: device.platform,
                              connected: remote.connectedDeviceIDs.contains(device.id),
                              path: remote.connectedPaths[device.id]?.rawValue, lastSeenAt: device.lastSeenAt)
        }
        let harnesses = HarnessCatalog.builtIns.map { descriptor in
            HostStatus.Harness(id: descriptor.id.rawValue, name: descriptor.displayName,
                               runtime: model.runtimeSelections.selectedURL(for: descriptor.id)?.path(percentEncoded: false))
        }
        return HostStatus(
            version: LinuxHostVersion.current, processID: getpid(), name: name,
            dataFolder: LinuxHostPaths.dataRootLocation().path(percentEncoded: false),
            remote: HostStatus.Remote(enabled: remote.isEnabled, direct: direct, port: port, directFailure: reach.directFailure,
                                      addresses: remote.directHosts, relay: relay, relayFailure: relayFailure,
                                      relayUnavailable: remote.relayUnavailableReason),
            devices: devices, harnesses: harnesses, projects: projects(),
            tasks: model.store.sessions.count, runningTasks: model.activeLocalSessions.count,
            pairing: currentPairing)
    }
}

/// The lock a running host holds on `host.lock` in its data folder, with its process ID in the file, so a second host
/// for the same person does not start beside it. The lock ends with the process.
struct HostLock {
    enum Failure: Error, CustomStringConvertible {
        case running(Int32?)
        case failed(String)

        var description: String {
            switch self {
            case let .running(pid?): "A Yardlet host is already running for this account (process \(pid))."
            case .running(nil): "A Yardlet host is already running for this account."
            case let .failed(message): message
            }
        }
    }

    let descriptor: Int32

    static func acquire() throws -> HostLock {
        do { _ = try LinuxHostPaths.dataRoot() } catch {
            throw Failure.failed("The data folder could not be made: \(error)")
        }
        let path = LinuxHostPaths.lockFile()
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.failed("\(path) could not be opened: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = holderProcessID(descriptor)
            close(descriptor)
            throw Failure.running(holder)
        }
        let text = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = text.withCString { write(descriptor, $0, strlen($0)) }
        return HostLock(descriptor: descriptor)
    }

    /// The process holding the lock, from the file it wrote; nil when no host holds it or the file says nothing.
    static func runningProcessID() -> Int32? {
        let descriptor = open(LinuxHostPaths.lockFile(), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // A shared lock taken at once means no host holds it.
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return nil
        }
        return holderProcessID(descriptor)
    }

    private static func holderProcessID(_ descriptor: Int32) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return nil }
        return Int32(String(decoding: bytes[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The host's own lines: to standard output, which the systemd journal keeps, and its problems to standard error.
enum HostOutput {
    static func line(_ text: String) {
        print(text)
        fflush(stdout)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
