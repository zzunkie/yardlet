import AppKit
import SwiftUI
@preconcurrency import WebKit

/// A message's HTML as its sender laid it out, with nothing of its own running: no scripts, no cookies
/// or storage, nothing fetched from the network until the person shows that message's images (a
/// tracking pixel tells the sender the mail was read), and a chosen link handed to Yardlet rather than
/// followed. The page is as tall as its content, so the thread scrolls it with everything else.
struct MailHTMLBody: NSViewRepresentable {
    let html: String
    /// The message's text, shown instead when the rules that block remote content cannot be made.
    var fallbackText = ""
    /// The person asked for this message's images and other remote content.
    let allowsRemoteContent: Bool
    let openLink: (URL) -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MailWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = MailWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Mail is written for a light page, as mail apps show it.
        view.appearance = NSAppearance(named: .aqua)
        context.coordinator.load(into: view)
        return view
    }

    func updateNSView(_ view: MailWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.loadedHTML != html || coordinator.loadedRemote != allowsRemoteContent {
            coordinator.load(into: view)
        }
    }

    /// Whether the HTML asks for anything on the network, so the person is offered to show it.
    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?\s*https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The message's own markup after a style that fits it to the reading column. Until remote content is
    /// allowed, the policy lets nothing load but the message's own inline images and styles, and links
    /// that would open a connection ahead of time are taken out.
    static func document(_ html: String, allowsRemoteContent: Bool) -> String {
        let policy = allowsRemoteContent
            ? "default-src 'none'; img-src * data: cid:; style-src * 'unsafe-inline'; font-src * data:; media-src *"
            : "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:"
        let body = allowsRemoteContent ? html : html.replacingOccurrences(
            of: #"<link\b[^>]*\brel\s*=\s*["']?(dns-prefetch|preconnect|prefetch|preload|prerender|modulepreload)[^>]*>"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="\(policy)">\
        <meta http-equiv="x-dns-prefetch-control" content="off">\
        <style>html,body{margin:0;padding:0;background:#fff;color:#1d1d1f;\
        font:14px -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}\
        img,table{max-width:100%!important;height:auto}</style></head><body>\(body)</body></html>
        """
    }

    /// Plain text as a page, for when the message's HTML cannot be shown safely.
    static func textDocument(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return document("<div style=\"white-space:pre-wrap\">\(escaped)</div>", allowsRemoteContent: false)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailHTMLBody
        private(set) var loadedHTML: String?
        private(set) var loadedRemote = false

        init(_ parent: MailHTMLBody) { self.parent = parent }

        func load(into view: WKWebView) {
            loadedHTML = parent.html
            loadedRemote = parent.allowsRemoteContent
            let html = parent.html
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            guard !parent.allowsRemoteContent else {
                view.loadHTMLString(MailHTMLBody.document(html, allowsRemoteContent: true), baseURL: nil)
                return
            }
            let fallback = parent.fallbackText
            Task {
                let rules = await MailRemoteContentRules.blockingAll()
                // A later load replaced this one meanwhile.
                guard loadedHTML == html, !loadedRemote else { return }
                guard let rules else {
                    // Without the rules nothing would stop a tracking pixel, so the text is shown instead.
                    view.loadHTMLString(MailHTMLBody.textDocument(fallback), baseURL: nil)
                    return
                }
                controller.add(rules)
                view.loadHTMLString(MailHTMLBody.document(html, allowsRemoteContent: false), baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The message itself loads; a chosen link is Yardlet's to open; nothing else navigates.
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.openLink(url)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight", in: nil, in: .defaultClient) { [weak self] result in
                guard let self, case let .success(value) = result, let height = (value as? NSNumber)?.doubleValue else { return }
                let fitted = CGFloat(height).rounded(.up)
                if abs(self.parent.height - fitted) > 0.5 { self.parent.height = fitted }
            }
        }
    }
}

/// A web view that leaves scrolling to the thread around it.
final class MailWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// The one content rule list that keeps a message from fetching anything over the network, compiled
/// once into the temporary folder, so nothing of it stays in the person's Library.
@MainActor
enum MailRemoteContentRules {
    private static var compiled: WKContentRuleList?

    static func blockingAll() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let folder = FileManager.default.temporaryDirectory.appending(path: "YardletMailRules")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = try? await WKContentRuleListStore(url: folder)?.compileContentRuleList(
            forIdentifier: "yardlet-mail-remote-content", encodedContentRuleList: rules)
        compiled = list
        return list
    }
}
