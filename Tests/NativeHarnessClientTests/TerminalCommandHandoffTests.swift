import AppKit
@preconcurrency import SwiftTerm
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// "Run in terminal" on every harness's command card (plan B10) and on an answer's shell code block: a
/// Codex command, a Claude Code Bash call and a Claude bash-mode command each offer it, and it opens the
/// task's terminal and runs the command at its prompt, as the Claude app's runs what it types.
///
/// The shells are zsh with a temporary `ZDOTDIR` (`ShellLaunchEnvironment.isolatedZsh`), the commands
/// are `printf`, and nothing typed reaches the person's `~/.zsh_history`. Review images:
/// `.build/terminal-handoff-qa/`.
@MainActor
final class TerminalCommandHandoffTests: XCTestCase {
    private typealias Projection = TaskSurfaceNavigationProjection

    /// A remote shell starts and receives output before any panel creates an AppKit terminal.
    func testSessionOwnsPTYWithoutAView() async throws {
        let folder = try temporaryFolder()
        let session = NativeTerminalSession(workspaceURL: folder, launch: .isolatedZsh(in: folder))
        defer { session.end() }
        var output = ""
        session.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        session.resize(columns: 100, rows: 30)
        session.start()
        XCTAssertTrue(session.hasShell)
        XCTAssertTrue(session.isRunning)
        let ready = await session.typeWhenReady("printf 'HEADLESS_%s\\n' READY; stty size\r")
        XCTAssertTrue(ready)
        try await waitUntil { output.contains("HEADLESS_READY") && output.contains("30 100") }
        XCTAssertTrue(output.contains("HEADLESS_READY"))
        XCTAssertTrue(session.bufferText.contains("HEADLESS_READY"), "The agent reads a headless session through the emulator")
        XCTAssertTrue(output.contains("30 100"))
        session.send(#"printf '\033[?1049h'; printf '%1100000s' '' | tr ' ' x; printf '\033[2J\033[HSTATE_AFTER_BURST\n'"# + "\r")
        try await waitUntil { session.bufferText.contains("STATE_AFTER_BURST") }
        let view = session.view {
            NativeTerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                options: TerminalOptions(scrollback: 5_000))
        }
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate, "Mounting adopts parser state even after more than 1 MiB")
        XCTAssertTrue(view.getTerminal().unwrappedText.contains("STATE_AFTER_BURST"))
        session.send(#"printf '\033[?1049l'"# + "\r")
        try await waitUntil { !view.getTerminal().isCurrentBufferAlternate }
        XCTAssertTrue(view.getTerminal().unwrappedText.contains("HEADLESS_READY"), "The normal buffer survives the alternate screen")
        session.end()
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.hasShell)
    }

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
    /// opens the task's terminal, starts its shell, and runs the command at the prompt: the command
    /// line shows once, with its output after.
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
            var buffer = ""
            let deadline = ContinuousClock.now + testWaitLimit
            while ContinuousClock.now < deadline {
                host.settle(passes: 1, interval: 0.05)
                buffer = host.hosting.terminalText
                if buffer.components(separatedBy: "\n").contains(where: { $0.hasPrefix(output) }) { break }
            }
            XCTAssertTrue(buffer.components(separatedBy: "\n").contains { $0.hasPrefix(output) },
                          "\(fixture.name): \(buffer)")
            XCTAssertEqual(buffer.components(separatedBy: "B10-%s").count - 1, 1,
                           "\(fixture.name): the command went in at the prompt, once: \(buffer)")
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

    /// While the person shares the terminal, a selection in it goes to the task's message with ⌘⇧L (the
    /// Claude app's key) or the terminal's right-click menu: a fenced block under the tab's name after what
    /// the message says. Turned off in Settings, the terminal has no menu and the key does nothing. Review
    /// images: `.build/terminal-tabs-qa/attach-*.png` and `settings-terminal-*.png`.
    func testASelectionInTheTerminalGoesToTheMessageWhileShared() throws {
        let directory = try WindowlessRender.directory("terminal-tabs-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TerminalSharing")))
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let fixture = HandoffFixture.all(workspace: try temporaryFolder(named: "yardlet"))[0]
        let workspace = TaskWorkspaceState()
        workspace.setPanels(.init(isTerminalPresented: true))
        let draft = TaskComposerDraft()
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                TaskTerminalHost(fixture: fixture, workspace: workspace, draft: draft)
                    .environment(\.terminalShellLaunch, launch)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .defaultAppStorage(defaults)
                    .frame(width: 1_000, height: 820)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 1_000, height: 820), appearance: appearance
            )
            defer { host.close() }
            host.settle()
            // The command and its output, as the person drags across them.
            func selectCommandAndOutput(in terminal: NativeTerminalView) throws {
                let buffer = terminal.getTerminal()
                let output = try XCTUnwrap((0..<buffer.rows).first {
                    buffer.getLine(row: $0)?.translateToString(trimRight: true) == "B2-selected"
                })
                terminal.selection.setSelection(start: Position(col: 0, row: output - 1),
                                                end: Position(col: buffer.cols, row: output))
            }
            if appearance == .dark {
                try selectCommandAndOutput(in: try XCTUnwrap(host.hosting.terminalView))
                host.settle()
                try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                              to: directory.appending(path: "attach-dark.png"))
                continue
            }
            let shell = workspace.terminal(in: fixture.workspaceURL, launch: launch, taskID: nil)
            try waitUntilSettled(in: host) { shell.isAtPrompt && host.hosting.terminalText.contains("%") }
            shell.send("printf 'B2-%s\\n' selected\r")
            try waitForLine("B2-selected", in: host)
            let terminal = try XCTUnwrap(host.hosting.terminalView)
            XCTAssertTrue(host.window.makeFirstResponder(terminal))
            try selectCommandAndOutput(in: terminal)
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let key = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil, characters: "L",
                charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
            XCTAssertEqual(terminal.menu(for: click)?.items.first?.title, L10n.string("Attach Selection to Message"))
            XCTAssertTrue(terminal.performKeyEquivalent(with: key))
            host.settle()
            let heading = L10n.format("Terminal (%@):", "yardlet") + "\n```\n"
            XCTAssertTrue(draft.text.hasPrefix(heading), "An empty message starts with the block: \(draft.text)")
            XCTAssertTrue(draft.text.hasSuffix("printf 'B2-%s\\n' selected\nB2-selected\n```\n"), draft.text)
            XCTAssertEqual(draft.selection?.lowerBound, draft.text.endIndex, "the caret goes after the block")
            // A window never shown never becomes key, so the composer's own step that puts the caret back
            // (`ComposerEditor`, which reads the key window's field) leaves AppKit's select-all here; the
            // field is drawn with the caret where that step puts it.
            Self.editableFields(in: host.hosting).forEach {
                $0.setSelectedRange(NSRange(location: $0.string.utf16.count, length: 0))
            }
            try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                          to: directory.appending(path: "attach-light.png"))

            defaults.set(false, forKey: TerminalSharingPreference.key)
            host.settle()
            let attached = draft.text
            XCTAssertNil(terminal.menu(for: click), "Not shared, the terminal has no menu")
            XCTAssertFalse(terminal.performKeyEquivalent(with: key))
            XCTAssertEqual(draft.text, attached, "and the key attaches nothing")
            defaults.removeObject(forKey: TerminalSharingPreference.key)
            host.settle()
        }
        workspace.endTerminal()
        // After what the message says, one blank line apart.
        let block = L10n.format("Terminal (%@):", "yardlet") + "\n```\nB2\n```\n"
        XCTAssertEqual(TerminalSelectionText.appending("B2\n", from: "yardlet", to: "Why?"), "Why?\n\n" + block)
        XCTAssertEqual(TerminalSelectionText.appending("B2", from: "yardlet", to: "Why?\n"), "Why?\n\n" + block)
        XCTAssertEqual(TerminalSelectionText.appending("B2", from: "yardlet", to: " \n"), block)
        XCTAssertEqual(TerminalSelectionText.appending("a ``` b", from: "t", to: ""),
                       L10n.format("Terminal (%@):", "t") + "\n````\na ``` b\n````\n", "A longer fence around one inside")

        // The setting, below the browser tools' switch in Settings › General.
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter())
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 820, height: 1_400), appearance: appearance)
            defer { host.close() }
            host.settle()
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "settings-terminal-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let labels = host.accessibilityElements().filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
                .map(\.label)
            XCTAssertTrue(labels.contains(L10n.string("Share the terminal with agents")), labels.description)
        }
    }

    /// With Settings' terminal location on the right, a terminal shown below moves to the side panel as its
    /// Terminal tab, beside the panel's other tabs, with its own tabs in a row under the panel's strip; Run in
    /// terminal types there; and back at Bottom it shows below again. Review images:
    /// `.build/terminal-tabs-qa/right-*.png`.
    func testOnTheRightTheTerminalIsTheSidePanelsTerminalTab() throws {
        let directory = try WindowlessRender.directory("terminal-tabs-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TerminalLocation")))
        defaults.set(TerminalLocation.right.rawValue, forKey: TerminalLocation.key)
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let fixture = HandoffFixture.all(workspace: try temporaryFolder(named: "yardlet"))[0]
        let workspace = TaskWorkspaceState()
        workspace.setPanels(Projection.showing("files", in: .init(isTerminalPresented: true)))
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                TaskTerminalHost(fixture: fixture, workspace: workspace)
                    .environment(\.terminalShellLaunch, launch)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .defaultAppStorage(defaults)
                    .frame(width: 1_200, height: 820)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 1_200, height: 820), appearance: appearance
            )
            defer { host.close() }
            host.settle()
            XCTAssertFalse(workspace.panels.isTerminalPresented, "nothing below")
            XCTAssertEqual(workspace.panels.trailingSurfaceID, "terminal")
            XCTAssertEqual(workspace.panels.trailingTabs, ["files", "terminal"])
            if appearance == .light {
                let shell = workspace.terminal(in: fixture.workspaceURL, launch: launch, taskID: nil)
                try waitUntilSettled(in: host) { shell.isAtPrompt && host.hosting.terminalText.contains("%") }
                workspace.openTerminalTab(in: fixture.workspaceURL, launch: launch, taskID: nil).name = "server"
                host.settle()
                workspace.showTerminalTab(shell)
                host.settle()
                XCTAssertEqual(host.hosting.pressAccessibilityElements(labelled: L10n.string("Run in terminal")), 1)
                try waitForText("B10-%s", in: host)
                XCTAssertEqual(workspace.panels.trailingSurfaceID, "terminal", "Run in terminal shows it where it is")
                XCTAssertFalse(workspace.panels.isTerminalPresented, "and not below as well")
                host.settle(passes: 6, interval: 0.1)
                XCTAssertEqual(host.hosting.terminalText.components(separatedBy: "B10-%s").count - 1, 1,
                               "typed once: \(host.hosting.terminalText)")
            }
            host.settle(passes: 6, interval: 0.1)
            try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                          to: directory.appending(path: "right-\(appearance.suffix).png"))
            guard appearance == .dark else { continue }
            defaults.set(TerminalLocation.bottom.rawValue, forKey: TerminalLocation.key)
            host.settle()
            XCTAssertTrue(workspace.panels.isTerminalPresented, "back below")
            XCTAssertEqual(workspace.panels.trailingTabs, ["files"])
        }
        workspace.endTerminal()
    }

    /// Split: a second tab beside the shown one below the conversation, one above the other as the side
    /// panel's Terminal tab, each half under its tab's name, its shell started. Review images:
    /// `.build/terminal-tabs-qa/split-*.png`.
    func testTheTerminalSplitsBelowAndInTheSidePanel() throws {
        let directory = try WindowlessRender.directory("terminal-tabs-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TerminalSplit")))
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let fixture = HandoffFixture.all(workspace: try temporaryFolder(named: "yardlet"))[0]
        for (location, appearances) in [(TerminalLocation.bottom, WindowlessRender.Appearance.allCases),
                                        (TerminalLocation.right, [WindowlessRender.Appearance.light])] {
            defaults.set(location.rawValue, forKey: TerminalLocation.key)
            let workspace = TaskWorkspaceState()
            workspace.setPanels(.init(isTerminalPresented: true))
            for appearance in appearances {
                let host = WindowlessRender.Host(
                    TaskTerminalHost(fixture: fixture, workspace: workspace)
                        .environment(\.terminalShellLaunch, launch)
                        .environment(\.colorScheme, appearance.colorScheme)
                        .defaultAppStorage(defaults)
                        .frame(width: 1_200, height: 820)
                        .background(ParityTheme.canvas),
                    size: NSSize(width: 1_200, height: 820), appearance: appearance
                )
                defer { host.close() }
                host.settle()
                if workspace.splitTerminal == nil {
                    let shown = workspace.terminal(in: fixture.workspaceURL, launch: launch, taskID: nil)
                    try waitUntilSettled(in: host) { shown.isAtPrompt }
                    XCTAssertEqual(host.hosting.pressAccessibilityElements(labelled: L10n.string("Split Terminal")), 1)
                    host.settle()
                }
                let split = try XCTUnwrap(workspace.splitTerminal)
                try waitUntilSettled(in: host) { split.isAtPrompt && split.bufferText.contains("%") }
                XCTAssertEqual(workspace.terminals.count, 2)
                host.settle(passes: 6, interval: 0.1)
                try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                              to: directory.appending(path: "split-\(location.rawValue)-\(appearance.suffix).png"))
            }
            workspace.endTerminal()
        }
        defaults.removeObject(forKey: TerminalLocation.key)
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
            try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                          to: directory.appending(path: "tabs-\(appearance.suffix).png"))
            workspace.endTerminal()
        }
    }

    /// The window as the screen shows it. A capture of the window draws neither SwiftTerm's default
    /// background, which it leaves to its layer, nor its text where it sits (drawn by an ancestor, the
    /// text lands to the right of the view): the capture is laid over the terminal's background, and
    /// each terminal, captured on its own, is put back in its place.
    static func asShown(_ host: WindowlessRender.Host<some View>,
                                appearance: WindowlessRender.Appearance) throws -> NSBitmapImageRep {
        let window = try host.capture().bitmap
        let image = try XCTUnwrap(window.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(TerminalAppearance.background(isDark: appearance == .dark).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for terminal in host.hosting.terminalViews {
            let alone = try XCTUnwrap(WindowlessRender.capture(terminal).cgImage)
            let scale = CGFloat(image.width) / host.hosting.bounds.width
            let frame = host.hosting.convert(terminal.bounds, from: terminal)
            let bottom = host.hosting.isFlipped ? host.hosting.bounds.height - frame.maxY : frame.minY
            let place = CGRect(x: frame.minX * scale, y: bottom * scale,
                               width: frame.width * scale, height: frame.height * scale)
            context.fill(place)
            context.draw(alone, in: place)
        }
        let shown = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        shown.size = window.size
        return shown
    }

    private static func editableFields(in view: NSView) -> [NSTextView] {
        ((view as? NSTextView).flatMap { $0.isEditable ? [$0] : nil } ?? []) + view.subviews.flatMap(editableFields)
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
    /// is running runs the next handoff in the same shell; one whose shell has exited starts a new one.
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
        try waitForLine("B10-first", in: host)
        let firstShell = try XCTUnwrap(host.hosting.terminalView?.process.shellPid)
        workspace.handOffToTerminal(#"printf 'B10-%s-%s\n' same "$B10_SHELL""#)
        try waitForLine("B10-same-\(firstShell)", in: host)

        // The pane learns the shell exited when SwiftTerm reports the process ended, which can come after
        // SwiftTerm's own `process.running` turns false on the terminal closing.
        let shell = try XCTUnwrap(host.hosting.terminalView?.session)
        workspace.handOffToTerminal("exit")
        try waitUntilSettled(in: host) { !shell.isRunning }
        workspace.handOffToTerminal(#"printf 'B10-%s-%s\n' new "${B10_SHELL:-unset}""#)
        try waitForLine("B10-new-unset", in: host)
        XCTAssertNotEqual(host.hosting.terminalView?.process.shellPid, firstShell)
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("terminal-handoff-qa")
            .appending(path: "pane-restarted-light.png"))
        XCTAssertFalse(Self.added(to: history).contains("B10-%s"), "A test's command reached ~/.zsh_history")
    }

    // MARK: - Code blocks

    /// Which of an answer's code blocks offer "Run in terminal", and what each runs: a shell block whole, the
    /// command lines of a `$ ` session without the prompts and the output, a block without a language only
    /// when every line reads as a command, and no block that hides a formatting character.
    func testACodeBlockRunsWhatItsShellLanguageOrPromptsSay() {
        func command(_ language: String?, _ code: String) -> String? {
            TerminalCodeBlockCommand.command(language: language, code: code)
        }
        XCTAssertEqual(command("bash", "git status\nnpm test\n\n"), "git status\nnpm test")
        XCTAssertEqual(command("zsh title=setup", "brew install jq"), "brew install jq", "the info string's first word")
        XCTAssertEqual(command("console", "$ npm install\nadded 5 packages\n$ npm test\n> app@1.0.0 test\nok\n"),
                       "npm install\nnpm test", "the prompts and the output are left out")
        XCTAssertEqual(command("shell-session", "$ docker run \\\n  --rm hello\nHello from Docker!"),
                       "docker run \\\n  --rm hello", "a line ending in a backslash goes on")
        XCTAssertEqual(command("console", "$ echo 'a\n> b'\na\nb"), "echo 'a\nb'", "an open quote's > line goes on")
        XCTAssertEqual(command("bash", "$ git pull\nAlready up to date."), "git pull", "a shell block in prompts")
        XCTAssertNil(command("console", "added 5 packages"), "a session with no prompt runs nothing")
        XCTAssertEqual(command(nil, "git status\nnpm install"), "git status\nnpm install")
        XCTAssertEqual(command("text", "./scripts/test-fast.sh"), "./scripts/test-fast.sh")
        XCTAssertEqual(command(nil, "$ git status"), "git status")
        XCTAssertNil(command(nil, "npm install && npm test"), "no language and a shell operator")
        XCTAssertNil(command(nil, "git status\nThen open the app."), "every line must read as a command")
        XCTAssertNil(command("python", "print(1)"))
        XCTAssertNil(command("swift", "git status"))
        XCTAssertNil(command("bash", "git status\u{200B}"), "a zero-width space")
        XCTAssertNil(command("bash", "echo \u{202E}txt.exe"), "a direction override")
        XCTAssertNil(command("bash", "  \n"))
    }

    /// An answer's bash and console blocks in the task screen offer "Run in terminal" beside "Copy code";
    /// the console block's runs its command lines in the task's terminal, Return and all, and its output
    /// shows there; a conversation without a terminal offers it on no block. Review images:
    /// `.build/terminal-handoff-qa/code-blocks-*.png`.
    func testAnAnswersShellCodeBlockRunsInTheTasksTerminal() throws {
        let history = Self.personalHistory()
        let directory = try WindowlessRender.directory("terminal-handoff-qa")
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let workspaceURL = try temporaryFolder(named: "yardlet")
        let answer = """
            Install the tools, then run the check.

            ```bash
            brew install jq
            jq --version
            ```

            Or in a terminal session:

            ```console
            $ printf 'B2C-%s\\n' ran
            B2C-ran
            ```
            """
        let fixture = HandoffFixture(name: "code-blocks", harness: .claudeCode, command: "", workspaceURL: workspaceURL,
                                     entries: [TranscriptEntry(content: .user(text: "How do I check it?")),
                                               TranscriptEntry(content: .assistant(text: answer, isStreaming: false))])
        let workspace = TaskWorkspaceState()
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                TaskTerminalHost(fixture: fixture, workspace: workspace)
                    .environment(\.terminalShellLaunch, launch)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: 1_000, height: 820)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 1_000, height: 820), appearance: appearance
            )
            defer { host.close() }
            host.settle()
            let runs = host.accessibilityElements().filter { $0.label == L10n.string("Run in terminal") }
            XCTAssertEqual(runs.count, 2, "\(host.accessibilityElements())")
            if appearance == .light {
                XCTAssertEqual(host.hosting.pressAccessibilityElements(labelled: L10n.string("Run in terminal"),
                                                                       valueContaining: "console"), 1)
                host.settle()
                XCTAssertTrue(workspace.panels.isTerminalPresented, "the terminal opens")
                var buffer = ""
                let deadline = ContinuousClock.now + testWaitLimit
                while ContinuousClock.now < deadline {
                    host.settle(passes: 1, interval: 0.05)
                    buffer = host.hosting.terminalText
                    if buffer.components(separatedBy: "\n").contains(where: { $0.hasPrefix("B2C-ran") }) { break }
                }
                XCTAssertTrue(buffer.components(separatedBy: "\n").contains { $0.hasPrefix("B2C-ran") },
                              "it ran: \(buffer)")
                XCTAssertFalse(buffer.contains("$ printf"), "without the prompt: \(buffer)")
                XCTAssertFalse(buffer.contains("brew"), "the other block stays where it is: \(buffer)")
            }
            try WindowlessRender.writePNG(Self.asShown(host, appearance: appearance),
                                          to: directory.appending(path: "code-blocks-\(appearance.suffix).png"))
        }
        workspace.endTerminal()
        XCTAssertFalse(Self.added(to: history).contains("B2C-"), "A test's command reached ~/.zsh_history")

        // Without a terminal (a side chat), no block offers it.
        let without = WindowlessRender.Host(fixture.conversation(actions: ConversationActions())
            .frame(width: 760, height: 560), size: NSSize(width: 760, height: 560), appearance: .light)
        defer { without.close() }
        without.settle()
        XCTAssertFalse(without.accessibilityElements().contains(label: L10n.string("Run in terminal")))
    }

    /// "Run in terminal" pastes the command as the shell takes a paste before its Return: its trailing
    /// line breaks left out, and a command over several lines as a bracketed paste when the shell asked
    /// for it, so the one Return runs every line.
    func testAHandedOffCommandGoesInAsAPaste() {
        XCTAssertEqual(NativeTerminalSession.pasteText("git status\n"), "git status")
        XCTAssertEqual(NativeTerminalSession.pasteText("a &&\nb", bracketedPaste: true), "\u{1B}[200~a &&\nb\u{1B}[201~")
        XCTAssertEqual(NativeTerminalSession.pasteText("a &&\nb", bracketedPaste: false), "a &&\nb")
    }

    // MARK: - Helpers

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
    var draft = TaskComposerDraft()
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            session: fixture.session, composerDraft: draft, workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, transcript: TaskTranscriptReader(fixture.entries), errorMessage: nil,
            codexTaskState: TaskCodexStateReader(fixture.codexTaskState), codexHistorySelection: nil, codexQueue: [],
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
    /// Every terminal view under this one: both halves of a split terminal.
    var terminalViews: [NativeTerminalView] {
        ((self as? NativeTerminalView).map { [$0] } ?? []) + subviews.flatMap(\.terminalViews)
    }

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

    /// Presses every accessibility element under the view with this label (and a value holding
    /// `value`, when given), as an assistive app would, and returns how many it pressed. SwiftUI builds
    /// its accessibility tree only while an assistive app has announced itself (`AXEnhancedUserInterface`),
    /// which this sets and puts back.
    func pressAccessibilityElements(labelled label: String, valueContaining value: String? = nil) -> Int {
        WindowlessRender.withAccessibilityTree {
            var found: [AnyObject] = []
            var visited: Set<ObjectIdentifier> = []
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    let read: Any? = (child.accessibilityValue?() as Any??) ?? nil
                    let text = (read as? String) ?? (read as? NSAttributedString)?.string ?? ""
                    if (child.accessibilityLabel?() ?? nil) == label, value.map({ text.contains($0) }) ?? true {
                        found.append(child)
                    }
                    visit(child)
                }
            }
            visit(self)
            return found.filter { $0.accessibilityPerformPress?() ?? false }.count
        }
    }
}
