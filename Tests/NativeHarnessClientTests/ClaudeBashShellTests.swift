import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

/// A Claude task's bash-mode shell, as the Claude app keeps one per session: one login shell per
/// task in a pseudo-terminal that runs the task's commands one after another. The shells are the
/// Mac's own (zsh, bash, dash, ksh, tcsh) in temporary folders, with startup files from temporary
/// folders where a test needs them to print or misbehave; commands are `cd`, `pwd`, `printf`,
/// `export` and `sleep`.
@MainActor final class ClaudeBashShellTests: XCTestCase {
    // MARK: - Marks

    func testMarksAreFoundAcrossReadsAndOtherOutputPassesThrough() {
        var marks = ShellOutputMarks(nonce: "n0nce")
        let start = Array("\u{1B}]6973;S;n0nce\u{07}".utf8)
        let end = Array("\u{1B}]6973;E;n0nce;3\u{07}".utf8)
        let foreign = Array("\u{1B}]6973;E;other;0\u{07}".utf8)
        let title = Array("\u{1B}]0;title\u{07}".utf8)
        let stream = Array("before".utf8) + start + Array("out".utf8) + title + foreign + Array("put".utf8) + end + Array("after".utf8)
        var events: [ShellOutputMarks.Event] = []
        // One byte at a time: every mark is split across reads.
        for byte in stream { events += marks.feed([byte][...]) }
        var output: [UInt8] = []
        var marksSeen: [String] = []
        for event in events {
            switch event {
            case let .output(bytes): output += bytes
            case let .mark(kind, status): marksSeen.append("\(kind)\(status.map(String.init) ?? "")"); output += Array("|".utf8)
            }
        }
        XCTAssertEqual(marksSeen, ["S", "E3"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self),
                       "before|out\u{1B}]0;title\u{07}\u{1B}]6973;E;other;0\u{07}put|after",
                       "Another nonce, and any other escape, is output")
    }

    // MARK: - State carries over

    func testTheUsersLoginShellKeepsItsDirectoryVariablesAndFunctionsBetweenCommands() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        let shell = TaskShellProcess(workingDirectory: folder, launch: .userLoginShell())
        addTeardownBlock { @MainActor in shell.close() }
        let sub = try physicalPath(folder.appending(path: "sub"))

