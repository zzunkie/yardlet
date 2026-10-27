import AppKit
import IOSurface
import QuartzCore

/// Supplies the page's accessibility elements for a browser view (`BrowserAccessibilityBridge`).
/// The view asks only this one source, so accessibility stays apart from input and drawing.
@MainActor
protocol BrowserAccessibilitySource: AnyObject {
    func accessibilityChildren(for view: BrowserHostView) -> [Any]
    /// The element at a screen point, or nil for the view itself.
    func accessibilityHitTest(_ point: NSPoint, in view: BrowserHostView) -> Any?
    /// The page's focused element, or nil for the view itself.
    func accessibilityFocusedElement(in view: BrowserHostView) -> Any?
    /// The page's title, spoken as the view's label.
    func accessibilityLabel(for view: BrowserHostView) -> String?
}

extension BrowserAccessibilitySource {
    func accessibilityHitTest(_ point: NSPoint, in view: BrowserHostView) -> Any? { nil }
    func accessibilityFocusedElement(in view: BrowserHostView) -> Any? { nil }
    func accessibilityLabel(for view: BrowserHostView) -> String? { nil }
}

/// Keyboard shortcuts the panel handles itself rather than the page, and the mouse's back and forward
/// buttons, which go back and forward in the page's history as the Codex app's browser page sends
/// them (`browser-sidebar-runtime-mouse-navigation`).
enum BrowserPanelShortcut: Equatable {
    case find, focusAddress, reload, back, forward
    /// The task's tabs, as the Claude app's Browser pane: ⌘T, ⌘W, ⌘⇧T, ⌃Tab, ⌃⇧Tab, ⌘1…⌘9.
    case newTab, closeTab, reopenClosedTab, nextTab, previousTab
    case selectTab(Int)
}

/// Shows a browser host tab's frames and forwards input to it. The page is drawn by the host into
/// IOSurfaces; this view only places them in layers. Text input follows cefclient's macOS
/// off-screen text input client: key presses go out as raw keys, and the input method's marked and
/// inserted text go out as composition commands.
@MainActor
final class BrowserHostView: NSView, @preconcurrency NSTextInputClient, MouseHistoryNavigating {
    /// Sends a command for this view's tab. Nil until the tab exists.
    var tabID: BrowserTabID? {
        // Another tab's focused field is not this one's; the panel says the new tab's (`isPasswordFieldFocused`).
        didSet { if tabID != oldValue { isPasswordFieldFocused = false } }
    }
    var sendCommand: ((BrowserHostCommand) -> Void)?
    var surfaceProvider: ((UInt64) -> IOSurfaceRef?)?
    var onViewportChange: ((BrowserViewport) -> Void)?
    /// Called when the view stops or starts being on screen (`isOccluded`).
    var onOcclusionChange: ((Bool) -> Void)?
    /// Whether the page has the keyboard in the key window: the view is the first responder of its window and the
    /// window is key. Called when that may have changed.
    var onKeyboardChange: ((Bool) -> Void)?
    /// The view joined or left a window.
    var onWindowChange: (() -> Void)?
    var onShortcut: ((BrowserPanelShortcut) -> Void)?
    /// Escape while the panel picks an element ends picking instead of reaching the page; true when it did.
    var onEscape: (() -> Bool)?
    weak var accessibilitySource: BrowserAccessibilitySource?

    /// Holds the page's frames and popups in the page's own points, placed and scaled where the page is drawn
    /// (`pageFrame`): the whole view, or an emulated screen size fit into it.
    private let pageLayer = CALayer()
    private let contentLayer = CALayer()
    private let popupLayer = CALayer()
    /// Shows the page's frames from the event pipe's queue (`MacBrowserHost.showFrames(of:in:)`).
    let frameDisplay: BrowserFrameDisplay
    private(set) var popupRect: BrowserRect?
    var viewSurface: IOSurfaceRef? { frameDisplay.currentSurface }
    private(set) var popupSurface: IOSurfaceRef?
    private var cursor = NSCursor.arrow
    private var compositionRects: [BrowserRect] = []
    private var trackingArea: NSTrackingArea?
    private var lastViewport: BrowserViewport?
    private var lastOcclusion: Bool?
    private var windowObservers: [any NSObjectProtocol] = []
    private var pinchAccumulator: CGFloat = 0
    private var dragOperations: BrowserDragOperations = .copy

