import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Commands start folded (decision of 2026-10-16;
/// `ConversationWorkDisclosure`): a command's line and a summary of commands only start
/// folded while they run and after, the line marking that it runs; a failed command, a summary with a
/// failed call and a waiting request stay in view; what the person opened or folded stays so. Claude
/// Code's Bash call that the CLI also tracks as a task (`local_bash`) is the command's line, not a
/// subagent card, and stops from the line.
///
/// Drawn without a provider, account, network or user data into `.build/command-disclosure-qa/`:
/// `claude-{light,dark}.png` (a running Claude Code turn as the person reported it: a finished
/// command, the running command the CLI tracks as a task, a summary of two commands, a failed
/// command and a waiting request), `codex-{light,dark}.png` (a running Codex turn: a summary of
/// commands with one running, a running command, a failed command), and `claude-opened-light.png`
/// (the same Claude turn after opening the running command and the summary).
@MainActor
final class CommandDisclosureTests: XCTestCase {
    private static let source = ConversationItemSource.transcript(TranscriptEntry(content: .plan("")))
    private static let workspace = URL(filePath: "/tmp/command-disclosure-qa", directoryHint: .isDirectory)

    // MARK: - The rule

    func testACommandStartsFoldedWhileItRunsAndAfterAndOpensWhenItFails() {
        let command = ConversationItemKind.command(ConversationCommand(command: "swift test", status: "inProgress"))
        let tool = ConversationItemKind.tool(ConversationTool(kind: .activity("Read"), name: "Read"))
        let edit = ConversationItemKind.fileChange(ConversationFileChange(rows: [], handoffs: []))
        let thinking = ConversationItemKind.reasoning(summary: nil, detail: "…", isStreaming: true)
        func opens(_ kind: ConversationItemKind, _ phase: ConversationItemPhase) -> Bool {
            ConversationWorkDisclosure.lineStartsOpen(ConversationItem(id: "i", kind: kind, phase: phase, source: Self.source))
        }
        XCTAssertFalse(opens(command, .running), "a running command starts folded")
        XCTAssertFalse(opens(command, .completed))
        XCTAssertFalse(opens(command, .stopped))
        XCTAssertTrue(opens(command, .failed), "a failed command opens on what went wrong")
        // Every other call, and the thinking, too (2026-10-16: not even a running call opens):
        // folded while it runs and after, open when it fails.
        for kind in [tool, edit, thinking] {
            XCTAssertFalse(opens(kind, .running), "\(kind)")
            XCTAssertFalse(opens(kind, .completed), "\(kind)")
            XCTAssertTrue(opens(kind, .failed), "\(kind)")
        }
    }

    func testASummaryOfCommandsStartsFoldedWhileItsTurnRuns() {
        func item(_ id: String, _ kind: ConversationItemKind, _ phase: ConversationItemPhase) -> ConversationItem {
            ConversationItem(id: id, kind: kind, phase: phase, source: Self.source)
        }
        let ran = item("c1", .command(ConversationCommand(command: "git status", status: "completed")), .completed)
        let running = item("c2", .command(ConversationCommand(command: "swift build", status: "inProgress")), .running)
        let failed = item("c3", .command(ConversationCommand(command: "swift test", status: "failed")), .failed)
        let read = item("r1", .tool(ConversationTool(kind: .activity("Read"), name: "Read")), .completed)
        func opens(_ items: [ConversationItem], running turn: Bool, opened: Bool = false) -> Bool {
            ConversationWorkDisclosure.groupStartsOpen(items, turnIsRunning: turn, workWasOpened: opened)
        }
        XCTAssertFalse(opens([ran, running], running: true), "commands only, while the turn runs")
        XCTAssertFalse(opens([ran, ran], running: true))
        XCTAssertFalse(opens([ran, running], running: false), "a background command after the turn ended")
        XCTAssertTrue(opens([ran, failed], running: true), "a failed command opens its summary")
        XCTAssertFalse(opens([ran, read], running: true), "a summary with other calls stays folded while the turn runs")
        XCTAssertFalse(opens([read, running], running: false), "and while one of its calls still runs")
        XCTAssertFalse(opens([ran, read], running: false), "a finished summary starts folded")
        XCTAssertTrue(opens([ran, ran], running: false, opened: true),
                      "the person opened the finished turn's folded work to see it")
        XCTAssertTrue(ConversationWorkDisclosure.groupHasFailure([ran, failed]))
        XCTAssertFalse(ConversationWorkDisclosure.groupHasFailure([ran, running]))
    }

    // MARK: - Claude Code's shell task

    /// The frames Claude Code 2.1.291 sent for a foreground Bash call it also tracks as a task
    /// (`task_started`, `task_type: local_bash`): the call stays its command's line, which can stop
    /// the task, where it used to become a subagent card ("Bash" badge, "Completed").
    func testClaudeCodesShellTaskIsTheCommandsLine() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Run the slow command")
        for frame in [SendNowFrames.toolUse, SendNowFrames.taskStarted] {
            for payload in projection.payloads(from: try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))) {
                builder.apply(payload)
            }
        }
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.last)
        let item = try XCTUnwrap(turn.work.first)
        XCTAssertEqual(turn.work.count, 1, "\(turn.work)")
        guard case let .command(command) = item.kind else { return XCTFail("\(item.kind)") }
        XCTAssertEqual(item.phase, .running)
        XCTAssertEqual(command.command, "sleep 20 && echo done")
        XCTAssertEqual(command.description, "Run sleep 20 seconds then print done")
        XCTAssertEqual(command.task, ConversationCommandTask(
            activityID: SendNowFrames.toolUseID,
            reference: HarnessSubtaskReference(taskID: SendNowFrames.taskID, toolUseID: SendNowFrames.toolUseID,
                                               taskType: "local_bash")
        ))
        XCTAssertFalse(ConversationWorkDisclosure.lineStartsOpen(item))

        // A shell task reported without its call names only its description; an agent stays the
        // subagent card.
        let bare = HarnessActivity(id: "claude-task:t9", kind: "Task", title: "Watch the build log",
                                   subtask: HarnessSubtaskReference(taskID: "t9", taskType: "local_bash"))
        guard case let .command(shell) = ConversationActivityProjection.kind(
            bare, harness: .claudeCode, phase: .running, isApproved: false
        ) else { return XCTFail("a shell task is a command") }
        XCTAssertEqual(shell.command, "")
        XCTAssertEqual(shell.description, "Watch the build log")
        XCTAssertEqual(shell.task?.activityID, "claude-task:t9")
        let agent = HarnessActivity(id: "agent", kind: "Agent", title: "Review the parser",
                                    subtask: HarnessSubtaskReference(taskID: "t1", taskType: "local_agent"))
        guard case .subagent = ConversationActivityProjection.kind(agent, harness: .claudeCode, phase: .running,
                                                                   isApproved: false)
        else { return XCTFail("an agent is the subagent card") }
    }

    // MARK: - Drawn

    /// The Claude Code turn the person reported, drawn: every command reads folded on its line, the
    /// running ones marked running, the shell task with its stop control and without a card; the
    /// summary of two commands folded; the failed command open on its output; the waiting request
    /// pinned under the turn with its answers.
    func testAClaudeCodeTurnDrawsItsCommandsFolded() throws {
        let directory = try WindowlessRender.directory("command-disclosure-qa")
        var stopped: [String] = []
        let entries = ClaudeTurn.entries()
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ClaudeTurn.timeline(entries, actions: ClaudeTurn.actions { stopped.append($0) }),
                size: ClaudeTurn.size, appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let elements = drawing.elements
            let collapsed = L10n.string("Collapsed"), expanded = L10n.string("Expanded")
            XCTAssertTrue(elements.contains(label: ClaudeTurn.words(ClaudeTurn.checked, .completed), value: collapsed),
                          "\(elements)")
            XCTAssertTrue(elements.contains(label: ClaudeTurn.words(ClaudeTurn.measuring, .running), value: collapsed),
                          "the running command starts folded: \(elements)")
            XCTAssertTrue(elements.contains(label: ClaudeTurn.summary, value: collapsed),
                          "the summary of commands starts folded: \(elements)")
            XCTAssertTrue(elements.contains(label: ClaudeTurn.words(ClaudeTurn.failing, .failed), value: expanded),
                          "the failed command opens: \(elements)")
            XCTAssertTrue(elements.contains(text: "error: no such module 'Parser'"), "\(elements)")
            XCTAssertFalse(elements.contains(text: ClaudeTurn.sampleOutput), "the running command's output is folded")
            XCTAssertFalse(elements.contains(text: "swift build"), "the summary's lines are folded: \(elements)")
            // The subagent card was titled with the description as written.
            XCTAssertFalse(elements.contains(label: ClaudeTurn.measuring), "no card for the shell task: \(elements)")
            // The waiting request stays in view under the turn with its answers (D1).
            let buttons = elements.filter { $0.role == NSAccessibility.Role.button.rawValue }.map(\.label)
            XCTAssertTrue(buttons.contains(L10n.string("Allow")) && buttons.contains(L10n.string("Deny")), "\(buttons)")
            XCTAssertEqual(buttons.filter { $0 == L10n.string("Stop task") }.count, 1,
                           "the running shell task stops from its line: \(buttons)")
        }

        // The stop control stops that task, by the activity that started it.
        let host = WindowlessRender.Host(
            ClaudeTurn.timeline(entries, actions: ClaudeTurn.actions { stopped.append($0) })
                .frame(width: ClaudeTurn.size.width, height: ClaudeTurn.size.height, alignment: .top),
            size: ClaudeTurn.size, appearance: .light
        )
        defer { host.close() }
        host.settle(passes: 10)
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Stop task")))
        XCTAssertEqual(stopped, ["toolu_measure"])

        // Opened by the person, the running command and the summary show what they hold.
        XCTAssertTrue(host.hosting.pressButton(labeled: ClaudeTurn.words(ClaudeTurn.measuring, .running)))
        XCTAssertTrue(host.hosting.pressButton(labeled: ClaudeTurn.summary))
        host.settle()
        let opened = host.accessibilityElements()
        XCTAssertTrue(opened.contains(label: ClaudeTurn.words(ClaudeTurn.measuring, .running),
                                      value: L10n.string("Expanded")), "\(opened)")
        XCTAssertTrue(opened.contains(label: ClaudeTurn.summary, value: L10n.string("Expanded")), "\(opened)")
        // Its lines show, each command still folded on its own line.
        XCTAssertTrue(opened.contains(label: ClaudeTurn.words("Build the app", .running), value: L10n.string("Collapsed")),
                      "\(opened)")
        XCTAssertFalse(opened.contains(text: "swift build"), "\(opened)")
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "claude-opened-light.png"))
    }

    /// A running Codex turn: the summary of commands folded on the running command's line, a running
    /// command folded with its live output, a failed command open on its exit code.
    func testACodexTurnDrawsItsCommandsFolded() throws {
        let directory = try WindowlessRender.directory("command-disclosure-qa")
        let state = CodexTurn.state()
        let size = NSSize(width: 820, height: 760)
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                TaskConversationView(harness: .codex, workspaceURL: Self.workspace, entries: [], sessionStatus: .running,
                                     codexTaskState: state, actions: ConversationActions()),
                size: size, appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "codex-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let elements = drawing.elements
            let collapsed = L10n.string("Collapsed"), expanded = L10n.string("Expanded")
            let header = ConversationLineWording.codex(.unknown(command: "swift test --filter ParserTests"),
                                                       phase: .running).text
            XCTAssertTrue(elements.contains(label: header, value: collapsed),
                          "the summary reads its running command, folded: \(elements)")
            XCTAssertFalse(elements.contains(text: "Test Suite 'ParserTests' started."), "\(elements)")
            let lint = ConversationLineWording.codex(.unknown(command: "npm run lint"), phase: .running).text
            XCTAssertTrue(elements.contains(label: lint, value: collapsed), "\(elements)")
            XCTAssertFalse(elements.contains(text: "Linting 42 files"), "the live output is folded: \(elements)")
            let build = ConversationLineWording.codex(.unknown(command: "swift build"), phase: .failed).text
            XCTAssertTrue(elements.contains(label: build, value: expanded), "the failed command opens: \(elements)")
            XCTAssertTrue(elements.contains(text: L10n.format("Exit code %lld", Int64(1))), "\(elements)")
        }
    }

    // MARK: - The person's choice

    /// What the person opened or folded stays so: under the live line while its calls run, and on
    /// the line or summary the run settles into once they ran; a call that fails later opens itself.
    func testWhatThePersonOpenedOrFoldedStays() throws {
        let user = TranscriptEntry(content: .user(text: "Build it"))
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID(), words = UUID()
        func bash(_ id: UUID, _ tool: String, _ command: String, _ description: String,
                  _ state: TranscriptActivityState, output: String? = nil) -> TranscriptEntry {
            TranscriptEntry(id: id, content: .activity(HarnessActivity(
                id: tool, kind: "Bash", title: "Bash", detail: command,
                outcome: state == .failed ? .failed : nil,
                input: command + "\n\ndescription: " + description, output: output
            ), state: state))
        }
        func line(_ description: String, _ phase: ConversationItemPhase) -> String {
            ConversationLineWording.command(ConversationCommand(command: "x", status: "", description: description),
                                            phase: phase, harness: .claudeCode).map(\.text).joined(separator: ", ")
        }
        func view(_ entries: [TranscriptEntry]) -> some View {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions())
                .frame(width: 760, height: 700, alignment: .top)
        }
        func button(_ host: WindowlessRender.Host<some View>, _ matches: (String) -> Bool) -> WindowlessRender.AccessibilityElement? {
            host.accessibilityElements().first { matches($0.label) && $0.role == NSAccessibility.Role.button.rawValue }
        }
        func value(of label: String, in host: WindowlessRender.Host<some View>) -> String? {
            button(host) { $0 == label }?.value
        }
        /// The live line reads the running call's words, then the turn's steps and time.
        func live(_ words: String, in host: WindowlessRender.Host<some View>) -> WindowlessRender.AccessibilityElement? {
            button(host) { $0.hasPrefix(words + ", ") }
        }
        let collapsed = L10n.string("Collapsed"), expanded = L10n.string("Expanded")

        // One command running: the live line stands for it, folded, and the command is not listed
        // above it. Opened, it shows the command's line open on what it holds; once the command ran,
        // its own line stays open.
        let host = WindowlessRender.Host(view([user, bash(first, "a", "swift build", "Build the app", .running,
                                                          output: "Compiling")]),
                                         size: NSSize(width: 760, height: 700), appearance: .light)
        defer { host.close() }
        host.settle()
        let building = try XCTUnwrap(live(line("Build the app", .running), in: host), "\(host.accessibilityElements())")
        XCTAssertEqual(building.value, collapsed)
        XCTAssertNil(value(of: line("Build the app", .running), in: host), "not also listed above the live line")
        XCTAssertFalse(host.accessibilityElements().contains(text: "Compiling"), "nothing running starts open")
        XCTAssertTrue(host.hosting.pressButton { $0.hasPrefix(line("Build the app", .running) + ", ") })
        host.settle()
        XCTAssertEqual(live(line("Build the app", .running), in: host)?.value, expanded)
        XCTAssertEqual(value(of: line("Build the app", .running), in: host), expanded, "\(host.accessibilityElements())")
        host.hosting.rootView = view([user, bash(first, "a", "swift build", "Build the app", .completed,
                                                 output: "Build complete!"),
                                      TranscriptEntry(id: words, content: .assistant(text: "Built. Testing next.",
                                                                                     isStreaming: false))])
        host.settle()
        XCTAssertEqual(value(of: line("Build the app", .completed), in: host), expanded, "\(host.accessibilityElements())")
        XCTAssertTrue(host.accessibilityElements().contains(text: "Build complete!"))

        // A run of commands: the live line stands for it while one runs. Opened, it stays open as
        // more commands join it; folded again, it stays folded, and the summary the run settles
        // into is folded too.
        let ran = bash(second, "b", "swift test", "Run the tests", .completed, output: "Executed 3 tests")
        let two = [user, bash(first, "a", "swift build", "Build the app", .completed, output: "Build complete!"),
                   TranscriptEntry(id: words, content: .assistant(text: "Built. Testing next.", isStreaming: false)),
                   bash(second, "b", "swift test", "Run the tests", .running),
                   bash(third, "c", "swift run", "Run the app", .running)]
        host.hosting.rootView = view(two)
        host.settle()
        let running = try XCTUnwrap(live(line("Run the app", .running), in: host), "\(host.accessibilityElements())")
        XCTAssertEqual(running.value, collapsed)
        XCTAssertTrue(running.label.contains(L10n.format("%lld steps", Int64(3))), running.label)
        XCTAssertTrue(host.hosting.pressButton { $0.hasPrefix(line("Run the app", .running) + ", ") })
        host.settle()
        XCTAssertEqual(live(line("Run the app", .running), in: host)?.value, expanded)
        XCTAssertEqual(value(of: line("Run the tests", .running), in: host), collapsed, "each line still folded")
        host.hosting.rootView = view(Array(two.dropLast(2)) + [ran, bash(third, "c", "swift run", "Run the app", .running)])
        host.settle()
        let stillOpen = try XCTUnwrap(live(line("Run the app", .running), in: host))
        XCTAssertEqual(stillOpen.value, expanded, "it stays open as the run goes on")
        XCTAssertTrue(host.hosting.pressButton { $0.hasPrefix(line("Run the app", .running) + ", ") })
        host.settle()
        XCTAssertEqual(live(line("Run the app", .running), in: host)?.value, collapsed)
        let settled = Array(two.dropLast(2)) + [ran, bash(third, "c", "swift run", "Run the app", .completed, output: "ok")]
        host.hosting.rootView = view(settled)
        host.settle()
        let summary = ConversationWorkSummary.title(for: (1...2).map {
            ConversationItem(id: "\($0)", kind: .command(ConversationCommand(command: "\($0)", status: "")),
                             phase: .completed, source: Self.source)
        }, harness: .claudeCode)
        XCTAssertEqual(value(of: summary, in: host), collapsed, "\(host.accessibilityElements())")
        XCTAssertNil(value(of: line("Run the tests", .completed), in: host), "its lines are folded with it")

        // Opened in the listed work, a run reads open under the live line when a call joins it again;
        // folded there, it stays folded until a call fails.
        XCTAssertTrue(host.hosting.pressButton(labeled: summary))
        host.settle()
        XCTAssertEqual(value(of: summary, in: host), expanded)
        host.hosting.rootView = view(settled + [bash(fourth, "d", "swift run -v", "Run the app again", .running)])
        host.settle()
        XCTAssertEqual(live(line("Run the app again", .running), in: host)?.value, expanded,
                       "\(host.accessibilityElements())")
        XCTAssertTrue(host.hosting.pressButton { $0.hasPrefix(line("Run the app again", .running) + ", ") })
        host.settle()
        XCTAssertEqual(live(line("Run the app again", .running), in: host)?.value, collapsed)

        // A failure is what needs attention: the summary and the failed line open.
        host.hosting.rootView = view(Array(two.dropLast(2)) + [
            ran, bash(third, "c", "swift run", "Run the app", .failed, output: "Segmentation fault")
        ])
        host.settle()
        XCTAssertEqual(value(of: summary, in: host), expanded, "\(host.accessibilityElements())")
        XCTAssertEqual(value(of: line("Run the app", .failed), in: host), expanded)
        XCTAssertTrue(host.accessibilityElements().contains(text: "Segmentation fault"))
    }

    /// A failed call opens whatever the person chose before; otherwise the person's choice wins over
    /// where a line, summary or the live line would start.
    func testThePersonsChoiceDecidesWhereALineStarts() {
        func item(_ id: String, _ phase: ConversationItemPhase) -> ConversationItem {
            ConversationItem(id: id, kind: .command(ConversationCommand(command: id, status: "")), phase: phase,
                             source: Self.source)
        }
        let ran = item("a", .completed), running = item("b", .running), failed = item("c", .failed)
        XCTAssertTrue(ConversationWorkDisclosure.lineStartsOpen(ran, choice: true))
        XCTAssertFalse(ConversationWorkDisclosure.lineStartsOpen(ran, choice: false))
        XCTAssertTrue(ConversationWorkDisclosure.lineStartsOpen(failed, choice: false), "a failure opens")
        XCTAssertFalse(ConversationWorkDisclosure.groupStartsOpen([ran, ran], turnIsRunning: false, workWasOpened: true,
                                                                  choice: false), "folded by the person")
        XCTAssertTrue(ConversationWorkDisclosure.groupStartsOpen([ran, running], turnIsRunning: true,
                                                                 workWasOpened: false, choice: true))
        XCTAssertFalse(ConversationWorkDisclosure.liveLineStartsOpen([ran, running], choice: nil), "live line folded")
        XCTAssertTrue(ConversationWorkDisclosure.liveLineStartsOpen([ran, running], choice: true))
        XCTAssertTrue(ConversationWorkDisclosure.liveLineStartsOpen([failed, running], choice: false))

        let choices = ConversationDisclosureChoices()
        let key = ConversationDisclosureChoices.runKey([ran, running])
        XCTAssertEqual(key, ConversationDisclosureChoices.runKey([ran]), "a run keeps its key as calls join it")
        XCTAssertNil(choices.choice(key))
        choices.record(key, isOpen: true)
        XCTAssertEqual(choices.choice(key), true)
        XCTAssertNil(choices.choice("a"), "a run's choice is not its first line's")
    }
}

