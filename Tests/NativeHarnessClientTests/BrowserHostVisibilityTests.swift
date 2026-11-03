import XCTest
@testable import NativeHarnessClient

/// A session tab paints only while a panel shows it or the agent used it recently.
@MainActor
final class BrowserHostVisibilityTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    private let connection = FakeConnection()

    private func makeClient(visibleWindow: Duration = .milliseconds(80)) -> BrowserHostClient {
        BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: visibleWindow) {
            [unowned self] in self.connection
        }
    }

    private func visibility(of tab: BrowserTab) -> [Bool] {
        connection.sent.compactMap { if case .visibility(let id, let hidden) = $0, id == tab.id { hidden } else { nil } }
    }

    private func wait(_ duration: Duration) async throws { try await Task.sleep(for: duration) }

    func testAgentTabIsHiddenAfterTheAgentStopsAndShownBeforeItsNextCommand() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        tab.noteAgentActivity()
        XCTAssertEqual(visibility(of: tab), [], "a new tab starts shown")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [true], "hidden once the agent is idle")

        tab.noteAgentActivity()
        tab.send(.devTools(tab: tab.id, message: "{}"))
        XCTAssertEqual(visibility(of: tab), [true, false])
        guard let shown = connection.sent.lastIndex(of: .visibility(tab: tab.id, isHidden: false)),
              let command = connection.sent.lastIndex(of: .devTools(tab: tab.id, message: "{}")) else {
            return XCTFail("missing commands")
        }
        XCTAssertLessThan(shown, command, "shown before the agent's command reaches the engine")
    }

    func testPanelKeepsTheTabShownAndClosingItHidesAnIdleTab() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        XCTAssertEqual(visibility(of: tab), [false], "attaching asks for a fresh frame")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false], "a panel keeps it shown past the agent window")
        client.detachPanel(from: tab)
        XCTAssertEqual(visibility(of: tab), [false, true])
        XCTAssertFalse(tab.isClosed, "hidden, not closed: the tab stays for the grace period")
    }

    /// A task's tab lost with the host leaves its page for the panel and the agent to open again.
    func testATabLostWithTheHostLeavesItsAddressForTheNextTab() throws {
        let client = makeClient()
        let session = UUID()
        let tab = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: tab.id, url: "https://www.facebook.com/login"))
        connection.eventHandler?(.address(tab: tab.id, url: "about:blank"))
        XCTAssertEqual(client.lastAddress(forSession: session), "https://www.facebook.com/login", "about:blank is no page")
        connection.eventHandler?(.terminated(reason: "crashed"))
        XCTAssertTrue(tab.isClosed)
        XCTAssertEqual(client.lastAddress(forSession: session), "https://www.facebook.com/login", "kept when the host ends")

        _ = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        XCTAssertNil(client.lastAddress(forSession: session), "a new tab for the task replaces what the host lost")
    }

    /// The memory saver (docs/BROWSER_HOST.md §3 "Memory saver"): a task's tab hidden past Chrome's time is offered to the host
    /// for discarding, once; a tab the person typed into, one downloading and one not on the web are not. A discarded tab
    /// loads its page again when a panel shows it, and turning the saver off brings the others back. Chrome's levels set
    /// the time and the revisits that keep a tab, and a tab the agent opened that no one saw goes sooner.
    func testTheMemorySaverDiscardsLongHiddenTabsAndAShownOneLoadsAgain() async throws {
        let client = makeClient(visibleWindow: .milliseconds(20))
        client.memorySaverTiming = BrowserMemorySaver.Timing(
            hiddenBeforeDiscard: .milliseconds(120), urgentInterval: .milliseconds(20), urgentProtection: .milliseconds(120),
            sweepInterval: .milliseconds(30), retryAfter: .seconds(60))
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "https://a.test/", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: session, url: "https://a.test/2", viewport: .offscreenDefault, select: false)
        let typed = try client.newTab(forSession: session, url: "https://a.test/form", viewport: .offscreenDefault, select: false)
        let downloading = try client.newTab(forSession: session, url: "https://a.test/file", viewport: .offscreenDefault, select: false)
        let blank = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        for tab in [first, second, typed, downloading] {
            connection.eventHandler?(.address(tab: tab.id, url: "https://a.test/\(tab.id)"))
        }
        typed.send(.key(tab: typed.id, input: BrowserKeyInput(kind: .character, windowsKeyCode: 65, nativeKeyCode: 0, character: 97)))
        connection.eventHandler?(.download(tab: downloading.id, download: BrowserDownload(
            id: 1, state: .inProgress, fileName: "a.zip", path: "/tmp/a.zip", receivedBytes: 1, totalBytes: 2)))
        client.isMemorySaverOn = true
        try await wait(.milliseconds(500))
        let asked = connection.sent.compactMap { if case .discard(let id, false) = $0 { id } else { nil } }
        XCTAssertEqual(asked.sorted(), [first.id, second.id], "only the long-hidden web pages, each asked once")
        XCTAssertFalse(asked.contains(blank.id))

        connection.eventHandler?(.discarded(tab: first.id))
        connection.eventHandler?(.discarded(tab: second.id))
        XCTAssertTrue(first.isDiscarded && second.isDiscarded)
        client.attachPanel(to: first)
        XCTAssertEqual(connection.sent.last, .navigation(tab: first.id, action: .reload), "a shown tab loads its page again")
        XCTAssertFalse(first.isDiscarded)
        client.isMemorySaverOn = false
        XCTAssertEqual(connection.sent.last, .navigation(tab: second.id, action: .reload), "turned off, the tabs are as before")
        XCTAssertFalse(second.isDiscarded)

        // Chrome's levels (MemorySaverModePolicy): 6, 4 and 2 hours hidden, and a tab the person brought in front more
        // than 5 or 15 times stays. Urgent discarding weighs neither.
        func hidden(_ seconds: Int, revisits: Int = 0) -> [BrowserMemorySaver.Candidate] {
            [BrowserMemorySaver.Candidate(tab: 1, hidden: .seconds(seconds), isProtected: false,
                                          isProtectedFromProactive: false, refusedRecently: false, revisits: revisits)]
        }
        let levels: [(BrowserMemorySaver.Level, hours: Int, revisits: Int)] = [(.moderate, 6, 5), (.balanced, 4, 15), (.maximum, 2, 15)]
        for (level, hours, revisits) in levels {
            XCTAssertEqual(BrowserMemorySaver.picks(hidden(hours * 3600 - 1), urgent: false, level: level), [], "\(level)")
            XCTAssertEqual(BrowserMemorySaver.picks(hidden(hours * 3600, revisits: revisits), urgent: false, level: level), [1], "\(level)")
            XCTAssertEqual(BrowserMemorySaver.picks(hidden(hours * 3600, revisits: revisits + 1), urgent: false, level: level), [],
                           "\(level)")
        }
        XCTAssertEqual(BrowserMemorySaver.picks(hidden(600, revisits: 99), urgent: true, level: .moderate), [1])

        // A tab the agent opened that no panel showed on screen goes once the agent let it go for the unseen time,
        // counted from its turn's end; a tab the person saw, or opened, waits for the level's time.
        client.memorySaverTiming = BrowserMemorySaver.Timing(
            hiddenBeforeDiscard: .seconds(3600), urgentProtection: .seconds(3600), unseenAgentTabIdle: .milliseconds(150),
            sweepInterval: .milliseconds(30), retryAfter: .seconds(60))
        let agentSession = UUID()
        let unseen = try client.openTab(forSession: agentSession, url: "https://b.test/", viewport: .offscreenDefault, byAgent: true)
        let offScreen = try client.newTab(forSession: agentSession, url: "https://b.test/2", viewport: .offscreenDefault,
                                          select: false, byAgent: true)
        let seen = try client.newTab(forSession: agentSession, url: "https://b.test/3", viewport: .offscreenDefault,
                                     select: false, byAgent: true)
        let persons = try client.newTab(forSession: agentSession, url: "https://b.test/4", viewport: .offscreenDefault, select: false)
        for tab in [unseen, offScreen, seen, persons] {
            connection.eventHandler?(.address(tab: tab.id, url: "https://b.test/\(tab.id)"))
        }
        for tab in [unseen, offScreen, seen] { tab.noteAgentActivity() }
        client.attachPanel(to: offScreen, occluded: true)
        client.detachPanel(from: offScreen, occluded: true)
        client.attachPanel(to: seen)
        client.detachPanel(from: seen)
        // The person's fronting is a revisit; the agent's is not.
        client.selectForAgent(seen)
        client.show(persons)
        client.show(seen)
        XCTAssertEqual([seen.revisits, persons.revisits], [1, 1])
        func agentTabsAsked() -> Set<BrowserTabID> {
            Set(connection.sent.compactMap { if case .discard(let id, false) = $0 { id } else { nil } })
                .intersection([unseen.id, offScreen.id, seen.id, persons.id])
        }
        client.isMemorySaverOn = true
        try await wait(.milliseconds(400))
        XCTAssertEqual(agentTabsAsked(), [], "kept while the agent's turn goes on")
        for tab in client.tabs(forSession: agentSession) { await tab.endAgentEmulation() }
        try await waitUntil { agentTabsAsked() == [unseen.id, offScreen.id] }
        try await wait(.milliseconds(200))
        XCTAssertEqual(agentTabsAsked(), [unseen.id, offScreen.id], "a tab the person saw, or opened, waits for the level")
        client.isMemorySaverOn = false
    }

    func testAnOccludedPanelHidesTheTabUntilItIsOnScreenAgain() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false])

        client.setPanelOccluded(true, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true], "a miniaturized or covered panel stops the painting")
        XCTAssertTrue(tab.isPanelAttached, "the panel still holds the tab")
        XCTAssertEqual(tab.visiblePanelCount, 0)

        tab.noteAgentActivity()
        XCTAssertEqual(visibility(of: tab), [false, true, false], "the agent's use shows it like a panel-less tab")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false, true, false, true], "and it hides again after the agent window")

        client.setPanelOccluded(false, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true, false, true, false], "back on screen: shown, with a fresh frame")

        // Back on screen while the agent's use keeps the engine drawing the tab: the panel, which may hold no frame of it
        // (a new view), still asks for one.
        client.setPanelOccluded(true, on: tab)
        tab.noteAgentActivity()
        let drawn = visibility(of: tab)
        XCTAssertEqual(drawn.suffix(2), [true, false])
        client.setPanelOccluded(false, on: tab)
        XCTAssertEqual(visibility(of: tab), drawn + [false], "a fresh frame though the engine draws the tab already")
        client.detachPanel(from: tab)
        try await waitUntil { self.visibility(of: tab).last == true }
    }

    func testAPanelsOwnTabHidesAsSoonAsThePanelIsOffScreen() throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        client.setPanelOccluded(true, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true], "no agent window from the opening once a panel showed it")
    }

    func testDetachingAnOccludedPanelKeepsTheCountsConsistent() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        try await wait(.milliseconds(250))
        client.setPanelOccluded(true, on: tab)
        client.detachPanel(from: tab, occluded: true)
        XCTAssertEqual(tab.visiblePanelCount, 0)
        XCTAssertEqual(visibility(of: tab), [false, true], "no second hide for the detach")

        client.attachPanel(to: tab)
        XCTAssertEqual(tab.visiblePanelCount, 1, "a new panel starts on screen")
        XCTAssertEqual(visibility(of: tab), [false, true, false])
        client.setPanelOccluded(false, on: tab)
        XCTAssertEqual(tab.visiblePanelCount, 1, "an unmatched un-occlude changes nothing")
        client.detachPanel(from: tab)
    }

    func testAPanelAttachingToAHiddenAgentTabShowsItAgain() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        tab.noteAgentActivity()
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [true], "hidden once the agent is idle")
        client.attachPanel(to: tab)
        XCTAssertEqual(visibility(of: tab), [true, false], "the panel shows the agent's tab and asks for a fresh frame")
        XCTAssertTrue(tab.isShown)
        XCTAssertTrue(tab.isPanelAttached)
    }

    func testTabsWithoutASessionStayShown() async throws {
        let client = makeClient()
        let tab = try client.openTab(url: "about:blank", viewport: .offscreenDefault)
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [])
        tab.close()
    }
}
