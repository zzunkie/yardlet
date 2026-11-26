import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Claude bash mode offscreen into `.build/bash-mode-qa`, light and dark: the composer in
/// bash mode and while a command runs, and the conversation's command rows running, finished,
/// long, silent, stopped and failed. No provider, shell, window server interaction or app launch.
@MainActor
final class ClaudeBashModeRenderingTests: XCTestCase {
    func testTheComposerInBashModeAndWhileACommandRuns() throws {
        let bashDraft = TaskComposerDraft()
        bashDraft.text = "!"
        bashDraft.enterBashModeIfTyped(after: "")
        bashDraft.text = "git log --oneline -5"
        let emptyBash = TaskComposerDraft()
        emptyBash.text = "!"
        emptyBash.enterBashModeIfTyped(after: "")
        let running = ClaudeShellCommandActions(isRunning: true, run: { _ in }, stop: {}, runForEntry: { _ in nil })
        let idle = ClaudeShellCommandActions(isRunning: false, run: { _ in }, stop: {}, runForEntry: { _ in nil })
        for (name, draft, actions) in [("composer-bash-mode", bashDraft, idle), ("composer-bash-empty", emptyBash, idle),
                                       ("composer-command-running", TaskComposerDraft(), running)] {
            try render(name: name, size: NSSize(width: 820, height: 150)) {
                PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
                    .environment(\.claudeShellCommands, actions)
            }
        }
    }

    /// A task running a bash-mode command shows the sidebar's running mark though Claude's own
    /// status is idle; the task beside it, idle in both, shows none.
    func testTheSidebarShowsATaskRunningAShellCommandAsRunning() throws {
        let busy = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Runs npm test in bash mode", status: .ready)
        let idle = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Idle task", status: .ready)
        let groups = TaskNavigationProjection.workspaceGroups(from: [busy, idle])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        try render(name: "sidebar-shell-busy", size: NSSize(width: ParityTheme.sidebarWidth, height: 260)) {
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(idle.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: ProjectStore(), onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in })
                .environment(\.shellBusyTaskIDs, [busy.id])
        }
    }

    /// The real composer in an unshown window, driven through its field editor with synthesized
    /// key events, as `ComposerFileMentionRenderingTests` drives it.
    func testKeysEnterAndLeaveBashModeAndReturnRunsTheCommand() throws {
        _ = NSApplication.shared
        let draft = TaskComposerDraft()
        var ran: [String] = []
        var sent: [HarnessUserInput] = []
        let actions = ClaudeShellCommandActions(isRunning: false, run: { ran.append($0) }, stop: {},
                                                runForEntry: { _ in nil })
        let hosting = NSHostingView(rootView: PromptComposer(
            harness: .claudeCode, composerDraft: draft, isRunning: false,
            actions: ComposerActions(send: { sent.append($0) })
        )
        .environment(\.claudeShellCommands, actions)
        .frame(width: 820, height: 160, alignment: .bottom)
        .background(ParityTheme.canvas))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        settle()
        let field = try XCTUnwrap(views(ComposerMarkdownTextView.self, in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)

        // `!` in the empty composer is the switch, not text.
        try press("!", keyCode: 18, in: window)
        XCTAssertTrue(draft.isBashMode)
        XCTAssertEqual(draft.text, "")
        try snapshot(hosting, "native-bash-mode-entered-light.png")

        // Backspace in the empty composer returns to chat. The field editor would take the key
        // before SwiftUI does, so the composer's own key monitor reads it first, as the app's
        // event loop runs local monitors before the window; the window gets what it leaves.
        let monitor = try XCTUnwrap(views(ComposerExternalInputView.self, in: hosting).first)
        let backspace = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51
        ))
        XCTAssertTrue(monitor.handleDeleteInEmptyText(backspace))
        settle()
        XCTAssertFalse(draft.isBashMode)
        XCTAssertFalse(monitor.handleDeleteInEmptyText(backspace), "In chat, Backspace is the editor's")

        // Escape does too.
        try press("!", keyCode: 18, in: window)
        XCTAssertTrue(draft.isBashMode)
        try press("\u{1b}", keyCode: 53, in: window)
        XCTAssertFalse(draft.isBashMode)

        // Return runs the command instead of sending it, and the composer is back in chat.
        try press("!", keyCode: 18, in: window)
        editor.insertText("printf 'hi'", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        settle()
        XCTAssertEqual(draft.text, "printf 'hi'")
        try snapshot(hosting, "native-bash-mode-typed-light.png")
        try press("\r", keyCode: 36, in: window)
        XCTAssertEqual(ran, ["printf 'hi'"])
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(draft.isBashMode)
        XCTAssertEqual(draft.text, "")

        // A `!` anywhere but the start of an empty composer is text, and Return sends a message.
        editor.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        settle()
        try press("!", keyCode: 18, in: window)
        XCTAssertFalse(draft.isBashMode)
        XCTAssertEqual(draft.text, "Hi!")
        try press("\r", keyCode: 36, in: window)
        XCTAssertEqual(sent.map(\.text), ["Hi!"])
        XCTAssertEqual(ran.count, 1)
    }

    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: characters == "!" ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        window.sendEvent(event)
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    private func snapshot(_ hosting: NSView, _ name: String) throws {
        let bitmap = try WindowlessRender.capture(hosting)
        try WindowlessRender.writePNG(bitmap, to: WindowlessRender.directory("bash-mode-qa").appending(path: name))
    }
}

