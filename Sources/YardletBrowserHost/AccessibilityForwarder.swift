import Foundation
import YardletCEFAccessibility

/// Sends CEF's accessibility changes to Yardlet in the contract's smaller shape. Parsing and
/// trimming a large page's tree takes hundreds of milliseconds, so it runs on its own serial queue
/// instead of CEF's UI thread; the queue keeps tree and location changes in order.
final class AccessibilityForwarder: @unchecked Sendable {
    struct Statistics {
        var treeChanges = 0
        var locationBatches = 0
        var rawBytes = 0
        var sentBytes = 0
        var largestRawBytes = 0
        var largestSentBytes = 0
        var reduceMilliseconds = 0.0
        var slowestReduceMilliseconds = 0.0
    }

    private let output: EventOutput
    private let recordPath: String
    private let queue = DispatchQueue(label: "com.zzunkie.yardlet.browser-host.accessibility", qos: .userInitiated)
    // Owned by `queue`.
    /// Location changes come in bursts (animations), so they are merged per node and sent at most
    /// every 100 ms; a tree change first sends the waiting ones.
    private var pendingLocations: [Int: [String: [String: Any]]] = [:]
    private var flushScheduled = false
    private var recorded = 0
    private var currentStatistics = Statistics()

    init(output: EventOutput, recordPath: String) {
        self.output = output
        self.recordPath = recordPath
    }

    var statistics: Statistics { queue.sync { currentStatistics } }

    func receive(tab: Int, kind: Int32, json: Data) {
        queue.async { self.process(tab: tab, kind: kind, json: json) }
    }

    func forget(tab: Int) {
        queue.async { self.pendingLocations[tab] = nil }
    }

    private func process(tab: Int, kind: Int32, json: Data) {
#if DEBUG
        record(tab: tab, kind: kind, json: json)
#endif
        let started = DispatchTime.now().uptimeNanoseconds
        guard let value = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else { return }
        guard kind == 0 else {
            var pending = pendingLocations[tab] ?? [:]
            for change in CEFAccessibilityReducer.locationChanges(value) {
                pending["\(change["tree"] ?? "")/\(change["id"] ?? "")"] = change
            }
            guard !pending.isEmpty else { return }
            pendingLocations[tab] = pending
            if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 0.1) {
                    self.flushScheduled = false
                    for tab in Array(self.pendingLocations.keys) { self.flushLocations(tab: tab) }
                }
            }
            return
        }
        flushLocations(tab: tab)
        guard let change = CEFAccessibilityReducer.treeChange(value) else { return }
        let event: [String: Any] = ["accessibilityTree": ["tab": tab, "change": change]]
        let sent = output.write(event)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        currentStatistics.treeChanges += 1
        currentStatistics.rawBytes += json.count
        currentStatistics.sentBytes += sent
        currentStatistics.largestRawBytes = max(currentStatistics.largestRawBytes, json.count)
        currentStatistics.largestSentBytes = max(currentStatistics.largestSentBytes, sent)
        currentStatistics.reduceMilliseconds += elapsed
        currentStatistics.slowestReduceMilliseconds = max(currentStatistics.slowestReduceMilliseconds, elapsed)
        if json.count > 100_000 {
            HostLog.write(String(format: "accessibility tree change tab=%d raw=%d sent=%d reduceMs=%.1f", tab, json.count,
                                 sent, elapsed))
        }
    }

    private func flushLocations(tab: Int) {
        guard let pending = pendingLocations.removeValue(forKey: tab), !pending.isEmpty else { return }
        currentStatistics.locationBatches += 1
        output.write(["accessibilityLocations": ["tab": tab, "changes": Array(pending.values)]])
    }

#if DEBUG
    private func record(tab: Int, kind: Int32, json: Data) {
        guard !recordPath.isEmpty else { return }
        let directory = URL(filePath: recordPath, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recorded += 1
        let name = String(format: "%05d-tab%d-%@.json", recorded, tab, kind == 0 ? "tree" : "location")
        try? json.write(to: directory.appending(path: name))
    }
#endif
}
