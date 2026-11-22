import Foundation
import Observation
import YardletRemote

/// The browser half of a host-owned sign-in. Nothing from this operation is persisted on the client.
@MainActor
@Observable
final class RemoteConnectorSetupClient {
    typealias Request = @MainActor (RemoteConnectorSetupRequest) async -> RemoteResponse

    private(set) var state: RemoteConnectorSetupState?
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var deviceCode: String?
    @ObservationIgnored private let userAgent: any OAuthUserAgent
    @ObservationIgnored private let request: Request
    @ObservationIgnored private let available: @MainActor () -> Bool
    @ObservationIgnored private let finished: @MainActor () async -> Void
    @ObservationIgnored private let host: String
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var listener: (any OAuthLoopbackReceiving)?
    @ObservationIgnored private var operationID: String?

    init(host: String, userAgent: any OAuthUserAgent, timeout: Duration = .seconds(300),
         available: @escaping @MainActor () -> Bool = { true },
         request: @escaping Request, finished: @escaping @MainActor () async -> Void = {}) {
        self.host = host
        self.userAgent = userAgent
        self.timeout = timeout
        self.available = available
        self.request = request
        self.finished = finished
    }

    func start(draft: RemoteConnectorDraft? = nil, connectorID: String? = nil) {
        guard !isRunning, draft != nil || connectorID != nil else { return }
        guard available() else {
            error = L10n.string("The connection or permission to change settings is no longer available.")
            return
        }
        let id = UUID().uuidString
        operationID = id
        state = nil
        error = nil
        deviceCode = nil
        isRunning = true
        work = Task { [weak self] in
            await self?.run(.init(action: .start, operationID: id, draft: draft, connectorID: connectorID))
        }
        monitor = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: self?.timeout ?? .seconds(300))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, isRunning else { return }
                if !available() {
                    error = L10n.string("The connection or permission to change settings is no longer available.")
                    cancel()
                    return
                }
                if ContinuousClock.now >= deadline {
                    error = L10n.string("Sign-in did not finish in time.")
                    cancel()
                    return
                }
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        work?.cancel()
        monitor?.cancel()
        listener?.stop()
        listener = nil
        if let operationID {
            let request = request
            Task { _ = await request(.init(action: .cancel, operationID: operationID)) }
        }
    }

    func reset() {
        guard !isRunning else { return }
        state = nil
        error = nil
        deviceCode = nil
    }

    private func run(_ start: RemoteConnectorSetupRequest) async {
        defer {
            monitor?.cancel()
            monitor = nil
            listener?.stop()
            listener = nil
            work = nil
            operationID = nil
            isRunning = false
        }
        var answered = Set<String>()
        do {
            var next = start
            while true {
                try Task.checkCancellation()
                guard available() else { throw CancellationError() }
                let response = await request(next)
                try Task.checkCancellation()
                guard response.ok, let current = response.connectorSetup,
                      current.operationID == start.operationID else {
                    error = RemoteHostModel.message(for: response.error, host: host)
                    if let cancelled = await cancelOnHost(start.operationID) { state = cancelled }
                    break
                }
                state = current
                guard current.status == .working else {
                    if current.status == .failed { error = current.message ?? L10n.string("Could not connect.") }
                    break
                }
                if let step = current.step, !answered.contains(step.id) {
                    let reply = try await answer(step)
                    try Task.checkCancellation()
                    answered.insert(step.id)
                    next = .init(action: .answer, operationID: start.operationID, reply: reply)
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                    next = .init(action: .poll, operationID: start.operationID)
                }
            }
        } catch is CancellationError {
            // If dismissal raced the start response, cancel again after the host has created the operation.
            let cancelled = await cancelOnHost(start.operationID)
            state = cancelled ?? .init(operationID: start.operationID, connectorID: state?.connectorID, status: .cancelled)
        } catch {
            // Browser failures contain no server response or credentials.
            self.error = L10n.string("Could not complete sign-in in this computer's browser. Try connecting again.")
            if let cancelled = await cancelOnHost(start.operationID) { state = cancelled }
        }
        await finished()
    }

    private func cancelOnHost(_ id: String) async -> RemoteConnectorSetupState? {
        let response = await request(.init(action: .cancel, operationID: id))
        guard response.ok, let state = response.connectorSetup, state.operationID == id else { return nil }
        return state
    }

    private func answer(_ step: RemoteConnectorSetupStep) async throws -> RemoteConnectorSetupReply {
        switch step.kind {
        case .listen:
            guard listener == nil, let state = step.state, !state.isEmpty else { throw ConnectorOAuthError.stateMismatch }
            let receiver = try await userAgent.startLoopback(port: step.port, state: state)
            listener = receiver
            return .init(stepID: step.id, value: receiver.redirectURI.absoluteString)
        case .open:
            guard let text = step.url, let url = URL(string: text), Self.canOpen(url) else {
                throw ConnectorOAuthError.cannotOpenBrowser
            }
            deviceCode = step.deviceCode
            return .init(stepID: step.id, accepted: await userAgent.open(url))
        case .confirm:
            guard let connector = step.connector, let server = step.serverHost, let signIn = step.signInHost else {
                throw ConnectorOAuthError.stateMismatch
            }
            return .init(stepID: step.id, accepted: await userAgent.confirm(.init(
                connector: connector, serverHost: server, signInHost: signIn)))
        case .callback:
            guard let listener else { throw ConnectorOAuthError.stateMismatch }
            let callback = try await listener.callback()
            // The Mac listener returns the request target with no port. Keep the endpoint that was
            // registered, carrying only the received query back to the host's OAuth verifier.
            guard var redirect = URLComponents(url: listener.redirectURI, resolvingAgainstBaseURL: false),
                  let received = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  received.scheme == redirect.scheme, received.host == redirect.host,
                  received.path == redirect.path, received.port == nil || received.port == redirect.port else {
                throw ConnectorOAuthError.stateMismatch
            }
            redirect.percentEncodedQuery = received.percentEncodedQuery
            guard let answer = redirect.url else { throw ConnectorOAuthError.stateMismatch }
            return .init(stepID: step.id, value: answer.absoluteString)
        }
    }

    /// The host may ask for a web sign-in, never a file, an application URL, or embedded credentials.
    static func canOpen(_ url: URL) -> Bool {
        guard let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
}

extension RemoteHostModel {
    var canSetUpHostConnectors: Bool {
        isConnected && canEditHostSettings && hostAccountsState?.connectorSetup == true
    }

    func makeConnectorSetupClient(userAgent: any OAuthUserAgent) -> RemoteConnectorSetupClient {
        RemoteConnectorSetupClient(host: name, userAgent: userAgent,
            available: { [weak self] in self?.canSetUpHostConnectors == true },
            request: { [weak self] request in
                guard let self else { return .failure(request.operationID, RemoteError(.unavailable)) }
                return await response(to: .connectorSetup(request))
            }, finished: { [weak self] in
                guard let self, isConnected else { return }
                await loadHostAccounts()
            })
    }
}
