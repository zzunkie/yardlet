import Foundation
import IOSurface
import QuartzCore
import YardletSimulatorHostProtocol
import YardletSurfacePort

/// Puts one panel's simulator frames on screen without the main thread, as `BrowserFrameDisplay` does for pages: the
/// helper's pipe queue hands each frame's IOSurface to the panel's own layer in an explicit transaction. The layer
/// fits the frame into itself (`contentsGravity`), so the panel sizes the layer and nothing here sizes it.
final class SimulatorFrameDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private let layer: CALayer
    private var shownAt: UInt64 = 0
    private var surface: IOSurfaceRef?
    private var frame: SimulatorFrame?
    private var observer: (@Sendable (SimulatorFrame) -> Void)?

    init(layer: CALayer) {
        self.layer = layer
    }

    /// The surface on screen now and the frame it holds.
    var current: (frame: SimulatorFrame, surface: IOSurfaceRef)? {
        lock.withLock { frame.flatMap { frame in surface.map { (frame, $0) } } }
    }

    /// Called, on the thread that showed it, for every frame placed on screen.
    func setObserver(_ observer: (@Sendable (SimulatorFrame) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    /// Shows a frame; one drawn before the frame on screen is skipped.
    func show(_ frame: SimulatorFrame, surface: IOSurfaceRef) {
        let observer: (@Sendable (SimulatorFrame) -> Void)? = lock.withLock {
            guard frame.drawnAt > shownAt || self.surface == nil else { return nil }
            shownAt = frame.drawnAt
            self.surface = surface
            self.frame = frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            return self.observer
        }
        observer?(frame)
    }

    func clear() {
        lock.withLock {
            surface = nil
            frame = nil
            shownAt = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = nil
            CATransaction.commit()
        }
    }
}

/// Which displays show each device, read on the helper's pipe queue and set on the main thread. Any number of
/// panels may show the same device; the helper copies each frame once, for the largest of them. The router keeps each
/// device's latest frame for a display that starts showing it.
final class SimulatorFrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [UUID: [SimulatorFrameDisplay]] = [:]
    private var latest: [UUID: (frame: SimulatorFrame, surface: IOSurfaceRef)] = [:]

    /// A frame on the pipe's queue: to every display of its device.
    func route(_ frame: SimulatorFrame, surface: IOSurfaceRef) {
        let shown = lock.withLock { () -> [SimulatorFrameDisplay] in
            latest[frame.device] = (frame, surface)
            return displays[frame.device] ?? []
        }
        for display in shown { display.show(frame, surface: surface) }
    }

    /// Adds a display and puts the device's latest frame on it now.
    func add(_ display: SimulatorFrameDisplay, for device: UUID) {
        let frame = lock.withLock { () -> (frame: SimulatorFrame, surface: IOSurfaceRef)? in
            if !(displays[device] ?? []).contains(where: { $0 === display }) { displays[device, default: []].append(display) }
            return latest[device]
        }
        if let frame { display.show(frame.frame, surface: frame.surface) }
    }

    func remove(_ display: SimulatorFrameDisplay, for device: UUID) {
        lock.withLock {
            displays[device]?.removeAll { $0 === display }
            if displays[device]?.isEmpty == true { displays[device] = nil }
        }
    }

    /// The helper let go of the device: its displays keep their last frame, and no new display gets one.
    func forgetLatestFrame(of device: UUID) {
        lock.withLock { latest[device] = nil }
    }

    func removeAll() {
        lock.withLock {
            displays.removeAll()
            latest.removeAll()
        }
    }
}

/// The IOSurfaces the launched helper sent, by IOSurface ID. A frame marked fresh follows its surface's Mach message,
/// which is taken off the port then; only the launched helper, with this launch's token, can deliver one. Surfaces of
/// a device's earlier pool are let go once a frame of a newer pool arrives.
final class SimulatorSurfaceReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private let port: mach_port_t
    private let token: [UInt8]
    private var hostProcessID: Int32 = 0
    private var surfaces: [UInt32: (device: UUID, pool: UInt64, surface: IOSurfaceRef)] = [:]
    /// Surfaces taken off the port before the frame that names them.
    private var early: [UInt32: IOSurfaceRef] = [:]
    private var pools: [UUID: UInt64] = [:]
    private var isClosed = false
    private var rejected = 0

    init(port: mach_port_t, token: [UInt8]) {
        self.port = port
        self.token = token
    }

    /// Surface messages refused because they came from another process or carried a wrong token.
    var rejectedMessages: Int { lock.withLock { rejected } }
    /// Surfaces held now.
    var count: Int { lock.withLock { surfaces.count } }

    func setHostProcessID(_ processID: Int32) {
        lock.withLock { hostProcessID = processID }
    }

    /// The surface a frame names. Never waits: the helper sends a surface's port before the frame event that names it.
    func surface(for frame: SimulatorFrame) -> IOSurfaceRef? {
        lock.withLock {
            guard !isClosed else { return nil }
            if let pool = pools[frame.device], pool < frame.pool {
                surfaces = surfaces.filter { $0.value.device != frame.device || $0.value.pool >= frame.pool }
            }
            pools[frame.device] = max(pools[frame.device] ?? 0, frame.pool)
            if frame.fresh {
                guard let surface = early.removeValue(forKey: frame.surface) ?? receive(frame.surface) else { return nil }
                surfaces[frame.surface] = (frame.device, frame.pool, surface)
                return surface
            }
            return surfaces[frame.surface]?.surface
        }
    }

    /// Takes messages off the port until the one for `id`; others wait for their frames.
    private func receive(_ id: UInt32) -> IOSurfaceRef? {
        for _ in 0..<16 {
            var received: UInt32 = 0
            var refused: UInt32 = 0
            let message = token.withUnsafeBufferPointer { bytes in
                yardlet_surface_port_receive(port, 0, hostProcessID, bytes.baseAddress!, &received, &refused)
            }
            rejected += Int(refused)
            guard let surface = message?.takeRetainedValue() else { return nil }
            if received == id { return surface }
            // Bounded: a surface whose frame never came is not kept for long.
            if early.count >= 16 { early.removeAll() }
            early[received] = surface
        }
        return nil
    }

    func forget(device: UUID) {
        lock.withLock {
            surfaces = surfaces.filter { $0.value.device != device }
            pools[device] = nil
        }
    }

    /// Forgets every surface and destroys the port.
    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            surfaces.removeAll()
            early.removeAll()
            yardlet_surface_port_destroy(port)
        }
    }
}
