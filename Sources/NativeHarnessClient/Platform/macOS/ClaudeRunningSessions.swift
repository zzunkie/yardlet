import Darwin
import Foundation

extension ClaudeConversationCatalog {
    /// Claude Code registers each running process as `sessions/<pid>.json` with its session ID.
    /// A process this app started (its child or a child's child) is Yardlet's own, not another
    /// app's, and is left out, so a task Yardlet itself just stopped is not taken for one held
    /// elsewhere while its process exits.
    static func runningSessionIDs(configDirectory: URL, excludingProcessesOf owner: pid_t = getpid()) -> Set<String> {
        let folder = configDirectory.appending(path: "sessions", directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var result: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count < 65_536,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let pid = value["pid"]?.doubleValue, pid > 1, pid < Double(Int32.max),
                  let session = value["sessionId"]?.stringValue,
                  kill(pid_t(pid), 0) == 0 || errno == EPERM,
                  !isDescendant(pid_t(pid), of: owner) else { continue }
            result.insert(session.lowercased())
        }
        return result
    }

    /// Whether `owner` is among the process's ancestors (not the process itself).
    static func isDescendant(_ pid: pid_t, of owner: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent == owner { return true }
            guard parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }
}
