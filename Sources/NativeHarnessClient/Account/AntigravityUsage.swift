import Foundation

/// Antigravity CLI's plan limits as `agy --print /usage --output-format json` reports them: the
/// models share a limit by group ("Gemini Models", "Claude and GPT models"), and each group lists
/// its buckets with the share left and when it refills. The CLI answers this without a model turn
/// and leaves no conversation behind. One row per bucket, named by its group without the word
/// "models" ("Gemini · 7 day limit"), so the row leaves the account its room.
enum AntigravityUsage {
    static let arguments = ["--print", "/usage", "--output-format", "json"]

    /// The rows in `output`, or nil when it holds no successful `/usage` answer.
    static func metrics(fromOutput output: String) -> [AccountUsageMetric]? {
        guard let value = answer(in: output), value["status"]?.stringValue == "SUCCESS",
              let groups = value["command"]?["data"]?["groups"]?.arrayValue else { return nil }
        let rows = groups.flatMap { group -> [AccountUsageMetric] in
            let name = group["name"]?.stringValue.map(shortName)
            return (group["buckets"]?.arrayValue ?? []).compactMap { bucket in
                guard let id = bucket["id"]?.stringValue,
                      let remaining = bucket["remaining_fraction"]?.doubleValue, remaining.isFinite else { return nil }
                let left = min(max(remaining, 0), 1)
                let minutes = windowMinutes(bucket["window"]?.stringValue)
                    ?? windowMinutes(id.split(separator: "-").last.map(String.init))
                let window = HarnessAccountBroker.usageWindowLabel(
                    minutes: minutes, fallback: bucket["name"]?.stringValue ?? L10n.string("Usage"))
                return AccountUsageMetric(
                    id: "antigravity:\(id)", label: name.map { "\($0) · \(window)" } ?? window,
                    usedFraction: 1 - left, detail: L10n.format("%.0f%% remaining", left * 100),
                    resetsAt: bucket["reset_time"]?.stringValue.flatMap(date), evidence: .exactQuota,
                    windowMinutes: minutes)
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// The JSON answer: the output itself, or its last line that is one (a notice may come first).
    private static func answer(in output: String) -> JSONValue? {
        let decode = { (text: Substring) in try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        if let whole = decode(Substring(output.trimmingCharacters(in: .whitespacesAndNewlines))) { return whole }
        return output.split(whereSeparator: \.isNewline).reversed()
            .first { $0.hasPrefix("{") }.flatMap(decode)
    }

    private static func shortName(_ group: String) -> String {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasSuffix(" models") else { return trimmed }
        return String(trimmed.dropLast(" models".count))
    }

    /// A window's length from a word that names it: "weekly", "daily", or a count and a unit ("5h",
    /// "7d"). A bucket's `window` is one, and so is the end of its ID ("gemini-weekly", "gemini-5h"),
    /// which is read when the `window` is not.
    private static func windowMinutes(_ window: String?) -> Double? {
        guard let window = window?.lowercased() else { return nil }
        switch window {
        case "weekly": return 10_080
        case "daily": return 1_440
        default: break
        }
        guard let count = Int(window.dropLast()), count > 0 else { return nil }
        switch window.last {
        case "h": return Double(count) * 60
        case "d": return Double(count) * 1_440
        default: return nil
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
