import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The side panel's width and the terminal's height are one pair for every task, as the Codex app
/// keeps one right-panel width and one bottom-panel height for all its threads; and the View menu's
/// side panel (⌘⌥B, the Codex app's `toggleSidePanel`) and terminal (⌘J, both apps).
@MainActor
final class TaskWorkspaceSizesTests: XCTestCase {
    private func repository() -> UserDefaultsTaskWorkspaceRepository {
        let suite = testDefaultsSuite("Yardlet.workspace-sizes-test")
        let defaults = UserDefaults(suiteName: suite)!
        return UserDefaultsTaskWorkspaceRepository(defaults: defaults)
    }

    func testAWidthDraggedInOneTaskIsTheWidthTheNextTaskOpensAt() {
        let repository = repository()
        let store = TaskWorkspaceStore(repository: repository)
        let dragged = store.state(for: UUID())
        dragged.layout.panelWidth = 560
        dragged.layout.terminalHeight = 300
        let next = store.state(for: UUID())
        XCTAssertEqual(next.layout, .init(panelWidth: 560, terminalHeight: 300, isExpanded: false))
        XCTAssertNil(repository.loadSizes(), "the shared sizes are saved with the other preferences, not on every drag")
        store.persistNow()
        XCTAssertEqual(repository.loadSizes(), .init(panelWidth: 560, terminalHeight: 300))
        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(restarted.state(for: UUID()).layout.panelWidth, 560)
        XCTAssertEqual(restarted.state(for: UUID()).layout.terminalHeight, 300)
    }

    /// Until the shared sizes were saved once, the first task whose snapshot carries sizes of its
    /// own seeds them (a build before this one kept them per task); a later task's own sizes do
    /// not move them again, and once saved, the saved pair wins over every task's.
    func testSizesSeedOnceFromATaskThatKeptItsOwn() {
        let repository = repository()
        let first = UUID(), second = UUID()
        repository.save(.init(layout: .init(panelWidth: 560, terminalHeight: 300)), for: first)
        repository.save(.init(layout: .init(panelWidth: 700, terminalHeight: 400, isExpanded: true)), for: second)
        let store = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(store.sizes.sizes, .init())
        XCTAssertEqual(store.state(for: first).layout.panelWidth, 560)
        XCTAssertEqual(store.state(for: second).layout, .init(panelWidth: 560, terminalHeight: 300, isExpanded: true))
        store.persistNow()
        XCTAssertEqual(repository.loadSizes(), .init(panelWidth: 560, terminalHeight: 300))

        let restarted = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(restarted.state(for: second).layout.panelWidth, 560)
        XCTAssertEqual(restarted.state(for: first).layout.panelWidth, 560)
    }

    /// A task whose snapshot still says the defaults does not seed, so a task resized later can.
    func testATaskAtTheDefaultsLeavesSeedingToTheNextTask() {
        let repository = repository()
        let untouched = UUID(), resized = UUID()
        repository.save(.init(), for: untouched)
        repository.save(.init(layout: .init(panelWidth: 480)), for: resized)
        let store = TaskWorkspaceStore(repository: repository)
        XCTAssertEqual(store.state(for: untouched).layout.panelWidth, 420)
        XCTAssertEqual(store.state(for: resized).layout.panelWidth, 480)
        XCTAssertEqual(store.state(for: untouched).layout.panelWidth, 480)
    }

    func testSizesStayWithinTheLayoutsBoundsAndCorruptValuesTakeTheDefaults() {
        let store = TaskWorkspaceStore()
        let state = store.state(for: UUID())
        state.layout.panelWidth = 5000
        state.layout.terminalHeight = 10
        XCTAssertEqual(store.sizes.sizes, .init(panelWidth: 1600, terminalHeight: 160))
        state.layout.panelWidth = .nan
        XCTAssertEqual(store.sizes.sizes.panelWidth, 420)
        XCTAssertEqual(TaskWorkspaceSizeStore(.init(panelWidth: .infinity, terminalHeight: -10)).sizes,
                       .init(panelWidth: 420, terminalHeight: 160))
        XCTAssertEqual(TaskWorkspaceSizeStore(.init(terminalHeight: .nan, panelWidthRatio: 3)).sizes,
                       .init(terminalHeight: 280, panelWidthRatio: 1))
        XCTAssertNil(TaskWorkspaceSizeStore(.init(panelWidthRatio: .infinity)).sizes.panelWidthRatio)
    }

    /// A task drawn without a store (a render) keeps the sizes its snapshot carries.
    func testATaskOnItsOwnKeepsItsSnapshotsSizes() {
        let state = TaskWorkspaceState(snapshot: .init(layout: .init(panelWidth: 360, terminalHeight: 200, isExpanded: true)))
        XCTAssertEqual(state.layout, .init(panelWidth: 360, terminalHeight: 200, isExpanded: true))
        XCTAssertEqual(state.snapshot.layout, state.layout)
    }

    func testTheViewMenuTogglesTheSidePanelWithTheCodexAppsKeyAndTheTerminalWithBothAppsKey() {
        XCTAssertEqual(TaskCommandShortcut.toggleSidePanel.key, KeyEquivalent("b"))
        XCTAssertEqual(TaskCommandShortcut.toggleSidePanel.modifiers, [.command, .option])
        XCTAssertEqual(TaskCommandShortcut.toggleTerminal.key, KeyEquivalent("j"))
        XCTAssertEqual(TaskCommandShortcut.toggleTerminal.modifiers, .command)
        XCTAssertTrue(TaskCommandShortcut.all.contains(TaskCommandShortcut.toggleSidePanel))
        XCTAssertTrue(TaskCommandShortcut.all.contains(TaskCommandShortcut.toggleTerminal))
        XCTAssertEqual(TaskCommandTitle.sidePanel(isShown: false), L10n.string("Show side panel"))
        XCTAssertEqual(TaskCommandTitle.sidePanel(isShown: true), L10n.string("Hide side panel"))
        XCTAssertEqual(L10n.string("Show terminal", languageCode: "ko"), "터미널 보기")
        XCTAssertEqual(L10n.string("Hide terminal", languageCode: "ko"), "터미널 숨기기")
        XCTAssertEqual(L10n.string("Show side panel", languageCode: "ko"), "사이드 패널 보기")
    }
}
