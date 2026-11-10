import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// An authorization server as its RFC 8414 (or OpenID) metadata describes it.
struct OAuthAuthorizationServer: Equatable, Sendable {
    var issuer: String?
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var tokenEndpointAuthMethods: [String]?
}

/// What discovery found for one MCP server: where to sign in, the resource to name, and the
/// scope to ask for.
struct OAuthPlan: Equatable, Sendable {
    var server: OAuthAuthorizationServer
    /// RFC 8707 resource indicator: the protected resource metadata's `resource`, or the server URL.
    /// Nil for a plain API sign-in (Google's REST APIs), which names no resource.
    var resource: String?
    var scope: String?
}

/// The OAuth client Yardlet registered for one sign-in.
struct OAuthClient: Equatable, Sendable {
    var id: String
    var secret: String?
    /// `none`, `client_secret_post`, or `client_secret_basic`.
    var authMethod: String
}

enum ConnectorOAuthError: Error, Equatable, LocalizedError {
    case noAuthorizationServer
    /// The server's protected resource metadata names a resource other than the server (RFC 9728
    /// §3.3), so it is not used.
    case resourceMismatch(String)
    case noDynamicRegistration
    case registrationFailed(String)
    case authorizationDenied(String)
    /// The person declined on the sign-in page (`access_denied`, Google's and Slack's Cancel).
    case declined
    case stateMismatch
    case missingCode
    case tokenRequestFailed(String)
    /// The authorization server refused the grant (`invalid_grant`): a refresh token that was
    /// revoked or has expired, or a spent code. Only a new sign-in helps.
    case invalidGrant(String)
    /// The token endpoint failed for now (5xx, 429, `temporarily_unavailable`, `server_error`, or
    /// an answer that was not a token). The grant may still be good; trying again later can work.
    case serverUnavailable(String)
    case timedOut
    case cannotOpenBrowser

    var errorDescription: String? {
        switch self {
        case .noAuthorizationServer:
            L10n.string("The server did not say where to sign in.")
        case .resourceMismatch(let resource):
            L10n.format("The server asked to sign in for another address (%@). Check the connector's server address.", resource)
        case .noDynamicRegistration:
            L10n.string("The server does not let apps register themselves. Connect with an OAuth client of your own or an access token.")
        case .registrationFailed(let detail):
            L10n.format("The server did not register Yardlet: %@", detail)
        case .authorizationDenied(let detail):
            L10n.format("Sign-in was not completed: %@", detail)
        case .declined:
            L10n.string("Sign-in was cancelled.")
        case .stateMismatch, .missingCode:
            L10n.string("The sign-in answer did not match the request. Try connecting again.")
        case .tokenRequestFailed(let detail):
            L10n.format("The server did not issue a token: %@", detail)
        case .invalidGrant(let detail):
            L10n.format("The sign-in is no longer valid: %@", detail)
        case .serverUnavailable(let detail):
            L10n.format("The sign-in server is not answering right now: %@", detail)
        case .timedOut:
            L10n.string("Sign-in did not finish in time.")
        case .cannotOpenBrowser:
            L10n.string("Yardlet could not open the browser to sign in.")
        }
    }
}

/// OAuth for MCP servers as the MCP authorization specification lays it out: protected resource
/// metadata (RFC 9728), authorization server metadata (RFC 8414), dynamic client registration
/// (RFC 7591), and the authorization code flow with PKCE for a native app on a loopback redirect
/// (RFC 8252), naming the MCP server as the resource (RFC 8707).
enum ConnectorOAuth {
    // MARK: Discovery

