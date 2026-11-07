import Foundation
@preconcurrency import SwiftTerm

/// A shell's exit status as SwiftTerm should have read it. SwiftTerm asks once, without waiting, as soon as the kernel
/// says the shell is exiting. A shell that leads its terminal's session is not finished then: it first waits for its
/// output to be read. SwiftTerm then reports 0 and leaves the process unreaped, so a 0 is checked here. Never wait for
/// this on the queue that reads the terminal, which the exit is waiting on.
enum TerminalExitStatus: Equatable {
    case notReady
    case known(Int32?)

    static func read(processID: pid_t, reported: Int32?) -> TerminalExitStatus {
        guard reported == 0, processID > 1 else { return .known(reported) }
        var status: Int32 = 0
        switch waitpid(processID, &status, WNOHANG) {
        case 0: return .notReady
        case processID: return .known(status)
        // SwiftTerm did reap it: 0 is the status.
        default: return .known(reported)
        }
    }
}

/// A terminal's byte stream and lifetime, independent of its renderer.
@MainActor
protocol TerminalHosting: AnyObject {
    var onOutput: ((ArraySlice<UInt8>) -> Void)? { get set }
    var onExit: ((Int32?) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var isReady: Bool { get }
    var statusMessage: String? { get }
    var processID: Int32? { get }
    var foregroundProcessGroup: Int32? { get }
    var workspaceURL: URL? { get }
    var isAtPrompt: Bool? { get }
    func refreshPromptState() async -> Bool?
    func start()
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(columns: Int, rows: Int)
    func stop()
}

/// Owns a PTY even while no terminal view exists.
@MainActor
final class LocalTerminalHosting: TerminalHosting, @MainActor LocalProcessDelegate {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    var isReady: Bool { process?.running == true }
    var statusMessage: String? { nil }
    var outputConsumer: (@Sendable (TerminalStreamUpdate) async -> Void)?
    private var flowDelegate: BackpressuredTerminalDelegate?
    private var flowID = UUID()
    private(set) var process: LocalProcess?
    private var ownedSessionID: pid_t?
    private let folder: URL
    private let launch: ShellLaunchEnvironment
    private var columns = 80
    private var rows = 24

    init(folder: URL, launch: ShellLaunchEnvironment) {
        self.folder = folder
        self.launch = launch
    }

    var workspaceURL: URL? { folder }
    var processID: Int32? { process.map(\.shellPid) }
    var isAtPrompt: Bool? {
        guard let group = foregroundProcessGroup, let processID else { return nil }
        return group == processID
    }
    func refreshPromptState() async -> Bool? { isAtPrompt }
    var foregroundProcessGroup: Int32? {
        guard let process, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        return group > 0 ? group : nil
    }

    func start() {
        guard process == nil else { return }
        let process: LocalProcess
        if let outputConsumer {
            let token = UUID()
            flowID = token
            let delegate = BackpressuredTerminalDelegate(columns: columns, rows: rows, display: { [weak self] bytes in
                await MainActor.run {
                    guard let self, self.flowID == token else { return }
                    self.onOutput?(bytes[...])
                }
            }, exited: { [weak self] status in
                await MainActor.run {
                    guard let self, self.flowID == token else { return }
                    self.onExit?(status)
                }
            }, consume: outputConsumer)
            flowDelegate = delegate
            process = LocalProcess(delegate: delegate, dispatchQueue: delegate.queue)
        } else {
            process = LocalProcess(delegate: self, dispatchQueue: .main)
        }
        self.process = process
        let start = launch.start(in: folder)
        process.startProcess(executable: start.executable, args: start.arguments,
                             environment: start.environment, execName: start.processName,
                             currentDirectory: start.currentDirectory)
        // The pinned SwiftTerm forkpty backend calls setsid; its session survives a fast-exiting leader.
        if process.shellPid > 1 { ownedSessionID = process.shellPid }
        if process.running { onReady?() }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let process, process.running else { return }
        process.send(data: bytes)
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(1, min(columns, 500))
        self.rows = max(1, min(rows, 300))
        flowDelegate?.resize(columns: self.columns, rows: self.rows)
        guard let process, process.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func stop() {
        flowDelegate?.stop()
        flowDelegate = nil
        flowID = UUID()
        if let process, let ownedSessionID {
            // Do not signal a stale leader PID after SwiftTerm reaped it. Dropping the process closes
            // its descriptor without signaling; the delegate's stop also ends any post-exit drain wait.
            if process.shellPid > 1, getsid(process.shellPid) == ownedSessionID {
                process.terminate()
                if getsid(process.shellPid) == ownedSessionID {
                    NativeProcessTree.terminate(rootPID: process.shellPid)
                }
            }
            NativeProcessTree.terminatePTYSession(ownedSessionID)
        }
        ownedSessionID = nil
        process = nil
    }

    func dataReceived(slice: ArraySlice<UInt8>) { onOutput?(slice) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }
        guard case let .known(status) = TerminalExitStatus.read(processID: source.shellPid, reported: exitCode) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.processTerminated(source, exitCode: exitCode)
            }
            return
        }
        onExit?(status)
    }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    }
}
