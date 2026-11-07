import Darwin
import Foundation

// Read-only process sampler. No command arguments, environment, or conversation text are emitted.
// Compile with swiftc -O; observe <app bundle> <seconds> [interval seconds] emits JSON lines.
// Each snapshot drains Foundation's autoreleased bridge objects before sleeping, as an app's run loop
// would. Keep only the live process identities and the previous counters, never the sample history.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let duration = Double(arguments[1]), duration.isFinite, duration > 0,
      arguments.count < 3 || Double(arguments[2]).map({ $0.isFinite && $0 > 0 }) == true else {
    FileHandle.standardError.write(Data("usage: observe <app bundle> <seconds> [interval seconds]\n".utf8))
    exit(2)
}
let interval = arguments.count > 2 ? Double(arguments[2])! : 5
let app = URL(filePath: arguments[0]).standardizedFileURL.path + "/"
let deadline = Date().addingTimeInterval(duration)
let mainPath = app + "Contents/MacOS/Yardlet"
let ownUID = getuid()
typealias Responsible = @convention(c) (pid_t) -> pid_t
let responsible = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")!, to: Responsible.self)
struct Identity: Hashable { let pid: pid_t; let start: UInt64 }
struct Reading { let cpu: UInt64; let footprint: UInt64 }
struct Member { let identity: Identity; let name: String; let category: String; let reading: Reading }

func path(_ pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &bytes, UInt32(bytes.count))
    return n > 0 ? String(decoding: bytes.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
}
func args(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
    return bytes[4..<size].split(separator: 0, omittingEmptySubsequences: true).prefix(5).map { String(decoding: $0, as: UTF8.self) }
}
func reading(_ pid: pid_t) -> Reading? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Reading(cpu: info.ri_user_time + info.ri_system_time, footprint: info.ri_phys_footprint) : nil
}
func cpuSeconds() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
// Verify the time unit against getrusage rather than assume a machine's timebase.
let rawBefore = reading(getpid())!.cpu, cpuBefore = cpuSeconds()
let calibrationEnd = ProcessInfo.processInfo.systemUptime + 0.03
while ProcessInfo.processInfo.systemUptime < calibrationEnd { _ = getpid() }
let cpuAfter = cpuSeconds(), rawAfter = reading(getpid())!.cpu
var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
let observedMultiplier = (cpuAfter - cpuBefore) * 1e9 / Double(rawAfter - rawBefore)
let candidates = [1.0, Double(timebase.numer) / Double(timebase.denom)]
let multiplier = candidates.min(by: { abs($0 - observedMultiplier) < abs($1 - observedMultiplier) })!
guard abs(multiplier - observedMultiplier) / multiplier < 0.2 else { fatalError("CPU unit calibration failed") }

