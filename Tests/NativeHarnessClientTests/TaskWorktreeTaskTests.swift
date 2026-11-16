import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// New tasks in a worktree, from the composer's choice through archive and unarchive, against
/// throwaway repositories and a stand-in harness. No runtime, account, or model is contacted.
@MainActor
final class TaskWorktreeTaskTests: XCTestCase {
    private var fixture: WorktreeFixture!
    private let harness = HarnessKind.openCode
    private let runtime = URL(filePath: "/tmp/opencode")

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try WorktreeFixture()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    // MARK: - Starting

    func testANewWorktreeTaskRunsInItsWorktreeUnderTheChosenProject() async throws {
        let repository = try fixture.makeRepository()
        let notes = fixture.root.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let (model, adapter) = makeModel()
        let project = model.projects.ensureProject(forRoot: repository, name: "Sample")
        model.projects.addRoot(notes, to: project.id)

        let created = try await model.createTask(try submission(in: repository, projectID: project.id,
                                                                prompt: "Fix the parser\nwith care"))
        let task = try XCTUnwrap(created)

        let worktree = try XCTUnwrap(model.worktrees.layout.worktreeURL(containing: task.workspaceURL))
        XCTAssertEqual(worktree.lastPathComponent, "fix-the-parser")
        XCTAssertTrue(fixture.exists(task.workspaceURL.appending(path: "README.md")))
        XCTAssertEqual(task.projectID, project.id)
        XCTAssertEqual(task.originWorkspacePath, ProjectSidebarPresentation.normalizedPath(for: repository))
        XCTAssertEqual(task.worktreeName, "fix-the-parser")
        XCTAssertEqual(task.branch, "yardlet/fix-the-parser")
        XCTAssertEqual(task.additionalRoots, [ProjectSidebarPresentation.normalizedPath(for: notes)],
                       "The project's other roots come along; the worktree stands in for the chosen folder")
        XCTAssertEqual(model.projects.projects.map(\.id), [project.id], "No second project for the worktree")
        let groups = model.projects.visibleGroups(sessions: model.store.sessions)
        XCTAssertEqual(groups.map(\.project?.id), [project.id])
        XCTAssertEqual(groups.first?.sessions.map(\.id), [task.id])
        XCTAssertEqual(SidebarWorktreeProjection.detail(for: task), "fix-the-parser")
        let started = await adapter.createdWorkspaces
        XCTAssertEqual(started, [task.workspaceURL])
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Fix the parser\nwith care"])
        await model.shutdown()
    }

    func testALocalStartIsUnchanged() async throws {
        let repository = try fixture.makeRepository()
        let (model, _) = makeModel()
        let project = model.projects.ensureProject(forRoot: repository)

        let created = try await model.createTask(try submission(in: repository, projectID: project.id,
                                                                prompt: "Stay here", inWorktree: false))

        XCTAssertEqual(created.map { ProjectSidebarPresentation.normalizedPath(for: $0.workspaceURL) },
                       ProjectSidebarPresentation.normalizedPath(for: repository))
        XCTAssertNil(created?.originWorkspacePath)
        XCTAssertFalse(fixture.exists(fixture.layout.rootURL))
        await model.shutdown()
    }

