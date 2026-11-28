import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders the window's tab strip in the whole main window into `.build/window-tabs-render/`, light
/// and dark.
@MainActor
final class WindowTabStripRenderingTests: XCTestCase {
    private static let folder = "window-tabs-render"
    private static let size = NSSize(width: 1280, height: 760)

    private struct Fixture {
        let model: AppModel
        let running: SessionRecord
        let left: SessionRecord
        let right: SessionRecord
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-tabs-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("WindowTabStripRendering")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = URL(filePath: "/usr/bin/true")
        let running = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                    title: "Build the task tab strip", status: .running)
        let left = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                 title: "Check split view", hasUnreadUpdate: true)
        let right = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                  title: "Render check")
        let sessions = [running, left, right]
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        return Fixture(model: model, running: running, left: left, right: right)
    }

    private func window(_ model: AppModel, _ appearance: WindowlessRender.Appearance) -> some View {
        MainWindow(model: model)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    func testThreeTabsTheSplitViewsTabAndOneTab() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let fixture = try makeFixture()
        let splits = fixture.model.splits
        splits.activate(.session(fixture.running.id))
        splits.openInNewTab(.session(fixture.left.id))
        splits.combine(fixture.right.id, with: fixture.left.id)
        let split = try XCTUnwrap(splits.activeSplit)
        splits.newTab()
        splits.selectTab(.session(fixture.running.id))
        XCTAssertEqual(splits.tabs, [.session(fixture.running.id), .split(split.id), .home])

        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(window(fixture.model, appearance), size: Self.size, appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "three-tabs-\(appearance.suffix).png"))
            let elements = host.accessibilityElements()
            let labels = Set(elements.map(\.label))
            XCTAssertTrue(labels.contains(L10n.string("New Tab")), "the strip's new-tab button")
            for title in ["Build the task tab strip", "Check split view + Render check", L10n.string("New task")] {
                XCTAssertTrue(labels.contains(title), "tab \(title)")
            }
            XCTAssertTrue(labels.contains(L10n.format("Close tab %@", "Build the task tab strip")),
                          "the active tab shows its close button")

            splits.selectTab(.split(split.id))
            host.settle(passes: 20, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "split-tab-\(appearance.suffix).png"))
            XCTAssertEqual(fixture.model.store.selectedSessionID, fixture.right.id,
                           "the split's focused pane is the selected task")
            splits.selectTab(.session(fixture.running.id))
            host.close()
        }

        splits.closeOtherTabs()
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(window(fixture.model, appearance), size: Self.size, appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "one-tab-\(appearance.suffix).png"))
            XCTAssertFalse(host.accessibilityElements().map(\.label).contains(L10n.string("New Tab")),
                           "one tab draws no strip")
            host.close()
        }
    }

    /// The window's tabs beside a side panel's tabs in the title bar's row, and a split view alone in its
    /// window, whose top panes stand in for the title bar: the headers the person sees as one bar.
    func testTitleBarRowWithTheSidePanelAndASplitViewAlone() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let fixture = try makeFixture()
        let splits = fixture.model.splits
        splits.activate(.session(fixture.running.id))
        splits.openInNewTab(.session(fixture.left.id))
        splits.combine(fixture.right.id, with: fixture.left.id)
        let split = try XCTUnwrap(splits.activeSplit)
        splits.selectTab(.session(fixture.running.id))
        let workspace = fixture.model.taskWorkspaces.state(for: fixture.running.id)
        for id in ["files", TaskSurfaceNavigationProjection.browserTabID(UUID()), "diff"] {
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(id, in: workspace.panels))
        }

        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(window(fixture.model, appearance), size: Self.size, appearance: appearance)
            host.settle(passes: 30, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "tabs-and-panel-\(appearance.suffix).png"))
            host.close()
        }
        // A preset moves every surface together; the shown tabs keep their edge on its canvas.
        for (preset, appearance) in [(YardletAccentPreference.nord, WindowlessRender.Appearance.dark), (.ember, .light)] {
            let themed = window(fixture.model, appearance)
                .environment(\.yardletColorTheme, MacColorTheme(preset: preset))
            let host = WindowlessRender.Host(themed, size: Self.size, appearance: appearance)
            host.settle(passes: 30, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(
                path: "tabs-and-panel-\(preset.rawValue)-\(appearance.suffix).png"))
            host.close()
        }

        splits.selectTab(.split(split.id))
        splits.closeOtherTabs()
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(window(fixture.model, appearance), size: Self.size, appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "split-alone-\(appearance.suffix).png"))
            host.close()
        }
    }

    /// The tab bar over a task with its side panel, a split view in three panes with the focused one standing
    /// out, and one of its panes maximized, at a wide and a laptop window's width: the tab bar is a row of its
    /// own, the task's header and the panel's tabs a step down under it.
    func testTabBarOverTheHeaderAndTheFocusedPaneAtTwoWidths() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let fixture = try makeFixture()
        let splits = fixture.model.splits
        splits.activate(.session(fixture.running.id))
        splits.openInNewTab(.session(fixture.left.id))
        splits.combine(fixture.right.id, with: fixture.left.id)
        let split = try XCTUnwrap(splits.activeSplit)
        let workspace = fixture.model.taskWorkspaces.state(for: fixture.running.id)
        for id in ["files", "diff"] {
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(id, in: workspace.panels))
        }
        let sizes = [NSSize(width: 1440, height: 860), NSSize(width: 1200, height: 800)]

        func render(_ name: String) throws {
            for size in sizes {
                for appearance in WindowlessRender.Appearance.allCases {
                    let content = MainWindow(model: fixture.model)
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, appearance.colorScheme)
                    let host = WindowlessRender.Host(content, size: size, appearance: appearance)
                    host.settle(passes: 30, interval: 0.03)
                    try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(
                        path: "\(name)-\(Int(size.width))-\(appearance.suffix).png"))
                    host.close()
                }
            }
        }

        splits.selectTab(.session(fixture.running.id))
        try render("bar-task-panel")

        splits.selectTab(.split(split.id))
        try render("bar-split-two")

        splits.split(.right)
        XCTAssertEqual(splits.activeSplit?.panes.count, 3)
        splits.moveFocus(.left)
        try render("bar-split-three")

        splits.toggleMaximizedPane()
        let maximized = try XCTUnwrap(splits.maximizedPane)
        try render("bar-split-maximized")
        let host = WindowlessRender.Host(window(fixture.model, .light), size: Self.size, appearance: .light)
        host.settle(passes: 20, interval: 0.03)
        let labels = Set(host.accessibilityElements().map(\.label))
        XCTAssertTrue(labels.contains(SplitCommandTitle.maximize(isMaximized: true)), "the maximized pane restores the split view")
        XCTAssertEqual(host.accessibilityElements().filter { $0.label == L10n.string("Close pane") }.count, 1,
                       "only the maximized pane is drawn")
        XCTAssertEqual(maximized.id, splits.activeSplit?.focusedPaneID)
        host.close()
        splits.toggleMaximizedPane()
        XCTAssertEqual(splits.activeSplit?.panes.count, 3, "restoring keeps the split view's panes")
    }

    /// A press on what AppKit draws in a pane without the focus (a conversation's text, a terminal), which takes the
    /// press for itself and never lets the pane's tap see it, still gives the pane the focus (`PanePressMonitor`); a
    /// press in the other pane does not, and nothing watches once the pane has the focus.
    func testAPressOnAppKitTextInAnUnfocusedPaneFocusesThePane() throws {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        // The pane on the left, all of it text that takes the press.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.addSubview(text)
        let monitor = PanePressMonitorView(frame: text.frame)
        content.addSubview(monitor)
        var presses = 0
        monitor.onPress = { presses += 1 }
        monitor.isActive = true
        window.alphaValue = 0
        window.orderFrontRegardless()

        func press(at point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try press(at: NSPoint(x: 100, y: 100))
        XCTAssertEqual(presses, 1, "a press on the pane's text focuses the pane")
        try press(at: NSPoint(x: 300, y: 100))
        XCTAssertEqual(presses, 1, "a press in the other pane does not")
        // A popover or a palette over the pane is a window of its own: a press on it is not the pane's.
        let over = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        over.isReleasedWhenClosed = false
        over.contentView = NSView()
        over.alphaValue = 0
        window.addChildWindow(over, ordered: .above)
        defer { over.close() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: over.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(presses, 1, "a press on a window over the pane does not")
        monitor.isActive = false
        try press(at: NSPoint(x: 100, y: 100))
        XCTAssertEqual(presses, 1, "a focused pane is not watched")
    }

    func testTabsShareTheWidthAndTheShownTabKeepsItsTitleWhenNarrow() {
        XCTAssertEqual(WindowTabMetrics.widths(count: 2, available: 1000).shown, WindowTabMetrics.tabMaxWidth)
        XCTAssertEqual(WindowTabMetrics.widths(count: 5, available: 900).other,
                       (900 - WindowTabMetrics.inset * 2 - 4 * WindowTabMetrics.spacing) / 5)
        // In a narrow title bar the shown tab keeps its title's room and the others give way, to their marks.
        let narrow = WindowTabMetrics.widths(count: 4, available: 420)
        XCTAssertGreaterThanOrEqual(narrow.shown, WindowTabMetrics.shownMinWidth)
        XCTAssertLessThan(narrow.other, WindowTabMetrics.tabMinWidth)
        XCTAssertEqual(WindowTabMetrics.widths(count: 12, available: 500).other, WindowTabMetrics.markWidth)
    }
}
