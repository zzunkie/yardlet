import Darwin
import Foundation
@preconcurrency import SwiftTerm

/// How a shell is asked to mark where a command's output starts and ends.
enum ShellDialect: Equatable {
    /// zsh, bash and the other POSIX shells: the typed line prints a mark, sources the command
    /// from a file, and prints a mark with its exit status. Each prompt is marked too (zsh's
    /// `precmd`, bash's `PROMPT_COMMAND`, the others' `PS1`), which is how a line that Control-C
    /// cut short ends.
    case zsh
    case bash
    case posix
    /// Any other shell (fish, csh, …): the command is typed as it is, as the Claude app types it,
    /// and has ended when the shell holds the terminal again and its output has gone quiet.
    case unmarked

    init(shellPath: String) {
        switch URL(filePath: shellPath).lastPathComponent {
        case "zsh": self = .zsh
        case "bash": self = .bash
        case "sh", "dash", "ash", "ksh", "ksh93", "mksh", "oksh", "pdksh", "yash": self = .posix
        default: self = .unmarked
        }
    }

    /// What runs a builtin past the user's functions and aliases.
    var builtin: String {
        switch self {
        case .zsh, .bash: "builtin "
        case .posix: "command "
        case .unmarked: ""
        }
    }
}

/// Yardlet's marks in a shell's output, `ESC ] 6973 ; kind ; nonce [; status] BEL`: an operating
/// system command no terminal acts on. The random nonce keeps output from passing for one.
struct ShellOutputMarks {
    enum Event: Equatable {
        case output([UInt8])
        case mark(Character, status: Int32?)
    }

    static let introducer: [UInt8] = Array("\u{1B}]6973;".utf8)
    /// A mark's body is short; anything longer is not one.
    private static let longestBody = 64
    let nonce: String
    private var pending: [UInt8] = []

    init(nonce: String) {
        self.nonce = nonce
    }

    /// The output and marks in arriving bytes, in order. A mark split across reads waits for
    /// its end.
    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [Event] {
        pending.append(contentsOf: bytes)
        let introducer = Self.introducer
        var events: [Event] = []
        var plainStart = 0
        var index = 0
        scan: while index < pending.count {
            guard pending[index] == 0x1B else { index += 1; continue }
            let available = min(pending.count - index, introducer.count)
            guard pending[index..<(index + available)].elementsEqual(introducer.prefix(available)) else {
                index += 1
                continue
            }
            guard available == introducer.count else { break scan }
            let bodyStart = index + introducer.count
            let searchEnd = min(pending.count, bodyStart + Self.longestBody)
            guard let bell = pending[bodyStart..<searchEnd].firstIndex(of: 0x07) else {
                if searchEnd < bodyStart + Self.longestBody { break scan }
                index += 1
                continue
            }
            let fields = String(decoding: pending[bodyStart..<bell], as: UTF8.self).split(separator: ";")
            guard fields.count >= 2, fields[0].count == 1, fields[1] == nonce, let kind = fields[0].first else {
                index += 1
                continue
            }
            if plainStart < index { events.append(.output(Array(pending[plainStart..<index]))) }
            events.append(.mark(kind, status: fields.count > 2 ? Int32(fields[2]) : nil))
            index = bell + 1
            plainStart = index
        }
        if plainStart < index { events.append(.output(Array(pending[plainStart..<index]))) }
        pending.removeFirst(index)
        return events
    }
}

