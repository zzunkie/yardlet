import XCTest
@testable import NativeHarnessClient

final class TaskSurfaceNavigationProjectionTests: XCTestCase {
    private let surfaceIDs = ["chat", "diff", "terminal", "browser"]
    /// One of the task's browser tabs, as a side-panel tab.
    private let browserKey = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private var browser: String { TaskSurfaceNavigationProjection.browserTabID(browserKey) }

    func testLeftAndRightStayWithinSurfacePickerOrder() {
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: "diff",
                offset: -1
            ),
            "chat"
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: "diff",
                offset: 1
            ),
            "terminal"
        )
    }

    func testMissingFocusStartsAtChatAndEdgesClamp() {
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.focusedIndex(surfaceIDs: surfaceIDs, focusedID: nil),
            0
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: nil,
                offset: 1
            ),
            "diff"
        )
        XCTAssertNil(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: "chat",
                offset: -1
            )
        )
        XCTAssertNil(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: "browser",
                offset: 1
            )
        )
    }

    func testStaleFocusFailsClosedToFirstSurface() {
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.focusedIndex(surfaceIDs: surfaceIDs, focusedID: "removed"),
            0
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.targetSurfaceID(
                in: surfaceIDs,
                focusedID: "removed",
                offset: 1
            ),
            "diff"
        )
        XCTAssertNil(
            TaskSurfaceNavigationProjection.targetSurfaceID(in: [], focusedID: nil, offset: 1)
        )
    }

    func testAuxiliarySurfacesProjectToCodexDockEdges() {
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: "chat"), .primary)
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: "diff"), .trailing)
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: "browser"), .trailing)
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: browser), .trailing)
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: "terminal"), .bottom)
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: "future"), .primary)
    }

    func testFixtureSurfaceProjectsToIndependentPanelState() {
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.initialPanelState(surfaceID: "browser", newBrowserKey: browserKey),
            .init(trailingSurfaceID: browser, trailingTabs: [browser], recentTrailingTabs: [browser])
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.initialPanelState(surfaceID: "workspace").trailingSurfaceID,
            TaskSurfaceNavigationProjection.launcherID
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.initialPanelState(surfaceID: "terminal"),
            .init(isTerminalPresented: true)
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.initialPanelState(surfaceID: "full", newBrowserKey: browserKey),
            .init(trailingSurfaceID: browser, isTerminalPresented: true,
                  trailingTabs: [browser], recentTrailingTabs: [browser])
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.initialPanelState(surfaceID: "unknown"),
            .init()
        )
    }

    func testTrailingAndBottomPanelsCanStayOpenTogether() {
        let browserOpen = TaskSurfaceNavigationProjection.toggledPanelState(
            current: .init(),
            targetID: "browser",
            newBrowserKey: browserKey
        )
        let browserAndTerminalOpen = TaskSurfaceNavigationProjection.toggledPanelState(
            current: browserOpen,
            targetID: "terminal"
        )

        XCTAssertEqual(
            browserAndTerminalOpen,
            .init(trailingSurfaceID: browser, isTerminalPresented: true,
                  trailingTabs: [browser], recentTrailingTabs: [browser])
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.toggledPanelState(
                current: browserAndTerminalOpen,
                targetID: "diff"
            ),
            .init(trailingSurfaceID: "diff", isTerminalPresented: true,
                  trailingTabs: [browser, "diff"], recentTrailingTabs: ["diff", browser])
        )
    }

    private typealias Projection = TaskSurfaceNavigationProjection
    private func toggleSidePanel(_ state: Projection.PanelState) -> Projection.PanelState {
        Projection.toggledPanelState(current: state, targetID: Projection.sidePanelToggleID)
    }

    func testSidePanelOpensToTheLauncherFirstAndThenTheTabUsedLast() {
        // The Codex app's panel launcher, not Review: nothing is a tab until something is chosen.
        let first = toggleSidePanel(.init())
        XCTAssertEqual(first.trailingSurfaceID, Projection.launcherID)
        XCTAssertEqual(first.trailingTabs, [])

        let browsing = Projection.showing(browser, in: first)
        XCTAssertEqual(browsing.trailingTabs, [browser])
        let hidden = toggleSidePanel(browsing)
        XCTAssertNil(hidden.trailingSurfaceID)
        XCTAssertEqual(hidden.trailingTabs, [browser], "Hiding the panel keeps its tabs")
        XCTAssertEqual(toggleSidePanel(hidden).trailingSurfaceID, browser)

        // A tab picked in the strip is the one the panel returns to.
        let review = Projection.showing("diff", in: toggleSidePanel(hidden))
        XCTAssertEqual(toggleSidePanel(toggleSidePanel(review)).trailingSurfaceID, "diff")
        XCTAssertEqual(review.trailingTabs, [browser, "diff"], "Switching tabs keeps their order")
    }

    func testTheLauncherCoversTheTabsAndItsCloseReturnsToTheTabItCovered() {
        var state = Projection.showing("files", in: .init())
        state = Projection.showing(Projection.launcherID, in: state)
        XCTAssertEqual(state.trailingSurfaceID, Projection.launcherID)
        XCTAssertEqual(state.trailingTabs, ["files"], "The launcher is not a tab")
        XCTAssertEqual(Projection.placement(for: Projection.launcherID), .trailing)
        XCTAssertEqual(Projection.closingTrailingTab(Projection.launcherID, in: state).trailingSurfaceID, "files")
        // With nothing to return to, closing it hides the panel.
        let alone = toggleSidePanel(.init())
        XCTAssertNil(Projection.closingTrailingTab(Projection.launcherID, in: alone).trailingSurfaceID)
    }

    func testAnotherTasksConversationIsATabThatIsSavedAndClosesLikeAnyOther() throws {
        let other = UUID()
        let id = Projection.taskTabID(other)
        XCTAssertEqual(Projection.taskID(inTab: id), other)
        XCTAssertNil(Projection.taskID(inTab: "diff"))
        XCTAssertNil(Projection.taskID(inTab: "task:not-a-uuid"))
        XCTAssertEqual(Projection.placement(for: id), .trailing)

        var state = Projection.showing("diff", in: .init())
        state = Projection.showing(id, in: state)
        XCTAssertEqual(state.trailingTabs, ["diff", id])
        XCTAssertEqual(state.recentTrailingTabs, [id, "diff"])
        // Saved and read back with its tab.
        let decoded = try JSONDecoder().decode(Projection.PanelState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(Projection.reconciled(decoded), state)
        XCTAssertEqual(Projection.closingTrailingTab(id, in: state).trailingSurfaceID, "diff")
        XCTAssertEqual(toggleSidePanel(toggleSidePanel(state)).trailingSurfaceID, id)
    }

    func testClosingATabReturnsToTheTabUsedBeforeItAndTheLastTabHidesThePanel() {
        var state = Projection.showing("files", in: .init())
        state = Projection.showing("diff", in: state)
        state = Projection.showing(browser, in: state)
        XCTAssertEqual(state.trailingTabs, ["files", "diff", browser])

        state = Projection.closingTrailingTab(browser, in: state)
        XCTAssertEqual(state.trailingSurfaceID, "diff", "Not the neighbour in the strip, the tab used before")
        // Closing a tab that is not shown leaves the shown one.
        state = Projection.closingTrailingTab("files", in: state)
        XCTAssertEqual(state.trailingSurfaceID, "diff")
        XCTAssertEqual(state.trailingTabs, ["diff"])
        state = Projection.closingTrailingTab("diff", in: state)
        XCTAssertNil(state.trailingSurfaceID)
        XCTAssertEqual(state.trailingTabs, [])
        XCTAssertEqual(toggleSidePanel(state).trailingSurfaceID, Projection.launcherID,
                       "With no tab left, the launcher opens again")
    }

    func testPanelShortcutsToggleTheirTabAndKeepTheOthers() {
        let browsing = Projection.toggledPanelState(current: .init(), targetID: "browser", newBrowserKey: browserKey)
        let review = Projection.toggledPanelState(current: browsing, targetID: "diff")
        XCTAssertEqual(review.trailingSurfaceID, "diff")
        XCTAssertEqual(review.trailingTabs, [browser, "diff"])
        let hidden = Projection.toggledPanelState(current: review, targetID: "diff")
        XCTAssertNil(hidden.trailingSurfaceID)
        XCTAssertEqual(toggleSidePanel(hidden).trailingSurfaceID, "diff")
        // By default the terminal sits below the conversation and is no side-panel tab.
        let terminal = Projection.toggledPanelState(current: hidden, targetID: "terminal")
        XCTAssertTrue(terminal.isTerminalPresented)
        XCTAssertEqual(terminal.trailingTabs, [browser, "diff"])
    }

    /// Settings' terminal location (the Codex app's "Default terminal location"): on the right the terminal
    /// is the side panel's Terminal tab, which its shortcut shows and hides as the tab used before comes back;
    /// changing the setting moves a terminal on screen to the other place, and one hidden stays hidden.
    func testTheTerminalOpensBelowOrAsTheSidePanelsTerminalTab() {
        let review = Projection.showing("diff", in: .init())
        let right = Projection.toggledPanelState(current: review, targetID: "terminal", terminalLocation: .right)
        XCTAssertEqual(right.trailingSurfaceID, "terminal")
        XCTAssertEqual(right.trailingTabs, ["diff", "terminal"])
        XCTAssertFalse(right.isTerminalPresented)
        XCTAssertTrue(right.showsTerminal)
        let hidden = Projection.toggledPanelState(current: right, targetID: "terminal", terminalLocation: .right)
        XCTAssertEqual(hidden.trailingSurfaceID, "diff", "the tab used before comes back")
        XCTAssertEqual(hidden.trailingTabs, ["diff"])
        XCTAssertFalse(hidden.showsTerminal)
        XCTAssertFalse(Projection.toggledPanelState(current: Projection.showing("terminal", in: .init()),
                                                    targetID: "terminal", terminalLocation: .right).showsTerminal)

        let below = Projection.relocatingTerminal(right, to: .bottom)
        XCTAssertTrue(below.isTerminalPresented, "on screen, it moves below")
        XCTAssertEqual(below.trailingSurfaceID, "diff")
        XCTAssertEqual(below.trailingTabs, ["diff"])
        XCTAssertEqual(Projection.relocatingTerminal(below, to: .right), Projection.showing("terminal", in: review))
        let behind = Projection.showing("diff", in: right)
        XCTAssertEqual(Projection.relocatingTerminal(behind, to: .bottom).isTerminalPresented, false,
                       "a Terminal tab not in front leaves without showing below")
        XCTAssertEqual(Projection.relocatingTerminal(.init(), to: .right), .init(), "a hidden terminal stays hidden")
        XCTAssertEqual(Projection.hidingTerminal(.init(isTerminalPresented: true)), .init())
        XCTAssertEqual(TaskFocusTarget.visibleContent(in: right), .terminal)
        XCTAssertEqual(TaskFocusTarget.destination(for: .terminal, panels: right), .terminal)
    }

    func testReturningToTheConversationHidesBothPanelsAndKeepsTheTabs() {
        var state = Projection.showing("files", in: .init(isTerminalPresented: true))
        state = Projection.toggledPanelState(current: state, targetID: "chat")
        XCTAssertNil(state.trailingSurfaceID)
        XCTAssertFalse(state.isTerminalPresented)
        XCTAssertEqual(state.trailingTabs, ["files"])
        XCTAssertEqual(toggleSidePanel(state).trailingSurfaceID, "files")
    }

    func testSubtaskShowsInThePanelWithoutBecomingATab() {
        let review = Projection.showing("diff", in: .init())
        let subtask = Projection.showing("subtask", in: review)
        XCTAssertEqual(subtask.trailingSurfaceID, "subtask")
        XCTAssertEqual(subtask.trailingTabs, ["diff"])
        XCTAssertEqual(subtask.recentTrailingTabs, ["diff"])
    }

    func testSavedPanelsFromBeforeTabsDecodeAndUnknownTabsAreDropped() throws {
        let old = try JSONDecoder().decode(Projection.PanelState.self,
            from: Data(#"{"trailingSurfaceID":"browser","isTerminalPresented":true}"#.utf8))
        XCTAssertEqual(old, .init(trailingSurfaceID: "browser", isTerminalPresented: true))
        // The one Browser tab of before is no tab now; the task's snapshot turns it into browser tabs
        // (`TaskWorkspaceSnapshot.migrated`).
        XCTAssertEqual(Projection.reconciled(old).trailingTabs, [])
        let list = Projection.reconciled(.init(trailingSurfaceID: "workspace"))
        XCTAssertEqual(list.trailingSurfaceID, Projection.launcherID, "The old panel list opens the launcher")
        let unknown = Projection.reconciled(.init(trailingTabs: ["removed", "files", "files"],
                                                  recentTrailingTabs: ["removed", "files"]))
        XCTAssertEqual(unknown.trailingTabs, ["files"])
        XCTAssertEqual(unknown.recentTrailingTabs, ["files"])
        let encoded = try JSONEncoder().encode(Projection.showing("files", in: .init()))
        XCTAssertEqual(try JSONDecoder().decode(Projection.PanelState.self, from: encoded).trailingTabs, ["files"])
    }

    @MainActor
    func testEveryHarnessGetsTheSameMenuAndAnUnavailableSideChatStaysInIt() {
        let available = TaskSidePanelTabs.choices(canOpenSideChat: true)
        let unavailable = TaskSidePanelTabs.choices(canOpenSideChat: false)
        XCTAssertEqual(available.map(\.id), ["diff", "terminal", "browser", "files", "sideChat"])
        XCTAssertEqual(unavailable.map(\.id), available.map(\.id))
        XCTAssertEqual(unavailable.filter { !$0.isAvailable }.map(\.id), ["sideChat"])
        XCTAssertEqual(TaskSidePanelTabs.tab("files", selectedFilePath: "Sources/App.swift")?.title, "App.swift")
        XCTAssertNil(TaskSidePanelTabs.tab("subtask", selectedFilePath: nil))
    }

    func testPanelsToggleIndependentlyAndChatClosesAllPanels() {
        let fullyOpen = TaskSurfaceNavigationProjection.reconciled(.init(
            trailingSurfaceID: browser,
            isTerminalPresented: true
        ))

        XCTAssertEqual(
            TaskSurfaceNavigationProjection.toggledPanelState(
                current: fullyOpen,
                targetID: "browser"
            ),
            .init(isTerminalPresented: true, trailingTabs: [browser], recentTrailingTabs: [browser]),
            "⌘4 on a browser tab hides the panel and keeps the tab"
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.toggledPanelState(
                current: fullyOpen,
                targetID: "terminal"
            ),
            .init(trailingSurfaceID: browser, trailingTabs: [browser], recentTrailingTabs: [browser])
        )
        XCTAssertEqual(
            TaskSurfaceNavigationProjection.toggledPanelState(
                current: fullyOpen,
                targetID: "chat"
            ),
            .init(trailingTabs: [browser], recentTrailingTabs: [browser])
        )
    }
}
