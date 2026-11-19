import Foundation

/// A running device's screen in the units the agent's tools give coordinates in: points on iOS, dp on Android. Its
/// screenshots are this size, so a position in one is a position on the screen.
struct SimulatorToolScreen: Equatable, Sendable {
    var width: Int
    var height: Int
}

/// A point on a device's screen as a fraction of its width and height, from the top-left: what a platform's input
/// takes, whatever the screen's units.
struct SimulatorScreenFraction: Equatable, Sendable {
    var x: Double
    var y: Double

    /// The fraction of a point in the screen's units; nil outside the screen.
    init?(x: Double, y: Double, on screen: SimulatorToolScreen) {
        guard screen.width > 0, screen.height > 0, x.isFinite, y.isFinite,
              (0...Double(screen.width)).contains(x), (0...Double(screen.height)).contains(y) else { return nil }
        self.x = x / Double(screen.width)
        self.y = y / Double(screen.height)
    }

    init(fractionX x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

enum SimulatorToolTouchPhase: Sendable {
    case down
    case move
    case up
}

enum SimulatorToolImageFormat: String, Sendable {
    case png
    case jpeg
}

/// A device's screen as a picture, the screen's size in its units.
struct SimulatorToolImage: Sendable {
    var data: Data
    var format: SimulatorToolImageFormat
    var width: Int
    var height: Int
}

/// A hardware button `simulator_press` presses; each platform has its own.
enum SimulatorToolButton: String, CaseIterable, Sendable {
    case home
    case lock
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case action
    case back
    case recents
    case power
}

/// A key `simulator_press` presses in the focused field or view.
enum SimulatorToolKey: String, CaseIterable, Sendable {
    case returnKey = "return"
    case delete
    case tab
    case escape
    case space
    case up
    case down
    case left
    case right
    case selectAll = "select_all"
}

/// A device command that did not go out or failed, with the line worth showing the agent.
struct SimulatorDriveError: Error, Equatable, Sendable {
    var message: String
}

/// Shows and drives a platform's running devices for the agent's simulator tools (`SimulatorAgentTools`): the Mac's iOS
/// simulators through the simulator host (Platform/macOS), Android's through scrcpy. Input goes out in order.
@MainActor
protocol SimulatorDeviceDriving: AnyObject {
    /// The buttons the platform's devices have.
    var buttons: [SimulatorToolButton] { get }
    /// Makes the device ready for input and pictures, if it is not yet, and returns its screen. Called before every
    /// tool, so a device that shut down and started again, or a helper that ended, is taken up again.
    func prepare(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorToolScreen
    func screenshot(of device: SimulatorDevice, format: SimulatorToolImageFormat) async throws -> SimulatorToolImage
    func touch(_ phase: SimulatorToolTouchPhase, at point: SimulatorScreenFraction, on device: SimulatorDevice) throws
    /// Presses and lets go of a button, returning once the press is over.
    func press(_ button: SimulatorToolButton, on device: SimulatorDevice) async throws
    /// Presses and lets go of a key, with what it needs held, returning once the press is over.
    func press(_ key: SimulatorToolKey, on device: SimulatorDevice) async throws
    /// Puts the text on the device's clipboard, pastes it into the focused field, and puts back the text the
    /// clipboard held.
    func paste(_ text: String, on device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws
    /// Types ASCII text on the hardware keyboard, which the device reads with its own keyboard layout, returning once
    /// it is typed.
    func typeKeys(_ text: String, on device: SimulatorDevice) async throws
    /// The accessibility elements of the app in front, their frames in the screen's units.
    func snapshot(of device: SimulatorDevice) async throws -> SimulatorUITree
    /// The task's tools let go of the device.
    func release(_ device: SimulatorDevice)
}
