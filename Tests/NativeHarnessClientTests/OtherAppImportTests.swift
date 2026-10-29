import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Importing the conversations open in the Claude and Codex apps all at once: where each one is
/// read from, where it goes in Yardlet, what it carries over, that importing starts no runtime, and
/// how a conversation another app still holds is refused and followed read-only. The fixtures copy
/// the shapes of the real files and answers with made-up values.
@MainActor
final class OtherAppImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "other-app-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Claude desktop sessions

    /// One session file as the Claude app writes it, reduced to what importing uses. Keys it does not
    /// need, a missing key, a worktree and an oversized or ID-less file are all handled.
    func testASessionFileReadsTheFieldsImportUsesAndToleratesMissingOnes() throws {
        let repo = root.appending(path: "repo")
        let worktree = repo.appending(path: ".claude/worktrees/brave-otter")
        let full = sessionFile(id: Self.ids[0], cwd: worktree, origin: repo, title: "Polish the importer",
                               model: "claude-opus-5-5", effort: "xhigh", permission: "bypassPermissions",
                               activity: 1_791_000_000_000, extra: ["branch": .string("claude/brave-otter"),
                                                                   "enabledMcpTools": .object([:]),
                                                                   "completedTurns": .integer(4)])
        let session = try XCTUnwrap(ClaudeDesktopSessionCatalog.session(from: full))
        XCTAssertEqual(session.cliSessionID, Self.ids[0])
        XCTAssertEqual(session.title, "Polish the importer")
        XCTAssertEqual(path(session.workspaceURL), path(worktree))
        XCTAssertEqual(session.originWorkspaceURL.map(path), path(repo))
        XCTAssertEqual(session.worktreeName, "brave-otter")
        XCTAssertEqual(session.branch, "claude/brave-otter")
        XCTAssertEqual(session.model, "claude-opus-5-5")
        XCTAssertEqual(session.effort, "xhigh")
        XCTAssertEqual(session.permissionMode, "bypassPermissions")
        XCTAssertFalse(session.isArchived)
        XCTAssertEqual(session.lastActivityAt, Date(timeIntervalSince1970: 1_791_000_000))

        // Only the CLI session and the folder are needed.
        let bare = try JSONEncoder().encode(JSONValue.object([
            "cliSessionId": .string(Self.ids[1].uppercased()), "cwd": .string(repo.path)]))
        let minimal = try XCTUnwrap(ClaudeDesktopSessionCatalog.session(from: bare))
        XCTAssertEqual(minimal.cliSessionID, Self.ids[1], "IDs compare in lower case")
        XCTAssertNil(minimal.title)
        XCTAssertNil(minimal.originWorkspaceURL)
        XCTAssertNil(minimal.model)
        XCTAssertNil(minimal.lastActivityAt)
        XCTAssertFalse(minimal.isArchived)

        // `originCwd` names the same folder, or one the session is not inside: no worktree.
        let same = sessionFile(id: Self.ids[2], cwd: repo, origin: repo, title: "Plain")
        XCTAssertNil(try XCTUnwrap(ClaudeDesktopSessionCatalog.session(from: same)).originWorkspaceURL)
        let elsewhere = sessionFile(id: Self.ids[2], cwd: repo, origin: root.appending(path: "other"), title: "Plain")
        XCTAssertNil(try XCTUnwrap(ClaudeDesktopSessionCatalog.session(from: elsewhere)).worktreeName)

        XCTAssertNil(ClaudeDesktopSessionCatalog.session(from: Data("not json".utf8)))
        XCTAssertNil(ClaudeDesktopSessionCatalog.session(from: try JSONEncoder().encode(JSONValue.object([
            "sessionId": .string("local_x"), "cwd": .string(repo.path)]))), "No CLI session, nothing to continue")
        XCTAssertNil(ClaudeDesktopSessionCatalog.session(from: try JSONEncoder().encode(JSONValue.object([
            "cliSessionId": .string("not-a-uuid"), "cwd": .string(repo.path)]))))
        XCTAssertNil(ClaudeDesktopSessionCatalog.session(from: try JSONEncoder().encode(JSONValue.object([
            "cliSessionId": .string(Self.ids[3]), "cwd": .string("relative/folder")]))))
        var oversized = full
        oversized.append(Data(repeating: 32, count: ClaudeDesktopSessionCatalog.maximumFileBytes))
        XCTAssertNil(ClaudeDesktopSessionCatalog.session(from: oversized), "A file far larger than a session is not read")
    }

    /// The list is the app's open sessions whose transcript is in the chosen account's history, the
    /// most recent first, each once. Archived ones and ones whose transcript is elsewhere are left
    /// out; one a live process holds is marked. The settings come over under Yardlet's keys.
    func testOnlyOpenSessionsWithATranscriptInTheAccountsHistoryAreListed() throws {
        let desktop = root.appending(path: "claude-code-sessions")
        let config = root.appending(path: "config")
        let project = root.appending(path: "project")
        let repo = root.appending(path: "repo")
        let worktree = repo.appending(path: ".claude/worktrees/brave-otter")
        try writeSession(desktop, sessionFile(id: Self.ids[0], cwd: project, origin: project, title: "Newest",
            model: "claude-opus-5-5", effort: "xhigh", permission: "bypassPermissions", activity: 3_000))
        try writeSession(desktop, sessionFile(id: Self.ids[1], cwd: worktree, origin: repo, title: "In a worktree",
            model: "claude-fable-5", effort: "high", permission: "default", activity: 2_000,
            extra: ["branch": .string("claude/brave-otter")]))
        try writeSession(desktop, sessionFile(id: Self.ids[2], cwd: project, origin: project, title: "Archived",
            archived: true, activity: 4_000))
        try writeSession(desktop, sessionFile(id: Self.ids[3], cwd: project, origin: project, title: "No transcript",
            activity: 5_000))
        try writeSession(desktop, sessionFile(id: Self.ids[4], cwd: project, origin: project, title: nil,
            activity: 1_000))
        // The same session under a second account folder is listed once.
        try writeSession(desktop, sessionFile(id: Self.ids[0], cwd: project, origin: project, title: "Newest",
            activity: 3_000), account: "account-2")
        try Data("{}".utf8).write(to: desktop.appending(path: "org-1/account-1/scheduled-tasks.json"))
        try transcript(config, project, Self.ids[0], lines: [user("Polish the importer", id: Self.ids[0])])
        try transcript(config, worktree, Self.ids[1], lines: [user("Work in the worktree", id: Self.ids[1])])
        try transcript(config, project, Self.ids[2], lines: [user("Old", id: Self.ids[2])])
        try transcript(config, project, Self.ids[4], lines: [user("Untitled in the app", id: Self.ids[4])])
        try hold(Self.ids[1], in: config)

        let found = ClaudeDesktopSessionCatalog.conversations(root: desktop, configDirectory: config)
        XCTAssertEqual(found.map(\.providerSessionID), [Self.ids[0], Self.ids[1], Self.ids[4]])
        XCTAssertEqual(found.map(\.title), ["Newest", "In a worktree", "Untitled in the app"],
                       "A session the app left untitled is named from its transcript")
        XCTAssertEqual(found.map(\.isOpenElsewhere), [false, true, false])
        XCTAssertEqual(found.map(\.updatedAt), [3, 2, 1].map { Date(timeIntervalSince1970: $0) })
        XCTAssertTrue(found.allSatisfy { $0.harness == .claudeCode })
        XCTAssertEqual(found[0].providerOptions, [ClaudeLaunchOption.model: "claude-opus-5-5",
            ClaudeLaunchOption.effort: "xhigh", ClaudeLaunchOption.permissionMode: "bypassPermissions"])
        XCTAssertEqual(found[1].providerOptions, [ClaudeLaunchOption.model: "claude-fable-5",
            ClaudeLaunchOption.effort: "high", ClaudeLaunchOption.permissionMode: ClaudePermissionMode.manual],
            "Claude's default permission mode is Yardlet's Manual")
        XCTAssertEqual(path(found[1].workspaceURL), path(worktree))
        XCTAssertEqual(found[1].workspaceOrigin, WorkspaceGitOrigin(
            originWorkspacePath: ProjectSidebarPresentation.normalizedPath(for: repo),
            worktreeName: "brave-otter", branch: "claude/brave-otter"))
        XCTAssertNil(found[0].workspaceOrigin)
        XCTAssertTrue(found[2].providerOptions.isEmpty)

        XCTAssertTrue(ClaudeDesktopSessionCatalog.conversations(root: root.appending(path: "missing"),
                                                                configDirectory: config).isEmpty)
    }

    /// Opt-in: `NHC_OTHER_APP_IMPORT_LIVE=1` reads the Claude app's real session files against
    /// `~/.claude` and prints only counts. Nothing is written.
    func testLiveClaudeAppSessionsAreListed() throws {
        guard ProcessInfo.processInfo.environment["NHC_OTHER_APP_IMPORT_LIVE"] == "1" else {
            throw XCTSkip("Set NHC_OTHER_APP_IMPORT_LIVE=1")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = ClaudeDesktopSessionCatalog.defaultRoot()
        let all = ClaudeDesktopSessionCatalog.sessions(in: root)
        let found = ClaudeDesktopSessionCatalog.conversations(root: root, configDirectory: home.appending(path: ".claude"))
        let places = found.map { conversation -> String in
            switch ConversationImportPlacement.of(conversation) {
            case .chat: "chat"
            case .project: conversation.workspaceOrigin == nil ? "project" : "worktree"
            }
        }
        print("claude-app sessions", all.count, "open", all.filter { !$0.isArchived }.count,
              "listed", found.count, "held elsewhere", found.filter(\.isOpenElsewhere).count,
              "placement", Dictionary(grouping: places, by: { $0 }).mapValues(\.count),
              "options", Set(found.flatMap(\.providerOptions.keys)).sorted(),
              "permission modes", Set(found.compactMap { $0.providerOptions[ClaudeLaunchOption.permissionMode] }).sorted())
        XCTAssertFalse(found.isEmpty)
    }

    /// A Claude process Yardlet started holds nothing "elsewhere": only another app's process does.
    func testYardletsOwnProcessDoesNotHoldAConversationElsewhere() throws {
        let config = root.appending(path: "config")
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        try FileManager.default.createDirectory(at: config.appending(path: "sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(child.processIdentifier)),
                                                   "sessionId": .string(Self.ids[0])]))
            .write(to: config.appending(path: "sessions/\(child.processIdentifier).json"))

        XCTAssertTrue(ClaudeConversationCatalog.isDescendant(child.processIdentifier, of: getpid()))
        XCTAssertFalse(ClaudeConversationCatalog.isDescendant(getpid(), of: getpid()))
        XCTAssertEqual(ClaudeConversationCatalog.runningSessionIDs(configDirectory: config), [])
        XCTAssertEqual(ClaudeConversationCatalog.runningSessionIDs(configDirectory: config, excludingProcessesOf: 999_999),
                       [Self.ids[0]], "Another app's process with the same registration holds it")
    }

    // MARK: - Codex threads

    /// Codex's list is every folder's threads a person started, from the default Codex login: one
    /// `thread/list` without a folder, asking for the interactive source kinds. A thread the answer
    /// still marks as an `exec` run, a subagent or ephemeral is left out too. Nothing loads.
    func testCodexListsEveryFoldersThreadsAPersonStartedWithoutExecRunsOrSubagents() async throws {
        let fixture = try makeFixture()
        let chat = Self.chatFolder("Codex")
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([
                thread("t-app", "From the Codex app", in: fixture.project, source: .string("vscode")),
                thread("t-cli", "From the CLI", in: fixture.project, source: .string("cli")),
                thread("t-chat", "A chat", in: chat, source: .string("vscode")),
                thread("t-exec", "An automation run", in: fixture.project, source: .string("exec")),
                thread("t-sub", "A subagent", in: fixture.project,
                       source: .object(["subAgent": .object(["thread_spawn": .object(["depth": .integer(1),
                           "parent_thread_id": .string("t-app")])])]), parent: "t-app"),
                thread("t-orphan", "A child without its source", in: fixture.project, source: .string("vscode"),
                       parent: "t-app"),
                thread("t-eph", "Ephemeral", in: fixture.project, source: .string("appServer"), ephemeral: true)
            ]),
            "nextCursor": .string("page-2")]))
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-old", "An older one", in: root.appending(path: "elsewhere"), source: .string("cli"))]),
            "nextCursor": .null]))

        let listed = await fixture.model.otherAppConversations(claudeConnection: fixture.claudeAccount)
        XCTAssertNil(listed.codexError)
        XCTAssertEqual(listed.codex.map(\.providerSessionID), ["t-app", "t-cli", "t-chat", "t-old"])
        XCTAssertTrue(listed.codex.allSatisfy { $0.harness == .codex && !$0.isOpenElsewhere && $0.providerOptions.isEmpty })

        let lists = await fixture.codex.requests.filter { $0.method == "thread/list" }
        XCTAssertEqual(lists.count, 2)
        for request in lists {
            XCTAssertNil(request.params["cwd"], "Every folder's threads")
            XCTAssertEqual(request.params["sourceKinds"], .array([.string("cli"), .string("vscode"), .string("appServer"), .string("cloud")]))
            XCTAssertEqual(request.params["archived"], .bool(false))
        }
        XCTAssertNil(lists[0].params["cursor"])
        XCTAssertEqual(lists[1].params["cursor"]?.stringValue, "page-2")
        let methods = await fixture.codex.requestMethods
        XCTAssertFalse(methods.contains { ["thread/start", "thread/resume", "thread/read", "turn/start"].contains($0) })
        XCTAssertTrue(fixture.model.store.sessions.isEmpty)
    }

    // MARK: - Placement

    /// Chats go to no project, a Claude worktree to its repository's project, anything else to its
    /// folder's. The task's folder stays the conversation's own.
    func testPlacementSendsChatsToNoProjectWorktreesToTheirRepositoryAndOthersToTheirFolder() {
        let home = URL(filePath: "/Users/someone")
        func conversation(_ path: String, origin: String? = nil) -> ImportableConversation {
            var value = ImportableConversation(harness: .claudeCode, providerSessionID: Self.ids[0], title: "x",
                workspaceURL: URL(filePath: path), updatedAt: Date(), isOpenElsewhere: false)
            value.workspaceOrigin = origin.map { WorkspaceGitOrigin(originWorkspacePath: $0, worktreeName: "w") }
            return value
        }
        XCTAssertEqual(ConversationImportPlacement.of(conversation("/Users/someone/Documents/Codex/2026-10-12/plan"),
                                                      home: home), .chat)
        XCTAssertEqual(ConversationImportPlacement.of(conversation(
            "/Users/someone/Library/Application Support/Claude/scratch-workspaces/abc"), home: home), .chat)
        XCTAssertEqual(ConversationImportPlacement.of(conversation("/Users/someone/w/app/.claude/worktrees/w",
                                                                   origin: "/Users/someone/w/app"), home: home),
                       .project(root: URL(filePath: "/Users/someone/w/app", directoryHint: .isDirectory)))
        XCTAssertEqual(ConversationImportPlacement.of(conversation("/Users/someone/w/app"), home: home),
                       .project(root: URL(filePath: "/Users/someone/w/app")))
        XCTAssertEqual(ConversationImportPlacement.of(conversation("/Users/someone/Documents/Codex"), home: home),
                       .project(root: URL(filePath: "/Users/someone/Documents/Codex")),
                       "The chats folder itself is not a chat")
    }

    /// A conversation in a folder inside a project's folder, or inside another imported
    /// conversation's, joins that project; the nearest one wins, and the home folder never counts.
    func testAConversationInAFolderInsideAProjectsFolderJoinsThatProject() {
        let home = URL(filePath: "/Users/someone")
        func placement(_ path: String, roots: [String]) -> ConversationImportPlacement {
            ConversationImportPlacement.of(
                ImportableConversation(harness: .codex, providerSessionID: Self.ids[0], title: "x",
                                       workspaceURL: URL(filePath: path), updatedAt: Date(), isOpenElsewhere: false),
                home: home, projectRoots: roots.map { URL(filePath: $0) })
        }
        let workspace = "/Users/someone/w/rental"
        XCTAssertEqual(placement("/Users/someone/w/rental/backend", roots: [workspace]),
                       .project(root: URL(filePath: workspace)))
        XCTAssertEqual(placement("/Users/someone/w/rental/backend/api", roots: [workspace, workspace + "/backend"]),
                       .project(root: URL(filePath: workspace + "/backend")), "The nearest enclosing folder wins")
        XCTAssertEqual(placement(workspace, roots: [workspace]), .project(root: URL(filePath: workspace)))
        XCTAssertEqual(placement("/Users/someone/w/rentals", roots: [workspace]),
                       .project(root: URL(filePath: "/Users/someone/w/rentals")), "A sibling with a longer name is not inside")
        XCTAssertEqual(placement("/Users/someone/w/shop", roots: ["/Users/someone", "/Users"]),
                       .project(root: URL(filePath: "/Users/someone/w/shop")), "The home folder takes in nothing")
    }

    /// A conversation in a worktree another app made (the Codex app's `~/.codex/worktrees`) is given
    /// its repository as origin from Git's own files, so it goes with that repository's project.
    func testAConversationInAnotherAppsWorktreeGoesWithItsRepository() {
        let reader = GitMetadataReader(
            kind: { $0 == "/Users/someone/.codex/worktrees/a539/brain/.git" ? .file : nil },
            text: { path in
                switch path {
                case "/Users/someone/.codex/worktrees/a539/brain/.git":
                    "gitdir: /Users/someone/w/brain/.git/worktrees/brain\n"
                case "/Users/someone/w/brain/.git/worktrees/brain/commondir": "../..\n"
                case "/Users/someone/w/brain/.git/worktrees/brain/HEAD": "ref: refs/heads/fix\n"
                default: nil
                }
            })
        var listed = OtherAppConversations()
        listed.codex = [ImportableConversation(harness: .codex, providerSessionID: Self.ids[0], title: "x",
            workspaceURL: URL(filePath: "/Users/someone/.codex/worktrees/a539/brain"), updatedAt: Date(),
            isOpenElsewhere: false)]
        listed.claude = [ImportableConversation(harness: .claudeCode, providerSessionID: Self.ids[1], title: "y",
            workspaceURL: URL(filePath: "/Users/someone/w/plain"), updatedAt: Date(), isOpenElsewhere: false)]
        let resolved = listed.resolvingWorktreeOrigins(reader: reader)
        XCTAssertEqual(resolved.codex[0].workspaceOrigin?.originWorkspacePath, "/Users/someone/w/brain")
        XCTAssertEqual(resolved.codex[0].workspaceOrigin?.branch, "fix")
        XCTAssertEqual(ConversationImportPlacement.of(resolved.codex[0], home: URL(filePath: "/Users/someone")),
                       .project(root: URL(filePath: "/Users/someone/w/brain", directoryHint: .isDirectory)))
        XCTAssertNil(resolved.claude[0].workspaceOrigin, "A folder that is no worktree keeps no origin")
    }

    /// Importing a mixed list places each conversation (a chat makes no project, a worktree joins
    /// its repository's project and keeps its origin even when the folder is gone, any other gets
    /// its folder's project), carries the title, settings and account over, keeps the other app's
    /// last activity, opens nothing, and adds no second task for one already imported.
    func testBulkImportPlacesEachConversationAndAddsNoSecondTask() async throws {
        let fixture = try makeFixture()
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let existing = fixture.model.projects.ensureProject(forRoot: repo, name: "Repository")
        let worktree = repo.appending(path: ".claude/worktrees/gone-otter")
        let claudeChat = Self.chatFolder("Claude")
        let codexChat = Self.chatFolder("Codex")
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[0], cwd: fixture.project, origin: fixture.project,
            title: "Plain project", model: "claude-opus-5-5", effort: "xhigh", permission: "bypassPermissions",
            activity: 1_791_000_000_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[1], cwd: worktree, origin: repo, title: "Worktree",
            model: "claude-fable-5", effort: "high", permission: "default", activity: 1_791_000_100_000,
            extra: ["branch": .string("claude/gone-otter")]))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[2], cwd: claudeChat, origin: claudeChat,
            title: "Claude chat", activity: 1_791_000_200_000))
        for (id, folder) in [(Self.ids[0], fixture.project), (Self.ids[1], worktree), (Self.ids[2], claudeChat)] {
            try transcript(fixture.config, folder, id, lines: [user("Hello", id: id)])
        }
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-plain", "Codex in the project", in: fixture.project, source: .string("vscode")),
                            thread("t-chat", "Codex chat", in: codexChat, source: .string("vscode"))]),
            "nextCursor": .null]))
        let projectsBefore = fixture.model.projects.projects.count
        let selectedBefore = fixture.model.store.selectedSessionID

        let listed = await fixture.model.otherAppConversations(claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(listed.all.count, 5)
        XCTAssertEqual(Set(listed.all.map { fixture.model.importDestination(for: $0).name }),
                       ["Repository", fixture.project.lastPathComponent, L10n.string("Chats")])
        var reported: [String] = []
        let failures = await fixture.model.importConversations(listed.all, claudeConnection: fixture.claudeAccount) {
            reported.append($0.id)
        }
        XCTAssertEqual(failures, [:])
        XCTAssertEqual(reported, listed.all.map(\.id))
        let sessions = fixture.model.store.sessions
        XCTAssertEqual(sessions.count, 5)
        XCTAssertEqual(fixture.model.store.selectedSessionID, selectedBefore, "A bulk import opens nothing")
        func task(_ id: String) throws -> SessionRecord { try XCTUnwrap(sessions.first { $0.providerSessionID == id }) }

        let plain = try task(Self.ids[0])
        let plainProject = try XCTUnwrap(fixture.model.projects.project(containingRoot: fixture.project))
        XCTAssertEqual(plain.projectID, plainProject.id)
        XCTAssertEqual(plain.title, "Plain project")
        XCTAssertEqual(plain.titleOrigin, .provider)
        XCTAssertEqual(plain.connection, fixture.claudeAccount)
        XCTAssertEqual(plain.environmentScope, .native)
        XCTAssertEqual(plain.providerOptions, [ClaudeLaunchOption.model: "claude-opus-5-5",
            ClaudeLaunchOption.effort: "xhigh", ClaudeLaunchOption.permissionMode: "bypassPermissions"])
        XCTAssertEqual(plain.updatedAt, Date(timeIntervalSince1970: 1_791_000_000), "The other app's last activity")

        let inWorktree = try task(Self.ids[1])
        XCTAssertEqual(inWorktree.projectID, existing.id, "A worktree joins its repository's project")
        XCTAssertEqual(path(inWorktree.workspaceURL), path(worktree), "and still runs in the worktree")
        XCTAssertEqual(inWorktree.originWorkspacePath, ProjectSidebarPresentation.normalizedPath(for: repo))
        XCTAssertEqual(inWorktree.worktreeName, "gone-otter")
        XCTAssertEqual(inWorktree.branch, "claude/gone-otter")
        XCTAssertEqual(inWorktree.providerOptions[ClaudeLaunchOption.permissionMode], ClaudePermissionMode.manual)
        XCTAssertNil(fixture.model.projects.project(containingRoot: worktree))

        let claudeChatTask = try task(Self.ids[2])
        XCTAssertNil(claudeChatTask.projectID, "A chat belongs to no project")
        XCTAssertTrue(claudeChatTask.additionalRoots.isEmpty)
        XCTAssertNil(fixture.model.projects.project(containingRoot: claudeChat))

        let codexPlain = try task("t-plain")
        XCTAssertEqual(codexPlain.projectID, plainProject.id)
        XCTAssertNil(codexPlain.connection, "Codex tasks use the default Codex login")
        XCTAssertTrue(codexPlain.providerOptions.isEmpty, "The thread keeps its own model")
        XCTAssertEqual(codexPlain.titleOrigin, .provider)
        let codexChatTask = try task("t-chat")
        XCTAssertNil(codexChatTask.projectID)
        XCTAssertNil(fixture.model.projects.project(containingRoot: codexChat))
        XCTAssertEqual(fixture.model.projects.projects.count, projectsBefore + 1, "Only the plain folder became a project")

        XCTAssertTrue(sessions.allSatisfy { !fixture.model.isAttached($0.id) })
        let resumed = await fixture.claude.calls
        XCTAssertEqual(resumed, [], "Importing starts no Claude process")
        let methods = await fixture.codex.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/list"], "Importing sends Codex nothing after the list")

        // Importing the same list again adds nothing.
        let again = await fixture.model.importConversations(listed.all, claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(again, [:])
        XCTAssertEqual(fixture.model.store.sessions.count, 5)
        XCTAssertTrue(listed.all.allSatisfy {
            fixture.model.existingTask(for: $0, connection: $0.harness == .claudeCode ? fixture.claudeAccount : nil) != nil
        })
    }

    /// A conversation that cannot be imported says why on its own; the rest still come in.
    func testABulkImportReportsEachFailureAndKeepsTheOthers() async throws {
        let fixture = try makeFixture()
        let claude = ImportableConversation(harness: .claudeCode, providerSessionID: Self.ids[0], title: "Fine",
            workspaceURL: fixture.project, updatedAt: Date(), isOpenElsewhere: false)
        let other = ImportableConversation(harness: .openCode, providerSessionID: "oc-1", title: "No runtime",
            workspaceURL: fixture.project, updatedAt: Date(), isOpenElsewhere: false)
        let failures = await fixture.model.importConversations([other, claude], claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(failures, [other.id: L10n.format("%@ is not installed.", HarnessKind.openCode.displayName)])
        XCTAssertEqual(fixture.model.store.sessions.map(\.providerSessionID), [Self.ids[0]])
    }

    /// After a relaunch, a task a project already shows (here a worktree under its repository's
    /// project) and a chat get no project for their own folder; a task from before projects still does.
    func testRelaunchMakesNoProjectForAChatOrAWorktreeTask() throws {
        let repo = root.appending(path: "repo")
        let owner = Project(name: "Repository", primaryRoot: repo)
        let worktree = repo.appending(path: ".claude/worktrees/w")
        let runtime = URL(filePath: "/usr/bin/true")
        let sessions = [
            SessionRecord(harness: .claudeCode, workspaceURL: worktree, runtimeExecutableURL: runtime, title: "Worktree",
                          projectID: owner.id, originWorkspacePath: repo.path),
            SessionRecord(harness: .codex, workspaceURL: Self.chatFolder("Codex"), runtimeExecutableURL: runtime,
                          title: "Chat"),
            SessionRecord(harness: .codex, workspaceURL: root.appending(path: "legacy"), runtimeExecutableURL: runtime,
                          title: "From before projects")
        ]
        let model = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in ClaudeRecorder() },
            projectRepository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: [owner])),
            restoresIndexOnLaunch: false)
        XCTAssertEqual(model.projects.projects.map(\.name), ["Repository", "legacy"])
        XCTAssertNil(model.projects.project(containingRoot: worktree))
    }

    // MARK: - Detached import

    /// An imported task starts nothing; opening it reads the provider's own history the way a task
    /// restored after relaunch does: Claude's transcript, Codex's thread with `thread/read`. Importing
    /// one conversation opens its task, and choosing a task starts that read (NATIVE_SESSION_STORAGE,
    /// 2026-10-18), so the checks wait for the read rather than for the import alone.
    func testImportStartsNoRuntimeAndOpeningShowsTheHistory() async throws {
        let fixture = try makeFixture()
        try transcript(fixture.config, fixture.project, Self.ids[0], lines: [
            user("Read the importer", id: Self.ids[0], uuid: "u1"),
            assistant("The importer reads each session file.", id: Self.ids[0], uuid: "a1", parent: "u1")])
        let claudeConversation = ImportableConversation(harness: .claudeCode, providerSessionID: Self.ids[0],
            title: "Read the importer", workspaceURL: fixture.project, updatedAt: Date(), isOpenElsewhere: false)
        let claudeTask = try unwrap(await fixture.model.importConversation(claudeConversation,
                                                                             connection: fixture.claudeAccount))
        XCTAssertFalse(fixture.model.isAttached(claudeTask.id))
        let claudeRead = await eventually { !fixture.model.isReadingSavedConversation(claudeTask.id) }
        XCTAssertTrue(claudeRead)

        await fixture.model.refreshConversationStatus(for: claudeTask)
        let entries = fixture.model.transcriptBySessionID[claudeTask.id] ?? []
        XCTAssertTrue(entries.contains { $0.content == .user(text: "Read the importer", images: nil) })
        XCTAssertTrue(entries.contains {
            if case let .assistant(text, _) = $0.content { text == "The importer reads each session file." } else { false }
        })
        let claudeCalls = await fixture.claude.calls
        XCTAssertEqual(claudeCalls, [], "Reading started no Claude process")

        let saved = savedThread("t-1", turns: 1)
        await fixture.codex.enqueue(method: "thread/read", result: CodexSavedThreadResponses.metadata(saved))
        await fixture.codex.enqueue(method: "thread/turns/list", result: CodexSavedThreadResponses.page(saved))
        let codexConversation = ImportableConversation(codex: CodexThreadSummary(id: "t-1", title: "Fix the list",
            preview: "", workspaceURL: fixture.project, updatedAt: Date(), forkedFromID: nil))
        let codexTask = try unwrap(await fixture.model.importConversation(codexConversation, connection: nil))
        let codexRead = await eventually { !fixture.model.isReadingSavedConversation(codexTask.id) }
        XCTAssertTrue(codexRead)
        let methods = await fixture.codex.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/read", "thread/turns/list"],
                       "Opening the imported thread reads it: nothing resumed, no turn")
        XCTAssertFalse(fixture.model.isAttached(codexTask.id))
        XCTAssertEqual(fixture.model.codexPresentationBySessionID[codexTask.id]?.thread?.turns.map(\.id), ["turn-1"])
    }

    // MARK: - Held elsewhere

    /// Another app's process holds the conversation: sending is refused with a notice in the task,
    /// the message stays in the composer, nothing starts and the task does not fail. Once that
    /// process is gone, sending attaches as for any detached task.
    func testSendingAConversationHeldElsewhereIsRefusedAndKeepsTheDraft() async throws {
        let fixture = try makeFixture()
        try transcript(fixture.config, fixture.project, Self.ids[0], lines: [user("Still open", id: Self.ids[0])])
        let holder = try hold(Self.ids[0], in: fixture.config)
        let conversation = try XCTUnwrap(ClaudeConversationCatalog.conversations(in: fixture.project,
            configDirectory: fixture.config).first)
        XCTAssertTrue(conversation.isOpenElsewhere)
        let task = try unwrap(await fixture.model.importConversation(conversation, connection: fixture.claudeAccount))
        XCTAssertTrue(fixture.model.isHeldElsewhere(task))
        let notice = L10n.string("This conversation is still open in the Claude app. It continues here once you close it there.")

        // The composer clears its draft before it sends; the refusal puts the message back.
        let draft = fixture.model.composerDrafts.tasks.draft(for: task.id)
        await fixture.model.send(HarnessUserInput(text: "Keep going"), to: task)
        XCTAssertEqual(draft.text, "Keep going")
        XCTAssertEqual(draft.notice, notice)
        // A draft the person kept typing is left as it is.
        draft.text = "Keep going, and test it"
        await fixture.model.send(HarnessUserInput(text: "Keep going"), to: task)
        XCTAssertEqual(draft.text, "Keep going, and test it")
        XCTAssertEqual(draft.notice, notice)

        draft.notice = nil
        await fixture.model.resume(task)
        XCTAssertEqual(draft.notice, notice)
        await fixture.model.loadProviderCapabilities(for: task)
        XCTAssertEqual(fixture.model.providerCapabilitiesBySessionID[task.id]?.errors.first, notice,
                       "Reading the settings would attach, so it is refused the same way")

        let refused = await fixture.claude.calls
        XCTAssertEqual(refused, [])
        XCTAssertFalse(fixture.model.isAttached(task.id))
        let current = try XCTUnwrap(fixture.model.store.sessions.first { $0.id == task.id })
        XCTAssertEqual(current.status, .ready)
        XCTAssertNil(fixture.model.errorBySessionID[task.id])
        XCTAssertFalse((fixture.model.transcriptBySessionID[task.id] ?? []).contains {
            $0.content == .user(text: "Keep going", images: nil)
        }, "Nothing was sent")

        try FileManager.default.removeItem(at: holder)
        XCTAssertFalse(fixture.model.isHeldElsewhere(task))
        await fixture.model.send(HarnessUserInput(text: "Keep going"), to: task)
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, ["resume \(Self.ids[0])", "send Keep going"])
    }

    /// While shown and held elsewhere, a Claude task follows the other app's writes to its
    /// transcript: each change is read again, nothing is sent and no process starts.
    func testAConversationHeldElsewhereIsFollowedReadOnly() async throws {
        let fixture = try makeFixture()
        let file = try transcript(fixture.config, fixture.project, Self.ids[0], lines: [
            user("Start the import", id: Self.ids[0], uuid: "u1")])
        try hold(Self.ids[0], in: fixture.config)
        let conversation = try XCTUnwrap(ClaudeConversationCatalog.conversations(in: fixture.project,
            configDirectory: fixture.config).first)
        let task = try unwrap(await fixture.model.importConversation(conversation, connection: fixture.claudeAccount))
        fixture.model.detachedFollowInterval = .milliseconds(40)
        await fixture.model.refreshConversationStatus(for: task)
        let follow = Task { await fixture.model.followDetachedConversation(for: task) }
        defer { follow.cancel() }
        try await Task.sleep(for: .milliseconds(150))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(JSONValue.object(
            assistant("Imported the first session.", id: Self.ids[0], uuid: "a1", parent: "u1"))) + Data([10]))
        try handle.close()

        let followed = await eventually {
            (fixture.model.transcriptBySessionID[task.id] ?? []).contains {
                if case let .assistant(text, _) = $0.content { text == "Imported the first session." } else { false }
            }
        }
        XCTAssertTrue(followed, "The other app's new answer shows up")
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, [])
        XCTAssertFalse(fixture.model.isAttached(task.id))
    }

    /// A shown detached Codex task reads its newest turns again when its rollout file changes, and
    /// only those (`thread/turns/list`'s first page), merged into the turns it shows. Codex has no
    /// registry of another app's loaded threads, so this is the only signal; sending is not guarded.
    func testADetachedCodexTaskFollowsItsRolloutReadOnly() async throws {
        let fixture = try makeFixture()
        let rollout = root.appending(path: "rollout-t-1.jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        await fixture.codex.enqueue(method: "thread/read", result: CodexSavedThreadResponses.metadata(
            savedThread("t-1", turns: 1, path: rollout.path)))
        await fixture.codex.enqueue(method: "thread/turns/list", result: CodexSavedThreadResponses.page(
            savedThread("t-1", turns: 1)))
        await fixture.codex.enqueue(method: "thread/turns/list", result: CodexSavedThreadResponses.page(
            savedThread("t-1", turns: 2)))
        let task = try unwrap(await fixture.model.importConversation(ImportableConversation(codex: CodexThreadSummary(
            id: "t-1", title: "Fix the list", preview: "", workspaceURL: fixture.project, updatedAt: Date(),
            forkedFromID: nil)), connection: nil))
        fixture.model.detachedFollowInterval = .milliseconds(40)
        // Importing opened the task, which reads it; a second read now would take the page kept
        // for the change below.
        let opened = await eventually { !fixture.model.isReadingSavedConversation(task.id) }
        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.codexPresentationBySessionID[task.id]?.thread?.turns.count, 1)
        let follow = Task { await fixture.model.followDetachedConversation(for: task) }
        defer { follow.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let unchanged = await fixture.codex.requestMethods
        XCTAssertEqual(unchanged, ["initialize", "thread/read", "thread/turns/list"],
                       "An unchanged rollout is not read again")

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\"}\n".utf8))
        try handle.close()
        let followed = await eventually { fixture.model.codexPresentationBySessionID[task.id]?.thread?.turns.count == 2 }
        XCTAssertTrue(followed)
        let methods = await fixture.codex.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/read", "thread/turns/list", "thread/turns/list"],
                       "a change reads the newest page, not the thread again")
        let newestPage = await fixture.codex.requests.last
        XCTAssertNil(newestPage?.params["cursor"])
        XCTAssertEqual(newestPage?.params["limit"], .integer(CodexThreadPaging.newestTurns))
        XCTAssertFalse(fixture.model.isAttached(task.id))
    }

    // MARK: - Sheet

    /// The sheet drawn without a window into `.build/other-app-import-qa/`, light and dark: projects
    /// then Chats, each row with its harness, folder and time; one already in Yardlet, one still
    /// open in the Claude app.
    func testWindowlessOtherAppImportSheetRenders() async throws {
        let directory = try WindowlessRender.directory("other-app-import-qa")
        let fixture = try makeFixture()
        let model = fixture.model
        model.connections.usesFixtureSnapshots = true
        try model.connections.save(fixture.claudeAccount)
        model.connections.selection[.claudeCode] = fixture.claudeAccount.id
        let now = Date()
        let ms = { (seconds: TimeInterval) in JSONValue.integer(Int64((now.timeIntervalSince1970 - seconds) * 1_000)) }
        let repo = root.appending(path: "yardlet")
        let worktree = repo.appending(path: ".claude/worktrees/brave-otter")
        let chat = Self.chatFolder("Claude")
        let rows: [(String, URL, URL, String, TimeInterval)] = [
            (Self.ids[0], fixture.project, fixture.project, "Polish the import sheet", 600),
            (Self.ids[1], worktree, repo, "Follow a conversation another app holds", 3_600),
            (Self.ids[2], chat, chat, "Plan the weekend trip", 86_400)
        ]
        for (id, cwd, origin, title, age) in rows {
            var file = sessionFile(id: id, cwd: cwd, origin: origin, title: title, model: "claude-opus-5-5",
                                   effort: "xhigh", permission: "auto")
            var value = try JSONDecoder().decode([String: JSONValue].self, from: file)
            value["lastActivityAt"] = ms(age)
            file = try JSONEncoder().encode(JSONValue.object(value))
            try writeSession(fixture.desktop, file)
            try transcript(fixture.config, cwd, id, lines: [user(title, id: id)])
        }
        try hold(Self.ids[1], in: fixture.config)
        let threads: JSONValue = .object([
            "data": .array([
                thread("t-1", "Codex in the same project", in: fixture.project, source: .string("vscode"),
                       updatedAt: now.addingTimeInterval(-1_800)),
                thread("t-2", "Draft the release notes", in: Self.chatFolder("Codex"), source: .string("vscode"),
                       updatedAt: now.addingTimeInterval(-7_200))]),
            "nextCursor": .null])
        for _ in 0..<3 { await fixture.codex.enqueue(method: "thread/list", result: threads) }
        _ = await model.importConversation(ImportableConversation(codex: CodexThreadSummary(id: "t-1",
            title: "Codex in the same project", preview: "", workspaceURL: fixture.project, updatedAt: now,
            forkedFromID: nil)), connection: nil)
        XCTAssertEqual(model.store.sessions.count, 1)

        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(OtherAppImportSheet(model: model, onDismiss: {})
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 720, height: 600), appearance: appearance)
            defer { host.close() }
            let deadline = ContinuousClock.now + .seconds(20)
            var listed = false
            while !listed, ContinuousClock.now < deadline {
                host.settle(passes: 2)
                try await Task.sleep(for: .milliseconds(50))
                listed = host.accessibilityElements().contains { $0.label.contains("Draft the release notes") }
            }
            XCTAssertTrue(listed, "the list arrives")
            host.settle(passes: 6)
            let labels = host.accessibilityElements().map(\.label)
            let followRow = labels.first { $0.contains("Follow a conversation another app holds") } ?? ""
            XCTAssertTrue(followRow.contains(L10n.string("Open in another app")), followRow)
            let importedRow = labels.first { $0.contains("Codex in the same project") } ?? ""
            XCTAssertTrue(importedRow.contains(L10n.string("Already in Yardlet")), importedRow)
            XCTAssertTrue(labels.contains { $0 == L10n.string("Chats") }, "Chats is a group")
            XCTAssertTrue(labels.contains { $0 == "yardlet" }, "A worktree is listed under its repository")
            let capture = try host.capture()
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "sheet-\(appearance.suffix).png"))
        }
        XCTAssertEqual(model.store.sessions.count, 1, "Drawing the sheet imported nothing")
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Sessions started from another session

    /// The Claude app records which session started which only in its own session files: the child's
    /// `spawnedFrom.sessionId` (the app's `local_` ID of the parent), else `forkedFromSessionId`;
    /// `lineageDetached` once the person moved it to top level. `spawnSeed` and
    /// `lastSpawnRootDetected` are about relaunching the CLI, not about links.
    func testSessionFilesSayWhichSessionStartedWhich() throws {
        let desktop = root.appending(path: "claude-code-sessions")
        let workspace = root.appending(path: "project")
        func file(_ index: Int, extra: [String: JSONValue] = [:]) throws {
            var fields = extra
            fields["sessionId"] = .string("local_\(Self.ids[index])")
            fields["spawnSeed"] = .object(["worktreeHookBased": .bool(false)])
            fields["lastSpawnRootDetected"] = .bool(false)
            try writeSession(desktop, sessionFile(id: Self.ids[index], cwd: workspace, origin: workspace,
                                                  title: "Session \(index)", extra: fields))
        }
        try file(0)
        try file(1, extra: ["spawnedFrom": .object(["sessionId": .string("local_\(Self.ids[0])"),
                                                    "taskId": .string("task_0f1e2d3c"), "title": .string("Session 0")]),
                            "spawnedFromEndNotified": .bool(true)])
        try file(2, extra: ["spawnedFrom": .object(["sessionId": .string("local_\(Self.ids[1])"), "taskId": .string("task_1"),
                                                    "title": .string("Session 1"), "name": .string("cs-check"),
                                                    "sideSession": .bool(true), "sharedFolder": .bool(true)])])
        try file(3, extra: ["spawnedFrom": .object(["sessionId": .string("local_\(Self.ids[0])"), "taskId": .string("task_2"),
                                                    "title": .string("Session 0")]),
                            "lineageDetached": .bool(true)])
        try file(4, extra: ["forkedFromSessionId": .string("local_\(Self.ids[0])"),
                            "forkedAtMessageUuid": .string(UUID().uuidString.lowercased())])
        try file(5, extra: ["spawnedFrom": .object(["sessionId": .string("local_gone"), "taskId": .string("task_3"),
                                                    "title": .string("Gone")])])
        let sessions = ClaudeDesktopSessionCatalog.sessions(in: desktop)
        XCTAssertEqual(sessions.count, 6)
        XCTAssertEqual(sessions.first { $0.cliSessionID == Self.ids[1] }?.desktopSessionID, "local_\(Self.ids[1])")
        XCTAssertEqual(ClaudeDesktopSessionCatalog.parentSessionIDs(of: sessions), [
            Self.ids[1]: Self.ids[0],
            Self.ids[2]: Self.ids[1],
            Self.ids[4]: Self.ids[0],
        ], "Detached (3) and a parent the files do not have (5) give no link")
    }

    /// Importing keeps the link when the parent is in Yardlet too, in whatever order the two come in;
    /// a session moved to top level and one whose parent stays in the other app are not linked. A
    /// forked Codex thread links to the task of the thread it was forked from.
    func testImportKeepsTheLinkWhenTheParentIsInYardletToo() async throws {
        let fixture = try makeFixture()
        func file(_ index: Int, archived: Bool = false, extra: [String: JSONValue] = [:]) throws {
            var fields = extra
            fields["sessionId"] = .string("local_\(Self.ids[index])")
            try writeSession(fixture.desktop, sessionFile(id: Self.ids[index], cwd: fixture.project, origin: fixture.project,
                title: "Session \(index)", archived: archived, activity: 1_791_000_000_000 + Int64(index) * 1_000, extra: fields))
            try transcript(fixture.config, fixture.project, Self.ids[index], lines: [user("Hello", id: Self.ids[index])])
        }
        func started(by index: Int) -> [String: JSONValue] {
            ["spawnedFrom": .object(["sessionId": .string("local_\(Self.ids[index])"), "taskId": .string("task_\(index)"),
                                     "title": .string("Session \(index)")])]
        }
        try file(0)
        try file(1, extra: started(by: 0))
        try file(2, extra: started(by: 1))
        try file(3, extra: started(by: 0).merging(["lineageDetached": .bool(true)]) { _, new in new })
        try file(4, archived: true)
        try file(5, extra: started(by: 4))
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-parent", "Codex parent", in: fixture.project, source: .string("vscode")),
                            forked(thread("t-fork", "Codex fork", in: fixture.project, source: .string("cli")), from: "t-parent")]),
            "nextCursor": .null]))
        let listed = await fixture.model.otherAppConversations(claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(listed.claude.first { $0.providerSessionID == Self.ids[2] }?.parentProviderSessionID, Self.ids[1])
        XCTAssertEqual(listed.claude.first { $0.providerSessionID == Self.ids[5] }?.parentProviderSessionID, Self.ids[4],
                       "The parent may be archived in the app")
        XCTAssertEqual(listed.codex.first { $0.providerSessionID == "t-fork" }?.parentProviderSessionID, "t-parent")

        // The grandchild first, then its parent; the root comes in a later import.
        let byID = Dictionary(uniqueKeysWithValues: listed.all.map { ($0.providerSessionID, $0) })
        let firstBatch = try [Self.ids[2], Self.ids[1], Self.ids[3], Self.ids[5], "t-fork", "t-parent"].map { try XCTUnwrap(byID[$0]) }
        let failures = await fixture.model.importConversations(firstBatch, claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(failures, [:])
        func task(_ id: String) -> SessionRecord? { fixture.model.store.sessions.first { $0.providerSessionID == id } }
        XCTAssertEqual(task(Self.ids[2])?.parentTaskID, task(Self.ids[1])?.id, "Linked though imported before its parent")
        XCTAssertNil(task(Self.ids[1])?.parentTaskID, "Its parent is not in Yardlet yet")
        XCTAssertNil(task(Self.ids[3])?.parentTaskID, "Moved to top level in the Claude app")
        XCTAssertNil(task(Self.ids[5])?.parentTaskID, "Its parent stayed in the Claude app")
        XCTAssertEqual(task("t-fork")?.parentTaskID, task("t-parent")?.id)

        let rootConversation = try XCTUnwrap(byID[Self.ids[0]])
        let rootTask = await fixture.model.importConversation(rootConversation, connection: fixture.claudeAccount)
        XCTAssertNotNil(rootTask)
        XCTAssertEqual(task(Self.ids[1])?.parentTaskID, rootTask?.id, "An earlier child links when its parent arrives")
        XCTAssertNil(task(Self.ids[3])?.parentTaskID)
        XCTAssertNil(rootTask?.parentTaskID)
        let resumed = await fixture.claude.calls
        XCTAssertEqual(resumed, [], "Linking starts no Claude process")
    }

    /// Tasks imported before links were kept are linked once from the Claude app's files, read only:
    /// running it again changes nothing, an existing link stays, the files and the transcripts are
    /// untouched, and the tasks keep their place. The launch-once read does not run twice.
    func testTasksImportedBeforeAreLinkedOnceFromTheClaudeAppsFiles() async throws {
        let fixture = try makeFixture()
        func file(_ index: Int, extra: [String: JSONValue] = [:]) throws {
            var fields = extra
            fields["sessionId"] = .string("local_\(Self.ids[index])")
            try writeSession(fixture.desktop, sessionFile(id: Self.ids[index], cwd: fixture.project, origin: fixture.project,
                                                          title: "Session \(index)", extra: fields))
        }
        func started(by index: Int) -> [String: JSONValue] {
            ["spawnedFrom": .object(["sessionId": .string("local_\(Self.ids[index])"), "taskId": .string("task_\(index)"),
                                     "title": .string("Session \(index)")])]
        }
        try file(0)
        try file(1, extra: started(by: 0))
        try file(2, extra: started(by: 0))
        try file(3, extra: started(by: 0))
        var tasks: [SessionRecord] = []
        for index in 0...3 {
            tasks.append(try await fixture.model.store.createSession(
                harness: .claudeCode, workspaceURL: fixture.project, runtimeExecutableURL: root.appending(path: "claude"),
                title: "Session \(index)", titleOrigin: .provider, providerSessionID: Self.ids[index],
                selectsSession: false, connection: fixture.claudeAccount,
                lastActivityAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(index)),
                parentTaskID: index == 3 ? tasks[2].id : nil))
        }
        let filesBefore = try desktopFiles(fixture.desktop)
        let recency = fixture.model.store.sessions.map(\.updatedAt)
        let suite = testDefaultsSuite("NativeHarnessClientTests.Lineage")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        await fixture.model.linkTasksStartedInTheClaudeAppOnce(defaults: defaults)
        func parent(_ index: Int) -> UUID? { fixture.model.store.sessions.first { $0.id == tasks[index].id }?.parentTaskID }
        XCTAssertEqual(parent(1), tasks[0].id)
        XCTAssertEqual(parent(2), tasks[0].id)
        XCTAssertEqual(parent(3), tasks[2].id, "A link already recorded stays")
        XCTAssertNil(parent(0))
        XCTAssertEqual(fixture.model.store.sessions.map(\.updatedAt), recency, "Linking is not activity")

        let linked = fixture.model.store.sessions
        await fixture.model.linkTasksStartedInTheClaudeApp()
        XCTAssertEqual(fixture.model.store.sessions, linked, "Reading again changes nothing")
        XCTAssertEqual(try desktopFiles(fixture.desktop), filesBefore, "The Claude app's files are only read")

        // The launch-once read is done: a link the files gain later waits for the next import.
        try FileManager.default.removeItem(at: fixture.desktop)
        try file(0, extra: started(by: 1))
        await fixture.model.linkTasksStartedInTheClaudeAppOnce(defaults: defaults)
        XCTAssertNil(parent(0))
        XCTAssertEqual(try desktopFiles(fixture.desktop).count, 1)
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, [], "No Claude process, no history touched")
    }

    /// A task the person detached to the top level in Yardlet stays there: the Claude app's files
    /// still say which session started it, but neither the read of those files nor a later import
    /// (which reads them again) links it, while a session imported after it still links. Only the
    /// index changes; no Claude process runs.
    func testATaskDetachedInYardletIsNotLinkedAgainByTheClaudeAppsFilesOrALaterImport() async throws {
        let fixture = try makeFixture()
        func file(_ index: Int, extra: [String: JSONValue] = [:]) throws {
            var fields = extra
            fields["sessionId"] = .string("local_\(Self.ids[index])")
            try writeSession(fixture.desktop, sessionFile(id: Self.ids[index], cwd: fixture.project, origin: fixture.project,
                title: "Session \(index)", activity: 1_791_000_000_000 + Int64(index) * 1_000, extra: fields))
            try transcript(fixture.config, fixture.project, Self.ids[index], lines: [user("Hello", id: Self.ids[index])])
        }
        let startedByFirst: [String: JSONValue] = ["spawnedFrom": .object([
            "sessionId": .string("local_\(Self.ids[0])"), "taskId": .string("task_0"), "title": .string("Session 0")])]
        try file(0)
        try file(1, extra: startedByFirst)
        try file(2, extra: startedByFirst)
        let listed = await fixture.model.otherAppConversations(claudeConnection: fixture.claudeAccount)
        let byID = Dictionary(uniqueKeysWithValues: listed.claude.map { ($0.providerSessionID, $0) })
        let first = try [Self.ids[0], Self.ids[1]].map { try XCTUnwrap(byID[$0]) }
        let failures = await fixture.model.importConversations(first, claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(failures, [:])
        func task(_ index: Int) -> SessionRecord? {
            fixture.model.store.sessions.first { $0.providerSessionID == Self.ids[index] }
        }
        let root = try XCTUnwrap(task(0))
        XCTAssertEqual(task(1)?.parentTaskID, root.id, "Nested under the session that started it")

        await fixture.model.detachFromParent(try XCTUnwrap(task(1)))
        XCTAssertNil(task(1)?.parentTaskID)
        XCTAssertEqual(task(1)?.isLineageDetached, true)

        await fixture.model.linkTasksStartedInTheClaudeApp()
        XCTAssertNil(task(1)?.parentTaskID, "The Claude app's files do not nest it again")

        let later = try XCTUnwrap(byID[Self.ids[2]])
        let laterFailures = await fixture.model.importConversations([later], claudeConnection: fixture.claudeAccount)
        XCTAssertEqual(laterFailures, [:])
        XCTAssertEqual(task(2)?.parentTaskID, root.id, "A session imported later still nests")
        XCTAssertNil(task(1)?.parentTaskID, "A later import does not nest the detached one again")
        XCTAssertEqual(task(1)?.isLineageDetached, true)
        XCTAssertNil(task(0)?.parentTaskID)
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, [], "No Claude process")
    }

    /// The Claude app's session files with their bytes and modification dates, to show reading
    /// changed nothing.
    private func desktopFiles(_ desktop: URL) throws -> [String: [String]] {
        var files: [String: [String]] = [:]
        let enumerator = FileManager.default.enumerator(at: desktop, includingPropertiesForKeys: [.contentModificationDateKey])
        for case let file as URL in enumerator?.allObjects ?? [] where file.pathExtension == "json" {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            files[file.path] = [try Data(contentsOf: file).base64EncodedString(), "\(modified?.timeIntervalSince1970 ?? 0)"]
        }
        return files
    }

    private func forked(_ thread: JSONValue, from parent: String) -> JSONValue {
        guard case var .object(fields) = thread else { return thread }
        fields["forkedFromId"] = .string(parent)
        return .object(fields)
    }

    // MARK: - Fixtures

    private static let ids = (1...6).map { String(format: "%08d-2222-4333-8444-555555555555", $0) }

    /// A chat folder under the real home's chat roots. Only its path is used; nothing is created.
    private static func chatFolder(_ app: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let name = "yardlet-import-test-\(UUID().uuidString.prefix(8))"
        switch app {
        case "Claude":
            return home.appending(path: "Library/Application Support/Claude/scratch-workspaces/\(name)",
                                  directoryHint: .isDirectory).standardizedFileURL
        default:
            return home.appending(path: "Documents/Codex/2026-10-12/\(name)", directoryHint: .isDirectory)
                .standardizedFileURL
        }
    }

    private struct Fixture {
        let model: AppModel
        let claude: ClaudeRecorder
        let codex: FakeCodexTransport
        let claudeAccount: ProviderConnection
        let config: URL
        let desktop: URL
        let project: URL
    }

    /// An AppModel whose Claude runtime records what it is asked and whose Codex runtime is a fake
    /// App Server behind the YHP bridge; a saved Claude account whose config is a temporary folder;
    /// the Claude app's session files in another.
    private func makeFixture() throws -> Fixture {
        let project = Project.canonical(root.appending(path: "project"))
        let config = root.appending(path: "config")
        let desktop = root.appending(path: "claude-code-sessions")
        for folder in [project, config, desktop] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let claudeCLI = root.appending(path: "claude")
        let codexCLI = root.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: claudeCLI)
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: codexCLI)
        for file in [claudeCLI, codexCLI] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let transport = FakeCodexTransport(responses: ["initialize": [.object(["platformOs": .string("macos")])]])
        let codex = YHPCodexCompatibilityAdapter(adapter: CodexAdapter(executableURL: codexCLI, transport: transport),
                                                 manifest: HarnessProtocolCompatibilityManifest.codex())
        let claude = ClaudeRecorder()
        let suite = testDefaultsSuite("NativeHarnessClientTests.OtherAppImport")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { harness, _ in harness == .codex ? codex as any HarnessAdapter : claude },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: config, codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(claudeCLI, for: .claudeCode)
        model.runtimeSelections.select(codexCLI, for: .codex)
        model.claudeDesktopSessionsRoot = desktop
        let account = ProviderConnection(id: "claude-work", name: "work@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: config.path, credentialSelector: nil)
        return Fixture(model: model, claude: claude, codex: transport, claudeAccount: account, config: config,
                       desktop: desktop, project: project)
    }

    /// A Claude app session file with the keys the app writes, made-up values.
    private func sessionFile(
        id: String, cwd: URL, origin: URL, title: String?, archived: Bool = false, model: String? = nil,
        effort: String? = nil, permission: String? = nil, activity: Int64 = 1_791_000_000_000,
        extra: [String: JSONValue] = [:]
    ) -> Data {
        var value: [String: JSONValue] = [
            "sessionId": .string("local_\(UUID().uuidString.lowercased())"), "cliSessionId": .string(id),
            "cwd": .string(cwd.path(percentEncoded: false)), "originCwd": .string(origin.path(percentEncoded: false)),
            "isArchived": .bool(archived), "createdAt": .integer(activity - 60_000), "lastActivityAt": .integer(activity),
            "lastFocusedAt": .integer(activity), "alwaysAllowedReasons": .array([]), "bridgeSessionIds": .array([]),
            "remoteMcpServersConfig": .array([]), "sessionPermissionUpdates": .array([]),
            "chromePermissionMode": .string("ask")
        ]
        if let title { value["title"] = .string(title) }
        if let model { value["model"] = .string(model) }
        if let effort { value["effort"] = .string(effort) }
        if let permission { value["permissionMode"] = .string(permission) }
        value.merge(extra) { _, new in new }
        return (try? JSONEncoder().encode(JSONValue.object(value))) ?? Data()
    }

    private func writeSession(_ desktop: URL, _ data: Data, account: String = "account-1") throws {
        let folder = desktop.appending(path: "org-1/\(account)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "local_\(UUID().uuidString.lowercased()).json"))
    }

    /// Registers this test process, as another app's would be, as holding the session.
    @discardableResult
    private func hold(_ id: String, in config: URL) throws -> URL {
        let folder = config.appending(path: "sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(getpid())-\(id.prefix(8)).json")
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(getpid())), "sessionId": .string(id)]))
            .write(to: file)
        return file
    }

    private func user(_ text: String, id: String, uuid: String = UUID().uuidString, parent: String? = nil)
        -> [String: JSONValue] {
        ["type": .string("user"), "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
         "sessionId": .string(id), "isSidechain": .bool(false),
         "message": .object(["role": .string("user"), "content": .string(text)])]
    }

    private func assistant(_ text: String, id: String, uuid: String, parent: String) -> [String: JSONValue] {
        ["type": .string("assistant"), "uuid": .string(uuid), "parentUuid": .string(parent), "sessionId": .string(id),
         "message": .object(["id": .string("m-\(uuid)"), "role": .string("assistant"),
                             "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]
    }

    @discardableResult
    private func transcript(_ config: URL, _ workspace: URL, _ id: String, lines: [[String: JSONValue]]) throws -> URL {
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id).jsonl")
        let data = try lines.reduce(into: Data()) { result, line in
            result.append(try JSONEncoder().encode(JSONValue.object(line))); result.append(10)
        }
        try data.write(to: file)
        return file
    }

    /// A thread as `thread/list` gives it.
    private func thread(_ id: String, _ name: String, in workspace: URL, source: JSONValue, parent: String? = nil,
                        ephemeral: Bool = false, updatedAt: Date = Date(timeIntervalSince1970: 1_791_000_000)) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "preview": .string(name),
                 "cwd": .string(workspace.standardizedFileURL.path(percentEncoded: false)),
                 "updatedAt": .integer(Int64(updatedAt.timeIntervalSince1970)), "source": source,
                 "parentThreadId": parent.map(JSONValue.string) ?? .null, "ephemeral": .bool(ephemeral),
                 "status": .object(["type": .string("notLoaded")])])
    }

    /// A not-loaded thread as `thread/read` with its turns gives it.
    private func savedThread(_ id: String, turns: Int, path: String? = nil) -> JSONValue {
        var thread: [String: JSONValue] = [
            "id": .string(id), "status": .object(["type": .string("notLoaded")]), "historyMode": .string("paginated"),
            "cwd": .string(root.path), "preview": .string("Fix the list"),
            "turns": .array((1...turns).map { index in
                .object(["id": .string("turn-\(index)"), "status": .string("completed"), "itemsView": .string("full"),
                         "error": .null, "items": .array([
                            .object(["id": .string("user-\(index)"), "type": .string("userMessage"),
                                     "content": .array([.object(["type": .string("text"), "text": .string("Step \(index)")])])]),
                            .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                                     "text": .string("Done \(index)"), "phase": .string("final_answer")])])])
            })
        ]
        if let path { thread["path"] = .string(path) }
        return .object(thread)
    }

    /// `XCTUnwrap` for a value an `await` produced (its autoclosure cannot await).
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func path(_ url: URL) -> String { ProjectSidebarPresentation.normalizedPath(for: url) }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// A Claude runtime that records what it is asked and starts no process.
private actor ClaudeRecorder: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode
    private(set) var calls: [String] = []

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        calls.append("create")
        return HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                    providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        calls.append("resume \(providerSessionID)")
        return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                    workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { calls.append("send \(prompt)") }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        AsyncStream { _ in }
    }
    func close(_ session: HarnessSessionHandle) async {}
}
