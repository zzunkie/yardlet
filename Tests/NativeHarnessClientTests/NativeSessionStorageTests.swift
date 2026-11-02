import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class NativeSessionStorageTests: XCTestCase {
    func testNewTaskRestartAndSideChatUseOriginalHomeAndPersistedIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = try fixture.model()
        addTeardownBlock { await model.shutdown() }
        await model.restoreIndex()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.runtimeHomeURL.path()))
        let created = await model.createSession(
            harness: .codex, workspaceURL: fixture.root,
            runtimeExecutableURL: fixture.executable, title: "Native task"
        )
        let session = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Task not created")
        XCTAssertEqual(session.environmentScope, .native)
        let providerID = try XCTUnwrap(session.providerSessionID)
        let providerFile = fixture.paths.nativeHomeURL.appending(path: "fixture-sessions/\(providerID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerFile.path()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.runtimeHomeURL.path()))
        await model.shutdown()

        // An external client changes the provider's persisted record between Yardlet launches.
        var external = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: providerFile))
            .objectValue ?? [:]
        external["name"] = .string("Changed outside Yardlet")
        try JSONEncoder().encode(JSONValue.object(external)).write(to: providerFile)
        let eventCount = try fixture.events().count
        let reopened = try fixture.model()
        addTeardownBlock { await reopened.shutdown() }
        await reopened.restoreIndex()
        XCTAssertEqual(try fixture.events().count, eventCount, "Restoring the index must not wake Codex")
        let restored = try XCTUnwrap(reopened.store.sessions.first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.providerSessionID, providerID)
        await reopened.resume(restored)
        XCTAssertNil(reopened.errorBySessionID[restored.id])
        XCTAssertTrue(reopened.isAttached(restored.id))
        try await waitUntil { reopened.codexPresentationBySessionID[restored.id]?.thread != nil }
        XCTAssertEqual(reopened.codexPresentationBySessionID[restored.id]?.thread?.name, "Changed outside Yardlet")
        let side = await reopened.branch(restored, placement: .sidePanel)
        let child = try XCTUnwrap(side, reopened.sideChatErrors[restored.id] ?? "Fork missing")
        XCTAssertEqual(child.environmentScope, .native)
        XCTAssertNotEqual(child.providerSessionID, providerID)
        let events = try fixture.events()
        XCTAssertTrue(events.contains { $0["method"] == .string("thread/resume") && $0["threadId"] == .string(providerID) })
        // A side chat's thread is ephemeral, as the Codex app's: nothing of it is written to the home.
        XCTAssertTrue(events.contains { $0["method"] == .string("thread/fork") && $0["ephemeral"] == .bool(true) })
        let sideThread = try XCTUnwrap(child.providerSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.nativeHomeURL
            .appending(path: "fixture-sessions/\(sideThread).json").path()))
        let forked = await reopened.branch(restored)
        XCTAssertNotNil(forked)
        XCTAssertTrue(try fixture.events().contains { $0["method"] == .string("thread/fork") && $0["ephemeral"] == .bool(false) },
                      "A fork into a task is saved as always")
        XCTAssertTrue(events.allSatisfy { $0["home"]?.stringValue == fixture.paths.nativeHomeURL.path(percentEncoded: false) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.runtimeHomeURL.path()))
        await reopened.shutdown()
    }

    func testExistingIsolatedTaskKeepsHomeThroughSQLiteRestoreResumeAndFork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let registry = HarnessRegistry(codexEnvironmentManager: fixture.manager)
        let legacy = await registry.adapter(for: .codex, executableURL: fixture.executable, environmentScope: .yardlet)
        let oldID = UUID()
        let handle = try await legacy.createSession(.init(localSessionID: oldID, workspaceURL: fixture.root, initialPrompt: nil))
        addTeardownBlock { await legacy.close(handle) }
        await legacy.close(handle)
        let old = SessionRecord(id: oldID, harness: .codex, workspaceURL: fixture.root,
            runtimeExecutableURL: fixture.executable, title: "Existing isolated task",
            providerSessionID: handle.providerSessionID, environmentScope: .yardlet)
        try await SQLiteSessionRepository(databaseURL: fixture.database).upsert(old)

        let model = try fixture.model()
        addTeardownBlock { await model.shutdown() }
        await model.restoreIndex()
        let restored = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(restored.environmentScope, .yardlet)
        await model.resume(restored)
        XCTAssertTrue(model.isAttached(restored.id))
        XCTAssertNil(model.errorBySessionID[restored.id])
        let side = await model.branch(restored, placement: .sidePanel)
        XCTAssertEqual(side?.environmentScope, .yardlet)
        XCTAssertNotNil(side?.providerSessionID)
        let observedHomes = try fixture.events().compactMap { $0["home"]?.stringValue }
        XCTAssertTrue(try fixture.events().allSatisfy {
            URL(filePath: $0["home"]?.stringValue ?? "/missing").standardizedFileURL.path
                == fixture.paths.runtimeHomeURL.standardizedFileURL.path
        }, "Observed homes: \(observedHomes), expected: \(fixture.paths.runtimeHomeURL.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.paths.nativeHomeURL.appending(path: "fixture-sessions").path()))

        // Identical provider IDs in different homes are different stored sessions. Importing
        // native history must not accidentally select an old isolated task with that ID.
        let relativePath = "fixture-sessions/\(handle.providerSessionID).json"
        let nativeFile = fixture.paths.nativeHomeURL.appending(path: relativePath)
        try FileManager.default.createDirectory(at: nativeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.paths.runtimeHomeURL.appending(path: relativePath), to: nativeFile)
        model.runtimeSelections.select(fixture.executable, for: .codex)
        let conversation = ImportableConversation(codex: .init(id: handle.providerSessionID, title: "Native import",
            preview: "", workspaceURL: fixture.root, updatedAt: Date(), forkedFromID: nil))
        XCTAssertNil(model.existingTask(for: conversation, connection: restored.connection))
        await model.importConversation(conversation, connection: restored.connection)
        let imported = try XCTUnwrap(model.store.selectedSession)
        XCTAssertNotEqual(imported.id, restored.id)
        XCTAssertEqual(imported.environmentScope, .native)
        XCTAssertEqual(imported.providerSessionID, restored.providerSessionID)
        // The import is detached; continuing it resumes the thread in the native home.
        XCTAssertFalse(model.isAttached(imported.id))
        await model.resume(imported)
        XCTAssertTrue(model.isAttached(imported.id))
        XCTAssertTrue(try fixture.events().contains {
            $0["method"] == .string("thread/resume")
                && $0["home"]?.stringValue == fixture.paths.nativeHomeURL.path(percentEncoded: false)
        })
        await model.shutdown()
    }

    func testAccountSnapshotAndMonitorUseSameNativeHomeAsTasks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let broker = HarnessAccountBroker(codexEnvironmentManager: fixture.manager)
        addTeardownBlock { await broker.stopCodexAccountUpdates() }
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .codex))
        let snapshot = await broker.snapshot(for: descriptor, executableURL: fixture.executable)
        XCTAssertEqual(snapshot.state, .signedOut)
        _ = try await broker.startCodexAccountUpdates(executableURL: fixture.executable)
        await broker.stopCodexAccountUpdates()
        let events = try fixture.events()
        XCTAssertEqual(events.filter { $0["method"] == .string("account/read") }.count, 2)
        XCTAssertTrue(events.allSatisfy { $0["home"]?.stringValue == fixture.paths.nativeHomeURL.path(percentEncoded: false) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.runtimeHomeURL.path()))
    }

    @MainActor
    func testThreeAccountBindingsSurviveRestartAndForkWithoutChangingNativeHome() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = try fixture.model()
        await model.restoreIndex()
        var created: [SessionRecord] = []
        for name in ["Account A", "Account B", "Account C"] {
            let home = fixture.root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let connection = ProviderConnection(id: name, name: name, harness: .codex,
                providerID: nil, homePath: home.path(percentEncoded: false), credentialSelector: nil)
            let value = await model.createSession(harness: .codex, workspaceURL: fixture.root,
                runtimeExecutableURL: fixture.executable, title: name, connection: connection)
            let session = try XCTUnwrap(value, model.errorBySessionID.values.first ?? "missing")
            XCTAssertEqual(session.connection, connection)
            let id = try XCTUnwrap(session.providerSessionID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "fixture-sessions/\(id).json").path()))
            created.append(session)
        }
        await model.shutdown()
        let reopened = try fixture.model()
        await reopened.restoreIndex()
        for original in created {
            let restored = try XCTUnwrap(reopened.store.sessions.first { $0.id == original.id })
            XCTAssertEqual(restored.connection, original.connection)
            await reopened.resume(restored)
            XCTAssertNil(reopened.errorBySessionID[restored.id])
            let fork = await reopened.branch(restored, placement: .sidePanel)
            XCTAssertEqual(fork?.connection, restored.connection)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.nativeHomeURL.appending(path: "fixture-sessions").path()))
        await reopened.shutdown()
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let database: URL
        let paths: CodexEnvironmentPaths
        let manager: CodexEnvironmentManager
        let defaults: UserDefaults

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "yardlet-native-session-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appending(path: "codex")
            database = root.appending(path: "session-index.sqlite3")
            paths = .init(nativeHomeURL: root.appending(path: "native"), yardletRootURL: root.appending(path: "yardlet"))
            manager = CodexEnvironmentManager(paths: paths)
            defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.NativeSessionStorageTests")))
            let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "scripts/fixtures/codex-session-home.py")
            // Pin the interpreter so fixtures do not depend on GUI or shell PATH discovery.
            let script = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path())
        }

        @MainActor func model() throws -> AppModel {
            AppModel(store: SessionStore(repository: try SQLiteSessionRepository(databaseURL: database)),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
                codexEnvironmentManager: manager,
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")))
        }

        func events() throws -> [JSONValue] {
            try String(contentsOf: root.appending(path: "home-events.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