/// A task's bash-mode shell: one hidden login shell in a pseudo-terminal, through SwiftTerm's
/// process as the terminal panel's shell runs, without a view. It starts with the task's first
/// command, runs its rc files once, and then runs each command in itself, so the directory,
/// exported and shell variables, functions and aliases carry over, as in the Claude app's bash
/// mode. Commands it runs stay out of the user's history file.
///
/// A command's output is the emulated screen text of what it printed, so carriage-return progress
/// lines and colours read as a terminal shows them; the shell's prompt, the typed line and the
/// rc files' output are not part of it. Stopping sends Control-C, as the Claude app's
/// `interruptBashCommand` does; a program that ignores it has its process group ended, and a
/// shell that does not answer after that is ended, so the next command starts a new one.
@MainActor
final class TaskShellProcess: @MainActor TerminalDelegate, @MainActor LocalProcessDelegate,
    NativeSurfaceResource, TaskShell {
    /// The Claude app's bash-mode pseudo-terminal is 80 by 24.
    static let columns = 80
    static let rows = 24
    /// Enough lines for the kept output at that width; older lines leave the scrollback.
    static let scrollbackLines = 4_000

    let workingDirectory: URL
    let launch: ShellLaunchEnvironment
    let dialect: ShellDialect
    /// Live screen text while a command runs, at most every `outputInterval`.
    var outputInterval: Duration = .milliseconds(100)
    /// How long each step of stopping waits: Control-C, then the foreground process group, then
    /// the shell.
    var stopGracePeriod: Duration = .milliseconds(1_500)
    /// How long the shell has to start, rc files included; the Claude app waits 30 seconds.
    var readyTimeout: Duration = .seconds(30)
    /// An unmarked shell's command has ended once its output has been quiet this long, as the
    /// Claude app reads one.
    var quietPeriod: Duration = .milliseconds(400)

    private(set) var wasReset = false
    private var process: LocalProcess?
    private var marks: ShellOutputMarks
    private let nonce: String
    private var hasStarted = false
    private var isReady = false
    private var hasExited = false
    private var isClosed = false
    private var exitStatus: Int32?
    private var current: TaskShellCommand?
    private var commandFolder: URL?
    private var readyTask: Task<Void, Never>?

    init(workingDirectory: URL, launch: ShellLaunchEnvironment) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.launch = launch
        self.dialect = ShellDialect(shellPath: launch.executable)
        let nonce = (0..<2).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        self.nonce = nonce
        self.marks = ShellOutputMarks(nonce: nonce)
    }

    var isAlive: Bool { !hasExited && !isClosed }
    var processID: pid_t { process?.shellPid ?? 0 }
    var isRunningCommand: Bool { current != nil }

    var hasOwnProcesses: Bool {
        guard isAlive, processID > 0 else { return false }
        return !NativeProcessTree.descendantProcessIDs(of: processID).isEmpty
    }

    func command(_ command: String, note: String?) -> any ShellCommandRunning {
        TaskShellCommand(text: command, note: note, shell: self)
    }

    // MARK: Running a command

    fileprivate func begin(_ command: TaskShellCommand) {
        guard current == nil else {
            command.report(ShellCommandResult(output: "", launchError: L10n.string("A shell command is already running")))
            return
        }
        let folder = Self.path(workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            command.report(ShellCommandResult(output: "", launchError: L10n.format("Working directory “%@” does not exist", folder)))
            // A shell left in a folder that went away is not reused.
            close()
            return
        }
        guard isAlive else {
            command.report(ShellCommandResult(output: "", launchError: L10n.string("The shell exited before it was ready")))
            return
        }
        current = command
        if !hasStarted {
            startShell()
        } else if isReady {
            type(command)
        }
    }

    private func startShell() {
        hasStarted = true
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-shell-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            commandFolder = folder
        } catch {
            failStart(error.localizedDescription)
            return
        }
        let process = LocalProcess(delegate: self, dispatchQueue: .main)
        self.process = process
        NativeSurfaceResourceRegistry.shared.register(self)
        // zsh can write a line to the history file as it is read, before the line that turns the
        // history file off has run; this keeps that line out. The line removes it again.
        let start = launch.start(in: workingDirectory,
                                 adding: dialect == .zsh ? ["HISTORY_IGNORE": "( *)"] : [:])
        process.startProcess(
            executable: start.executable,
            args: start.arguments,
            environment: start.environment,
            execName: start.processName,
            currentDirectory: start.currentDirectory
        )
        guard process.running || hasExited else {
            self.process = nil
            failStart(L10n.format("Could not start %@", launch.executable))
            return
        }
        // Typed ahead: the shell reads it once its rc files have run, at its first prompt.
        send(setupLine)
        let timeout = readyTimeout
        readyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, !self.isReady, self.isAlive else { return }
            self.failStart(L10n.format("The shell did not become ready within %lld seconds",
                                       Int64(timeout.components.seconds)))
        }
    }

    /// The command could not run because the shell did not start; the shell is ended.
    private func failStart(_ message: String) {
        let command = current
        current = nil
        endShell()
        command?.report(ShellCommandResult(output: "", launchError: message))
    }

    /// Run once, after the rc files: no history file, the task's folder (an rc file may have
    /// changed directory), the prompt mark, and the mark that says the shell is ready.
    private var setupLine: String {
        let builtin = dialect.builtin
        var parts = [" unset HISTFILE" + (dialect == .zsh ? " HISTORY_IGNORE" : ""),
                     "\(builtin)cd -- \(Self.quoted(Self.path(workingDirectory)))"]
        switch dialect {
        case .zsh:
            parts.append("__yardlet_prompt() { \(mark("P", status: true)); }")
            parts.append("precmd_functions[1,0]=(__yardlet_prompt)")
        case .bash:
            parts.append("__yardlet_prompt() { local s=$?; \(mark("P", status: true)); return $s; }")
            parts.append("PROMPT_COMMAND=\"__yardlet_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"")
        case .posix:
            parts.append("PS1=\"$(\(mark("P")))$PS1\"")
        case .unmarked:
            return " " + mark("R") + "\r"
        }
        parts.append(mark("R"))
        return parts.joined(separator: "; ") + "\r"
    }

    /// A line that prints one of the marks; with `status`, the last command's exit status.
    private func mark(_ kind: Character, status: Bool = false) -> String {
        status
            ? "\(dialect.builtin)printf '\\033]6973;\(kind);%s;%d\\007' \(nonce) \"$?\""
            : "\(dialect.builtin)printf '\\033]6973;\(kind);%s\\007' \(nonce)"
    }

    private func type(_ command: TaskShellCommand) {
        command.terminal = Terminal(delegate: self, options: TerminalOptions(
            cols: Self.columns, rows: Self.rows, scrollback: Self.scrollbackLines
        ))
        switch dialect {
        case .zsh, .bash, .posix:
            // Sourced from a file, the command may span lines and quote anything, and the typed
            // line stays short whatever its length.
            do {
                guard let file = commandFolder?.appending(path: "command") else { throw CocoaError(.fileNoSuchFile) }
                try Data(command.text.utf8).write(to: file, options: .atomic)
                command.phase = .typed
                send(" " + mark("S") + "; . \(Self.quoted(Self.path(file))); " + mark("E", status: true) + "\r")
            } catch {
                current = nil
                command.report(ShellCommandResult(output: "", launchError: error.localizedDescription))
            }
        case .unmarked:
            command.phase = .capturing
            command.typedAt = .now
            command.lastDataAt = .now
            send(" " + command.text + "\r")
            watchForQuiet(command)
        }
    }

    fileprivate func stop(_ command: TaskShellCommand) {
        guard current === command, !command.stopRequested else { return }
        command.stopRequested = true
        guard command.phase != .waiting else {
            // Still waiting for the shell to start: nothing ran.
            finish(command, exitCode: nil)
            return
        }
        send("\u{3}")
        command.stopTask = Task { @MainActor [weak self] in await self?.escalateStop(of: command) }
    }

    /// Control-C did not end it: end the process group that holds the terminal, then ask the
    /// shell for a mark, then end the shell.
    private func escalateStop(of command: TaskShellCommand) async {
        let grace = stopGracePeriod
        try? await Task.sleep(for: grace)
        guard current === command, !Task.isCancelled else { return }
        if let group = foregroundProcessGroup, group != processID {
            command.signal = SIGKILL
            _ = killpg(group, SIGKILL)
            try? await Task.sleep(for: grace)
            guard current === command, !Task.isCancelled else { return }
        }
        if dialect != .unmarked, foregroundProcessGroup == processID {
            // The shell holds the terminal but printed no mark: if it is at its prompt, it
            // answers this one. Its echo is not part of the output.
            command.isFrozen = true
            command.isSyncing = true
            send(" " + mark("Y") + "\r")
            try? await Task.sleep(for: grace)
            guard current === command, !Task.isCancelled else { return }
        }
        wasReset = true
        command.signal = SIGKILL
        endShell()
        finish(command, exitCode: nil)
    }

    /// An unmarked shell's command has ended when nothing but the shell has held the terminal and
    /// the output has been quiet. A program that held it counts as activity, as output does: in
    /// `sleep 1; echo late` the shell holds the terminal again before it prints the rest.
    private func watchForQuiet(_ command: TaskShellCommand) {
        let quiet = quietPeriod
        command.quietTask = Task { @MainActor [weak self] in
            var heldAt = command.typedAt
            while !Task.isCancelled {
                try? await Task.sleep(for: quiet / 4)
                guard let self, self.current === command, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                if self.foregroundProcessGroup != self.processID { heldAt = now }
                if now - command.lastDataAt >= quiet, now - heldAt >= quiet {
                    self.finish(command, exitCode: nil)
                    return
                }
            }
        }
    }

    private var foregroundProcessGroup: pid_t? {
        guard let fd = process?.childfd, fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    private func finish(_ command: TaskShellCommand, exitCode: Int32?) {
        guard current === command else { return }
        current = nil
        var text = command.screenText(markingTruncation: true, cuttingPrompt: dialect == .unmarked)
        if dialect == .unmarked { text = Self.droppingEcho(of: command.text, from: text) }
        var result = ShellCommandResult(output: command.withNote(ClaudeBashMessage.capped(text)), exitCode: exitCode)
        result.signal = command.signal
        result.wasStopped = command.stopRequested
        command.report(result)
    }

    // MARK: Ending

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let command = current
        current = nil
        command?.discard()
        endShell()
    }

    func stop() {
        close()
    }

    func terminateForApplicationShutdown() {
        close()
    }

    /// Ends the shell's process tree at once.
    private func endShell() {
        readyTask?.cancel()
        if !hasExited, let process, process.running, process.shellPid > 0 {
            hasExited = true
            NativeProcessTree.terminate(rootPID: process.shellPid)
        }
        hasExited = true
        process = nil
        if let commandFolder { try? FileManager.default.removeItem(at: commandFolder) }
        commandFolder = nil
    }

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process, !hasExited else { return }
        hasExited = true
        exitStatus = exitCode
        readyTask?.cancel()
        guard let command = current else {
            endShell()
            return
        }
        // The exit can arrive before the last of the output has been read. Wait until it has
        // been quiet briefly, bounded, so the end of the output is not lost.
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < deadline, ContinuousClock.now - command.lastDataAt < .milliseconds(80) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self else { return }
            defer { self.endShell() }
            guard self.current === command else { return }
            if !self.isReady {
                self.failStart(L10n.string("The shell exited before it was ready"))
                return
            }
            let (code, signal) = Self.decoded(self.exitStatus)
            if command.signal == nil { command.signal = signal }
            self.finish(command, exitCode: code)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard !isClosed else { return }
        if current?.terminal == nil { answerDeviceAttributes(in: slice) }
        for event in marks.feed(slice) {
            switch event {
            case let .output(bytes): received(bytes)
            case let .mark(kind, status): marked(kind, status: status)
            }
        }
    }

    private func received(_ bytes: [UInt8]) {
        guard let command = current, command.phase == .capturing, !command.isFrozen else { return }
        command.terminal?.feed(byteArray: bytes)
        command.lastDataAt = .now
        guard command.outputTask == nil else { return }
        let interval = outputInterval
        command.outputTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled, self.current === command else { return }
            command.outputTask = nil
            command.onOutput?(command.withNote(command.screenText(cuttingPrompt: self.dialect == .unmarked)))
        }
    }

    private func marked(_ kind: Character, status: Int32?) {
        switch kind {
        case "R":
            guard !isReady else { return }
            isReady = true
            readyTask?.cancel()
            if let current, current.phase == .waiting { type(current) }
        case "S":
            if let current, current.phase == .typed { current.phase = .capturing }
        case "E", "P":
            // A prompt mark ends a line Control-C cut short. One from before the command started
            // comes before its start mark and is not for it.
            if let current, current.phase == .capturing { finish(current, exitCode: status) }
        case "Y":
            if let current, current.isSyncing { finish(current, exitCode: nil) }
        default:
            break
        }
    }

    /// Outside a command, a primary device-attributes query is answered as the Claude app
    /// answers it; within one, the command's terminal answers everything.
    private func answerDeviceAttributes(in slice: ArraySlice<UInt8>) {
        let text = String(decoding: slice, as: UTF8.self)
        if text.contains("\u{1B}[c") || text.contains("\u{1B}[0c") { send("\u{1B}[?62;22c") }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(Self.rows), ws_col: UInt16(Self.columns), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalDelegate

    /// The emulator's own answers, such as a cursor-position report, go back to the program.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard source === current?.terminal else { return }
        process?.send(data: data)
    }

    // MARK: Helpers

    private func send(_ text: String) {
        guard let process, process.running else { return }
        process.send(data: Array(text.utf8)[...])
    }

    private static func decoded(_ status: Int32?) -> (code: Int32?, signal: Int32?) {
        guard let status else { return (nil, nil) }
        let signal = status & 0x7f
        if signal == 0 { return ((status >> 8) & 0xff, nil) }
        return signal == 0x7f ? (nil, nil) : (nil, signal)
    }

    static func path(_ url: URL) -> String {
        ShellLaunchEnvironment.directoryPath(url)
    }

    /// Single-quoted for any POSIX shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An unmarked shell echoes the typed command first, as the Claude app's reading drops it.
    static func droppingEcho(of command: String, from text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let typed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty
                || (!typed.isEmpty && first.trimmingCharacters(in: .whitespaces).hasSuffix(typed)) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}

