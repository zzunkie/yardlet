import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The side panel in the whole main window, light and dark, into `.build/side-panel-qa/<phase>/`
/// (`YARDLET_QA_PHASE`, "after" unless set): what the panel opens to the first time in a folder
/// that is not a Git repository and in one with changes, the Review tab in a folder that is not a
/// repository and in a clean one, and another task's conversation opened from the launcher as a
/// tab, replied to there, and shown in a split pane beside the panel's task.
///
/// The folders are temporary: one plain, one repository with a change, one clean repository. No
/// provider is contacted and no task attaches; buttons are pressed through accessibility and the
/// reply is typed into the panel's composer and sent with Return.
@MainActor
final class SidePanelQATests: XCTestCase {
    private static let size = NSSize(width: 1280, height: 760)
    private static var folder: String {
        "side-panel-qa/\(ProcessInfo.processInfo.environment["YARDLET_QA_PHASE"] ?? "after")"
    }

    private struct Fixture {
        let model: AppModel
        let defaults: UserDefaults
        let plain: SessionRecord
        let dirty: SessionRecord
        let clean: SessionRecord
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=QA", "-c", "user.email=qa@example.test", "-c", "init.defaultBranch=main"]
            + arguments
        process.currentDirectoryURL = folder
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    /// - Parameter readsSavedConversations: the model reads the saved conversations as a launch does
    ///   (`restoreIndex`), which the conversations shown need; nothing else of the person's is read.
    private func makeFixture(cleanIsRunning: Bool = false, readsSavedConversations: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-side-panel-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plain = root.appending(path: "landing")
        let dirty = root.appending(path: "session-index")
        let clean = root.appending(path: "release-notes")
        for folder in [plain, dirty, clean] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("# \(folder.lastPathComponent)\n".utf8).write(to: folder.appending(path: "README.md"))
        }
        for folder in [dirty, clean] {
            try git(["init", "-q"], in: folder)
            try git(["add", "README.md"], in: folder)
            try git(["commit", "-q", "-m", "Start"], in: folder)
        }
        try Data("# session-index\n\nRead the old index once, then write the new one.\n".utf8)
            .write(to: dirty.appending(path: "README.md"))
        try Data("struct IndexMigration {}\n".utf8).write(to: dirty.appending(path: "IndexMigration.swift"))

        let suite = testDefaultsSuite("SidePanelQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = URL(filePath: "/usr/bin/true")
        let plainTask = SessionRecord(harness: .claudeCode, workspaceURL: plain, runtimeExecutableURL: cli,
                                      title: "Polish the landing page copy")
        let dirtyTask = SessionRecord(harness: .codex, workspaceURL: dirty, runtimeExecutableURL: cli,
                                      title: "Fix the session index migration")
        let cleanTask = SessionRecord(harness: .claudeCode, workspaceURL: clean, runtimeExecutableURL: cli,
                                      title: "Tidy the release notes", status: cleanIsRunning ? .running : .ready)
        let sessions = [plainTask, dirtyTask, cleanTask]
        let transcripts = FileTranscriptRepository(directoryURL: root.appending(path: "transcripts"))
        transcripts.save([
            TranscriptEntry(content: .user(text: "Make the first screen's title shorter.")),
            TranscriptEntry(content: .assistant(text: "I shortened the title to \"Today's work in one place\".", isStreaming: false))
        ], for: plainTask.id)
        transcripts.save([
            TranscriptEntry(content: .user(text: "Sum up this release's changes in three lines.")),
            TranscriptEntry(content: .assistant(text: "1. The side panel opens on a new tab screen.\n2. Another task's conversation opens as a panel tab.\n3. Review stays quiet in folders that aren't Git.", isStreaming: false))
        ], for: cleanTask.id)
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: transcripts,
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: readsSavedConversations
        )
        addTeardownBlock { await model.shutdown() }
        return Fixture(model: model, defaults: defaults, plain: plainTask, dirty: dirtyTask, clean: cleanTask)
    }

