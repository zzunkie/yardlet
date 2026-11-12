import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude bash mode (`!`), as the Claude app's Code tab has it: the composer switch, the command
/// running in the task's folder in a pseudo-terminal, its output and its limit, stopping it, the
/// one message Claude receives, and saved bash commands read back from Claude's history. The CLI
/// is a fake transport speaking 2.1.291's frames; commands are `printf`, `seq` and `sleep` in
/// temporary folders, and no model is asked anything.
@MainActor final class ClaudeBashModeTests: XCTestCase {
    // MARK: - The message

    func testTheMessageIsTheClaudeAppsBashMessageAndReadsBackAsTheCommandAndItsOutput() throws {
        let text = ClaudeBashMessage.text(command: "npm i @types/node", stdout: "added <1> package & @scope/x", stderr: "warn")
        XCTAssertEqual(text, "<bash-input>npm i \u{FF20}types/node</bash-input>"
            + "<bash-stdout>added &lt;1&gt; package &amp; \u{FF20}scope/x</bash-stdout><bash-stderr>warn</bash-stderr>",
            "stdout and stderr escaped; an @ that starts a word is not a file mention for Claude Code")
        let message = try XCTUnwrap(ClaudeBashMessage.parse(text))
        XCTAssertEqual(message.command, "npm i \u{FF20}types/node")
        XCTAssertEqual(message.output, "added <1> package & \u{FF20}scope/x\nwarn")
        XCTAssertTrue(message.hasOutput)

        // An @ inside a word, an address or a lone @ stays as typed.
        XCTAssertEqual(ClaudeBashMessage.neutralizingMentions("a@b.c @ x\t@y"), "a@b.c @ x\t\u{FF20}y")

        // Nothing but bash tags: mixed text, slash-command tags or a missing command is a message.
        XCTAssertNil(ClaudeBashMessage.parse("Please look: <bash-input>ls</bash-input>"))
        XCTAssertNil(ClaudeBashMessage.parse("<bash-stdout>out</bash-stdout>"))
        XCTAssertNil(ClaudeBashMessage.parse("<command-name>/x</command-name><bash-input>ls</bash-input>"))
        XCTAssertNil(ClaudeBashMessage.parse("Run the tests"))

        let pending = try XCTUnwrap(ClaudeBashMessage.parse(ClaudeBashMessage.inputText(command: "sleep 5")))
        XCTAssertEqual(pending.command, "sleep 5")
        XCTAssertFalse(pending.hasOutput)
        XCTAssertEqual(ClaudeBashMessage.summary(of: text), "! npm i \u{FF20}types/node")
        XCTAssertEqual(ClaudeBashMessage.readableText(of: ClaudeBashMessage.text(command: "ls", stdout: "a\nb")), "! ls\na\nb")
    }

    func testOutputLongerThanTheClaudeAppsLimitKeepsItsEnd() {
        let output = (0..<3_000).map { String(format: "%05d %@", $0, String(repeating: "x", count: 40)) }
            .joined(separator: "\n")
        XCTAssertGreaterThan(output.count, ClaudeBashMessage.outputCharacterLimit)
        let capped = ClaudeBashMessage.capped(output)
        XCTAssertTrue(capped.hasPrefix("[output truncated]\n"))
        XCTAssertEqual(capped.count, ClaudeBashMessage.truncationMarker.count + ClaudeBashMessage.outputCharacterLimit)
        XCTAssertTrue(capped.hasSuffix("02999 " + String(repeating: "x", count: 40)))
        XCTAssertEqual(ClaudeBashMessage.capped("short"), "short")
    }

    // MARK: - The composer switch

