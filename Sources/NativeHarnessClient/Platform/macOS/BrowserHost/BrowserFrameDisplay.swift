import Foundation
import IOSurface
import QuartzCore
import YardletSurfacePort

/// Puts one panel's page frames on screen without the main thread. The event pipe's queue hands
/// each frame's IOSurface to the panel's own layer in an explicit transaction, which goes to the
/// window server when it commits; the main thread, however busy with the rest of the window, is
/// not in the way between the host's paint and the screen. The main thread still sets the scale
/// and clears the layer; one lock orders those with the frames.
final class BrowserFrameDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private let layer: CALayer
    /// The layer takes the page's size (the panel); otherwise it keeps its own and the frame is fit
    /// into it (`contentsGravity`, the rail's preview).
    private let sizesLayer: Bool
    private var scale: CGFloat = 2
    private var shownSequence: UInt64 = 0
    private var surface: IOSurfaceRef?
    private var observer: (@Sendable (BrowserFrame, Double) -> Void)?

    init(layer: CALayer, sizesLayer: Bool = true) {
        self.layer = layer
        self.sizesLayer = sizesLayer
    }

    /// The surface on screen now.
    var currentSurface: IOSurfaceRef? { lock.withLock { surface } }

    func setScale(_ scale: CGFloat) {
        lock.withLock {
            self.scale = scale
            layer.contentsScale = scale
        }
    }

    /// Called, on the thread that showed it, for every frame placed on screen with its
    /// paint-to-display latency in milliseconds.
    func setObserver(_ observer: (@Sendable (BrowserFrame, Double) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    /// Whether this frame, or a later one, is already on screen.
    func hasShown(_ frame: BrowserFrame) -> Bool {
        lock.withLock { surface != nil && shownSequence >= frame.sequence }
    }

    /// Prepares the display to show another tab's frames: the sequence counter restarts, so a cached
    /// frame of the next tab with a lower sequence than the one on screen is not skipped. The surface
    /// stays on screen until the next tab paints, so the panel does not go blank between tabs.
    func prepareForNextTab() {
        lock.withLock { shownSequence = 0 }
    }

    /// Shows a page frame; an older frame than the one on screen is skipped.
    func show(_ frame: BrowserFrame, surface: IOSurfaceRef) {
        let observer: (@Sendable (BrowserFrame, Double) -> Void)? = lock.withLock {
            guard frame.sequence > shownSequence || self.surface == nil else { return nil }
            shownSequence = frame.sequence
            self.surface = surface
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            if sizesLayer {
                layer.frame = CGRect(x: 0, y: 0, width: CGFloat(frame.pixelWidth) / scale,
                                     height: CGFloat(frame.pixelHeight) / scale)
            }
            CATransaction.commit()
            return self.observer
        }
        let latency = Double(DispatchTime.now().uptimeNanoseconds &- frame.paintedAt) / 1_000_000
        observer?(frame, latency)
    }

    func clear() {
        lock.withLock {
            surface = nil
            shownSequence = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = nil
            CATransaction.commit()
        }
    }
}

/// Which display shows each tab's page, read on the event pipe's queue and set on the main
/// thread. One display per tab: the panel that adopted the tab last, as with the tab's event handler;
/// and at most one preview (the rail's Preview card). It keeps each painting tab's latest frame for a
/// preview that starts showing it, and lets go of it when the host hides or closes the tab, so a
/// hidden tab still holds no surface.
final class BrowserFrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [BrowserTabID: BrowserFrameDisplay] = [:]
    private var previews: [BrowserTabID: BrowserFrameDisplay] = [:]
    private var latest: [BrowserTabID: (frame: BrowserFrame, surface: IOSurfaceRef)] = [:]

    /// A page frame on the pipe's queue: to the tab's panel and preview.
    func route(_ frame: BrowserFrame, surface: IOSurfaceRef, of tab: BrowserTabID) {
        let (display, preview) = lock.withLock { () -> (BrowserFrameDisplay?, BrowserFrameDisplay?) in
            latest[tab] = (frame, surface)
            return (displays[tab], previews[tab])
        }
        display?.show(frame, surface: surface)
        preview?.show(frame, surface: surface)
    }

    func latestFrame(of tab: BrowserTabID) -> (BrowserFrame, IOSurfaceRef)? {
        lock.withLock { latest[tab].map { ($0.frame, $0.surface) } }
    }

    func forgetLatestFrame(of tab: BrowserTabID) {
        lock.withLock { latest[tab] = nil }
    }

    func setPreview(_ display: BrowserFrameDisplay, for tab: BrowserTabID) {
        lock.withLock { previews[tab] = display }
    }

    func removePreview(_ display: BrowserFrameDisplay, for tab: BrowserTabID) {
        lock.withLock { if previews[tab] === display { previews[tab] = nil } }
    }

    func set(_ display: BrowserFrameDisplay, for tab: BrowserTabID) {
        lock.withLock { displays[tab] = display }
    }

    func remove(_ display: BrowserFrameDisplay, for tab: BrowserTabID) {
        lock.withLock { if displays[tab] === display { displays[tab] = nil } }
    }

    func removeAll() {
        lock.withLock {
            displays.removeAll()
            previews.removeAll()
            latest.removeAll()
        }
    }

    func display(for tab: BrowserTabID) -> BrowserFrameDisplay? {
        lock.withLock { displays[tab] }
    }
}

