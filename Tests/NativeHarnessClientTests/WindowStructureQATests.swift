import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The window's structure in each state it can be in, drawn in the whole main window, light and
/// dark, into `.build/window-structure-qa/`, with what the title bar offers in that state and what
/// its buttons act on (`report.md`): one task, several tabs, a split view with each pane focused and
/// with an empty pane focused, the new-task screen, a narrow window, the side panel and the terminal
/// open, scheduled tasks shown, and a split view whose panes are narrow.
///
/// No provider is contacted and no task attaches; the buttons are pressed through accessibility, as
/// VoiceOver presses them.
@MainActor
final class WindowStructureQATests: XCTestCase {
    private static let folder = "window-structure-qa"
    private static let size = NSSize(width: 1280, height: 760)

    private struct Fixture {
        let model: AppModel
        let running: SessionRecord
        let left: SessionRecord
        let right: SessionRecord
        let third: SessionRecord
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-structure-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("WindowStructureQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = URL(filePath: "/usr/bin/true")
        let running = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                    title: "Check panels from top-right buttons", status: .running)
        let left = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                 title: "Split view left task", hasUnreadUpdate: true)
        let right = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                  title: "Split view right task")
        let third = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                  title: "Third pane")
        let sessions = [running, left, right, third]
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
        return Fixture(model: model, running: running, left: left, right: right, third: third)
    }

    private func window(_ model: AppModel, _ appearance: WindowlessRender.Appearance, size: NSSize) -> some View {
        MainWindow(model: model)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    // MARK: - Accessibility with frames

    private struct Control {
        let role: String
        let label: String
        /// In the window, top-left origin.
        let frame: NSRect
        let object: AnyObject
    }

    private static func withEnhancedInterface<T>(_ body: () -> T) -> T {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        return body()
    }

    /// Every labelled element, buttons or not, with its frame.
    private func elements<Content: View>(in host: WindowlessRender.Host<Content>, buttonsOnly: Bool = true) -> [Control] {
        host.hosting.layoutSubtreeIfNeeded()
        let windowFrame = host.window.frame
        return Self.withEnhancedInterface {
            var found: [Control] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if let role = child.accessibilityRole?() ?? nil,
                       !buttonsOnly || [.button, .menuButton, .popUpButton, .checkBox].contains(role) {
                        let label = (child.accessibilityLabel?() ?? nil) ?? ""
                        let screen = child.accessibilityFrame?() ?? .zero
                        let frame = NSRect(x: screen.minX - windowFrame.minX,
                                           y: windowFrame.maxY - screen.maxY,
                                           width: screen.width, height: screen.height)
                        found.append(Control(role: role.rawValue, label: label, frame: frame, object: child))
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    private func controls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        elements(in: host)
    }

    /// The buttons in the title bar's band, left to right.
    private func titleBarControls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        controls(in: host)
            .filter { $0.frame.midY < ParityTheme.titleBarHeight && $0.frame.height > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The buttons in the split panes' headers, left to right: those on a Close pane button's line.
    private func paneHeaderControls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        let all = controls(in: host).filter { $0.frame.height > 0 && $0.frame.midY > ParityTheme.titleBarHeight }
        let lines = all.filter { $0.label == L10n.string("Close pane") }.map(\.frame.midY)
        return all.filter { control in lines.contains { abs($0 - control.frame.midY) < 6 } }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// Clicks and drags reach SwiftUI only in an ordered window: transparent and off screen.
    private func orderIn<Content: View>(_ host: WindowlessRender.Host<Content>) {
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 10, interval: 0.03)
    }

    @discardableResult
    private func press<Content: View>(_ control: Control?, in host: WindowlessRender.Host<Content>) -> Bool {
        guard let control else { return false }
        let pressed = Self.withEnhancedInterface { control.object.accessibilityPerformPress?() ?? false }
        host.settle(passes: 12, interval: 0.03)
        return pressed
    }

    @discardableResult
    private func press<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>,
                                      titleBar: Bool = true) -> Bool {
        let pool = titleBar ? titleBarControls(in: host) : controls(in: host)
        return press(pool.first(where: { $0.label == label }), in: host)
    }

    // MARK: - Pointer

    private func mouse<Content: View>(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1,
                                      in host: WindowlessRender.Host<Content>) {
        // The window's own coordinates: bottom-left origin.
        let location = NSPoint(x: point.x, y: host.window.frame.height - point.y)
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        if let event { host.window.sendEvent(event) }
        host.settle(passes: 3, interval: 0.02)
    }

    /// Drags from the middle of `control` by `offset` (top-left coordinates), in steps.
    private func drag<Content: View>(_ control: Control, by offset: CGSize, in host: WindowlessRender.Host<Content>) {
        let start = NSPoint(x: control.frame.midX, y: control.frame.midY)
        mouse(.leftMouseDown, at: start, in: host)
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            mouse(.leftMouseDragged, at: NSPoint(x: start.x + offset.width * fraction, y: start.y + offset.height * fraction),
                  in: host)
        }
        mouse(.leftMouseUp, at: NSPoint(x: start.x + offset.width, y: start.y + offset.height), in: host)
        host.settle(passes: 10, interval: 0.03)
    }

    private func doubleClick<Content: View>(_ control: Control, in host: WindowlessRender.Host<Content>) {
        let point = NSPoint(x: control.frame.midX, y: control.frame.midY)
        mouse(.leftMouseDown, at: point, clicks: 1, in: host)
        mouse(.leftMouseUp, at: point, clicks: 1, in: host)
        mouse(.leftMouseDown, at: point, clicks: 2, in: host)
        mouse(.leftMouseUp, at: point, clicks: 2, in: host)
        host.settle(passes: 10, interval: 0.03)
    }

    private func handle<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>) -> Control? {
        elements(in: host, buttonsOnly: false).first { $0.label == label && $0.frame.width > 0 }
    }

    // MARK: - Report

    private var report: [String] = []

    private func describe(_ state: String, _ controls: [Control], width: CGFloat, notes: [String] = []) {
        report.append("## \(state)")
        report.append("")
        let lines = controls.map { control -> String in
            let clipped = control.frame.maxX > width + 0.5 || control.frame.minX < -0.5 || control.frame.width < 4
            return "- \(control.label.isEmpty ? "(no name)" : control.label) [\(control.role)] "
                + "x \(Int(control.frame.minX))–\(Int(control.frame.maxX))\(clipped ? " **clipped/outside window**" : "")"
        }
        report.append(contentsOf: lines.isEmpty ? ["- (no buttons)"] : lines)
        for note in notes { report.append("- Check: \(note)") }
        report.append("")
    }

    private func draw<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                     _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=QA", "-c", "user.email=qa@example.test", "-c", "init.defaultBranch=main"]
            + arguments
        process.currentDirectoryURL = folder
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func panels(_ model: AppModel, _ id: UUID) -> TaskSurfaceNavigationProjection.PanelState {
        model.taskWorkspaces.state(for: id).panels
    }

    private func writeReport() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try (["# Header buttons per window state and what they act on", ""] + report).joined(separator: "\n")
            .write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - States

    func testEachWindowStatesHeadersAndWhatTheirButtonsActOn() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let splits = model.splits
        let terminal = TaskCommandTitle.terminal(isShown: false)
        let sidePanel = TaskCommandTitle.sidePanel(isShown: false)
        let more = L10n.string("More")
        let taskButtons: Set<String> = [terminal, sidePanel, TaskCommandTitle.terminal(isShown: true),
                                        TaskCommandTitle.sidePanel(isShown: true), more,
                                        L10n.string("Show session rail"), L10n.string("Hide session rail")]

        for appearance in WindowlessRender.Appearance.allCases {
            let light = appearance == .light
            // One task.
            splits.activate(.session(fixture.running.id))
            var host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                             appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "single", appearance)
            if light { describe("One task (1280×760)", titleBarControls(in: host), width: Self.size.width) }

            // The side panel and the terminal open from the title bar, at the Codex app's sizes.
            if light {
                XCTAssertTrue(press(sidePanel, in: host), "the title bar's side panel button")
                XCTAssertTrue(press(terminal, in: host), "the title bar's terminal button")
                XCTAssertNotNil(panels(model, fixture.running.id).trailingSurfaceID)
                XCTAssertTrue(panels(model, fixture.running.id).isTerminalPresented)
            } else {
                model.taskWorkspaces.state(for: fixture.running.id).setPanels(
                    .init(trailingSurfaceID: "diff", isTerminalPresented: true, trailingTabs: ["diff"],
                          recentTrailingTabs: ["diff"]))
                host.settle(passes: 12, interval: 0.03)
            }
            try draw(host, "single-panels-open", appearance)
            if light {
                let panelHandle = try XCTUnwrap(handle(L10n.string("Resize side panel"), in: host))
                let terminalHandle = try XCTUnwrap(handle(L10n.string("Resize terminal"), in: host))
                let panelWidth = Self.size.width - panelHandle.frame.maxX
                let terminalHeight = Self.size.height - terminalHandle.frame.maxY
                // 1280 × 760 beside a 240 sidebar: the Codex app's default, max(320, min(1216, 539), min(640, 687)).
                XCTAssertEqual(panelWidth, 640, accuracy: 1)
                XCTAssertEqual(terminalHeight, 280, accuracy: 1)
                var notes = ["Side panel width \(Int(panelWidth)) (Codex formula, was 420), terminal \(Int(terminalHeight)) (was 240)"]
                orderIn(host)

                // A drag past half the panel's minimum closes it, keeping the width it had.
                drag(panelHandle, by: CGSize(width: panelWidth - 120, height: 0), in: host)
                let panelClosed = panels(model, fixture.running.id).trailingSurfaceID == nil
                XCTAssertTrue(panelClosed, "a drag narrower than 160 closes the side panel")
                XCTAssertNil(model.taskWorkspaces.sizes.sizes.panelWidthRatio, "closing keeps the width it had")
                notes.append("Side panel handle dragged to width 120 → \(panelClosed ? "closed" : "unchanged"), saved width unchanged")
                XCTAssertTrue(press(sidePanel, in: host))
                // A drag that stays wide sets the share; a double click returns to the default.
                let reopened = try XCTUnwrap(handle(L10n.string("Resize side panel"), in: host))
                drag(reopened, by: CGSize(width: 100, height: 0), in: host)
                let ratio = model.taskWorkspaces.sizes.sizes.panelWidthRatio
                XCTAssertNotNil(ratio, "a drag keeps the width as a share")
                let draggedWidth = Self.size.width - (handle(L10n.string("Resize side panel"), in: host)?.frame.maxX ?? 0)
                notes.append("Dragged 100 right → width \(Int(draggedWidth)), share \(ratio.map { String(format: "%.3f", $0) } ?? "none") saved")
                if let dragged = handle(L10n.string("Resize side panel"), in: host) { doubleClick(dragged, in: host) }
                let resetWidth = Self.size.width - (handle(L10n.string("Resize side panel"), in: host)?.frame.maxX ?? 0)
                XCTAssertNil(model.taskWorkspaces.sizes.sizes.panelWidthRatio, "a double click returns to the default")
                XCTAssertEqual(resetWidth, 640, accuracy: 1)
                notes.append("Handle double-clicked → width \(Int(resetWidth)) (default)")

                // The terminal: lower than 80 closes it, keeping its height.
                let terminalNow = try XCTUnwrap(handle(L10n.string("Resize terminal"), in: host))
                drag(terminalNow, by: CGSize(width: 0, height: terminalHeight - 60), in: host)
                let terminalClosed = !panels(model, fixture.running.id).isTerminalPresented
                XCTAssertTrue(terminalClosed, "a drag lower than 80 closes the terminal")
                XCTAssertEqual(model.taskWorkspaces.sizes.sizes.terminalHeight, 280, "closing keeps the height it had")
                notes.append("Terminal handle dragged to height 60 → \(terminalClosed ? "closed" : "unchanged"), saved height \(Int(model.taskWorkspaces.sizes.sizes.terminalHeight))")
                XCTAssertTrue(press(terminal, in: host))
                let shortened = try XCTUnwrap(handle(L10n.string("Resize terminal"), in: host))
                drag(shortened, by: CGSize(width: 0, height: 180), in: host)
                let floor = Self.size.height - (handle(L10n.string("Resize terminal"), in: host)?.frame.maxY ?? 0)
                XCTAssertTrue(panels(model, fixture.running.id).isTerminalPresented)
                XCTAssertEqual(floor, 160, accuracy: 1)
                notes.append("Terminal dragged to height 100 → stays open at \(Int(floor)) (minimum)")
                if let low = handle(L10n.string("Resize terminal"), in: host) { doubleClick(low, in: host) }
                let restored = Self.size.height - (handle(L10n.string("Resize terminal"), in: host)?.frame.maxY ?? 0)
                XCTAssertEqual(restored, 280, accuracy: 1)
                notes.append("Terminal handle double-clicked → \(Int(restored)) (default)")

                // The sidebar's line: a drag widens the sidebar, a double click returns it to its standard width.
                // The line's middle is the sidebar's width; its frame is the wider area that takes the drag.
                let sidebarLine = try XCTUnwrap(handle(L10n.string("Resize sidebar"), in: host))
                drag(sidebarLine, by: CGSize(width: 80, height: 0), in: host)
                let widened = handle(L10n.string("Resize sidebar"), in: host)?.frame.midX ?? 0
                XCTAssertEqual(widened, SidebarWidth.standard + 80, accuracy: 1)
                if let line = handle(L10n.string("Resize sidebar"), in: host) { doubleClick(line, in: host) }
                let standard = handle(L10n.string("Resize sidebar"), in: host)?.frame.midX ?? 0
                XCTAssertEqual(standard, SidebarWidth.standard, accuracy: 1, "a double click returns the sidebar to its standard width")
                XCTAssertEqual(UserDefaults.yardlet.object(forKey: SidebarWidth.defaultsKey) as? Double, Double(SidebarWidth.standard))
                notes.append("Sidebar line dragged 80 right → width \(Int(widened)), double-clicked → \(Int(standard)) (standard)")
                UserDefaults.yardlet.removeObject(forKey: SidebarWidth.defaultsKey)
                describe("One task, side panel and terminal open", titleBarControls(in: host), width: Self.size.width, notes: notes)
            }
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(.init())
            host.close()

            // Several tabs, the split view's tab shown, the left pane focused, then the right.
            splits.activate(.session(fixture.running.id))
            splits.openInNewTab(.session(fixture.left.id))
            splits.combine(fixture.right.id, with: fixture.left.id)
            let split = try XCTUnwrap(splits.activeSplit)
            let leftPane = try XCTUnwrap(split.pane(hosting: fixture.left.id))
            let rightPane = try XCTUnwrap(split.pane(hosting: fixture.right.id))
            splits.newTab()
            splits.selectTab(.split(split.id))
            splits.focusPane(leftPane.id)
            host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                         appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "split-left-focused", appearance)
            if light {
                let titleBar = titleBarControls(in: host)
                let panes = paneHeaderControls(in: host)
                XCTAssertFalse(titleBar.contains { taskButtons.contains($0.label) }, "a split view's title bar has no task buttons")
                let rightTerminal = panes.last { $0.label == terminal }
                XCTAssertEqual(panes.filter { $0.label == terminal }.count, 2, "each pane's header has its buttons")
                XCTAssertTrue(press(rightTerminal, in: host))
                let leftHas = panels(model, fixture.left.id).isTerminalPresented
                let rightHas = panels(model, fixture.right.id).isTerminalPresented
                let focused = splits.activeSplit?.focusedPaneID == rightPane.id
                describe("Three tabs + split view (left pane focused): title bar", titleBar, width: Self.size.width)
                describe("Three tabs + split view (left pane focused): pane headers", panes, width: Self.size.width,
                         notes: ["Right pane header's terminal button → left task \(leftHas ? "open" : "closed"), right task \(rightHas ? "open" : "closed"), "
                                 + "focus \(focused ? "moved to the right pane" : "unchanged")"])
                XCTAssertFalse(leftHas)
                XCTAssertTrue(rightHas)
                XCTAssertTrue(focused, "a pane's button focuses its pane")
                model.taskWorkspaces.state(for: fixture.right.id).setPanels(.init())

                // The boundary between the panes follows the pointer.
                orderIn(host)
                let boundary = try XCTUnwrap(handle(L10n.string("Resize panes"), in: host))
                func leftShare() -> Double {
                    guard case let .branch(_, _, fractions)? = splits.activeSplit?.root else { return 0 }
                    return fractions[0]
                }
                let before = leftShare()
                drag(boundary, by: CGSize(width: 100, height: 0), in: host)
                let moved = (leftShare() - before) * Double(Self.size.width - 241 - SplitLayoutMetrics.handleThickness)
                XCTAssertEqual(moved, 100, accuracy: 2, "the pane boundary moves as far as the pointer")
                report.append("- Check: handle between panes dragged 100 right → boundary moved \(Int(moved.rounded())) (half before)")
                // A double click gives the two panes beside the line equal room.
                if let moved = handle(L10n.string("Resize panes"), in: host) { doubleClick(moved, in: host) }
                XCTAssertEqual(leftShare(), 0.5, accuracy: 0.001, "a double click on the pane boundary evens the two panes")
                report.append("- Check: handle between panes double-clicked → left share \(String(format: "%.3f", leftShare())) (even)")
                report.append("")
                splits.resize(at: [], fractions: [before, 1 - before])
            }
            splits.focusPane(rightPane.id)
            host.settle(passes: 12, interval: 0.03)
            if light {
                // From the right pane, the left pane's side panel button opens the left task's panel.
                let leftPanel = paneHeaderControls(in: host).first { $0.label == sidePanel }
                XCTAssertTrue(press(leftPanel, in: host))
                let leftHas = panels(model, fixture.left.id).trailingSurfaceID != nil
                let rightHas = panels(model, fixture.right.id).trailingSurfaceID != nil
                describe("Split view (right pane focused): pane headers", paneHeaderControls(in: host), width: Self.size.width,
                         notes: ["Left pane header's side panel button → left \(leftHas ? "open" : "closed"), right \(rightHas ? "open" : "closed")"])
                XCTAssertTrue(leftHas)
                XCTAssertFalse(rightHas)
                model.taskWorkspaces.state(for: fixture.left.id).setPanels(.init())
                splits.focusPane(rightPane.id)
            }
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(
                .init(trailingSurfaceID: "diff", trailingTabs: ["diff"], recentTrailingTabs: ["diff"]))
            host.settle(passes: 12, interval: 0.03)
            try draw(host, "split-right-focused-panel", appearance)
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(.init())

            // An empty pane focused: the other panes keep their buttons.
            splits.split(.down)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "split-empty-pane-focused", appearance)
            if light {
                let panes = paneHeaderControls(in: host)
                let leftTerminal = panes.first { $0.label == terminal }
                XCTAssertTrue(press(leftTerminal, in: host), "the left pane's terminal button")
                let leftHas = panels(model, fixture.left.id).isTerminalPresented
                describe("Split view (empty pane focused, right after ⌘⇧D): pane headers", panes, width: Self.size.width,
                         notes: ["Left pane header's terminal button → left task \(leftHas ? "open" : "closed")",
                                 "(the empty pane's header below has only \"New task\" and close)"])
                XCTAssertTrue(leftHas)
                model.taskWorkspaces.state(for: fixture.left.id).setPanels(.init())
                splits.split(.down)
            }
            splits.closePane()
            host.close()

            // The new-task screen.
            splits.selectTab(.home)
            host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                         appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "home", appearance)
            if light { describe("New task screen (tab)", titleBarControls(in: host), width: Self.size.width,
                                notes: ["Terminal and browser out of scope here (suggested as a separate task)"]) }
            host.close()
            splits.closeOtherTabs(than: .session(fixture.running.id))

            // Scheduled tasks shown in place of the task.
            host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                         appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            XCTAssertTrue(press(L10n.string("Scheduled tasks"), in: host, titleBar: false), "the sidebar's Scheduled tasks")
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "schedules", appearance)
            if light {
                let shown = titleBarControls(in: host)
                XCTAssertFalse(shown.contains { taskButtons.contains($0.label) }, "scheduled tasks show no task's buttons")
                describe("Scheduled tasks screen", shown, width: Self.size.width,
                         notes: ["No header or buttons for the hidden task in the title bar; View menu ⌘J, ⌘⌥B, ⌃⌘I, ⌘1–4 off too (code)"])
            }
            host.close()

            // A narrow window: the window's minimum, the sidebar as wide as it goes.
            let narrow = NSSize(width: 760, height: 560)
            UserDefaults.yardlet.set(Double(SidebarWidth.maximum), forKey: SidebarWidth.defaultsKey)
            splits.activate(.session(fixture.running.id))
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(
                .init(trailingSurfaceID: "diff", isTerminalPresented: true, trailingTabs: ["diff"],
                      recentTrailingTabs: ["diff"]))
            host = WindowlessRender.Host(window(model, appearance, size: narrow), size: narrow, appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "narrow-sidebar-wide", appearance)
            if light {
                let shown = titleBarControls(in: host)
                XCTAssertTrue(shown.contains { $0.label == more }, "a narrow title bar folds its buttons")
                describe("Narrow window 760×560, sidebar at max width, side panel and terminal open", shown, width: narrow.width,
                         notes: ["The three buttons fold into a \"More\" menu and the title gets more room"])
            }
            UserDefaults.yardlet.removeObject(forKey: SidebarWidth.defaultsKey)
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(.init())
            host.close()

            // Three panes side by side, each about a third of the content, a side panel open in one.
            for existing in splits.splits { splits.dissolve(existing.id) }
            splits.activate(.session(fixture.left.id))
            splits.split(.right, placing: fixture.right.id)
            splits.split(.right, placing: fixture.third.id)
            let three = try XCTUnwrap(splits.activeSplit)
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(
                .init(trailingSurfaceID: "diff", isTerminalPresented: true, trailingTabs: ["diff"],
                      recentTrailingTabs: ["diff"]))
            if let middle = three.pane(hosting: fixture.right.id) { splits.focusPane(middle.id) }
            host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                         appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "split-three-narrow-panes", appearance)
            if light {
                let panes = paneHeaderControls(in: host)
                // The right half was split again: the left pane keeps half, the other two a quarter each.
                XCTAssertEqual(panes.filter { $0.label == more }.count, 2, "the two narrow panes fold their buttons")
                XCTAssertEqual(panes.filter { $0.label == terminal }.count, 1, "the wide pane keeps its buttons")
                describe("Three panes (side panel and terminal in the middle pane): pane headers", panes, width: Self.size.width,
                         notes: ["Left pane (about 500) has three buttons, middle and right (about 260) \"More\". The middle one's side panel replaces its conversation (under 678)"])
            }
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(.init())
            splits.dissolve(three.id)
            host.close()
        }
        try writeReport()
    }

    /// 2026-10-24 (A layout, asked for so the tabs are the topmost header as in Codex and waste no space): the
    /// window's tabs are in the title bar, and a side panel beside the conversation reaches the window's top
    /// with its tabs in the title bar's row, or in a split view in the pane header's row. Tabs, panes and a
    /// side panel's tabs drag to new places with the pointer, and Esc cancels a drag. Drawn light and dark
    /// into `.build/window-structure-qa/` (`header-*`, `drag-*`), heights and moves in `header-and-drag.md`.
    func testTheTitleBarRowAndDraggingInTheWindow() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let splits = model.splits
        let browser = TaskSurfaceNavigationProjection.browserTabID(UUID())
        let panel = TaskSurfaceNavigationProjection.PanelState(
            trailingSurfaceID: browser, trailingTabs: ["diff", "files", browser], recentTrailingTabs: [browser, "files", "diff"])
        var notes: [String] = []

        /// The browser's page starts under its address bar (40, then a 1 pt line), whose Open button is in its middle.
        func pageTop<Content: View>(_ host: WindowlessRender.Host<Content>) -> CGFloat? {
            controls(in: host)
                .filter { $0.label == L10n.string("Open") && $0.frame.height > 0 }
                .max { $0.frame.minX < $1.frame.minX }
                .map { $0.frame.midY + 20 + 1 }
        }
        func inTitleBar(_ control: Control?) -> Bool {
            control.map { $0.frame.midY < ParityTheme.titleBarHeight } ?? false
        }

        // A change for the Review tab to count: one file, two lines added and one removed.
        let folder = fixture.running.workspaceURL
        try "a\nb\nc\n".write(to: folder.appending(path: "page.tsx"), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: folder)
        try git(["add", "."], in: folder)
        try git(["commit", "-qm", "first"], in: folder)
        try "a\nB\nc\nd\n".write(to: folder.appending(path: "page.tsx"), atomically: true, encoding: .utf8)
        let status = L10n.format("%d file · +%d −%d", 1, 2, 1)

        for appearance in WindowlessRender.Appearance.allCases {
            let light = appearance == .light
            // The Review tab alone beside the conversation, at a laptop window's widths: its title and its status
            // stay whole, as the strip's empty part, which moves the window, takes only the room they leave.
            // While that part was a flexible view it shared the room with the tabs: at 1360 the title read "…"
            // and the status was gone (2026-10-27, the public site's captures).
            for existing in splits.splits { splits.dissolve(existing.id) }
            splits.activate(.session(fixture.running.id))
            splits.closeOtherTabs(than: .session(fixture.running.id))
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(
                .init(trailingSurfaceID: "diff", trailingTabs: ["diff"], recentTrailingTabs: ["diff"]))
            for size in [NSSize(width: 1280, height: 760), NSSize(width: 1360, height: 840), NSSize(width: 1440, height: 900)] {
                let host = WindowlessRender.Host(window(model, appearance, size: size), size: size, appearance: appearance)
                // The Review tab reads Git in the background before it says what changed.
                host.settle(passes: 40, interval: 0.05)
                try draw(host, "header-review-\(Int(size.width))", appearance)
                let row = elements(in: host, buttonsOnly: false).filter { $0.frame.midY < ParityTheme.titleBarHeight }
                for (text, style) in [(L10n.string("Review"), NSFont.TextStyle.callout), (status, .caption1)] {
                    // The status is a text with no label: its words are its value, read as `WindowlessRender` reads one.
                    let shown = try XCTUnwrap(row.first { control in
                        let value = (control.object as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?
                            .takeUnretainedValue() as? String
                        return control.label == text || value == text
                    }, "\(text) in the title bar at \(Int(size.width))")
                    let natural = NSAttributedString(string: text, attributes: [.font: NSFont.preferredFont(forTextStyle: style)])
                        .size().width
                    XCTAssertGreaterThanOrEqual(shown.frame.width, natural - 1,
                                                "\(text) whole at \(Int(size.width)), \(appearance.suffix)")
                }
                host.close()
            }

            // Three tabs, a task shown with its side panel on a browser tab.
            for existing in splits.splits { splits.dissolve(existing.id) }
            splits.activate(.session(fixture.running.id))
            splits.closeOtherTabs(than: .session(fixture.running.id))
            splits.openInNewTab(.session(fixture.left.id))
            splits.newTab()
            splits.selectTab(.session(fixture.running.id))
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(panel)
            var host = WindowlessRender.Host(window(model, appearance, size: Self.size), size: Self.size,
                                             appearance: appearance)
            host.settle(passes: 30, interval: 0.03)
            try draw(host, "header-single-panel", appearance)
            if light {
                let all = controls(in: host)
                XCTAssertTrue(inTitleBar(all.first { $0.label == L10n.string("Close panel") }),
                              "the side panel's strip is in the title bar's row")
                XCTAssertTrue(inTitleBar(all.first { $0.label == fixture.left.title && $0.frame.minX > ParityTheme.sidebarWidth }),
                              "the window's tabs are in the title bar")
                let top = try XCTUnwrap(pageTop(host), "the browser's address bar")
                XCTAssertEqual(top, ParityTheme.titleBarHeight + 41, accuracy: 2)
                notes.append("One task + three tabs + side panel browser: page starts at \(Int(top.rounded())) pt "
                             + "(previous layout 34 + 50 + 42 + 41 = 167 pt)")
            }
            host.close()

            // A split view, the right pane's side panel open beside its conversation.
            model.taskWorkspaces.state(for: fixture.running.id).setPanels(.init())
            splits.selectTab(.session(fixture.left.id))
            splits.closeOtherTabs(than: .session(fixture.left.id))
            splits.split(.right, placing: fixture.right.id)
            let wide = NSSize(width: 1680, height: 900)
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(panel)
            host = WindowlessRender.Host(window(model, appearance, size: wide), size: wide, appearance: appearance)
            host.settle(passes: 30, interval: 0.03)
            try draw(host, "header-split-panel", appearance)
            if light {
                let all = controls(in: host)
                let paneLine = try XCTUnwrap(all.last { $0.label == L10n.string("Close pane") }).frame.midY
                let closePanel = try XCTUnwrap(all.first { $0.label == L10n.string("Close panel") })
                XCTAssertEqual(closePanel.frame.midY, paneLine, accuracy: 3, "the pane's panel strip is in its header's row")
                let top = try XCTUnwrap(pageTop(host))
                XCTAssertEqual(top, ParityTheme.titleBarHeight + SplitLayoutMetrics.paneHeaderHeight + 41, accuracy: 2)
                notes.append("Split view (1680×900), side panel browser in the right pane: page starts at \(Int(top.rounded())) pt "
                             + "(previous layout 50 + 36 + 42 + 41 = 169 pt, 34 pt more with two or more tabs)")
            }
            model.taskWorkspaces.state(for: fixture.right.id).setPanels(.init())
            host.close()
        }

        // The window's buttons stay centred on the title bar's row, which a task's area now draws: a window
        // with a title bar, as the app's (`.hiddenTitleBar`), transparent and off every screen.
        model.taskWorkspaces.state(for: fixture.right.id).setPanels(.init())
        let titled = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: Self.size.width, height: Self.size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        titled.isReleasedWhenClosed = false
        titled.titlebarAppearsTransparent = true
        titled.titleVisibility = .hidden
        // As the app's window group puts the window's content under its title bar.
        titled.contentView = NSHostingView(rootView: window(model, .light, size: Self.size)
            .ignoresSafeArea(.container, edges: .top))
        titled.alphaValue = 0
        titled.orderFrontRegardless()
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let close = try XCTUnwrap(titled.standardWindowButton(.closeButton))
        let buttonY = try XCTUnwrap(close.superview).convert(close.frame, to: nil).midY
        let fromTop = (titled.contentView?.bounds.height ?? 0) - buttonY
        XCTAssertEqual(fromTop, ParityTheme.titleBarHeight / 2, accuracy: 1.5)
        notes.append("Traffic light center: \(String(format: "%.1f", fromTop)) pt from the window top (middle of the 50 pt title row)")
        titled.close()

        // Dragging, with the pointer, in a window off every screen.
        for existing in splits.splits { splits.dissolve(existing.id) }
        splits.activate(.session(fixture.running.id))
        splits.closeOtherTabs(than: .session(fixture.running.id))
        splits.openInNewTab(.session(fixture.left.id))
        splits.newTab()
        splits.selectTab(.session(fixture.running.id))
        let host = WindowlessRender.Host(window(model, .light, size: Self.size), size: Self.size, appearance: .light)
        defer { host.close() }
        orderIn(host)
        host.settle(passes: 20, interval: 0.03)
        // The shown tab is a group holding its title's menu; the others are buttons.
        func tab(_ title: String) -> Control? {
            elements(in: host, buttonsOnly: false).first { $0.label == title && $0.frame.midY < ParityTheme.titleBarHeight
                && $0.frame.minX > ParityTheme.sidebarWidth && $0.frame.width > 30 }
        }
        func pointer(_ type: NSEvent.EventType, _ point: NSPoint) { mouse(type, at: point, in: host) }
        /// Presses at `from`, moves to `to` in steps, and leaves the pointer down there.
        func hold(from: NSPoint, to: NSPoint) {
            pointer(.leftMouseDown, from)
            for step in 1...10 {
                let f = CGFloat(step) / 10
                pointer(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
            }
            host.settle(passes: 8, interval: 0.03)
        }
        func release(_ at: NSPoint) {
            pointer(.leftMouseUp, at)
            host.settle(passes: 12, interval: 0.03)
        }
        let directory = try WindowlessRender.directory(Self.folder)
        func snapshot(_ name: String) throws {
            try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "\(name)-light.png"))
        }

        // The shown tab's title opens its menu: it drags by its mark, as Safari's compact active tab does.
        func mark(_ control: Control) -> NSPoint { NSPoint(x: control.frame.minX + 17, y: control.frame.midY) }
        func middle(_ control: Control) -> NSPoint { NSPoint(x: control.frame.midX, y: control.frame.midY) }

        // 1. A tab along the bar: the second tab before the first, which then shows.
        let first = try XCTUnwrap(tab(fixture.running.title), "the shown task's tab")
        let second = try XCTUnwrap(tab(fixture.left.title))
        let before = NSPoint(x: first.frame.minX + 8, y: first.frame.midY)
        hold(from: middle(second), to: before)
        try snapshot("drag-tab-sliding")
        release(before)
        XCTAssertEqual(splits.tabs, [.session(fixture.left.id), .session(fixture.running.id), .home])
        XCTAssertEqual(splits.selection, .session(fixture.left.id))
        notes.append("Back window tab dragged before the first → order [\(fixture.left.title), \(fixture.running.title), New task], dragged tab shown")

        // The shown tab by its mark, to the end of the bar.
        let shown = try XCTUnwrap(tab(fixture.left.title))
        let home = try XCTUnwrap(tab(L10n.string("New task")))
        let last = NSPoint(x: home.frame.maxX - 4, y: home.frame.midY)
        hold(from: mark(shown), to: last)
        try snapshot("drag-shown-tab")
        release(last)
        XCTAssertEqual(splits.tabs, [.session(fixture.running.id), .home, .session(fixture.left.id)])
        notes.append("Shown tab dragged by its icon to the end of the bar → [\(fixture.running.title), New task, \(fixture.left.title)]")

        // 2. Esc cancels a drag: the tab stays.
        let running = try XCTUnwrap(tab(fixture.running.title))
        let from = middle(running)
        hold(from: from, to: NSPoint(x: from.x + 300, y: from.y))
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: host.window.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(escape)
        }
        host.settle(passes: 6, interval: 0.03)
        release(NSPoint(x: from.x + 300, y: from.y))
        XCTAssertEqual(splits.tabs, [.session(fixture.running.id), .home, .session(fixture.left.id)], "Esc cancels the drag")
        XCTAssertEqual(splits.selection, .session(fixture.left.id))
        notes.append("Esc while dragging a window tab → order and shown tab unchanged after release")

        // 3. A task's tab onto the shown task's right side: the two make a split view.
        let runningTab = try XCTUnwrap(tab(fixture.running.title))
        let rightSide = NSPoint(x: Self.size.width - 40, y: Self.size.height / 2)
        hold(from: middle(runningTab), to: rightSide)
        try snapshot("drag-tab-to-pane")
        release(rightSide)
        let split = try XCTUnwrap(splits.activeSplit, "a task's tab dropped beside the shown task makes a split view")
        XCTAssertEqual(split.panes.map(\.sessionID), [fixture.left.id, fixture.running.id])
        XCTAssertEqual(splits.tabs, [.home, .split(split.id)])
        notes.append("Another task's window tab onto the shown task's right edge → split view [\(fixture.left.title) | \(fixture.running.title)], "
                     + "that task's tab merges into the split view's tab")

        // A pane's header: its free part, left of its buttons.
        func paneHandle(_ index: Int) throws -> NSPoint {
            let all = controls(in: host)
            let lines = all.filter { $0.label == L10n.string("Close pane") }.sorted { $0.frame.minX < $1.frame.minX }
            let line = try XCTUnwrap(lines.dropFirst(index).first, "pane \(index)'s header")
            let buttons = all.filter { abs($0.frame.midY - line.frame.midY) < 4 && $0.frame.maxX <= line.frame.maxX
                && $0.frame.minX >= (index == 0 ? ParityTheme.sidebarWidth : lines[index - 1].frame.maxX) }
                .sorted { $0.frame.minX < $1.frame.minX }
            // The task's title, which opens its actions.
            let title = try XCTUnwrap(buttons.first { $0.role == NSAccessibility.Role.menuButton.rawValue })
            let next = try XCTUnwrap(buttons.first { $0.frame.minX > title.frame.maxX + 1 })
            return NSPoint(x: next.frame.minX - 10, y: line.frame.midY)
        }
        func paneFrames() -> [CGRect] {
            elements(in: host, buttonsOnly: false).filter { $0.label == L10n.string("Pane") }.map(\.frame)
                .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        }

        // 4. A pane onto the other's middle: they swap.
        let panes = paneFrames()
        XCTAssertEqual(panes.count, 2)
        let handle = try paneHandle(0)
        let center = NSPoint(x: panes[1].midX, y: panes[1].midY)
        hold(from: handle, to: center)
        try snapshot("drag-pane-swap")
        release(center)
        XCTAssertEqual(splits.activeSplit?.panes.map(\.sessionID), [fixture.running.id, fixture.left.id])
        notes.append("Left pane header onto the right pane's middle → swapped")

        // 5. A pane onto the other's bottom edge: the split view stacks them.
        let below = NSPoint(x: panes[1].midX, y: panes[1].maxY - 30)
        hold(from: try paneHandle(0), to: below)
        try snapshot("drag-pane-edge")
        release(below)
        if case let .branch(axis, _, _)? = splits.activeSplit?.root {
            XCTAssertEqual(axis, .vertical)
        } else {
            XCTFail("A pane moved within a split of two ended the split")
        }
        XCTAssertEqual(splits.activeSplit?.panes.map(\.sessionID), [fixture.left.id, fixture.running.id])
        notes.append("Pane header onto the other pane's bottom edge → stacked (the two-pane split does not end)")

        // 6. A pane onto the tab bar: its task leaves the split view for a tab of its own.
        host.settle(passes: 12, interval: 0.03)
        let top = try XCTUnwrap(controls(in: host).filter { $0.label == L10n.string("Close pane") }
            .min { $0.frame.minY < $1.frame.minY })
        let topHandle = try XCTUnwrap(controls(in: host).filter { abs($0.frame.midY - top.frame.midY) < 4 }
            .first { $0.role == NSAccessibility.Role.menuButton.rawValue })
        let homeTab = try XCTUnwrap(tab(L10n.string("New task")))
        let grip = NSPoint(x: topHandle.frame.maxX + 60, y: top.frame.midY)
        let onBar = NSPoint(x: homeTab.frame.minX + 6, y: homeTab.frame.midY)
        hold(from: grip, to: onBar)
        try snapshot("drag-pane-to-tabs")
        release(onBar)
        XCTAssertNil(splits.activeSplit)
        XCTAssertEqual(splits.tabs, [.session(fixture.left.id), .home, .session(fixture.running.id)])
        XCTAssertEqual(splits.selection, .session(fixture.left.id))
        notes.append("Top pane header before the tab bar's \"New task\" tab → that task becomes its own tab and shows, the other stays alone in the split view's place")

        // 7. A side panel's tab along its strip.
        splits.activate(.session(fixture.running.id))
        model.taskWorkspaces.state(for: fixture.running.id).setPanels(panel)
        host.settle(passes: 30, interval: 0.03)
        let files = try XCTUnwrap(controls(in: host).first { $0.label == L10n.string("Files") && $0.frame.midY < ParityTheme.titleBarHeight })
        let closePanel = try XCTUnwrap(controls(in: host).first { $0.label == L10n.string("Close panel") })
        let end = NSPoint(x: closePanel.frame.minX - 60, y: files.frame.midY)
        hold(from: NSPoint(x: files.frame.midX, y: files.frame.midY), to: end)
        try snapshot("drag-panel-tab")
        release(end)
        XCTAssertEqual(panels(model, fixture.running.id).trailingTabs, ["diff", browser, "files"])
        XCTAssertEqual(panels(model, fixture.running.id).trailingSurfaceID, "files")
        notes.append("Side panel \"Files\" tab to the end of the strip → order [Review, Browser, Files], dragged tab shown")

        try (["# One-row header (option A) and dragging in the window", ""] + notes.map { "- " + $0 }).joined(separator: "\n")
            .write(to: directory.appending(path: "header-and-drag.md"), atomically: true, encoding: .utf8)
    }

    /// 2026-10-24 (a user reported that a message sent in an old task, with the sidebar scrolled down, moved the
    /// task to the top and out of sight): while the sidebar is scrolled away from its top, the shown task keeps its place and its
    /// project's when it becomes active; with the list at its top it goes where its activity puts it (`SidebarOrderHold`).
    /// The task is picked by pressing its row, the list is scrolled by its scroll view, into
    /// `.build/window-structure-qa/sidebar-hold-*.png`.
    func testTheShownTaskKeepsItsPlaceWhileTheSidebarIsScrolled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-hold-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("WindowStructureQA.hold")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = URL(filePath: "/usr/bin/true")
        let now = Date()
        var sessions: [SessionRecord] = []
        var folders: [URL] = []
        for project in 0..<10 {
            let folder = root.appending(path: "project-\(project)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
            for task in 0..<3 {
                sessions.append(SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                    title: "Task \(project)-\(task)", updatedAt: now.addingTimeInterval(-Double(project * 10 + task) * 60)))
            }
        }
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
        for (index, folder) in folders.enumerated() { _ = model.projects.ensureProject(forRoot: folder, name: "Project \(index)") }
        let target = try XCTUnwrap(sessions.first { $0.title == "Task 7-1" })
        let directory = try WindowlessRender.directory(Self.folder)

        let host = WindowlessRender.Host(window(model, .light, size: Self.size), size: Self.size, appearance: .light)
        defer { host.close() }
        orderIn(host)
        func row() -> Control? { elements(in: host).first { $0.label.hasPrefix(target.title) && $0.frame.height > 0 } }
        // The list scrolls to the task shown at launch at its next update, which a window off every screen
        // makes only when the list's rows change: a row marked unread and read again makes one now.
        await model.store.markUnread(id: sessions[0].id)
        host.settle(passes: 6, interval: 0.03)
        await model.store.markRead(id: sessions[0].id)
        host.settle(passes: 6, interval: 0.03)
        let firstRow = try XCTUnwrap(elements(in: host).first { $0.label.hasPrefix("Task 0-0") })
        let scroll = try XCTUnwrap(sidebarScrollView(in: host.hosting, x: firstRow.frame.midX))
        // Down to the task, short of the list's end: there the list's height, which it estimates for the rows
        // it has not drawn, can shorten and take the scroll back with it whatever the order does.
        let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 400, "The sidebar does not scroll far enough")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom - 250))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.settle(passes: 10, interval: 0.03)
        let before = try XCTUnwrap(row(), "The task's row is not in view")
        XCTAssertTrue(press(before, in: host))
        XCTAssertEqual(model.splits.selection, .session(target.id))
        let shown = try XCTUnwrap(row())
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "sidebar-hold-before-light.png"))

        // A message sent in it: its activity moves to now, ahead of every task.
        try await model.store.moveLastActivity(id: target.id, forwardTo: Date())
        host.settle(passes: 12, interval: 0.03)
        let held = try XCTUnwrap(row(), "The shown task left the list's view")
        XCTAssertEqual(held.frame.minY, shown.frame.minY, accuracy: 1, "The shown task moved")
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "sidebar-hold-after-light.png"))

        // At the list's top it goes where its activity puts it: its project first.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.settle(passes: 12, interval: 0.03)
        let top = try XCTUnwrap(row())
        let other = try XCTUnwrap(elements(in: host).first { $0.label.hasPrefix("Task 0-0") })
        XCTAssertLessThan(top.frame.minY, other.frame.minY, "At the top the task did not take its place by activity")
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "sidebar-hold-top-light.png"))
    }

    /// The scroll view whose list holds the point at `x`, the sidebar's.
    private func sidebarScrollView(in root: NSView, x: CGFloat) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(root).first { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return frame.minX <= x && x <= frame.maxX && frame.width <= ParityTheme.sidebarWidth + 1
                && (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height
        }
    }
}
