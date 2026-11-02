import XCTest
import SwiftUI
import WebKit
@testable import NativeHarnessClient

@MainActor
final class TaskWorkspaceRestorationTests: XCTestCase {
    /// Without the browser engine, each browser tab of the side panel is a WebKit page of its own; only
    /// its address is saved.
    func testBrowserPagesBelongToTheirTasksAndOnlyAddressPersistsAcrossRestart() throws {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let firstKey = try XCTUnwrap(store.state(for: first).openBrowserTab())
        let secondKey = try XCTUnwrap(store.state(for: second).openBrowserTab())
        let firstBrowser = store.state(for: first).browserTabs.preview(for: firstKey)
        let secondBrowser = store.state(for: second).browserTabs.preview(for: secondKey)
        firstBrowser.address = "localhost:8080/first"
        firstBrowser.navigate()
        secondBrowser.address = "  localhost:9090/다음 초안  "
        XCTAssertTrue(store.state(for: first).browserTabs.preview(for: firstKey) === firstBrowser)
        XCTAssertFalse(firstBrowser === secondBrowser)
        XCTAssertNil(secondBrowser.requestedURL)
        store.persistNow()
        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(restarted.state(for: first).browserTabs.preview(for: firstKey).address, "http://localhost:8080/first")
        XCTAssertEqual(restarted.state(for: second).browserTabs.preview(for: secondKey).address, "  localhost:9090/다음 초안  ")
        XCTAssertNil(restarted.state(for: first).browserTabs.preview(for: firstKey).requestedURL)
        XCTAssertFalse(restarted.state(for: first).browserTabs.preview(for: firstKey).hasAttachedWebView)
        firstBrowser.stop()
    }

    func testRemovingTaskDisposesOnlyItsBrowserAndDoesNotResaveItsAddress() throws {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let firstKey = try XCTUnwrap(store.state(for: first).openBrowserTab())
        let secondKey = try XCTUnwrap(store.state(for: second).openBrowserTab())
        let firstBrowser = store.state(for: first).browserTabs.preview(for: firstKey)
        let secondBrowser = store.state(for: second).browserTabs.preview(for: secondKey)
        let firstView = WKWebView(frame: .zero), secondView = WKWebView(frame: .zero)
        firstBrowser.attach(firstView)
        secondBrowser.attach(secondView)
        firstBrowser.address = "localhost:8080/first"
        secondBrowser.address = "localhost:9090/second"
        store.persistNow()
        store.remove(for: first)
        firstBrowser.address = "a late callback"
        store.persistNow()
        XCTAssertNil(repository.load(for: first))
        XCTAssertNil(firstView.navigationDelegate)
        XCTAssertFalse(firstBrowser.hasAttachedWebView)
        XCTAssertTrue(secondView.navigationDelegate === secondBrowser)
        XCTAssertEqual(repository.load(for: second)?.browser?.pages?.map(\.address), ["localhost:9090/second"])
        XCTAssertEqual(repository.load(for: second)?.browser?.address, "localhost:9090/second",
                       "the page also goes where a build before side-panel browser tabs reads it")
        secondBrowser.terminateForApplicationShutdown()
    }

