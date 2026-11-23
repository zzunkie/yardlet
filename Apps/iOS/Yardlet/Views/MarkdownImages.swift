import Darwin
import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit
import YardletRemote

// Inline Markdown images for iOS (docs/CONVERSATION_MEDIA.md, "Pictures"):
// - Local workspace / file: / ~/ / relative image paths load via `readFile` (§15.22) into memory only (never persisted
//   to disk), auto-loading only up to 5 MB and showing a tap-to-load chip beyond that to protect mobile bandwidth.
// - Inline `data:image/...` (excluding SVG) decodes off the main thread with a bounded size limit.
// - Web `https://` images are NEVER auto-fetched; they render a chip with alt text, host, and "Load image". Only on tap
//   does `WebImageLoader` fetch via an ephemeral session (no cookies/cache/credentials, https-only including redirects,
//   blocking private/loopback/link-local IPs via `getaddrinfo` and connection metrics, non-SVG `image/*`, <= 10 MB).
// - Plain `http://` stays a link chip.

// MARK: - Target resolution

/// Where a Markdown picture's source leads on iOS.
enum MarkdownPictureTarget: Equatable, Sendable {
    /// A supported raster image path on the paired Mac (`readFile` §15.22).
    case localImage(path: String)
    /// Any other file on the paired Mac (opened via QuickLook / file link).
    case localFile(path: String)
    /// Inline `data:image/...` (non-SVG).
    case dataImage(String)
    /// Explicit-opt-in `https://` web image (never auto-fetched).
    case webHTTPS(URL)
    /// Plain `http://` link (never fetched).
    case webHTTP(URL)
    /// Unrecognized or disallowed source (e.g. `javascript:`, `data:image/svg+xml`).
    case unsupported

    static let allowedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"
    ]

    private static let linkCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    init(_ source: String) {
        var trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { self = .unsupported; return }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("data:") {
            guard lowered.hasPrefix("data:image/"),
                  !lowered.hasPrefix("data:image/svg") else {
                self = .unsupported
                return
            }
            self = .dataImage(trimmed)
            return
        }

        let escaped = trimmed.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        if let encoded = escaped.addingPercentEncoding(withAllowedCharacters: Self.linkCharacters),
           let url = URL(string: encoded),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "https":
                self = url.host?.isEmpty == false ? .webHTTPS(url) : .unsupported
                return
            case "http":
                self = url.host?.isEmpty == false ? .webHTTP(url) : .unsupported
                return
            case "file":
                guard ["", "localhost"].contains(url.host()?.lowercased() ?? "") else {
                    self = .unsupported
                    return
                }
                let path = url.path(percentEncoded: false)
                self = Self.classifyLocalPath(path)
                return
            default:
                self = .unsupported
                return
            }
        }

        // Plain path (relative, `./`, `~/`, or `/...`).
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        self = Self.classifyLocalPath(decoded)
    }

    private static func classifyLocalPath(_ raw: String) -> MarkdownPictureTarget {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.count <= 1_024,
              !path.hasPrefix("#"),
              !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0 })
        else { return .unsupported }

        // Strip trailing line/column suffixes if present.
        path = path.replacing(/(:\d+(:\d+)?|#L\d+(C\d+)?(-L?\d+(C\d+)?)?)$/, with: "")
        // Strip query/fragment on relative asset paths if present.
        if let queryIndex = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<queryIndex])
        }
        guard !path.isEmpty else { return .unsupported }

        let ext = URL(filePath: path).pathExtension.lowercased()
        if allowedImageExtensions.contains(ext) {
            return .localImage(path: path)
        }
        return .localFile(path: path)
    }
}

// MARK: - Memory-only cache and off-main-thread decoding

/// Memory-only decoded image cache shared across conversations; never writes to disk and automatically evicts under
/// memory pressure.
final class MarkdownImageCache: @unchecked Sendable {
    static let shared = MarkdownImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 120
        return cache
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: max(1, cost))
    }
}

/// Decodes and downsamples raster image bytes off the main thread using ImageIO, rejecting SVG payloads.
enum MarkdownImageDecoder {
    static let maxPixelDimension: CGFloat = 1_600
    static let maxDataURIBytes = 10 * 1_048_576

