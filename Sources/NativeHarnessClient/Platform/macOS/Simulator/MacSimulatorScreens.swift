import Foundation
import Observation
import YardletSimulatorHostProtocol

/// What a panel's screen needs from the simulator host: the display its frames go to, and the size in pixels it
/// shows the screen at.
@MainActor
protocol SimulatorScreenSubscriber: AnyObject {
    var frameDisplay: SimulatorFrameDisplay { get }
    /// Nil until the panel is laid out in a window.
    var screenPixelSize: (width: Int, height: Int)? { get }
}

/// The Mac's simulator screens: one simulator host per Xcode (`SimulatorHostClient`) for iOS simulators, scrcpy
/// streams for Android emulators (`AndroidScreenClient`), the running devices attached for the panels that show them,
/// and each panel's frames. A device is attached when the first panel starts showing it and let go a little after
/// the last one stops, so going to another tab and back does not attach it again; the iOS helper ends a minute after
/// it lets go of its last device, and an Android device's stream ends with its last panel. Every panel that shows a
/// device subscribes with its own size, and each frame is made once, for the largest of them. The agents' simulator
/// tools attach an iOS simulator through the same helper (`attachForTools`), and hold it attached while they use it,
/// with or without a panel showing it.
///
/// Turning Settings › General › Simulator off ends every helper and stream (`endAll()`).
@MainActor @Observable
final class MacSimulatorScreens: SimulatorHostAttaching {
    static let shared = MacSimulatorScreens()

    /// How long a device stays attached after the last panel stops showing it.
    static let releaseDelay: Duration = .seconds(10)
    /// How long the agents' tools hold a device attached after their last call, unless they let go of it first.
    static let toolHoldDelay: Duration = .seconds(120)

    /// A running device a panel shows: which one, the adb serial it has while it runs (Android), and the Xcode or SDK
    /// that runs it.
    struct Target: Equatable {
        var device: SimulatorDeviceIdentity
        var adbSerial: String?
        var toolchain: SimulatorToolchain
    }

    /// How far a device's screen is.
    enum Link: Equatable {
        case attaching
        case attached(SimulatorScreen)
        /// The device's screen could not be shown, or stopped showing.
        case failed(SimulatorScreenFailure)
    }

    /// Each device's link, while a panel shows it or it waits to be let go.
    private(set) var links: [SimulatorDeviceIdentity: Link] = [:]

    /// The Xcode the helper cannot show screens with: the simulator center says so for its tab
    /// (`SimulatorCenter.markNotSupportedYet`).
    @ObservationIgnored var onUnsupported: @MainActor (SimulatorToolchain) -> Void = { _ in }
    /// A device whose screen went away, most often because the device shut down: the simulator center reads the
    /// devices again (`SimulatorCenter.refreshDevices`), as it reads them only when asked.
    @ObservationIgnored var onDeviceLetGo: @MainActor (SimulatorDeviceIdentity) -> Void = { _ in }
    /// The helper's executable; QA points it elsewhere.
    @ObservationIgnored var executable = SimulatorHostProcess.bundledExecutable

    @ObservationIgnored private let android: AndroidScreenClient
    @ObservationIgnored private var clients: [String: SimulatorHostClient] = [:]
    @ObservationIgnored private var deviceClients: [SimulatorDeviceIdentity: SimulatorHostClient] = [:]
    @ObservationIgnored private var targets: [SimulatorDeviceIdentity: Target] = [:]
    @ObservationIgnored private var subscribers: [SimulatorDeviceIdentity: [ObjectIdentifier: WeakSubscriber]] = [:]
    @ObservationIgnored private var releases: [SimulatorDeviceIdentity: Task<Void, Never>] = [:]
    @ObservationIgnored private var attaches: [SimulatorDeviceIdentity: Task<Void, Never>] = [:]
    /// The devices the agents' tools hold attached, each with the wait that lets go of it.
    @ObservationIgnored private var toolHolds: [SimulatorDeviceIdentity: Task<Void, Never>] = [:]

    private struct WeakSubscriber {
        weak var subscriber: (any SimulatorScreenSubscriber)?
    }

