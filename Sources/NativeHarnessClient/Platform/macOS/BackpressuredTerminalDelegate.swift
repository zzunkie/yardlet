import Foundation
@preconcurrency import SwiftTerm

enum TerminalStreamUpdate: Sendable { case output(Data), exited(Int32?) }

/// SwiftTerm waits for a non-main delegate before arming its next PTY read. This queue may wait
/// for the remote consumer; the main actor never waits for capacity and the kernel bounds the rest.
final class BackpressuredTerminalDelegate: LocalProcessDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "yardlet.terminal.output", qos: .userInitiated)
    private let dimensions = NSLock()
    private var columns: Int
    private var rows: Int
    private var finished = false // Only the delegate queue accesses this.
    private let display: @Sendable ([UInt8]) async -> Void
    private let exited: @Sendable (Int32?) async -> Void
    private let consume: @Sendable (TerminalStreamUpdate) async -> Void

    init(columns: Int, rows: Int, display: @escaping @Sendable ([UInt8]) async -> Void,
         exited: @escaping @Sendable (Int32?) async -> Void,
         consume: @escaping @Sendable (TerminalStreamUpdate) async -> Void) {
        self.columns = columns; self.rows = rows
        self.display = display; self.exited = exited; self.consume = consume
    }

    func resize(columns: Int, rows: Int) { dimensions.withLock { self.columns = columns; self.rows = rows } }
    func getWindowSize() -> winsize {
        dimensions.withLock { winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0) }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        guard !finished else { return }
        let bytes = Array(slice)
        waitForConsumer { [display, consume] in
            await display(bytes)
            await consume(.output(Data(bytes)))
        }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // The process-exit notification can precede the PTY's last read. Drain to EOF before exit.
        finishWhenDrained(source, status: exitCode)
    }
    private func finishWhenDrained(_ source: LocalProcess, status: Int32?) {
        guard !finished else { return }
        if source.childfd < 0, case let .known(known) = TerminalExitStatus.read(processID: source.shellPid, reported: status) {
            finish(known)
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in finishWhenDrained(source, status: status) }
        }
    }
    func stop() { queue.async { [self] in finish(nil) } }
    private func finish(_ status: Int32?) {
        guard !finished else { return }
        finished = true
        waitForConsumer { [exited, consume] in
            await exited(status)
            await consume(.exited(status))
        }
    }
    private func waitForConsumer(_ work: @escaping @Sendable () async -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let completed = DispatchSemaphore(value: 0)
        Task { await work(); completed.signal() }
        completed.wait()
    }
}
