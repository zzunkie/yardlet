import Dispatch
import Foundation

/// The end of a child process Yardlet started, as Foundation reports it to the process's termination
/// handler. Every wait for a child goes through here rather than `Process.waitUntilExit()`.
///
/// Foundation ties a process's end to the thread that launched it: it posts the end from that
/// thread's run loop, and `waitUntilExit()` turns the calling thread's run loop until it has seen
/// the end. A task in the concurrency pool has no thread of its own and no run loop that anyone
/// turns, and there the wait has gone on for hours after the child was gone, holding one of the
/// pool's few threads for each stuck wait. The termination handler is called on a dispatch queue,
/// and setting it also turns off the posting, so this wait depends on no run loop and holds no
/// thread while it waits.
final class ProcessExit: @unchecked Sendable {
    /// Ends the waits whose time is up. A queue of its own always gets a thread, while the global
    /// queues can wait behind a concurrency pool whose threads are all blocked.
    private static let deadlines = DispatchQueue(label: "Yardlet process exit deadlines")

    private let lock = NSLock()
    private var hasEnded = false
    private var waiters: [Int: @Sendable () -> Void] = [:]
    private var nextWaiter = 0

    /// Starts `process` with `NativeProcessTree.run(_:)` and watches for its end. A termination
    /// handler set before this still runs, before any wait returns; set none after it, as that
    /// would replace the one this watches with.
    init(running process: Process) throws {
        let handler = process.terminationHandler
        process.terminationHandler = { [self] process in
            handler?(process)
            end()
        }
        do {
            try NativeProcessTree.run(process)
        } catch {
            process.terminationHandler = handler
            throw error
        }
    }

    /// Suspends, holding no thread, until the process has ended, for at most `timeout`. False when
    /// it had not ended by then.
    func wait(timeout: Duration) async -> Bool {
        // Whichever of the end and the deadline takes the waiter out resumes it, so it resumes once.
        await withCheckedContinuation { continuation in
            guard let id = addWaiter({ continuation.resume(returning: true) }) else {
                return continuation.resume(returning: true)
            }
            Self.deadlines.asyncAfter(deadline: .now() + Self.seconds(timeout)) { [self] in
                if removeWaiter(id) { continuation.resume(returning: false) }
            }
        }
    }

    /// Blocks this thread until the process has ended, for at most `timeout`, for code that cannot
    /// suspend. The thread keeps its own deadline, so the wait ends on time however busy the
    /// dispatch queues are.
    func waitBlockingThread(timeout: Duration) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        guard let id = addWaiter({ semaphore.signal() }) else { return true }
        if semaphore.wait(timeout: .now() + Self.seconds(timeout)) == .success { return true }
        if removeWaiter(id) { return false }
        // The end came as the time ran out and is signaling now.
        semaphore.wait()
        return true
    }

    /// Registers `waiter` for the end, or returns nil when the process has already ended.
    private func addWaiter(_ waiter: @escaping @Sendable () -> Void) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return nil }
        let id = nextWaiter
        nextWaiter += 1
        waiters[id] = waiter
        return id
    }

    /// Whether `id` was still waiting, which it then no longer is.
    private func removeWaiter(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: id) != nil
    }

    private func end() {
        lock.lock()
        hasEnded = true
        let ended = waiters.values
        waiters.removeAll()
        lock.unlock()
        for waiter in ended { waiter() }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
