import AppKit
import SwiftUI
@preconcurrency import WebKit
import YardletAgentTools

/// One drawn MCP App view (docs/CONNECTORS.md, "MCP Apps"): its web view, the documents it is served from and its
/// bridge. The view is someone else's page, so it gets nothing of Yardlet's:
/// - its own non-persistent data store, so no cookies or storage are shared with the browser, other views or tasks;
/// - two documents from Yardlet's own scheme at two random hosts, so two origins: an outer page that holds only an
///   `<iframe sandbox="allow-scripts allow-same-origin">`, and the view's HTML, served with the Content Security
///   Policy its server declared (`MCPAppCSP`) as a response header;
/// - a bridge script in an isolated content world of the outer page, the only place its message handler exists, that
///   passes on what the view's frame posts and posts Yardlet's answers into that frame;
/// - no navigation after the two documents, no new windows, downloads, dialogs, camera or microphone.
/// What the row draws of a view: its state and height, observed by the card.
@MainActor @Observable
final class MCPAppViewDisplay {
    var state: MCPAppViewController.State = .idle
    /// The height the view reported, kept while it is parked so the conversation does not jump.
    var height: CGFloat = 120
    /// The server's choice of border (`prefersBorder`); nil leaves it to Yardlet.
    var prefersBorder: Bool? = nil
    /// The view's `ui://` resource, once the row asked for it.
    var uri: String? = nil
}