    static func decodeDownsampled(_ data: Data) async -> UIImage? {
        guard !data.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            decodeSync(data, maxPixelDimension: maxPixelDimension)
        }.value
    }

    static func decodeDataURI(_ source: String) async -> UIImage? {
        // Quick encoded length cap (~1.37x base64 overhead plus header).
        guard source.utf8.count <= maxDataURIBytes * 2 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = extractDataURIBytes(source, maxBytes: maxDataURIBytes) else { return nil }
            return decodeSync(data, maxPixelDimension: maxPixelDimension)
        }.value
    }

    static func extractDataURIBytes(_ source: String, maxBytes: Int = maxDataURIBytes) -> Data? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), !header.hasPrefix("data:image/svg") else { return nil }
        let payload = String(source[source.index(after: comma)...])
        let data: Data?
        if header.contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    private static func decodeSync(_ data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        if let type = CGImageSourceGetType(source) as String?, type.lowercased().contains("svg") {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0 else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }
}

// MARK: - Ephemeral HTTPS web image loader (matching Mac TranscriptWebImageLoader)

/// Fetches a web image only when the person taps "Load image": `https` only (redirects included), blocking private,
/// loopback, link-local, shared, reserved, and multicast addresses both on DNS resolution and on the remote address
/// reached; ephemeral session with no cookies, cache, credentials, or referrer; non-SVG `image/*` only, <= 10 MB.
enum WebImageLoader {
    static let maximumBytes = 10 * 1_048_576

    static func load(_ url: URL) async -> Data? {
        let allowed = await Task.detached(priority: .userInitiated) { isAllowed(url) }.value
        guard allowed, !Task.isCancelled else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8"
        ]

        let fetch = Fetch()
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Referer")

        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetch.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return resolvesPublicly(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    static func resolvesPublicly(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }

        var found = false
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            guard let address = current.pointee.ai_addr,
                  let text = numericHost(address, length: current.pointee.ai_addrlen),
                  isPublic(address: text) else { return false }
            found = true
            entry = current.pointee.ai_next
        }
        return found
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether a numeric IPv4/IPv6 address is publicly routable (not private, loopback, link-local, shared, reserved,
    /// multicast, or scoped).
    static func isPublic(address text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return isPublic(v4: [UInt8](withUnsafeBytes(of: &v4.s_addr) { Array($0) }))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = [UInt8](withUnsafeBytes(of: &v6) { Array($0) })
        let embeddedV4 = Array(bytes[12...])
        // IPv4-mapped ::ffff:0:0/96
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isPublic(v4: embeddedV4)
        }
        // Unspecified ::, loopback ::1, IPv4-compatible
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        // NAT64 64:ff9b::/96
        if bytes[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
            return isPublic(v4: embeddedV4)
        }
        // Multicast ff00::/8
        if bytes[0] == 0xff { return false }
        // Unique local fc00::/7
        if bytes[0] & 0xfe == 0xfc { return false }
        // Link-local fe80::/10 and site-local fec0::/10
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 || bytes[1] & 0xc0 == 0xc0 { return false }
        return true
    }

    private static func isPublic(v4 bytes: [UInt8]) -> Bool {
        let (a, b, c) = (bytes[0], bytes[1], bytes[2])
        switch a {
        case 0, 10, 127: return false
        case 100 where b & 0xc0 == 64: return false
        case 169 where b == 254: return false
        case 172 where b & 0xf0 == 16: return false
        case 192 where b == 168 || (b == 0 && c == 0): return false
        case 198 where b & 0xfe == 18: return false
        case 224...: return false
        default: return true
        }
    }

    private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var data = Data()
        private var refused = false
        private var reachedOnlyPublicAddresses = true

