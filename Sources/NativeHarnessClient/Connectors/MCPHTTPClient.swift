import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Sends one HTTP request. Connectors use URLSession; tests stand in a scripted server.
protocol ConnectorHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, no cache, nothing written to disk. A connector's only
/// credential is the bearer token Yardlet adds itself.
struct URLSessionConnectorTransport: ConnectorHTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSessionConnectorTransport.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The parameters of a `WWW-Authenticate: Bearer …` challenge that MCP authorization uses.
struct BearerChallenge: Equatable, Sendable {
    var resourceMetadata: URL?
    var scope: String?
    var error: String?

    init(resourceMetadata: URL? = nil, scope: String? = nil, error: String? = nil) {
        self.resourceMetadata = resourceMetadata
        self.scope = scope
        self.error = error
    }

    /// Nil when the header is absent or names another scheme.
    init?(header: String?) {
        guard let header, let range = header.range(of: "bearer", options: [.caseInsensitive, .anchored]) else {
            return nil
        }
        let parameters = Self.parameters(String(header[range.upperBound...]))
        resourceMetadata = parameters["resource_metadata"].flatMap(URL.init(string:))
        scope = parameters["scope"]
        error = parameters["error"]
    }

    private static let parameterPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))"#
    )

    static func parameters(_ text: String) -> [String: String] {
        let range = NSRange(text.startIndex..., in: text)
        var parameters: [String: String] = [:]
        for match in parameterPattern.matches(in: text, range: range) {
            guard let key = Range(match.range(at: 1), in: text) else { continue }
            let value = Range(match.range(at: 2), in: text) ?? Range(match.range(at: 3), in: text)
            guard let value else { continue }
            parameters[text[key].lowercased()] = text[value].replacingOccurrences(of: #"\""#, with: #"""#)
        }
        return parameters
    }
}

enum MCPHTTPError: Error, Equatable, LocalizedError {
    /// 401, or 403 `insufficient_scope`: the credential is missing, expired, or not enough.
    case unauthorized(BearerChallenge?)
    case http(status: Int, body: String)
    case rpc(code: Int64, message: String)
    case invalidResponse(String)
    /// The server forgot the MCP session this client was using (404 with a session ID).
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .unauthorized: L10n.string("The server asked for a new sign-in.")
        case .http(let status, let body): body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
        case .rpc(_, let message): message
        case .invalidResponse(let detail): L10n.format("The server sent a reply Yardlet could not read (%@).", detail)
        case .sessionExpired: L10n.string("The server ended the session.")
        }
    }
}

