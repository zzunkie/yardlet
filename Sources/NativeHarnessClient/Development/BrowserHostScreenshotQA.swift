#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// QA for the agent's screenshots of tabs no panel shows (docs/AGENT_BROWSER_TOOLS.md), against the real browser host,
/// run by `run-check.sh … --ui-fixture-browser-check-only=screenshot --ui-fixture-browser-agent-visible=3`. The agent's
/// calls go through the Yardlet MCP broker for the task the QA window shows. Each step leaves the tab as an agent's tab
/// is left between its calls: scrolled after a single-page app's history navigations, hidden once the agent's window
/// passed, hidden while Chromium is told memory is critical, shown in the task's panel and the panel closed, and a
/// second tab used in turn. Each screenshot must come back with the page in it, well before the tool's 30 seconds.
@MainActor
final class BrowserHostScreenshotQA {
    private let output: URL
    private let base: String
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var token = ""

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        let first = await call(AgentToolCatalog.navigate, ["url": .string(base + "tall")])
        check("the agent's tab loads", !first.isError, first.text)
        let tab = client.tab(forSession: session)
        await shoot("a new tab")

        _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll)])
        await shoot("after history navigations and a scroll")

        await idle(tab)
        _ = await call(AgentToolCatalog.evaluate, ["function": .string("() => scrollY")])
        await shoot("hidden, then used again")

        await idle(tab)
        await dropHiddenDrawing(tab)
        await shoot("hidden while memory was critical")

        await idle(tab)
        _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll)])
        await shoot("hidden, then navigated and scrolled")

        if await openPanel() {
            await closePanel()
            await idle(tab)
            await shoot("shown in the panel, the panel closed, then hidden")
            await idle(tab)
            await dropHiddenDrawing(tab)
            _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll)])
            await shoot("shown in the panel, then hidden while memory was critical")
        }

        // Other tasks' tabs hide after this one, so Chromium keeps their last frames and lets this tab's go.
        var others: [BrowserTab] = []
        for index in 0..<12 {
            if let other = try? client.openTab(forSession: UUID(), url: base + "tall?other=\(index)",
                                               viewport: .offscreenDefault, byAgent: true) { others.append(other) }
        }
        try? await Task.sleep(for: .seconds(4))
        await idle(tab)
        _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll)])
        await shoot("hidden while other tasks' tabs hid after it")

        // A size the agent set goes back when its turn ends, while the tab is hidden.
        _ = await call(AgentToolCatalog.resize, ["width": .integer(1000), "height": .integer(1320)])
        await idle(tab)
        broker.taskTurnEnded(session)
        try? await Task.sleep(for: .seconds(1))
        await idle(tab)
        _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll)])
        await shoot("resized back while hidden at the turn's end")

        // The engine hides the tab while Yardlet takes it as shown: a hidden view draws no frame for the capture.
        _ = await call(AgentToolCatalog.evaluate, ["function": .string("() => scrollY")])
        if let tab { tab.send(.visibility(tab: tab.id, isHidden: true)) }
        try? await Task.sleep(for: .seconds(1))
        await shoot("the engine hid the tab while Yardlet took it as shown")

        let second = await call(AgentToolCatalog.tabNew)
        let secondID = second.structuredContent?["tabId"]?.stringValue ?? Self.tabID(in: second.text)
        if let secondID {
            _ = await call(AgentToolCatalog.navigate, ["url": .string(base + "tall?second"), "tabId": .string(secondID)])
            await shoot("a second tab", tabID: secondID)
            await idle(nil)
            if let firstID = tab.map({ String($0.id) }) {
                _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll), "tabId": .string(firstID)])
                await shoot("the first tab again, both hidden meanwhile", tabID: firstID)
            }
            _ = await call(AgentToolCatalog.evaluate, ["function": .string(Self.navigateAndScroll), "tabId": .string(secondID)])
            await shoot("the second tab again", tabID: secondID)
        } else {
            check("a second tab opens", false, second.text)
        }
        await finish()
    }

    // MARK: Steps

    /// What an agent's page script does on a single-page app: history navigations, each followed by an event the app
    /// renders on, and then a scroll to a section.
    private static let navigateAndScroll = """
        async () => { for (let i = 0; i < 6; i++) { history.pushState({}, '', '/tall?step=' + i); \
        dispatchEvent(new PopStateEvent('popstate')); await new Promise(r => setTimeout(r, 150)); } \
        scrollTo(0, 1600); scrollBy(0, -70); return scrollY; }
        """

    /// The agent leaves the tab alone past its window (`--ui-fixture-browser-agent-visible`): the tab hides.
    private func idle(_ tab: BrowserTab?) async {
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(2))
        if let tab { record["hidden-\(checks.count)"] = .bool(!tab.isShown) }
    }

    /// What Chromium drops of a hidden page's drawing when memory is short, told directly rather than as the agent.
    private func dropHiddenDrawing(_ tab: BrowserTab?) async {
        _ = try? await tab?.devTools.send("Memory.simulatePressureNotification", ["level": .string("critical")],
                                          timeout: .seconds(5))
        try? await Task.sleep(for: .seconds(1))
    }

    private func shoot(_ step: String, tabID: String? = nil) async {
        let started = ContinuousClock.now
        var arguments: [String: ToolJSON] = ["format": .string("jpeg")]
        if let tabID { arguments["tabId"] = .string(tabID) }
        let shot = await call(AgentToolCatalog.screenshot, arguments)
        let took = ContinuousClock.now - started
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let image = shot.content.contains { if case .image = $0 { true } else { false } }
        check("screenshot: \(step)", !shot.isError && image && seconds < 10,
              String(format: "%.2f s, ", seconds) + shot.text)
    }

    // MARK: Panel

    private func openPanel() async -> Bool {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        let opened = await waitUntil(.seconds(10)) { BrowserHostPaneController.current !== previous
            && BrowserHostPaneController.current?.view?.viewSurface != nil }
        check("the task's panel shows the agent's tab", opened, "panel \(BrowserHostPaneController.current != nil)")
        return opened
    }

    private func closePanel() async {
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        _ = await waitUntil(.seconds(5)) { BrowserHostPaneController.current?.hasTab != true }
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: Calls

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
    }

    private static func tabID(in text: String) -> String? {
        text.range(of: #"tab(Id)?\D{0,4}(\d+)"#, options: .regularExpression)
            .map { String(text[$0]).filter(\.isNumber) }
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    // MARK: Record

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}
#endif
