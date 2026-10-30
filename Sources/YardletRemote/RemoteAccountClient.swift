import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The relay's optional accounts (docs/REMOTE_PROTOCOL.md §14.4), from an app's side: the sign-in
/// address with PKCE, exchanging the one-time code for a token, and listing, registering and removing
/// Macs. The account only finds the person's Macs; nothing of a task passes through it.
public struct RemoteAccountClient: Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var id: String
        public var provider: String
        public var name: String?
        public var macs: [Mac]?
    }

    public struct Mac: Codable, Equatable, Sendable {
        public var room: String
        public var macKey: String
        public var relayKey: String
        public var name: String
        public var updatedAt: Int64?
    }

    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var code: String

        /// The token no longer works: sign in again.
        public var isUnauthorized: Bool { status == 401 }
    }

    /// The code verifier an app keeps while the browser signs in, and what it sends.
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public var challenge: String {
            RemoteEncoding.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public init(verifier: String = RemoteEncoding.base64url(Data(RemoteRandom.bytes(32)))) {
            self.verifier = verifier
        }
    }

    public static let redirectURI = "yardlet-remote://auth"
    public static let callbackScheme = "yardlet-remote"

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.scheme == "wss" { components?.scheme = "https" }
        if components?.scheme == "ws" { components?.scheme = "http" }
        self.baseURL = components?.url ?? baseURL
        self.session = session
    }

    public func providers() async throws -> [String] {
        struct Answer: Decodable { var providers: [String] }
        return try await request("v1/auth/providers", as: Answer.self).providers
    }

    /// Where the browser sign-in starts.
    public func startURL(provider: String, pkce: PKCE, state: String) -> URL? {
        var components = URLComponents(url: baseURL.appending(path: "v1/auth/\(provider)/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    /// The one-time code from the browser's return address, when its state is ours.
    public static func code(from callback: URL, state: String) -> String? {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    public func exchange(code: String, pkce: PKCE, deviceName: String) async throws -> (token: String, account: Account) {
        struct Answer: Decodable { var token: String; var account: Account }
        let answer = try await request("v1/auth/token", method: "POST",
                                       body: ["code": code, "codeVerifier": pkce.verifier, "deviceName": deviceName],
                                       as: Answer.self)
        return (answer.token, answer.account)
    }

    public func account(token: String) async throws -> Account {
        try await request("v1/account", token: token, as: Account.self)
    }

    /// Puts this Mac on the account, proving it holds the room's key.
    public func registerMac(token: String, identity: RemoteIdentity, name: String, accountID: String) async throws {
        let macKey = RemoteEncoding.base64url(identity.noise.publicKey)
        let message = Data("yardlet-account-mac/1\n\(accountID)\n\(identity.room)\n\(macKey)\n\(name)".utf8)
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.relayPrivateKey).signature(for: message)
        struct Answer: Decodable { var ok: Bool? }
        _ = try await request("v1/account/macs/\(identity.room)", method: "PUT", token: token, body: [
            "macKey": macKey, "relayKey": RemoteEncoding.base64url(identity.relayPublicKey), "name": name,
            "sig": RemoteEncoding.base64url(signature)
        ], as: Answer.self)
    }

    public func removeMac(token: String, room: String) async throws {
        try await send("v1/account/macs/\(room)", method: "DELETE", token: token)
    }

    public func logout(token: String) async throws {
        try await send("v1/auth/logout", method: "POST", token: token)
    }

    // MARK: - HTTP

    private func send(_ path: String, method: String, token: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
    }

    private func request<Value: Decodable>(_ path: String, method: String = "GET", token: String? = nil,
                                           body: [String: String]? = nil, as type: Value.Type) async throws -> Value {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: "noResponse") }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(status: http.statusCode, code: code ?? "http\(http.statusCode)")
        }
    }
}
