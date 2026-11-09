import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Chats, like the Codex app's: a task in a folder a harness app makes for a conversation with no
/// project (`ChatWorkspaces`) that no project holds is listed under Chats, above the projects.
/// The folder decides, not a missing project ID.
final class ChatSidebarTests: XCTestCase {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    private let base = Date(timeIntervalSince1970: 1_000)

    private var codexChat: URL { home.appending(path: "Documents/Codex/2026-10-09/new-chat") }
    private var claudeChat: URL {
        home.appending(path: "Library/Application Support/Claude/scratch-workspaces/a/b/scratch-2026-10-04-7fbdb2")
    }
    private var yardletChat: URL { home.appending(path: "Documents/Yardlet/2026-10-12/new-chat") }
    private let alpha = URL(filePath: "/tmp/chat-sidebar/alpha")
    private let beta = URL(filePath: "/tmp/chat-sidebar/beta")

    private func task(_ title: String, in folder: URL, minutesAgo: Double, harness: HarnessKind = .claudeCode,
                      titleOrigin: SessionTitleOrigin = .provider, isPinned: Bool = false,
                      projectID: UUID? = nil) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                      title: title, titleOrigin: titleOrigin, updatedAt: base.addingTimeInterval(-minutesAgo * 60),
                      isPinned: isPinned, projectID: projectID)
    }

    func testChatsAreTasksInAChatFolderThatNoProjectHolds() throws {
        let notesProject = Project(name: "Notes", primaryRoot: yardletChat)
        let alphaProject = Project(name: "Alpha", primaryRoot: alpha)
        let projects = [notesProject, alphaProject]
        let codex = task("Ask about the weather", in: codexChat, minutesAgo: 2, harness: .codex)
        let claude = task("Plan a trip", in: claudeChat, minutesAgo: 1)
        // A chat's folder the person made a project stays a project.
        let inProjectChatFolder = task("Notes in a project", in: yardletChat, minutesAgo: 3)
        // An old task stored no project ID; its folder is a project's, so it is not a chat.
        let legacy = task("Legacy task", in: alpha, minutesAgo: 4)
        let folderTask = task("Folder task", in: beta, minutesAgo: 5)
        let pinnedChat = task("Pinned chat", in: home.appending(path: "Documents/Codex/2026-10-09/new-chat-2"),
                              minutesAgo: 6, isPinned: true)
        let sessions = [codex, claude, inProjectChatFolder, legacy, folderTask, pinnedChat]

        XCTAssertTrue(ProjectProjection.isChat(codex, in: projects, home: home))
        XCTAssertFalse(ProjectProjection.isChat(inProjectChatFolder, in: projects, home: home))
        XCTAssertFalse(ProjectProjection.isChat(legacy, in: projects, home: home))
        XCTAssertNil(legacy.projectID)
        XCTAssertFalse(ProjectProjection.isChat(folderTask, in: projects, home: home))
        XCTAssertEqual(ProjectProjection.chats(from: sessions, projects: projects, home: home).map(\.id),
                       [claude.id, codex.id, pinnedChat.id], "Most recent first")

        let groups = ProjectProjection.visibleGroups(sessions: sessions, projects: projects, home: home)
        XCTAssertEqual(groups.map(\.displayName), ["Notes", "Alpha", "beta"], "A chat makes no folder group")
        XCTAssertFalse(groups.flatMap(\.sessions).contains { [codex.id, claude.id, pinnedChat.id].contains($0.id) })

        let chats = ProjectProjection.chats(from: sessions, projects: projects, home: home)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                              isFiltering: false, disclosure: SidebarDisclosure(rowLimit: 5))
        XCTAssertEqual(layout.pinned.map(\.id), [.session(pinnedChat.id)], "A pinned chat goes to Pinned")
        XCTAssertEqual(layout.chats?.rows.map(\.id), [.session(claude.id), .session(codex.id)])
        XCTAssertEqual(layout.chats?.hiddenRowCount, 0)
        XCTAssertEqual(layout.sections.map(\.group.displayName), ["Notes", "Alpha", "beta"])
        // Keyboard order: Pinned, then Chats, then each project's tasks.
        XCTAssertEqual(layout.rows.map(\.id), [pinnedChat, claude, codex, inProjectChatFolder, legacy, folderTask]
            .map { .session($0.id) })
        XCTAssertEqual(SidebarProjection.adjacentRow(in: layout, selected: .session(codex.id), offset: 1),
                       .session(inProjectChatFolder.id))
        XCTAssertEqual(SidebarProjection.targetRow(in: layout, selected: .session(pinnedChat.id), offset: 1),
                       .session(claude.id))
        XCTAssertNil(SidebarProjection.section(holding: .session(codex.id), in: layout), "Chats never collapse")

        // Without chats there is no section.
        let none = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        XCTAssertNil(none.chats)

        // A task the store keeps elsewhere (another home's chat folder) is not a chat here.
        XCTAssertFalse(ProjectProjection.isChat(codex, in: projects, home: URL(filePath: "/Users/other")))
    }

    func testChatsListFiveRowsAndShowMoreAddsTen() throws {
        let many = (0..<18).map {
            task("Chat \($0)", in: home.appending(path: "Documents/Codex/2026-10-09/chat-\($0)"), minutesAgo: Double($0))
        }
        let chats = ProjectProjection.chats(from: many, projects: [], home: home)
        func layout(_ disclosure: SidebarDisclosure, selection: WindowItem? = nil) -> SidebarProjection.Layout {
            SidebarProjection.layout(visibleGroups: [], allGroups: [], chats: chats, splits: [], isFiltering: false,
                                     disclosure: disclosure, selection: selection)
        }
        let limited = try XCTUnwrap(layout(SidebarDisclosure(rowLimit: SidebarDisclosure.codexRowLimit)).chats)
        XCTAssertEqual(limited.rows.map(\.title), (0..<5).map { "Chat \($0)" })
        XCTAssertEqual(limited.hiddenRowCount, 13)
        let once = try XCTUnwrap(layout(SidebarDisclosure(revealedPages: [SidebarChats.disclosureKey: 1], rowLimit: 5)).chats)
        XCTAssertEqual(once.rows.count, 15)
        let twice = try XCTUnwrap(layout(SidebarDisclosure(revealedPages: [SidebarChats.disclosureKey: 2], rowLimit: 5)).chats)
        XCTAssertEqual(twice.hiddenRowCount, 0)
        // The shown chat stays listed past the limit.
        let selected = try XCTUnwrap(layout(SidebarDisclosure(rowLimit: 5), selection: .session(many[12].id)).chats)
        XCTAssertEqual(selected.rows.map(\.title), (0..<5).map { "Chat \($0)" } + ["Chat 12"])
    }

    func testASearchListsMatchingChatsAndASplitStaysWithItsChat() throws {
        let weather = task("Ask about the weather", in: codexChat, minutesAgo: 1, harness: .codex)
        let trip = task("Plan a trip", in: claudeChat, minutesAgo: 2)
        let chats = ProjectProjection.chats(from: [weather, trip], projects: [], home: home)
        let found = TaskNavigationProjection.filteredSessions(chats, query: " trip ")
        XCTAssertEqual(found.map(\.id), [trip.id])
        XCTAssertTrue(TaskNavigationProjection.filteredSessions(chats, query: "new-chat").isEmpty,
                      "A chat's folder name says nothing about it")
        let searched = SidebarProjection.layout(visibleGroups: [], allGroups: [], chats: found, allChats: chats,
                                                splits: [], isFiltering: true)
        XCTAssertEqual(searched.chats?.rows.map(\.id), [.session(trip.id)])

        var split = SplitGroup(root: .pane(SplitPane(sessionID: weather.id)))
        split.split(.right, placing: trip.id)
        let withSplit = SidebarProjection.layout(visibleGroups: [], allGroups: [], chats: chats, splits: [split],
                                                 isFiltering: false)
        XCTAssertEqual(withSplit.chats?.rows.map(\.id), [.split(split.id)], "The split's tasks are not listed again")
    }

    /// A chat's folder name (`new-chat-4`) is generated and says nothing about the task, so a chat's
    /// fallback title leaves it out, and a title Yardlet stored with it before reads without it from
    /// the index, for every place that shows the task's title.
    func testAChatsTitleLeavesOutItsFolderName() async throws {
        XCTAssertEqual(SessionTitleProjection.fallbackTitle(firstUserMessage: "디스크 좀 비우자",
                                                            workspaceURL: yardletChat, home: home), "디스크 좀 비우자")
        XCTAssertEqual(SessionTitleProjection.fallbackTitle(firstUserMessage: "앱이 잘 작동하니?",
                                                            workspaceURL: yardletChat, home: home), "앱이 잘 작동하니")
        XCTAssertEqual(SessionTitleProjection.fallbackTitle(firstUserMessage: "디스크 좀 비우자",
                                                            workspaceURL: alpha, home: home), "alpha · 디스크 좀 비우자")

        let root = FileManager.default.temporaryDirectory.appending(path: "chat-titles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = task("new-chat · Ask about the weather", in: yardletChat, minutesAgo: 0, titleOrigin: .automatic)
        let korean = task("new-chat 작동 상태 확인", in: yardletChat, minutesAgo: 0, titleOrigin: .automatic)
        let provider = task("new-chat · kept", in: yardletChat, minutesAgo: 0, titleOrigin: .provider)
        let manual = task("new-chat · kept", in: yardletChat, minutesAgo: 0, titleOrigin: .manual)
        let inProject = task("alpha · Fix tests", in: alpha, minutesAgo: 0, titleOrigin: .automatic)
        let writer = try SQLiteSessionRepository(databaseURL: root.appending(path: "sessions.sqlite3"),
                                                 chatWorkspaceHome: home)
        for session in [fallback, korean, provider, manual, inProject] { try await writer.upsert(session) }
        let read = try await SQLiteSessionRepository(databaseURL: root.appending(path: "sessions.sqlite3"),
                                                     chatWorkspaceHome: home).loadSessions()
        let titles = Dictionary(uniqueKeysWithValues: read.map { ($0.id, $0.title) })
        XCTAssertEqual(titles[fallback.id], "Ask about the weather")
        XCTAssertEqual(titles[korean.id], "작동 상태 확인")
        XCTAssertEqual(titles[provider.id], "new-chat · kept", "A provider's title shows as it gave it")
        XCTAssertEqual(titles[manual.id], "new-chat · kept", "A name the person gave shows as given")
        XCTAssertEqual(titles[inProject.id], "alpha · Fix tests", "A project's folder name stays in its stored title")

        XCTAssertEqual(SidebarProjection.chatRowTitle(for: SidebarRow(content: .session(fallback))), "Ask about the weather")
        XCTAssertEqual(SidebarProjection.chatRowTitle(for: SidebarRow(content: .session(provider))), "new-chat · kept")
    }

    /// A task that already belongs to a project, by its ID (a worktree or a subfolder imported into
    /// its repository's project) or by its worktree's origin, gives its own folder no project; a
    /// task in no project still makes one, and a chat makes none.
    @MainActor
    func testOnlyATaskInNoProjectMakesAProjectOfItsFolder() {
        let store = ProjectStore(chatWorkspaceHome: home)
        let repository = store.ensureProject(forRoot: alpha)
        let worktree = alpha.appending(path: ".claude/worktrees/blue")
        let subfolder = alpha.appending(path: "backend")
        var byOrigin = task("Origin", in: URL(filePath: "/tmp/chat-sidebar/elsewhere/alpha-tree"), minutesAgo: 0)
        byOrigin.originWorkspacePath = alpha.path(percentEncoded: false)
        store.ensureProjects(forTasks: [
            task("Worktree", in: worktree, minutesAgo: 0, projectID: repository.id),
            task("Subfolder", in: subfolder, minutesAgo: 0, projectID: repository.id),
            byOrigin,
            task("Chat", in: codexChat, minutesAgo: 0),
            task("Plain", in: beta, minutesAgo: 0)
        ])
        XCTAssertEqual(store.projects.map(\.name), ["alpha", "beta"])
    }

    @MainActor
    func testATasksChatFolderBecomesNoProjectButAProjectsFolderStaysOne() {
        let store = ProjectStore(chatWorkspaceHome: home)
        XCTAssertNil(store.ensureProject(forTaskIn: codexChat))
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(store.ensureProject(forTaskIn: alpha)?.name, "alpha")
        // Added explicitly, a chat's folder is a project, and its tasks join it.
        let added = store.ensureProject(forRoot: yardletChat)
        XCTAssertEqual(store.ensureProject(forTaskIn: yardletChat)?.id, added.id)

        // Converting the old folder settings makes no project for a chat's folder either.
        store.importFolderPreferences(LegacyProjectFolderPreferences(), sessionWorkspaceURLs: [claudeChat, beta])
        XCTAssertEqual(Set(store.projects.map(\.name)), ["alpha", "new-chat", "beta"])
        XCTAssertEqual(store.chats(sessions: [task("Trip", in: claudeChat, minutesAgo: 0)]).count, 1)
    }

    func testNewStringsAreLocalized() {
        XCTAssertEqual(L10n.string("Chats", languageCode: "en"), "Chats")
        XCTAssertEqual(L10n.string("Chats", languageCode: "ko"), "채팅")
        XCTAssertEqual(L10n.string("Chat (no project)", languageCode: "en"), "Chat (no project)")
        XCTAssertEqual(L10n.string("Chat (no project)", languageCode: "ko"), "채팅(프로젝트 없음)")
    }
}

