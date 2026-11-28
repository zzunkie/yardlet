import AppKit

/// Gives VoiceOver and other macOS accessibility clients the page inside a browser panel. The
/// host's windowless Chromium computes the page's accessibility tree only while this bridge asks
/// for it; the bridge turns the tree into `NSAccessibilityElement`s under the panel view and
/// performs their actions with the panel's own mouse input (press) or in the page itself (focus,
/// value, options, scrolling).
///
/// The tree is on only when something reads it: VoiceOver is running, or an accessibility client
/// asked for the view's children in the last `idleTimeout`. It goes off when the panel closes.
@MainActor
final class BrowserAccessibilityBridge: BrowserAccessibilitySource {
    typealias Key = BrowserAccessibilityKey

    let tree = BrowserAccessibilityTree()
    private weak var tab: BrowserTab?
    private weak var view: BrowserHostView?
    private let idleTimeout: Duration
    private var elements: [Key: BrowserAccessibilityElement] = [:]
    private(set) var isEnabled = false
    private var lastQuery = ContinuousClock.now
    private var idleTask: Task<Void, Never>?
    private var layoutNotificationTask: Task<Void, Never>?
    private var voiceOverObservation: NSKeyValueObservation?
    /// Waiters for the next tree or location change (actions that scroll first wait for one).
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var statistics = Statistics()

    struct Statistics: Equatable, Sendable {
        var treeChanges = 0
        var locationChanges = 0
        var applyMilliseconds = 0.0
        var slowestApplyMilliseconds = 0.0
        var scrollChanges = 0
        var enableCount = 0
        var disableCount = 0
    }

    /// Why the tree last turned on: `voiceOver`, or the accessibility request that asked
    /// (`children`, `hitTest`, `focusedElement`, `element`).
    private(set) var enableReason: String?

    /// Called when the tree turns on or off (QA fixtures record it).
    var onEnabledChange: ((Bool) -> Void)?
#if DEBUG
    /// QA fixtures choose `<select>` options without the native menu.
    var optionsMenuOverride: (([String]) -> Int?)?
#endif

    init(tab: BrowserTab, view: BrowserHostView, idleTimeout: Duration = .seconds(60)) {
        self.tab = tab
        self.view = view
        self.idleTimeout = idleTimeout
    }

