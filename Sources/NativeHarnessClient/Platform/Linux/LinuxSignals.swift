import Dispatch
import Foundation
import Glibc

/// Signals in the Linux host's own process, handled without ignoring them. A signal set to SIG_IGN stays ignored in a
/// program the process starts (exec keeps it, and Foundation's `Process` restores no dispositions), so a harness would
/// ignore the Control-C that stops its turn. A signal caught by a handler goes back to its default in a started
/// program, so the host catches what it handles: the handler writes the signal's number to a pipe, which a dispatch
/// source reads on the queue given.
enum LinuxSignals {
    nonisolated(unsafe) private static var pipeWrite: Int32 = -1
    nonisolated(unsafe) private static var sources: [any DispatchSourceRead] = []

    /// Calls `handler` on `queue` with each of `signals` the process receives.
    static func handle(_ signals: [Int32], on queue: DispatchQueue, _ handler: @escaping @Sendable (Int32) -> Void) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
        pipeWrite = ends[1]
        let read = ends[0]
        let source = DispatchSource.makeReadSource(fileDescriptor: read, queue: queue)
        source.setEventHandler {
            var number: UInt8 = 0
            guard Glibc.read(read, &number, 1) == 1 else { return }
            handler(Int32(number))
        }
        source.resume()
        sources.append(source)
        for number in signals {
            _ = signal(number) { number in
                var byte = UInt8(truncatingIfNeeded: number)
                _ = write(LinuxSignals.pipeWrite, &byte, 1)
            }
        }
    }

    /// Catches `number` with a handler that does nothing: for SIGPIPE, a write to a closed pipe or socket then fails
    /// with EPIPE rather than ending the host, and a started program gets the default back.
    static func absorb(_ number: Int32) {
        _ = signal(number) { _ in }
    }
}
