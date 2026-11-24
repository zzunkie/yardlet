import Foundation

/// Starts an emulator, which runs on after the command that started it: the `emulator` program becomes the
/// emulator's own process (`qemu-system-*`) under the same process ID.
protocol AndroidEmulatorLaunching: Sendable {
    /// Starts it without input or output, with these variables over Yardlet's own, and returns its process ID.
    func launch(_ executable: URL, arguments: [String], environment: [String: String]) throws -> Int32
    /// Whether a process this launcher started has ended; nil for one it did not start.
    func hasEnded(_ processID: Int32) -> Bool?
    /// Ends a process this launcher started: a copy let go of before adb reaches its console.
    func terminate(_ processID: Int32)
}

extension AndroidEmulatorLaunching {
    func terminate(_ processID: Int32) {}
}

/// The emulators this Yardlet started, one entry for each start, so an ended one still answers.
final class LiveAndroidEmulatorLauncher: AndroidEmulatorLaunching, @unchecked Sendable {
    static let shared = LiveAndroidEmulatorLauncher()

    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    func launch(_ executable: URL, arguments: [String], environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // No pipe: a pipe would end the emulator with Yardlet, before Yardlet's own stop at quit or its next start.
        process.standardInput = FileHandle.childNullDevice()
        process.standardOutput = FileHandle.childNullDevice()
        process.standardError = FileHandle.childNullDevice()
        process.environment = RuntimeProcessEnvironment.values(executableURL: executable, overrides: environment)
        try NativeProcessTree.run(process)
        let processID = process.processIdentifier
        lock.withLock { processes[processID] = process }
        return processID
    }

    func hasEnded(_ processID: Int32) -> Bool? {
        lock.withLock { processes[processID].map { !$0.isRunning } }
    }

    func terminate(_ processID: Int32) {
        lock.withLock { processes[processID] }?.terminate()
    }
}

/// Android emulators and devices, through the person's own SDK. Emulators: AVDs from `emulator -list-avds`, the
/// running ones from `adb devices -l`, each started without a window (`emulator -avd <name> -no-window -gpu host
/// -no-boot-anim -no-audio -port <port>`), ready once `sys.boot_completed` is set, and stopped with `adb emu kill`,
/// which keeps the quick-boot snapshot as Android Studio's stop does. An AVD is never started read-only, so what is
/// installed on it stays, as in Android Studio. An AVD already running elsewhere is used where it runs and not
/// started again.
///
/// Real devices: the phones and tablets adb lists ready, over USB or `adb connect`, each known by the serial number it
/// reports (`ro.serialno`), never by adb's serial, which a wireless connection changes. Yardlet never turns one on or
/// off; one that is unauthorized or offline is not listed, as nothing can be read from it.
///
/// Copies (`makeCopy`): an AVD runs once unless every instance of it is read-only, and Android Studio's and Yardlet's
/// are not, so a task whose AVD another task uses gets a new AVD of the same hardware and system image instead, in
/// Yardlet's own AVD folder (`copiesHome`), which Android Studio's list never reads. It boots fresh, keeps no
/// snapshot, and `deleteCopy` removes its folder.
struct AndroidEmulatorBackend: SimulatorBackend {
    /// The start of a copy's AVD name, which only Yardlet's AVD folder holds.
    static let copyPrefix = "yardlet_copy_"

    /// The console ports the emulator takes, even ones; each emulator also takes the odd port above for adb.
    static let consolePorts = Array(stride(from: 5554, through: 5682, by: 2))

