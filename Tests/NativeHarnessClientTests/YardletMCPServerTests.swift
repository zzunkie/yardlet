import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The Yardlet MCP server speaks just enough MCP for a harness to list and call its tools. These
/// pin the JSON-RPC a harness sees, and the local connection that carries each call to the app.
final class YardletMCPServerTests: XCTestCase {
    private actor RecordingInvoker: AgentToolInvoking {
        private(set) var calls: [(tool: String, arguments: ToolJSON)] = []
        let result: AgentToolResult

        init(result: AgentToolResult) { self.result = result }

        nonisolated func call(tool: String, arguments: ToolJSON) async -> AgentToolResult {
            await record(tool, arguments)
            return result
        }

        private func record(_ tool: String, _ arguments: ToolJSON) { calls.append((tool, arguments)) }
    }

    private func reply(_ server: MCPServer, _ request: String) async throws -> ToolJSON? {
        guard let data = await server.handle(Data(request.utf8)) else { return nil }
        XCTAssertFalse(data.contains(0x0A), "A reply must fit on one line of the stdio transport")
        return try JSONDecoder().decode(ToolJSON.self, from: data)
    }

    func testInitializeAnswersTheClientsVersionWhenSupportedAndTheNewestOtherwise() async throws {
        let server = MCPServer(version: "1.2.3", invoker: RecordingInvoker(result: .text("")))
        let known = try await reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"codex","version":"1"}}}"#)
        XCTAssertEqual(known?["id"], .integer(1))
        XCTAssertEqual(known?["result"]?["protocolVersion"], .string("2025-03-26"))
        XCTAssertEqual(known?["result"]?["capabilities"]?["tools"]?["listChanged"], .bool(true),
                       "The server tells its client when the task's tools change")
        XCTAssertEqual(known?["result"]?["serverInfo"]?["name"], .string("yardlet"))
        XCTAssertEqual(known?["result"]?["serverInfo"]?["version"], .string("1.2.3"))
        XCTAssertNotNil(known?["result"]?["instructions"]?.stringValue)

        let unknown = try await reply(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknown?["id"], .string("a"), "String request ids come back as they were sent")
        XCTAssertEqual(unknown?["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))
    }

    func testNotificationsAndClientResponsesGetNoReplyAndPingGetsAnEmptyResult() async throws {
        let server = MCPServer(version: "1", invoker: RecordingInvoker(result: .text("")))
        let initialized = try await reply(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized)
        let cancelled = try await reply(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)
        XCTAssertNil(cancelled)
        let response = try await reply(server, #"{"jsonrpc":"2.0","id":9,"result":{}}"#)
        XCTAssertNil(response)
        let ping = try await reply(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(ping?["result"], .object([:]))
    }

    func testToolsListCarriesEveryBrowserToolWithAnObjectSchema() async throws {
        let server = MCPServer(version: "1", invoker: RecordingInvoker(result: .text("")))
        let listed = try await reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(listed?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, [
            "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_press_key",
            "browser_scroll", "browser_select_option", "browser_wait_for", "browser_screenshot",
            "browser_console_messages", "browser_evaluate", "browser_handle_dialog", "browser_file_upload", "browser_resize",
            "browser_handoff",
            "browser_batch", "browser_tab_list", "browser_tab_new", "browser_tab_select", "browser_tab_close",
            "spawn_task", "dismiss_task",
            "list_tasks", "read_task", "send_message_to_task", "wait_tasks", "create_task", "run_agent", "archive_task",
            "list_projects", "hide_project", "show_project", "list_accounts",
            "create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task",
            "run_scheduled_task", "list_task_runs"
        ], "Without the app the list is Yardlet's own tools: the browser, task suggestion, session and scheduled-task tools")
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"), "\(tool["name"] ?? .null)")
            XCTAssertNotNil(tool["description"]?.stringValue)
        }
        let batch = try XCTUnwrap(tools.first { $0["name"] == .string("browser_batch") })
        let names = batch["inputSchema"]?["properties"]?["actions"]?["items"]?["properties"]?["name"]?["enum"]?.arrayValue
        XCTAssertEqual(names?.compactMap(\.stringValue), AgentToolCatalog.batchableNames,
                       "A batch lists every other tool and not itself")
        XCTAssertEqual(tools.first { $0["name"] == .string("browser_snapshot") }?["annotations"]?["readOnlyHint"], .bool(true))
    }

    func testToolsCallForwardsTheArgumentsAndReturnsTextAndImageContent() async throws {
        let invoker = RecordingInvoker(result: AgentToolResult(content: [
            .image(data: "iVBORw0KGgo=", mimeType: "image/png"), .text("Screenshot of https://example.com/")
        ]))
        let server = MCPServer(version: "1", invoker: invoker)
        let called = try await reply(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"browser_screenshot","arguments":{"fullPage":true}}}"#)
        XCTAssertEqual(called?["result"]?["isError"], .bool(false))
        XCTAssertEqual(called?["result"]?["content"], .array([
            .object(["type": .string("image"), "data": .string("iVBORw0KGgo="), "mimeType": .string("image/png")]),
            .object(["type": .string("text"), "text": .string("Screenshot of https://example.com/")])
        ]))
        let calls = await invoker.calls
        XCTAssertEqual(calls.first?.tool, "browser_screenshot")
        XCTAssertEqual(calls.first?.arguments, .object(["fullPage": .bool(true)]))

        let noArguments = try await reply(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"browser_snapshot"}}"#)
        XCTAssertNotNil(noArguments?["result"])
        let recorded = await invoker.calls
        XCTAssertEqual(recorded.last?.arguments, .object([:]), "Missing arguments are an empty object")

        // The app lists the password manager's fill tool only while it is on, so the server forwards it
        // rather than refusing a browser tool it does not list itself.
        let fill = try await reply(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"browser_fill_credential","arguments":{"ref":"@e7"}}}"#)
        XCTAssertNil(fill?["error"])
        let forwarded = await invoker.calls
        XCTAssertEqual(forwarded.last?.tool, "browser_fill_credential")
    }

    func testAFailingToolIsAResultWithIsErrorNotAProtocolError() async throws {
        let server = MCPServer(version: "1", invoker: RecordingInvoker(result: .error("@e4 is stale")))
        let called = try await reply(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"browser_click","arguments":{"ref":"@e4"}}}"#)
        XCTAssertNil(called?["error"])
        XCTAssertEqual(called?["result"]?["isError"], .bool(true))
        XCTAssertEqual(called?["result"]?["content"]?.arrayValue?.first?["text"], .string("@e4 is stale"))
    }

    func testProtocolErrorsUseTheJSONRPCCodes() async throws {
        let invoker = RecordingInvoker(result: .text(""))
        let server = MCPServer(version: "1", invoker: invoker)
        let parse = try await reply(server, "{not json")
        XCTAssertEqual(parse?["id"], .null)
        XCTAssertEqual(parse?["error"]?["code"], .integer(-32700))
        let unknownMethod = try await reply(server, #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        XCTAssertEqual(unknownMethod?["error"]?["code"], .integer(-32601))
        let unknownTool = try await reply(server, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"browser_fly"}}"#)
        XCTAssertEqual(unknownTool?["error"]?["code"], .integer(-32602))
        XCTAssertEqual(unknownTool?["error"]?["message"]?.stringValue?.contains("Yardlet's browser tools are browser_navigate, "),
                       true, "It names the tools there are")
        let noName = try await reply(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(noName?["error"]?["code"], .integer(-32602))
        let badArguments = try await reply(server, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"browser_snapshot","arguments":[1]}}"#)
        XCTAssertEqual(badArguments?["error"]?["code"], .integer(-32602))
        let notARequest = try await reply(server, "42")
        XCTAssertEqual(notARequest?["error"]?["code"], .integer(-32600))
        let calls = await invoker.calls
        XCTAssertTrue(calls.isEmpty, "No malformed call reaches the app")
    }

    // MARK: - Local connection

    private func privateDirectory() -> URL {
        // Unix socket paths are short; the per-user temporary folder leaves room.
        FileManager.default.temporaryDirectory.appending(path: "ytl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    func testACallCrossesTheSocketAndItsResultComesBack() async throws {
        let directory = privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        let listener = try UnixSocketListener(path: path) { body, peer in
            let call = try? JSONDecoder().decode(AgentToolCall.self, from: body)
            let result = AgentToolResult(content: [
                .text("\(call?.tool ?? "?") for \(call?.session ?? "?") with \(call?.token ?? "?") from \(peer ?? 0)"),
                .image(data: String(repeating: "A", count: 300_000), mimeType: "image/png")
            ])
            return (try? JSONEncoder().encode(result)) ?? Data()
        }
        defer { listener.stop() }

        var status = stat()
        XCTAssertEqual(lstat(directory.path(percentEncoded: false), &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700, "Only the user can open the socket's directory")
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)

        let invoker = UnixSocketToolInvoker(environment: [
            AgentToolEnvironment.endpoint: path,
            AgentToolEnvironment.token: "token-1",
            AgentToolEnvironment.session: "session-1"
        ])
        let result = await invoker.call(tool: "browser_navigate", arguments: .object(["url": .string("https://example.com")]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "browser_navigate for session-1 with token-1 from \(ProcessInfo.processInfo.processIdentifier)",
                       "The app learns which process called")
        if case .image(let data, _) = result.content.last {
            XCTAssertEqual(data.count, 300_000, "A large result arrives whole")
        } else {
            XCTFail("The image did not arrive")
        }
    }

    /// An endpoint that does not answer says whether the Yardlet that started the server has quit or still runs
    /// with the connection gone; a server from an earlier build, which does not know, says either.
    func testTheServerSaysSoWhenYardletIsNotRunningOrDidNotStartIt() async throws {
        let missing = privateDirectory().appending(path: "tools.sock").path(percentEncoded: false)
        func call(appProcess: Int32?) async -> AgentToolResult {
            var environment = [
                AgentToolEnvironment.endpoint: missing,
                AgentToolEnvironment.token: "t",
                AgentToolEnvironment.session: "s"
            ]
            environment[AgentToolEnvironment.appProcess] = appProcess.map(String.init)
            return await UnixSocketToolInvoker(environment: environment).call(tool: "browser_snapshot", arguments: .object([:]))
        }
        let notRunning = await call(appProcess: nil)
        XCTAssertTrue(notRunning.isError)
        XCTAssertTrue(notRunning.text.contains("Yardlet is not running"), notRunning.text)
        XCTAssertEqual(notRunning.failure?.kind, .unreachable)

        let ended = Process()
        ended.executableURL = URL(filePath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let quit = await call(appProcess: ended.processIdentifier)
        XCTAssertTrue(quit.text.contains("has quit"), quit.text)
        let running = await call(appProcess: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(running.text.contains("Yardlet is running, but this task's connection to it is gone"), running.text)
        XCTAssertEqual(running.failure?.retry, .no)

        let unmanaged = await UnixSocketToolInvoker(environment: [:])
            .call(tool: "browser_snapshot", arguments: .object([:]))
        XCTAssertTrue(unmanaged.isError)
        XCTAssertTrue(unmanaged.text.contains("did not start this MCP server"), unmanaged.text)
        XCTAssertEqual(unmanaged.failure?.kind, .refused)
    }

    /// A call that went out and got no answer may have run: it says so, rather than that Yardlet could not be
    /// reached. The server waits longer than the app runs a connector call, so the app's own answer comes first.
    func testACallYardletDoesNotAnswerHasAnUnknownOutcome() async throws {
        let directory = privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        let listener = try UnixSocketListener(path: path) { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return Data()
        }
        defer { listener.stop() }
        var invoker = UnixSocketToolInvoker(environment: [
            AgentToolEnvironment.endpoint: path, AgentToolEnvironment.token: "t", AgentToolEnvironment.session: "s"
        ])
        invoker.timeout = 1
        let result = await invoker.call(tool: "slack_send_message", arguments: .object([:]))
        XCTAssertEqual(result.failure?.kind, .outcomeUnknown, result.text)
        XCTAssertEqual(result.failure?.retry, .afterChecking)
        XCTAssertTrue(result.text.hasPrefix("Yardlet did not answer within 1 seconds."), result.text)

        XCTAssertGreaterThan(UnixSocketToolInvoker(environment: [:]).timeout,
                             TimeInterval(AgentToolTimeLimits.connectorCall.components.seconds) + 15)
    }

    func testTheListenerRefusesADirectoryThatIsNotADirectory() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ytl-file-\(UUID().uuidString.prefix(8))")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data()))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try UnixSocketListener(path: file.appending(path: "tools.sock").path(percentEncoded: false)) { _, _ in Data() })
    }

    /// The executable a harness starts, spoken to exactly as a harness would: JSON-RPC lines on
    /// standard input, replies on standard output.
    func testTheBuiltServerAnswersOverStandardInputAndOutput() throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appending(path: AgentToolEnvironment.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw XCTSkip("yardlet-mcp is not built next to the tests")
        }
        let process = Process()
        process.executableURL = executable
        process.environment = [
            AgentToolEnvironment.endpoint: privateDirectory().appending(path: "tools.sock").path(percentEncoded: false),
            AgentToolEnvironment.token: "t",
            AgentToolEnvironment.session: "s"
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}"#
        ]
        try input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The server ends when its input closes")
        let replies = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(ToolJSON.self, from: Data($0.utf8))
        }
        let ids: [Int64] = replies.compactMap { reply in
            if case .integer(let id) = reply["id"] { return id }
            return nil
        }
        XCTAssertEqual(ids.sorted(), [1, 2, 3])
        let list = replies.first { $0["id"] == .integer(2) }
        XCTAssertEqual(list?["result"]?["tools"]?.arrayValue?.count, 39,
                       "20 browser tools, the 2 task suggestion tools, the 11 session tools and the 6 scheduled-task tools")
        let call = replies.first { $0["id"] == .integer(3) }
        XCTAssertEqual(call?["result"]?["isError"], .bool(true))
        XCTAssertTrue(call?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("Yardlet is not running") == true)
    }
}
