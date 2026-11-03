import XCTest
@testable import NativeHarnessClient

/// A task keeps several browser tabs in strip order with one fronted, as the Claude app's Browser
/// pane and the Codex app's in-app browser do.
@MainActor
final class BrowserSessionTabsTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    private let connection = FakeConnection()

    private func makeClient() -> BrowserHostClient {
        BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(80)) { [unowned self] in self.connection }
    }

    private func opened() -> [String] {
        connection.sent.compactMap { if case .open(_, let url, _, _) = $0 { url } else { nil } }
    }

    /// Every tab of a task opens in that task's profile, a tab of no task in the default one, and a task that takes a
    /// profile of its own opens its tabs again in their places, at their pages, in it: a tab's profile is fixed once it
    /// opens, so a tab left behind would sign the agent in where the person's sign-ins are
    /// (docs/BROWSER_SESSION_ISOLATION.md 3).
    func testATasksTabsOpenInItsProfileAndOpenAgainInPlaceWhenItTakesOne() throws {
        let client = makeClient()
        let task = UUID()
        var own = false
        client.profileForSession = { own ? BrowserTabProfile(key: $0.uuidString, seedFrom: nil) : nil }
        let first = try client.openTab(forSession: task, url: "https://a.test", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: task, url: "https://b.test", viewport: .offscreenDefault, select: false)
        _ = try client.openTab(url: "https://c.test", viewport: .offscreenDefault)
        let profiles = { self.connection.sent.compactMap { if case .open(_, _, _, let profile) = $0 { profile?.key ?? "default" } else { nil } } }
        XCTAssertEqual(profiles(), ["default", "default", "default"])
        connection.eventHandler?(.address(tab: first.id, url: "https://a.test/signin"))
        connection.eventHandler?(.address(tab: second.id, url: "https://b.test/"))

        own = true
        connection.sent.removeAll()
        client.reopenTabs(forSession: task, cause: .ownProfile)
        let reopened = connection.sent.compactMap { if case .open(_, let url, _, let profile) = $0 { "\(url) \(profile?.key ?? "default")" } else { nil } }
        XCTAssertEqual(reopened, ["https://a.test/signin \(task.uuidString)", "https://b.test/ \(task.uuidString)"])
        XCTAssertEqual(connection.sent.filter { if case .close = $0 { true } else { false } }.count, 2)
        let tabs = client.tabs(forSession: task)
        XCTAssertEqual(tabs.map(\.key), [first.key, second.key], "each opens again as the same panel tab, in its place")
        XCTAssertTrue(client.tab(forSession: task) === tabs[0], "the fronted tab stays in front")
        XCTAssertEqual(client.departure(of: first.id)?.departure, .reopened(key: first.key, cause: .ownProfile))
    }

    func testNewTabsOpenBehindTheFrontedTabUnlessSelected() throws {
        let client = makeClient()
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "https://a.test", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: session, url: "https://b.test", viewport: .offscreenDefault, select: false)
        XCTAssertTrue(client.tab(forSession: session) === first, "a background tab leaves the front alone")
        let third = try client.newTab(forSession: session, url: "https://c.test", viewport: .offscreenDefault, select: true)
        XCTAssertTrue(client.tab(forSession: session) === third)
        XCTAssertEqual(client.tabs(forSession: session).map(\.id), [first.id, second.id, third.id], "new tabs go last")
        second.select()
        XCTAssertTrue(client.tab(forSession: session) === second)
        XCTAssertTrue(try client.openTab(forSession: session, url: "https://d.test", viewport: .offscreenDefault) === second,
                      "the task's tab is the fronted one; its page is not loaded again")
        XCTAssertEqual(opened(), ["https://a.test", "https://b.test", "https://c.test"])
        XCTAssertTrue(client.tabs(forSession: UUID()).isEmpty, "other tasks have their own tabs")
    }

    func testClosingTheFrontedTabFrontsItsNeighbourAndCanBeReopened() throws {
        let client = makeClient()
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "https://a.test", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: session, url: "https://b.test", viewport: .offscreenDefault, select: true)
        let third = try client.newTab(forSession: session, url: "https://c.test", viewport: .offscreenDefault, select: false)
        connection.eventHandler?(.address(tab: second.id, url: "https://b.test/page"))
        // A page whose address or title carries a value the vault filled is not one the tab remembers.
        client.carriesFilledValue = { $0.contains("hunter22") }
        connection.eventHandler?(.address(tab: second.id, url: "https://b.test/login?password=hunter22"))
        connection.eventHandler?(.title(tab: second.id, title: "Signed in as hunter22"))
        XCTAssertEqual(second.lastPageURL, "https://b.test/page")
        XCTAssertEqual(second.title, "")
        second.close()
        XCTAssertTrue(client.tab(forSession: session) === third, "the tab that took its place, as Chrome")
        third.close()
        XCTAssertTrue(client.tab(forSession: session) === first, "else the one before it")

        let reopened = try XCTUnwrap(client.reopenClosedTab(forSession: session, viewport: .offscreenDefault))
        XCTAssertTrue(client.tab(forSession: session) === reopened)
        XCTAssertEqual(opened().last, "https://b.test/page", "the closed tab's page, not its first address")
        XCTAssertNil(try client.reopenClosedTab(forSession: session, viewport: .offscreenDefault),
                     "a tab that showed no page is not on the reopen list")
    }

    func testATaskKeepsAtMostNineTabs() throws {
        let client = makeClient()
        let session = UUID()
        _ = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        for _ in 1..<BrowserHostClient.maxTabsPerSession {
            _ = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        }
        XCTAssertThrowsError(try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: true)) {
            XCTAssertEqual($0 as? BrowserTabLimitError, BrowserTabLimitError())
        }
        XCTAssertEqual(client.tabs(forSession: session).count, 9)
        XCTAssertNoThrow(try client.newTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault, select: true),
                         "the limit is per task")
    }

    func testTabsLostWithTheHostOpenAgainInOrderWithTheSameFront() throws {
        let client = makeClient()
        let history = BrowserAddressHistory(file: nil)
        client.addressHistory = history
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        let blank = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        let third = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: true)
        connection.eventHandler?(.address(tab: first.id, url: "https://a.test/"))
        connection.eventHandler?(.address(tab: third.id, url: "https://c.test/"))
        connection.eventHandler?(.address(tab: blank.id, url: "about:blank"))
        connection.eventHandler?(.terminated(reason: "crashed"))
        XCTAssertTrue(client.tabs(forSession: session).isEmpty)
        XCTAssertEqual(client.rememberedTabs(forSession: session),
                       BrowserRememberedTabs(addresses: ["https://a.test/", "https://c.test/"], keys: [first.key, third.key],
                                             titles: ["", ""], favicons: [nil, nil], fronted: 1),
                       "tabs that showed no page are not kept")
        XCTAssertEqual(client.lastAddress(forSession: session), "https://c.test/")

        connection.sent = []
        let fronted = try XCTUnwrap(client.restoreTabs(forSession: session, viewport: .offscreenDefault))
        XCTAssertEqual(opened(), ["https://c.test/"], "only the tab in front loads its page, as Chrome restores tabs")
        XCTAssertTrue(client.tabs(forSession: session).last === fronted)
        XCTAssertEqual(client.tabs(forSession: session).map(\.key), [first.key, third.key],
                       "they are the same side-panel tabs")
        XCTAssertNil(client.rememberedTabs(forSession: session))
        XCTAssertNil(try client.restoreTabs(forSession: session, viewport: .offscreenDefault), "restored once")
        let waiting = try XCTUnwrap(client.tabs(forSession: session).first)
        XCTAssertEqual(waiting.pendingAddress, "https://a.test/")
        client.noteAgentActivity(on: waiting)
        XCTAssertEqual(opened(), ["https://c.test/", "https://a.test/"], "the other loads as the agent uses it")
        XCTAssertNil(waiting.pendingAddress)

        // The address field's history: each page a tab commits once, typed only from the address field.
        for (tab, url) in zip(client.tabs(forSession: session), ["https://a.test/", "https://c.test/"]) {
            connection.eventHandler?(.address(tab: tab.id, url: url))
        }
        connection.eventHandler?(.address(tab: fronted.id, url: "https://c.test/"))
        XCTAssertEqual(history.pages.mapValues(\.visitCount), ["https://a.test/": 1, "https://c.test/": 1],
                       "a restored page and a page shown again are no new visits")
        fronted.noteTypedNavigation()
        connection.eventHandler?(.address(tab: fronted.id, url: "https://c.test/next"))
        connection.eventHandler?(.title(tab: fronted.id, title: "Next"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://c.test/next#part"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://me:pw@c.test/private"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://www.google.com/search?q=two%20words"))
        fronted.noteTypedNavigation()
        connection.eventHandler?(.loadError(tab: fronted.id, url: "https://gone.test/", code: -105, message: "ERR_NAME_NOT_RESOLVED"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://gone.test/"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://c.test/after"))
        client.carriesFilledValue = { $0.contains("hunter22") }
        connection.eventHandler?(.address(tab: fronted.id, url: "https://c.test/login?password=hunter22"))
        connection.eventHandler?(.address(tab: fronted.id, url: "https://www.google.com/search?q=hunter22"))
        let next = try XCTUnwrap(history.pages["https://c.test/next"])
        XCTAssertEqual([next.visitCount, next.typedCount], [1, 1], "a move within the page is no visit")
        XCTAssertEqual(next.title, "Next")
        XCTAssertNotNil(history.pages["https://c.test/private"], "kept without the user name and password")
        XCTAssertEqual(history.pages["https://c.test/after"]?.typedCount, 0, "a failed typed address types nothing after it")
        XCTAssertNil(history.pages["https://gone.test/"], "an error page is no visit")
        XCTAssertEqual(history.searches.values.map(\.terms), ["two words"], "a results page counts as its search")
        XCTAssertFalse(history.pages.keys.contains { $0.contains("hunter22") }, "a page that carries a filled value is no visit")
    }

    func testObserversHearTabChangesButNotFrames() throws {
        let client = makeClient()
        let session = UUID()
        var calls = 0
        let token = client.addTabsObserver(forSession: session) { calls += 1 }
        let tab = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        XCTAssertEqual(calls, 1)
        connection.eventHandler?(.title(tab: tab.id, title: "Example"))
        XCTAssertEqual(tab.title, "Example")
        XCTAssertEqual(calls, 2)
        connection.eventHandler?(.frame(tab: tab.id, frame: BrowserFrame(
            layer: .view, surface: 1, pixelWidth: 2, pixelHeight: 2, sequence: 1, paintedAt: 0, source: "accelerated"
        )))
        XCTAssertEqual(calls, 2, "frames do not rebuild the panel's tabs")
        connection.eventHandler?(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        XCTAssertEqual(calls, 3, "a page starting to load shows on its tab")
        connection.eventHandler?(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: true))
        XCTAssertEqual(calls, 3, "the rest of the loading state does not")
        XCTAssertTrue(tab.isLoading)
        XCTAssertTrue(tab.canGoBack)
        connection.eventHandler?(.favicon(tab: tab.id, url: "https://a.test/favicon.ico", png: Data([1, 2, 3])))
        XCTAssertEqual(calls, 4, "the page's icon shows on its tab")
        XCTAssertEqual(tab.favicon, Data([1, 2, 3]))
        let other = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        other.select()
        other.close()
        XCTAssertEqual(calls, 7)
        client.removeTabsObserver(token, forSession: session)
        tab.close()
        XCTAssertEqual(calls, 7)
    }

    func testClosingATasksTabsClosesThemAllAndForgetsThem() throws {
        let client = makeClient()
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        connection.eventHandler?(.address(tab: first.id, url: "https://a.test/"))
        client.closeTabs(forSession: session)
        XCTAssertTrue(first.isClosed && second.isClosed)
        XCTAssertTrue(client.tabs(forSession: session).isEmpty)
        XCTAssertNil(try client.reopenClosedTab(forSession: session, viewport: .offscreenDefault), "nothing to reopen for an archived task")
    }

    func testAPageThatClosesItselfLeavesTheStrip() throws {
        let client = makeClient()
        let session = UUID()
        let first = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: true)
        connection.eventHandler?(.closed(tab: second.id))
        XCTAssertTrue(second.isClosed)
        XCTAssertTrue(client.tab(forSession: session) === first)
    }

    func testABackgroundTabPaintsOnlyWhileTheAgentUsesIt() async throws {
        let client = makeClient()
        let session = UUID()
        let shown = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: shown)
        let background = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        try await Task.sleep(for: .milliseconds(250))
        func visibility(_ tab: BrowserTab) -> [Bool] {
            connection.sent.compactMap { if case .visibility(let id, let hidden) = $0, id == tab.id { hidden } else { nil } }
        }
        XCTAssertEqual(visibility(background), [true], "a tab nobody shows stops painting after the opening window")
        background.noteAgentActivity()
        XCTAssertEqual(visibility(background), [true, false], "the agent driving it in the background shows it to the engine")
        XCTAssertEqual(visibility(shown), [false], "the panel's tab stays shown")
    }

    // MARK: New windows

    func testANewWindowRequestOpensAnotherTabOfTheTask() throws {
        let client = makeClient()
        let session = UUID()
        let opener = try client.openTab(forSession: session, url: "https://a.test/", viewport: .offscreenDefault)
        var opened: [BrowserTabID?] = []
        opener.addEventObserver { if case .openedTab(_, let newTab, _) = $0 { opened.append(newTab) } }
        opener.send(.resize(tab: opener.id, viewport: BrowserViewport(width: 500, height: 400, scale: 2)))

        connection.eventHandler?(.newWindow(tab: opener.id, url: "https://b.test/", background: false, userGesture: true))
        let front = try XCTUnwrap(client.tab(forSession: session))
        XCTAssertFalse(front === opener, "window.open and target=_blank open in front")
        XCTAssertEqual(opened, [front.id])
        guard case .open(_, let url, let viewport, _)? = connection.sent.last(where: { if case .open = $0 { true } else { false } }) else {
            return XCTFail("no tab opened")
        }
        XCTAssertEqual(url, "https://b.test/")
        XCTAssertEqual(viewport.width, 500, "at the opener's size")

        connection.eventHandler?(.newWindow(tab: opener.id, url: "https://c.test/", background: true, userGesture: true))
        XCTAssertTrue(client.tab(forSession: session) === front, "a background-tab click opens behind")
        XCTAssertEqual(client.tabs(forSession: session).count, 3)

        connection.eventHandler?(.newWindow(tab: opener.id, url: "https://ad.test/", background: false, userGesture: false))
        XCTAssertEqual(client.tabs(forSession: session).count, 3, "no tab without a user gesture, as Chrome blocks those pop-ups")
        XCTAssertFalse(connection.sent.contains(.navigate(tab: opener.id, url: "https://ad.test/")))

        // The host made the new window itself, so it keeps window.opener: Yardlet shows that tab.
        let sent = connection.sent.count
        connection.eventHandler?(.popupOpened(tab: 1 << 30, opener: opener.id, url: "https://issuer.test/", background: false))
        let popup = try XCTUnwrap(client.tab(forSession: session))
        XCTAssertEqual(popup.id, 1 << 30, "the host's popup is the task's tab, in front")
        XCTAssertEqual(client.tabs(forSession: session).last?.id, popup.id)
        XCTAssertEqual(opened.last, popup.id)
        XCTAssertFalse(connection.sent.dropFirst(sent).contains { if case .open = $0 { true } else { false } },
                       "Yardlet opens nothing for it")
        connection.eventHandler?(.closed(tab: popup.id))
        XCTAssertNil(client.tabs(forSession: session).first { $0.id == popup.id }, "window.close() closes its tab")
    }

    func testANewWindowOutsideATaskOrPastTheLimitLoadsInPlace() throws {
        let client = makeClient()
        let loose = try client.openTab(url: "https://a.test/", viewport: .offscreenDefault)
        connection.eventHandler?(.newWindow(tab: loose.id, url: "https://b.test/", background: false, userGesture: true))
        XCTAssertEqual(connection.sent.last, .navigate(tab: loose.id, url: "https://b.test/"))

        let session = UUID()
        let opener = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        for _ in 1..<BrowserHostClient.maxTabsPerSession {
            _ = try client.newTab(forSession: session, url: "about:blank", viewport: .offscreenDefault, select: false)
        }
        var opened: [BrowserTabID?] = []
        opener.addEventObserver { if case .openedTab(_, let newTab, _) = $0 { opened.append(newTab) } }
        connection.eventHandler?(.newWindow(tab: opener.id, url: "https://c.test/", background: false, userGesture: true))
        XCTAssertEqual(connection.sent.last, .navigate(tab: opener.id, url: "https://c.test/"))
        XCTAssertEqual(opened, [nil], "the page goes there itself and the agent is told")

        // A new window the host made has nowhere to go either: it closes and the page goes there itself.
        connection.eventHandler?(.popupOpened(tab: 1 << 30, opener: opener.id, url: "https://d.test/", background: false))
        XCTAssertEqual(Array(connection.sent.suffix(2)), [.close(tab: 1 << 30), .navigate(tab: opener.id, url: "https://d.test/")])
        XCTAssertEqual(client.tabs(forSession: session).count, BrowserHostClient.maxTabsPerSession)
        connection.eventHandler?(.popupOpened(tab: (1 << 30) + 1, opener: loose.id, url: "https://e.test/", background: false))
        XCTAssertEqual(Array(connection.sent.suffix(2)), [.close(tab: (1 << 30) + 1), .navigate(tab: loose.id, url: "https://e.test/")])
    }

    func testTabsSavedWithTheTaskOpenOnlyWhenItHasNone() throws {
        let client = makeClient()
        let session = UUID()
        client.rememberTabs(BrowserRememberedTabs(addresses: ["https://a.test/", "https://b.test/"], titles: ["A", "B"],
                                                  fronted: 7), forSession: session)
        XCTAssertEqual(client.rememberedTabs(forSession: session)?.fronted, 1, "an out-of-range front is clamped")
        let fronted = try XCTUnwrap(client.restoreTabs(forSession: session, viewport: .offscreenDefault))
        XCTAssertEqual(opened(), ["https://b.test/"])
        XCTAssertTrue(client.tabs(forSession: session).last === fronted)
        // The other waits in the strip as it was, a page not loaded, until it is shown or used.
        let waiting = try XCTUnwrap(client.tabs(forSession: session).first)
        XCTAssertEqual([waiting.lastPageURL, waiting.title], ["https://a.test/", "A"])
        XCTAssertTrue(waiting.isDiscarded)
        client.isMemorySaverOn = true
        client.isMemorySaverOn = false
        XCTAssertEqual(opened(), ["https://b.test/"], "turning the saver off loads only the pages it discarded")
        client.requestClose(waiting)
        XCTAssertFalse(client.tabs(forSession: session).contains { $0 === waiting }, "with no page to ask, it closes at once")
        client.rememberTabs(BrowserRememberedTabs(addresses: ["https://c.test/"], fronted: 0), forSession: session)
        XCTAssertNil(client.rememberedTabs(forSession: session), "a task with open tabs keeps them")
    }
}
