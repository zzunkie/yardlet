import Darwin
import Foundation

/// Whether the browser host still has a task profile's folder open, by what the kernel reports for the host and the
/// Chromium processes it started (docs/BROWSER_SESSION_ISOLATION.md, "Archive and delete"). The bridge releases a
/// profile's request context when its last tab or cookie copy ends, and Chromium closes the profile's files some time
/// after that, in the browser process and in the network and storage services.
enum BrowserProfileFolderUse {
    /// The keys of `folders` that a process of the tree under `root` has a file open in. A process whose files cannot
    /// be read counts as having every folder open.
    nonisolated static func keys(of folders: [String: URL], openInTreeOf root: pid_t) -> Set<String> {
        // The kernel reports a file by its real path: a home under /var is in /private/var.
        let prefixes = folders.mapValues { realPath(of: $0.deletingLastPathComponent()) + "/" + $0.lastPathComponent + "/" }
        var open: Set<String> = []
        for process in [root] + NativeProcessTree.descendantProcessIDs(of: root) {
            guard let paths = openFiles(of: process) else {
                // One that ended meanwhile holds nothing.
                if kill(process, 0) == 0 || errno != ESRCH { return Set(folders.keys) }
                continue
            }
            for path in paths {
                for (key, prefix) in prefixes where path.hasPrefix(prefix) { open.insert(key) }
            }
        }
        return open
    }

    private static func realPath(of url: URL) -> String {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return url.path(percentEncoded: false) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The paths of the process's open files (`PROC_PIDLISTFDS`, then `PROC_PIDFDVNODEPATHINFO` for each), or nil
    /// when they cannot be read.
    private static func openFiles(of process: pid_t) -> [String]? {
        let needed = proc_pidinfo(process, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let read = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(process, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard read > 0 else { return nil }
        var paths: [String] = []
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for descriptor in descriptors.prefix(Int(read) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            // A descriptor closed meanwhile reads short.
            guard proc_pidfdinfo(process, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            paths.append(withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return paths
    }
}
