import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NativeHarnessClient

/// Renders the sidebar before and after a project move offscreen into `.build/move-project-qa`,
/// light and dark.
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

    /// Making a chat a project asks first: the New project sheet opens with the name it offers in its
    /// field, all of it selected, so Return keeps it and typing replaces it, the chat's folder as the
    /// primary one, and Cancel beside Create. Nothing is made while it shows. Drawn into
    /// `.build/move-project-qa` as `new-project-sheet-*.png`, light and dark.
    func testMakingAChatAProjectAsksWithTheNewProjectSheet() throws {
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let folder = home.appending(path: "Documents/Yardlet/2026-11-20/new-chat-2", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        let chat = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                                 title: "Plan the weekend trip", titleOrigin: .provider, status: .ready)
        XCTAssertTrue(TaskProjectMove.options(for: chat, visibleProjects: [], projects: projects.projects).canMakeProject)
        let request = NewProjectRequest(session: chat, name: TaskProjectMove.projectName(for: chat))
        let size = NSSize(width: 520, height: 300)
        func sheet(_ scheme: ColorScheme) -> some View {
            NewProjectSheet(request: request) { _, _ in XCTFail("Nothing is made before Create") }
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
        }

        let host = WindowlessRender.Host(sheet(.light), size: size, appearance: .light)
        defer { host.close() }
        host.settle()
        let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView, "The name has the keyboard")
        XCTAssertEqual(editor.string, "Plan the weekend trip")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count),
                       "All of the name is selected")
        XCTAssertTrue(projects.projects.isEmpty)

        let directory = try WindowlessRender.directory("move-project-qa")
        try WindowlessRender.hostedInBothAppearances("new-project-sheet", in: directory, size: size) { appearance in
            sheet(appearance.colorScheme)
        }
    }

    /// With no projects the sidebar lists no Projects title, as before. While a chat that can become a
    /// project is dragged (`SidebarChatDrag`), Projects is listed under the chats and takes the chat,
    /// which becomes a project of its own folder; once the drag ends, the title is gone again. Another
    /// Mac's window, which makes no project here, lists none. Drawn into `.build/move-project-qa` with the
    /// chat over the title, light and dark: `projects-drop-target-*.png`.
    func testProjectsIsListedWhileAChatIsDraggedWithNoProjects() async throws {
        // SwiftUI reads a dropped item only in a type Launch Services knows as data, as the next test says.
        guard UTType.yardletTaskReference.conforms(to: .data) else {
            return XCTFail("No registered bundle declares \(UTType.yardletTaskReference.identifier), "
                           + "so a drop cannot read the task")
        }
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        let now = Date()
        func chat(_ title: String, in folder: String, minutesAgo: Double) -> SessionRecord {
            SessionRecord(harness: .claudeCode,
                          workspaceURL: home.appending(path: "Documents/Yardlet/2026-11-20/\(folder)", directoryHint: .isDirectory),
                          runtimeExecutableURL: URL(filePath: "/tmp/agent"), title: title, titleOrigin: .provider,
                          status: .ready, updatedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        let trip = chat("Plan the weekend trip", in: "new-chat", minutesAgo: 3)
        let desks = chat("Compare standing desks", in: "new-chat-2", minutesAgo: 20)
        let sessions = [trip, desks]
        let disclosure = SidebarDisclosureStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("projects-drop-qa"))))
        let chatDrag = SidebarChatDrag()
        var made: [String] = []
        func sidebar(_ scheme: ColorScheme = .light, makesProjects: Bool = true) -> some View {
            let groups = projects.visibleGroups(sessions: sessions)
            let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups,
                                                  chats: projects.chats(sessions: sessions), splits: [],
                                                  isFiltering: false, disclosure: disclosure.disclosure,
                                                  selection: .session(trip.id))
            return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(trip.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                onAddProject: {}, projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                onMakeProject: makesProjects ? { made.append($0.title) } : nil, disclosure: disclosure)
                .environment(\.sidebarChatDrag, chatDrag)
                .tint(Color.primary)
                .environment(\.colorScheme, scheme)
                .frame(width: ParityTheme.sidebarWidth, height: 300, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 300)
        func isTitle(_ text: String) -> (WindowlessRender.AccessibilityElement) -> Bool {
            { $0.label == text || $0.value == text }
        }
        func listsProjects(_ host: WindowlessRender.Host<some View>) -> Bool {
            host.accessibilityElements().contains(where: isTitle(L10n.string("Projects")))
        }
        /// The middle of `frame`, from the window's top-left, unflipped as a drag gives it.
        func middle(_ frame: CGRect) -> NSPoint { NSPoint(x: frame.midX, y: size.height - frame.midY) }

        let host = WindowlessRender.Host(sidebar(), size: size, appearance: .light)
        defer { host.close() }
        host.settle()
        XCTAssertFalse(listsProjects(host), "With no projects and no drag, the sidebar is as it was")

        // A chat's drag starts, as its row tells SwiftUI the task it drags.
        _ = SidebarNesting.dragging(desks.id)
        chatDrag.setDragging(true)
        host.settle()
        let shown = host.accessibilityElements()
        let chatsTitle = try XCTUnwrap(shown.firstIndex(where: isTitle(L10n.string("Chats"))), "\(shown)")
        let projectsTitle = try XCTUnwrap(shown.firstIndex(where: isTitle(L10n.string("Projects"))), "\(shown)")
        let lastChat = try XCTUnwrap(shown.lastIndex { $0.label.hasPrefix(desks.title) }, "\(shown)")
        XCTAssertTrue(chatsTitle < lastChat && lastChat < projectsTitle, "Under the chats: \(shown)")

        let directory = try WindowlessRender.directory("move-project-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let shot = WindowlessRender.Host(sidebar(appearance.colorScheme), size: size, appearance: appearance)
            defer { shot.close() }
            shot.settle()
            let drag = try TaskRowDrag(desks.id, at: middle(try textFrame(L10n.string("Projects"), in: shot)),
                                       in: shot.window)
            defer { drag.close() }
            let destination = try XCTUnwrap(drag.destination(in: shot.hosting))
            _ = destination.draggingEntered(drag)
            XCTAssertEqual(destination.draggingUpdated(drag), .move, "A chat can become a project")
            shot.settle(passes: 3)
            try WindowlessRender.writePNG(try shot.capture().bitmap,
                                          to: directory.appending(path: "projects-drop-target-\(appearance.suffix).png"))
            destination.draggingExited(drag)
        }

        // Dropped there, the chat becomes a project of its own folder. The drop reads the task from the
        // drag's pasteboard after it returns, so the drag closes once the drop has acted.
        let drag = try TaskRowDrag(desks.id, at: middle(try textFrame(L10n.string("Projects"), in: host)), in: host.window)
        defer { drag.close() }
        let destination = try XCTUnwrap(drag.destination(in: host.hosting))
        _ = destination.draggingEntered(drag)
        _ = destination.draggingUpdated(drag)
        XCTAssertTrue(destination.performDragOperation(drag))
        try await waitUntil { made == [desks.title] }

        let remote = WindowlessRender.Host(sidebar(makesProjects: false), size: size)
        defer { remote.close() }
        remote.settle()
        XCTAssertFalse(listsProjects(remote), "Another Mac's window makes no project here")

        chatDrag.setDragging(false)
        host.settle()
        XCTAssertFalse(listsProjects(host), "Gone once the drag ends")
    }

    /// A task dragged onto a project's row moves there, as its "Move to project" menu offers, and a chat
    /// dragged onto Projects becomes a project of its own folder. Each shows it can take the task while
    /// the task is over it and refuses one it cannot take. Drawn into `.build/move-project-qa` while a
    /// chat is over them, light and dark: `drop-on-project-*.png` and `drop-on-projects-*.png`.
    func testATaskDroppedOnAProjectMovesThereAndAChatDroppedOnProjectsBecomesOne() async throws {
        // SwiftUI reads a dropped item only in a type Launch Services knows as data, from a registered
        // bundle that declares it: an installed Yardlet, or the bundle the nightly run registers.
        guard UTType.yardletTaskReference.conforms(to: .data) else {
            return XCTFail("No registered bundle declares \(UTType.yardletTaskReference.identifier), "
                           + "so a drop cannot read the task")
        }
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/move-project-qa/website", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        _ = projects.ensureProject(forRoot: website, name: "Website")
        let now = Date()
        func task(_ title: String, in folder: URL, minutesAgo: Double) -> SessionRecord {
            SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                          title: title, titleOrigin: .provider, status: .ready,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        func chatFolder(_ name: String) -> URL {
            home.appending(path: "Documents/Yardlet/2026-11-20/\(name)", directoryHint: .isDirectory)
        }
        let trip = task("Plan the weekend trip", in: chatFolder("new-chat"), minutesAgo: 3)
        let desks = task("Compare standing desks", in: chatFolder("new-chat-2"), minutesAgo: 20)
        let hero = task("Redesign the hero section", in: website, minutesAgo: 40)
        let sessions = [trip, desks, hero]
        let disclosure = SidebarDisclosureStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("project-drop-qa"))))
        var moves: [String] = []
        var made: [String] = []
        func view(_ scheme: ColorScheme) -> some View {
            let groups = projects.visibleGroups(sessions: sessions)
            let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups,
                                                  chats: projects.chats(sessions: sessions), splits: [],
                                                  isFiltering: false, disclosure: disclosure.disclosure,
                                                  selection: .session(trip.id))
            return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(trip.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                onAddProject: {}, projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                onMoveToProject: { session, project in moves.append("\(session.title) → \(project?.name ?? "Chats")") },
                onMakeProject: { made.append($0.title) },
                disclosure: disclosure)
                .tint(Color.primary)
                .environment(\.colorScheme, scheme)
                .frame(width: ParityTheme.sidebarWidth, height: 360, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 360)
        let directory = try WindowlessRender.directory("move-project-qa")
        /// The middle of `frame`, from the window's top-left, unflipped as a drag gives it.
        func middle(_ frame: CGRect) -> NSPoint { NSPoint(x: frame.midX, y: size.height - frame.midY) }

        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(view(appearance.colorScheme), size: size, appearance: appearance)
            defer { host.close() }
            host.settle()
            let onProject = middle(try rowFrame(L10n.format("Project %@", "Website"), in: host))
            let onProjects = middle(try textFrame(L10n.string("Projects"), in: host))
            func over(_ task: SessionRecord, _ location: NSPoint, capture name: String? = nil) throws -> NSDragOperation {
                _ = SidebarNesting.dragging(task.id)
                let drag = try TaskRowDrag(task.id, at: location, in: host.window)
                defer { drag.close() }
                let destination = try XCTUnwrap(drag.destination(in: host.hosting))
                _ = destination.draggingEntered(drag)
                let operation = destination.draggingUpdated(drag)
                host.settle(passes: 3)
                if let name {
                    try WindowlessRender.writePNG(try host.capture().bitmap,
                                                  to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                }
                destination.draggingExited(drag)
                host.settle(passes: 2)
                return operation
            }
            XCTAssertEqual(try over(trip, onProject, capture: "drop-on-project"), .move, "A chat can move to Website")
            XCTAssertEqual(try over(hero, onProject), [], "A task in Website stays where it is")
            XCTAssertEqual(try over(desks, onProjects, capture: "drop-on-projects"), .move, "A chat can become a project")
            XCTAssertEqual(try over(hero, onProjects), [], "A task in a project has its project")
        }

        let host = WindowlessRender.Host(view(.light), size: size, appearance: .light)
        defer { host.close() }
        host.settle()
        /// Drops the task; the drop reads the task from the drag's pasteboard after it returns, so the
        /// caller closes the drag once the drop has acted.
        func drop(_ task: SessionRecord, at location: NSPoint) throws -> TaskRowDrag {
            _ = SidebarNesting.dragging(task.id)
            let drag = try TaskRowDrag(task.id, at: location, in: host.window)
            let destination = try XCTUnwrap(drag.destination(in: host.hosting))
            _ = destination.draggingEntered(drag)
            _ = destination.draggingUpdated(drag)
            XCTAssertTrue(destination.performDragOperation(drag))
            return drag
        }
        let onProject = try drop(trip, at: middle(try rowFrame(L10n.format("Project %@", "Website"), in: host)))
        defer { onProject.close() }
        try await waitUntil { moves == ["Plan the weekend trip → Website"] }
        let onProjects = try drop(desks, at: middle(try textFrame(L10n.string("Projects"), in: host)))
        defer { onProjects.close() }
        try await waitUntil { made == ["Compare standing desks"] }
        XCTAssertEqual(moves, ["Plan the weekend trip → Website"], "The drop on Projects moves nothing else")
    }

    /// The words `text` (a section's title), in the window's top-left space.
    private func textFrame(_ text: String, in host: WindowlessRender.Host<some View>) throws -> CGRect {
        host.hosting.layoutSubtreeIfNeeded()
        let window = host.window, height = host.hosting.bounds.height
        return try WindowlessRender.withAccessibilityTree {
            func find(_ node: AnyObject) -> CGRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    let label = (child.accessibilityLabel?() ?? nil) ?? ""
                    let value = ((child.accessibilityValue?() as Any??) ?? nil) as? String ?? ""
                    if label == text || value == text, let screen = child.accessibilityFrame?(), screen.height > 0 {
                        let frame = window.convertFromScreen(screen)
                        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
                    }
                    if let found = find(child) { return found }
                }
                return nil
            }
            return try XCTUnwrap(find(host.hosting), "No \(text)")
        }
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
