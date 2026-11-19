import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import WebKit

// Mermaid diagrams in an answer (docs/CONVERSATION_MEDIA.md, "Mermaid diagrams"). The Mermaid release Yardlet ships
// (`Resources/Mermaid/mermaid.min.js`, THIRD_PARTY_NOTICES.md) runs in one offscreen web view that has nothing of
// Yardlet's and no network; its SVG stays there, and only a picture of it, a PNG, leaves. Pictures are kept in memory
// by their source and appearance, so a diagram is drawn by Mermaid once and every block with the same source shows
// it without a web view.

/// A drawn diagram: a PNG with a transparent background, and its size in points.
final class MermaidDiagram: Sendable {
    let png: Data
    let size: CGSize

    init(png: Data, size: CGSize) {
        self.png = png
        self.size = size
    }

    /// The bitmap, decoded off the main thread.
    func bitmap() async -> MermaidBitmap? {
        let png = png
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            return MermaidBitmap(image: image)
        }.value
    }

    /// The diagram on an opaque background of its appearance, with a margin, as a PNG: for the image viewer, whose
    /// backdrop is dark, and for the pasteboard, whose reader may have any background.
    func opaquePNG(isDark: Bool) async -> Data? {
        let png = png, size = size
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), size.width > 0 else { return nil }
            let scale = CGFloat(image.width) / size.width
            let margin = (16 * scale).rounded()
            let width = image.width + Int(margin) * 2, height = image.height + Int(margin) * 2
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            // The conversation's canvas (`ParityTheme.canvas`).
            context.setFillColor(CGColor(gray: isDark ? 0.075 : 0.995, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: margin, y: margin, width: CGFloat(image.width), height: CGFloat(image.height)))
            return context.makeImage().flatMap { MermaidDiagrams.png($0, scale: scale) }
        }.value
    }
}

/// A decoded diagram, handed from the decoding thread to the view.
struct MermaidBitmap: @unchecked Sendable {
    let image: CGImage
}

/// The diagrams drawn so far and the one web view that draws them, one at a time, for the blocks on screen.
@MainActor
final class MermaidDiagrams {
    static let shared = MermaidDiagrams()

    struct Key: Hashable, Sendable {
        let source: String
        let isDark: Bool
    }

    enum Result: Sendable {
        case diagram(MermaidDiagram)
        /// Mermaid could not draw it: the block stays its code.
        case failed
    }

    /// The pictures kept, oldest first out past this many bytes of PNG (hundreds of diagrams) or this many results.
    static let keptBytes = 32 * 1_048_576
    static let keptCount = 1_000
    /// A source past Mermaid's own limit (`maxTextSize`) is not drawn.
    static let maximumSourceLength = 50_000
    /// How long the web view may take over one diagram before it is let go and the block stays its code.
    static let renderLimit: Duration = .seconds(10)
    /// How long the web view is kept after the last diagram, so a scroll through several does not start it again.
    static let idleLimit: Duration = .seconds(30)

    private var results: [Key: Result] = [:]
    /// Keys by when they were kept, for letting the oldest go.
    private var order: [Key] = []
    private var keptPNGBytes = 0

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result?, Never>
    }

    private var waiters: [Key: [Waiter]] = [:]
    /// Diagrams asked for and not yet started, in the order asked.
    private var queue: [Key] = []
    private var current: Key?
    private var renderer: MermaidRenderer?
    private var idle: Task<Void, Never>?

    /// How many diagrams the web view has drawn (tests).
    private(set) var renderCount = 0

    func cached(_ key: Key) -> Result? {
        results[key]
    }

    /// The diagram for `key`, drawn if it has not been. Nil when the task is cancelled before it is drawn: a block
    /// that leaves the screen withdraws its request, and one no block waits for is not drawn.
    func result(for key: Key) async -> Result? {
        if let cached = results[key] { return cached }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                if current != key, !queue.contains(key) { queue.append(key) }
                startNext()
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(id, from: key) }
        }
    }

    private func withdraw(_ id: UUID, from key: Key) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[key]!.remove(at: index)
        waiter.continuation.resume(returning: nil)
        if waiters[key]?.isEmpty == true {
            waiters[key] = nil
            queue.removeAll { $0 == key }
        }
    }

    private func startNext() {
        guard current == nil else { return }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard waiters[key]?.isEmpty == false else { continue }
            if let cached = results[key] {
                finish(key, cached)
                continue
            }
            current = key
            idle?.cancel()
            idle = nil
            let renderer = renderer ?? MermaidRenderer()
            self.renderer = renderer
            Task {
                let result = await renderer.render(key.source, isDark: key.isDark)
                renderCount += 1
                keep(result, for: key)
                current = nil
                finish(key, result)
                startNext()
            }
            return
        }
        guard renderer != nil, idle == nil else { return }
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLimit)
            guard let self, !Task.isCancelled, self.current == nil else { return }
            self.renderer?.tearDown()
            self.renderer = nil
            self.idle = nil
        }
    }

    private func finish(_ key: Key, _ result: Result) {
        let waiting = waiters.removeValue(forKey: key) ?? []
        for waiter in waiting { waiter.continuation.resume(returning: result) }
    }

    private func keep(_ result: Result, for key: Key) {
        if results.updateValue(result, forKey: key) == nil { order.append(key) }
        keptPNGBytes += Self.bytes(of: result)
        while keptPNGBytes > Self.keptBytes || order.count > Self.keptCount, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = results.removeValue(forKey: oldest) { keptPNGBytes -= Self.bytes(of: gone) }
        }
    }

    private static func bytes(of result: Result) -> Int {
        if case let .diagram(diagram) = result { return diagram.png.count }
        return 0
    }

    /// `image` as a PNG that says its resolution, so an app that pastes it or the image viewer sizes it in points.
    nonisolated static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The offscreen web view Mermaid runs in. It has nothing of Yardlet's: its own non-persistent data store, one
