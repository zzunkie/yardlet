import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import QuartzCore
import XCTest
import YardletSimulatorHostProtocol
@testable import NativeHarnessClient

/// Android screens against a real, running emulator: how long decoding takes, the first frame, the navigation
/// buttons, a swipe, keys, a rotation, screenshots in dp with and without a stream, and that the stream and the
/// server on the device end with the last panel. Run by scripts/simulator-qa/run-android-check.sh, which makes a
/// throwaway AVD, starts it without a window and deletes it after; without `YARDLET_ANDROID_QA_SERIAL` the test is
/// skipped.
///
///   YARDLET_ANDROID_QA_SERIAL   the running emulator's adb serial (emulator-<port>)
///   YARDLET_ANDROID_QA_AVD      its AVD's name
///   YARDLET_ANDROID_QA_ADB      the SDK's adb
///   YARDLET_ANDROID_QA_SERVER   the scrcpy server file (ScrcpyServer's pinned release)
///   YARDLET_ANDROID_QA_OUTPUT   where the screenshots are written
@MainActor
final class AndroidScreenQATests: XCTestCase {
    private struct Setup {
        let target: AndroidScreenTarget
        let server: URL
        let output: URL
    }

    private func setup() throws -> Setup {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["YARDLET_ANDROID_QA_SERIAL"] else {
            throw XCTSkip("scripts/simulator-qa/run-android-check.sh runs this check against a throwaway emulator")
        }
        let avd = try XCTUnwrap(environment["YARDLET_ANDROID_QA_AVD"])
        let adb = URL(fileURLWithPath: try XCTUnwrap(environment["YARDLET_ANDROID_QA_ADB"]))
        let server = URL(fileURLWithPath: try XCTUnwrap(environment["YARDLET_ANDROID_QA_SERVER"]))
        let output = URL(fileURLWithPath: environment["YARDLET_ANDROID_QA_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(path: "yardlet-android-qa").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let device = SimulatorDevice(identity: .androidEmulator(avd: avd), name: avd, state: .on, osName: "Android",
                                     osVersion: "", adbSerial: serial)
        return Setup(target: try XCTUnwrap(AndroidScreenTarget(device: device, adb: adb)), server: server, output: output)
    }

    func testShowsAndDrivesAnEmulatorAndStopsWithItsLastPanel() async throws {
        let setup = try setup()
        let target = setup.target
        let metrics = try await displayMetrics(target)
        let portrait = metrics.dpSize(frameWidth: 1, frameHeight: 2)
        try await measureDecoding(setup)

        let client = AndroidScreenClient(serverFile: { setup.server })
        addTeardownBlock { @MainActor in client.stopAll() }
        let ended = Ended()
        client.onStreamEnded = { _, end in ended.note(String(describing: end)) }

        // The first frame, decoded and shown off the main thread.
        let layer = CALayer()
        let display = SimulatorFrameDisplay(layer: layer)
        let frames = FrameCount()
        display.setObserver { frames.note($0) }
        let showing = ContinuousClock.now
        client.showFrames(of: target, in: display, pixelWidth: 840, pixelHeight: 1800)
        try await waitUntil(message: "no frame arrived") { display.current != nil }
        let firstFrame = showing.duration(to: .now)
        let first = try XCTUnwrap(display.current)
        XCTAssertTrue(layer.contents != nil)
        XCTAssertEqual(max(first.frame.pixelWidth, first.frame.pixelHeight), 1280)
        XCTAssertEqual(Double(first.frame.pixelWidth) / Double(first.frame.pixelHeight),
                       Double(metrics.width) / Double(metrics.height), accuracy: 0.01)
        XCTAssertEqual(frames.onMainThread, 0, "a frame was shown on the main thread")

        client.press(.home, on: target)
        try await Task.sleep(for: .seconds(2))
        let home = try await screenshot(client, setup, "1-home")
        XCTAssertTrue((home.width, home.height) == portrait, "the screenshot is \(home.width)x\(home.height), not dp")

        // From the Recents button to the first frame that shows its effect.
        let framesBeforeRecents = frames.count
        let pressed = ContinuousClock.now
        client.press(.recents, on: target)
        try await waitUntil(message: "no frame after Recents") { frames.count > framesBeforeRecents }
        let inputToFrame = pressed.duration(to: .now)
        _ = try await screenshot(client, setup, "2-recents", "Recents did not open") { $0.difference(from: home) > 0.2 }
        client.press(.home, on: target)
        _ = try await screenshot(client, setup, "3-home-again", "Home did not return") { $0.difference(from: home) < 0.05 }

        // A swipe up opens the app drawer.
        try await drag(client, from: (0.5, 0.85), to: (0.5, 0.3), on: target)
        _ = try await screenshot(client, setup, "4-drawer", "the swipe did not open the app drawer") {
            $0.difference(from: home) > 0.3
        }
        client.press(.home, on: target)
        _ = try await screenshot(client, setup, "4-home-again", "Home did not close the drawer") { $0.difference(from: home) < 0.05 }

        // A tap on Settings' search bar, and keys type into its field: each Mac key by its place on the keyboard.
        // The device's UI tree says when each step took; the screenshots show it.
        try await shell(target, "settings put system accelerometer_rotation 1; am force-stop com.google.android.settings.intelligence; "
                        + "am start -S -W -a android.settings.SETTINGS")
        var searchBar: SimulatorPoint?
        try await waitUntil(message: "Settings did not open") {
            searchBar = try await self.center(of: "com.android.settings:id/search_action_bar", on: target, metrics: metrics)
            return searchBar != nil
        }
        _ = try await screenshot(client, setup, "5-settings")
        client.touch(.down, at: try XCTUnwrap(searchBar), on: target)
        try await Task.sleep(for: .milliseconds(60))
        client.touch(.up, at: try XCTUnwrap(searchBar), on: target)
        try await waitUntil(message: "the tap did not open the search") {
            try await self.uiTree(target).contains("open_search_view_edit_text")
        }
        // The on-screen keyboard slides up first.
        try await Task.sleep(for: .seconds(1))
        _ = try await screenshot(client, setup, "5-search")
        for scalar in "wifi".unicodeScalars {
            let stroke = try XCTUnwrap(SimulatorKeyboard.stroke(for: scalar))
            client.key(stroke.usage, .down, on: target)
            client.key(stroke.usage, .up, on: target)
        }
        try await waitUntil(message: "the keys did not type wifi") { try await self.uiTree(target).contains("text=\"wifi\"") }
        _ = try await screenshot(client, setup, "5-typed")

        // Turned with an app that turns, the stream starts a new capture in landscape.
        try await adb(target, ["emu", "rotate"])
        try await waitUntil(message: "the stream did not turn") {
            guard let frame = display.current?.frame else { return false }
            return frame.pixelWidth > frame.pixelHeight
        }
        // The device animates the turn in the new frames.
        try await Task.sleep(for: .seconds(2))
        let turned = try await screenshot(client, setup, "6-turned", "the screenshot did not turn") { $0.width > $0.height }
        XCTAssertTrue((turned.width, turned.height) == (portrait.height, portrait.width))
        try writeSurface(try XCTUnwrap(display.current).surface, to: setup.output.appending(path: "6-turned-frame.png"))
        for _ in 0..<3 { try await adb(target, ["emu", "rotate"]) }
        try await waitUntil(message: "the stream did not turn back") {
            guard let frame = display.current?.frame else { return false }
            return frame.pixelWidth < frame.pixelHeight
        }
        client.press(.home, on: target)
        try await Task.sleep(for: .seconds(1))

        // The last panel gone: no stream, no server on the device, no tunnel, and no more frames.
        client.stopShowingFrames(of: target, in: display)
        XCTAssertFalse(client.isStreaming(target))
        try await waitUntil(message: "the server still runs on the device") {
            try await !self.shell(target, "ps -A -o ARGS").contains("com.genymobile.scrcpy.Server")
        }
        let forwards = try await adb(target, ["forward", "--list"])
        XCTAssertFalse(forwards.contains(target.serial), "a tunnel is left: \(forwards)")
        let framesAfterStop = frames.count
        try await shell(target, "input keyevent KEYCODE_APP_SWITCH")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(frames.count, framesAfterStop, "frames kept coming with no panel")

        // Without a stream, a screenshot comes from screencap, at the same size.
        let captured = try await client.screenshot(of: target, format: .png)
        try captured.data.write(to: setup.output.appending(path: "7-screencap.png"))
        XCTAssertTrue((captured.width, captured.height) == portrait)
        try await shell(target, "input keyevent KEYCODE_HOME")
        XCTAssertEqual(ended.problems, [], "a stream ended on its own")
        XCTAssertEqual(frames.onMainThread, 0, "a frame was shown on the main thread")
        print("Android QA: first frame \(firstFrame), Recents to its first frame \(inputToFrame), \(frames.count) frames shown, "
              + "screen \(metrics.width)x\(metrics.height) at \(metrics.density) dpi, dp \(portrait)")
    }

    /// A session and a decoder of their own while the screen moves: how long each picture takes from its arrival
    /// to its decoded frame, and the CPU the whole process uses meanwhile.
    private func measureDecoding(_ setup: Setup) async throws {
        let target = setup.target
        let session = ScrcpySession(adb: target.adb, serial: target.serial, serverFile: setup.server)
        let timing = DecodeTiming()
        let decoder = AndroidVideoDecoder(output: { timing.decoded($0) }, needsKeyFrame: {})
        try await session.start(video: { event in
            timing.arrived(event)
            decoder.handle(event)
        })
        try await waitUntil(message: "no frame was decoded") { timing.count > 0 }
        let cpuBefore = Self.cpuSeconds()
        let clock = ContinuousClock.now
        for keycode: UInt32 in [187, 3, 187, 3] { // Recents and Home, each animating the screen
            try await session.send(.key(.down, keycode: keycode))
            try await session.send(.key(.up, keycode: keycode))
            try await Task.sleep(for: .milliseconds(800))
        }
        let elapsed = clock.duration(to: .now) / .seconds(1)
        let cpu = Self.cpuSeconds() - cpuBefore
        await session.stop()
        decoder.flush()
        decoder.close()
        let latencies = timing.latencies.sorted()
        XCTAssertGreaterThan(latencies.count, 30, "the screen hardly moved")
        guard !latencies.isEmpty else { return }
        let median = latencies[latencies.count / 2]
        let p95 = latencies[min(latencies.count - 1, latencies.count * 95 / 100)]
        print(String(format: "Android QA: %d pictures (%d bytes) decoded, arrival to frame median %.2f ms, p95 %.2f ms, max %.2f ms; process CPU %.1f%% over %.1f s",
                     latencies.count, timing.bytes, median, p95, latencies.last!, cpu / elapsed * 100, elapsed))
    }

    // MARK: Helpers

    private func drag(_ client: AndroidScreenClient, from start: (Double, Double), to end: (Double, Double),
                      on target: AndroidScreenTarget) async throws {
        client.touch(.down, at: SimulatorPoint(x: start.0, y: start.1)!, on: target)
        for step in 1...15 {
            try await Task.sleep(for: .milliseconds(16))
            let fraction = Double(step) / 15
            client.touch(.move, at: SimulatorPoint(x: start.0 + (end.0 - start.0) * fraction,
                                                   y: start.1 + (end.1 - start.1) * fraction)!, on: target)
        }
        client.touch(.up, at: SimulatorPoint(x: end.0, y: end.1)!, on: target)
    }

    private func screenshot(_ client: AndroidScreenClient, _ setup: Setup, _ name: String, _ failure: String,
                            until condition: (Pixels) -> Bool) async throws -> Pixels {
        var last: Pixels?
        try await waitUntil(message: failure) {
            let shot = try await screenshot(client, setup, name)
            last = shot
            return condition(shot)
        }
        return try XCTUnwrap(last)
    }

    private func screenshot(_ client: AndroidScreenClient, _ setup: Setup, _ name: String) async throws -> Pixels {
        let image = try await client.screenshot(of: setup.target, format: .png)
        try image.data.write(to: setup.output.appending(path: "\(name).png"))
        let pixels = try XCTUnwrap(Pixels(png: image.data), "\(name) is not a PNG")
        XCTAssertEqual(pixels.width, image.width)
        return pixels
    }

    /// The device's UI tree as `uiautomator` dumps it.
    private func uiTree(_ target: AndroidScreenTarget) async throws -> String {
        try await shell(target, "uiautomator dump /data/local/tmp/yardlet-qa-ui.xml >/dev/null && cat /data/local/tmp/yardlet-qa-ui.xml")
    }

    /// The middle of the view with `resourceID`, as fractions of a portrait screen.
    private func center(of resourceID: String, on target: AndroidScreenTarget,
                        metrics: AndroidDisplayMetrics) async throws -> SimulatorPoint? {
        let tree = try await uiTree(target)
        guard let node = tree.range(of: "resource-id=\"\(resourceID)\""),
              let bounds = tree[node.upperBound...].firstMatch(of: /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/),
              let left = Double(bounds.1), let top = Double(bounds.2), let right = Double(bounds.3),
              let bottom = Double(bounds.4) else { return nil }
        return SimulatorPoint(x: (left + right) / 2 / Double(metrics.width), y: (top + bottom) / 2 / Double(metrics.height))
    }

    private func displayMetrics(_ target: AndroidScreenTarget) async throws -> AndroidDisplayMetrics {
        let output = try await shell(target, AndroidDisplayMetrics.shellCommand)
        return try XCTUnwrap(AndroidDisplayMetrics.parse(output))
    }

    @discardableResult
    private func shell(_ target: AndroidScreenTarget, _ command: String) async throws -> String {
        try await adb(target, ["shell", command])
    }

    @discardableResult
    private func adb(_ target: AndroidScreenTarget, _ arguments: [String]) async throws -> String {
        let result = await CLIProcess.run(CLICommand(executable: target.adb, arguments: ["-s", target.serial] + arguments,
                                                     timeout: .seconds(30)))
        guard result.succeeded else { throw ScrcpyProtocolError("adb \(arguments): \(result.failureSummary)") }
        return result.stdout
    }

    private func writeSurface(_ surface: IOSurfaceRef, to url: URL) throws {
        let image = try XCTUnwrap(Pixels.image(of: surface))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private final class FrameCount: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var main = 0
        var count: Int { lock.withLock { frames } }
        var onMainThread: Int { lock.withLock { main } }
        func note(_ frame: SimulatorFrame) {
            let isMain = Thread.isMainThread
            lock.withLock {
                frames += 1
                if isMain { main += 1 }
            }
        }
    }

    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var noted: [String] = []
        var problems: [String] { lock.withLock { noted } }
        func note(_ end: String) { lock.withLock { noted.append(end) } }
    }

