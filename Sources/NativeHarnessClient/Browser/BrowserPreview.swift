import AppKit
import Observation
import SwiftUI
@preconcurrency import WebKit

enum BrowserPreviewAddressError: Error, Equatable {
    case empty
    case unsupportedScheme
    case missingHost
    case containsCredentials
    case insecureRemoteHTTP
}

struct BrowserPreviewAddress {
    static func resolve(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BrowserPreviewAddressError.empty }

        let candidate: String
        if value.contains("://") {
            candidate = value
        } else if looksLocal(value) {
            candidate = "http://\(value)"
        } else if value.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
            options: .regularExpression
        ) != nil {
            candidate = value
        } else {
            candidate = "https://\(value)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            throw BrowserPreviewAddressError.unsupportedScheme
        }
        guard components.host != nil else {
            throw BrowserPreviewAddressError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw BrowserPreviewAddressError.containsCredentials
        }
        if scheme == "http", !isLoopbackHost(components.host) {
            throw BrowserPreviewAddressError.insecureRemoteHTTP
        }
        guard let url = components.url else {
            throw BrowserPreviewAddressError.missingHost
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil
        else { return false }
        return scheme == "https" || isLoopbackHost(components.host)
    }

    private static func looksLocal(_ value: String) -> Bool {
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let hostWithoutPort: String?
        if host.hasPrefix("["), let closingBracket = host.firstIndex(of: "]") {
            hostWithoutPort = String(host[host.index(after: host.startIndex)..<closingBracket])
        } else {
            hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        return isLoopbackHost(hostWithoutPort)
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt8($0) != nil
        }
    }
}

struct BrowserPreviewPreferences: Codable, Equatable {
    /// The page shown last, which a build before side-panel browser tabs opens.
    var address = ""
    /// The pages of the task's browser tabs and which was in front, kept when it has several, for a
    /// build before side-panel browser tabs.
    var tabs: [String]?
    var selectedTab: Int?
    /// Each of the side panel's browser tabs, in the panel's order (2026-10-23).
    var pages: [BrowserTabPage]?
    /// The pages the task's tabs showed, which the launcher and a new tab's start page offer again (2026-10-29).
    var visited: [BrowserVisitedPage]?
}

@MainActor
@Observable
final class BrowserPreviewModel: NSObject, @MainActor WKNavigationDelegate, @MainActor WKUIDelegate, NativeSurfaceResource {
    var address: String {
        didSet {
            addressError = nil
            if address != oldValue { addressRevision &+= 1; onChange?() }
        }
    }
    private(set) var addressError: String?
    /// The page's title, for its side-panel tab.
    private(set) var title = "" {
        didSet { if title != oldValue { onChange?() } }
    }
    private(set) var requestedURL: URL?
    private(set) var displayedURL: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var errorMessage: String?
    private(set) var hasAttachedWebView = false

    // The task owns the page. Removing its SwiftUI host must not discard DOM input,
    // scroll position, or back/forward history.
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var pendingRequest: URLRequest?
    @ObservationIgnored private var issuedNavigation: WKNavigation?
    @ObservationIgnored private var addressRevision = 0
    @ObservationIgnored private var navigationAddressRevision = 0
    @ObservationIgnored var onChange: (() -> Void)?

    /// One browser tab's page in the build without the browser engine (`TaskBrowserTabs.preview(for:)`).
    init(preferences: BrowserPreviewPreferences = .init()) {
        address = preferences.address
        super.init()
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    func acquireWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsMagnification = true
        attach(view)
        return view
    }

