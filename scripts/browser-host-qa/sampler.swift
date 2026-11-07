// Samples a process tree with proc_pid_rusage: physical footprint, resident size, CPU time and
// wakeups, every half second over an interval, and prints one JSON object. Per-process counters use
// PID and start time so a reused PID cannot subtract another process's CPU. Endpoint memory remains
// compatible with the browser QA tools; aggregate peaks are simultaneous samples, not sums of peaks.
// usage: sampler <root pid> <label> [interval seconds]
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let root = pid_t(arguments[1]) else {
    FileHandle.standardError.write("usage: sampler <root pid> <label> [interval]\n".data(using: .utf8)!)
    exit(2)
}
let label = arguments[2]
let interval = arguments.count > 3 ? Double(arguments[3]) ?? 3 : 3
guard interval.isFinite, interval > 0 else { exit(2) }

func children(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 512)
    let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Array(buffer.prefix(Int(count)))
}

func tree(_ pid: pid_t) -> [pid_t] {
    [pid] + children(of: pid).flatMap(tree)
}

func path(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return "?" }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

struct Usage {
    let footprint: UInt64
    let resident: UInt64
    let cpuNanoseconds: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
}

func usage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    return Usage(footprint: info.ri_phys_footprint, resident: info.ri_resident_size,
                 cpuNanoseconds: cpu, idleWakeups: info.ri_pkg_idle_wkups,
                 interruptWakeups: info.ri_interrupt_wkups)
}

struct Identity: Hashable { let pid: pid_t; let start: UInt64 }
struct Stat {
    var path: String
    var previous: Usage
    var cpu: UInt64 = 0
    var wakeups: UInt64 = 0
    var peak: UInt64 = 0
}
func identity(_ pid: pid_t) -> Identity? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
    return Identity(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}
var stats: [Identity: Stat] = [:]
var alive = Set<Identity>()
var aggregatePeaks = ["app": 0.0, "browser": 0.0, "yardlet": 0.0]
var sampleCount = 0
let started = ContinuousClock.now
let deadline = started + .seconds(interval)
repeat {
    autoreleasepool {
        var current = Set<Identity>()
        var totals = ["app": 0.0, "browser": 0.0]
        for pid in tree(root) {
            guard let key = identity(pid), let now = usage(pid) else { continue }
            current.insert(key)
            var stat = stats[key] ?? Stat(path: path(pid), previous: now)
            if alive.contains(key) {
                if now.cpuNanoseconds >= stat.previous.cpuNanoseconds { stat.cpu += now.cpuNanoseconds - stat.previous.cpuNanoseconds }
                let oldWakeups = stat.previous.idleWakeups + stat.previous.interruptWakeups
                let newWakeups = now.idleWakeups + now.interruptWakeups
                if newWakeups >= oldWakeups { stat.wakeups += newWakeups - oldWakeups }
            }
            stat.previous = now
            stat.peak = max(stat.peak, now.footprint)
            stats[key] = stat
            if pid == root { totals["app", default: 0] += Double(now.footprint) / 1_048_576 }
            else if stat.path.contains("Yardlet Browser Host") { totals["browser", default: 0] += Double(now.footprint) / 1_048_576 }
        }
        totals["yardlet"] = totals["app", default: 0] + totals["browser", default: 0]
        for (key, value) in totals { aggregatePeaks[key] = max(aggregatePeaks[key, default: 0], value) }
        alive = current
        sampleCount += 1
    }
    let remaining = (ContinuousClock.now.duration(to: deadline)).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    if seconds <= 0 { break }
    Thread.sleep(forTimeInterval: min(0.5, seconds))
} while true
let elapsed = (ContinuousClock.now - started).components
let actualSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
let processes: [[String: Any]] = stats.map { key, stat in
    ["pid": key.pid, "startEpochUs": key.start, "path": stat.path, "isRunning": alive.contains(key),
     "footprintMiB": alive.contains(key) ? Double(stat.previous.footprint) / 1_048_576 : 0,
     "residentMiB": alive.contains(key) ? Double(stat.previous.resident) / 1_048_576 : 0,
     "footprintPeakMiB": Double(stat.peak) / 1_048_576,
     "cpuPercent": Double(stat.cpu) / (actualSeconds * 1e9) * 100,
     "wakeupsPerSecond": Double(stat.wakeups) / actualSeconds]
}.sorted { ($0["pid"] as! pid_t) < ($1["pid"] as! pid_t) }
let totalFootprint = stats.filter { alive.contains($0.key) }.values.reduce(UInt64(0)) { $0 + $1.previous.footprint }
let output: [String: Any] = [
    "label": label,
    "rootPid": root,
    "processCount": alive.count,
    "totalFootprintMiB": Double(totalFootprint) / 1_048_576,
    "intervalSeconds": interval,
    "actualSeconds": actualSeconds,
    "sampleCount": sampleCount,
    "aggregate": ["appPeakFootprintMiB": aggregatePeaks["app"]!, "browserPeakFootprintMiB": aggregatePeaks["browser"]!,
                  "yardletPeakFootprintMiB": aggregatePeaks["yardlet"]!],
    "processes": processes
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
