import XCTest
@testable import NativeHarnessClient

@MainActor
final class ComposerDraftPersistenceTests: XCTestCase {
    private func fileRepository() throws -> FileComposerDraftRepository {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-drafts-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return FileComposerDraftRepository(directoryURL: directory)
    }

    private func model(repository: any ComposerDraftRepository,
                       sessions: any SessionRepository = InMemorySessionRepository()) -> AppModel {
        let defaults = UserDefaults(suiteName: testDefaultsSuite("yardlet-draft-tests"))!
        return AppModel(
            store: SessionStore(repository: sessions),
            runtimeSelections: RuntimeSelectionStore(
                defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false
            ),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            composerDraftRepository: repository,
            sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0,
            isVisualFixture: true
        )
    }

    private func session() -> SessionRecord {
        SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/draft-project"),
                      runtimeExecutableURL: URL(filePath: "/tmp/no-runtime"), title: "Draft owner")
    }

    func testDiskRoundTripPreservesExactInputAndEveryTypedAttachment() throws {
        let repository = try fileRepository()
        let id = UUID(), otherID = UUID()
        let text = "  한글 👩🏽‍💻\n    indentation\n\n"
        let attachments: [CodexUserInput] = [
            .localImage(URL(filePath: "/missing/이미지.png"), detail: .original),
            .image(URL(string: "https://example.test/image.png")!),
            .localAudio(URL(filePath: "/missing/audio.wav")),
            .audio(URL(string: "https://example.test/audio.wav")!),
            .mention(name: "Sources", path: URL(filePath: "/missing/Sources")),
            .skill(name: "Review", path: URL(filePath: "/missing/SKILL.md")),
            .unknown(.object(["type": .string("future-input"), "payload": .array([.integer(42), .number(42.5)])]))
        ]
        let first = ComposerDrafts(repository: repository)
        first.tasks.draft(for: id).text = text
        first.tasks.draft(for: id).attachments = attachments
        first.tasks.draft(for: otherID).text = "Separate task"
        first.home.text = "  A home draft\n"
        first.home.workspaceURL = URL(filePath: "/tmp/다른 프로젝트")
        first.home.harness = .openCode
        first.persistNow()

        let restarted = ComposerDrafts(repository: repository)
        XCTAssertEqual(restarted.tasks.draft(for: id).text, text)
        XCTAssertEqual(restarted.tasks.draft(for: id).attachments, attachments)
        XCTAssertNil(restarted.tasks.draft(for: id).notice)
        XCTAssertEqual(restarted.tasks.draft(for: otherID).text, "Separate task")
        XCTAssertEqual(restarted.home.snapshot, first.home.snapshot)
        XCTAssertTrue(restarted.home.wasRestored)
        XCTAssertNil(restarted.storageFailure)
    }

    func testMissingFileIsAnEmptyDraftWithoutCreatingStorageOnLaunch() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        drafts.persistNow()
        XCTAssertNil(drafts.storageFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.fileURL.path))
    }

    func testPrivatePermissionsSurviveAtomicReplacement() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        for text in ["first", "replacement"] {
            drafts.home.text = text
            drafts.persistNow()
            StateFileWriter.shared.flush()
            let file = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
            let directory = try FileManager.default.attributesOfItem(atPath: repository.directoryURL.path)
            XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testInterruptedHomeStartRestoresUnsentAndDoesNotChooseAnotherHarness() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        drafts.home.text = "A pending start"
        drafts.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/original"),
                            availableHarnesses: [.openCode])
        XCTAssertNotNil(drafts.home.beginSubmission(runtimeURL: URL(filePath: "/tmp/runtime")))
        drafts.persistNow()
        let restarted = ComposerDrafts(repository: repository)
        restarted.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/another"),
                               availableHarnesses: [.codex])
        XCTAssertFalse(restarted.home.isCreating)
        XCTAssertFalse(restarted.home.creationFailed)
        XCTAssertEqual(restarted.home.text, "A pending start")
        XCTAssertEqual(restarted.home.harness, .openCode)
        XCTAssertEqual(restarted.home.workspaceURL, URL(filePath: "/tmp/original"))
        XCTAssertFalse(restarted.home.canCreate(runtimeURL: nil))
    }

    func testExplicitlyClearedProjectAndUnknownHarnessAreNotReplacedOnRestart() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        drafts.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/old"), availableHarnesses: [])
        drafts.home.workspaceURL = nil
        drafts.home.harness = HarnessKind(rawValue: "future-harness")
        drafts.home.text = "Choose where this goes"
        drafts.persistNow()
        let restarted = ComposerDrafts(repository: repository)
        restarted.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/default"), availableHarnesses: [.codex])
        XCTAssertNil(restarted.home.workspaceURL)
        XCTAssertEqual(restarted.home.harness?.rawValue, "future-harness")
    }

    func testSuccessfulHomeStartStaysClearedAfterRestart() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        drafts.home.text = "Start this"
        drafts.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/project"), availableHarnesses: [.codex])
        let submission = try XCTUnwrap(drafts.home.beginSubmission(runtimeURL: URL(filePath: "/tmp/runtime")))
        drafts.persistNow()
        drafts.home.complete(submission, succeeded: true)
        drafts.persistNow()
        let restarted = ComposerDrafts(repository: repository)
        XCTAssertEqual(restarted.home.text, "")
        XCTAssertFalse(restarted.home.wasRestored)
        XCTAssertEqual(restarted.home.harness, .codex)
    }

    func testHomeAttachmentsPersistAndLeaveWithASuccessfulStart() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository)
        let attachments: [CodexUserInput] = [
            .localImage(URL(filePath: "/tmp/pasted/image.png"), detail: .auto),
            .mention(name: "README.md", path: URL(filePath: "/repo/README.md"))
        ]
        drafts.home.text = "Look at this"
        drafts.home.attachments = attachments
        drafts.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/project"), availableHarnesses: [.codex])
        drafts.persistNow()
        XCTAssertEqual(ComposerDrafts(repository: repository).home.attachments, attachments)

        let submission = try XCTUnwrap(drafts.home.beginSubmission(runtimeURL: URL(filePath: "/tmp/runtime")))
        XCTAssertEqual(submission.attachments, attachments)
        drafts.home.complete(submission, succeeded: true)
        drafts.persistNow()
        XCTAssertEqual(drafts.home.attachments, [])
        XCTAssertEqual(ComposerDrafts(repository: repository).home.attachments, [])

        // A home draft saved before attachments existed still loads.
        let older = try JSONDecoder().decode(HomeDraftSnapshot.self, from: Data(#"{"text":"Old","hasPreparedWorkspace":false}"#.utf8))
        XCTAssertEqual(older.text, "Old")
        XCTAssertNil(older.attachments)
    }

    func testDebounceSavesLatestAndClearingCannotResurrectOlderInput() async throws {
        let repository = InMemoryComposerDraftRepository()
        let drafts = ComposerDrafts(repository: repository, saveDelay: .milliseconds(20))
        let id = UUID()
        for index in 0..<100 { drafts.tasks.draft(for: id).text = "Input \(index)" }
        try await waitUntil { repository.snapshot.tasks[id] != nil }
        XCTAssertEqual(repository.snapshot.tasks[id]?.text, "Input 99")
        drafts.tasks.draft(for: id).text = "Immediate pending edit"
        drafts.tasks.draft(for: id).clear()
        drafts.persistNow()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(ComposerDrafts(repository: repository).tasks.draft(for: id).submission.isEmpty)
    }

    func testASaveNeverWaitsForTheDiskAndQuittingWaitsForTheSave() throws {
        let repository = try fileRepository()
        let drafts = ComposerDrafts(repository: repository, saveDelay: .seconds(60))
        // A write that holds the writer stands for a disk that takes a second to sync a file.
        let disk = DispatchSemaphore(value: 0)
        StateFileWriter.shared.write(repository.directoryURL.appending(path: "busy")) { _ = disk.wait(timeout: .now() + 10) }
        drafts.home.text = "Typed just before quitting"
        drafts.persistNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.fileURL.path),
                       "the draft is written on the writer's queue, not while the main thread waits")
        disk.signal()
        // What quitting does after the stores hand over their last state.
        StateFileWriter.shared.flush()
        XCTAssertEqual(try FileComposerDraftRepository(directoryURL: repository.directoryURL).load().home.text,
                       "Typed just before quitting")
        XCTAssertNil(drafts.storageFailure)
    }

    func testShutdownFlushesTheLastKeystrokeBeforeDebounce() async throws {
        let repository = try fileRepository()
        let app = model(repository: repository)
        app.composerDrafts.home.text = "Last keystroke 한"
        await app.shutdown()
        XCTAssertEqual(ComposerDrafts(repository: repository).home.text, "Last keystroke 한")
    }

    func testIndexRestorationDoesNotPruneDraftsBeforeSessionsAreLoaded() async throws {
        let repository = try fileRepository()
        let owner = session()
        let seed = ComposerDrafts(repository: repository)
        seed.tasks.draft(for: owner.id).text = "Still belongs to this task"
        seed.tasks.draft(for: UUID()).text = "An archived task"
        seed.persistNow()
        let app = model(repository: repository, sessions: InMemorySessionRepository(sessions: [owner]))
        XCTAssertTrue(app.store.sessions.isEmpty)
        XCTAssertEqual(app.composerDrafts.tasks.snapshot.count, 2)
        await app.restoreIndex()
        await app.shutdown()
        let restarted = ComposerDrafts(repository: repository)
        XCTAssertEqual(restarted.tasks.snapshot.count, 1)
        XCTAssertEqual(restarted.tasks.draft(for: owner.id).text, "Still belongs to this task")
        XCTAssertFalse(app.isAttached(owner.id))
    }

    func testFailedIndexRestoreAndFailedArchiveKeepDrafts() async throws {
        let repository = try fileRepository()
        let owner = session()
        let seed = ComposerDrafts(repository: repository)
        seed.tasks.draft(for: owner.id).text = "Keep on index failure"
        seed.persistNow()
        let sessions = FailingDraftSessionRepository()
        let app = model(repository: repository, sessions: sessions)
        await app.restoreIndex()
        await app.shutdown()
        XCTAssertEqual(ComposerDrafts(repository: repository).tasks.draft(for: owner.id).text,
                       "Keep on index failure")
        await sessions.allowLoad(owner)
        await app.restoreIndex()
        await app.archive(owner)
        XCTAssertTrue(app.store.sessions.contains { $0.id == owner.id })
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: owner.id).text, "Keep on index failure")
    }

    func testConfirmedRemovalClearsOnlyItsTaskOnDisk() async throws {
        let repository = try fileRepository()
        let first = session(), second = session()
        let app = model(repository: repository, sessions: InMemorySessionRepository(sessions: [first, second]))
        await app.restoreIndex()
        app.composerDrafts.tasks.draft(for: first.id).text = "Remove"
        app.composerDrafts.tasks.draft(for: second.id).text = "Retain"
        await app.delete(first)
        await app.shutdown()
        let restarted = ComposerDrafts(repository: repository)
        XCTAssertNil(restarted.tasks.snapshot[first.id])
        XCTAssertEqual(restarted.tasks.draft(for: second.id).text, "Retain")
    }

    func testCorruptAndNewerFormatFilesArePreservedEvenAfterEditingAndRetry() throws {
        for source in ["{broken", "{\"version\":2,\"future\":\"preserve\"}"] {
            let repository = try fileRepository()
            try FileManager.default.createDirectory(at: repository.directoryURL, withIntermediateDirectories: true)
            let original = Data(source.utf8)
            try original.write(to: repository.fileURL)
            let drafts = ComposerDrafts(repository: repository)
            XCTAssertEqual(drafts.storageFailure, .restore)
            drafts.home.text = "Current input is not lost"
            drafts.persistNow()
            drafts.retry()
            XCTAssertEqual(try Data(contentsOf: repository.fileURL), original)
            XCTAssertEqual(drafts.home.text, "Current input is not lost")
            XCTAssertEqual(drafts.storageFailure, .restore)
        }
    }

    func testRetryMergesRecoveredStorageWithCurrentEditsAndRemovedTasks() {
        let repository = FailingComposerDraftRepository()
        let untouched = UUID(), edited = UUID(), removed = UUID()
        repository.snapshot.home.text = "Old home"
        for id in [untouched, edited, removed] { repository.snapshot.tasks[id] = TaskDraftSnapshot(text: "Old task") }
        repository.failLoad = true
        let drafts = ComposerDrafts(repository: repository)
        drafts.home.text = "Current home"
        drafts.tasks.draft(for: edited).text = "Current task"
        drafts.remove(for: removed)
        repository.failLoad = false
        drafts.retry()
        let restarted = ComposerDrafts(repository: repository)
        XCTAssertEqual(restarted.home.text, "Current home")
        XCTAssertEqual(restarted.tasks.draft(for: untouched).text, "Old task")
        XCTAssertEqual(restarted.tasks.draft(for: edited).text, "Current task")
        XCTAssertNil(restarted.tasks.snapshot[removed])
        XCTAssertNil(drafts.storageFailure)
    }

    func testSaveFailureKeepsInputAndRetryWritesLatestState() {
        let repository = FailingComposerDraftRepository()
        let drafts = ComposerDrafts(repository: repository)
        repository.failSave = true
        drafts.home.text = "Unwritten draft"
        drafts.persistNow()
        XCTAssertEqual(drafts.storageFailure, .save)
        XCTAssertEqual(drafts.home.text, "Unwritten draft")
        drafts.home.text = "Edited during failure"
        repository.failSave = false
        drafts.retry()
        XCTAssertNil(drafts.storageFailure)
        XCTAssertEqual(ComposerDrafts(repository: repository).home.text, "Edited during failure")
    }

    func testRetryDoesNotTreatAutomaticHomePreparationAsUserEdit() {
        let repository = FailingComposerDraftRepository()
        repository.snapshot.home = HomeDraftSnapshot(
            text: "Recover the original request", workspaceURL: URL(filePath: "/tmp/original"),
            harness: .openCode, hasPreparedWorkspace: true
        )
        repository.failLoad = true
        let drafts = ComposerDrafts(repository: repository)
        drafts.home.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/default"), availableHarnesses: [.codex])
        repository.failLoad = false
        drafts.retry()
        XCTAssertEqual(drafts.home.snapshot, repository.snapshot.home)
        XCTAssertEqual(drafts.home.harness, .openCode)
        XCTAssertEqual(drafts.home.text, "Recover the original request")
    }

    func testFailedRenameRetryKeepsDraftAndClearsTheResolvedError() async throws {
        let repository = try fileRepository(), owner = session()
        let app = model(repository: repository, sessions: TaskManagementFixtureRepository(
            sessions: [owner], failOnce: .rename
        ))
        await app.restoreIndex()
        app.composerDrafts.tasks.draft(for: owner.id).text = "  Keep 한글 👩🏽‍💻\n"
        await app.rename(owner, to: "New name")
        XCTAssertEqual(app.store.selectedSession?.title, owner.title)
        XCTAssertNotNil(app.bootstrapError)

        await app.rename(owner, to: "New name")
        XCTAssertEqual(app.store.selectedSession?.title, "New name")
        XCTAssertNil(app.bootstrapError)
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: owner.id).text, "  Keep 한글 👩🏽‍💻\n")
    }

    func testProjectArchiveKeepsFailedTaskAndReportsFailureAfterOtherTasksSucceed() async throws {
        let repository = try fileRepository(), failed = session(), removed = session()
        let app = model(repository: repository, sessions: TaskManagementFixtureRepository(
            sessions: [failed, removed], failOnce: .archive
        ))
        await app.restoreIndex()
        app.composerDrafts.tasks.draft(for: failed.id).text = "Keep failed draft"
        app.composerDrafts.tasks.draft(for: removed.id).text = "Remove successful draft"
        await app.archive([failed, removed])
        XCTAssertEqual(app.store.sessions.map(\.id), [failed.id])
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: failed.id).text, "Keep failed draft")
        XCTAssertNil(app.composerDrafts.tasks.snapshot[removed.id])
        XCTAssertNotNil(app.bootstrapError)

        await app.archive(failed)
        XCTAssertTrue(app.store.sessions.isEmpty)
        XCTAssertNil(app.composerDrafts.tasks.snapshot[failed.id])
        XCTAssertNil(app.bootstrapError)
    }
}

@MainActor
private final class FailingComposerDraftRepository: ComposerDraftRepository {
    var snapshot = ComposerDraftSnapshot()
    var failLoad = false
    var failSave = false
    func load() throws -> ComposerDraftSnapshot {
        if failLoad { throw CocoaError(.fileReadUnknown) }
        return snapshot
    }
    func save(_ snapshot: ComposerDraftSnapshot, saved: @escaping StateFileWriter.Done) {
        if !failSave { self.snapshot = snapshot }
        saved(!failSave)
    }
}

private actor FailingDraftSessionRepository: SessionRepository {
    var owner: SessionRecord?
    func allowLoad(_ owner: SessionRecord) { self.owner = owner }
    func loadSessions() throws -> [SessionRecord] {
        guard let owner else { throw CocoaError(.fileReadUnknown) }
        return [owner]
    }
    func upsert(_ session: SessionRecord) {}
    func archive(id: UUID) throws { throw CocoaError(.fileWriteUnknown) }
}