    var runner: any CLICommandRunning = LiveCLICommandRunner()
    var launcher: any AndroidEmulatorLaunching = LiveAndroidEmulatorLauncher.shared
    var processes: any ProcessTableReading = LiveProcessTable()
    var locateSDK: @Sendable () -> AndroidSDK? = { AndroidSDKLocator.locate() }
    var avdHome: @Sendable () -> URL = { AndroidSDKLocator.avdHome() }
    var readText: @Sendable (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    /// Yardlet's own AVD folder, holding the copies it made; nil makes none.
    var copiesHome: URL? = nil
    /// The console ports to start an emulator on, the first free one taken.
    var ports = AndroidEmulatorBackend.consolePorts
    /// How long to wait for a started emulator to be ready, and between looks.
    var readyTimeout: Duration = .seconds(300)
    var readyPollInterval: Duration = .seconds(1)
    private let launches = Launches()
    private let connections = Connections()

    var platform: SimulatorPlatform { .android }

    func check() async -> SimulatorPlatformCheck {
        guard let sdk = locateSDK() else { return SimulatorPlatformCheck(availability: .sdkMissing) }
        return SimulatorPlatformCheck(availability: .available, toolchain: sdk.toolchain)
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] {
        let sdk = AndroidSDK(toolchain: toolchain)
        async let avds = runner.run(CLICommand(executable: sdk.emulator, arguments: ["-list-avds"], timeout: .seconds(30)))
        let listed = try await adbDevices(sdk)
        let running = try await runningEmulators(sdk, listed: listed)
        let copies = copyNames()
        let names = (await avds.succeeded ? AndroidDeviceList.avdNames(avds.stdout) : []).filter { !copies.contains($0) }
        // An AVD running from another AVD folder is listed too: it can be used where it runs.
        let all = names + copies + running.keys.filter { !names.contains($0) && !copies.contains($0) }.sorted()
        let emulators = all.map { name in
            let home = home(of: name)
            let entry = AndroidDeviceList.iniValues(readText(home.appending(path: "\(name).ini")) ?? "")
            let config = entry["path"].flatMap {
                readText(URL(filePath: $0, directoryHint: .isDirectory).appending(path: "config.ini"))
            }.map(AndroidDeviceList.iniValues) ?? [:]
            let api = AndroidDeviceList.apiLevel(target: entry["target"] ?? config["image.sysdir.1"])
            let adb = running[name]
            // Listed by adb, it runs: ready once adb may use it. Offline, unauthorized or in another state it is still
            // on its way as far as Yardlet can tell, and an emulator Yardlet started stays counted as its own.
            let state: SimulatorDeviceState = switch adb?.state {
            case nil: .off
            case .device?: .on
            default: .booting
            }
            return SimulatorDevice(identity: .androidEmulator(avd: name),
                                   name: config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
                                   state: state, osName: api.map { "Android API \($0)" } ?? "Android",
                                   osVersion: api ?? "", adbSerial: adb?.serial)
        }
        return emulators + (await connectedDevices(listed, sdk: sdk))
    }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart {
        guard device.identity.kind == .androidEmulator else { throw Self.notTurnedOnOrOff }
        let sdk = AndroidSDK(toolchain: toolchain)
        let avd = device.identity.value
        let listed = try await adbDevices(sdk)
        // Already running, here or in Android Studio: an AVD runs once, so it is used where it runs.
        if try await runningEmulators(sdk, listed: listed)[avd] != nil { return .alreadyOn }
        // Taken under the record's lock, so two emulators starting at once never pick the same port.
        guard let port = launches.reservePort(for: avd, from: ports, excluding: Set(listed.compactMap(\.emulatorPort)))
        else { throw SimulatorCommandError(message: "No free emulator port between 5554 and 5682") }
        let processID: Int32
        do {
            let copy = isCopy(avd)
            processID = try launcher.launch(
                sdk.emulator, arguments: Self.launchArguments(avd: avd, port: port, isCopy: copy),
                environment: copy ? ["ANDROID_AVD_HOME": home(of: avd).nativePath] : [:])
        } catch {
            launches.remove(avd: avd)
            throw SimulatorCommandError(message: "The emulator did not start: \(error.localizedDescription)")
        }
        launches.add(avd: avd, port: port, processID: processID)
        return .started
    }

    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        guard device.identity.kind == .androidEmulator else { throw Self.notTurnedOnOrOff }
        let sdk = AndroidSDK(toolchain: toolchain)
        let avd = device.identity.value
        let deadline = ContinuousClock.now + readyTimeout
        while ContinuousClock.now < deadline {
            if let launched = launches.launch(of: avd), launcher.hasEnded(launched.processID) == true {
                launches.remove(avd: avd)
                throw SimulatorCommandError(message: "The emulator ended before it was ready")
            }
            if let serial = try await serial(of: avd, sdk: sdk) {
                let booted = await adb(sdk, serial, ["shell", "getprop", "sys.boot_completed"], timeout: .seconds(10))
                if booted.succeeded, booted.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            }
            try await Task.sleep(for: readyPollInterval)
        }
        throw SimulatorCommandError(message: "The emulator was not ready in time")
    }

    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        guard device.identity.kind == .androidEmulator else { throw Self.notTurnedOnOrOff }
        let sdk = AndroidSDK(toolchain: toolchain)
        let avd = device.identity.value
        guard let serial = try await serial(of: avd, sdk: sdk) else { return }
        let result = await adb(sdk, serial, ["emu", "kill"], timeout: .seconds(20))
        guard result.succeeded else { throw SimulatorCommandError(message: result.failureSummary) }
        // `emu kill` answers before the emulator has saved its snapshot and ended; wait for it to leave adb's list, and
        // for an emulator this Yardlet started, for its process to end, after which it writes nothing more.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if (try? await adbDevices(sdk))?.contains(where: { $0.serial == serial }) == false { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        while ContinuousClock.now < deadline, let launched = launches.launch(of: avd),
              launcher.hasEnded(launched.processID) == false {
            try await Task.sleep(for: .milliseconds(500))
        }
        launches.remove(avd: avd)
    }

    /// The emulator's process, its start time and its AVD: the process this Yardlet started, else the one the
    /// emulator's console names (`avd discoverypath`, whose file is named after the process).
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? {
        guard device.kind == .androidEmulator else { return nil }
        let sdk = AndroidSDK(toolchain: toolchain)
        let processID: Int32
        if let launched = liveLaunch(of: device.value) {
            processID = launched.processID
        } else {
            guard let serial = try? await runningEmulators(sdk)[device.value]?.serial else { return nil }
            let path = await adb(sdk, serial, ["emu", "avd", "discoverypath"], timeout: .seconds(10))
            guard path.succeeded, let found = AndroidDeviceList.consoleValue(path.stdout)
                .flatMap(AndroidDeviceList.processID(discoveryPath:)) else { return nil }
            processID = found
        }
        let start = processes.entries().first { $0.processID == processID }?.startMicroseconds
        return SimulatorBootIdentity(processID: processID, processStartMicroseconds: start, avdName: device.value)
    }

    /// The emulator's arguments: no window, so the person's screen is never taken; the Mac's GPU, as without a
    /// window the emulator otherwise draws in software; no audio, as the emulator would open the Mac's microphone,
    /// which asks the person for Yardlet's access, and the panel carries no sound. A copy keeps no snapshot: it is
    /// deleted once its task lets go of it, and a snapshot would take gigabytes meanwhile.
    static func launchArguments(avd: String, port: Int, isCopy: Bool = false) -> [String] {
        ["-avd", avd, "-no-window", "-gpu", "host", "-no-boot-anim", "-no-audio", "-port", String(port)]
            + (isCopy ? ["-no-snapshot"] : [])
    }

    // MARK: - Copies

    /// A new AVD in Yardlet's AVD folder with the original's `config.ini`: the same hardware profile and system
    /// image, its own name, no SD card image (which only the AVD manager makes), and a data partition the emulator
    /// makes from the system image on its first boot.
    func makeCopy(of device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorDevice {
        guard device.identity.kind == .androidEmulator, let copiesHome else {
            throw SimulatorCommandError(message: "Yardlet makes copies of emulators only")
        }
        let source = device.identity.value
        let sourceHome = home(of: source)
        let entry = AndroidDeviceList.iniValues(readText(sourceHome.appending(path: "\(source).ini")) ?? "")
        guard let path = entry["path"],
              let config = readText(URL(filePath: path, directoryHint: .isDirectory).appending(path: "config.ini"))
        else { throw SimulatorCommandError(message: "\(device.name)'s configuration can't be read") }
        let name = Self.copyPrefix + UUID().uuidString.prefix(8).lowercased()
        let folder = copiesHome.appending(path: "\(name).avd", directoryHint: .isDirectory)
        let displayName = Self.copyName(of: device.name)
        var lines = config.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return !["avd.ini.displayname", "hw.sdCard", "sdcard.size", "sdcard.path", "AvdId", "avd.id", "avd.name",
                     "disk.dataPartition.path"].contains(key ?? "")
        }
        lines += ["avd.ini.displayname=\(displayName)", "AvdId=\(name)", "hw.sdCard=no"]
        var ini = ["avd.ini.encoding=UTF-8", "path=\(folder.nativePath)"]
        if let target = entry["target"] { ini.append("target=\(target)") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appending(path: "config.ini"), atomically: true,
                                                            encoding: .utf8)
            try (ini.joined(separator: "\n") + "\n").write(to: copiesHome.appending(path: "\(name).ini"),
                                                          atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw SimulatorCommandError(message: "The copy of \(device.name) can't be written: \(error.localizedDescription)")
        }
        return SimulatorDevice(identity: .androidEmulator(avd: name), name: displayName, state: .off,
                               osName: device.osName, osVersion: device.osVersion)
    }

    func deleteCopy(_ device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async throws {
        guard device.kind == .androidEmulator, isCopy(device.value), let copiesHome else { return }
        let sdk = AndroidSDK(toolchain: toolchain)
        let copy = SimulatorDevice(identity: device, name: device.value, state: .on, osName: "", osVersion: "")
        if let launched = liveLaunch(of: device.value) {
            do {
                try await shutDown(copy, with: toolchain)
            } catch {
                // Started so recently that adb does not reach its console yet: its process is ended instead.
                launcher.terminate(launched.processID)
                let deadline = ContinuousClock.now + .seconds(30)
                while ContinuousClock.now < deadline, launcher.hasEnded(launched.processID) == false {
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard launcher.hasEnded(launched.processID) != false else {
                    throw SimulatorCommandError(message: "The copy's emulator did not end")
                }
                launches.remove(avd: device.value)
            }
        } else if try await serial(of: device.value, sdk: sdk) != nil {
            // An emulator of an earlier Yardlet: its files go only once it has stopped.
            try await shutDown(copy, with: toolchain)
        }
        for item in [copiesHome.appending(path: "\(device.value).avd", directoryHint: .isDirectory),
                     copiesHome.appending(path: "\(device.value).ini")]
            where FileManager.default.fileExists(atPath: item.nativePath) {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                throw SimulatorCommandError(message: "The copy can't be removed: \(error.localizedDescription)")
            }
        }
    }

    /// "Pixel 9 (Yardlet)": the name the copy shows.
    static func copyName(of name: String) -> String { "\(name) (Yardlet)" }

    /// The copies in Yardlet's AVD folder.
    func copyNames() -> [String] {
        guard let copiesHome,
              let items = try? FileManager.default.contentsOfDirectory(atPath: copiesHome.nativePath)
        else { return [] }
        return items.filter { $0.hasPrefix(Self.copyPrefix) && $0.hasSuffix(".ini") }
            .map { String($0.dropLast(4)) }.sorted()
    }

    private func isCopy(_ avd: String) -> Bool {
        copiesHome != nil && avd.hasPrefix(Self.copyPrefix)
    }

    /// The AVD folder an AVD is in: Yardlet's for a copy, else the person's.
    private func home(of avd: String) -> URL {
        if isCopy(avd), let copiesHome { return copiesHome }
        return avdHome()
    }

    private static let notTurnedOnOrOff = SimulatorCommandError(message: "Yardlet does not turn real devices on or off")

    // MARK: - Real devices

    /// The real devices adb lists ready for commands, in its order. Two connections that report the same serial number
    /// are one device, the first listed: emulators reached over `adb connect` report their version's.
    private func connectedDevices(_ listed: [AdbDevice], sdk: AndroidSDK) async -> [SimulatorDevice] {
        var devices: [SimulatorDevice] = []
        var connected: Set<String> = []
        for device in listed where device.emulatorPort == nil && device.state == .device {
            let connection = device.properties["transport_id"].map { "\(device.serial)\n\($0)" }
            if let connection { connected.insert(connection) }
            guard let found = await connectedDevice(device, connection: connection, sdk: sdk),
                  !devices.contains(where: { $0.identity == found.identity }) else { continue }
            devices.append(found)
        }
        connections.keep(connected)
        return devices
    }

    /// A real device, asked once for each connection (adb's transport, which a device that connects again, or another
    /// device at the same address, does not share): its serial number, name, Android version and API level.
    private func connectedDevice(_ device: AdbDevice, connection: String?, sdk: AndroidSDK) async -> SimulatorDevice? {
        if let connection, let known = connections.device(for: connection) { return known }
        let answer = await adb(sdk, device.serial, ["shell", AndroidDeviceList.connectedDeviceCommand],
                               timeout: .seconds(10))
        guard let properties = AndroidDeviceList.connectedDeviceProperties(answer.stdout) else { return nil }
        let found = SimulatorDevice(identity: .androidDevice(serialNumber: properties.serialNumber),
                                    name: properties.name, state: .on,
                                    osName: properties.release.isEmpty ? "Android" : "Android \(properties.release)",
                                    osVersion: properties.apiLevel, adbSerial: device.serial)
        if let connection { connections.set(found, for: connection) }
        return found
    }

    // MARK: - adb

    private func adbDevices(_ sdk: AndroidSDK) async throws -> [AdbDevice] {
        let result = await runner.run(CLICommand(executable: sdk.adb, arguments: ["devices", "-l"], timeout: .seconds(15)))
        guard result.succeeded else { throw SimulatorCommandError(message: result.failureSummary) }
        return AndroidDeviceList.adbDevices(result.stdout)
    }

    /// The emulators adb lists, by the AVD each runs: known for those this Yardlet started, asked of the others'
    /// consoles.
    private func runningEmulators(_ sdk: AndroidSDK, listed: [AdbDevice]? = nil) async throws -> [String: AdbDevice] {
        var running: [String: AdbDevice] = [:]
        let emulators: [AdbDevice]
        if let listed { emulators = listed } else { emulators = try await adbDevices(sdk) }
        for emulator in emulators {
            guard let port = emulator.emulatorPort else { continue }
            if let avd = launches.avd(onPort: port), liveLaunch(of: avd) != nil {
                running[avd] = emulator
                continue
            }
            let name = await adb(sdk, emulator.serial, ["emu", "avd", "name"], timeout: .seconds(10))
            if name.succeeded, let avd = AndroidDeviceList.consoleValue(name.stdout) { running[avd] = emulator }
        }
        return running
    }

    /// The serial of the emulator running the AVD: the port this Yardlet started it on, else adb's.
    private func serial(of avd: String, sdk: AndroidSDK) async throws -> String? {
        if let launched = liveLaunch(of: avd) { return "emulator-\(launched.port)" }
        return try await runningEmulators(sdk)[avd]?.serial
    }

    /// The emulator this Yardlet started for the AVD, while it runs; one that ended leaves the record, so its port
    /// names no other emulator later.
    private func liveLaunch(of avd: String) -> Launches.Launch? {
        // A port reserved for a launch not made yet is no running emulator.
        guard let launched = launches.launch(of: avd), launched.processID > 0 else { return nil }
        guard launcher.hasEnded(launched.processID) != true else {
            launches.remove(avd: avd)
            return nil
        }
        return launched
    }

    /// A command to one device: an emulator's console commands (`emu`) go only to an emulator's serial.
    private func adb(_ sdk: AndroidSDK, _ serial: String, _ arguments: [String], timeout: Duration) async -> CLICommandResult {
        await runner.run(CLICommand(executable: sdk.adb, arguments: ["-s", serial] + arguments, timeout: timeout))
    }

    /// The emulators this Yardlet started, by AVD.
    private final class Launches: @unchecked Sendable {
        struct Launch: Sendable {
            var port: Int
            var processID: Int32
        }

        private let lock = NSLock()
        private var launches: [String: Launch] = [:]

        var ports: Set<Int> { lock.withLock { Set(launches.values.map(\.port)) } }
        func launch(of avd: String) -> Launch? { lock.withLock { launches[avd] } }
        func avd(onPort port: Int) -> String? { lock.withLock { launches.first { $0.value.port == port }?.key } }
        func add(avd: String, port: Int, processID: Int32) {
            lock.withLock { launches[avd] = Launch(port: port, processID: processID) }
        }
        /// Holds the first port free of `excluding` and of the other launches for the AVD until it is launched.
        func reservePort(for avd: String, from ports: [Int], excluding taken: Set<Int>) -> Int? {
            lock.withLock {
                let held = taken.union(launches.filter { $0.key != avd }.map(\.value.port))
                guard let port = ports.first(where: { !held.contains($0) }) else { return nil }
                launches[avd] = Launch(port: port, processID: 0)
                return port
            }
        }
        func remove(avd: String) { lock.withLock { _ = launches.removeValue(forKey: avd) } }
    }

    /// The real devices read, by connection, while they stay connected.
    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [String: SimulatorDevice] = [:]

        func device(for connection: String) -> SimulatorDevice? { lock.withLock { devices[connection] } }
        func set(_ device: SimulatorDevice, for connection: String) { lock.withLock { devices[connection] = device } }
        func keep(_ connections: Set<String>) { lock.withLock { devices = devices.filter { connections.contains($0.key) } } }
    }
}
