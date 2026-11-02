import AppKit
@preconcurrency import SwiftTerm
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// "Run in terminal" on every harness's command card (plan B10): a Codex command, a Claude Code Bash
/// call and a Claude bash-mode command each offer it, and it opens the task's terminal and puts the
/// command at its prompt.
///
/// The shells are zsh with a temporary `ZDOTDIR` (`ShellLaunchEnvironment.isolatedZsh`), the commands
/// are `printf`, and nothing typed reaches the person's `~/.zsh_history`. Review images:
/// `.build/terminal-handoff-qa/`.
@MainActor
final class TerminalCommandHandoffTests: XCTestCase {
    // MARK: - The cards

    /// Every harness's command card offers the action and hands over its own command; other calls
    /// (a Read) do not, and a conversation without a terminal (a side chat, a subtask) offers none.
    func testEveryHarnessCommandCardOffersRunInTerminal() throws {
        let workspace = try temporaryFolder()
        let directory = try WindowlessRender.directory("terminal-handoff-qa")
        for fixture in HandoffFixture.all(workspace: workspace) {
            var ran: [String] = []
            var actions = ConversationActions()
            actions.runInTerminal = { ran.append($0) }
            for appearance in WindowlessRender.Appearance.allCases {
                let host = WindowlessRender.Host(
                    fixture.conversation(actions: actions)
                        .environment(\.colorScheme, appearance.colorScheme)
                        .frame(width: 760, height: 560)
                        .background(ParityTheme.canvas),
                    size: NSSize(width: 760, height: 560), appearance: appearance
                )
                defer { host.close() }
                host.settle()
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(
                    path: "conversation-\(fixture.name)-\(appearance.suffix).png"))
                guard appearance == .light else { continue }
                let pressed = host.hosting.pressAccessibilityElements(labelled: L10n.string("Run in terminal"))
                XCTAssertEqual(pressed, 1, "\(fixture.name): one command, one button: \(host.accessibilityElements())")
                XCTAssertEqual(ran, [fixture.command], fixture.name)
            }

            let without = WindowlessRender.Host(fixture.conversation(actions: ConversationActions())
                .frame(width: 760, height: 560), size: NSSize(width: 760, height: 560), appearance: .light)
            defer { without.close() }
            without.settle()
            XCTAssertFalse(without.accessibilityElements().contains(label: L10n.string("Run in terminal")),
                           "\(fixture.name): no terminal, no button")
        }
    }

    /// The three commands side by side, their actions shown, for review in both appearances: the Codex
    /// and Claude Code commands' status lines and the bash-mode command's row.
    func testTheCommandCardsDrawTheAction() throws {
        let directory = try WindowlessRender.directory("terminal-handoff-qa")
        let run: (String) -> Void = { _ in }
        func line(_ id: String, _ harness: HarnessKind, _ command: ConversationCommand) -> ConversationWorkLine {
            ConversationWorkLine(
                item: ConversationItem(id: id, kind: .command(command), phase: .completed,
                                       source: .transcript(TranscriptEntry(content: .plan(""))), copyDetails: "details"),
                harness: harness, workspaceURL: URL(filePath: "/tmp/yardlet"), runInTerminal: run
            )
        }
        try WindowlessRender.hostedInBothAppearances("command-cards", in: directory, size: NSSize(width: 620, height: 330)) {
            appearance in
            VStack(alignment: .leading, spacing: 18) {
                line("codex", .codex, ConversationCommand(command: HandoffFixture.codexCommand, workingDirectory: "/tmp/yardlet",
                                                          status: "completed", output: "B10-codex\n", exitCode: 0))
                line("claude", .claudeCode, ConversationCommand(command: HandoffFixture.claudeCommand, status: "completed",
                                                                output: "B10-claude"))
                ClaudeBashCommandRow(entryID: UUID(), message: ClaudeBashMessage(
                    command: HandoffFixture.bashModeCommand, output: "B10-bash", hasOutput: true), runInTerminal: run)
            }
            .padding(20)
            .frame(width: 620, height: 330, alignment: .topLeading)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.revealsSentMessageActions, true)
        }
    }

    // MARK: - The task's terminal

    /// A click hands one command to the task's terminal: each click is its own request, closing the
    /// terminal or leaving the task drops it, and the terminal says when it is done with one.
    func testTheTaskKeepsOneHandoffUntilItsTerminalIsDoneWithIt() {
        let state = TaskWorkspaceState()
        state.handOffToTerminal("ls")
        let first = state.terminalHandoff
        XCTAssertEqual(first?.command, "ls")
        XCTAssertTrue(state.terminalStartRequested, "The click may start a shell")
        XCTAssertTrue(state.terminals.isEmpty, "A tab opens with the panel")
        state.handOffToTerminal("ls")
        XCTAssertNotEqual(state.terminalHandoff?.id, first?.id, "Twice is twice")

        state.setPanels(.init(isTerminalPresented: true))
        XCTAssertNotNil(state.terminalHandoff, "Opening the terminal keeps it")
        state.finishTerminalHandoff(first!.id)
        XCTAssertNotNil(state.terminalHandoff, "Done with an older one leaves the newer")
        state.finishTerminalHandoff(state.terminalHandoff!.id)
        XCTAssertNil(state.terminalHandoff)

        state.handOffToTerminal("pwd")
        state.setPanels(.init(isTerminalPresented: false))
        XCTAssertNil(state.terminalHandoff, "Closing the terminal drops it")
        XCTAssertFalse(state.terminalStartRequested)

        state.handOffToTerminal("pwd")
        state.leaveTerminal()
        XCTAssertNil(state.terminalHandoff, "Leaving the task drops it")
        XCTAssertFalse(state.terminalStartRequested)
        XCTAssertNil(TaskWorkspaceState(snapshot: state.snapshot).terminalHandoff, "Never saved")
    }

    /// The whole path for each harness, in the task screen: pressing the card's "Run in terminal"
    /// opens the task's terminal, starts its shell, and types the command at the prompt without
    /// running it; the person's Return runs it, and the typed line shows once with its output after.
    func testRunInTerminalOpensTheTasksTerminalAndRunsTheCommandForEveryHarness() throws {
        let history = Self.personalHistory()
        let directory = try WindowlessRender.directory("terminal-handoff-qa")
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        for fixture in HandoffFixture.all(workspace: try temporaryFolder()) {
            let workspace = TaskWorkspaceState()
            let host = WindowlessRender.Host(
                TaskTerminalHost(fixture: fixture, workspace: workspace)
                    .environment(\.terminalShellLaunch, launch)
                    .environment(\.colorScheme, .light)
                    .frame(width: 1_000, height: 820)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 1_000, height: 820), appearance: .light
            )
            defer { host.close() }
            host.settle()
            XCTAssertFalse(workspace.panels.isTerminalPresented)
            XCTAssertEqual(host.hosting.pressAccessibilityElements(labelled: L10n.string("Run in terminal")), 1,
                           fixture.name)
            host.settle()
            XCTAssertTrue(workspace.panels.isTerminalPresented, "\(fixture.name): the terminal opens")

            let output = "B10-\(fixture.name)"
            try waitForText("B10-%s", in: host)
            host.settle(passes: 6, interval: 0.1)
            XCTAssertFalse(host.hosting.terminalText.components(separatedBy: "\n").contains { $0.hasPrefix(output) },
                           "\(fixture.name): typed, not run: \(host.hosting.terminalText)")
            host.hosting.terminalView?.send(txt: "\r")
            var buffer = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                host.settle(passes: 1, interval: 0.05)
                buffer = host.hosting.terminalText
                if buffer.components(separatedBy: "\n").contains(where: { $0.hasPrefix(output) }) { break }
            }
            XCTAssertTrue(buffer.components(separatedBy: "\n").contains { $0.hasPrefix(output) },
                          "\(fixture.name): \(buffer)")
            XCTAssertEqual(buffer.components(separatedBy: "B10-%s").count - 1, 1,
                           "\(fixture.name): the command was typed at the prompt, once: \(buffer)")
            XCTAssertNil(workspace.terminalHandoff, "\(fixture.name): the terminal is done with it")
            // Drawn with the whole screen, SwiftTerm's text lands right of its view in an unshown
            // window (its frame is the panel's); drawn alone, it is where the terminal shows it.
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "task-terminal-\(fixture.name)-light.png"))
            let terminal = try XCTUnwrap(host.hosting.terminalView)
            try WindowlessRender.writePNG(WindowlessRender.capture(terminal), to: directory.appending(
                path: "task-terminal-\(fixture.name)-terminal-only-light.png"))
        }
        XCTAssertFalse(Self.added(to: history).contains("B10-%s"), "A test's command reached ~/.zsh_history")
    }

    /// "Run in terminal" never types into a program that holds a tab's terminal (here `cat`, as a
    /// sign-in waiting for its code would): the shown tab takes the command only at its prompt, else
    /// another tab at its prompt shows and takes it, else a new tab opens for it, as the Claude app's
    /// terminal takes a tab at its prompt. Closing asks first only for the tab where `cat` runs.
    func testRunInTerminalLeavesATabWhereAProgramRuns() throws {
        let history = Self.personalHistory()
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let fixture = HandoffFixture.all(workspace: try temporaryFolder(named: "yardlet"))[0]
        let workspace = TaskWorkspaceState()
        let host = Self.taskHost(fixture, workspace, launch: launch, appearance: .light)
        defer { host.close() }
        host.settle()
        func runInTerminal() {
            XCTAssertEqual(host.hosting.pressAccessibilityElements(labelled: L10n.string("Run in terminal")), 1)
            host.settle()
        }

        runInTerminal()
        try waitForText("B10-%s", in: host)
        let busy = try XCTUnwrap(workspace.terminals.first)
        busy.send("\u{15}cat\r")
        try waitUntilSettled(in: host) { busy.isRunningProgram }
        XCTAssertFalse(busy.isAtPrompt)

        runInTerminal()
        XCTAssertEqual(workspace.terminals.count, 2, "a new tab, not the one where cat runs")
        let idle = workspace.terminals[1]
        try waitForText("B10-%s", in: host)
        XCTAssertTrue(workspace.terminal(in: fixture.workspaceURL, launch: launch, taskID: nil) === idle)
        try waitUntilSettled(in: host) { workspace.terminalHandoff == nil }
        XCTAssertFalse(busy.bufferText.components(separatedBy: "cat").dropFirst().joined().contains("B10-%s"),
                       "nothing reached cat: \(busy.bufferText)")
        XCTAssertTrue(idle.isAtPrompt)
        XCTAssertFalse(idle.isRunningProgram, "closing it asks nothing")

        idle.send("\u{15}")
        workspace.showTerminalTab(busy)
        host.settle()
        runInTerminal()
        XCTAssertEqual(workspace.terminals.count, 2, "the other tab at its prompt, not a third")
        XCTAssertTrue(workspace.terminal(in: fixture.workspaceURL, launch: launch, taskID: nil) === idle)
        try waitUntilSettled(in: host) { workspace.terminalHandoff == nil }
        XCTAssertEqual(TerminalCloseQuestion.message(closing: [busy], titles: TerminalTabTitle.titles(for: workspace.terminals)),
                       L10n.format("A command is still running in %@. Closing the terminal stops it.", "yardlet"))
        busy.send("\u{4}")
        workspace.endTerminal()
        XCTAssertFalse(Self.added(to: history).contains("B10-%s"), "A test's command reached ~/.zsh_history")
    }

    /// The Codex app's Control-` shows and hides the terminal as ⌘J does, with the terminal focused too,
    /// whose shell would read it as Control-@.
    func testControlBacktickTogglesTheTerminalWithTheTerminalFocused() throws {
        var toggles = 0
        let workspace = TaskWorkspaceState()
        let host = WindowlessRender.Host(
            PaneHost(folder: try temporaryFolder(), workspace: workspace,
                     launch: .isolatedZsh(in: try temporaryFolder()), startsAutomatically: true)
                .background(TerminalToggleKey(isEnabled: true) { toggles += 1 })
                .frame(width: 800, height: 360),
            size: NSSize(width: 800, height: 360), appearance: .light
        )
        defer { host.close() }
        try waitUntilSettled(in: host) { host.hosting.terminalText.contains("%") }
        let terminal = try XCTUnwrap(host.hosting.terminalView)
        XCTAssertTrue(host.window.makeFirstResponder(terminal))
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .control) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil, characters: "\u{0}",
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
        }
        try press("`", keyCode: 50)
        XCTAssertEqual(toggles, 1)
        try press("₩", keyCode: 50)
        XCTAssertEqual(toggles, 2, "the same key where the layout gives it another character")
        try press("`", keyCode: 50, modifiers: [.control, .shift])
        XCTAssertEqual(toggles, 2, "Control-Shift-` is not it")
    }

    /// Three tabs, one renamed, in both appearances, for review: `.build/terminal-tabs-qa/`.
    func testTheTerminalDrawsItsTabs() throws {
        let directory = try WindowlessRender.directory("terminal-tabs-qa")
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let fixture = HandoffFixture.all(workspace: try temporaryFolder(named: "yardlet"))[0]
        for appearance in WindowlessRender.Appearance.allCases {
            let workspace = TaskWorkspaceState()
            workspace.setPanels(.init(isTerminalPresented: true))
            let host = Self.taskHost(fixture, workspace, launch: launch, appearance: appearance)
            defer { host.close() }
            host.settle()
            workspace.openTerminalTab(in: fixture.workspaceURL, launch: launch, taskID: nil).name = "server"
            workspace.openTerminalTab(in: fixture.workspaceURL, launch: launch, taskID: nil)
            try waitUntilSettled(in: host) { host.hosting.terminalText.contains("%") }
            host.settle(passes: 6, interval: 0.1)
            try WindowlessRender.writePNG(Self.overTerminalBackground(host.capture().bitmap, appearance: appearance),
                                          to: directory.appending(path: "tabs-\(appearance.suffix).png"))
            workspace.endTerminal()
        }
    }

    /// SwiftTerm leaves its default background to its layer, which a capture of the window does not
    /// draw: the capture laid over the terminal's background, as the screen shows it.
    private static func overTerminalBackground(_ bitmap: NSBitmapImageRep,
                                               appearance: WindowlessRender.Appearance) throws -> NSBitmapImageRep {
        let flat = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        flat.size = bitmap.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
        TerminalAppearance.background(isDark: appearance == .dark).setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        bitmap.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return flat
    }

    private static func taskHost(_ fixture: HandoffFixture, _ workspace: TaskWorkspaceState, launch: ShellLaunchEnvironment,
                                 appearance: WindowlessRender.Appearance) -> WindowlessRender.Host<some View> {
        WindowlessRender.Host(
            TaskTerminalHost(fixture: fixture, workspace: workspace)
                .environment(\.terminalShellLaunch, launch)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 1_000, height: 820)
                .background(ParityTheme.canvas),
            size: NSSize(width: 1_000, height: 820), appearance: appearance
        )
    }

    /// The terminal offers no command of its own: the command card has the action. The terminal here
    /// waits for Start terminal.
    func testTheCommandCardNotTheTerminalOffersTheCommand() throws {
        let fixture = HandoffFixture.all(workspace: try temporaryFolder())[0]
        let workspace = TaskWorkspaceState()
        workspace.setPanels(.init(isTerminalPresented: true))
        workspace.terminalStartRequested = false
        let host = WindowlessRender.Host(
            TaskTerminalHost(fixture: fixture, workspace: workspace)
                .environment(\.terminalShellLaunch, .isolatedZsh(in: try temporaryFolder()))
                .frame(width: 1_000, height: 820),
            size: NSSize(width: 1_000, height: 820), appearance: .light
        )
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains(label: L10n.string("Run in terminal")), "\(elements)")
        XCTAssertTrue(host.hosting.terminalText.isEmpty, "No shell started")
    }

    /// A terminal waiting for "Start terminal" (a restored task) starts for a handoff; one whose shell
    /// is running types the next handoff into the same shell; one whose shell has exited starts a new one.
    func testTheTerminalStartsRestartsOrReusesItsShellForAHandoff() throws {
        let history = Self.personalHistory()
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let workspace = TaskWorkspaceState()
        let folder = try temporaryFolder()
        let host = WindowlessRender.Host(
            PaneHost(folder: folder, workspace: workspace, launch: launch)
                .frame(width: 800, height: 360),
            size: NSSize(width: 800, height: 360), appearance: .light
        )
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.terminalText.isEmpty, "Waits for Start terminal")

        workspace.handOffToTerminal(#"export B10_SHELL=$$; printf 'B10-%s\n' first"#)
        try pressReturnOnceTyped("printf 'B10-%s\\n' first", in: host)
        try waitForLine("B10-first", in: host)
        let firstShell = try XCTUnwrap(host.hosting.terminalView?.process.shellPid)
        workspace.handOffToTerminal(#"printf 'B10-%s-%s\n' same "$B10_SHELL""#)
        try pressReturnOnceTyped("same \"$B10_SHELL\"", in: host)
        try waitForLine("B10-same-\(firstShell)", in: host)

        workspace.handOffToTerminal("exit")
        try pressReturnOnceTyped("exit", in: host)
        let exited = ContinuousClock.now + .seconds(5)
        while host.hosting.terminalView?.process.running == true, ContinuousClock.now < exited {
            host.settle(passes: 1, interval: 0.05)
        }
        workspace.handOffToTerminal(#"printf 'B10-%s-%s\n' new "${B10_SHELL:-unset}""#)
        try pressReturnOnceTyped("new \"${B10_SHELL:-unset}\"", in: host)
        try waitForLine("B10-new-unset", in: host)
        XCTAssertNotEqual(host.hosting.terminalView?.process.shellPid, firstShell)
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("terminal-handoff-qa")
            .appending(path: "pane-restarted-light.png"))
        XCTAssertFalse(Self.added(to: history).contains("B10-%s"), "A test's command reached ~/.zsh_history")
    }

    /// "Run in terminal" types the command for the person to review: no Return, and a command over
    /// several lines as a bracketed paste when the shell asked for it, so no line runs on its own.
    func testAHandedOffCommandIsTypedForReviewNotRun() {
        XCTAssertEqual(NativeTerminalSession.reviewText("git status\n"), "git status")
        XCTAssertEqual(NativeTerminalSession.reviewText("a &&\nb", bracketedPaste: true), "\u{1B}[200~a &&\nb\u{1B}[201~")
        XCTAssertEqual(NativeTerminalSession.reviewText("a &&\nb", bracketedPaste: false), "a &&\nb")
    }

    // MARK: - Helpers

    /// Waits for the handed-off command to sit at the prompt, then presses Return as the person would.
    private func pressReturnOnceTyped(_ text: String, in host: WindowlessRender.Host<some View>) throws {
        try waitForText(text, in: host)
        host.hosting.terminalView?.send(txt: "\r")
    }

    private func waitUntilSettled(in host: WindowlessRender.Host<some View>, _ condition: () -> Bool) throws {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            host.settle(passes: 1, interval: 0.05)
            if condition() { return }
        }
        XCTFail("Timed out: \(host.hosting.terminalText)")
    }

    private func waitForText(_ text: String, in host: WindowlessRender.Host<some View>) throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            host.settle(passes: 1, interval: 0.05)
            if host.hosting.terminalText.contains(text) { return }
        }
        XCTFail("Not typed \(text): \(host.hosting.terminalText)")
    }

    private func waitForLine(_ prefix: String, in host: WindowlessRender.Host<some View>) throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            host.settle(passes: 1, interval: 0.05)
            if host.hosting.terminalText.components(separatedBy: "\n").contains(where: { $0.hasPrefix(prefix) }) {
                return
            }
        }
        XCTFail("No line \(prefix): \(host.hosting.terminalText)")
    }

    private func temporaryFolder(named name: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-handoff-test-\(UUID().uuidString)")
        let folder = name.map { root.appending(path: $0) } ?? root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return folder
    }

    /// The person's own zsh history as it is now, read only to check nothing of a test's is added.
    private static func personalHistory() -> Data {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zsh_history")
        return FileManager.default.contents(atPath: path.path(percentEncoded: false)) ?? Data()
    }

    /// What the history file has now that it did not have before, as text.
    private static func added(to before: Data) -> String {
        let after = personalHistory()
        let new = after.starts(with: before) ? after.dropFirst(before.count) : after[...]
        return String(decoding: new, as: UTF8.self)
    }
}

