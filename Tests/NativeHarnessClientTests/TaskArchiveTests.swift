import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class TaskArchiveTests: XCTestCase {
    private let connection = ProviderConnection(id: "codex-work", name: "Work", harness: .codex,
        providerID: nil, homePath: "/tmp/yardlet-archive-test-codex-home", credentialSelector: nil)

    private func codexTask(
        title: String = "Archived Codex task",
        threadID: String = "codex-thread-archived",
        projectID: UUID? = nil,
        status: SessionStatus = .completed
    ) -> SessionRecord {
        SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/archive-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: title,
            titleOrigin: .provider,
            status: status,
            // Whole seconds survive the index's REAL columns exactly.
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            providerSessionID: threadID,
            isPinned: true,
            providerOptions: ["model": "gpt-5.6-codex"],
            environmentScope: .yardlet,
            connection: connection,
            projectID: projectID,
            additionalRoots: ["/tmp/archive-extra-root"]
        )
    }

    /// A stand-in `codex` that only answers `--version`, so the runtime check passes without a
    /// real runtime, account, or model.
    private func fakeCodexExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-archive-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "codex")
        try Data("#!/bin/sh\necho 'codex-cli 0.160.0'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path())
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return executable
    }

    // MARK: - Index

    func testSQLiteListsArchivedTasksAndRestoresThemUnchangedWhileDeletedTasksStayHidden() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "sessions.sqlite3")
        let project = UUID()
        let archived = codexTask(projectID: project)
        let older = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/archive-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Older archive",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), providerSessionID: "claude-session")
        let deleted = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/archive-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Deleted")
        let active = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/archive-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Active")
        let repository = try SQLiteSessionRepository(databaseURL: database)
        for session in [archived, older, deleted, active] { try await repository.upsert(session) }

        try await repository.archive(id: older.id)
        try await repository.archive(id: archived.id, providerArchived: true)
        try await repository.discard(id: deleted.id)

        let reopened = try SQLiteSessionRepository(databaseURL: database)
        let loaded = try await reopened.loadSessions()
        XCTAssertEqual(loaded.map(\.id), [active.id])
        let list = try await reopened.loadArchivedSessions()
        XCTAssertEqual(list.map(\.id), [archived.id, older.id], "Most recently archived first; deleted tasks are not listed")
        XCTAssertEqual(list.first?.isProviderArchived, true)
        XCTAssertEqual(list.last?.isProviderArchived, false)
        XCTAssertNotNil(list.first?.archivedAt)
        XCTAssertEqual(list.first?.session, archived)

        let restored = try await reopened.unarchive(id: archived.id)
        XCTAssertEqual(restored, archived, "Provider session, scope, account, project, roots, and pin come back as they were")
        let restoredAgain = try await reopened.unarchive(id: archived.id)
        XCTAssertNil(restoredAgain)
        let deletedRestore = try await reopened.unarchive(id: deleted.id)
        XCTAssertNil(deletedRestore, "A deleted task cannot be brought back as an archived one")
        let afterRestore = try await reopened.loadSessions()
        XCTAssertEqual(Set(afterRestore.map(\.id)), [active.id, archived.id])
        let remaining = try await reopened.loadArchivedSessions()
        XCTAssertEqual(remaining.map(\.id), [older.id])
    }

    func testStoreRestoresAnArchivedTaskInRecencyOrderAndReadyWithoutTouchingTheList() async throws {
        let newer = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let older = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let archivedMidTurn = codexTask(status: .running)
        let repository = InMemorySessionRepository(sessions: [newer, archivedMidTurn, older])
        let store = SessionStore(sessions: [newer, archivedMidTurn, older], repository: repository)
        XCTAssertNil(store.archivedSessions)

        try await store.loadArchivedSessions()
        XCTAssertEqual(store.archivedSessions, [])
        try await store.archiveSession(id: archivedMidTurn.id, providerArchived: true)
        XCTAssertEqual(store.sessions.map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.archivedSessions?.map(\.id), [archivedMidTurn.id])
        XCTAssertEqual(store.archivedSessions?.first?.isProviderArchived, true)

        try await store.discardSession(id: older.id)
        XCTAssertEqual(store.archivedSessions?.map(\.id), [archivedMidTurn.id])

        let selected = store.selectedSessionID
        let unarchived = try await store.unarchiveSession(id: archivedMidTurn.id)
        let restored = try XCTUnwrap(unarchived)
        XCTAssertEqual(restored.status, .ready, "No turn runs for a restored task")
        XCTAssertEqual(restored.providerSessionID, archivedMidTurn.providerSessionID)
        XCTAssertEqual(restored.connection, archivedMidTurn.connection)
        XCTAssertEqual(restored.environmentScope, .yardlet)
        XCTAssertEqual(store.sessions.map(\.id), [newer.id, archivedMidTurn.id])
        XCTAssertEqual(store.archivedSessions, [])
        XCTAssertEqual(store.selectedSessionID, selected, "Restoring does not open the task")
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first { $0.id == archivedMidTurn.id }?.status, .ready)

        try await store.loadArchivedSessions()
        let stale = try await store.unarchiveSession(id: older.id)
        XCTAssertNil(stale, "A deleted task is not restored")
        XCTAssertFalse(store.sessions.contains { $0.id == older.id })
    }

    // MARK: - Provider boundary

    func testRestoringATaskYardletArchivedInCodexUnarchivesTheThreadWithoutResumingIt() async throws {
        let executable = try fakeCodexExecutable()
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/unarchive": [.object(["thread": .object(["id": .string("codex-thread-archived")])])]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let repository = InMemorySessionRepository()
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        let project = model.projects.ensureProject(forRoot: URL(filePath: "/tmp/archive-project"))
        model.projects.hide(project.id)
        var session = codexTask(projectID: project.id)
        session.runtimeExecutableURL = executable
        try await repository.upsert(session)
        try await repository.archive(id: session.id, providerArchived: true)
        await model.loadArchivedTasks()
        let record = try XCTUnwrap(model.store.archivedSessions?.first)

        await model.unarchive(record)

        XCTAssertNil(model.archivedTaskError)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["initialize", "thread/unarchive"])
        XCTAssertEqual(requests.last?.params["threadId"]?.stringValue, "codex-thread-archived")
        let restored = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(restored, session)
        XCTAssertFalse(model.isAttached(session.id), "Restoring does not attach or resume the task")
        XCTAssertEqual(model.store.archivedSessions, [])
        XCTAssertEqual(model.projects.project(id: project.id)?.isHidden, false, "Its hidden project comes back too")
        XCTAssertTrue(model.unarchivingSessionIDs.isEmpty)
    }

    func testRestoringATaskYardletOnlyArchivedLocallyLeavesTheProviderAlone() async throws {
        let transport = FakeCodexTransport(responses: [:])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let session = codexTask()
        let repository = InMemorySessionRepository(sessions: [session])
        try await repository.archive(id: session.id, providerArchived: false)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await model.loadArchivedTasks()
        let record = try XCTUnwrap(model.store.archivedSessions?.first)

        await model.unarchive(record)

        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "No runtime wakes for a thread Yardlet never archived in Codex")
        XCTAssertEqual(model.store.sessions, [session])
    }

    func testAFailedProviderUnarchiveKeepsTheTaskArchived() async throws {
        let executable = try fakeCodexExecutable()
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])]
        ])
        let adapter = CodexAdapter(executableURL: executable, transport: transport)
        var session = codexTask()
        session.runtimeExecutableURL = executable
        let repository = InMemorySessionRepository(sessions: [session])
        try await repository.archive(id: session.id, providerArchived: true)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await model.loadArchivedTasks()
        let record = try XCTUnwrap(model.store.archivedSessions?.first)

        await model.unarchive(record)

        XCTAssertNotNil(model.archivedTaskError)
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertEqual(model.store.archivedSessions?.map(\.id), [session.id])
        let stillArchived = try await repository.loadArchivedSessions()
        XCTAssertEqual(stillArchived.first?.isProviderArchived, true, "A retry still unarchives the thread")
    }

    func testArchivingAnAttachedCodexTaskRecordsTheProviderArchive() async throws {
        let executable = try fakeCodexExecutable()
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("codex-thread-attached")])])],
            "thread/archive": [.object([:])]
        ])
        let adapter = CodexAdapter(executableURL: executable, transport: transport)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/archive-attached"),
            runtimeExecutableURL: executable, title: "Attached")
        let session = try XCTUnwrap(created)
        XCTAssertTrue(model.isAttached(session.id))
        await model.loadArchivedTasks()

        await model.archive(session)

        let methods = await transport.requestMethods
        XCTAssertEqual(methods.last, "thread/archive")
        XCTAssertEqual(model.store.archivedSessions?.map(\.id), [session.id])
        XCTAssertEqual(model.store.archivedSessions?.first?.isProviderArchived, true)
        await model.shutdown()
    }

    func testArchiveListsTheTaskAndDeleteDoesNot() async throws {
        let archived = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Archive me", providerSessionID: "claude-a")
        let deleted = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/a"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Delete me", providerSessionID: "claude-b")
        let repository = InMemorySessionRepository(sessions: [archived, deleted])
        let model = AppModel(
            store: SessionStore(sessions: [archived, deleted], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            restoresIndexOnLaunch: false
        )
        await model.loadArchivedTasks()

        await model.archive(archived)
        await model.delete(deleted)

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertEqual(model.store.archivedSessions?.map(\.id), [archived.id])
        XCTAssertEqual(model.store.archivedSessions?.first?.isProviderArchived, false)
        let persisted = try await repository.loadArchivedSessions()
        XCTAssertEqual(persisted.map(\.id), [archived.id])
    }

    // MARK: - Reading an archived task

    /// An archived Codex task's thread opens from the archived list as a detached task's does, through
    /// the App Server of its account and scope: `thread/read` and the newest page of turns, then the
    /// page before as the person scrolls up (codex-cli 0.166.0 answers both for a thread in
    /// `archived_sessions`). The thread is not unarchived or resumed, no turn starts, the task stays
    /// archived and the model keeps no Codex state for it. A harness whose saved conversations
    /// Yardlet does not read says so and reads nothing.
    func testAnArchivedTaskShowsItsConversationWithoutUnarchivingOrResumingIt() async throws {
        let executable = try fakeCodexExecutable()
        func turn(_ index: Int) -> JSONValue {
            .object(["id": .string("turn-\(index)"), "status": .string("completed"), "durationMs": .integer(1_000),
                     "startedAt": .integer(1_700_000_000 + Int64(index)), "itemsView": .string("full"),
                     "completedAt": .integer(1_700_000_001 + Int64(index)), "error": .null, "items": .array([
                        .object(["id": .string("user-\(index)"), "type": .string("userMessage"), "content": .array([
                            .object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                        .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                                 "text": .string("Answer \(index)"), "phase": .string("final_answer")])])])
        }
        let thread = JSONValue.object([
            "id": .string("codex-thread-archived"), "status": .object(["type": .string("notLoaded")]),
            "historyMode": .string("paginated"), "cwd": .string("/tmp/archive-project"),
            "preview": .string("Request 1"), "turns": .array((1...7).map(turn))])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/read": [CodexSavedThreadResponses.metadata(thread)],
            "thread/turns/list": [CodexSavedThreadResponses.page(thread, limit: Int(CodexThreadPaging.newestTurns)),
                                  CodexSavedThreadResponses.page(thread, before: "before-2",
                                                                 limit: Int(CodexThreadPaging.earlierTurns))]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        var session = codexTask()
        session.runtimeExecutableURL = executable
        session.connection = ProviderConnection(id: "codex-work", name: "Work", harness: .codex, providerID: nil,
            homePath: executable.deletingLastPathComponent().path, credentialSelector: nil)
        let repository = InMemorySessionRepository(sessions: [session])
        try await repository.archive(id: session.id, providerArchived: true)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive")))),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await model.loadArchivedTasks()
        let record = try XCTUnwrap(model.store.archivedSessions?.first)

        let reading = ArchivedTaskReading(record: record)
        await model.readArchivedConversation(reading)
        XCTAssertEqual(reading.outcome, .shown)
        XCTAssertEqual(reading.codexState?.thread?.turns.map(\.id), (3...7).map { "turn-\($0)" }, "the newest page")
        XCTAssertTrue(reading.hasEarlierHistory)
        await model.readEarlierArchivedHistory(reading)
        XCTAssertEqual(reading.codexState?.thread?.turns.map(\.id), (1...7).map { "turn-\($0)" })
        XCTAssertFalse(reading.hasEarlierHistory)

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["initialize", "thread/read", "thread/turns/list", "thread/turns/list"],
                       "no thread/unarchive, thread/resume or turn")
        XCTAssertEqual(requests[1].params["threadId"]?.stringValue, "codex-thread-archived")
        XCTAssertTrue(model.store.sessions.isEmpty, "the task stays archived")
        XCTAssertEqual(model.store.archivedSessions?.map(\.id), [session.id])
        XCTAssertEqual(model.store.archivedSessions?.first?.isProviderArchived, true)
        XCTAssertNil(model.codexPresentationBySessionID[session.id])
        XCTAssertNil(model.transcriptBySessionID[session.id])
        XCTAssertFalse(model.isAttached(session.id))

        let pi = ArchivedTaskReading(record: ArchivedSessionRecord(
            session: SessionRecord(harness: .pi, workspaceURL: URL(filePath: "/tmp/archive-project"),
                runtimeExecutableURL: URL(filePath: "/tmp/pi"), title: "Pi task", providerSessionID: "pi-session"),
            archivedAt: nil, isProviderArchived: false))
        XCTAssertEqual(pi.outcome, .unsupported)
        await model.readArchivedConversation(pi)
        XCTAssertEqual(pi.outcome, .unsupported)
        let after = await transport.requests
        XCTAssertEqual(after.count, requests.count)
    }

    func testCodexThreadUnarchiveIsATypedRequestByThreadID() {
        let request = CodexProtocol.unarchiveThread(id: 9, threadID: "thread-1")
        XCTAssertEqual(request.method, "thread/unarchive")
        XCTAssertEqual(request.params["threadId"]?.stringValue, "thread-1")
    }

    // MARK: - Lifecycle capability

    /// The provider side follows the adapter's `HarnessSessionLifecycleProviding`, not the
    /// harness name: the same harness reaches the provider with it and stays local without it.
    func testAttachedTaskReachesTheProviderLifecycleOnlyWhenItsAdapterProvidesOne() async throws {
        for providesLifecycle in [true, false] {
            let adapter: any HarnessAdapter = providesLifecycle
                ? LifecycleStubAdapter(kind: .openCode) : SessionStubAdapter(kind: .openCode)
            let model = AppModel(
                store: SessionStore(repository: InMemorySessionRepository()),
                runtimeSelections: RuntimeSelectionStore(
                    defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Archive"))),
                    discoversRuntimes: false
                ),
                registry: HarnessRegistry { _, _ in adapter },
                sessionTitleResolver: { _ in nil },
                restoresIndexOnLaunch: false
            )
            await model.loadArchivedTasks()
            let createdKept = await model.createSession(harness: .openCode,
                workspaceURL: URL(filePath: "/tmp/archive-lifecycle"),
                runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Kept")
            let createdDeleted = await model.createSession(harness: .openCode,
                workspaceURL: URL(filePath: "/tmp/archive-lifecycle"),
                runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Deleted")
            let kept = try XCTUnwrap(createdKept)
            let deleted = try XCTUnwrap(createdDeleted)
            XCTAssertTrue(model.isAttached(kept.id))

            await model.rename(kept, to: "Renamed")
            await model.delete(deleted)
            await model.archive(kept)
            let record = try XCTUnwrap(model.store.archivedSessions?.first)
            XCTAssertEqual(record.isProviderArchived, providesLifecycle)
            await model.unarchive(record)

            XCTAssertNil(model.archivedTaskError)
            XCTAssertNil(model.bootstrapError)
            XCTAssertEqual(model.store.sessions.map(\.title), ["Renamed"])
            XCTAssertEqual(model.store.archivedSessions, [])
            let calls = await (adapter as? LifecycleStubAdapter)?.calls ?? []
            XCTAssertEqual(calls, providesLifecycle ? [
                "rename \(kept.id) Renamed",
                "delete \(deleted.id)",
                "archive \(kept.id)",
                "unarchive stub-\(kept.id)"
            ] : [])
            await model.shutdown()
        }
    }
}

/// An attached session that answers nothing, so the task stays attached until it is closed.
private actor SessionStubAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]

    init(kind: HarnessKind) { self.kind = kind }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"),
            version: "stub", capabilities: .unavailable, fingerprint: "stub")
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
            providerSessionID: "stub-\(request.localSessionID)", workspaceURL: request.workspaceURL)
    }

    func resumeSession(providerSessionID: String, localSessionID: UUID,
                       workspaceURL: URL) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(harness: kind, localSessionID: localSessionID,
            providerSessionID: providerSessionID, workspaceURL: workspaceURL)
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision,
                 in session: HarnessSessionHandle) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
        continuations[session.localSessionID] = continuation
        return stream
    }

    func close(_ session: HarnessSessionHandle) async {
        continuations.removeValue(forKey: session.localSessionID)?.finish()
    }
}

