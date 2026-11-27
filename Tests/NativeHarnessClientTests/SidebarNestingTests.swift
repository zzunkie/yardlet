import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Task rows nested under their project as in the Codex app: collapse remembered per project,
/// five rows before "Show more", "No chats" for an empty project, pinned and searched rows
/// unaffected, and Yardlet fallback titles shown without the project's name under it.
final class SidebarNestingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)

    private func task(
        _ title: String, in folder: URL, minutesAgo: Double, harness: HarnessKind = .codex,
        titleOrigin: SessionTitleOrigin = .provider, isPinned: Bool = false, projectID: UUID? = nil,
        origin: URL? = nil, worktree: String? = nil, status: SessionStatus = .ready, unread: Bool = false,
        parent: SessionRecord? = nil
    ) -> SessionRecord {
        SessionRecord(
            harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
            title: title, titleOrigin: titleOrigin, status: status, updatedAt: base.addingTimeInterval(-minutesAgo * 60),
            hasUnreadUpdate: unread, isPinned: isPinned, projectID: projectID,
            originWorkspacePath: origin?.path(percentEncoded: false), worktreeName: worktree, parentTaskID: parent?.id
        )
    }

    private let alpha = URL(filePath: "/tmp/sidebar-nesting/alpha", directoryHint: .isDirectory)
    private let beta = URL(filePath: "/tmp/sidebar-nesting/beta", directoryHint: .isDirectory)
    private let empty = URL(filePath: "/tmp/sidebar-nesting/empty", directoryHint: .isDirectory)

    private func groups(_ sessions: [SessionRecord], projects: [Project]) -> [WorkspaceGroup] {
        ProjectProjection.visibleGroups(sessions: sessions, projects: projects)
    }

    // MARK: - Projection

    func testProjectsNestTheirTasksAndAnEmptyProjectShowsNoChats() throws {
        let projects = [Project(name: "Alpha", primaryRoot: alpha), Project(name: "Empty", primaryRoot: empty),
                        Project(name: "Beta", primaryRoot: beta)]
        let a1 = task("Newest", in: alpha, minutesAgo: 1, harness: .claudeCode)
        let a2 = task("Older", in: alpha, minutesAgo: 5)
        let b1 = task("Beta task", in: beta, minutesAgo: 3)
        let all = groups([a1, a2, b1], projects: projects)
        let layout = SidebarProjection.layout(visibleGroups: all, allGroups: all, splits: [], isFiltering: false,
                                              disclosure: SidebarDisclosure(rowLimit: 5))

        XCTAssertEqual(layout.sections.map(\.group.displayName), ["Alpha", "Beta", "Empty"])
        XCTAssertEqual(layout.sections[0].rows.map(\.id), [.session(a1.id), .session(a2.id)])
        XCTAssertFalse(layout.sections[0].showsEmptyState)
        XCTAssertEqual(layout.sections[0].hiddenRowCount, 0)
        let emptySection = try XCTUnwrap(layout.sections.last)
        XCTAssertTrue(emptySection.rows.isEmpty)
        XCTAssertTrue(emptySection.showsEmptyState)
        XCTAssertEqual(emptySection.disclosureKey, "project:\(projects[1].id.uuidString)")
        XCTAssertEqual(layout.sections[1].disclosureKey, "project:\(projects[2].id.uuidString)")
        XCTAssertEqual(layout.rows.map(\.id), [.session(a1.id), .session(a2.id), .session(b1.id)])

        // A project whose only task is pinned has tasks, so it lists nothing rather than "No chats".
        let pinnedOnly = groups([task("Pinned", in: empty, minutesAgo: 1, isPinned: true)], projects: projects)
        let pinnedLayout = SidebarProjection.layout(visibleGroups: pinnedOnly, allGroups: pinnedOnly, splits: [],
                                                    isFiltering: false, disclosure: SidebarDisclosure(rowLimit: 5))
        XCTAssertEqual(pinnedLayout.sections.map(\.group.displayName), ["Empty", "Alpha", "Beta"])
        XCTAssertFalse(pinnedLayout.sections[0].showsEmptyState)
        XCTAssertTrue(pinnedLayout.sections[1].showsEmptyState)
    }

    func testACollapsedProjectListsNoRowsAndKeyboardOrderSkipsThem() {
        let project = Project(name: "Alpha", primaryRoot: alpha)
        let a1 = task("A1", in: alpha, minutesAgo: 1)
        let a2 = task("A2", in: alpha, minutesAgo: 2)
        let b1 = task("B1", in: beta, minutesAgo: 3)
        let pinned = task("Pinned in alpha", in: alpha, minutesAgo: 4, isPinned: true)
        let all = groups([a1, a2, b1, pinned], projects: [project, Project(name: "Beta", primaryRoot: beta)])
        let key = "project:\(project.id.uuidString)"
        let disclosure = SidebarDisclosure(collapsedKeys: [key], rowLimit: 5)
        let layout = SidebarProjection.layout(visibleGroups: all, allGroups: all, splits: [], isFiltering: false,
                                              disclosure: disclosure)

        let alphaSection = layout.sections[0]
        XCTAssertTrue(alphaSection.isCollapsed)
        XCTAssertTrue(alphaSection.rows.isEmpty)
        XCTAssertEqual(alphaSection.allRows.map(\.id), [.session(a1.id), .session(a2.id)])
        XCTAssertFalse(alphaSection.showsEmptyState, "A collapsed project shows nothing under it")
        XCTAssertEqual(alphaSection.hiddenRowCount, 0)
        // A pinned task stays in Pinned whether its project is open or not.
        XCTAssertEqual(layout.pinned.map(\.id), [.session(pinned.id)])
        XCTAssertEqual(layout.rows.map(\.id), [.session(pinned.id), .session(b1.id)])
        XCTAssertEqual(
            SidebarProjection.adjacentRow(in: layout, selected: .session(pinned.id), offset: 1), .session(b1.id)
        )
        // The project holding the shown task is found though it lists nothing, so going to that
        // task can open it; a pinned task belongs to no project.
        XCTAssertEqual(SidebarProjection.section(holding: .session(a2.id), in: layout)?.disclosureKey, key)
        XCTAssertNil(SidebarProjection.section(holding: .session(pinned.id), in: layout))

        // A search lists every match, collapsed project or not.
        let filtered = TaskNavigationProjection.filteredGroups(in: all, query: "A2")
        let searched = SidebarProjection.layout(visibleGroups: filtered, allGroups: all, splits: [], isFiltering: true,
                                                disclosure: disclosure)
        XCTAssertEqual(searched.rows.map(\.id), [.session(a2.id)])
        XCTAssertFalse(searched.sections[0].isCollapsed)
    }

    func testFiveRowsShowBeforeShowMoreAndEachShowMoreAddsTen() throws {
        let many = (0..<18).map { task("Task \($0)", in: alpha, minutesAgo: Double($0)) }
        let alphaProject = [Project(name: "Alpha", primaryRoot: alpha)]
        let all = groups(many, projects: alphaProject)
        let key = SidebarProjection.disclosureKey(for: all[0])

        func section(_ disclosure: SidebarDisclosure, selection: WindowItem? = nil) -> SidebarSection {
            SidebarProjection.layout(visibleGroups: all, allGroups: all, splits: [], isFiltering: false,
                                     disclosure: disclosure, selection: selection).sections[0]
        }
        let limited = section(SidebarDisclosure(rowLimit: SidebarDisclosure.codexRowLimit))
        XCTAssertEqual(limited.rows.map(\.title), (0..<5).map { "Task \($0)" })
        XCTAssertEqual(limited.hiddenRowCount, 13)

        let once = section(SidebarDisclosure(revealedPages: [key: 1], rowLimit: 5))
        XCTAssertEqual(once.rows.count, 15)
        XCTAssertEqual(once.hiddenRowCount, 3)
        let twice = section(SidebarDisclosure(revealedPages: [key: 2], rowLimit: 5))
        XCTAssertEqual(twice.rows.count, 18)
        XCTAssertEqual(twice.hiddenRowCount, 0)

        // The shown task stays listed past the limit, after the first five.
        let selected = section(SidebarDisclosure(rowLimit: 5), selection: .session(many[12].id))
        XCTAssertEqual(selected.rows.map(\.title), (0..<5).map { "Task \($0)" } + ["Task 12"])
        XCTAssertEqual(selected.hiddenRowCount, 12)

        // One row left behind "Show more" is listed instead.
        let six = groups(Array(many.prefix(6)), projects: alphaProject)
        let sixLayout = SidebarProjection.layout(visibleGroups: six, allGroups: six, splits: [], isFiltering: false,
                                                 disclosure: SidebarDisclosure(rowLimit: 5))
        XCTAssertEqual(sixLayout.sections[0].rows.count, 6)
        XCTAssertEqual(sixLayout.sections[0].hiddenRowCount, 0)
        let seven = groups(Array(many.prefix(7)), projects: alphaProject)
        let sevenSelected = SidebarProjection.layout(
            visibleGroups: seven, allGroups: seven, splits: [], isFiltering: false,
            disclosure: SidebarDisclosure(rowLimit: 5), selection: .session(many[6].id)
        )
        XCTAssertEqual(sevenSelected.sections[0].rows.map(\.title), (0..<7).map { "Task \($0)" })
    }

    func testWorktreeTasksNestUnderTheProjectTheyCameFrom() {
        let project = Project(name: "Alpha", primaryRoot: alpha)
        let worktreeFolder = URL(filePath: "/tmp/yardlet-worktrees/alpha/fix-sidebar", directoryHint: .isDirectory)
        let worktreeTask = task("Fix the sidebar", in: worktreeFolder, minutesAgo: 1, origin: alpha,
                                worktree: "fix-sidebar")
        let local = task("Local", in: alpha, minutesAgo: 2)
        let all = groups([worktreeTask, local], projects: [project])
        let layout = SidebarProjection.layout(visibleGroups: all, allGroups: all, splits: [], isFiltering: false,
                                              disclosure: SidebarDisclosure(rowLimit: 5))
        XCTAssertEqual(layout.sections.count, 1)
        XCTAssertEqual(layout.sections[0].group.displayName, "Alpha")
        XCTAssertEqual(layout.sections[0].rows.map(\.id), [.session(worktreeTask.id), .session(local.id)])
        XCTAssertEqual(SidebarWorktreeProjection.detail(for: worktreeTask), "fix-sidebar")
    }

    /// With nothing collapsed and no project over the limit, the sidebar lists and steps through
    /// tasks in the same order as before the nesting: Pinned, then each project's tasks by recency.
    func testKeyboardOrderIsUnchangedWhileEveryProjectIsOpen() {
        let a1 = task("A1", in: alpha, minutesAgo: 1)
        let a2 = task("A2", in: alpha, minutesAgo: 4)
        let b1 = task("B1", in: beta, minutesAgo: 2, harness: .claudeCode)
        let b2 = task("B2", in: beta, minutesAgo: 6, harness: .claudeCode)
        let pinned = task("P", in: beta, minutesAgo: 3, isPinned: true)
        let all = TaskNavigationProjection.workspaceGroups(from: [a1, a2, b1, b2, pinned])
        let before = SidebarProjection.layout(visibleGroups: all, allGroups: all, splits: [], isFiltering: false)
        let nested = SidebarProjection.layout(
            visibleGroups: all, allGroups: all, splits: [], isFiltering: false,
            disclosure: SidebarDisclosure(rowLimit: SidebarDisclosure.codexRowLimit), selection: .session(a2.id)
        )
        let expected = TaskNavigationProjection.flattenedSessionIDs(in: all).map(WindowItem.session)
        XCTAssertEqual(before.rows.map(\.id), expected)
        XCTAssertEqual(nested.rows.map(\.id), expected)
        for item in expected {
            XCTAssertEqual(SidebarProjection.adjacentRow(in: nested, selected: item, offset: 1),
                           SidebarProjection.adjacentRow(in: before, selected: item, offset: 1))
            XCTAssertEqual(SidebarProjection.adjacentRow(in: nested, selected: item, offset: -1),
                           SidebarProjection.adjacentRow(in: before, selected: item, offset: -1))
        }
        let targets = TaskCommandTargets.make(layout: nested, selection: .session(pinned.id), shownSession: pinned,
                                              sidebarSessions: all.flatMap(\.sessions), splits: [])
        XCTAssertEqual(targets.nextRow, expected[1])
        XCTAssertNil(targets.previousRow)
    }

    // MARK: - Grouped by state

    /// Grouped by state, the rows go under the Claude app's state groups in its order, each family
    /// under its most urgent task and each row knowing its project or Chats; Pinned stays as it is. A
    /// state collapses, lists five rows before "Show more" and is found for the shown task as a project
    /// is, and a search lists every match.
    func testGroupingByStateListsEachFamilyUnderItsMostUrgentTask() throws {
        let project = Project(name: "Alpha", primaryRoot: alpha)
        let parent = task("Parent", in: alpha, minutesAgo: 9)
        let asking = task("Asks", in: alpha, minutesAgo: 8, status: .waitingForApproval, parent: parent)
        let running = task("Runs", in: beta, minutesAgo: 7, status: .running)
        let unread = task("Finished", in: alpha, minutesAgo: 1, unread: true)
        let quiet = task("Quiet", in: beta, minutesAgo: 2)
        let pinned = task("Pinned", in: alpha, minutesAgo: 3, isPinned: true, status: .running)
        let chat = task("Chat", in: URL(filePath: "/tmp/sidebar-nesting/new-chat", directoryHint: .isDirectory),
                        minutesAgo: 5)
        let older = (0..<8).map { task("Older \($0)", in: beta, minutesAgo: Double(20 + $0)) }
        let all = groups([parent, asking, running, unread, quiet, pinned] + older,
                         projects: [project, Project(name: "beta", primaryRoot: beta)])
        func layout(_ disclosure: SidebarDisclosure = SidebarDisclosure(rowLimit: 5), selection: WindowItem? = nil,
                    filtering query: String? = nil) -> SidebarProjection.Layout {
            SidebarProjection.layout(
                visibleGroups: query.map { TaskNavigationProjection.filteredGroups(in: all, query: $0) } ?? all,
                allGroups: all, chats: query == nil ? [chat] : [], allChats: [chat], splits: [],
                isFiltering: query != nil, disclosure: disclosure, selection: selection,
                state: { TaskAttentionProjection.state(of: $0) })
        }
        func listed(from name: String) -> SidebarRowProject? {
            all.first { $0.displayName == name }.map { .project($0.workspaceURL.standardizedFileURL) }
        }

        let grouped = layout()
        XCTAssertNil(grouped.chats)
        XCTAssertTrue(grouped.sections.isEmpty)
        XCTAssertEqual(grouped.pinned.map(\.id), [.session(pinned.id)])
        XCTAssertNil(grouped.pinned[0].project)
        XCTAssertEqual(grouped.states.map(\.state), [.waiting, .active, .unread, .idle])
        XCTAssertEqual(grouped.states.map(\.title), ["Needs input", "Working", "Unread", "Idle"].map(L10n.string))
        XCTAssertEqual(grouped.states[0].rows.map(\.id), [.session(parent.id)], "A family goes with its waiting task")
        XCTAssertEqual(grouped.states[0].rows[0].children.map(\.id), [.session(asking.id)])
        XCTAssertEqual(grouped.states[0].rows[0].project, listed(from: "Alpha"))
        XCTAssertEqual(grouped.states[0].rows[0].children[0].project, listed(from: "Alpha"))
        XCTAssertEqual(grouped.states[1].rows.map(\.project), [listed(from: "beta")])
        XCTAssertEqual(grouped.states[3].allRows.map(\.id), ([quiet, chat] + older).map { .session($0.id) },
                       "The most recently active first, chats among the projects' tasks")
        XCTAssertEqual(grouped.states[3].allRows[1].project, .chats)
        XCTAssertEqual(grouped.states[3].rows.count, 5)
        XCTAssertEqual(grouped.states[3].hiddenRowCount, 5)
        XCTAssertEqual(grouped.rows.map(\.id), ([pinned, parent, asking, running, unread, quiet, chat]
                                                + older.prefix(3)).map { .session($0.id) })

        // The shown task stays listed past the limit, and its state is found to open it.
        let shown = layout(selection: .session(older[6].id)).states[3]
        XCTAssertEqual(shown.rows.last?.id, .session(older[6].id))
        let key = SidebarStateSection.disclosureKey(for: .idle)
        let collapsed = layout(SidebarDisclosure(collapsedKeys: [key], rowLimit: 5))
        XCTAssertTrue(collapsed.states[3].isCollapsed)
        XCTAssertTrue(collapsed.states[3].rows.isEmpty)
        XCTAssertEqual(SidebarProjection.disclosureKey(holding: .session(chat.id), in: collapsed), key)
        XCTAssertNil(SidebarProjection.disclosureKey(holding: .session(pinned.id), in: collapsed))
        XCTAssertEqual(SidebarProjection.disclosureKey(holding: .session(quiet.id), in: SidebarProjection.layout(
            visibleGroups: all, allGroups: all, splits: [], isFiltering: false)),
                       SidebarProjection.disclosureKey(for: all.first { $0.displayName == "beta" }!))

        // A search lists every match, its state collapsed or not.
        let searched = layout(SidebarDisclosure(collapsedKeys: [key], rowLimit: 5), filtering: "Older")
        XCTAssertEqual(searched.states.map(\.state), [.idle])
        XCTAssertFalse(searched.states[0].isCollapsed)
        XCTAssertEqual(searched.states[0].rows.count, older.count)
    }

    // MARK: - Remembered state

    @MainActor
    func testCollapsingIsRememberedAndForgetsShowMore() throws {
        let suite = testDefaultsSuite("SidebarNestingTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        let store = SidebarDisclosureStore(defaults: defaults)
        XCTAssertFalse(store.isCollapsed("project:a"), "A project nobody collapsed is open")
        store.showMore("project:a")
        store.showMore("project:a")
        XCTAssertEqual(store.disclosure.limit(for: "project:a"), 25)
        store.toggle("project:a")
        XCTAssertTrue(store.isCollapsed("project:a"))
        XCTAssertNil(store.revealedPages["project:a"])
        store.collapse("folder:/tmp/b")

        let relaunched = SidebarDisclosureStore(defaults: defaults)
        XCTAssertEqual(relaunched.collapsedKeys, ["project:a", "folder:/tmp/b"])
        XCTAssertEqual(relaunched.disclosure.limit(for: "project:a"), 5, "Show more lasts only until quit")
        relaunched.toggle("project:a")
        XCTAssertEqual(SidebarDisclosureStore(defaults: defaults).collapsedKeys, ["folder:/tmp/b"])
    }

    // MARK: - Titles

    func testFallbackTitlesDropTheProjectNameOnlyUnderTheProject() {
        let sandbox = URL(filePath: "/tmp/sidebar-nesting/yardlet-sandbox", directoryHint: .isDirectory)
        let request = "test_calc.py를 실행해서 결과를 알려줘"
        let fallback = SessionTitleProjection.fallbackTitle(firstUserMessage: request, workspaceURL: sandbox)
        XCTAssertEqual(fallback, "yardlet-sandbox · \(request)")
        let group = WorkspaceGroup(workspaceURL: sandbox, sessions: [], project: Project(name: "Sandbox", primaryRoot: sandbox))

        let automatic = task(fallback, in: sandbox, minutesAgo: 0, titleOrigin: .automatic)
        XCTAssertEqual(SidebarProjection.rowTitle(for: automatic, under: group), request)
        XCTAssertEqual(automatic.title, fallback, "The stored title keeps the project for the window title")

        let korean = SessionTitleProjection.fallbackTitle(firstUserMessage: "앱이 잘 작동하니?", workspaceURL: sandbox)
        XCTAssertEqual(korean, "yardlet-sandbox 작동 상태 확인")
        XCTAssertEqual(
            SidebarProjection.rowTitle(for: task(korean, in: sandbox, minutesAgo: 0, titleOrigin: .automatic),
                                       under: group),
            "작동 상태 확인"
        )
        // The project's own name, as the person renamed it, counts too.
        XCTAssertEqual(
            SidebarProjection.rowTitle(for: task("Sandbox · Fix tests", in: sandbox, minutesAgo: 0,
                                                 titleOrigin: .provisional), under: group),
            "Fix tests"
        )
        // A worktree task's fallback names its worktree folder, which the project row stands for.
        let worktreeFolder = URL(filePath: "/tmp/yardlet-worktrees/sandbox/fix-tests", directoryHint: .isDirectory)
        let worktree = task("fix-tests · Fix tests", in: worktreeFolder, minutesAgo: 0, titleOrigin: .automatic,
                            origin: sandbox, worktree: "fix-tests")
        XCTAssertEqual(SidebarProjection.rowTitle(for: worktree, under: group), "Fix tests")

        // Titles a provider or the person gave, and older titles of unknown origin, show as stored.
        for origin in [SessionTitleOrigin.provider, .manual, .legacy] {
            let other = task(fallback, in: sandbox, minutesAgo: 0, titleOrigin: origin)
            XCTAssertEqual(SidebarProjection.rowTitle(for: other, under: group), fallback)
        }
        // Another folder's name, a name inside the title, and an empty remainder stay.
        XCTAssertEqual(SidebarProjection.rowTitle(
            for: task("website · Fix tests", in: sandbox, minutesAgo: 0, titleOrigin: .automatic), under: group),
            "website · Fix tests")
        XCTAssertEqual(SidebarProjection.rowTitle(
            for: task("Run yardlet-sandbox · now", in: sandbox, minutesAgo: 0, titleOrigin: .automatic), under: group),
            "Run yardlet-sandbox · now")
        XCTAssertEqual(SidebarProjection.rowTitle(
            for: task("yardlet-sandbox · ", in: sandbox, minutesAgo: 0, titleOrigin: .automatic), under: group),
            "yardlet-sandbox · ")
    }

    func testSplitTitlesUnderAProjectDropItsName() {
        let first = task("alpha · Fix parser", in: alpha, minutesAgo: 1, titleOrigin: .automatic)
        let second = task("Provider title", in: alpha, minutesAgo: 2)
        var split = SplitGroup(root: .pane(SplitPane(sessionID: first.id)))
        split.split(.right, placing: second.id)
        let row = SidebarRow(content: .split(split, members: [first, second]))
        let group = WorkspaceGroup(workspaceURL: alpha, sessions: [first, second])
        XCTAssertEqual(SidebarProjection.rowTitle(for: row, under: group), "Fix parser + Provider title")
        XCTAssertEqual(row.title, "alpha · Fix parser + Provider title")
    }

    func testNewStringsAreLocalized() {
        for key in ["No chats", "Expand folder", "Collapse folder", "Show more", "Expanded", "Collapsed",
                    "Group by", "State", "Idle", "New nested task", "Nested under %@",
                    "Clear parent task", "Switch to chat"] {
            XCTAssertEqual(L10n.string(key, languageCode: "en"), key)
            XCTAssertNotEqual(L10n.string(key, languageCode: "ko"), key, key)
        }
        XCTAssertEqual(L10n.string("No chats", languageCode: "ko"), "채팅 없음")
        XCTAssertEqual(L10n.string("Show more", languageCode: "ko"), "더 보기")
    }
}