private extension TaskWorkspaceState {
    /// A handoff where a new tab, if one is needed, opens in a scratch folder with the person's shell.
    func handOffToTerminal(_ command: String) {
        handOffToTerminal(command, in: FileManager.default.temporaryDirectory, launch: .userLoginShell(), taskID: nil)
    }
}

// MARK: - Fixtures

/// One harness's conversation with one command and one other call, in a running turn.
@MainActor
private struct HandoffFixture {
    static let codexCommand = #"printf 'B10-%s\n' codex"#
    static let claudeCommand = #"printf 'B10-%s\n' claude"#
    static let bashModeCommand = #"printf 'B10-%s\n' bash"#

    let name: String
    let harness: HarnessKind
    let command: String
    let workspaceURL: URL
    var entries: [TranscriptEntry] = []
    var codexTaskState: CodexTaskState? = nil

    static func all(workspace: URL) -> [HandoffFixture] {
        [codex(workspace), claude(workspace), bashMode(workspace)]
    }

    func conversation(actions: ConversationActions) -> some View {
        TaskConversationView(harness: harness, workspaceURL: workspaceURL, entries: entries, sessionStatus: .running,
                             codexTaskState: codexTaskState, actions: actions)
            .environment(\.transcriptWorkspaceURL, workspaceURL)
    }

