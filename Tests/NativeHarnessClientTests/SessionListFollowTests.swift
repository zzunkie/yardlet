import XCTest
@testable import NativeHarnessClient

/// Following the Claude app's Code sessions and the Codex threads a person started
/// (`SessionListFollow`): which conversations come in, which tasks move, take a title or leave
/// the list, which never do, how often a pass runs, and that the sources are only read. The
/// fixtures copy the shapes of the Claude app's session files and Codex's `thread/list` answers
/// with made-up values; the index is in memory.
@MainActor
final class SessionListFollowTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "session-list-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - The rules

    /// A conversation open in its source and never in Yardlet comes in; one archived there does
    /// not, and each comes in once however often it is listed.
    func testOpenConversationsNotInYardletComeInAndArchivedOnesDoNot() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let open = entry("c-open", in: folder, at: 100)
        let archived = entry("c-archived", in: folder, at: 200, archived: true)
        let plan = SessionListFollow.plan([open, archived, open], state: state(tasks: []))
        XCTAssertEqual(plan.imports.map(\.providerSessionID), ["c-open"])
        XCTAssertTrue(plan.archives.isEmpty && plan.activity.isEmpty && plan.titles.isEmpty)
    }

    /// Test and scratch runs in temporary folders are not followed: the user's temporary
    /// directory, `/private/var/folders` and `/tmp`, through links too.
    func testConversationsInTemporaryFoldersAreLeftAlone() {
        for path in [NSTemporaryDirectory() + "Yardlet.Acceptance/workspace", "/private/var/folders/_s/x/T/run",
                     "/var/folders/_s/x/T/run", "/tmp/Yardlet.CommonUI.abc", "/private/tmp/Yardlet.CommonUI.abc"] {
            XCTAssertTrue(SessionListFollow.isTemporaryFolder(URL(filePath: path)), path)
        }
        for path in ["/Users/someone/Desktop/workspace/app", "/Users/someone/tmp/app", "/private/var/db",
                     "/Users/someone/Library/Application Support/Claude/scratch-workspaces/a/b"] {
            XCTAssertFalse(SessionListFollow.isTemporaryFolder(URL(filePath: path)), path)
        }
        let plan = SessionListFollow.plan([entry("c-temp", in: URL(filePath: "/private/var/folders/_s/x/T/run"), at: 1),
                                           entry("c-tmp", in: URL(filePath: "/tmp/qa"), at: 1)],
                                          state: state(tasks: []))
        XCTAssertTrue(plan.imports.isEmpty)
    }

    /// A conversation the index has a row for in any state — listed under another account,
    /// archived, deleted, or attached right now — never comes in a second time.
    func testAConversationOnceInYardletIsNotBroughtInAgainInAnyState() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let entries = ["c-other-account", "c-archived", "c-deleted", "c-attached"].map { entry($0, in: folder, at: 10) }
        let indexed = Set(entries.map {
            SessionListFollow.IndexedSession(harness: .claudeCode, providerSessionID: $0.conversation.providerSessionID.uppercased())
        })
        let plan = SessionListFollow.plan(entries, state: state(tasks: [], indexed: indexed))
        XCTAssertTrue(plan.isEmpty, "IDs compare in lower case")
        // A Codex thread with the same ID as a Claude session is another conversation.
        let codex = entry("c-archived", harness: .codex, in: folder, at: 10)
        XCTAssertEqual(SessionListFollow.plan([codex], state: state(tasks: [], indexed: indexed)).imports.count, 1)
    }

    /// The source's last activity moves a task forward in recency order, never back.
    func testLastActivityOnlyMovesForward() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let behind = task("c-behind", in: folder, updatedAt: 100)
        let ahead = task("c-ahead", in: folder, updatedAt: 500)
        let same = task("c-same", in: folder, updatedAt: 300)
        let plan = SessionListFollow.plan(
            [entry("c-behind", in: folder, at: 200), entry("c-ahead", in: folder, at: 400),
             entry("c-same", in: folder, at: 300)],
            state: state(tasks: [behind, ahead, same]))
        XCTAssertEqual(plan.activity, [behind.id: Date(timeIntervalSince1970: 200)])
        XCTAssertTrue(plan.imports.isEmpty, "A conversation with a task is followed, not imported")
    }

    /// Only a title the provider gave follows the source's own title; the person's, Yardlet's
    /// fallback, the same title and a source without one stay as they are.
    func testOnlyAProviderTitleFollowsTheSource() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let provider = task("c-provider", in: folder, title: "Old", origin: .provider)
        let manual = task("c-manual", in: folder, title: "Mine", origin: .manual)
        let automatic = task("c-automatic", in: folder, title: "Fallback", origin: .automatic)
        let unchanged = task("c-unchanged", in: folder, title: "Same", origin: .provider)
        let untitled = task("c-untitled", in: folder, title: "Kept", origin: .provider)
        let plan = SessionListFollow.plan(
            [entry("c-provider", in: folder, at: 0, title: "  New   title "), entry("c-manual", in: folder, at: 0, title: "New"),
             entry("c-automatic", in: folder, at: 0, title: "New"), entry("c-unchanged", in: folder, at: 0, title: "Same"),
             entry("c-untitled", in: folder, at: 0, title: nil)],
            state: state(tasks: [provider, manual, automatic, unchanged, untitled]))
        XCTAssertEqual(plan.titles, [provider.id: "New title"])
    }

    /// A listed task the source archived leaves the list unless the person is working in it, has
    /// a draft or queued message, continued it in Yardlet after the source's last activity,
    /// pinned it, or brought it back from Yardlet's archive.
    func testArchiveSkipsWorkInputNewerActivityPinsAndTasksKeptListed() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let idle = task("c-idle", in: folder, updatedAt: 100)
        let equal = task("c-equal", in: folder, updatedAt: 200)
        let busy = task("c-busy", in: folder, updatedAt: 100)
        let newer = task("c-newer", in: folder, updatedAt: 300)
        var pinned = task("c-pinned", in: folder, updatedAt: 100)
        pinned.isPinned = true
        let kept = task("c-kept", in: folder, updatedAt: 100)
        let tasks = [idle, equal, busy, newer, pinned, kept]
        let plan = SessionListFollow.plan(
            tasks.map { entry($0.providerSessionID!, in: folder, at: 200, archived: true, title: "Changed") },
            state: state(tasks: tasks, busy: [busy.id], keptListed: [kept.id]))
        XCTAssertEqual(plan.archives, [idle.id: Date(timeIntervalSince1970: 200), equal.id: Date(timeIntervalSince1970: 200)])
        XCTAssertTrue(plan.activity.isEmpty, "An archived source moves nothing")
        XCTAssertTrue(plan.titles.isEmpty)
    }

    /// A task archived in Yardlet stays archived when its source has it open: it is not in the
    /// list, and the open conversation does not come in beside it. A task kept listed is let go
    /// once its source lists it open again.
    func testATaskArchivedInYardletIsNeverUnarchivedByAnOpenSource() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let kept = task("c-kept", in: folder, updatedAt: 100)
        let plan = SessionListFollow.plan(
            [entry("c-archived-here", in: folder, at: 900), entry("c-kept", in: folder, at: 50)],
            state: state(tasks: [kept], indexed: [.init(harness: .claudeCode, providerSessionID: "c-archived-here")],
                         keptListed: [kept.id]))
        XCTAssertTrue(plan.imports.isEmpty)
        XCTAssertTrue(plan.archives.isEmpty)
        XCTAssertEqual(plan.keptListedReleased, [kept.id])
    }

    /// A native Codex task's thread is listed a moment before the task records its ID: a thread
    /// in the folder of a task made in the last ten minutes with no ID yet waits for a later pass.
    func testAThreadOfANewTaskThatHasNoIDYetWaitsForTheNextPass() {
        let folder = URL(filePath: "/Users/someone/work/app")
        let now = Date(timeIntervalSince1970: 10_000)
        let starting = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/bin/codex"),
                                     title: "New task", createdAt: now.addingTimeInterval(-30), updatedAt: now)
        let thread = entry("t-new", harness: .codex, in: folder, at: 10_000)
        XCTAssertTrue(SessionListFollow.plan([thread], state: state(tasks: [starting], now: now)).imports.isEmpty)
        // Another folder, another harness, an older thread or a task long without an ID do not hold it.
        XCTAssertEqual(SessionListFollow.plan([entry("t-new", harness: .codex, in: URL(filePath: "/elsewhere"), at: 10_000)],
                                              state: state(tasks: [starting], now: now)).imports.count, 1)
        XCTAssertEqual(SessionListFollow.plan([entry("t-new", in: folder, at: 10_000)],
                                              state: state(tasks: [starting], now: now)).imports.count, 1)
        XCTAssertEqual(SessionListFollow.plan([entry("t-old", harness: .codex, in: folder, at: 9_000)],
                                              state: state(tasks: [starting], now: now)).imports.count, 1)
        XCTAssertEqual(SessionListFollow.plan([thread], state: state(tasks: [starting], now: now.addingTimeInterval(700)))
            .imports.count, 1)
    }

    /// A pass starts at most once every ten minutes, and never while one is running.
    func testAPassRunsAtMostEveryTenMinutesAndOneAtATime() {
        var schedule = SessionListFollow.Schedule()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(schedule.begin(at: start))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(700)), "One at a time")
        schedule.end()
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(60)))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(599)))
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(600)))
        schedule.end()
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(900)))
    }

    // MARK: - Reading the sources and the index

    /// The Claude app's list for following has its open and archived sessions whose transcript
    /// is in the account's history, each once: open while any of its files is open, with the
    /// app's own title to follow (none when the app has none, though the import names it from the
    /// transcript). The import sheet's list stays the open ones.
    func testTheClaudeAppsListIsReadOpenAndArchivedEachOnce() throws {
        let desktop = root.appending(path: "claude-code-sessions")
        let config = root.appending(path: "config")
        let project = root.appending(path: "project")
        try writeSession(desktop, sessionFile(id: Self.ids[0], cwd: project, title: "Open", activity: 3_000))
        try writeSession(desktop, sessionFile(id: Self.ids[1], cwd: project, title: "Archived", archived: true,
                                              activity: 2_000))
        // Archived under one account, open under another: open.
        try writeSession(desktop, sessionFile(id: Self.ids[2], cwd: project, title: "Both", archived: true,
                                              activity: 5_000))
        try writeSession(desktop, sessionFile(id: Self.ids[2], cwd: project, title: "Both", activity: 1_000),
                         account: "account-2")
        try writeSession(desktop, sessionFile(id: Self.ids[3], cwd: project, title: nil, activity: 4_000))
        try writeSession(desktop, sessionFile(id: Self.ids[4], cwd: project, title: "No transcript", activity: 6_000))
        for id in Self.ids[0...3] { try transcript(config, project, id) }

        let followed = ClaudeDesktopSessionCatalog.followedConversations(root: desktop, configDirectory: config)
        let byID = Dictionary(uniqueKeysWithValues: followed.map { ($0.conversation.providerSessionID, $0) })
        XCTAssertEqual(Set(byID.keys), Set(Self.ids[0...3]))
        XCTAssertEqual(followed.count, 4)
        XCTAssertEqual(byID[Self.ids[0]]?.isArchived, false)
        XCTAssertEqual(byID[Self.ids[1]]?.isArchived, true)
        XCTAssertEqual(byID[Self.ids[2]]?.isArchived, false)
        XCTAssertEqual(byID[Self.ids[2]]?.lastActivity, Date(timeIntervalSince1970: 1), "From the open file")
        XCTAssertEqual(byID[Self.ids[0]]?.sourceTitle, "Open")
        XCTAssertNil(byID[Self.ids[3]]?.sourceTitle, "No title of the app's to follow")
        XCTAssertEqual(byID[Self.ids[3]]?.conversation.title, "Hello", "The import names it from the transcript")
        XCTAssertEqual(Set(ClaudeDesktopSessionCatalog.conversations(root: desktop, configDirectory: config)
            .map(\.providerSessionID)), [Self.ids[0], Self.ids[2], Self.ids[3]])
    }

    /// The SQLite index answers which provider sessions it has a row for in any state: listed,
    /// archived and deleted (or discarded) alike.
    func testTheIndexKnowsListedArchivedAndDeletedSessions() async throws {
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        func record(_ id: String?, _ harness: HarnessKind = .claudeCode) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/bin/echo"),
                          title: "Task", providerSessionID: id)
        }
        let listed = record("AAAA-listed"), archived = record("aaaa-archived"), deleted = record("aaaa-deleted")
        let codex = record("t-1", .codex), none = record(nil)
        for session in [listed, archived, deleted, codex, none] { try await repository.upsert(session) }
        try await repository.archive(id: archived.id, providerArchived: false)
        try await repository.discard(id: deleted.id)
        let indexed = try await repository.indexedProviderSessions()
        XCTAssertEqual(indexed, [
            .init(harness: .claudeCode, providerSessionID: "aaaa-listed"),
            .init(harness: .claudeCode, providerSessionID: "aaaa-archived"),
            .init(harness: .claudeCode, providerSessionID: "aaaa-deleted"),
            .init(harness: .codex, providerSessionID: "t-1")])
        let loaded = try await repository.loadSessions()
        XCTAssertEqual(Set(loaded.map(\.id)), [listed.id, codex.id, none.id], "Reading it changes no row's state")
    }

    /// Opt-in dry run: `NHC_SESSION_LIST_FOLLOW_LIVE=1` with `NHC_SESSION_LIST_FOLLOW_INDEX` (a copy
    /// of `session-index.sqlite3`) and `NHC_SESSION_LIST_FOLLOW_CLAUDE_HOME` (the Claude account's
    /// config folder) plans a pass over the Claude app's real session files and prints only counts.
    /// The copy is read; nothing is written anywhere, and no task is taken as busy.
    func testLiveDryRunOverTheClaudeAppsSessions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NHC_SESSION_LIST_FOLLOW_LIVE"] == "1", let index = environment["NHC_SESSION_LIST_FOLLOW_INDEX"],
              let home = environment["NHC_SESSION_LIST_FOLLOW_CLAUDE_HOME"] else {
            throw XCTSkip("Set NHC_SESSION_LIST_FOLLOW_LIVE=1, NHC_SESSION_LIST_FOLLOW_INDEX and NHC_SESSION_LIST_FOLLOW_CLAUDE_HOME")
        }
        let repository = try SQLiteSessionRepository(databaseURL: URL(filePath: index))
        let tasks = try await repository.loadSessions()
        let indexed = try await repository.indexedProviderSessions()
        let entries = ClaudeDesktopSessionCatalog.followedConversations(
            root: ClaudeDesktopSessionCatalog.defaultRoot(), configDirectory: URL(filePath: home, directoryHint: .isDirectory))
        let plan = SessionListFollow.plan(entries, state: SessionListFollow.State(
            tasks: tasks, indexed: indexed,
            task: { conversation in
                tasks.first { $0.harness == conversation.harness && $0.environmentScope == .native
                    && $0.providerSessionID?.lowercased() == conversation.providerSessionID.lowercased() }
            },
            isBusy: { _ in false }))
        let places = plan.imports.map { conversation -> String in
            switch ConversationImportPlacement.of(conversation) {
            case .chat: "chat"
            case .project: "project"
            }
        }
        let archivedListed = entries.filter { entry in
            entry.isArchived && tasks.contains { $0.providerSessionID?.lowercased() == entry.conversation.providerSessionID }
        }.count
        print("follow dry run: entries", entries.count, "open", entries.filter { !$0.isArchived }.count,
              "imports", plan.imports.count, Dictionary(grouping: places, by: { $0 }).mapValues(\.count),
              "activity", plan.activity.count, "titles", plan.titles.count,
              "archived in the app and listed", archivedListed, "archives", plan.archives.count,
              "kept by newer Yardlet activity", archivedListed - plan.archives.count)
    }

    // MARK: - A pass in the app

    /// Open conversations come in through the import path: the Claude account the import sheet
    /// starts on, Codex's default login, the other app's last activity (Codex's `recencyAt`), a
    /// project for a folder and none for a chat, no task opened. Archived ones, temporary
    /// folders and sessions without a transcript stay out. Codex is asked only `thread/list`, for
    /// open and archived threads; no Claude process starts; the sources are not written.
    func testAPassImportsThroughTheImportPathAndWritesNothingToTheSources() async throws {
        let fixture = try makeFixture()
        let chat = Self.chatFolder()
        let scratch = root.appending(path: "scratch/run")
        let lone = root.appending(path: "lone")
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[0], cwd: fixture.project, title: "Plain project",
                                                      activity: 1_791_000_000_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[1], cwd: fixture.project, title: "Archived there",
                                                      archived: true, activity: 1_791_000_100_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[2], cwd: scratch, title: "A test run",
                                                      activity: 1_791_000_200_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[3], cwd: chat, title: "Claude chat",
                                                      activity: 1_791_000_300_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[4], cwd: fixture.project, title: "No transcript",
                                                      activity: 1_791_000_400_000))
        var transcripts: [URL] = []
        for (id, folder) in [(Self.ids[0], fixture.project), (Self.ids[1], fixture.project), (Self.ids[2], scratch),
                             (Self.ids[3], chat)] {
            transcripts.append(try transcript(fixture.config, folder, id))
        }
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([
                thread("t-new", "Codex in a folder", in: lone, updatedAt: 1_791_000_900, recencyAt: 1_791_000_500),
                thread("t-exec", "An automation run", in: lone, source: .string("exec")),
                thread("t-temp", "A test thread", in: scratch)]),
            "nextCursor": .null]))
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-gone", "Archived in Codex", in: lone)]), "nextCursor": .null]))
        let filesBefore = try desktopFiles(fixture.desktop)
        let transcriptsBefore = try transcripts.map { try Data(contentsOf: $0) }

        await fixture.model.followSessionLists()

        let sessions = fixture.model.store.sessions
        XCTAssertEqual(Set(sessions.compactMap(\.providerSessionID)), [Self.ids[0], Self.ids[3], "t-new"])
        func task(_ id: String) throws -> SessionRecord { try XCTUnwrap(sessions.first { $0.providerSessionID == id }) }
        let plain = try task(Self.ids[0])
        XCTAssertEqual(plain.connection, fixture.claudeAccount, "The account the import sheet starts on")
        XCTAssertEqual(plain.environmentScope, .native)
        XCTAssertEqual(plain.titleOrigin, .provider)
        XCTAssertEqual(plain.title, "Plain project")
        XCTAssertEqual(plain.updatedAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(plain.projectID, fixture.model.projects.project(containingRoot: fixture.project)?.id)
        XCTAssertNil(try task(Self.ids[3]).projectID, "A Claude app scratch workspace is a chat: no project")
        XCTAssertNil(fixture.model.projects.project(containingRoot: chat))
        let codex = try task("t-new")
        XCTAssertNil(codex.connection, "Codex's default login")
        XCTAssertEqual(codex.updatedAt, Date(timeIntervalSince1970: 1_791_000_500), "When a person last worked in it")
        XCTAssertNil(fixture.model.store.selectedSessionID, "Nothing opens")
        XCTAssertTrue(sessions.allSatisfy { !fixture.model.isAttached($0.id) })

        let claudeCalls = await fixture.claude.calls
        XCTAssertEqual(claudeCalls, [], "No Claude process")
        let methods = await fixture.codex.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/list", "thread/list"])
        let lists = await fixture.codex.requests.filter { $0.method == "thread/list" }
        XCTAssertEqual(lists.map { $0.params["archived"] }, [.bool(false), .bool(true)])
        XCTAssertEqual(lists[1].params["sourceKinds"], .array([.string("cli"), .string("vscode"), .string("appServer"), .string("cloud")]))
        XCTAssertEqual(try desktopFiles(fixture.desktop), filesBefore, "The Claude app's files are only read")
        XCTAssertEqual(try transcripts.map { try Data(contentsOf: $0) }, transcriptsBefore)

        // The next pass adds nothing: each conversation has its task.
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-new", "Codex in a folder", in: lone, updatedAt: 1_791_000_900,
                                   recencyAt: 1_791_000_500)]), "nextCursor": .null]))
        await fixture.model.followSessionLists()
        XCTAssertEqual(fixture.model.store.sessions.count, 3)
    }

    /// Tasks already in Yardlet follow their source: the last activity forward, a provider title,
    /// the archive. A task the person is in, has a draft in, continued in Yardlet, or pinned
    /// stays listed with its draft. The archive is Yardlet's only: Codex is not asked to archive,
    /// and no provider ID, scope, account, project, reading state or pin changes.
    func testAPassFollowsActivityTitlesAndArchivesWithoutLosingADraft() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        func make(_ id: String, _ harness: HarnessKind = .claudeCode, title: String = "Imported",
                  origin: SessionTitleOrigin = .provider, at seconds: TimeInterval) async throws -> SessionRecord {
            try await model.store.createSession(
                harness: harness, workspaceURL: fixture.project, runtimeExecutableURL: URL(filePath: "/bin/echo"),
                title: title, titleOrigin: origin, providerSessionID: id, selectsSession: false,
                connection: harness == .claudeCode ? fixture.claudeAccount : nil,
                lastActivityAt: Date(timeIntervalSince1970: seconds))
        }
        let moved = try await make(Self.ids[0], at: 1_000)
        let named = try await make(Self.ids[1], title: "My own name", origin: .manual, at: 3_000)
        let idle = try await make(Self.ids[2], at: 1_000)
        let drafted = try await make(Self.ids[3], at: 1_000)
        let continued = try await make(Self.ids[4], at: 5_000)
        let pinned = try await make(Self.ids[5], at: 1_000)
        let running = try await make(Self.ids[6], at: 1_000)
        let codexIdle = try await make("t-idle", .codex, at: 1_000)
        let codexRunning = try await make("t-running", .codex, at: 1_000)
        try await model.store.togglePinned(id: pinned.id)
        try await model.store.updateSession(id: running.id, status: .running, updatesRecency: false)
        try await model.store.updateSession(id: codexRunning.id, status: .running, updatesRecency: false)
        try await model.store.markUnread(id: moved.id)
        model.composerDrafts.tasks.draft(for: drafted.id).text = "Words not sent yet"

        try writeSession(fixture.desktop, sessionFile(id: Self.ids[0], cwd: fixture.project, title: "Renamed in the app",
                                                      activity: 2_000_000))
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[1], cwd: fixture.project, title: "The app's title",
                                                      activity: 2_500_000))
        for (index, id) in Self.ids[2...6].enumerated() {
            try writeSession(fixture.desktop, sessionFile(id: id, cwd: fixture.project, title: "Archived \(index)",
                                                          archived: true, activity: 1_000_000))
        }
        for id in Self.ids[0...6] { try transcript(fixture.config, fixture.project, id) }
        await fixture.codex.enqueue(method: "thread/list", result: .object(["data": .array([]), "nextCursor": .null]))
        await fixture.codex.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-idle", "Idle", in: fixture.project, updatedAt: 1_000),
                            thread("t-running", "Running", in: fixture.project, updatedAt: 1_000)]),
            "nextCursor": .null]))

        await model.followSessionLists()

        func current(_ task: SessionRecord) -> SessionRecord? { model.store.sessions.first { $0.id == task.id } }
        let after = try XCTUnwrap(current(moved))
        XCTAssertEqual(after.updatedAt, Date(timeIntervalSince1970: 2_000), "Forward to the app's last activity")
        XCTAssertEqual(after.title, "Renamed in the app")
        XCTAssertEqual(after.titleOrigin, .provider)
        XCTAssertEqual(after.providerSessionID, moved.providerSessionID)
        XCTAssertEqual(after.environmentScope, moved.environmentScope)
        XCTAssertEqual(after.connection, moved.connection)
        XCTAssertEqual(after.projectID, moved.projectID)
        XCTAssertTrue(after.hasUnreadUpdate, "Reading state stays")
        XCTAssertFalse(after.isPinned)
        let kept = try XCTUnwrap(current(named))
        XCTAssertEqual(kept.title, "My own name", "The person's title stays")
        XCTAssertEqual(kept.updatedAt, Date(timeIntervalSince1970: 3_000), "Never moved back")

        XCTAssertNil(current(idle), "Archived in the app and idle here: archived")
        XCTAssertNil(current(codexIdle), "Archived in Codex and idle here: archived")
        for task in [drafted, continued, pinned, running, codexRunning] {
            XCTAssertNotNil(current(task), "\(task.providerSessionID ?? "") stays listed")
        }
        XCTAssertEqual(model.composerDrafts.tasks.existingDraft(for: drafted.id)?.text, "Words not sent yet")
        XCTAssertTrue(try XCTUnwrap(current(pinned)).isPinned)
        await model.loadArchivedTasks()
        let archived = try XCTUnwrap(model.store.archivedSessions)
        XCTAssertEqual(Set(archived.map(\.id)), [idle.id, codexIdle.id])
        XCTAssertTrue(archived.allSatisfy { !$0.isProviderArchived }, "Archived in Yardlet only")
        XCTAssertEqual(archived.first { $0.id == idle.id }?.session.providerSessionID, Self.ids[2])
        let methods = await fixture.codex.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/list", "thread/list"], "No thread/archive, no write to Codex")
        let claudeCalls = await fixture.claude.calls
        XCTAssertEqual(claudeCalls, [])
    }

    /// A Claude session Yardlet made (a child task, under an account that shares the history or
    /// one that does not) is not imported a second time when a source lists it, nor is one the
    /// person deleted or archived in Yardlet; the archived one stays archived.
    func testAYardletCreatedClaudeSessionIsNotImportedASecondTime() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let sharedHome = root.appending(path: "shared-home")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.config.appending(path: "projects"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sharedHome.appending(path: "projects"),
                                                   withDestinationURL: fixture.config.appending(path: "projects"))
        let otherHome = root.appending(path: "other-home")
        try FileManager.default.createDirectory(at: otherHome.appending(path: "projects"), withIntermediateDirectories: true)
        let shared = ProviderConnection(id: "claude-shared", name: "shared@example.test", harness: .claudeCode,
                                        providerID: nil, homePath: sharedHome.path, credentialSelector: nil)
        let other = ProviderConnection(id: "claude-other", name: "other@example.test", harness: .claudeCode,
                                       providerID: nil, homePath: otherHome.path, credentialSelector: nil)
        func make(_ id: String, connection: ProviderConnection, parent: UUID? = nil) async throws -> SessionRecord {
            try await model.store.createSession(
                harness: .claudeCode, workspaceURL: fixture.project, runtimeExecutableURL: URL(filePath: "/bin/echo"),
                title: "Made in Yardlet", titleOrigin: .provisional, providerSessionID: id, selectsSession: false,
                connection: connection, lastActivityAt: Date(timeIntervalSince1970: 1_000), parentTaskID: parent)
        }
        let parent = try await make(Self.ids[5], connection: fixture.claudeAccount)
        let child = try await make(Self.ids[0], connection: shared, parent: parent.id)
        _ = try await make(Self.ids[1], connection: other)
        let deleted = try await make(Self.ids[2], connection: fixture.claudeAccount)
        let archived = try await make(Self.ids[3], connection: fixture.claudeAccount)
        try await model.store.discardSession(id: deleted.id)
        try await model.store.archiveSession(id: archived.id)
        for id in Self.ids[0...3] {
            try writeSession(fixture.desktop, sessionFile(id: id, cwd: fixture.project, title: "Listed by a source",
                                                          activity: 2_000_000))
            try transcript(fixture.config, fixture.project, id)
        }
        let before = model.store.sessions.map(\.id)

        await model.followSessionLists()

        XCTAssertEqual(model.store.sessions.map(\.id), before, "No second task")
        XCTAssertEqual(model.store.sessions.first { $0.id == child.id }?.parentTaskID, parent.id)
        XCTAssertEqual(model.store.sessions.first { $0.id == child.id }?.connection, shared,
                       "Matched across accounts sharing the history, and its account stays")
        await model.loadArchivedTasks()
        XCTAssertEqual(model.store.archivedSessions?.map(\.id), [archived.id], "Not unarchived")
    }

    /// Bringing a task back from Yardlet's archive is the person's choice: the source still
    /// having it archived does not archive it again, until the source lists it open once more.
    func testUnarchivingInYardletIsNotUndoneUntilTheSourceOpensItAgain() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let task = try await model.store.createSession(
            harness: .claudeCode, workspaceURL: fixture.project, runtimeExecutableURL: URL(filePath: "/bin/echo"),
            title: "Imported", titleOrigin: .provider, providerSessionID: Self.ids[0], selectsSession: false,
            connection: fixture.claudeAccount, lastActivityAt: Date(timeIntervalSince1970: 1_000))
        try transcript(fixture.config, fixture.project, Self.ids[0])
        let file = try writeSession(fixture.desktop, sessionFile(id: Self.ids[0], cwd: fixture.project, title: "Imported",
                                                                 archived: true, activity: 1_000_000))
        await model.followSessionLists()
        XCTAssertTrue(model.store.sessions.isEmpty, "Archived with its source")

        await model.loadArchivedTasks()
        await model.unarchive(try XCTUnwrap(model.store.archivedSessions?.first))
        XCTAssertEqual(model.store.sessions.map(\.id), [task.id])
        XCTAssertEqual(model.sessionListFollowKeptListed(), [task.id])
        await model.followSessionLists()
        XCTAssertEqual(model.store.sessions.map(\.id), [task.id], "Kept listed while the source has it archived")

        try sessionFile(id: Self.ids[0], cwd: fixture.project, title: "Imported", activity: 1_000_000).write(to: file)
        await model.followSessionLists()
        XCTAssertEqual(model.sessionListFollowKeptListed(), [], "Let go once the source lists it open")
        XCTAssertEqual(model.store.sessions.map(\.id), [task.id])

        try sessionFile(id: Self.ids[0], cwd: fixture.project, title: "Imported", archived: true,
                        activity: 1_000_000).write(to: file)
        await model.followSessionLists()
        XCTAssertTrue(model.store.sessions.isEmpty, "A later archive in the source counts again")
    }

    /// Launch asks for a pass once the index is restored; another comes only when the person asks
    /// (File › Refresh from the Claude App and Codex), at any time (2026-10-22 user decision).
    func testLaunchRunsAPassAndTheRefreshRunsOneWhenAsked() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        try writeSession(fixture.desktop, sessionFile(id: Self.ids[0], cwd: fixture.project, title: "First"))
        try transcript(fixture.config, fixture.project, Self.ids[0])
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        model.sessionListFollowIsReady = false
        await model.followSessionListsIfDue(now: start)
        await model.followSessionListsNow(now: start)
        XCTAssertTrue(model.store.sessions.isEmpty, "Not before the index is restored")

        model.sessionListFollowIsReady = true
        await model.followSessionListsIfDue(now: start)
        XCTAssertEqual(model.store.sessions.count, 1)
        XCTAssertFalse(model.isFollowingSessionLists)

        try writeSession(fixture.desktop, sessionFile(id: Self.ids[1], cwd: fixture.project, title: "Second"))
        try transcript(fixture.config, fixture.project, Self.ids[1])
        await model.followSessionListsIfDue(now: start.addingTimeInterval(60))
        XCTAssertEqual(model.store.sessions.count, 1, "Launch's pass does not repeat by itself")
        await model.followSessionListsNow(now: start.addingTimeInterval(61))
        XCTAssertEqual(model.store.sessions.count, 2, "Asked, it runs at once")
        XCTAssertFalse(model.isFollowingSessionLists)
    }

    func testTheAccountMenuOffersTheRefreshAndSaysWhileItRuns() {
        let identity = SidebarAccountIdentity(fullName: "Person", userName: nil)
        let idle = SidebarAccountMenu.make(identity: identity, settingsSections: [.accounts])
        let item = idle.items.first { $0.destination == .refreshFromOtherApps }
        XCTAssertEqual(item?.title, L10n.string("Refresh from the Claude App and Codex"))
        XCTAssertEqual(item?.isEnabled, true)
        let running = SidebarAccountMenu.make(identity: identity, settingsSections: [.accounts], refreshing: true)
        let busy = running.items.first { $0.destination == .refreshFromOtherApps }
        XCTAssertEqual(busy?.title, L10n.string("Refreshing from the Claude App and Codex…"))
        XCTAssertEqual(busy?.isEnabled, false)
    }

    // MARK: - Rule fixtures

    private func entry(_ id: String, harness: HarnessKind = .claudeCode, in folder: URL, at seconds: TimeInterval,
                       archived: Bool = false, title: String? = "Title") -> SessionListFollow.Entry {
        SessionListFollow.Entry(
            conversation: ImportableConversation(harness: harness, providerSessionID: id, title: title ?? "Listed",
                                                 workspaceURL: folder, updatedAt: Date(timeIntervalSince1970: seconds),
                                                 isOpenElsewhere: false),
            isArchived: archived, sourceTitle: title)
    }

    private func task(_ id: String, harness: HarnessKind = .claudeCode, in folder: URL, updatedAt seconds: TimeInterval = 0,
                      title: String = "Title", origin: SessionTitleOrigin = .provider) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/bin/echo"),
                      title: title, titleOrigin: origin, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: seconds), providerSessionID: id)
    }

    /// The listed tasks matched by harness and provider ID, as the app matches them under one account.
    private func state(tasks: [SessionRecord], indexed: Set<SessionListFollow.IndexedSession> = [],
                       busy: Set<UUID> = [], keptListed: Set<UUID> = [],
                       now: Date = Date(timeIntervalSince1970: 1_000_000)) -> SessionListFollow.State {
        let all = indexed.union(tasks.compactMap { task in
            task.providerSessionID.map { SessionListFollow.IndexedSession(harness: task.harness, providerSessionID: $0) }
        })
        return SessionListFollow.State(
            tasks: tasks, indexed: all,
            task: { conversation in
                tasks.first { $0.harness == conversation.harness && $0.providerSessionID == conversation.providerSessionID }
            },
            isBusy: { busy.contains($0.id) }, keptListed: keptListed, now: now)
    }

    // MARK: - App fixtures

    private static let ids = (1...8).map { String(format: "%08d-3333-4444-8555-666666666666", $0) }

    /// A chat folder under the real home's Claude app chat root. Only its path is used.
    private static func chatFolder() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/scratch-workspaces/yardlet-follow-test-\(UUID().uuidString.prefix(8))",
                       directoryHint: .isDirectory).standardizedFileURL
    }

    private struct Fixture {
        let model: AppModel
        let claude: FollowClaudeRecorder
        let codex: FakeCodexTransport
        let claudeAccount: ProviderConnection
        let config: URL
        let desktop: URL
        let project: URL
    }

    /// An AppModel with an in-memory index whose Claude runtime records what it is asked and whose
    /// Codex runtime is a fake App Server behind the YHP bridge; a saved Claude account, chosen for
    /// new tasks, whose config is a temporary folder; the Claude app's session files in another.
    /// Folders under `scratch` stand for temporary ones (the fixture itself is in a temporary folder).
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
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: codexCLI)
        for file in [claudeCLI, codexCLI] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let transport = FakeCodexTransport(responses: ["initialize": [.object(["platformOs": .string("macos")])]])
        let codex = YHPCodexCompatibilityAdapter(adapter: CodexAdapter(executableURL: codexCLI, transport: transport),
                                                 manifest: HarnessProtocolCompatibilityManifest.codex())
        let claude = FollowClaudeRecorder()
        let suite = testDefaultsSuite("NativeHarnessClientTests.SessionListFollow")
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
        let scratch = ProjectSidebarPresentation.normalizedPath(for: root.appending(path: "scratch")) + "/"
        model.sessionListFollowSkipsFolder = { ProjectSidebarPresentation.normalizedPath(for: $0).hasPrefix(scratch) }
        let account = ProviderConnection(id: "claude-work", name: "work@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: config.path, credentialSelector: nil)
        try model.connections.save(account)
        model.connections.selection[.claudeCode] = account.id
        return Fixture(model: model, claude: claude, codex: transport, claudeAccount: account, config: config,
                       desktop: desktop, project: project)
    }

    /// A Claude app session file with the keys the app writes, made-up values.
    private func sessionFile(id: String, cwd: URL, title: String?, archived: Bool = false,
                             activity: Int64 = 1_791_000_000_000) -> Data {
        var value: [String: JSONValue] = [
            "sessionId": .string("local_\(UUID().uuidString.lowercased())"), "cliSessionId": .string(id),
            "cwd": .string(cwd.path(percentEncoded: false)), "originCwd": .string(cwd.path(percentEncoded: false)),
            "isArchived": .bool(archived), "createdAt": .integer(activity - 60_000), "lastActivityAt": .integer(activity),
            "lastFocusedAt": .integer(activity), "permissionMode": .string("default")
        ]
        if let title { value["title"] = .string(title) }
        return (try? JSONEncoder().encode(JSONValue.object(value))) ?? Data()
    }

    @discardableResult
    private func writeSession(_ desktop: URL, _ data: Data, account: String = "account-1") throws -> URL {
        let folder = desktop.appending(path: "org-1/\(account)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "local_\(UUID().uuidString.lowercased()).json")
        try data.write(to: file)
        return file
    }

    /// A one-line Claude Code transcript for the session, where the account's history keeps it.
    @discardableResult
    private func transcript(_ config: URL, _ workspace: URL, _ id: String) throws -> URL {
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id).jsonl")
        let line: [String: JSONValue] = [
            "type": .string("user"), "uuid": .string(UUID().uuidString), "parentUuid": .null, "sessionId": .string(id),
            "isSidechain": .bool(false), "message": .object(["role": .string("user"), "content": .string("Hello")])]
        var data = try JSONEncoder().encode(JSONValue.object(line))
        data.append(10)
        try data.write(to: file)
        return file
    }

    /// A thread as `thread/list` gives it.
    private func thread(_ id: String, _ name: String, in workspace: URL, source: JSONValue = .string("vscode"),
                        updatedAt: Int64 = 1_791_000_000, recencyAt: Int64? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "preview": .string("First request of \(id)"),
            "cwd": .string(workspace.standardizedFileURL.path(percentEncoded: false)),
            "updatedAt": .integer(updatedAt), "source": source, "parentThreadId": .null, "ephemeral": .bool(false),
            "status": .object(["type": .string("notLoaded")])]
        if let recencyAt { value["recencyAt"] = .integer(recencyAt) }
        return .object(value)
    }

    /// The Claude app's session files with their bytes and modification dates.
    private func desktopFiles(_ desktop: URL) throws -> [String: [String]] {
        var files: [String: [String]] = [:]
        let enumerator = FileManager.default.enumerator(at: desktop, includingPropertiesForKeys: [.contentModificationDateKey])
        for case let file as URL in enumerator?.allObjects ?? [] where file.pathExtension == "json" {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            files[file.path] = [try Data(contentsOf: file).base64EncodedString(), "\(modified?.timeIntervalSince1970 ?? 0)"]
        }
        return files
    }
}

/// A Claude runtime that records what it is asked and starts no process.
private actor FollowClaudeRecorder: HarnessAdapter {
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
