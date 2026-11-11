import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

/// MCP Apps for Yardlet's connectors (docs/CONNECTORS.md, "MCP Apps"), against a local fake server that lists a tool
/// with a view, a tool only views may call and a tool that changes something, and serves the view.
@MainActor
final class MCPAppConnectorTests: XCTestCase {
    private func connectedCenter(_ server: FakeAppServer) async throws -> (ConnectorCenter, ConnectorRecord) {
        let environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(), http: server,
            userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: { Date() },
            refreshRetrySleep: { _ in })
        let center = ConnectorCenter(environment: environment)
        let record = try await center.add(name: "Viewer", serverURL: FakeAppServer.url)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        return (center, try XCTUnwrap(center.record(record.id)))
    }

    func testAToolOnlyViewsMayCallStaysOutOfTheModelsListAndCalls() async throws {
        let server = FakeAppServer()
        let (center, _) = try await connectedCenter(server)
        let task = ConnectorToolContext(taskID: UUID())

        let tools = await center.connectorTools(for: task)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue },
                       ["viewer_get_profile", "viewer_send_note", "viewer_model_only"])
        let profile = try XCTUnwrap(tools.first)
        XCTAssertNil(profile["_meta"]?["ui"], "The view is the app's to draw; a harness gets no view to read")
        XCTAssertEqual(profile["_meta"]?["other/flag"], .bool(true), "The rest of the server's _meta goes as it was")

        let hidden = await center.callConnectorTool(named: "viewer_ui_lookup", arguments: .object([:]), for: task)
        XCTAssertNil(hidden, "A model's call to a view-only tool answers as no tool's")
        XCTAssertFalse(server.calls.contains("ui_lookup"))

        // A view may call it, and may not call a tool the server keeps for the model.
        let looked = try await center.callFromView(viewTool: "viewer_get_profile", tool: "ui_lookup",
                                                   arguments: .object([:]), context: task) { _, _, _ in false }
        XCTAssertEqual(looked["content"]?.arrayValue?.first?["text"], .string("labels"))
        do {
            _ = try await center.callFromView(viewTool: "viewer_get_profile", tool: "model_only",
                                              arguments: .object([:]), context: task) { _, _, _ in true }
            XCTFail("A model-only tool is not a view's to call")
        } catch MCPAppViewFailure.refused {}
        XCTAssertEqual(server.calls, ["ui_lookup"])
    }

    func testAViewsCallThatMayChangeSomethingAsksThePersonFirst() async throws {
        let server = FakeAppServer()
        let (center, _) = try await connectedCenter(server)
        let task = ConnectorToolContext(taskID: UUID())
        var asked: [(String, String, ToolJSON)] = []
        do {
            _ = try await center.callFromView(viewTool: "viewer_get_profile", tool: "send_note",
                                              arguments: .object(["text": .string("hi")]), context: task) {
                asked.append(($0, $1, $2))
                return false
            }
            XCTFail("Declined")
        } catch MCPAppViewFailure.refused {}
        XCTAssertEqual(asked.map(\.0), ["Viewer"])
        XCTAssertEqual(asked.map(\.1), ["send_note"])
        XCTAssertTrue(server.calls.isEmpty, "Nothing went to the server before the person allowed it")

        let sent = try await center.callFromView(viewTool: "viewer_get_profile", tool: "send_note",
                                                 arguments: .object(["text": .string("hi")]), context: task) { _, _, _ in true }
        XCTAssertEqual(sent["content"]?.arrayValue?.first?["text"], .string("sent hi"))
        XCTAssertEqual(server.calls, ["send_note"])

        // A call the person allowed still meets the task's switch, as a model's call does.
        center.setConnector(try XCTUnwrap(center.connectors.first).id, on: false, inTask: try XCTUnwrap(task.taskID))
        let off = try await center.callFromView(viewTool: "viewer_get_profile", tool: "send_note",
                                                arguments: .object(["text": .string("again")]), context: task) { _, _, _ in true }
        XCTAssertEqual(off["isError"], .bool(true))
        XCTAssertEqual(server.calls, ["send_note"])
    }

    func testAViewIsReadOnceFromItsConnectorAndChecked() async throws {
        let server = FakeAppServer()
        let (center, _) = try await connectedCenter(server)

        let (view, tool) = try await center.appView(forTool: "viewer_get_profile")
        XCTAssertEqual(view.uri, "ui://viewer/profile")
        XCTAssertTrue(view.html.contains("profile-view"))
        XCTAssertEqual(view.prefersBorder, false)
        XCTAssertEqual(view.csp.resourceDomains, ["https://avatars.example.test"],
                       "Only plain https or wss origins are taken from the server")
        XCTAssertEqual(tool["name"], .string("get_profile"), "The tool as its server listed it")
        _ = try await center.appView(forTool: "viewer_get_profile")
        XCTAssertEqual(server.reads, ["ui://viewer/profile"], "Read once for the app's run")

        server.serveText = true
        do {
            _ = try await center.appView(forTool: "viewer_send_note")
            XCTFail("Not HTML")
        } catch MCPAppView.Problem.notHTML {}
        do {
            _ = try await center.appView(forTool: "viewer_ui_lookup")
            XCTFail("Names no view")
        } catch MCPAppViewFailure.noView {}

        // A view reads only views of its own connector.
        do {
            _ = try await center.readFromView(viewTool: "viewer_get_profile", uri: "file:///etc/hosts")
            XCTFail("Not a view")
        } catch MCPAppViewFailure.refused {}
    }

    func testARowShowsTheWholeResultItsCallReturnedOrWhatItsHarnessKeptForAReadOnly() async throws {
        let server = FakeAppServer()
        let (center, record) = try await connectedCenter(server)
        let taskID = UUID()
        let task = ConnectorToolContext(taskID: taskID)
        let arguments: ToolJSON = .object(["login": .string("octo"), "full": .bool(true)])
        _ = await center.callConnectorTool(named: "viewer_get_profile", arguments: arguments, for: task)
        _ = await center.callConnectorTool(named: "viewer_send_note", arguments: .object(["text": .string("x")]), for: task)

        let host = ConnectorViewHost(taskID: taskID, center: center, context: { task }, ask: { _, _, _ in false })
        ConnectorToolLabels.shared.update([record])
        defer { ConnectorToolLabels.shared.update([]) }
        let label = try XCTUnwrap(ConnectorToolLabels.shared.label(forTool: "viewer_get_profile"))
        // The row's arguments as Claude Code and Codex show them: pretty, sorted JSON.
        let shown = MCPAppArguments.parse("{\n  \"full\" : true,\n  \"login\" : \"octo\"\n}")
        let row = try XCTUnwrap(ConversationConnectorView.of(tool: "viewer_get_profile", label: label, arguments: shown,
                                                             harnessResult: ConversationConnectorView.textResult("kept text")))
        XCTAssertEqual(host.result(for: row)?["structuredContent"], .object(["login": .string("octo")]),
                       "The whole result, which the harness did not keep")

        let other = ConnectorViewHost(taskID: UUID(), center: center, context: { task }, ask: { _, _, _ in false })
        XCTAssertEqual(other.result(for: row), ConversationConnectorView.textResult("kept text"),
                       "Another task's row (or one from before the app started) shows what its harness kept")

        let noteLabel = try XCTUnwrap(ConnectorToolLabels.shared.label(forTool: "viewer_send_note"))
        let note = try XCTUnwrap(ConversationConnectorView.of(tool: "viewer_send_note", label: noteLabel,
                                                              arguments: .object(["text": .string("x")]),
                                                              harnessResult: ConversationConnectorView.textResult("sent x")))
        XCTAssertNotNil(host.result(for: note), "This run's call of a tool that changes something")
        XCTAssertNil(other.result(for: note), "Without its whole result, a tool that changes something stays text")
    }

    func testEveryHarnessesConnectorRowCarriesItsViewOnceTheCallCompleted() async throws {
        let server = FakeAppServer()
        let (_, record) = try await connectedCenter(server)
        // A conversation drawn before the connectors were read (at launch) gets its views once they are.
        ConnectorToolLabels.shared.update([])
        let cache = ConversationProjectionCache()
        let entries = [TranscriptEntry(content: .user(text: "Who am I?")), TranscriptEntry(content: .activity(
            HarnessActivity(id: "early", kind: "mcp__yardlet__viewer_get_profile", title: "x", input: nil, output: "o"),
            state: .completed))]
        func drawnView() -> ConversationConnectorView? {
            let items = cache.transcript(TranscriptTurns(entries), harness: .claudeCode, status: .ready,
                                         latestTurnIsComplete: true).turns.flatMap { $0.work + $0.answers }
            return items.compactMap { item -> ConversationConnectorView? in
                if case let .tool(tool) = item.kind { return tool.view }
                return nil
            }.first
        }
        XCTAssertNil(drawnView())
        ConnectorToolLabels.shared.update([record])
        defer { ConnectorToolLabels.shared.update([]) }
        XCTAssertEqual(drawnView()?.tool, "viewer_get_profile")

        func view(_ kind: ConversationItemKind) -> ConversationConnectorView? {
            if case let .tool(tool) = kind { return tool.view }
            return nil
        }
        for (name, harness) in [("mcp__yardlet__viewer_get_profile", HarnessKind.claudeCode),
                                ("mcp_yardlet_viewer_get_profile", .antigravityCLI),
                                ("mcp_yardlet_1a2b3c4d_viewer_get_profile", .antigravityCLI)] {
            let activity = HarnessActivity(id: "a", kind: harness == .claudeCode ? name : "other", title: name,
                                           input: #"{"login":"octo"}"#, output: "octo")
            let done = view(ConversationActivityProjection.kind(activity, harness: harness, phase: .completed, isApproved: false))
            XCTAssertEqual(done?.tool, "viewer_get_profile", name)
            XCTAssertEqual(done?.uri, "ui://viewer/profile")
            XCTAssertEqual(done?.arguments, .object(["login": .string("octo")]))
            XCTAssertNil(view(ConversationActivityProjection.kind(activity, harness: harness, phase: .running, isApproved: false)),
                         "A running call is a tool row until it completes")
            XCTAssertNil(view(ConversationActivityProjection.kind(activity, harness: harness, phase: .failed, isApproved: false)))
        }
        let plain = HarnessActivity(id: "b", kind: "mcp__yardlet__viewer_send_note", title: "send", input: nil, output: "ok")
        XCTAssertNotNil(view(ConversationActivityProjection.kind(plain, harness: .claudeCode, phase: .completed, isApproved: false)))

        // A view's row stands alone and stays when its turn's work folds.
        let item = ConversationItem(id: "v", kind: ConversationActivityProjection.kind(
            HarnessActivity(id: "v", kind: "mcp__yardlet__viewer_get_profile", title: "x", input: nil, output: "o"),
            harness: .claudeCode, phase: .completed, isApproved: false), phase: .completed,
            source: .transcript(TranscriptEntry(content: .plan(""))))
        XCTAssertFalse(ConversationWorkGrouping.joinsRun(item))
        XCTAssertTrue(ConversationWorkDisclosure.lineStartsOpen(item))
        XCTAssertFalse(ConversationWorkDisclosure.lineStartsOpen(item, choice: false), "The person folded it")
    }

    func testOnlyPlainOriginsWidenAViewsPolicy() {
        XCTAssertEqual(MCPAppCSP.source("https://cdn.example.test/"), "https://cdn.example.test")
        XCTAssertEqual(MCPAppCSP.source("https://*.Example.test"), "https://*.example.test")
        XCTAssertEqual(MCPAppCSP.source("wss://live.example.test:8443"), "wss://live.example.test:8443")
        for refused in ["*", "https:", "http://example.test", "'unsafe-eval'", "https://a.test; script-src *",
                        "https://a.test/path", "data:", "https://a.test 'unsafe-eval'", "javascript:alert(1)"] {
            XCTAssertNil(MCPAppCSP.source(refused), refused)
        }
        let none = MCPAppCSP(nil).header
        XCTAssertTrue(none.contains("default-src 'none'"))
        XCTAssertTrue(none.contains("connect-src 'none'"), "No connections unless declared")
        XCTAssertTrue(none.contains("frame-src 'none'"))
        XCTAssertTrue(none.contains("object-src 'none'"))
        let declared = MCPAppCSP(.object(["connectDomains": .array([.string("https://api.example.test")])])).header
        XCTAssertTrue(declared.contains("connect-src https://api.example.test;"))
    }

    func testTheBridgeAnswersInTheSpecsOrderAndRefusesWhatYardletDoesNotPassOn() async throws {
        var posted: [ToolJSON] = []
        var opened: [URL] = []
        var calls: [String] = []
        let host = MCPAppBridge.Host(
            tool: .object(["name": .string("get_profile")]), arguments: .object(["login": .string("octo")]),
            result: .object(["content": .array([])]), version: "9.9",
            callTool: { name, _ in calls.append(name); return .object(["content": .array([])]) },
            readResource: { _ in throw MCPAppViewFailure.refused("no") },
            openLink: { opened.append($0) })
        let bridge = MCPAppBridge(host: host, context: MCPAppHostContext(isDark: true)) { posted.append($0) }
        func send(_ id: Int64?, _ method: String, _ params: ToolJSON = .object([:])) {
            var message: [String: ToolJSON] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
            if let id { message["id"] = .integer(id) }
            bridge.receive(.object(message))
        }
        func reply(_ id: Int64) -> ToolJSON? { posted.last { $0["id"] == .integer(id) } }

        send(1, "tools/call", .object(["name": .string("ui_lookup")]))
        XCTAssertEqual(reply(1)?["error"]?["code"], .integer(-32002), "Nothing before ui/initialize")
        XCTAssertTrue(calls.isEmpty)

        send(2, "ui/initialize", .object(["appCapabilities": .object([:])]))
        let initialized = try XCTUnwrap(reply(2)?["result"])
        XCTAssertEqual(initialized["protocolVersion"], .string("2026-01-26"))
        XCTAssertEqual(initialized["hostContext"]?["theme"], .string("dark"))
        XCTAssertEqual(initialized["hostContext"]?["toolInfo"]?["tool"]?["name"], .string("get_profile"))
        XCTAssertEqual(initialized["hostContext"]?["displayMode"], .string("inline"))
        XCTAssertFalse(posted.contains { $0["method"]?.stringValue?.hasPrefix("ui/notifications/tool") == true },
                       "No input or result before the view says it is initialized")

        send(nil, "ui/notifications/initialized")
        XCTAssertEqual(posted.suffix(2).compactMap { $0["method"]?.stringValue },
                       ["ui/notifications/tool-input", "ui/notifications/tool-result"])
        XCTAssertEqual(posted.suffix(2).first?["params"]?["arguments"], .object(["login": .string("octo")]))

        send(3, "ui/message", .object(["role": .string("user")]))
        XCTAssertEqual(reply(3)?["error"]?["code"], .integer(-32000))
        send(4, "ui/update-model-context")
        XCTAssertEqual(reply(4)?["error"]?["code"], .integer(-32000))
        send(5, "ui/open-link", .object(["url": .string("file:///etc/passwd")]))
        XCTAssertNotNil(reply(5)?["error"])
        send(6, "ui/open-link", .object(["url": .string("https://example.test/a")]))
        send(7, "ui/open-link", .object(["url": .string("https://example.test/b")]))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.test/a"], "One link a second at most")
        XCTAssertNotNil(reply(7)?["error"])
        send(8, "sampling/createMessage")
        XCTAssertEqual(reply(8)?["error"]?["code"], .integer(-32601))

        var heights: [Double] = []
        bridge.onHeight = { heights.append($0) }
        send(nil, "ui/notifications/size-changed", .object(["width": .integer(500), "height": .integer(240)]))
        XCTAssertEqual(heights, [240])

        send(9, "tools/call", .object(["name": .string("ui_lookup"), "arguments": .object([:])]))
        try await waitUntil { reply(9)?["result"] != nil }
        XCTAssertEqual(calls, ["ui_lookup"])

        bridge.receive("{not json")
        bridge.receive(String(repeating: " ", count: MCPAppBridge.maximumMessageLength + 1))
        await bridge.tearDown()
        XCTAssertEqual(posted.last?["method"], .string("ui/resource-teardown"))
        send(10, "ping")
        XCTAssertNil(reply(10), "Nothing after teardown")
    }
}

