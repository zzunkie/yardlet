import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The window's structure: the side panel's width and the terminal's height as the Codex app sizes its
/// right and bottom panels (ChatGPT.app 26.1016), a header per thing the window shows, and "Open in
/// Split View" from a sidebar task row (the Claude app's "Open in split view").
@MainActor
final class WindowStructureTests: XCTestCase {
    // MARK: - Side panel width

    /// `EZt`: max(320, min(height × 1.6, area − 500), min(640, area − 352)), within 320 and the area less
    /// the conversation's 560 and the divider.
    func testTheDefaultWidthIsTheCodexAppsForTheAreaAndTheWindow() {
        // A 1512 × 945 window beside a 240 sidebar and its line.
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 1271, windowHeight: 945, keepsRail: false), 705)
        // A short window: height × 1.6 is the smaller.
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 1700, windowHeight: 600, keepsRail: false), 960)
        // A 1280 × 760 window: the Codex app's 640 leaves the conversation less than its minimum.
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 1039, windowHeight: 760, keepsRail: false), 473)
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 700, windowHeight: 560, keepsRail: false), 320)
    }

    /// Where the rail is on and the area has room for it beside the panel (the rail, the conversation's
    /// 560 and the divider), the default leaves it that room; where it has none anyway, it does not.
    func testTheDefaultLeavesTheRailItsRoomWhereThereIsAny() {
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 1271, windowHeight: 945, keepsRail: true), 425)
        let metrics = TaskWorkspaceMetrics.resolve(
            size: CGSize(width: 1271, height: 800), trailing: true, terminal: false,
            preferredWidth: SidePanelWidth.standard(areaWidth: 1271, windowHeight: 945, keepsRail: true),
            preferredHeight: 280, rail: true)
        XCTAssertTrue(metrics.showsRail, "the rail stays beside the conversation when the panel opens")
        XCTAssertEqual(metrics.chatWidth, 560)
        // 1039 − 846 leaves less than the panel's 320: the rail has no room beside a panel there.
        XCTAssertEqual(SidePanelWidth.standard(areaWidth: 1039, windowHeight: 760, keepsRail: true), 473)
    }

    /// The dragged width is kept as the Codex app keeps it, a share of the room between 320 and the
    /// widest, so it follows the window; a width an earlier build saved is used as it is.
    func testADraggedWidthIsAShareThatFollowsTheArea() {
        let ratio = SidePanelWidth.ratio(width: 560, areaWidth: 1271)
        XCTAssertEqual(ratio, 240.0 / 385.0, accuracy: 1e-9)
        XCTAssertEqual(SidePanelWidth.width(ratio: ratio, areaWidth: 1271), 560, accuracy: 1e-9)
        XCTAssertEqual(SidePanelWidth.width(ratio: ratio, areaWidth: 1700), 320 + 814 * 240 / 385, accuracy: 1e-9)
        XCTAssertEqual(SidePanelWidth.ratio(width: 100, areaWidth: 1271), 0)
        XCTAssertEqual(SidePanelWidth.ratio(width: 5000, areaWidth: 1271), 1)
        XCTAssertEqual(SidePanelWidth.ratio(width: 400, areaWidth: 800), 0, "no room above the minimum")

        var preferences = TaskWorkspacePreferences()
        XCTAssertEqual(SidePanelWidth.resolve(preferences, areaWidth: 1271, windowHeight: 945, keepsRail: false), 705)
        preferences.panelWidth = 560
        XCTAssertEqual(SidePanelWidth.resolve(preferences, areaWidth: 1271, windowHeight: 945, keepsRail: false), 560)
        preferences.panelWidthRatio = 0.5
        XCTAssertEqual(SidePanelWidth.resolve(preferences, areaWidth: 1271, windowHeight: 945, keepsRail: false),
                       320 + 385 / 2)
    }

    /// Narrower than 160 on a drag the panel closes, as the Codex app's (`Rk(320)`); between that and
    /// 320 it stays 320. Lower than 80 the terminal closes (`Rk(160)`); between that and 160 it stays 160.
    func testDraggingAPanelPastHalfItsMinimumClosesIt() {
        XCTAssertEqual(TaskWorkspaceMetrics.sidePanelDrag(from: 500, by: 341, areaWidth: 1271), .close)
        XCTAssertEqual(TaskWorkspaceMetrics.sidePanelDrag(from: 500, by: 340, areaWidth: 1271), .size(320))
        XCTAssertEqual(TaskWorkspaceMetrics.sidePanelDrag(from: 500, by: -100, areaWidth: 1271), .size(600))
        XCTAssertEqual(TaskWorkspaceMetrics.sidePanelDrag(from: 500, by: -900, areaWidth: 1271), .size(705))

        XCTAssertEqual(TaskWorkspaceMetrics.terminalDrag(from: 280, by: 201, availableHeight: 700, trailing: false), .close)
        XCTAssertEqual(TaskWorkspaceMetrics.terminalDrag(from: 280, by: 200, availableHeight: 700, trailing: false), .size(160))
        XCTAssertEqual(TaskWorkspaceMetrics.terminalDrag(from: 280, by: -20, availableHeight: 700, trailing: false), .size(300))
    }

    // MARK: - Shared sizes

    private func repository() -> UserDefaultsTaskWorkspaceRepository {
        let suite = testDefaultsSuite("Yardlet.window-structure-test")
        let defaults = UserDefaults(suiteName: suite)!
        return UserDefaultsTaskWorkspaceRepository(defaults: defaults)
    }

    /// The terminal opens at the Codex app's 280; a task an earlier build saved at the earlier 240 the
    /// person never chose does not hold the shared height there.
    func testTheTerminalOpensAtTheCodexAppsHeightAndTheEarlierDefaultDoesNotSeed() {
        XCTAssertEqual(TaskWorkspaceSizes().terminalHeight, 280)
        let repository = repository()
        let earlier = UUID()
        repository.save(.init(layout: .init(panelWidth: 420, terminalHeight: 240)), for: earlier)
        let store = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(store.state(for: earlier).layout.terminalHeight, 280)
        XCTAssertEqual(store.sizes.sizes, .init())
    }

    /// The share is one for every task and saved with the other preferences.
    func testTheShareIsSharedAndSaved() {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        store.state(for: UUID()).layout.panelWidthRatio = 0.25
        XCTAssertEqual(store.state(for: UUID()).layout.panelWidthRatio, 0.25)
        store.persistNow()
        XCTAssertEqual(repository.loadSizes()?.panelWidthRatio, 0.25)
        XCTAssertEqual(TaskWorkspaceStore(repository: repository).state(for: UUID()).layout.panelWidthRatio, 0.25)
    }

    // MARK: - Headers

    func testAHeaderFoldsItsButtonsWhenItIsNarrow() {
        XCTAssertFalse(TaskHeaderFold.folds(headerWidth: 516))
        XCTAssertFalse(TaskHeaderFold.folds(headerWidth: 362))
        XCTAssertTrue(TaskHeaderFold.folds(headerWidth: 352))
        XCTAssertTrue(TaskHeaderFold.folds(headerWidth: 372, interfaceScale: 1.08))
    }

    // MARK: - Open in Split View

    private func readyStore() -> SplitStore {
        let store = SplitStore(repository: InMemorySplitRepository())
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        return store
    }

    func testOpenInSplitViewPutsTheTaskRightOfTheFocusedPane() throws {
        let store = readyStore()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertFalse(store.openInSplitView(a), "the new-task screen has no pane to put it beside")

        store.activate(.session(a))
        XCTAssertFalse(store.openInSplitView(a), "a task shown alone is in view already")
        XCTAssertTrue(store.openInSplitView(b))
        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(split.sessionIDs, [a, b])
        XCTAssertEqual(split.focusedSessionID, b)

        // From the left pane, the next goes between it and the right one.
        store.focusPane(try XCTUnwrap(split.pane(hosting: a)).id)
        XCTAssertTrue(store.openInSplitView(c))
        XCTAssertEqual(store.activeSplit?.sessionIDs, [a, c, b])
        XCTAssertEqual(store.activeSplit?.focusedSessionID, c)
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// A task the split view shows already keeps its pane, which takes the focus, rather than leaving
    /// an empty pane behind.
    func testOpenInSplitViewFocusesATaskTheSplitViewShowsAlready() throws {
        let store = readyStore()
        let a = UUID(), b = UUID()
        store.activate(.session(a))
        store.openInSplitView(b)
        XCTAssertTrue(store.openInSplitView(a))
        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(split.panes.count, 2)
        XCTAssertEqual(split.sessionIDs, [a, b])
        XCTAssertEqual(split.focusedSessionID, a)

        store.split(.right, placing: b)
        XCTAssertEqual(store.activeSplit?.panes.count, 2, "Split right with a shown task only focuses it")
        XCTAssertEqual(store.activeSplit?.focusedSessionID, b)
    }

    func testTheMenuItemReadsLikeTheClaudeApps() {
        XCTAssertEqual(L10n.string("Open in Split View", languageCode: "en"), "Open in Split View")
        XCTAssertEqual(L10n.string("Open in Split View", languageCode: "ko"), "분할 화면에서 열기")
    }
}