    func start() {
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceOverChanged() } }
        }
        if NSWorkspace.shared.isVoiceOverEnabled { enable(reason: "voiceOver") }
    }

    /// The panel closed or the tab went away.
    func stop(sendingDisable: Bool = true) {
        voiceOverObservation?.invalidate()
        voiceOverObservation = nil
        idleTask?.cancel()
        layoutNotificationTask?.cancel()
        if isEnabled { disable(sending: sendingDisable) }
        resumeWaiters()
    }

    private func voiceOverChanged() {
        if NSWorkspace.shared.isVoiceOverEnabled {
            enable(reason: "voiceOver")
        } else {
            scheduleIdleCheck()
        }
    }

    private func enable(reason: String) {
        guard !isEnabled, let tab else { return }
        isEnabled = true
        enableReason = reason
        statistics.enableCount += 1
        tab.send(.accessibility(tab: tab.id, isEnabled: true))
        scheduleIdleCheck()
        onEnabledChange?(true)
    }

    private func disable(sending: Bool = true) {
        guard isEnabled else { return }
        isEnabled = false
        statistics.disableCount += 1
        if sending, let tab { tab.send(.accessibility(tab: tab.id, isEnabled: false)) }
        tree.reset()
        elements = [:]
        onEnabledChange?(false)
    }

    /// An accessibility client read the page: keep the tree on (or turn it on).
    func noteAccessibilityQuery(_ reason: String = "element") {
        lastQuery = .now
        if !isEnabled { enable(reason: reason) }
    }

    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.idleTimeout - (ContinuousClock.now - self.lastQuery)
                try? await Task.sleep(for: max(wait, .milliseconds(200)))
                guard !Task.isCancelled, self.isEnabled else { return }
                if !NSWorkspace.shared.isVoiceOverEnabled, ContinuousClock.now - self.lastQuery >= self.idleTimeout {
                    self.disable()
                    return
                }
                if NSWorkspace.shared.isVoiceOverEnabled { return }
            }
        }
    }

    // MARK: Events

    func handle(_ event: BrowserHostEvent) {
        guard isEnabled else { return }
        let started = ContinuousClock.now
        switch event {
        case .discarded:
            tree.reset()
            elements = [:]
        case .accessibilityTree(_, let change):
            let summary = tree.apply(change)
            statistics.treeChanges += 1
            post(summary)
        case .accessibilityLocations(_, let changes):
            tree.apply(changes)
            statistics.locationChanges += 1
        case .scrollOffset(_, let x, let y):
            tree.setMainScroll(x: x * pixelsPerPoint, y: y * pixelsPerPoint)
            statistics.scrollChanges += 1
        default:
            return
        }
        let elapsed = (ContinuousClock.now - started) / .milliseconds(1)
        statistics.applyMilliseconds += elapsed
        statistics.slowestApplyMilliseconds = max(statistics.slowestApplyMilliseconds, elapsed)
        resumeWaiters()
    }

    private func post(_ summary: BrowserAccessibilityChangeSummary) {
        guard let view else { return }
        if summary.documentChanged { elements = [:] }
        var destroyed: [BrowserAccessibilityElement] = []
        for key in summary.removed {
            if let element = elements.removeValue(forKey: key) { destroyed.append(element) }
        }
        if destroyed.count <= 20 {
            for element in destroyed { NSAccessibility.post(element: element, notification: .uiElementDestroyed) }
        }
        for key in summary.valueChanged {
            if let element = elements[key] { NSAccessibility.post(element: element, notification: .valueChanged) }
        }
        for key in summary.nameChanged {
            if let element = elements[key] { NSAccessibility.post(element: element, notification: .titleChanged) }
        }
        if summary.structureChanged || summary.loadCompleted { scheduleLayoutNotification() }
        if summary.focusChanged, view.window?.firstResponder === view, let focus = tree.focus,
           let node = tree.node(focus), tree.isExposed(node), tree.isShown(focus) {
            NSAccessibility.post(element: element(for: focus), notification: .focusedUIElementChanged)
        }
    }

    /// One layout notification per burst of structural changes.
    private func scheduleLayoutNotification() {
        guard layoutNotificationTask == nil else { return }
        layoutNotificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.layoutNotificationTask = nil
            if let view = self.view { NSAccessibility.post(element: view, notification: .layoutChanged) }
        }
    }

    private func resumeWaiters() {
        let waiting = changeWaiters
        changeWaiters = []
        waiting.forEach { $0.resume() }
    }

    private func nextChange(timeout: Duration) async {
        await withCheckedContinuation { continuation in
            changeWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiters()
            }
        }
    }

    // MARK: BrowserAccessibilitySource

    func accessibilityChildren(for view: BrowserHostView) -> [Any] {
        noteAccessibilityQuery("children")
        return tree.exposedChildren(of: nil).map { element(for: $0) }
    }

    func accessibilityHitTest(_ point: NSPoint, in view: BrowserHostView) -> Any? {
        noteAccessibilityQuery("hitTest")
        guard let window = view.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: point)
        let viewPoint = view.pagePoint(view.convert(windowPoint, from: nil))
        let scale = pixelsPerPoint
        guard let key = tree.exposedNode(at: (Double(viewPoint.x) * scale, Double(viewPoint.y) * scale)) else { return nil }
        return element(for: key)
    }

    func accessibilityFocusedElement(in view: BrowserHostView) -> Any? {
        noteAccessibilityQuery("focusedElement")
        guard let focus = tree.focus, let node = tree.node(focus), tree.isExposed(node) else { return nil }
        return element(for: focus)
    }

    func accessibilityLabel(for view: BrowserHostView) -> String? {
        tree.title
    }

    // MARK: Elements

    func element(for key: Key) -> BrowserAccessibilityElement {
        if let element = elements[key] { return element }
        let element = BrowserAccessibilityElement(key: key, bridge: self)
        elements[key] = element
        return element
    }

    func children(of key: Key) -> [Any] {
        noteAccessibilityQuery()
        return tree.exposedChildren(of: key).map { element(for: $0) }
    }

    func parent(of key: Key) -> Any? {
        if let parent = tree.exposedParent(of: key) { return element(for: parent) }
        return view
    }

    var window: NSWindow? { view?.window }

    /// Engine page pixels per view point. Chromium reports bounds in device pixels.
    var pixelsPerPoint: Double { max(view?.viewport.scale ?? 1, 1) }

    /// The node's bounds in the panel view (points, top-left origin), or nil without bounds.
    func viewRect(of key: Key) -> NSRect? {
        guard let bounds = tree.pageBounds(of: key) else { return nil }
        let scale = pixelsPerPoint
        let page = NSRect(x: bounds.x / scale, y: bounds.y / scale, width: bounds.width / scale, height: bounds.height / scale)
        return view?.viewRect(page) ?? page
    }

    func screenFrame(of key: Key) -> NSRect {
        guard let view, let window = view.window, let rect = viewRect(of: key) else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    var isViewFocused: Bool {
        guard let view else { return false }
        return view.window?.firstResponder === view
    }

    // MARK: Actions
    //
    // CEF's accessibility tree carries no DOM node ids, so actions find the page's element by
    // position: the node is scrolled into view if needed, then the element at its center gets the
    // action (the mouse for AXPress, one `Runtime.evaluate` for focus, value and `<select>`). Same-
    // origin iframes are followed; in a cross-origin frame only AXPress works.

    /// AXPress: a `<select>` opens a native menu of its options; anything else is clicked at its
    /// center with the panel's mouse input.
    func press(_ key: Key) {
        guard let node = tree.node(key) else { return }
        if BrowserAccessibilityRoles.isSelect(node) {
            showOptions(of: key)
            return
        }
        if node.role == "menuListOption", let select = selectHolding(key) {
            choose(optionAt: tree.options(of: select).firstIndex(of: key) ?? 0, in: select)
            return
        }
        Task { @MainActor in await self.click(key) }
    }

    func click(_ key: Key) async {
        guard let tab, let view else { return }
        await reveal(key)
        guard let rect = viewRect(of: key) else { return }
        let visible = rect.intersection(view.bounds)
        guard !visible.isEmpty else { return }
        let point = NSPoint(x: visible.midX, y: visible.midY)
        for (kind, button) in [(BrowserMouseInput.Kind.move, BrowserMouseButton?.none), (.down, .left), (.up, .left)] {
            tab.send(.mouse(tab: tab.id, input: BrowserMouseInput(kind: kind, x: point.x, y: point.y, button: button)))
        }
    }

    /// Scrolls the page so the node's center is in view, then waits for the tree to report the
    /// new scroll position. Scroll areas inside the page are not scrolled.
    func reveal(_ key: Key) async {
        guard let tab, let view, let rect = viewRect(of: key) else { return }
        guard !view.bounds.contains(NSPoint(x: rect.midX, y: rect.midY)) else { return }
        let dx = rect.midX < 0 || rect.midX > view.bounds.width ? rect.midX - view.bounds.width / 2 : 0
        let dy = rect.midY < 0 || rect.midY > view.bounds.height ? rect.midY - view.bounds.height / 2 : 0
        // View points equal CSS pixels times the page zoom; the page divides by its zoom.
        let zoom = "(window.devicePixelRatio / \(pixelsPerPoint))"
        _ = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string("window.scrollBy(\(Double(dx)) / \(zoom), \(Double(dy)) / \(zoom)); 'ok'"),
            "returnByValue": .bool(true)
        ], timeout: .seconds(5))
        for _ in 0..<8 {
            if let moved = viewRect(of: key), view.bounds.contains(NSPoint(x: moved.midX, y: moved.midY)) { return }
            await nextChange(timeout: .milliseconds(150))
        }
    }

    func focus(_ key: Key) {
        Task { @MainActor in
            _ = await self.withElement(key, """
                (element) => {
                    const target = element.closest('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]') || element;
                    target.focus();
                    return target.ownerDocument.activeElement === target ? 'ok' : 'not focusable';
                }
                """)
        }
    }

    /// Replaces a text field's value the way typing would (its text selected, then the new text
    /// inserted), so the page's input handlers run.
    func setValue(_ value: String, of key: Key) {
        Task { @MainActor in
            _ = await self.withElement(key, """
                (element, value) => {
                    const field = element.closest('input, textarea, [contenteditable]');
                    if (!field) return 'not a text field';
                    const document = field.ownerDocument;
                    field.focus();
                    if (typeof field.select === 'function') { field.select(); }
                    else {
                        const range = document.createRange();
                        range.selectNodeContents(field);
                        const selection = document.getSelection();
                        selection.removeAllRanges();
                        selection.addRange(range);
                    }
                    if (value === '') document.execCommand('delete');
                    else document.execCommand('insertText', false, value);
                    return 'ok';
                }
                """, argument: .string(value))
        }
    }

    /// Chooses a `<select>` option the way the user's pick would (input and change events).
    func choose(optionAt index: Int, in select: Key) {
        Task { @MainActor in
            _ = await self.withElement(select, """
                (element, index) => {
                    const select = element.closest('select');
                    if (!select) return 'not a select';
                    select.selectedIndex = index;
                    select.dispatchEvent(new Event('input', { bubbles: true }));
                    select.dispatchEvent(new Event('change', { bubbles: true }));
                    return 'ok';
                }
                """, argument: .integer(Int64(index)))
        }
    }

    private func selectHolding(_ option: Key) -> Key? {
        var current = tree.parent(of: option)
        while let key = current {
            if let node = tree.node(key), BrowserAccessibilityRoles.isSelect(node) { return key }
            current = tree.parent(of: key)
        }
        return nil
    }

    /// Runs `function(element, argument)` in the page on the element at the node's center
    /// (following same-origin iframes) and returns its string result.
    @discardableResult
    func withElement(_ key: Key, _ function: String, argument: JSONValue = .null) async -> String? {
        guard let tab else { return nil }
        await reveal(key)
        guard let bounds = tree.pageBounds(of: key) else { return nil }
        let argumentJSON = (try? JSONEncoder().encode(argument)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let expression = """
            (() => {
                const ratio = window.devicePixelRatio;
                let x = \(bounds.x + bounds.width / 2) / ratio, y = \(bounds.y + bounds.height / 2) / ratio;
                let element = document.elementFromPoint(x, y);
                while (element && (element.tagName === 'IFRAME' || element.tagName === 'FRAME')) {
                    let inner = null;
                    try { inner = element.contentDocument; } catch (error) {}
                    if (!inner) break;
                    const box = element.getBoundingClientRect();
                    x -= box.left + element.clientLeft;
                    y -= box.top + element.clientTop;
                    element = inner.elementFromPoint(x, y);
                }
                if (!element) return 'no element';
                return (\(function))(element, \(argumentJSON));
            })()
            """
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true), "userGesture": .bool(true)
        ], timeout: .seconds(5))
        return result?["result"]?["value"]?.stringValue
    }

    private func showOptions(of key: Key) {
        let options = tree.options(of: key)
        guard !options.isEmpty, let view else {
            Task { @MainActor in await self.click(key) }
            return
        }
        let titles = options.map { tree.node($0)?.name ?? "" }
#if DEBUG
        if let optionsMenuOverride {
            if let index = optionsMenuOverride(titles), options.indices.contains(index) { choose(optionAt: index, in: key) }
            return
        }
#endif
        let menu = NSMenu()
        let chooser = OptionChooser()
        var selected: NSMenuItem?
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: titles[index], action: #selector(OptionChooser.choose(_:)), keyEquivalent: "")
            item.target = chooser
            item.tag = index
            item.isEnabled = tree.node(option)?.restriction != "disabled"
            if tree.node(option)?.selected == true {
                item.state = .on
                selected = item
            }
            menu.addItem(item)
        }
        let rect = viewRect(of: key) ?? .zero
        menu.popUp(positioning: selected, at: NSPoint(x: rect.minX, y: rect.maxY), in: view)
        if let index = chooser.chosen { choose(optionAt: index, in: key) }
    }

    private final class OptionChooser: NSObject {
        var chosen: Int?
        @objc func choose(_ sender: NSMenuItem) { chosen = sender.tag }
    }
}
