import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

final class GoogleWorkspaceMCPClientTests: XCTestCase {
    private let endpoint = URL(string: "https://workspace.example.test/mcp/v1")!
    private let address = "work@example.test"
    private let token = UUID().uuidString

    func testButtonsReplayThePreparedAttachmentEvenIfTheFileChanges() async throws {
        for selected in ["ALLOW_ONCE", "DENY_ONCE", "ALLOW_AUDIENCE_ALWAYS"] {
            let server = GoogleScriptedServer([.form(), .done])
            let client = GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: path) }
            try Data("original".utf8).write(to: path)
            let args: ToolJSON = .object(["account": .string(address), "attachments": .array([
                .object(["path": .string(path.path)])])])
            _ = try await client.callTool(name: "send_message", arguments: args, accountAddress: address, token: token, responder: { card in
                XCTAssertEqual(card.title, "Send · work@example.test")
                XCTAssertEqual(card.actions.map(\.label), ["Once", "Deny", "Always for audience"])
                XCTAssertEqual(card.actions.map(\.kind), ["allow_once", "reject_once", "allow_always"])
                XCTAssertEqual(card.actions.map(\.decision), [.allow, .deny, .allow])
                XCTAssertTrue(card.detail.contains("report_v1.pdf"))
                try Data("changed".utf8).write(to: path)
                return selected
            })
            let requests = await server.requests
            XCTAssertEqual(requests.count, 2)
            for request in requests {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url, endpoint)
                XCTAssertEqual(request.timeoutInterval, 150)
                XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            }
            let bodies = try requests.map { try XCTUnwrap($0.httpBody) }
            // Inspect the wire bytes of the fixture's attachment array, including object field order.
            func toolBytes(_ data: Data) throws -> [Substring] {
                let wire = String(decoding: data, as: UTF8.self)
                let start = try XCTUnwrap(wire.range(of: #""arguments":{"#)).lowerBound
                let end = try XCTUnwrap(wire.range(of: "]}", range: start..<wire.endIndex)).upperBound
                let name = try XCTUnwrap(wire.range(of: #""name":"send_message""#))
                return [wire[start..<end], wire[name]]
            }
            XCTAssertEqual(try toolBytes(bodies[0]), try toolBytes(bodies[1]))
            let params = try JSONDecoder().decode(ToolJSON.self, from: bodies[1])["params"]
            XCTAssertNil(params?["arguments"]?["account"])
            XCTAssertEqual(params?["arguments"]?["attachments"]?.arrayValue?.first?["content"],
                           .string(Data("original".utf8).base64EncodedString()))
            XCTAssertEqual(params?["requestState"], .string("opaque"))
            XCTAssertEqual(params?["inputResponses"]?["request"], .object([
                "action": .string("accept"), "content": .object(["choice": .string(selected)])]))
        }
    }

    func testStatelessListProbeWithMetadataAndSSE() async throws {
        let server = GoogleScriptedServer([.init(body: #"data: {"id":1,"result":{"tools":[]}}"# + "\n\n",
                                                   headers: ["Content-Type": "text/event-stream"])])
        let client = GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server, clientVersion: "8.7.6", language: "ko-KR")
        let tools = try await client.listTools()
        XCTAssertEqual(tools, [])
        let requests = await server.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2026-07-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "ko-KR")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        let envelope = try JSONDecoder().decode(ToolJSON.self, from: XCTUnwrap(request.httpBody))
        let meta = envelope["params"]?["_meta"]
        XCTAssertEqual(meta?["io.modelcontextprotocol/protocolVersion"], .string("2026-07-28"))
        XCTAssertEqual(meta?["io.modelcontextprotocol/clientInfo"], .object(["name": .string("Yardlet"), "version": .string("8.7.6")]))
        XCTAssertEqual(meta?["io.modelcontextprotocol/clientCapabilities"], .object(["elicitation": .object(["form": .object([:])])]))
    }

    func testDismissHeadlessAndUnsupportedSchemaCancelOnTheServer() async throws {
        for mode in ["dismiss", "headless", "unsupported"] {
            let server = GoogleScriptedServer([.form(extraField: mode == "unsupported"), .denied])
            let client = GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server)
            let responder: GoogleWorkspaceMCPClient.Responder? = mode == "headless" ? nil : { @Sendable _ in
                XCTAssertEqual(mode, "dismiss")
                return nil
            }
            do {
                _ = try await client.callTool(name: "send_message", arguments: .object([:]), accountAddress: address,
                                              token: token, responder: responder)
                XCTFail("Expected cancellation")
            } catch {
                switch mode {
                case "headless": XCTAssertEqual(error as? GoogleWorkspaceMCPError, .unattended)
                case "unsupported": XCTAssertEqual(error as? GoogleWorkspaceMCPError, .unsupported)
                default: XCTAssertEqual(error.localizedDescription, "UserDeniedAction")
                }
            }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 2)
            let envelope = try JSONDecoder().decode(ToolJSON.self, from: XCTUnwrap(requests.last?.httpBody))
            XCTAssertEqual(envelope["params"]?["inputResponses"]?["request"], .object(["action": .string("cancel")]))
        }
    }

    func testStopAndExpiredStateDoNotRetry() async throws {
        for stop in [true, false] {
            let server = GoogleScriptedServer([.form(), .init(body: #"{"id":1,"error":{"code":-32602,"message":"invalid requestState"}}"#)])
            do {
                _ = try await GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server)
                    .callTool(name: "send_message", arguments: .object([:]), accountAddress: address, token: token, responder: { _ in
                        if stop { throw CancellationError() }
                        return "ALLOW_ONCE"
                    })
                XCTFail("Expected failure")
            } catch {
                if stop { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? GoogleWorkspaceMCPError, .expired) }
            }
            let requests = await server.requests
            XCTAssertEqual(requests.count, stop ? 1 : 2)
        }
    }

    func testTooManyFormsCancelWithoutAnotherCard() async throws {
        let server = GoogleScriptedServer(Array(repeating: .form(), count: 4) + [.denied])
        do {
            _ = try await GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server)
                .callTool(name: "send_message", arguments: .object([:]), accountAddress: address, token: token, responder: { _ in "ALLOW_ONCE" })
            XCTFail("Expected round limit")
        } catch { XCTAssertEqual(error as? GoogleWorkspaceMCPError, .roundLimit) }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 5)
        let last = try JSONDecoder().decode(ToolJSON.self, from: XCTUnwrap(requests.last?.httpBody))
        XCTAssertEqual(last["params"]?["inputResponses"]?["request"]?["action"], .string("cancel"))
    }

    func testDiagnosticsAndSingleTokenRefresh() async throws {
        let unauthorized = GoogleScriptedServer.Frame(body: "", status: 401)
        let cases: [([GoogleScriptedServer.Frame], GoogleWorkspaceMCPError)] = [
            ([unauthorized, unauthorized], .agentClient),
            ([.init(body: #"{"id":1,"error":{"code":-32021,"message":"MissingRequiredClientCapability"}}"#)], .capability),
            ([.init(body: #"{"error":{"message":"Request had insufficient authentication scopes"}}"#, status: 403)], .scope),
            ([.init(body: #"{"error":{"details":[{"reason":"SERVICE_DISABLED","metadata":{"consumer":"projects/12345"}}]}}"#, status: 403)],
             .serviceDisabled(project: "12345")),
            ([.init(body: #"{"result":{"tools":[{"description":""# + String(repeating: "a", count: 51_200) + #""}]}}"#, status: 403)],
             .serviceDisabled(project: nil)),
            ([.init(body: "RESOURCE_EXHAUSTED", status: 429, headers: ["Retry-After": "42"])],
             .quota(retryAfter: L10n.format("%ld seconds", 42)))
        ]
        for (frames, expected) in cases {
            let server = GoogleScriptedServer(frames)
            let client = GoogleWorkspaceMCPClient(endpoint: endpoint, transport: server)
            do {
                _ = try await client.listTools(token: token, refreshToken: { _ in UUID().uuidString })
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? GoogleWorkspaceMCPError, expected)
                XCTAssertLessThan(error.localizedDescription.count, 500)
            }
            let requests = await server.requests
            XCTAssertEqual(requests.count, frames.count)
            if frames.count == 2 {
                XCTAssertFalse(requests.first?.value(forHTTPHeaderField: "Authorization") == requests.last?.value(forHTTPHeaderField: "Authorization"))
            }
        }
    }
}

actor GoogleScriptedServer: ConnectorHTTPTransport {
    struct Frame {
        var body: String
        var status = 200
        var headers = ["Content-Type": "application/json"]
        static let done = Self(body: #"{"id":1,"result":{"content":[]}}"#)
        static let denied = Self(body: #"{"id":1,"error":{"code":-1,"message":"UserDeniedAction"}}"#)
        static func form(extraField: Bool = false) -> Self {
            let extra = extraField ? #","unexpected":{"type":"string"}"# : ""
            return Self(body: """
            {"id":1,"result":{"resultType":"input_required","requestState":"opaque","inputRequests":{"request":{
              "method":"elicitation/create","params":{"mode":"form","message":"**Attachment:** \u{60}report_v1.pdf\u{60}",
              "requestedSchema":{"type":"object","properties":{"choice":{"title":"Send","oneOf":[
              {"const":"ALLOW_ONCE","title":"Once"},{"const":"DENY_ONCE","title":"Deny"},
              {"const":"ALLOW_AUDIENCE_ALWAYS","title":"Always for audience"}]}\(extra)}}}}}}}
            """)
        }
    }
    private var frames: [Frame]
    private(set) var requests: [URLRequest] = []
    init(_ frames: [Frame]) { self.frames = frames }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !frames.isEmpty else { throw URLError(.badServerResponse) }
        let frame = frames.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: frame.status,
                                                     httpVersion: nil, headerFields: frame.headers))
        return (Data(frame.body.utf8), response)
    }
}
