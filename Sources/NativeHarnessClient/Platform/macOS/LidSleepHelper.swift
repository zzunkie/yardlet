import Foundation
import Observation
import ServiceManagement
import YardletLidSleep

/// Settings › General › "Keep tasks working with the lid closed". Off by default. Turning it on asks
/// macOS to allow Yardlet's lid helper, a launch daemon in the bundle; turning it off removes the
/// helper (docs/REMOTE_V2_DESIGN.md §6.5).
enum LidClosedWorkPreference {
    static let key = "Yardlet.keepWorkingWithLidClosed"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Yardlet's lid helper as Settings and `RunningWorkActivity` see it: whether macOS lets it run, and
/// whether it says the Mac stays awake with the lid closed now.
@MainActor @Observable final class LidSleepHelper {
    enum Status: Equatable {
        /// This copy of Yardlet has no helper: a development run, a local build signed ad hoc, or a QA
        /// copy under another identifier.
        case unavailable
        /// Not registered with macOS.
        case off
        /// Registered, waiting for the person to allow it in System Settings › General › Login Items
        /// & Extensions.
        case needsApproval
        case ready
    }

    private(set) var status: Status
    /// The helper answered that the Mac stays awake with the lid closed.
    private(set) var isKeepingAwake = false
    /// Called when `isKeepingAwake` changes.
    @ObservationIgnored var keepingAwakeChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let backend: any LidSleepHelperBackend
    @ObservationIgnored private var wanted = false
    /// Counts the status reads, so a read that ends off the main thread after a later one leaves the later one's.
    @ObservationIgnored private var statusReads = 0

    init(backend: any LidSleepHelperBackend) {
        self.backend = backend
        status = backend.status()
        backend.answered = { [weak self] holding in self?.helperAnswered(holding) }
    }

    static func live() -> LidSleepHelper { LidSleepHelper(backend: ServiceManagementLidSleepHelper()) }

    /// Reads the registration again off the main thread and calls `changed` when it changed:
    /// `SMAppService.status` waits for macOS's service manager to answer, a quarter of a second at times,
    /// and Yardlet asks each time it comes to the front.
    func refreshStatus(changed: (@MainActor () -> Void)? = nil) {
        statusReads += 1
        let read = statusReads
        Task {
            let status = await backend.readStatus()
            guard read == statusReads, status != self.status else { return }
            self.status = status
            changed?()
        }
    }

    /// Registers the helper. When the person just turned the setting on, System Settings opens where
    /// they allow it; Yardlet opening with the setting on registers it quietly again.
    func turnOn(opensSettings: Bool) {
        guard status != .unavailable else { return }
        if status == .off { backend.register() }
        // Read here, since what follows depends on it.
        statusReads += 1
        status = backend.status()
        if opensSettings, status == .needsApproval { backend.openSystemSettings() }
    }

    /// Ends the connection, which already lets the Mac sleep again, and removes the helper.
    func turnOff() {
        wanted = false
        backend.disconnect()
        helperAnswered(false)
        guard status != .unavailable, status != .off else { return }
        backend.unregister { [weak self] in self?.refreshStatus() }
    }

    func openSystemSettings() { backend.openSystemSettings() }

    /// Tells the helper whether tasks are working, when that changed.
    func keepAwake(_ keepsAwake: Bool) {
        let keepsAwake = keepsAwake && status == .ready
        guard keepsAwake != wanted else { return }
        wanted = keepsAwake
        backend.send(keepsAwake: keepsAwake)
    }

    /// Says again that tasks are working, every minute while they do: the helper lets go of a
    /// "working" not said again within its lease (`LidSleepGuard.lease`), so a Yardlet that stopped
    /// running cannot keep a closed Mac awake. The answer also catches a helper that let go for the
    /// battery or the heat and holds again, or that started again.
    func renew() {
        guard wanted else { return }
        backend.send(keepsAwake: true)
    }