var categoryCache: [Identity: (String, String, pid_t)] = [:]
func members() -> [Member] {
    let count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var result: [Member] = []; var alive = Set<Identity>()
    for pid in pids.prefix(max(Int(n), 0)) where pid > 0 {
        var b = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout.size(ofValue: b))) == MemoryLayout.size(ofValue: b), b.pbi_uid == ownUID,
              let executable = path(pid), let r = reading(pid) else { continue }
        let key = Identity(pid: pid, start: b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec)
        alive.insert(key)
        let name = (executable as NSString).lastPathComponent
        let charged = responsible(pid)
        var category: String
        if let cached = categoryCache[key], cached.0 == executable, cached.2 == charged { category = cached.1 }
        else {
            let tied = executable.hasPrefix(app) || (charged != pid && path(charged)?.hasPrefix(app) == true)
            if executable == mainPath { category = "yardletMain" }
            else if executable.hasPrefix(app + "Contents/Frameworks/Yardlet Browser Host.app/") { category = "yardletBrowser" }
            else if executable.hasPrefix(app) { category = "yardletHelpers" }
            else if tied {
                let tokens = args(pid).map { ($0 as NSString).lastPathComponent.lowercased() }
                let agentNames: Set<String> = ["claude", "codex", "codex-code-mode-host", "agy", "antigravity", "kimi", "opencode", "hermes", "grok"]
                if agentNames.contains(name.lowercased()) || tokens.contains(where: { agentNames.contains($0) }) || executable.contains("/runtimes/claude/") || executable.contains("/runtimes/codex/") { category = "agents" }
                else { category = "yardletAttributedOther" }
            } else { category = "otherUserProcesses" }
            categoryCache[key] = (executable, category, charged)
        }
        if pid == getpid() { category = "observer" }
        result.append(Member(identity: key, name: name, category: category, reading: r))
    }
    categoryCache = categoryCache.filter { alive.contains($0.key) }
    return result
}
func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
func output(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
output(["kind": "samplerStarted", "pid": getpid(), "cpuUnitMultiplier": multiplier, "calibrationObservedMultiplier": observedMultiplier,
        "intervalSeconds": interval, "at": formatter.string(from: Date()), "cpuPercentBasis": "100 percent = one CPU core; first observation has no CPU delta"])
var previous: [Identity: Reading] = [:]
var previousTime = Date(); var index = 0
while Date() < deadline {
    let delay = autoreleasepool { () -> Double in
    let began = Date(), ownBefore = cpuSeconds()
    let elapsed = began.timeIntervalSince(previousTime)
    let current = members()
    var categories: [String: [String: Double]] = [:]
    var rows: [[String: Any]] = []; var next: [Identity: Reading] = [:]
    var mains: [[String: Any]] = []
    for m in current {
        let old = previous[m.identity]
        let delta = old.flatMap { m.reading.cpu >= $0.cpu ? m.reading.cpu - $0.cpu : nil }
        let cpu = delta.map { Double($0) * multiplier / 1e9 / max(elapsed, 0.001) * 100 } ?? 0
        let memory = Double(m.reading.footprint) / 1_048_576
        var total = categories[m.category] ?? ["count": 0, "cpuPercent": 0, "footprintMiB": 0, "unbaselinedCPUCount": 0]
        total["count", default: 0] += 1; total["cpuPercent", default: 0] += cpu; total["footprintMiB", default: 0] += memory
        if delta == nil { total["unbaselinedCPUCount", default: 0] += 1 }
        categories[m.category] = total; next[m.identity] = m.reading
        let row: [String: Any] = ["pid": m.identity.pid, "startEpochUs": m.identity.start, "name": m.name, "category": m.category,
                                 "cpuPercent": round3(cpu), "footprintMiB": round3(memory), "cpuBaselined": delta != nil]
        rows.append(row)
        if m.category == "yardletMain" { mains.append(row) }
    }
    let sorted = rows.sorted { ($0["cpuPercent"] as! Double) > ($1["cpuPercent"] as! Double) }
    var loads = [Double](repeating: 0, count: 3); getloadavg(&loads, 3)
    let snapshotCPU = (cpuSeconds() - ownBefore) * 1000
    var object: [String: Any] = ["kind": "sample", "at": formatter.string(from: began), "epoch": began.timeIntervalSince1970,
        "intervalSeconds": round3(elapsed), "gap": index > 0 && elapsed > interval * 3,
        "categories": categories.mapValues { $0.mapValues(round3) }, "mainProcesses": mains,
        "loadAverage": loads, "collectionWallMs": round3(Date().timeIntervalSince(began) * 1000), "collectionCPUMs": round3(snapshotCPU)]
    if index % 12 == 0 {
        object["processes"] = rows.filter { ($0["category"] as! String) != "otherUserProcesses" }
        object["topOtherProcesses"] = Array(sorted.filter { ($0["category"] as! String) == "otherUserProcesses" }.prefix(10))
    }
    output(object); previous = next; previousTime = began; index += 1
    return max(0, interval - Date().timeIntervalSince(began))
    }
    Thread.sleep(forTimeInterval: max(0, min(delay, deadline.timeIntervalSinceNow)))
}
output(["kind": "samplerFinished", "at": formatter.string(from: Date()), "sampleCount": index])
