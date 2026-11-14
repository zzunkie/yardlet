import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A tab whose page does not respond (2026-10-23, the ERP review's tab whose renderer stayed busy):
/// Chromium's hang monitor and a DevTools call its renderer did not answer both say so, the person
/// gets Chrome's Wait and a Reload, and the agent's tools say what is known and which tools act on the tab.
@MainActor
final class BrowserUnresponsiveTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        /// Answers DevTools calls with an empty result, as an idle page does; a busy page answers none.
        var answers = false
        /// Calls an answering page still leaves unanswered, as a promise that never settles leaves `awaitPromise`.
        var withholds: (String) -> Bool = { _ in false }
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            guard answers, case .devTools(let tab, let message) = command, !withholds(message),
                  let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: #"{"id":\#(id),"result":{}}"#)) }
            }
        }
        func terminate() {}
    }

    private let connection = FakeConnection()
    private func makeClient() -> BrowserHostClient {
        let client = BrowserHostClient(idleGrace: .seconds(60)) { [unowned self] in self.connection }
        // Long enough for a page that answers, on a CI runner too; a busy page waits it out.
        client.rendererCheckWait = .milliseconds(500)
        return client
    }

    /// Both signals mark the page and what clears it; Wait waits and Reload replaces the tab under the
    /// same side-panel tab; the panel's header says one state, Not responding first.
    func testAPageThatDoesNotRespondUntilItAnswersAndWaitOrReloadKeepItsTab() async throws {
        let client = makeClient()
        let task = UUID()
        let workspace = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        var heard = 0
        _ = client.addTabsObserver(forSession: task) { heard += 1 }
        let first = try client.newTab(forSession: task, url: "https://a.test/", viewport: .offscreenDefault, select: false)
        let stuck = try client.newTab(forSession: task, url: "https://b.test/", viewport: .offscreenDefault, select: true)
        let third = try client.newTab(forSession: task, url: "https://c.test/", viewport: .offscreenDefault, select: false)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.browserTabID(stuck.key),
                                                                    in: workspace.panels))
        let panels = workspace.panels

        // Chromium's hang monitor (read by the host), heard by the panel and the side panel's tab.
        heard = 0
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        XCTAssertEqual(stuck.unresponsive, .hangMonitor)
        XCTAssertEqual(heard, 1)
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: true))
        XCTAssertNil(stuck.unresponsive)

        // A call the browser answers itself says nothing of the page; one its renderer answers does, when the call
        // the renderer answers at once right after goes unanswered too, until an answer comes.
        _ = try? await stuck.devTools.send("Page.navigate", ["url": .string("https://b.test/x")], timeout: .milliseconds(30))
        XCTAssertNil(stuck.unresponsive)
        let renderer = await stuck.rendererAnswered(after: "Page.navigate")
        XCTAssertNil(renderer, "nothing was checked")
        _ = try? await stuck.devTools.send("Runtime.evaluate", ["expression": .string("1")], timeout: .milliseconds(30))
        let busy = await stuck.rendererAnswered(after: "Runtime.evaluate")
        XCTAssertEqual(busy, false)
        XCTAssertEqual(stuck.unresponsive, .unanswered(method: "Runtime.evaluate"))
        connection.answers = true
        _ = try await stuck.devTools.send("DOM.getDocument", [:], timeout: .seconds(2))
        XCTAssertNil(stuck.unresponsive, "the page answers again")
        // A call that awaits the page's promise is late while the renderer answers the check: the page responds.
        connection.withholds = { $0.contains(#""awaitPromise":true"#) }
        _ = try? await stuck.devTools.send("Runtime.evaluate", ["expression": .string("new Promise(() => {})"),
                                                                "awaitPromise": .bool(true)], timeout: .milliseconds(30))
        let late = await stuck.rendererAnswered(after: "Runtime.evaluate")
        XCTAssertEqual(late, true)
        XCTAssertNil(stuck.unresponsive, "a late promise is no page that does not respond")
        connection.withholds = { _ in false }
        connection.answers = false

        // A renderer that ended crashed (a failed CHECK traps); it is no longer a page that does not
        // respond, and a load starts another renderer.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.eventHandler?(.pageCrashed(tab: stuck.id, reason: "SIGTRAP", status: "crashed", code: 5))
        XCTAssertNil(stuck.unresponsive)
        XCTAssertEqual(stuck.crash, BrowserTabCrash(status: "crashed", code: 5, errorCode: "SIGTRAP"))
        connection.eventHandler?(.loading(tab: stuck.id, isLoading: true, canGoBack: true, canGoForward: false))
        XCTAssertNil(stuck.crash)

        // Wait tells the hang monitor and hides it for 15 seconds, as Chrome's Wait.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.sent = []
        client.waitForPage(stuck)
        XCTAssertEqual(connection.sent, [.unresponsive(tab: stuck.id, action: .wait)])
        XCTAssertNil(stuck.unresponsive)

        // Reload: the renderer the hang monitor holds ends, and the tab opens again in its place, in
        // front, under the same side-panel tab, and is no closed tab to reopen.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.sent = []
        let replacement = try client.replace(stuck, url: "https://b.test/")
        XCTAssertEqual(connection.sent.prefix(2), [.unresponsive(tab: stuck.id, action: .terminate), .close(tab: stuck.id)])
        XCTAssertTrue(stuck.isClosed)
        XCTAssertEqual(replacement.key, stuck.key)
        XCTAssertEqual(client.tabs(forSession: task).map(\.id), [first.id, replacement.id, third.id])
        XCTAssertTrue(client.tab(forSession: task) === replacement)
        XCTAssertEqual(workspace.panels, panels)
        XCTAssertNil(try client.reopenClosedTab(forSession: task, viewport: .offscreenDefault))

        // The header's one state.
        typealias Pane = BrowserHostPaneController
        XCTAssertEqual(Pane.status(isUnresponsive: true, isCrashed: true, hasError: true, isLoading: true, hasTab: true),
                       L10n.string("Not responding"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, isCrashed: true, hasError: true, isLoading: true, hasTab: true),
                       L10n.string("Crashed"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: true, isLoading: true, hasTab: true), L10n.string("Unavailable"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: false, isLoading: true, hasTab: true), L10n.string("Loading"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: false, isLoading: false, hasTab: true), L10n.string("Ready"))
        XCTAssertNil(Pane.status(isUnresponsive: false, hasError: false, isLoading: false, hasTab: false))
    }

    func testTheAgentHearsItsTabIsNotRespondingAndBrowserNavigateOpensItAgain() async throws {
        let client = makeClient()
        let task = UUID()
        let tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { client })
        tools.commandTimeout = .milliseconds(80)
        tools.loadTimeout = .milliseconds(120)
        func text(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }

        // The page's main thread is busy: nothing it runs answers, while the browser still answers what it answers
        // itself (the tab's history, which a late call's error reads).
        connection.answers = true
        connection.withholds = { !$0.contains("Page.getNavigationHistory") }
        let busy = await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                   sessionID: task)
        let tab = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertTrue(busy.isError)
        XCTAssertTrue(text(busy).contains("This tab's page is not responding: its renderer did not answer Page.enable in time, "
                                          + "nor a call it answers at once right after."), text(busy))
        XCTAssertFalse(text(busy).contains("main thread"), "only what was checked")
        XCTAssertTrue(text(busy).contains("browser_navigate opens a page again in its place; browser_tab_close closes the tab."))
        XCTAssertFalse(text(busy).localizedCaseInsensitiveContains("should"), "facts and tools, no instructions")
        let listing = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(listing.contains(#""responding":false"#), listing)
        XCTAssertTrue(listing.contains("Not responding: tab \(tab.id)"), listing)

        // browser_navigate opens the page again in the stuck one's place.
        connection.withholds = { _ in false }
        let moved = await tools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string("https://app.test/")]),
                                    sessionID: task)
        let replacement = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertFalse(replacement === tab)
        XCTAssertEqual(replacement.key, tab.key)
        XCTAssertTrue(text(moved).hasPrefix("Tab \(tab.id)'s page was not responding"), text(moved))
        XCTAssertTrue(text(moved).contains(#"as tabId "\#(replacement.id)""#))
        let after = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(after.contains(#""responding":true"#), after)
        XCTAssertFalse(after.contains("Not responding"))

        // The old id reaches the tab opened in its place, in a batch too, and the result says so.
        let old = String(tab.id)
        let viaOld = text(await tools.run(tool: AgentToolCatalog.batch, arguments: .object(["actions": .array([
            .object(["name": .string(AgentToolCatalog.evaluate), "input": .object(["function": .string("() => 1"), "tabId": .string(old)])])
        ])]), sessionID: task))
        XCTAssertTrue(viaOld.contains("1. browser_evaluate: Tab \(old) is now tab \(replacement.id): its page was not responding, "
                                      + "and it was opened again in its place"), viaOld)

        // A function whose promise does not settle is late on a page that answers everything else: no page that does
        // not respond, and the result says what was found.
        connection.withholds = { $0.contains(#""awaitPromise":true"#) }
        let pendingResult = await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
            "function": .string("() => new Promise(() => {})")]), sessionID: task)
        let pending = text(pendingResult)
        connection.withholds = { _ in false }
        XCTAssertEqual(pendingResult.failure?.kind, .outcomeUnknown, "the function may still finish in the page")
        XCTAssertEqual(pendingResult.failure?.retry, .afterChecking)
        XCTAssertTrue(pending.contains("The function did not finish within 0.1 seconds. The page answered another call right "
                                       + "after, so its renderer is not stuck"), pending)
        XCTAssertFalse(pending.contains("not responding"), pending)
        XCTAssertNil(replacement.unresponsive)

        // Its renderer ends: the same facts, the error code and the same tools.
        connection.eventHandler?(.pageCrashed(tab: replacement.id, reason: "SIGTRAP", status: "crashed", code: 5))
        let crashed = text(await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                           sessionID: task))
        XCTAssertTrue(crashed.contains("This tab's page crashed: its renderer ended (error code SIGTRAP)."), crashed)
        XCTAssertFalse(crashed.localizedCaseInsensitiveContains("should"))
        let crashList = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(crashList.contains("Crashed: tab \(replacement.id) (SIGTRAP)"), crashList)
        XCTAssertFalse(crashList.contains("Not responding"))
    }

    /// A tab the host could not open (2026-10-27: the host held 16 browsers, and the tabs past them stayed open blank
    /// tabs that answered "The browser tab is gone."): the tab knows why, calls fail at once with the reason, the tab
    /// list says so, the panel's card says it plainly, and browser_navigate opens the tab again in its place.
    func testATabTheHostCouldNotOpenSaysWhyAndOpensAgainInItsPlace() async throws {
        let client = makeClient()
        let task = UUID()
        let tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { client })
        tools.commandTimeout = .milliseconds(200)
        tools.loadTimeout = .milliseconds(120)
        func text(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
        let reason = "The browser already has 256 tabs open across tasks, its most; closing a tab in this or another task "
            + "makes room for this one"
        let tab = try client.openTab(forSession: task, url: "about:blank", viewport: .offscreenDefault)
        let other = try client.newTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault, select: false)
        connection.eventHandler?(.failed(message: reason, tab: tab.id, limit: 256))
        connection.eventHandler?(.failed(message: "The browser host could not start"))
        XCTAssertEqual(tab.openFailure, BrowserTabOpenFailure(message: reason, limit: 256))
        XCTAssertNil(other.openFailure, "a failure of the whole host opened no tab less")
        XCTAssertEqual(BrowserHostPaneController.message(for: tab.openFailure!),
                       L10n.string("The browser has too many tabs open. Close a tab in this or another task, then try again."))

        // Nothing waits on a tab without a page: the call fails at once and never reaches the host.
        connection.sent = []
        let started = ContinuousClock.now
        let refused = await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                      sessionID: task)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(text(refused).hasPrefix("This tab could not open: \(reason). It has no page."), text(refused))
        XCTAssertFalse(text(refused).contains("not running"), "the browser runs; only this tab has no page")
        XCTAssertFalse(connection.sent.contains { if case .devTools = $0 { true } else { false } })
        let listing = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(listing.contains(#""responding":false"#), listing)
        XCTAssertTrue(listing.contains("Could not open: tab \(tab.id) (\(reason))"), listing)
        XCTAssertFalse(listing.contains("Not responding"), listing)

        // browser_navigate opens it again under the same side-panel tab.
        connection.answers = true
        let moved = await tools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string("https://app.test/")]),
                                    sessionID: task)
        let replacement = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertFalse(replacement === tab)
        XCTAssertEqual(replacement.key, tab.key)
        XCTAssertNil(replacement.openFailure)
        XCTAssertTrue(text(moved).hasPrefix(#"Tab \#(tab.id) could not open (\#(reason)); the tab was opened again in its place as tabId "\#(replacement.id)"."#),
                      text(moved))
    }
}