    /// A side chat is temporary: closing its tab says so, and its link is never saved, while the
    /// reading positions are. A snapshot saved with a side chat link reads as before without it.
    func testReadingPositionsSurviveRestartAndASideChatLinkEndsWithItsTab() throws {
        let repository = repository()
        let workspaces = TaskWorkspaceStore(repository: repository)
        var closed: [UUID] = []
        workspaces.onSideChatClose = { closed.append($0) }
        let parent = UUID(), child = UUID()
        let state = workspaces.state(for: parent)
        state.sideChatSessionID = child
        state.setPanels(.init(trailingSurfaceID: "sideChat", isTerminalPresented: true))
        workspaces.state(for: child).codex.bookmark = .init(anchorID: "side-turn-3", fraction: 0.2, followsLatest: false)
        XCTAssertEqual(closed, [])
        state.setPanels(.init(isTerminalPresented: true))
        XCTAssertEqual(closed, [parent])
        workspaces.persistNow()
        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertNil(restarted.state(for: parent).sideChatSessionID)
        XCTAssertNil(restarted.state(for: parent).panels.trailingSurfaceID)
        XCTAssertFalse(restarted.state(for: parent).terminalStartRequested)
        XCTAssertEqual(restarted.state(for: child).codex.bookmark.anchorID, "side-turn-3")
        let savedWithLink = Data("{\"version\":1,\"panels\":{\"isTerminalPresented\":false,\"trailingTabs\":[\"diff\"]},\"layout\":{\"panelWidth\":420,\"terminalHeight\":240,\"isExpanded\":false},\"transcript\":{\"fraction\":0,\"followsLatest\":true},\"codex\":{\"fraction\":0,\"followsLatest\":true},\"sideChatSessionID\":\"\(child.uuidString)\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(TaskWorkspaceSnapshot.self, from: savedWithLink).panels.trailingTabs, ["diff"])
    }

    private func repository() -> UserDefaultsTaskWorkspaceRepository {
        let suite = testDefaultsSuite("Yardlet.workspace-test")
        let defaults = UserDefaults(suiteName: suite)!
        return UserDefaultsTaskWorkspaceRepository(defaults: defaults)
    }

    /// Panels, expansion, reading positions and review choices stay with their task; the side
    /// panel's width and the terminal's height are one pair for every task, as the Codex app keeps
    /// them (`TaskWorkspaceSizesTests`).
    func testTaskPanelsAndReadingPositionsRemainIndependentAcrossRestartWhileSizesAreShared() {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let firstState = store.state(for: first)
        firstState.setPanels(.init(trailingSurfaceID: "diff", isTerminalPresented: true))
        firstState.layout = .init(panelWidth: 530, terminalHeight: 280, isExpanded: true)
        firstState.codex.bookmark = .init(anchorID: "turn-12", fraction: 0.42, followsLatest: false)
        firstState.review.selectedPath = "Sources/working.swift"
        firstState.review.scope = .staged
        firstState.review.selectedPath = "Sources/한글 👩🏽‍💻.swift"
        let secondState = store.state(for: second)
        secondState.setPanels(.init(trailingSurfaceID: TaskSurfaceNavigationProjection.browserTabID(UUID())))
        secondState.transcript.bookmark = .init(anchorID: "message-42", fraction: 0.71, followsLatest: false)
        secondState.review.selectedPath = "Other.txt"
        XCTAssertEqual(secondState.layout, .init(panelWidth: 530, terminalHeight: 280, isExpanded: false))
        XCTAssertTrue(store.state(for: first) === firstState)
        store.persistNow()
        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(restarted.sizes.sizes, .init(panelWidth: 530, terminalHeight: 280))
        XCTAssertEqual(restarted.state(for: first).snapshot, firstState.snapshot)
        XCTAssertEqual(restarted.state(for: second).snapshot, secondState.snapshot)
        XCTAssertTrue(restarted.state(for: first).layout.isExpanded)
        XCTAssertFalse(restarted.state(for: second).layout.isExpanded)
        XCTAssertTrue(restarted.state(for: first).transcript.bookmark.followsLatest)
        XCTAssertFalse(restarted.state(for: first).terminalStartRequested)
        XCTAssertEqual(restarted.state(for: first).review.scope, .staged)
        XCTAssertEqual(restarted.state(for: first).review.selectedPath, "Sources/한글 👩🏽‍💻.swift")
        restarted.state(for: first).review.scope = .unstaged
        XCTAssertEqual(restarted.state(for: first).review.selectedPath, "Sources/working.swift")
        XCTAssertEqual(restarted.state(for: second).review.selectedPath, "Other.txt")
    }

    func testWorkspaceBeforeReviewPreferencesPreservesExistingReadingPosition() throws {
        let previous = TaskWorkspaceSnapshot(
            panels: .init(trailingSurfaceID: "diff"),
            layout: .init(panelWidth: 640),
            transcript: .init(anchorID: "message-12", fraction: 0.5, followsLatest: false)
        )
        let encoded = try JSONEncoder().encode(previous)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"review\""))
        let decoded = try JSONDecoder().decode(TaskWorkspaceSnapshot.self, from: encoded)
        let state = TaskWorkspaceState(snapshot: decoded)
        XCTAssertEqual(state.panels.trailingSurfaceID, previous.panels.trailingSurfaceID)
        XCTAssertEqual(state.panels.trailingTabs, ["diff"])
        XCTAssertEqual(state.layout, previous.layout)
        XCTAssertEqual(state.transcript.bookmark, previous.transcript)
        XCTAssertEqual(state.review.scope, .unstaged)
        XCTAssertNil(state.review.selectedPath)
    }

    func testOnlyExplicitTerminalOpenRequestsAShell() {
        let state = TaskWorkspaceState(snapshot: .init(panels: .init(isTerminalPresented: true)))
        XCTAssertFalse(state.terminalStartRequested)
        state.setPanels(.init())
        state.setPanels(.init(isTerminalPresented: true))
        XCTAssertTrue(state.terminalStartRequested)
        state.terminalStartRequested = false // Leaving the mounted task ends its process lifetime.
        state.setPanels(.init(trailingSurfaceID: TaskSurfaceNavigationProjection.browserTabID(UUID()), isTerminalPresented: true))
        XCTAssertFalse(state.terminalStartRequested)
    }

    func testSavedPanelListOpensTheLauncherBesideTerminalWithoutStartingAShellOrLosingReview() throws {
        let repository = repository()
        let id = UUID()
        // Saved while the old panel list was showing, before side-panel tabs existed.
        var review = DiffReviewPreferences()
        review.scope = .staged
        review.selectedPath = "Sources/한글.swift"
        let previous = TaskWorkspaceSnapshot(
            panels: .init(trailingSurfaceID: "workspace", isTerminalPresented: true),
            codex: .init(anchorID: "turn-12", fraction: 0.42, followsLatest: false), review: review)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        json["panels"] = ["trailingSurfaceID": "workspace", "isTerminalPresented": true]
        repository.defaults.set(try JSONSerialization.data(withJSONObject: json),
                                forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        let restored = TaskWorkspaceStore(repository: repository).state(for: id)
        XCTAssertEqual(restored.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
        XCTAssertEqual(restored.panels.trailingTabs, [])
        XCTAssertTrue(restored.panels.isTerminalPresented)
        XCTAssertFalse(restored.terminalStartRequested)
        XCTAssertEqual(TaskFocusTarget.visibleContent(in: restored.panels), .launcher)
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        restored.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: restored.panels, targetID: toggle))
        XCTAssertNil(restored.panels.trailingSurfaceID)
        XCTAssertEqual(restored.panels.trailingTabs, [])
        XCTAssertTrue(restored.panels.isTerminalPresented)
        XCTAssertFalse(restored.terminalStartRequested)
        XCTAssertEqual(restored.review.scope, .staged)
        XCTAssertEqual(restored.review.selectedPath, "Sources/한글.swift")
        XCTAssertEqual(restored.codex.bookmark.anchorID, "turn-12")
    }

    func testEachTaskReopensItsOwnLastSidePanelTabAfterRestart() throws {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        let firstState = store.state(for: first)
        firstState.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: firstState.panels, targetID: toggle))
        XCTAssertEqual(firstState.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
        firstState.setPanels(TaskSurfaceNavigationProjection.showing("diff", in: firstState.panels))
        var panels = firstState.panels
        panels.trailingSurfaceID = "files" // A file link opens the Files tab beside Review.
        firstState.setPanels(panels)
        firstState.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: firstState.panels, targetID: toggle))
        let secondState = store.state(for: second)
        secondState.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: secondState.panels, targetID: "browser"))
        let browserTab = try XCTUnwrap(secondState.panels.trailingSurfaceID)
        XCTAssertNotNil(TaskSurfaceNavigationProjection.browserKey(inTab: browserTab), "⌘4 opens a browser tab")
        store.persistNow()

        let restarted = TaskWorkspaceStore(repository: repository)
        let firstRestored = restarted.state(for: first)
        XCTAssertNil(firstRestored.panels.trailingSurfaceID)
        XCTAssertEqual(firstRestored.panels.trailingTabs, ["diff", "files"])
        firstRestored.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: firstRestored.panels, targetID: toggle))
        XCTAssertEqual(firstRestored.panels.trailingSurfaceID, "files")
        XCTAssertEqual(restarted.state(for: second).panels.trailingSurfaceID, browserTab)
        XCTAssertEqual(restarted.state(for: second).panels.trailingTabs, [browserTab])
        let third = restarted.state(for: UUID())
        third.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: third.panels, targetID: toggle))
        XCTAssertEqual(third.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
    }

    /// Before the launcher, a panel that had never been used opened to Review on its own, so a task
    /// saved then whose only tab is Review opens to the launcher, once. Review chosen beside another
    /// tab, or saved since, stays.
    func testReviewTheOldFirstOpenAddedOnItsOwnGivesWayToTheLauncherOnce() throws {
        let repository = repository()
        let lone = UUID(), shownLone = UUID(), beside = UUID(), since = UUID()
        func save(_ snapshot: TaskWorkspaceSnapshot, for id: UUID) throws {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            json.removeValue(forKey: "panelsRevision")
            repository.defaults.set(try JSONSerialization.data(withJSONObject: json),
                                    forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        }
        try save(.init(panels: .init(trailingTabs: ["diff"], recentTrailingTabs: ["diff"])), for: lone)
        try save(.init(panels: .init(trailingSurfaceID: "diff", trailingTabs: ["diff"], recentTrailingTabs: ["diff"])),
                 for: shownLone)
        try save(.init(panels: .init(trailingTabs: ["diff", "browser"], recentTrailingTabs: ["browser", "diff"])),
                 for: beside)
        repository.save(.init(panels: .init(trailingTabs: ["diff"], recentTrailingTabs: ["diff"]),
                              panelsRevision: TaskWorkspaceSnapshot.launcherPanelsRevision), for: since)

        let store = TaskWorkspaceStore(repository: repository)
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        let loneState = store.state(for: lone)
        XCTAssertEqual(loneState.panels.trailingTabs, [])
        loneState.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: loneState.panels, targetID: toggle))
        XCTAssertEqual(loneState.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
        XCTAssertEqual(store.state(for: shownLone).panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
        let besideTabs = store.state(for: beside).panels.trailingTabs
        XCTAssertEqual(besideTabs.first, "diff")
        XCTAssertEqual(besideTabs.count, 2)
        XCTAssertNotNil(TaskSurfaceNavigationProjection.browserKey(inTab: besideTabs.last),
                        "the old Browser tab becomes a side-panel browser tab")
        XCTAssertEqual(store.state(for: since).panels.trailingTabs, ["diff"])

        // Saved again, the lone task keeps what it chose from then on.
        loneState.setPanels(TaskSurfaceNavigationProjection.showing("diff", in: loneState.panels))
        store.persistNow()
        XCTAssertEqual(TaskWorkspaceStore(repository: repository).state(for: lone).panels.trailingTabs, ["diff"])
    }

    func testCorruptAndFuturePreferencesUseSafeDefaults() {
        let repository = repository()
        let id = UUID()
        repository.defaults.set(Data("broken".utf8), forKey: "Yardlet.taskWorkspace.\(id.uuidString)")
        XCTAssertNil(repository.load(for: id))
        repository.save(.init(version: 2), for: id)
        XCTAssertNil(repository.load(for: id))
        let state = TaskWorkspaceState(snapshot: .init(
            panels: .init(trailingSurfaceID: "removed-panel"),
            layout: .init(panelWidth: .infinity, terminalHeight: -10)
        ))
        XCTAssertNil(state.panels.trailingSurfaceID)
        XCTAssertEqual(state.layout.panelWidth, 420)
        XCTAssertEqual(state.layout.terminalHeight, TaskWorkspaceSizes.minimumTerminalHeight)
    }

    func testRemovalCannotBeUndoneByAPendingSaveOrDetachedView() {
        let repository = InMemoryTaskWorkspaceRepository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID(), second = UUID()
        let detached = store.state(for: first)
        detached.setPanels(.init(trailingSurfaceID: TaskSurfaceNavigationProjection.browserTabID(UUID())))
        store.state(for: second).setPanels(.init(trailingSurfaceID: "diff"))
        store.remove(for: first)
        detached.layout.panelWidth = 600
        store.persistNow()
        XCTAssertNil(repository.snapshots[first])
        XCTAssertEqual(repository.snapshots[second]?.panels.trailingSurfaceID, "diff")
    }

    func testSelectionRestoresTaskOrHomeAndIgnoresMissingTask() {
        let repository = InMemoryTaskWorkspaceRepository()
        let first = session(), second = session()
        let sessions = SessionStore(sessions: [first, second])
        let store = TaskWorkspaceStore(repository: repository)
        store.rememberSelection(second.id)
        store.restoreSelection(in: sessions)
        XCTAssertEqual(sessions.selectedSessionID, second.id)
        store.rememberSelection(nil)
        store.restoreSelection(in: sessions)
        XCTAssertNil(sessions.selectedSessionID)
        store.rememberSelection(UUID())
        sessions.selectedSessionID = first.id
        store.restoreSelection(in: sessions)
        XCTAssertEqual(sessions.selectedSessionID, first.id)
    }

    func testModelRestoresSelectionAfterIndexAndFlushesBeforeShutdown() async throws {
        let repository = repository()
        let first = session(), second = session()
        repository.saveSelection(.task(second.id))
        let app = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [first, second])),
            runtimeSelections: RuntimeSelectionStore(defaults: repository.defaults,
                discoversRuntimes: false, loadsPersistedSelections: false),
            taskWorkspaceRepository: repository,
            sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0, isVisualFixture: true
        )
        XCTAssertNil(app.store.selectedSessionID)
        await app.restoreIndex()
        XCTAssertEqual(app.store.selectedSessionID, second.id)
        XCTAssertFalse(app.isAttached(second.id))
        app.taskWorkspaces.state(for: second.id).setPanels(.init(trailingSurfaceID: "diff"))
        await app.shutdown()
        XCTAssertEqual(repository.load(for: second.id)?.panels.trailingSurfaceID, "diff")
    }

    func testBookmarkUsesStableRowAndInternalPositionInsteadOfDocumentPercentage() {
        let frames = ["first": CGRect(x: 0, y: 24, width: 500, height: 400),
                      "second": CGRect(x: 0, y: 448, width: 500, height: 600)]
        let bookmark = TranscriptReadingTracker.bookmark(offset: 748, frames: frames, itemIDs: ["first", "second"])
        XCTAssertEqual(bookmark, .init(anchorID: "second", fraction: 0.5, followsLatest: false))
        XCTAssertEqual(TranscriptReadingTracker.bookmark(offset: 430, frames: frames, itemIDs: ["first", "second"])?.anchorID, "second")
    }

    func testStaleLazyFramesDoNotWinBookmarkOverVisibleMessageAfterLargeJump() {
        let record = TranscriptReadingPosition()
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["old-request", "old-answer", "long-answer"])
        tracker.measure(id: "old-request", frame: CGRect(x: 0, y: -8, width: 600, height: 26))
        tracker.measure(id: "old-answer", frame: CGRect(x: 0, y: 36, width: 600, height: 407))
        tracker.measure(id: "long-answer", frame: CGRect(x: 0, y: -1_200, width: 600, height: 2_400))
        // Prefetched rows retained their initial frames after a large jump.
        tracker.updateVisibleItems(["long-answer"])
        tracker.observe(offset: 9_000, height: 10_062, viewport: CGSize(width: 659, height: 531),
                        followsLatest: false, userDriven: true)
        tracker.settleGeometry()
        XCTAssertEqual(record.bookmark, .init(anchorID: "long-answer", fraction: 0.5, followsLatest: false))
    }

    func testVisibilityArrivingAfterScrollStillCapturesTheCurrentMessage() {
        let record = TranscriptReadingPosition()
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["answer"])
        tracker.updateVisibleItems([])
        tracker.measure(id: "answer", frame: CGRect(x: 0, y: -600, width: 600, height: 1_200))
        tracker.observe(offset: 600, height: 1_200, viewport: CGSize(width: 600, height: 400),
                        followsLatest: false, userDriven: true)
        tracker.settleGeometry()
        XCTAssertTrue(record.bookmark.followsLatest)
        tracker.updateVisibleItems(["answer"])
        tracker.settleGeometry()
        XCTAssertEqual(record.bookmark, .init(anchorID: "answer", fraction: 0.5, followsLatest: false))
    }

    func testRestorationFirstFindsLazyRowThenRestoresFractionAfterMeasurement() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "row", fraction: 0.25, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["row"])
        XCTAssertEqual(tracker.request, .anchor("row"))
        tracker.observe(offset: 0, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 1_000, width: 500, height: 800))
        tracker.settleGeometry()
        XCTAssertEqual(tracker.request, .offset(1_200))
        tracker.measure(id: "row", frame: CGRect(x: 0, y: -200, width: 500, height: 800))
        tracker.observe(offset: 1_200, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertFalse(tracker.isRestoring)
        XCTAssertEqual(tracker.visibleAnchorID, "row")
        XCTAssertNil(tracker.request)
        XCTAssertEqual(record.bookmark.fraction, 0.25)
    }

    func testReflowAndHiddenConversationDoNotEraseBookmark() {
        let (tracker, record) = restoredTracker()
        tracker.observe(offset: 0, height: 30_000, viewport: CGSize(width: 0, height: 400), followsLatest: false, userDriven: false)
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 0, width: 0, height: 10_000))
        XCTAssertEqual(record.bookmark.fraction, 0.25)
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 1_500, width: 350, height: 1_200))
        tracker.observe(offset: 0, height: 4_000, viewport: CGSize(width: 350, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(tracker.request, .offset(1_800))
        XCTAssertEqual(record.bookmark.anchorID, "row")
    }

    func testLatestResponseGrowthKeepsEarlierReadingAndLatestActionResumesFollowing() {
        let (tracker, record) = restoredTracker()
        tracker.observe(offset: 1_200, height: 8_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(record.bookmark, .init(anchorID: "row", fraction: 0.25, followsLatest: false))
        tracker.followLatest()
        XCTAssertEqual(tracker.request, .latest)
        XCTAssertTrue(record.bookmark.followsLatest)
    }

    func testHiddenLazyRowIsLocatedAgainWhenConversationReturns() {
        let (tracker, record) = restoredTracker()
        tracker.observe(offset: 0, height: 3_000, viewport: CGSize(width: 0, height: 400), followsLatest: false, userDriven: false)
        tracker.measure(id: "row", frame: nil)
        tracker.observe(offset: 0, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        XCTAssertEqual(tracker.request, .anchor("row"))
        XCTAssertEqual(record.bookmark.fraction, 0.25)
    }

    func testManualScrollCancelsPendingRestore() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "old", fraction: 0.9, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["old", "new"])
        tracker.measure(id: "new", frame: CGRect(x: 0, y: -400, width: 500, height: 800))
        tracker.observe(offset: 1_400, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: true)
        tracker.settleGeometry()
        XCTAssertFalse(tracker.isRestoring)
        XCTAssertEqual(record.bookmark, .init(anchorID: "new", fraction: 0.5, followsLatest: false))
    }

    func testRowReflowBeforeScrollGeometryDoesNotReplaceSavedReadingPosition() {
        let (tracker, record) = restoredTracker()
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 1_500, width: 350, height: 1_200))
        tracker.settleGeometry()
        XCTAssertEqual(record.bookmark.fraction, 0.25)
        tracker.observe(offset: 1_200, height: 8_000, viewport: CGSize(width: 350, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(tracker.request, .offset(3_000))
    }

    func testLazyTargetCanBeLocatedAgainAfterItsEstimatedHeightChanges() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "row", fraction: 0.25, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["row"])
        tracker.observe(offset: 900, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(tracker.anchorRevision, 1)
        tracker.observe(offset: 1_000, height: 3_500, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(tracker.anchorRevision, 2)
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 100, width: 500, height: 800))
        tracker.settleGeometry()
        XCTAssertEqual(tracker.request, .offset(1_300))
    }

    func testMissingSavedRowFallsBackToLatestAndInvalidFractionIsClamped() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "missing", fraction: 0.8, followsLatest: false)
        let missing = TranscriptReadingTracker()
        missing.start(record: record, itemIDs: ["available"])
        XCTAssertEqual(missing.request, .latest)
        record.bookmark = .init(anchorID: "available", fraction: .nan, followsLatest: false)
        let invalid = TranscriptReadingTracker()
        invalid.start(record: record, itemIDs: ["available"])
        invalid.measure(id: "available", frame: CGRect(x: 0, y: 100, width: 500, height: 200))
        invalid.observe(offset: 0, height: 800, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        invalid.settleGeometry()
        XCTAssertEqual(invalid.request, .offset(100))
    }

    func testTemporarilyClampedLazyHeightDoesNotCompleteReadingRestore() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "row", fraction: 0.25, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["before", "row", "after"])
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 100, width: 340, height: 800))
        tracker.observe(offset: 400, height: 1_000, viewport: CGSize(width: 340, height: 600), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertTrue(tracker.isRestoring)
        XCTAssertEqual(tracker.request, .anchor("row"))
        XCTAssertEqual(tracker.anchorRevision, 1)

        // Locating the message replaces the temporary document height with measured geometry.
        tracker.measure(id: "row", frame: CGRect(x: 0, y: 0, width: 340, height: 800))
        tracker.observe(offset: 1_000, height: 3_000, viewport: CGSize(width: 340, height: 600), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertEqual(tracker.request, .offset(1_200))
        tracker.measure(id: "row", frame: CGRect(x: 0, y: -200, width: 340, height: 800))
        tracker.observe(offset: 1_200, height: 3_000, viewport: CGSize(width: 340, height: 600), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertFalse(tracker.isRestoring)
        XCTAssertEqual(record.bookmark, .init(anchorID: "row", fraction: 0.25, followsLatest: false))
    }

    func testAnActuallyVisibleLastRowCanFinishAtTheDocumentBoundary() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "last", fraction: 0.8, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["first", "last"])
        tracker.measure(id: "last", frame: CGRect(x: 0, y: 100, width: 340, height: 200))
        tracker.observe(offset: 400, height: 1_000, viewport: CGSize(width: 340, height: 600), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertFalse(tracker.isRestoring)
        XCTAssertFalse(record.bookmark.followsLatest)
    }

    func testDelayedProgrammaticOffsetAfterReflowDoesNotResumeFollowing() {
        var state = TranscriptScrollFollowState()
        state.observe(distance: 800, userDriven: true)
        let before = TranscriptScrollMetrics(height: 3_000, viewport: CGSize(width: 500, height: 600), offset: 1_600, distance: 800)
        let after = TranscriptScrollMetrics(height: 3_000, viewport: before.viewport, offset: 2_400, distance: 0)
        state.observe(distance: after.distance, userDriven: after.isUserMovement(
            from: before, interacting: false, positionedByUser: false, restoring: false))
        XCTAssertFalse(state.isFollowing)
        // An actual accessibility/keyboard scroll still works without a tracking phase.
        state.observe(distance: after.distance, userDriven: after.isUserMovement(
            from: before, interacting: false, positionedByUser: true, restoring: false))
        XCTAssertTrue(state.isFollowing)
    }

    func testRepeatedMissingGeometryReleasesRestorationWithoutErasingBookmark() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "row", fraction: 0.5, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["row"])
        tracker.observe(offset: 0, height: 3_000, viewport: CGSize(width: 500, height: 600), followsLatest: false, userDriven: false)
        for _ in 0..<9 { tracker.settleGeometry() }
        XCTAssertFalse(tracker.isRestoring)
        XCTAssertNil(tracker.request)
        XCTAssertEqual(record.bookmark, .init(anchorID: "row", fraction: 0.5, followsLatest: false))
    }

    func testAnEstimatedShortDocumentCannotFinishBeforeItsLongLastMessageIsVisible() {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "only", fraction: 0.5, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["only"])
        tracker.measure(id: "only", frame: CGRect(x: 0, y: 24, width: 340, height: 1_200))
        tracker.observe(offset: 0, height: 400, viewport: CGSize(width: 340, height: 600), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        XCTAssertTrue(tracker.isRestoring)
        XCTAssertEqual(tracker.request, .anchor("only"))
    }

    private func restoredTracker() -> (TranscriptReadingTracker, TranscriptReadingPosition) {
        let record = TranscriptReadingPosition()
        record.bookmark = .init(anchorID: "row", fraction: 0.25, followsLatest: false)
        let tracker = TranscriptReadingTracker()
        tracker.start(record: record, itemIDs: ["row"])
        tracker.measure(id: "row", frame: CGRect(x: 0, y: -200, width: 500, height: 800))
        tracker.observe(offset: 1_200, height: 3_000, viewport: CGSize(width: 500, height: 400), followsLatest: false, userDriven: false)
        tracker.settleGeometry()
        return (tracker, record)
    }

    private func session() -> SessionRecord {
        SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/workspace-reading"),
                      runtimeExecutableURL: URL(filePath: "/tmp/no-runtime"), title: "Reading task")
    }
}