    init(android: AndroidScreenClient = AndroidScreenClient()) {
        self.android = android
        android.onStreamEnded = { [weak self] target, end in self?.androidStreamEnded(target, end: end) }
        android.onFrameSize = { [weak self] target, width, height in
            self?.androidFrameSize(target, width: width, height: height)
        }
    }

    func link(of device: SimulatorDeviceIdentity) -> Link? { links[device] }

    // MARK: - Panels

    /// A panel starts showing the device, or shows it at another size: attaches the device first when no panel
    /// shows it, then asks for frames of the panel's size.
    func show(_ target: Target, in subscriber: any SimulatorScreenSubscriber) {
        let device = target.device
        releases.removeValue(forKey: device)?.cancel()
        subscribers[device, default: [:]][ObjectIdentifier(subscriber)] = WeakSubscriber(subscriber: subscriber)
        if let shown = targets[device], shown != target {
            // Another Xcode runs the device now, or the emulator runs on another serial: start over with it.
            letGo(device)
        }
        targets[device] = target
        switch links[device] {
        case .attached:
            sendFrames(of: device, to: subscriber)
        case .attaching:
            break
        case .failed, nil:
            attach(target)
        }
    }

    /// A panel stops showing the device: hidden, out of its window, or showing another device.
    func stopShowing(_ device: SimulatorDeviceIdentity, in subscriber: any SimulatorScreenSubscriber) {
        guard subscribers[device]?.removeValue(forKey: ObjectIdentifier(subscriber)) != nil else { return }
        if let udid = Self.udid(of: device) {
            deviceClients[device]?.stopShowingFrames(of: udid, in: subscriber.frameDisplay)
        } else if let target = androidTarget(device) {
            android.stopShowingFrames(of: target, in: subscriber.frameDisplay)
        }
        subscriber.frameDisplay.clear()
        pruneSubscribers(of: device)
        guard subscribers[device] == nil else { return }
        releases[device] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled else { return }
            self?.release(device)
        }
    }

    /// Attaches the device again after it failed: the panel's Try Again.
    func retry(_ device: SimulatorDeviceIdentity) {
        guard case .failed = links[device], let target = targets[device] else { return }
        attach(target)
    }

    // MARK: - Input

    func touch(_ phase: SimulatorTouchPhase, at point: SimulatorPoint, on device: SimulatorDeviceIdentity) {
        guard isAttached(device) else { return }
        if let udid = Self.udid(of: device) {
            deviceClients[device]?.touch(phase, at: point, on: udid)
        } else if let target = androidTarget(device) {
            android.touch(phase, at: point, on: target)
        }
    }

    /// A device's button: an iOS simulator's; on an Android device, Home is its Home and the others do nothing.
    func press(_ button: SimulatorButton, on device: SimulatorDeviceIdentity) {
        guard isAttached(device) else { return }
        if let udid = Self.udid(of: device) {
            deviceClients[device]?.press(button, .press, on: udid)
        } else if button == .home {
            pressNavigation(.home, on: device)
        }
    }

    /// An Android device's Back, Home and Recents.
    func pressNavigation(_ button: AndroidNavigationButton, on device: SimulatorDeviceIdentity) {
        guard isAttached(device), let target = androidTarget(device) else { return }
        android.press(button, on: target)
    }

    func key(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase, on device: SimulatorDeviceIdentity) {
        guard isAttached(device) else { return }
        if let udid = Self.udid(of: device) {
            deviceClients[device]?.key(usage, phase, on: udid)
        } else if let target = androidTarget(device) {
            android.key(usage, phase, on: target)
        }
    }

    // MARK: - Agent tools

    /// Attaches the iOS simulator for the agents' tools as a panel would, or finds it attached, and holds it attached
    /// until `releaseForTools(_:)` or a while after this last call.
    func attachForTools(_ udid: UUID, with toolchain: SimulatorToolchain) async throws
        -> (client: SimulatorHostClient, screen: SimulatorScreen) {
        let device = SimulatorDeviceIdentity.iOSSimulator(udid: udid.uuidString)
        holdForTools(device)
        let target = Target(device: device, toolchain: toolchain)
        if let shown = targets[device], shown != target { letGo(device) }
        targets[device] = target
        switch links[device] {
        case .attached:
            break
        case .attaching:
            if let attaching = attaches[device] { await attaching.value }
        case .failed, nil:
            attach(target)
            if let attaching = attaches[device] { await attaching.value }
        }
        switch links[device] {
        case let .attached(screen):
            guard let client = deviceClients[device] else { break }
            return (client, screen)
        case let .failed(failure):
            throw SimulatorHostClient.Failure.device(failure.toolReason)
        case .attaching, nil:
            break
        }
        throw SimulatorHostClient.Failure.device("the simulator host let go of the device")
    }

    /// The agents' tools let go of the iOS simulator: it is let go of now, unless a panel shows it.
    func releaseForTools(_ udid: UUID) {
        let device = SimulatorDeviceIdentity.iOSSimulator(udid: udid.uuidString)
        guard let hold = toolHolds.removeValue(forKey: device) else { return }
        hold.cancel()
        release(device)
    }

    private func holdForTools(_ device: SimulatorDeviceIdentity) {
        releases.removeValue(forKey: device)?.cancel()
        toolHolds[device]?.cancel()
        toolHolds[device] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.toolHoldDelay)
            guard !Task.isCancelled, let udid = UUID(uuidString: device.value) else { return }
            self?.releaseForTools(udid)
        }
    }

    // MARK: - The switch

    /// Settings › General › Simulator turned off: every helper and stream ends, and the panels' screens go blank.
    func endAll() {
        for task in releases.values { task.cancel() }
        for task in attaches.values { task.cancel() }
        for task in toolHolds.values { task.cancel() }
        releases = [:]
        attaches = [:]
        toolHolds = [:]
        for subscribersOfDevice in subscribers.values {
            for entry in subscribersOfDevice.values { entry.subscriber?.frameDisplay.clear() }
        }
        subscribers = [:]
        for client in clients.values { client.terminate() }
        clients = [:]
        deviceClients = [:]
        android.stopAll()
        targets = [:]
        links = [:]
    }