/// Renders the sidebar with a Chats section offscreen into `.build/sidebar-qa`, light and dark:
/// chats from Codex, Claude Code and Yardlet with running and unread marks, a pinned chat, "Show
/// more", and a project below. No provider, window server interaction, or app launch.
@MainActor
final class ChatSidebarRenderingTests: XCTestCase {
    func testTheSidebarDrawsChatsAboveProjects() throws {
        let home = URL(filePath: "/tmp/chat-sidebar-qa/home", directoryHint: .isDirectory)
        let project = URL(filePath: "/tmp/chat-sidebar-qa/yardlet-sandbox", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        _ = projects.ensureProject(forRoot: project)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  status: SessionStatus = .ready, origin: SessionTitleOrigin = .provider, unread: Bool = false,
                  pinned: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                          title: title, titleOrigin: origin, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                          completionState: unread ? .completed : .none, isPinned: pinned)
        }
        func chat(_ path: String) -> URL { home.appending(path: path, directoryHint: .isDirectory) }
        let running = task("Summarize the meeting notes", .claudeCode, in: chat("Documents/Yardlet/2026-10-12/new-chat"),
                           minutesAgo: 1, status: .running)
        let unread = task("new-chat-2 · What's the weather today", .codex, in: chat("Documents/Yardlet/2026-10-12/new-chat-2"),
                          minutesAgo: 2, status: .completed, origin: .automatic, unread: true)
        let selected = task("Draft an email to the team", .codex, in: chat("Documents/Codex/2026-10-09/new-chat"),
                            minutesAgo: 3)
        let claudeApp = task("Plan the weekend trip", .claudeCode,
                             in: chat("Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1"), minutesAgo: 4)
        let older = (0..<3).map { task("Older chat \($0 + 1)", .claudeCode,
                                       in: chat("Documents/Yardlet/2026-10-11/new-chat-\($0 + 1)"),
                                       minutesAgo: Double(10 + $0)) }
        let pinned = task("Pinned chat", .claudeCode, in: chat("Documents/Yardlet/2026-10-10/new-chat"), minutesAgo: 6,
                          pinned: true)
        let projectTask = task("Nest task rows under their project", .codex, in: project, minutesAgo: 5)
        let sessions = [running, unread, selected, claudeApp, pinned, projectTask] + older