    func navigate() {
        do {
            let url = try BrowserPreviewAddress.resolve(address)
            requestedURL = url
            address = url.absoluteString
            errorMessage = nil
            isLoading = true
            load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        } catch let error as BrowserPreviewAddressError {
            addressError = message(for: error)
        } catch {
            addressError = error.localizedDescription
        }
    }

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        if let existing = self.webView {
            existing.stopLoading()
            existing.navigationDelegate = nil
            existing.uiDelegate = nil
        }
        self.webView = webView
        hasAttachedWebView = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let pendingRequest { load(pendingRequest) }
        updateNavigationState(from: webView)
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        self.webView = nil
        issuedNavigation = nil
        hasAttachedWebView = false
        isLoading = false
        canGoBack = false
        canGoForward = false
    }

    func goBack() {
        navigationAddressRevision = addressRevision
        issuedNavigation = webView?.goBack()
    }
    func goForward() {
        navigationAddressRevision = addressRevision
        issuedNavigation = webView?.goForward()
    }
    func reload() {
        guard let requestedURL else { return }
        errorMessage = nil
        isLoading = true
        navigationAddressRevision = addressRevision
        if let webView, webView.url == requestedURL {
            issuedNavigation = webView.reloadFromOrigin()
        } else {
            load(URLRequest(url: requestedURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
    func stop() {
        webView?.stopLoading()
        pendingRequest = nil
        isLoading = false
    }

    func terminateForApplicationShutdown() {
        pendingRequest = nil
        if let webView {
            detach(webView)
        } else {
            isLoading = false
        }
    }

    func closeTab() {
        terminateForApplicationShutdown()
        requestedURL = nil
        displayedURL = nil
        errorMessage = nil
        address = ""
    }

    private func load(_ request: URLRequest) {
        navigationAddressRevision = addressRevision
        guard let webView else { pendingRequest = request; return }
        pendingRequest = nil
        issuedNavigation = webView.load(request)
    }

    func openInDefaultBrowser() {
        guard let url = displayedURL ?? requestedURL else { return }
        OutsideBrowser.open(url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        if navigation !== issuedNavigation { navigationAddressRevision = addressRevision }
        isLoading = true
        errorMessage = nil
        updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        isLoading = false
        title = webView.title ?? ""
        if let url = webView.url, BrowserPreviewAddress.isAllowed(url) {
            displayedURL = url
            requestedURL = url
            if addressRevision == navigationAddressRevision { address = url.absoluteString }
        } else if requestedURL != nil, errorMessage == nil {
            // WebKit can finish at about:blank for a blocked destination (for example,
            // a restricted port). A blank page is not a successfully loaded preview.
            errorMessage = L10n.string("This address cannot be previewed.")
        }
        updateNavigationState(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        didFail(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        didFail(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard self.webView === webView else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url,
              BrowserPreviewAddress.isAllowed(url)
        else {
            errorMessage = L10n.string("Only HTTPS and local HTTP addresses can be previewed.")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard self.webView === webView, navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              BrowserPreviewAddress.isAllowed(url)
        else { return nil }
        webView.load(URLRequest(url: url))
        return nil
    }

    private func didFail(_ webView: WKWebView, error: Error) {
        guard self.webView === webView else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        isLoading = false
        errorMessage = error.localizedDescription
        updateNavigationState(from: webView)
    }

    private func updateNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func message(for error: BrowserPreviewAddressError) -> String {
        switch error {
        case .empty, .missingHost:
            L10n.string("Enter a valid preview address.")
        case .unsupportedScheme:
            L10n.string("Only HTTP and HTTPS addresses are supported.")
        case .containsCredentials:
            L10n.string("Addresses containing credentials are not allowed.")
        case .insecureRemoteHTTP:
            L10n.string("Only HTTPS and local HTTP addresses can be previewed.")
        }
    }
}

struct BrowserPane: View {
    let workspaceURL: URL
    let onClose: () -> Void
    @State private var model: BrowserPreviewModel
    @FocusState private var isAddressFocused: Bool

    init(workspaceURL: URL, model: BrowserPreviewModel? = nil, onClose: @escaping () -> Void) {
        self.workspaceURL = workspaceURL
        self.onClose = onClose
        _model = State(initialValue: model ?? BrowserPreviewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: BrowserTabTitle.make(pageTitle: model.title,
                                            address: model.displayedURL?.absoluteString ?? model.requestedURL?.absoluteString),
                systemName: "globe",
                isLoading: model.isLoading,
                workspaceURL: workspaceURL,
                status: statusText,
                statusTint: model.errorMessage == nil && model.addressError == nil ? .secondary : .red,
                onClose: onClose
            ) {
                if model.requestedURL != nil {
                    ParityIconButton(systemName: "arrow.up.forward.app", help: L10n.string("Open externally")) {
                        model.openInDefaultBrowser()
                    }
                }
            }

            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ParityIconButton(systemName: "chevron.left", help: L10n.string("Back")) {
                        model.goBack()
                    }
                    .disabled(!model.canGoBack)
                    ParityIconButton(systemName: "chevron.right", help: L10n.string("Forward")) {
                        model.goForward()
                    }
                    .disabled(!model.canGoForward)
                    ParityIconButton(
                        systemName: model.isLoading ? "xmark" : "arrow.clockwise",
                        help: model.isLoading ? L10n.string("Stop") : L10n.string("Reload")
                    ) {
                        if model.isLoading { model.stop() } else { model.reload() }
                    }
                    .disabled(model.requestedURL == nil)
                }

                TextField(L10n.string("Preview address"), text: $model.address)
                    .focused($isAddressFocused)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .onSubmit { model.navigate() }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).stroke(ParityTheme.separator)
                }

                ParityIconButton(systemName: "arrow.right", help: L10n.string("Open")) { model.navigate() }
                    .disabled(model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(ParityTheme.canvas)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
            }

            if let addressError = model.addressError {
                Label(addressError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ParityTheme.subtleFill)
            }
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .accessibilityLabel(L10n.string("Loading preview…"))
            }
            ZStack {
                if model.requestedURL == nil {
                    browserEmptyState
                } else {
                    BrowserWebView(model: model)
                        .accessibilityHidden(model.errorMessage != nil)
                    if let errorMessage = model.errorMessage {
                        browserError(errorMessage)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .taskFocus(.browser, isFocused: $isAddressFocused)
    }

    private var statusText: String? {
        if model.isLoading { return L10n.string("Loading") }
        if model.errorMessage != nil || model.addressError != nil { return L10n.string("Unavailable") }
        if model.requestedURL != nil { return L10n.string("Ready") }
        return nil
    }

    private var browserEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.string("Preview a local app"))
                .font(.callout.weight(.semibold))
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browserError(_ message: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.orange)
            Text(L10n.string("Preview unavailable"))
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Try again")) { model.reload() }
                .controlSize(.small)
                .parityPointer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
    }
}

struct BrowserWebView: NSViewRepresentable {
    let model: BrowserPreviewModel

    func makeNSView(context: Context) -> BrowserWebViewHost {
        BrowserWebViewHost(webView: model.acquireWebView())
    }

    func updateNSView(_ nsView: BrowserWebViewHost, context: Context) {}

    static func dismantleNSView(_ nsView: BrowserWebViewHost, coordinator: ()) {
        nsView.unmount()
    }
}

/// A fresh host keeps delayed SwiftUI teardown from removing a page already
/// reattached to the next panel. The web view itself remains task-owned.
final class BrowserWebViewHost: NSView {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: webView.frame)
        webView.removeFromSuperview()
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        webView.frame = bounds
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { resignPageFocus() }
        super.viewWillMove(toWindow: newWindow)
    }

    func unmount() {
        if webView.superview === self {
            resignPageFocus()
            webView.removeFromSuperview()
        }
    }

    private func resignPageFocus() {
        guard let window, let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: webView) else { return }
        // WebKit otherwise restores the focused form field by scrolling it into view
        // when the same page is mounted again, even if the user had scrolled away.
        window.makeFirstResponder(nil)
    }
}