    // Text input state.
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var isHandlingKeyDown = false
    private var pendingInsertion: String?
    private var pendingComposition: BrowserComposition?
    private var pendingUnmark = false
    /// The input method passed the key's command on (`doCommand(by:)`) instead of using the key.
    private var passedCommand = false

    // Context menu state.
    private var menuCommand: Int?

    // Password fields.
    /// The shown tab's focused field is a password field (the host's `passwordField`).
    var isPasswordFieldFocused = false {
        didSet { if isPasswordFieldFocused != oldValue { updateSecureInput() } }
    }
    var secureInput: any BrowserSecureInputSystem = BrowserSecureInput.system
    /// Secure keyboard entry and the Roman input sources are on for this view (`updateSecureInput`).
    private(set) var isInSecureInputState = false

    override init(frame: NSRect) {
        frameDisplay = BrowserFrameDisplay(layer: contentLayer)
        super.init(frame: frame)
        wantsLayer = true
        // A frame larger than the panel (the agent's full-page screenshot draws the tab at the page's size
        // for a moment) stays inside it.
        clipsToBounds = true
        layer?.backgroundColor = NSColor.white.cgColor
        pageLayer.anchorPoint = .zero
        pageLayer.masksToBounds = true
        pageLayer.backgroundColor = NSColor.white.cgColor
        pageLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layer?.addSublayer(pageLayer)
        for sublayer in [contentLayer, popupLayer] {
            sublayer.anchorPoint = .zero
            sublayer.contentsGravity = .topLeft
            sublayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            pageLayer.addSublayer(sublayer)
        }
        popupLayer.isHidden = true
        popupLayer.zPosition = 1
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { L10n.string("Web content") }
    override func accessibilityChildren() -> [Any]? {
        accessibilitySource?.accessibilityChildren(for: self) ?? []
    }
    override func accessibilityLabel() -> String? {
        accessibilitySource?.accessibilityLabel(for: self)
    }
    // AppKit declares these two nonisolated; it calls them on the main thread.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var element: Any?
        MainActor.assumeIsolated { element = accessibilitySource?.accessibilityHitTest(point, in: self) }
        return element ?? self
    }
    override var accessibilityFocusedUIElement: Any? {
        nonisolated(unsafe) var element: Any?
        MainActor.assumeIsolated { element = accessibilitySource?.accessibilityFocusedElement(in: self) }
        return element ?? self
    }

    // MARK: Viewport

    /// The screen size the shown tab's page is emulated at (`BrowserTab.emulation`): the tab is drawn at it and
    /// the view fits it in, scaled down when it is larger. Nil: the page takes the view's size.
    var emulatedSize: CGSize? {
        didSet {
            guard emulatedSize != oldValue else { return }
            placePage()
            reportViewportIfChanged()
        }
    }

