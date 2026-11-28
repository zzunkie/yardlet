import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Task Resource Usage offscreen into `.build/resource-usage-qa`, light and dark.
@MainActor
final class TaskResourceRenderingTests: XCTestCase {
    func testSidebarRowsShowTheCPUMarkOnlyForBusyTasks() throws {
        let directory = try WindowlessRender.directory("resource-usage-qa")
        let yardlet = URL(filePath: "/tmp/resource-usage-qa/yardlet-sandbox", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/resource-usage-qa/website", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: yardlet)
        let websiteProject = projects.ensureProject(forRoot: website, name: "Website")
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  status: SessionStatus = .ready, unread: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                          title: title, titleOrigin: .provider, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                          completionState: unread ? .completed : .none)
        }
        let heldByClaudeApp = task("Run the full test suite", .claudeCode, in: yardlet, minutesAgo: 1)
        let running = task("Build the release bundle", .claudeCode, in: yardlet, minutesAgo: 2, status: .running)
        let selected = task("Review the session index migration", .codex, in: yardlet, minutesAgo: 3)
        let unread = task("Summarize the crash reports", .claudeCode, in: yardlet, minutesAgo: 4,
                          status: .completed, unread: true)
        let idle = task("Tidy the README", .codex, in: yardlet, minutesAgo: 5)
        let websiteBusy = task("Regenerate the screenshots", .claudeCode, in: website, minutesAgo: 6, status: .running)
        let websiteIdle = task("Fix the footer links", .codex, in: website, minutesAgo: 7)
        let sessions = [heldByClaudeApp, running, selected, unread, idle, websiteBusy, websiteIdle]

        let monitor = Self.monitor(sessions: sessions, usages: [
            (heldByClaudeApp, 142, true), (running, 87, true), (unread, 3, false), (websiteBusy, 64, true)
        ])
        XCTAssertEqual(monitor.busyTaskCPU, [heldByClaudeApp.id: 142, running.id: 87, websiteBusy.id: 64])

        let disclosure = SidebarDisclosureStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("resource-qa"))))
        disclosure.collapse(SidebarProjection.disclosureKey(
            for: WorkspaceGroup(workspaceURL: website, sessions: [], project: websiteProject)))
        let groups = projects.visibleGroups(sessions: sessions)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: .session(selected.id))
        XCTAssertTrue(layout.sections[1].isCollapsed)

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 470)
        let captures = try WindowlessRender.hostedInBothAppearances("sidebar", in: directory, size: size) { appearance in
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .environment(monitor)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }

        // The rows say it to assistive apps too: busy rows carry the CPU in their value, idle ones do not.
        let host = WindowlessRender.Host(
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .environment(monitor)
                .frame(width: size.width, height: size.height, alignment: .top),
            size: size
        )
        defer { host.close() }
        host.settle()
        // A row with the running spinner exposes the spinner under the row's label instead of the
        // row's value (as before this change), so the rows checked here are ones without it.
        let elements = host.accessibilityElements()
        func value(of label: String) -> String? { elements.first { $0.label.hasPrefix(label) }?.value }
        XCTAssertEqual(value(of: heldByClaudeApp.title)?.contains(L10n.format("CPU %lld%%", 142)), true,
                       elements.description)
        XCTAssertEqual(value(of: unread.title)?.contains("CPU"), false, "A task that is not busy has no CPU mark")
        XCTAssertEqual(value(of: idle.title)?.contains("CPU"), false)
    }

    func testTheResourceListRendersHeaviestFirst() throws {
        let directory = try WindowlessRender.directory("resource-usage-qa")
        let folder = URL(filePath: "/tmp/resource-usage-qa/yardlet-sandbox", directoryHint: .isDirectory)
        func task(_ title: String, _ harness: HarnessKind) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                          title: title, titleOrigin: .provider)
        }
        let heavy = task("Run the full test suite", .claudeCode)
        let building = task("Build the release bundle", .claudeCode)
        let both = task("Fix the flaky sampler test", .claudeCode)
        let idle = task("Summarize the crash reports", .claudeCode)
        let monitor = TaskResourceMonitor(table: FakeProcessTable())
        let server = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: nil, environmentScope: .native))
        let sessions = [heavy, building, both, idle]
        monitor.describe = { owner in
            if case .codexAppServer = owner { return (.codex, L10n.format("Codex App Server · %@", "dev@example.test")) }
            return sessions.first { $0.id == owner.taskID }.map { ($0.harness, $0.title) }
        }
        monitor.apply([
            TaskResourceUsage(owner: .task(idle.id), locations: [.yardlet], processCount: 1, memoryBytes: 182 << 20,
                              cpuPercent: 0.4, isBusy: false),
            TaskResourceUsage(owner: server, locations: [.yardlet], processCount: 4, memoryBytes: 96 << 20,
                              cpuPercent: 3.1, isBusy: false),
            TaskResourceUsage(owner: .task(heavy.id), locations: [.claudeApp], processCount: 81,
                              memoryBytes: 6_700 << 20, cpuPercent: 1_143.26, isBusy: true),
            TaskResourceUsage(owner: .task(both.id), locations: [.yardlet, .claudeApp], processCount: 3,
                              memoryBytes: 410 << 20, cpuPercent: 12.5, isBusy: false),
            TaskResourceUsage(owner: .task(building.id), locations: [.yardlet], processCount: 9,
                              memoryBytes: 1_250 << 20, cpuPercent: 87.4, isBusy: true)
        ])
        XCTAssertEqual(monitor.rows.map(\.title), [heavy.title, building.title, both.title,
                                                   L10n.format("Codex App Server · %@", "dev@example.test"), idle.title])
        XCTAssertEqual(monitor.rows[2].location, "Yardlet, " + L10n.string("Claude app"))

        let size = NSSize(width: 720, height: 220)
        let captures = try WindowlessRender.hostedInBothAppearances("list", in: directory, size: size, passes: 12) { appearance in
            TaskResourceUsageWindow(monitor: monitor)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }

        let empty = TaskResourceMonitor(table: FakeProcessTable())
        try WindowlessRender.hostedInBothAppearances("list-empty", in: directory, size: NSSize(width: 720, height: 160)) {
            appearance in
            // The window behind the view, which the offscreen host does not draw.
            TaskResourceUsageWindow(monitor: empty)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 720, height: 160)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// A monitor that shows `usages` for `sessions`: the task, its CPU, and whether it is busy.
    private static func monitor(sessions: [SessionRecord],
                                usages: [(SessionRecord, Double, Bool)]) -> TaskResourceMonitor {
        let monitor = TaskResourceMonitor(table: FakeProcessTable())
        monitor.describe = { owner in
            sessions.first { $0.id == owner.taskID }.map { ($0.harness, $0.title) }
        }
        monitor.apply(usages.map { session, cpu, busy in
            TaskResourceUsage(owner: .task(session.id), locations: [.claudeApp], processCount: 4,
                              memoryBytes: 300 << 20, cpuPercent: cpu, isBusy: busy)
        })
        return monitor
    }
}
