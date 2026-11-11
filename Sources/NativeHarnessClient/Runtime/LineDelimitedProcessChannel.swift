import Dispatch
import Foundation

/// A child process Yardlet exchanges lines with: it writes to the process's standard input and reads
/// its standard output a line at a time. What every such exchange shares is here: starting the
/// process, splitting what it writes into lines, keeping the end of its standard error, and the
/// order things end in. What a line means, and which answer meets which request, stay with the
/// transport that owns the channel.
///
/// `events` carries each line and then, once, the process's own exit. A response written just
/// before the process exits can still be in the pipe when the exit is reported, and so can its last
/// words on standard error, so the exit goes out only after both pipes have been read to their
/// ends. A child the process left behind can keep a pipe open; the exit waits `drainGrace` for it.
final class LineDelimitedProcessChannel: @unchecked Sendable {
    struct Launch: Sendable {
        var executableURL: URL
        var arguments: [String] = []
        var currentDirectoryURL: URL?
        /// The whole environment the process starts with; nil for Yardlet's own.
        var environment: [String: String]?
        /// The row the process tree counts toward in Task Resource Usage while it runs.
        var resourceOwner: TaskResourceOwner?
        var processRegistry: TaskProcessRegistry = .shared
    }

    enum Event: Equatable, Sendable {
        /// One line of standard output without its line ending (`\n` or `\r\n`). Empty lines are
        /// skipped, and so is a last line the process never ended.
        case line(Data)
        /// The process ended by itself, with this status and these last words on standard error.
        /// Always the last event.
        case exited(code: Int32, stderr: String)
    }

    /// Each line the process writes, then its exit. After `stop()` the events end with no exit.
    let events: AsyncStream<Event>

    private let process: Process
    private let input: FileHandle
    private let output: Output