    static func discover(
        serverURL: URL,
        challenge: BearerChallenge?,
        http: any ConnectorHTTPTransport
    ) async throws -> OAuthPlan {
        var resourceMetadata: ToolJSON?
        for url in protectedResourceMetadataURLs(serverURL: serverURL, challenge: challenge) {
            if let metadata = await fetchJSON(url, http: http), metadata["authorization_servers"] != nil || metadata["resource"] != nil {
                resourceMetadata = metadata
                break
            }
        }
        let resource = resourceMetadata?["resource"]?.stringValue
        if let resource, !Self.resource(resource, covers: serverURL) {
            throw ConnectorOAuthError.resourceMismatch(resource)
        }
        // Servers from before protected resource metadata act as their own authorization server.
        let issuers = resourceMetadata?["authorization_servers"]?.arrayValue?.compactMap(\.stringValue)
            .compactMap(URL.init(string:)) ?? []
        let issuer = issuers.first ?? origin(of: serverURL)
        guard let issuer, let server = await authorizationServer(issuer: issuer, http: http) else {
            throw ConnectorOAuthError.noAuthorizationServer
        }
        let scopes = resourceMetadata?["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let scope = challenge?.scope ?? (scopes.isEmpty ? nil : scopes.joined(separator: " "))
        return OAuthPlan(
            server: server,
            resource: resource ?? canonicalResource(serverURL),
            scope: scope
        )
    }

    /// Whether protected resource metadata naming `resource` is the server's (RFC 9728 §3.3): the same
    /// scheme, host and port, and the server's path at or under the resource's. Many servers name their
    /// origin rather than the exact address, so the MCP SDKs compare them this way too.
    static func resource(_ resource: String, covers serverURL: URL) -> Bool {
        guard let named = URLComponents(string: resource),
              let server = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = named.scheme?.lowercased(), scheme == server.scheme?.lowercased(),
              let host = named.host?.lowercased(), !host.isEmpty, host == server.host?.lowercased(),
              port(named) == port(server)
        else { return false }
        func directory(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }
        return directory(server.percentEncodedPath).hasPrefix(directory(named.percentEncodedPath))
    }

    private static func port(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// The challenge's metadata address, then the well-known one with the server's path, then
    /// the well-known one at the root.
    static func protectedResourceMetadataURLs(serverURL: URL, challenge: BearerChallenge?) -> [URL] {
        var urls: [URL] = []
        if let named = challenge?.resourceMetadata { urls.append(named) }
        guard let origin = origin(of: serverURL) else { return urls }
        let path = serverURL.path(percentEncoded: true)
        let wellKnown = "/.well-known/oauth-protected-resource"
        if !path.isEmpty, path != "/", let url = URL(string: origin.absoluteString + wellKnown + path) { urls.append(url) }
        if let url = URL(string: origin.absoluteString + wellKnown) { urls.append(url) }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// RFC 8414 and OpenID discovery addresses in the order the MCP specification gives.
    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        var path = issuer.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        let base = origin.absoluteString
        let strings = path.isEmpty
            ? ["\(base)/.well-known/oauth-authorization-server", "\(base)/.well-known/openid-configuration"]
            : ["\(base)/.well-known/oauth-authorization-server\(path)",
               "\(base)/.well-known/openid-configuration\(path)",
               "\(base)\(path)/.well-known/openid-configuration"]
        return strings.compactMap(URL.init(string:))
    }

    private static func authorizationServer(issuer: URL, http: any ConnectorHTTPTransport) async -> OAuthAuthorizationServer? {
        for url in authorizationServerMetadataURLs(issuer: issuer) {
            guard let metadata = await fetchJSON(url, http: http),
                  let authorization = metadata["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                  let token = metadata["token_endpoint"]?.stringValue.flatMap(URL.init(string:))
            else { continue }
            return OAuthAuthorizationServer(
                issuer: metadata["issuer"]?.stringValue,
                authorizationEndpoint: authorization,
                tokenEndpoint: token,
                registrationEndpoint: metadata["registration_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                tokenEndpointAuthMethods: metadata["token_endpoint_auth_methods_supported"]?.arrayValue?.compactMap(\.stringValue)
            )
        }
        return nil
    }

    // MARK: Registration

    static func register(
        with server: OAuthAuthorizationServer,
        redirectURI: URL,
        http: any ConnectorHTTPTransport
    ) async throws -> OAuthClient {
        guard let endpoint = server.registrationEndpoint else { throw ConnectorOAuthError.noDynamicRegistration }
        // A public client with PKCE, unless the server takes only confidential ones.
        let methods = server.tokenEndpointAuthMethods ?? ["none"]
        let requested = methods.contains("none") ? "none"
            : methods.contains("client_secret_post") ? "client_secret_post" : "client_secret_basic"
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ToolJSON.object([
            "client_name": .string("Yardlet"),
            "redirect_uris": .array([.string(redirectURI.absoluteString)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string(requested)
        ]))
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let body = try? JSONDecoder().decode(ToolJSON.self, from: data),
              let clientID = body["client_id"]?.stringValue
        else {
            throw ConnectorOAuthError.registrationFailed(oauthErrorText(data, status: response.statusCode))
        }
        let secret = body["client_secret"]?.stringValue
        let method = body["token_endpoint_auth_method"]?.stringValue ?? (secret == nil ? "none" : requested)
        return OAuthClient(id: clientID, secret: secret, authMethod: method)
    }

    /// The loopback port a registered client's redirect uses. A client the user registers with a
    /// service names its redirect URI exactly (Slack, Google web clients), so it cannot be the
    /// random port a dynamically registered client gets.
    static let registeredClientRedirectPort: UInt16 = 47823

    /// `http://127.0.0.1:47823/callback`, which the user enters in the service's app settings.
    static var registeredClientRedirectURI: URL {
        URL(string: "http://127.0.0.1:\(registeredClientRedirectPort)/callback")!
    }

    /// A client the user registered: public with PKCE when there is no secret, otherwise the
    /// secret goes the way the server takes it, in the form unless it takes only Basic.
    static func registeredClient(id: String, secret: String?, server: OAuthAuthorizationServer) -> OAuthClient {
        guard let secret, !secret.isEmpty else { return OAuthClient(id: id, secret: nil, authMethod: "none") }
        let methods = server.tokenEndpointAuthMethods ?? []
        let method = methods.isEmpty || methods.contains("client_secret_post") ? "client_secret_post" : "client_secret_basic"
        return OAuthClient(id: id, secret: secret, authMethod: method)
    }

    // MARK: Authorization

    static func authorizationURL(
        plan: OAuthPlan,
        client: OAuthClient,
        redirectURI: URL,
        state: String,
        codeChallenge: String,
        extraParameters: [String: String] = [:]
    ) -> URL {
        var components = URLComponents(url: plan.server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        if let resource = plan.resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        if let scope = plan.scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        let taken = Set(items.map(\.name))
        items += extraParameters.sorted { $0.key < $1.key }.filter { !taken.contains($0.key) }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        // `+` in a query value is a space to many servers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The code from the loopback redirect, after checking it answers this request.
    static func code(fromCallback callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw ConnectorOAuthError.declined }
            throw ConnectorOAuthError.authorizationDenied(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw ConnectorOAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw ConnectorOAuthError.missingCode }
        return code
    }

    // MARK: Tokens

    static func exchange(
        code: String,
        verifier: String,
        plan: OAuthPlan,
        client: OAuthClient,
        redirectURI: URL,
        http: any ConnectorHTTPTransport,
        now: Date
    ) async throws -> ConnectorCredential {
        let base = ConnectorCredential(
            kind: .oauth,
            accessToken: "",
            scope: plan.scope,
            clientID: client.id,
            clientSecret: client.secret,
            tokenEndpoint: plan.server.tokenEndpoint,
            tokenEndpointAuthMethod: client.authMethod,
            resource: plan.resource
        )
        return try await tokenRequest(
            credential: base,
            fields: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI.absoluteString),
                ("code_verifier", verifier)
            ],
            http: http,
            now: now
        )
    }

    static func refresh(
        _ credential: ConnectorCredential,
        http: any ConnectorHTTPTransport,
        now: Date
    ) async throws -> ConnectorCredential {
        guard let refreshToken = credential.refreshToken else {
            throw ConnectorOAuthError.tokenRequestFailed("no refresh token")
        }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken)]
        if let scope = credential.refreshScope, !scope.isEmpty { fields.append(("scope", scope)) }
        return try await tokenRequest(credential: credential, fields: fields, http: http, now: now)
    }

    private static func tokenRequest(
        credential: ConnectorCredential,
        fields: [(String, String)],
        http: any ConnectorHTTPTransport,
        now: Date
    ) async throws -> ConnectorCredential {
        guard let endpoint = credential.tokenEndpoint, let clientID = credential.clientID else {
            throw ConnectorOAuthError.tokenRequestFailed("no token endpoint")
        }
        var form = fields
        if let resource = credential.resource { form.append(("resource", resource)) }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch (credential.tokenEndpointAuthMethod, credential.clientSecret) {
        case ("client_secret_basic", let secret?):
            let pair = "\(formEncode(clientID)):\(formEncode(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        case ("client_secret_post", let secret?):
            form += [("client_id", clientID), ("client_secret", secret)]
        default:
            form.append(("client_id", clientID))
        }
        request.httpBody = Data(form.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let body = try? JSONDecoder().decode(ToolJSON.self, from: data),
              let accessToken = body["access_token"]?.stringValue, !accessToken.isEmpty
        else {
            let code = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["error"]?.stringValue
            if response.statusCode == 400, code == "invalid_grant" {
                throw ConnectorOAuthError.invalidGrant(oauthErrorText(data, status: response.statusCode))
            }
            if isTemporary(status: response.statusCode, code: code) {
                throw ConnectorOAuthError.serverUnavailable(oauthErrorText(data, status: response.statusCode))
            }
            throw ConnectorOAuthError.tokenRequestFailed(oauthErrorText(data, status: response.statusCode))
        }
        var issued = credential
        issued.accessToken = accessToken
        // A server that rotates refresh tokens sends a new one; one that does not keeps the old.
        if let refreshToken = body["refresh_token"]?.stringValue { issued.refreshToken = refreshToken }
        issued.expiresAt = expiresIn(body["expires_in"]).map { now.addingTimeInterval($0) }
        if let scope = body["scope"]?.stringValue { issued.scope = scope }
        return issued
    }

    private static func expiresIn(_ value: ToolJSON?) -> TimeInterval? {
        switch value {
        case .integer(let seconds): TimeInterval(seconds)
        case .number(let seconds): seconds
        case .string(let text): TimeInterval(text)
        default: nil
        }
    }

    // MARK: PKCE and values

    /// 32 random bytes, base64url: a PKCE verifier or a `state`.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data()
        for _ in 0..<4 { withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) } }
        return base64URL(bytes)
    }

