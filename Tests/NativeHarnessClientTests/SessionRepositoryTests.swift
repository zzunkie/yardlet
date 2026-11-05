import CSQLite
import Foundation
import XCTest
@testable import NativeHarnessClient

final class SessionRepositoryTests: XCTestCase {
    func testInheritedSideChatContextSurvivesSQLiteReopenAndDeliveryUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "side-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = SessionRecord(harness: .grokBuild, workspaceURL: root,
                                   runtimeExecutableURL: URL(filePath: "/tmp/grok"), title: "Source")
        let context = SideChatContext(source: source, entries: [
            TranscriptEntry(content: .user(text: "  Keep this context 👩🏽‍💻\n")),
            TranscriptEntry(content: .assistant(text: "Decision preserved.", isStreaming: true))])
        var child = SessionRecord(harness: source.harness, workspaceURL: root,
                                  runtimeExecutableURL: source.runtimeExecutableURL, title: "Side",
                                  inheritedContext: context)
        let database = root.appending(path: "sessions.sqlite3")
        try await SQLiteSessionRepository(databaseURL: database).upsert(child)
        let restored = try await SQLiteSessionRepository(databaseURL: database).loadSessions()
        XCTAssertEqual(restored.first?.inheritedContext, context)
        child.inheritedContext?.isDelivered = true
        try await SQLiteSessionRepository(databaseURL: database).upsert(child)
        let delivered = try await SQLiteSessionRepository(databaseURL: database).loadSessions()
        XCTAssertEqual(delivered.first?.inheritedContext?.isDelivered, true)
        XCTAssertEqual(delivered.first?.inheritedContext?.messages.first?.text, "  Keep this context 👩🏽‍💻\n")
    }

    func testSQLiteRoundTripPreservesHarnessRuntimeAndProviderIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-session-repository-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "sessions.sqlite3")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/project-a"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Codex task",
            titleOrigin: .provider,
            previousTitles: ["Fix the failing calc tests", "Calculator"],
            createdAt: timestamp,
            updatedAt: timestamp,
            providerSessionID: "codex-thread-1",
            hasUnreadUpdate: true,
            completionState: .completed,
            isPinned: true,
            providerOptions: ["model": "gpt-5", "sandbox": "enabled"],
            environmentScope: .native
        )
        let claude = SessionRecord(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/project-b"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Claude task",
            createdAt: timestamp,
            updatedAt: timestamp,
            providerSessionID: "claude-session-1"
        )

        let writer = try SQLiteSessionRepository(databaseURL: databaseURL)
        try await writer.upsert(codex)
        try await writer.upsert(claude)

        let reader = try SQLiteSessionRepository(databaseURL: databaseURL)
        let restored = try await reader.loadSessions()
        XCTAssertEqual(Set(restored), Set([codex, claude]))

        try await reader.archive(id: codex.id)
        let afterArchive = try await reader.loadSessions()
        XCTAssertEqual(afterArchive, [claude])
    }

    func testSQLiteRoundTripPreservesUnknownHarnessIdentifier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-open-harness-id-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteSessionRepository(
            databaseURL: root.appending(path: "sessions.sqlite3")
        )
        let session = SessionRecord(
            harness: HarnessKind(rawValue: "future-agent"),
            workspaceURL: URL(filePath: "/tmp/future-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/future-agent"),
            title: "Future task",
            providerSessionID: "future-session"
        )
        // A task of a harness removed from the catalog loads as it was saved, account binding included.
        let removed = SessionRecord(
            harness: HarnessKind(rawValue: "gajae-code"),
            workspaceURL: URL(filePath: "/tmp/removed-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/gjc"),
            title: "Removed harness task",
            providerSessionID: "removed-session",
            connection: ProviderConnection(id: "gjc:/tmp/gjc-home:anthropic/id:1", name: "Saved",
                harness: HarnessKind(rawValue: "gajae-code"), providerID: "anthropic",
                homePath: "/tmp/gjc-home", credentialSelector: "anthropic/id:1")
        )

        try await repository.upsert(session)
        try await repository.upsert(removed)
        let restored = try await repository.loadSessions()

        let future = try XCTUnwrap(restored.first { $0.id == session.id })
        XCTAssertEqual(future.harness.rawValue, "future-agent")
        XCTAssertEqual(future.providerSessionID, "future-session")
        let loaded = try XCTUnwrap(restored.first { $0.id == removed.id })
        XCTAssertEqual(loaded.harness, removed.harness)
        XCTAssertEqual(loaded.providerSessionID, "removed-session")
        XCTAssertEqual(loaded.connection, removed.connection)
    }

    func testSQLiteRoundTripPreservesUnreadCompletionMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-session-metadata-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = try SQLiteSessionRepository(
            databaseURL: root.appending(path: "sessions.sqlite3")
        )
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/metadata-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Metadata task",
            hasUnreadUpdate: true,
            completionState: .failed,
            environmentScope: .yardlet
        )

        try await repository.upsert(session)
        let restored = try await repository.loadSessions()
        XCTAssertEqual(restored.first?.hasUnreadUpdate, true)
        XCTAssertEqual(restored.first?.completionState, .failed)
        XCTAssertEqual(restored.first?.environmentScope, .yardlet)
    }

    func testLegacyRowsMigrateIntoNativeCompatibilityScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-session-scope-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "sessions.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path(), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let id = UUID()
        let legacySchema = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                harness TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                provider_session_id TEXT,
                unread INTEGER NOT NULL DEFAULT 0,
                completion_state TEXT NOT NULL DEFAULT 'none',
                archived INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO sessions VALUES (
                '\(id.uuidString)', 'codex', '/tmp/legacy', '/tmp/codex',
                'Legacy Codex task', 'ready', 1700000000, 1700000000,
                'legacy-thread', 0, 'none', 0
            );
            """
        XCTAssertEqual(sqlite3_exec(database, legacySchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let repository = try SQLiteSessionRepository(databaseURL: databaseURL)
        let restored = try await repository.loadSessions()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.environmentScope, .native)
        XCTAssertEqual(restored.first?.providerSessionID, "legacy-thread")
        XCTAssertEqual(restored.first?.isPinned, false)
        XCTAssertEqual(restored.first?.titleOrigin, .legacy)
        XCTAssertEqual(restored.first?.providerOptions, [:])
        XCTAssertNil(restored.first?.projectID, "A row written before projects keeps no project")
        XCTAssertEqual(restored.first?.additionalRoots, [])
    }

    func testProjectColumnsAreAddedWithoutDisturbingExistingRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-session-project-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "sessions.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path(), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let existingID = UUID()
        // The schema as it stood before projects existed, with connection_binding already added.
        let previousSchema = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                harness TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                provider_session_id TEXT,
                unread INTEGER NOT NULL DEFAULT 0,
                completion_state TEXT NOT NULL DEFAULT 'none',
                environment_scope TEXT NOT NULL DEFAULT 'native',
                pinned INTEGER NOT NULL DEFAULT 0,
                title_origin TEXT NOT NULL DEFAULT 'legacy',
                archived INTEGER NOT NULL DEFAULT 0,
                provider_options TEXT NOT NULL DEFAULT '{}',
                inherited_context TEXT,
                connection_binding TEXT
            );
            INSERT INTO sessions (
                id, harness, workspace_path, runtime_path, title, status,
                created_at, updated_at, provider_session_id, pinned, provider_options
            ) VALUES (
                '\(existingID.uuidString)', 'claude-code', '/tmp/before-projects', '/tmp/claude',
                'Task from before projects', 'ready', 1700000000, 1700000000,
                'claude-session', 1, '{"model":"sonnet"}'
            );
            """
        XCTAssertEqual(sqlite3_exec(database, previousSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let repository = try SQLiteSessionRepository(databaseURL: databaseURL)
        let existing = try await repository.loadSessions()
        XCTAssertEqual(existing.count, 1)
        XCTAssertEqual(existing.first?.id, existingID)
        XCTAssertEqual(existing.first?.title, "Task from before projects")
        XCTAssertEqual(existing.first?.providerSessionID, "claude-session")
        XCTAssertEqual(existing.first?.isPinned, true)
        XCTAssertEqual(existing.first?.providerOptions, ["model": "sonnet"])
        XCTAssertNil(existing.first?.projectID)
        XCTAssertEqual(existing.first?.additionalRoots, [])

        let projectID = UUID()
        let multiRoot = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/repo-a"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Multi root task",
            projectID: projectID,
            additionalRoots: ["/tmp/repo-b", "/tmp/repo-a"]
        )
        try await repository.upsert(multiRoot)

        let reopened = try await SQLiteSessionRepository(databaseURL: databaseURL).loadSessions()
        let stored = try XCTUnwrap(reopened.first { $0.id == multiRoot.id })
        XCTAssertEqual(stored.projectID, projectID)
        XCTAssertEqual(stored.additionalRoots, ["/tmp/repo-b"], "The cwd never repeats as an extra root")
        XCTAssertEqual(reopened.count, 2, "The row written before projects survives the migration")
    }

    func testWorktreeOriginColumnsAreAddedAndLeaveExistingRowsNull() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-session-worktree-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "sessions.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path(), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let existingID = UUID()
        // The schema as it stood before worktree origin existed: projects, but no origin columns.
        let previousSchema = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                harness TEXT NOT NULL,
                workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                provider_session_id TEXT,
                unread INTEGER NOT NULL DEFAULT 0,
                completion_state TEXT NOT NULL DEFAULT 'none',
                environment_scope TEXT NOT NULL DEFAULT 'native',
                pinned INTEGER NOT NULL DEFAULT 0,
                title_origin TEXT NOT NULL DEFAULT 'legacy',
                archived INTEGER NOT NULL DEFAULT 0,
                provider_options TEXT NOT NULL DEFAULT '{}',
                inherited_context TEXT,
                connection_binding TEXT,
                project_id TEXT,
                additional_roots TEXT
            );
            INSERT INTO sessions (
                id, harness, workspace_path, runtime_path, title, status,
                created_at, updated_at, provider_session_id, additional_roots
            ) VALUES (
                '\(existingID.uuidString)', 'codex', '/tmp/before-worktrees', '/tmp/codex',
                'Task from before worktree origin', 'ready', 1700000000, 1700000000,
                'codex-thread', '["/tmp/extra-root"]'
            );
            """
        XCTAssertEqual(sqlite3_exec(database, previousSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let repository = try SQLiteSessionRepository(databaseURL: databaseURL)
        let existing = try await repository.loadSessions()
        XCTAssertEqual(existing.count, 1)
        XCTAssertEqual(existing.first?.id, existingID)
        XCTAssertEqual(existing.first?.title, "Task from before worktree origin")
        XCTAssertEqual(existing.first?.additionalRoots, ["/tmp/extra-root"])
        XCTAssertNil(existing.first?.originWorkspacePath, "An existing row keeps a null origin")
        XCTAssertNil(existing.first?.worktreeName)
        XCTAssertNil(existing.first?.branch)

        let worktreeTask = SessionRecord(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/trees/blue"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Worktree task",
            originWorkspacePath: "/tmp/repo",
            worktreeName: "blue",
            branch: "blue-branch"
        )
        let plainTask = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/repo"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Repository task",
            branch: "main"
        )
        try await repository.upsert(worktreeTask)
        try await repository.upsert(plainTask)

        let reopened = try await SQLiteSessionRepository(databaseURL: databaseURL).loadSessions()
        XCTAssertEqual(reopened.count, 3, "The row written before worktree origin survives")
        let storedWorktree = try XCTUnwrap(reopened.first { $0.id == worktreeTask.id })
        XCTAssertEqual(storedWorktree.originWorkspacePath, "/tmp/repo")
        XCTAssertEqual(storedWorktree.worktreeName, "blue")
        XCTAssertEqual(storedWorktree.branch, "blue-branch")
        let storedPlain = try XCTUnwrap(reopened.first { $0.id == plainTask.id })
        XCTAssertNil(storedPlain.originWorkspacePath, "An ordinary checkout stores no origin")
        XCTAssertNil(storedPlain.worktreeName)
        XCTAssertEqual(storedPlain.branch, "main")
    }
}