    private func helperAnswered(_ holding: Bool) {
        let holding = holding && wanted
        guard holding != isKeepingAwake else { return }
        isKeepingAwake = holding
        keepingAwakeChanged?()
    }
}

/// What `LidSleepHelper` needs of macOS: the registration (`SMAppService`) and the helper's
/// connection (XPC). Tests put a fake in its place.
@MainActor protocol LidSleepHelperBackend: AnyObject {
    /// Gets each answer of the helper, and false when its connection ends.
    var answered: (@MainActor (Bool) -> Void)? { get set }
    func status() -> LidSleepHelper.Status
    /// `status()`, read off the main thread where it waits for the system.
    func readStatus() async -> LidSleepHelper.Status
    func register()
    func unregister(done: @escaping @MainActor () -> Void)
    func openSystemSettings()
    func send(keepsAwake: Bool)
    func disconnect()
}

extension LidSleepHelperBackend {
    func readStatus() async -> LidSleepHelper.Status { status() }
}

/// The helper registered with `SMAppService.daemon` and reached over its Mach service. The
/// connection stays open while tasks work, since the helper lets go when it ends, and closes when
/// they stop, so the helper can exit.
@MainActor final class ServiceManagementLidSleepHelper: LidSleepHelperBackend {
    var answered: (@MainActor (Bool) -> Void)?
    private let label: String?
    /// The helper's code requirement (`LidSleepHelperIdentity.peerRequirement`).
    private let requirement: String?
    private let service: SMAppService?
    private let plistName: String?
    private var connection: NSXPCConnection?
    private var wanted = false

    init(bundle: Bundle = .main) {
        let identifier = bundle.bundleIdentifier
        let label = identifier.map { LidSleepHelperIdentity.label(appIdentifier: $0) }
        guard !QABackground.isOn, let identifier, let label,
              let requirement = LidSleepHelperIdentity.peerRequirement(identifier: label),
              FileManager.default.fileExists(atPath: bundle.bundleURL
                .appending(path: "Contents/Library/LaunchDaemons")
                .appending(path: LidSleepHelperIdentity.plistName(appIdentifier: identifier)).path) else {
            self.label = nil
            self.requirement = nil
            service = nil
            plistName = nil
            return
        }
        self.label = label
        self.requirement = requirement
        let plistName = LidSleepHelperIdentity.plistName(appIdentifier: identifier)
        self.plistName = plistName
        service = SMAppService.daemon(plistName: plistName)
    }

    func status() -> LidSleepHelper.Status {
        service.map { Self.status(of: $0) } ?? .unavailable
    }

    func readStatus() async -> LidSleepHelper.Status {
        guard let plistName else { return .unavailable }
        return await Task.detached(priority: .utility) {
            Self.status(of: SMAppService.daemon(plistName: plistName))
        }.value
    }

    private nonisolated static func status(of service: SMAppService) -> LidSleepHelper.Status {
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// A refusal shows in the status that follows (needs approval, or still off).
    func register() { try? service?.register() }

    func unregister(done: @escaping @MainActor () -> Void) {
        guard let service else { return done() }
        service.unregister { _ in Task { @MainActor in done() } }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func send(keepsAwake: Bool) {
        wanted = keepsAwake
        guard let label, let requirement, keepsAwake || connection != nil else {
            answered?(false)
            return
        }
        let connection = connection ?? connect(label, requirement: requirement)
        let id = ObjectIdentifier(connection)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.reply(false, on: id) }
        } as? LidSleepHelperProtocol
        proxy?.setKeepsAwake(keepsAwake) { [weak self] holding in
            Task { @MainActor in self?.reply(holding, on: id) }
        }
    }

    func disconnect() {
        wanted = false
        connection?.invalidate()
        connection = nil
    }

    private func connect(_ label: String, requirement: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LidSleepHelperProtocol.self)
        // The helper is signed as part of this bundle, with its label as its identifier.
        connection.setCodeSigningRequirement(requirement)
        let id = ObjectIdentifier(connection)
        // The helper ended under the connection (it is started again on the next message): what
        // Yardlet wants is sent again.
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.ended(id, again: true) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.ended(id, again: false) }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func reply(_ holding: Bool, on id: ObjectIdentifier) {
        guard let connection, ObjectIdentifier(connection) == id else { return }
        answered?(holding)
        if !wanted { disconnect() }
    }

    private func ended(_ id: ObjectIdentifier, again: Bool) {
        guard let connection, ObjectIdentifier(connection) == id else { return }
        answered?(false)
        if !again {
            self.connection = nil
        } else if wanted {
            send(keepsAwake: true)
        }
    }
}
