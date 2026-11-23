import Foundation
import Network
import Observation
import SafariServices
import SwiftUI
import UIKit
import YardletRemote

// MARK: - RFC 8252 IPv4 Loopback OAuth Server

/// Single-use RFC 8252 loopback HTTP listener bound strictly to `127.0.0.1` for remote connector OAuth.
/// Keeps a UIKit background task alive while waiting so brief app switches (e.g., 2FA or Passkey apps)
/// do not immediately suspend the local socket.
final class LoopbackOAuthServer: @unchecked Sendable {
    enum Failure: Error {
        case cannotBind
        case stateMismatch
        case backgroundExpired
    }

    static let callbackPath = "/callback"

    let redirectURI: URL
    private let port: UInt16
    private let expectedState: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var outcome: Result<URL, Error>?
    private var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var stopped = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init(listener: NWListener, port: UInt16, state: String, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.expectedState = state
        self.queue = queue
        self.redirectURI = URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
    }

    deinit {
        stop()
    }

    /// Starts listening strictly on IPv4 loopback `127.0.0.1` (`preferredPort` or ephemeral `.any`).
    static func start(preferredPort: UInt16? = nil, state: String) async throws -> LoopbackOAuthServer {
        guard !state.isEmpty else { throw Failure.stateMismatch }
        let parameters = NWParameters.tcp
        let endpointPort = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "app.yardlet.ios.connector-oauth")

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    if let actualPort = listener.port?.rawValue {
                        once.resume(with: .success(actualPort))
                    } else {
                        once.resume(with: .failure(Failure.cannotBind))
                    }
                case let .failed(error):
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