/// An MCP server without sign-in that lists a tool with a view (`get_profile`, read-only), a tool that changes
/// something (`send_note`, its view the same), a tool only views may call (`ui_lookup`) and one only the model may
/// (`model_only`), and serves the view with `resources/read`.
final class FakeAppServer: ConnectorHTTPTransport, @unchecked Sendable {
    static let url = URL(string: "https://apps.example.test/mcp")!
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedReads: [String] = []
    private var text = false
    private var html = FakeAppServer.profileHTML
    private var callArguments: [ToolJSON] = []
    private var answers: [String: ToolJSON] = [:]
    private var ui: ToolJSON = .object([
        "prefersBorder": .bool(false),
        "csp": .object(["resourceDomains": .array([
            .string("https://avatars.example.test"), .string("'unsafe-eval'"), .string("http://plain.example.test")
        ])])
    ])

    var calls: [String] { lock.withLock { recordedCalls } }
    var reads: [String] { lock.withLock { recordedReads } }
    /// The arguments of each call, in order.
    var arguments: [ToolJSON] { lock.withLock { callArguments } }
    /// What `get_profile` answers, in place of its default.
    var result: ToolJSON? {
        get { lock.withLock { answers["get_profile"] } }
        set { lock.withLock { answers["get_profile"] = newValue } }
    }

