import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import QuartzCore
import XCTest
import YardletSimulatorHostProtocol
@testable import NativeHarnessClient

/// The simulator host against a real, booted simulator: the first frame, a tap that opens Settings, the home button,
/// a drag, keys, the agent tools' select-all and paste (`MacIOSSimulatorDriver`), and that the helper holds no screen
/// recording or accessibility permission of its own. Run by
/// scripts/simulator-qa/run-check.sh, which makes a throwaway device, boots it without a window and deletes it after;
/// without `YARDLET_SIMULATOR_QA_DEVICE` the test is skipped.
///
///   YARDLET_SIMULATOR_QA_DEVICE         the booted device's UDID
///   YARDLET_SIMULATOR_QA_HELPER         the helper's executable (the build's YardletSimulatorHost by default)
///   YARDLET_SIMULATOR_QA_DEVELOPER_DIR  the Xcode's Contents/Developer
///   YARDLET_SIMULATOR_QA_OUTPUT         where the screenshots are written
///   YARDLET_SIMULATOR_QA_SETTINGS       the Settings icon on the first home screen page, "x,y" as fractions of the
///                                       screen (an iPhone 17's on iOS 27 by default)
@MainActor
final class SimulatorHostQATests: XCTestCase {
    private struct Setup {
        let device: UUID
        let helper: URL
        let developerDirectory: URL
        let output: URL
        let settings: SimulatorPoint
    }

