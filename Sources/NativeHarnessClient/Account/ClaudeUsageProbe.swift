import Foundation

/// Reads a Claude subscription's plan limits the way Claude Code's own usage screen does: the
/// official CLI answers a `get_usage` control request with its own login. No model request is
/// sent, no conversation is written, and Yardlet never handles a credential.
enum ClaudeUsageProbe {
    static func read(
        executableURL: URL,
        environment: [String: String],
        timeout: Duration = .seconds(20)
    ) async throws -> [AccountUsageMetric]? {
        try await Task.detached(priority: .utility) {
            // An empty private folder keeps the probe out of every project's settings and history.
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Yardlet-ClaudeUsage-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }

            let process = Process()
            let input = Pipe.childInput()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                 "--verbose", "--strict-mcp-config"]
            process.currentDirectoryURL = folder
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var values = RuntimeProcessEnvironment.values(executableURL: executableURL,
                overrides: ["NO_COLOR": "1"].merging(environment) { _, new in new })
            // The CLI counts the usage endpoint as nonessential traffic.
            values.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
            process.environment = values
            try process.run()

            let timeoutTask = Task {
                do { try await Task.sleep(for: timeout) } catch { return false }
                guard process.isRunning else { return false }
                NativeProcessTree.terminate(process: process)
                return true
            }
            defer {
                timeoutTask.cancel()
                try? input.fileHandleForWriting.close()
                if process.isRunning { NativeProcessTree.terminate(process: process) }
                process.waitUntilExit()
            }
            for (id, request) in [("init", #"{"subtype":"initialize"}"#),
                                  ("usage", #"{"subtype":"get_usage","skip_behaviors":true}"#)] {
                let line = #"{"type":"control_request","request_id":"\#(id)","request":\#(request)}"# + "\n"
                try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            }

            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                guard buffer.count <= 4 * 1_048_576 else { break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                          value["type"]?.stringValue == "control_response",
                          value["response"]?["request_id"]?.stringValue == "usage" else { continue }
                    guard value["response"]?["subtype"]?.stringValue == "success" else { return nil }
                    return usage(from: value["response"]?["response"])
                }
            }
            if await timeoutTask.value { throw AccountCommandError.timedOut }
            return nil
        }.value
    }

    /// Projects the CLI's `limits` rows, or its older `five_hour`/`seven_day` objects when the
    /// rows are absent. A login without plan limits (an API key, for example) reports none.
    static func usage(from response: JSONValue?) -> [AccountUsageMetric]? {
        guard let response, response["rate_limits_available"]?.boolValue != false,
              let limits = response["rate_limits"], limits.objectValue != nil else { return nil }
        var metrics: [AccountUsageMetric] = []
        if let rows = limits["limits"]?.arrayValue, !rows.isEmpty {
            for row in rows {
                guard let kind = row["kind"]?.stringValue,
                      let minutes = windowMinutes(group: row["group"]?.stringValue),
                      let percent = row["percent"]?.doubleValue else { continue }
                let model = row["scope"]?["model"]?["display_name"]?.stringValue
                metrics.append(metric(id: "claude:\(kind):\(model ?? "")", model: model, minutes: minutes,
                    percent: percent, resetsAt: row["resets_at"]?.stringValue))
            }
        } else {
            for (key, minutes) in [("five_hour", 300.0), ("seven_day", 10_080.0)] {
                guard let percent = limits[key]?["utilization"]?.doubleValue else { continue }
                metrics.append(metric(id: "claude:\(key):", model: nil, minutes: minutes, percent: percent,
                    resetsAt: limits[key]?["resets_at"]?.stringValue))
            }
            for row in limits["model_scoped"]?.arrayValue ?? [] {
                guard let model = row["display_name"]?.stringValue,
                      let percent = row["utilization"]?.doubleValue else { continue }
                metrics.append(metric(id: "claude:model:\(model)", model: model, minutes: 10_080, percent: percent,
                    resetsAt: row["resets_at"]?.stringValue))
            }
        }
        return metrics
    }

    private static func windowMinutes(group: String?) -> Double? {
        switch group {
        case "session": 300
        case "weekly": 10_080
        default: nil
        }
    }

    private static func metric(id: String, model: String?, minutes: Double, percent: Double,
                               resetsAt: String?) -> AccountUsageMetric {
        metric(id: id, model: model, minutes: minutes, percent: percent, resetsAt: resetsAt.flatMap(date))
    }

    private static func metric(id: String, model: String?, minutes: Double, percent: Double,
                               resetsAt: Date?) -> AccountUsageMetric {
        let used = min(100, max(0, percent.isFinite ? percent : 0))
        return AccountUsageMetric(id: id, label: AccountLimitWindow.accountName(minutes: minutes, model: model),
            usedFraction: used / 100, detail: L10n.format("%.0f%% remaining", 100 - used),
            resetsAt: resetsAt, evidence: .exactQuota, windowMinutes: minutes, model: model)
    }

    /// An account's limits after a session reported its plan limits on the stream. Each window
    /// the report measured replaces the row a check produced for it, so the account list follows
    /// the session between checks; a window the account has no row for yet gets one. A refused
    /// window the report gave no figure for is full.
    static func usage(_ metrics: [AccountUsageMetric], updatedBy limit: HarnessRateLimit) -> [AccountUsageMetric] {
        var updated = metrics
        for reading in limit.measuredWindows {
            guard let minutes = reading.window.minutes else { continue }
            let kind = switch reading.window {
            case .session: "session"
            case .weekly: "weekly_all"
            case .model, .overage: "weekly_scoped"
            }
            let index = updated.firstIndex { reads(reading, $0.id) }
            let row = metric(id: index.map { updated[$0].id } ?? "claude:\(kind):\(reading.model ?? "")",
                model: reading.model, minutes: minutes, percent: reading.usedFraction * 100,
                resetsAt: reading.resetsAt ?? index.flatMap { updated[$0].resetsAt })
            if let index { updated[index] = row } else { updated.append(row) }
        }
        return updated
    }

    /// Whether a row a check produced is the window a stream report measured. Rows keep the
    /// check's `claude:<kind>:<model>` id, in the current `limits` names or the older ones.
    private static func reads(_ reading: HarnessRateLimit.WindowUsage, _ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "claude" else { return false }
        switch reading.window {
        case .session: return ["session", "five_hour"].contains(parts[1])
        case .weekly: return ["weekly_all", "seven_day"].contains(parts[1])
        case .model:
            return ["weekly_scoped", "model"].contains(parts[1])
                && reading.model?.caseInsensitiveCompare(parts[2]) == .orderedSame
        case .overage: return false
        }
    }

    /// The CLI writes microsecond timestamps, which the ISO 8601 formatter does not accept.
    static func date(_ value: String) -> Date? {
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
