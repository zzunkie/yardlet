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

/// The Mac's simulator screens: one simulator host per Xcode (`SimulatorHostClient`), the booted devices it has
/// attached for the panels that show them, and each panel's frames. A device is attached when the first panel
/// starts showing it and let go a little after the last one stops, so going to another tab and back does not
/// attach it again; the helper ends a minute after it lets go of its last device. Every panel that shows a device
/// subscribes with its own size, and the helper copies each frame once, for the largest of them.
///
/// Turning Settings › General › Simulator off ends every helper (`endAll()`).
@MainActor @Observable
final class MacSimulatorScreens {
    static let shared = MacSimulatorScreens()

    /// How long a device stays attached after the last panel stops showing it.
    static let releaseDelay: Duration = .seconds(10)

    /// How far a device's screen is.
    enum Link: Equatable {
        case attaching
        case attached(SimulatorScreen)
        /// The helper could not attach it, or let go of it; `message` says why.
        case failed(String)
    }

    /// Each device's link, while a panel shows it or it waits to be let go.
    private(set) var links: [UUID: Link] = [:]

    /// The Xcode the helper cannot show screens with: the simulator center says so for its tab
    /// (`SimulatorCenter.markNotSupportedYet`).
    @ObservationIgnored var onUnsupported: @MainActor (SimulatorToolchain) -> Void = { _ in }
    /// The helper let go of a device it showed, most often because the device shut down: the simulator center
    /// reads the devices again (`SimulatorCenter.refreshDevices`), as it reads them only when asked.
    @ObservationIgnored var onDeviceLetGo: @MainActor (UUID) -> Void = { _ in }
    /// The helper's executable; QA points it elsewhere.
    @ObservationIgnored var executable = SimulatorHostProcess.bundledExecutable

    @ObservationIgnored private var clients: [String: SimulatorHostClient] = [:]
    @ObservationIgnored private var deviceClients: [UUID: SimulatorHostClient] = [:]
    @ObservationIgnored private var toolchains: [UUID: SimulatorToolchain] = [:]
    @ObservationIgnored private var subscribers: [UUID: [ObjectIdentifier: WeakSubscriber]] = [:]
    @ObservationIgnored private var releases: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attaches: [UUID: Task<Void, Never>] = [:]

    private struct WeakSubscriber {
        weak var subscriber: (any SimulatorScreenSubscriber)?
    }

    func link(of device: UUID) -> Link? { links[device] }

    // MARK: - Panels

    /// A panel starts showing the device, or shows it at another size: attaches the device first when no panel
    /// shows it, then asks for frames of the panel's size.
    func show(_ device: UUID, with toolchain: SimulatorToolchain, in subscriber: any SimulatorScreenSubscriber) {
        releases.removeValue(forKey: device)?.cancel()
        subscribers[device, default: [:]][ObjectIdentifier(subscriber)] = WeakSubscriber(subscriber: subscriber)
        if let attached = deviceClients[device], toolchains[device] != toolchain {
            // Another Xcode now runs the device: the panel asks the helper of that one.
            attached.detach(device)
            deviceClients[device] = nil
            links[device] = nil
        }
        toolchains[device] = toolchain
        switch links[device] {
        case .attached:
            sendFrames(of: device, to: subscriber)
        case .attaching:
            break
        case .failed, nil:
            attach(device, with: toolchain)
        }
    }

