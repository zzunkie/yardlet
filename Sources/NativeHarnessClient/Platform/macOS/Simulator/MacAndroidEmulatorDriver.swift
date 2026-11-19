import Foundation
import YardletSimulatorHostProtocol

/// Android emulators and real devices for the agent's simulator tools, through the scrcpy stream the Simulator tabs use
/// (`AndroidScreenClient`): screenshots and coordinates in dp, touches and keys as scrcpy control messages, and the
/// clipboard through scrcpy's own clipboard messages, which `simulator_type` pastes from (docs/SIMULATOR.md, "Agent
/// tools").
@MainActor
final class MacAndroidEmulatorDriver: SimulatorDeviceDriving {
    /// How long the clipboard keeps the pasted text before its earlier text goes back: the device acknowledges the
    /// clipboard once it has sent the paste key, which the focused app handles a moment later.
    static let pasteSettle = 0.5
    /// A key's way through the stream and the device's input before the next tool looks at the screen.
    static let strokeTime = 0.03

    let buttons: [SimulatorToolButton] = [.back, .home, .recents, .power, .volumeUp, .volumeDown]
    private let screens: any SimulatorToolScreens

    init(screens: any SimulatorToolScreens) {
        self.screens = screens
    }

    func prepare(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorToolScreen {
        try Self.checkAndroid(device)
        guard let serial = device.adbSerial else {
            throw SimulatorDriveError(message: "\(device.name) has no adb serial; it may still be starting")
        }
        let screen = try await screens.attachForTools(MacSimulatorScreens.Target(device: device.identity,
                                                                                 adbSerial: serial,
                                                                                 toolchain: toolchain))
        // The screen in dp, as `AndroidDisplayMetrics.dpSize` gives the screenshots.
        return SimulatorToolScreen(width: max(1, screen.pointWidth), height: max(1, screen.pointHeight))
    }

    func screenshot(of device: SimulatorDevice, format: SimulatorToolImageFormat) async throws -> SimulatorToolImage {
        let (client, target) = try attached(device)
        do {
            let shot = try await client.screenshot(of: target, format: format == .png ? .png : .jpeg)
            return SimulatorToolImage(data: shot.data, format: format, width: shot.width, height: shot.height)
        } catch let error as ScrcpyProtocolError {
            throw SimulatorDriveError(message: error.description)
        }
    }

    func touch(_ phase: SimulatorToolTouchPhase, at point: SimulatorScreenFraction, on device: SimulatorDevice) throws {
        let (client, target) = try attached(device)
        guard let point = SimulatorPoint(x: point.x, y: point.y) else {
            throw SimulatorDriveError(message: "the point is off the screen")
        }
        let phase: SimulatorTouchPhase = switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        }
        client.touch(phase, at: point, on: target)
    }

    func press(_ button: SimulatorToolButton, on device: SimulatorDevice) async throws {
        let (client, target) = try attached(device)
        switch button {
        case .back: client.press(.back, on: target)
        case .home: client.press(.home, on: target)
        case .recents: client.press(.recents, on: target)
        case .power: try client.press(keycode: Self.power, on: target)
        case .volumeUp: try client.press(keycode: Self.volumeUp, on: target)
        case .volumeDown: try client.press(keycode: Self.volumeDown, on: target)
        case .lock, .action: throw SimulatorDriveError(message: "an Android device has no \(button.rawValue) button")
        }
        await Self.wait(Self.strokeTime)
    }

    func press(_ key: SimulatorToolKey, on device: SimulatorDevice) async throws {
        let (client, target) = try attached(device)
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
            // Control-A, which Android's text fields take as Select All.
            client.key(SimulatorKeyboard.leftControl, .down, on: target)
            client.key(SimulatorKeyboard.letterA, .press, on: target)
            client.key(SimulatorKeyboard.leftControl, .up, on: target)
            await Self.wait(Self.strokeTime)
            return
        }
        client.key(usage, .press, on: target)
        await Self.wait(Self.strokeTime)
    }

    /// Puts the text on the device's clipboard and has the device paste it (scrcpy's set-clipboard message with its
    /// paste flag), then puts back the text the clipboard held, or empty text when it held none: the device reads it
    /// as a paste of its own, in any language, whatever its keyboard.
    func paste(_ text: String, on device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        let (client, target) = try attached(device)
        do {
            let earlier = try await client.clipboard(of: target)
            try await client.setClipboard(text, paste: true, on: target)
            await Self.wait(Self.pasteSettle)
            try await client.setClipboard(earlier ?? "", paste: false, on: target)
        } catch let error as ScrcpyProtocolError {
            throw SimulatorDriveError(message: error.description)
        }
    }

    /// ASCII text as key events the device makes from it with its own key map (scrcpy's text injection).
    func typeKeys(_ text: String, on device: SimulatorDevice) async throws {
        let (client, target) = try attached(device)
        guard SimulatorKeyboardText(text) != nil else {
            throw SimulatorDriveError(message: "the hardware keyboard types ASCII text of at most 1,000 characters")
        }
        do {
            try client.type(text, on: target)
        } catch let error as ScrcpyProtocolError {
            throw SimulatorDriveError(message: error.description)
        }
        await Self.wait(Self.strokeTime + Double(text.utf8.count) * 0.005)
    }

    func release(_ device: SimulatorDevice) {
        screens.releaseForTools(device.identity)
    }

    // MARK: - Private

    /// `android.view.KeyEvent` codes of the buttons without a navigation key of their own.
    private static let power: UInt32 = 26 // KEYCODE_POWER
    private static let volumeUp: UInt32 = 24 // KEYCODE_VOLUME_UP
    private static let volumeDown: UInt32 = 25 // KEYCODE_VOLUME_DOWN

    private func attached(_ device: SimulatorDevice) throws -> (AndroidScreenClient, AndroidScreenTarget) {
        try Self.checkAndroid(device)
        guard let stream = screens.androidStream(of: device.identity) else {
            throw SimulatorDriveError(message: SimulatorScreenFailure.lost.toolReason)
        }
        return stream
    }

    private static func checkAndroid(_ device: SimulatorDevice) throws {
        guard device.platform == .android else {
            throw SimulatorDriveError(message: "\(device.name) is not an Android device")
        }
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded())))
    }
}
