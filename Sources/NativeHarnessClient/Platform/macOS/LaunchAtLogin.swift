import Foundation
import Observation
import ServiceManagement

/// Settings › General › "Launch at login": Yardlet itself as a login item (`SMAppService.mainApp`), with no helper.
/// macOS keeps whether it is on, not Yardlet's preferences, so turning it off removes the item and leaves nothing.
@MainActor @Observable final class LaunchAtLogin {
    enum Status: Equatable, Sendable {
        /// A run outside an app bundle or a QA copy, which must not become a login item.
        case unavailable
        case off
        case on
        /// Added, but turned off in System Settings › General › Login Items & Extensions.
        case needsApproval
    }

    private(set) var status: Status
    @ObservationIgnored private let backend: (any LaunchAtLoginBackend)?
    /// Counts the reads, so a read that ends after a later one leaves the later one's.
    @ObservationIgnored private var reads = 0

    /// Off until macOS answers: reading the status waits for its service manager.
    init(backend: (any LaunchAtLoginBackend)?) {
        self.backend = backend
        status = backend == nil ? .unavailable : .off
        refresh()
    }

    static func live(bundle: Bundle = .main) -> LaunchAtLogin {
        LaunchAtLogin(backend: bundle.bundleURL.pathExtension == "app" && !QABackground.isOn ? MainAppLoginItem() : nil)
    }

    /// On, off, or nil where this copy cannot be a login item.
    var isOn: Bool? { status == .unavailable ? nil : status != .off }

    /// Reads the status again off the main thread, as when Settings shows it: the person may have changed it in
    /// System Settings.
    func refresh() {
        guard let backend else { return }
        reads += 1
        let read = reads
        Task {
            let status = await backend.status()
            guard read == reads else { return }
            self.status = status
        }
    }

    /// Adds or removes Yardlet; why it did not, or nil.
    func set(_ isOn: Bool) -> String? {
        guard let backend else { return L10n.string("Not available in this copy of Yardlet") }
        reads += 1
        do {
            if isOn { try backend.register() } else { try backend.unregister() }
        } catch {
            refresh()
            return error.localizedDescription
        }
        status = isOn ? .on : .off
        refresh()
        return nil
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// What `LaunchAtLogin` needs of macOS. Tests put a fake in its place, so they never add a login item.
protocol LaunchAtLoginBackend: Sendable {
    func status() async -> LaunchAtLogin.Status
    func register() throws
    func unregister() throws
}

/// The app's own entry in Login Items.
struct MainAppLoginItem: LaunchAtLoginBackend {
    func status() async -> LaunchAtLogin.Status {
        await Task.detached(priority: .utility) {
            switch SMAppService.mainApp.status {
            case .enabled: LaunchAtLogin.Status.on
            case .requiresApproval: .needsApproval
            case .notRegistered: .off
            case .notFound: .unavailable
            @unknown default: .unavailable
            }
        }.value
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
