import AppKit
import QuartzCore
import YardletSimulatorHostProtocol

/// A booted device's screen in a simulator panel, and the person's hands on it.
///
/// The screen is fit into the view, keeping its proportions, with the room around it left empty and no bezel. Its
/// frames reach the layer from the simulator host's pipe queue, or an Android stream's decoder, without the main
/// thread (`SimulatorFrameDisplay`); the view only sizes the layer and says which size it shows the screen at. While
/// nobody can see the view (no window, hidden, its window covered or minimized) it asks for no frames.
///
/// Input goes to the device as the hardware does: a press, a drag and a release are one finger; a trackpad scroll is
/// a finger dragged by as much (the device draws the glide after it), since HID scroll messages are not used; keys go
/// by their place on the keyboard, past the Mac's input method, so the device's own keyboard layout composes text.
/// ⇧⌘H is Home and ⌘L an iOS simulator's lock button, as in Simulator.app, and ⌘W closes the tab; the window's and
/// the menus' keys are Yardlet's first.
@MainActor
final class SimulatorScreenView: NSView, SimulatorScreenSubscriber {
    /// The device the view shows, with the Xcode or SDK that runs it.
    typealias Configuration = MacSimulatorScreens.Target

    /// Room left around the screen.
    static let margin: CGFloat = 16
    /// How far from the screen's edges a scroll starts its finger, so it does not start an edge gesture (Home,
    /// Notification Center, Control Center, going back).
    static let scrollStartInset: CGFloat = 24

    let frameDisplay: SimulatorFrameDisplay
    let screens: MacSimulatorScreens
    var configuration: Configuration? {
        willSet {
            // What the old device holds is let go on the old device.
            if newValue != configuration { endInput() }
        }
        didSet {
            guard configuration != oldValue else { return }
            needsLayout = true
            updateSubscription()
        }
    }
    /// The person pressed, typed or scrolled on the device.
    var onPersonInput: (() -> Void)?
    /// ⌘W with the screen focused.
    var onCloseTab: (() -> Void)?

    private let screenLayer = CALayer()
    private var subscribed: (target: Configuration, pixelWidth: Int, pixelHeight: Int)?
    private var windowObservers: [NSObjectProtocol] = []
    /// The finger a press or a scroll puts down, where it is now.
    private var finger: SimulatorPoint?
    private var fingerIsScroll = false
    private var wheelEnd: Task<Void, Never>?
    private var pressedKeys: Set<SimulatorKeyUsage> = []

