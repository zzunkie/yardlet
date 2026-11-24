import CoreMedia
import CoreVideo
import Foundation
@testable import NativeHarnessClient
import VideoToolbox
import XCTest
import YardletSimulatorHostProtocol

final class AndroidSimulatorTests: XCTestCase {
    func testFindsTheSDKAndListsEmulatorsAndRealDevicesByTheirOwnSerialNumbers() async throws {
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

        // Three AVDs, one running elsewhere on 5554 and one on 5556 that adb may not use yet, which is still starting;
        // a phone over USB and the same phone over Wi-Fi, known by the serial number it reports, not by adb's; and a
        // phone that has not allowed this Mac, which is asked nothing.
        let connected = Listing("emulator-5554 device transport_id:9\nTESTSERIAL01 device usb:1-1 transport_id:3\n"
            + "192.168.0.7:41234 device transport_id:4\nTESTSERIAL02 unauthorized usb:1-2 transport_id:5\n"
            + "emulator-5556 unauthorized transport_id:7\n")
        let runner = ScriptedCommands { command in
            switch command.arguments {
            case ["-list-avds"]: "Test_AVD\nOff_AVD\nStarting_AVD\n"
            case ["devices", "-l"]: "List of devices attached\n" + connected.value
            case ["-s", "emulator-5554", "emu", "avd", "name"]: "Test_AVD\nOK\n"
            case ["-s", "emulator-5556", "emu", "avd", "name"]: "Starting_AVD\nOK\n"
            case ["-s", "TESTSERIAL01", "shell", AndroidDeviceList.connectedDeviceCommand],
                 ["-s", "192.168.0.7:41234", "shell", AndroidDeviceList.connectedDeviceCommand]:
                "R5CT00TEST\nTest-Phone\n14\n34\nnull\n"
            default: nil
            }
        }
        func asked(_ serial: String) -> Int { runner.commands.filter { $0.arguments.starts(with: ["-s", serial, "shell"]) }.count }
        let avds = FileManager.default.temporaryDirectory.appending(path: "avds-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: avds) }
        try FileManager.default.createDirectory(at: avds.appending(path: "Test_AVD.avd"), withIntermediateDirectories: true)
        try Data("path=\(avds.appending(path: "Test_AVD.avd").nativePath)\ntarget=android-34\n".utf8)
            .write(to: avds.appending(path: "Test_AVD.ini"))
        try Data("avd.ini.displayname=Test Phone API 34\n".utf8).write(to: avds.appending(path: "Test_AVD.avd/config.ini"))
        let backend = AndroidEmulatorBackend(runner: runner, launcher: NoLaunches(), avdHome: { avds })
        let sdk = SimulatorToolchain(directory: "/srv/sdk")
        let devices = try await backend.devices(with: sdk)
        XCTAssertEqual(devices.map(\.name), ["Test Phone API 34", "Off AVD", "Starting AVD", "Test-Phone"])
        XCTAssertEqual(devices.map(\.state), [.on, .off, .booting, .on])
        XCTAssertEqual(devices.map(\.toolID), ["emulator-5554", "Off_AVD", "emulator-5556", "TESTSERIAL01"])
        XCTAssertEqual(devices.map(\.osName), ["Android API 34", "Android", "Android", "Android 14"])
        XCTAssertEqual(devices[3].identity, .androidDevice(serialNumber: "R5CT00TEST"))
        XCTAssertEqual(asked("TESTSERIAL02"), 0)
        let start = try await backend.boot(devices[0], with: sdk)
        XCTAssertEqual(start, .alreadyOn)
        // A real device is asked once a connection, and Yardlet never turns one on or off.
        _ = try await backend.devices(with: sdk)
        XCTAssertEqual(asked("TESTSERIAL01"), 1)
        connected.value = "TESTSERIAL01 device usb:1-1 transport_id:6\n"
        _ = try await backend.devices(with: sdk)
        XCTAssertEqual(asked("TESTSERIAL01"), 2)
        do {
            _ = try await backend.boot(devices[3], with: sdk)
            XCTFail("a real device was started")
        } catch {}
        XCTAssertEqual(AndroidDeviceList.connectedDeviceProperties("R5CT00TEST\nSM-G996N\n15\n35\nJo's Phone\n")?.name,
                       "Jo's Phone")

        let arguments = AndroidEmulatorBackend.launchArguments(avd: "Test_AVD", port: 5600)
        XCTAssertEqual(arguments, ["-avd", "Test_AVD", "-no-window", "-gpu", "host", "-no-boot-anim", "-no-audio",
                                   "-port", "5600"])
        XCTAssertFalse(arguments.contains("-read-only"))
    }

    /// A copy of an emulator is a new AVD of the same configuration in Yardlet's own AVD folder, which the person's
    /// list never shows: it starts without a snapshot from that folder, and deleting it removes its files.
    func testACopyOfAnEmulatorIsANewAVDInYardletsOwnFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avd-copies-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let (avds, copies) = (root.appending(path: "person", directoryHint: .isDirectory),
                              root.appending(path: "yardlet", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: avds.appending(path: "Test_AVD.avd"), withIntermediateDirectories: true)
        try Data("path=\(avds.appending(path: "Test_AVD.avd").nativePath)\ntarget=android-34\n".utf8)
            .write(to: avds.appending(path: "Test_AVD.ini"))
        try Data("""
            avd.ini.displayname=Test Phone API 34
            image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/
            hw.sdCard=yes
            sdcard.size=512 MB
            hw.lcd.width=1080

            """.utf8).write(to: avds.appending(path: "Test_AVD.avd/config.ini"))
        let ended = Listing("")
        let launcher = RecordedLaunches(ended: ended)
        let runner = ScriptedCommands { command -> String? in
            switch command.arguments {
            case ["-list-avds"]: return "Test_AVD\n"
            case ["devices", "-l"]:
                let running = !launcher.arguments.isEmpty && ended.value.isEmpty
                return "List of devices attached\n" + (running ? "emulator-5554 device\n" : "")
            case ["-s", "emulator-5554", "emu", "kill"]:
                ended.value = "yes"
                return "OK\n"
            default: return nil
            }
        }
        let backend = AndroidEmulatorBackend(runner: runner, launcher: launcher, avdHome: { avds }, copiesHome: copies,
                                             ports: [5554])
        let sdk = SimulatorToolchain(directory: "/srv/sdk")
        let originals = try await backend.devices(with: sdk)
        let original = try XCTUnwrap(originals.first)

        let copy = try await backend.makeCopy(of: original, with: sdk)
        XCTAssertEqual(copy.name, "Test Phone API 34 (Yardlet)")
        XCTAssertTrue(copy.identity.value.hasPrefix(AndroidEmulatorBackend.copyPrefix))
        let config = try String(contentsOf: copies.appending(path: "\(copy.identity.value).avd/config.ini"), encoding: .utf8)
        XCTAssertTrue(config.contains("image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/"), config)
        XCTAssertTrue(config.contains("hw.lcd.width=1080") && config.contains("hw.sdCard=no"), config)
        XCTAssertFalse(config.contains("sdcard.size"), config)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: avds.nativePath).sorted(),
                       ["Test_AVD.avd", "Test_AVD.ini"], "The person's AVD folder is left alone")
        let listed = try await backend.devices(with: sdk)
        XCTAssertEqual(listed.map(\.name), ["Test Phone API 34", "Test Phone API 34 (Yardlet)"])
        XCTAssertEqual(listed.last?.osName, "Android API 34")

