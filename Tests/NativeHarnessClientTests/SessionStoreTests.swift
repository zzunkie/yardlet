import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class SessionStoreTests: XCTestCase {
    func testCreateSessionPinsHarnessAndSelectsSession() async throws {
        let store = SessionStore()
        let workspace = URL(filePath: "/tmp/example")
        let runtime = URL(filePath: "/tmp/claude")

        let session = try await store.createSession(
            harness: .claudeCode,
            workspaceURL: workspace,
            runtimeExecutableURL: runtime,
            title: "  Review auth flow  "
        )

        XCTAssertEqual(session.harness, .claudeCode)
        XCTAssertEqual(session.title, "Review auth flow")
        XCTAssertEqual(session.workspaceURL, workspace.standardizedFileURL)
        XCTAssertEqual(session.runtimeExecutableURL, runtime.standardizedFileURL)
        XCTAssertEqual(session.environmentScope, .native)
        XCTAssertEqual(session.titleOrigin, .manual)
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testWorkspaceGroupsSortByLatestSession() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let firstWorkspace = URL(filePath: "/tmp/first")
        let secondWorkspace = URL(filePath: "/tmp/second")

        let store = SessionStore(sessions: [
            SessionRecord(
                harness: .codex,
                workspaceURL: firstWorkspace,
                runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                title: "Older",
                createdAt: older,
                updatedAt: older
            ),
            SessionRecord(
                harness: .claudeCode,
                workspaceURL: secondWorkspace,
                runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                title: "Newer",
                createdAt: newer,
                updatedAt: newer
            )
        ])

        XCTAssertEqual(store.workspaceGroups.map(\.workspaceURL), [
            secondWorkspace.standardizedFileURL,
            firstWorkspace.standardizedFileURL
        ])
    }

    func testBlankTitleUsesStableFallback() async throws {
        let store = SessionStore()

        let session = try await store.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "   "
        )

        XCTAssertEqual(session.title, L10n.string("New task"))
    }

    func testRestoreKeepsRuntimeAsleepInsteadOfShowingStaleRunningState() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Interrupted by restart",
            status: .running,
            providerSessionID: "thread-1"
        )
        let repository = InMemorySessionRepository(sessions: [session])
        let store = SessionStore(repository: repository)

        try await store.restore()

        XCTAssertEqual(store.sessions.first?.status, .ready)
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first?.status, .ready)
    }

    func testRenamePersistsTrimmedTitle() async throws {
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository)
        let session = try await store.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Before"
        )

        try await store.renameSession(
            id: session.id,
            title: "  After  ",
            titleOrigin: .provider
        )

        XCTAssertEqual(store.sessions.first?.title, "After")
        XCTAssertEqual(store.sessions.first?.titleOrigin, .provider)
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first?.title, "After")
        XCTAssertEqual(persisted.first?.previousTitles, [], "A provider's next title replaces its last")

        // The person's renames keep the names they replace, which the sidebar search still finds.
        try await store.renameSession(id: session.id, title: "Mine", titleOrigin: .manual)
        try await store.renameSession(id: session.id, title: "Mine again", titleOrigin: .manual)
        try await store.renameSession(id: session.id, title: "After", titleOrigin: .manual)
        let renamed = try await repository.loadSessions()
        XCTAssertEqual(renamed.first?.previousTitles, ["Mine", "Mine again"])
        let found = TaskNavigationProjection.filteredSessions(store.sessions, query: "again")
        XCTAssertEqual(found.map(\.id), [session.id])
        for name in ["1", "2", "3", "4", "5", "6"] {
            try await store.renameSession(id: session.id, title: name, titleOrigin: .manual)
        }
        XCTAssertEqual(store.sessions.first?.previousTitles, ["1", "2", "3", "4", "5"], "Only the last five stay")
    }

    func testTogglePinnedPersistsWithoutChangingTaskRecency() async throws {
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository)
        let session = try await store.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Pin me"
        )

        try await store.togglePinned(id: session.id)

        XCTAssertTrue(store.sessions.first?.isPinned == true)
        XCTAssertEqual(store.sessions.first?.updatedAt, session.updatedAt)
        let persisted = try await repository.loadSessions()
        XCTAssertTrue(persisted.first?.isPinned == true)
    }

    func testProviderOptionPersistsWithTask() async throws {
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository)
        let session = try await store.createSession(
            harness: .antigravityCLI,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/agy"),
            title: "Configured task"
        )

        try await store.updateProviderOption(
            id: session.id,
            optionID: StructuredHeadlessOptionID.reasoningEffort,
            value: "high"
        )

        XCTAssertEqual(
            store.sessions.first?.providerOptions[StructuredHeadlessOptionID.reasoningEffort],
            "high"
        )
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(
            persisted.first?.providerOptions[StructuredHeadlessOptionID.reasoningEffort],
            "high"
        )
    }

    func testUnreadCompletionStatePersistsAndSelectionMarksTaskRead() async throws {
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository)
        let session = try await store.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/example"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Background task"
        )

        try await store.updateSession(
            id: session.id,
            status: .completed,
            hasUnreadUpdate: true
        )
        XCTAssertEqual(store.sessions.first?.completionState, .completed)
        XCTAssertTrue(store.sessions.first?.hasUnreadUpdate == true)
        let unreadPersisted = try await repository.loadSessions()
        XCTAssertEqual(unreadPersisted.first?.hasUnreadUpdate, true)

        await store.markRead(id: session.id)
        XCTAssertFalse(store.sessions.first?.hasUnreadUpdate ?? true)
        let readPersisted = try await repository.loadSessions()
        XCTAssertFalse(readPersisted.first?.hasUnreadUpdate ?? true)
    }

    func testANewTaskInAWorktreeRecordsItsOriginNameAndBranch() async throws {
        let worktree = URL(filePath: "/tmp/trees/blue")
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository) { url in
            url.standardizedFileURL == worktree.standardizedFileURL
                ? WorkspaceGitOrigin(
                    originWorkspacePath: "/tmp/origin-repository",
                    worktreeName: "blue",
                    branch: "blue-branch"
                )
                : WorkspaceGitOrigin(branch: "main")
        }

        let worktreeTask = try await store.createSession(
            harness: .codex,
            workspaceURL: worktree,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Worktree task"
        )
        let plainTask = try await store.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/origin-repository"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Repository task"
        )

        XCTAssertEqual(worktreeTask.originWorkspacePath, "/tmp/origin-repository")
        XCTAssertEqual(worktreeTask.worktreeName, "blue")
        XCTAssertEqual(worktreeTask.branch, "blue-branch")
        XCTAssertEqual(worktreeTask.workspaceURL, worktree, "The worktree stays the task's cwd")
        XCTAssertNil(plainTask.originWorkspacePath, "An ordinary checkout is not a worktree")
        XCTAssertEqual(plainTask.branch, "main")

        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first { $0.id == worktreeTask.id }?.worktreeName, "blue")
    }

    func testOpeningATaskFillsAMissingOriginOnceAndLeavesOtherTasksAlone() async throws {
        let worktree = URL(filePath: "/tmp/trees/green")
        let plainFolder = URL(filePath: "/tmp/plain-repository")
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // Rows written before worktree origin existed: no origin, no name, no branch.
        let existing = SessionRecord(
            harness: .codex,
            workspaceURL: worktree,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Older worktree task",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        let plain = SessionRecord(
            harness: .codex,
            workspaceURL: plainFolder,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Older repository task",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        let repository = InMemorySessionRepository(sessions: [existing, plain])
        var lookups: [String] = []
        let store = SessionStore(sessions: [existing, plain], repository: repository) { url in
            lookups.append(url.path(percentEncoded: false))
            return url.standardizedFileURL == worktree.standardizedFileURL
                ? WorkspaceGitOrigin(
                    originWorkspacePath: plainFolder.path(percentEncoded: false),
                    worktreeName: "green",
                    branch: "green-branch"
                )
                : WorkspaceGitOrigin(branch: "main")
        }

        let filled = try await store.recordWorkspaceOriginIfMissing(id: existing.id)
        XCTAssertEqual(filled?.originWorkspacePath, plainFolder.path(percentEncoded: false))
        XCTAssertEqual(filled?.worktreeName, "green")
        XCTAssertEqual(filled?.branch, "green-branch")
        XCTAssertEqual(filled?.updatedAt, updatedAt, "Filling the origin does not reorder the sidebar")
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first { $0.id == existing.id }?.worktreeName, "green")

        // Opening it again neither rereads the folder nor rewrites the row.
        let lookupsAfterFirstOpen = lookups.count
        let secondOpen = try await store.recordWorkspaceOriginIfMissing(id: existing.id)
        XCTAssertNil(secondOpen)
        XCTAssertEqual(lookups.count, lookupsAfterFirstOpen)

        // An ordinary checkout is left exactly as it was found.
        let plainOpen = try await store.recordWorkspaceOriginIfMissing(id: plain.id)
        XCTAssertNil(plainOpen)
        XCTAssertNil(store.sessions.first { $0.id == plain.id }?.branch)
    }

    /// Archiving one task while another task's status write was waiting on the index used to
    /// write that status into a row position that no longer existed.
    func testAWriteThatOutlivesAnArchiveFindsItsRowAgain() async throws {
        let runtime = URL(filePath: "/tmp/claude")
        let first = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
                                  runtimeExecutableURL: runtime, title: "First")
        let second = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/b"),
                                   runtimeExecutableURL: runtime, title: "Second")
        let repository = GatedSessionRepository(sessions: [first, second])
        let store = SessionStore(sessions: [first, second], repository: repository)
        await repository.holdNextWrite()

        let write = Task { try await store.updateSession(id: second.id, status: .failed) }
        while !(await repository.isWaiting) { await Task.yield() }
        try await store.archiveSession(id: first.id)
        await repository.release()
        try await write.value

        XCTAssertEqual(store.sessions.map(\.id), [second.id])
        XCTAssertEqual(store.sessions.first?.status, .failed)
    }

    /// A title save and a status save that overlap each keep the other's change, in the store
    /// and in the index, instead of the later one writing back the copy it started from.
    func testSavesThatOverlapKeepEachOthersChanges() async throws {
        let task = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/a"),
                                 runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Fallback",
                                 titleOrigin: .automatic, status: .running)
        let repository = GatedSessionRepository(sessions: [task])
        let store = SessionStore(sessions: [task], repository: repository)
        await repository.holdNextWrite()

        let rename = Task { try await store.renameSession(id: task.id, title: "Fix the parser", titleOrigin: .provider) }
        while !(await repository.isWaiting) { await Task.yield() }
        try await store.updateSession(id: task.id, status: .completed)
        await repository.release()
        try await rename.value

        let current = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(current.title, "Fix the parser")
        XCTAssertEqual(current.status, .completed)
        XCTAssertEqual(current.completionState, .completed)
        let saved = await repository.record(task.id)
        XCTAssertEqual(saved, current, "The index ends with both changes too")
    }

    /// A save that lands after its task was archived or deleted leaves it archived or deleted;
    /// before, the index's save put the task back on the next launch.
    func testALateSaveLeavesAnArchivedOrDeletedTaskThere() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-late-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = URL(filePath: "/tmp/claude")
        var archived = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
                                     runtimeExecutableURL: runtime, title: "Archived")
        var deleted = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/b"),
                                    runtimeExecutableURL: runtime, title: "Deleted")
        let repositories: [any SessionRepository] = [
            try SQLiteSessionRepository(databaseURL: root.appending(path: "sessions.sqlite3")),
            InMemorySessionRepository()
        ]
        for repository in repositories {
            try await repository.upsert(archived)
            try await repository.upsert(deleted)
            try await repository.archive(id: archived.id, providerArchived: false)
            try await repository.discard(id: deleted.id)
            archived.status = .failed
            deleted.status = .failed
            try await repository.upsert(archived)
            try await repository.upsert(deleted)

            let active = try await repository.loadSessions()
            XCTAssertEqual(active, [], "\(type(of: repository))")
            let archivedList = try await repository.loadArchivedSessions()
            XCTAssertEqual(archivedList.map(\.id), [archived.id])
            let restored = try await repository.unarchive(id: archived.id)
            XCTAssertEqual(restored?.status, .failed, "The late save's fields are kept for when it is restored")
        }
    }
}

/// An index whose next write waits until the test lets it finish.
private actor GatedSessionRepository: SessionRepository {
    private var stored: [UUID: SessionRecord] = [:]
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private var holdsNextWrite = false

    init(sessions: [SessionRecord]) {
        stored = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    func holdNextWrite() { holdsNextWrite = true }
    func release() { gate?.resume(); gate = nil }

    func loadSessions() async throws -> [SessionRecord] { Array(stored.values) }
    func record(_ id: UUID) -> SessionRecord? { stored[id] }
    func upsert(_ session: SessionRecord) async throws {
        if holdsNextWrite {
            holdsNextWrite = false
            isWaiting = true
            await withCheckedContinuation { gate = $0 }
            isWaiting = false
        }
        stored[session.id] = session
    }
    func archive(id: UUID) async throws {}
}
