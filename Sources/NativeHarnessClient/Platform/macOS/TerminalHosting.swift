import Foundation
@preconcurrency import SwiftTerm

/// A terminal's byte stream and lifetime, independent of its renderer.
@MainActor
protocol TerminalHosting: AnyObject {
    var onOutput: ((ArraySlice<UInt8>) -> Void)? { get set }
    var onExit: ((Int32?) -> Void)? { get set }
    var processID: Int32? { get }
    var foregroundProcessGroup: Int32? { get }
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
    private(set) var process: LocalProcess?
    private let folder: URL
    private let launch: ShellLaunchEnvironment
    private var columns = 80
    private var rows = 24

    init(folder: URL, launch: ShellLaunchEnvironment) {
        self.folder = folder
        self.launch = launch
    }

    var processID: Int32? { process.map(\.shellPid) }
    var foregroundProcessGroup: Int32? {
        guard let process, process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        return group > 0 ? group : nil
    }

    func start() {
        guard process == nil else { return }
        let process = LocalProcess(delegate: self, dispatchQueue: .main)
        self.process = process
        let start = launch.start(in: folder)
        process.startProcess(executable: start.executable, args: start.arguments,
                             environment: start.environment, execName: start.processName,
                             currentDirectory: start.currentDirectory)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let process, process.running else { return }
        process.send(data: bytes)
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(1, min(columns, 500))
        self.rows = max(1, min(rows, 300))
        guard let process, process.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func stop() {
        if let process, process.running, process.shellPid > 0 {
            NativeProcessTree.terminate(rootPID: process.shellPid)
            process.terminate()
        }
        process = nil
    }

    func dataReceived(slice: ArraySlice<UInt8>) { onOutput?(slice) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }
        onExit?(exitCode)
    }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    }
}
