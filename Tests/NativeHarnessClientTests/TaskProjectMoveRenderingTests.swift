import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders the sidebar offscreen into `.build/move-project-qa`, light and dark, before and after a
/// chat moves into a project (the Codex app thread the person had moved to a project of theirs), and
/// a task in its project's own folder moved to Chats from its row's menu. A menu is built as a right
/// click builds it and drawn beside the sidebar, never opened. No provider, app launch, or window
/// server interaction.
@MainActor
final class TaskProjectMoveRenderingTests: XCTestCase {
    func testTheSidebarShowsAMovedChatUnderItsNewProject() throws {
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let thirteen = URL(filePath: "/tmp/move-project-qa/13weeks", directoryHint: .isDirectory)
        let sandbox = URL(filePath: "/tmp/move-project-qa/yardlet-sandbox", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        let thirteenProject = projects.ensureProject(forRoot: thirteen, name: "13 Weeks")
        _ = projects.ensureProject(forRoot: sandbox)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  projectID: UUID? = nil, status: SessionStatus = .ready, unread: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder,
                          runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                          title: title, titleOrigin: .provider, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                          completionState: unread ? .completed : .none, projectID: projectID)
        }
        let game = task("Finish the OpenAI Game 2026 web game", .codex,
                        in: home.appending(path: "Documents/Codex/2026-08-25/new-chat", directoryHint: .isDirectory),
                        minutesAgo: 2)
        let trip = task("Plan the weekend trip", .claudeCode,
                        in: home.appending(path: "Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                                           directoryHint: .isDirectory), minutesAgo: 4)
        let weekly = task("Organize the weekly study plan", .codex, in: thirteen, minutesAgo: 30, projectID: thirteenProject.id,
                          unread: true)
        let sandboxTask = task("Nest task rows under their project", .claudeCode, in: sandbox, minutesAgo: 8,
                               status: .running)
        let before = [game, trip, weekly, sandboxTask]
        let options = TaskProjectMove.options(
            for: game, visibleProjects: projects.visibleGroups(sessions: before).compactMap(\.project),
            projects: projects.projects)
        XCTAssertTrue(options.allows(thirteenProject))
        let moved = TaskProjectMove.moved(game, to: thirteenProject)
        let after = [moved, trip, weekly, sandboxTask]
        XCTAssertEqual(projects.chats(sessions: before).map(\.id), [game.id, trip.id])
        XCTAssertEqual(projects.chats(sessions: after).map(\.id), [trip.id])

        let suite = testDefaultsSuite("move-project-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        func sidebar(_ sessions: [SessionRecord]) -> TaskSidebar {
            let groups = projects.visibleGroups(sessions: sessions)
            let chats = projects.chats(sessions: sessions)
            let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                                  isFiltering: false, disclosure: disclosure.disclosure,
                                                  selection: .session(game.id))
            return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(game.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
        }

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 420)
        let directory = try WindowlessRender.directory("move-project-qa")
        for (name, sessions) in [("sidebar-before-move", before), ("sidebar-after-move", after)] {
            try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) {
                sidebar(sessions)
                    .environment(\.colorScheme, $0.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.sidebar)
            }
        }

