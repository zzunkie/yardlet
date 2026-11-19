import Foundation
import SwiftUI

// An `https` image an answer's Markdown names, loaded only when the person asks (docs/CONVERSATION_MEDIA.md,
// "Pictures"): the address a model wrote can carry what it read, so nothing is fetched on its own. Loaded, it goes
// through the same path as a local picture, from memory, for as long as the conversation is shown.

private struct TranscriptWebImagesKey: EnvironmentKey {
    static let defaultValue: TranscriptWebImages? = nil
}

extension EnvironmentValues {
    /// The web images the shown conversation loaded; nil where web images stay links (a fixture, a sheet).
    var transcriptWebImages: TranscriptWebImages? {
        get { self[TranscriptWebImagesKey.self] }
        set { self[TranscriptWebImagesKey.self] = newValue }
    }
}

/// The web images one shown conversation loaded, by address. They go when the conversation is no longer shown.
@MainActor @Observable
final class TranscriptWebImages {
    enum Phase: Equatable {
        case loading
        /// Its bytes in memory, under a `TranscriptMemoryImages` address the picture path reads.
        case loaded(URL)
        case failed
    }

    private(set) var phases: [URL: Phase] = [:]
    @ObservationIgnored private let owner = TranscriptMemoryImages.Owner()
    @ObservationIgnored private var loads: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let fetch: @Sendable (URL) async -> Data?

    init(fetch: @escaping @Sendable (URL) async -> Data? = { await TranscriptWebImageLoader.load($0) }) {
        self.fetch = fetch
    }

    func phase(_ url: URL) -> Phase? { phases[url] }

    /// The memory address of a loaded image.
    func loaded(_ url: URL) -> URL? {
        if case let .loaded(memory)? = phases[url] { return memory }
        return nil
    }

    /// Loads `url` once the person asked, or again after it failed.
    func load(_ url: URL) {
        guard phases[url] == nil || phases[url] == .failed else { return }
        phases[url] = .loading
        let fetch = fetch, owner = owner
        loads[url] = Task { [weak self] in
            let data = await fetch(url)
            guard let self, !Task.isCancelled else { return }
            self.loads[url] = nil
            self.phases[url] = data.map { .loaded(TranscriptMemoryImages.shared.keep($0, for: owner)) } ?? .failed
        }
    }

    isolated deinit {
        loads.values.forEach { $0.cancel() }
    }
}

/// Image bytes kept in memory under `yardlet-memory-image:` addresses, which `TranscriptImageThumbnails` reads as it
/// reads a file. Each belongs to an owner and goes with it, its previews and size with it.
final class TranscriptMemoryImages: @unchecked Sendable {
    static let shared = TranscriptMemoryImages()
    static let scheme = "yardlet-memory-image"

    final class Owner: Sendable {
        let id = UUID()
        deinit { TranscriptMemoryImages.shared.forget(owner: id) }
    }

    private let lock = NSLock()
    private var entries: [String: (owner: UUID, data: Data)] = [:]

    func keep(_ data: Data, for owner: Owner) -> URL {
        let url = URL(string: "\(Self.scheme):\(UUID().uuidString.lowercased())")!
        lock.withLock { entries[url.absoluteString] = (owner.id, data) }
        return url
    }

    func data(for url: URL) -> Data? {
        lock.withLock { entries[url.absoluteString]?.data }
    }

    private func forget(owner: UUID) {
        let gone = lock.withLock {
            let keys = entries.filter { $0.value.owner == owner }.map(\.key)
            keys.forEach { entries.removeValue(forKey: $0) }
            return keys
        }
        for key in gone {
            if let url = URL(string: key) { TranscriptImageThumbnails.shared.forget(url) }
        }
    }
}

/// Fetches an image the person asked to load: `https` only, redirects included; never to a private, loopback or
/// link-local address, checked before connecting and against the addresses the connection reached; in an ephemeral
/// session with no cookies, cache, credentials or referrer; only a response that says it is an image other than SVG,
/// at most 20 MB.
enum TranscriptWebImageLoader {
    static let maximumBytes = 20 * 1_048_576

    @concurrent static func load(_ url: URL) async -> Data? {
        guard isAllowed(url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8"]
        let fetch = Fetch()
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
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

    /// An `https` address whose host resolves only to public addresses.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return resolvesPublicly(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// Whether every address `host` resolves to is public; false when it resolves to none.
    static func resolvesPublicly(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var found = false
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            guard let address = current.pointee.ai_addr, let text = numericHost(address, length: current.pointee.ai_addrlen),
                  isPublic(address: text) else { return false }
            found = true
            entry = current.pointee.ai_next
        }
        return found
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether a numeric address is one a public host has: not private, loopback, link-local, shared, reserved or
    /// multicast. A text that is no plain address (a scoped IPv6 address) is not.
    static func isPublic(address text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return isPublic(v4: [UInt8](withUnsafeBytes(of: &v4.s_addr) { Array($0) }))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = [UInt8](withUnsafeBytes(of: &v6) { Array($0) })
        let embeddedV4 = Array(bytes[12...])
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return isPublic(v4: embeddedV4) }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(v4: embeddedV4) }
        if bytes[0] == 0xff { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
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

    /// One load: its checks as the response, its redirects and its bytes arrive.
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
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let type = http.mimeType?.lowercased(), type.hasPrefix("image/"), !type.hasPrefix("image/svg"),
                  http.expectedContentLength <= Int64(TranscriptWebImageLoader.maximumBytes) else {
                lock.withLock { refused = true }
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock {
                self.data.append(data)
                if self.data.count > TranscriptWebImageLoader.maximumBytes { refused = true }
                return refused
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, TranscriptWebImageLoader.isAllowed(url) else {
                lock.withLock { refused = true }
                return completionHandler(nil)
            }
            var request = request
            request.setValue(nil, forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            completionHandler(request)
        }

        // Called before the task completes: where each request actually went. Through a proxy only the proxy is known,
        // and the host was checked before connecting.
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let reached = metrics.transactionMetrics.allSatisfy { transaction in
                guard transaction.resourceFetchType == .networkLoad, !transaction.isProxyConnection else { return true }
                return transaction.remoteAddress.map(TranscriptWebImageLoader.isPublic(address:)) ?? false
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