@MainActor
final class MCPAppViewController: NSObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        /// The view could not be drawn; the row shows its text.
        case failed
        /// Torn down off screen to keep the number of live views small; drawn again when seen.
        case parked
    }

    static let scheme = "yardlet-mcp-view"
    private static let handlerName = "yardletMCPApp"
    /// How long a view has to send `ui/initialize` before its row shows text.
    static let initializeLimit: Duration = .seconds(10)

    let display = MCPAppViewDisplay()
    private var state: State {
        get { display.state }
        set { if display.state != newValue { display.state = newValue } }
    }
    private var height: CGFloat {
        get { display.height }
        set { if display.height != newValue { display.height = newValue } }
    }
    /// Where the web view is shown; nil while the row is not drawn.
    weak var container: NSView? {
        didSet { attach() }
    }
    private(set) var webView: MCPAppWebView?
    private var bridge: MCPAppBridge?
    private var schemeHandler: MCPAppSchemeHandler?
    private var world: WKContentWorld?
    private var loading: Task<Void, Never>?
    private var isDark = false
    private var maximumHeight: CGFloat = 600

    /// Reads the view and draws it; does nothing while it is loading or live.
    func start(_ view: ConversationConnectorView, host: ConnectorViewHost, isDark: Bool,
               openLink: @escaping @MainActor (URL) -> Void) {
        guard state == .idle || state == .parked else { return }
        if display.uri != view.uri { display.uri = view.uri }
        self.isDark = isDark
        state = .loading
        loading = Task { [weak self] in
            do {
                let (read, bridgeHost) = try await host.load(view, openLink: openLink)
                guard let self, !Task.isCancelled, self.state == .loading else { return }
                self.show(read, host: bridgeHost)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed
            }
        }
    }

    /// The person asked to see a view that failed again.
    func retry() {
        guard state == .failed else { return }
        state = .idle
    }

    func setDark(_ isDark: Bool) {
        guard self.isDark != isDark else { return }
        self.isDark = isDark
        webView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        bridge?.setDark(isDark)
    }

    /// Tears the view down (telling it first), keeping its height for when it is drawn again.
    func park() async {
        guard state == .live || state == .loading else { return }
        loading?.cancel()
        loading = nil
        await bridge?.tearDown()
        dismantle()
        if state != .failed { state = .parked }
    }

    private func dismantle() {
        bridge = nil
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil
        schemeHandler = nil
        world = nil
    }

    private func show(_ view: MCPAppView, host: MCPAppBridge.Host) {
        let outer = "host-" + UUID().uuidString.lowercased()
        let inner = "view-" + UUID().uuidString.lowercased()
        let handler = MCPAppSchemeHandler(outerHost: outer, viewHost: inner, html: view.html, policy: view.csp.header)
        let world = WKContentWorld.world(name: "yardlet-mcp-app-" + inner)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: Self.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        controller.add(MCPAppMessageHandler(self), contentWorld: world, name: Self.handlerName)
        let webView = MCPAppWebView(frame: NSRect(x: 0, y: 0, width: 600, height: height), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        webView.allowedHosts = [outer, inner]
        display.prefersBorder = view.prefersBorder
        self.schemeHandler = handler
        self.world = world
        self.webView = webView
        let bridge = MCPAppBridge(host: host, context: MCPAppHostContext(isDark: isDark, maximumHeight: Int(maximumHeight))) {
            [weak self] message in self?.post(message)
        }
        bridge.onHeight = { [weak self] reported in
            guard let self else { return }
            let fitted = min(max(CGFloat(reported).rounded(.up), 24), self.maximumHeight)
            self.height = fitted
            self.webView?.passesScrollToConversation = CGFloat(reported) <= self.maximumHeight
        }
        self.bridge = bridge
        state = .live
        attach()
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://\(outer)/")!))
        Task { [weak self] in
            try? await Task.sleep(for: Self.initializeLimit)
            guard let self, self.bridge === bridge, bridge.phase == .loading else { return }
            self.dismantle()
            self.state = .failed
        }
    }

    /// Puts the web view in the row's container, filling it.
    private func attach() {
        guard let webView, let container else { return }
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    fileprivate func receive(_ text: String) {
        bridge?.receive(text)
    }

    private func post(_ message: ToolJSON) {
        guard let webView, let world, let data = try? JSONEncoder().encode(message) else { return }
        let text = String(decoding: data, as: UTF8.self)
        webView.callAsyncJavaScript(
            "const frame = document.getElementById('view'); if (frame && frame.contentWindow) { frame.contentWindow.postMessage(JSON.parse(message), '*'); }",
            arguments: ["message": text], in: nil, in: world, completionHandler: nil)
    }

    /// Runs in the outer page's isolated world: what the view's frame posts goes to Yardlet as JSON text.
    private static let bridgeScript = """
    (() => {
      const frame = document.getElementById('view');
      if (!frame) { return; }
      window.addEventListener('message', (event) => {
        if (event.source !== frame.contentWindow) { return; }
        let text;
        try { text = JSON.stringify(event.data); } catch (error) { return; }
        if (typeof text !== 'string' || text.length > \(MCPAppBridge.maximumMessageLength)) { return; }
        window.webkit.messageHandlers.\(handlerName).postMessage(text);
      });
    })();
    """
}

extension MCPAppViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let view = webView as? MCPAppWebView else { return .cancel }
        if action.shouldPerformDownload { return .cancel }
        if let url = action.request.url, url.scheme == Self.scheme, let host = url.host,
           view.allowedHosts.contains(host), action.navigationType == .other {
            // Each of the two documents loads once, the outer page in the main frame and the view in its frame.
            view.allowedHosts.remove(host)
            return .allow
        }
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // A link the person clicked in the view opens as the view's `ui/open-link` would.
            bridgeOpen(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dismantle()
        state = .failed
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            bridgeOpen(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    private func bridgeOpen(_ url: URL) {
        bridge?.receive(.object(["jsonrpc": .string("2.0"), "id": .string("yardlet-link"),
                                 "method": .string("ui/open-link"), "params": .object(["url": .string(url.absoluteString)])]))
    }
}

/// Holds the controller weakly, so the content controller does not keep it alive.
private final class MCPAppMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var controller: MCPAppViewController?

    init(_ controller: MCPAppViewController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        MainActor.assumeIsolated { controller?.receive(text) }
    }
}

/// Serves the two documents of one view and nothing else.
final class MCPAppSchemeHandler: NSObject, WKURLSchemeHandler {
    let outerHost: String
    let viewHost: String
    private let html: Data
    private let policy: String

    init(outerHost: String, viewHost: String, html: String, policy: String) {
        self.outerHost = outerHost
        self.viewHost = viewHost
        self.html = Data(html.utf8)
        self.policy = policy
    }

    /// The outer page: one sandboxed frame for the view, nothing of its own to run.
    var outerDocument: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;height:100%;\
        background:transparent;overflow:hidden}iframe{display:block;border:0;width:100%;height:100%;\
        background:transparent;color-scheme:normal}</style></head><body><iframe id="view" \
        sandbox="allow-scripts allow-same-origin" src="\(MCPAppViewController.scheme)://\(viewHost)/"></iframe>\
        </body></html>
        """
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.path.isEmpty || url.path == "/" else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let body: Data
        let policy: String
        switch url.host {
        case outerHost?:
            body = Data(outerDocument.utf8)
            policy = "default-src 'none'; style-src 'unsafe-inline'; frame-src \(MCPAppViewController.scheme):; "
                + "script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        case viewHost?:
            body = html
            policy = self.policy
        default:
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": policy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ])!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A view's web view. While the view fits, scrolling over it scrolls the conversation, as over any other line.
final class MCPAppWebView: WKWebView {
    var passesScrollToConversation = true
    /// The two documents still to load, by host (`MCPAppViewController.decidePolicyFor`).
    var allowedHosts: Set<String> = []

    override func scrollWheel(with event: NSEvent) {
        if passesScrollToConversation { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// The views drawn at once across the app: at most `limit` live, the least recently seen one off screen parked when
/// another is drawn.
@MainActor
final class MCPAppViewPool {
    static let shared = MCPAppViewPool()
    static let limit = 4
    /// Controllers kept (live, parked or failed), so a view keeps its height and state while the conversation redraws.
    static let kept = 200

    private var controllers: [String: MCPAppViewController] = [:]
    /// Keys by when they were last on screen, the latest last.
    private var seen: [String] = []
    private var onScreen: Set<String> = []

    func controller(_ key: String) -> MCPAppViewController {
        if let controller = controllers[key] { return controller }
        let controller = MCPAppViewController()
        controllers[key] = controller
        if controllers.count > Self.kept, let oldest = seen.first(where: { !onScreen.contains($0) }) {
            forget(oldest)
        }
        return controller
    }

    func setOnScreen(_ key: String, _ isOnScreen: Bool) {
        if isOnScreen {
            onScreen.insert(key)
            seen.removeAll { $0 == key }
            seen.append(key)
            parkBeyondLimit()
        } else {
            onScreen.remove(key)
        }
    }

    /// The controllers of one task's rows and their web views, by key (tests).
    func controllers(forTask taskID: UUID) -> [String: MCPAppViewController] {
        controllers.filter { $0.key.hasPrefix(taskID.uuidString) }
    }

    /// Live views now (tests).
    var liveCount: Int {
        controllers.values.filter { $0.display.state == .live || $0.display.state == .loading }.count
    }

    private func parkBeyondLimit() {
        var live = seen.filter { [.live, .loading].contains(controllers[$0]?.display.state) }
        while live.count > Self.limit, let oldest = live.first(where: { !onScreen.contains($0) }) {
            live.removeAll { $0 == oldest }
            let controller = controllers[oldest]
            Task { await controller?.park() }
        }
    }

    private func forget(_ key: String) {
        let controller = controllers.removeValue(forKey: key)
        seen.removeAll { $0 == key }
        Task { await controller?.park() }
    }
}

/// The row's place for a view's web view. It tells the pool when it comes on screen and leaves it, from the
/// conversation's scroll view: each turn is drawn in a hosting view of its own (`ConversationTurnHost`), which a
/// SwiftUI scroll position does not reach. Only a change of being on screen is told.
final class MCPAppContainerView: NSView {
    var onScreenChanged: (@MainActor (Bool) -> Void)?
    private var isOnScreen = false
    /// Removed when the view leaves its window, which it does before it goes.
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if window != nil {
            let center = NotificationCenter.default
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkOnScreen() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkOnScreen() }
            })
        }
        checkOnScreen()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        checkOnScreen()
    }

    func checkOnScreen() {
        let now = window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        guard now != isOnScreen else { return }
        isOnScreen = now
        onScreenChanged?(now)
    }
}