        try await expect("cd sub && pwd -P", in: shell, output: sub)
        try await expect("pwd -P", in: shell, output: sub, "The directory carried over")
        try await expect("export YARDLET_BASH_VALUE=1", in: shell, output: "")
        try await expect("echo \"value=$YARDLET_BASH_VALUE\"", in: shell, output: "value=1")
        try await expect("yardlet_bash_fn() { echo \"fn:$1\"; }", in: shell, output: "")
        try await expect("yardlet_bash_fn ok", in: shell, output: "fn:ok")
        let failed = try await run("false", in: shell)
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertEqual(failed.output, "")
        let multiline = try await run("for word in a 'b c'; do\n  printf '<%s>\\n' \"$word\"\ndone", in: shell)
        XCTAssertEqual(multiline.output, "<a>\n<b c>", "A command over several lines, quotes and all")
    }

    func testStartupFilesPromptsAndHooksThatPrintStayOutOfTheOutputAndTheHistoryFile() async throws {
        let folder = try temporaryFolder()
        let zdotdir = try temporaryFolder()
        try "echo 'zshenv says hi'\n".write(to: zdotdir.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
        try """
        echo 'zshrc banner'
        setopt share_history inc_append_history
        precmd() { print -n '\\e]0;title\\a'; echo precmd-noise }
        preexec() { echo preexec-noise }
        PROMPT='%n@%m %~ %# '
        RPROMPT='[right]'
        cd /

        """.write(to: zdotdir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let shell = TaskShellProcess(workingDirectory: folder, launch: ShellLaunchEnvironment(
            executable: "/bin/zsh", arguments: ["-l"], overrides: ["ZDOTDIR": zdotdir.path]))
        addTeardownBlock { @MainActor in shell.close() }

        try await expect("pwd -P", in: shell, output: try physicalPath(folder),
                         "In the task's folder though the rc file changed directory")
        try await expect("echo hi", in: shell, output: "hi")
        try await expect("printf 'no newline'", in: shell, output: "no newline")
        let history = zdotdir.appending(path: ".zsh_history")
        let saved = (try? String(contentsOf: history, encoding: .utf8)) ?? ""
        XCTAssertFalse(saved.contains("echo hi") || saved.contains("HISTFILE") || saved.contains("6973"),
                       "Nothing Yardlet typed reaches the history file: \(saved)")
    }

    func testBashKeepsItsStateAndItsProfileAndPromptCommandStayOut() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        let home = try temporaryFolder()
        try """
        echo 'profile banner'
        PROMPT_COMMAND='echo prompt-noise'
        HISTFILE="$HOME/.bash_history"
        cd /

        """.write(to: home.appending(path: ".bash_profile"), atomically: true, encoding: .utf8)
        let shell = TaskShellProcess(workingDirectory: folder, launch: ShellLaunchEnvironment(
            executable: "/bin/bash", arguments: ["-l"], overrides: ["HOME": home.path]))
        shell.outputInterval = .milliseconds(20)
        addTeardownBlock { @MainActor in shell.close() }
        let sub = try physicalPath(folder.appending(path: "sub"))

        try await expect("cd sub && pwd -P", in: shell, output: sub)
        try await expect("pwd -P", in: shell, output: sub)
        try await expect("export YARDLET_BASH_VALUE=2; f() { echo \"f$YARDLET_BASH_VALUE\"; }", in: shell, output: "")
        try await expect("f", in: shell, output: "f2")
        try await expectStop("printf 'started\\n'; sleep 30", in: shell)
        try await expect("pwd -P", in: shell, output: sub, "The same shell after the stop")
        shell.close()
        let saved = (try? String(contentsOf: home.appending(path: ".bash_history"), encoding: .utf8)) ?? ""
        XCTAssertFalse(saved.contains("pwd"), "Nothing Yardlet typed reaches the history file: \(saved)")
    }

    func testOtherPOSIXShellsMarkTheirPromptSoAStoppedLineEnds() async throws {
        for executable in ["/bin/dash", "/bin/ksh"] {
            let folder = try temporaryFolder()
            try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
            let shell = TaskShellProcess(workingDirectory: folder, launch: ShellLaunchEnvironment(
                executable: executable, arguments: ["-l"], overrides: ["HOME": try temporaryFolder().path]))
            shell.outputInterval = .milliseconds(20)
            let sub = try physicalPath(folder.appending(path: "sub"))
            try await expect("cd sub", in: shell, output: "", executable)
            try await expect("pwd -P", in: shell, output: sub, executable)
            let stopped = try await expectStop("printf 'started\\n'; sleep 30; printf 'never\\n'", in: shell)
            XCTAssertFalse(stopped.output.contains("never"), executable)
            try await expect("pwd -P", in: shell, output: sub, executable)
            shell.close()
        }
    }

    func testAnUnmarkedShellRunsTypedCommandsUntilTheyAreDoneAndQuiet() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        let shell = TaskShellProcess(workingDirectory: folder, launch: ShellLaunchEnvironment(
            executable: "/bin/tcsh", arguments: ["-l"], overrides: ["HOME": try temporaryFolder().path]))
        shell.outputInterval = .milliseconds(20)
        addTeardownBlock { @MainActor in shell.close() }
        XCTAssertEqual(shell.dialect, .unmarked)
        let sub = try physicalPath(folder.appending(path: "sub"))

        try await expect("cd sub && /bin/pwd -P", in: shell, output: sub, "No typed line and no prompt")
        try await expect("/bin/pwd -P", in: shell, output: sub)
        let late = try await run("sleep 1; echo late", in: shell)
        XCTAssertEqual(late.output, "late", "A quiet program still holding the terminal is still running")
        XCTAssertNil(late.exitCode, "An unmarked shell does not say")
        // The main thread held from the middle of the program to past its output, as on a loaded Mac: the
        // watch did not see that time, so it is not quiet, and the output that came in it is read.
        let held = shell.command("sleep 1; echo late", note: nil)
        var heldResult: ShellCommandResult?
        held.onFinish = { heldResult = $0 }
        held.start()
        try await Task.sleep(for: .milliseconds(500))
        holdTheMainThread(for: 1.5)
        try await waitUntil { heldResult != nil }
        XCTAssertEqual(heldResult?.output, "late", "The command ended before reading what came while the main thread was held")
        try await expectStop("echo started; sleep 30", in: shell)
        try await expect("/bin/pwd -P", in: shell, output: sub)
    }

    // MARK: - Starting

    func testAShellStillStartingCanBeStoppedAndOneThatNeverGetsReadyIsEnded() async throws {
        let folder = try temporaryFolder()
        let zdotdir = try temporaryFolder()
        try "sleep 1\n".write(to: zdotdir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let launch = ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"], overrides: ["ZDOTDIR": zdotdir.path])
        let shell = TaskShellProcess(workingDirectory: folder, launch: launch)
        addTeardownBlock { @MainActor in shell.close() }
        let early = shell.command("printf 'never typed\\n'", note: nil)
        var stopped: ShellCommandResult?
        early.onFinish = { stopped = $0 }
        early.start()
        early.stop()
        XCTAssertEqual(stopped?.wasStopped, true, "Stopped before the shell was ready: nothing ran")
        XCTAssertEqual(stopped?.output, "")
        try await expect("printf 'ready now\\n'", in: shell, output: "ready now")

        try "sleep 30\n".write(to: zdotdir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let slow = TaskShellProcess(workingDirectory: folder, launch: launch)
        slow.readyTimeout = .seconds(1)
        let result = try await run("printf hi", in: slow)
        XCTAssertEqual(result.launchError, L10n.format("The shell did not become ready within %lld seconds", Int64(1)))
        XCTAssertFalse(slow.isAlive)
    }

    // MARK: - The task's folder

    func testATaskWhoseFolderChangedGetsANewShellThereUnlessItsShellStillRunsProcesses() async throws {
        let first = try temporaryFolder(), second = try temporaryFolder(), third = try temporaryFolder()
        let zdotdir = try temporaryFolder()
        let shells = TaskShells(launch: ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"],
                                                           overrides: ["ZDOTDIR": zdotdir.path])) {
            TaskShellProcess(workingDirectory: $0, launch: $1)
        }
        addTeardownBlock { @MainActor in shells.closeAll() }
        let task = UUID()
        _ = try await run("export YARDLET_MOVED=1", in: shells, task: task, folder: first)
        let original = try XCTUnwrap(shells.shell(for: task) as? TaskShellProcess)

        let moved = try await run("printf '%s:%s\\n' \"$(pwd -P)\" \"${YARDLET_MOVED:-}\"", in: shells, task: task, folder: second)
        XCTAssertEqual(moved.output, "(new shell in \(path(second)) \u{2014} the session moved out of \(path(first)), "
            + "so the environment was reset)\n\(try physicalPath(second)):", "The Claude app's note, then the output")
        XCTAssertFalse(original.isAlive, "The old shell was closed")

        // A shell running a process of its own stays where it is, and says so once.
        _ = try await run("sleep 30 &", in: shells, task: task, folder: second)
        let busy = try XCTUnwrap(shells.shell(for: task) as? TaskShellProcess)
        try await waitUntil { busy.hasOwnProcesses }
        let background = NativeProcessTree.descendantProcessIDs(of: busy.processID)
        let kept = try await run("pwd -P", in: shells, task: task, folder: third)
        XCTAssertEqual(kept.output, "(the session moved to \(path(third)); this shell is still in \(path(second)) "
            + "because it has processes running \u{2014} cd when they are done)\n\(try physicalPath(second))")
        let again = try await run("pwd -P", in: shells, task: task, folder: third)
        XCTAssertEqual(again.output, try physicalPath(second))
        XCTAssertTrue(busy.isAlive)

        shells.closeAll()
        XCTAssertFalse(busy.isAlive)
        try await waitUntil { background.allSatisfy { Darwin.kill($0, 0) != 0 } }
    }

    func testAtMostSixteenShellsStayOpenAndTheOneUsedLongestAgoWithNothingRunningCloses() {
        var made: [FakeShell] = []
        let shells = TaskShells(launch: ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"])) { folder, _ in
            let shell = FakeShell(workingDirectory: folder)
            made.append(shell)
            return shell
        }
        let folder = URL(filePath: "/tmp")
        let tasks = (0..<(TaskShells.limit + 2)).map { _ in UUID() }
        _ = shells.command("true", for: tasks[0], in: folder)
        made[0].isRunningCommand = true
        for task in tasks[1..<TaskShells.limit] { _ = shells.command("true", for: task, in: folder) }
        _ = shells.command("true", for: tasks[1], in: folder)
        XCTAssertTrue(made.allSatisfy(\.isAlive), "Sixteen stay open")

        _ = shells.command("true", for: tasks[TaskShells.limit], in: folder)
        XCTAssertTrue(made[0].isAlive, "Running a command: kept")
        XCTAssertTrue(made[1].isAlive, "Used again since")
        XCTAssertFalse(made[2].isAlive, "Used longest ago with nothing running")
        XCTAssertNil(shells.shell(for: tasks[2]))

        made[0].isRunningCommand = false
        _ = shells.command("true", for: tasks[TaskShells.limit + 1], in: folder)
        XCTAssertFalse(made[0].isAlive)
        XCTAssertEqual(made.filter(\.isAlive).count, TaskShells.limit)
    }

    private final class FakeShell: TaskShell {
        let workingDirectory: URL
        var isAlive = true
        var wasReset = false
        var hasOwnProcesses = false
        var isRunningCommand = false

        init(workingDirectory: URL) {
            self.workingDirectory = workingDirectory
        }

        func command(_ command: String, note: String?) -> any ShellCommandRunning {
            FakeCommand()
        }

        func close() {
            isAlive = false
        }
    }

    private final class FakeCommand: ShellCommandRunning {
        var onOutput: ((String) -> Void)?
        var onFinish: ((ShellCommandResult) -> Void)?
        func start() {}
        func stop() {}
        func terminate() {}
    }

    // MARK: - Helpers

    private func expect(
        _ command: String, in shell: TaskShellProcess, output: String, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let result = try await run(command, in: shell)
        XCTAssertNil(result.launchError, message, file: file, line: line)
        XCTAssertEqual(result.output, output, "\(command) \(message)", file: file, line: line)
        XCTAssertFalse(result.wasStopped, file: file, line: line)
    }

    /// Runs a command that prints `started` and keeps running, then stops it.
    @discardableResult
    private func expectStop(
        _ command: String, in shell: TaskShellProcess, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ShellCommandResult {
        let process = shell.command(command, note: nil)
        var started = false
        var finished: ShellCommandResult?
        process.onOutput = { started = started || $0.contains("started") }
        process.onFinish = { finished = $0 }
        process.start()
        try await waitUntil(timeout: .seconds(15)) { started }
        process.stop()
        try await waitUntil { finished != nil }
        let result = try XCTUnwrap(finished, file: file, line: line)
        XCTAssertTrue(result.wasStopped, file: file, line: line)
        XCTAssertTrue(result.output.hasPrefix("started"), result.output, file: file, line: line)
        XCTAssertTrue(shell.isAlive, "Stopping a command keeps the shell", file: file, line: line)
        return result
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

    /// Keeps the main thread busy, as a loaded Mac can.
    private func holdTheMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func path(_ url: URL) -> String {
        TaskShellProcess.path(url)
    }

    private func physicalPath(_ url: URL) throws -> String {
        try XCTUnwrap(realpath(url.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-shell-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