/// One command in a task's shell.
@MainActor
final class TaskShellCommand: ShellCommandRunning {
    enum Phase {
        /// Waiting for the shell to be ready.
        case waiting
        /// Typed; its start mark has not come yet.
        case typed
        /// Its output is arriving.
        case capturing
    }

    let text: String
    let note: String?
    var onOutput: ((String) -> Void)?
    var onFinish: ((ShellCommandResult) -> Void)?
    private weak var shell: TaskShellProcess?

    fileprivate var phase = Phase.waiting
    /// What the command printed, emulated on its own 80 by 24 terminal.
    fileprivate var terminal: Terminal?
    fileprivate var stopRequested = false
    fileprivate var signal: Int32?
    /// Output after this point is the shell's, not the command's.
    fileprivate var isFrozen = false
    fileprivate var isSyncing = false
    fileprivate var typedAt = ContinuousClock.now
    fileprivate var lastDataAt = ContinuousClock.now
    fileprivate var outputTask: Task<Void, Never>?
    fileprivate var stopTask: Task<Void, Never>?
    fileprivate var quietTask: Task<Void, Never>?
    private var finished = false

    fileprivate init(text: String, note: String?, shell: TaskShellProcess) {
        self.text = text
        self.note = note
        self.shell = shell
    }

    func start() {
        guard let shell else {
            report(ShellCommandResult(output: "", launchError: L10n.string("The shell exited before it was ready")))
            return
        }
        shell.begin(self)
    }

