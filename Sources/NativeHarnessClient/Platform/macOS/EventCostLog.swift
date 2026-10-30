#if DEBUG
import Darwin

/// The main thread's time for each provider event the app handles, by kind: a Codex task's streamed
/// state, a transcript publication, and a subagent's Codex state or event. The performance bench
/// (`PerfBenchFixture`, docs/PERFORMANCE_BENCH.md) turns it on and holds each kind to a budget; otherwise it
/// records nothing. Product builds never compile it.
@MainActor
enum EventCostLog {
    enum Kind: String, CaseIterable {
        case codexState, transcriptPublication, agentRunState, agentRunEvent
    }

    static var isEnabled = false
    private static var durations: [Kind: [Double]] = [:]
    private static var cpuDurations: [Kind: [Double]] = [:]

    struct Start {
        fileprivate let wall: UInt64
        fileprivate let cpu: UInt64
    }

    /// A start for `record`, or nil while the log is off.
    static func start() -> Start? {
        guard isEnabled else { return nil }
        return Start(wall: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
    }

    /// The wall-clock time since `start`, which includes waiting for a busy Mac's cores, and the
    /// thread's own CPU time, which does not.
    static func record(_ kind: Kind, since start: Start?) {
        guard let start else { return }
        durations[kind, default: []].append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start.wall) / 1_000_000)
        cpuDurations[kind, default: []].append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start.cpu) / 1_000_000)
    }

    static func reset() {
        durations.removeAll(keepingCapacity: true)
        cpuDurations.removeAll(keepingCapacity: true)
    }

    /// Each kind seen since the last reset: how many, their median, 95th percentile and longest wall-clock
    /// time, and the same of the thread's CPU time.
    static func summary() -> [String: Any] {
        func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        var result: [String: Any] = [:]
        for (kind, values) in durations where !values.isEmpty {
            let wall = values.sorted(), cpu = (cpuDurations[kind] ?? []).sorted()
            result[kind.rawValue] = [
                "events": wall.count,
                "medianMs": round(percentile(wall, 0.5)), "p95Ms": round(percentile(wall, 0.95)), "maxMs": round(wall.last ?? 0),
                "cpuMedianMs": round(percentile(cpu, 0.5)), "cpuP95Ms": round(percentile(cpu, 0.95)), "cpuMaxMs": round(cpu.last ?? 0),
                "cpuTotalMs": round(cpu.reduce(0, +))
            ] as [String: Any]
        }
        return result
    }
}
#endif
