import Darwin
import Foundation

/// The Mac's iOS simulators, through the selected or newest Xcode's `simctl`. Simulator.app is never opened: a
/// device boots without a window, and the simulator host shows its screen in the panel.
///
/// xcode-select is never changed; an Xcode other than the selected one is named to `xcrun` with `DEVELOPER_DIR`.
/// `simctl` runs only once that Xcode's first launch is done (`xcodebuild -checkFirstLaunchStatus`), as Xcode's
/// `simctl` would otherwise start the first launch's installation itself.
struct MacIOSSimulatorBackend: SimulatorBackend {
    var runner: any CLICommandRunning = LiveCLICommandRunner()
    var applicationsFolder = URL(filePath: "/Applications", directoryHint: .isDirectory)
    var coreSimulatorFramework = URL(filePath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework")

    var platform: SimulatorPlatform { .iOS }

    func check() async -> SimulatorPlatformCheck {
        let selected = await runner.run(CLICommand(executable: URL(filePath: "/usr/bin/xcode-select"),
                                                   arguments: ["-p"], timeout: .seconds(10)))
        let selectedPath = selected.succeeded ? selected.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard let xcode = XcodeLocator.choose(selected: selectedPath,
                                              installs: XcodeLocator.installs(in: applicationsFolder)) else {
            return SimulatorPlatformCheck(availability: .xcodeMissing)
        }
        var directory = xcode.developerDirectory.path(percentEncoded: false)
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        let toolchain = SimulatorToolchain(directory: directory, version: xcode.version)
        let firstLaunch = await runner.run(CLICommand(
            executable: xcode.developerDirectory.appending(path: "usr/bin/xcodebuild"),
            arguments: ["-checkFirstLaunchStatus"], timeout: .seconds(30)))
        guard firstLaunch.succeeded,
              FileManager.default.fileExists(atPath: coreSimulatorFramework.path(percentEncoded: false)) else {
            return SimulatorPlatformCheck(availability: .xcodeNotSetUp)
        }
        let runtimes = await simctl(["list", "runtimes", "-j"], with: toolchain, timeout: .seconds(30))
        guard runtimes.succeeded, let listed = try? SimctlList.runtimes(from: Data(runtimes.stdout.utf8)) else {
            return SimulatorPlatformCheck(availability: .xcodeNotSetUp)
        }
        guard listed.contains(where: { $0.isAvailable && $0.isIOS }) else {
            return SimulatorPlatformCheck(availability: .runtimeMissing, toolchain: toolchain)
        }
        return SimulatorPlatformCheck(availability: .available, toolchain: toolchain)
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] {
        let result = await simctl(["list", "devices", "-j"], with: toolchain, timeout: .seconds(30))
        guard result.succeeded else { throw SimulatorCommandError(message: result.failureSummary) }
        do {
            return try SimctlList.devices(from: Data(result.stdout.utf8))
        } catch {
            throw SimulatorCommandError(message: "simctl list: \(error.localizedDescription)")
        }
    }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart {
        let result = await simctl(["boot", device.identity.value], with: toolchain, timeout: .seconds(120))
        if result.succeeded { return .started }
        // `simctl` answers a device already on, or starting, with "Unable to boot device in current state: Booted".
        if result.stderr.contains("current state: Boot") { return .alreadyOn }
        throw SimulatorCommandError(message: result.failureSummary)
    }

    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        // `bootstatus` waits for a device that is off to be started by someone, so it runs only after a boot, and
        // never longer than a first boot after a new runtime's data migration takes.
        let result = await simctl(["bootstatus", device.identity.value], with: toolchain, timeout: .seconds(300))
        guard result.succeeded else { throw SimulatorCommandError(message: result.failureSummary) }
    }

    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        // Short: the quit waits for it. A device stops in about four seconds.
        let result = await simctl(["shutdown", device.identity.value], with: toolchain, timeout: .seconds(20))
        guard result.succeeded || result.stderr.contains("current state: Shutdown") else {
            throw SimulatorCommandError(message: result.failureSummary)
        }
    }

    /// A new device of the original's device type and runtime, in the default device set beside the person's own:
    /// Xcode's build and run (`xcodebuild -destination id=<UDID>`) and `simctl` without `--set` find only devices
    /// there, and the agent hands the copy's UDID to them. Its name says Yardlet made it; `deleteCopy` removes it.
    func makeCopy(of device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorDevice {
        guard let type = device.deviceTypeIdentifier, let runtime = device.runtimeIdentifier else {
            throw SimulatorCommandError(message: "simctl did not list \(device.name)'s device type")
        }
        let name = Self.copyName(of: device.name)
        let result = await simctl(["create", name, type, runtime], with: toolchain, timeout: .seconds(60))
        let udid = result.stdout.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard result.succeeded, UUID(uuidString: udid) != nil else {
            throw SimulatorCommandError(message: result.failureSummary)
        }
        return SimulatorDevice(identity: .iOSSimulator(udid: udid), name: name, state: .off, osName: device.osName,
                               osVersion: device.osVersion, runtimeIdentifier: runtime, deviceTypeIdentifier: type)
    }

    func deleteCopy(_ device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async throws {
        guard device.kind == .iOSSimulator else { return }
        _ = await simctl(["shutdown", device.value], with: toolchain, timeout: .seconds(20))
        let result = await simctl(["delete", device.value], with: toolchain, timeout: .seconds(60))
        // A copy already gone, removed in Xcode, is as good as deleted.
        guard result.succeeded || result.stderr.contains("Invalid device") else {
            throw SimulatorCommandError(message: result.failureSummary)
        }
    }

    /// "iPhone 17 (Yardlet)": the name Xcode's list shows while the copy exists.
    static func copyName(of name: String) -> String { "\(name) (Yardlet)" }

    /// The device's `launchd_sim`: CoreSimulator runs each booted device as a launchd job of the person's own,
    /// `com.apple.CoreSimulator.SimDevice.<UDID>`, whose process is the device's `launchd_sim`, and removes the job
    /// when the device stops. The process's start time goes with its ID, which repeats after the Mac restarts.
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? {
        guard device.kind == .iOSSimulator else { return nil }
        let result = await runner.run(CLICommand(executable: URL(filePath: "/bin/launchctl"),
            arguments: ["list", "com.apple.CoreSimulator.SimDevice.\(device.value)"], timeout: .seconds(10)))
        guard result.succeeded, let processID = SimctlList.launchdJobProcessID(result.stdout),
              let process = MacProcessStart.read(processID), process.name == "launchd_sim" else { return nil }
        return SimulatorBootIdentity(processID: processID, processStartMicroseconds: process.startMicroseconds)
    }

    private func simctl(_ arguments: [String], with toolchain: SimulatorToolchain,
                        timeout: Duration) async -> CLICommandResult {
        await runner.run(CLICommand(executable: URL(filePath: "/usr/bin/xcrun"), arguments: ["simctl"] + arguments,
                                    environment: ["DEVELOPER_DIR": toolchain.directory], timeout: timeout))
    }
}

/// An Xcode on this Mac.
struct XcodeInstall: Equatable, Sendable {
    var developerDirectory: URL
    /// Its version ("27.2"), from `Contents/version.plist`.
    var version: String?
}

/// Which Xcode the simulators run with: the one xcode-select names when it is a full Xcode, else the newest in
/// /Applications. The Command Line Tools have no simulators.
enum XcodeLocator {
    static func choose(selected: String?, installs: [XcodeInstall]) -> XcodeInstall? {
        if let selected, let install = install(developerDirectory: URL(filePath: selected, directoryHint: .isDirectory)) {
            return install
        }
        return installs.max { left, right in
            SimulatorDeviceOrder.isNewer(right.version ?? "0", than: left.version ?? "0")
        }
    }

    /// The `Xcode*.app` in the folder, beta or not.
    static func installs(in applications: URL) -> [XcodeInstall] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().compactMap {
            install(developerDirectory: applications.appending(path: "\($0)/Contents/Developer", directoryHint: .isDirectory))
        }
    }

    /// The Xcode whose developer folder this is, when it is a full Xcode's, with `simctl`.
    static func install(developerDirectory: URL) -> XcodeInstall? {
        let contents = developerDirectory.deletingLastPathComponent()
        guard developerDirectory.lastPathComponent == "Developer", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              FileManager.default.isExecutableFile(
                atPath: developerDirectory.appending(path: "usr/bin/simctl").path(percentEncoded: false)) else { return nil }
        let plist = (try? Data(contentsOf: contents.appending(path: "version.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return XcodeInstall(developerDirectory: developerDirectory,
                            version: plist?["CFBundleShortVersionString"] as? String)
    }
}

/// `simctl list`'s JSON.
enum SimctlList {
    struct Runtime: Decodable, Equatable {
        var identifier: String
        var name: String
        var version: String
        var platform: String?
        var isAvailable: Bool

        var isIOS: Bool { platform == "iOS" || (platform == nil && identifier.contains(".SimRuntime.iOS-")) }
    }

    private struct Device: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool?
        var deviceTypeIdentifier: String?
    }

    private struct Listing: Decodable {
        var devices: [String: [Device]]?
        var runtimes: [Runtime]?
    }

    static func runtimes(from data: Data) throws -> [Runtime] {
        try JSONDecoder().decode(Listing.self, from: data).runtimes ?? []
    }

    /// `simctl list devices -j`: the available devices of the iOS runtimes, by runtime, newest first, each runtime's
    /// in `simctl`'s order. A device of a runtime that is missing or not available is not available itself.
    static func devices(from data: Data) throws -> [SimulatorDevice] {
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let runtimes = (listing.devices ?? [:]).compactMap { key, devices -> (identifier: String, version: String, [Device])? in
            iOSVersion(ofRuntime: key).map { (key, $0, devices) }
        }.sorted { SimulatorDeviceOrder.isNewer($0.version, than: $1.version) }
        return runtimes.flatMap { identifier, version, devices in
            devices.filter { $0.isAvailable ?? true }.map {
                SimulatorDevice(identity: .iOSSimulator(udid: $0.udid), name: $0.name, state: state($0.state),
                                osName: "iOS \(version)", osVersion: version, runtimeIdentifier: identifier,
                                deviceTypeIdentifier: $0.deviceTypeIdentifier)
            }
        }
    }

    /// "27.2" for `com.apple.CoreSimulator.SimRuntime.iOS-27-2`; nil for another platform's runtime.
    static func iOSVersion(ofRuntime identifier: String) -> String? {
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: "-")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.joined(separator: ".")
    }

    static func state(_ value: String) -> SimulatorDeviceState {
        switch value {
        case "Booted": .on
        case "Booting": .booting
        case "Shutting Down": .shuttingDown
        default: .off
        }
    }

    /// The `"PID" = 1234;` line of `launchctl list <label>`, which a job that is not running has none of.
    static func launchdJobProcessID(_ output: String) -> Int32? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"PID\" = ") else { continue }
            let digits = trimmed.dropFirst("\"PID\" = ".count).prefix { $0.isNumber }
            return Int32(digits).flatMap { $0 > 0 ? $0 : nil }
        }
        return nil
    }
}

/// A process's name and start time, from the kernel (`proc_pidinfo`, `PROC_PIDTBSDINFO`).
enum MacProcessStart {
    static func read(_ processID: Int32) -> (name: String, startMicroseconds: Int64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let command = withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (name.isEmpty ? command : name,
                Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
    }
}
