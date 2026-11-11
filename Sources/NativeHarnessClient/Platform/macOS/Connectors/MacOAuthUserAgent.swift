import AppKit
import CryptoKit
import Foundation
import Network

/// Signs in to a connector in the user's default browser, with the redirect coming back to a
/// listener on 127.0.0.1 (RFC 8252). The browser keeps the user's existing sessions with the
/// service, and Yardlet never sees the password.
struct MacOAuthUserAgent: OAuthUserAgent {
    func startLoopback(port: UInt16?, state: String) async throws -> any OAuthLoopbackReceiving {
        try await MacOAuthLoopback.start(port: port, state: state)
    }

    func open(_ url: URL) async -> Bool {
#if DEBUG
        // QA without a browser: fetch the page and follow its redirects, which works with a
        // stand-in authorization server that approves at once.
        if ProcessInfo.processInfo.environment["YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN"] == "1" {
            Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: url) }
            return true
        }
#endif
        return await MainActor.run { NSWorkspace.shared.open(url) }
    }

    func confirm(_ confirmation: ConnectorSignInConfirmation) async -> Bool {
        await MainActor.run { confirmation.alert().runModal() == .alertFirstButtonReturn }
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

extension ConnectorSignInConfirmation {
    /// The warning alert: Continue first, Cancel second.
    @MainActor
    func alert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("Continue"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert
    }
}

/// One redirect's listener: the first `GET /callback` that carries the sign-in's `state` ends the
/// wait, gets a short page telling the user to return to Yardlet, and brings Yardlet forward. Any
/// page in the browser can send a request here, so one without the state is answered 404 like any
/// other path and the wait goes on.
final class MacOAuthLoopback: OAuthLoopbackReceiving, @unchecked Sendable {
    static let callbackPath = "/callback"

    let redirectURI: URL
    private let state: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var outcome: Result<URL, Error>?
    private var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]

    private init(listener: NWListener, port: UInt16, state: String, queue: DispatchQueue) {
        self.listener = listener
        self.state = state
        self.queue = queue
        redirectURI = URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
    }

    /// Listens on 127.0.0.1: on `port` when a registered redirect URI names one, else on any. The port
    /// is this listener's alone while it waits.
    static func start(port fixedPort: UInt16? = nil, state: String) async throws -> MacOAuthLoopback {
        let parameters = NWParameters.tcp
        let endpointPort = fixedPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "Yardlet.ConnectorSignIn")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.resume(with: .success(port)) }
                case .failed(let error):
                    once.resume(with: .failure(error))
                case .cancelled:
                    once.resume(with: .failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let loopback = MacOAuthLoopback(listener: listener, port: port, state: state, queue: queue)
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = { [weak loopback] connection in loopback?.accept(connection) }
        return loopback
    }

    func callback() async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let outcome {
                        continuation.resume(with: outcome)
                    } else {
                        waiters[id] = continuation
                    }
                }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending: [CheckedContinuation<URL, Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        pending.forEach { $0.resume(with: result) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let target = parts.count >= 2 ? String(parts[1]) : ""
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard parts.first == "GET", path == Self.callbackPath, let url = URL(string: "http://127.0.0.1\(target)"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }
        let failed = items.contains { $0.name == "error" }
        respond(on: connection, status: "200 OK", body: Self.page(failed: failed))
        finish(.success(url))
        // Back from the browser to Yardlet, as after any sign-in; a background QA run stays put.
        guard !QABackground.isOn else { return }
        DispatchQueue.main.async { NSApp?.activate() }
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(failed: Bool) -> String {
        let title = failed ? L10n.string("Sign-in was not completed") : L10n.string("Connected to Yardlet")
        let detail = L10n.string("You can close this tab and return to Yardlet.")
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Yardlet</title>
            <style>body{font:15px -apple-system,system-ui,sans-serif;margin:18vh auto;max-width:28em;padding:0 16px;color:#1d1d1f}
            @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}}h1{font-size:20px}</style></head>
            <body><h1>\(title)</h1><p>\(detail)</p></body></html>
            """
    }
}

/// Resumes a continuation the first time only; the listener reports states more than once.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }?.resume(with: result)
    }
}