    init(screens: MacSimulatorScreens) {
        self.screens = screens
        frameDisplay = SimulatorFrameDisplay(layer: screenLayer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        screenLayer.contentsGravity = .resizeAspect
        screenLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(screenLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Size and visibility

    /// The device's screen as the helper attached it; nil until then.
    private var screen: SimulatorScreen? {
        guard let configuration, case let .attached(screen) = screens.link(of: configuration.device) else { return nil }
        return screen
    }

    /// Where the screen is drawn: fit into the view, inside its margin, on whole points.
    var screenRect: CGRect {
        let room = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        guard let screen, screen.pixelWidth > 0, screen.pixelHeight > 0, room.width > 0, room.height > 0 else {
            return .zero
        }
        let aspect = CGFloat(screen.pixelWidth) / CGFloat(screen.pixelHeight)
        var size = CGSize(width: room.width, height: room.width / aspect)
        if size.height > room.height { size = CGSize(width: room.height * aspect, height: room.height) }
        let origin = CGPoint(x: room.midX - size.width / 2, y: room.midY - size.height / 2)
        return CGRect(origin: origin, size: size).integral
    }

    var screenPixelSize: (width: Int, height: Int)? {
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        return (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    /// Nobody can see the view: no window, a window that is covered, minimized, on another space or in a hidden
    /// app, or the view itself is hidden.
    private var isOccluded: Bool {
        guard let window else { return true }
#if DEBUG
        if Self.ignoresWindowOcclusion { return isHiddenOrHasHiddenAncestor }
#endif
        return !window.occlusionState.contains(.visible) || isHiddenOrHasHiddenAncestor
    }

#if DEBUG
    /// QA draws the panel in a window that is never on screen, whose device must still send frames: a QA bundle
    /// launched with `--ui-fixture-browser-ignore-occlusion`, as for the browser panel, or a test.
    static var ignoresWindowOcclusion = BrowserHostView.qaIgnoresWindowOcclusion
#endif

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.frame = screenRect
        screenLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateSubscription()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        if window == nil { endInput() }
        needsLayout = true
        updateSubscription()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateSubscription()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateSubscription()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// The screen came or changed: the layer takes its place, and the frames its size.
    func screenDidChange() {
        needsLayout = true
    }

    /// Asks for frames of the device at the size the view shows it, or for none while nobody can see it.
    func updateSubscription() {
        guard let configuration, !isOccluded else {
            stopFrames()
            return
        }
        // Another device, or the same emulator on another serial.
        if let subscribed, subscribed.target != configuration { stopFrames() }
        let size = screenPixelSize
        if let subscribed, let size, subscribed.pixelWidth == size.width, subscribed.pixelHeight == size.height {
            return
        }
        if subscribed != nil, size == nil { return }
        screens.show(configuration, in: self)
        subscribed = (configuration, size?.width ?? 0, size?.height ?? 0)
    }

    /// The panel goes: no more frames for it.
    func stopFrames() {
        guard let subscribed else { return }
        self.subscribed = nil
        screens.stopShowing(subscribed.target.device, in: self)
    }

    private func observeWindow() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
        guard let window else { return }
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSubscription() }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        })
    }

    // MARK: - Touches

    /// A point of the view as a fraction of the screen; nil outside it, unless `clamped`, which brings it to the edge.
    private func screenPoint(_ point: NSPoint, clamped: Bool) -> SimulatorPoint? {
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (point.x - rect.minX) / rect.width
        var y = (point.y - rect.minY) / rect.height
        if clamped {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        return SimulatorPoint(x: x, y: y)
    }

    private func location(of event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard finger == nil, let point = screenPoint(location(of: event), clamped: false) else { return }
        putFinger(at: point, scroll: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard finger != nil, !fingerIsScroll, let point = screenPoint(location(of: event), clamped: true) else { return }
        moveFinger(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard finger != nil, !fingerIsScroll else { return }
        if let point = screenPoint(location(of: event), clamped: true) { finger = point }
        liftFinger()
    }

    /// A trackpad's scroll is a finger put down where the pointer is, dragged by the scroll's distance and lifted when
    /// the fingers leave the trackpad; the glide after it is the device's own. A mouse wheel's clicks drag the same
    /// way, lifted when the wheel rests.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let isWheel = event.phase.isEmpty
        if event.phase.contains(.began) || (isWheel && finger == nil) {
            guard finger == nil, let start = scrollStart(at: location(of: event)) else { return }
            putFinger(at: start, scroll: true)
        }
        guard fingerIsScroll, let current = finger else { return }
        let rect = screenRect
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0), rect.width > 0, rect.height > 0,
           let point = SimulatorPoint(x: min(max(current.x + event.scrollingDeltaX * scale / rect.width, 0), 1),
                                      y: min(max(current.y + event.scrollingDeltaY * scale / rect.height, 0), 1)) {
            moveFinger(to: point)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            liftFinger()
        } else if isWheel {
            wheelEnd?.cancel()
            wheelEnd = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.fingerIsScroll else { return }
                self.liftFinger()
            }
        }
    }

    /// Where a scroll puts its finger: under the pointer, kept off the screen's edges.
    private func scrollStart(at location: NSPoint) -> SimulatorPoint? {
        let rect = screenRect
        guard rect.contains(location) else { return nil }
        let insetX = min(Self.scrollStartInset / rect.width, 0.5)
        let insetY = min(Self.scrollStartInset / rect.height, 0.5)
        guard let point = screenPoint(location, clamped: true) else { return nil }
        return SimulatorPoint(x: min(max(point.x, insetX), 1 - insetX), y: min(max(point.y, insetY), 1 - insetY))
    }

    private func putFinger(at point: SimulatorPoint, scroll: Bool) {
        guard let device = configuration?.device else { return }
        finger = point
        fingerIsScroll = scroll
        onPersonInput?()
        screens.touch(.down, at: point, on: device)
    }

    private func moveFinger(to point: SimulatorPoint) {
        guard let device = configuration?.device else { return }
        finger = point
        screens.touch(.move, at: point, on: device)
    }

    private func liftFinger() {
        wheelEnd?.cancel()
        wheelEnd = nil
        guard let point = finger else { return }
        finger = nil
        fingerIsScroll = false
        if let device = configuration?.device { screens.touch(.up, at: point, on: device) }
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performSimulatorShortcut(event, customizedOnly: false) || super.performKeyEquivalent(with: event)
    }

    private func performSimulatorShortcut(_ event: NSEvent, customizedOnly: Bool) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, let device = configuration?.device else { return false }
        let key = MacShortcutEvent(event)
        switch [MacShortcut.simulatorHome, .simulatorLock, .simulatorClose].first(where: {
            (!customizedOnly || $0.isCustomized) && $0.matches(key)
        }) {
        case .simulatorHome:
            onPersonInput?()
            screens.press(.home, on: device)
        case .simulatorLock:
            onPersonInput?()
            screens.press(.lock, on: device)
        case .simulatorClose:
            onCloseTab?()
        default:
            // The window's keys and the menus' come first; a key none of them takes reaches `keyDown`.
            return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !MacShortcutPreferences.shared.snapshot.overrides.isEmpty, performSimulatorShortcut(event, customizedOnly: true) { return }
        // A held key repeats on the device.
        guard !event.isARepeat, let device = configuration?.device,
              let usage = SimulatorKeyMap.usage(forKeyCode: event.keyCode) else { return }
        onPersonInput?()
        pressedKeys.insert(usage)
        screens.key(usage, .down, on: device)
    }

    override func keyUp(with event: NSEvent) {
        guard let device = configuration?.device, let usage = SimulatorKeyMap.usage(forKeyCode: event.keyCode),
              pressedKeys.remove(usage) != nil else { return }
        screens.key(usage, .up, on: device)
    }

    /// Shift, Control, Option and Command go down and up as keys; Caps Lock, which switches the device's keyboard
    /// between its languages, is pressed once at each change.
    override func flagsChanged(with event: NSEvent) {
        guard let device = configuration?.device, let usage = SimulatorKeyMap.usage(forKeyCode: event.keyCode) else {
            return
        }
        if event.keyCode == SimulatorKeyMap.capsLock {
            onPersonInput?()
            screens.key(usage, .press, on: device)
            return
        }
        guard let flag = SimulatorKeyMap.modifierFlags[event.keyCode] else { return }
        // The other key of the pair may still hold the flag: the key's own state decides.
        let isDown = event.modifierFlags.contains(flag) && !pressedKeys.contains(usage)
        if isDown {
            pressedKeys.insert(usage)
            screens.key(usage, .down, on: device)
        } else if pressedKeys.remove(usage) != nil {
            screens.key(usage, .up, on: device)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        return super.resignFirstResponder()
    }

    /// Lets go of every key held and lifts the finger, so nothing stays pressed on the device when the view loses the
    /// keyboard, leaves its window or shows another device.
    private func endInput() {
        liftFinger()
        releaseKeys()
    }

    private func releaseKeys() {
        guard let device = configuration?.device else {
            pressedKeys = []
            return
        }
        for usage in pressedKeys { screens.key(usage, .up, on: device) }
        pressedKeys = []
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? {
        L10n.string("Simulator screen")
    }
}
