import Foundation
import YardletSimulatorHostProtocol

/// The Mac's iOS simulators for the agent's simulator tools: the screen and input through the simulator host
/// (`SimulatorHostClient`) the Simulator tabs use, and the clipboard through `simctl`, which `simulator_type` pastes
/// from (docs/SIMULATOR.md, "Agent tools").
@MainActor
final class MacIOSSimulatorDriver: SimulatorDeviceDriving {
    /// How long the clipboard keeps the pasted text before its earlier text goes back: the app reads the clipboard as
    /// it handles the ⌘V, which reaches it a few milliseconds after it goes out.
    static let pasteSettle = 0.5
    /// One key or button press in the helper (`HIDInput`): held 50 ms, then 10 ms before the next stroke.
    static let strokeTime = 0.06

    let buttons: [SimulatorToolButton] = [.home, .lock, .volumeUp, .volumeDown, .action]
    var runner: any CLICommandRunning = LiveCLICommandRunner()
    private let screens: any SimulatorToolScreens

    init(screens: any SimulatorToolScreens) {
        self.screens = screens
    }

    func prepare(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorToolScreen {
        _ = try Self.udid(device)
        let screen = try await screens.attachForTools(MacSimulatorScreens.Target(device: device.identity,
                                                                                 toolchain: toolchain))
        return SimulatorToolScreen(width: screen.pointWidth, height: screen.pointHeight)
    }

    func screenshot(of device: SimulatorDevice, format: SimulatorToolImageFormat) async throws -> SimulatorToolImage {
        let (udid, client) = try attached(device)
        do {
            let shot = try await client.screenshot(of: udid, format: format == .png ? .png : .jpeg)
            return SimulatorToolImage(data: shot.data, format: format, width: shot.width, height: shot.height)
        } catch let failure as SimulatorHostClient.Failure {
            throw SimulatorDriveError(message: failure.description)
        }
    }

    func touch(_ phase: SimulatorToolTouchPhase, at point: SimulatorScreenFraction, on device: SimulatorDevice) throws {
        let (udid, client) = try attached(device)
        guard let point = SimulatorPoint(x: point.x, y: point.y) else {
            throw SimulatorDriveError(message: "the point is off the screen")
        }
        let phase: SimulatorTouchPhase = switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        }
        client.touch(phase, at: point, on: udid)
    }

    func press(_ button: SimulatorToolButton, on device: SimulatorDevice) async throws {
        let (udid, client) = try attached(device)
        let hardware: SimulatorButton
        switch button {
        case .home: hardware = .home
        case .lock: hardware = .lock
        case .volumeUp: hardware = .volumeUp
        case .volumeDown: hardware = .volumeDown
        case .action: hardware = .action
        case .back, .recents, .power: throw SimulatorDriveError(message: "an iPhone has no \(button.rawValue) button")
        }
        client.press(hardware, .press, on: udid)
        await Self.wait(Self.strokeTime)
    }

    func press(_ key: SimulatorToolKey, on device: SimulatorDevice) async throws {
        let (udid, client) = try attached(device)
        let usage: SimulatorKeyUsage
        switch key {
        case .returnKey: usage = SimulatorKeyboard.returnKey
        case .delete: usage = SimulatorKeyboard.deleteBackward
        case .tab: usage = SimulatorKeyboard.tab
        case .escape: usage = SimulatorKeyboard.escape
        case .space: usage = SimulatorKeyboard.space
        case .up: usage = SimulatorKeyboard.upArrow
        case .down: usage = SimulatorKeyboard.downArrow
        case .left: usage = SimulatorKeyboard.leftArrow
        case .right: usage = SimulatorKeyboard.rightArrow
        case .selectAll:
            command(SimulatorKeyboard.letterA, on: udid, with: client)
            await Self.wait(Self.strokeTime)
            return
        }
        client.key(usage, .press, on: udid)
        await Self.wait(Self.strokeTime)
    }

    /// Pastes with ⌘V from the device's clipboard: the device reads it as the person's own paste, so no "Allow Paste"
    /// question comes up, and a keyboard layout of another language leaves the text as it is.
    func paste(_ text: String, on device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        let (udid, client) = try attached(device)
        let earlier = await simctl(["pbpaste", udid.uuidString], with: toolchain)
        guard earlier.succeeded else { throw SimulatorDriveError(message: "simctl pbpaste: \(earlier.failureSummary)") }
        let copied = await simctl(["pbcopy", udid.uuidString], with: toolchain, input: Data(text.utf8))
        guard copied.succeeded else { throw SimulatorDriveError(message: "simctl pbcopy: \(copied.failureSummary)") }
        command(SimulatorKeyboard.letterV, on: udid, with: client)
        await Self.wait(Self.pasteSettle)
        _ = await simctl(["pbcopy", udid.uuidString], with: toolchain, input: Data(earlier.stdout.utf8))
    }

    func typeKeys(_ text: String, on device: SimulatorDevice) async throws {
        let (udid, client) = try attached(device)
        guard let keyboard = SimulatorKeyboardText(text) else {
            throw SimulatorDriveError(message: "the hardware keyboard types ASCII text of at most 1,000 characters")
        }
        client.type(keyboard, on: udid)
        await Self.wait(Double(text.unicodeScalars.count) * Self.strokeTime)
    }

    func release(_ device: SimulatorDevice) {
        screens.releaseForTools(device.identity)
    }

    // MARK: - Private

    /// ⌘ and a letter, as a hardware keyboard sends a shortcut.
    private func command(_ letter: SimulatorKeyUsage, on udid: UUID, with client: SimulatorHostClient) {
        client.key(SimulatorKeyboard.leftCommand, .down, on: udid)
        client.key(letter, .press, on: udid)
        client.key(SimulatorKeyboard.leftCommand, .up, on: udid)
    }

    private func attached(_ device: SimulatorDevice) throws -> (UUID, SimulatorHostClient) {
        let udid = try Self.udid(device)
        guard let client = screens.hostClient(of: device.identity), client.screens[udid] != nil else {
            throw SimulatorDriveError(message: SimulatorScreenFailure.lost.toolReason)
        }
        return (udid, client)
    }

    private static func udid(_ device: SimulatorDevice) throws -> UUID {
        guard device.identity.kind == .iOSSimulator, let udid = UUID(uuidString: device.identity.value) else {
            throw SimulatorDriveError(message: "\(device.name) is not an iOS simulator")
        }
        return udid
    }

    /// `simctl pbcopy` reads its input in the locale's encoding and refuses text outside ASCII without a UTF-8 one,
    /// which an app opened from the Finder does not have.
    private func simctl(_ arguments: [String], with toolchain: SimulatorToolchain, input: Data? = nil) async
        -> CLICommandResult {
        await runner.run(CLICommand(executable: URL(filePath: "/usr/bin/xcrun"), arguments: ["simctl"] + arguments,
                                    environment: ["DEVELOPER_DIR": toolchain.directory, "LC_CTYPE": "UTF-8"],
                                    timeout: .seconds(20), standardInput: input))
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded())))
    }
}
