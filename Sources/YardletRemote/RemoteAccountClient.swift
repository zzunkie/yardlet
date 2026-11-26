import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The relay's optional accounts (docs/REMOTE_PROTOCOL.md §14.4), from an app's side: the sign-in
/// address with PKCE, exchanging the one-time code for a token, and listing, registering and removing
/// Macs, and enrolling a device on a Mac on the account. Task content stays on the host. Also a phone's
/// push targets in a Mac's room (§14.5).
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

        public init(status: Int, code: String) {
            self.status = status
            self.code = code
        }

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
    /// The longest device or Mac name the relay keeps, in UTF-16 code units as it counts them.
    public static let maxNameLength = 64

    /// A name as the relay takes it: trimmed, and cut to `maxNameLength` without splitting a character.
    public static func relayName(_ name: String) -> String {
        var result = ""
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard result.utf16.count + character.utf16.count <= maxNameLength else { break }
            result.append(character)
        }
        return result
    }

    /// Whether a link opened with the app is the browser's return from a sign-in (`redirectURI`).
    public static func isSignInCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host?.lowercased() == "auth"
    }

    /// The error the relay returned to the app instead of a code (`providerFailed`, or the provider's own).
    public static func callbackError(from callback: URL) -> String? {
        let error = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "error" }?.value
        return error?.isEmpty == false ? error : nil
    }

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
                                       body: ["code": code, "codeVerifier": pkce.verifier, "deviceName": Self.relayName(deviceName)],
                                       as: Answer.self)
        return (answer.token, answer.account)
    }

    public func account(token: String) async throws -> Account {
        try await request("v1/account", token: token, as: Account.self)
    }

    /// Puts this Mac on the account, proving it holds the room's key.
    public func registerMac(token: String, identity: RemoteIdentity, name: String, accountID: String) async throws {
        let name = Self.relayName(name)
        let macKey = RemoteEncoding.base64url(identity.noise.publicKey)
        let message = Data("yardlet-account-mac/1\n\(accountID)\n\(identity.room)\n\(macKey)\n\(name)".utf8)
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.relayPrivateKey).signature(for: message)
        struct Answer: Decodable { var ok: Bool? }
        _ = try await request("v1/account/macs/\(identity.room)", method: "PUT", token: token, body: [
            "macKey": macKey, "relayKey": RemoteEncoding.base64url(identity.relayPublicKey), "name": name,
            "sig": RemoteEncoding.base64url(signature)
        ], as: Answer.self)
    }

    /// A one-use enrollment for the authenticated Noise key on this host. Older relays only support
    /// the number both devices compare; a missing host or an authentication failure is still an error.
    public func linkGrant(token: String, room: String, clientKey: Data) async throws -> String? {
        struct Answer: Decodable { var grant: String }
        do {
            return try await request("v1/account/macs/\(room)/link-grants", method: "POST", token: token,
                                     body: ["clientKey": RemoteEncoding.base64url(clientKey)], as: Answer.self).grant
        } catch let error as Failure where error.status == 404 && error.code == "http404" {
            return nil
        }
    }

    public func redeemLinkGrant(_ grant: String, token: String, room: String, clientKey: Data) async throws -> Bool {
        struct Answer: Decodable { var ok: Bool }
        return try await request("v1/account/macs/\(room)/link-grants/redeem", method: "POST", token: token,
                                 body: ["grant": grant, "clientKey": RemoteEncoding.base64url(clientKey)], as: Answer.self).ok
    }

    public func removeMac(token: String, room: String) async throws {
        try await send("v1/account/macs/\(room)", method: "DELETE", token: token)
    }

    public func logout(token: String) async throws {
        try await send("v1/auth/logout", method: "POST", token: token)
    }

    // MARK: - Push targets

    /// Binds this phone's push token to the Mac's room (§14.5): the target `held` names when the room still holds it
    /// for the token, or nil when the relay sent the target to the token in a push instead. The phone gives the target
    /// to that Mac; the relay pushes to it for that room alone, and the Mac never holds the token.
    public func registerPushTarget(room: String, provider: String, token: String, held: String?) async throws -> String? {
        struct Answer: Decodable { var target: String? }
        var body = ["provider": provider, "token": token]
        body["target"] = held
        return try await request("v1/rooms/\(room)/push-targets", method: "POST", body: body, as: Answer.self).target
    }

    /// Ends a target this phone registered, so its Mac can no longer push to it (§14.5).
    public func removePushTarget(room: String, target: String) async throws {
        try await send("v1/rooms/\(room)/push-targets", method: "DELETE", body: ["target": target])
    }

    // MARK: - HTTP

    private func send(_ path: String, method: String, token: String? = nil, body: [String: String]? = nil) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
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