    /// The HTML every view is served with.
    var viewHTML: String {
        get { lock.withLock { html } }
        set { lock.withLock { html = newValue } }
    }
    /// Serves the next views as plain text.
    var serveText: Bool {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
    }

    static let profileHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>profile-view</title></head><body>profile-view</body></html>
    """

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        guard url.path() == "/mcp", request.httpMethod == "POST" else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let message = (try? JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data())) ?? .null
        let id = message["id"] ?? .null
        let params = message["params"] ?? .object([:])
        let result: ToolJSON
        switch message["method"]?.stringValue {
        case "initialize":
            result = .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]),
                              "serverInfo": .object(["name": .string("viewer"), "version": .string("1")])])
        case "notifications/initialized":
            return (Data(), HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        case "tools/list":
            func tool(_ name: String, readOnly: Bool, ui: ToolJSON?, extra: [String: ToolJSON] = [:]) -> ToolJSON {
                var meta = extra
                if let ui { meta["ui"] = ui }
                var fields: [String: ToolJSON] = ["name": .string(name), "inputSchema": .object(["type": .string("object")]),
                                                  "annotations": .object(["readOnlyHint": .bool(readOnly)])]
                if !meta.isEmpty { fields["_meta"] = .object(meta) }
                return .object(fields)
            }
            result = .object(["tools": .array([
                tool("get_profile", readOnly: true, ui: .object(["resourceUri": .string("ui://viewer/profile")]),
                     extra: ["other/flag": .bool(true)]),
                tool("send_note", readOnly: false, ui: .object(["resourceUri": .string("ui://viewer/note"),
                                                                "visibility": .array([.string("model"), .string("app")])])),
                tool("ui_lookup", readOnly: true, ui: .object(["visibility": .array([.string("app")])])),
                tool("model_only", readOnly: true, ui: .object(["visibility": .array([.string("model")])]))
            ])])
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            lock.withLock {
                recordedCalls.append(name)
                callArguments.append(params["arguments"] ?? .null)
            }
            switch name {
            case "get_profile":
                result = self.result ?? .object(["content": .array([.object(["type": .string("text"), "text": .string("octo")])]),
                                  "structuredContent": .object(["login": .string("octo")])])
            case "send_note":
                let text = params["arguments"]?["text"]?.stringValue ?? ""
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string("sent \(text)")])])])
            default:
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string("labels")])])])
            }
        case "resources/read":
            let uri = params["uri"]?.stringValue ?? ""
            lock.withLock { recordedReads.append(uri) }
            result = .object(["contents": .array([.object([
                "uri": .string(uri),
                "mimeType": .string(serveText ? "text/plain" : MCPAppView.mimeType),
                "text": .string(viewHTML),
                "_meta": .object(["ui": ui])
            ])])])
        default:
            result = .object([:])
        }
        let body = try JSONEncoder().encode(ToolJSON.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json"])!)
    }
}