        let server = LoopbackOAuthServer(listener: listener, port: boundPort, state: state, queue: queue)
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection)
        }
        await server.beginBackgroundProtection()
        return server
    }

    /// Strict validation for OAuth sign-in URLs sent by the host: `https://` only, or local loopback `http://`.
    static func isAllowedSignInURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "127.0.0.1" || host == "localhost")
    }

    /// Waits until a matching `GET /callback?...` with exact single `state` query parameter arrives.
    func waitForCallback() async throws -> URL {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let outcome {
                        continuation.resume(with: outcome)
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: waiterID) }?.resume(throwing: CancellationError())
        }
    }

    /// Stops the listener, releases any background task, and cancels any pending waiters.
    func stop() {
        let shouldCancelListener = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldCancelListener {
            listener.cancel()
        }
        finish(.failure(CancellationError()))
        endBackgroundProtection()
    }

    // MARK: - Background Task Protection

    @MainActor
    private func beginBackgroundProtection() {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "YardletConnectorOAuth") { [weak self] in
            self?.handleBackgroundExpiration()
        }
        lock.withLock {
            if stopped {
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            } else {
                backgroundTaskID = taskID
            }
        }
    }

    private func handleBackgroundExpiration() {
        finish(.failure(Failure.backgroundExpired))
        listener.cancel()
        endBackgroundProtection()
    }

    private func endBackgroundProtection() {
        let taskID = lock.withLock { () -> UIBackgroundTaskIdentifier in
            let current = backgroundTaskID
            backgroundTaskID = .invalid
            return current
        }
        guard taskID != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    // MARK: - HTTP Connection Handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: next[..<headerEnd.lowerBound], as: UTF8.self)
                self.handleHTTPHead(headerText, on: connection)
            } else if isComplete || error != nil || next.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func handleHTTPHead(_ head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }
        let target = String(parts[1])
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard rawPath == Self.callbackPath,
              let received = URLComponents(string: "http://127.0.0.1:\(port)\(target)"),
              received.scheme == "http",
              received.host == "127.0.0.1",
              received.port == Int(port),
              received.path == Self.callbackPath,
              received.user == nil,
              received.password == nil,
              received.fragment == nil else {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        // Exact single `state` query match: reject missing, mismatched, or duplicate state parameters.
        let states = received.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states.first?.value == expectedState else {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        var canonical = URLComponents()
        canonical.scheme = "http"
        canonical.host = "127.0.0.1"
        canonical.port = Int(port)
        canonical.path = Self.callbackPath
        canonical.percentEncodedQuery = received.percentEncodedQuery
        guard let callbackURL = canonical.url else {
            respond(on: connection, status: "404 Not Found", body: "")
            return
        }

        let failed = received.queryItems?.contains { $0.name == "error" } == true
        respond(on: connection, status: "200 OK", body: Self.htmlPage(failed: failed))
        finish(.success(callbackURL))
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending: [CheckedContinuation<URL, Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for continuation in pending {
            continuation.resume(with: result)
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func htmlPage(failed: Bool) -> String {
        let title = failed
            ? String(localized: "Sign-in was not completed")
            : String(localized: "Sign-in complete")
        let detail = String(localized: "Sign-in complete — you can close this sheet and return to Yardlet.")
        let bodyText = failed
            ? String(localized: "You can close this sheet and return to Yardlet.")
            : detail
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Yardlet</title>
            <style>body{font:16px -apple-system,system-ui,sans-serif;margin:20vh auto;max-width:26em;padding:0 20px;color:#1c1c1e;background:#fff}
            @media (prefers-color-scheme:dark){body{background:#161618;color:#ececee}}h1{font-size:20px;margin:0 0 8px}p{margin:0;color:#6c6c70;line-height:1.45}
            @media (prefers-color-scheme:dark){p{color:#9d9da3}}</style></head>
            <body><h1>\(title)</h1><p>\(bodyText)</p></body></html>
            """
    }
}

private final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
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

// MARK: - In-App Safari Sheet

/// Presents `SFSafariViewController` in-app so Yardlet remains in the foreground and the `127.0.0.1` loopback
/// socket stays active until the OAuth callback arrives or the user closes the sheet.
struct SafariSignInSheet: UIViewControllerRepresentable {
    let url: URL
    let onUserDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserDismiss: onUserDismiss)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .cancel
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onUserDismiss: () -> Void

        init(onUserDismiss: @escaping () -> Void) {
            self.onUserDismiss = onUserDismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onUserDismiss()
        }
    }
}

// MARK: - Remote Connector Setup State Machine

/// Drives the host-owned remote connector setup protocol (`listen` -> `confirm` -> `open` -> `callback`)
/// on iOS without persisting any OAuth tokens or PKCE state on the phone.
@MainActor
@Observable
final class ConnectorSetupController {
    struct SignInSession: Identifiable, Equatable {
        let id: String
        let url: URL
    }

    struct PendingConfirmation: Identifiable, Equatable {
        let id: String
        let connector: String
        let serverHost: String
        let signInHost: String
    }

    struct Banner: Equatable {
        let isSuccess: Bool
        let message: String
    }

    private(set) var state: RemoteConnectorSetupState?
    private(set) var isRunning = false
    private(set) var deviceCode: String?
    private(set) var activeSignIn: SignInSession?
    private(set) var pendingConfirmation: PendingConfirmation?
    var banner: Banner?

    @ObservationIgnored private let session: HostSession
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var server: LoopbackOAuthServer?
    @ObservationIgnored private var operationID: String?
    @ObservationIgnored private var confirmationContinuation: CheckedContinuation<Bool, Error>?

    init(session: HostSession, timeout: Duration = .seconds(300)) {
        self.session = session
        self.timeout = timeout
    }

    var canSetUp: Bool {
        session.isConnected && session.hostAccounts?.editable == true && session.hostAccounts?.connectorSetup == true
    }

    var statusText: String {
        switch state?.step?.kind {
        case .listen?:
            String(localized: "Preparing sign-in…")
        case .confirm?:
            String(localized: "Waiting for confirmation…")
        case .open?:
            String(localized: "Opening sign-in…")
        case .callback?:
            String(localized: "Finish signing in in the browser sheet…")
        case nil:
            String(localized: "Connecting on \(session.name)…")
        }
    }

    func start(draft: RemoteConnectorDraft? = nil, connectorID: String? = nil) {
        guard !isRunning, draft != nil || connectorID != nil else { return }
        guard canSetUp else {
            banner = Banner(
                isSuccess: false,
                message: String(localized: "The connection or permission to change settings is no longer available.")
            )
            return
        }

        let id = UUID().uuidString
        operationID = id
        state = nil
        deviceCode = nil
        activeSignIn = nil
        pendingConfirmation = nil
        banner = nil
        isRunning = true

        let startRequest = RemoteConnectorSetupRequest(
            action: .start,
            operationID: id,
            draft: draft,
            connectorID: connectorID
        )

        work = Task { [weak self] in
            await self?.run(startRequest)
        }

        monitor = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: self?.timeout ?? .seconds(300))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, isRunning else { return }
                if !canSetUp {
                    banner = Banner(
                        isSuccess: false,
                        message: String(localized: "The connection or permission to change settings is no longer available.")
                    )
                    cancel()
                    return
                }
                if ContinuousClock.now >= deadline {
                    banner = Banner(isSuccess: false, message: String(localized: "Sign-in did not finish in time."))
                    cancel()
                    return
                }
            }
        }
    }

    func respondToConfirmation(accepted: Bool) {
        pendingConfirmation = nil
        let continuation = confirmationContinuation
        confirmationContinuation = nil
        continuation?.resume(returning: accepted)
    }

    func userCancelledSafari() {
        activeSignIn = nil
        if isRunning {
            cancel()
        }
    }

    func cancel() {
        guard isRunning else {
            stopServerAndUI()
            return
        }
        let opID = operationID
        work?.cancel()
        monitor?.cancel()
        stopServerAndUI()
        if let opID {
            let session = session
            Task { _ = await session.sendConnectorSetup(.init(action: .cancel, operationID: opID)) }
        }
    }

    func dismissBanner() {
        banner = nil
    }

    private func stopServerAndUI() {
        server?.stop()
        server = nil
        activeSignIn = nil
        pendingConfirmation = nil
        if let continuation = confirmationContinuation {
            confirmationContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private func run(_ start: RemoteConnectorSetupRequest) async {
        defer {
            monitor?.cancel()
            monitor = nil
            stopServerAndUI()
            work = nil
            operationID = nil
            deviceCode = nil
            isRunning = false
        }

        var answered = Set<String>()
        do {
            var next = start
            while true {
                try Task.checkCancellation()
                guard canSetUp else { throw CancellationError() }
                let response = await session.sendConnectorSetup(next)
                try Task.checkCancellation()

                guard response.ok, let current = response.connectorSetup,
                      current.operationID == start.operationID else {
                    let message = HostSession.message(for: response.error, host: session.name)
                    banner = Banner(isSuccess: false, message: message)
                    if let cancelled = await cancelOnHost(start.operationID) { state = cancelled }
                    break
                }

                state = current
                switch current.status {
                case .connected:
                    banner = Banner(
                        isSuccess: true,
                        message: String(localized: "Connected on \(session.name).")
                    )
                    await session.fetchHostAccounts(watching: true)
                    return
                case .failed:
                    banner = Banner(
                        isSuccess: false,
                        message: current.message ?? String(localized: "Could not connect.")
                    )
                    await session.fetchHostAccounts(watching: true)
                    return
                case .cancelled:
                    await session.fetchHostAccounts(watching: true)
                    return
                case .working:
                    break
                }

                if let step = current.step, !answered.contains(step.id) {
                    let reply = try await answer(step)
                    try Task.checkCancellation()
                    answered.insert(step.id)
                    next = RemoteConnectorSetupRequest(action: .answer, operationID: start.operationID, reply: reply)
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                    next = RemoteConnectorSetupRequest(action: .poll, operationID: start.operationID)
                }
            }
        } catch is CancellationError {
            let cancelled = await cancelOnHost(start.operationID)
            state = cancelled ?? RemoteConnectorSetupState(
                operationID: start.operationID,
                connectorID: state?.connectorID,
                status: .cancelled
            )
        } catch {
            if banner == nil {
                banner = Banner(
                    isSuccess: false,
                    message: String(localized: "Could not complete sign-in on this phone. Try connecting again.")
                )
            }
            if let cancelled = await cancelOnHost(start.operationID) { state = cancelled }
        }
        await session.fetchHostAccounts(watching: true)
    }

    private func cancelOnHost(_ id: String) async -> RemoteConnectorSetupState? {
        let response = await session.sendConnectorSetup(.init(action: .cancel, operationID: id))
        guard response.ok, let state = response.connectorSetup, state.operationID == id else { return nil }
        return state
    }

    private func answer(_ step: RemoteConnectorSetupStep) async throws -> RemoteConnectorSetupReply {
        switch step.kind {
        case .listen:
            guard server == nil, let expectedState = step.state, !expectedState.isEmpty else {
                throw LoopbackOAuthServer.Failure.stateMismatch
            }
            let started = try await LoopbackOAuthServer.start(preferredPort: step.port, state: expectedState)
            server = started
            return RemoteConnectorSetupReply(stepID: step.id, value: started.redirectURI.absoluteString)

        case .confirm:
            guard let connector = step.connector,
                  let serverHost = step.serverHost,
                  let signInHost = step.signInHost else {
                throw LoopbackOAuthServer.Failure.stateMismatch
            }
            let accepted = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    confirmationContinuation = continuation
                    pendingConfirmation = PendingConfirmation(
                        id: step.id,
                        connector: connector,
                        serverHost: serverHost,
                        signInHost: signInHost
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.pendingConfirmation = nil
                    if let continuation = self?.confirmationContinuation {
                        self?.confirmationContinuation = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            return RemoteConnectorSetupReply(stepID: step.id, accepted: accepted)

        case .open:
            guard let rawURL = step.url,
                  let url = URL(string: rawURL),
                  LoopbackOAuthServer.isAllowedSignInURL(url) else {
                throw LoopbackOAuthServer.Failure.stateMismatch
            }
            deviceCode = step.deviceCode
            activeSignIn = SignInSession(id: step.id, url: url)
            return RemoteConnectorSetupReply(stepID: step.id, accepted: true)

        case .callback:
            guard let server else { throw LoopbackOAuthServer.Failure.stateMismatch }
            let callbackURL = try await server.waitForCallback()
            activeSignIn = nil
            server.stop()
            self.server = nil
            guard var redirect = URLComponents(url: server.redirectURI, resolvingAgainstBaseURL: false),
                  let received = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  received.scheme == redirect.scheme,
                  received.host == redirect.host,
                  received.path == redirect.path,
                  received.port == nil || received.port == redirect.port else {
                throw LoopbackOAuthServer.Failure.stateMismatch
            }
            redirect.percentEncodedQuery = received.percentEncodedQuery
            guard let answerURL = redirect.url else {
                throw LoopbackOAuthServer.Failure.stateMismatch
            }
            return RemoteConnectorSetupReply(stepID: step.id, value: answerURL.absoluteString)
        }
    }
}
