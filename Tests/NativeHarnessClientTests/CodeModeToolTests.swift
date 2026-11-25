import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

@MainActor
final class CodeModeToolTests: XCTestCase {
    private func makeBroker(
        codeMode: CodeModePreference.Mode,
        connectors: (any ConnectorToolProviding)? = nil,
        connectorScope: ConnectorTaskScope? = nil
    ) throws -> (AgentToolBroker, UUID, String, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "code-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let broker = AgentToolBroker(
            environment: .init(
                executableURL: URL(filePath: "/usr/bin/true"),
                endpoint: dir.appending(path: "sock").path,
                privateDirectory: dir,
                isEnabled: { false }
            ),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) })
        )
        broker.codeModeSetting = { codeMode }
        broker.connectors = connectors
        let sessionID = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(for: sessionID, workspaceRoots: [dir], connectorScope: connectorScope))
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
        return (broker, sessionID, token, dir)
    }

    func testModeDefaultsToAutoAndKeepsASwitchSavedBeforeIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("CodeModeMode")))
        let context = YardletSettingsContext(defaults: defaults)
        let setting = YardletSetting.agentCodeMode
        let shown = CodeModePreference.isSupported
        XCTAssertEqual(CodeModePreference.mode(in: defaults), .auto)
        XCTAssertEqual(setting.value(in: context), shown ? "auto" : nil)
        // The switch saved a value only once the person turned it, and Settings and the settings tools
        // read it right before it is converted.
        defaults.set(true, forKey: CodeModePreference.key)
        XCTAssertEqual(CodeModePreference.mode(in: defaults), .on)
        XCTAssertEqual(setting.value(in: context), shown ? "on" : nil)
        defaults.set(false, forKey: CodeModePreference.key)
        XCTAssertEqual(setting.value(in: context), shown ? "off" : nil)
        defaults.set(true, forKey: CodeModePreference.key)
        CodeModePreference.convertSavedSwitch(in: defaults)
        XCTAssertEqual(defaults.string(forKey: CodeModePreference.key), "on")
        defaults.set(false, forKey: CodeModePreference.key)
        XCTAssertEqual(CodeModePreference.mode(in: defaults), .off)
        CodeModePreference.convertSavedSwitch(in: defaults)
        XCTAssertEqual(defaults.string(forKey: CodeModePreference.key), "off")
        XCTAssertEqual(YardletSettingCatalog.setting("agent_code_mode")?.choices.map(\.value), ["auto", "on", "off"])
    }

    func testAutoDecidesByHarnessAndConnectorToolCount() async throws {
        func listsCodeMode(_ harness: HarnessKind, connectorTools: Int) async throws -> Bool {
            let stub = ExperimentConnectorProvider(toolCount: connectorTools)
            let (broker, sessionID, token, _) = try makeBroker(codeMode: .auto, connectors: stub,
                                                               connectorScope: ConnectorTaskScope(harness: harness))
            let listed = await broker.list(AgentToolCall(token: token, session: sessionID.uuidString, tool: "",
                                                         arguments: .object([:]), method: AgentToolCall.listMethod))
            return try XCTUnwrap(listed).tools.contains { $0["name"]?.stringValue == CodeModeToolCatalog.runScript }
        }
        let supported = CodeModePreference.isSupported
        let threshold = CodeModePreference.claudeCodeConnectorToolThreshold
        let codex = try await listsCodeMode(.codex, connectorTools: 40)
        XCTAssertFalse(codex)
        let claudeBelow = try await listsCodeMode(.claudeCode, connectorTools: threshold - 1)
        XCTAssertFalse(claudeBelow)
        XCTAssertFalse(CodeModePreference.isOn(.auto, harness: nil, connectorToolCount: 100))
        let claudeAt = try await listsCodeMode(.claudeCode, connectorTools: threshold)
        XCTAssertEqual(claudeAt, supported)
        let antigravityNone = try await listsCodeMode(.antigravityCLI, connectorTools: 0)
        XCTAssertFalse(antigravityNone)
        let antigravity = try await listsCodeMode(.antigravityCLI, connectorTools: 1)
        XCTAssertEqual(antigravity, supported)
        let openCode = try await listsCodeMode(.openCode, connectorTools: 1)
        XCTAssertEqual(openCode, supported)

        // Where Auto leaves it off, its tools are refused when called by name.
        for (harness, count) in [(HarnessKind.codex, 40), (.claudeCode, threshold - 1)] {
            let (broker, sessionID, token, _) = try makeBroker(
                codeMode: .auto, connectors: ExperimentConnectorProvider(toolCount: count),
                connectorScope: ConnectorTaskScope(harness: harness))
            for tool in [CodeModeToolCatalog.searchTools, CodeModeToolCatalog.runScript] {
                let refused = await broker.handle(AgentToolCall(token: token, session: sessionID.uuidString, tool: tool,
                                                                arguments: .object(["code": .string("return 1;")])))
                XCTAssertEqual(refused.structuredContent?["error"]?["kind"]?.stringValue,
                               AgentToolFailure.Kind.refused.rawValue, "\(harness.rawValue) \(tool)")
            }
        }
    }

    func testOffByDefaultRefusesCodeModeToolsEvenWithEmptyArgumentsAndLeavesConnectorListFlat() async throws {
        let stub = ExperimentConnectorProvider(toolCount: 25)
        let (broker, sessionID, token, _) = try makeBroker(codeMode: .off, connectors: stub)

        let listCall = AgentToolCall(
            token: token, session: sessionID.uuidString, tool: "",
            arguments: .object([:]), method: AgentToolCall.listMethod
        )
        let rawListed = await broker.list(listCall)
        let listed = try XCTUnwrap(rawListed)
        let names = Set(listed.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertFalse(names.contains(CodeModeToolCatalog.searchTools))
        XCTAssertFalse(names.contains(CodeModeToolCatalog.runScript))
        XCTAssertTrue(names.contains("gmail_search_threads"))

        // Even with missing required `code`, OFF must return `.refused` without leaking schema validation.
        let refused = await broker.handle(AgentToolCall(
            token: token, session: sessionID.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object([:])
        ))
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.structuredContent?["error"]?["kind"]?.stringValue, AgentToolFailure.Kind.refused.rawValue)
    }

    func testCodeModeCollapsesSchemasChainsAndFiltersToolsAndEnforcesGuardrails() async throws {
        let stub = ExperimentConnectorProvider(toolCount: 40)
        let (brokerOff, sessionOff, tokenOff, _) = try makeBroker(codeMode: .off, connectors: stub)
        let (brokerOn, sessionOn, tokenOn, _) = try makeBroker(codeMode: .on, connectors: stub)

        let encoder = JSONEncoder()
        let rawFlatList = await brokerOff.list(AgentToolCall(
            token: tokenOff, session: sessionOff.uuidString, tool: "",
            arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let flatList = try XCTUnwrap(rawFlatList)
        let rawCodeList = await brokerOn.list(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: "",
            arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let codeList = try XCTUnwrap(rawCodeList)
        let flatSchemaBytes = try encoder.encode(ToolJSON.array(flatList.tools)).count
        let codeSchemaBytes = try encoder.encode(ToolJSON.array(codeList.tools)).count
        XCTAssertLessThan(codeSchemaBytes, flatSchemaBytes / 3, "Code Mode collapses flat connector schemas")

        // 1. Progressive discovery via search_yardlet_tools (summary, category, exact, unknown)
        let summarySearch = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object([:])
        ))
        XCTAssertFalse(summarySearch.isError)
        let summary = try json(of: summarySearch)
        XCTAssertEqual(summary["count"] as? Int, 40)
        XCTAssertNotNil(summary["hint"])
        let summaryTools = try XCTUnwrap(summary["tools"] as? [[String: Any]])
        XCTAssertEqual(summaryTools.count, 40)
        XCTAssertNil(summaryTools.first?["inputSchema"], "Many matches list without schemas")

        let categorySearch = try json(of: await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object(["category": .string("gmail")])
        )))
        XCTAssertEqual(categorySearch["count"] as? Int, 2)
        let gmailTools = try XCTUnwrap(categorySearch["tools"] as? [[String: Any]])
        XCTAssertEqual(gmailTools.first?["category"] as? String, "gmail")
        XCTAssertNotNil(gmailTools.first?["inputSchema"], "Few matches list with schemas")

        let querySearch = try json(of: await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object(["query": .string("full gmail thread")])
        )))
        XCTAssertEqual((querySearch["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["gmail_get_thread"])

        let noMatch = try json(of: await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object(["query": .string("no such tool anywhere")])
        )))
        XCTAssertEqual(noMatch["count"] as? Int, 0)
        XCTAssertEqual((noMatch["tools"] as? [Any])?.count, 0)
        XCTAssertFalse((noMatch["groups"] as? [Any] ?? []).isEmpty, "No match lists every group to widen the search")

        // A script gets the search as an object it can filter.
        let scriptedSearch = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string(
                "return callTool('search_yardlet_tools', { category: 'gmail' }).tools.map(t => t.name);")])
        ))
        XCTAssertFalse(scriptedSearch.isError, text(of: scriptedSearch))
        XCTAssertTrue(text(of: scriptedSearch).contains("gmail_search_threads"))
        XCTAssertTrue(codeList.tools.filter {
            CodeModeToolCatalog.definition(named: $0["name"]?.stringValue ?? "") != nil
        }.allSatisfy { $0["_meta"]?["anthropic/alwaysLoad"] == .bool(true) })

        let exactSearch = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object(["tool": .string("gmail_get_thread")])
        ))
        XCTAssertFalse(exactSearch.isError)
        XCTAssertTrue(text(of: exactSearch).contains("inputSchema"))
        XCTAssertFalse(text(of: exactSearch).contains("\"_meta\""))

        let unknownSearch = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.searchTools,
            arguments: .object(["tool": .string("gmail_does_not_exist")])
        ))
        XCTAssertTrue(unknownSearch.isError)
        XCTAssertEqual(unknownSearch.structuredContent?["error"]?["kind"]?.stringValue, AgentToolFailure.Kind.unknownTool.rawValue)

        // 2. Multi-step filtering experiment: list 30 threads, fetch 5 urgent ones, return compact summary
        let began = Date()
        let script = """
        const listing = callTool("gmail_search_threads", { query: "is:unread" });
        const urgent = listing.threads.filter(t => t.labels.includes("URGENT")).slice(0, 5);
        const summary = urgent.map(t => {
            const detail = callTool("gmail_get_thread", { id: t.id });
            return { id: t.id, subject: detail.subject, owner: detail.owner, action: detail.actionItem };
        });
        return { scanned: listing.threads.length, urgentCount: summary.length, items: summary };
        """
        let runResult = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string(script)])
        ))
        let elapsedMs = Date().timeIntervalSince(began) * 1000
        XCTAssertFalse(runResult.isError, text(of: runResult))

        let codeResultBytes = text(of: runResult).utf8.count
        let rawBytes = stub.totalRawBytesReturned
        XCTAssertEqual(stub.callCount, 6)
        XCTAssertTrue(text(of: runResult).contains("\"urgentCount\":5"))
        XCTAssertLessThan(codeResultBytes, rawBytes / 10, "Distilled JS result is >10x smaller than raw MCP payloads")

        let schemaSavedPct = (1.0 - Double(codeSchemaBytes) / Double(flatSchemaBytes)) * 100
        let payloadSavedPct = (1.0 - Double(codeResultBytes) / Double(rawBytes)) * 100
        print(String(
            format: "CODE_MODE_BENCH schema=%d->%dB (-%.1f%%) payload=%d->%dB (-%.1f%%) calls=%d elapsed=%.1fms",
            flatSchemaBytes, codeSchemaBytes, schemaSavedPct, rawBytes, codeResultBytes, payloadSavedPct,
            stub.callCount, elapsedMs
        ))

        // 3. Guardrail: recursion refused & internal bridge globals hidden
        let recursive = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string("return callTool('run_yardlet_script', { code: 'return 1;' });")])
        ))
        XCTAssertTrue(recursive.isError)
        XCTAssertTrue(text(of: recursive).contains("Recursive"))

        let hiddenGlobals = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string("return { log: typeof globalThis.__yardletLog, call: typeof globalThis.__yardletCallTool };")])
        ))
        XCTAssertFalse(hiddenGlobals.isError)
        XCTAssertTrue(text(of: hiddenGlobals).contains("\"call\":\"undefined\""))
        XCTAssertTrue(text(of: hiddenGlobals).contains("\"log\":\"undefined\""))

        // 4. Guardrail: 20-call cap enforced
        let tooMany = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string("for (let i = 0; i < 25; i++) { callTool('gmail_search_threads', {}); } return true;")])
        ))
        XCTAssertTrue(tooMany.isError)
        XCTAssertTrue(text(of: tooMany).contains("maximum of 20"))

        // 5. Guardrail: credentials scrubbed in output, logs, AND thrown error structuredContent
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
        let leaked = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string("console.log('\(secret)'); return { token: '\(secret)' };")])
        ))
        XCTAssertFalse(leaked.isError)
        XCTAssertFalse(text(of: leaked).contains(secret), "CredentialText must scrub keys from script output and logs")

        let thrownSecret = await brokerOn.handle(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: CodeModeToolCatalog.runScript,
            arguments: .object(["code": .string("throw new Error('leaked \(secret)');")])
        ))
        XCTAssertTrue(thrownSecret.isError)
        XCTAssertFalse(text(of: thrownSecret).contains(secret))
        let structuredError = thrownSecret.structuredContent?["error"]?["message"]?.stringValue ?? ""
        XCTAssertFalse(structuredError.contains(secret), "structuredContent error message must also be scrubbed")
    }

    func testBridgeSafetyMultibyteCapAndTimeoutOutcomeUnknown() async throws {
        // 1. Null/undefined/function arguments never crash JSC bridging
        let edgeArgs = await CodeModeRunner.run(
            code: """
            console.log(undefined, null, () => {});
            const r1 = callTool("echo_tool");
            const r2 = callTool("echo_tool", null);
            const r3 = callTool("echo_tool", { fn: () => {} });
            return { r1, r2, r3 };
            """,
            timeoutSeconds: 5
        ) { _, _ in .text(#"{"ok":true}"#) }
        XCTAssertFalse(edgeArgs.isError, text(of: edgeArgs))

        // Non-object args fail cleanly in JS instead of crashing
        let badArgs = await CodeModeRunner.run(
            code: #"return callTool("echo_tool", [1, 2, 3]);"#,
            timeoutSeconds: 5
        ) { _, _ in .text("{}") }
        XCTAssertTrue(badArgs.isError)
        XCTAssertTrue(text(of: badArgs).contains("JSON object"))

        // 2. Multibyte Korean output stays strictly within maxOutputBytes
        let korean = await CodeModeRunner.run(
            code: #"return "가나다라마바사".repeat(1200);"#,
            timeoutSeconds: 5
        ) { _, _ in .text("{}") }
        XCTAssertFalse(korean.isError)
        XCTAssertLessThanOrEqual(text(of: korean).utf8.count, CodeModeRunner.maxOutputBytes)
        XCTAssertTrue(text(of: korean).contains("truncated"))

        // 3. Slow tool timeout after a call started reports `.outcomeUnknown` with `.afterChecking`
        let timedOut = await CodeModeRunner.run(
            code: #"return callTool("slow_tool", {});"#,
            timeoutSeconds: 1
        ) { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return .text("{}")
        }
        XCTAssertTrue(timedOut.isError)
        XCTAssertEqual(timedOut.structuredContent?["error"]?["kind"]?.stringValue, AgentToolFailure.Kind.outcomeUnknown.rawValue)
        XCTAssertEqual(timedOut.structuredContent?["error"]?["retry"]?.stringValue, AgentToolFailure.Retry.afterChecking.rawValue)
    }

    func testAntigravityCompactScopeUsesCodeModeWhenEnabled() async throws {
        let stub = ExperimentConnectorProvider(toolCount: 15)
        let scope = ConnectorTaskScope(harness: .antigravityCLI)
        let (brokerOn, sessionOn, tokenOn, _) = try makeBroker(codeMode: .on, connectors: stub, connectorScope: scope)
        let rawList = await brokerOn.list(AgentToolCall(
            token: tokenOn, session: sessionOn.uuidString, tool: "",
            arguments: .object([:]), method: AgentToolCall.listMethod
        ))
        let list = try XCTUnwrap(rawList)
        let names = Set(list.tools.compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(names.contains(CodeModeToolCatalog.searchTools))
        XCTAssertTrue(names.contains(CodeModeToolCatalog.runScript))
        XCTAssertFalse(names.contains(ConnectorGatewayToolCatalog.listTools))
        XCTAssertFalse(names.contains("gmail_search_threads"))
    }

    private func json(of result: AgentToolResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(of: result).utf8)) as? [String: Any])
    }

    private func text(of result: AgentToolResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

@MainActor
private final class ExperimentConnectorProvider: ConnectorToolProviding {
    let toolCount: Int
    var callCount = 0
    var totalRawBytesReturned = 0

    init(toolCount: Int) { self.toolCount = toolCount }
    var offersTools: Bool { true }

    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] {
        var list: [ToolJSON] = [
            makeTool("gmail_search_threads", "Search Gmail threads matching query and return metadata."),
            makeTool("gmail_get_thread", "Fetch full Gmail thread messages, headers, and HTML/text body.")
        ]
        for i in 2..<max(toolCount, 2) {
            let service = ["linear", "slack", "github", "notion", "calendar"][i % 5]
            list.append(makeTool(
                "\(service)_action_\(i)",
                "Perform \(service) operation \(i) with pagination, filters, sorting, and expanded metadata fields."
            ))
        }
        return Array(list.prefix(toolCount))
    }

    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
        callCount += 1
        let json: String
        if name == "gmail_search_threads" {
            let threads = (1...30).map { idx -> [String: Any] in
                [
                    "id": "th_\(idx)",
                    "snippet": String(repeating: "Thread preview metadata and quoted history line \(idx). ", count: 6),
                    "labels": idx % 5 == 0 ? ["INBOX", "UNREAD", "URGENT"] : ["INBOX", "UNREAD"],
                    "headers": ["from": "sender\(idx)@example.test", "to": "team@example.test", "messageId": "<m\(idx)@example.test>"],
                    "sizeEstimate": 48_000 + idx * 100
                ]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["threads": threads])
            json = String(data: data, encoding: .utf8)!
        } else if name == "gmail_get_thread" {
            let id = arguments["id"]?.stringValue ?? "unknown"
            let detail: [String: Any] = [
                "id": id,
                "subject": "Urgent release sign-off \(id)",
                "owner": "ops-\(id)",
                "actionItem": "Approve deployment window",
                "rawHeaders": Array(repeating: ["name": "Received", "value": "from mail.example.test by mx.example.test with ESMTPS"], count: 12),
                "body": String(repeating: "Full verbose HTML/plain email thread body, disclaimers, and quoted replies for \(id). ", count: 35)
            ]
            let data = try! JSONSerialization.data(withJSONObject: detail)
            json = String(data: data, encoding: .utf8)!
        } else {
            return nil
        }
        totalRawBytesReturned += json.utf8.count
        return .text(json)
    }

    private func makeTool(_ name: String, _ description: String) -> ToolJSON {
        .object([
            "name": .string(name),
            "description": .string(description),
            "_meta": .object(["internal": .bool(true)]),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Resource identifier")]),
                    "query": .object(["type": .string("string"), "description": .string("Search query string")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Maximum items to return")]),
                    "cursor": .object(["type": .string("string"), "description": .string("Pagination cursor from previous page")]),
                    "includeArchived": .object(["type": .string("boolean"), "description": .string("Include archived items")])
                ])
            ])
        ])
    }
}
