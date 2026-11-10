import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The tab tools list, open, front and close a task's tabs, and every page tool takes the tab it acts
/// on, as the Claude app's Browser pane tools (`tabs_context`, `tabs_create`, `tabs_select`,
/// `tabs_close`, and `tabId` on the others) do.
@MainActor
final class BrowserAgentTabToolsTests: XCTestCase {
    private final class FakeHostConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        /// Answers every CDP command with an empty result, as an idle page does.
        var answersDevTools = false
        /// Answers each CDP command with the result this gives for its tab and method, when set.
        var answer: (@MainActor (BrowserTabID, String) -> JSONValue)?
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            guard case .devTools(let tab, let message) = command,
                  let request = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)),
                  let id = request["id"]?.integerValue else { return }
            let result: JSONValue
            if let answer {
                result = MainActor.assumeIsolated { answer(tab, request["method"]?.stringValue ?? "") }
            } else if answersDevTools {
                result = .object([:])
            } else {
                return
            }
            let reply = String(decoding: (try? JSONEncoder().encode(JSONValue.object(["id": .integer(id), "result": result]))) ?? Data(),
                               as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: reply)) }
            }
        }
        func terminate() {}
    }

    private let connection = FakeHostConnection()
    private var client: BrowserHostClient!
    private var tools: BrowserAgentTools!
    private var tabs: BrowserAgentTabs!
    private let task = UUID()

    override func setUp() async throws {
        let connection = connection
        client = BrowserHostClient(idleGrace: .seconds(60)) { connection }
        client.rendererCheckWait = .milliseconds(50)
        let client = client!
        tabs = BrowserAgentTabs { client }
        tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: tabs)
    }

    private func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
        await tools.run(tool: tool, arguments: .object(arguments), sessionID: task)
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    private func listing() async throws -> JSONValue {
        let result = await run(AgentToolCatalog.tabList)
        XCTAssertFalse(result.isError)
        let json = try XCTUnwrap(text(result).split(separator: "\n").first)
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testTheCatalogOffersTheTabToolsAndATabOnEveryPageTool() {
        XCTAssertEqual(AgentToolCatalog.tabToolNames,
                       ["browser_tab_list", "browser_tab_new", "browser_tab_select", "browser_tab_close"])
        for tool in AgentToolCatalog.browserTools where !AgentToolCatalog.tabToolNames.contains(tool.name) && tool.name != AgentToolCatalog.batch {
            XCTAssertNotNil(tool.inputSchema["properties"]?["tabId"], "\(tool.name) takes a tabId")
        }
        XCTAssertTrue(AgentToolCatalog.batchableNames.contains(AgentToolCatalog.tabNew), "a batch can open and switch tabs")
        XCTAssertEqual(AgentToolCatalog.definition(named: AgentToolCatalog.tabList)?.readOnly, true)
    }

    func testListingNewSelectingAndClosingTabs() async throws {
        let empty = try await listing()
        XCTAssertEqual(empty["tabs"]?.arrayValue?.count, 0)
        let emptyText = text(await run(AgentToolCatalog.tabList))
        XCTAssertTrue(emptyText.contains("no browser tab yet"))

        // The first page tool opens the task's tab, as before.
        let first = try BrowserAgentTabs { [client] in client }.page(for: task, tabID: nil)
        connection.eventHandler?(.address(tab: first.tabID, url: "https://example.com/private/path?q=1"))

        let opened = await run(AgentToolCatalog.tabNew)
        XCTAssertFalse(opened.isError)
        XCTAssertTrue(text(opened).contains("behind the active tab"))
        let tabs = client.tabs(forSession: task)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(client.tab(forSession: task)?.id, first.tabID, "background by default")

        let list = try await listing()
        XCTAssertEqual(list["panelOpen"]?.boolValue, false)
        XCTAssertEqual(list["tabs"]?.arrayValue?.first?["origin"]?.stringValue, "https://example.com", "origin only")
        XCTAssertEqual(list["tabs"]?.arrayValue?.first?["isActive"]?.boolValue, true)
        XCTAssertEqual(list["tabs"]?.arrayValue?.last?["origin"]?.stringValue, "about:blank")
        let closedPanel = text(await run(AgentToolCatalog.tabList))
        XCTAssertTrue(closedPanel.contains("panel is closed"))

        let second = String(tabs[1].id)
        // A result that names a tab gives its origin too: the person sees the page's title and site, never a tab id.
        let selected = await run(AgentToolCatalog.tabSelect, ["tabId": .string(second)])
        XCTAssertEqual(text(selected), "Tab \(second) (about:blank) is now the active tab.")
        XCTAssertTrue(client.tab(forSession: task) === tabs[1])

        let foreground = await run(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        XCTAssertTrue(text(foreground).contains("It is the active tab"))
        XCTAssertTrue(client.tab(forSession: task) === client.tabs(forSession: task).last)

        let closedID = String(client.tabs(forSession: task)[2].id)
        let closed = await run(AgentToolCatalog.tabClose, ["tabId": .string(closedID)])
        XCTAssertEqual(text(closed), "Closed tab \(closedID) (about:blank). Tab \(second) (about:blank) is now the active tab.")

        // A tab that is gone says how it went and lists the task's tabs; no other tab is picked for it.
        let firstID = String(client.tabs(forSession: task)[0].id)
        let tabsNow = "This task's tabs now: \(firstID) (https://example.com), \(second) (about:blank, active)."
        let missing = await run(AgentToolCatalog.tabSelect, ["tabId": .string("999")])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(text(missing), "This task has no tab 999, and no tab of this task has had that id since Yardlet started. "
                       + tabsNow)
        XCTAssertEqual(missing.failure, AgentToolFailure(.notFound, retry: .withChanges, details: [
            "tabId": .string("999"), "tabs": .array([.string(firstID), .string(second)])
        ]))
        let gone = await run(AgentToolCatalog.snapshot, ["tabId": .string(closedID)])
        XCTAssertEqual(text(gone), "Tab \(closedID) is closed: browser_tab_close closed it. " + tabsNow)
        // The mailbox's panel is no task's: its pages (a sign-in link, an invoice) are not this task's to list or close.
        let otherTasksTab = try client.openTab(forSession: TaskWorkspaceStore.mailID, url: "about:blank", viewport: .offscreenDefault)
        let withMail = try await listing()
        XCTAssertEqual(withMail["tabs"]?.arrayValue?.count, 2, "the agent's list leaves the mailbox's tab out")
        let foreign = await run(AgentToolCatalog.tabClose, ["tabId": .string(String(otherTasksTab.id))])
        XCTAssertTrue(foreign.isError, "another panel's tab is not this task's to close")
        XCTAssertTrue(text(foreign).hasPrefix("This task has no tab \(otherTasksTab.id)"), text(foreign))
        XCTAssertFalse(otherTasksTab.isClosed)

        // The browser host ends: a tool that names a tab's old id opens the task's tabs again and reaches that tab
        // under its new id, saying so.
        connection.eventHandler?(.terminated(reason: "crashed"))
        XCTAssertTrue(client.tabs(forSession: task).isEmpty)
        let reopened = await run(AgentToolCatalog.tabSelect, ["tabId": .string(firstID)])
        XCTAssertFalse(reopened.isError, text(reopened))
        let now = try XCTUnwrap(client.tabs(forSession: task).first)
        XCTAssertNotEqual(String(now.id), firstID)
        XCTAssertTrue(text(reopened).hasPrefix("Tab \(firstID) is now tab \(now.id): the browser host ended, and it was opened "
                                               + "again in its place as the same tab of the task's browser panel."), text(reopened))
        XCTAssertTrue(text(reopened).contains("Tab \(now.id) (about:blank) is now the active tab"), text(reopened))
    }

    func testAPageToolActsOnTheTabItNames() async throws {
        _ = await run(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        _ = await run(AgentToolCatalog.tabNew)
        let tabs = client.tabs(forSession: task)
        let background = tabs[1]
        connection.sent = []
        // No CDP answers come in this test; the first command (enabling Page) times out quickly.
        tools.commandTimeout = .milliseconds(50)
        _ = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com"), "tabId": .string(String(background.id))])
        let devTools = connection.sent.compactMap { if case .devTools(let tab, let message) = $0 { (tab, message) } else { nil } }
        XCTAssertFalse(devTools.isEmpty)
        XCTAssertTrue(devTools.allSatisfy { $0.0 == background.id }, "the named background tab, not the active one")
        XCTAssertTrue(connection.sent.contains(.visibility(tab: background.id, isHidden: false)) || background.isShown,
                      "a background tab the agent drives paints")
    }

    func testABatchCanOpenATabAndActInIt() async throws {
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string(AgentToolCatalog.tabNew), "input": .object(["foreground": .bool(true)])]),
            .object(["name": .string(AgentToolCatalog.tabList), "input": .object([:])])
        ])])
        XCTAssertFalse(result.isError, text(result))
        XCTAssertTrue(text(result).contains("1. browser_tab_new"))
        XCTAssertTrue(text(result).contains("2. browser_tab_list"))
        XCTAssertEqual(client.tabs(forSession: task).count, 1)
    }

    func testTheTabLimitComesBackAsAToolError() async {
        for _ in 0..<BrowserHostClient.maxTabsPerSession { _ = await run(AgentToolCatalog.tabNew) }
        let tenth = await run(AgentToolCatalog.tabNew)
        XCTAssertTrue(tenth.isError)
        XCTAssertTrue(text(tenth).contains("already has 9 browser tabs"), text(tenth))
    }

    func testOriginsKeepOnlySchemeHostAndPort() {
        XCTAssertEqual(BrowserAgentTabs.origin(of: "http://localhost:3000/app?x=1"), "http://localhost:3000")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "about:blank"), "about:blank")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "data:text/html,hi"), "data:")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "file:///Users/me/a.html"), "file:")
    }

    // MARK: Chromium's passkey dialog

    func testAToolSaysAPasskeyDialogWaitsAndTheAgentCanCloseIt() async throws {
        let page = try BrowserAgentTabs { [client] in client }.page(for: task, tabID: nil)
        connection.answersDevTools = true
        func closes() -> [BrowserHostCommand] {
            connection.sent.filter { if case .closeChromiumWindows = $0 { true } else { false } }
        }
        func inputSent(since count: Int) -> Bool {
            connection.sent.dropFirst(count).contains { if case .devTools(_, let message) = $0 { message.contains("\"Input.") } else { false } }
        }
        // Another task's page asked for a passkey (or the person did, in that task's panel): its window is over that
        // task's tab, so this task's agent neither hears of it nor closes it.
        let other = try BrowserAgentTabs { [client] in client }.page(for: UUID(), tabID: nil)
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["패스키"], kinds: ["passkey"], ids: [9], tabs: [other.tabID]))
        let quiet = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertFalse(quiet.contains("passkey"), quiet)
        let notOurs = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertTrue(text(notOurs).contains("No JavaScript dialog is open"), text(notOurs))
        XCTAssertTrue(closes().isEmpty, "another task's window stays open")
        let unblocked = text(await run(AgentToolCatalog.click, ["x": .number(10), "y": .number(10)]))
        XCTAssertFalse(unblocked.contains("was not sent"), "another task's window is over its own tab: \(unblocked)")

        // This page asked for a passkey on this device; Chromium says there is none and waits for "Close".
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["패스키", "패스키 없음"], kinds: ["passkey", "passkey"],
                                                 ids: [9, 10], tabs: [other.tabID, page.tabID]))
        let listed = text(await run(AgentToolCatalog.tabList))
        XCTAssertFalse(listed.contains("passkey dialog"), "the tab tools do not act on a page")
        let consoleResult = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertTrue(consoleResult.contains("passkey dialog “패스키 없음” is open over tab \(page.tabID)"), consoleResult)
        XCTAssertFalse(consoleResult.contains("“패스키”"), "only this task's window: \(consoleResult)")
        XCTAssertTrue(consoleResult.contains("browser_handoff shows the tab to the person"), consoleResult)
        XCTAssertTrue(consoleResult.contains("browser_handle_dialog with accept false"), consoleResult)

        // Input to the tab under the window would be dropped: it is not sent, and the tool fails saying why and what
        // comes next. Reading the page still works.
        let sentBefore = connection.sent.count
        let refusedClick = await run(AgentToolCatalog.click, ["x": .number(10), "y": .number(10)])
        XCTAssertTrue(refusedClick.isError)
        XCTAssertTrue(text(refusedClick).hasPrefix("The click was not sent to tab \(page.tabID). Chromium's passkey dialog “패스키 없음”"),
                      text(refusedClick))
        XCTAssertTrue(text(refusedClick).contains("browser_handle_dialog with accept false closes it"), text(refusedClick))
        XCTAssertTrue(text(refusedClick).contains("browser_handoff shows the tab to the person"), text(refusedClick))
        for (tool, arguments) in [(AgentToolCatalog.type, ["ref": JSONValue.string("@e1"), "text": .string("x")]),
                                  (AgentToolCatalog.pressKey, ["key": .string("Enter")]), (AgentToolCatalog.scroll, [:])] {
            let refused = await run(tool, arguments)
            XCTAssertTrue(refused.isError && text(refused).contains("was not sent to tab \(page.tabID)"), "\(tool): \(text(refused))")
        }
        XCTAssertFalse(inputSent(since: sentBefore), "no input reaches the tab")
        let read = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(text(read).contains("was not sent"), text(read))

        let accept = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(accept.isError, "only the person can complete a passkey request")
        XCTAssertTrue(closes().isEmpty)

        let close = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertFalse(close.isError, text(close))
        XCTAssertTrue(text(close).contains("NotAllowedError"))
        XCTAssertEqual(closes(), [.closeChromiumWindows(tabs: [page.tabID])], "the host closes this task's window alone")

        connection.eventHandler?(.chromiumWindow(isShown: false, titles: nil))
        XCTAssertTrue(client.chromiumWindowTitles.isEmpty)

        // A site's sign-in window for HTTP authentication is named as one, not as a passkey dialog.
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["로그인"], kinds: ["signIn"], ids: [11], tabs: [page.tabID]))
        let signIn = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertTrue(signIn.contains("sign-in window for the site's HTTP authentication “로그인” is open"), signIn)
        XCTAssertFalse(signIn.contains("passkey"), signIn)

        // The print dialog runs without a tab: no task's agent closes it, and it is mentioned only when a tool fails.
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["Print"], kinds: ["print"], ids: [12], tabs: [-1]))
        let unmentioned = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertFalse(unmentioned.contains("print dialog"), unmentioned)
        let printing = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertTrue(text(printing).contains("No JavaScript dialog is open"), text(printing))
        XCTAssertTrue(text(printing).contains("which tab opened it is not known"), text(printing))
        XCTAssertEqual(closes().count, 1, "no agent closes a window whose tab is not known")
        connection.eventHandler?(.chromiumWindow(isShown: false, titles: nil))
    }

    // MARK: The task's page across turns

    /// A page the agent loaded is still there at its next turn: the agent idle past every window, the
    /// panel opened and closed, and the next tool call reaches the same tab without opening another.
    /// Before 2026-10-22 an unwatched tab closed five minutes and a minute after the agent's last use
    /// and the next call opened a new about:blank tab (the Meta sign-in page that "went blank").
    /// The tab the person uses is theirs (docs/AGENT_BROWSER_TOOLS.md, section 2, "The tab the person uses"): while they use it in the
    /// panel, the agent's new tab in front and its choice of another tab stay behind it, the tools without a tabId go to
    /// the agent's own tab, and a tool on the person's tab says that they use it. Once they stop, the panel follows the
    /// agent again.
    func testThePanelStaysOnTheTabThePersonIsUsing() async throws {
        let connection = connection
        connection.answersDevTools = true
        let client = BrowserHostClient(personUseWindow: .seconds(2)) { connection }
        let tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { client })
        let task = task
        func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> String {
            text(await tools.run(tool: tool, arguments: .object(arguments), sessionID: task))
        }
        let person = try client.openTab(forSession: task, url: "https://example.com", viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: person.id, url: "https://example.com/inbox"))
        client.attachPanel(to: person)
        person.send(.mouse(tab: person.id, input: BrowserMouseInput(kind: .down, x: 10, y: 10, button: .left)))

        let opened = await run(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        let own = try XCTUnwrap(client.tabs(forSession: task).last)
        XCTAssertTrue(client.tab(forSession: task) === person, "the panel keeps the person's tab")
        XCTAssertTrue(client.agentTab(forSession: task) === own)
        XCTAssertTrue(opened.contains("stays on tab \(person.id) (https://example.com), which the person is using"), opened)
        connection.sent = []
        let read = await run(AgentToolCatalog.consoleMessages)
        let calls = connection.sent.compactMap { if case .devTools(let tab, _) = $0 { tab } else { nil } }
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0 == own.id }, "a tool without a tabId acts on the agent's own tab")
        XCTAssertFalse(read.contains("The person is using this tab"), read)
        let onTheirs = await run(AgentToolCatalog.consoleMessages, ["tabId": .string(String(person.id))])
        XCTAssertTrue(onTheirs.contains("The person is using this tab") && onTheirs.contains("browser_handoff"), onTheirs)
        let selected = await run(AgentToolCatalog.tabSelect, ["tabId": .string(String(own.id))])
        XCTAssertTrue(client.tab(forSession: task) === person && selected.contains("your active tab"), selected)

        try await Task.sleep(for: .milliseconds(2300))
        _ = await run(AgentToolCatalog.tabSelect, ["tabId": .string(String(own.id))])
        XCTAssertTrue(client.tab(forSession: task) === own, "once the person stops, the panel follows the agent")
    }

    func testThePageTheAgentLoadedIsThereAtItsNextTurn() async throws {
        let connection = connection
        let client = BrowserHostClient(idleGrace: .milliseconds(30), agentVisibleWindow: .milliseconds(20)) { connection }
        let tabs = BrowserAgentTabs { client }
        let first = try tabs.page(for: task, tabID: nil)
        connection.eventHandler?(.address(tab: first.tabID, url: "https://www.facebook.com/login/"))
        try await Task.sleep(for: .milliseconds(200))
        let tab = try XCTUnwrap(client.tab(forSession: task))
        client.attachPanel(to: tab)
        client.detachPanel(from: tab)
        try await Task.sleep(for: .milliseconds(200))
        let opensBefore = connection.sent.filter { if case .open = $0 { true } else { false } }.count

        let next = try tabs.page(for: task, tabID: nil)
        XCTAssertTrue(next === first, "the same page object, so the same tab")
        XCTAssertEqual(client.tab(forSession: task)?.currentURL, "https://www.facebook.com/login/")
        XCTAssertFalse(tab.isClosed)
        XCTAssertEqual(connection.sent.filter { if case .open = $0 { true } else { false } }.count, opensBefore,
                       "no new tab between turns")
        XCTAssertTrue(client.isHostRunning)
    }

    /// A fill asks the person first wherever a script the agent ran may still reach the document, through the windows a
    /// page opened and their openers (docs/BROWSER_VAULT_DESIGN.md §5.3): a window the script opened, while it ran or
    /// after; a document such a window or its opener loads while the other shows one; and that also once the tab that
    /// ran the script left or closed, or the tab that linked two others closed. A new document with no such tab linked
    /// fills as before.
    func testAFillAsksFirstWhereAScriptTheAgentRanMayReachThroughLinkedWindows() async throws {
        let item = VaultItem(name: "Example", sites: ["example.com"], username: "ada", policy: .always)
        var asked = 0
        tools.vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct-horse-battery")]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            confirm: { _ in asked += 1; return false }, defaults: .vaultTests()))
        // Each tab's document (its main frame's loaderId), and what the agent's next script does in the page.
        var documents: [BrowserTabID: String] = [:]
        var duringScript: @MainActor () -> Void = {}
        connection.answer = { tab, method in
            switch method {
            case "Page.getFrameTree":
                return .object(["frameTree": .object(["frame": .object([
                    "id": .string("main-\(tab)"), "loaderId": .string(documents[tab] ?? "\(tab)-blank"),
                    "url": .string("https://www.example.com/login"), "securityOrigin": .string("https://www.example.com")
                ])])])
            case "Runtime.evaluate":
                let script = duringScript
                DispatchQueue.main.async { MainActor.assumeIsolated { script() } }
                return .object(["result": .object(["type": .string("number"), "value": .integer(1)])])
            case "Page.createIsolatedWorld":
                return .object(["executionContextId": .integer(7)])
            case "DOM.resolveNode":
                return .object(["object": .object(["objectId": .string("field")])])
            case "Runtime.callFunctionOn":
                return .object(["result": .object(["type": .string("boolean"), "value": .bool(true)])])
            default:
                return .object([:])
            }
        }
        func load(_ tab: BrowserTabID, _ document: String) {
            documents[tab] = document
            connection.eventHandler?(.newDocument(tab: tab, url: "https://www.example.com/login"))
        }
        func script(in tab: BrowserTabID, session: UUID) async {
            let result = await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
                "function": .string("() => 1"), "tabId": .string(String(tab))]), sessionID: session)
            XCTAssertFalse(result.isError, text(result))
            duringScript = {}
        }
        /// Fills the tab's sign-in, and says whether the person was asked first.
        func fillAsks(_ tab: BrowserTabID, session: UUID) async throws -> Bool {
            let page = try tabs.page(for: session, tabID: String(tab))
            page.replaceRefs(["@e1": .init(node: 3, session: nil)], eventMark: page.cdp.eventLog.count)
            let before = asked
            let result = await tools.run(tool: VaultToolCatalog.fillCredential, arguments: .object([
                "ref": .string("@e1"), "tabId": .string(String(tab))]), sessionID: session)
            guard asked > before else { return false }
            XCTAssertTrue(result.isError && text(result).contains("ran your own scripts"), text(result))
            return true
        }

        // The script opens a window (`window.open` keeps the opener) and can reach what it loads.
        let opener = try tabs.page(for: task, tabID: nil).tabID
        load(opener, "opener-1")
        let popup: BrowserTabID = 1 << 30
        duringScript = { [connection] in
            connection.eventHandler?(.popupOpened(tab: popup, opener: opener, url: "https://www.example.com/login", background: false))
        }
        await script(in: opener, session: task)
        XCTAssertTrue(client.tabs(forSession: task).contains { $0.id == popup }, "the window opened while the script ran")
        load(popup, "popup-1")
        let inScriptWindow = try await fillAsks(popup, session: task)
        XCTAssertTrue(inScriptWindow, "a window the script opened")
        // A window it opens once it has returned (a timer, within the click's activation).
        connection.eventHandler?(.newWindow(tab: opener, url: "https://www.example.com/login", background: true, userGesture: true))
        let later = try XCTUnwrap(client.tabs(forSession: task).first { ![opener, popup].contains($0.id) }).id
        load(later, "later-1")
        let afterScriptWindow = try await fillAsks(later, session: task)
        XCTAssertTrue(afterScriptWindow, "a window it opened after it returned")
        // Code it left in the window stays when the tab that ran it moves on, and that tab can reach the window again.
        load(opener, "opener-2")
        let afterOpenerLeft = try await fillAsks(popup, session: task)
        XCTAssertTrue(afterOpenerLeft, "the window after the tab that ran the script moved on")
        let openerAgain = try await fillAsks(opener, session: task)
        XCTAssertTrue(openerAgain, "the opener's next document, which the window's code can reach")
        // Closing the tab between two windows the script opened leaves them linked.
        connection.eventHandler?(.closed(tab: opener))
        load(popup, "popup-2")
        let afterOpenerClosed = try await fillAsks(popup, session: task)
        XCTAssertTrue(afterOpenerClosed, "the other window it opened still reaches this one")
        connection.eventHandler?(.closed(tab: later))
        load(popup, "popup-3")
        let alone = try await fillAsks(popup, session: task)
        XCTAssertFalse(alone, "no tab that a script reached links to the window any more")

        // A script in a window the person opened reaches its opener's next document.
        let other = UUID()
        let signIn = try tabs.page(for: other, tabID: nil).tabID
        load(signIn, "sign-in-1")
        let window: BrowserTabID = (1 << 30) + 1
        connection.eventHandler?(.popupOpened(tab: window, opener: signIn, url: "https://www.example.com/help", background: false))
        load(window, "window-1")
        await script(in: window, session: other)
        load(signIn, "sign-in-2")
        let openerOfScriptedWindow = try await fillAsks(signIn, session: other)
        XCTAssertTrue(openerOfScriptedWindow, "the opener's next document")
    }
}