// MARK: - Fixtures

/// The running Claude Code turn the person reported.
@MainActor
private enum ClaudeTurn {
    static let size = NSSize(width: 820, height: 900)
    static let checked = "Check repo state and Yardlet CPU usage"
    static let measuring = "Measure Yardlet CPU and sample its threads"
    static let failing = "Run the parser tests"
    static let sampleOutput = "Sampling process 4242 for 3 seconds with 1 millisecond of run time between samples"
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Claude Bash call's line, in the test's language.
    static func words(_ description: String, _ phase: ConversationItemPhase) -> String {
        ConversationLineWording.command(ConversationCommand(command: "x", status: "", description: description),
                                        phase: phase, harness: .claudeCode).map(\.text).joined(separator: ", ")
    }

    /// "Ran 2 commands".
    static var summary: String {
        ConversationWorkSummary.title(for: [
            ConversationItem(id: "1", kind: .command(ConversationCommand(command: "a", status: "")), phase: .completed,
                             source: .transcript(TranscriptEntry(content: .plan("")))),
            ConversationItem(id: "2", kind: .command(ConversationCommand(command: "b", status: "")), phase: .running,
                             source: .transcript(TranscriptEntry(content: .plan(""))))
        ], harness: .claudeCode)
    }

    static func actions(stop: @escaping (String) -> Void) -> ConversationActions {
        var actions = ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in })
        actions.subtaskControls = HarnessActivityActions(open: { _ in }, stop: { stop($0.id) },
                                                         isStopping: { _ in false }, error: { _ in nil })
        return actions
    }

    static func timeline(_ entries: [TranscriptEntry], actions: ConversationActions) -> some View {
        ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                 latestTurnIsComplete: false),
                             actions: actions)
    }

    static func entries() -> [TranscriptEntry] {
        func bash(_ id: String, _ command: String, _ description: String, output: String? = nil,
                  outcome: HarnessActivityOutcome? = nil, task: String? = nil) -> HarnessActivity {
            HarnessActivity(id: id, kind: "Bash", title: task == nil ? "Bash" : description, detail: command,
                            outcome: outcome, input: command + "\n\ndescription: " + description, output: output,
                            isBackground: task == nil ? nil : false,
                            subtask: task.map { HarnessSubtaskReference(taskID: $0, toolUseID: id, taskType: "local_bash") })
        }
        let contents: [TranscriptEntryContent] = [
            .user(text: "Look into why Yardlet's CPU usage is high"),
            .activity(bash("toolu_check", "git status --short && ps -o %cpu= -p $(pgrep -x Yardlet)", checked,
                           output: " M Sources/App.swift\n 142.0"), state: .completed),
            .assistant(text: "Yardlet is at 142% CPU. Sampling its threads.", isStreaming: false),
            .activity(bash("toolu_measure", "sample Yardlet 3 -file /tmp/yardlet.sample", measuring,
                           output: sampleOutput, task: "b7x2k"), state: .running),
            .assistant(text: "While it samples, building and checking the tree.", isStreaming: false),
            .activity(bash("toolu_status", "git status", "Show the working tree",
                           output: "On branch main"), state: .completed),
            .activity(bash("toolu_build", "swift build", "Build the app"), state: .running),
            .assistant(text: "The parser tests next.", isStreaming: false),
            .activity(bash("toolu_test", "swift test --filter ParserTests", failing,
                           output: "error: no such module 'Parser'", outcome: .failed), state: .failed),
            .permission(PermissionRequest(id: "clean", title: "Bash", detail: "Remove the build folder",
                                          command: "rm -rf .build", toolCallID: "toolu_clean"), state: .pending)
        ]
        return contents.enumerated().map { index, content in
            TranscriptEntry(createdAt: start.addingTimeInterval(Double(index) * 4), content: content)
        }
    }
}