        func start(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let type = http.mimeType?.lowercased(),
                  type.hasPrefix("image/"), !type.hasPrefix("image/svg"),
                  http.expectedContentLength <= Int64(WebImageLoader.maximumBytes) else {
                lock.withLock { refused = true }
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock {
                self.data.append(data)
                if self.data.count > WebImageLoader.maximumBytes { refused = true }
                return refused
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, WebImageLoader.isAllowed(url) else {
                lock.withLock { refused = true }
                return completionHandler(nil)
            }
            var request = request
            request.setValue(nil, forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let reached = metrics.transactionMetrics.allSatisfy { transaction in
                guard transaction.resourceFetchType == .networkLoad, !transaction.isProxyConnection else { return true }
                return transaction.remoteAddress.map(WebImageLoader.isPublic(address:)) ?? false
            }
            lock.withLock { reachedOnlyPublicAddresses = reached }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, result) = lock.withLock { () -> (CheckedContinuation<Data?, Never>?, Data?) in
                defer { self.continuation = nil }
                let ok = error == nil && !refused && reachedOnlyPublicAddresses && !data.isEmpty
                return (self.continuation, ok ? data : nil)
            }
            continuation?.resume(returning: result)
        }
    }
}

// MARK: - Conversation-scoped image loader

/// Loads and tracks local Mac task images (via `readFile` §15.22, memory-only) and explicitly requested `https` web
/// images for one open conversation. Cancels in-flight tasks when released.
@MainActor
@Observable
final class MarkdownImageLoader {
    enum Phase: Equatable {
        case loading
        case loaded(UIImage)
        /// Exceeded the 5 MB automatic download cap; shows a tap-to-load chip instead.
        case tooLarge(size: Int)
        case failed

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.failed, .failed): true
            case let (.tooLarge(a), .tooLarge(b)): a == b
            case let (.loaded(a), .loaded(b)): a === b
            default: false
            }
        }
    }

    /// Auto-load ceiling for mobile/relay bandwidth protection.
    static let autoLoadMaxBytes = 5 * 1_048_576
    /// Ceiling when the person explicitly taps "Load image" on a large local image.
    static let manualLoadMaxBytes = 20 * 1_048_576
    private static let maxConcurrentAutoLoads = 2

    private(set) var phases: [String: Phase] = [:]

    @ObservationIgnored private weak var session: HostSession?
    @ObservationIgnored private let taskID: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeAutoLoads = 0
    @ObservationIgnored private var autoLoadWaiters: [CheckedContinuation<Void, Never>] = []

    init(session: HostSession? = nil, taskID: String? = nil) {
        self.session = session
        self.taskID = taskID
    }

    var canReadFiles: Bool {
        session?.taskFiles == true && taskID != nil
    }

    func localCacheKey(for path: String) -> String {
        "local:\(session?.id ?? ""):\(taskID ?? ""):\(path)"
    }

    func webCacheKey(for url: URL) -> String {
        "web:\(url.absoluteString)"
    }

    func localPhase(for path: String) -> Phase? {
        let key = localCacheKey(for: path)
        if let cached = MarkdownImageCache.shared.image(forKey: key) {
            return .loaded(cached)
        }
        return phases[key]
    }

    func webPhase(for url: URL) -> Phase? {
        let key = webCacheKey(for: url)
        if let cached = MarkdownImageCache.shared.image(forKey: key) {
            return .loaded(cached)
        }
        return phases[key]
    }

    /// Loads a local task image via `readFile` (§15.22) into memory only. When `manual` is false, stops immediately if
    /// the file exceeds `autoLoadMaxBytes` (5 MB) without downloading the remainder.
    func loadLocal(path: String, manual: Bool = false) {
        guard let session, let taskID, session.taskFiles else { return }
        let key = localCacheKey(for: path)
        if let cached = MarkdownImageCache.shared.image(forKey: key) {
            phases[key] = .loaded(cached)
            return
        }
        if case .loading = phases[key] { return }
        if !manual {
            if case .tooLarge = phases[key] { return }
            if case .failed = phases[key] { return }
        }

        phases[key] = .loading
        let maxBytes = manual ? Self.manualLoadMaxBytes : Self.autoLoadMaxBytes
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            if !manual {
                await self.acquireAutoLoadSlot()
            }
            defer {
                if !manual { self.releaseAutoLoadSlot() }
            }
            guard !Task.isCancelled else { return }

            let result = await session.readFileData(path, of: taskID, maxBytes: maxBytes)
            guard !Task.isCancelled else { return }

            switch result {
            case let .success(data):
                let decoded = await MarkdownImageDecoder.decodeDownsampled(data)
                guard !Task.isCancelled else { return }
                self.tasks[key] = nil
                if let decoded {
                    MarkdownImageCache.shared.store(decoded, forKey: key)
                    self.phases[key] = .loaded(decoded)
                } else {
                    self.phases[key] = .failed
                }
            case let .failure(.tooLarge(size)):
                self.tasks[key] = nil
                self.phases[key] = .tooLarge(size: size)
            case .failure(.cancelled):
                self.tasks[key] = nil
                self.phases[key] = nil
            case .failure:
                self.tasks[key] = nil
                self.phases[key] = .failed
            }
        }
    }

    /// Explicitly fetches an `https://` web image on user tap via ephemeral session; never called automatically.
    func loadWeb(_ url: URL) {
        let key = webCacheKey(for: url)
        if let cached = MarkdownImageCache.shared.image(forKey: key) {
            phases[key] = .loaded(cached)
            return
        }
        if case .loading = phases[key] { return }

        phases[key] = .loading
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            let data = await WebImageLoader.load(url)
            guard let self, !Task.isCancelled else { return }
            guard let data, let decoded = await MarkdownImageDecoder.decodeDownsampled(data) else {
                guard !Task.isCancelled else { return }
                self.tasks[key] = nil
                self.phases[key] = .failed
                return
            }
            guard !Task.isCancelled else { return }
            self.tasks[key] = nil
            MarkdownImageCache.shared.store(decoded, forKey: key)
            self.phases[key] = .loaded(decoded)
        }
    }

    private func acquireAutoLoadSlot() async {
        while activeAutoLoads >= Self.maxConcurrentAutoLoads {
            await withCheckedContinuation { continuation in
                autoLoadWaiters.append(continuation)
            }
            if Task.isCancelled { return }
        }
        activeAutoLoads += 1
    }

    private func releaseAutoLoadSlot() {
        activeAutoLoads = max(0, activeAutoLoads - 1)
        if !autoLoadWaiters.isEmpty {
            let next = autoLoadWaiters.removeFirst()
            next.resume()
        }
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
        let waiters = autoLoadWaiters
        autoLoadWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension EnvironmentValues {
    @Entry var markdownImageLoader: MarkdownImageLoader?
}

// MARK: - Views

/// One block of inline Markdown pictures, either a single image or several in a responsive layout.
struct MarkdownPicturesView: View {
    let pictures: [MarkdownView.Picture]
    let opensFiles: Bool

    var body: some View {
        if pictures.count == 1, let first = pictures.first {
            MarkdownPictureItemView(picture: first, opensFiles: opensFiles, isOneOfSeveral: false)
        } else {
            let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 8, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(pictures.enumerated()), id: \.offset) { _, picture in
                    MarkdownPictureItemView(picture: picture, opensFiles: opensFiles, isOneOfSeveral: true)
                }
            }
        }
    }
}

