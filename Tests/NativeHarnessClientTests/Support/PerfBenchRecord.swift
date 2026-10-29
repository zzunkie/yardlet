import Foundation

/// What a benchmark run with `NHC_PERF_BENCH=1` leaves for the performance bench (`scripts/perf-bench/run.sh`,
/// docs/PERFORMANCE_BENCH.md): with `NHC_PERF_BENCH_OUTPUT` set, one JSON line a measurement,
/// `{"name": …, "metrics": {…}}`, beside the lines the benchmark prints. Every metric is a cost, so a larger
/// value is worse, and its name ends in its unit: `Ms`, `Percent`, `MiB`, `PerSecond` or `Count`.
enum PerfBenchRecord {
    static func write(_ name: String, _ metrics: [String: Double]) {
        guard let path = ProcessInfo.processInfo.environment["NHC_PERF_BENCH_OUTPUT"], !path.isEmpty,
              var line = try? JSONSerialization.data(withJSONObject: ["name": name, "metrics": metrics],
                                                     options: [.sortedKeys]) else { return }
        line.append(10)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
