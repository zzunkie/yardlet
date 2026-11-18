import Foundation
import YardletSimulatorHostProtocol

/// Yardlet's side of the simulator host for one Xcode: starts the helper when a device is first attached, waits for
/// its answers, and starts it again after it ended (the helper ends a minute after it lets go of its last device). An
/// Xcode the helper does not support yet is remembered, and the helper is not started again for it.
///
/// The order of use: `attach(_:)` a booted device, then `showFrames(of:in:pixelWidth:pixelHeight:)` for each panel
/// that shows it, input and `screenshot(of:format:)` as needed, and `detach(_:)`. Which devices exist, booting them
/// and which task may drive one are decided before this.
@MainActor
final class SimulatorHostClient {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// This Xcode lacks parts the helper uses; `missing` names them.
        case unsupportedXcode(version: String, missing: [String])
        case device(String)
        case request(String)
        case helperEnded(String)

        var description: String {
            switch self {
            case .unsupportedXcode(let version, let missing): "Xcode \(version) is not supported yet (missing \(missing.joined(separator: ", ")))"
            case .device(let message), .request(let message): message
            case .helperEnded(let reason): "the simulator host ended (\(reason))"
            }
        }
    }

    let developerDirectory: URL
    /// Every event but frames and answers, for the panels: `screenChanged`, `detached`, `commandFailed`.
    var onEvent: ((SimulatorHostEvent) -> Void)?
    private(set) var xcodeVersion: String?
    private(set) var capabilities: [String] = []
    private(set) var unsupported: Failure?
    private(set) var screens: [UUID: SimulatorScreen] = [:]

    private let executable: URL
    private let log: URL?
    private let idleExit: Duration?
    private var process: SimulatorHostProcess?
    private var attaching: [UUID: [CheckedContinuation<SimulatorScreen, any Error>]] = [:]
    private var requests: [Int: CheckedContinuation<SimulatorHostEvent, any Error>] = [:]
    private var nextRequest = 1
    private var subscriptions: [ObjectIdentifier: Int] = [:]
    private var nextSubscription = 1

    init(developerDirectory: URL, executable: URL = SimulatorHostProcess.bundledExecutable, log: URL? = nil,
         idleExit: Duration? = nil) {
        self.developerDirectory = developerDirectory
        self.executable = executable
        self.log = log
        self.idleExit = idleExit
    }

    /// The running helper's process ID, if one runs.
    var helperProcessID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    /// Starts showing and driving a booted device. Attaching it again starts from the device's screen as it is now.
    func attach(_ device: UUID) async throws -> SimulatorScreen {
        let helper = try running()
        return try await withCheckedThrowingContinuation { continuation in
            attaching[device, default: []].append(continuation)
            helper.send(.attach(device: device))
        }
    }

    func detach(_ device: UUID) {
        screens[device] = nil
        process?.send(.detach(device: device))
    }

    /// Sends the device's frames to the display, fit within the panel's size in pixels, until
    /// `stopShowingFrames(of:in:)`. Called again with another size, it changes the size.
    func showFrames(of device: UUID, in display: SimulatorFrameDisplay, pixelWidth: Int, pixelHeight: Int) {
        guard let process else { return }
        let subscription = subscriptions[ObjectIdentifier(display)] ?? {
            defer { nextSubscription += 1 }
            subscriptions[ObjectIdentifier(display)] = nextSubscription
            return nextSubscription
        }()
        process.frameRouter.add(display, for: device)
        process.send(.startFrames(device: device, subscription: subscription, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    func stopShowingFrames(of device: UUID, in display: SimulatorFrameDisplay) {
        guard let subscription = subscriptions.removeValue(forKey: ObjectIdentifier(display)) else { return }
        process?.frameRouter.remove(display, for: device)
        process?.send(.stopFrames(device: device, subscription: subscription))
    }

    func screenshot(of device: UUID, format: SimulatorImageFormat) async throws -> SimulatorScreenshot {
        let request = nextRequest
        let answer = try await ask(request) { .screenshot(request: request, device: device, format: format) }
        guard case .screenshot(_, let image) = answer else { throw Failure.request("the helper answered with no screenshot") }
        return image
    }

    func touch(_ phase: SimulatorTouchPhase, at point: SimulatorPoint, on device: UUID) {
        process?.send(.touch(device: device, phase: phase, point: point))
    }

    func press(_ button: SimulatorButton, _ phase: SimulatorPressPhase, on device: UUID) {
        process?.send(.button(device: device, button: button, phase: phase))
    }

    func key(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase, on device: UUID) {
        process?.send(.key(device: device, usage: usage, phase: phase))
    }

    /// Types on the hardware keyboard, which the device reads with its own keyboard layout (a Korean layout turns
    /// Latin keys into Hangul).
    func type(_ text: SimulatorKeyboardText, on device: UUID) {
        process?.send(.typeText(device: device, text: text))
    }

    struct Diagnosis: Equatable {
        var processID: Int32
        /// The process macOS holds responsible for the helper: the helper itself, so it has none of Yardlet's permissions.
        var responsibleProcessID: Int32?
        var sandboxed: Bool?
        var screenCaptureAccess: Bool
        var homeReadable: Bool
        var networkReachable: Bool
    }

    /// For QA: how the helper runs. It should be responsible for itself and sandboxed, and hold no screen recording
    /// permission, no read of the home folder and no network.
    func diagnose() async throws -> Diagnosis {
        let request = nextRequest
        let answer = try await ask(request) { .diagnose(request: request) }
        guard case .diagnosis(_, let processID, let screenCapture, let home, let network) = answer else {
            throw Failure.request("the helper answered with no diagnosis")
        }
        return Diagnosis(processID: processID, responsibleProcessID: DisclaimedSpawn.responsibleProcess(for: processID),
                         sandboxed: SimulatorHostSandbox.isSandboxed(processID), screenCaptureAccess: screenCapture,
                         homeReadable: home, networkReachable: network)
    }

    func terminate() {
        process?.terminate()
    }

    // MARK: Helper

    private func running() throws -> SimulatorHostProcess {
        if let unsupported { throw unsupported }
        if let process, process.isRunning { return process }
        // The last helper ended and its end has not reached here yet: what waited on it fails now.
        if process != nil { helperExited("it ended") }
        let started = try SimulatorHostProcess(
            executable: executable, developerDirectory: developerDirectory, log: log, idleExit: idleExit,
            events: { [weak self] processID, events in
                guard let self, self.process?.processIdentifier == processID else { return }
                for event in events { self.receive(event) }
            },
            exited: { [weak self] processID, reason in
                guard let self, self.process?.processIdentifier == processID else { return }
                self.helperExited(reason)
            })
        process = started
        return started
    }

    private func ask(_ request: Int, _ command: () -> SimulatorHostCommand) async throws -> SimulatorHostEvent {
        nextRequest += 1
        let helper = try running()
        let command = command()
        return try await withCheckedThrowingContinuation { continuation in
            requests[request] = continuation
            helper.send(command)
        }
    }

    private func receive(_ event: SimulatorHostEvent) {
        switch event {
        case .ready(let xcode, let capabilities):
            xcodeVersion = xcode
            self.capabilities = capabilities
        case .unsupported(let xcode, let missing):
            xcodeVersion = xcode
            unsupported = .unsupportedXcode(version: xcode, missing: missing)
        case .attached(let device, let screen):
            screens[device] = screen
            for waiting in attaching.removeValue(forKey: device) ?? [] { waiting.resume(returning: screen) }
        case .deviceFailed(let device, let message):
            screens[device] = nil
            for waiting in attaching.removeValue(forKey: device) ?? [] { waiting.resume(throwing: Failure.device(message)) }
        case .screenChanged(let device, let screen):
            screens[device] = screen
            onEvent?(event)
        case .detached(let device, _):
            screens[device] = nil
            onEvent?(event)
        case .screenshot(let request, _), .diagnosis(let request, _, _, _, _):
            requests.removeValue(forKey: request)?.resume(returning: event)
        case .requestFailed(let request, let message):
            requests.removeValue(forKey: request)?.resume(throwing: Failure.request(message))
        case .commandFailed:
            onEvent?(event)
        case .frame:
            break
        }
    }

    private func helperExited(_ reason: String) {
        process = nil
        subscriptions.removeAll()
        let failure = unsupported ?? Failure.helperEnded(reason)
        let devices = Array(screens.keys)
        screens.removeAll()
        for waiting in attaching.values.flatMap({ $0 }) { waiting.resume(throwing: failure) }
        for waiting in requests.values { waiting.resume(throwing: failure) }
        attaching.removeAll()
        requests.removeAll()
        for device in devices { onEvent?(.detached(device: device, reason: "\(failure)")) }
    }
}
