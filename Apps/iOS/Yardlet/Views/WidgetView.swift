import SwiftUI
import UIKit
@preconcurrency import WebKit
import YardletRemote

/// A sandboxed `show_widget` card inline in the conversation (docs/CONVERSATION_MEDIA.md, "Views from other
/// harnesses"): open by default with a fold toggle and an Expand button for a full-screen sheet.
struct ConversationWidgetCard: View {
    let id: String
    let widget: RemoteConversationBody.Widget

    @State private var isCollapsed = false
    @State private var inlineHeight: CGFloat = WidgetDocument.initialInlineHeight
    @State private var isLoading = true
    @State private var hasFailed = false
    @State private var reloadToken = 0
    @State private var isExpanded = false

    private var title: String {
        let trimmed = widget.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Widget") : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                if hasFailed {
                    failureView
                } else {
                    WidgetWebView(
                        code: widget.code,
                        isExpanded: false,
                        reloadToken: reloadToken,
                        measuredHeight: $inlineHeight,
                        isLoading: $isLoading,
                        hasFailed: $hasFailed
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: inlineHeight)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Loading…")
                        }
                    }
                }
            }
        }
        .background(YardletPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
        )
        .sheet(isPresented: $isExpanded) {
            WidgetExpandedSheet(title: title, code: widget.code)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .frame(width: 12)
                    // The view's own first heading says the same, so the bar leaves it to the view while it shows.
                    if isCollapsed || !WidgetDocument.opens(widget.code, with: title) {
                        Text(verbatim: title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurface)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? String(localized: "Show") : String(localized: "Hide"))
            .accessibilityValue(title)

            Button {
                isExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(YardletPalette.surfaceContainerLow)
    }

    private var failureView: some View {
        HStack(spacing: 12) {
            Text("Couldn't display this widget.")
                .font(.footnote)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            Spacer(minLength: 0)
            Button("Reload") {
                hasFailed = false
                isLoading = true
                reloadToken += 1
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
    }
}

/// Full-screen sheet for interacting with a widget with full scrolling.
private struct WidgetExpandedSheet: View {
    let title: String
    let code: String

    @Environment(\.dismiss) private var dismiss
    @State private var ignoredHeight: CGFloat = WidgetDocument.initialInlineHeight
    @State private var isLoading = true
    @State private var hasFailed = false
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if hasFailed {
                    VStack(spacing: 12) {
                        Text("Couldn't display this widget.")
                            .font(.callout)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Button("Reload") {
                            hasFailed = false
                            isLoading = true
                            reloadToken += 1
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WidgetWebView(
                        code: code,
                        isExpanded: true,
                        reloadToken: reloadToken,
                        measuredHeight: $ignoredHeight,
                        isLoading: $isLoading,
                        hasFailed: $hasFailed
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .accessibilityLabel("Loading…")
                        }
                    }
                }
            }
            .background(YardletPalette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Sandboxed document and policy

/// Builds the sandboxed HTML document, Content Security Policy, and isolated-world height observer for `show_widget`.
enum WidgetDocument {
    static let scheme = "yardlet-widget"
    static let handlerName = "yardletWidget"
    static let minInlineHeight: CGFloat = 120
    static let maxInlineHeight: CGFloat = 640
    static let initialInlineHeight: CGFloat = 200

    /// Strict CSP matching docs/CONVERSATION_MEDIA.md: inline + allowed public CDNs only, no external fetch/frames/forms.
    static let policy = [
        "default-src 'none'",
        "script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://esm.sh",
        "style-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://esm.sh https://fonts.googleapis.com https://fonts.bunny.net",
        "font-src data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://esm.sh https://fonts.gstatic.com https://fonts.bunny.net",
        "img-src data: blob:",
        "media-src data: blob:",
        "connect-src blob: data:",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

    /// Whether the view's first heading reads as its title: compared without tags, spacing or case.
    static func opens(_ code: String, with title: String) -> Bool {
        guard let match = code.firstMatch(of: /<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/) else { return false }
        let heading = String(match.1).replacing(/<[^>]*>/, with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        func plain(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        return !title.isEmpty && plain(heading) == plain(title)
    }

    static func isFullDocument(_ html: String) -> Bool {
        let start = html.drop { $0.isWhitespace }.prefix(15).lowercased()
        return start.hasPrefix("<!doctype") || start.hasPrefix("<html")
    }

    static func html(for code: String) -> String {
        if isFullDocument(code) {
            return code
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>
        \(YardletWidgetTheme.stylesheet)
        :where(html, body) { overflow-x: auto; }
        :where(body) { padding: 12px; }
        :where(img, svg, canvas, video) { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(code)
        </body>
        </html>
        """
    }

    static func clampInlineHeight(_ reported: Double) -> CGFloat? {
        guard reported.isFinite, reported > 0 else { return nil }
        return min(max(CGFloat(reported).rounded(.up), minInlineHeight), maxInlineHeight)
    }

    /// Runs in an isolated WKContentWorld so untrusted page scripts cannot see or call the message handler.
    static func heightObserverScript(handler: String = handlerName) -> String {
        """
        (() => {
          let last = 0;
          let timer = null;
          const measure = () => {
            const body = document.body;
            if (!body) { return; }
            const rectHeight = body.getBoundingClientRect().height;
            const height = Math.ceil(Math.max(body.scrollHeight, rectHeight));
            if (height > 0 && Math.abs(height - last) >= 1) {
              last = height;
              try {
                window.webkit.messageHandlers.\(handler).postMessage({ type: 'height', height });
              } catch (_) {}
            }
          };
          const schedule = () => {
            if (timer !== null) { return; }
            timer = setTimeout(() => {
              timer = null;
              requestAnimationFrame(measure);
            }, 32);
          };
          const start = () => {
            measure();
            if (typeof ResizeObserver !== 'undefined') {
              const ro = new ResizeObserver(schedule);
              if (document.body) { ro.observe(document.body); }
              if (document.documentElement) { ro.observe(document.documentElement); }
            }
            if (typeof MutationObserver !== 'undefined' && document.body) {
              new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true, attributes: true });
            }
            window.addEventListener('load', schedule);
            setTimeout(measure, 150);
            setTimeout(measure, 500);
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
          } else {
            start();
          }
        })();
        """
    }
}

// MARK: - WKWebView wrapper

/// Sandboxed non-persistent WKWebView serving one widget document from a unique opaque scheme origin.
private struct WidgetWebView: UIViewRepresentable {
    let code: String
    let isExpanded: Bool
    let reloadToken: Int
    @Binding var measuredHeight: CGFloat
    @Binding var isLoading: Bool
    @Binding var hasFailed: Bool

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let schemeHandler = WidgetSchemeHandler()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WidgetDocument.scheme)
        coordinator.schemeHandler = schemeHandler

        let world = WKContentWorld.world(name: "yardlet-widget-" + UUID().uuidString.lowercased())
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: WidgetDocument.heightObserverScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
        controller.add(WidgetMessageHandler(coordinator), contentWorld: world, name: WidgetDocument.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = isExpanded
        webView.scrollView.isScrollEnabled = isExpanded
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light

        coordinator.webView = webView
        coordinator.load(code: code, reloadToken: reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        if webView.overrideUserInterfaceStyle != style {
            webView.overrideUserInterfaceStyle = style
        }
        coordinator.updateScrollBehavior(for: webView)
        if coordinator.loadedCode != code || coordinator.loadedToken != reloadToken {
            coordinator.load(code: code, reloadToken: reloadToken)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.webView = nil
        coordinator.schemeHandler?.clear()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WidgetWebView
        weak var webView: WKWebView?
        var schemeHandler: WidgetSchemeHandler?
        private(set) var loadedCode: String?
        private(set) var loadedToken: Int = -1
        private var allowedHost: String?
        private var reportedHeight: CGFloat = 0
        private var isNavigationInFlight = false
        private var lastExternalOpen = Date.distantPast

        init(parent: WidgetWebView) {
            self.parent = parent
        }

        func load(code: String, reloadToken: Int) {
            guard let webView, let schemeHandler else { return }
            loadedCode = code
            loadedToken = reloadToken
            reportedHeight = 0
            isNavigationInFlight = true

            let host = "view-" + UUID().uuidString.lowercased()
            allowedHost = host
            schemeHandler.setDocument(host: host, html: WidgetDocument.html(for: code))
            updateScrollBehavior(for: webView)

            if !parent.isLoading || parent.hasFailed {
                Task { @MainActor [weak self] in
                    guard let self, self.loadedCode == code, self.loadedToken == reloadToken,
                          self.isNavigationInFlight else { return }
                    if !self.parent.isLoading { self.parent.isLoading = true }
                    if self.parent.hasFailed { self.parent.hasFailed = false }
                }
            }

            if let url = URL(string: "\(WidgetDocument.scheme)://\(host)/") {
                webView.load(URLRequest(url: url))
            }
        }

        func updateScrollBehavior(for webView: WKWebView) {
            let needsScroll = parent.isExpanded || reportedHeight > WidgetDocument.maxInlineHeight
            if webView.scrollView.isScrollEnabled != needsScroll {
                webView.scrollView.isScrollEnabled = needsScroll
            }
            if webView.scrollView.bounces != parent.isExpanded {
                webView.scrollView.bounces = parent.isExpanded
            }
        }

        func receiveMessage(_ body: Any) {
            guard let dict = body as? [String: Any],
                  dict["type"] as? String == "height",
                  let rawHeight = (dict["height"] as? NSNumber)?.doubleValue,
                  rawHeight.isFinite, rawHeight > 0 else { return }

            reportedHeight = CGFloat(rawHeight).rounded(.up)
            if let webView { updateScrollBehavior(for: webView) }
            if !parent.isExpanded, let clamped = WidgetDocument.clampInlineHeight(rawHeight),
               abs(parent.measuredHeight - clamped) >= 1 {
                parent.measuredHeight = clamped
            }
            if parent.isLoading {
                isNavigationInFlight = false
                parent.isLoading = false
            }
        }

        private func openExternalIfAllowed(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            let now = Date()
            guard now.timeIntervalSince(lastExternalOpen) >= 1 else { return }
            lastExternalOpen = now
            UIApplication.shared.open(url)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.shouldPerformDownload { return .cancel }

            // Allow only the single initial top-level document load from our unique opaque origin.
            if navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .other,
               let url = navigationAction.request.url,
               url.scheme == WidgetDocument.scheme,
               let host = url.host, host == allowedHost {
                allowedHost = nil
                return .allow
            }

            // Allow only user-initiated http/https link clicks to open outside the app.
            if navigationAction.navigationType == .linkActivated {
                openExternalIfAllowed(navigationAction.request.url)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.canShowMIMEType,
                  navigationResponse.response.url?.scheme == WidgetDocument.scheme else {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isNavigationInFlight = false
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            isNavigationInFlight = false
            parent.isLoading = false
            parent.hasFailed = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            isNavigationInFlight = false
            parent.isLoading = false
            parent.hasFailed = true
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isNavigationInFlight = false
            parent.isLoading = false
            parent.hasFailed = true
        }

        // MARK: WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated {
                openExternalIfAllowed(navigationAction.request.url)
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

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
    }
}

/// Weak wrapper so WKUserContentController does not retain the coordinator.
private final class WidgetMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: WidgetWebView.Coordinator?

    init(_ coordinator: WidgetWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let body = message.body
        MainActor.assumeIsolated {
            coordinator?.receiveMessage(body)
        }
    }
}

/// Serves one widget HTML document from its unique opaque origin with HTTP CSP headers and nothing else.
private final class WidgetSchemeHandler: NSObject, WKURLSchemeHandler {
    private var host: String?
    private var htmlData: Data?

    func setDocument(host: String, html: String) {
        self.host = host
        self.htmlData = Data(html.utf8)
    }

    func clear() {
        host = nil
        htmlData = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == WidgetDocument.scheme,
              url.host == host,
              url.path.isEmpty || url.path == "/",
              let data = htmlData,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Security-Policy": WidgetDocument.policy,
                    "Referrer-Policy": "no-referrer",
                    "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff"
                ]
              ) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
