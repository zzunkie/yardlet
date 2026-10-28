import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The new-task screen's terminal, browser, files and side panel, drawn in the whole main window,
/// light and dark, into `.build/draft-tools-qa/<phase>/` (`DRAFT_TOOLS_QA_PHASE`, "after" by
/// default), with what its title bar offers (`report.md`).
///
/// No provider is contacted and no task attaches; the buttons are pressed through accessibility, as
/// VoiceOver presses them.
@MainActor
final class DraftToolsQATests: XCTestCase {
    private static let size = NSSize(width: 1280, height: 760)
    private static var folder: String {
        "draft-tools-qa/" + (ProcessInfo.processInfo.environment["DRAFT_TOOLS_QA_PHASE"] ?? "after")
    }

    private struct Fixture {
        let model: AppModel
        let folder: URL
        /// Another project's folder, for a folder chosen after the terminal opened.
        let otherFolder: URL
        let other: SessionRecord
        let cli: URL
        let launch: ShellLaunchEnvironment
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-draft-tools-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        let otherFolder = root.appending(path: "notes-app")
        let shellHome = root.appending(path: "shell")
        for directory in [folder, otherFolder, shellHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "# Yardlet\n".write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("DraftToolsQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let other = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                  title: "Tidy the release notes")
        let sessions = [other]
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in Recorder() },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(cli, for: .claudeCode)
        let project = model.projects.ensureProject(forRoot: folder)
        _ = model.projects.ensureProject(forRoot: otherFolder)
        model.composerDrafts.home.projectID = project.id
        model.composerDrafts.home.workspaceURL = folder
        model.composerDrafts.home.harness = .claudeCode
        return Fixture(model: model, folder: folder, otherFolder: otherFolder, other: other, cli: cli,
                       launch: .isolatedZsh(in: shellHome))
    }

    private func window(_ fixture: Fixture, _ appearance: WindowlessRender.Appearance) -> some View {
        MainWindow(model: fixture.model)
            .environment(\.terminalShellLaunch, fixture.launch)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    // MARK: - Accessibility with frames

    private struct Control {
        let role: String
        let label: String
        /// In the window, top-left origin.
        let frame: NSRect
        let object: AnyObject
    }

    private static func withEnhancedInterface<T>(_ body: () -> T) -> T {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        return body()
    }

    private func elements<Content: View>(in host: WindowlessRender.Host<Content>, buttonsOnly: Bool = true) -> [Control] {
        host.hosting.layoutSubtreeIfNeeded()
        let windowFrame = host.window.frame
        return Self.withEnhancedInterface {
            var found: [Control] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if let role = child.accessibilityRole?() ?? nil,
                       !buttonsOnly || [.button, .menuButton, .popUpButton, .checkBox].contains(role) {
                        let label = (child.accessibilityLabel?() ?? nil) ?? ""
                        let screen = child.accessibilityFrame?() ?? .zero
                        let frame = NSRect(x: screen.minX - windowFrame.minX,
                                           y: windowFrame.maxY - screen.maxY,
                                           width: screen.width, height: screen.height)
                        found.append(Control(role: role.rawValue, label: label, frame: frame, object: child))
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    private func controls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        elements(in: host).filter { $0.frame.height > 0 }
    }

    @discardableResult
    private func press<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>,
                                      titleBar: Bool = false) -> Bool {
        let pool = titleBar ? titleBarControls(in: host) : controls(in: host)
        guard let control = pool.first(where: { $0.label == label }) else { return false }
        let pressed = Self.withEnhancedInterface { control.object.accessibilityPerformPress?() ?? false }
        host.settle(passes: 12, interval: 0.03)
        return pressed
    }

    /// Clicks and keys reach SwiftUI only in an ordered window: transparent and off screen.
    private func orderIn<Content: View>(_ host: WindowlessRender.Host<Content>) {
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 10, interval: 0.03)
    }

    /// A ⌘-key as the keyboard sends it: the window's key equivalents first.
    private func commandKey<Content: View>(_ character: String, in host: WindowlessRender.Host<Content>) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: host.window.windowNumber, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: Self.keyCodes[character] ?? 0)
        else { return false }
        let handled = host.window.performKeyEquivalent(with: event)
        host.settle(passes: 12, interval: 0.03)
        return handled
    }

    private static let keyCodes: [String: UInt16] = ["1": 18, "3": 20, "4": 21]

    private func terminalView(in view: NSView) -> NativeTerminalView? {
        if let view = view as? NativeTerminalView { return view }
        for subview in view.subviews {
            if let found = terminalView(in: subview) { return found }
        }
        return nil
    }

    private func terminalText<Content: View>(in host: WindowlessRender.Host<Content>) -> String {
        terminalView(in: host.hosting)?.getTerminal().unwrappedText ?? ""
    }