/// A running Codex turn with a summary of commands, a running command and a failed one.
private enum CodexTurn {
    static func state() -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        let workspace = "/tmp/command-disclosure-qa"
        func command(_ id: String, _ text: String, _ status: String, output: String, exitCode: Int64? = nil) -> JSONValue {
            var object: [String: JSONValue] = [
                "id": .string(id), "type": .string("commandExecution"), "command": .string(text),
                "cwd": .string(workspace), "status": .string(status), "commandActions": .array([]),
                "aggregatedOutput": .string(output)
            ]
            if let exitCode { object["exitCode"] = .integer(exitCode) }
            return .object(object)
        }
        func commentary(_ id: String, _ text: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text),
                     "phase": .string("commentary")])
        }
        var thread = decoder.thread(from: .object(["id": .string("thread-disclosure")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("inProgress"),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Fix the parser")])])]),
                command("c1", "git status --short", "completed", output: " M Sources/Parser.swift\n", exitCode: 0),
                command("c2", "swift test --filter ParserTests", "inProgress", output: "Test Suite 'ParserTests' started.\n"),
                commentary("m1", "Linting while the tests run."),
                command("c3", "npm run lint", "inProgress", output: "Linting 42 files\n"),
                commentary("m2", "Building once more."),
                command("c4", "swift build", "failed", output: "error: no such module 'Parser'\n", exitCode: 1)
            ])
        ]), fallbackID: "turn-1")!]
        // A thread read decodes its items as history; these two are still running, as the live
        // stream reports them (`item/started`).
        for index in thread.turns[0].items.indices where ["c2", "c3"].contains(thread.turns[0].items[index].id) {
            thread.turns[0].items[index].lifecycle = .inProgress
        }
        return CodexTaskState(thread: thread)
    }
}
