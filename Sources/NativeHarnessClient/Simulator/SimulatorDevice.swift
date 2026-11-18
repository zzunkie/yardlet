import Foundation

/// The platform a simulated or connected device runs.
enum SimulatorPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case iOS
    case android
}

/// What kind of device it is, which decides how it is told apart from others, how its boot is recognized and how
/// long a person's approval to use it is remembered.
enum SimulatorDeviceKind: String, Codable, Hashable, Sendable {
    /// An iOS simulator, known by its UDID.
    case iOSSimulator
    /// An Android emulator, known by its AVD's name.
    case androidEmulator
    /// An Android phone or tablet over USB or `adb connect`, known by the serial number the device itself reports
    /// (`ro.serialno`), never by adb's serial: a wireless port changes each time and another device can take it.
    case androidDevice

    var platform: SimulatorPlatform {
        switch self {
        case .iOSSimulator: .iOS
        case .androidEmulator, .androidDevice: .android
        }
    }

    /// A real device, which has a person's own accounts signed in.
    var isPhysical: Bool { self == .androidDevice }

    /// Whether an approval to use the device holds for every task, or only for the task it was given in. A real
    /// device's would otherwise let any later task, a scheduled run's or one that asks nothing, reach a phone signed
    /// in to real accounts.
    var approvalHoldsForEveryTask: Bool { !isPhysical }
}

/// The same device across boots, restarts of Yardlet and changes of adb serial: what a task's attachment, an
/// approval and the record of the devices Yardlet started name.
struct SimulatorDeviceIdentity: Codable, Hashable, Sendable {
    var kind: SimulatorDeviceKind
    /// The UDID, the AVD's name or the device's own serial number, by `kind`.
    var value: String

    static func iOSSimulator(udid: String) -> Self { Self(kind: .iOSSimulator, value: udid.uppercased()) }
    static func androidEmulator(avd: String) -> Self { Self(kind: .androidEmulator, value: avd) }
    static func androidDevice(serialNumber: String) -> Self { Self(kind: .androidDevice, value: serialNumber) }
}

/// One boot of a device: what tells the device Yardlet started from the same device started again, elsewhere or
/// after a restart, so Yardlet never stops a boot that is not its own. A process ID alone repeats after the Mac
/// restarts, so the process's start time goes with it where the platform can read it.
struct SimulatorBootIdentity: Codable, Hashable, Sendable {
    /// An iOS simulator's `launchd_sim`, or an Android emulator's own process.
    var processID: Int32
    /// When that process started, in microseconds since 1970; nil where it cannot be read.
    var processStartMicroseconds: Int64?
    /// The AVD an Android emulator process runs.
    var avdName: String?
}

/// Whether a device runs.
enum SimulatorDeviceState: String, Codable, Hashable, Sendable {
    case off
    case booting
    case on
    case shuttingDown

    /// On, or on its way.
    var isRunning: Bool { self == .on || self == .booting }
}

/// A device a platform lists.
struct SimulatorDevice: Equatable, Sendable, Identifiable {
    var identity: SimulatorDeviceIdentity
    var name: String
    var state: SimulatorDeviceState
    /// The OS it runs, as people name it ("iOS 27.2").
    var osName: String
    /// The OS version alone ("27.2"), for ordering.
    var osVersion: String
    /// The iOS runtime's identifier; nil for Android.
    var runtimeIdentifier: String? = nil
    /// The serial adb knows a running Android device by ("emulator-5554"); nil for iOS and for an AVD that is off.
    var adbSerial: String? = nil

    var id: SimulatorDeviceIdentity { identity }
    var platform: SimulatorPlatform { identity.kind.platform }

    /// What a task's tools hand to the agent's own build and install tools: the UDID, the running Android device's
    /// adb serial, else the AVD's name.
    var toolID: String { adbSerial ?? identity.value }
}

/// Whether a platform's devices can be used on this computer.
enum SimulatorAvailability: Equatable, Sendable {
    case available
    /// No full Xcode: none selected and none in /Applications, or only the Command Line Tools.
    case xcodeMissing
    /// Xcode is there, but the simulator framework it installs on its first launch is not
    /// (`/Library/Developer/PrivateFrameworks/CoreSimulator.framework`).
    case xcodeNotSetUp
    /// No iOS runtime is installed.
    case runtimeMissing
    /// The devices list and start, but the simulator host cannot show this Xcode's screens yet.
    case xcodeNotSupportedYet(xcodeVersion: String?)
    /// No Android SDK with adb and the emulator.
    case sdkMissing

    /// Whether the platform's devices can be listed, started and stopped.
    var listsDevices: Bool {
        switch self {
        case .available, .xcodeNotSupportedYet: true
        case .xcodeMissing, .xcodeNotSetUp, .runtimeMissing, .sdkMissing: false
        }
    }
}

/// What a platform's devices are run with: the Xcode's developer folder, which the simulator host is also handed,
/// or the Android SDK's folder.
struct SimulatorToolchain: Equatable, Sendable {
    var directory: String
    /// Xcode's version ("27.2"); nil for Android.
    var version: String? = nil
}

/// What a platform's check found.
struct SimulatorPlatformCheck: Equatable, Sendable {
    var availability: SimulatorAvailability
    /// Set whenever devices can be listed.
    var toolchain: SimulatorToolchain?
}

/// How a boot command went.
enum SimulatorBootStart: Equatable, Sendable {
    /// The command started the device.
    case started
    /// The device was already on, started elsewhere: it is not Yardlet's to stop.
    case alreadyOn
}

/// A device command that failed, with the line worth showing.
struct SimulatorCommandError: Error, Equatable, Sendable {
    var message: String
}

/// One platform's devices: listing, starting, stopping and recognizing a boot. The Mac's iOS simulators run through
/// `xcrun simctl` (Platform/macOS); Android's emulators and devices through adb, on every platform.
protocol SimulatorBackend: Sendable {
    var platform: SimulatorPlatform { get }
    /// Whether the platform can be used, and with what. Runs off the main thread.
    func check() async -> SimulatorPlatformCheck
    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice]
    /// Starts the device without a window, returning once the command does, before the device is ready.
    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart
    /// Returns once a device that is starting is ready to use; throws when it is not ready in time.
    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws
    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws
    /// The boot the device runs now; nil when it is off or its boot cannot be read.
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity?
}
