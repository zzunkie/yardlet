import Darwin
import Foundation

/// Bounded cleanup for app-owned process trees. Native surfaces may launch a wrapper
/// (`script`, a shell, or a PTY host) whose children outlive the wrapper's termination
/// signal, so cleanup snapshots and signals descendants directly before reaping the root.
enum NativeProcessTree {
    static func terminate(rootPID: pid_t) {
        guard rootPID > 0 else { return }

        let descendants = descendantProcessIDs(of: rootPID)
        signalTermination(rootPID: rootPID, descendants: descendants)

        var status: Int32 = 0
        _ = Darwin.waitpid(rootPID, &status, 0)
    }

    /// Terminates a Foundation-owned process tree and lets `Process` reap its own child.
    /// Calling `waitpid` separately would leave Foundation believing the task is still running
    /// and makes `terminationStatus` raise an Objective-C exception.
    @discardableResult
    static func terminate(process: Process) -> Int32 {
        guard process.isRunning else { return process.terminationStatus }
        let rootPID = process.processIdentifier
        let descendants = descendantProcessIDs(of: rootPID)
        signalTermination(rootPID: rootPID, descendants: descendants)
        // waitUntilExit can wait on the wrong thread's run loop after an async
        // executor hop, even once the child has gone. Let Foundation reap it on
        // its own queue while bounding the caller's wait. -1 means unconfirmed.
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            Darwin.usleep(10_000)
        }
        return process.isRunning ? -1 : process.terminationStatus
    }

    private static func signalTermination(rootPID: pid_t, descendants: [pid_t]) {
        // Drain descendants while the root is still parented. Killing the wrapper first can
        // reparent a just-launched child before a single process-tree snapshot reaches it.
        var pending = descendants
        var consecutiveEmptyScans = 0
        for _ in 0..<6 {
            for pid in pending.reversed() {
                _ = Darwin.kill(pid, SIGHUP)
                _ = Darwin.kill(pid, SIGKILL)
            }
            Darwin.usleep(10_000)
            pending = descendantProcessIDs(of: rootPID)
            consecutiveEmptyScans = pending.isEmpty ? consecutiveEmptyScans + 1 : 0
            if consecutiveEmptyScans >= 2 { break }
        }

        _ = Darwin.kill(-rootPID, SIGHUP)
        _ = Darwin.kill(rootPID, SIGHUP)
        _ = Darwin.kill(-rootPID, SIGKILL)
        _ = Darwin.kill(rootPID, SIGKILL)
    }

    static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        guard rootPID > 0 else { return [] }

        var pending = [rootPID]
        var seen: Set<pid_t> = [rootPID]
        var descendants: [pid_t] = []

        while !pending.isEmpty {
            let parentPID = pending.removeFirst()
            var capacity = 32
            var childIDs: [pid_t] = []

            for _ in 0..<4 {
                var buffer = [pid_t](repeating: 0, count: capacity)
                let result = buffer.withUnsafeMutableBytes { rawBuffer in
                    proc_listchildpids(
                        parentPID,
                        rawBuffer.baseAddress,
                        Int32(rawBuffer.count)
                    )
                }
                guard result > 0 else { break }

                let count = min(Int(result), buffer.count)
                childIDs = Array(buffer.prefix(count).filter { $0 > 0 })
                if Int(result) < capacity || capacity >= 4_096 { break }
                capacity *= 2
            }

            for childPID in childIDs where seen.insert(childPID).inserted {
                descendants.append(childPID)
                pending.append(childPID)
            }
        }

        return descendants
    }
}