    var session: SessionRecord {
        SessionRecord(harness: harness, workspaceURL: workspaceURL, runtimeExecutableURL: URL(filePath: "/usr/bin/false"),
                      title: "Run in terminal", status: .running)
    }

    /// A Codex command that ran, in a running turn: the command's own line (a run of calls folds into
    /// its summary while the turn runs, 2026-10-16).
    private static func codex(_ workspace: URL) -> HandoffFixture {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-b10")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("inProgress"),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Print the marker")])])]),
                .object(["id": .string("c1"), "type": .string("commandExecution"), "command": .string(codexCommand),
                         "cwd": .string(workspace.path(percentEncoded: false)), "status": .string("completed"),
                         "commandActions": .array([]), "aggregatedOutput": .string("B10-codex\n"),
                         "exitCode": .integer(0)])
            ])
        ]), fallbackID: "turn-1")!]
        return HandoffFixture(name: "codex", harness: .codex, command: codexCommand, workspaceURL: workspace,
                              codexTaskState: CodexTaskState(thread: thread))
    }

    /// A Claude Code Bash call, a note and a running Read, in a running turn: the Bash call keeps its
    /// own line and the Read is the live line's (2026-10-16).
    private static func claude(_ workspace: URL) -> HandoffFixture {
        let bash = HarnessActivity(id: "toolu_b10", kind: "Bash", title: "Bash", detail: claudeCommand,
                                   input: claudeCommand + "\n\ndescription: Print the marker", output: "B10-claude")
        return HandoffFixture(name: "claude", harness: .claudeCode, command: claudeCommand, workspaceURL: workspace,
                              entries: [
                                TranscriptEntry(content: .user(text: "Print the marker")),
                                TranscriptEntry(content: .activity(bash, state: .completed)),
                                TranscriptEntry(content: .assistant(text: "Reading the README next.", isStreaming: false)),
                                TranscriptEntry(content: .activity(HarnessActivity(
                                    id: "toolu_read", kind: "Read", title: "Read", input: "README.md"), state: .running))
                              ])
    }

    /// A Claude bash-mode command the person ran.
    private static func bashMode(_ workspace: URL) -> HandoffFixture {
        HandoffFixture(name: "bash", harness: .claudeCode, command: bashModeCommand, workspaceURL: workspace, entries: [
            TranscriptEntry(content: .user(text: "Print the marker")),
            TranscriptEntry(content: .assistant(text: "Run it yourself with `!`.", isStreaming: false)),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: bashModeCommand, stdout: "B10-bash")))
        ])
    }
}