    func stop() {
        shell?.stop(self)
    }

    func terminate() {
        shell?.close()
    }

    fileprivate func report(_ result: ShellCommandResult) {
        guard !finished else { return }
        cancelTasks()
        terminal = nil
        finished = true
        let onFinish = self.onFinish
        self.onFinish = nil
        onOutput = nil
        onFinish?(result)
    }

    /// The task went away: nobody is told.
    fileprivate func discard() {
        cancelTasks()
        terminal = nil
        finished = true
        onFinish = nil
        onOutput = nil
    }

    private func cancelTasks() {
        outputTask?.cancel()
        stopTask?.cancel()
        quietTask?.cancel()
    }

    fileprivate func withNote(_ output: String) -> String {
        guard let note else { return output }
        return output.isEmpty ? note : note + "\n" + output
    }

    /// The terminal's text from the top of its scrollback: wrapped rows joined into their line,
    /// trailing blanks and empty lines at either end dropped. An unmarked shell's new prompt, the
    /// cursor's line, is cut.
    fileprivate func screenText(markingTruncation: Bool = false, cuttingPrompt: Bool = false) -> String {
        guard let terminal else { return "" }
        let first = terminal.buffer.totalLinesTrimmed
        var promptRow = Int.max
        if cuttingPrompt {
            // The prompt's line starts where the cursor's line does, before any rows it wrapped onto.
            promptRow = first + terminal.buffer.yDisp + terminal.buffer.y
            while promptRow > first, terminal.getScrollInvariantLine(row: promptRow)?.isWrapped == true { promptRow -= 1 }
        }
        var lines: [String] = []
        var current = ""
        var row = first
        while row < promptRow, let line = terminal.getScrollInvariantLine(row: row) {
            let continues = terminal.getScrollInvariantLine(row: row + 1)?.isWrapped == true
            current += line.translateToString(trimRight: !continues, skipNullCellsFollowingWide: true)
            if !continues {
                lines.append(current.replacingOccurrences(of: "\u{0}", with: " ").replacing(/\s+$/, with: ""))
                current = ""
            }
            row += 1
        }
        if !current.isEmpty { lines.append(current) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        let text = lines.joined(separator: "\n")
        // Lines that left the scrollback are output Claude will not see either.
        if markingTruncation, first > 0, !text.hasPrefix(ClaudeBashMessage.truncationMarker) {
            return ClaudeBashMessage.truncationMarker + text
        }
        return text
    }
}
