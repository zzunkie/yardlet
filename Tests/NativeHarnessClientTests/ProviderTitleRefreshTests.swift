import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ProviderTitleRefreshTests: XCTestCase {
    func testRestoreRefreshesImportedTitleAndKeepsLocalMetadataAndRecency() async throws {
        var session = makeSession()
        session.isPinned = true
        session.hasUnreadUpdate = true
        session.providerOptions = ["model": "selected-model"]
        let repository = TitleRefreshRepository([session])
        let source = DelayedTitleSource()
        let model = try makeModel(repository: repository, resolver: { _ in source.read() })
        let restore = Task { await model.restoreIndex() }
        // The list shows the index's titles while the harness's are read: a hundred long Claude Code
        // histories kept "Restoring tasks…" up for about 15 seconds.
        try await waitUntil { source.readCount == 1 }
        XCTAssertFalse(model.isRestoringIndex)
        XCTAssertTrue(model.hasRestoredIndex)
        XCTAssertEqual(model.store.sessions.first?.title, session.title)
        source.release.signal()
        await restore.value

        var expected = session
        expected.title = "Older provider title"
        XCTAssertEqual(model.store.sessions, [expected])
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted, [expected])
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testReopeningDetachedTaskReadsChangedGrokTitleWithoutRepeatedWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-title-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession()
        let summary = root.appending(path: "grok/workspace/provider-id/summary.json")
        try FileManager.default.createDirectory(at: summary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let paths = ProviderSessionTitlePaths(grokSessionsRoot: root.appending(path: "grok"),
            claudeProjectsRoot: root.appending(path: "claude"), openCodeDatabaseURL: root.appending(path: "opencode.db"),
            kimiSessionsRoot: root.appending(path: "kimi/sessions"))
        try Data(#"{"generated_title":"Original title"}"#.utf8).write(to: summary)
        let repository = TitleRefreshRepository([session])
        let model = try makeModel(repository: repository, resolver: { ProviderSessionTitleResolver.title(for: $0, paths: paths) })
        await model.restoreIndex()
        let baselineWrites = await repository.writes
        try Data(#"{"generated_title":"Renamed in Grok"}"#.utf8).write(to: summary)
        await model.refreshConversationStatus(for: session)

        XCTAssertEqual(model.store.selectedSession?.title, "Renamed in Grok")
        XCTAssertEqual(model.store.selectedSession?.updatedAt, session.updatedAt)
        XCTAssertFalse(model.isAttached(session.id))
        await model.refreshConversationStatus(for: session)
        await model.refreshConversationStatus(for: session)
        let writes = await repository.writes
        XCTAssertEqual(writes, baselineWrites + 1, "Unchanged title reads must not rewrite or reorder the task")
        await model.shutdown()
    }

    func testManualAndUnknownLegacyTitlesSurviveExternalRefresh() async throws {
        for origin in [SessionTitleOrigin.manual, .legacy] {
            var session = makeSession()
            session.titleOrigin = origin
            let repository = TitleRefreshRepository([session])
            let model = try makeModel(repository: repository, resolver: { _ in "Provider title" })
            await model.restoreIndex()
            await model.refreshConversationStatus(for: session)
            XCTAssertEqual(model.store.sessions, [session])
            await model.shutdown()
        }
    }

    func testActivationRefreshesOnlyVisibleTaskAndPreservesDraftAndSelection() async throws {
        let visible = makeSession()
        var background = makeSession()
        background.providerSessionID = "background-provider"
        let repository = TitleRefreshRepository([visible, background])
        let model = try makeModel(repository: repository, resolver: { _ in "Updated provider title" }, restores: false)
        model.store.selectedSessionID = visible.id
        model.setShowsTasks(true, inWindow: UUID())
        let draft = model.composerDrafts.tasks.draft(for: visible.id)
        draft.text = "  Keep this unsent draft 👩🏽‍💻\n"
        draft.rememberSelection(NSRange(location: 2, length: 4), in: draft.text)
        let selection = draft.selection

        await model.refreshVisibleProviderTitles()

        XCTAssertEqual(model.store.sessions.first(where: { $0.id == visible.id })?.title, "Updated provider title")
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == background.id }), background)
        XCTAssertEqual(model.store.selectedSessionID, visible.id)
        XCTAssertEqual(draft.text, "  Keep this unsent draft 👩🏽‍💻\n")
        XCTAssertEqual(draft.selection, selection)
        let writes = await repository.writes
        XCTAssertEqual(writes, 1)
        await model.shutdown()
    }

    func testMissingOrBlankProviderTitlePreservesExistingTitle() async throws {
        for value in [nil, " \n "] as [String?] {
            let session = makeSession()
            let repository = TitleRefreshRepository([session])
            let model = try makeModel(repository: repository, resolver: { _ in value })
            await model.restoreIndex()
            await model.refreshConversationStatus(for: session)
            XCTAssertEqual(model.store.sessions, [session])
            let writes = await repository.writes
            XCTAssertEqual(writes, 0)
            await model.shutdown()
        }
    }

    func testOlderReadCannotOverwriteNewerRefreshOrManualRenameOrDeletedTask() async throws {
        for action in ["newer", "manual", "delete", "cancel", "shutdown"] {
            let session = makeSession()
            let source = DelayedTitleSource()
            let repository = TitleRefreshRepository([session])
            let model = try makeModel(repository: repository, resolver: { _ in source.read() }, restores: false)
            let refresh = Task { await model.refreshConversationStatus(for: session) }
            try await waitUntil { source.readCount != 0 }
            guard source.readCount == 1 else {
                source.release.signal()
                await refresh.value
                XCTFail("The detached title resolver was never called")
                await model.shutdown()
                continue
            }
            switch action {
            case "newer": await model.refreshConversationStatus(for: session)
            case "manual": await model.rename(session, to: "My title")
            case "delete": await model.delete(session)
            case "shutdown": await model.shutdown()
            default: refresh.cancel()
            }
            source.release.signal()
            await refresh.value
            let expected = ["newer": "Newest provider title", "manual": "My title", "cancel": session.title,
                            "shutdown": session.title][action]
            XCTAssertEqual(model.store.sessions.first?.title, expected)
            await model.shutdown()
        }
    }

    private func makeSession() -> SessionRecord {
        SessionRecord(harness: .grokBuild, workspaceURL: URL(filePath: "/tmp/title-refresh"),
            runtimeExecutableURL: URL(filePath: "/nonexistent/grok"), title: "Original title",
            titleOrigin: .provider, createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20), providerSessionID: "provider-id")
    }

    private func makeModel(repository: TitleRefreshRepository,
        resolver: @escaping @Sendable (SessionRecord) -> String?, restores: Bool = true) throws -> AppModel {
        let suite = testDefaultsSuite("Yardlet.ProviderTitleRefreshTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return AppModel(store: SessionStore(sessions: repository.initial, repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            transcriptRepository: FileTranscriptRepository(directoryURL: URL(filePath: "/nonexistent/transcripts")),
            sessionTitleResolver: resolver, restoresIndexOnLaunch: restores)
    }
}

private actor TitleRefreshRepository: SessionRepository {
    nonisolated let initial: [SessionRecord]
    private var sessions: [SessionRecord]
    private(set) var writes = 0
    init(_ sessions: [SessionRecord]) { self.initial = sessions; self.sessions = sessions }
    func loadSessions() async throws -> [SessionRecord] { sessions }
    func upsert(_ session: SessionRecord) async throws {
        writes += 1
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
    }
    func archive(id: UUID) async throws { sessions.removeAll { $0.id == id } }
}

private final class DelayedTitleSource: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let release = DispatchSemaphore(value: 0)
    var readCount: Int { lock.withLock { reads } }
    func read() -> String? {
        let ordinal = lock.withLock { reads += 1; return reads }
        if ordinal == 1 {
            guard release.wait(timeout: .now() + 5) == .success else { return nil }
            return "Older provider title"
        }
        return "Newest provider title"
    }
}