/// The task screen as the window mounts it, with the fixture's conversation.
private struct TaskTerminalHost: View {
    let fixture: HandoffFixture
    let workspace: TaskWorkspaceState
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            session: fixture.session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, transcript: TaskTranscriptReader(fixture.entries), errorMessage: nil,
            codexTaskState: fixture.codexTaskState, codexHistorySelection: nil, codexQueue: [],
            codexCapabilities: .empty, providerCapabilities: nil, providerUsage: nil, isProviderAttached: false,
            onShowCodexCapabilities: {}, conversationActions: ConversationActions(), composerActions: ComposerActions()
        )
        .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
        .environment(\.transcriptWorkspaceURL, fixture.workspaceURL)
    }
}

/// The terminal panel alone, restored (it waits for Start terminal), handed commands by the task.
private struct PaneHost: View {
    let folder: URL
    let workspace: TaskWorkspaceState
    let launch: ShellLaunchEnvironment
    var startsAutomatically = false

    var body: some View {
        TerminalPane(workspaceURL: folder, handoff: workspace.terminalHandoff, launch: launch,
                     startsAutomatically: startsAutomatically, onHandoffDone: { workspace.finishTerminalHandoff($0) },
                     onClose: {})
    }
}

private extension NSView {
    /// The terminal panel's view under this one, if any.
    var terminalView: NativeTerminalView? {
        if let view = self as? NativeTerminalView { return view }
        for subview in subviews {
            if let found = subview.terminalView { return found }
        }
        return nil
    }

    /// What the terminal under this view shows, scrollback included, wrapped rows joined.
    var terminalText: String {
        terminalView?.getTerminal().unwrappedText ?? ""
    }

    /// Presses every accessibility element under the view with this label, as an assistive app
    /// would, and returns how many it pressed. SwiftUI builds its accessibility tree only while an
    /// assistive app has announced itself (`AXEnhancedUserInterface`), which this sets and puts back.
    func pressAccessibilityElements(labelled label: String) -> Int {
        WindowlessRender.withAccessibilityTree {
            var found: [AnyObject] = []
            var visited: Set<ObjectIdentifier> = []
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if (child.accessibilityLabel?() ?? nil) == label { found.append(child) }
                    visit(child)
                }
            }
            visit(self)
            return found.filter { $0.accessibilityPerformPress?() ?? false }.count
        }
    }
}