/// Renders the nested sidebar offscreen into `.build/sidebar-qa`, light and dark: projects with
/// Codex and Claude Code tasks, an empty project, a collapsed project with a running task,
/// "Show more", running, unread and shell-busy rows, a worktree task, and Pinned. No provider,
/// window server interaction, or app launch.
@MainActor
final class SidebarNestingRenderingTests: XCTestCase {
    func testNestedSidebarRendersWithoutAWindow() throws {
        let yardlet = URL(filePath: "/tmp/sidebar-qa/yardlet-sandbox", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/sidebar-qa/website", directoryHint: .isDirectory)
        let notes = URL(filePath: "/tmp/sidebar-qa/notes", directoryHint: .isDirectory)
        let worktreeFolder = URL(filePath: "/tmp/sidebar-qa/worktrees/fix-sidebar", directoryHint: .isDirectory)
        let projects = ProjectStore()
        let yardletProject = projects.ensureProject(forRoot: yardlet)
        let websiteProject = projects.ensureProject(forRoot: website, name: "Website")
        _ = projects.ensureProject(forRoot: notes)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  status: SessionStatus = .ready, origin: SessionTitleOrigin = .provider, unread: Bool = false,
                  pinned: Bool = false, worktreeOf: URL? = nil) -> SessionRecord {
            SessionRecord(
                harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                title: title, titleOrigin: origin, status: status, updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                hasUnreadUpdate: unread, completionState: unread ? .completed : .none, isPinned: pinned,
                originWorkspacePath: worktreeOf?.path(percentEncoded: false),
                worktreeName: worktreeOf == nil ? nil : "fix-sidebar"
            )
        }
        let running = task("Nest task rows under their project", .codex, in: yardlet, minutesAgo: 1, status: .running)
        let unread = task("yardlet-sandbox · Run test_calc.py and report the result", .claudeCode, in: yardlet,
                          minutesAgo: 2, status: .completed, origin: .automatic, unread: true)
        let shellBusy = task("Run the release checklist", .claudeCode, in: yardlet, minutesAgo: 3)
        let selected = task("Review the session index migration", .codex, in: yardlet, minutesAgo: 4)
        let worktree = task("fix-sidebar · Fix the sidebar spacing", .codex, in: worktreeFolder, minutesAgo: 5,
                            origin: .automatic, worktreeOf: yardlet)
        let older = (0..<3).map { task("Older task \($0 + 1)", $0 == 1 ? .claudeCode : .codex, in: yardlet,
                                       minutesAgo: Double(10 + $0)) }
        let pinned = task("yardlet-sandbox · Draft the release notes", .claudeCode, in: yardlet, minutesAgo: 6,
                          origin: .automatic, pinned: true)
        let websiteRunning = task("Landing page copy", .claudeCode, in: website, minutesAgo: 7, status: .running)
        let websiteIdle = task("Fix the footer links", .codex, in: website, minutesAgo: 8)
        let sessions = [running, unread, shellBusy, selected, worktree, pinned, websiteRunning, websiteIdle] + older

        let disclosure = SidebarDisclosureStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("sidebar-qa"))))
        disclosure.collapse(SidebarProjection.disclosureKey(
            for: WorkspaceGroup(workspaceURL: website, sessions: [], project: websiteProject)))
        let groups = projects.visibleGroups(sessions: sessions)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: .session(selected.id))
        XCTAssertEqual(layout.sections.map(\.group.displayName), ["yardlet-sandbox", "Website", "notes"])
        XCTAssertEqual(layout.sections[0].rows.count, 5)
        XCTAssertEqual(layout.sections[0].hiddenRowCount, 3)
        XCTAssertTrue(layout.sections[1].isCollapsed)
        XCTAssertTrue(layout.sections[2].showsEmptyState)
        XCTAssertEqual(yardletProject.name, "yardlet-sandbox")

        try render(name: "sidebar-nested", size: NSSize(width: ParityTheme.sidebarWidth, height: 620)) {
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .environment(\.shellBusyTaskIDs, [shellBusy.id])
                // A scheduled run's clock sits with the row's end marks, whatever the title's length.
                .environment(\.scheduledTaskIDs, [unread.id, selected.id, shellBusy.id])
        }

        // The same sidebar with "Show more" pressed and the collapsed project opened.
        disclosure.showMore(layout.sections[0].disclosureKey)
        disclosure.expand(layout.sections[1].disclosureKey)
        let opened = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: .session(selected.id))
        XCTAssertEqual(opened.sections[0].rows.count, 8)
        try render(name: "sidebar-nested-expanded", size: NSSize(width: ParityTheme.sidebarWidth, height: 720)) {
            TaskSidebar(layout: opened, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .environment(\.shellBusyTaskIDs, [shellBusy.id])
        }
    }

    func testCollapsedParentTaskExposesExpandChevronButton() throws {
        let alpha = URL(filePath: "/tmp/sidebar-qa/family-alpha", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: alpha)
        let now = Date()
        let parent = SessionRecord(harness: .claudeCode, workspaceURL: alpha,
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                   title: "Coordinate release", titleOrigin: .provider, updatedAt: now)
        let child1 = SessionRecord(harness: .codex, workspaceURL: alpha,
                                   runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                   title: "Run tests", titleOrigin: .provider,
                                   updatedAt: now.addingTimeInterval(-60), parentTaskID: parent.id)
        let child2 = SessionRecord(harness: .codex, workspaceURL: alpha,
                                   runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                   title: "Update changelog", titleOrigin: .provider,
                                   updatedAt: now.addingTimeInterval(-120), parentTaskID: parent.id)
        let groups = projects.visibleGroups(sessions: [parent, child1, child2])
        let disclosure = SidebarDisclosureStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("sidebar-family-qa"))))
        let familyKey = SidebarProjection.familyKey(for: parent.id)
        disclosure.collapse(familyKey)

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 340)
        let collapsedLayout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [],
                                                       isFiltering: false, disclosure: disclosure.disclosure,
                                                       selection: .session(parent.id))
        try render(name: "sidebar-family-collapsed", size: size) {
            TaskSidebar(layout: collapsedLayout, allGroups: groups, isRestoring: false, selection: .session(parent.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
        }

        let host = WindowlessRender.Host(
            SidebarHost(shown: ShownItem(.session(parent.id)), groups: groups, projects: projects, disclosure: disclosure)
                .frame(width: size.width, height: size.height),
            size: size, appearance: .light)
        defer { host.close() }
        host.settle(passes: 8)
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains { $0.role == "AXButton" && $0.label == L10n.string("Show nested sessions") },
                      "Collapsed parent row keeps an inline expand button visible without hover: \(elements.map(\.description).joined(separator: "\n"))")

        disclosure.expand(familyKey)
        let expandedLayout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [],
                                                      isFiltering: false, disclosure: disclosure.disclosure,
                                                      selection: .session(parent.id))
        try render(name: "sidebar-family-expanded", size: size) {
            TaskSidebar(layout: expandedLayout, allGroups: groups, isRestoring: false, selection: .session(parent.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
        }
    }

    /// A task with tasks under it offers New nested task among its hover buttons, as a project's label
    /// offers New task in project, and the button starts a task under that row's task. A task with none
    /// under it shows Pin and Archive alone, and so does every row where the window cannot start one
    /// (another Mac's). The hovered rows draw into `.build/sidebar-qa/sidebar-family-hover-*.png`.
    func testATaskWithTasksUnderItOffersNewNestedTaskOnHover() throws {
        let alpha = URL(filePath: "/tmp/sidebar-qa/family-hover", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: alpha)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, minutesAgo: Double, parent: SessionRecord? = nil)
            -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: alpha, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                          title: title, titleOrigin: .provider, updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                          parentTaskID: parent?.id)
        }
        let release = task("Coordinate release", .claudeCode, minutesAgo: 0)
        let tests = task("Run tests", .codex, minutesAgo: 1, parent: release)
        let logs = task("Read the failing logs", .codex, minutesAgo: 2, parent: tests)
        let changelog = task("Update changelog", .claudeCode, minutesAgo: 3, parent: release)
        let readme = task("Tidy the README", .codex, minutesAgo: 4)
        let groups = projects.visibleGroups(sessions: [release, tests, logs, changelog, readme])
        let disclosure = SidebarDisclosureStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("sidebar-family-hover"))))
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: .session(readme.id))
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 360)
        func sidebar(_ appearance: WindowlessRender.Appearance,
                     onNewNestedTask: ((SessionRecord) -> Void)?) -> some View {
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(readme.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                onNewNestedTask: onNewNestedTask, disclosure: disclosure)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        let pinAndArchive = [L10n.string("Pin"), L10n.string("Archive")]
        let newNestedTask = L10n.string("New nested task")
        let directory = try WindowlessRender.directory("sidebar-qa")

        for appearance in WindowlessRender.Appearance.allCases {
            var started: [UUID] = []
            let host = WindowlessRender.Host(sidebar(appearance) { started.append($0.id) }, size: size,
                                             appearance: appearance)
            defer { host.close() }
            host.settle()
            XCTAssertEqual(try hoverButtons(onRow: release.title, entering: true, in: host),
                           [L10n.string("Hide nested sessions"), newNestedTask] + pinAndArchive,
                           "\(appearance): a family's top task")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "sidebar-family-hover-top-\(appearance.suffix).png"))
            XCTAssertEqual(try hoverButtons(onRow: tests.title, in: host), [newNestedTask] + pinAndArchive,
                           "\(appearance): a nested task with a task under it")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "sidebar-family-hover-nested-\(appearance.suffix).png"))
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: newNestedTask))
            XCTAssertEqual(started, [tests.id], "\(appearance): the button starts a task under the hovered row's task")
            for title in [logs.title, changelog.title, readme.title] {
                XCTAssertEqual(try hoverButtons(onRow: title, in: host), pinAndArchive, "\(appearance): \(title)")
            }
        }

        // Another Mac's window, which starts no nested task, offers none.
        let remote = WindowlessRender.Host(sidebar(.light, onNewNestedTask: nil), size: size, appearance: .light)
        defer { remote.close() }
        remote.settle()
        XCTAssertEqual(try hoverButtons(onRow: release.title, entering: true, in: remote),
                       [L10n.string("Hide nested sessions")] + pinAndArchive)
    }

    /// The buttons a task row's hover shows, in order, with the pointer handed to the hosting view over
    /// the row titled `title`, coming into the window first when `entering`, as `WindowStructureQATests`
    /// hands it the pointer: the real pointer stays where it is.
    private func hoverButtons(onRow title: String, entering: Bool = false,
                              in host: WindowlessRender.Host<some View>) throws -> [String] {
        host.hosting.layoutSubtreeIfNeeded()
        let screenFrame = WindowlessRender.withAccessibilityTree { () -> CGRect? in
            func visit(_ node: AnyObject) -> CGRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if let label = child.accessibilityLabel?() ?? nil, label.hasPrefix("\(title), "),
                       let frame = child.accessibilityFrame?(), frame.height > 0 {
                        return frame
                    }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(host.hosting)
        }
        let row = host.window.convertFromScreen(try XCTUnwrap(screenFrame, "No row \(title)"))
        let location = NSPoint(x: row.midX, y: row.midY)
        let hosting = host.hosting, number = host.window.windowNumber, now = ProcessInfo.processInfo.systemUptime
        if entering, let area = hosting.trackingAreas.first(where: { $0.options.contains(.mouseEnteredAndExited) }),
           let entered = NSEvent.enterExitEvent(
               with: .mouseEntered, location: location, modifierFlags: [], timestamp: now, windowNumber: number,
               context: nil, eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
               userData: nil) {
            hosting.mouseEntered(with: entered)
        }
        let moved = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: now, windowNumber: number, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        hosting.mouseMoved(with: moved)
        host.settle(passes: 4, interval: 0.02)
        let hoverLabels = Set(["Hide nested sessions", "Show nested sessions", "New nested task", "Pin", "Unpin",
                               "Archive"].map { L10n.string($0) })
        return host.accessibilityElements().filter { $0.role == "AXButton" && hoverLabels.contains($0.label) }.map(\.label)
    }

    /// Showing a task in a collapsed project opens the project, when the sidebar appears and when
    /// another task is shown, as the Codex sidebar does for a new current chat. A project collapsed
    /// around the shown task stays collapsed until another of its tasks is shown.
    func testGoingToATaskInACollapsedProjectOpensIt() throws {
        let alpha = URL(filePath: "/tmp/sidebar-qa/alpha", directoryHint: .isDirectory)
        let beta = URL(filePath: "/tmp/sidebar-qa/beta", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: alpha)
        _ = projects.ensureProject(forRoot: beta)
        let first = SessionRecord(harness: .codex, workspaceURL: alpha, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                  title: "First", titleOrigin: .provider)
        let second = SessionRecord(harness: .claudeCode, workspaceURL: alpha,
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Second")
        let other = SessionRecord(harness: .codex, workspaceURL: beta, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                  title: "Other")
        let groups = projects.visibleGroups(sessions: [first, second, other])
        let suite = testDefaultsSuite("sidebar-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        let alphaKey: String? = SidebarProjection.disclosureKey(for: try XCTUnwrap(groups.first {
            $0.displayName == "alpha"
        }))
        XCTAssertEqual(alphaKey?.hasPrefix("project:"), true)
        disclosure.collapse(try XCTUnwrap(alphaKey))
        let shown = ShownItem(.session(first.id))

        let hosting = NSHostingView(rootView: SidebarHost(shown: shown, groups: groups, projects: projects,
                                                          disclosure: disclosure)
            .frame(width: ParityTheme.sidebarWidth, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ParityTheme.sidebarWidth, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        settle(hosting)
        XCTAssertFalse(disclosure.isCollapsed(try XCTUnwrap(alphaKey)), "The shown task's project opens")

        disclosure.collapse(try XCTUnwrap(alphaKey))
        settle(hosting)
        XCTAssertTrue(disclosure.isCollapsed(try XCTUnwrap(alphaKey)), "Collapsing around the shown task holds")

        shown.item = .session(other.id)
        settle(hosting)
        XCTAssertTrue(disclosure.isCollapsed(try XCTUnwrap(alphaKey)))

        shown.item = .session(second.id)
        settle(hosting)
        XCTAssertFalse(disclosure.isCollapsed(try XCTUnwrap(alphaKey)))
    }

    /// A click on a project row collapses it and a second click opens it, through the row's own
    /// button in an unshown window.
    func testClickingAProjectRowCollapsesAndExpandsIt() throws {
        let alpha = URL(filePath: "/tmp/sidebar-qa/click-alpha", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: alpha)
        let first = SessionRecord(harness: .codex, workspaceURL: alpha, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                  title: "First", titleOrigin: .provider)
        let groups = projects.visibleGroups(sessions: [first])
        let key = SidebarProjection.disclosureKey(for: try XCTUnwrap(groups.first))
        let suite = testDefaultsSuite("sidebar-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        let hosting = NSHostingView(rootView: SidebarHost(shown: ShownItem(.home), groups: groups, projects: projects,
                                                          disclosure: disclosure)
            .frame(width: ParityTheme.sidebarWidth, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ParityTheme.sidebarWidth, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        // Clicks reach SwiftUI only in an ordered window, as `TranscriptAutoFollowTests` does it:
        // transparent and off screen.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.display()
        settle(hosting)

        // The first project's label sits under New task (32), the search field (8 + 30), the list's
        // top inset (16), the Projects title (22) and a row gap (1), then its own 4 above its 28:
        // its middle is 127pt from the top.
        let row = NSPoint(x: ParityTheme.sidebarWidth / 2, y: 400 - 127)
        click(at: row, in: window)
        settle(hosting)
        XCTAssertTrue(disclosure.isCollapsed(key))
        click(at: row, in: window)
        settle(hosting)
        XCTAssertFalse(disclosure.isCollapsed(key))
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func settle(_ hosting: NSView) {
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func render<Content: View>(name: String, size: NSSize, @ViewBuilder content: () -> Content) throws {
        // Never ordered on screen: a borderless backing window lets AppKit-backed fields and
        // scroll views draw, which ImageRenderer replaces with placeholders.
        try WindowlessRender.hostedInBothAppearances(name, in: WindowlessRender.directory("sidebar-qa"), size: size) {
            content()
                .environment(\.colorScheme, $0.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }
    }
}

@MainActor
@Observable
private final class ShownItem {
    var item: WindowItem
    init(_ item: WindowItem) { self.item = item }
}

/// The sidebar as the window builds it: the layout follows the remembered disclosure and what
/// the window shows.
@MainActor
private struct SidebarHost: View {
    let shown: ShownItem
    let groups: [WorkspaceGroup]
    let projects: ProjectStore
    let disclosure: SidebarDisclosureStore

    var body: some View {
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure.disclosure, selection: shown.item)
        TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: shown.item,
            searchText: .constant(""), onNewTask: {}, onActivate: { shown.item = $0 }, onNewTaskInProject: { _ in },
            projects: projects, onEditProject: { _ in },
            onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
            onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
            disclosure: disclosure)
    }
}