    /// Starts the process. `stderrLimit` is how many bytes of the end of its standard error are kept.
    init(_ launch: Launch, stderrLimit: Int, drainGrace: Duration = .seconds(1)) throws {
        let process = Process()
        let stdinPipe = Pipe.childInput()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if let directory = launch.currentDirectoryURL { process.currentDirectoryURL = directory }
        if let environment = launch.environment { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let output = Output(stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading,
                            stderrLimit: stderrLimit, continuation: continuation,
                            resourceOwner: launch.resourceOwner, processRegistry: launch.processRegistry)
        self.events = events
        self.process = process
        input = stdinPipe.fileHandleForWriting
        self.output = output

        output.startReading()
        process.terminationHandler = { process in
            output.processExited(process.processIdentifier, code: process.terminationStatus, drainGrace: drainGrace)
        }
        do {
            try NativeProcessTree.run(process)
        } catch {
            output.stopReading()
            throw error
        }
        output.processStarted(process.processIdentifier)
    }

    var isRunning: Bool { process.isRunning }

    /// The status the process ended with; nil while it runs.
    var exitCode: Int32? { process.isRunning ? nil : process.terminationStatus }

    /// The end of what the process has written to standard error so far.
    var stderrText: String { output.stderrText }

    /// Writes to the process's standard input; throws once the process no longer reads it. Writes
    /// and `stop()` come from the one owner of the channel, a call at a time.
    func write(_ data: Data) throws {
        try input.write(contentsOf: data)
    }

    /// Ends the exchange: no more events, the input closed, the process and what it started ended.
    /// Returns the status the process ended with, -1 when its end could not be confirmed.
    @discardableResult
    func stop() -> Int32 {
        output.stopReading()
        try? input.close()
        let code = NativeProcessTree.terminate(process: process)
        output.processStopped(process.processIdentifier)
        return code
    }

    /// What the process writes, read on the pipes' own queues, and when it has all been read.
    ///
    /// Each pipe's handler holds this object until the pipe ends or the channel is stopped, so the
    /// pipes are read for as long as anything writes to them even if nothing else holds the channel.
    private final class Output: @unchecked Sendable {
        /// Ends the drain grace on time. A queue of its own always gets a thread, while the global
        /// queues can wait behind a concurrency pool whose threads are all blocked.
        private static let deadlines = DispatchQueue(label: "Yardlet process channel deadlines")

        private let lock = NSLock()
        private let stdout: FileHandle
        private let stderr: FileHandle
        private let stderrLimit: Int
        private let continuation: AsyncStream<Event>.Continuation
        private let resourceOwner: TaskResourceOwner?
        private let processRegistry: TaskProcessRegistry
        private var lines = LineSplitter()
        private var stderrTail = Data()
        private var stdoutEnded = false
        private var stderrEnded = false
        private var exitCode: Int32?
        private var finished = false

        init(stdout: FileHandle, stderr: FileHandle, stderrLimit: Int,
             continuation: AsyncStream<Event>.Continuation,
             resourceOwner: TaskResourceOwner?, processRegistry: TaskProcessRegistry) {
            self.stdout = stdout
            self.stderr = stderr
            self.stderrLimit = max(0, stderrLimit)
            self.continuation = continuation
            self.resourceOwner = resourceOwner
            self.processRegistry = processRegistry
        }

        var stderrText: String {
            lock.withLock { Self.text(stderrTail) }
        }

        func startReading() {
            stdout.readChunks({ [self] in accept($0) }, atEnd: { [self] in pipeEnded(stdout: true) })
            stderr.readChunks({ [self] in keep($0) }, atEnd: { [self] in pipeEnded(stdout: false) })
        }

        /// The process is running: it counts for its owner until it ends. One that has already
        /// ended is not counted, as nothing would take it out again.
        func processStarted(_ processID: Int32) {
            guard let resourceOwner else { return }
            lock.withLock {
                guard exitCode == nil else { return }
                processRegistry.register(processID, owner: resourceOwner)
            }
        }

        func processStopped(_ processID: Int32) {
            guard let resourceOwner else { return }
            processRegistry.unregister(processID, owner: resourceOwner)
        }

        /// The process has ended. Its exit goes out now if both pipes have ended, otherwise when
        /// they do or when `drainGrace` is over, whichever comes first.
        func processExited(_ processID: Int32, code: Int32, drainGrace: Duration) {
            let published = lock.withLock {
                exitCode = code
                if let resourceOwner { processRegistry.unregister(processID, owner: resourceOwner) }
                publishExitOnceRead()
                return finished
            }
            guard !published else { return }
            // The pipes are still read after the grace and what arrives is dropped, so a child that
            // goes on writing to them is never held up by a full pipe and never replaces the
            // process's own last words.
            Self.deadlines.asyncAfter(deadline: .now() + drainGrace / .seconds(1)) { [self] in
                lock.withLock { end(publishingExit: true) }
            }
        }

        /// Stops reading and ends the events with no exit.
        func stopReading() {
            lock.withLock { end(publishingExit: false) }
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
        }

        // Lines and the exit are yielded with the lock held, so no line can follow the exit.
        private func accept(_ chunk: Data) {
            lock.withLock {
                guard !finished else { return }
                for line in lines.append(chunk) { continuation.yield(.line(line)) }
            }
        }

        private func keep(_ chunk: Data) {
            lock.withLock {
                guard !finished else { return }
                stderrTail.append(chunk)
                if stderrTail.count > stderrLimit { stderrTail = Data(stderrTail.suffix(stderrLimit)) }
            }
        }

        private func pipeEnded(stdout: Bool) {
            lock.withLock {
                if stdout { stdoutEnded = true } else { stderrEnded = true }
                publishExitOnceRead()
            }
        }

        /// With the lock held.
        private func publishExitOnceRead() {
            guard exitCode != nil, stdoutEnded, stderrEnded else { return }
            end(publishingExit: true)
        }

        /// With the lock held.
        private func end(publishingExit: Bool) {
            guard !finished else { return }
            finished = true
            if publishingExit, let exitCode {
                continuation.yield(.exited(code: exitCode, stderr: Self.text(stderrTail)))
            }
            continuation.finish()
        }

        private static func text(_ tail: Data) -> String {
            String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Splits bytes into the lines they hold, as they arrive in chunks.
private struct LineSplitter {
    /// What has arrived of the line still being read.
    private var partial = Data()

    /// The lines `chunk` completes, without their line endings (`\n` or `\r\n`). Empty lines are skipped.
    mutating func append(_ chunk: Data) -> [Data] {
        // Only the new chunk can hold the end of the line being read: a large line (a whole thread
        // with its turns, a picture) arrives in many chunks, and looking through everything
        // buffered on each of them made reading it grow with the square of its size.
        let scanned = partial.count
        partial.append(chunk)
        var lines: [Data] = []
        var lineStart = partial.startIndex
        var searchStart = partial.startIndex + scanned
        while let newline = partial[searchStart...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > lineStart, partial[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd > lineStart { lines.append(Data(partial[lineStart..<lineEnd])) }
            lineStart = newline + 1
            searchStart = lineStart
        }
        if lineStart == partial.endIndex {
            // Nothing is left of a line: let go of the buffer, which a large line made large.
            partial = Data()
        } else if lineStart > partial.startIndex {
            partial.removeSubrange(partial.startIndex..<lineStart)
        }
        return lines
    }
}
