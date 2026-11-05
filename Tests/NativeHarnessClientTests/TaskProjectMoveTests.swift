import AppKit
import SQLite3
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Moving a task to another project, or out of its project to Chats, as the Codex app's sidebar
/// moves a thread. Only the task's project, the roots that come along and whether the person moved
/// it to Chats change; its folder, provider session, storage scope, account, draft and pin stay,
/// and relaunch keeps the move.
@MainActor
final class TaskProjectMoveTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    private var chatFolder: URL { home.appending(path: "Documents/Codex/2026-08-25/new-chat", directoryHint: .isDirectory) }
    private var thirteen: URL { root.appending(path: "13weeks", directoryHint: .isDirectory) }
    private var thirteenNotes: URL { root.appending(path: "13weeks-notes", directoryHint: .isDirectory) }
    private var alpha: URL { root.appending(path: "alpha", directoryHint: .isDirectory) }
    private var alphaDocs: URL { root.appending(path: "alpha-docs", directoryHint: .isDirectory) }
    private var beta: URL { root.appending(path: "beta", directoryHint: .isDirectory) }
    private let connection = ProviderConnection(id: "codex-work", name: "Work", harness: .codex, providerID: nil,
                                                homePath: "/tmp/yardlet-move-test-codex-home", credentialSelector: nil)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-move-project-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in `codex` that exists, so relaunch does not look for another runtime.
    private func runtime() throws -> URL {
        let executable = root.appending(path: "codex")
        if !FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) {
            try Data("#!/bin/sh\necho 'codex-cli 0.160.0'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: executable.path(percentEncoded: false))
        }
        return executable
    }

    private func task(_ title: String, in folder: URL, projectID: UUID? = nil, additionalRoots: [String] = [],
                      status: SessionStatus = .completed, pinned: Bool = false) throws -> SessionRecord {
        SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: try runtime(), title: title,
                      titleOrigin: .provider, status: status,
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                      providerSessionID: "thread-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                      hasUnreadUpdate: true, completionState: .completed, isPinned: pinned,
                      providerOptions: ["model": "gpt-5.6-codex"], environmentScope: .yardlet,
                      connection: connection, projectID: projectID, additionalRoots: additionalRoots)
    }

    /// A model whose index holds `sessions` exactly as given and whose project list is `projects`.
    private func makeModel(sessions: [SessionRecord] = [], projects: [Project] = [],
                       registry: HarnessRegistry? = nil) throws -> AppModel {
        try makeModel(sessions: sessions, projectRepository: InMemoryProjectRepository(
            snapshot: ProjectSnapshot(projects: projects, didImportFolderPreferences: true)), registry: registry)
    }

    private func makeModel(sessions: [SessionRecord] = [], repository: (any SessionRepository)? = nil,
                       projectRepository: any ProjectRepository,
                       registry: HarnessRegistry? = nil, restores: Bool = false) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskProjectMoveTests")))
        let model = AppModel(
            store: SessionStore(sessions: sessions,
                                repository: repository ?? InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: registry, preferences: defaults, projectRepository: projectRepository,
            chatWorkspaceHome: home, legacyProjectFolderPreferences: LegacyProjectFolderPreferences(),
            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: restores)
        addTeardownBlock { await model.shutdown() }
        return model
    }

    /// The task's other fields, which a move must leave exactly as they were.
    private func unchangedFields(_ session: SessionRecord) -> SessionRecord {
        var copy = session
        copy.assignProject(nil, additionalRoots: [])
        return copy
    }

    private func visibleProjects(_ model: AppModel) -> [Project] {
        model.projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project)
    }

    // MARK: - Moving

    func testMovingBetweenProjectsChangesOnlyTheProjectAndTheRootsThatComeAlong() async throws {
        let alphaProject = Project(name: "Alpha", primaryRoot: alpha, additionalRoots: [alphaDocs])
        let betaProject = Project(name: "Beta", primaryRoot: beta, additionalRoots: [thirteenNotes])
        let session = try task("Fix the login form", in: alpha, projectID: alphaProject.id,
                               additionalRoots: [alphaDocs.path(percentEncoded: false)])
        let model = try makeModel(sessions: [session], projects: [alphaProject, betaProject])
        model.composerDrafts.tasks.draft(for: session.id).text = "Keep this unsent draft"
        let betaRootsBefore = try XCTUnwrap(model.projects.project(id: betaProject.id)).roots

        let options = model.projectMoveOptions(for: session, visibleProjects: visibleProjects(model))
        XCTAssertEqual(options.destinations.map(\.name), ["Beta"], "Every visible project but the task's own")
        XCTAssertEqual(options.removableFrom?.id, alphaProject.id, "Any task in a project can go to Chats")

        let moved = try await move(session, to: betaProject, in: model)
        XCTAssertEqual(moved.projectID, betaProject.id)
        XCTAssertEqual(moved.workspaceURL, alpha.standardizedFileURL, "The task keeps running in its own folder")
        XCTAssertEqual(moved.additionalRoots, [beta, thirteenNotes].map { $0.path(percentEncoded: false) }
            .map { ProjectSidebarPresentation.normalizedPath(for: URL(filePath: $0)) },
                       "The project's roots come along, as they do for a task started in it")
        XCTAssertEqual(unchangedFields(moved), unchangedFields(session),
                       "Folder, provider ID, scope, account, title, status, pin, unread and recency stay")
        XCTAssertEqual(model.store.sessions.first { $0.id == session.id }, moved)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: session.id).text, "Keep this unsent draft")
        XCTAssertEqual(model.projects.project(id: betaProject.id)?.roots, betaRootsBefore, "The project's roots stay")
        XCTAssertEqual(model.projects.project(id: alphaProject.id)?.roots, [alpha, alphaDocs].map(Project.canonical))

        let groups = model.projects.visibleGroups(sessions: model.store.sessions)
        XCTAssertEqual(groups.first { $0.project?.id == betaProject.id }?.sessions.map(\.id).contains(session.id), true)
        XCTAssertEqual(groups.first { $0.project?.id == alphaProject.id }?.sessions.map(\.id).contains(session.id),
                       false, "The old project stays, without the task")

        // Back to where it came from: the project's other root comes along again.
        let back = try await move(moved, to: alphaProject, in: model)
        XCTAssertEqual(back.projectID, alphaProject.id)
        XCTAssertEqual(back.additionalRoots, [ProjectSidebarPresentation.normalizedPath(for: alphaDocs)])
        XCTAssertEqual(unchangedFields(back), unchangedFields(session))
    }

    func testAChatMovesIntoAProjectAndBackToChats() async throws {
        let thirteenProject = Project(name: "13 Weeks", primaryRoot: thirteen)
        let other = Project(name: "Website", primaryRoot: beta)
        let chat = try task("Finish the OpenAI Game 2026 web game", in: chatFolder)
        let model = try makeModel(sessions: [chat], projects: [thirteenProject, other])
        model.composerDrafts.tasks.draft(for: chat.id).text = "Next step"
        XCTAssertTrue(ProjectProjection.isChat(chat, in: model.projects.projects, home: home))

        let asChat = model.projectMoveOptions(for: chat, visibleProjects: visibleProjects(model))
        XCTAssertEqual(Set(asChat.destinations.map(\.name)), ["13 Weeks", "Website"])
        XCTAssertNil(asChat.removableFrom, "A chat is in no project to leave")

        let moved = try await move(chat, to: thirteenProject, in: model)
        XCTAssertEqual(moved.projectID, thirteenProject.id)
        XCTAssertEqual(moved.workspaceURL, chatFolder.standardizedFileURL, "The chat's folder stays its cwd")
        XCTAssertEqual(moved.additionalRoots, [ProjectSidebarPresentation.normalizedPath(for: thirteen)],
                       "The project's folder comes along for the next start")
        XCTAssertEqual(unchangedFields(moved), unchangedFields(chat))
        XCTAssertFalse(ProjectProjection.isChat(moved, in: model.projects.projects, home: home))
        XCTAssertTrue(model.projects.chats(sessions: model.store.sessions).isEmpty)
        XCTAssertEqual(model.projects.visibleGroups(sessions: model.store.sessions)
            .first { $0.project?.id == thirteenProject.id }?.sessions.map(\.id), [chat.id])
        XCTAssertFalse(model.projects.isChatFolder(thirteen))
        XCTAssertEqual(model.projects.project(id: thirteenProject.id)?.roots, [Project.canonical(thirteen)])

        // In the project, its folder being a chat's, it can go back.
        let inProject = model.projectMoveOptions(for: moved, visibleProjects: visibleProjects(model))
        XCTAssertEqual(inProject.destinations.map(\.id), [other.id])
        XCTAssertEqual(inProject.removableFrom?.id, thirteenProject.id)
        XCTAssertEqual(TaskProjectMove.commands(inProject).map(\.title), [
            L10n.format("Move to project: %@", "Website"), L10n.string("Move to Chats")
        ])
        XCTAssertEqual(TaskProjectMove.commands(inProject).map(\.destination?.id), [other.id, nil])

        let back = try await move(moved, to: nil, in: model)
        XCTAssertNil(back.projectID)
        XCTAssertEqual(back.additionalRoots, [], "A chat has no other roots, as a new chat has none")
        XCTAssertEqual(unchangedFields(back), unchangedFields(chat))
        XCTAssertEqual(model.projects.chats(sessions: model.store.sessions).map(\.id), [chat.id])
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: chat.id).text, "Next step")
        // Making projects for tasks in none, as the window does, gives the chat's folder none.
        let projectCount = model.projects.projects.count
        model.projects.ensureProjects(forTasks: model.store.sessions)
        XCTAssertEqual(model.projects.projects.count, projectCount)
    }

    /// A task in its project's own folder moves to Chats too, from the same menus: Yardlet's index
    /// records the person's choice (`isMovedToChats`), so the folder does not put it back. It keeps
    /// working in its folder without the project's other roots, and every list of tasks shows it
    /// under Chats: the sidebar, the menu bar's lists, `list_tasks`, the phone's snapshot and
    /// another Mac's window. A later move to a project clears the choice.
    func testATaskInItsProjectsFolderMovesToChatsAndEveryListShowsItThere() async throws {
        let alphaProject = Project(name: "Alpha", primaryRoot: alpha, additionalRoots: [alphaDocs])
        let betaProject = Project(name: "Beta", primaryRoot: beta)
        // Its folder is the project's: without the project ID the folder rule puts it there.
        let byFolder = try task("By folder", in: alpha)
        let withID = try task("With ID", in: alpha, projectID: alphaProject.id,
                              additionalRoots: [alphaDocs.path(percentEncoded: false)])
        // A chat's folder the person added as a project.
        let addedChatFolder = home.appending(path: "Documents/Yardlet/2026-10-12/new-chat", directoryHint: .isDirectory)
        let notes = Project(name: "Notes", primaryRoot: addedChatFolder)
        let inAddedChatFolder = try task("Notes", in: addedChatFolder, projectID: notes.id)
        let model = try makeModel(sessions: [byFolder, withID, inAddedChatFolder],
                                  projects: [alphaProject, betaProject, notes])
        model.composerDrafts.tasks.draft(for: withID.id).text = "Keep this unsent draft"

        for (session, project) in [(byFolder, alphaProject), (withID, alphaProject), (inAddedChatFolder, notes)] {
            let options = model.projectMoveOptions(for: session, visibleProjects: visibleProjects(model))
            XCTAssertEqual(options.removableFrom?.id, project.id, session.title)
            XCTAssertTrue(options.allows(nil), session.title)
            XCTAssertEqual(TaskProjectMove.commands(options).last.map { [$0.id, $0.title] },
                           ["move-to-chats", L10n.string("Move to Chats")], session.title)
        }
        let snapshotBefore = AppModelRemoteBridge.snapshot(of: model)
        XCTAssertEqual(snapshotBefore.tasks.first { $0.id == withID.id.uuidString }?.canReturnToChats, true,
                       "Another Mac's window offers the move too")

        let moved = try await move(withID, to: nil, in: model)
        XCTAssertNil(moved.projectID)
        XCTAssertTrue(moved.isMovedToChats, "The index records the person's choice")
        XCTAssertEqual(moved.workspaceURL, alpha.standardizedFileURL, "The task keeps working in its own folder")
        XCTAssertEqual(moved.additionalRoots, [], "It loses the project's other roots, as a chat has none")
        XCTAssertEqual(unchangedFields(moved), unchangedFields(withID),
                       "Provider ID, scope, account, title, status, pin, unread and recency stay")
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: withID.id).text, "Keep this unsent draft")
        XCTAssertEqual(model.projects.project(id: alphaProject.id)?.roots, [alpha, alphaDocs].map(Project.canonical),
                       "The project's roots stay")
        XCTAssertNil(model.project(for: moved))
        XCTAssertEqual(model.projects.displayName(for: moved), L10n.string("Chats"), "The title bar and menus say Chats")

        // Every list of tasks shows it under Chats, and the project keeps its other task.
        let sessions = model.store.sessions
        XCTAssertEqual(model.projects.chats(sessions: sessions).map(\.id), [moved.id])
        XCTAssertEqual(model.projects.visibleGroups(sessions: sessions)
            .first { $0.project?.id == alphaProject.id }?.sessions.map(\.id), [byFolder.id])
        XCTAssertEqual(model.sidebarLists.chats?.allRows.flatMap(\.familySessions).map(\.id), [moved.id])
        XCTAssertEqual(model.taskPlaceNames()(moved), L10n.string("Chats"))
        struct Listing: Decodable {
            struct Entry: Decodable { let taskId: String; let project: String? }
            let tasks: [Entry]
        }
        let listing = await model.callSessionTool(named: "list_tasks",
                                                  arguments: .object(["scope": .string("all")]), callerID: byFolder.id)
        let entries = try JSONDecoder().decode(Listing.self, from: Data(listing.text.utf8)).tasks
        XCTAssertNil(try XCTUnwrap(entries.first { $0.taskId == moved.id.uuidString }).project, "list_tasks names no project")
        XCTAssertEqual(entries.first { $0.taskId == byFolder.id.uuidString }?.project, "Alpha")
        let snapshot = AppModelRemoteBridge.snapshot(of: model)
        XCTAssertEqual(snapshot.tasks.first { $0.id == moved.id.uuidString }?.projectId,
                       RemoteTaskProjection.chatsProjectID, "The phone lists it under Chats")
        let mirror = RemoteSidebarMirror(hostID: "host", projects: snapshot.projects, tasks: snapshot.tasks)
        XCTAssertEqual(mirror.chats.map(\.id), [moved.id], "Another Mac's window lists it under Chats")
        XCTAssertEqual(mirror.groups.first { $0.project?.id == alphaProject.id }?.sessions.map(\.id), [byFolder.id])

        // The window gives each task in no project a project of its folder: none for this one, and
        // the hidden project of its folder stays hidden.
        model.projects.hide(alphaProject.id)
        let projectCount = model.projects.projects.count
        model.projects.ensureProjects(forTasks: model.store.sessions)
        XCTAssertEqual(model.projects.projects.count, projectCount)
        XCTAssertEqual(model.projects.project(id: alphaProject.id)?.isHidden, true)
        model.projects.reveal(alphaProject.id)

        // In Chats it is in no project to leave, and its folder's project is a destination again.
        let asChat = model.projectMoveOptions(for: moved, visibleProjects: visibleProjects(model))
        XCTAssertNil(asChat.removableFrom)
        XCTAssertEqual(Set(asChat.destinations.map(\.name)), ["Alpha", "Beta", "Notes"])
        let back = try await move(moved, to: alphaProject, in: model)
        XCTAssertFalse(back.isMovedToChats, "A move to a project clears the choice")
        XCTAssertEqual(back, withID, "Back where it was, with the project's roots")
        // From Chats to another project, the same.
        let byFolderInChats = try await move(byFolder, to: nil, in: model)
        XCTAssertTrue(model.projects.isChat(byFolderInChats))
        let inBeta = try await move(byFolderInChats, to: betaProject, in: model)
        XCTAssertEqual(inBeta.projectID, betaProject.id)
        XCTAssertFalse(inBeta.isMovedToChats)
        XCTAssertEqual(inBeta.additionalRoots, [ProjectSidebarPresentation.normalizedPath(for: beta)])
        XCTAssertTrue(model.projects.chats(sessions: model.store.sessions).isEmpty)

        // A project the task is already in, or one that is hidden, is not a destination.
        model.projects.hide(betaProject.id)
        let hidden = try XCTUnwrap(model.projects.project(id: betaProject.id))
        let options = model.projectMoveOptions(for: back, visibleProjects: visibleProjects(model))
        XCTAssertEqual(options.destinations.map(\.name), ["Notes"])
        let refusedHidden = await model.moveTask(back, to: hidden)
        XCTAssertNil(refusedHidden)
        let refusedSame = await model.moveTask(back, to: alphaProject)
        XCTAssertNil(refusedSame)
        XCTAssertEqual(model.store.sessions.first { $0.id == withID.id }, back)
    }

    /// The submenu lists the projects in the sidebar's order: pinned projects first, then recency.
    func testTheDestinationsFollowTheSidebarOrder() throws {
        let projects = ProjectStore(chatWorkspaceHome: home)
        let older = projects.ensureProject(forRoot: alpha, name: "Older")
        let newer = projects.ensureProject(forRoot: beta, name: "Newer")
        let pinned = projects.ensureProject(forRoot: thirteen, name: "Pinned")
        projects.togglePinned(pinned.id)
        let chat = try task("Chat", in: chatFolder)
        var olderTask = try task("Older task", in: alpha, projectID: older.id)
        olderTask.updatedAt = Date(timeIntervalSince1970: 1_000)
        let newerTask = try task("Newer task", in: beta, projectID: newer.id)
        let order = projects.visibleGroups(sessions: [chat, olderTask, newerTask]).compactMap(\.project)
        let options = TaskProjectMove.options(for: chat, visibleProjects: order, projects: projects.projects)
        XCTAssertEqual(options.destinations.map(\.name), ["Pinned", "Newer", "Older"])
        XCTAssertEqual(TaskProjectMove.commands(options).map(\.id),
                       [pinned, newer, older].map { "move-to-project-\($0.id.uuidString)" })
    }

    /// A worktree stands in for the root it was checked out from, as it does for a task started in
    /// a new worktree; a task in Chats gets no other roots.
    func testAWorktreeStandsInForItsRepositoryAmongTheRoots() throws {
        let project = Project(name: "Alpha", primaryRoot: alpha, additionalRoots: [alphaDocs])
        let worktree = root.appending(path: "worktrees/alpha/blue", directoryHint: .isDirectory)
        var inWorktree = try task("Worktree", in: worktree)
        inWorktree.originWorkspacePath = alpha.path(percentEncoded: false)
        XCTAssertEqual(TaskProjectMove.additionalRoots(for: inWorktree, in: project),
                       [ProjectSidebarPresentation.normalizedPath(for: alphaDocs)])
        XCTAssertEqual(TaskProjectMove.additionalRoots(for: try task("Docs", in: alphaDocs), in: project),
                       [ProjectSidebarPresentation.normalizedPath(for: alpha)])
        XCTAssertEqual(TaskProjectMove.additionalRoots(for: inWorktree, in: nil), [])
        XCTAssertEqual(TaskProjectMove.moved(inWorktree, to: project).originWorkspacePath,
                       inWorktree.originWorkspacePath)
    }

    // MARK: - Relaunch

    /// A relaunch keeps every move, a move to Chats of a task in its project's folder too; an index
    /// from before that was recorded gains its column, with its rows where their folders put them.
    func testRelaunchKeepsTheMove() async throws {
        let database = root.appending(path: "sessions.sqlite3")
        let projectFile = FileProjectRepository(fileURL: root.appending(path: "projects.json"))
        let thirteenProject = Project(name: "13 Weeks", primaryRoot: thirteen)
        let alphaProject = Project(name: "Alpha", primaryRoot: alpha)
        let betaProject = Project(name: "Beta", primaryRoot: beta)
        projectFile.save(ProjectSnapshot(projects: [thirteenProject, alphaProject, betaProject],
                                         didImportFolderPreferences: true))
        let chat = try task("Finish the OpenAI Game 2026 web game", in: chatFolder)
        let returned = try task("Returned chat", in: home.appending(
            path: "Documents/Codex/2026-08-26/new-chat", directoryHint: .isDirectory))
        let legacy = try task("Legacy task", in: alpha)
        XCTAssertNil(legacy.projectID, "Written before projects: its folder puts it in Alpha")
        let inAlpha = try task("Organize the notes", in: alpha)
        // An index the build before wrote, with no `moved_to_chats`.
        let older = UUID()
        let runtimePath = try runtime().path(percentEncoded: false)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0,
                project_id TEXT, additional_roots TEXT, lineage_detached INTEGER NOT NULL DEFAULT 0);
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at)
                VALUES ('\(older.uuidString)', 'codex', '\(alpha.path(percentEncoded: false))',
                '\(runtimePath)', 'Written before the column', 'completed', 1, 2);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let index = try SQLiteSessionRepository(databaseURL: database)
        let olderRows = try await index.loadSessions()
        XCTAssertEqual(olderRows.map(\.id), [older])
        XCTAssertEqual(olderRows.first?.isMovedToChats, false, "An older row is not moved: its folder places it")
        for session in [chat, returned, legacy, inAlpha] { try await index.upsert(session) }
        let first = try makeModel(repository: index, projectRepository: projectFile, restores: true)
        await first.restoreIndex()
        XCTAssertEqual(first.store.sessions.count, 5)

        let movedChat = try await move(chat, to: thirteenProject, in: first)
        let movedLegacy = try await move(legacy, to: betaProject, in: first)
        let intoProject = try await move(returned, to: alphaProject, in: first)
        let backToChats = try await move(intoProject, to: nil, in: first)
        let toChats = try await move(inAlpha, to: nil, in: first)
        first.projects.persistNow()
        let projectCount = first.projects.projects.count
        await first.shutdown()

        let second = try makeModel(repository: try SQLiteSessionRepository(databaseURL: database),
                               projectRepository: projectFile, restores: true)
        await second.restoreIndex()
        // The window gives each task in no project a project of its folder.
        second.projects.ensureProjects(forTasks: second.store.sessions)
        XCTAssertEqual(second.projects.projects.count, projectCount, "No project is made for a moved task's folder")

        func restored(_ session: SessionRecord) throws -> SessionRecord {
            try XCTUnwrap(second.store.sessions.first { $0.id == session.id })
        }
        XCTAssertEqual(try restored(chat), movedChat)
        XCTAssertEqual(try restored(legacy), movedLegacy)
        XCTAssertEqual(try restored(returned), backToChats)
        XCTAssertEqual(try restored(inAlpha), toChats)
        XCTAssertTrue(try restored(inAlpha).isMovedToChats)
        XCTAssertEqual(second.project(for: try restored(chat))?.id, thirteenProject.id)
        XCTAssertEqual(second.project(for: try restored(legacy))?.id, betaProject.id,
                       "The project ID wins over the folder's project")
        XCTAssertNil(second.project(for: try restored(inAlpha)), "Its folder does not put it back in Alpha")
        XCTAssertEqual(Set(second.projects.chats(sessions: second.store.sessions).map(\.id)), [returned.id, inAlpha.id])
        let groups = second.projects.visibleGroups(sessions: second.store.sessions)
        XCTAssertEqual(groups.first { $0.project?.id == thirteenProject.id }?.sessions.map(\.id), [chat.id])
        XCTAssertEqual(groups.first { $0.project?.id == betaProject.id }?.sessions.map(\.id), [legacy.id])
        XCTAssertEqual(groups.first { $0.project?.id == alphaProject.id }?.sessions.map(\.id), [older])

        // A later move to a project clears the choice in the index too.
        _ = try await move(try restored(inAlpha), to: betaProject, in: second)
        let reread = try await SQLiteSessionRepository(databaseURL: database).loadSessions()
        let inBeta = try XCTUnwrap(reread.first { $0.id == inAlpha.id })
        XCTAssertEqual(inBeta.projectID, betaProject.id)
        XCTAssertFalse(inBeta.isMovedToChats)
    }

    // MARK: - Running task

    /// A running task moves too: the move is where the task is listed. Its turn and attached
    /// session go on untouched, and the next start or resume hands the harness the new roots.
    func testARunningTaskMovesWithoutTouchingItsTurnAndLaterStartsGetTheNewRoots() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let target = Project(name: "13 Weeks", primaryRoot: thirteen)
        let model = try makeModel(projects: [target], registry: HarnessRegistry { _, _ in adapter })
        let started = await model.createSession(harness: .codex, workspaceURL: alpha,
                                                runtimeExecutableURL: try runtime(), title: "Long build")
        let created = try XCTUnwrap(started)
        await adapter.emit(.sessionStatusChanged(.running), for: created.id, sequence: 10)
        try await waitUntil { model.store.sessions.first?.status == .running }
        let running = try XCTUnwrap(model.store.sessions.first { $0.id == created.id })
        XCTAssertEqual(running.status, .running)
        XCTAssertTrue(model.isAttached(running.id))
        let options = model.projectMoveOptions(for: running, visibleProjects: visibleProjects(model))
        XCTAssertTrue(options.allows(target), "Moving is offered while a turn runs")
        let createsBefore = await adapter.createCount

        let moved = try await move(running, to: target, in: model)
        XCTAssertEqual(moved.status, .running)
        XCTAssertEqual(moved.updatedAt, running.updatedAt, "A move is not activity")
        XCTAssertTrue(model.isAttached(running.id), "The attached session stays")
        await adapter.emit(.assistantDelta("Still streaming"), for: running.id, sequence: 11)
        try await waitUntil { model.transcriptBySessionID[running.id]?.isEmpty == false }
        XCTAssertTrue(model.transcriptBySessionID[running.id]?.contains {
            if case let .assistant(text, _) = $0.content { return text == "Still streaming" }
            return false
        } == true, "The turn goes on")
        let creates = await adapter.createCount
        let resumes = await adapter.resumeCount
        let closes = await adapter.closeCount
        XCTAssertEqual(creates, createsBefore)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(closes, 0)

        // The next resume hands the harness the moved task's roots.
        let recorder = RootsRecorder()
        let later = try makeModel(sessions: [moved], registry: HarnessRegistry { _, _ in recorder })
        await later.resume(moved)
        let handed = await recorder.roots[moved.id]
        XCTAssertEqual(handed, [thirteen.standardizedFileURL])
        let resumedIDs = await recorder.resumedProviderIDs
        XCTAssertEqual(resumedIDs, [moved.providerSessionID].compactMap { $0 })
    }

    func testTheNewStringsAreLocalized() {
        XCTAssertEqual(L10n.string("Move to project", languageCode: "en"), "Move to project")
        XCTAssertEqual(L10n.string("Move to project", languageCode: "ko"), "프로젝트로 이동")
        XCTAssertEqual(L10n.string("Move to Chats", languageCode: "en"), "Move to Chats")
        XCTAssertEqual(L10n.string("Move to Chats", languageCode: "ko"), "채팅으로 이동")
        XCTAssertEqual(L10n.string("Move to project: %@", languageCode: "ko"), "프로젝트로 이동: %@")
    }

    // MARK: - Helpers

    /// Moves the task and returns it as moved; fails the test when the move is refused.
    private func move(_ session: SessionRecord, to project: Project?, in model: AppModel) async throws
        -> SessionRecord {
        let moved = await model.moveTask(session, to: project)
        return try XCTUnwrap(moved, "\(session.title) to \(project?.name ?? "Chats")")
    }

    /// A harness that records the roots handed to it before a resume, and runs nothing.
    private actor RootsRecorder: HarnessAdapter, HarnessWorkspaceRootsConfiguring {
        nonisolated let kind = HarnessKind.codex
        private(set) var roots: [UUID: [URL]] = [:]
        private(set) var resumedProviderIDs: [String] = []
        func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
            self.roots[localSessionID] = roots
        }
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
            -> HarnessSessionHandle {
            resumedProviderIDs.append(providerSessionID)
            return HarnessSessionHandle(harness: kind, localSessionID: localSessionID,
                                        providerSessionID: providerSessionID, workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle)
            async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            AsyncStream { _ in }
        }
        func close(_ session: HarnessSessionHandle) async {}
    }
}