    var viewport: BrowserViewport {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var screenX = 0.0, screenY = 0.0
        let page = pageFrame
        if let window, let screen = window.screen ?? NSScreen.main {
            let onScreen = window.convertToScreen(convert(CGRect(origin: page.origin, size: bounds.size), to: nil))
            screenX = onScreen.minX
            screenY = screen.frame.maxY - onScreen.maxY
        }
        let size = emulatedSize ?? bounds.size
        return BrowserViewport(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()),
                               scale: scale, screenX: screenX, screenY: screenY,
                               framesPerSecond: window?.screen.map { max(1, $0.maximumFramesPerSecond) })
    }

    /// Where the page is drawn in the view and at what scale: the whole view, or an emulated size scaled down to
    /// fit, across the middle and from the top (`BrowserViewportEmulation.pageFrame`).
    var pageFrame: (origin: CGPoint, scale: CGFloat) {
        guard let emulatedSize else { return (.zero, 1) }
        return BrowserViewportEmulation.pageFrame(for: emulatedSize, in: bounds.size)
    }

    /// A point in the view as the page's own (its CSS pixels at zoom 1).
    func pagePoint(_ point: NSPoint) -> NSPoint {
        let page = pageFrame
        return NSPoint(x: (point.x - page.origin.x) / page.scale, y: (point.y - page.origin.y) / page.scale)
    }

    /// A rectangle in the page's points as the view shows it.
    func viewRect(_ rect: NSRect) -> NSRect {
        let page = pageFrame
        return NSRect(x: page.origin.x + rect.minX * page.scale, y: page.origin.y + rect.minY * page.scale,
                      width: rect.width * page.scale, height: rect.height * page.scale)
    }

    /// Places the page's layer where `pageFrame` says, with the space around an emulated size in the gray macOS
    /// puts behind a page (Preview's).
    private func placePage() {
        let page = pageFrame
        let size = emulatedSize ?? bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.bounds = CGRect(origin: .zero, size: size)
        pageLayer.position = page.origin
        pageLayer.setAffineTransform(CGAffineTransform(scaleX: page.scale, y: page.scale))
        var backdrop = NSColor.white.cgColor
        var edge: CGColor?
        if emulatedSize != nil {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                backdrop = NSColor.underPageBackgroundColor.cgColor
                edge = NSColor.separatorColor.cgColor
            }
        }
        layer?.backgroundColor = backdrop
        // One point around the page, whatever its scale.
        pageLayer.borderColor = edge
        pageLayer.borderWidth = edge == nil ? 0 : 1 / max(page.scale, 0.01)
        CATransaction.commit()
    }

    /// Nobody can see the view: it has no window, its window is miniaturized, covered, on another
    /// space or in a hidden app, or the view itself is hidden.
    var isOccluded: Bool {
        guard let window else { return true }
#if DEBUG
        if Self.qaIgnoresWindowOcclusion { return isHiddenOrHasHiddenAncestor }
#endif
        return !window.occlusionState.contains(.visible) || isHiddenOrHasHiddenAncestor
    }

#if DEBUG
    /// QA bundles launch in the background (`open -g`) and their window often sits under other
    /// windows or on another space; the panel checks of scripts/browser-host-qa/run-check.sh need it
    /// to paint anyway. Occlusion itself is covered by BrowserHostVisibilityTests and run-perf.sh.
    static let qaIgnoresWindowOcclusion = CommandLine.arguments.contains("--ui-fixture-browser-ignore-occlusion")