        _ = try await backend.boot(copy, with: sdk)
        XCTAssertEqual(launcher.arguments.last?.suffix(1), ["-no-snapshot"])
        XCTAssertEqual(launcher.environments.last, ["ANDROID_AVD_HOME": copies.nativePath])
        try await backend.deleteCopy(copy.identity, with: sdk)
        XCTAssertTrue(runner.commands.contains { $0.arguments == ["-s", "emulator-5554", "emu", "kill"] })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.nativePath), [])
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

    func testScreenshotsAndTouchesUseTheScreensDpAndTheStreamsFrame() throws {
        let metrics = try XCTUnwrap(AndroidDisplayMetrics.parse("""
            Physical size: 1080x2400
            Override size: 720x1600
            Physical density: 420
            Override density: 320

            """))
        XCTAssertEqual(metrics, AndroidDisplayMetrics(width: 720, height: 1600, density: 320))
        // Turned as the frame is.
        XCTAssertTrue(metrics.dpSize(frameWidth: 576, frameHeight: 1280) == (360, 800))
        XCTAssertTrue(metrics.dpSize(frameWidth: 1280, frameHeight: 576) == (800, 360))
        XCTAssertEqual(AndroidDisplayMetrics.parse("Physical size: 1080x2400\nPhysical density: 420\n")?.density, 420)
        XCTAssertNil(AndroidDisplayMetrics.parse("Physical size: 1080x2400\n"))

        XCTAssertEqual(ScrcpyPosition(fractionX: 0.5, y: 0.25, frameWidth: 576, frameHeight: 1280),
                       ScrcpyPosition(x: 288, y: 320, screenWidth: 576, screenHeight: 1280))
        XCTAssertEqual(ScrcpyPosition(fractionX: 1, y: .nan, frameWidth: 576, frameHeight: 1280),
                       ScrcpyPosition(x: 575, y: 0, screenWidth: 576, screenHeight: 1280))

        // UI Automator's dump, written to the command's output and named after it, gives elements in dp.
        let dump = """
            <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" \
            resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">\
            <node index="0" text="Search settings" resource-id="com.example:id/search_field" \
            class="android.widget.EditText" content-desc="" checkable="false" clickable="true" password="false" \
            bounds="[189,147][1080,273]" /><node index="1" text="" resource-id="android:id/switch_widget" \
            class="android.widget.Switch" content-desc="Wi-Fi" checkable="true" checked="true" clickable="true" \
            bounds="[900,400][1050,505]" /></node></hierarchy>UI hierchary dumped to: /dev/tty
            """
        let tree = try XCTUnwrap(AndroidUITree.parse(dump, pixelsPerDp: 2.625))
        XCTAssertEqual(tree.elements.map(\.role), ["group"])
        XCTAssertEqual(tree.elements.first?.children, [
            SimulatorUIElement(role: "text field", label: "Search settings", identifier: "search_field",
                               frame: SimulatorUIRect(x: 72, y: 56, width: 891 / 2.625, height: 48)),
            SimulatorUIElement(role: "switch", label: "Wi-Fi", value: "checked", identifier: "switch_widget",
                               frame: SimulatorUIRect(x: 900 / 2.625, y: 400 / 2.625, width: 150 / 2.625, height: 40))
        ])
        XCTAssertNil(AndroidUITree.parse("ERROR: could not get idle state.", pixelsPerDp: 2.625))

        // A key goes by its place on the keyboard, and each event carries the modifiers held, as Android reads them.
        var keyboard = AndroidKeyboard()
        let shift = SimulatorKeyboard.leftShift, letterA = try XCTUnwrap(SimulatorKeyUsage(0x04))
        XCTAssertEqual(keyboard.messages(shift, .down), [.key(.down, keycode: 59, metaState: 0x41)])
        XCTAssertEqual(keyboard.messages(letterA, .down), [.key(.down, keycode: 29, metaState: 0x41)])
        XCTAssertEqual(keyboard.messages(shift, .up), [.key(.up, keycode: 59, metaState: 0)])
        XCTAssertEqual(keyboard.messages(try XCTUnwrap(SimulatorKeyUsage(0x39)), .press).map(\.encoded).count, 2)
        XCTAssertEqual(keyboard.metaState, 0x10_0000, "Caps Lock stays on until it is pressed again")

        // The bundle carries the file the client checks before it pushes one to a device.
        let script = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../scripts/build-app.sh").standardizedFileURL, encoding: .utf8)
        XCTAssertTrue(script.contains("SCRCPY_SERVER_URL=\"\(ScrcpyServer.releaseURL)\""))
        XCTAssertTrue(script.contains("SCRCPY_SERVER_SHA256=\"\(ScrcpyServer.sha256)\""))
        XCTAssertTrue(script.contains("$RESOURCES_DIR/\(ScrcpyServer.resourceName)\""))
    }

    /// A device's stream as scrcpy sends it, Annex B with the parameter sets in config packets, decodes into
    /// IOSurfaces a layer can show, and a rotation's new capture starts the decoder over at the new size.
    func testDecodesTheStreamIntoSurfacesAndStartsOverWhenTheDeviceTurns() throws {
        let frames = DecodedFrames()
        let decoder = AndroidVideoDecoder(output: { frames.add($0) }, needsKeyFrame: {})
        for (width, height) in [(360, 640), (640, 360)] {
            decoder.handle(.session(width: width, height: height))
            let (sets, pictures) = try encodedFrames(width: width, height: height, count: 3)
            // A picture before the config packet is no use to a decoder that has not started.
            if width == 360 { decoder.handle(.packet(pictures[0], presentationMicroseconds: 1, isKeyFrame: true)) }
            decoder.handle(.packet(sets, presentationMicroseconds: nil, isKeyFrame: false))
            for (number, picture) in pictures.enumerated() {
                decoder.handle(.packet(picture, presentationMicroseconds: UInt64(number + 1) * 16_000, isKeyFrame: number == 0))
            }
            decoder.flush()
        }
        let decoded = frames.all
        XCTAssertEqual(decoded.map { "\($0.width)x\($0.height)" }, ["360x640", "360x640", "360x640", "640x360", "640x360", "640x360"])
        XCTAssertEqual(decoded.map(\.format), [1, 1, 1, 2, 2, 2])
        XCTAssertEqual(decoded.map(\.sequence), [1, 2, 3, 4, 5, 6])
        let last = try XCTUnwrap(decoded.last)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(last.pixelBuffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(IOSurfaceGetWidth(last.surface), 640)
        XCTAssertEqual(decoder.latest?.sequence, 6)
    }

    /// Frames encoded with VideoToolbox as an Android encoder sends them: the parameter sets in Annex B, then each
    /// picture in Annex B, the first a key frame.
    private func encodedFrames(width: Int, height: Int, count: Int) throws -> (sets: Data, pictures: [Data]) {
        var created: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                  codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &created), noErr)
        let session = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var samples: [CMSampleBuffer] = []
        for number in 0..<count {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
            let buffer = try XCTUnwrap(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 * (number + 1)), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let options = number == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                                            presentationTimeStamp: CMTime(value: Int64(number), timescale: 60),
                                            duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, sample in
                if status == noErr, let sample { samples.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        XCTAssertEqual(samples.count, count)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(samples[0]))
        var sets = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            sets.append(contentsOf: [0, 0, 0, 1])
            sets.append(try XCTUnwrap(pointer), count: size)
        }
        let pictures = try samples.map { sample -> Data in
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var avcc = Data(count: CMBlockBufferGetDataLength(block))
            avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            var annexB = Data()
            var offset = 0
            while offset + 4 <= avcc.count {
                let length = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(avcc[offset + 4..<offset + 4 + length])
                offset += 4 + length
            }
            return annexB
        }
        return (sets, pictures)
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