    /// A panel stops showing the device: hidden, out of its window, or showing another device.
    func stopShowing(_ device: UUID, in subscriber: any SimulatorScreenSubscriber) {
        guard subscribers[device]?.removeValue(forKey: ObjectIdentifier(subscriber)) != nil else { return }
        deviceClients[device]?.stopShowingFrames(of: device, in: subscriber.frameDisplay)
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
    func retry(_ device: UUID) {
        guard case .failed = links[device], let toolchain = toolchains[device] else { return }
        attach(device, with: toolchain)
    }

    // MARK: - Input

    func touch(_ phase: SimulatorTouchPhase, at point: SimulatorPoint, on device: UUID) {
        attachedClient(device)?.touch(phase, at: point, on: device)
    }

    func press(_ button: SimulatorButton, on device: UUID) {
        attachedClient(device)?.press(button, .press, on: device)
    }

    func key(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase, on device: UUID) {
        attachedClient(device)?.key(usage, phase, on: device)
    }

    // MARK: - The switch

    /// Settings › General › Simulator turned off: every helper ends, and the panels' screens go blank.
    func endAll() {
        for task in releases.values { task.cancel() }
        for task in attaches.values { task.cancel() }
        releases = [:]
        attaches = [:]
        for subscribersOfDevice in subscribers.values {
            for entry in subscribersOfDevice.values { entry.subscriber?.frameDisplay.clear() }
        }
        subscribers = [:]
        for client in clients.values { client.terminate() }
        clients = [:]
        deviceClients = [:]
        toolchains = [:]
        links = [:]
    }

#if DEBUG
    /// The performance bench's device (`PerfBenchSimulatorBackend`): attached with no helper behind it, so the panels
    /// ask no helper for frames and the bench puts frames on their displays itself.
    func attachWithoutHelper(_ device: UUID, screen: SimulatorScreen, toolchain: SimulatorToolchain) {
        toolchains[device] = toolchain
        links[device] = .attached(screen)
    }
#endif

    // MARK: - Private

    private func attachedClient(_ device: UUID) -> SimulatorHostClient? {
        guard case .attached = links[device] else { return nil }
        return deviceClients[device]
    }

    private func client(for toolchain: SimulatorToolchain) -> SimulatorHostClient {
        if let client = clients[toolchain.directory] { return client }
        let client = SimulatorHostClient(developerDirectory: URL(filePath: toolchain.directory, directoryHint: .isDirectory),
                                         executable: executable)
        client.onEvent = { [weak self] event in self?.receive(event) }
        clients[toolchain.directory] = client
        return client
    }

    private func attach(_ device: UUID, with toolchain: SimulatorToolchain) {
        let client = client(for: toolchain)
        deviceClients[device] = client
        links[device] = .attaching
        attaches[device]?.cancel()
        attaches[device] = Task { @MainActor [weak self] in
            do {
                let screen = try await client.attach(device)
                guard let self, !Task.isCancelled, self.deviceClients[device] === client else { return }
                self.attaches[device] = nil
                self.links[device] = .attached(screen)
                for subscriber in self.liveSubscribers(of: device) { self.sendFrames(of: device, to: subscriber) }
            } catch {
                guard let self, !Task.isCancelled, self.deviceClients[device] === client else { return }
                self.attaches[device] = nil
                if case .unsupportedXcode = error as? SimulatorHostClient.Failure {
                    self.onUnsupported(toolchain)
                }
                self.links[device] = .failed(Self.message(for: error))
            }
        }
    }

    private func sendFrames(of device: UUID, to subscriber: any SimulatorScreenSubscriber) {
        guard let client = deviceClients[device], let size = subscriber.screenPixelSize,
              size.width > 0, size.height > 0 else { return }
        client.showFrames(of: device, in: subscriber.frameDisplay, pixelWidth: size.width, pixelHeight: size.height)
    }

    private func release(_ device: UUID) {
        releases[device] = nil
        pruneSubscribers(of: device)
        guard subscribers[device] == nil else { return }
        attaches.removeValue(forKey: device)?.cancel()
        deviceClients.removeValue(forKey: device)?.detach(device)
        toolchains[device] = nil
        links[device] = nil
    }

    private func liveSubscribers(of device: UUID) -> [any SimulatorScreenSubscriber] {
        (subscribers[device] ?? [:]).values.compactMap(\.subscriber)
    }

    private func pruneSubscribers(of device: UUID) {
        let live = (subscribers[device] ?? [:]).filter { $0.value.subscriber != nil }
        subscribers[device] = live.isEmpty ? nil : live
    }

    /// The helper's events beside frames and answers: a screen that changed size, and a device it let go of (shut
    /// down, or the helper ended).
    private func receive(_ event: SimulatorHostEvent) {
        switch event {
        case let .screenChanged(device, screen):
            guard case .attached = links[device] else { return }
            links[device] = .attached(screen)
            for subscriber in liveSubscribers(of: device) { sendFrames(of: device, to: subscriber) }
        case let .detached(device, reason):
            guard links[device] != nil else { return }
            links[device] = .failed(reason)
            onDeviceLetGo(device)
        case .commandFailed, .ready, .unsupported, .attached, .deviceFailed, .frame, .screenshot, .requestFailed,
             .diagnosis:
            break
        }
    }

    private static func message(for error: any Error) -> String {
        if let failure = error as? SimulatorHostClient.Failure { return failure.description }
        return error.localizedDescription
    }
}
