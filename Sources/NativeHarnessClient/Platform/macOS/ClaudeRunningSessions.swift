import Darwin
import Foundation

extension ClaudeConversationCatalog {
    /// The entrypoint Yardlet starts Claude Code with (`ClaudeProcessTransport.environment`).
    static let yardletEntrypoint = "native-harness-client"

    /// A Claude Code process as it registered itself in `sessions/<pid>.json`.
    struct RunningProcess {
        let pid: pid_t
        let sessionID: String
        /// When the kernel says it started, which tells it from a later process given the same ID.
        let started: Int
        /// Started by a Yardlet that has since gone (it crashed or was killed): launchd adopted it.
        /// The CLI keeps running after its input closes while a tool call or a background command
        /// runs, so such a process can outlive its Yardlet with nothing left to read it.
        let isYardletLeftover: Bool
    }

    /// Claude Code registers each running process as `sessions/<pid>.json` with its session ID.
    /// A process this app started (its child or a child's child) is Yardlet's own, not another
    /// app's, and is left out, so a task Yardlet itself just stopped is not taken for one held
    /// elsewhere while its process exits. So is a leftover of a Yardlet that has gone: no app holds
    /// its conversation any more. Another running Yardlet's processes still count.
    static func runningSessionIDs(configDirectory: URL, excludingProcessesOf owner: pid_t = getpid()) -> Set<String> {
        Set(runningProcesses(configDirectory: configDirectory)
            .filter { !$0.isYardletLeftover && !isDescendant($0.pid, of: owner) }
            .map(\.sessionID))
    }

    /// The registered processes still running. A registration whose process started at another
    /// time than the CLI recorded (`procStart`, the CLI's own check) belongs to a process that has
    /// gone, and is left out.
    static func runningProcesses(configDirectory: URL) -> [RunningProcess] {
        let folder = configDirectory.appending(path: "sessions", directoryHint: .isDirectory).resolvingSymlinksInPath()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file), data.count < 65_536,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let number = value["pid"]?.doubleValue, number > 1, number < Double(Int32.max),
                  let session = value["sessionId"]?.stringValue,
                  let info = processInfo(pid_t(number)) else { return nil }
            let started = Int(info.kp_proc.p_starttime.tv_sec)
            if let recorded = value["procStart"]?.stringValue.flatMap(recordedStart), abs(recorded - started) > 1 {
                return nil
            }
            return RunningProcess(pid: pid_t(number), sessionID: session.lowercased(), started: started,
                                  isYardletLeftover: info.kp_eproc.e_ppid == 1
                                      && value["entrypoint"]?.stringValue == yardletEntrypoint)
        }
    }

    /// Ends the leftovers of a Yardlet that has gone (`RunningProcess.isYardletLeftover`) that hold
    /// this conversation, before Yardlet continues it, so two processes do not write it. Each gets
    /// SIGTERM, on which the CLI ends its own commands and removes its registration; one still
    /// running after `grace` is ended with its process tree. Returns the processes it ended.
    @discardableResult
    static func endYardletLeftovers(holding sessionID: String, configDirectory: URL,
                                    grace: Duration = .seconds(5)) -> [pid_t] {
        let leftovers = runningProcesses(configDirectory: configDirectory)
            .filter { $0.isYardletLeftover && $0.sessionID == sessionID.lowercased() }
        guard !leftovers.isEmpty else { return [] }
        // The same process: alive, started when it was found and still adopted by launchd.
        func isRunning(_ leftover: RunningProcess) -> Bool {
            guard let info = processInfo(leftover.pid) else { return false }
            return Int(info.kp_proc.p_starttime.tv_sec) == leftover.started && info.kp_eproc.e_ppid == 1
        }
        for leftover in leftovers { _ = kill(leftover.pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline, leftovers.contains(where: isRunning) {
            usleep(20_000)
        }
        for leftover in leftovers where isRunning(leftover) {
            NativeProcessTree.terminate(rootPID: leftover.pid)
        }
        return leftovers.map(\.pid)
    }

    /// Whether `owner` is among the process's ancestors (not the process itself).
    static func isDescendant(_ pid: pid_t, of owner: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            guard let parent = processInfo(current)?.kp_eproc.e_ppid else { return false }
            if parent == owner { return true }
            guard parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    /// The kernel's record of a process, or nil once it has gone (a zombie included).
    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
        return info
    }

    /// The start the CLI records as `procStart`, `ps -o lstart=` in the C locale and UTC
    /// ("Wed Nov  4 12:17:54 2026"), in seconds since 1970; nil for a value it cannot read.
    static func recordedStart(_ text: String) -> Int? {
        let parts = text.split(separator: " ")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let clock = parts.count == 5 ? parts[3].split(separator: ":").compactMap { Int32($0) } : []
        guard clock.count == 3, let month = months.firstIndex(of: String(parts[1])),
              let day = Int32(parts[2]), let year = Int32(parts[4]) else { return nil }
        var time = tm()
        time.tm_year = year - 1900
        time.tm_mon = Int32(month)
        time.tm_mday = day
        time.tm_hour = clock[0]
        time.tm_min = clock[1]
        time.tm_sec = clock[2]
        return Int(timegm(&time))
    }
}
