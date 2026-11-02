import AppKit
import SwiftTerm
import XCTest
@testable import NativeHarnessClient

/// The new-task screen's terminal, browser and side panel, and the task it starts taking them over
/// as they are (the Codex app's thread takes over its draft's tabs).
@MainActor
final class DraftToolsTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    // MARK: - Browser tabs

    func testABrowserTabMovesToAnotherTaskWithItsPage() throws {
        let connection = FakeConnection()
        let client = BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(80)) { connection }
        let draft = UUID()
        let task = UUID()
        let first = try client.openTab(forSession: draft, url: "https://a.test", viewport: .offscreenDefault)
        let second = try client.newTab(forSession: draft, url: "https://b.test", viewport: .offscreenDefault, select: true)
        let third = try client.newTab(forSession: draft, url: "https://c.test", viewport: .offscreenDefault, select: false)
        connection.eventHandler?(.address(tab: first.id, url: "https://a.test/page"))
        let sentBefore = connection.sent.count
        var draftChanges = 0
        var taskChanges = 0
        _ = client.addTabsObserver(forSession: draft) { draftChanges += 1 }
        _ = client.addTabsObserver(forSession: task) { taskChanges += 1 }

        // One tab: it leaves the draft's strip and joins the task's, page and all.
        try client.move(first, toSession: task, select: false)
        XCTAssertEqual(first.session, task)
        XCTAssertEqual(client.tabs(forSession: draft).map(\.id), [second.id, third.id])
        XCTAssertTrue(client.tab(forSession: task) === first, "a task with no tab in front fronts the one it gets")
        XCTAssertTrue(client.tab(forSession: draft) === second, "the draft keeps its own front")
        XCTAssertEqual(connection.sent.count, sentBefore, "nothing reaches the host: the page goes on")
        XCTAssertNil(try client.reopenClosedTab(forSession: draft, viewport: .offscreenDefault),
                     "a moved tab was not closed, so it is not on the reopen list")
        XCTAssertGreaterThan(draftChanges, 0)
        XCTAssertGreaterThan(taskChanges, 0)

        // The rest in strip order, the draft's front still in front.
        client.moveTabs(fromSession: draft, toSession: task)
        XCTAssertEqual(client.tabs(forSession: task).map(\.id), [first.id, second.id, third.id])
        XCTAssertTrue(client.tab(forSession: task) === second, "the draft's front is the task's front")
        XCTAssertTrue(client.tabs(forSession: draft).isEmpty)
        XCTAssertFalse(connection.sent.contains { if case .close = $0 { true } else { false } }, "no tab closed")
        XCTAssertEqual(connection.sent.count, sentBefore)

        // A task that already has as many tabs as one can keep does not take another.
        let full = UUID()
        for index in 0..<BrowserHostClient.maxTabsPerSession {
            _ = try client.newTab(forSession: full, url: "https://\(index).test", viewport: .offscreenDefault, select: false)
        }
        XCTAssertThrowsError(try client.move(first, toSession: full, select: true))
        XCTAssertEqual(first.session, task)
    }

    // MARK: - Workspace state

    func testTheTaskTakesOverTheNewTaskScreensPanelsAndShell() throws {
        let store = TaskWorkspaceStore()
        let draft = store.draft
        let folder = FileManager.default.temporaryDirectory
        let browserKey = try XCTUnwrap(draft.openBrowserTab(address: "https://example.test"))
        draft.setPanels(TaskSurfaceNavigationProjection.showing(
            "files", in: .init(isTerminalPresented: true, trailingTabs: draft.panels.trailingTabs)))
        draft.terminalStartRequested = true
        draft.files.preferences.selectedPath = "README.md"
        let files = draft.files
        let browser = draft.browserTabs
        let first = draft.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertTrue(draft.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === first,
                      "the workspace keeps its tabs")
        let shell = draft.openTerminalTab(in: folder, launch: .userLoginShell(), taskID: nil)
        let panels = draft.panels

        let taskID = UUID()
        store.handOffDraft(to: taskID)
        let task = store.state(for: taskID)
        XCTAssertEqual(task.panels, panels)
        XCTAssertTrue(task.terminalStartRequested)
        XCTAssertTrue(task.files === files, "the Files panel's state, unsaved edits included")
        XCTAssertTrue(task.browserTabs === browser, "the browser tabs' pages, the WebKit pages among them")
        XCTAssertTrue(task.terminal(in: URL(filePath: "/elsewhere"), launch: .userLoginShell(), taskID: taskID) === shell,
                      "the same shell goes on, shown")
        XCTAssertTrue(task.terminals.elementsEqual([first, shell], by: ===), "every tab goes on")
        XCTAssertEqual(shell.taskID, taskID, "it counts toward the task now")
        XCTAssertEqual(first.taskID, taskID)
        XCTAssertEqual(task.snapshot.browser?.pages, [BrowserTabPage(key: browserKey, address: "https://example.test", title: "")])

        // The new-task screen starts over empty, as the Codex app's does with a new draft.
        XCTAssertEqual(draft.panels, .init())
        XCTAssertFalse(draft.terminalStartRequested)
        XCTAssertFalse(draft.files === files)
        XCTAssertFalse(draft.browserTabs === browser)
        XCTAssertNil(draft.browserTabs.tab(browserKey))
        XCTAssertFalse(draft.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === shell)
        XCTAssertEqual(draft.terminals.count, 1)
        XCTAssertFalse(shell.hasEnded)
        XCTAssertFalse(first.hasEnded)
        first.end()
        XCTAssertTrue(task.terminals.elementsEqual([shell], by: ===), "a tab that ends leaves the task's tabs")
    }

    /// Each task keeps several terminal tabs, as the Claude app's sessions and the Codex app's threads
    /// do: + opens one in the task's folder and shows it, each takes the lowest number no tab has for
    /// its title, and closing one shows the tab after it, else the one before. A tab whose shell ended
    /// leaves; with none left the panel hides, and the next opens a new tab.
    func testATaskKeepsSeveralTerminalTabs() throws {
        let workspace = TaskWorkspaceState()
        let folder = URL(filePath: "/tmp/yardlet")
        let first = workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        let second = workspace.openTerminalTab(in: folder, launch: .userLoginShell(), taskID: nil)
        let third = workspace.openTerminalTab(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertTrue(workspace.terminals.elementsEqual([first, second, third], by: ===))
        XCTAssertTrue(workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === third, "+ shows its tab")
        XCTAssertEqual(workspace.terminals.map(\.number), [1, 2, 3])
        XCTAssertEqual(workspace.terminals.map(TerminalTabTitle.defaultTitle), ["yardlet", "yardlet 2", "yardlet 3"])

        workspace.showTerminalTab(second)
        let revision = workspace.terminalRevision
        XCTAssertTrue(workspace.closeTerminalTabs([second]))
        XCTAssertTrue(second.hasEnded, "closing a tab ends its shell")
        XCTAssertGreaterThan(workspace.terminalRevision, revision)
        XCTAssertTrue(workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === third, "the tab after it")
        let reopened = workspace.openTerminalTab(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertEqual(reopened.number, 2, "the lowest number no tab has")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(third.number, 3, "the others keep theirs")

        reopened.name = "server"
        XCTAssertEqual(TerminalTabTitle.titles(for: workspace.terminals)[ObjectIdentifier(reopened)], "server")
        workspace.restartTerminal(in: URL(filePath: "/tmp/elsewhere"), launch: .userLoginShell(), taskID: nil)
        let restarted = workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertTrue(reopened.hasEnded, "Restart in … ends the shell")
        XCTAssertTrue(workspace.terminals.elementsEqual([first, third, restarted], by: ===), "and keeps its place")
        XCTAssertEqual(restarted.name, "server")
        XCTAssertEqual(restarted.number, 2)
        XCTAssertEqual(restarted.workspaceURL.path(percentEncoded: false), "/tmp/elsewhere")

        // Split: a new tab beside the shown one; showing it changes the two sides; closing it ends the split.
        workspace.showTerminalTab(first)
        workspace.splitTerminal(in: folder, launch: .userLoginShell(), taskID: nil)
        let beside = try XCTUnwrap(workspace.splitTerminal)
        XCTAssertTrue(workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === first, "the shown tab stays")
        XCTAssertTrue(beside.focusesWhenShown, "the new half takes the keyboard")
        workspace.showTerminalTab(beside)
        XCTAssertTrue(workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === beside)
        XCTAssertTrue(workspace.splitTerminal === first, "the two change sides")
        workspace.unsplitTerminal()
        XCTAssertNil(workspace.splitTerminal)
        XCTAssertFalse(first.hasEnded, "unsplit keeps the other shell as a tab")
        workspace.splitTerminal(in: folder, launch: .userLoginShell(), taskID: nil)
        let closing = try XCTUnwrap(workspace.splitTerminal)
        XCTAssertTrue(workspace.closeTerminalTabs([closing]))
        XCTAssertNil(workspace.splitTerminal, "closing the half ends the split")
        XCTAssertTrue(workspace.closeTerminalTabs([beside]))
        workspace.showTerminalTab(first)

        third.end()
        XCTAssertTrue(workspace.terminals.elementsEqual([first, restarted], by: ===), "a shell that ended leaves")
        XCTAssertFalse(workspace.closeTerminalTabs([first, restarted]), "none left: the panel hides")
        XCTAssertTrue(workspace.terminals.isEmpty)
        let next = workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertEqual(next.number, 1)
        XCTAssertTrue(workspace.terminals.elementsEqual([next], by: ===))
    }

    /// A running shell goes on while no panel shows it, as a thread's terminal does in the Codex app,
    /// and counts toward its task meanwhile. It ends with its task (archived or deleted) and when
    /// Yardlet quits. One that never started, or exited, ends once no panel shows it, so the next
    /// panel opens a new one.
    func testAShellGoesOnWithoutAPanelAndEndsWithItsTask() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "nhc-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let launch = ShellLaunchEnvironment.isolatedZsh(in: home)
        let folder = FileManager.default.temporaryDirectory
        let store = TaskWorkspaceStore()
        let taskID = UUID()
        let shell = store.state(for: taskID).terminal(in: folder, launch: launch, taskID: taskID)
        defer { shell.stop() }
        let view = shell.view { Self.terminalView() }
        let shellPID = view.process.shellPid
        XCTAssertTrue(shell.isRunning)
        shell.panelAppeared()
        shell.panelDisappeared()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(shell.isRunning, "no panel shows it, and it goes on")
        XCTAssertFalse(shell.hasEnded)
        XCTAssertEqual(TaskProcessRegistry.shared.registered[shellPID], .task(taskID), "still the task's")
        XCTAssertTrue(store.state(for: taskID).terminal(in: folder, launch: launch, taskID: taskID) === shell,
                      "the next panel shows the same shell")

        store.remove(for: taskID)
        XCTAssertTrue(shell.hasEnded, "archiving or deleting the task ends its shell")
        XCTAssertFalse(shell.isRunning)
        XCTAssertNil(TaskProcessRegistry.shared.registered[shellPID])

        // Quitting ends the shells no panel shows.
        let other = TaskWorkspaceState().terminal(in: folder, launch: launch, taskID: nil)
        defer { other.stop() }
        _ = other.view { Self.terminalView() }
        XCTAssertTrue(other.isRunning)
        NativeSurfaceResourceRegistry.shared.stopAll()
        XCTAssertFalse(other.isRunning)

        // A shell that exited ends once no panel shows it; one shown again in the same update stays.
        let workspace = TaskWorkspaceState()
        let exited = workspace.terminal(in: folder, launch: launch, taskID: nil)
        defer { exited.stop() }
        _ = exited.view { Self.terminalView() }
        let typed = await exited.typeWhenReady("exit\n", limit: testWaitLimit)
        XCTAssertTrue(typed, "the shell reached its prompt")
        try await waitUntil { !exited.isRunning }
        XCTAssertFalse(exited.isRunning)
        exited.panelAppeared()
        exited.panelDisappeared()
        exited.panelAppeared()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(exited.hasEnded, "a panel drawn again in the same update keeps it")
        exited.panelDisappeared()
        XCTAssertFalse(exited.hasEnded, "checked after the window's update")
        try await waitUntil { exited.hasEnded }
        XCTAssertTrue(exited.hasEnded)
        XCTAssertFalse(workspace.terminal(in: folder, launch: launch, taskID: nil) === exited,
                       "the next panel opens a new shell")

        // "Restart in …" ends the shell and asks for the next one.
        let next = workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        let revision = workspace.terminalRevision
        workspace.terminalStartRequested = false
        workspace.restartTerminal(in: folder, launch: .userLoginShell(), taskID: nil)
        XCTAssertTrue(next.hasEnded)
        XCTAssertTrue(workspace.terminalStartRequested)
        XCTAssertGreaterThan(workspace.terminalRevision, revision)
        XCTAssertFalse(workspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil) === next)
    }

    private static func terminalView() -> LocalProcessTerminalView {
        LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300),
                                 font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                 options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 100))
    }

    func testTheNewTaskScreenOffersTheTerminalBrowserAndFiles() {
        XCTAssertEqual(TaskSidePanelTabs.draftChoices.map(\.id), ["terminal", "browser", "files"])
        XCTAssertEqual(TaskSidePanelTabs.draftChoices.map(\.shortcut), ["⌘3", "⌘4", nil])
        let folder = URL(filePath: "/tmp/project")
        let context = TerminalFolderContext(folders: [folder, URL(filePath: "/tmp/other")], restart: {})
        XCTAssertTrue(context.contains(URL(filePath: "/tmp/project/")))
        XCTAssertTrue(context.contains(URL(filePath: "/tmp/other")))
        XCTAssertFalse(context.contains(URL(filePath: "/tmp/project/worktree")))
    }

    // MARK: - Starting a task

    func testATaskStartedFromTheNewTaskScreenTakesOverItsPanels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-tools-\(UUID().uuidString)")
        let folder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                             runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
                             registry: HarnessRegistry { _, _ in Recorder() }, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(cli, for: .claudeCode)

        let draftWorkspace = model.taskWorkspaces.draft
        draftWorkspace.setPanels(TaskSurfaceNavigationProjection.showing(
            TaskSurfaceNavigationProjection.browserTabID(UUID()), in: .init(isTerminalPresented: true)))
        let shell = draftWorkspace.terminal(in: folder, launch: .userLoginShell(), taskID: nil)
        let panels = draftWorkspace.panels

        // A start the new-task screen did not make (a schedule, a suggested task) leaves them alone.
        let draft = NewTaskDraft()
        draft.workspaceURL = folder
        draft.prepare(defaultWorkspaceURL: folder, availableHarnesses: [.claudeCode])
        draft.text = "Check the build"
        let other = try XCTUnwrap(draft.beginSubmission(runtimeURL: cli))
        let otherResult = try await model.createTask(other)
        let otherTask = try XCTUnwrap(otherResult)
        XCTAssertEqual(model.taskWorkspaces.state(for: otherTask.id).panels, .init())
        XCTAssertEqual(draftWorkspace.panels, panels)
        draft.complete(other, succeeded: true)

        draft.text = "Fix the login page"
        var submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: cli))
        submission.takesDraftWorkspace = true
        let result = try await model.createTask(submission)
        let created = try XCTUnwrap(result)
        let task = model.taskWorkspaces.state(for: created.id)
        XCTAssertEqual(task.panels, panels)
        XCTAssertTrue(task.terminal(in: folder, launch: .userLoginShell(), taskID: created.id) === shell)
        XCTAssertEqual(shell.taskID, created.id)
        XCTAssertEqual(draftWorkspace.panels, .init(), "the new-task screen starts over")
    }

    /// A Claude adapter that starts sessions and sends nothing.
    private actor Recorder: HarnessAdapter {
        nonisolated let kind = HarnessKind.claudeCode
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
            -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
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