#endif

    override func layout() {
        super.layout()
        placePage()
        reportViewportIfChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        placePage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        observeWindow()
        reportViewportIfChanged()
        reportOcclusionIfChanged()
        updateSecureInput()
        reportKeyboard()
        onWindowChange?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reportOcclusionIfChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reportOcclusionIfChanged()
    }

    private func observeWindow() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
        guard let window else { return }
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportOcclusionIfChanged() }
        })
        // Another display may have another refresh rate at the same scale.
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportViewportIfChanged() }
        })
        // Secure keyboard entry follows the key window: another window, a sheet, another app.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateSecureInput()
                    self?.reportKeyboard()
                }
            })
        }
    }

    private func reportOcclusionIfChanged() {
        let occluded = isOccluded
        guard occluded != lastOcclusion else { return }
        lastOcclusion = occluded
        onOcclusionChange?(occluded)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
        reportViewportIfChanged()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? 2
        frameDisplay.setScale(scale)
        popupLayer.contentsScale = scale
    }

    /// Sends the current size and position again, for a tab that was just attached.
    func resendViewport() {
        lastViewport = nil
        reportViewportIfChanged()
    }

    private func reportViewportIfChanged() {
        let viewport = viewport
        guard viewport.width != lastViewport?.width || viewport.height != lastViewport?.height
                || viewport.scale != lastViewport?.scale || viewport.framesPerSecond != lastViewport?.framesPerSecond else { return }
        lastViewport = viewport
        onViewportChange?(viewport)
        if let tabID { sendCommand?(.resize(tab: tabID, viewport: viewport)) }
    }

    // MARK: Frames

    /// A frame event on the main thread. The page's frames are normally on screen already
    /// (`frameDisplay`); popup frames, and a page frame no display showed, are placed here.
    func show(_ frame: BrowserFrame) {
        guard frame.layer == .popup || !frameDisplay.hasShown(frame),
              let surface = surfaceProvider?(frame.surface) else { return }
        guard frame.layer == .popup else { return frameDisplay.show(frame, surface: surface) }
        let scale = window?.backingScaleFactor ?? popupLayer.contentsScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popupLayer.contents = surface
        if let popupRect {
            popupLayer.frame = CGRect(x: popupRect.x, y: popupRect.y,
                                      width: CGFloat(frame.pixelWidth) / scale, height: CGFloat(frame.pixelHeight) / scale)
        }
        popupLayer.isHidden = popupRect == nil
        CATransaction.commit()
        popupSurface = surface
    }

    func setPopup(_ rect: BrowserRect?) {
        popupRect = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            popupLayer.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        } else {
            popupLayer.contents = nil
            popupSurface = nil
        }
        popupLayer.isHidden = rect == nil || popupSurface == nil
        CATransaction.commit()
    }

    func clear() {
        frameDisplay.clear()
        popupLayer.contents = nil
        popupSurface = nil
        popupRect = nil
        toolTip = nil
    }

    func setCompositionBounds(_ rects: [BrowserRect]) {
        compositionRects = rects
    }

    func setTooltip(_ text: String?) {
        toolTip = text
    }

    func setDragOperations(_ raw: Int) {
        dragOperations = BrowserDragOperations(rawValue: raw)
    }

    // MARK: Cursor

    func setCursor(_ value: BrowserCursor) {
        cursor = switch value {
        case .hand: .pointingHand
        case .text: .iBeam
        case .crosshair: .crosshair
        case .notAllowed: .operationNotAllowed
        case .resizeEast, .resizeWest, .resizeEastWest, .resizeColumn: .resizeLeftRight
        case .resizeNorth, .resizeSouth, .resizeNorthSouth, .resizeRow: .resizeUpDown
        case .grab: .openHand
        case .grabbing, .move: .closedHand
        case .contextMenu: .contextualMenu
        case .copy: .dragCopy
        case .alias: .dragLink
        default: .arrow
        }
        window?.invalidateCursorRects(for: self)
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            cursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(.down, .left, event)
    }
    override func mouseUp(with event: NSEvent) { sendMouse(.up, .left, event) }
    override func mouseDragged(with event: NSEvent) { sendMouse(.move, nil, event) }
    override func mouseMoved(with event: NSEvent) { sendMouse(.move, nil, event) }
    override func mouseExited(with event: NSEvent) { sendMouse(.leave, nil, event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(.down, .right, event)
    }
    override func rightMouseUp(with event: NSEvent) { sendMouse(.up, .right, event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(.move, nil, event) }
    /// Chromium's mouse input knows left, middle and right only; the back and forward buttons go to the
    /// page's history on release instead of reaching the page as a middle click.
    override func otherMouseDown(with event: NSEvent) {
        guard MouseNavigationButton(event) == nil else { return }
        sendMouse(.down, .middle, event)
    }
    override func otherMouseUp(with event: NSEvent) {
        switch MouseNavigationButton(event) {
        case .back?: onShortcut?(.back)
        case .forward?: onShortcut?(.forward)
        case nil: sendMouse(.up, .middle, event)
        }
    }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(.move, nil, event) }

    /// Trackpad scrolling arrives with precise deltas through its phases and the momentum that
    /// follows, so inertia continues in the page; mouse wheels send line deltas.
    override func scrollWheel(with event: NSEvent) {
        guard let tabID else { return }
        let point = pagePoint(convert(event.locationInWindow, from: nil))
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        var modifiers = Self.modifiers(event.modifierFlags)
        if event.hasPreciseScrollingDeltas {
            modifiers.insert(.preciseScrolling)
        } else {
            deltaX *= 40
            deltaY *= 40
        }
        guard deltaX != 0 || deltaY != 0 else { return }
        sendCommand?(.wheel(tab: tabID, input: BrowserWheelInput(
            x: point.x, y: point.y, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers
        )))
    }

    /// Pinch to zoom, in the same steps as ⌘+ and ⌘−.
    override func magnify(with event: NSEvent) {
        guard let tabID else { return }
        if event.phase == .began { pinchAccumulator = 0 }
        pinchAccumulator += event.magnification
        if pinchAccumulator > 0.15 {
            sendCommand?(.zoom(tab: tabID, action: .zoomIn))
            pinchAccumulator = 0
        } else if pinchAccumulator < -0.15 {
            sendCommand?(.zoom(tab: tabID, action: .zoomOut))
            pinchAccumulator = 0
        }
    }

    private func sendMouse(_ kind: BrowserMouseInput.Kind, _ button: BrowserMouseButton?, _ event: NSEvent) {
        guard let tabID else { return }
        let point = pagePoint(convert(event.locationInWindow, from: nil))
        // A press beside an emulated screen size is not on the page.
        if kind == .down, emulatedSize != nil, let size = emulatedSize,
           !CGRect(origin: .zero, size: size).contains(point) { return }
        var modifiers = Self.modifiers(event.modifierFlags)
        let pressed = NSEvent.pressedMouseButtons
        if kind != .up {
            if pressed & 1 != 0 { modifiers.insert(.leftButton) }
            if pressed & 2 != 0 { modifiers.insert(.rightButton) }
            if pressed & 4 != 0 { modifiers.insert(.middleButton) }
        }
        let clickCount = event.type == .mouseMoved || event.type == .mouseExited ? 0 : event.clickCount
        sendCommand?(.mouse(tab: tabID, input: BrowserMouseInput(
            kind: kind, x: point.x, y: point.y, button: button, clickCount: max(1, clickCount), modifiers: modifiers
        )))
    }

    // MARK: Drag and drop (files from Finder onto the page)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let files = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let tabID, !files.isEmpty else { return [] }
        dragOperations = .copy
        sendDrag(.enter, sender, files: files.map { $0.path(percentEncoded: false) }, tab: tabID)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tabID else { return [] }
        sendDrag(.over, sender, files: [], tab: tabID)
        if dragOperations.contains(.copy) { return .copy }
        if dragOperations.contains(.link) { return .link }
        if dragOperations.contains(.move) || dragOperations.contains(.generic) { return .generic }
        return []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard let tabID else { return }
        sendCommand?(.drag(tab: tabID, input: BrowserDragInput(phase: .leave, x: 0, y: 0)))
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tabID else { return false }
        sendDrag(.drop, sender, files: [], tab: tabID)
        return true
    }

    private func sendDrag(_ phase: BrowserDragInput.Phase, _ sender: any NSDraggingInfo, files: [String], tab: BrowserTabID) {
        let point = pagePoint(convert(sender.draggingLocation, from: nil))
        var allowed: BrowserDragOperations = []
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { allowed.insert(.copy) }
        if mask.contains(.link) { allowed.insert(.link) }
        if mask.contains(.generic) { allowed.insert(.generic) }
        if mask.contains(.move) { allowed.insert(.move) }
        sendCommand?(.drag(tab: tab, input: BrowserDragInput(
            phase: phase, x: point.x, y: point.y, files: files,
            operations: (allowed.isEmpty ? .copy : allowed).rawValue,
            modifiers: Self.modifiers(NSEvent.modifierFlags)
        )))
    }

    // MARK: Focus

    /// The view is its window's first responder: the shown tab's page has the keyboard.
    var hasKeyboardFocus: Bool { window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        if let tabID { sendCommand?(.focus(tab: tabID, isFocused: true)) }
        updateSecureInput(hasKeyboard: true)
        reportKeyboard(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let tabID {
            if hasMarkedText() { sendCommand?(.composition(tab: tabID, composition: .cancel)) }
            markedText = ""
            sendCommand?(.focus(tab: tabID, isFocused: false))
        }
        updateSecureInput(hasKeyboard: false)
        reportKeyboard(false)
        return true
    }

    /// `hasKeyboard` stands in for the first responder inside becoming and resigning it, as for secure input.
    private func reportKeyboard(_ hasKeyboard: Bool? = nil) {
        onKeyboardChange?((hasKeyboard ?? hasKeyboardFocus) && window?.isKeyWindow == true)
    }

    /// Secure keyboard entry and Roman input sources only, exactly while the page's password field has the
    /// keyboard: the view shows a tab whose focused field is a password field and is the first responder of
    /// the key window (WebKit's `WebViewImpl::updateSecureInputState`). Leaving the field or the view (a
    /// hidden view gives up the first responder), another tab, a removed view, another window or app, and
    /// the tab's renderer or host ending turn both off; each enable has one disable. `hasKeyboard` stands
    /// in for the first responder inside becoming and resigning it, before the window has switched.
    private func updateSecureInput(hasKeyboard: Bool? = nil) {
        let secure = isPasswordFieldFocused && tabID != nil && (hasKeyboard ?? hasKeyboardFocus)
            && window.map(secureInput.isKeyWindow) == true
        guard secure != isInSecureInputState else { return }
        isInSecureInputState = secure
        if secure {
            secureInput.setSecureEventInput(true)
            secureInput.setRomanInputSourcesOnly(true, in: inputContext)
        } else {
            secureInput.setRomanInputSourcesOnly(false, in: inputContext)
            secureInput.setSecureEventInput(false)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText(), onEscape?() == true { return }
        keyDown(event) { [self] in
            if inputContext?.handleEvent(event) != true {
                interpretKeyEvents([event])
            }
        }
    }

    /// `interpret` runs the input method on the key; its marked and inserted text and the commands it
    /// passes on arrive meanwhile through NSTextInputClient.
    func keyDown(_ event: NSEvent, interpret: () -> Void) {
        guard let tabID else { return }
        let hadMarkedText = hasMarkedText()
        isHandlingKeyDown = true
        pendingInsertion = nil
        pendingComposition = nil
        pendingUnmark = false
        passedCommand = false
        interpret()
        isHandlingKeyDown = false

        let imeConsumed = hadMarkedText || pendingComposition != nil || hasMarkedText()
        var key = Self.keyInput(.rawDown, event)
        // Chromium reports a key an input method used as "Process" (229).
        if imeConsumed { key.windowsKeyCode = BrowserKeyCodes.inputMethodProcessKey }
        sendCommand?(.key(tab: tabID, input: key))

        if let text = pendingInsertion {
            if imeConsumed || text.utf16.count != 1 {
                sendCommand?(.composition(tab: tabID, composition: .commit(text: text, replacement: nil, relativeCursor: 0)))
            } else {
                var character = Self.keyInput(.character, event)
                character.character = text.utf16.first ?? 0
                sendCommand?(.key(tab: tabID, input: character))
            }
        } else if !imeConsumed, let code = event.characters?.utf16.first, code == 13 || code == 3 || code == 9 {
            // Return, Enter and Tab also produce a character event, which inserts a line, submits a
            // form or inserts a tab where the page allows it.
            var character = Self.keyInput(.character, event)
            character.character = code == 3 ? 13 : code
            sendCommand?(.key(tab: tabID, input: character))
        }
        if let composition = pendingComposition {
            sendCommand?(.composition(tab: tabID, composition: composition))
        } else if pendingUnmark, pendingInsertion == nil {
            sendCommand?(.composition(tab: tabID, composition: .finish(keepSelection: false)))
        }
        // The input method finished its text with this key and passed the key on (Korean commits the
        // syllable, then Return, an arrow or Tab acts): as in Chrome, the page gets the key itself
        // after the text. Before, it got only "Process" and the first Return after Hangul was lost.
        if imeConsumed, passedCommand, !hasMarkedText() {
            sendCommand?(.key(tab: tabID, input: Self.keyInput(.rawDown, event)))
            if let code = event.characters?.utf16.first, code == 13 || code == 3 || code == 9 {
                var character = Self.keyInput(.character, event)
                character.character = code == 3 ? 13 : code
                sendCommand?(.key(tab: tabID, input: character))
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let tabID, !hasMarkedText() else { return }
        sendCommand?(.key(tab: tabID, input: Self.keyInput(.up, event)))
    }

    /// Shift, Control, Option, Command and Caps Lock arrive as flag changes; pages see them as
    /// key presses and releases.
    override func flagsChanged(with event: NSEvent) {
        guard let tabID, let modifier = BrowserKeyCodes.modifierKeys[event.keyCode] else { return }
        var input = Self.keyInput(.rawDown, event)
        input.modifiers.insert(modifier.isRight ? .isRight : .isLeft)
        if modifier.flag == .capsLock {
            sendCommand?(.key(tab: tabID, input: input))
            input.kind = .up
            sendCommand?(.key(tab: tabID, input: input))
            return
        }
        input.kind = event.modifierFlags.contains(modifier.flag) ? .rawDown : .up
        sendCommand?(.key(tab: tabID, input: input))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        // ⌃Tab and ⌃⇧Tab move between the task's tabs while the page has focus.
        if event.keyCode == 48, flags.subtracting(.shift) == .control {
            onShortcut?(shift ? .previousTab : .nextTab)
            return true
        }
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if !shift, flags.subtracting([.command, .numericPad]).isEmpty,
           let number = Int(key), (1...9).contains(number) {
            onShortcut?(.selectTab(number))
            return true
        }
        switch key {
        case "t": onShortcut?(shift ? .reopenClosedTab : .newTab)
        case "w" where !shift: onShortcut?(.closeTab)
        case "c": edit(.copy)
        case "x": edit(.cut)
        case "v": edit(.paste)
        case "a": edit(.selectAll)
        case "z": edit(shift ? .redo : .undo)
        case "=", "+": zoom(.zoomIn)
        case "-": zoom(.zoomOut)
        case "0": zoom(.reset)
        case "f": onShortcut?(.find)
        case "l": onShortcut?(.focusAddress)
        case "r": onShortcut?(.reload)
        case "[": onShortcut?(.back)
        case "]": onShortcut?(.forward)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func copy(_ sender: Any?) { edit(.copy) }
    @objc func cut(_ sender: Any?) { edit(.cut) }
    @objc func paste(_ sender: Any?) { edit(.paste) }
    @objc override func selectAll(_ sender: Any?) { edit(.selectAll) }
    @objc func undo(_ sender: Any?) { edit(.undo) }
    @objc func redo(_ sender: Any?) { edit(.redo) }
    @objc func delete(_ sender: Any?) { edit(.delete) }

    private func edit(_ action: BrowserEditAction) {
        guard let tabID else { return }
        sendCommand?(.edit(tab: tabID, action: action))
    }

    private func zoom(_ action: BrowserZoomAction) {
        guard let tabID else { return }
        sendCommand?(.zoom(tab: tabID, action: action))
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if isHandlingKeyDown {
            pendingInsertion = (pendingInsertion ?? "") + text
            pendingComposition = nil
            pendingUnmark = false
        } else if let tabID {
            sendCommand?(.composition(tab: tabID, composition: .commit(
                text: text, replacement: Self.range(replacementRange), relativeCursor: 0
            )))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        let hadMarkedText = hasMarkedText()
        markedText = attributed.string
        markedSelection = selectedRange
        let composition: BrowserComposition
        if markedText.isEmpty {
            guard hadMarkedText else { return }
            composition = .cancel
        } else {
            composition = .set(
                text: markedText,
                underlines: Self.underlines(for: attributed, selectedRange: selectedRange),
                selection: BrowserTextRange(location: selectedRange.location, length: selectedRange.length),
                replacement: Self.range(replacementRange)
            )
        }
        if isHandlingKeyDown {
            pendingComposition = composition
        } else if let tabID {
            sendCommand?(.composition(tab: tabID, composition: composition))
        }
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        markedText = ""
        if isHandlingKeyDown {
            pendingUnmark = true
        } else if let tabID {
            sendCommand?(.composition(tab: tabID, composition: .finish(keepSelection: false)))
        }
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect: NSRect
        if !compositionRects.isEmpty {
            let index = range.location == NSNotFound ? 0 : min(range.location, compositionRects.count - 1)
            let bounds = compositionRects[index]
            rect = NSRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        } else {
            rect = NSRect(x: 0, y: 0, width: 0, height: 20)
        }
        guard let window else { return .zero }
        return window.convertToScreen(convert(viewRect(rect), to: nil))
    }

    override func doCommand(by selector: Selector) {
        // Editing keys (Delete, arrows) reach the page as raw key presses (`keyDown`), also when an
        // input method passes one on.
        if isHandlingKeyDown { passedCommand = true }
    }

    // MARK: Context menu

    /// Yardlet's own items after the page's (the vault's "Add to Password Manager…" and "Make a Yardlet Passkey", and
    /// "Import Sign-ins from Another Browser…").
    var extraContextMenuItems: (() -> [(title: String, action: () -> Void)])?
    private var extraMenuAction: (() -> Void)?

    func showContextMenu(_ contextMenu: BrowserContextMenu) {
        guard let tabID else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        extraMenuAction = nil
        let extras = extraContextMenuItems?() ?? []
        for item in contextMenu.items {
            guard let commandID = item.commandID else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = commandID
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? .on : .off
            menu.addItem(menuItem)
        }
        if !extras.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for (index, extra) in extras.enumerated() {
                let item = NSMenuItem(title: extra.title, action: #selector(extraMenuItemChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }
        menuCommand = nil
        // Show after the current event finishes; popUp runs its own tracking loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            menu.popUp(positioning: nil, at: self.viewRect(NSRect(x: contextMenu.x, y: contextMenu.y, width: 0, height: 0)).origin,
                       in: self)
            let chosen = self.menuCommand
            self.menuCommand = nil
            self.sendCommand?(.contextMenuResult(tab: tabID, menu: contextMenu.id, commandID: chosen))
            let extra = self.extraMenuAction
            self.extraMenuAction = nil
            extra?()
        }
        extrasForMenu = extras
    }

    private var extrasForMenu: [(title: String, action: () -> Void)] = []

    @objc private func contextMenuItemChosen(_ sender: NSMenuItem) {
        menuCommand = sender.tag
    }

    @objc private func extraMenuItemChosen(_ sender: NSMenuItem) {
        menuCommand = nil
        guard extrasForMenu.indices.contains(sender.tag) else { return }
        extraMenuAction = extrasForMenu[sender.tag].action
    }

    // MARK: Conversions

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> BrowserModifiers {
        var modifiers: BrowserModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.keypad) }
        return modifiers
    }

    static func keyInput(_ kind: BrowserKeyInput.Kind, _ event: NSEvent) -> BrowserKeyInput {
        var modifiers = modifiers(event.modifierFlags)
        if BrowserKeyCodes.keypadKeyCodes.contains(event.keyCode) { modifiers.insert(.keypad) }
        let isKeyEvent = event.type == .keyDown || event.type == .keyUp
        if isKeyEvent, event.isARepeat { modifiers.insert(.isRepeat) }
        return BrowserKeyInput(
            kind: kind,
            windowsKeyCode: BrowserKeyCodes.windowsKeyCode(forMacKeyCode: event.keyCode),
            nativeKeyCode: Int(event.keyCode),
            character: isKeyEvent ? event.characters?.utf16.first ?? 0 : 0,
            unmodifiedCharacter: isKeyEvent ? event.charactersIgnoringModifiers?.utf16.first ?? 0 : 0,
            modifiers: modifiers,
            isSystemKey: false
        )
    }

    private static func range(_ range: NSRange) -> BrowserTextRange? {
        range.location == NSNotFound ? nil : BrowserTextRange(location: range.location, length: range.length)
    }

    /// A thin underline under each clause the input method marks, thick under the selected one.
    static func underlines(for text: NSAttributedString, selectedRange: NSRange) -> [BrowserCompositionUnderline] {
        var underlines: [BrowserCompositionUnderline] = []
        text.enumerateAttribute(.markedClauseSegment, in: NSRange(location: 0, length: text.length)) { _, range, _ in
            let isSelected = selectedRange.length > 0 && NSIntersectionRange(range, selectedRange).length > 0
            underlines.append(BrowserCompositionUnderline(
                range: BrowserTextRange(location: range.location, length: range.length), isThick: isSelected
            ))
        }
        if underlines.isEmpty {
            underlines = [BrowserCompositionUnderline(range: BrowserTextRange(location: 0, length: text.length), isThick: false)]
        }
        return underlines
    }
}
