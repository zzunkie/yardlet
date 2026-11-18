#if DEBUG
import Foundation
import IOSurface
import YardletSimulatorHostProtocol

/// The performance bench's simulator (`simulator-scroll`): one iOS device that is on, and no Xcode or simulator
/// host behind it. The bench shows it in the task's Simulator tab and puts frames on the tab's display itself.
struct PerfBenchSimulatorBackend: SimulatorBackend {
    static let device = UUID(uuidString: "0FA1B2C3-0000-4000-8000-00000000D001")!
    static let toolchain = SimulatorToolchain(directory: "/Applications/Xcode.app/Contents/Developer", version: "27.2")
    /// An iPhone 17's screen.
    static let screen = SimulatorScreen(screenID: 1, pixelWidth: 1206, pixelHeight: 2622, scale: 3)

    var platform: SimulatorPlatform { .iOS }

    func check() async -> SimulatorPlatformCheck {
        SimulatorPlatformCheck(availability: .available, toolchain: Self.toolchain)
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] {
        [SimulatorDevice(identity: .iOSSimulator(udid: Self.device.uuidString), name: "iPhone 17", state: .on,
                         osName: "iOS 27.2", osVersion: "27.2")]
    }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart { .alreadyOn }
    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}
    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? { nil }
}

/// Frames for a Simulator tab's display at 60 a second, from a queue of their own, as the simulator host's pipe
/// queue hands each frame's IOSurface to the panels' layers: three surfaces of the panel's size in turn, as the
/// helper's pool. What the main thread does meanwhile is what the bench measures.
final class PerfBenchSimulatorFrames: @unchecked Sendable {
    private let display: SimulatorFrameDisplay
    private let queue = DispatchQueue(label: "Yardlet perf bench simulator frames", qos: .userInteractive)
    private let surfaces: [IOSurfaceRef]
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var sent: UInt64 = 0
    private var shown = 0

    init?(display: SimulatorFrameDisplay, pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let properties: [CFString: Any] = [kIOSurfaceWidth: pixelWidth, kIOSurfaceHeight: pixelHeight,
                                           kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: 0x4247_5241]  // 'BGRA'
        let made = (0..<3).compactMap { _ in IOSurfaceCreate(properties as CFDictionary) }
        guard made.count == 3 else { return nil }
        // Each surface a colour of its own, so the layer changes with every frame.
        for (index, surface) in made.enumerated() {
            IOSurfaceLock(surface, [], nil)
            let base = IOSurfaceGetBaseAddress(surface)
            let pixel: UInt32 = [0xFF30_6090, 0xFF90_3060, 0xFF60_9030][index]
            let count = IOSurfaceGetBytesPerRow(surface) / 4 * pixelHeight
            base.bindMemory(to: UInt32.self, capacity: count).update(repeating: pixel, count: count)
            IOSurfaceUnlock(surface, [], nil)
        }
        self.display = display
        surfaces = made
        width = pixelWidth
        height = pixelHeight
        display.setObserver { [weak self] _ in self?.lock.withLock { self?.shown += 1 } }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    /// What the frames did: how many were sent and how many the display put on screen.
    var record: [String: Any] {
        lock.withLock { ["framesSent": Int(sent), "framesShown": shown, "pixelWidth": width, "pixelHeight": height] }
    }

    private func sendFrame() {
        let sequence = lock.withLock { () -> UInt64 in
            sent += 1
            return sent
        }
        let surface = surfaces[Int(sequence % 3)]
        let frame = SimulatorFrame(device: PerfBenchSimulatorBackend.device, surface: IOSurfaceGetID(surface),
                                   fresh: false, pool: 1, pixelWidth: width, pixelHeight: height, sequence: sequence,
                                   drawnAt: DispatchTime.now().uptimeNanoseconds)
        display.show(frame, surface: surface)
    }
}
#endif
