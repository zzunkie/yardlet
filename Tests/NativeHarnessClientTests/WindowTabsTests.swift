import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The window's task tabs (`SplitStore.tabs`): a browser's tabs over Yardlet's window items.
@MainActor
final class WindowTabsTests: XCTestCase {
    private func readyStore(_ repository: any SplitRepository = InMemorySplitRepository()) -> SplitStore {
        let store = SplitStore(repository: repository)
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        return store
    }

    func testChoosingARowReplacesTheActiveTabOrMovesToTheTabThatShowsIt() {
        let store = readyStore()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(store.tabs, [.home])

        store.activate(.session(a))
        XCTAssertEqual(store.tabs, [.session(a)])

        store.openInNewTab(.session(b))
        XCTAssertEqual(store.tabs, [.session(a), .session(b)])
        XCTAssertEqual(store.selection, .session(b))

        // A row shown in the active tab replaces it; a row already in a tab moves there.
        store.activate(.session(c))
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        store.activate(.session(a))
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        XCTAssertEqual(store.selection, .session(a))

        // Opening an open item in a new tab only moves to it.
        store.openInNewTab(.session(c))
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        XCTAssertEqual(store.selection, .session(c))
    }

    func testNewTabShowsTheNewTaskScreenAndATaskStartedThereTakesThatTab() {
        let store = readyStore()
        var published: [UUID?] = []
        store.onFocusedSessionChange = { published.append($0) }
        let a = UUID(), started = UUID()
        store.activate(.session(a))

        store.newTab()
        XCTAssertEqual(store.tabs, [.session(a), .home])
        XCTAssertNil(store.focusedSessionID)
        XCTAssertEqual(published.last, .some(nil))

        // The task index selects the task started from the new-task screen.
        store.focusSession(started)
        XCTAssertEqual(store.tabs, [.session(a), .session(started)])
        XCTAssertEqual(published.last, started)
    }

    func testClosingATabLeavesItsTaskAndShowsTheNeighbour() {
        let store = readyStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.activate(.session(a))
        store.openInNewTab(.session(b))
        store.openInNewTab(.session(c))
        store.selectTab(.session(b))

        store.closeTab()
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        XCTAssertEqual(store.selection, .session(c))

        store.closeTab()
        XCTAssertEqual(store.tabs, [.session(a)])
        XCTAssertEqual(store.selection, .session(a))

        // The last tab is the window's: it does not close as a tab.
        XCTAssertFalse(store.canCloseTab)
        store.closeTab()
        XCTAssertEqual(store.tabs, [.session(a)])

        store.reopenClosedTab()
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        XCTAssertEqual(store.selection, .session(c))
        store.reopenClosedTab()
        XCTAssertEqual(store.tabs, [.session(a), .session(c), .session(b)])
        XCTAssertEqual(store.selection, .session(b))
        XCTAssertFalse(store.canReopenClosedTab)

        store.closeOtherTabs()
        XCTAssertEqual(store.tabs, [.session(b)])
    }

    func testControlTabWrapsAround() {
        let store = readyStore()
        let a = UUID(), b = UUID()
        store.activate(.session(a))
        store.openInNewTab(.session(b))
        store.selectTab(offset: 1)
        XCTAssertEqual(store.selection, .session(a))
        store.selectTab(offset: -1)
        XCTAssertEqual(store.selection, .session(b))
        store.selectTab(offset: -1)
        XCTAssertEqual(store.selection, .session(a))
    }

    /// Back and Forward follow the order things were shown in, across tabs, as a browser's history.
    func testBackAndForwardStepThroughWhatTheWindowShowed() {
        let store = readyStore()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertFalse(store.canGoBack)
        store.activate(.session(a))
        store.activate(.session(b))
        store.openInNewTab(.session(c))

        store.goBack()
        XCTAssertEqual(store.selection, .session(b))
        XCTAssertEqual(store.tabs, [.session(b), .session(c)], "going back moves to the tab that shows it")
        store.goBack()
        XCTAssertEqual(store.selection, .session(a))
        XCTAssertEqual(store.tabs, [.session(a), .session(c)], "an item without a tab shows in the active one")
        store.goForward()
        XCTAssertEqual(store.selection, .session(b))

        // A new visit ends the forward list; a task that is gone is passed over.
        store.activate(.home)
        XCTAssertFalse(store.canGoForward)
        store.removeSession(b)
        store.goBack()
        XCTAssertEqual(store.selection, .session(a))
        store.goBack()
        XCTAssertEqual(store.selection, .home, "the first thing shown")
        XCTAssertFalse(store.canGoBack)
    }