    private func window(_ model: AppModel, _ appearance: WindowlessRender.Appearance,
                        defaults: UserDefaults? = nil) -> some View {
        MainWindow(model: model)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, appearance.colorScheme)
            .defaultAppStorage(defaults ?? .yardlet)
    }

    private func write<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                      _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    // MARK: - Accessibility and keys

    private struct Element {
        let role: String
        let label: String
        /// In the window, top-left origin.
        let frame: NSRect
        let object: AnyObject
    }

    /// Every labelled element right of `minX`, with its frame.
    private func elements<Content: View>(in host: WindowlessRender.Host<Content>, rightOf minX: CGFloat) -> [Element] {
        host.hosting.layoutSubtreeIfNeeded()
        let windowFrame = host.window.frame
        return WindowlessRender.withAccessibilityTree {
            var found: [Element] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if let role = child.accessibilityRole?() ?? nil {
                        let label = (child.accessibilityLabel?() ?? nil) ?? ""
                        let value = ((child as? NSObject)?.value(forKey: "accessibilityValue") as? String) ?? ""
                        let screen = child.accessibilityFrame?() ?? .zero
                        let frame = NSRect(x: screen.minX - windowFrame.minX, y: windowFrame.maxY - screen.maxY,
                                           width: screen.width, height: screen.height)
                        if frame.minX >= minX, frame.width > 0 {
                            found.append(Element(role: role.rawValue, label: label.isEmpty ? value : label,
                                                 frame: frame, object: child))
                        }
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    @discardableResult
    private func press<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>,
                                      rightOf minX: CGFloat) -> Bool {
        let buttons = elements(in: host, rightOf: minX).filter { $0.role == NSAccessibility.Role.button.rawValue }
        guard let control = buttons.first(where: { $0.label == label }) else { return false }
        let pressed = WindowlessRender.withAccessibilityTree { control.object.accessibilityPerformPress?() ?? false }
        host.settle(passes: 20, interval: 0.03)
        return pressed
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }

    private func draw(_ model: AppModel, showing id: UUID, _ name: String,
                      _ appearance: WindowlessRender.Appearance) throws {
        model.splits.activate(.session(id))
        let host = WindowlessRender.Host(window(model, appearance), size: Self.size, appearance: appearance)
        defer { host.close() }
        // The Review tab reads Git in the background before it draws.
        host.settle(passes: 40, interval: 0.05)
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    private func reset(_ model: AppModel, _ ids: [UUID]) {
        for id in ids { model.taskWorkspaces.state(for: id).setPanels(.init()) }
    }

    func testWhatTheSidePanelOpensToAndTheReviewTabsQuietStates() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let all = [fixture.plain.id, fixture.dirty.id, fixture.clean.id]
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        for appearance in WindowlessRender.Appearance.allCases {
            // A task whose panel was never used, in a folder that is not a repository, then in one
            // with changes: the title bar's side panel button.
            for (task, name) in [(fixture.plain, "first-open-plain"), (fixture.dirty, "first-open-repo")] {
                let workspace = model.taskWorkspaces.state(for: task.id)
                workspace.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: workspace.panels,
                                                                                      targetID: toggle))
                try draw(model, showing: task.id, name, appearance)
            }
            reset(model, all)

            // Review chosen in a folder that is not a repository, and in a clean repository.
            for (task, name) in [(fixture.plain, "review-plain"), (fixture.clean, "review-clean")] {
                let workspace = model.taskWorkspaces.state(for: task.id)
                workspace.setPanels(TaskSurfaceNavigationProjection.showing("diff", in: workspace.panels))
                try draw(model, showing: task.id, name, appearance)
            }
            reset(model, all)
        }
    }

    /// The panel's task is the plain folder's; the other task, which is running, opens from the
    /// launcher's Tasks list as a tab. A reply typed into the tab's composer goes to that task by its
    /// rules: it is running and Yardlet holds no runtime for it, so ⌘Return (the follow-up setting's
    /// other way; Steer is the default) queues it there without attaching anything, and nothing
    /// reaches the panel's task. With the other task in a split pane beside the panel's, the tab says
    /// so and "Go to Pane" focuses that pane.
    func testAnotherTasksConversationOpensFromTheLauncherAndItsReplyKeepsThatTasksRules() async throws {
        let fixture = try makeFixture(cleanIsRunning: true, readsSavedConversations: true)
        let model = fixture.model
        await model.restoreIndex()
        XCTAssertFalse(model.transcriptBySessionID[fixture.clean.id]?.isEmpty ?? true)
        // A launch reads a running task as stopped; this one runs, with no runtime in Yardlet.
        try await model.store.updateSession(id: fixture.clean.id, status: .running)
        let owner = fixture.plain, other = fixture.clean
        let tab = TaskSurfaceNavigationProjection.taskTabID(other.id)
        let toggle = TaskSurfaceNavigationProjection.sidePanelToggleID
        let reply = "Make the third line shorter."
        for appearance in WindowlessRender.Appearance.allCases {
            let light = appearance == .light
            model.splits.activate(.session(owner.id))
            let ownerState = model.taskWorkspaces.state(for: owner.id)
            ownerState.setPanels(.init())
            ownerState.setPanels(TaskSurfaceNavigationProjection.toggledPanelState(current: ownerState.panels,
                                                                                   targetID: toggle))
            let host = WindowlessRender.Host(window(model, appearance, defaults: fixture.defaults), size: Self.size,
                                             appearance: appearance)
            defer { host.close() }
            host.settle(passes: 40, interval: 0.05)
            // The launcher offers Review once Git has said whether a repository holds the folder.
            for _ in 0..<40 where ownerState.hasRepository == nil {
                try await Task.sleep(for: .milliseconds(25))
                host.settle(passes: 2, interval: 0.02)
            }
            XCTAssertEqual(ownerState.hasRepository, false)
            host.settle(passes: 10, interval: 0.03)
            let handle = elements(in: host, rightOf: 0).first { $0.label == L10n.string("Resize side panel") }
            let panelMinX = try XCTUnwrap(handle).frame.maxX
            try write(host, "launcher-tasks", appearance)

            if light {
                // The folder is no repository: Files first and no Review, then the tasks.
                let rows = elements(in: host, rightOf: panelMinX)
                    .filter { $0.role == NSAccessibility.Role.button.rawValue && $0.frame.minY > 120 }
                    .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
                let tools = rows.filter { [L10n.string("Files"), L10n.string("Side chat"), L10n.string("Browser"),
                                           L10n.string("Terminal"), L10n.string("Review")].contains($0) }
                XCTAssertEqual(tools, [L10n.string("Files"), L10n.string("Side chat"), L10n.string("Browser"),
                                       L10n.string("Terminal")], "\(rows)")
                XCTAssertTrue(rows.contains(other.title), "\(rows)")
                XCTAssertTrue(rows.contains(fixture.dirty.title), "\(rows)")
                XCTAssertFalse(rows.contains(owner.title), "The panel's own task is not offered")
                XCTAssertTrue(press(other.title, in: host, rightOf: panelMinX), "the launcher's row for the other task")
                XCTAssertEqual(ownerState.panels.trailingSurfaceID, tab)
                XCTAssertEqual(ownerState.panels.trailingTabs, [tab])
            } else {
                ownerState.setPanels(TaskSurfaceNavigationProjection.showing(tab, in: ownerState.panels))
                host.settle(passes: 30, interval: 0.04)
            }
            try write(host, "task-tab", appearance)

            if light {
                // The tab's composer is the other task's: type, then ⌘Return.
                let fields = views(NSTextField.self, in: host.hosting).filter {
                    $0.convert($0.bounds, to: nil).minX >= panelMinX
                }
                let field = try XCTUnwrap(fields.last, "the panel's composer")
                XCTAssertTrue(host.window.makeFirstResponder(field))
                host.settle(passes: 5, interval: 0.02)
                let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
                editor.insertText(reply, replacementRange: NSRange(location: 0, length: 0))
                host.settle(passes: 5, interval: 0.02)
                XCTAssertEqual(model.composerDrafts.tasks.draft(for: other.id).text, reply)
                XCTAssertEqual(model.composerDrafts.tasks.draft(for: owner.id).text, "")
                try key("\r", keyCode: 36, modifiers: .command, in: host.window)
                for _ in 0..<40 where model.followUps.queue(for: other.id).isEmpty {
                    try await Task.sleep(for: .milliseconds(25))
                }
                host.settle(passes: 20, interval: 0.03)
                XCTAssertEqual(model.followUps.queue(for: other.id).map(\.draft.text), [reply])
                XCTAssertTrue(model.followUps.queue(for: owner.id).isEmpty)
                XCTAssertEqual(model.composerDrafts.tasks.draft(for: other.id).text, "")
                try write(host, "task-tab-queued", appearance)
            }

            // The other task beside the panel's in a split view: the tab says another pane shows it.
            model.splits.combine(other.id, with: owner.id)
            if let ownerPane = model.splits.activeSplit?.pane(hosting: owner.id) { model.splits.focusPane(ownerPane.id) }
            host.settle(passes: 30, interval: 0.04)
            try write(host, "task-tab-in-split", appearance)
            if light {
                let texts = elements(in: host, rightOf: 0).map(\.label)
                XCTAssertTrue(texts.contains(L10n.string("Showing in another pane")), "\(texts)")
                let split = try XCTUnwrap(model.splits.activeSplit)
                XCTAssertNotEqual(split.focusedPaneID, split.pane(hosting: other.id)?.id)
                XCTAssertTrue(press(L10n.string("Go to Pane"), in: host, rightOf: 0))
                let focused = try XCTUnwrap(model.splits.activeSplit)
                XCTAssertEqual(focused.focusedPaneID, focused.pane(hosting: other.id)?.id)
            }
            if let split = model.splits.activeSplit { model.splits.dissolve(split.id) }
            for item in model.followUps.queue(for: other.id) { _ = model.followUps.remove(item.id, from: other.id) }
        }
    }
}