    func testTypingBangIntoTheEmptyComposerEntersBashModeAndBackspaceEscapeOrSendingLeavesIt() throws {
        let draft = TaskComposerDraft()
        draft.text = "!"
        XCTAssertTrue(draft.enterBashModeIfTyped(after: ""))
        XCTAssertTrue(draft.isBashMode)
        XCTAssertEqual(draft.text, "", "The ! is the switch, not part of the command")

        // Only a ! typed into an empty composer, and never twice.
        XCTAssertFalse(draft.enterBashModeIfTyped(after: ""))
        let typing = TaskComposerDraft()
        typing.text = "echo"
        typing.text = "!"
        XCTAssertFalse(typing.enterBashModeIfTyped(after: "echo"))
        typing.text = "hi!"
        XCTAssertFalse(typing.enterBashModeIfTyped(after: "hi"))
        XCTAssertFalse(typing.isBashMode)

        // Backspace in the empty composer, or Escape, returns to chat.
        XCTAssertTrue(draft.leaveBashMode())
        XCTAssertFalse(draft.isBashMode)
        XCTAssertFalse(draft.leaveBashMode())

        // Running the command clears the composer back to chat.
        draft.text = "!"
        draft.enterBashModeIfTyped(after: "")
        draft.text = "ls -la"
        draft.clear()
        XCTAssertFalse(draft.isBashMode)

        // Not while a message is being edited.
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Edit")
        let editing = TaskComposerDraft()
        editing.editState = ConversationEditState(session: session, targetID: "t", previousID: nil, originalText: "x",
                                                  draft: TaskDraftSnapshot(), entries: [])
        editing.text = "!"
        XCTAssertFalse(editing.enterBashModeIfTyped(after: ""))
        XCTAssertEqual(editing.text, "!")
    }

