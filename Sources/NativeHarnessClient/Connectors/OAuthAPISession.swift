import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One account's access to a REST API Yardlet calls itself (Google's, Microsoft Graph): the bearer
/// token from the secure store, refreshed a minute before it expires and once more if the API
/// refuses it, one refresh at a time. A refresh the identity provider refuses (`invalid_grant`:
/// access revoked, the password changed, months unused, or a 7-day token from a Google app still in
/// Testing) ends in `signInRequired`; a network failure does not.
actor OAuthAPISession {
    enum Failure: Error, Equatable {
        case signInRequired
    }

    private let id: UUID
    private let credentials: any ConnectorCredentialStoring
    /// The transport without the token, for an address that carries its own authorization.
    nonisolated let http: any ConnectorHTTPTransport
    private let now: @Sendable () -> Date
    private var credential: ConnectorCredential?
    private var loaded = false
    private var refreshing: Task<Result<ConnectorCredential, Error>, Never>?

    init(id: UUID, credentials: any ConnectorCredentialStoring, http: any ConnectorHTTPTransport,
         now: @escaping @Sendable () -> Date) {
        self.id = id
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    func use(_ credential: ConnectorCredential?) {
        self.credential = credential
        loaded = true
    }

    /// Sends a request with the account's bearer token. `make` builds it afresh for a retry.
    func send(_ make: @Sendable () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        if !loaded {
            credential = try credentials.load(id)
            loaded = true
        }
        guard let current = credential, current.kind == .oauth, !current.accessToken.isEmpty else {
            throw Failure.signInRequired
        }
        if current.needsRefresh(at: now()) { try await refresh(from: current.accessToken) }
        let used = credential?.accessToken
        let first = try await http.send(authorized(make()))
        guard first.1.statusCode == 401 else { return first }
        try await refresh(from: used)
        let second = try await http.send(authorized(make()))
        if second.1.statusCode == 401 { throw Failure.signInRequired }
        return second
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token = credential?.accessToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Refreshes unless another call already replaced `staleToken`.
    private func refresh(from staleToken: String?) async throws {
        if let current = credential?.accessToken, current != staleToken { return }
        let task: Task<Result<ConnectorCredential, Error>, Never>
        if let refreshing {
            task = refreshing
        } else {
            guard let current = credential, current.refreshToken != nil else { throw Failure.signInRequired }
            let http = http
            let now = now
            task = Task {
                do { return .success(try await ConnectorOAuth.refresh(current, http: http, now: now())) }
                catch { return .failure(error) }
            }
            refreshing = task
        }
        let outcome = await task.value
        if refreshing == task { refreshing = nil }
        switch outcome {
        case .success(let refreshed):
            if credential?.accessToken != refreshed.accessToken {
                credential = refreshed
                try? credentials.save(refreshed, for: id)
            }
        case .failure(ConnectorOAuthError.invalidGrant):
            throw Failure.signInRequired
        case .failure(ConnectorOAuthError.tokenRequestFailed("no refresh token")):
            throw Failure.signInRequired
        case .failure(let error):
            throw error
        }
    }
}
