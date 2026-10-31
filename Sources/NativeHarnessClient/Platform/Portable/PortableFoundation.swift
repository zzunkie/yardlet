import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// What Apple's Foundation and Combine give the engine and Foundation elsewhere lacks, in the
// smallest shape the engine uses.

#if !canImport(Darwin)
/// The inline styles a Markdown run carries (Foundation's `InlinePresentationIntent`).
struct InlinePresentationIntent: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt
    static let emphasized = Self(rawValue: 1 << 0)
    static let stronglyEmphasized = Self(rawValue: 1 << 1)
    static let code = Self(rawValue: 1 << 2)
    static let strikethrough = Self(rawValue: 1 << 5)
    static let softBreak = Self(rawValue: 1 << 6)
    static let lineBreak = Self(rawValue: 1 << 7)
    static let inlineHTML = Self(rawValue: 1 << 8)
    static let blockHTML = Self(rawValue: 1 << 9)
}

enum InlinePresentationIntentAttribute: CodableAttributedStringKey {
    typealias Value = InlinePresentationIntent
    static let name = "NSInlinePresentationIntent"
}

extension AttributeScopes {
    struct YardletAttributes: AttributeScope {
        let inlinePresentationIntent: InlinePresentationIntentAttribute
        let foundation: FoundationAttributes
    }

    var yardlet: YardletAttributes.Type { YardletAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.YardletAttributes, T>) -> T {
        self[T.self]
    }
}
#endif

#if !canImport(Combine)
/// An object whose changes a screen follows (Combine's `ObservableObject`); nothing follows it here.
protocol ObservableObject: AnyObject {}

extension ObservableObject {
    /// What the object announces before it changes (Combine's `objectWillChange`); no one hears it here.
    var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

/// Combine's `ObservableObjectPublisher`, which sends to no one here.
struct ObservableObjectPublisher {
    func send() {}
}

/// A property whose changes a screen follows (Combine's `Published`); here it only holds the value.
@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value

    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
#endif

#if !canImport(Darwin)
extension URLSession {
    /// A response's body as it arrives (Apple's `bytes(for:)`), through a session of the same configuration
    /// whose delegate hands each part over. A redirect is refused, as the app's own sessions refuse it.
    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        let receiver = StreamingReceiver()
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let response = try await receiver.start(session.dataTask(with: request))
        return (receiver.bytes, response)
    }
}

private final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let bytes: AsyncThrowingStream<UInt8, Error>
    private let continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    private let lock = NSLock()
    private var response: CheckedContinuation<URLResponse, Error>?

    override init() {
        (bytes, continuation) = AsyncThrowingStream.makeStream()
        super.init()
    }

    func start(_ task: URLSessionDataTask) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { response in
            lock.withLock { self.response = response }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response.take() }?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for byte in data { continuation.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { self.response.take() }?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}
#endif