        let suite = testDefaultsSuite("chat-sidebar-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        let groups = projects.visibleGroups(sessions: sessions)
        let chats = projects.chats(sessions: sessions)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                              isFiltering: false, disclosure: disclosure.disclosure,
                                              selection: .session(selected.id))
        XCTAssertEqual(layout.chats?.rows.count, 5)
        XCTAssertEqual(layout.chats?.hiddenRowCount, 2)
        XCTAssertEqual(layout.pinned.map(\.id), [.session(pinned.id)])
        XCTAssertEqual(layout.sections.map(\.group.displayName), ["yardlet-sandbox"])

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 560)
        try WindowlessRender.hostedInBothAppearances("sidebar-chats", in: WindowlessRender.directory("sidebar-qa"),
                                                     size: size) {
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .environment(\.colorScheme, $0.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }

        // What the sidebar exposes, in reading order: Pinned, Chats with its rows, then Projects.
        let host = WindowlessRender.Host(
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(selected.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
                .frame(width: size.width, height: size.height, alignment: .top),
            size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        func index(of text: String) throws -> Int {
            try XCTUnwrap(elements.firstIndex { $0.label == text || $0.value == text }, "\(text): \(elements)")
        }
        let pinnedTitle = try index(of: L10n.string("Pinned"))
        let chatsTitle = try index(of: L10n.string("Chats"))
        let projectsTitle = try index(of: L10n.string("Projects"))
        XCTAssertLessThan(pinnedTitle, chatsTitle)
        XCTAssertLessThan(chatsTitle, projectsTitle)
        let firstChat = try index(of: "Summarize the meeting notes, Claude Code")
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(firstChat))
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(try index(of: "What's the weather today, Codex")),
                      "The folder name is dropped from a fallback title")
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(try index(of: L10n.string("Show more"))))
    }
}
