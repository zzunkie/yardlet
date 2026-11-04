import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Microsoft Graph v1.0 for one Microsoft account, through the account's `OAuthAPISession`: JSON in
/// and out, the headers some Graph requests need (`Prefer`, `ConsistencyLevel`), the raw bytes an
/// upload sends, an upload session's ranges, and the next page Graph links to. Nothing here logs or
/// keeps what a mailbox, calendar, drive, or chat holds; a failure carries Graph's own error message,
/// never a request or response body (learn.microsoft.com/graph/errors).
struct GraphAPI: Sendable {
    let base: URL
    let session: OAuthAPISession

    enum Failure: Error, Equatable, LocalizedError {
        /// Graph answered with an error: its HTTP status and its `error.message`.
        case http(status: Int, message: String)
        case unreadableAnswer
        /// An ID a request cannot carry (empty, too long, a line break), refused before it.
        case invalidID(String)
        /// A page link that does not point back into Graph, which the account's token never goes to.
        case foreignLink
        /// Content larger than a tool sends or returns.
        case tooLarge(bytes: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "\(message) (HTTP \(status))"
            case .unreadableAnswer: "Microsoft Graph's answer could not be read."
            case .invalidID(let id): "Not an ID Microsoft Graph takes: \(id)"
            case .foreignLink: "pageToken is not a Microsoft Graph page link from an earlier answer."
            case .tooLarge(let bytes, let limit): "The content is \(bytes) bytes, over the \(limit) a tool takes."
            }
        }
    }

    /// An ID as one path segment, percent-encoded: message and item IDs carry `=`, `-`, and `_`,
    /// and a chat ID carries `:` and `@`.
    static func segment(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 1_024, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidID(id) }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
    }

    func get(_ path: [String], _ query: [URLQueryItem] = [], headers: [String: String] = [:]) async throws -> ToolJSON {
        try await json("GET", url(path, query), body: nil, headers: headers)
    }

    /// The next page of a list, from the `@odata.nextLink` an earlier answer gave. Only a link
    /// into this Graph base is followed, so the account's token goes nowhere else.
    func get(page link: String, headers: [String: String] = [:]) async throws -> ToolJSON {
        guard let url = URL(string: link), url.scheme == base.scheme, url.host() == base.host(),
              url.port == base.port, url.path(percentEncoded: true).hasPrefix(base.path(percentEncoded: true))
        else { throw Failure.foreignLink }
        return try await json("GET", url, body: nil, headers: headers)
    }

    func post(_ path: [String], _ body: ToolJSON, headers: [String: String] = [:]) async throws -> ToolJSON {
        try await json("POST", url(path, []), body: body, headers: headers)
    }

    func patch(_ path: [String], _ body: ToolJSON, headers: [String: String] = [:]) async throws -> ToolJSON {
        try await json("PATCH", url(path, []), body: body, headers: headers)
    }

    func delete(_ path: [String]) async throws {
        _ = try await json("DELETE", url(path, []), body: nil, headers: [:])
    }

    /// Sends bytes as they are (`PUT …/content`), answering with Graph's JSON.
    func put(_ path: [String], _ query: [URLQueryItem], content: Data, contentType: String) async throws -> ToolJSON {
        let (data, response) = try await send("PUT", url(path, query), body: content,
                                              headers: ["Content-Type": contentType, "Accept": "application/json"])
        return try Self.decode(data, response)
    }

    /// Sends one range of a file's bytes to an upload session's address (`uploadUrl`), which carries
    /// its own authorization, so the account's token is not sent there
    /// (learn.microsoft.com/graph/outlook-large-attachments).
    func upload(_ content: Data, at offset: Int, of total: Int, to uploadURL: URL) async throws -> ToolJSON {
        let (data, response) = try await session.http.send(Self.request("PUT", uploadURL, body: content, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(content.count),
            "Content-Range": "bytes \(offset)-\(offset + content.count - 1)/\(total)",
        ]))
        return try Self.decode(data, response)
    }

    /// Ends an upload session that will not be finished, also without the token.
    func cancelUpload(_ uploadURL: URL) async {
        _ = try? await session.http.send(Self.request("DELETE", uploadURL, body: nil, headers: [:]))
    }

    // MARK: Requests

    private func json(_ method: String, _ url: URL, body: ToolJSON?, headers: [String: String]) async throws -> ToolJSON {
        var all = headers
        all["Accept"] = "application/json"
        let payload = try body.map { try JSONEncoder().encode($0) }
        if payload != nil { all["Content-Type"] = "application/json" }
        let (data, response) = try await send(method, url, body: payload, headers: all)
        return try Self.decode(data, response)
    }

    private func url(_ path: [String], _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var prefix = components.percentEncodedPath
        if !prefix.hasSuffix("/") { prefix += "/" }
        components.percentEncodedPath = prefix + path.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
            // `+` would be a space to Graph's query parser; a query that means a plus keeps it.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try await session.send { Self.request(method, url, body: body, headers: headers) }
    }

    private static func request(_ method: String, _ url: URL, body: Data?, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    private static func decode(_ data: Data, _ response: HTTPURLResponse) throws -> ToolJSON {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["error"]?["message"]?.stringValue ?? ""
            throw Failure.http(status: response.statusCode, message: message)
        }
        if data.isEmpty { return .object([:]) }
        guard let json = try? JSONDecoder().decode(ToolJSON.self, from: data) else { throw Failure.unreadableAnswer }
        return json
    }
}

/// What the Microsoft runners share: Graph's people and lists in the shape tools answer with.
enum GraphShape {
    /// "Name <address>" for a Graph `recipient`, or the address alone.
    static func person(_ recipient: ToolJSON?) -> ToolJSON? {
        guard let address = recipient?["emailAddress"]?["address"]?.stringValue else { return nil }
        let name = recipient?["emailAddress"]?["name"]?.stringValue
        return .string(name.map { $0.isEmpty || $0 == address ? address : "\($0) <\(address)>" } ?? address)
    }

    static func people(_ recipients: ToolJSON?) -> ToolJSON {
        .array((recipients?.arrayValue ?? []).compactMap(person))
    }

    /// Graph's recipients for a list of addresses. An address with a line break, a comma, or no
    /// `@` is refused before any request.
    static func recipients(_ addresses: [String], field: String) throws -> ToolJSON {
        .array(try addresses.map { address in
            let value = address.trimmingCharacters(in: .whitespaces)
            guard value.contains("@"), !value.contains(","),
                  !value.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
            else { throw ConnectorToolArguments.Problem.invalid("\(field) has an address Yardlet cannot send to: \(address)") }
            return .object(["emailAddress": .object(["address": .string(value)])])
        })
    }

    /// A list answer: the items, and the next page's link as `nextPageToken` when there is one.
    static func page(_ list: ToolJSON, key: String, _ transform: (ToolJSON) -> ToolJSON) -> ToolJSON {
        var result: [String: ToolJSON] = [key: .array((list["value"]?.arrayValue ?? []).map(transform))]
        if let next = list["@odata.nextLink"]?.stringValue { result["nextPageToken"] = .string(next) }
        return .object(result)
    }

    static func cut(_ text: String, _ limit: Int) -> (String, Bool) {
        text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }
}