/// The conversation case, drawn through `TaskConversationView` as a task draws it, and the render
/// helper every case uses.
extension ClaudeBashModeRenderingTests {
    func testTheConversationShowsCommandsWithTheirOutput() throws {
        let session = UUID()
        let runningID = UUID(), stoppedID = UUID(), failedID = UUID()
        let live = ClaudeShellCommandRun(id: runningID, sessionID: session, command: "npm test")
        live.output = "> yardlet@1.0.0 test\n> jest\n\nPASS  src/a.test.ts\nRUNS  src/b.test.ts"
        let stopped = ClaudeShellCommandRun(id: stoppedID, sessionID: session, command: "tail -f build.log")
        stopped.output = "[12:01] compiling…\n^C"
        stopped.state = .stopped
        let failed = ClaudeShellCommandRun(id: failedID, sessionID: session, command: "ls")
        failed.state = .failed("Working directory “/tmp/gone” does not exist")
        let runs = [runningID: live, stoppedID: stopped, failedID: failed]
        let actions = ClaudeShellCommandActions(isRunning: true, run: { _ in }, stop: {}, runForEntry: { runs[$0] })

        let long = (1...40).map { "src/module\($0).swift | \($0 * 3) +++--" }.joined(separator: "\n")
        let entries = [
            TranscriptEntry(content: .user(text: "Check the repository state")),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(
                command: "git status --short && echo \"<done>\"", stdout: " M Sources/App.swift\n?? notes.md\n<done>"))),
            TranscriptEntry(content: .assistant(text: "One file is modified and one is untracked.", isStreaming: false)),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: "git diff --stat", stdout: long))),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: "true", stdout: ""))),
            TranscriptEntry(id: stoppedID, content: .user(text: ClaudeBashMessage.text(command: "tail -f build.log",
                                                                                       stdout: "[12:01] compiling…\n^C"))),
            TranscriptEntry(id: failedID, content: .user(text: ClaudeBashMessage.text(
                command: "ls", stdout: "", stderr: "Working directory “/tmp/gone” does not exist"))),
            TranscriptEntry(id: runningID, content: .user(text: ClaudeBashMessage.inputText(command: "npm test")))
        ]
        try render(name: "conversation-bash-rows", size: NSSize(width: 820, height: 1_100)) {
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"), entries: entries)
                .environment(\.claudeShellCommands, actions)
        }

        // Another harness never reads a bash tag as a command.
        try render(name: "conversation-other-harness", size: NSSize(width: 820, height: 200)) {
            TaskConversationView(harness: .openCode, workspaceURL: URL(filePath: "/tmp/yardlet"), entries: [entries[1]])
        }
        XCTAssertTrue(ClaudeBashCommandRow.needsScrolling(long))
        XCTAssertFalse(ClaudeBashCommandRow.needsScrolling(" M Sources/App.swift\n?? notes.md"))
    }

    func render<Content: View>(name: String, size: NSSize, @ViewBuilder content: () -> Content) throws {
        // Never ordered on screen: a borderless backing window lets AppKit-backed fields and
        // scroll views draw, which ImageRenderer replaces with placeholders.
        let captures = try WindowlessRender.hostedInBothAppearances(
            name, in: WindowlessRender.directory("bash-mode-qa"), size: size
        ) {
            content()
                .environment(\.colorScheme, $0.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 8, background: (2, 2)),
                          "\(name) rendered nothing")
        }
    }
}