/// The client half of MCP's Streamable HTTP transport, for tools only: `initialize`,
/// `tools/list` (every page), and `tools/call`. Each request is a POST whose answer is JSON or a
/// short event stream; the server's `Mcp-Session-Id` is sent back until the server forgets it,
/// and then the client initializes again once. The client declares no capabilities, so a server
/// has no reason to send it requests of its own.
actor MCPHTTPClient {
    static let protocolVersion = "2025-11-25"

    let endpoint: URL
    private let transport: any ConnectorHTTPTransport
    private let clientVersion: String
    private var bearer: String?
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var initialized = false
    /// The icons the server gave for itself in its last `initialize`.
    private(set) var serverIcons: [MCPServerIcon] = []
    private var initialization: Task<Void, Error>?
    private var nextID: Int64 = 1
    /// Shorter than Codex's 120-second MCP call limit, so a slow server ends as a tool error.
    private let requestTimeout: TimeInterval

    init(endpoint: URL, transport: any ConnectorHTTPTransport, clientVersion: String, requestTimeout: TimeInterval = 100) {
        self.endpoint = endpoint
        self.transport = transport
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
    }

    func setBearer(_ token: String?) {
        bearer = token
    }

    /// Sends the token in the address's query instead of a header, for a server that takes its key
    /// there (Browserbase). The endpoint the client keeps stays without it.
    func setQueryToken(name: String, value: String?) {
        queryToken = value.map { (name, $0) }
        bearer = nil
    }

    private var queryToken: (name: String, value: String)?

    /// Sends the token as is in a header of the server's choosing (`x-api-key`) instead of
    /// `Authorization: Bearer`.
    func setHeaderToken(name: String, value: String?) {
        headerToken = value.map { (name, $0) }
        bearer = nil
    }

    private var headerToken: (name: String, value: String)?

    private var requestURL: URL {
        guard let queryToken, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != queryToken.name }
            + [URLQueryItem(name: queryToken.name, value: queryToken.value)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? endpoint
    }

    func listTools() async throws -> [ToolJSON] {
        var tools: [ToolJSON] = []
        var cursor: String?
        repeat {
            let params: ToolJSON = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await request("tools/list", params)
            tools += result["tools"]?.arrayValue ?? []
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && tools.count < 2_000
        return tools
    }

    /// The server's `CallToolResult` as sent.
    func callTool(name: String, arguments: ToolJSON) async throws -> ToolJSON {
        try await request("tools/call", .object(["name": .string(name), "arguments": arguments]))
    }

    /// Forgets the MCP session, as when the credential changes.
    func reset() {
        sessionID = nil
        negotiatedVersion = nil
        initialized = false
    }

    private func request(_ method: String, _ params: ToolJSON) async throws -> ToolJSON {
        do {
            try await initializeIfNeeded()
            return try await send(method, params)
        } catch MCPHTTPError.sessionExpired {
            reset()
            try await initializeIfNeeded()
            return try await send(method, params)
        }
    }

    /// Concurrent first calls share one `initialize`.
    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        if let initialization { return try await initialization.value }
        let task = Task { try await self.performInitialize() }
        initialization = task
        defer { initialization = nil }
        try await task.value
    }

    private func performInitialize() async throws {
        let result = try await send("initialize", .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("yardlet"),
                "title": .string("Yardlet"),
                "version": .string(clientVersion)
            ])
        ]))
        negotiatedVersion = result["protocolVersion"]?.stringValue
        serverIcons = MCPServerIcon.list(in: result["serverInfo"])
        initialized = true
        _ = try? await post(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
    }

    private func send(_ method: String, _ params: ToolJSON) async throws -> ToolJSON {
        let id = nextID
        nextID += 1
        let (data, response) = try await post(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params
        ]))
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        let message = try Self.reply(to: id, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        if let error = message["error"] {
            let code: Int64 = if case .integer(let value) = error["code"] { value } else { 0 }
            throw MCPHTTPError.rpc(code: code, message: error["message"]?.stringValue ?? "Error \(code)")
        }
        guard let result = message["result"] else { throw MCPHTTPError.invalidResponse("no result") }
        return result
    }

    @discardableResult
    private func post(_ body: ToolJSON) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: requestURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let headerToken { request.setValue(headerToken.value, forHTTPHeaderField: headerToken.name) }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw MCPHTTPError.unauthorized(BearerChallenge(header: response.value(forHTTPHeaderField: "WWW-Authenticate")))
        case 403:
            let challenge = BearerChallenge(header: response.value(forHTTPHeaderField: "WWW-Authenticate"))
            if challenge?.error == "insufficient_scope" { throw MCPHTTPError.unauthorized(challenge) }
            throw MCPHTTPError.http(status: 403, body: Self.excerpt(data))
        case 404 where sessionID != nil:
            throw MCPHTTPError.sessionExpired
        default:
            throw MCPHTTPError.http(status: response.statusCode, body: Self.excerpt(data))
        }
    }

    /// The JSON-RPC response with this ID, from a JSON body or from the `data:` of an event stream.
    static func reply(to id: Int64, in data: Data, contentType: String?) throws -> ToolJSON {
        let messages: [ToolJSON]
        if contentType?.lowercased().contains("text/event-stream") == true {
            messages = eventStreamMessages(data)
        } else {
            guard let message = try? JSONDecoder().decode(ToolJSON.self, from: data) else {
                throw MCPHTTPError.invalidResponse("not JSON")
            }
            messages = message.arrayValue ?? [message]
        }
        let reply = messages.first { message in
            message["id"] == .integer(id) && (message["result"] != nil || message["error"] != nil)
        }
        guard let reply else { throw MCPHTTPError.invalidResponse("no reply to request \(id)") }
        return reply
    }

    /// Each event's `data:` lines joined, decoded as JSON; other fields and bad events are skipped.
    static func eventStreamMessages(_ data: Data) -> [ToolJSON] {
        let text = String(decoding: data, as: UTF8.self)
        var messages: [ToolJSON] = []
        var lines: [String] = []
        func flush() {
            defer { lines.removeAll() }
            guard !lines.isEmpty, let message = try? JSONDecoder().decode(ToolJSON.self, from: Data(lines.joined(separator: "\n").utf8)) else { return }
            messages.append(contentsOf: message.arrayValue ?? [message])
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                lines.append(String(value))
            }
        }
        flush()
        return messages
    }

    static func excerpt(_ data: Data) -> String {
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}