    func testAWorktreeThatCannotBeMadeStartsNoTask() async throws {
        let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let (model, adapter) = makeModel()
        let project = model.projects.ensureProject(forRoot: plain)

        do {
            _ = try await model.createTask(try submission(in: plain, projectID: project.id, prompt: "Nope"))
            XCTFail("A folder outside Git cannot start in a worktree")
        } catch {
            XCTAssertEqual(error as? TaskWorktreeError, .notARepository)
        }
        XCTAssertTrue(model.store.sessions.isEmpty)
        let creates = await adapter.createdWorkspaces
        XCTAssertTrue(creates.isEmpty)

        // A start that would fail anyway does not make a worktree first.
        let repository = try fixture.makeRepository()
        let wrongAccount = ProviderConnection(id: "codex-account", name: "Codex", harness: .codex,
            providerID: nil, homePath: nil, credentialSelector: nil)
        do {
            _ = try await model.createTask(try submission(in: repository, projectID: nil, prompt: "Wrong account",
                                                          connection: wrongAccount))
            XCTFail("An account for another harness must be refused")
        } catch {
            XCTAssertNil(error as? TaskWorktreeError)
        }
        XCTAssertFalse(fixture.exists(fixture.layout.rootURL))
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testAWorktreeWhoseTaskNeverCameToExistIsTakenBack() async throws {
        let repository = try fixture.makeRepository()
        let (model, _) = makeModel(repository: RefusingSessionRepository())
        let project = model.projects.ensureProject(forRoot: repository)

        let created = try await model.createTask(try submission(in: repository, projectID: project.id, prompt: "Lost"))

        XCTAssertNil(created)
        XCTAssertNotNil(model.bootstrapError)
        XCTAssertFalse(fixture.exists(fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "lost")))
        XCTAssertFalse(try fixture.branchExists("yardlet/lost", in: repository))
        await model.shutdown()
    }

    // MARK: - Archive and unarchive

    func testArchivingRemovesACleanWorktreeAndUnarchivingPutsItBack() async throws {
        let repository = try fixture.makeRepository()
        let (model, _) = makeModel()
        let project = model.projects.ensureProject(forRoot: repository)
        let task = try await startInWorktree(model, from: repository, projectID: project.id, prompt: "Round trip")
        let worktree = try XCTUnwrap(model.worktrees.layout.worktreeURL(containing: task.workspaceURL))

        await model.archive(task)

        XCTAssertFalse(model.store.sessions.contains { $0.id == task.id })
        XCTAssertFalse(fixture.exists(worktree))
        XCTAssertTrue(try fixture.branchExists("yardlet/round-trip", in: repository))
        XCTAssertNil(model.worktreeNotice, "A clean removal needs no message")

        try await model.store.loadArchivedSessions()
        let archived = try XCTUnwrap(model.store.archivedSessions?.first { $0.id == task.id })
        await model.unarchive(archived)

        XCTAssertTrue(model.store.sessions.contains { $0.id == task.id })
        XCTAssertTrue(fixture.exists(task.workspaceURL.appending(path: "README.md")))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"], in: task.workspaceURL), "yardlet/round-trip")
        XCTAssertEqual(model.worktreeNotice,
                       L10n.format("Recreated the worktree of “%@” from %@.", task.title, "yardlet/round-trip"))
        model.dismissWorktreeNotice()
        XCTAssertNil(model.worktreeNotice)

        // Without its branch the worktree cannot come back; the task still does, and says why.
        await model.archive(task)
        try fixture.git(["branch", "-D", "yardlet/round-trip"], in: repository)
        try await model.store.loadArchivedSessions()
        await model.unarchive(try XCTUnwrap(model.store.archivedSessions?.first { $0.id == task.id }))
        XCTAssertTrue(model.store.sessions.contains { $0.id == task.id })
        XCTAssertFalse(fixture.exists(worktree))
        XCTAssertEqual(model.worktreeNotice,
                       L10n.format("Couldn't recreate the worktree of “%@” because %@ no longer exists.",
                                   task.title, "yardlet/round-trip"))
        await model.shutdown()
    }