#if DEBUG
    /// The performance bench's device (`PerfBenchSimulatorBackend`): attached with no helper behind it, so the panels
    /// ask no helper for frames and the bench puts frames on their displays itself.
    func attachWithoutHelper(_ device: SimulatorDeviceIdentity, screen: SimulatorScreen, toolchain: SimulatorToolchain) {
        targets[device] = Target(device: device, toolchain: toolchain)
        links[device] = .attached(screen)
    }
#endif

    // MARK: - Private

    /// An iOS simulator's UDID, which the simulator host takes.
    private static func udid(of device: SimulatorDeviceIdentity) -> UUID? {
        device.kind == .iOSSimulator ? UUID(uuidString: device.value) : nil
    }

    private func androidTarget(_ device: SimulatorDeviceIdentity) -> AndroidScreenTarget? {
        targets[device].flatMap {
            AndroidScreenTarget(identity: device, adbSerial: $0.adbSerial, adb: AndroidSDK(toolchain: $0.toolchain).adb)
        }
    }

    private func isAttached(_ device: SimulatorDeviceIdentity) -> Bool {
        if case .attached = links[device] { return true }
        return false
    }

    private func client(for toolchain: SimulatorToolchain) -> SimulatorHostClient {
        if let client = clients[toolchain.directory] { return client }
        let client = SimulatorHostClient(developerDirectory: URL(filePath: toolchain.directory, directoryHint: .isDirectory),
                                         executable: executable)
        client.onEvent = { [weak self] event in self?.receive(event) }
        clients[toolchain.directory] = client
        return client
    }

    private func attach(_ target: Target) {
        let device = target.device
        links[device] = .attaching
        attaches[device]?.cancel()
        if let udid = Self.udid(of: device) {
            let client = client(for: target.toolchain)
            deviceClients[device] = client
            attaches[device] = Task { @MainActor [weak self] in
                do {
                    let screen = try await client.attach(udid)
                    guard let self, !Task.isCancelled, self.deviceClients[device] === client else { return }
                    self.attached(device, screen: screen)
                } catch {
                    guard let self, !Task.isCancelled, self.deviceClients[device] === client else { return }
                    self.attaches[device] = nil
                    if case .unsupportedXcode = error as? SimulatorHostClient.Failure {
                        self.onUnsupported(target.toolchain)
                    }
                    NSLog("Yardlet simulator screen of %@: %@", device.value, String(describing: error))
                    self.links[device] = .failed(SimulatorScreenFailure(error, executable: self.executable))
                }
            }
        } else if let android = androidTarget(device) {
            // An Android device is attached once its screen's size is read; its stream starts with the frames.
            attaches[device] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let screen = try await self.android.screen(of: android)
                    guard !Task.isCancelled, self.targets[device] == target else { return }
                    self.attached(device, screen: screen)
                } catch {
                    guard !Task.isCancelled, self.targets[device] == target else { return }
                    self.attaches[device] = nil
                    NSLog("Yardlet emulator screen of %@: %@", device.value, String(describing: error))
                    self.links[device] = .failed(.emulatorRefused)
                }
            }
        } else {
            // An Android device with no adb serial: it is not running.
            links[device] = .failed(.emulatorRefused)
        }
    }

    private func attached(_ device: SimulatorDeviceIdentity, screen: SimulatorScreen) {
        attaches[device] = nil
        links[device] = .attached(screen)
        for subscriber in liveSubscribers(of: device) { sendFrames(of: device, to: subscriber) }
    }

    private func sendFrames(of device: SimulatorDeviceIdentity, to subscriber: any SimulatorScreenSubscriber) {
        guard let size = subscriber.screenPixelSize, size.width > 0, size.height > 0 else { return }
        if let udid = Self.udid(of: device) {
            deviceClients[device]?.showFrames(of: udid, in: subscriber.frameDisplay, pixelWidth: size.width,
                                              pixelHeight: size.height)
        } else if let target = androidTarget(device) {
            android.showFrames(of: target, in: subscriber.frameDisplay, pixelWidth: size.width, pixelHeight: size.height)
        }
    }

    private func release(_ device: SimulatorDeviceIdentity) {
        releases[device] = nil
        pruneSubscribers(of: device)
        guard subscribers[device] == nil, toolHolds[device] == nil else { return }
        letGo(device)
        targets[device] = nil
    }

    /// Lets go of what showed the device: the helper's attachment, or the stream of a device no panel shows.
    private func letGo(_ device: SimulatorDeviceIdentity) {
        attaches.removeValue(forKey: device)?.cancel()
        if let udid = Self.udid(of: device) {
            deviceClients.removeValue(forKey: device)?.detach(udid)
        } else if let target = androidTarget(device) {
            for subscriber in liveSubscribers(of: device) {
                android.stopShowingFrames(of: target, in: subscriber.frameDisplay)
            }
        }
        links[device] = nil
    }

    private func liveSubscribers(of device: SimulatorDeviceIdentity) -> [any SimulatorScreenSubscriber] {
        (subscribers[device] ?? [:]).values.compactMap(\.subscriber)
    }

    private func pruneSubscribers(of device: SimulatorDeviceIdentity) {
        let live = (subscribers[device] ?? [:]).filter { $0.value.subscriber != nil }
        subscribers[device] = live.isEmpty ? nil : live
    }

    /// The helper's events beside frames and answers: a screen that changed size, and a device it let go of (shut
    /// down, or the helper ended).
    private func receive(_ event: SimulatorHostEvent) {
        switch event {
        case let .screenChanged(udid, screen):
            let device = SimulatorDeviceIdentity.iOSSimulator(udid: udid.uuidString)
            guard isAttached(device) else { return }
            links[device] = .attached(screen)
            for subscriber in liveSubscribers(of: device) { sendFrames(of: device, to: subscriber) }
        case let .detached(udid, reason):
            let device = SimulatorDeviceIdentity.iOSSimulator(udid: udid.uuidString)
            guard links[device] != nil else { return }
            NSLog("Yardlet simulator screen of %@ let go: %@", device.value, reason)
            links[device] = .failed(.lost)
            onDeviceLetGo(device)
        case .commandFailed, .ready, .unsupported, .attached, .deviceFailed, .frame, .screenshot, .requestFailed,
             .diagnosis:
            break
        }
    }

    /// An Android device's stream ended while a panel showed it: the server is missing, it did not start, or the
    /// stream ended (the emulator stopped, or the connection broke).
    private func androidStreamEnded(_ target: AndroidScreenTarget, end: AndroidStreamEnd) {
        let device = target.identity
        guard androidTarget(device) == target, links[device] != nil else { return }
        switch end {
        case .serverMissing:
            links[device] = .failed(.emulatorServerMissing)
        case let .couldNotStart(detail):
            NSLog("Yardlet emulator screen of %@: %@", device.value, detail)
            links[device] = .failed(.emulatorRefused)
        case let .ended(detail):
            if let detail { NSLog("Yardlet emulator screen of %@ ended: %@", device.value, detail) }
            links[device] = .failed(.emulatorLost)
        }
        onDeviceLetGo(device)
    }

    /// An Android device turned: the screen takes the frames' orientation, and the panels their new size.
    private func androidFrameSize(_ target: AndroidScreenTarget, width: Int, height: Int) {
        let device = target.identity
        guard androidTarget(device) == target, case var .attached(screen) = links[device],
              (screen.pixelWidth > screen.pixelHeight) != (width > height) else { return }
        swap(&screen.pixelWidth, &screen.pixelHeight)
        links[device] = .attached(screen)
        for subscriber in liveSubscribers(of: device) { sendFrames(of: device, to: subscriber) }
    }
}