private struct MarkdownPictureItemView: View {
    let picture: MarkdownView.Picture
    let opensFiles: Bool
    let isOneOfSeveral: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.openPreview) private var openPreview
    @Environment(\.markdownImageLoader) private var loader
    @State private var localFallbackSheet: OpenedPreview?
    @State private var standaloneWebLoader: MarkdownImageLoader?
    @State private var dataImage: UIImage?
    @State private var dataFailed = false

    private var target: MarkdownPictureTarget { MarkdownPictureTarget(picture.source) }

    private var linkURL: URL? {
        guard let raw = picture.link?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        if opensFiles, let path = ConversationLinks.path(raw, link: true) {
            return ConversationLinks.fileLink(path)
        }
        return nil
    }

    var body: some View {
        Group {
            switch target {
            case let .localImage(path):
                localImageView(path: path)
            case let .localFile(path):
                fileChip(path: path)
            case let .dataImage(raw):
                dataImageView(raw: raw)
            case let .webHTTPS(url):
                webHTTPSView(url: url)
            case let .webHTTP(url):
                webLinkChip(url: url, destination: linkURL ?? url)
            case .unsupported:
                staticChip(systemImage: "photo", detail: nil)
            }
        }
        .sheet(item: $localFallbackSheet) { PreviewViewer(source: $0.source) }
    }

    // MARK: Local workspace image

    @ViewBuilder
    private func localImageView(path: String) -> some View {
        if opensFiles, let loader, loader.canReadFiles {
            let phase = loader.localPhase(for: path)
            switch phase {
            case let .loaded(image)?:
                renderedImage(image, link: linkURL)
            case let .tooLarge(size)?:
                largeLocalImageChip(path: path, size: size, loader: loader)
            case .failed?:
                VStack(alignment: .leading, spacing: 6) {
                    fileChip(path: path)
                    HStack(spacing: 8) {
                        Text("Couldn't load the image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try again") { loader.loadLocal(path: path, manual: true) }
                            .font(.caption.weight(.semibold))
                    }
                }
            case .loading?, nil:
                imagePlaceholder
                    .task(id: path) {
                        loader.loadLocal(path: path, manual: false)
                    }
            }
        } else {
            fileChip(path: path)
        }
    }

    private func largeLocalImageChip(path: String, size: Int, loader: MarkdownImageLoader) -> some View {
        let formattedSize = Int64(size).formatted(.byteCount(style: .file))
        let canLoadInline = size <= MarkdownImageLoader.manualLoadMaxBytes
        return HStack(spacing: 8) {
            Button {
                if let url = ConversationLinks.fileLink(path) { openURL(url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text(verbatim: picture.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: formattedSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.footnote)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if canLoadInline {
                Button("Load image") {
                    loader.loadLocal(path: path, manual: true)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button("Open File") {
                    if let url = ConversationLinks.fileLink(path) { openURL(url) }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    // MARK: Inline data:image/...

    @ViewBuilder
    private func dataImageView(raw: String) -> some View {
        let cacheKey = "data:\(raw.hashValue):\(raw.count)"
        if let cached = dataImage ?? MarkdownImageCache.shared.image(forKey: cacheKey) {
            renderedImage(cached, link: linkURL)
        } else if dataFailed {
            staticChip(systemImage: "photo", detail: nil)
        } else {
            imagePlaceholder
                .task(id: cacheKey) {
                    if let cached = MarkdownImageCache.shared.image(forKey: cacheKey) {
                        dataImage = cached
                        return
                    }
                    if let decoded = await MarkdownImageDecoder.decodeDataURI(raw) {
                        MarkdownImageCache.shared.store(decoded, forKey: cacheKey)
                        dataImage = decoded
                    } else {
                        dataFailed = true
                    }
                }
        }
    }

    // MARK: Web https:// (never auto-fetched)

    @ViewBuilder
    private func webHTTPSView(url: URL) -> some View {
        let activeLoader = loader ?? standaloneWebLoader
        let phase = activeLoader?.webPhase(for: url)
        let destination = linkURL ?? url
        if case let .loaded(image)? = phase {
            renderedImage(image, link: destination)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        openURL(destination)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: picture.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let host = url.host() {
                                    Text(verbatim: host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    switch phase {
                    case .loading?:
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading…")
                    case .failed?:
                        Button("Try again") { triggerWebLoad(url) }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    default:
                        Button("Load image") { triggerWebLoad(url) }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                if case .failed? = phase {
                    Text("Couldn't load the image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        }
    }

    private func triggerWebLoad(_ url: URL) {
        if let loader {
            loader.loadWeb(url)
        } else {
            let web = standaloneWebLoader ?? MarkdownImageLoader()
            standaloneWebLoader = web
            web.loadWeb(url)
        }
    }

    // MARK: Shared rendering and chips

    private func renderedImage(_ image: UIImage, link: URL?) -> some View {
        let maxHeight: CGFloat = isOneOfSeveral ? 200 : 360
        return Button {
            if let openPreview {
                openPreview(image: image, name: picture.label)
            } else {
                localFallbackSheet = OpenedPreview(image: image, name: picture.label)
            }
        } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(picture.label)
        .contextMenu {
            Button {
                if let openPreview {
                    openPreview(image: image, name: picture.label)
                } else {
                    localFallbackSheet = OpenedPreview(image: image, name: picture.label)
                }
            } label: {
                Label("View Image", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if let link {
                Button {
                    openURL(link)
                } label: {
                    Label("Open Link", systemImage: "safari")
                }
            }
            Button {
                UIPasteboard.general.image = image
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .frame(maxWidth: isOneOfSeveral ? .infinity : 260, minHeight: isOneOfSeveral ? 110 : 140,
                   maxHeight: isOneOfSeveral ? 140 : 180)
            .overlay {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading…")
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func fileChip(path: String) -> some View {
        if opensFiles, let url = ConversationLinks.fileLink(path) {
            Button {
                openURL(url)
            } label: {
                chipBody(systemImage: OutputsSheet.symbol(path), detail: nil, interactive: true)
            }
            .buttonStyle(.plain)
        } else {
            staticChip(systemImage: OutputsSheet.symbol(path), detail: nil)
        }
    }

    private func webLinkChip(url: URL, destination: URL) -> some View {
        Button {
            openURL(destination)
        } label: {
            chipBody(systemImage: "globe", detail: url.host(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func staticChip(systemImage: String, detail: String?) -> some View {
        chipBody(systemImage: systemImage, detail: detail, interactive: false)
    }

    private func chipBody(systemImage: String, detail: String?, interactive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(verbatim: picture.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(interactive ? .primary : .secondary)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}