    private func setup() throws -> Setup {
        let environment = ProcessInfo.processInfo.environment
        guard let deviceValue = environment["YARDLET_SIMULATOR_QA_DEVICE"] else {
            throw XCTSkip("scripts/simulator-qa/run-check.sh runs this check against a throwaway simulator")
        }
        let device = try XCTUnwrap(UUID(uuidString: deviceValue))
        let built = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "YardletSimulatorHost")
        let helper = environment["YARDLET_SIMULATOR_QA_HELPER"].map { URL(fileURLWithPath: $0) } ?? built
        let developer = URL(fileURLWithPath: try XCTUnwrap(environment["YARDLET_SIMULATOR_QA_DEVELOPER_DIR"]))
        let output = URL(fileURLWithPath: environment["YARDLET_SIMULATOR_QA_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(path: "yardlet-simulator-qa").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let values = (environment["YARDLET_SIMULATOR_QA_SETTINGS"] ?? "0.843,0.492").split(separator: ",").compactMap { Double($0) }
        let settings = try XCTUnwrap(values.count == 2 ? SimulatorPoint(x: values[0], y: values[1]) : nil)
        return Setup(device: device, helper: helper, developerDirectory: developer, output: output, settings: settings)
    }

    func testHelperShowsAndDrivesADeviceWithoutPermissionsOfItsOwn() async throws {
        let setup = try setup()
        let client = SimulatorHostClient(developerDirectory: setup.developerDirectory, executable: setup.helper,
                                         log: setup.output.appending(path: "helper.log"), idleExit: .seconds(2))
        addTeardownBlock { @MainActor in client.terminate() }

        let screen = try await client.attach(setup.device)
        XCTAssertGreaterThan(screen.pixelWidth, 0)
        XCTAssertGreaterThan(screen.scale, 1)
        XCTAssertNil(client.unsupported)
        print("Simulator QA: Xcode \(client.xcodeVersion ?? "?"), \(client.capabilities), screen \(screen)")

        // Started responsible for itself, the helper holds none of the permissions Yardlet (or this test's terminal)
        // holds: screen recording, accessibility, automation. Its sandbox keeps it out of the home folder and the network.
        let diagnosis = try await client.diagnose()
        XCTAssertEqual(diagnosis.processID, client.helperProcessID)
        XCTAssertEqual(diagnosis.responsibleProcessID, diagnosis.processID, "the helper is not responsible for itself")
        XCTAssertFalse(diagnosis.screenCaptureAccess, "the helper inherited screen recording permission")
        XCTAssertEqual(diagnosis.sandboxed, true, "the helper runs without its sandbox")
        XCTAssertFalse(diagnosis.homeReadable, "the helper reads the home folder")
        XCTAssertFalse(diagnosis.networkReachable, "the helper reaches the network")

        // The first frame: the screen as it is, fit within the size asked for.
        let layer = CALayer()
        let display = SimulatorFrameDisplay(layer: layer)
        let frames = FrameCount()
        display.setObserver { frames.note($0) }
        client.showFrames(of: setup.device, in: display, pixelWidth: 600, pixelHeight: 1300)
        try await waitUntil(message: "no frame arrived") { display.current != nil }
        let first = try XCTUnwrap(display.current)
        XCTAssertLessThanOrEqual(first.frame.pixelWidth, 600)
        XCTAssertLessThanOrEqual(first.frame.pixelHeight, 1300)
        XCTAssertEqual(Double(first.frame.pixelWidth) / Double(first.frame.pixelHeight),
                       Double(screen.pixelWidth) / Double(screen.pixelHeight), accuracy: 0.01)
        XCTAssertTrue(layer.contents != nil)
        let firstPixels = Pixels(surface: first.surface)
        XCTAssertGreaterThan(firstPixels.distinctColors, 50, "the first frame is blank")

        client.press(.home, .press, on: setup.device)
        try await Task.sleep(for: .seconds(2))
        let home = try await screenshot(client, setup, "1-home")
        XCTAssertEqual(home.width, screen.pointWidth)
        XCTAssertEqual(home.height, screen.pointHeight)

        // A tap on Settings: new frames, in another surface or with another seed, and other pixels.
        let beforeTap = try XCTUnwrap(display.current)
        let seedBeforeTap = IOSurfaceGetSeed(beforeTap.surface)
        let pixelsBeforeTap = Pixels(surface: beforeTap.surface)
        let framesBeforeTap = frames.count
        try await tap(client, setup.settings, on: setup.device)
        try await waitUntil(message: "no frame after the tap") { frames.count > framesBeforeTap }
        // A new device's first Settings launch shows a blank page for a few seconds; its list has colored icons.
        let settings = try await screenshot(client, setup, "2-settings", "Settings did not open") {
            $0.colored > 0.005 && $0.difference(from: home) > 0.3
        }
        let afterTap = try XCTUnwrap(display.current)
        XCTAssertTrue(afterTap.surface !== beforeTap.surface || IOSurfaceGetSeed(afterTap.surface) != seedBeforeTap)
        XCTAssertGreaterThan(Pixels(surface: afterTap.surface).difference(from: pixelsBeforeTap), 0.3,
                             "the frames did not follow the screen")

        // A drag scrolls the Settings list.
        try await drag(client, from: SimulatorPoint(x: 0.5, y: 0.75)!, to: SimulatorPoint(x: 0.5, y: 0.35)!, on: setup.device)
        _ = try await screenshot(client, setup, "3-scrolled", "the drag did not scroll") { $0.difference(from: settings) > 0.05 }

        // The home button goes back to the home screen.
        client.press(.home, .press, on: setup.device)
        let homeAgain = try await screenshot(client, setup, "4-home-again", "the home button did not return to the home screen") {
            $0.difference(from: home) < 0.05
        }

        // A swipe down on the home screen opens Search with its field focused; keys type into it.
        try await drag(client, from: SimulatorPoint(x: 0.5, y: 0.3)!, to: SimulatorPoint(x: 0.5, y: 0.6)!, on: setup.device)
        let search = try await screenshot(client, setup, "5-search", "the swipe did not open Search") {
            $0.difference(from: homeAgain) > 0.3
        }
        try await Task.sleep(for: .seconds(1))
        client.type(try XCTUnwrap(SimulatorKeyboardText("yardlet")), on: setup.device)
        let typed = try await screenshot(client, setup, "6-typed", "the keys typed nothing") { $0.difference(from: search) > 0.01 }

        // The agent tools' driver: select-all and delete empty the field, and a paste enters text in any language from
        // the device's clipboard, which then holds what it held before.
        let driver = MacIOSSimulatorDriver(screens: AttachedHost(client: client))
        let device = SimulatorDevice(identity: .iOSSimulator(udid: setup.device.uuidString), name: "QA device", state: .on,
                                     osName: "", osVersion: "")
        let toolchain = SimulatorToolchain(directory: setup.developerDirectory.path)
        let toolScreen = try await driver.prepare(device, with: toolchain)
        XCTAssertEqual(toolScreen, SimulatorToolScreen(width: screen.pointWidth, height: screen.pointHeight))
        try await driver.press(.selectAll, on: device)
        try await driver.press(.delete, on: device)
        let cleared = try await screenshot(client, setup, "7-cleared", "select-all and delete left the field") {
            $0.difference(from: typed) > 0.005
        }
        let earlier = "The person's clipboard"
        let copied = await pasteboard(["pbcopy", setup.device.uuidString], setup, input: earlier)
        XCTAssertTrue(copied.succeeded, copied.stderr)
        try await driver.paste("안녕하세요 Yardlet", on: device, with: toolchain)
        _ = try await screenshot(client, setup, "8-pasted", "the paste entered nothing") { $0.difference(from: cleared) > 0.005 }
        let restored = await pasteboard(["pbpaste", setup.device.uuidString], setup)
        XCTAssertEqual(restored.stdout, earlier, "the device's clipboard did not get its text back")
        client.key(SimulatorKeyboard.escape, .press, on: setup.device)
        client.press(.home, .press, on: setup.device)
        try await Task.sleep(for: .seconds(1))

        // No subscription, no copies: the frames stop while the screen still changes.
        client.stopShowingFrames(of: setup.device, in: display)
        try await Task.sleep(for: .milliseconds(300))
        let framesAfterStop = frames.count
        try await tap(client, setup.settings, on: setup.device)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(frames.count, framesAfterStop, "frames kept coming with no display")
        client.press(.home, .press, on: setup.device)
        print("Simulator QA: \(frames.count) frames shown")

        // Let go of the device, and the helper ends on its own.
        client.detach(setup.device)
        try await waitUntil(message: "the helper did not end after its last device") { client.helperProcessID == nil }
    }

    // MARK: Helpers

    /// The device's clipboard through `simctl`, as the driver reads and writes it.
    private func pasteboard(_ arguments: [String], _ setup: Setup, input: String? = nil) async -> CLICommandResult {
        await CLIProcess.run(CLICommand(
            executable: URL(filePath: "/usr/bin/xcrun"), arguments: ["simctl"] + arguments,
            environment: ["DEVELOPER_DIR": setup.developerDirectory.path, "LC_CTYPE": "UTF-8"], timeout: .seconds(20),
            standardInput: input.map { Data($0.utf8) }))
    }

    /// The test's own client, attached already, as the driver's host.
    private final class AttachedHost: SimulatorToolScreens {
        let client: SimulatorHostClient

        init(client: SimulatorHostClient) {
            self.client = client
        }

        func attachForTools(_ target: MacSimulatorScreens.Target) async throws -> SimulatorScreen {
            guard let udid = UUID(uuidString: target.device.value), let screen = client.screens[udid] else {
                throw SimulatorHostClient.Failure.device("not attached")
            }
            return screen
        }

        func releaseForTools(_ device: SimulatorDeviceIdentity) {}
        func hostClient(of device: SimulatorDeviceIdentity) -> SimulatorHostClient? { client }
        func androidStream(of device: SimulatorDeviceIdentity)
            -> (client: AndroidScreenClient, target: AndroidScreenTarget)? { nil }
    }

    /// A finger down and up again, as a person taps.
    private func tap(_ client: SimulatorHostClient, _ point: SimulatorPoint, on device: UUID) async throws {
        client.touch(.down, at: point, on: device)
        try await Task.sleep(for: .milliseconds(60))
        client.touch(.up, at: point, on: device)
    }

    /// A finger moved over a quarter of a second, a step for each frame of a 60 Hz screen.
    private func drag(_ client: SimulatorHostClient, from start: SimulatorPoint, to end: SimulatorPoint,
                      on device: UUID) async throws {
        client.touch(.down, at: start, on: device)
        for step in 1...15 {
            try await Task.sleep(for: .milliseconds(16))
            let fraction = Double(step) / 15
            client.touch(.move, at: SimulatorPoint(x: start.x + (end.x - start.x) * fraction,
                                                   y: start.y + (end.y - start.y) * fraction)!, on: device)
        }
        client.touch(.up, at: end, on: device)
    }

    /// Screenshots until one shows what `condition` looks for (the device draws in its own time), and returns it.
    private func screenshot(_ client: SimulatorHostClient, _ setup: Setup, _ name: String, _ failure: String,
                            until condition: (Pixels) -> Bool) async throws -> Pixels {
        var last: Pixels?
        try await waitUntil(message: failure) {
            let shot = try await screenshot(client, setup, name)
            last = shot
            return condition(shot)
        }
        return try XCTUnwrap(last)
    }

    private func screenshot(_ client: SimulatorHostClient, _ setup: Setup, _ name: String) async throws -> Pixels {
        let image = try await client.screenshot(of: setup.device, format: .png)
        try image.data.write(to: setup.output.appending(path: "\(name).png"))
        return try XCTUnwrap(Pixels(png: image.data), "\(name) is not a PNG")
    }

    private final class FrameCount: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        var count: Int { lock.withLock { frames } }
        func note(_ frame: SimulatorFrame) { lock.withLock { frames += 1 } }
    }

