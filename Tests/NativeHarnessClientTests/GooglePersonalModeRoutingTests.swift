import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

@MainActor
final class GooglePersonalModeRoutingTests: XCTestCase {
    func testTwoAccountsRefreshAndCallWithTheirOwnPersonalModeClients() async throws {
        let server = PersonalModeServer()
        let agent = FakeUserAgent()
        let store = InMemoryConnectorCredentialStore()
        var env = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: store, http: server,
            userAgent: agent, sha256: MacOAuthUserAgent.sha256, clientVersion: "test")
        env.google = FakeGoogle.endpoints
        env.googleWorkspaceTransport = server
        let center = ConnectorCenter(environment: env)
        let users = ["first", "second"]
        for user in users {
            let added = try await center.addGoogleAccount(services: [.gmail], clientID: PersonalModeServer.client(user),
                                                          secret: "fixture-\(user)")
            let account = try XCTUnwrap(added)
            await center.waitForConnection(account.id)
            XCTAssertEqual(center.googleAccounts.first { $0.id == account.id }?.address, "\(user)@example.test")
            let item = try XCTUnwrap(store.load(account.id))
            XCTAssertEqual(item.clientID, PersonalModeServer.client(user))
            XCTAssertNil(item.uiAccessToken)
        }

        XCTAssertNil(center.googleAppClientID)
        let tools = await center.connectorTools(for: ConnectorToolContext())
        let labels = try XCTUnwrap(tools.first { $0["name"] == .string("gmail_list_labels") })
        let accounts = labels["inputSchema"]?["properties"]?["account"]?["enum"]?.arrayValue
        XCTAssertEqual(Set(accounts?.compactMap(\.stringValue) ?? []), Set(users.map { "\($0)@example.test" }))
        for user in users.reversed() {
            let account = "\(user)@example.test"
            let result = await center.callConnectorTool(named: "gmail_list_labels", arguments: .object(["account": .string(account)]),
                                                        for: ConnectorToolContext())
            let answer = try XCTUnwrap(result)
            XCTAssertFalse(answer.isError, answer.text)
            XCTAssertTrue(answer.text.contains(account))
        }
    }
}

private struct PersonalModeServer: ConnectorHTTPTransport {
    static func client(_ user: String) -> String { "\(user).apps.googleusercontent.com" }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        func reply(_ status: Int, _ body: [String: ToolJSON]) throws -> (Data, HTTPURLResponse) {
            let data = try JSONEncoder().encode(ToolJSON.object(body))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                          headerFields: ["Content-Type": "application/json"])!)
        }
        let users = ["first", "second"]
        if url == FakeGoogle.endpoints.token {
            let form = FakeConnectorServer.form(request)
            guard let user = users.first(where: { Self.client($0) == form["client_id"] }),
                  form["client_secret"] == "fixture-\(user)" else { return try reply(401, [:]) }
            let refresh = form["grant_type"] == "refresh_token"
            guard !refresh || form["refresh_token"] == "renew-\(user)" else { return try reply(400, [:]) }
            return try reply(200, ["access_token": .string((refresh ? "fresh-" : "initial-") + user),
                                   "refresh_token": .string("renew-\(user)"), "token_type": .string("Bearer"),
                                   "expires_in": .integer(3600)])
        }

        let bearer = request.value(forHTTPHeaderField: "Authorization")
        guard let user = users.first(where: { bearer == "Bearer initial-\($0)" || bearer == "Bearer fresh-\($0)" })
        else { return try reply(401, [:]) }
        let address = ToolJSON.string("\(user)@example.test")
        if url.path.hasSuffix("/profile") || url.path.hasSuffix("/userinfo") {
            return try reply(200, ["emailAddress": address, "email": address])
        }
        guard url.absoluteString == "https://gmailmcp.googleapis.com/mcp/v1", let data = request.httpBody
        else { throw URLError(.badURL) }
        let body = try JSONDecoder().decode(ToolJSON.self, from: data)
        let result: ToolJSON
        switch body["method"]?.stringValue {
        case "tools/list":
            result = .object(["tools": .array([.object([
                "name": .string("list_labels"), "description": .string("List labels"),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                "annotations": .object(["readOnlyHint": .bool(true)])
            ])])])
        case "tools/call":
            guard bearer == "Bearer fresh-\(user)" else { return try reply(401, [:]) }
            guard body["params"]?["name"] == .string("list_labels"),
                  body["params"]?["arguments"]?["account"] == nil else { return try reply(400, [:]) }
            result = .object(["content": .array([.object(["type": .string("text"), "text": address])])])
        default:
            throw URLError(.badServerResponse)
        }
        return try reply(200, ["jsonrpc": .string("2.0"), "id": .integer(1), "result": result])
    }
}
