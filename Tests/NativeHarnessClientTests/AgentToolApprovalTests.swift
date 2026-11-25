import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own approvals for agent tool calls (`AgentToolBroker+Approvals`): weighed where a tool runs, so a call
/// inside a wrapper is weighed as a direct one, a read-only task changes nothing, and no call gets two cards.
@MainActor
final class AgentToolApprovalTests: XCTestCase {
    private func makeBroker(policy: AgentToolCallerPolicy?, answer: Bool = true,
                            simulators: (any SimulatorToolHandling)? = nil)
        throws -> (AgentToolBroker, UUID, String, ApprovalConnectors, RecordingApprovals) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let broker = AgentToolBroker(
            environment: .init(executableURL: URL(filePath: "/usr/bin/true"), endpoint: dir.appending(path: "sock").path,
                               privateDirectory: dir, isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) })
        )
        broker.codeModeSetting = { .on }
        broker.simulators = simulators
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
                     AgentToolCatalog.tabNew, AgentToolCatalog.click, VaultToolCatalog.fillCredential,
                     SimulatorToolCatalog.tap] {
            let refusal = await broker.approvalRefusal(tool: tool, arguments: .object([:]), sessionID: session, origin: .direct)
            XCTAssertNotNil(refusal, tool)
        }
        for tool in [SessionToolCatalog.readTask, SessionToolCatalog.runAgent, SessionToolCatalog.createTask,
                     AgentToolCatalog.scroll, AgentToolCatalog.resize, AgentToolCatalog.snapshot,
                     AgentToolCatalog.tabList, AgentToolCatalog.screenshot, AgentToolCatalog.consoleMessages,
                     AgentToolCatalog.waitFor, CodeModeToolCatalog.runScript, ConnectorGatewayToolCatalog.callTool,
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
        let tabBatch = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.snapshot, AgentToolCatalog.tabNew]), sessionID: session, origin: .direct)
        XCTAssertNotNil(tabBatch, "A read-only task opens no tab")
    }

    func testABatchAsksOnceForItsChangingActions() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy(claudeCLIAsks: true))
        let observing = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([
            AgentToolCatalog.snapshot, AgentToolCatalog.scroll, AgentToolCatalog.screenshot]),
            sessionID: session, origin: .direct)
        XCTAssertNil(observing)
        XCTAssertEqual(approvals.titles, [])
        var actions = Self.batch([AgentToolCatalog.snapshot, AgentToolCatalog.click, AgentToolCatalog.type])
        actions = Self.prependingNavigation("https://docs.example.test/a", to: actions)
        let acting = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: actions,
                                                  sessionID: session, origin: .direct)
        XCTAssertNil(acting)
        XCTAssertEqual(approvals.titles, [L10n.string("Allow this task to run these browser actions?")])
        XCTAssertEqual(approvals.details.last?.split(separator: "\n").count, 4, approvals.details.last ?? "")
        XCTAssertTrue(approvals.details.last?.contains("https://docs.example.test") == true)
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

    func testTabToolsAskInABatchAndInAScript() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy(claudeCLIAsks: true))
        for tool in [AgentToolCatalog.tabClose, AgentToolCatalog.tabSelect] {
            XCTAssertTrue(AgentToolBroker.changingBrowserTools.contains(tool), tool)
            let inBatch = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: Self.batch([tool]),
                                                       sessionID: session, origin: .direct)
            XCTAssertNil(inBatch)
            _ = await broker.approvalRefusal(tool: tool, arguments: .object([:]), sessionID: session, origin: .wrapped)
        }
        XCTAssertEqual(approvals.titles.count, 4)
        XCTAssertFalse(AgentToolBroker.changingBrowserTools.contains(AgentToolCatalog.scroll))
        XCTAssertFalse(AgentToolBroker.changingBrowserTools.contains(AgentToolCatalog.handoff))
    }

    func testACancelledCallTakesItsCardAwayAndRunsNothing() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy())
        let center = SessionToolCenter(defaults: try XCTUnwrap(UserDefaults(suiteName: "approvals-\(UUID().uuidString)")))
        approvals.center = center
        let host = approvals.hostTaskID
        let call = Task { await self.direct("gmail_send", broker, session, token) }
        try await waitUntil { !center.approvals(for: host).isEmpty }
        call.cancel()
        try await waitUntil { center.approvals(for: host).isEmpty }
        let result = await call.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(connectors.calls, [], "A late answer cannot send it either")

        // A script out of time cancels its call the same way.
        let script = Task { await self.script(#"return callTool("gmail_send", {});"#, broker, session, token) }
        try await waitUntil { !center.approvals(for: host).isEmpty }
        script.cancel()
        try await waitUntil { center.approvals(for: host).isEmpty }
        _ = await script.value
        XCTAssertEqual(connectors.calls, [])
    }

    func testAFirstReadQuestionIsSharedAndALaterOneIsNotLost() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy())
        let center = SessionToolCenter(defaults: try XCTUnwrap(UserDefaults(suiteName: "approvals-\(UUID().uuidString)")))
        approvals.center = center
        let host = approvals.hostTaskID
        let first = Task { await self.direct("gmail_search", broker, session, token) }
        let second = Task { await self.direct("gmail_search", broker, session, token) }
        try await waitUntil { center.approvals(for: host).count == 1 && broker.pendingReadApprovals.first?.value.waiters == 2 }
        let card = try XCTUnwrap(center.approvals(for: host).first)
        XCTAssertTrue(center.answer(card.id, allow: false))
        let declined = await first.value
        XCTAssertTrue(declined.isError)
        let third = Task { await self.direct("gmail_search", broker, session, token) }
        try await waitUntil { center.approvals(for: host).count == 1 }
        _ = await second.value
        XCTAssertNotNil(broker.pendingReadApprovals.first, "The second call's clean-up leaves the third's question")
        XCTAssertTrue(center.answer(try XCTUnwrap(center.approvals(for: host).first).id, allow: true))
        let read = await third.value
        XCTAssertFalse(read.isError)
        XCTAssertEqual(connectors.calls, ["gmail_search"])
        XCTAssertEqual(approvals.titles.count, 2)

        // Every waiter cancelled withdraws the question.
        let slack = Task { await self.direct("slack_read", broker, session, token) }
        try await waitUntil { !center.approvals(for: host).isEmpty }
        slack.cancel()
        try await waitUntil { center.approvals(for: host).isEmpty }
        _ = await slack.value
        XCTAssertEqual(connectors.calls, ["gmail_search"])
    }

    /// The person's personal agents are read once per task after one card, shared by calls made while it waits, in
    /// every task that asks (a read-only one included) and through a script as directly.
    func testPersonalAgentsAreReadAfterOneCardPerTask() async throws {
        let (broker, session, token, _, approvals) = try makeBroker(policy: policy(readOnly: true))
        let center = SessionToolCenter(defaults: try XCTUnwrap(UserDefaults(suiteName: "approvals-\(UUID().uuidString)")))
        approvals.center = center
        let host = approvals.hostTaskID
        let first = Task { await self.direct(SessionToolCatalog.listPersonalAgents, broker, session, token) }
        let second = Task { await self.direct(SessionToolCatalog.listPersonalAgents, broker, session, token) }
        try await waitUntil { broker.pendingReadApprovals.first?.value.waiters == 2 }
        XCTAssertEqual(center.approvals(for: host).count, 1)
        XCTAssertEqual(approvals.titles, [L10n.string("Allow this task to read your personal agents?")])
        XCTAssertTrue(center.answer(try XCTUnwrap(center.approvals(for: host).first).id, allow: true))
        for call in [first, second] {
            let result = await call.value
            XCTAssertNotEqual(result.structuredContent?["error"]?["kind"]?.stringValue,
                              AgentToolFailure.Kind.refused.rawValue, text(result))
        }
        _ = await direct(SessionToolCatalog.listPersonalAgents, broker, session, token)
        _ = await script(#"callTool("read_personal_agent", {agent: "dot"}); return 1;"#, broker, session, token)
        XCTAssertEqual(approvals.titles.count, 1, "Later reads, direct or wrapped, ask nothing")

        // A task that runs without asking is not asked; a declined card reads nothing.
        let (unasked, unaskedSession, unaskedToken, _, unaskedApprovals) = try makeBroker(policy: policy(asks: false))
        _ = await direct(SessionToolCatalog.listPersonalAgents, unasked, unaskedSession, unaskedToken)
        XCTAssertEqual(unaskedApprovals.titles, [])
        let (declining, declinedSession, declinedToken, _, _) = try makeBroker(policy: policy(), answer: false)
        let declined = await direct(SessionToolCatalog.listPersonalAgents, declining, declinedSession, declinedToken)
        XCTAssertEqual(declined.structuredContent?["error"]?["kind"]?.stringValue, AgentToolFailure.Kind.refused.rawValue)
    }

    /// A task released while its first read's card waits takes the card away and keeps no allow, whatever comes after.
    func testReleasingATaskWithdrawsItsFirstReadQuestion() async throws {
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy())
        let center = SessionToolCenter(defaults: try XCTUnwrap(UserDefaults(suiteName: "approvals-\(UUID().uuidString)")))
        approvals.center = center
        let host = approvals.hostTaskID
        let read = Task { await self.direct("gmail_search", broker, session, token) }
        try await waitUntil { !center.approvals(for: host).isEmpty }
        broker.releaseAgentTools(for: session)
        try await waitUntil { center.approvals(for: host).isEmpty }
        let result = await read.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(broker.pendingReadApprovals.isEmpty)
        XCTAssertNil(broker.approvedReadServices[session])
        XCTAssertEqual(connectors.calls, [])
    }

    func testAWriteCardNamesItsAccount() async throws {
        let (broker, session, token, _, approvals) = try makeBroker(policy: policy())
        _ = await direct("gmail_send", broker, session, token)
        _ = await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: "gmail_send",
                                              arguments: .object(["account": .string("work@example.test")])))
        XCTAssertEqual(approvals.details.map { $0.split(separator: "\n").first.map(String.init) },
                       [L10n.format("Account: %@", "me@example.test"), L10n.format("Account: %@", "work@example.test")])
    }

    func testTheGatewaysWeighTheToolTheyCall() async throws {
        let simulator = ApprovalSimulators()
        let (broker, session, token, connectors, approvals) = try makeBroker(policy: policy(readOnly: true),
                                                                             simulators: simulator)
        func gateway(_ name: String, _ tool: String) async -> AgentToolResult {
            await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: name,
                                              arguments: .object(["tool": .string(tool)])))
        }
        let tap = await gateway(SimulatorGatewayToolCatalog.callTool, SimulatorToolCatalog.tap)
        XCTAssertTrue(text(tap).contains("read-only"), text(tap))
        _ = await gateway(SimulatorGatewayToolCatalog.callTool, SimulatorToolCatalog.screenshot)
        XCTAssertEqual(simulator.calls, [SimulatorToolCatalog.screenshot])
        // In a task that asks, a write through the connector gateway asks as a direct one does.
        approvals.policy = policy()
        _ = await gateway(ConnectorGatewayToolCatalog.callTool, "gmail_send")
        XCTAssertEqual(approvals.titles, [L10n.format("Allow this task to use %@ in %@?", "Send", "Gmail")])
        XCTAssertEqual(connectors.calls, ["gmail_send"])
    }

    func testReadingAndViewingATabGoUnaskedEverywhere() async throws {
        let unasked = Set(AgentToolCatalog.unaskedTools)
        XCTAssertEqual(unasked, [AgentToolCatalog.tabList, AgentToolCatalog.snapshot, AgentToolCatalog.screenshot,
                                 AgentToolCatalog.consoleMessages, AgentToolCatalog.waitFor, AgentToolCatalog.scroll,
                                 AgentToolCatalog.resize, AgentToolCatalog.tabNew])
        for tool in unasked.union([AgentToolCatalog.navigate]) {
            // Claude Code runs it without its card, and Codex and Antigravity read it as one that changes nothing.
            XCTAssertTrue(AgentToolServerLaunch.claudeAllowedTools.contains("mcp__yardlet__\(tool)"), tool)
            XCTAssertEqual(AgentToolCatalog.definition(named: tool)?.json["annotations"]?["readOnlyHint"], .bool(true), tool)
        }
        XCTAssertTrue(AgentToolBroker.changingBrowserTools.isDisjoint(with: unasked))
        XCTAssertTrue(AgentToolHarnessApproval.asksEachTime(tool: AgentToolCatalog.navigate, labels: ConnectorToolLabels()),
                      "No harness card allows every site for good")
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy())
        let viewing = await broker.approvalRefusal(tool: AgentToolCatalog.batch,
                                                   arguments: Self.batch(Array(unasked)), sessionID: session,
                                                   origin: .direct)
        XCTAssertNil(viewing)
        for tool in unasked {
            _ = await broker.approvalRefusal(tool: tool, arguments: .object([:]), sessionID: session, origin: .wrapped)
        }
        XCTAssertEqual(approvals.titles, [])
    }

    func testNavigationIsAllowedBySiteAndPort() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy())
        approvals.listeningPorts = [3000]
        func goes(_ address: String) async -> Bool {
            await broker.allowsNavigation(to: address, redirectedFrom: nil, sessionID: session)
        }
        // A blank page, a file (weighed by folders elsewhere) and the task's own server go unasked, by any loopback name.
        for address in ["about:blank", "file:///tmp/x.html", "http://localhost:3000/", "http://127.0.0.1:3000/a",
                        "http://[::1]:3000", "https://localhost:3000", "http://0.0.0.0:3000/", "http://[::]:3000"] {
            let allowed = await goes(address)
            XCTAssertTrue(allowed, address)
        }
        XCTAssertEqual(approvals.titles, [])
        // Another port of the Mac, the local network and a data: address ask; a data: card offers no site to allow.
        approvals.chosen = BrowserNavigationAnswer.onceID
        for address in ["http://localhost:3001", "http://192.168.0.2:3000", "data:text/html,hi"] {
            let allowed = await goes(address)
            XCTAssertTrue(allowed, address)
        }
        XCTAssertEqual(approvals.titles.count, 3)
        XCTAssertEqual(approvals.offered.last, [BrowserNavigationAnswer.denyID, BrowserNavigationAnswer.onceID])
        XCTAssertEqual(approvals.offered.first?.last, BrowserNavigationAnswer.siteID)

        // Allowed for the task: the same scheme, host and port go; another port or scheme asks.
        approvals.chosen = BrowserNavigationAnswer.siteID
        _ = await goes("https://docs.stripe.com/a")
        let asked = approvals.titles.count
        _ = await goes("https://docs.stripe.com/b?q=1")
        _ = await goes("HTTPS://DOCS.STRIPE.COM:443/c")
        XCTAssertEqual(approvals.titles.count, asked)
        approvals.answer = false
        let otherPort = await goes("https://docs.stripe.com:8443/")
        let otherScheme = await goes("http://docs.stripe.com/")
        XCTAssertFalse(otherPort)
        XCTAssertFalse(otherScheme)
        XCTAssertEqual(approvals.titles.count, asked + 2)

        // What a batch's card let through goes while the batch runs, and no longer.
        let site = BrowserNavigationTarget("https://example.test/x").passKey
        let passed = await BrowserNavigationPass.$allowed.withValue([site]) { await goes("https://example.test/y") }
        XCTAssertTrue(passed)
        let after = await goes("https://example.test/y")
        XCTAssertFalse(after)

        // A released task's sites are asked about again; a task that runs without asking is asked nothing.
        broker.releaseAgentTools(for: session)
        approvals.answer = true
        approvals.chosen = BrowserNavigationAnswer.onceID
        _ = await goes("https://docs.stripe.com/a")
        XCTAssertEqual(approvals.titles.count, asked + 4)
        approvals.policy = policy(asks: false)
        let unasked = await goes("https://anywhere.example.test")
        XCTAssertTrue(unasked)
        XCTAssertEqual(approvals.titles.count, asked + 4)
    }

    func testABatchCardCanAllowItsSitesForTheTask() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy())
        approvals.chosen = BrowserNavigationAnswer.siteID
        var pass: Set<String> = []
        let arguments = Self.prependingNavigation("https://docs.example.test/a", to: Self.batch([AgentToolCatalog.snapshot]))
        let refusal = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: arguments, sessionID: session,
                                                   origin: .direct, navigationPass: &pass)
        XCTAssertNil(refusal)
        XCTAssertEqual(pass, ["https://docs.example.test"])
        // The site is the task's now: the same batch, and a direct navigation there, ask nothing.
        _ = await broker.approvalRefusal(tool: AgentToolCatalog.batch, arguments: arguments, sessionID: session,
                                         origin: .direct)
        let direct = await broker.allowsNavigation(to: "https://docs.example.test/b", redirectedFrom: nil, sessionID: session)
        XCTAssertTrue(direct)
        XCTAssertEqual(approvals.titles.count, 1)
    }

    func testADownloadFromASiteAsksOnceForTheTask() async throws {
        let (broker, session, _, _, approvals) = try makeBroker(policy: policy())
        approvals.listeningPorts = [5173]
        let own = await broker.allowsAgentDownload(from: "http://localhost:5173/report.csv", fileName: "report.csv",
                                                   sessionID: session)
        XCTAssertTrue(own)
        XCTAssertEqual(approvals.titles, [])
        let first = await broker.allowsAgentDownload(from: "https://files.example.test/a.zip", fileName: "a.zip",
                                                     sessionID: session)
        let second = await broker.allowsAgentDownload(from: "https://files.example.test/b.zip", fileName: "b.zip",
                                                      sessionID: session)
        XCTAssertTrue(first && second)
        XCTAssertEqual(approvals.titles, [L10n.format("Allow downloads from %@ in this task?", "https://files.example.test")])
        // Allowing a site to open does not allow its downloads, and a declined one is not kept.
        approvals.answer = false
        let declined = await broker.allowsAgentDownload(from: "https://other.example.test/c.zip", fileName: "c.zip",
                                                        sessionID: session)
        XCTAssertFalse(declined)
        let again = await broker.allowsAgentDownload(from: "https://other.example.test/c.zip", fileName: "c.zip",
                                                     sessionID: session)
        XCTAssertFalse(again)
        XCTAssertEqual(approvals.titles.count, 3)
    }

    func testAnAddressChromiumReadsAsAnotherSiteNamesNoSite() {
        // Chromium reads a backslash as a slash and drops control characters; Foundation reads them otherwise.
        for address in ["http://169.254.169.254\\@localhost:3000/", "https://evil.test\\exfil=1@docs.stripe.com/",
                        "https://user:pass@docs.stripe.com/", "https://evil.test@docs.stripe.com/",
                        "http://local\thost:3000/", "http://localhost\n:3000/", "http://loc%61lhost:3000/",
                        "https:docs.stripe.com/", "http:/localhost:3000", "https://ｌｏｃａｌｈｏｓｔ:3000/"] {
            XCTAssertNil(BrowserSite(address), address)
            guard case .other = BrowserNavigationTarget(address) else { return XCTFail(address) }
        }
        XCTAssertEqual(BrowserSite("https://docs.stripe.com/a\\b?q=@x#@y")?.text, "https://docs.stripe.com",
                       "Past the host, such characters are the page's")
        XCTAssertEqual(BrowserSite("http://[::1]:3000/")?.namesThisMac, true)
    }

    func testACardWithSeveralAllowsReportsTheOneChosen() async throws {
        let center = SessionToolCenter(defaults: try XCTUnwrap(UserDefaults(suiteName: "approvals-\(UUID().uuidString)")))
        let task = UUID()
        let actions = BrowserNavigationAnswer.actions(site: "https://docs.example.test")
        func ask(timeout: Duration = .seconds(60)) -> Task<String?, Never> {
            Task { await center.choose(PermissionRequest(id: UUID().uuidString, title: "t", detail: "d", command: nil,
                                                         actions: actions), in: task, timeout: timeout, onChange: {}) }
        }
        func card() async throws -> SessionToolApproval {
            try await waitUntil { !center.approvals(for: task).isEmpty }
            return try XCTUnwrap(center.approvals(for: task).first)
        }
        let site = ask()
        center.answer(try await card().id, allow: true, actionID: BrowserNavigationAnswer.siteID)
        let chosen = await site.value
        XCTAssertEqual(chosen, BrowserNavigationAnswer.siteID)
        // An allow that names none (a notification) takes the narrowest; a no, a cancel and a timeout answer nil.
        let plain = ask()
        center.answer(try await card().id, allow: true)
        let narrowest = await plain.value
        XCTAssertEqual(narrowest, BrowserNavigationAnswer.onceID)
        let denied = ask()
        center.answer(try await card().id, allow: false, actionID: BrowserNavigationAnswer.siteID)
        let no = await denied.value
        XCTAssertNil(no)
        let cancelled = ask()
        _ = try await card()
        cancelled.cancel()
        let gone = await cancelled.value
        XCTAssertNil(gone)
        try await waitUntil { center.approvals(for: task).isEmpty }
        let late = await ask(timeout: .milliseconds(50)).value
        XCTAssertNil(late)
        XCTAssertTrue(center.approvals(for: task).isEmpty)
    }

    func testADeclinedDownloadIsCancelledOrTrashedWhateverArrivesFirst() async throws {
        let checks = AgentDownloadChecks()
        var cancels = 0
        var trashed: [String] = []
        var answer: CheckedContinuation<Bool, Never>?
        func download(_ state: BrowserDownload.State) -> BrowserDownload {
            BrowserDownload(id: 1, state: state, fileName: "a.zip", path: "/tmp/a.zip", receivedBytes: 1, totalBytes: 2)
        }
        func note(_ state: BrowserDownload.State, key: String = "t-1", isAgents: Bool = true) {
            checks.note(download(state), key: key, isAgents: isAgents,
                        ask: { await withCheckedContinuation { answer = $0 } },
                        cancel: { cancels += 1 }, trash: { trashed.append($0) })
        }
        // Declined while it runs: cancelled; its completion, reported before the cancel reached the host, is trashed.
        note(.started)
        try await waitUntil { answer != nil }
        answer?.resume(returning: false)
        answer = nil
        try await waitUntil { cancels == 1 }
        note(.inProgress)
        note(.completed)
        XCTAssertEqual(trashed, ["/tmp/a.zip"])
        XCTAssertFalse(checks.isChecking("t-1"))

        // Finished before the answer came: trashed once the person declines.
        note(.started, key: "t-2")
        try await waitUntil { answer != nil }
        note(.completed, key: "t-2")
        answer?.resume(returning: false)
        answer = nil
        try await waitUntil { trashed.count == 2 }
        XCTAssertEqual(cancels, 1)

        // Allowed, or not the agent's: nothing is touched.
        note(.started, key: "t-3")
        try await waitUntil { answer != nil }
        answer?.resume(returning: true)
        answer = nil
        try await waitUntil { !checks.isChecking("t-3") }
        note(.completed, key: "t-3")
        note(.started, key: "t-4", isAgents: false)
        XCTAssertFalse(checks.isChecking("t-4"))
        XCTAssertEqual(trashed.count, 2)
        XCTAssertEqual(cancels, 1)
    }

    func testOnlyTheAgentsActMakesADownloadItsOwn() throws {
        final class Connection: BrowserHostConnection {
            var eventHandler: ((BrowserHostEvent) -> Void)?
            func send(_ command: BrowserHostCommand) {}
            func terminate() {}
        }
        let connection = Connection()
        let client = BrowserHostClient(idleGrace: .seconds(60)) { connection }
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        tab.noteAgentInput()
        XCTAssertTrue(tab.downloadsAreAgents)
        // The person clicks a download; the agent then only reads the page.
        tab.notePersonInput()
        client.noteAgentActivity(on: tab)
        XCTAssertTrue(tab.isDrivenByAgent)
        XCTAssertFalse(tab.downloadsAreAgents, "A read leaves the person's download theirs")

        // Where the agent's download comes from: what it opened, until the tab shows another page.
        tab.noteAgentInput()
        tab.noteAgentOpened("http://localhost:3000/export")
        XCTAssertEqual(tab.agentDownloadAddress, "http://localhost:3000/export")
        connection.eventHandler?(.address(tab: tab.id, url: "https://untrusted.example.test/"))
        XCTAssertEqual(tab.agentDownloadAddress, "https://untrusted.example.test/")
        tab.noteAgentOpened("http://localhost:3000/export")
        tab.notePersonInput()
        XCTAssertNotEqual(tab.agentDownloadAddress, "http://localhost:3000/export")
    }

    func testAToolNotKnownToReadGetsNoLastingAllow() {
        let labels = ConnectorToolLabels()
        XCTAssertTrue(AgentToolHarnessApproval.asksEachTime(tool: "slack_post_message", labels: labels),
                      "A connector whose labels have not come")
        XCTAssertFalse(AgentToolHarnessApproval.asksEachTime(tool: AgentToolCatalog.click, labels: labels))
        XCTAssertFalse(AgentToolHarnessApproval.asksEachTime(tool: SessionToolCatalog.readTask, labels: labels))
        XCTAssertTrue(AgentToolHarnessApproval.asksEachTime(tool: VaultToolCatalog.fillCredential, labels: labels))
    }

    private static func batch(_ names: [String]) -> ToolJSON {
        .object(["actions": .array(names.map { .object(["name": .string($0), "input": .object([:])]) })])
    }

    private static func prependingNavigation(_ url: String, to batch: ToolJSON) -> ToolJSON {
        guard case let .array(actions)? = batch["actions"] else { return batch }
        let navigate: ToolJSON = .object(["name": .string(AgentToolCatalog.navigate),
                                          "input": .object(["url": .string(url)])])
        return .object(["actions": .array([navigate] + actions)])
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

@MainActor
private final class RecordingApprovals: AgentToolApprovalHandling {
    var policy: AgentToolCallerPolicy?
    var answer: Bool
    /// The allow chosen on a card that offers several; nil answers as `answer` does, with the narrowest allow.
    var chosen: String?
    /// The answers each such card offered, by id.
    var offered: [[String]] = []
    /// The ports the caller's task listens on.
    var listeningPorts: Set<Int> = []
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

    /// When set, each question waits on a real card there, which the test answers or cancels.
    var center: SessionToolCenter?

    func askPerson(title: String, detail: String, callerID: UUID) async -> Bool {
        titles.append(title)
        details.append(detail)
        guard let center else { return answer }
        return await center.ask(PermissionRequest(id: UUID().uuidString, title: title, detail: detail, command: nil),
                                in: hostTaskID, onChange: {})
    }

    func askPerson(title: String, detail: String, actions: [PermissionRequestAction], callerID: UUID) async -> String? {
        titles.append(title)
        details.append(detail)
        offered.append(actions.map(\.id))
        guard answer else { return nil }
        return chosen ?? PermissionActionPreference.preferred(from: actions, decision: .allow)?.id
    }

    func taskListens(on port: Int, callerID: UUID) async -> Bool {
        listeningPorts.contains(port)
    }
}

@MainActor
private final class ApprovalConnectors: ConnectorToolProviding {
    private let facts: [String: ConnectorToolFacts] = [
        "gmail_search": .init(service: "Gmail", title: "Search", readOnly: true),
        "gmail_send": .init(service: "Gmail", title: "Send", readOnly: false, account: "me@example.test"),
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

@MainActor
private final class ApprovalSimulators: SimulatorToolHandling {
    var simulatorSwitchIsOn: Bool { true }
    var simulatorPlatformIsUsable: Bool { true }
    var calls: [String] = []

    func callSimulatorTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
        calls.append(name)
        return .text("ok")
    }
}
