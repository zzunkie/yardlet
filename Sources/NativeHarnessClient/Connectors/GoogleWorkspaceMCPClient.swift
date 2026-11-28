import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Each POST stands alone. Only the caller holds the account, token and continuation state.
struct GoogleWorkspaceMCPClient: Sendable {
    static let protocolVersion = "2026-07-28"
    static let maxElicitationRounds = 3
    static let roundTripTimeout: TimeInterval = 150

    struct Card: Sendable {
        let title: String
        let detail: String
        let actions: [PermissionRequestAction]
    }
    typealias Responder = @Sendable (Card) async throws -> String?
    typealias RefreshToken = @Sendable (String) async throws -> String

    let endpoint: URL
    var transport: any ConnectorHTTPTransport = GoogleWorkspaceTransport()
    var clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    var language = L10n.shownLocalization ?? Locale.preferredLanguages.first ?? "en"

    func listTools(token: String? = nil, refreshToken: RefreshToken? = nil) async throws -> [ToolJSON] {
        var bearer = token
        var cursor: String?
        var seen: Set<String> = []
        var tools: [ToolJSON] = []
        repeat {
            let params = cursor.map { ["cursor": ToolJSON.string($0)] } ?? [:]
            let result = try await post("tools/list", params, token: &bearer, refreshToken: refreshToken)
            guard let page = result["tools"]?.arrayValue else { throw MCPHTTPError.invalidResponse("missing tools") }
            tools += page.map(GoogleWorkspaceMCPBridge.exposedTool)
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw MCPHTTPError.invalidResponse("repeated cursor") }
        } while cursor != nil
        return tools
    }

    func callTool(name: String, arguments: ToolJSON, taskFolders: [URL] = [], accountAddress: String,
                  token: String, refreshToken: RefreshToken? = nil, responder: Responder? = nil) async throws -> ToolJSON {
        guard !token.isEmpty else { throw MCPHTTPError.unauthorized(nil) }
        let prepared = try GoogleWorkspaceMCPBridge.prepareArguments(name: name, arguments: arguments, taskFolders: taskFolders)
        let call: [String: ToolJSON] = ["name": .string(name), "arguments": prepared]
        var bearer: String? = token
        var params = call
        var rounds = 0
        while true {
            let result = try await post("tools/call", params, token: &bearer, refreshToken: refreshToken)
            guard result["resultType"] == .string("input_required") else {
                return try await GoogleWorkspaceMCPBridge.augmentResult(name: name, result: result)
            }
            guard let state = result["requestState"]?.stringValue, !state.isEmpty,
                  let inputs = result["inputRequests"]?.objectValue, !inputs.isEmpty else {
                throw MCPHTTPError.invalidResponse("incomplete approval request")
            }
            var responses = inputs.mapValues { _ in ToolJSON.object(["action": .string("cancel")]) }
            var failure: GoogleWorkspaceMCPError?
            if rounds >= Self.maxElicitationRounds {
                failure = .roundLimit
            } else if responder == nil {
                failure = .unattended
            } else if inputs.count == 1, let (key, input) = inputs.first,
                      let form = GoogleWorkspaceForm(input: input, account: accountAddress), let responder {
                try Task.checkCancellation()
                let choice = try await ApprovalWait.whilePersonReads { try await responder(form.card) }
                try Task.checkCancellation()
                if let choice, form.card.actions.contains(where: { $0.id == choice }) {
                    responses[key] = .object(["action": .string("accept"), "content": .object([form.field: .string(choice)])])
                }
            } else {
                failure = .unsupported
            }
            params = call
            params["requestState"] = .string(state)
            params["inputResponses"] = .object(responses)
            if !responses.values.contains(where: { $0["action"] == .string("accept") }) {
                // A cancellation is terminal even if a server returns another form.
                let denied: ToolJSON
                do {
                    denied = try await post("tools/call", params, token: &bearer, refreshToken: refreshToken)
                } catch {
                    try Task.checkCancellation()
                    if let failure { throw failure }
                    throw error
                }
                if let failure { throw failure }
                guard denied["resultType"] != .string("input_required") else { throw GoogleWorkspaceMCPError.denied }
                return denied
            }
            rounds += 1
        }
    }

    private func post(_ method: String, _ fields: [String: ToolJSON], token: inout String?,
                      refreshToken: RefreshToken?) async throws -> ToolJSON {
        guard endpoint.scheme?.lowercased() == "https", endpoint.path == "/mcp/v1",
              endpoint.user == nil, endpoint.password == nil else { throw URLError(.badURL) }
        var params = fields
        params["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(Self.protocolVersion),
            "io.modelcontextprotocol/clientInfo": .object(["name": .string("Yardlet"), "version": .string(clientVersion)]),
            "io.modelcontextprotocol/clientCapabilities": .object(["elicitation": .object(["form": .object([:])])])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = URLRequest(url: endpoint, timeoutInterval: Self.roundTripTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        request.httpBody = try encoder.encode(ToolJSON.object([
            "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string(method), "params": .object(params)
        ]))
        var refreshed = false
        while true {
            try Task.checkCancellation()
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await roundTrip(request)
            try Task.checkCancellation()
            if response.statusCode == 401 {
                guard !refreshed else { throw GoogleWorkspaceMCPError.agentClient }
                guard let rejected = token, let refreshToken else { throw MCPHTTPError.unauthorized(nil) }
                token = try await refreshToken(rejected)
                guard token?.isEmpty == false else { throw MCPHTTPError.unauthorized(nil) }
                refreshed = true
                continue
            }
            let continuing = fields["requestState"] != nil
            guard (200..<300).contains(response.statusCode) else {
                throw GoogleWorkspaceMCPError.http(response, data: data, continuing: continuing)
            }
            let reply = try MCPHTTPClient.reply(to: 1, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
            if let error = reply["error"] {
                let message = error["message"]?.stringValue ?? ""
                if error["code"] == .integer(-32021) { throw GoogleWorkspaceMCPError.capability }
                if continuing, GoogleWorkspaceMCPError.isInvalidState(message) { throw GoogleWorkspaceMCPError.expired }
                let code: Int64 = if case let .integer(code) = error["code"] { code } else { 0 }
                throw MCPHTTPError.rpc(code: code, message: String(message.prefix(400)))
            }
            guard let result = reply["result"] else { throw MCPHTTPError.invalidResponse("missing result") }
            return result
        }
    }

    private func roundTrip(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await transport.send(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.roundTripTimeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Refuse redirects, including redirects that would turn the authenticated POST into a GET.
struct GoogleWorkspaceTransport: ConnectorHTTPTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await URLSessionConnectorTransport(session: Self.session).send(request)
    }
}