/// Why a device's screen can't be shown, as the panel tells the person; what went wrong in detail goes to the log.
enum SimulatorScreenFailure: Equatable {
    /// The helper is not in the app (a damaged copy, or a build run outside an app bundle without it).
    case helperMissing
    /// The helper is there but did not start: no sandbox, or the system refused to start it.
    case helperDidNotStart
    /// The helper ended while it showed the device, or before it attached it.
    case helperEnded
    /// The helper is running, but the simulator did not let it attach.
    case deviceRefused
    /// The helper let go of the device: it shut down, or its screen went away.
    case lost
    /// The app has no scrcpy server to send an Android device.
    case emulatorServerMissing
    /// The emulator is not running, or its screen's stream did not start.
    case emulatorRefused
    /// The emulator's stream ended: it shut down, or the connection broke.
    case emulatorLost

    init(_ error: any Error, executable: URL) {
        // A missing helper fails however it was started: sandbox-exec ends at once, or the spawn finds no file.
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            self = .helperMissing
            return
        }
        switch error as? SimulatorHostClient.Failure {
        case .helperEnded?: self = .helperEnded
        case .device?: self = .deviceRefused
        case .request?: self = .lost
        // Anything else failed while the helper started.
        case .unsupportedXcode?, nil: self = .helperDidNotStart
        }
    }

    /// What the panel says under "The simulator's screen can't be shown."
    var message: String {
        switch self {
        case .helperMissing: L10n.string("Yardlet's simulator helper is missing. Reinstall Yardlet to use simulators.")
        case .helperDidNotStart: L10n.string("Yardlet's simulator helper couldn't start.")
        case .helperEnded: L10n.string("Yardlet's simulator helper stopped.")
        case .deviceRefused: L10n.string("Yardlet couldn't connect to this simulator.")
        case .lost: L10n.string("The connection to this simulator ended.")
        case .emulatorServerMissing:
            L10n.string("Yardlet's Android screen server is missing. Reinstall Yardlet to use Android emulators.")
        case .emulatorRefused: L10n.string("Yardlet couldn't connect to this emulator.")
        case .emulatorLost: L10n.string("The connection to this emulator ended.")
        }
    }

    /// Whether trying again can help: it starts the helper or the stream again. A missing file stays missing.
    var canTryAgain: Bool { self != .helperMissing && self != .emulatorServerMissing }

    /// What the agents' tools are told, in English as the rest of their results: the same reason, untranslated.
    var toolReason: String {
        switch self {
        case .helperMissing: "Yardlet's simulator helper is missing from the app; reinstalling Yardlet restores it"
        case .helperDidNotStart: "Yardlet's simulator helper couldn't start"
        case .helperEnded: "Yardlet's simulator helper stopped"
        case .deviceRefused: "the simulator did not let Yardlet's helper connect to it"
        case .lost: "the connection to the simulator ended"
        case .emulatorServerMissing: "Yardlet's scrcpy server is missing from the app; reinstalling Yardlet restores it"
        case .emulatorRefused: "Yardlet couldn't connect to the emulator"
        case .emulatorLost: "the connection to the emulator ended"
        }
    }
}