    private func waitFor<Content: View>(_ text: String, in host: WindowlessRender.Host<Content>) -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            host.settle(passes: 1, interval: 0.05)
            if terminalText(in: host).components(separatedBy: "\n").contains(where: { $0.hasPrefix(text) }) { return true }
        }
        return false
    }

    /// Waits for the shell's prompt, then runs `command`.
    private func run<Content: View>(_ command: String, in host: WindowlessRender.Host<Content>) {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, terminalView(in: host.hosting)?.process.running != true {
            host.settle(passes: 1, interval: 0.05)
        }
        host.settle(passes: 10, interval: 0.05)
        terminalView(in: host.hosting)?.send(txt: command)
        host.settle(passes: 6, interval: 0.05)
        terminalView(in: host.hosting)?.send(txt: "\r")
    }

    private static func isAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    /// Runs async work while the window's run loop turns. The test itself stays synchronous: run loop
    /// turns inside a main-actor job would hold back the main queue (the shell's output, a panel's
    /// deferred check) until the job ended.
    private func perform<T, Content: View>(in host: WindowlessRender.Host<Content>,
                                           _ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while result == nil, ContinuousClock.now < deadline { host.settle(passes: 1, interval: 0.02) }
        return try XCTUnwrap(result).get()
    }

    /// The buttons in the title bar's band, left to right.
    private func titleBarControls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        elements(in: host)
            .filter { $0.frame.midY < ParityTheme.titleBarHeight && $0.frame.height > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - Report

    private var report: [String] = []
    /// The light pass writes the report; the dark pass draws the same states.
    private var recordsReport = true

    private func describe(_ state: String, _ controls: [Control], notes: [String] = []) {
        guard recordsReport else { return }
        report.append("## \(state)")
        report.append("")
        let lines = controls.map { "- \($0.label.isEmpty ? "(no name)" : $0.label) [\($0.role)]" }
        report.append(contentsOf: lines.isEmpty ? ["- (no buttons)"] : lines)
        for note in notes { report.append("- Check: \(note)") }
        report.append("")
    }

    private func draw<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                     _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    private func writeReport() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try (["# Title bar buttons and panels on the new-task screen", ""] + report).joined(separator: "\n")
            .write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - States

    func testNewTaskScreenOffersTheTaskScreensPanels() throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            recordsReport = appearance == .light
            try newTaskScreen(appearance)
        }
        try writeReport()
    }

    /// The new-task screen's buttons, launcher, files, terminal, keys and folder notice, then the task
    /// it starts taking them over, then leaving and coming back.
    private func newTaskScreen(_ appearance: WindowlessRender.Appearance) throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let draftWorkspace = model.taskWorkspaces.draft
        let showTerminal = TaskCommandTitle.terminal(isShown: false)
        let showSidePanel = TaskCommandTitle.sidePanel(isShown: false)

        do {
            model.splits.showNewTask()
            let host = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "home", appearance)
            let titleBar = titleBarControls(in: host)
            describe("New-task screen (1280×760)", titleBar)
            XCTAssertTrue(titleBar.contains { $0.label == showTerminal }, "\(titleBar.map(\.label))")
            XCTAssertTrue(titleBar.contains { $0.label == showSidePanel })
            XCTAssertFalse(titleBar.contains { $0.label == L10n.string("Show session rail") }, "no task for a rail")
            orderIn(host)

            // The side panel opens to the launcher: what the screen can open, and other tasks.
            XCTAssertTrue(press(showSidePanel, in: host, titleBar: true))
            XCTAssertEqual(draftWorkspace.panels.trailingSurfaceID, TaskSurfaceNavigationProjection.launcherID)
            let launcher = controls(in: host).map(\.label)
            for choice in TaskSidePanelTabs.draftChoices { XCTAssertTrue(launcher.contains(choice.title), "\(launcher)") }
            XCTAssertFalse(launcher.contains(L10n.string("Review")), "Review needs a task")
            XCTAssertFalse(launcher.contains(L10n.string("Side chat")), "a side chat needs a task")
            XCTAssertTrue(launcher.contains(fixture.other.title), "another task's conversation can open here")
            try draw(host, "home-launcher", appearance)
            describe("Right panel (launcher)", [], notes: ["Launcher row: " + TaskSidePanelTabs.draftChoices.map(\.title).joined(separator: "·")
                + ", '\(fixture.other.title)' in the task list, no Review or side chat"])

            // Files in the draft's folder, from the launcher.
            XCTAssertTrue(press(L10n.string("Files"), in: host))
            XCTAssertEqual(draftWorkspace.panels.trailingSurfaceID, "files")
            host.settle(passes: 20, interval: 0.03)
            try draw(host, "home-files", appearance)

            // The terminal, from the title bar. ⌘1 returns to the composer (the terminal hides and its
            // shell goes on, as on a task); ⌘3 and ⌘4 open the terminal and the browser, as on a task.
            XCTAssertTrue(press(showTerminal, in: host, titleBar: true))
            XCTAssertTrue(draftWorkspace.panels.isTerminalPresented)
            let one = commandKey("1", in: host)
            let afterOne = draftWorkspace.panels
            let three = commandKey("3", in: host)
            let afterThree = draftWorkspace.panels
            let four = commandKey("4", in: host)
            let afterFour = draftWorkspace.panels
            XCTAssertFalse(afterOne.isTerminalPresented, "⌘1 returns to the composer")
            XCTAssertNil(afterOne.trailingSurfaceID)
            XCTAssertTrue(afterThree.isTerminalPresented, "⌘3 opens the terminal")
            XCTAssertNotNil(TaskSurfaceNavigationProjection.browserKey(inTab: afterFour.trailingSurfaceID),
                            "⌘4 opens a browser tab")
            describe("New-task screen keys", [], notes: [
                "⌘1 handled \(one) → terminal \(afterOne.isTerminalPresented ? "open" : "closed"), right panel \(afterOne.trailingSurfaceID ?? "closed")",
                "⌘3 handled \(three) → terminal \(afterThree.isTerminalPresented ? "open" : "closed")",
                "⌘4 handled \(four) → right panel \(afterFour.trailingSurfaceID ?? "closed")"
            ])

            // A shell in the draft's folder.
            run("export DRAFT_MARK=draft-$$; printf 'DRAFT-%s\\n' \"$DRAFT_MARK\" \"$PWD\"", in: host)
            XCTAssertTrue(waitFor("DRAFT-draft-", in: host), terminalText(in: host))
            let shellPID = try XCTUnwrap(terminalView(in: host.hosting)?.process.shellPid)
            XCTAssertTrue(terminalText(in: host).contains("DRAFT-/"), "it printed its folder")
            XCTAssertTrue(terminalText(in: host).contains(fixture.folder.lastPathComponent), "the draft's folder")
            try draw(host, "home-terminal-browser", appearance)

            // A folder chosen after the terminal opened: the shell stays, and says so (Codex app).
            model.composerDrafts.home.workspaceURL = fixture.otherFolder
            model.composerDrafts.home.projectID = model.projects.project(containingRoot: fixture.otherFolder)?.id
            host.settle(passes: 20, interval: 0.03)
            let notice = L10n.format("This terminal opened in %@, outside the task's folder.", fixture.folder.lastPathComponent)
            let restartLabel = L10n.format("Restart in %@", fixture.otherFolder.lastPathComponent)
            let noticeShown = elements(in: host, buttonsOnly: false).contains { $0.label == notice }
                || controls(in: host).contains { $0.label == restartLabel }
            XCTAssertTrue(noticeShown, "the folder notice")
            XCTAssertEqual(terminalView(in: host.hosting)?.process.shellPid, shellPID, "the shell stays where it is")
            try draw(host, "home-folder-changed", appearance)
            XCTAssertTrue(press(L10n.string("Dismiss"), in: host))
            let dismissed = !controls(in: host).contains { $0.label == restartLabel }
            XCTAssertTrue(dismissed)
            describe("Folder changed after the terminal opened", [], notes: [
                "Notice '\(notice)' and '\(restartLabel)' \(noticeShown ? "shown" : "not shown"), shell pid unchanged",
                "Dismiss → notice \(dismissed ? "gone" : "still there")"
            ])
            model.composerDrafts.home.workspaceURL = fixture.folder
            model.composerDrafts.home.projectID = model.projects.project(containingRoot: fixture.folder)?.id
            host.settle(passes: 12, interval: 0.03)

            // Starting the task: the task takes over the panels, the shell and the page's model.
            let browserModel = draftWorkspace.browserTabs
            let files = draftWorkspace.files
            let panelsBefore = draftWorkspace.panels
            let draft = model.composerDrafts.home
            draft.text = "Fix the sign-in screen"
            var submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.cli))
            submission.takesDraftWorkspace = true
            let result = try perform(in: host) { try await model.createTask(submission) }
            let created = try XCTUnwrap(result)
            draft.complete(submission, succeeded: true)
            host.settle(passes: 30, interval: 0.03)
            XCTAssertEqual(model.splits.selection, .session(created.id))
            let task = model.taskWorkspaces.state(for: created.id)
            XCTAssertEqual(task.panels, panelsBefore)
            XCTAssertTrue(task.browserTabs === browserModel)
            XCTAssertTrue(task.files === files)
            let taskShell = terminalView(in: host.hosting)?.process.shellPid
            XCTAssertEqual(taskShell, shellPID, "the same shell, not started again")
            XCTAssertTrue(Self.isAlive(shellPID))
            run("printf 'TASK-%s\\n' \"$DRAFT_MARK\"", in: host)
            XCTAssertTrue(waitFor("TASK-draft-", in: host), "the shell kept its variables: \(terminalText(in: host))")
            XCTAssertTrue(terminalText(in: host).contains("DRAFT-draft-"), "and its scrollback")
            XCTAssertEqual(draftWorkspace.panels, .init(), "the new-task screen starts over")
            let taskTitleBar = titleBarControls(in: host)
            try draw(host, "task-after-handoff", appearance)
            describe("After the task is created (the same tab becomes the task)", taskTitleBar, notes: [
                "Panels \(task.panels == panelsBefore ? "same" : "different"), shell pid \(shellPID) → \(taskShell.map(String.init) ?? "none"), variables and scrollback carried over",
                "Browser model and file state are the same objects, the new-task screen's panels are empty"
            ])

            // Back on the new-task screen: empty, and its next shell is a new one. The task left the
            // screen for the new tab and its shell goes on, as a thread's terminal does in the Codex app.
            model.splits.newTab()
            host.settle(passes: 20, interval: 0.03)
            XCTAssertFalse(terminalText(in: host).contains("DRAFT-draft-"), "a new draft has no terminal")
            XCTAssertTrue(press(showTerminal, in: host, titleBar: true))
            run("printf 'NEXT-%s\\n' \"${DRAFT_MARK:-none}\"", in: host)
            XCTAssertTrue(waitFor("NEXT-none", in: host), terminalText(in: host))
            let nextPID = try XCTUnwrap(terminalView(in: host.hosting)?.process.shellPid)
            XCTAssertNotEqual(nextPID, shellPID)
            let taskShellLives = Self.isAlive(shellPID)
            XCTAssertTrue(taskShellLives, "a task's shell goes on while the task is off screen")

            // The task again: the same shell, with its output and variables.
            let nextShell = draftWorkspace.terminal(in: fixture.folder, launch: fixture.launch, taskID: nil)
            defer { nextShell.end() }
            model.splits.selectTab(.session(created.id))
            host.settle(passes: 20, interval: 0.05)
            XCTAssertEqual(terminalView(in: host.hosting)?.process.shellPid, shellPID, "the same shell")
            XCTAssertTrue(terminalText(in: host).contains("TASK-draft-"), "its output: \(terminalText(in: host))")
            run("printf 'BACK-%s\\n' \"$DRAFT_MARK\"", in: host)
            XCTAssertTrue(waitFor("BACK-draft-", in: host), "its variables: \(terminalText(in: host))")
            try draw(host, "task-returned", appearance)
            let draftShellLives = !nextShell.hasEnded && nextShell.isRunning && Self.isAlive(nextPID)
            XCTAssertTrue(draftShellLives, "the new-task screen's shell goes on too")

            // Back on the new-task screen: its shell, as it was.
            model.splits.selectTab(.home)
            host.settle(passes: 20, interval: 0.03)
            XCTAssertEqual(terminalView(in: host.hosting)?.process.shellPid, nextPID)
            let draftOutput = terminalText(in: host).contains("NEXT-none")
            XCTAssertTrue(draftOutput, "its output: \(terminalText(in: host))")

            // Archiving the task ends its shell, as archiving a thread closes its terminals in the Codex app.
            let record = try XCTUnwrap(model.store.sessions.first { $0.id == created.id })
            try perform(in: host) { await model.archive(record) }
            let deadline = ContinuousClock.now + .seconds(5)
            while Self.isAlive(shellPID), ContinuousClock.now < deadline { host.settle(passes: 1, interval: 0.05) }
            let archivedShellEnded = !Self.isAlive(shellPID)
            XCTAssertTrue(archivedShellEnded, "archiving the task ends its shell")
            XCTAssertTrue(Self.isAlive(nextPID), "and only its own")
            describe("Left the task and the new-task screen and came back", [], notes: [
                "When a new tab takes the task off the screen, the task shell \(shellPID) \(taskShellLives ? "goes on" : "ended")",
                "Back on the task: the same shell, its output and variables; the new-task screen's shell \(nextPID) \(draftShellLives ? "goes on" : "ended")",
                "Back on the new-task screen: the same shell, its output \(draftOutput ? "kept" : "missing")",
                "Archiving the task: its shell \(archivedShellEnded ? "ended" : "remains")"
            ])
            try draw(host, "home-returned", appearance)
            host.close()
        }
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
        /// Open until the task closes, as a live harness's are: a finished stream reads as a lost connection.
        private var streams: [AsyncStream<HarnessEventEnvelope>.Continuation] = []
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
            streams.append(continuation)
            return stream
        }
        func close(_ session: HarnessSessionHandle) async {
            streams.forEach { $0.finish() }
            streams.removeAll()
        }
    }
}