    func testArchivingKeepsAWorktreeWithWorkInItAndSaysWhy() async throws {
        let repository = try fixture.makeRepository()
        let (model, _) = makeModel()
        let project = model.projects.ensureProject(forRoot: repository)
        let dirty = try await startInWorktree(model, from: repository, projectID: project.id, prompt: "Dirty")
        try fixture.write("draft\n", to: "notes.txt", in: dirty.workspaceURL)
        let committed = try await startInWorktree(model, from: repository, projectID: project.id, prompt: "Committed")
        try fixture.write("done\n", to: "done.txt", in: committed.workspaceURL)
        try fixture.commit("Finish", in: committed.workspaceURL)

        await model.archive([dirty, committed])

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(fixture.exists(dirty.workspaceURL.appending(path: "notes.txt")))
        XCTAssertTrue(fixture.exists(committed.workspaceURL.appending(path: "done.txt")))
        XCTAssertEqual(model.worktreeNotice, [
            L10n.format("Kept the worktree of “%@” because it has uncommitted changes.", dirty.title),
            L10n.format("Kept the worktree of “%@” because %@ has commits that aren't on another branch.",
                        committed.title, "yardlet/committed")
        ].joined(separator: "\n"))

        // The next archive starts a fresh notice.
        let clean = try await startInWorktree(model, from: repository, projectID: project.id, prompt: "Clean")
        await model.archive(clean)
        XCTAssertNil(model.worktreeNotice)
        await model.shutdown()
    }

    func testAWorktreeAnotherTaskStillUsesIsLeftForThatTask() async throws {
        let repository = try fixture.makeRepository()
        let (model, _) = makeModel()
        let project = model.projects.ensureProject(forRoot: repository)
        let first = try await startInWorktree(model, from: repository, projectID: project.id, prompt: "Shared")
        // A second task started directly in the same worktree, as a side chat or fork would be.
        let created = await model.createSession(harness: harness, workspaceURL: first.workspaceURL,
                                                runtimeExecutableURL: runtime, title: "Second look")
        let second = try XCTUnwrap(created)
        let worktree = try XCTUnwrap(model.worktrees.layout.worktreeURL(containing: first.workspaceURL))

        await model.archive(first)
        XCTAssertTrue(fixture.exists(worktree))
        XCTAssertNil(model.worktreeNotice)

        await model.archive(second)
        XCTAssertFalse(fixture.exists(worktree), "The last task out tidies it")
        await model.shutdown()
    }

