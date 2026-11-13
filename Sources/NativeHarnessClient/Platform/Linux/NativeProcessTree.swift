import Foundation
import Glibc

/// Ending a process Yardlet started together with what it started (docs/LINUX_HOST.md, "Processes"). Foundation's
/// `Process` on Linux starts each child in a process group of its own (`POSIX_SPAWN_SETPGROUP`) and its `terminate()`
/// signals the child alone, so the node and MCP servers a CLI started would stay behind. `terminate(process:)` reads
/// the process table in `/proc`, ends the child's descendants while it is still their parent, then every process left
/// in its group, which reaches those whose parent has already ended, and last the child, which Foundation reaps. A
/// descendant that left the group and lost its parent first (a daemon that forked twice and called `setsid`) is not
/// found; under the systemd service its unit's control group ends it when the service stops.
enum NativeProcessTree {
    static func run(_ process: Process) throws {
        try process.run()
    }

    /// Stops a process the way Control-C would (SIGINT), for a CLI whose turn is the process itself.
    static func interrupt(process: Process) {
        process.interrupt()
    }

    @discardableResult
    static func terminate(process: Process) -> Int32 {
        guard process.isRunning else { return process.terminationStatus }
        // While `isRunning` holds, Foundation has not reaped the child, so its process ID and group are still its own.
        LinuxProcessTable.end(root: process.processIdentifier)
        // Foundation sees the end on its own thread; the caller's wait is bounded. -1 means unconfirmed.
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        return process.isRunning ? -1 : process.terminationStatus
    }
}

/// The processes `/proc` lists, with what ending a tree needs of each.
enum LinuxProcessTable {
    struct Entry: Equatable {
        var pid: pid_t
        var parent: pid_t
        var group: pid_t
        var session: pid_t
    }

    /// Ends `root`'s descendants and group, then `root`, with SIGKILL, as the Mac's layer ends a tree. The descendants
    /// go first and are looked for again until two looks find none: ending a wrapper first could leave a child it had
    /// just started under another parent before a look reached it. The group is signalled only when `root` leads a
    /// group of its own, never this process's.
    static func end(root: pid_t) {
        guard root > 1, root != getpid() else { return }
        let ownGroup = getpgrp()
        let leadsGroup = getpgid(root) == root && root != ownGroup
        var emptyLooks = 0
        for _ in 0..<6 {
            let entries = snapshot()
            let pending = members(of: root, leadsGroup: leadsGroup, in: entries)
            emptyLooks = pending.isEmpty ? emptyLooks + 1 : 0
            if emptyLooks >= 2 { break }
            for pid in pending.reversed() { _ = kill(pid, SIGKILL) }
            usleep(10_000)
        }
        if leadsGroup { _ = killpg(root, SIGKILL) }
        _ = kill(root, SIGKILL)
    }

    /// `root`'s descendants by parent, deepest last, and the other processes of its group when it leads one; never
    /// `root` itself or this process.
    static func members(of root: pid_t, leadsGroup: Bool, in entries: [Entry]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for entry in entries { children[entry.parent, default: []].append(entry.pid) }
        var found: [pid_t] = []
        var seen: Set<pid_t> = [root, getpid()]
        var pending = [root]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where seen.insert(child).inserted {
                found.append(child)
                pending.append(child)
            }
        }
        if leadsGroup {
            for entry in entries where entry.group == root && seen.insert(entry.pid).inserted { found.append(entry.pid) }
        }
        return found
    }

    /// Every process `/proc` lists now. A process that ends while it is read is left out.
    static func snapshot() -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return names.compactMap { name in
            guard let pid = pid_t(name), pid > 0 else { return nil }
            return read(pid)
        }
    }

    static func read(_ pid: pid_t) -> Entry? {
        let descriptor = open("/proc/\(pid)/stat", O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { Glibc.read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        return parse(String(decoding: bytes[..<count], as: UTF8.self))
    }

    /// One `/proc/<pid>/stat` line: `pid (name) state ppid pgrp session …`. The name may hold spaces and
    /// parentheses, so the fields are read after its last parenthesis.
    static func parse(_ line: String) -> Entry? {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"),
              let pid = pid_t(line[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let fields = line[line.index(after: close)...].split(separator: " ")
        guard fields.count >= 4, let parent = pid_t(fields[1]), let group = pid_t(fields[2]),
              let session = pid_t(fields[3]) else { return nil }
        return Entry(pid: pid, parent: parent, group: group, session: session)
    }
}
