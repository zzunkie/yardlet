import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders the sidebar's task states and the activity view offscreen into `.build/attention-qa`,
/// light and dark.
@MainActor
final class AttentionRenderingTests: XCTestCase {
    @MainActor
    private struct Fixture {
        var projects = ProjectStore()
        var sessions: [SessionRecord] = []
        var details: [UUID: TaskAttentionDetail] = [:]
        var splits: [SplitGroup] = []
        var collapsed: Set<String> = []
        var selected: SessionRecord?
        var monitor = TaskResourceMonitor(table: FakeProcessTable())
    }

    private func fixture() -> Fixture {
        let yardlet = URL(filePath: "/tmp/attention-qa/yardlet", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/attention-qa/website", directoryHint: .isDirectory)
        let docs = URL(filePath: "/tmp/attention-qa/docs", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: yardlet)
        let websiteProject = projects.ensureProject(forRoot: website, name: "Website")
        let docsProject = projects.ensureProject(forRoot: docs, name: "Docs")
        let now = Date()
        var minutes = 0.0
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, status: SessionStatus = .ready,
                  completion: SessionCompletionState = .none, unread: Bool = false) -> SessionRecord {
            minutes += 1
            return SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                                 title: title, titleOrigin: .provider, status: status,
                                 updatedAt: now.addingTimeInterval(-minutes * 60), hasUnreadUpdate: unread,
                                 completionState: completion)
        }
        let approval = task("Approve the index migration", .claudeCode, in: yardlet, status: .waitingForApproval,
                            unread: true)
        let question = task("Pick the icon set", .codex, in: yardlet, status: .running)
        let failed = task("Fix the flaky sampler test", .claudeCode, in: yardlet, status: .failed,
                          completion: .failed, unread: true)
        let limited = task("Run the full test suite", .claudeCode, in: yardlet, status: .completed,
                           completion: .completed)
        let running = task("Build the release bundle", .claudeCode, in: yardlet, status: .running)
        let unread = task("Summarize the crash reports", .codex, in: yardlet, status: .completed,
                          completion: .completed, unread: true)
        let idle = task("Tidy the README", .codex, in: yardlet)
        let splitLeft = task("Compare the parsers", .claudeCode, in: yardlet, status: .failed, completion: .failed)
        let splitRight = task("Benchmark the parsers", .codex, in: yardlet, status: .running)
        let websiteWaiting = task("Regenerate the screenshots", .claudeCode, in: website, status: .waitingForApproval)
        let websiteRunning = task("Fix the footer links", .codex, in: website, status: .running)
        let docsLimited = task("Translate the guide", .claudeCode, in: docs, status: .completed, completion: .completed)
        let docsUnread = task("Proofread the changelog", .codex, in: docs, status: .completed, completion: .completed,
                              unread: true)
        let sessions = [approval, question, failed, limited, running, unread, idle, splitLeft, splitRight,
                        websiteWaiting, websiteRunning, docsLimited, docsUnread]
        let limit = HarnessRateLimit(status: .rejected, window: .session,
                                     resetsAt: Calendar.current.date(byAdding: .hour, value: 3, to: now))
        let details: [UUID: TaskAttentionDetail] = [
            question.id: TaskAttentionDetail(pendingRequest: .input),
            approval.id: TaskAttentionDetail(pendingRequest: .approval),
            failed.id: TaskAttentionDetail(errorMessage: "Stream closed before the response finished"),
            limited.id: TaskAttentionDetail(usageLimit: limit),
            docsLimited.id: TaskAttentionDetail(usageLimit: limit),
        ]
        let rightPane = SplitPane(sessionID: splitRight.id)
        let split = SplitGroup(isPinned: false, anchorSessionID: splitLeft.id,
            root: .branch(axis: .horizontal, children: [.pane(SplitPane(sessionID: splitLeft.id)), .pane(rightPane)],
                          fractions: [1, 1]),
            focusedPaneID: rightPane.id)
        let monitor = TaskResourceMonitor(table: FakeProcessTable())
        monitor.describe = { owner in sessions.first { $0.id == owner.taskID }.map { ($0.harness, $0.title) } }
        monitor.apply([(running, 142.0), (websiteRunning, 64.0)].map { session, cpu in
            TaskResourceUsage(owner: .task(session.id), locations: [.yardlet], processCount: 4,
                              memoryBytes: 300 << 20, cpuPercent: cpu, isBusy: true)
        })
        let collapsed: Set<String> = [
            SidebarProjection.disclosureKey(for: WorkspaceGroup(workspaceURL: website, sessions: [], project: websiteProject)),
            SidebarProjection.disclosureKey(for: WorkspaceGroup(workspaceURL: docs, sessions: [], project: docsProject)),
        ]
        return Fixture(projects: projects, sessions: sessions, details: details, splits: [split], collapsed: collapsed,
                       selected: idle, monitor: monitor)
    }

    private func sidebar(_ fixture: Fixture, activity: SidebarActivity? = nil) -> some View {
        let groups = fixture.projects.visibleGroups(sessions: fixture.sessions)
        let selection = fixture.selected.map { WindowItem.session($0.id) } ?? .home
        let layout = SidebarProjection.layout(
            visibleGroups: groups, allGroups: groups, splits: fixture.splits, isFiltering: false,
            disclosure: SidebarDisclosure(collapsedKeys: fixture.collapsed), selection: selection)
        return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: selection,
            searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
            projects: fixture.projects, onEditProject: { _ in },
            onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
            onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
            activity: activity)
            .environment(fixture.monitor)
            .environment(\.taskAttentionDetails, fixture.details)
    }

    func testTheSidebarShowsEveryTaskStateAndSummarizesCollapsedRowsByTheMostUrgent() throws {
        let fixture = fixture()
        let directory = try WindowlessRender.directory("attention-qa")
        let groups = fixture.projects.visibleGroups(sessions: fixture.sessions)
        let layout = SidebarProjection.layout(
            visibleGroups: groups, allGroups: groups, splits: fixture.splits, isFiltering: false,
            disclosure: SidebarDisclosure(collapsedKeys: fixture.collapsed))
        XCTAssertEqual(layout.sections.map(\.isCollapsed), [false, true, true])
        func summary(_ section: SidebarSection) -> SidebarTaskStatus? {
            SidebarTaskIndicatorProjection.summary(of: section.allRows.flatMap(\.sessions), details: fixture.details)
        }
        XCTAssertEqual(summary(layout.sections[1]), .awaitingApproval)
        XCTAssertEqual(summary(layout.sections[2])?.urgency, SidebarTaskStatus.usageLimit(.init(status: .rejected)).urgency)
        let splitRow = try XCTUnwrap(layout.sections[0].rows.first { if case .split = $0.content { true } else { false } })
        XCTAssertEqual(SidebarTaskIndicatorProjection.summary(of: splitRow.sessions, details: fixture.details),
                       .failed(message: nil))

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 600)
        let captures = try WindowlessRender.hostedInBothAppearances("sidebar", in: directory, size: size) { appearance in
            sidebar(fixture)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }

        // Assistive apps hear the state, not "Running", for a task that waits.
        let host = WindowlessRender.Host(sidebar(fixture).frame(width: size.width, height: size.height, alignment: .top),
                                         size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let spoken = elements.map { "\($0.label) \($0.value)" }
        func says(_ title: String, _ state: String) -> Bool {
            spoken.contains { $0.contains(title) && $0.contains(state) } || spoken.contains(state)
        }
        XCTAssertTrue(says("Approve the index migration", L10n.string("Needs approval")), elements.description)
        XCTAssertTrue(says("Pick the icon set", L10n.string("Needs answer")), elements.description)
        XCTAssertTrue(says("Fix the flaky sampler test", L10n.string("Task encountered a system error")),
                      elements.description)
        XCTAssertTrue(says("Run the full test suite", L10n.string("Session limit reached")), elements.description)
        XCTAssertTrue(says("Summarize the crash reports", L10n.string("Unread response")), elements.description)
        XCTAssertFalse(spoken.contains { $0.contains("Approve the index migration") && $0.contains(L10n.string("Running")) })
        let website = try XCTUnwrap(elements.first { $0.label.contains("Website") })
        XCTAssertTrue(website.value.contains(L10n.string("Needs approval")), elements.description)
    }

    func testTheActivityViewListsTasksNeedingAttentionAcrossProjects() throws {
        let fixture = fixture()
        let directory = try WindowlessRender.directory("attention-qa")
        let listed = TaskAttentionProjection.activityList(in: fixture.sessions, details: fixture.details)
        XCTAssertEqual(listed.map(\.title), [
            "Approve the index migration", "Pick the icon set", "Regenerate the screenshots",
            "Fix the flaky sampler test", "Summarize the crash reports", "Proofread the changelog",
            "Build the release bundle", "Benchmark the parsers", "Fix the footer links",
        ])
        let groups = fixture.projects.visibleGroups(sessions: fixture.sessions)
        let names = Dictionary(groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        let activity = SidebarActivity(sessions: listed, selectedSessionID: listed[3].id,
                                       subtitle: { names[$0.id] ?? "" })
        XCTAssertTrue(activity.canMarkAllRead)
        XCTAssertEqual(activity.layout.rows.map(\.id), listed.map { .session($0.id) })
        XCTAssertEqual(activity.selection, .session(listed[3].id))

        let windowWidth = ParityTheme.sidebarWidth + 1 + 220
        let width = windowWidth + 1 + ParityTheme.sidebarWidth
        let size = NSSize(width: width, height: 600 + ParityTheme.titleBarHeight)
        let captures = try WindowlessRender.hostedInBothAppearances("activity", in: directory, size: size) { appearance in
            HStack(alignment: .top, spacing: 0) {
                // The window as the shell puts it together: the title bar's activity button on.
                ActivityWindowShowcase(sidebar: sidebar(fixture, activity: activity))
                    .frame(width: windowWidth, height: size.height, alignment: .top)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ActivityViewButton(toggle: ActivityViewToggle(isOn: false, needsAttention: false, toggle: {}))
                        ActivityViewButton(toggle: ActivityViewToggle(isOn: false, needsAttention: true, toggle: {}))
                        ActivityViewButton(toggle: ActivityViewToggle(isOn: true, needsAttention: true, toggle: {}))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    sidebar(Fixture(), activity: SidebarActivity(sessions: []))
                        .frame(width: ParityTheme.sidebarWidth, height: 220, alignment: .top)
                    Spacer(minLength: 0)
                }
                .frame(width: ParityTheme.sidebarWidth, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
            }
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(ParityTheme.sidebar)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }

        let toggle = ActivityViewToggle(isOn: false, needsAttention: true, toggle: {})
        XCTAssertEqual(toggle.accessibilityLabel, L10n.string("View activity, needs attention"))
        XCTAssertEqual(ActivityViewToggle(isOn: true, needsAttention: true, toggle: {}).accessibilityLabel,
                       L10n.string("Turn off activity view"))
        XCTAssertEqual(ActivityViewToggle(isOn: false, needsAttention: false, toggle: {}).help, L10n.string("View activity"))
    }
}

/// The title bar over the sidebar and an empty content area, as `MainWindow` puts them, with the
/// activity view on.
private struct ActivityWindowShowcase<Sidebar: View>: View {
    let sidebar: Sidebar
    @State private var panels = TaskSurfaceNavigationProjection.PanelState()
    @FocusState private var focusedSurface: TaskSurface?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TitleBarSidebarPart(isSidebarVisible: true, width: ParityTheme.sidebarWidth, onToggleSidebar: {},
                                    onNewTask: {},
                                    activityToggle: ActivityViewToggle(isOn: true, needsAttention: true, toggle: {}))
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                IntegratedTitleBar(
                    session: nil, isSidebarVisible: true, isAttached: false, showsSessionRail: false,
                    onToggleSessionRail: {}, panelState: $panels, focusedSurface: $focusedSurface,
                    onToggleSidebar: {}, onNewTask: {}, onResume: { _ in }, onRename: { _ in },
                    onTogglePinned: { _ in }, onArchive: { _ in }, onBackToConversation: { _ in }
                )
            }
            HStack(spacing: 0) {
                sidebar.frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ParityTheme.canvas
            }
        }
        .background(ParityTheme.canvas)
    }
}
