import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Where a chat goes: a task started or imported in a folder the person did not add as a project
/// gets no project, a new chat gets a folder of its own under
/// `~/Documents/Yardlet/<yyyy-MM-dd>/new-chat`, and a folder the person added as a project stays one.
/// Every folder here is in a temporary home.
@MainActor
final class ChatPlacementTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "chat-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - New chat folders

    func testANewChatsFolderIsNamedForTheDayAndNeverReusesOne() throws {
        let chats = ChatWorkspaces.yardletRoot(home: home)
        let day = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: .current, year: 2026, month: 10, day: 12, hour: 23, minute: 30)))
        XCTAssertEqual(ChatWorkspaces.dayName(for: day), "2026-10-12")

        let first = try ChatWorkspaces.makeFolder(in: chats, on: day)
        XCTAssertEqual(first.path(percentEncoded: false),
                       chats.appending(path: "2026-10-12/new-chat").path(percentEncoded: false))
        let second = try ChatWorkspaces.makeFolder(in: chats, on: day)
        XCTAssertEqual(second.lastPathComponent, "new-chat-2")
        // A folder someone else made with the next name is skipped, not reused.
        try FileManager.default.createDirectory(at: chats.appending(path: "2026-10-12/new-chat-3"),
                                                withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: chats.appending(path: "2026-10-12/new-chat-3/notes.txt"))
        XCTAssertEqual(try ChatWorkspaces.makeFolder(in: chats, on: day).lastPathComponent, "new-chat-4")
        XCTAssertEqual(try String(contentsOf: chats.appending(path: "2026-10-12/new-chat-3/notes.txt"), encoding: .utf8),
                       "kept")
        let nextDay = day.addingTimeInterval(3_600)
        XCTAssertEqual(try ChatWorkspaces.makeFolder(in: chats, on: nextDay).path(percentEncoded: false),
                       chats.appending(path: "2026-10-13/new-chat").path(percentEncoded: false))
        XCTAssertTrue(ChatWorkspaces.isChat(first, home: home))
    }

    // MARK: - The new-task draft

    func testTheDraftStartsAChatWithoutAFolder() throws {
        let project = URL(filePath: "/tmp/chat-placement-project")
        let draft = NewTaskDraft()
        draft.prepare(defaultWorkspaceURL: project, availableHarnesses: [.claudeCode])
        draft.text = "Plan the weekend trip"
        draft.setStartsInNewWorktree(true, projectID: UUID())
        draft.chooseChat()
        XCTAssertTrue(draft.startsChat)
        XCTAssertNil(draft.workspaceURL)
        XCTAssertNil(draft.projectID)
        XCTAssertTrue(draft.canCreate(runtimeURL: URL(filePath: "/usr/bin/true")))

        // The choice survives navigation and a relaunch, as the chosen folder does.
        draft.prepare(defaultWorkspaceURL: project, availableHarnesses: [.claudeCode])
        XCTAssertTrue(draft.startsChat)
        let restored = NewTaskDraft()
        restored.apply(draft.snapshot)
        XCTAssertTrue(restored.startsChat)
        XCTAssertNil(restored.workspaceURL)
        let old = try JSONDecoder().decode(HomeDraftSnapshot.self, from: Data(#"{"text":"x","hasPreparedWorkspace":true}"#.utf8))
        XCTAssertNil(old.startsChat, "A draft saved before chats starts in its folder")

        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: URL(filePath: "/usr/bin/true"),
                                                             startsInNewWorktree: true))
        XCTAssertNil(submission.workspaceURL)
        XCTAssertTrue(submission.startsChat)
        XCTAssertNil(submission.projectID)
        XCTAssertFalse(submission.startsInNewWorktree, "A chat's folder has no repository to branch")
        draft.complete(submission, succeeded: true)
        XCTAssertEqual(draft.text, "", "A started chat clears the draft")
        XCTAssertTrue(draft.startsChat, "The next task starts as a chat again")

        // Choosing a project or a folder is choosing not to start a chat.
        draft.workspaceURL = project
        XCTAssertFalse(draft.startsChat)
        XCTAssertFalse(NewTaskDraft().startsChat)

        // With no project chosen the home starts a chat: the project removed, or none to start in.
        draft.workspaceURL = nil
        XCTAssertTrue(draft.startsChat)
        let empty = NewTaskDraft()
        empty.prepare(defaultWorkspaceURL: nil, availableHarnesses: [.claudeCode])
        empty.text = "Plan the weekend trip"
        XCTAssertTrue(empty.startsChat)
        XCTAssertNil(try XCTUnwrap(empty.beginSubmission(runtimeURL: URL(filePath: "/usr/bin/true"))).workspaceURL)
    }

    // MARK: - App model

    func testANewChatGetsItsOwnFolderAndNoProject() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let draft = NewTaskDraft()
        draft.prepare(defaultWorkspaceURL: nil, availableHarnesses: [.claudeCode])
        draft.chooseChat()
        draft.text = "Plan the weekend trip"
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.cli))
        let result = try await model.createTask(submission)
        let created = try XCTUnwrap(result)

        let today = ChatWorkspaces.dayName(for: Date())
        let folder = ChatWorkspaces.yardletRoot(home: home).appending(path: "\(today)/new-chat")
        XCTAssertEqual(created.workspaceURL.path(percentEncoded: false), Project.canonical(folder).path(percentEncoded: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        XCTAssertNil(created.projectID)
        XCTAssertTrue(created.additionalRoots.isEmpty)
        XCTAssertTrue(model.projects.projects.isEmpty, "A chat makes no project")
        XCTAssertNil(model.project(for: created))
        XCTAssertEqual(model.projects.chats(sessions: model.store.sessions).map(\.id), [created.id])
        XCTAssertTrue(model.projects.visibleGroups(sessions: model.store.sessions).isEmpty)
        let started = await fixture.adapter.createdWorkspaces
        XCTAssertEqual(started.map { $0.path(percentEncoded: false) }, [created.workspaceURL.path(percentEncoded: false)])

        // The next chat gets the next folder.
        draft.complete(submission, succeeded: true)
        draft.text = "Another question"
        let next = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.cli))
        let nextResult = try await model.createTask(next)
        let second = try XCTUnwrap(nextResult)
        XCTAssertEqual(second.workspaceURL.lastPathComponent, "new-chat-2")
        XCTAssertTrue(model.projects.projects.isEmpty)
    }

    func testATaskInAFolderGetsNoProjectUnlessThePersonAddedIt() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let codexChat = home.appending(path: "Documents/Codex/2026-10-09/new-chat", directoryHint: .isDirectory)
        let explicit = home.appending(path: "Documents/Yardlet/2026-10-01/notes", directoryHint: .isDirectory)
        let plain = root.appending(path: "plain-project", directoryHint: .isDirectory)
        for folder in [codexChat, explicit, plain] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        XCTAssertNil(model.projectForNewTask(workspaceURL: codexChat, projectID: nil))
        let added = model.projects.ensureProject(forRoot: explicit, name: "Notes")

        let chatResult = await model.createSession(
            harness: .claudeCode, workspaceURL: codexChat, runtimeExecutableURL: fixture.cli, title: "Chat")
        let inProjectResult = await model.createSession(
            harness: .claudeCode, workspaceURL: explicit, runtimeExecutableURL: fixture.cli, title: "Notes task")
        let ordinaryResult = await model.createSession(
            harness: .claudeCode, workspaceURL: plain, runtimeExecutableURL: fixture.cli, title: "Project task")
        let chat = try XCTUnwrap(chatResult)
        let inProject = try XCTUnwrap(inProjectResult)
        let ordinary = try XCTUnwrap(ordinaryResult)
        XCTAssertNil(chat.projectID)
        XCTAssertEqual(inProject.projectID, added.id, "A chat's folder the person added stays a project")
        XCTAssertNil(ordinary.projectID, "Any other folder is no project until the person adds it")
        XCTAssertFalse(ordinary.isMovedToChats)
        XCTAssertEqual(model.projects.projects.map(\.name), ["Notes"])
        XCTAssertEqual(Set(model.projects.chats(sessions: model.store.sessions).map(\.id)), [chat.id, ordinary.id])

        // A project the person hid stays hidden with its tasks; a new task in its folder is a chat,
        // kept in Chats, and shows it nowhere.
        model.projects.hide(added.id)
        let besideHiddenResult = await model.createSession(
            harness: .claudeCode, workspaceURL: explicit, runtimeExecutableURL: fixture.cli, title: "After hiding")
        let besideHidden = try XCTUnwrap(besideHiddenResult)
        XCTAssertNil(besideHidden.projectID)
        XCTAssertTrue(besideHidden.isMovedToChats)
        XCTAssertEqual(model.projects.project(id: added.id)?.isHidden, true)
        XCTAssertEqual(Set(model.projects.chats(sessions: model.store.sessions).map(\.id)),
                       [chat.id, ordinary.id, besideHidden.id])
        XCTAssertFalse(model.projects.visibleGroups(sessions: model.store.sessions).flatMap(\.sessions)
            .contains { $0.id == inProject.id }, "Its earlier task stays hidden with it")
        // Named by its ID, as a child of its task or a schedule names it, it stays hidden all the same.
        XCTAssertNil(model.projectForNewTask(workspaceURL: explicit, projectID: added.id))
        let namedResult = await model.createSession(
            harness: .claudeCode, workspaceURL: explicit, runtimeExecutableURL: fixture.cli, title: "Named",
            projectID: added.id)
        let named = try XCTUnwrap(namedResult)
        XCTAssertNil(named.projectID)
        XCTAssertTrue(named.isMovedToChats)
        // And by its folder, as `create_task` names one.
        let caller = try XCTUnwrap(model.sessionToolCaller(chat.id))
        XCTAssertNil(try model.sessionToolPlace(explicit.path(percentEncoded: false), caller: caller).get().project)

        // So does a conversation imported or followed from another app in its folder.
        let conversation = ImportableConversation(
            harness: .claudeCode, providerSessionID: "55555555-2222-4333-8444-666666666666", title: "From the app",
            workspaceURL: explicit, updatedAt: Date(), isOpenElsewhere: false)
        XCTAssertEqual(model.importDestination(for: conversation), .chats)
        let importedResult = await model.importConversation(conversation, connection: nil)
        let imported = try XCTUnwrap(importedResult)
        XCTAssertNil(imported.projectID)
        XCTAssertTrue(imported.isMovedToChats)
        XCTAssertEqual(model.projects.project(id: added.id)?.isHidden, true)
    }

    func testAConversationImportedFromAChatFolderStaysAChat() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let scratch = home.appending(path: "Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let config = root.appending(path: "claude-config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
                                         homePath: config.path(percentEncoded: false), credentialSelector: nil)
        let conversation = ImportableConversation(
            harness: .claudeCode, providerSessionID: "44444444-2222-4333-8444-555555555555", title: "Plan the trip",
            workspaceURL: scratch, updatedAt: Date(), isOpenElsewhere: false)

        let importResult = await model.importConversation(conversation, connection: account)
        let imported = try XCTUnwrap(importResult)
        XCTAssertNil(imported.projectID)
        XCTAssertTrue(imported.additionalRoots.isEmpty)
        XCTAssertTrue(model.projects.projects.isEmpty, "Importing a chat makes no project")
        XCTAssertEqual(model.projects.chats(sessions: model.store.sessions).map(\.id), [imported.id])
        // Importing starts no runtime; the chat resumes when the person first sends.
        let resumed = await fixture.adapter.resumed
        XCTAssertEqual(resumed, [])
        XCTAssertEqual(imported.providerSessionID, conversation.providerSessionID)
    }

    /// The new-task screen offers a chat as a destination in its folder control, not as a button
    /// of its own; chosen, the control names it and the screen asks for no folder.
    func testTheNewTaskScreenOffersAChatAsItsDestination() throws {
        let suite = testDefaultsSuite("ChatPlacement")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let project = Project(name: "yardlet-sandbox", primaryRoot: URL(filePath: "/tmp/chat-placement-sandbox"))
        let draft = NewTaskDraft()
        draft.harness = .claudeCode
        draft.text = "Plan the weekend trip"
        draft.chooseChat()

        let directory = try WindowlessRender.directory("sidebar-qa")
        var lightElements: [WindowlessRender.AccessibilityElement] = []
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                            onSelectSession: { _ in }, onShowHarnesses: {},
                            onCreate: { _ in nil })
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: 860, height: 300, alignment: .top)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 860, height: 300), appearance: appearance)
            host.settle()
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "new-task-chat-\(appearance.suffix).png"))
            if appearance == .light { lightElements = host.accessibilityElements() }
            host.close()
        }
        // The menu button's value is the destination; AppKit names the button itself.
        XCTAssertTrue(lightElements.contains { $0.role == "AXMenuButton" && $0.value == L10n.string("Chat (no project)") },
                      "\(lightElements)")
        XCTAssertFalse(lightElements.contains { $0.label == L10n.string("Where to run") }, "No worktree for a chat")
    }

    // MARK: - Helpers

    private struct Fixture {
        let model: AppModel
        let adapter: ChatRecorder
        let cli: URL
    }

    private func makeModel() throws -> Fixture {
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let adapter = ChatRecorder()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                             runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
                             registry: HarnessRegistry { _, _ in adapter }, chatWorkspaceHome: home,
                             restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(cli, for: .claudeCode)
        return Fixture(model: model, adapter: adapter, cli: cli)
    }

    /// A Claude adapter that records the sessions it starts and resumes, and sends nothing.
    private actor ChatRecorder: HarnessAdapter {
        nonisolated let kind = HarnessKind.claudeCode
        private(set) var createdWorkspaces: [URL] = []
        private(set) var resumed: [String] = []
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            createdWorkspaces.append(request.workspaceURL)
            return HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                        providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
            -> HarnessSessionHandle {
            resumed.append(providerSessionID)
            return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                        workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle)
            async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            AsyncStream { $0.finish() }
        }
        func close(_ session: HarnessSessionHandle) async {}
    }
}
