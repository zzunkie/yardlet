import Foundation
@testable import NativeHarnessClient
import XCTest

final class AndroidSimulatorTests: XCTestCase {
    func testFindsTheSDKAndListsEmulatorsWithoutTouchingRealDevices() async throws {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let candidates = AndroidSDKLocator.candidates(
            environment: ["ANDROID_SDK_ROOT": "/opt/android"], loginShellPath: "/usr/bin:/srv/sdk/platform-tools:/bin",
            home: home)
        XCTAssertEqual(candidates.map(\.nativePath).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 },
                       ["/opt/android", "/srv/sdk", "/Users/test/Library/Android/sdk"])
        let found = AndroidSDKLocator.locate(environment: [:], loginShellPath: "/srv/sdk/emulator", home: home,
                                             isExecutable: { $0.nativePath.hasPrefix("/srv/sdk/") })
        XCTAssertEqual(found?.adb.nativePath, "/srv/sdk/platform-tools/adb")

        let listed = AndroidDeviceList.adbDevices("""
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:9
            TESTSERIAL01           device usb:1-1 product:test model:Test_Phone device:test transport_id:1
            TESTSERIAL02           unauthorized usb:1-2 transport_id:2
            emulator-5556          offline transport_id:3
            TESTSERIAL03           no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html] usb:1-3 transport_id:4

            """)
        XCTAssertEqual(listed.map(\.serial), ["emulator-5554", "TESTSERIAL01", "TESTSERIAL02", "emulator-5556", "TESTSERIAL03"])
        XCTAssertEqual(listed.map(\.state), [.device, .device, .unauthorized, .offline, .other("no permissions")])
        XCTAssertEqual(listed.map(\.emulatorPort), [5554, nil, nil, 5556, nil])
        XCTAssertEqual(listed[1].properties["model"], "Test_Phone")
        XCTAssertEqual(AndroidDeviceList.avdNames("INFO    | Storing crashdata in: /tmp/x\nTest_AVD\nOther.avd-2\n"),
                       ["Test_AVD", "Other.avd-2"])
        XCTAssertEqual(AndroidDeviceList.apiLevel(target: "android-34"), "34")
        XCTAssertEqual(AndroidDeviceList.apiLevel(target: "system-images/android-36/google_apis/arm64-v8a/"), "36")
        XCTAssertEqual(AndroidDeviceList.consoleValue("Test_AVD\r\nOK\r\n"), "Test_AVD")
        XCTAssertEqual(AndroidDeviceList.processID(discoveryPath: "/tmp/avd/running/pid_46118.ini"), 46118)

        // Two AVDs, one running elsewhere on 5554; the real device never gets a command.
        let runner = ScriptedCommands { command in
            switch command.arguments {
            case ["-list-avds"]: "Test_AVD\nOff_AVD\n"
            case ["devices", "-l"]: "List of devices attached\nemulator-5554 device transport_id:9\nTESTSERIAL01 device usb:1-1\n"
            case ["-s", "emulator-5554", "emu", "avd", "name"]: "Test_AVD\nOK\n"
            default: nil
            }
        }
        let avds = FileManager.default.temporaryDirectory.appending(path: "avds-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: avds) }
        try FileManager.default.createDirectory(at: avds.appending(path: "Test_AVD.avd"), withIntermediateDirectories: true)
        try Data("path=\(avds.appending(path: "Test_AVD.avd").nativePath)\ntarget=android-34\n".utf8)
            .write(to: avds.appending(path: "Test_AVD.ini"))
        try Data("avd.ini.displayname=Test Phone API 34\n".utf8).write(to: avds.appending(path: "Test_AVD.avd/config.ini"))
        let backend = AndroidEmulatorBackend(runner: runner, launcher: NoLaunches(), avdHome: { avds })
        let devices = try await backend.devices(with: SimulatorToolchain(directory: "/srv/sdk"))
        XCTAssertEqual(devices.map(\.name), ["Test Phone API 34", "Off AVD"])
        XCTAssertEqual(devices.map(\.state), [.on, .off])
        XCTAssertEqual(devices.map(\.toolID), ["emulator-5554", "Off_AVD"])
        XCTAssertEqual(devices[0].osName, "Android API 34")
        XCTAssertFalse(runner.commands.contains { $0.arguments.contains("TESTSERIAL01") })
        let start = try await backend.boot(devices[0], with: SimulatorToolchain(directory: "/srv/sdk"))
        XCTAssertEqual(start, .alreadyOn)

        let arguments = AndroidEmulatorBackend.launchArguments(avd: "Test_AVD", port: 5600)
        XCTAssertEqual(arguments, ["-avd", "Test_AVD", "-no-window", "-gpu", "host", "-no-boot-anim", "-no-audio",
                                   "-port", "5600"])
        XCTAssertFalse(arguments.contains("-read-only"))
    }