    /// Each picture packet's arrival, matched in order with the frames the decoder puts out.
    private final class DecodeTiming: @unchecked Sendable {
        private let lock = NSLock()
        private var arrivals: [UInt64] = []
        private var measured: [Double] = []
        private var total = 0
        var count: Int { lock.withLock { measured.count } }
        var latencies: [Double] { lock.withLock { measured } }
        var bytes: Int { lock.withLock { total } }

        func arrived(_ event: ScrcpyVideoEvent) {
            guard case let .packet(data, presentation, _) = event else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                total += data.count
                if presentation != nil { arrivals.append(now) }
            }
        }

        func decoded(_ frame: AndroidVideoDecoder.Frame) {
            lock.withLock {
                guard !arrivals.isEmpty else { return }
                measured.append(Double(frame.decodedAt - arrivals.removeFirst()) / 1_000_000)
            }
        }
    }

    /// RGBA pixels at a fixed small size, for comparing screens.
    private struct Pixels {
        static let side = 128
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(png: Data) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: Self.side, height: Self.side, bitsPerComponent: 8,
                                        bytesPerRow: Self.side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            }
            self.bytes = bytes
        }

        static func image(of surface: IOSurfaceRef) -> CGImage? {
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            return CGContext(data: IOSurfaceGetBaseAddress(surface), width: IOSurfaceGetWidth(surface),
                             height: IOSurfaceGetHeight(surface), bitsPerComponent: 8,
                             bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }

        /// The share of pixels whose color moved by more than a little.
        func difference(from other: Pixels) -> Double {
            var changed = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let delta = (0..<3).map { abs(Int(bytes[index + $0]) - Int(other.bytes[index + $0])) }.max()!
                if delta > 24 { changed += 1 }
            }
            return Double(changed) / Double(Self.side * Self.side)
        }
    }
}