    /// The mouse's back and forward buttons belong to what is under the pointer: a browser page's own
    /// history over the page, the window's Back and Forward anywhere else, never both.
    func testTheMouseBackButtonIsThePagesOverABrowserAndTheWindowsElsewhere() throws {
        func button(_ number: Int64) throws -> MouseNavigationButton? {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                                              mouseCursorPosition: .zero, mouseButton: .center))
            event.setIntegerValueField(.mouseEventButtonNumber, value: number)
            return MouseNavigationButton(try XCTUnwrap(NSEvent(cgEvent: event)))
        }
        XCTAssertEqual(try button(3), .back)
        XCTAssertEqual(try button(4), .forward)
        XCTAssertNil(try button(2), "the middle button stays a middle click")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        let page = BrowserHostView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        page.addSubview(NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50)))
        content.addSubview(page)
        content.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        XCTAssertTrue(MouseNavigationMonitorView.keepsOwnHistory(at: NSPoint(x: 300, y: 100), in: window))
        XCTAssertTrue(MouseNavigationMonitorView.keepsOwnHistory(at: NSPoint(x: 220, y: 20), in: window),
                      "a view inside the page is the page's")
        XCTAssertFalse(MouseNavigationMonitorView.keepsOwnHistory(at: NSPoint(x: 100, y: 100), in: window))
    }

    func testATabFollowsItsTaskIntoAndOutOfASplitView() throws {
        let store = readyStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.activate(.session(a))
        store.openInNewTab(.session(b))
        store.openInNewTab(.session(c))

        // Dropping `a` on `c`'s row puts both in a split view: the active tab shows it and `a`'s
        // own tab goes, since an item is in one tab at most.
        store.combine(a, with: c)
        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(store.tabs, [.session(b), .split(split.id)])

        // A split view's task chosen from another tab moves to the split's tab.
        store.selectTab(.session(b))
        store.activate(.session(a))
        XCTAssertEqual(store.selection, .split(split.id))
        XCTAssertEqual(store.tabs, [.session(b), .split(split.id)])
        XCTAssertEqual(store.focusedSessionID, a)

        // Splitting the active task turns its tab into the new split view.
        store.selectTab(.session(b))
        store.split(.right)
        let second = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(store.tabs, [.split(second.id), .split(split.id)])

        // A split view that ends in another tab leaves that tab on the task it kept.
        store.dissolve(split.id)
        XCTAssertEqual(store.tabs, [.split(second.id), .session(a)])
        XCTAssertEqual(store.selection, .split(second.id))

        // Closing the last other pane ends the active split; its tab shows the task left.
        store.closePane()
        XCTAssertEqual(store.tabs, [.session(b), .session(a)])
        XCTAssertEqual(store.selection, .session(b))
    }

    /// 2026-10-24 (A layout, dragging in the window): a tab dragged along the bar keeps which tab shows; a
    /// pane dragged onto the bar leaves its split view for a tab of its own there, which shows, and a split
    /// left with one task ends in its own tab.
    func testATabDragsAlongTheBarAndAPaneDragsOutToATabOfItsOwn() throws {
        let repository = InMemorySplitRepository()
        let store = readyStore(repository)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        store.activate(.session(a))
        store.openInNewTab(.session(b))
        store.openInNewTab(.session(c))
        store.selectTab(.session(b))

        store.moveTab(.session(c), before: .session(a))
        XCTAssertEqual(store.tabs, [.session(c), .session(a), .session(b)])
        XCTAssertEqual(store.selection, .session(b))
        store.moveTab(.session(c), before: nil)
        XCTAssertEqual(store.tabs, [.session(a), .session(b), .session(c)])
        store.persistNow()
        XCTAssertEqual(repository.load()?.tabs, [.session(a), .session(b), .session(c)])

        // `b` and `d` in a split view; `d`'s pane dragged before `a`.
        store.combine(d, with: b)
        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(store.tabs, [.session(a), .split(split.id), .session(c)])
        store.openInOwnTab(d, before: .session(a))
        XCTAssertEqual(store.tabs, [.session(d), .session(a), .session(b), .session(c)])
        XCTAssertEqual(store.selection, .session(d))
        XCTAssertTrue(store.splits.isEmpty)

        // Dropped where its own tab is, a task keeps its place.
        store.openInOwnTab(c, before: .session(c))
        XCTAssertEqual(store.tabs, [.session(d), .session(a), .session(b), .session(c)])
        XCTAssertEqual(store.selection, .session(c))
    }

    func testArchivingATaskClosesItsTabsAndTheWindowMovesToTheNextTab() {
        let store = readyStore()
        var published: [UUID?] = []
        store.onFocusedSessionChange = { published.append($0) }
        let a = UUID(), b = UUID(), c = UUID()
        store.activate(.session(a))
        store.openInNewTab(.session(b))
        store.openInNewTab(.session(c))
        store.selectTab(.session(b))

        store.removeSession(b)
        XCTAssertEqual(store.tabs, [.session(a), .session(c)])
        XCTAssertEqual(store.selection, .session(c))
        XCTAssertEqual(published.last, c)

        // A task in a tab that is not shown closes that tab.
        store.removeSession(a)
        XCTAssertEqual(store.tabs, [.session(c)])

        // The only tab's task stays until the index selects the next task, which takes the tab.
        store.removeSession(c)
        XCTAssertEqual(store.tabs, [.session(c)])
        store.focusSession(b)
        XCTAssertEqual(store.tabs, [.session(b)], "an unarchived task chosen again has a tab again")
    }

    func testTabsSurviveARelaunchAndAnOlderFileOpensWithItsOneItem() throws {
        let repository = InMemorySplitRepository()
        let a = UUID(), b = UUID(), gone = UUID()
        do {
            let store = readyStore(repository)
            store.activate(.session(a))
            store.openInNewTab(.session(gone))
            store.openInNewTab(.session(b))
            store.selectTab(.session(a))
            store.persistNow()
        }
        let data = try JSONEncoder().encode(try XCTUnwrap(repository.snapshot))
        XCTAssertEqual(try JSONDecoder().decode(SplitSnapshot.self, from: data), repository.snapshot)

        let relaunched = SplitStore(repository: repository)
        relaunched.restore(knownSessionIDs: [a, b], fallbackSessionID: nil)
        XCTAssertEqual(relaunched.tabs, [.session(a), .session(b)])
        XCTAssertEqual(relaunched.selection, .session(a))

        // Opened again over five minutes after it was saved (not an update's or a restart's
        // relaunch): the home takes the active tab's place, and the other tabs stay.
        let saved = try XCTUnwrap(repository.snapshot?.savedAt)
        let later = SplitStore(repository: repository, now: { saved.addingTimeInterval(SplitStore.relaunchWindow + 1) })
        later.restore(knownSessionIDs: [a, b], fallbackSessionID: a)
        XCTAssertEqual(later.selection, .home)
        XCTAssertEqual(later.tabs, [.home, .session(b)])
        XCTAssertNil(later.focusedSessionID)

        let older = Data(#"{"version":1,"splits":[],"selection":{"kind":"session","id":"\#(a.uuidString)"}}"#.utf8)
        let snapshot = try JSONDecoder().decode(SplitSnapshot.self, from: older)
        XCTAssertNil(snapshot.tabs)
        let fromOlder = SplitStore(repository: InMemorySplitRepository(snapshot: snapshot))
        fromOlder.restore(knownSessionIDs: [a], fallbackSessionID: nil)
        XCTAssertEqual(fromOlder.tabs, [.session(a)])
    }

    func testTabKeysAreMacOSsAndDoNotTakeYardletsOwn() {
        let tabs = [TabCommandShortcut.newTab, TabCommandShortcut.closeTab, TabCommandShortcut.closeWindow,
                    TabCommandShortcut.reopenClosedTab, TabCommandShortcut.nextTab, TabCommandShortcut.previousTab]
        let splitKeys = [KeyboardShortcut("d", modifiers: [.command, .shift]),
                         KeyboardShortcut("d", modifiers: [.command, .shift, .option]),
                         KeyboardShortcut("w", modifiers: [.command, .control])]
        for shortcut in TaskCommandShortcut.all + [TaskCommandShortcut.newTask] + splitKeys {
            XCTAssertFalse(tabs.contains(shortcut), "\(shortcut)")
        }
        XCTAssertEqual(Set(tabs.map { "\($0.key.character)\($0.modifiers.rawValue)" }).count, tabs.count)
        // A keyboard's ⇧Tab is the back-tab character.
        XCTAssertEqual(TabCommandShortcut.previousTab.key.character, "\u{19}")
        XCTAssertEqual(TabCommandShortcut.nextTab.key, .tab)
    }
}