    static func codeChallenge(for verifier: String, sha256: (Data) -> Data) -> String {
        base64URL(sha256(Data(verifier.utf8)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase scheme and host, no fragment: the MCP specification's canonical server URI.
    static func canonicalResource(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func origin(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(port)")
    }

    private static let formAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    private static func fetchJSON(_ url: URL, http: any ConnectorHTTPTransport) async -> ToolJSON? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPHTTPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await http.send(request), response.statusCode == 200,
              let json = try? JSONDecoder().decode(ToolJSON.self, from: data), json.objectValue != nil
        else { return nil }
        return json
    }

    private static func oauthErrorText(_ data: Data, status: Int) -> String {
        if let body = try? JSONDecoder().decode(ToolJSON.self, from: data) {
            if let description = body["error_description"]?.stringValue { return description }
            if let error = body["error"]?.stringValue { return error }
        }
        let excerpt = MCPHTTPClient.excerpt(data)
        return excerpt.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(excerpt)"
    }

    /// A token answer worth trying again: the server's own trouble or a rate limit, the
    /// `temporarily_unavailable` and `server_error` codes some servers send here too, or a success
    /// that carried no token. Any other refusal stands.
    private static func isTemporary(status: Int, code: String?) -> Bool {
        status >= 500 || status == 429 || status == 408 || (200..<300).contains(status)
            || code == "temporarily_unavailable" || code == "server_error"
    }
}