        // What the sidebar exposes after the move: the chat is under its project, below Projects, and Chats
        // holds only the other chat.
        let host = WindowlessRender.Host(
            sidebar(after).frame(width: size.width, height: size.height, alignment: .top), size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        func index(where matches: (WindowlessRender.AccessibilityElement) -> Bool, _ what: String) throws -> Int {
            try XCTUnwrap(elements.firstIndex(where: matches), "\(what): \(elements)")
        }
        func index(of text: String) throws -> Int {
            try index(where: { $0.label == text || $0.value == text }, text)
        }
        let chatsTitle = try index(of: L10n.string("Chats"))
        let projectsTitle = try index(of: L10n.string("Projects"))
        let movedRow = try index(of: "Finish the OpenAI Game 2026 web game, Codex")
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(try index(of: "Plan the weekend trip, Claude Code")))
        XCTAssertGreaterThan(movedRow, projectsTitle)
        XCTAssertGreaterThan(movedRow, try index(where: { $0.label.contains("13 Weeks") }, "13 Weeks"))
        XCTAssertLessThan(movedRow, try index(where: { $0.label.contains("yardlet-sandbox") }, "yardlet-sandbox"))
    }

    /// A task in its project's own folder moves to Chats from its row's menu: "Move to Chats" under
    /// "Move to project", and its row is then listed under Chats. Drawn into `.build/move-project-qa`,
    /// light and dark:
    ///
    /// - `move-to-chats-menu-*.png`: the row's menu beside the sidebar, in the language the test runs in.
    /// - `move-to-chats-menu-en-*.png`, `move-to-chats-menu-ko-*.png`: the same menu's items in English
    ///   and Korean.
    /// - `move-to-chats-moved-*.png`: the sidebar once the menu moved it.
    func testARowsMenuMovesATaskInItsProjectsFolderToChats() async throws {
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let yardlet = URL(filePath: "/tmp/move-project-qa/yardlet", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/move-project-qa/website", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        _ = projects.ensureProject(forRoot: yardlet, name: "Yardlet")
        _ = projects.ensureProject(forRoot: website, name: "Website")
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  status: SessionStatus = .ready) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                          title: title, titleOrigin: .provider, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        let post = task("Draft the launch post", .claudeCode, in: yardlet, minutesAgo: 3)
        let build = task("Fix the release build", .codex, in: yardlet, minutesAgo: 12, status: .running)
        let trip = task("Plan the weekend trip", .claudeCode,
                        in: home.appending(path: "Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                                           directoryHint: .isDirectory), minutesAgo: 5)
        let hero = task("Redesign the hero section", .codex, in: website, minutesAgo: 40)
        let store = SessionStore(sessions: [post, build, trip, hero])
        let disclosure = SidebarDisclosureStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("move-to-chats-qa"))))
        var moves: [String] = []
        func view(_ scheme: ColorScheme) -> some View {
            let groups = projects.visibleGroups(sessions: store.sessions)
            let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups,
                                                  chats: projects.chats(sessions: store.sessions), splits: [],
                                                  isFiltering: false, disclosure: disclosure.disclosure,
                                                  selection: .session(post.id))
            return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(post.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                onMoveToProject: { session, project in
                    moves.append("\(session.title) → \(project?.name ?? "Chats")")
                    let moved = TaskProjectMove.moved(session, to: project)
                    Task { try? await store.moveSession(id: session.id, toProject: moved.projectID,
                                                        additionalRoots: moved.additionalRoots) }
                },
                disclosure: disclosure)
                // The window's tint, as `MainWindow` sets it.
                .tint(Color.primary)
                .environment(\.colorScheme, scheme)
                .frame(width: ParityTheme.sidebarWidth, height: 380, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 380)
        let directory = try WindowlessRender.directory("move-project-qa")

        // The row's menu, built as a right click builds it, without opening it.
        let host = WindowlessRender.Host(view(.light), size: size, appearance: .light)
        defer { host.close() }
        host.settle()
        let row = try rowFrame(post.title, in: host)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: row.midX, y: size.height - row.midY),
            modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var target = host.hosting.hitTest(click.locationInWindow)
        var menu: NSMenu?
        while let view = target, menu == nil { menu = view.menu(for: click); target = view.superview }
        let items = try XCTUnwrap(menu).items
        let toProject = try XCTUnwrap(items.firstIndex { $0.title == L10n.string("Move to project") })
        let toChats = try XCTUnwrap(items.firstIndex { $0.title == L10n.string("Move to Chats") })
        XCTAssertEqual(toChats, toProject + 1, "Move to Chats follows Move to project")
        XCTAssertEqual(items[toProject].submenu?.items.map(\.title), ["Website"])

        let lines = MenuLine.lines(items)
        let menuSize = NSSize(width: ParityTheme.sidebarWidth + 260, height: 480)
        try WindowlessRender.hostedInBothAppearances("move-to-chats-menu", in: directory, size: menuSize) { appearance in
            HStack(alignment: .top, spacing: 0) {
                view(appearance.colorScheme)
                MenuPanel(lines: lines, width: 230, highlighted: toChats)
                    .padding(.top, row.midY - 4)
                    .padding(.leading, -40)
                Spacer(minLength: 0)
            }
            .frame(width: menuSize.width, height: menuSize.height, alignment: .topLeading)
            .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
            .environment(\.colorScheme, appearance.colorScheme)
        }
        // The same items in each language: a title goes back to its key, then to that language's words.
        let keys = ["Open in New Tab", "Open in Split View", "Open in Side Panel", "Pin", "Unpin", "Rename…",
                    "Mark task as read", "Mark task as unread", "Move up one level", "Move under task",
                    "Detach to top level", "Move to project", "Move to Chats", "Archive", "Delete task"]
        for language in ["en", "ko"] {
            let translated = items.map { item in
                let copy = item.copy() as! NSMenuItem
                copy.title = keys.first { L10n.string($0) == item.title }.map { L10n.string($0, languageCode: language) }
                    ?? item.title
                return copy
            }
            let panelSize = NSSize(width: 250, height: MenuPanel.height(lines) + 20)
            try WindowlessRender.hostedInBothAppearances("move-to-chats-menu-\(language)", in: directory,
                                                         size: panelSize) { appearance in
                MenuPanel(lines: MenuLine.lines(translated), width: 230, highlighted: toChats)
                    .frame(width: panelSize.width, height: panelSize.height)
                    .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                    .environment(\.colorScheme, appearance.colorScheme)
            }
        }

        // "Move to Chats": the task is listed under Chats and keeps its folder.
        try XCTUnwrap(menu).performActionForItem(at: toChats)
        try await waitUntil { store.sessions.first { $0.id == post.id }?.isMovedToChats == true }
        XCTAssertEqual(moves, ["Draft the launch post → Chats"])
        let moved = try XCTUnwrap(store.sessions.first { $0.id == post.id })
        XCTAssertEqual(moved.workspaceURL, yardlet.standardizedFileURL)
        XCTAssertEqual(Set(projects.chats(sessions: store.sessions).map(\.id)), [post.id, trip.id])
        try WindowlessRender.hostedInBothAppearances("move-to-chats-moved", in: directory, size: size) { appearance in
            view(appearance.colorScheme)
        }
        host.hosting.rootView = view(.light)
        host.settle()
        let elements = host.accessibilityElements()
        func index(where matches: (WindowlessRender.AccessibilityElement) -> Bool, _ what: String) throws -> Int {
            try XCTUnwrap(elements.firstIndex(where: matches), "\(what): \(elements)")
        }
        let chatsTitle = try index(where: { $0.label == L10n.string("Chats") || $0.value == L10n.string("Chats") }, "Chats")
        let projectsTitle = try index(where: { $0.label == L10n.string("Projects") || $0.value == L10n.string("Projects") },
                                      "Projects")
        let movedRow = try index(where: { $0.label.hasPrefix(post.title) }, post.title)
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(movedRow), "Listed under Chats, above the projects")
        XCTAssertGreaterThan(try index(where: { $0.label.hasPrefix(build.title) }, build.title), projectsTitle,
                             "The project's other task stays in it")
    }

    /// The row titled `title`, in the window's top-left space.
    private func rowFrame(_ title: String, in host: WindowlessRender.Host<some View>) throws -> CGRect {
        host.hosting.layoutSubtreeIfNeeded()
        let window = host.window, height = host.hosting.bounds.height
        return try WindowlessRender.withAccessibilityTree {
            func find(_ node: AnyObject) -> CGRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if ((child.accessibilityLabel?() ?? nil) ?? "").hasPrefix(title),
                       let screen = child.accessibilityFrame?(), screen.height > 0 {
                        let frame = window.convertFromScreen(screen)
                        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
                    }
                    if let found = find(child) { return found }
                }
                return nil
            }
            return try XCTUnwrap(find(host.hosting), "No row \(title)")
        }
    }
}
