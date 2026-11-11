import Foundation
import YardletLidSleep

// yardlet-lid-helper: Yardlet's launch daemon for Settings › General › "Keep tasks working with the
// lid closed" (docs/SLEEP_PREVENTION.md). It runs as root only while that setting is
// on (`SMAppService.daemon`), starts when Yardlet connects and once at startup, keeps the Mac awake
// with the lid closed only while a connected Yardlet says its tasks are working, and exits when it has
// nothing to do.

/// The app bundle this executable sits in (`<app>/Contents/Helpers/yardlet-lid-helper`).
let executable = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let appBundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard let appIdentifier = Bundle(url: appBundle)?.bundleIdentifier else {
    FileHandle.standardError.write(Data("yardlet-lid-helper: not inside a Yardlet bundle\n".utf8))
    exit(1)
}

@MainActor final class LidHelper: NSObject, NSXPCListenerDelegate {
    private let guardian = LidSleepGuard(setting: SystemSleepDisabledSetting(), record: SleepDisabledRecordFile(),
                                         conditions: PowerConditions.current)
    private let listener: NSXPCListener
    private var nextClient = 0
    private var clients: Set<LidSleepGuard.Client> = []
    private var powerCheck: DispatchSourceTimer?
    private var idleExit: DispatchWorkItem?
    private var termination: DispatchSourceSignal?
    private var thermalObserver: NSObjectProtocol?

    init(appIdentifier: String, requirement: String) {
        listener = NSXPCListener(machServiceName: LidSleepHelperIdentity.label(appIdentifier: appIdentifier))
        super.init()
        // Only Yardlet itself, signed by the team that signed this helper, may connect.
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
    }

    func run() {
        // Unregistering the helper or shutting down ends it with SIGTERM: the setting goes back first.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.guardian.stop() }
            exit(0)
        }
        termination.resume()
        self.termination = termination
        // A critical heat lets go at once, not at the next minute's check.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardian.powerChanged() }
        }
        guardian.start()
        listener.resume()
        changed()
    }

    /// Called on XPC's queue; the client is counted on the main queue before the connection starts,
    /// so the helper does not exit under it.
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> LidSleepGuard.Client in
                nextClient += 1
                clients.insert(nextClient)
                idleExit?.cancel()
                return nextClient
            }
        }
        connection.exportedInterface = NSXPCInterface(with: LidSleepHelperProtocol.self)
        connection.exportedObject = Session(client: client, helper: self)
        let ended: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.disconnect(client) } }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        connection.resume()
        return true
    }

    func set(_ client: LidSleepGuard.Client, keepsAwake: Bool) -> Bool {
        // A call that arrives after its connection ended must not hold for a client that is gone.
        guard clients.contains(client) else { return false }
        let holding = guardian.set(client, keepsAwake: keepsAwake)
        changed()
        return holding
    }

    private func disconnect(_ client: LidSleepGuard.Client) {
        guard clients.remove(client) != nil else { return }
        guardian.disconnect(client)
        changed()
    }

    /// Checks the battery and the heat every minute while a client wants the Mac awake, and exits
    /// once nothing is connected and nothing is held; launchd starts it again on the next connection.
    private func changed() {
        if guardian.wantsPowerChecks, powerCheck == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.guardian.powerChanged() } }
            timer.resume()
            powerCheck = timer
        } else if !guardian.wantsPowerChecks, let timer = powerCheck {
            timer.cancel()
            powerCheck = nil
        }
        idleExit?.cancel()
        guard clients.isEmpty, guardian.isIdle else { return }
        let exitWhenIdle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.clients.isEmpty, self.guardian.isIdle else { return }
                exit(0)
            }
        }
        idleExit = exitWhenIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: exitWhenIdle)
    }
}

/// One connection's calls, answered on the main queue where the guard lives.
final class Session: NSObject, LidSleepHelperProtocol, @unchecked Sendable {
    private let client: LidSleepGuard.Client
    private weak var helper: LidHelper?

    init(client: LidSleepGuard.Client, helper: LidHelper) {
        self.client = client
        self.helper = helper
    }

    func setKeepsAwake(_ keepsAwake: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        let client = client
        DispatchQueue.main.async { [weak helper] in
            MainActor.assumeIsolated { reply(helper?.set(client, keepsAwake: keepsAwake) ?? false) }
        }
    }
}

MainActor.assumeIsolated {
    // Signed ad hoc: Yardlet registers no helper then, so this one has nothing to hold or put back.
    guard let requirement = LidSleepHelperIdentity.peerRequirement(identifier: appIdentifier) else { exit(1) }
    let helper = LidHelper(appIdentifier: appIdentifier, requirement: requirement)
    helper.run()
    withExtendedLifetime(helper) { dispatchMain() }
}
