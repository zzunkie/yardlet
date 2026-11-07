import AppKit
import ImageIO
import SwiftUI
import YardletRemote

/// A host task's browser in the window's side panel (docs/REMOTE_PROTOCOL.md §15.25), where the Mac's own window shows
/// the task's browser panel: its tabs in the panel's strip, Back, Forward and Reload, the handoff's bar, and the watched
/// tab's page as the host pictures it, which takes clicks, drags, scrolling and typing, sent back to the page there.
/// Addresses and tab closes are performed on the host.
struct RemoteBrowserPanel: View {
    let model: RemoteHostModel
    @Environment(\.workSurfaceNavigation) private var navigation
    @State private var address = ""
    @State private var submittedAddress = false
    @FocusState private var addressFocused: Bool
    private var browser: RemoteBrowserModel { model.browser }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            bars
            page
        }
        .background(ParityTheme.canvas)
        .onChange(of: browser.watchedTab?.url, initial: true) { _, url in
            if !addressFocused { address = url ?? "" }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused {
                if !submittedAddress { address = browser.watchedTab?.url ?? "" }
                submittedAddress = false
            }
        }
    }

    // MARK: - Tabs

    private var header: some View {
        WorkSurfaceHeader(title: browser.watchedTab.map { BrowserTabTitle.make(pageTitle: $0.title ?? "", address: $0.url) }
            ?? L10n.string("Browser"), systemName: "globe", isLoading: browser.watchedTab?.loading == true,
            onClose: {
                if let tabID = browser.tabID { browser.closeTab(tabID) }
                else { browser.hide() }
            }) { EmptyView() }
            .environment(\.workSurfaceNavigation, navigation ?? browser.surfaceNavigation)
    }

    private var toolbar: some View {
        let tab = browser.watchedTab
        return HStack(spacing: 6) {
            HStack(spacing: 2) {
                ParityIconButton(systemName: "chevron.left", help: L10n.string("Back")) { navigate("back") }
                    .disabled(tab?.canGoBack != true)
                ParityIconButton(systemName: "chevron.right", help: L10n.string("Forward")) { navigate("forward") }
                    .disabled(tab?.canGoForward != true)
                ParityIconButton(systemName: "arrow.clockwise", help: L10n.string("Reload")) { navigate("reload") }
                    .disabled(tab == nil)
            }
            TextField(L10n.string("Search or enter address"), text: $address)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .focused($addressFocused)
                .disabled(!browser.canControlTabs)
                .onSubmit { submittedAddress = true; browser.openAddress(address); addressFocused = false }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(ParityTheme.separator) }
                .help(tab?.url ?? "")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(ParityTheme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    private func navigate(_ action: String) {
        browser.input(RemoteTabInput(kind: .navigate, action: action))
    }

    // MARK: - Bars

    @ViewBuilder
    private var bars: some View {
        if let tab = browser.watchedTab, let requestID = tab.requestId, let taskID = browser.taskID {
            BrowserHandoffBar(reason: tab.reason ?? "", decline: {
                model.send(.answerHandoff(taskID: taskID, requestID: requestID, answer: .decline))
            }, done: {
                model.send(.answerHandoff(taskID: taskID, requestID: requestID, answer: .done))
            })
        } else if let tab = browser.watchedTab, let waiting = tab.waiting.flatMap(BrowserPersonWait.Kind.init(rawValue:)) {
            noticeBar(L10n.format("%@. Answer it on %@.",
                                  BrowserPersonWaitText.describe(BrowserPersonWait(kind: waiting, id: ""),
                                                                 site: tab.url.flatMap { URL(string: $0)?.host() }),
                                  model.name), systemImage: "hand.raised")
        }
        if let refusal = browser.refusal {
            noticeBar(refusal, systemImage: "exclamationmark.circle") { browser.refusal = nil }
        }
    }

    private func noticeBar(_ text: String, systemImage: String, close: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let close { ParityIconButton(systemName: "xmark", help: L10n.string("Close"), action: close) }
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, close == nil ? 8 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    // MARK: - Page

    @ViewBuilder
    private var page: some View {
        if browser.isListed, browser.tabs.isEmpty {
            placeholder(systemName: "globe", title: L10n.string("No browser tabs"),
                        detail: L10n.format("This task's browser tabs on %@ show here.", model.name))
        } else if browser.watchedTab?.url == "file://" {
            // The host names a file page outside the task's files by its scheme alone and sends no picture of it.
            placeholder(systemName: "doc", title: L10n.format("This page shows only on %@.", model.name),
                        detail: L10n.string("It is a file outside this task's folders."))
        } else {
            ZStack {
                RemoteBrowserPage(browser: browser, hostName: model.name)
                if browser.frame == nil { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(systemName: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The browser lends its tabs and actions to the task's ordinary side-panel navigation.
extension RemoteBrowserModel {
    func surfaceTabs(for taskID: String) -> [WorkSurfaceTab] {
        tabs(for: taskID).map { tab in
            WorkSurfaceTab(id: "browser:" + tab.tabId,
                           title: BrowserTabTitle.make(pageTitle: tab.title ?? "", address: tab.url),
                           systemName: "globe", isClosable: canControlTabs,
                           isLoading: tab.loading == true,
                           waitNote: tab.waiting.flatMap(BrowserPersonWait.Kind.init(rawValue:)).map {
                               BrowserPersonWaitText.describe(BrowserPersonWait(kind: $0, id: ""),
                                                              site: tab.url.flatMap { URL(string: $0)?.host() })
                           })
        }
    }

    func selectSurfaceTab(_ id: String, taskID: String) {
        guard id.hasPrefix("browser:") else { return }
        let tabID = String(id.dropFirst("browser:".count))
        if self.taskID == taskID { select(tabID) }
        else { show(taskID: taskID, tabID: tabID) }
    }

    func closeSurfaceTab(_ id: String, taskID: String) {
        guard id.hasPrefix("browser:") else { return }
        closeTabs([String(id.dropFirst("browser:".count))], in: taskID)
    }

    func closeSurfaceTabs(_ ids: [String], taskID: String) {
        closeTabs(ids.filter { $0.hasPrefix("browser:") }.map { String($0.dropFirst("browser:".count)) }, in: taskID)
    }

    func newSurfaceTab(taskID: String) {
        if self.taskID != taskID { show(taskID: taskID) }
        openAddress("about:blank", inNewTab: true)
    }

    var surfaceNavigation: WorkSurfaceNavigation {
        let task = taskID
        return WorkSurfaceNavigation(tabs: task.map { surfaceTabs(for: $0) } ?? [],
            activeID: tabID.map { "browser:" + $0 }, choices: [],
            select: { [weak self] id in if let task { self?.selectSurfaceTab(id, taskID: task) } },
            open: { _ in },
            closeTab: { [weak self] id in if let task { self?.closeSurfaceTab(id, taskID: task) } },
            closeTabs: { [weak self] ids in if let task { self?.closeSurfaceTabs(ids, taskID: task) } },
            closePanel: { [weak self] in self?.hide() },
            newTab: canControlTabs && task != nil ? WorkSurfaceNewTab(help: L10n.string("New tab"), action: { [weak self] in
                if let task { self?.newSurfaceTab(taskID: task) }
            }) : nil)
    }
}

// MARK: - The page

/// The watched tab's picture, fitted to the panel at its top, and the person's input to it.
private struct RemoteBrowserPage: NSViewRepresentable {
    let browser: RemoteBrowserModel
    let hostName: String

    func makeNSView(context: Context) -> RemoteBrowserPageView {
        let view = RemoteBrowserPageView()
        view.browser = browser
        return view
    }

    func updateNSView(_ view: RemoteBrowserPageView, context: Context) {
        view.browser = browser
        view.hostName = hostName
        view.show(browser.frame)
        view.passwordField = browser.watchedTab?.passwordField == true
    }

    static func dismantleNSView(_ view: RemoteBrowserPageView, coordinator: ()) {
        view.passwordField = false
    }
}

/// Draws the host's picture of the page and turns this Mac's mouse, trackpad and keyboard into the page's input:
/// a click is a click at the same point of the page, a drag presses, moves and releases, the trackpad scrolls, keys
/// go as keys, and an input method's committed text (Korean, Japanese, dictation) goes as text; what it is still
/// composing shows here until committed. ⌘V types this Mac's clipboard. While the page's focused field is a password
/// field, secure keyboard entry is on and only Roman input sources compose, as in the Mac's own browser panel.
@MainActor
final class RemoteBrowserPageView: NSView, @preconcurrency NSTextInputClient {
    weak var browser: RemoteBrowserModel?
    var hostName = ""
    var passwordField = false {
        didSet { if passwordField != oldValue { updateSecureInput() } }
    }
    var secureInput: any BrowserSecureInputSystem = BrowserSecureInput.system

    private let pageLayer = CALayer()
    private let composing = NSTextField(labelWithString: "")
    private var shownFrame: Int?
    private var pictureSize: CGSize = .zero
    private var marked = NSAttributedString()
    private var lastPoint: NSPoint?
    private var dragStart: NSPoint?
    private var isDragging = false
    private var lastMoveAt = Date.distantPast
    private var isInSecureInputState = false
    private var keyObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pageLayer)
        pageLayer.contentsGravity = .resize
        pageLayer.magnificationFilter = .linear
        pageLayer.minificationFilter = .trilinear
        composing.isHidden = true
        composing.font = .systemFont(ofSize: 15)
        composing.drawsBackground = true
        composing.backgroundColor = .textBackgroundColor
        composing.wantsLayer = true
        composing.layer?.cornerRadius = 4
        addSubview(composing)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityLabel() -> String? {
        L10n.format("Browser page on %@", hostName)
    }

    // MARK: Picture

    func show(_ frame: RemoteBrowserModel.Frame?) {
        guard frame?.number != shownFrame || frame == nil else { return }
        shownFrame = frame?.number
        guard let frame, let source = CGImageSourceCreateWithData(frame.image as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            pageLayer.contents = nil
            pictureSize = .zero
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = image
        pictureSize = CGSize(width: frame.viewportWidth, height: frame.viewportHeight)
        layoutPicture()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutPicture()
        CATransaction.commit()
        guard let window, !bounds.isEmpty else { return }
        browser?.setPanelSize(width: bounds.width, height: bounds.height, scale: window.backingScaleFactor)
    }

    /// Where the picture is drawn: the page's whole width fitted to the panel, at its top.
    private var pictureRect: CGRect {
        guard pictureSize.width > 0, pictureSize.height > 0, bounds.width > 0 else { return .zero }
        let fit = min(bounds.width / pictureSize.width, bounds.height / pictureSize.height)
        let size = CGSize(width: pictureSize.width * fit, height: pictureSize.height * fit)
        return CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    private func layoutPicture() {
        pageLayer.frame = pictureRect
    }

    /// The page's point under a point of this view, in its CSS pixels; nil off the picture.
    private func pagePoint(_ point: NSPoint) -> (x: Double, y: Double)? {
        let rect = pictureRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        return browser?.pagePoint(x: point.x - rect.minX, y: point.y - rect.minY, drawnWidth: rect.width)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        isDragging = false
        lastPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, let page = pagePoint(point) else { return }
        if !isDragging {
            guard hypot(point.x - start.x, point.y - start.y) > 3, let from = pagePoint(start) else { return }
            isDragging = true
            browser?.input(RemoteTabInput(kind: .mouse, x: from.x, y: from.y, action: "down", modifiers: Self.modifiers(event)))
        }
        // A drag's moves, about twenty a second.
        guard Date().timeIntervalSince(lastMoveAt) > 0.05 else { return }
        lastMoveAt = Date()
        browser?.input(RemoteTabInput(kind: .mouse, x: page.x, y: page.y, button: "left", action: "move"))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            dragStart = nil
            isDragging = false
        }
        if isDragging {
            let page = pagePoint(point) ?? pagePoint(lastPoint ?? point)
            if let page { browser?.input(RemoteTabInput(kind: .mouse, x: page.x, y: page.y, action: "up")) }
        } else if let page = pagePoint(point) {
            browser?.input(.click(x: page.x, y: page.y, clickCount: event.clickCount > 1 ? min(event.clickCount, 3) : nil,
                                  modifiers: Self.modifiers(event)))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = pagePoint(point), let factor = browser?.pagePoint(x: 1, y: 1, drawnWidth: pictureRect.width)?.x else {
            return
        }
        // Points on this screen are the page's CSS pixels times the picture's scale; a wheel's line is about 40 of them.
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        browser?.scroll(x: page.x, y: page.y, deltaX: -event.scrollingDeltaX * lines * factor,
                        deltaY: -event.scrollingDeltaY * lines * factor)
    }

    private static func modifiers(_ event: NSEvent) -> [String]? {
        var names: [String] = []
        if event.modifierFlags.contains(.shift) { names.append("shift") }
        if event.modifierFlags.contains(.control) { names.append("control") }
        if event.modifierFlags.contains(.option) { names.append("alt") }
        if event.modifierFlags.contains(.command) { names.append("meta") }
        return names.isEmpty ? nil : names
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v":
                // This Mac's clipboard, typed: the host's is not the person's here.
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    browser?.input(.text(String(text.prefix(RemoteProtocol.maxTabInputCharacters))))
                }
            case "a", "z":
                browser?.input(.key((event.modifierFlags.contains(.shift) ? "Shift+Meta+" : "Meta+") + key))
            default:
                super.keyDown(with: event)
            }
            return
        }
        if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
    }

    override func doCommand(by selector: Selector) {
        guard let key = Self.keys[NSStringFromSelector(selector)] else { return }
        browser?.input(.key(key))
    }

    /// The text system's editing commands as the page's keys.
    private static let keys: [String: String] = [
        "insertNewline:": "Enter", "insertNewlineIgnoringFieldEditor:": "Enter", "insertLineBreak:": "Shift+Enter",
        "insertTab:": "Tab", "insertBacktab:": "Shift+Tab", "cancelOperation:": "Escape",
        "deleteBackward:": "Backspace", "deleteForward:": "Delete", "deleteWordBackward:": "Alt+Backspace",
        "deleteToBeginningOfLine:": "Meta+Backspace",
        "moveLeft:": "ArrowLeft", "moveRight:": "ArrowRight", "moveUp:": "ArrowUp", "moveDown:": "ArrowDown",
        "moveWordLeft:": "Alt+ArrowLeft", "moveWordRight:": "Alt+ArrowRight",
        "moveToBeginningOfLine:": "Meta+ArrowLeft", "moveToLeftEndOfLine:": "Meta+ArrowLeft",
        "moveToEndOfLine:": "Meta+ArrowRight", "moveToRightEndOfLine:": "Meta+ArrowRight",
        "moveLeftAndModifySelection:": "Shift+ArrowLeft", "moveRightAndModifySelection:": "Shift+ArrowRight",
        "moveUpAndModifySelection:": "Shift+ArrowUp", "moveDownAndModifySelection:": "Shift+ArrowDown",
        "scrollPageUp:": "PageUp", "pageUp:": "PageUp", "scrollPageDown:": "PageDown", "pageDown:": "PageDown",
        "scrollToBeginningOfDocument:": "Home", "moveToBeginningOfDocument:": "Home",
        "scrollToEndOfDocument:": "End", "moveToEndOfDocument:": "End"
    ]

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        setComposing(NSAttributedString())
        guard !text.isEmpty else { return }
        browser?.input(.text(String(text.prefix(RemoteProtocol.maxTabInputCharacters))))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setComposing((string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? ""))
    }

    func unmarkText() {
        let text = marked.string
        setComposing(NSAttributedString())
        if !text.isEmpty { browser?.input(.text(text)) }
    }

    func hasMarkedText() -> Bool { marked.length > 0 }

    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the input method's candidates go: under the text being composed, at the last click.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = composing.isHidden ? NSRect(origin: lastPoint ?? .zero, size: NSSize(width: 1, height: 18)) : composing.frame
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    /// The input method's text still being composed, at the last click; it goes to the page once committed.
    private func setComposing(_ text: NSAttributedString) {
        marked = text
        composing.stringValue = text.string
        composing.isHidden = text.length == 0
        guard text.length > 0 else { return }
        composing.sizeToFit()
        let origin = lastPoint ?? NSPoint(x: 12, y: 12)
        composing.frame.origin = NSPoint(x: min(origin.x, max(0, bounds.width - composing.frame.width)), y: origin.y + 12)
    }

    // MARK: Secure input

    override func becomeFirstResponder() -> Bool {
        updateSecureInput(hasKeyboard: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setComposing(NSAttributedString())
        updateSecureInput(hasKeyboard: false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateSecureInput() }
                })
            }
        }
        updateSecureInput()
    }

    /// Secure keyboard entry and Roman input sources only, exactly while the page's focused field is a password field
    /// and this view has the key window's keyboard (`BrowserHostView.updateSecureInput`).
    private func updateSecureInput(hasKeyboard: Bool? = nil) {
        let secure = passwordField && (hasKeyboard ?? (window?.firstResponder === self))
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
}