    func testEncodesControlMessagesAndReadsTheVideoStreamInAnyPieces() throws {
        let position = ScrcpyPosition(x: 100, y: 200, screenWidth: 1080, screenHeight: 2400)
        XCTAssertEqual([UInt8](ScrcpyControlMessage.touch(.down, pointer: ScrcpyControlMessage.fingerPointer,
                                                          at: position, pressure: 1).encoded),
                       [2, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0, 0, 0, 100, 0, 0, 0, 200, 0x04, 0x38,
                        0x09, 0x60, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](ScrcpyControlMessage.scroll(at: position, horizontal: 0, vertical: -1).encoded).suffix(8),
                       [0, 0, 0xF8, 0x00, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](ScrcpyControlMessage.key(.down, keycode: 3).encoded),
                       [0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
        // Cut at a character: 299 bytes, as the next character takes three.
        let cut = ScrcpyControlMessage.text(String(repeating: "a", count: 299) + "가").encoded
        XCTAssertEqual(cut.count, 1 + 4 + 299)
        XCTAssertEqual([UInt8](ScrcpyControlMessage.setClipboard("hi", sequence: 7, paste: true).encoded),
                       [9, 0, 0, 0, 0, 0, 0, 0, 7, 1, 0, 0, 0, 2, 0x68, 0x69])
        XCTAssertEqual([UInt8](ScrcpyControlMessage.resetVideo.encoded), [17])

        var stream = Data([0x68, 0x32, 0x36, 0x34])
        stream.append(header(0, size: 0, session: (1080, 2400)))
        stream.append(header(1 << 62, size: 5))
        stream.append(contentsOf: [1, 2, 3, 4, 5])
        stream.append(header(1 << 61 | 1234, size: 3))
        stream.append(contentsOf: [6, 7, 8])
        var reader = ScrcpyVideoStreamReader()
        var events: [ScrcpyVideoEvent] = []
        var offset = 0
        for size in [3, 1, 7, 11, 2, 30] where offset < stream.count {
            events += try reader.read(stream.subdata(in: offset..<min(offset + size, stream.count)))
            offset += size
        }
        XCTAssertEqual(events, [.session(width: 1080, height: 2400),
                                .packet(Data([1, 2, 3, 4, 5]), presentationMicroseconds: nil, isKeyFrame: false),
                                .packet(Data([6, 7, 8]), presentationMicroseconds: 1234, isKeyFrame: true)])
        var refused = ScrcpyVideoStreamReader()
        XCTAssertThrowsError(try refused.read(Data([0, 0, 0, 1])))

        XCTAssertNil(try ScrcpyDeviceMessage.parse(Data([0, 0, 0, 0, 3, 0x61])))
        let (clipboard, length) = try XCTUnwrap(ScrcpyDeviceMessage.parse(Data([0, 0, 0, 0, 2, 0x6F, 0x6B, 1])))
        XCTAssertEqual(clipboard, .clipboard("ok"))
        XCTAssertEqual(length, 7)
    }

    func testASessionConnectsInTheServersOrderAndCleansUp() async throws {
        let runner = ScriptedCommands { $0.arguments.contains("tcp:0") ? "41234\n" : "" }
        let video = ScriptedSocket(reads: [Data([0]) + Data("Test Phone".utf8) + Data(count: 54) + Data([0x68, 0x32]),
                                           Data([0x36, 0x34]) + header(0, size: 0, session: (720, 1280))])
        let control = ScriptedSocket(reads: [])
        let sockets = ScriptedSockets([video, control])
        let server = RunningServer()
        let session = ScrcpySession(adb: URL(filePath: "/srv/sdk/platform-tools/adb"), serial: "emulator-5600",
                                    serverFile: URL(filePath: "/tmp/scrcpy-server"), runner: runner, sockets: sockets,
                                    startServer: { _, arguments in
                                        server.arguments = arguments
                                        return server
                                    }, checkServerFile: { _ in })
        let received = Received()
        try await session.start(video: { received.add($0) })
        try await waitUntil { received.events == [.session(width: 720, height: 1280)] }
        let name = await session.deviceName
        XCTAssertEqual(name, "Test Phone")
        XCTAssertTrue(server.arguments.contains("5.0.1"))
        XCTAssertTrue(server.arguments.contains("tunnel_forward=true"))
        XCTAssertTrue(server.arguments.contains("audio=false"))

        try await session.send(.key(.down, keycode: 4))
        XCTAssertEqual(control.written, [ScrcpyControlMessage.key(.down, keycode: 4).encoded])
        // Once connected the tunnel goes; at the end the server and the sockets do.
        let removals = runner.commands.filter { $0.arguments.contains("--remove") }
        XCTAssertEqual(removals.map(\.arguments), [["-s", "emulator-5600", "forward", "--remove", "tcp:41234"]])
        await session.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertTrue(video.closed && control.closed)
    }

    private func header(_ flags: UInt64, size: UInt32, session: (Int, Int)? = nil) -> Data {
        var data = Data()
        if let session {
            data.append(contentsOf: [0x80, 0, 0, 0])
            for value in [UInt32(session.0), UInt32(session.1)] { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
            return data
        }
        withUnsafeBytes(of: flags.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: size.bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}

/// Answers each command with `answer`'s output, or fails it; keeps every command.
private final class ScriptedCommands: CLICommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: @Sendable (CLICommand) -> String?
    private var received: [CLICommand] = []

    init(_ answer: @escaping @Sendable (CLICommand) -> String?) { self.answer = answer }

    var commands: [CLICommand] { lock.withLock { received } }

    func run(_ command: CLICommand) async -> CLICommandResult {
        lock.withLock { received.append(command) }
        guard let output = answer(command) else { return CLICommandResult(exitCode: 1, stdout: "", stderr: "no script") }
        return CLICommandResult(exitCode: 0, stdout: output, stderr: "")
    }
}

private struct NoLaunches: AndroidEmulatorLaunching {
    func launch(_ executable: URL, arguments: [String]) throws -> Int32 { throw SimulatorCommandError(message: "no") }
    func hasEnded(_ processID: Int32) -> Bool? { nil }
}

private final class ScriptedSocket: LoopbackSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data]
    private var writes: [Data] = []
    private var isClosed = false
    private var waiting: CheckedContinuation<Data, Error>?

    init(reads: [Data]) { self.reads = reads }

    var written: [Data] { lock.withLock { writes } }
    var closed: Bool { lock.withLock { isClosed } }

    /// The scripted reads, then a wait until closed.
    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !reads.isEmpty { return continuation.resume(returning: reads.removeFirst()) }
                if isClosed { return continuation.resume(returning: Data()) }
                waiting = continuation
            }
        }
    }

    func write(_ data: Data) async throws { lock.withLock { writes.append(data) } }

    func close() {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            isClosed = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: Data())
    }
}

private final class ScriptedSockets: LoopbackSocketOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [ScriptedSocket]

    init(_ sockets: [ScriptedSocket]) { self.sockets = sockets }

    func open(port: Int) async throws -> any LoopbackSocket {
        try lock.withLock {
            guard port == 41234, !sockets.isEmpty else { throw ScrcpyProtocolError("refused") }
            return sockets.removeFirst()
        }
    }
}

private final class RunningServer: ScrcpyServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var startedWith: [String] = []

    var arguments: [String] {
        get { lock.withLock { startedWith } }
        set { lock.withLock { startedWith = newValue } }
    }

    var isRunning: Bool { lock.withLock { running } }
    var output: String { "" }
    func terminate() { lock.withLock { running = false } }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScrcpyVideoEvent] = []

    var events: [ScrcpyVideoEvent] { lock.withLock { all } }
    func add(_ event: ScrcpyVideoEvent) { lock.withLock { all.append(event) } }
}