/// document from its own scheme under a Content Security Policy that loads nothing (`default-src 'none'`) and runs
/// no script of the page's own, and Mermaid in an isolated content world, read from the app's resources as text. It
/// navigates nowhere else and opens no window, dialog, download, camera or microphone. Mermaid runs with
/// `securityLevel: "strict"`: labels' HTML is sanitized and click callbacks are off.
@MainActor
private final class MermaidRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let scheme = "yardlet-mermaid"
    /// The width diagrams are laid out in: the conversation's column.
    static let layoutWidth: CGFloat = 768
    /// Pixels per point of the picture, a Retina screen's.
    static let pictureScale: CGFloat = 2
    /// The largest picture, in pixels; a larger diagram is pictured at a lower resolution.
    static let maximumPixels: CGFloat = 16_000_000

    private var webView: WKWebView?
    private var world: WKContentWorld?
    private var loading: Task<WKWebView?, Never>?
    private var loaded: CheckedContinuation<Bool, Never>?

    /// The diagram, or `.failed` when Mermaid cannot draw it or does not within `MermaidDiagrams.renderLimit`, after
    /// which the web view is let go, stopping it.
    func render(_ source: String, isDark: Bool) async -> MermaidDiagrams.Result {
        let outcome = Outcome()
        return await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            let drawing = Task { outcome.finish(await self.draw(source, isDark: isDark)) }
            outcome.watchdog = Task { [weak self] in
                try? await Task.sleep(for: MermaidDiagrams.renderLimit)
                guard !Task.isCancelled else { return }
                drawing.cancel()
                self?.tearDown()
                outcome.finish(.failed)
            }
        }
    }

    /// The first of a drawing and its watchdog to finish.
    private final class Outcome {
        var continuation: CheckedContinuation<MermaidDiagrams.Result, Never>?
        var watchdog: Task<Void, Never>?

        func finish(_ result: MermaidDiagrams.Result) {
            watchdog?.cancel()
            watchdog = nil
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private func draw(_ source: String, isDark: Bool) async -> MermaidDiagrams.Result {
        guard source.count <= MermaidDiagrams.maximumSourceLength, let webView = await ready(), let world else { return .failed }
        do {
            webView.frame = NSRect(x: 0, y: 0, width: Self.layoutWidth, height: 600)
            let reply = try await webView.callAsyncJavaScript(Self.renderScript, arguments: ["source": source, "dark": isDark],
                                                              in: nil, contentWorld: world)
            guard let measured = reply as? [String: Any], let width = (measured["width"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  let height = (measured["height"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  width >= 1, height >= 1, self.webView === webView else { return .failed }
            let size = CGSize(width: width.rounded(.up), height: height.rounded(.up))
            let pixelScale = min(Self.pictureScale, (Self.maximumPixels / (size.width * size.height)).squareRoot())
            guard size.width * pixelScale >= 1, size.height * pixelScale >= 1 else { return .failed }
            // The whole diagram must be inside the view to be pictured.
            webView.frame = NSRect(x: 0, y: 0, width: max(Self.layoutWidth, size.width), height: max(600, size.height))
            _ = try await webView.callAsyncJavaScript("return 0", arguments: [:], in: nil, contentWorld: world)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            let deviceScale = CGFloat((measured["scale"] as? NSNumber)?.doubleValue ?? 1)
            configuration.snapshotWidth = NSNumber(value: Double(size.width * pixelScale / max(deviceScale, 1)))
            let picture = try await webView.takeSnapshot(configuration: configuration)
            guard self.webView === webView,
                  let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .failed }
            let bitmap = MermaidBitmap(image: image)
            let png = await Task.detached(priority: .userInitiated) {
                MermaidDiagrams.png(bitmap.image, scale: CGFloat(bitmap.image.width) / size.width)
            }.value
            guard let png else { return .failed }
            return .diagram(MermaidDiagram(png: png, size: size))
        } catch {
            return .failed
        }
    }

    /// The web view with Mermaid loaded, made the first time; nil when it cannot be.
    private func ready() async -> WKWebView? {
        if let webView, loading == nil { return webView }
        if let loading { return await loading.value }
        let loading = Task { () -> WKWebView? in
            guard let url = Self.scriptURL(),
                  let script = await Task.detached(priority: .userInitiated, operation: {
                      try? String(contentsOf: url, encoding: .utf8)
                  }).value
            else { return nil }
            let world = WKContentWorld.world(name: "yardlet-mermaid")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(MermaidSchemeHandler(), forURLScheme: Self.scheme)
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isElementFullscreenEnabled = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.layoutWidth, height: 600),
                                    configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView
            self.world = world
            let didLoad = await withCheckedContinuation { continuation in
                loaded = continuation
                webView.load(URLRequest(url: URL(string: "\(Self.scheme)://diagram/")!))
            }
            guard didLoad, self.webView === webView else { return nil }
            return webView
        }
        self.loading = loading
        let webView = await loading.value
        self.loading = nil
        if webView == nil { tearDown() }
        return webView
    }

    func tearDown() {
        loaded?.resume(returning: false)
        loaded = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        webView = nil
        world = nil
    }

    /// The release Yardlet ships. A packaged app reads its own Resources only (`PublicSuffixList.bundled`).
    static func scriptURL() -> URL? {
        let packaged = Bundle.main.bundleURL.pathExtension == "app"
        return Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? (packaged ? nil : Bundle.module.url(forResource: "mermaid.min", withExtension: "js"))
    }

    /// Runs in Mermaid's world: draws `source` in the page, sized as Mermaid sized it, and says its size, or what went
    /// wrong. The page's own world runs nothing.
    private static let renderScript = """
    const out = document.getElementById('diagram');
    out.replaceChildren();
    if (typeof mermaid === 'undefined') { return { error: 'Mermaid is not loaded' }; }
    const font = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif';
    mermaid.initialize({
      startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default', fontFamily: font,
      themeVariables: { fontFamily: font }, suppressErrorRendering: true
    });
    window.yardletDiagrams = (window.yardletDiagrams || 0) + 1;
    try {
      await mermaid.parse(source);
      const { svg } = await mermaid.render('yardlet-diagram-' + window.yardletDiagrams, source);
      out.innerHTML = svg;
    } catch (error) {
      out.replaceChildren();
      return { error: String((error && error.message) || error) };
    }
    const picture = out.querySelector('svg');
    if (!picture) { return { error: 'No diagram' }; }
    // Its own size, not the page's width, which some diagrams scale to.
    const box = picture.viewBox && picture.viewBox.baseVal;
    if (box && box.width > 0 && box.height > 0) {
      picture.setAttribute('width', String(box.width));
      picture.setAttribute('height', String(box.height));
      picture.style.maxWidth = 'none';
    }
    const rect = picture.getBoundingClientRect();
    return { width: rect.width, height: rect.height, scale: window.devicePixelRatio || 1 };
    """

    // MARK: Navigation and the page's requests

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .cancel }
        // The one document, once.
        guard action.request.url?.scheme == Self.scheme, action.targetFrame?.isMainFrame == true,
              loaded != nil else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(returning: true)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        tearDown()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
}

/// Serves the renderer's one document, under a policy that loads nothing and runs no script of its own.
private final class MermaidSchemeHandler: NSObject, WKURLSchemeHandler {
    static let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; "
        + "object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
    private static let document = """
    <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent}\
    #diagram{position:absolute;left:0;top:0}#diagram svg{display:block}</style></head>\
    <body><div id="diagram"></div></body></html>
    """

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "diagram", url.path.isEmpty || url.path == "/" else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": Self.policy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ])!
        task.didReceive(response)
        task.didReceive(Data(Self.document.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