    func testABashModeDraftIsSavedAndOlderDraftsReadAsChat() throws {
        let draft = TaskComposerDraft()
        draft.text = "!"
        draft.enterBashModeIfTyped(after: "")
        draft.text = "git status"
        let data = try JSONEncoder().encode(draft.snapshot)
        let restored = TaskComposerDraft()
        restored.apply(try JSONDecoder().decode(TaskDraftSnapshot.self, from: data))
        XCTAssertTrue(restored.isBashMode)
        XCTAssertEqual(restored.text, "git status")

        let older = try JSONDecoder().decode(TaskDraftSnapshot.self, from: Data(#"{"text":"hi","attachments":[]}"#.utf8))
        XCTAssertNil(older.isBashMode)
        restored.apply(older)
        XCTAssertFalse(restored.isBashMode)
        XCTAssertNil(TaskComposerDraft().snapshot.isBashMode, "Chat drafts save as they always did")
    }

    // MARK: - Running a command

    func testACommandRunsInTheTaskFolderWithTheUsersLoginShell() async throws {
        let folder = try temporaryFolder()
        let launch = ShellLaunchEnvironment.userLoginShell()
        XCTAssertEqual(launch.arguments, ["-l"], "The Claude app's bash-mode shell is `$SHELL -l`")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launch.executable))
        let result = try await run("printf 'yardlet-bash:%s\\n' \"$(pwd -P)\"", in: folder, launch: launch)
        XCTAssertNil(result.launchError)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.wasStopped)
        XCTAssertEqual(result.output, "yardlet-bash:\(try physicalPath(folder))",
                       "Only what the command printed: no rc output, prompt or typed line")
    }

    func testOutputIsTheTerminalTextWithStderrAndTheExitStatus() async throws {
        let folder = try temporaryFolder()
        let result = try await run(
            "printf 'out\\n'; printf '\\033[31mred\\033[0m\\n'; printf 'progress 10%%\\rprogress 100%%\\n'; printf 'err\\n' >&2; (exit 3)",
            in: folder
        )
        XCTAssertEqual(result.output, "out\nred\nprogress 100%\nerr",
                       "Colours dropped, a carriage-return line overwritten as a terminal shows it, stderr kept")
        XCTAssertEqual(result.exitCode, 3)

        let empty = try await run("true", in: folder)
        XCTAssertEqual(empty.output, "")
        XCTAssertEqual(empty.exitCode, 0)

        // `exit` ends the task's shell, as typing it into a terminal would; its status is the result.
        let shell = TaskShellProcess(workingDirectory: folder, launch: try plainShell())
        let exited = try await run("printf 'bye\\n'; exit 4", in: shell)
        XCTAssertEqual(exited.output, "bye")
        XCTAssertEqual(exited.exitCode, 4)
        XCTAssertFalse(shell.isAlive)
        XCTAssertFalse(shell.wasReset, "It ended on its own; nothing was reset")
    }

    func testOutputThatLeavesTheScrollbackIsMarkedTruncatedAndKeepsItsEnd() async throws {
        let folder = try temporaryFolder()
        let result = try await run("seq 1 6000", in: folder)
        XCTAssertTrue(result.output.hasPrefix(ClaudeBashMessage.truncationMarker), String(result.output.prefix(80)))
        XCTAssertTrue(result.output.hasSuffix("\n6000"))
        XCTAssertFalse(result.output.contains("\n1\n"))
        XCTAssertLessThanOrEqual(result.output.count, ClaudeBashMessage.truncationMarker.count + ClaudeBashMessage.outputCharacterLimit)
    }

    func testStoppingSendsControlCAndEndsACommandThatIgnoresIt() async throws {
        let folder = try temporaryFolder()
        let shell = TaskShellProcess(workingDirectory: folder, launch: try plainShell())
        shell.outputInterval = .milliseconds(20)
        addTeardownBlock { @MainActor in shell.close() }
        let process = shell.command("printf 'started\\n'; sleep 30; printf 'never\\n'", note: nil)
        var live: [String] = []
        var finished: ShellCommandResult?
        process.onOutput = { live.append($0) }
        process.onFinish = { finished = $0 }
        process.start()
        try await waitUntil(timeout: .seconds(15)) { live.last?.contains("started") == true }
        XCTAssertTrue(shell.isRunningCommand)
        let stoppedAt = ContinuousClock.now
        process.stop()
        try await waitUntil { finished != nil }
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .seconds(1), "Control-C ended it")
        XCTAssertEqual(finished?.wasStopped, true)
        // The terminal echoes the Control-C, as the terminal panel would show it.
        XCTAssertEqual(finished?.output.hasPrefix("started"), true)
        XCTAssertEqual(finished?.output.contains("never"), false, "Control-C ended the whole line")
        XCTAssertEqual(finished?.exitCode, 130)
        XCTAssertFalse(shell.isRunningCommand)
        XCTAssertTrue(shell.isAlive, "Control-C stops the command, not the task's shell")

        // A program that ignores Control-C: its process group is ended, and the shell goes on.
        shell.stopGracePeriod = .milliseconds(200)
        let stubborn = shell.command("cd /; sh -c \"trap '' INT; printf 'ready\\\\n'; sleep 30\"", note: nil)
        var ready = false
        var ended: ShellCommandResult?
        stubborn.onOutput = { ready = ready || $0.contains("ready") }
        stubborn.onFinish = { ended = $0 }
        stubborn.start()
        try await waitUntil { ready }
        stubborn.stop()
        try await waitUntil { ended != nil }
        XCTAssertEqual(ended?.wasStopped, true)
        XCTAssertEqual(ended?.signal, SIGKILL, "The program was ended after the grace period")
        XCTAssertTrue(shell.isAlive)
        try await waitUntil { NativeProcessTree.descendantProcessIDs(of: shell.processID).isEmpty }
        let after = try await run("pwd -P", in: shell)
        XCTAssertEqual(after.output, "/", "The same shell, where the stopped command left it")
        XCTAssertEqual(after.exitCode, 0)
    }

    func testAShellThatDoesNotAnswerControlCIsEndedAndTheNextCommandSaysTheShellIsNew() async throws {
        let folder = try temporaryFolder()
        let shells = TaskShells(launch: try plainShell()) { folder, launch in
            let shell = TaskShellProcess(workingDirectory: folder, launch: launch)
            shell.outputInterval = .milliseconds(20)
            shell.stopGracePeriod = .milliseconds(200)
            return shell
        }
        let task = UUID()
        addTeardownBlock { @MainActor in shells.closeAll() }
        _ = try await run("export YARDLET_KEPT=1", in: shells, task: task, folder: folder)
        let first = try XCTUnwrap(shells.shell(for: task) as? TaskShellProcess)
        let pid = first.processID

        // The shell itself ignores Control-C and is busy: nothing but ending it stops this.
        let hung = shells.command("trap '' INT; printf 'looping\\n'; while :; do :; done", for: task, in: folder)
        var looping = false
        var ended: ShellCommandResult?
        hung.onOutput = { looping = looping || $0.contains("looping") }
        hung.onFinish = { ended = $0 }
        hung.start()
        try await waitUntil { looping }
        hung.stop()
        try await waitUntil { ended != nil }
        XCTAssertEqual(ended?.wasStopped, true)
        XCTAssertEqual(ended?.signal, SIGKILL)
        XCTAssertEqual(ended?.output.hasPrefix("looping"), true)
        XCTAssertEqual(ended?.output.contains("6973"), false, "The line typed to ask the shell for a mark is not output")
        XCTAssertFalse(first.isAlive)
        XCTAssertTrue(first.wasReset)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Nothing is left running")

        let next = try await run("printf 'kept=%s\\n' \"${YARDLET_KEPT:-}\"", in: shells, task: task, folder: folder)
        XCTAssertEqual(next.output, "(new shell \u{2014} the previous command was still running and was stopped, "
            + "so the directory and environment were reset)\nkept=", "The Claude app's note, then the output")
        XCTAssertEqual(next.exitCode, 0)
        let again = try await run("printf 'quiet\\n'", in: shells, task: task, folder: folder)
        XCTAssertEqual(again.output, "quiet", "Said once")
    }

    func testAMissingFolderIsReportedWithoutStartingAShell() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "yardlet-bash-missing-\(UUID().uuidString)")
        let shell = TaskShellProcess(workingDirectory: missing, launch: try plainShell())
        let result = try await run("printf hi", in: shell)
        XCTAssertEqual(result.launchError, L10n.format("Working directory “%@” does not exist", missing.path))
        XCTAssertEqual(result.output, "")
        XCTAssertFalse(shell.isAlive, "A shell is not kept for a folder that is gone")
        XCTAssertEqual(shell.processID, 0, "Nothing was started")
    }

    // MARK: - Claude receives it

    func testACommandShowsInTheConversationAndItsOutputIsSentToClaudeAsOneMessage() async throws {
        let fixture = try await makeFixture(idle: true)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        let sentBefore = await transport.sentValues.count

        model.runShellCommand("printf 'hello from bash\\n'", in: task)
        XCTAssertTrue(model.isShellCommandRunning(in: task))
        let entry = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last)
        XCTAssertEqual(entry.content, .user(text: "<bash-input>printf 'hello from bash\\n'</bash-input>"))
        let run = try XCTUnwrap(model.shellCommandRun(entryID: entry.id))
        XCTAssertEqual(run.state, .running)

        try await waitUntil { await transport.sentValues.count == sentBefore + 1 }
        let expected = ClaudeBashMessage.text(command: "printf 'hello from bash\\n'", stdout: "hello from bash")
        let sent = try await lastSent(transport)
        XCTAssertEqual(sent["message"]?["content"]?.stringValue, expected, "One user message, as the Claude app sends")
        XCTAssertNil(sent["uuid"], "Sent as any message to an idle task, which Claude answers")
        XCTAssertEqual(run.state, .finished)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertFalse(model.isShellCommandRunning(in: task))
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content, .user(text: expected),
                       "The row is the message Claude got; no second bubble")
        XCTAssertEqual(lines(model, task).filter { $0.hasPrefix("user: ") }.count, 2)
        try await waitUntil { model.store.sessions.first?.status == .running }
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, task.providerSessionID,
                       "Same Claude session and storage")
    }

    func testOutputWaitsForTheRunningTurnAndAnEditAndAStoppedCommandIsNotSent() async throws {
        let fixture = try await makeFixture(idle: false)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        let sentBefore = await transport.sentValues.count

        model.runShellCommand("printf 'done\\n'", in: task)
        let entryID = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
        try await waitUntil { model.shellCommandRun(entryID: entryID)?.state == .finished }
        try await Task.sleep(for: .milliseconds(150))
        let whileRunning = await transport.sentValues.count
        XCTAssertEqual(whileRunning, sentBefore, "Claude's turn is still running; the output waits")

        // A second command while one runs is refused, and the composer says so.
        model.runShellCommand("sleep 30", in: task)
        let sleeping = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
        model.runShellCommand("printf again", in: task)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).notice, L10n.string("A shell command is already running"))
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.id, sleeping)

        // Stopped: kept in the conversation as stopped, never sent.
        model.stopShellCommand(in: task)
        try await waitUntil { model.shellCommandRun(entryID: sleeping)?.state == .stopped }

        // An earlier message being edited when the turn ends holds the output too, which would cut in front of
        // the edit; cancelling the edit lets it go.
        model.composerDrafts.tasks.draft(for: task.id).editState = ConversationEditState(session: task, targetID: "t",
            previousID: nil, originalText: "Earlier", draft: TaskDraftSnapshot(), entries: [])
        await transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await Task.sleep(for: .milliseconds(150))
        let whileEditing = await transport.sentValues.count
        XCTAssertEqual(whileEditing, sentBefore, "The output waits for the edit")
        model.cancelConversationEdit(in: task)
        try await waitUntil { await transport.sentValues.count == sentBefore + 1 }
        let sent = try await lastSent(transport)
        XCTAssertEqual(sent["message"]?["content"]?.stringValue,
                       ClaudeBashMessage.text(command: "printf 'done\\n'", stdout: "done"))
        try await waitUntil { model.store.sessions.first?.status == .running }
        await transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await Task.sleep(for: .milliseconds(150))
        let afterStopped = await transport.sentValues.count
        XCTAssertEqual(afterStopped, sentBefore + 1, "The stopped command was not sent")
    }

    func testOutputWaitsBehindQueuedMessagesAndACommandThatCouldNotStartStillTellsClaudeWhy() async throws {
        let fixture = try await makeFixture(idle: false, followUps: .queue)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await model.send(HarnessUserInput(text: "Then update the README"), to: task)
        try FileManager.default.removeItem(at: task.workspaceURL)
        model.runShellCommand("ls", in: task)
        let entryID = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
        var folder = task.workspaceURL.standardizedFileURL.path(percentEncoded: false)
        if folder.hasSuffix("/") { folder.removeLast() }
        let missing = L10n.format("Working directory “%@” does not exist", folder)
        try await waitUntil { model.shellCommandRun(entryID: entryID)?.state == .failed(missing) }

        await transport.emit(try json(result))
        try await waitUntil { await transport.sentValues.count == 2 }
        let first = try await lastSent(transport)
        XCTAssertEqual(first["message"]?["content"]?.stringValue, "Then update the README", "The queued message goes first")
        await transport.emit(try json(result))
        try await waitUntil { await transport.sentValues.count == 3 }
        let second = try await lastSent(transport)
        XCTAssertEqual(second["message"]?["content"]?.stringValue,
                       ClaudeBashMessage.text(command: "ls", stdout: "", stderr: missing))
    }

    func testATasksCommandsShareItsShellAndARunningCommandShowsTheTaskAsRunning() async throws {
        let fixture = try await makeFixture(idle: true)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        let sub = task.workspaceURL.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        // The directory and an exported variable carry to the next command, as in a terminal.
        for (index, command) in ["cd sub && export YARDLET_BASH=kept",
                                 "printf '%s %s\\n' \"$(pwd -P)\" \"$YARDLET_BASH\""].enumerated() {
            let sentBefore = await transport.sentValues.count
            model.runShellCommand(command, in: task)
            let entryID = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
            try await waitUntil(timeout: .seconds(15)) { model.shellCommandRun(entryID: entryID)?.state == .finished }
            if index == 1 {
                XCTAssertEqual(model.shellCommandRun(entryID: entryID)?.output, "\(try physicalPath(sub)) kept")
            }
            try await waitUntil { await transport.sentValues.count == sentBefore + 1 }
            try await waitUntil { model.store.sessions.first?.status == .running }
            await transport.emit(try json(result))
            try await waitUntil { model.store.sessions.first?.status == .ready }
        }
        let shell = try XCTUnwrap(model.taskShells.shell(for: task.id) as? TaskShellProcess)
        let pid = shell.processID

        // While a command runs the task reads as running in the sidebar and keeps the Mac awake;
        // the provider's status is Claude's and stays as it is.
        let activity = RunningWorkActivity()
        defer { activity.update(isWorking: false) }
        activity.update(isWorking: model.hasRunningWork)
        XCTAssertFalse(activity.isHolding)
        model.runShellCommand("sleep 30", in: task)
        let sleeping = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
        XCTAssertEqual(model.shellBusySessionIDs, [task.id])
        XCTAssertTrue(model.hasRunningWork)
        XCTAssertEqual(model.activeLocalSessions.map(\.id), [task.id], "Quitting asks first, as for a running turn")
        XCTAssertEqual(model.store.sessions.first?.status, .ready)
        var idleRecord = task
        idleRecord.status = .ready
        idleRecord.completionState = .none
        idleRecord.hasUnreadUpdate = false
        XCTAssertEqual(SidebarTaskIndicatorProjection.status(
            of: idleRecord, isShellBusy: model.shellBusySessionIDs.contains(task.id)), .running)
        activity.update(isWorking: model.hasRunningWork)
        XCTAssertTrue(activity.isHolding)

        model.stopShellCommand(in: task)
        try await waitUntil { model.shellCommandRun(entryID: sleeping)?.state == .stopped }
        XCTAssertTrue(model.shellBusySessionIDs.isEmpty)
        XCTAssertFalse(model.hasRunningWork)
        XCTAssertTrue(model.activeLocalSessions.isEmpty)
        activity.update(isWorking: model.hasRunningWork)
        XCTAssertFalse(activity.isHolding)
        XCTAssertNil(SidebarTaskIndicatorProjection.status(
            of: idleRecord, isShellBusy: model.shellBusySessionIDs.contains(task.id)))
        XCTAssertTrue(shell.isAlive, "Stopping a command keeps the task's shell")

        // Archiving the task ends its shell.
        await model.archive(task)
        XCTAssertNil(model.taskShells.shell(for: task.id))
        XCTAssertFalse(shell.isAlive)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
    }

    func testOutputNotYetSentSurvivesQuittingAndGoesInOrderOnceTheTaskIsOpenedAgain() async throws {
        let fixture = try await makeFixture(idle: false)
        let model = fixture.model, task = fixture.task, defaults = fixture.defaults
        let repository = fixture.queueRepository
        for command in ["printf 'one\\n'", "printf 'two\\n'"] {
            model.runShellCommand(command, in: task)
            let entryID = try XCTUnwrap(model.transcriptBySessionID[task.id]?.last?.id)
            try await waitUntil(timeout: .seconds(15)) { model.shellCommandRun(entryID: entryID)?.state == .finished }
        }
        let messages = [ClaudeBashMessage.text(command: "printf 'one\\n'", stdout: "one"),
                        ClaudeBashMessage.text(command: "printf 'two\\n'", stdout: "two")]
        XCTAssertEqual(repository.loadShellDeliveries(for: task.id).map(\.text), messages,
                       "Saved with the task's queue while Claude's turn runs")
        let saved = try XCTUnwrap(model.store.sessions.first)
        await model.shutdown()
        XCTAssertEqual(repository.loadShellDeliveries(for: task.id).map(\.text), messages, "Quitting keeps them")

        let transports = TransportLog()
        let restored = makeModel(store: SessionStore(repository: InMemorySessionRepository(sessions: [saved])),
                                 defaults: defaults, queueRepository: repository, transports: transports,
                                 restoresIndex: true)
        addTeardownBlock { await restored.shutdown() }
        await restored.restoreIndex()
        let session = try XCTUnwrap(restored.store.sessions.first)
        XCTAssertEqual(lines(restored, session).suffix(2), messages.map { "user: \($0)" },
                       "The conversation still shows both commands with their output")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(transports.all.isEmpty, "Launching starts nothing; the task attaches when it is opened")

        await restored.resume(session)
        let transport = try XCTUnwrap(transports.all.first)
        try await waitUntil { await transport.sentValues.count == 1 }
        let first = try await lastSent(transport)
        XCTAssertEqual(first["message"]?["content"]?.stringValue, messages[0])
        XCTAssertEqual(repository.loadShellDeliveries(for: task.id).map(\.text), [messages[1]])
        try await waitUntil { restored.store.sessions.first?.status == .running }
        await transport.emit(try json(result))
        try await waitUntil { await transport.sentValues.count == 2 }
        let second = try await lastSent(transport)
        XCTAssertEqual(second["message"]?["content"]?.stringValue, messages[1])
        XCTAssertTrue(repository.loadShellDeliveries(for: task.id).isEmpty)
        XCTAssertEqual(lines(restored, session).filter { $0.hasPrefix("user: <bash-input>") }.count, 2,
                       "Sent from the rows already there, not added again")
        XCTAssertEqual(restored.store.sessions.first?.providerSessionID, task.providerSessionID,
                       "Same Claude session and storage")
    }

    func testABashRowIsNotAnEditableRequestAndReadsAsItsCommandElsewhere() {
        let bash = ClaudeBashMessage.text(command: "make", stdout: "error 2")
        let entries = [TranscriptEntry(content: .user(text: bash)),
                       TranscriptEntry(content: .error(message: "Failed", recoverable: true))]
        XCTAssertNil(TranscriptRecoveryProjection.editableRequest(for: entries[1].id, entries: entries, status: .failed))
        let source = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Source")
        let context = SideChatContext(source: source, entries: entries)
        XCTAssertEqual(context.messages.first?.text, "! make\nerror 2")
    }

    // MARK: - Saved history

    func testSavedBashCommandsFromTheAppAndTheCLIReadAsCommandsWithTheirOutput() throws {
        let root = try temporaryFolder()
        let sessionID = "11111111-2222-4333-8444-555555555555"
        let project = root.appending(path: "projects/-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let desktop = ClaudeBashMessage.text(command: "git status", stdout: "On branch main\nnothing to commit")
        var records: [[String: Any]] = []
        func add(_ type: String, _ content: Any, meta: Bool = false) {
            var record: [String: Any] = ["type": type, "uuid": UUID().uuidString.lowercased(), "sessionId": sessionID,
                                         "parentUuid": records.last?["uuid"] ?? NSNull(),
                                         "timestamp": "2026-10-08T01:00:0\(records.count % 10).000Z",
                                         "message": ["role": type, "content": content]]
            if meta { record["isMeta"] = true }
            records.append(record)
        }
        add("user", "Check the repo")
        add("assistant", [["type": "text", "text": "Looking."]])
        // The Claude app: one message, which Claude answered.
        add("user", desktop)
        add("assistant", [["type": "text", "text": "Clean tree."]])
        // The CLI with respondToBashCommands off: a caveat, the command, then its output.
        add("user", "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>", meta: true)
        add("user", "<bash-input>echo '<x>' && false</bash-input>")
        add("user", "<bash-stdout><x></bash-stdout><bash-stderr>exit 1</bash-stderr>")
        add("user", "Thanks")
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appending(path: "\(sessionID).jsonl"))

        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let entries = try XCTUnwrap(try reader.readConversation(sessionID: sessionID)).entries
        let users = entries.compactMap { entry -> String? in
            if case let .user(text, _) = entry.content { return text }
            return nil
        }
        XCTAssertEqual(users.count, 4, "The CLI's two records are one command: \(users)")
        XCTAssertEqual(users[0], "Check the repo")
        XCTAssertEqual(ClaudeBashMessage.parse(users[1]), ClaudeBashMessage(
            command: "git status", output: "On branch main\nnothing to commit", hasOutput: true))
        XCTAssertEqual(ClaudeBashMessage.parse(users[2]), ClaudeBashMessage(
            command: "echo '<x>' && false", output: "<x>\nexit 1", hasOutput: true),
            "Unescaped CLI output reads as printed")
        XCTAssertEqual(users[3], "Thanks")
        XCTAssertFalse(users.contains { $0.contains("local-command-caveat") })

        // The output half is not a separate checkpoint; the command reads as `! command`.
        let points = try reader.conversationPoints(sessionID: sessionID)
        XCTAssertEqual(points.map { ClaudeBashMessage.summary(of: $0.text) ?? $0.text },
                       ["Check the repo", "! git status", "! echo '<x>' && false", "Thanks"])
    }

    // MARK: - Fixture

    /// macOS's zsh as a login shell, with startup files from an empty folder instead of the
    /// user's, so the tests do not depend on what the user's rc files print or take.
    private func plainShell() throws -> ShellLaunchEnvironment {
        ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"], overrides: ["ZDOTDIR": try temporaryFolder().path])
    }

    /// One command in a new shell, which is closed afterwards.
    private func run(_ command: String, in folder: URL, launch: ShellLaunchEnvironment? = nil) async throws -> ShellCommandResult {
        let shell = TaskShellProcess(workingDirectory: folder, launch: try launch ?? plainShell())
        defer { shell.close() }
        return try await run(command, in: shell)
    }

    private func run(_ command: String, in shell: TaskShellProcess) async throws -> ShellCommandResult {
        try await finish(shell.command(command, note: nil))
    }

    private func run(_ command: String, in shells: TaskShells, task: UUID, folder: URL) async throws -> ShellCommandResult {
        try await finish(shells.command(command, for: task, in: folder))
    }

    private func finish(_ process: any ShellCommandRunning) async throws -> ShellCommandResult {
        var finished: ShellCommandResult?
        process.onFinish = { finished = $0 }
        process.start()
        try await waitUntil(timeout: .seconds(20)) { finished != nil }
        return try XCTUnwrap(finished)
    }

    private func physicalPath(_ url: URL) throws -> String {
        try XCTUnwrap(realpath(url.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-bash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let transport: FakeClaudeTransport
        let defaults: UserDefaults
        let queueRepository: UserDefaultsCodexQueueRepository
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        func make() -> FakeClaudeTransport {
            let transport = FakeClaudeTransport()
            lock.withLock { transports.append(transport) }
            return transport
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
    }

    /// A Claude task on the product route after its first request; idle when that turn ended.
    private func makeFixture(idle: Bool, followUps mode: CodexFollowUpMode? = nil) async throws -> Fixture {
        let root = try temporaryFolder()
        let cli = root.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ClaudeBashMode")))
        if let mode { defaults.set(mode.rawValue, forKey: CodexFollowUpMode.preferenceKey) }
        let transports = TransportLog()
        let queueRepository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let model = makeModel(store: SessionStore(repository: InMemorySessionRepository()), defaults: defaults,
                              queueRepository: queueRepository, transports: transports, restoresIndex: false)
        model.shellCommandLaunch = try plainShell()
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                runtimeExecutableURL: cli, title: "Bash mode")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(transports.all.first)
        await model.send(HarnessUserInput(text: "Run the tests"), to: task)
        try await waitUntil {
            model.eventsBySessionID[task.id]?.contains { $0.payload == .sessionStatusChanged(.running) } == true
                && model.store.sessions.first?.status == .running
        }
        if idle {
            await transport.emit(try json(result))
            try await waitUntil { model.store.sessions.first?.status == .ready }
        }
        return Fixture(model: model, task: try XCTUnwrap(model.store.sessions.first), transport: transport,
                       defaults: defaults, queueRepository: queueRepository)
    }

    /// The product route to a fake Claude Code, with the queue and conversation saved in `defaults`.
    private func makeModel(store: SessionStore, defaults: UserDefaults, queueRepository: UserDefaultsCodexQueueRepository,
                           transports: TransportLog, restoresIndex: Bool) -> AppModel {
        AppModel(
            store: store,
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: queueRepository,
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "transcript."),
            restoresIndexOnLaunch: restoresIndex
        )
    }

    private func lines(_ model: AppModel, _ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            switch entry.content {
            case let .user(text, _): "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            default: nil
            }
        }
    }

    private func lastSent(_ transport: FakeClaudeTransport) async throws -> JSONValue {
        let values = await transport.sentValues
        return try XCTUnwrap(values.last)
    }

    private var result: String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
