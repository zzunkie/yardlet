import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own approvals for agent tool calls (`AgentToolBroker+Approvals`): weighed where a tool runs, so a call
/// inside a wrapper is weighed as a direct one, a read-only task changes nothing, and no call gets two cards.
@MainActor
final class AgentToolApprovalTests: XCTestCase {
    private func makeBroker(policy: AgentToolCallerPolicy?, answer: Bool = true)
        throws -> (AgentToolBroker, UUID, String, ApprovalConnectors, RecordingApprovals) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let broker = AgentToolBroker(
            environment: .init(executableURL: URL(filePath: "/usr/bin/true"), endpoint: dir.appending(path: "sock").path,
                               privateDirectory: dir, isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) })
        )
        broker.codeModeEnabled = { true }
        let connectors = ApprovalConnectors()
        broker.connectors = connectors
        let approvals = RecordingApprovals(policy: policy, answer: answer)
        broker.approvals = approvals
        // The broker holds its approvals weakly, as it holds the app.
        addTeardownBlock { _ = approvals }
        let sessionID = UUID()
        approvals.hostTaskID = sessionID
        let launch = try XCTUnwrap(broker.agentToolServer(for: sessionID, workspaceRoots: [dir], connectorScope: nil))
        return (broker, sessionID, try XCTUnwrap(launch.environment[AgentToolEnvironment.token]), connectors, approvals)
    }

    private func policy(readOnly: Bool = false, asks: Bool = true, claudeCLIAsks: Bool = false) -> AgentToolCallerPolicy {
        AgentToolCallerPolicy(hostTaskID: UUID(), readOnly: readOnly, asksPerson: asks,
                              harnessAsksBeforeDirectCalls: claudeCLIAsks)
    }

    private func script(_ body: String, _ broker: AgentToolBroker, _ session: UUID, _ token: String) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: CodeModeToolCatalog.runScript,
                                          arguments: .object(["code": .string(body)])))
    }

    private func direct(_ tool: String, _ broker: AgentToolBroker, _ session: UUID, _ token: String) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object([:])))
    }

    func testAWrapperAsksOncePerServiceToReadAndEachTimeToWrite() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy())
        _ = await script("""
            callTool("gmail_search", {}); callTool("gmail_search", {}); callTool("slack_read", {});
            callTool("gmail_send", {}); return 1;
            """, broker, session, token)
        XCTAssertEqual(approvals.titles, [
            L10n.format("Allow this task to read from %@?", "Gmail"),
            L10n.format("Allow this task to read from %@?", "Slack"),
            L10n.format("Allow this task to use %@ in %@?", "Send", "Gmail")
        ])
        XCTAssertEqual(connectors.calls, ["gmail_search", "gmail_search", "slack_read", "gmail_send"])

        // A later read from an allowed service, direct or wrapped, asks nothing; every write asks again.
        _ = await direct("gmail_search", broker, session, token)
        _ = await script(#"callTool("gmail_search", {}); callTool("gmail_send", {}); return 1;"#, broker, session, token)
        XCTAssertEqual(approvals.titles.count, 4)
        XCTAssertEqual(approvals.titles.last, L10n.format("Allow this task to use %@ in %@?", "Send", "Gmail"))
    }

    func testADeclinedCardRunsNothing() async throws {
        let (broker, session, token, connectors, _) = try makeBroker(policy: policy(), answer: false)
        let result = await direct("gmail_send", broker, session, token)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?["error"]?["kind"]?.stringValue, AgentToolFailure.Kind.refused.rawValue)
        XCTAssertEqual(connectors.calls, [])
    }

    func testClaudeCodesOwnCardAnswersOnlyItsDirectCall() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy(claudeCLIAsks: true))
        _ = await direct("gmail_send", broker, session, token)
        _ = await direct("gmail_search", broker, session, token)
        XCTAssertEqual(approvals.titles, [], "The CLI asked about both")
        // The read the CLI allowed counts for the service; a write inside a script was never on the CLI's card.
        _ = await script(#"callTool("gmail_search", {}); callTool("gmail_send", {}); return 1;"#, broker, session, token)
        XCTAssertEqual(approvals.titles, [L10n.format("Allow this task to use %@ in %@?", "Send", "Gmail")])
        XCTAssertEqual(connectors.calls.count, 4)
    }

    func testATaskThatRunsWithoutAskingIsNotAsked() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy(asks: false))
        _ = await script(#"callTool("gmail_search", {}); callTool("gmail_send", {}); return 1;"#, broker, session, token)
        XCTAssertEqual(approvals.titles, [])
        XCTAssertEqual(connectors.calls, ["gmail_search", "gmail_send"])
    }

    func testAReadOnlyTaskReadsThroughWrappersAndChangesNothing() async throws {
        let (broker, session, token, connectors, _) = try makeBroker(policy: policy(readOnly: true, asks: false))
        _ = await script(#"callTool("gmail_search", {}); return 1;"#, broker, session, token)
        let write = await script(#"return callTool("gmail_send", {});"#, broker, session, token)
        XCTAssertTrue(text(write).contains("read-only"), text(write))
        let gateway = await broker.handle(AgentToolCall(
            token: token, session: session.uuidString, tool: ConnectorGatewayToolCatalog.callTool,
            arguments: .object(["tool": .string("gmail_send")])))
        XCTAssertTrue(text(gateway).contains("read-only"))
        XCTAssertEqual(connectors.calls, ["gmail_search"])

        for tool in [SessionToolCatalog.sendMessageToTask, SessionToolCatalog.archiveTask, SessionToolCatalog.createProject,
                     SettingsToolCatalog.update, ScheduleToolCatalog.create, AgentToolCatalog.navigate,
                     AgentToolCatalog.click, VaultToolCatalog.fillCredential, SimulatorToolCatalog.tap] {
            let refusal = await broker.approvalRefusal(tool: tool, arguments: .object([:]), sessionID: session, origin: .direct)
            XCTAssertNotNil(refusal, tool)
        }
        for tool in [SessionToolCatalog.readTask, SessionToolCatalog.runAgent, SessionToolCatalog.createTask,
                     AgentToolCatalog.scroll, AgentToolCatalog.resize, AgentToolCatalog.snapshot,
                     CodeModeToolCatalog.runScript, ConnectorGatewayToolCatalog.callTool,
                     SimulatorGatewayToolCatalog.callTool] {
            let refusal = await broker.approvalRefusal(tool: tool, arguments: .object([:]), sessionID: session, origin: .direct)
            XCTAssertNil(refusal, tool)
        }
        let readingBatch = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.snapshot, AgentToolCatalog.scroll]), sessionID: session, origin: .direct)
        XCTAssertNil(readingBatch)
        let clickingBatch = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.snapshot, AgentToolCatalog.click]), sessionID: session, origin: .direct)
        XCTAssertNotNil(clickingBatch)
    }

    func testABatchAsksOnceForItsChangingActions() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy(claudeCLIAsks: true))
        let observing = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.snapshot, AgentToolCatalog.scroll, AgentToolCatalog.screenshot]),
            sessionID: session, origin: .direct)
        XCTAssertNil(observing)
        XCTAssertEqual(approvals.titles, [])
        let acting = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.navigate, AgentToolCatalog.snapshot, AgentToolCatalog.click, AgentToolCatalog.type]),
            sessionID: session, origin: .direct)
        XCTAssertNil(acting)
        XCTAssertEqual(approvals.titles, [L10n.string("Allow this task to run these browser actions?")])
        XCTAssertEqual(approvals.details.last?.split(separator: "\n").count, 3)
        // A script's browser action was never on the harness's card.
        _ = await broker.approvalRefusal(tool: AgentToolCatalog.click, arguments: .object([:]), sessionID: session,
                                         origin: .wrapped)
        _ = await broker.approvalRefusal(tool: AgentToolCatalog.click, arguments: .object([:]), sessionID: session,
                                         origin: .direct)
        XCTAssertEqual(approvals.titles.count, 2)
    }

    func testScheduleChangesAndSignInFillsAskEachTimeTheHarnessDidNot() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy(claudeCLIAsks: true))
        for origin in [AgentToolCallOrigin.direct, .wrapped] {
            _ = await broker.approvalRefusal(tool: ScheduleToolCatalog.delete, arguments: .object([:]), sessionID: session,
                                             origin: origin)
            _ = await broker.approvalRefusal(tool: VaultToolCatalog.fillCredential, arguments: .object([:]),
                                             sessionID: session, origin: origin)
            _ = await broker.approvalRefusal(tool: ScheduleToolCatalog.list, arguments: .object([:]), sessionID: session,
                                             origin: origin)
        }
        XCTAssertEqual(approvals.titles, [L10n.string("Allow this task to delete a scheduled task?"),
                                          L10n.string("Allow this task to fill a saved sign-in?")])
    }

    func testHarnessCardsOfferNoLastingAllowForWhatYardletAsksEachTime() {
        XCTAssertTrue(AgentToolServerLaunch.claudeAllowedTools.contains("mcp__yardlet__\(CodeModeToolCatalog.runScript)"))
        XCTAssertTrue(AgentToolServerLaunch.claudeAllowedTools.contains("mcp__yardlet__\(AgentToolCatalog.batch)"))
        func codexCard(server: String, tool: String) -> [String] {
            let params: JSONValue = .object([
                "serverName": .string(server),
                "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "tool_name": .string(tool),
                                  "persist": .array([.string("session"), .string("always")])])
            ])
            return CodexMCPToolApproval(params: params)?.responses.map(\.title) ?? []
        }
        let once = [L10n.string("Deny"), L10n.string("Allow once")]
        XCTAssertEqual(codexCard(server: "yardlet", tool: ScheduleToolCatalog.delete), once)
        XCTAssertEqual(codexCard(server: "yardlet", tool: CodeModeToolCatalog.runScript), once)
        XCTAssertEqual(codexCard(server: "yardlet", tool: AgentToolCatalog.click).count, 4)
        XCTAssertEqual(codexCard(server: "other", tool: ScheduleToolCatalog.delete).count, 4)
    }

    func testDestructiveToolsSaySo() {
        let destructive = Set([SessionToolCatalog.archiveTask, ScheduleToolCatalog.delete, AgentToolCatalog.tabClose])
        let all = AgentToolCatalog.browserTools + SessionToolCatalog.tools + ScheduleToolCatalog.tools
        for definition in all {
            XCTAssertEqual(definition.json["annotations"]?["destructiveHint"], .bool(destructive.contains(definition.name)),
                           definition.name)
        }
    }

    private static func batch(_ names: [String]) -> ToolJSON {
        .object(["actions": .array(names.map { .object(["name": .string($0), "input": .object([:])]) })])
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

@MainActor
private final class RecordingApprovals: AgentToolApprovalHandling {
    var policy: AgentToolCallerPolicy?
    let answer: Bool
    var hostTaskID = UUID()
    var titles: [String] = []
    var details: [String] = []

    init(policy: AgentToolCallerPolicy?, answer: Bool) {
        self.policy = policy
        self.answer = answer
    }

    func agentToolPolicy(callerID: UUID) -> AgentToolCallerPolicy? {
        guard var policy else { return nil }
        policy.hostTaskID = hostTaskID
        return policy
    }

    func askPerson(title: String, detail: String, callerID: UUID) async -> Bool {
        titles.append(title)
        details.append(detail)
        return answer
    }
}

@MainActor
private final class ApprovalConnectors: ConnectorToolProviding {
    private let facts: [String: ConnectorToolFacts] = [
        "gmail_search": .init(service: "Gmail", title: "Search", readOnly: true),
        "gmail_send": .init(service: "Gmail", title: "Send", readOnly: false),
        "slack_read": .init(service: "Slack", title: "Read", readOnly: true)
    ]
    var calls: [String] = []
    var offersTools: Bool { true }

    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] {
        facts.keys.sorted().map { .object(["name": .string($0), "inputSchema": .object(["type": .string("object")])]) }
    }

    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
        guard facts[name] != nil else { return nil }
        calls.append(name)
        return .text("{}")
    }

    func connectorToolFacts(named name: String, for context: ConnectorToolContext) -> ConnectorToolFacts? {
        facts[name]
    }
}
