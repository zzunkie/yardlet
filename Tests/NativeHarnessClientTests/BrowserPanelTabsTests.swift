import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Each of a task's browser tabs is a tab of its side panel, as in the Codex app (docs/BROWSER_HOST.md, section 3, "Tabs"):
/// the panel's rules for them, a panel saved when one Browser tab held them, the panel and the browser
/// engine keeping the same tabs, and the panel's tab strip drawn light and dark into
/// `.build/browser-panel-tabs-render/`.
@MainActor
final class BrowserPanelTabsTests: XCTestCase {
    private typealias Navigation = TaskSurfaceNavigationProjection

    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        private var open: [BrowserTabID] = []
        /// Tabs whose pages ask before they are left, as a page with a beforeunload handler does.
        var asksBeforeLeaving: Set<BrowserTabID> = []
        /// Tabs closed in the host, in order.
        private(set) var closedTabs: [BrowserTabID] = []
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            switch command {
            case .open(let tab, _, _, _): open.append(tab)
            case .close(let tab): close(tab, reporting: false)
            // As the host: a page that asks puts its leave-page question, any other closes and says so.
            case .requestClose(let tab) where asksBeforeLeaving.contains(tab):
                eventHandler?(.javaScriptDialog(tab: tab, dialog: BrowserJavaScriptDialog(
                    id: tab * 10, kind: .beforeUnload, message: "", defaultPrompt: "", origin: "", isReload: false)))
            case .requestClose(let tab): close(tab, reporting: true)
            case .javaScriptDialogResult(let tab, _, true, _) where asksBeforeLeaving.contains(tab): close(tab, reporting: true)
            // As the host's `shutdown`: it closes every tab, each reporting `closed`, before it exits.
            case .shutdown: open.forEach { eventHandler?(.closed(tab: $0)) }
            default: break
            }
        }
        private func close(_ tab: BrowserTabID, reporting: Bool) {
            guard open.contains(tab) else { return }
            open.removeAll { $0 == tab }
            closedTabs.append(tab)
            if reporting { eventHandler?(.closed(tab: tab)) }
        }
        func terminate() { eventHandler?(.terminated(reason: "signal 15")) }
    }

    private var connection = FakeConnection()

    private func makeClient() -> BrowserHostClient {
        BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(80)) { [unowned self] in
            self.connection = FakeConnection()
            return self.connection
        }
    }

    private func id(_ key: UUID) -> String { Navigation.browserTabID(key) }

    private func closed() -> [BrowserTabID] {
        connection.closedTabs
    }

    // MARK: - The panel's rules

    func testABrowserTabIsASidePanelTabOfItsOwn() throws {
        let key = UUID()
        XCTAssertEqual(Navigation.browserKey(inTab: id(key)), key)
        XCTAssertNil(Navigation.browserKey(inTab: "browser"), "the + menu's Browser is no tab")
        XCTAssertNil(Navigation.browserKey(inTab: "browser:not-a-key"))
        XCTAssertTrue(Navigation.isTab(id(key)))
        XCTAssertFalse(Navigation.isTab("browser"))
        XCTAssertEqual(Navigation.placement(for: id(key)), .trailing)

        // ⌘4: a new tab when the task has none, the panel hides on a browser tab, and from another tab
        // the browser tab used last shows.
        let first = UUID(), second = UUID()
        var state = Navigation.toggledPanelState(current: .init(), targetID: "browser", newBrowserKey: first)
        XCTAssertEqual(state.trailingSurfaceID, id(first))
        state = Navigation.showingNewBrowserTab(second, after: nil, in: state)
        state = Navigation.showing("diff", in: state)
        XCTAssertEqual(state.trailingTabs, [id(first), id(second), "diff"])
        XCTAssertEqual(Navigation.toggledPanelState(current: state, targetID: "browser").trailingSurfaceID, id(second))
        let onBrowser = Navigation.showing(id(first), in: state)
        XCTAssertNil(Navigation.toggledPanelState(current: onBrowser, targetID: "browser").trailingSurfaceID)

        // New Tab to the Right and Duplicate go right after their tab.
        let right = UUID()
        state = Navigation.showingNewBrowserTab(right, after: id(first), in: state)
        XCTAssertEqual(state.trailingTabs, [id(first), id(right), id(second), "diff"])
        XCTAssertEqual(state.trailingSurfaceID, id(right))

        // A tab the agent or a page opens joins after the browser tab before it, without showing.
        let agent = UUID()
        state = Navigation.addingBrowserTab(agent, after: second, in: state)
        XCTAssertEqual(state.trailingTabs, [id(first), id(right), id(second), id(agent), "diff"])
        XCTAssertEqual(state.trailingSurfaceID, id(right))
        let unanchored = Navigation.addingBrowserTab(UUID(), after: nil, in: Navigation.showing("files", in: .init()))
        XCTAssertEqual(unanchored.trailingTabs.first, "files", "with no browser tab yet, at the end")
        XCTAssertEqual(unanchored.trailingSurfaceID, "files")

        // The browser fronting a tab: a panel showing a browser tab shows it; one showing Review keeps
        // Review and ⌘4 returns to the fronted tab; a hidden panel shows it when it opens again.
        XCTAssertEqual(Navigation.frontingBrowserTab(agent, in: state).trailingSurfaceID, id(agent))
        let review = Navigation.frontingBrowserTab(agent, in: Navigation.showing("diff", in: state))
        XCTAssertEqual(review.trailingSurfaceID, "diff")
        XCTAssertEqual(Navigation.latestBrowserTab(in: review), id(agent))
        let hidden = Navigation.frontingBrowserTab(agent, in: Navigation.hidingTrailing(state))
        XCTAssertNil(hidden.trailingSurfaceID)
        XCTAssertEqual(Navigation.reopenedTrailingTab(in: hidden), id(agent))

        // A tab's menu closes several tabs by the rule for one.
        XCTAssertEqual(Navigation.otherTabs(than: id(second), in: state), [id(first), id(right), id(agent), "diff"])
        XCTAssertEqual(Navigation.tabs(rightOf: id(second), in: state), [id(agent), "diff"])
        let closedRight = Navigation.closingTrailingTabs(Navigation.tabs(rightOf: id(first), in: state), in: state)
        XCTAssertEqual(closedRight.trailingTabs, [id(first)])
        XCTAssertEqual(closedRight.trailingSurfaceID, id(first))
        XCTAssertNil(Navigation.closingTrailingTabs(state.trailingTabs, in: state).trailingSurfaceID,
                     "the last tab closing hides the panel, a browser tab as any other")
    }

    // MARK: - A panel saved when one Browser tab held the task's browser tabs

    func testAnOldBrowserTabBecomesOneSidePanelTabPerBrowserTabOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("BrowserPanelTabsTests")))
        let repository = UserDefaultsTaskWorkspaceRepository(defaults: defaults)
        let several = UUID(), one = UUID(), closedBrowser = UUID()
        func save(_ json: String, for id: UUID) {
            defaults.set(Data(json.utf8), forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        }
        // As a build before side-panel browser tabs saved them (`panelsRevision` 2).
        save(#"""
        {"version":1,"panelsRevision":2,
         "panels":{"trailingSurfaceID":"browser","isTerminalPresented":false,
                   "trailingTabs":["diff","browser","files"],"recentTrailingTabs":["browser","files","diff"]},
         "layout":{"panelWidth":420,"terminalHeight":280,"isExpanded":false},
         "transcript":{"fraction":0,"followsLatest":true},"codex":{"fraction":0,"followsLatest":true},
         "browser":{"address":"https://b.test/","tabs":["https://a.test/","https://b.test/","https://c.test/"],"selectedTab":1}}
        """#, for: several)
        save(#"""
        {"version":1,"panelsRevision":2,
         "panels":{"isTerminalPresented":false,"trailingTabs":["browser"],"recentTrailingTabs":["browser"]},
         "layout":{"panelWidth":420,"terminalHeight":280,"isExpanded":false},
         "transcript":{"fraction":0,"followsLatest":true},"codex":{"fraction":0,"followsLatest":true},
         "browser":{"address":"https://one.test/"}}
        """#, for: one)
        save(#"""
        {"version":1,"panelsRevision":2,
         "panels":{"isTerminalPresented":false,"trailingTabs":["diff"],"recentTrailingTabs":["diff"]},
         "layout":{"panelWidth":420,"terminalHeight":280,"isExpanded":false},
         "transcript":{"fraction":0,"followsLatest":true},"codex":{"fraction":0,"followsLatest":true},
         "browser":{"address":"https://gone.test/"}}
        """#, for: closedBrowser)

        let store = TaskWorkspaceStore(repository: repository)
        let state = store.state(for: several)
        let keys = Navigation.browserKeys(in: state.panels)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(state.panels.trailingTabs, ["diff"] + keys.map(id) + ["files"], "where Browser was, in order")
        XCTAssertEqual(state.panels.trailingSurfaceID, id(keys[1]), "the tab in front shows where Browser showed")
        XCTAssertEqual(state.panels.recentTrailingTabs, [id(keys[1]), "files", "diff", id(keys[0]), id(keys[2])])
        XCTAssertEqual(keys.map { state.browserTabs.tab($0)?.address }, ["https://a.test/", "https://b.test/", "https://c.test/"])
        XCTAssertEqual(TaskSidePanelTabs.browserTab(keys[0], in: state.browserTabs).title, "a.test",
                       "a page not loaded yet is named by its host")

        let lone = store.state(for: one)
        let loneKeys = Navigation.browserKeys(in: lone.panels)
        XCTAssertEqual(loneKeys.count, 1)
        XCTAssertEqual(lone.browserTabs.tab(loneKeys[0])?.address, "https://one.test/")
        XCTAssertEqual(store.state(for: closedBrowser).panels.trailingTabs, ["diff"],
                       "a Browser tab closed before stays closed")

        // Saved under the new rules, it reads back the same, once.
        store.persistNow()
        let saved = try XCTUnwrap(repository.load(for: several))
        XCTAssertEqual(saved.panelsRevision, TaskWorkspaceSnapshot.browserTabsPanelsRevision)
        XCTAssertEqual(saved.browser?.pages?.map(\.key), keys)
        XCTAssertEqual(saved.browser?.tabs, ["https://a.test/", "https://b.test/", "https://c.test/"],
                       "a build before side-panel browser tabs still finds the pages")
        XCTAssertEqual(saved.browser?.selectedTab, 1)
        let restarted = TaskWorkspaceStore(repository: repository).state(for: several)
        XCTAssertEqual(restarted.panels, state.panels)
    }

    // MARK: - The panel and the engine have the same tabs

    func testThePanelAndTheEngineKeepTheSameTabs() throws {
        let client = makeClient()
        let task = UUID()
        let store = TaskWorkspaceStore(browserClient: { client })
        let state = store.state(for: task)

        // The launcher's Browser: a panel tab, which opens in the engine when its pane shows it.
        let first = try XCTUnwrap(state.openBrowserTab())
        XCTAssertEqual(state.panels.trailingSurfaceID, id(first))
        XCTAssertTrue(client.tabs(forSession: task).isEmpty, "nothing opens until the pane shows it")
        let firstTab = try XCTUnwrap(try state.openBrowserEngineTab(first, viewport: .offscreenDefault))
        XCTAssertEqual(firstTab.key, first)
        XCTAssertTrue(client.tab(forSession: task) === firstTab)
        connection.eventHandler?(.address(tab: firstTab.id, url: "https://first.test/"))
        connection.eventHandler?(.title(tab: firstTab.id, title: "First"))
        XCTAssertEqual(TaskSidePanelTabs.browserTab(first, in: state.browserTabs).title, "First")

        // The agent opens a tab behind: it joins the panel after the first, which stays shown.
        let agentTab = try client.newTab(forSession: task, url: "https://agent.test/", viewport: .offscreenDefault,
                                         select: false)
        XCTAssertEqual(state.panels.trailingTabs, [id(first), id(agentTab.key)])
        XCTAssertEqual(state.panels.trailingSurfaceID, id(first))
        connection.eventHandler?(.loading(tab: agentTab.id, isLoading: true, canGoBack: false, canGoForward: false))
        connection.eventHandler?(.favicon(tab: agentTab.id, url: "https://agent.test/icon.png", png: Data([9])))
        XCTAssertEqual(state.browserTabs.tab(agentTab.key)?.isLoading, true)
        XCTAssertEqual(state.browserTabs.tab(agentTab.key)?.favicon, Data([9]))

        // The panel shows Review; the agent fronts its tab (browser_tab_select): Review stays, and ⌘4
        // returns to the agent's tab.
        state.setPanels(Navigation.showing("diff", in: state.panels))
        agentTab.select()
        XCTAssertEqual(state.panels.trailingSurfaceID, "diff")
        state.setPanels(Navigation.toggledPanelState(current: state.panels, targetID: "browser"))
        XCTAssertEqual(state.panels.trailingSurfaceID, id(agentTab.key))

        // Showing a tab fronts it for the agent's tools; the agent fronting one shows it.
        state.setPanels(Navigation.showing(id(first), in: state.panels))
        XCTAssertTrue(client.tab(forSession: task) === firstTab, "the tab the panel shows is the agent's default")
        agentTab.select()
        XCTAssertEqual(state.panels.trailingSurfaceID, id(agentTab.key))

        // The agent closes the tab shown (browser_tab_close): the panel shows the tab the engine fronted.
        agentTab.close()
        XCTAssertEqual(state.panels.trailingTabs, [id(first), "diff"])
        XCTAssertEqual(state.panels.trailingSurfaceID, id(first))
        XCTAssertNil(state.browserTabs.tab(agentTab.key))

        // A tab closed from the panel closes its page; the panel goes to the tab used before (Review),
        // not to a browser neighbor.
        let third = try XCTUnwrap(state.openBrowserTab())
        let thirdTab = try XCTUnwrap(try state.openBrowserEngineTab(third, viewport: .offscreenDefault))
        state.setPanels(Navigation.showing("diff", in: state.panels))
        state.setPanels(Navigation.showing(id(third), in: state.panels))
        XCTAssertEqual(closed(), [agentTab.id])
        state.closeSidePanelTabs([id(third)])
        XCTAssertEqual(closed(), [agentTab.id, thirdTab.id])
        XCTAssertEqual(state.panels.trailingSurfaceID, "diff")
        XCTAssertEqual(state.panels.trailingTabs, [id(first), "diff"], "the closed tab does not come back")
        XCTAssertNil(client.tab(key: third, forSession: task))

        // A page that asks before it is left keeps its tab while it asks, as Chrome's "Leave site?" does: Cancel
        // keeps the tab and its page, Leave closes both and the panel goes to the tab used before.
        let asking = try XCTUnwrap(state.openBrowserTab())
        let askingTab = try XCTUnwrap(try state.openBrowserEngineTab(asking, viewport: .offscreenDefault))
        connection.asksBeforeLeaving.insert(askingTab.id)
        state.closeSidePanelTabs([id(asking)])
        XCTAssertEqual(state.panels.trailingSurfaceID, id(asking), "the tab stays while its page asks")
        let question = try XCTUnwrap(askingTab.closeQuestion)
        askingTab.send(.javaScriptDialogResult(tab: askingTab.id, dialog: question.id, accepted: false, text: nil))
        XCTAssertEqual(state.panels.trailingSurfaceID, id(asking), "Cancel keeps the tab")
        XCTAssertTrue(client.tab(key: asking, forSession: task) === askingTab)
        state.closeSidePanelTabs([id(asking)])
        let again = try XCTUnwrap(askingTab.closeQuestion, "the page asks again at the next close")
        askingTab.send(.javaScriptDialogResult(tab: askingTab.id, dialog: again.id, accepted: true, text: nil))
        XCTAssertEqual(state.panels.trailingTabs, [id(first), "diff"])
        XCTAssertEqual(state.panels.trailingSurfaceID, "diff")
        XCTAssertNil(client.tab(key: asking, forSession: task))
        XCTAssertEqual(closed(), [agentTab.id, thirdTab.id, askingTab.id])

        // Close Other Tabs from Review's menu closes the browser tab's page too.
        state.closeSidePanelTabs(Navigation.otherTabs(than: "diff", in: state.panels))
        XCTAssertEqual(state.panels.trailingTabs, ["diff"])
        XCTAssertTrue(client.tabs(forSession: task).isEmpty)
        XCTAssertEqual(closed(), [agentTab.id, thirdTab.id, askingTab.id, firstTab.id])

        // ⌘⇧T opens the closed tab again as a new panel tab.
        try state.reopenClosedBrowserTab(viewport: .offscreenDefault)
        let reopened = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertEqual(state.panels.trailingTabs, ["diff", id(reopened.key)])
        XCTAssertNotEqual(reopened.key, first)

        // Nine tabs at most, as before.
        while Navigation.browserKeys(in: state.panels).count < BrowserHostClient.maxTabsPerSession {
            XCTAssertNotNil(state.openBrowserTab())
        }
        XCTAssertNil(state.openBrowserTab(), "a tenth does not open")
    }

    /// The launcher and a new tab's start page offer the pages a task's tabs showed (docs/BROWSER_HOST.md, section 3,
    /// "Start page"): closed tabs first, then pages the tabs moved on from, none a tab shows; never an address that
    /// carries a value the vault filled; saved with the task; and with "Suggest pages on new tabs" off, nothing.
    func testATasksTabsOfferThePagesTheyShowedAgain() throws {
        let client = makeClient()
        client.carriesFilledValue = { $0.contains("hunter22") }
        let repository = InMemoryTaskWorkspaceRepository()
        let task = UUID()
        let store = TaskWorkspaceStore(repository: repository, browserClient: { client })
        let state = store.state(for: task)
        let first = try XCTUnwrap(state.openBrowserTab())
        let firstTab = try XCTUnwrap(try state.openBrowserEngineTab(first, viewport: .offscreenDefault))
        for page in ["https://docs.test/start", "https://docs.test/guide", "https://bank.test/login?password=hunter22"] {
            connection.eventHandler?(.address(tab: firstTab.id, url: page))
        }
        connection.eventHandler?(.title(tab: firstTab.id, title: "Guide"))
        let second = try XCTUnwrap(state.openBrowserTab())
        let secondTab = try XCTUnwrap(try state.openBrowserEngineTab(second, viewport: .offscreenDefault))
        connection.eventHandler?(.address(tab: secondTab.id, url: "https://me:pw@issues.test/42"))
        connection.eventHandler?(.title(tab: secondTab.id, title: "Issue 42"))
        state.closeSidePanelTabs([id(second)])
        let offered = state.browserTabs.suggestedPages(limit: 6)
        XCTAssertEqual(offered.map(\.address), ["https://issues.test/42", "https://docs.test/start"],
                       "the closed tab first, then the page the open tab moved on from; not the page it shows")
        XCTAssertEqual(offered.map(\.title), ["Issue 42", ""])
        XCTAssertNotNil(offered[0].closed)
        XCTAssertFalse(state.browserTabs.visited.contains { $0.address.contains("hunter22") || $0.address.contains("pw@") })

        // Opened again, a closed page is a page a tab shows; another task has its own.
        let third = try XCTUnwrap(state.openBrowserTab(address: "https://issues.test/42"))
        let thirdTab = try XCTUnwrap(try state.openBrowserEngineTab(third, viewport: .offscreenDefault))
        connection.eventHandler?(.address(tab: thirdTab.id, url: "https://issues.test/42"))
        XCTAssertEqual(state.browserTabs.suggestedPages(limit: 6).map(\.address), ["https://docs.test/start"])
        XCTAssertNil(state.browserTabs.visited.first { $0.address == "https://issues.test/42" }?.closed)
        XCTAssertTrue(store.state(for: UUID()).browserTabs.suggestedPages(limit: 6).isEmpty)

        // Saved with the task, and read back with it.
        store.persistNow()
        let saved = try XCTUnwrap(repository.snapshots[task]?.browser?.visited)
        XCTAssertEqual(saved.map(\.address), state.browserTabs.visited.map(\.address))
        XCTAssertEqual(TaskWorkspaceState(snapshot: try XCTUnwrap(repository.snapshots[task])).browserTabs.visited, saved)

        // Turned off: nothing is kept or offered, and the task's next save drops what it kept.
        UserDefaults.yardlet.set(false, forKey: BrowserPageSuggestionPreference.key)
        defer { UserDefaults.yardlet.removeObject(forKey: BrowserPageSuggestionPreference.key) }
        connection.eventHandler?(.address(tab: firstTab.id, url: "https://docs.test/later"))
        XCTAssertFalse(state.browserTabs.visited.contains { $0.address == "https://docs.test/later" })
        XCTAssertTrue(state.browserTabs.suggestedPages(limit: 6).isEmpty)
        store.persistNow()
        XCTAssertNil(repository.snapshots[task]?.browser?.visited)
        XCTAssertNotNil(repository.snapshots[task]?.browser?.pages, "the tabs themselves stay")
    }

    func testTabsLostWithTheHostStayAsTabsAndComeBackTogether() throws {
        let client = makeClient()
        let task = UUID()
        let state = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        let first = try XCTUnwrap(state.openBrowserTab(address: "https://a.test/"))
        let firstTab = try XCTUnwrap(try state.openBrowserEngineTab(first, viewport: .offscreenDefault))
        let second = try XCTUnwrap(state.openBrowserTab(address: "https://b.test/"))
        let secondTab = try XCTUnwrap(try state.openBrowserEngineTab(second, viewport: .offscreenDefault))
        connection.eventHandler?(.address(tab: firstTab.id, url: "https://a.test/"))
        connection.eventHandler?(.address(tab: secondTab.id, url: "https://b.test/"))
        let panels = state.panels

        connection.eventHandler?(.terminated(reason: "crashed"))
        XCTAssertEqual(state.panels, panels, "the panel keeps the tabs the host lost")

        // Showing one opens them all again under their keys, the one shown in front.
        state.setPanels(Navigation.showing(id(first), in: state.panels))
        let shown = try XCTUnwrap(try state.openBrowserEngineTab(first, viewport: .offscreenDefault))
        XCTAssertEqual(client.tabs(forSession: task).map(\.key), [first, second])
        XCTAssertTrue(client.tab(forSession: task) === shown)
        XCTAssertEqual(state.panels.trailingTabs, panels.trailingTabs)
    }

    func testTabsSavedBeforeARestartAreTheTabsTheAgentFinds() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("BrowserPanelTabsTests")))
        let repository = UserDefaultsTaskWorkspaceRepository(defaults: defaults)
        let task = UUID()
        let before = makeClient()
        let store = TaskWorkspaceStore(repository: repository, browserClient: { before })
        let state = store.state(for: task)
        let first = try XCTUnwrap(state.openBrowserTab(address: "https://a.test/"))
        let blank = try XCTUnwrap(state.openBrowserTab())
        let second = try XCTUnwrap(state.openBrowserTab(address: "https://b.test/"))
        // Showing one opens the saved pages together and the agent opens another: all three are open in
        // the engine as Yardlet quits, and its host closes them on its way out. They are lost with the
        // host, not closed, and saved as the task's tabs (2026-10-25, the panel lost them).
        let shown = try XCTUnwrap(try state.openBrowserEngineTab(first, viewport: .offscreenDefault))
        connection.eventHandler?(.address(tab: shown.id, url: "https://a.test/next"))
        let agentTab = try before.newTab(forSession: task, url: "https://c.test/", viewport: .offscreenDefault,
                                         select: false)
        connection.eventHandler?(.address(tab: agentTab.id, url: "https://c.test/"))
        let panels = state.panels
        before.terminateHost()
        XCTAssertEqual(state.panels, panels, "quitting keeps the panel's tabs")
        store.persistNow()
        let c = agentTab.key

        // Yardlet starts again: the panel's tabs are there, with no page open yet.
        let after = makeClient()
        let restarted = TaskWorkspaceStore(repository: repository, browserClient: { after })
        let tabs = BrowserAgentTabs { after }
        tabs.prepareSession = { _ = restarted.state(for: $0) }
        let restored = restarted.state(for: task)
        XCTAssertEqual(restored.panels, panels)
        XCTAssertEqual(Navigation.browserKeys(in: restored.panels), [first, blank, second, c])
        XCTAssertEqual(after.rememberedTabs(forSession: task)?.keys, [first, second, c],
                       "the pages the panel saved wait for the engine, a blank tab has none")
        XCTAssertEqual(after.rememberedTabs(forSession: task)?.addresses,
                       ["https://a.test/next", "https://b.test/", "https://c.test/"], "each at the page it showed")
        XCTAssertTrue(after.tabs(forSession: task).isEmpty)

        // The agent's first call opens them, the one used last in front: listing them too, so the ids
        // it lists are ones the other tools take.
        let list = try tabs.tabs(for: task)
        XCTAssertEqual(list.tabs.count, 3)
        XCTAssertEqual(after.tabs(forSession: task).map(\.key), [first, second, c])
        _ = try tabs.page(for: task, tabID: list.tabs[0].id)
        XCTAssertEqual(after.tab(forSession: task)?.key, second)
        XCTAssertEqual(Navigation.browserKeys(in: restored.panels), [first, blank, second, c], "the same panel tabs")

        // The blank tab opens when shown, between the first two.
        _ = try restored.openBrowserEngineTab(blank, viewport: .offscreenDefault)
        XCTAssertEqual(after.tabs(forSession: task).map(\.key), [first, blank, second, c])
    }

    func testTheNewTaskScreensTabsAreTheTasksSamePanelTabs() throws {
        let client = makeClient()
        let store = TaskWorkspaceStore(browserClient: { client })
        let draft = store.draft
        let first = try XCTUnwrap(draft.openBrowserTab(address: "https://a.test/"))
        let firstTab = try XCTUnwrap(try draft.openBrowserEngineTab(first, viewport: .offscreenDefault))
        let second = try XCTUnwrap(draft.openBrowserTab())
        _ = try draft.openBrowserEngineTab(second, viewport: .offscreenDefault)
        let panels = draft.panels
        let sent = connection.sent.count

        let task = UUID()
        store.handOffDraft(to: task)
        client.moveTabs(fromSession: TaskWorkspaceStore.draftID, toSession: task)
        let state = store.state(for: task)
        XCTAssertEqual(state.panels, panels)
        XCTAssertEqual(client.tabs(forSession: task).map(\.key), [first, second])
        XCTAssertTrue(client.tab(forSession: task)?.key == second)
        XCTAssertTrue(firstTab.session == task)
        XCTAssertEqual(state.browserTabs.tab(first)?.address, "https://a.test/")
        XCTAssertEqual(draft.panels, .init(), "the new-task screen starts over")
        XCTAssertEqual(connection.sent.count, sent, "nothing reaches the host; the pages go on")
    }

    // MARK: - Drawn

    /// The launcher's Browser opens a blank tab with its address field ready. As in Chrome, a field the
    /// person has not typed in follows the page another opens there (the agent's browser_navigate); one
    /// they typed in keeps their text.
    func testANewTabsAddressFieldFollowsThePageUntilThePersonTypes() throws {
        let client = makeClient()
        let task = UUID()
        let workspace = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        let key = try XCTUnwrap(workspace.openBrowserTab())
        let controller = BrowserHostPaneController(session: task, key: key, workspace: workspace, client: client)
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { withExtendedLifetime(window) {} }
        controller.attach(view)
        let tab = try XCTUnwrap(client.tab(key: key, forSession: task))
        XCTAssertTrue(controller.isEditingAddress)
        XCTAssertEqual(controller.addressInput, "")

        connection.eventHandler?(.address(tab: tab.id, url: "http://localhost:3100/erp/review"))
        XCTAssertEqual(controller.addressInput, "http://localhost:3100/erp/review", "before, it stayed empty")
        XCTAssertTrue(controller.isEditingAddress, "still focused")

        controller.addressInput = "github.com/y"
        connection.eventHandler?(.address(tab: tab.id, url: "http://localhost:3100/erp/list"))
        XCTAssertEqual(controller.addressInput, "github.com/y", "what the person typed stays")
        controller.isEditingAddress = false
        connection.eventHandler?(.address(tab: tab.id, url: "http://localhost:3100/erp/next"))
        XCTAssertEqual(controller.addressInput, "http://localhost:3100/erp/next")
    }

    /// The pane shows the tab the panel shows however quickly the panel changes: it follows the
    /// workspace itself. Through SwiftUI's `onChange(of:)`, which runs once a frame, a second change
    /// before the window drew again left the pane on a tab the panel had left (the browser QA's window,
    /// which is never drawn, hit it in most runs).
    func testThePaneFollowsThePanelWithoutTheWindowDrawing() async throws {
        let client = makeClient()
        let task = UUID()
        let workspace = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        let first = try XCTUnwrap(workspace.openBrowserTab())
        let controller = BrowserHostPaneController(session: task, key: first, workspace: workspace, client: client)
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { withExtendedLifetime(window) {} }
        controller.attach(view)

        // The agent opens a tab in front and closes it, then ⌘T, with nothing drawn in between.
        let agentTab = try client.newTab(forSession: task, url: "https://agent.test/", viewport: .offscreenDefault,
                                         select: true)
        agentTab.close()
        let second = try XCTUnwrap(workspace.openBrowserTab())
        for _ in 0..<1000 where controller.key != second { await Task.yield() }
        XCTAssertEqual(controller.key, second)
        XCTAssertTrue(controller.tab === client.tab(key: second, forSession: task))
        XCTAssertTrue(controller.isEditingAddress, "a new tab's address field is ready")
    }

    func testTheStripShowsEachBrowserTabWithItsTitleAndIcon() throws {
        let directory = try WindowlessRender.directory("browser-panel-tabs-render")
        let tabs = TaskBrowserTabs()
        let keys = (0..<4).map { _ in UUID() }
        tabs.update(keys[0], address: "https://github.com/example/yardlet", title: "example/yardlet",
                    favicon: Self.icon(.systemPurple), isLoading: false)
        tabs.update(keys[1], address: "http://localhost:3000/", title: "", favicon: nil, isLoading: false)
        tabs.update(keys[2], address: "https://example.com/", title: "Example Domain", favicon: nil, isLoading: true)
        tabs.update(keys[3], address: nil, title: "about:blank", favicon: nil, isLoading: false)
        let ids = keys.map(id)
        let titles = keys.map { TaskSidePanelTabs.browserTab($0, in: tabs).title }
        XCTAssertEqual(titles, ["example/yardlet", "localhost", "Example Domain", L10n.string("New tab")])
        let review = try XCTUnwrap(TaskSidePanelTabs.tab("diff", selectedFilePath: nil))
        let navigation = WorkSurfaceNavigation(
            tabs: [review] + keys.map { TaskSidePanelTabs.browserTab($0, in: tabs) },
            activeID: ids[0],
            choices: TaskSidePanelTabs.choices(canOpenSideChat: true),
            select: { _ in }, open: { _ in }, closeTab: { _ in }, closeTabs: { _ in }, closePanel: {},
            browserMenu: BrowserTabMenuActions(address: { _ in nil }, isOpen: { _ in true }, newTabToTheRight: { _ in },
                                               reload: { _ in }, duplicate: { _ in }))
        for appearance in WindowlessRender.Appearance.allCases {
            let header = WorkSurfaceHeader(title: titles[0], systemName: "globe", favicon: Self.icon(.systemPurple),
                                           workspaceURL: URL(filePath: "/tmp/yardlet"), status: L10n.string("Ready"),
                                           onClose: {}) { EmptyView() }
                .environment(\.workSurfaceNavigation, navigation)
                .frame(width: 760)
                .environment(\.colorScheme, appearance.colorScheme)
            let host = WindowlessRender.Host(header, size: NSSize(width: 760, height: 42), appearance: appearance)
            host.settle(passes: 10, interval: 0.02)
            try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "strip-\(appearance.suffix).png"))
            let labels = host.accessibilityElements().map(\.label)
            for title in titles.dropFirst() { XCTAssertTrue(labels.contains(title), "tab \(title): \(labels)") }
            XCTAssertTrue(labels.contains(L10n.string("Review")))
            host.close()
        }
    }

    /// A 32-pixel page icon.
    static func icon(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor.white.setFill()
            NSRect(x: 8, y: 13, width: 16, height: 6).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
