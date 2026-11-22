import Foundation
import YardletRemote

/// Browser requests are held only for the connection that started a setup, never in a shared account snapshot.
@MainActor
final class RemoteConnectorSetupExchange {
    private(set) var step: RemoteConnectorSetupStep?
    private(set) var declined = false
    private var stopped = false
    private var pending: CheckedContinuation<RemoteConnectorSetupReply, Error>?

    func markDeclined() { declined = true }

    func ask(_ next: RemoteConnectorSetupStep) async throws -> RemoteConnectorSetupReply {
        try Task.checkCancellation()
        guard !stopped, pending == nil else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !stopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                step = next
                pending = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(stepID: next.id) }
        }
    }

    /// A malformed or late answer leaves the pending step alone, so it cannot advance another sign-in.
    func answer(_ reply: RemoteConnectorSetupReply) -> Bool {
        guard let step, reply.stepID == step.id, let pending else { return false }
        if reply.accepted == false {
            declined = true
            self.step = nil
            self.pending = nil
            pending.resume(throwing: CancellationError())
            return true
        }
        switch step.kind {
        case .listen:
            guard let value = reply.value, Self.redirect(value, port: step.port) != nil else { return false }
        case .callback:
            guard let value = reply.value, let redirect = step.url, let state = step.state,
                  Self.callback(value, redirect: redirect, state: state) != nil else { return false }
        case .open, .confirm:
            guard reply.accepted == true else { return false }
        }
        self.step = nil
        self.pending = nil
        pending.resume(returning: reply)
        return true
    }

    func stop() {
        stopped = true
        cancel(stepID: step?.id)
    }

    private func cancel(stepID: String?) {
        guard step?.id == stepID else { return }
        let waiter = pending
        pending = nil
        step = nil
        waiter?.resume(throwing: CancellationError())
    }

    static func redirect(_ text: String, port: UInt16?) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme == "http", parts.host == "127.0.0.1",
              let number = parts.port, (1...65_535).contains(number),
              port.map({ number == Int($0) }) ?? true, parts.path == "/callback",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    static func callback(_ text: String, redirect: String, state: String) -> URL? {
        guard let expected = URLComponents(string: redirect), let parts = URLComponents(string: text),
              parts.scheme == expected.scheme, parts.host == expected.host, parts.port == expected.port,
              parts.path == expected.path, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let values = parts.queryItems?.filter({ $0.name == "state" }), values.count == 1,
              values.first?.value == state else { return nil }
        return parts.url
    }
}

/// The existing OAuth client still discovers the provider and exchanges/stores tokens on the host.
/// Only the listener, default browser and consent dialog belong to the initiating remote device.
struct RemoteConnectorSetupUserAgent: OAuthUserAgent {
    let exchange: RemoteConnectorSetupExchange
    let deviceCode: @MainActor @Sendable () -> String?

    func startLoopback(port: UInt16?, state: String) async throws -> any OAuthLoopbackReceiving {
        let reply = try await exchange.ask(.init(id: UUID().uuidString, kind: .listen, port: port, state: state))
        guard let text = reply.value, let redirect = await RemoteConnectorSetupExchange.redirect(text, port: port) else {
            throw CancellationError()
        }
        return RemoteConnectorSetupLoopback(redirectURI: redirect, state: state, exchange: exchange)
    }

    func open(_ url: URL) async -> Bool {
        guard ConnectorOAuth.isSignInPage(url) else { return false }
        do {
            let code = await deviceCode()
            let reply = try await exchange.ask(.init(id: UUID().uuidString, kind: .open,
                                                      url: url.absoluteString, deviceCode: code))
            return reply.accepted == true
        } catch { return false }
    }

    func confirm(_ confirmation: ConnectorSignInConfirmation) async -> Bool {
        do {
            let reply = try await exchange.ask(.init(id: UUID().uuidString, kind: .confirm,
                connector: confirmation.connector, serverHost: confirmation.serverHost,
                signInHost: confirmation.signInHost))
            return reply.accepted == true
        } catch { return false }
    }
}

private struct RemoteConnectorSetupLoopback: OAuthLoopbackReceiving {
    let redirectURI: URL
    let state: String
    let exchange: RemoteConnectorSetupExchange

    func callback() async throws -> URL {
        let reply = try await exchange.ask(.init(id: UUID().uuidString, kind: .callback,
                                                 url: redirectURI.absoluteString, state: state))
        guard let text = reply.value,
              let callback = await RemoteConnectorSetupExchange.callback(text, redirect: redirectURI.absoluteString, state: state)
        else { throw CancellationError() }
        return callback
    }

    // The client owns its listener and closes it when the operation completes or the connection closes.
    func stop() {}
}