    /// RGBA pixels at a fixed small size, for comparing screens.
    private struct Pixels {
        static let width = 100, height = 200
        let bytes: [UInt8]
        var width: Int = 0
        var height: Int = 0

        init?(png: Data) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            self.init(image: image)
            width = image.width
            height = image.height
        }

        init(surface: IOSurfaceRef) {
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let context = CGContext(data: IOSurfaceGetBaseAddress(surface), width: IOSurfaceGetWidth(surface),
                                    height: IOSurfaceGetHeight(surface), bitsPerComponent: 8,
                                    bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            self.init(image: context!.makeImage()!)
        }

        private init(image: CGImage) {
            var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                        bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            }
            self.bytes = bytes
        }

        /// The share of pixels whose color moved by more than a little.
        func difference(from other: Pixels) -> Double {
            var changed = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let delta = (0..<3).map { abs(Int(bytes[index + $0]) - Int(other.bytes[index + $0])) }.max()!
                if delta > 24 { changed += 1 }
            }
            return Double(changed) / Double(Self.width * Self.height)
        }

        /// The share of pixels with a color rather than a shade of gray.
        var colored: Double {
            let count = stride(from: 0, to: bytes.count, by: 4).filter {
                let channels = [bytes[$0], bytes[$0 + 1], bytes[$0 + 2]].map(Int.init)
                return channels.max()! - channels.min()! > 40
            }.count
            return Double(count) / Double(Self.width * Self.height)
        }

        var distinctColors: Int {
            Set(stride(from: 0, to: bytes.count, by: 4).map { UInt32(bytes[$0]) << 16 | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) }).count
        }
    }
}