private final class DecodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AndroidVideoDecoder.Frame] = []
    var all: [AndroidVideoDecoder.Frame] { lock.withLock { frames } }
    func add(_ frame: AndroidVideoDecoder.Frame) { lock.withLock { frames.append(frame) } }
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

/// What `adb devices -l` lists after its header, which a test changes as devices come and go.
private final class Listing: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    init(_ value: String) { current = value }
    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Keeps each launch's arguments and variables; its process ends once `ended` holds anything.
private final class RecordedLaunches: AndroidEmulatorLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let ended: Listing
    private var launched: [(arguments: [String], environment: [String: String])] = []

    init(ended: Listing) { self.ended = ended }

    var arguments: [[String]] { lock.withLock { launched.map(\.arguments) } }
    var environments: [[String: String]] { lock.withLock { launched.map(\.environment) } }

    func launch(_ executable: URL, arguments: [String], environment: [String: String]) throws -> Int32 {
        lock.withLock { launched.append((arguments, environment)) }
        return 4242
    }

    func hasEnded(_ processID: Int32) -> Bool? { !ended.value.isEmpty }
}

private struct NoLaunches: AndroidEmulatorLaunching {
    func launch(_ executable: URL, arguments: [String], environment: [String: String]) throws -> Int32 { throw SimulatorCommandError(message: "no") }
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