    /// A worktree Yardlet did not make is left by archive and unarchive alike. When it goes from under
    /// its task (2026-10-23: an agent's clean-up removed its own folder), the task says so above its
    /// composer, keeps what the person sends there and starts nothing; its worktree comes back in the
    /// same place from its branch only when the person asks.
    func testATaskInAWorktreeYardletDidNotMakeIsLeftAndGetsItBackOnlyWhenAsked() async throws {
        let repository = try fixture.makeRepository()
        let own = fixture.root.appending(path: "my-own-worktree", directoryHint: .isDirectory)
        try fixture.git(["worktree", "add", "-q", "-b", "mine", own.path(percentEncoded: false)], in: repository)
        let (model, adapter) = makeModel()
        let created = await model.createSession(harness: harness, workspaceURL: own,
                                                runtimeExecutableURL: runtime, title: "Mine")
        let task = try XCTUnwrap(created)
        XCTAssertEqual(task.branch, "mine")

        await model.archive(task)

        XCTAssertTrue(fixture.exists(own.appending(path: "README.md")))
        XCTAssertNil(model.worktreeNotice)

        try await model.store.loadArchivedSessions()
        await model.unarchive(try XCTUnwrap(model.store.archivedSessions?.first { $0.id == task.id }))
        try fixture.git(["worktree", "remove", own.path(percentEncoded: false)], in: repository)
        XCTAssertNil(model.worktreeNotice, "Unarchiving makes no worktree Yardlet did not make")
        let startedBefore = await adapter.createdWorkspaces

        await model.refreshTaskFolder(task.id)
        let missing = try XCTUnwrap(model.missingTaskFolders[task.id])
        XCTAssertEqual(missing.path, ProjectSidebarPresentation.normalizedPath(for: own))
        XCTAssertEqual(missing.worktreeBranch, "mine")
        let draft = model.composerDrafts.tasks.draft(for: task.id)
        draft.text = "Keep going"
        let refused = model.sendDraft(of: task)
        XCTAssertEqual(draft.text, "", "The draft empties as the message goes")
        await refused?.value
        XCTAssertEqual(draft.text, "Keep going", "The refusal puts it back")
        XCTAssertEqual(draft.notice, missing.localizedDescription)
        await model.resume(task)
        XCTAssertFalse(model.isAttached(task.id))
        var prompts = await adapter.prompts
        XCTAssertEqual(prompts, [])
        let workspaces = await adapter.createdWorkspaces
        XCTAssertEqual(workspaces, startedBefore, "Nothing started in the folder that is gone")
        let current = try XCTUnwrap(model.store.sessions.first { $0.id == task.id })
        XCTAssertEqual(current.providerSessionID, task.providerSessionID)
        XCTAssertEqual(current.workspaceURL, task.workspaceURL)

        // Above the composer: the fact, and the way back while the branch is there.
        var pressed = 0
        let notice = TaskFolderMissingNotice(missing: missing, isRecreating: false, recreateWorktree: { pressed += 1 })
        let directory = try WindowlessRender.directory("task-folder-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                TaskFolderMissingBanner(notice: notice).padding(.vertical, 12).frame(width: 720, height: 96)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 720, height: 96), appearance: appearance
            )
            host.settle()
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "worktree-missing-\(appearance.suffix).png"))
            let elements = host.accessibilityElements().map(\.description)
            XCTAssertTrue(elements.contains { $0.contains(L10n.string("Task folder not found")) }, "\(elements)")
            XCTAssertTrue(elements.contains { $0.contains(missing.path) }, "\(elements)")
            XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Recreate worktree")), "\(elements)")
            host.close()
        }
        XCTAssertEqual(pressed, 2)

        await model.recreateTaskWorktree(task.id)
        XCTAssertTrue(fixture.exists(own.appending(path: "README.md")))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"], in: own), "mine")
        XCTAssertNil(model.missingTaskFolders[task.id])
        XCTAssertEqual(model.worktreeNotice, L10n.format("Recreated the worktree of “%@” from %@.", task.title, "mine"))
        // What stayed in the draft goes once the folder is back.
        await model.sendDraft(of: task)?.value
        XCTAssertEqual(draft.text, "")
        XCTAssertNil(draft.notice)
        prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Keep going"])

        // Without its branch only the fact is left: no way back is offered, and none is drawn.
        try fixture.git(["worktree", "remove", own.path(percentEncoded: false)], in: repository)
        try fixture.git(["branch", "-D", "mine"], in: repository)
        await model.refreshTaskFolder(task.id)
        let gone = try XCTUnwrap(model.missingTaskFolders[task.id])
        XCTAssertNil(gone.worktreeBranch)
        let host = WindowlessRender.Host(
            TaskFolderMissingBanner(notice: TaskFolderMissingNotice(missing: gone, isRecreating: false,
                                                                    recreateWorktree: { pressed += 1 }))
                .frame(width: 720, height: 96),
            size: NSSize(width: 720, height: 96)
        )
        host.settle()
        try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "folder-missing.png"))
        XCTAssertFalse(host.accessibilityElements().contains { $0.label == L10n.string("Recreate worktree") })
        host.close()
        await model.send(HarnessUserInput(text: "Still there?"), to: task)
        prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Keep going"])
        await model.shutdown()
    }

    // MARK: - The composer's choice

    func testTheChoiceIsRememberedPerProjectAndTravelsWithTheSubmission() throws {
        let first = UUID(), second = UUID()
        let draft = NewTaskDraft()
        draft.prepare(defaultWorkspaceURL: URL(filePath: "/tmp/worktree-choice"), defaultProjectID: first,
                      availableHarnesses: [.claudeCode])
        XCTAssertFalse(draft.startsInNewWorktree(projectID: first), "Local is the default")
        var writes = 0
        draft.onChange = { writes += 1 }

        draft.setStartsInNewWorktree(true, projectID: first)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(draft.startsInNewWorktree(projectID: first))
        XCTAssertFalse(draft.startsInNewWorktree(projectID: second))
        XCTAssertFalse(draft.startsInNewWorktree(projectID: nil))

        let restored = NewTaskDraft()
        restored.apply(draft.snapshot)
        XCTAssertTrue(restored.startsInNewWorktree(projectID: first), "The choice survives a relaunch")
        let decoded = try JSONDecoder().decode(HomeDraftSnapshot.self, from: JSONEncoder().encode(draft.snapshot))
        XCTAssertEqual(decoded, draft.snapshot)
        let older = try JSONDecoder().decode(HomeDraftSnapshot.self, from: Data(#"{"text":"","hasPreparedWorkspace":true}"#.utf8))
        XCTAssertNil(older.worktreeProjectIDs, "Drafts saved before the choice existed still load")

        draft.text = "Start"
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime, startsInNewWorktree: true))
        XCTAssertTrue(submission.startsInNewWorktree)
        draft.complete(submission, succeeded: false, error: "Couldn't create the worktree: no")
        XCTAssertTrue(draft.creationFailed)
        XCTAssertEqual(draft.creationError, "Couldn't create the worktree: no")
        XCTAssertEqual(draft.text, "Start", "The draft stays for another try")
        let retry = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
        XCTAssertNil(draft.creationError)
        XCTAssertFalse(retry.startsInNewWorktree)

        draft.setStartsInNewWorktree(false, projectID: first)
        XCTAssertFalse(draft.startsInNewWorktree(projectID: first))
        XCTAssertNil(draft.snapshot.worktreeProjectIDs)
    }

    func testTheComposerOffersTheChoiceOnlyForAGitFolderAndRendersWithoutAWindowOnScreen() throws {
        let repository = try fixture.makeRepository()
        let plain = fixture.root.appending(path: "plain-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertTrue(GitWorktreeOriginResolver.isInRepository(repository))
        XCTAssertTrue(GitWorktreeOriginResolver.isInRepository(repository.appending(path: "app")))
        XCTAssertFalse(GitWorktreeOriginResolver.isInRepository(plain))
        let repoProject = Project(name: "Sample Repo", primaryRoot: repository)
        let plainProject = Project(name: "plain-folder", primaryRoot: plain)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskWorktreeTaskTests")))
        let selections = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        selections.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let directory = try WindowlessRender.directory("new-task-worktree-qa")

        func render(_ name: String, project: Project, worktree: Bool, error: String? = nil, width: CGFloat = 720,
                    scheme: ColorScheme = .light) throws -> Data {
            let draft = NewTaskDraft()
            draft.harness = .claudeCode
            draft.workspaceURL = project.primaryRoot
            draft.projectID = project.id
            draft.text = "Fix the parser"
            draft.setStartsInNewWorktree(worktree, projectID: project.id)
            if let error, let submission = draft.beginSubmission(runtimeURL: URL(filePath: "/usr/bin/true")) {
                draft.complete(submission, succeeded: false, error: error)
            }
            let view = VStack(spacing: 0) {
                NewTaskHome(recentSessions: [], projects: [repoProject, plainProject], draft: draft,
                            runtimeSelections: selections, onSelectSession: { _ in }, onChooseWorkspace: { _ in },
                            onShowHarnesses: {}, onCreate: { _ in nil })
                    .frame(width: width, height: 300)
                WorktreeNoticeBar(message: L10n.format("Kept the worktree of “%@” because it has uncommitted changes.",
                                                       "Fix the parser"), onDismiss: {})
            }
            .frame(width: width, height: 340, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, scheme)
            let host = WindowlessRender.Host(view, size: NSSize(width: width, height: 340),
                                             appearance: WindowlessRender.Appearance(scheme))
            defer { host.close() }
            host.settle(passes: 1, interval: 0.15)
            let capture = try host.capture()
            let png = try WindowlessRender.pngData(capture.bitmap)
            try png.write(to: directory.appending(path: name))
            XCTAssertEqual(capture.bitmap.pixelsWide, Int(width * capture.backingScaleFactor))
            return png
        }

        // The images are what to look at; these only catch a control that silently stopped drawing.
        let outside = try render("not-git-light.png", project: plainProject, worktree: true)
        let outsideLocal = try render("not-git-local-light.png", project: plainProject, worktree: false)
        XCTAssertEqual(outside, outsideLocal, "A folder outside Git shows no choice, whatever was remembered")
        let local = try render("local-light.png", project: repoProject, worktree: false)
        XCTAssertNotEqual(local, outsideLocal)
        let worktree = try render("worktree-light.png", project: repoProject, worktree: true)
        XCTAssertNotEqual(worktree, local)
        _ = try render("worktree-dark.png", project: repoProject, worktree: true, scheme: .dark)
        _ = try render("worktree-narrow-light.png", project: repoProject, worktree: true, width: 440)
        let failed = try render("failed-light.png", project: repoProject, worktree: true,
                                error: TaskWorktreeError.gitFailed("cannot lock ref 'refs/heads/yardlet/fix'").localizedDescription)
        XCTAssertNotEqual(failed, worktree)
    }

    // MARK: - Fixtures

    private func makeModel(repository: (any SessionRepository)? = nil) -> (AppModel, WorktreeRecordingAdapter) {
        let adapter = WorktreeRecordingAdapter(kind: harness)
        let model = AppModel(
            store: SessionStore(repository: repository ?? InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: UserDefaults(suiteName: testDefaultsSuite("TaskWorktree"))!,
                                                     discoversRuntimes: false, loadsPersistedSelections: false),
            // The stand-in records where a harness would start: in the task's folder.
            registry: HarnessRegistry(factory: { _, _ in adapter }, startsHarnessesInTaskFolders: true),
            worktrees: fixture.service(),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: QuietWorktreeNotificationCenter(),
            restoresIndexOnLaunch: false
        )
        return (model, adapter)
    }

    private func startInWorktree(
        _ model: AppModel,
        from folder: URL,
        projectID: UUID,
        prompt: String
    ) async throws -> SessionRecord {
        let created = try await model.createTask(try submission(in: folder, projectID: projectID, prompt: prompt))
        return try XCTUnwrap(created)
    }

    private func submission(
        in folder: URL,
        projectID: UUID?,
        prompt: String,
        inWorktree: Bool = true,
        connection: ProviderConnection? = nil
    ) throws -> NewTaskDraft.Submission {
        let draft = NewTaskDraft()
        draft.harness = harness
        draft.workspaceURL = folder
        draft.projectID = projectID
        draft.text = prompt
        return try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime, connection: connection,
                                                   startsInNewWorktree: inWorktree))
    }
}

/// Starts sessions without a runtime and records where and what it was asked to run.
private actor WorktreeRecordingAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind
    private(set) var createdWorkspaces: [URL] = []
    private(set) var prompts: [String] = []
    init(kind: HarnessKind) { self.kind = kind }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        createdWorkspaces.append(request.workspaceURL)
        return HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                    providerSessionID: UUID().uuidString.lowercased(), workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                             workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { prompts.append(prompt) }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    /// Like a live provider, the stream stays open until the task is closed.
    private var streams: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
        streams[session.localSessionID] = continuation
        return stream
    }
    func close(_ session: HarnessSessionHandle) async {
        streams.removeValue(forKey: session.localSessionID)?.finish()
    }
}

private final class QuietWorktreeNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}

/// An index that cannot record a new task, so the start fails before the task exists.
private actor RefusingSessionRepository: SessionRepository {
    func loadSessions() async throws -> [SessionRecord] { [] }
    func upsert(_ session: SessionRecord) async throws {
        throw SessionRepositoryError.statementFailed("The index is read-only")
    }
    func archive(id: UUID) async throws {}
}