/// The same session, with a provider that keeps its own sessions and records what reached it.
private actor LifecycleStubAdapter: HarnessAdapter, HarnessSessionLifecycleProviding {
    nonisolated let kind: HarnessKind
    private let session: SessionStubAdapter
    private(set) var calls: [String] = []

    init(kind: HarnessKind) {
        self.kind = kind
        session = SessionStubAdapter(kind: kind)
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor { try await session.probeRuntime() }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        try await session.createSession(request)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID,
                       workspaceURL: URL) async throws -> HarnessSessionHandle {
        try await session.resumeSession(providerSessionID: providerSessionID,
            localSessionID: localSessionID, workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to handle: HarnessSessionHandle) async throws {}
    func interrupt(_ handle: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision,
                 in handle: HarnessSessionHandle) async throws {}
    func events(for handle: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        await session.events(for: handle)
    }
    func close(_ handle: HarnessSessionHandle) async { await session.close(handle) }

    func archiveProviderSession(_ handle: HarnessSessionHandle) async throws {
        calls.append("archive \(handle.localSessionID)")
    }

    func unarchiveProviderSession(providerSessionID: String) async throws {
        calls.append("unarchive \(providerSessionID)")
    }

    func deleteProviderSession(_ handle: HarnessSessionHandle) async throws {
        calls.append("delete \(handle.localSessionID)")
    }

    func renameProviderSession(_ handle: HarnessSessionHandle, to title: String) async throws {
        calls.append("rename \(handle.localSessionID) \(title)")
    }
}
