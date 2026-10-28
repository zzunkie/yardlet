import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders a task's side panel offscreen into `.build/right-panel-qa`: the first open (the launcher), a
/// strip with several tabs, and a narrow panel, for Codex and Claude Code tasks. The Review tab reads
/// this checkout's Git state; no provider, app launch or window server interaction is involved.
@MainActor
final class RightPanelRenderingTests: XCTestCase {
    private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private var directory: URL { root.appending(path: ".build/right-panel-qa") }

    func testSidePanelOpensToContentWithItsTabStripForEveryHarness() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        for appearance in [ColorScheme.light, .dark] {
            let suffix = appearance == .dark ? "dark" : "light"

            // A task whose side panel was never used opens to the launcher, as the Codex app's does.
            let codex = session(.codex, title: "Fix the session index migration")
            let first = TaskWorkspaceState()
            first.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: first.panels, targetID: toggle))
            XCTAssertEqual(first.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
            try write(PanelHost(session: codex, workspace: first), appearance: appearance,
                      size: NSSize(width: 1180, height: 640), name: "first-open-codex-\(suffix).png")

            // The same for Claude Code, after Files and Browser were opened beside Review; the panel
            // was hidden and shown again, so it returns to the tab used last.
            let claude = session(.claudeCode, title: "Landing page copy")
            let tabs = TaskWorkspaceState()
            tabs.setPanels(TaskSurfaceNavigationProjection.showing("files", in: tabs.panels))
            let browserTab = TaskSurfaceNavigationProjection.browserTabID(UUID())
            tabs.setPanels(TaskSurfaceNavigationProjection.showing(browserTab, in: tabs.panels))
            tabs.setPanels(TaskSurfaceNavigationProjection.showing("diff", in: tabs.panels))
            tabs.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: tabs.panels, targetID: toggle))
            tabs.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: tabs.panels, targetID: toggle))
            XCTAssertEqual(tabs.panels.trailingSurfaceID, "diff")
            XCTAssertEqual(tabs.panels.trailingTabs, ["files", browserTab, "diff"])
            try write(PanelHost(session: claude, workspace: tabs), appearance: appearance,
                      size: NSSize(width: 1180, height: 640), name: "tabs-claude-\(suffix).png")

            // A narrow panel with every tab open, Files shown.
            let narrow = TaskWorkspaceState()
            for id in ["diff", TaskSurfaceNavigationProjection.browserTabID(UUID()), "sideChat", "files"] {
                narrow.setPanels(TaskSurfaceNavigationProjection.showing(id, in: narrow.panels))
            }
            narrow.layout.panelWidth = 360
            try write(PanelHost(session: codex, workspace: narrow), appearance: appearance,
                      size: NSSize(width: 980, height: 520), name: "narrow-codex-\(suffix).png")

            // The width dragged in one task is the width the next task's panel opens at, as the
            // Codex app keeps one right-panel width: the first task's panel was dragged to 560, and
            // a task opened afterwards shows its launcher at 560 rather than the 420 default.
            let store = TaskWorkspaceStore(repository: InMemoryTaskWorkspaceRepository())
            let dragged = store.state(for: UUID())
            dragged.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.browserTabID(UUID()),
                                                                      in: dragged.panels))
            dragged.layout.panelWidth = 560
            let next = store.state(for: UUID())
            next.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: next.panels, targetID: toggle))
            XCTAssertEqual(next.layout.panelWidth, 560)
            try write(PanelHost(session: claude, workspace: next), appearance: appearance,
                      size: NSSize(width: 1180, height: 640), name: "shared-width-next-task-\(suffix).png")
        }
    }

    private func session(_ harness: HarnessKind, title: String) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/usr/bin/false"),
                      title: title)
    }

    private func write<Content: View>(_ view: Content, appearance: ColorScheme, size: NSSize, name: String) throws {
        let host = WindowlessRender.Host(view
            .frame(width: size.width, height: size.height)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance), size: size, appearance: WindowlessRender.Appearance(appearance))
        defer { host.close() }
        // The Review tab reads Git in the background before it draws its diff.
        host.settle(passes: 40, interval: 0.05)
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: name))
    }
}

private struct PanelHost: View {
    let session: SessionRecord
    let workspace: TaskWorkspaceState
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            sideChat: AnyView(SideChatPanel(
                workspaceURL: session.workspaceURL, harness: session.harness, childID: nil, isLoading: false,
                errorMessage: nil, parentFocus: workspace.keyboardFocus, childFocus: nil, onCreate: {}, onClose: {},
                content: nil)),
            onOpenSideChat: {},
            session: session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, entries: [], errorMessage: nil, codexTaskState: nil,
            codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty, providerCapabilities: nil,
            providerUsage: nil, isProviderAttached: false, onShowCodexCapabilities: {},
            conversationActions: ConversationActions(retryTurn: { _ in }, showHarnessSettings: {}),
            composerActions: ComposerActions(
                submitCodex: { _, _ in }, removeQueued: { _ in }, retryQueued: { _ in }, moveQueued: { _, _ in },
                sendQueuedNow: { _ in }, editQueued: { _ in nil }, resumeQueue: {}
            )
        )
        .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
    }
}