/// The IOSurfaces the launched host sent, by frame token, kept while the host paints into them
/// (`BrowserFrameSurfaceCache` drops them with the host's rings). New surfaces are taken off the Mach
/// port the first time a frame names them (the host sends the port before the frame event); only the
/// launched host, with this launch's token, can deliver one. The event pipe's queue receives and
/// notes frames and releases in event order; the main thread looks surfaces up for popup frames.
final class BrowserSurfaceReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private let port: mach_port_t
    private let token: [UInt8]
    private var hostProcessID: Int32 = 0
    private var cache = BrowserFrameSurfaceCache<IOSurfaceRef>()
    private var isClosed = false
    private var rejected = 0

    init(port: mach_port_t, token: [UInt8]) {
        self.port = port
        self.token = token
    }

    /// Surface messages refused because they came from another process or carried a wrong token.
    var rejectedMessages: Int { lock.withLock { rejected } }
    /// Surfaces kept now, for QA.
    var count: Int { lock.withLock { cache.count } }

    func setHostProcessID(_ processID: Int32) {
        lock.withLock { hostProcessID = processID }
    }

    /// Never waits: the host sends a surface's port before it writes the frame event that names it,
    /// so by the time the event is read the port is queued here, or it was never sent and the frame
    /// is dropped at once (before 2026-10-22 each such frame waited 200 ms).
    func surface(for id: UInt64) -> IOSurfaceRef? {
        lock.withLock {
            if let surface = cache.surface(for: id) { return surface }
            guard !isClosed else { return nil }
            // Each pass takes one queued message; others are kept for their own frames.
            var remainingMessages = 16
            while remainingMessages > 0 {
                remainingMessages -= 1
                var received: UInt32 = 0
                var refused: UInt32 = 0
                let message = token.withUnsafeBufferPointer { tokenBytes in
                    yardlet_surface_port_receive(port, 0, hostProcessID, tokenBytes.baseAddress!, &received, &refused)
                }
                rejected += Int(refused)
                guard let message else { break }
                cache.store(message.takeRetainedValue(), token: UInt64(received))
                if UInt64(received) == id { break }
            }
            return cache.surface(for: id)
        }
    }

    /// The surface for a frame event, which from now on belongs to the frame's tab and layer.
    func surface(for frame: BrowserFrame, tab: BrowserTabID) -> IOSurfaceRef? {
        guard let surface = surface(for: frame.surface) else { return nil }
        lock.withLock { cache.noteFrame(frame, tab: tab) }
        return surface
    }

    /// The host released a tab's rings (`hidden`, `closed`), or a popup went away.
    func evict(tab: BrowserTabID, layer: BrowserFrameLayer? = nil) {
        lock.withLock { cache.evict(tab: tab, layer: layer) }
    }

    /// Forgets every surface and destroys the port.
    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            cache.removeAll()
            yardlet_surface_port_destroy(port)
        }
    }
}

/// Events on their way from the event pipe's queue to the main thread. A page frame that is
/// already on screen only tells the main thread that the tab painted, so a later frame of the same
/// tab replaces it while the main thread is busy: a slow main thread gets one frame per tab per
/// turn instead of a backlog.
final class BrowserMainThreadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [BrowserHostEvent] = []
    private var isScheduled = false
    private let deliver: @MainActor ([BrowserHostEvent]) -> Void

    init(deliver: @escaping @MainActor ([BrowserHostEvent]) -> Void) {
        self.deliver = deliver
    }

    func enqueue(_ events: [BrowserHostEvent]) {
        guard !events.isEmpty else { return }
        let schedule: Bool = lock.withLock {
            for event in events {
                if case .frame(let tab, let frame) = event, frame.layer == .view {
                    pending.removeAll {
                        if case .frame(tab, let earlier) = $0 { earlier.layer == .view } else { false }
                    }
                }
                pending.append(event)
            }
            defer { isScheduled = true }
            return !isScheduled
        }
        guard schedule else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.drain() } }
    }

    @MainActor private func drain() {
        let events: [BrowserHostEvent] = lock.withLock {
            isScheduled = false
            defer { pending.removeAll() }
            return pending
        }
        deliver(events)
    }
}
