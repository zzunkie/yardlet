import Foundation

/// One model request a transcript recorded, as the harness counted its tokens.
struct TokenUsageRequest: Equatable, Sendable {
    var harness: HarnessKind
    var date: Date
    var model: String
    /// The provider's session (Claude Code's `sessionId`, Codex's thread id).
    var session: String
    /// The folder the session worked in.
    var folder: String
    var freshInput: Int64 = 0
    var cacheWrite: Int64 = 0
    /// Claude's 1-hour cache writes, priced apart from its 5-minute ones.
    var longCacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var fast = false
    var usOnly = false
    /// Claude writes one line per content block of a response, each with the response's usage and an
    /// output that grows to its final count; the id counts the response once.
    var messageID: String?

    /// Every input token of the request, which a long-prompt price is decided by.
    var prompt: Int64 { freshInput + cacheWrite + longCacheWrite + cacheRead }
}

/// The lines of a transcript file not read yet: whole lines only, the rest left for the next read.
enum TokenUsageLines {
    /// The complete lines in `data` and how many bytes they took.
    static func complete(_ data: Data) -> (lines: [Data], consumed: Int) {
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(data[start..<newline]) }
            start = data.index(after: newline)
        }
        return (lines, start - data.startIndex)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? isoWithFraction.parse(text)) ?? (try? iso.parse(text))
    }

    static func int(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
        line.withUnsafeBytes { buffer in
            guard buffer.count >= needle.count else { return false }
            return memmem(buffer.baseAddress, buffer.count, needle, needle.count) != nil
        }
    }
}

/// Claude Code's transcripts (`~/.claude/projects/<folder>/<session>.jsonl` and its subagents'):
/// each `assistant` line's `message.usage`.
enum ClaudeUsageReader {
    private static let usageKey = Array(#""usage""#.utf8)
    private static let assistantKey = Array(#""assistant""#.utf8)

    static func requests(in lines: [Data]) -> [TokenUsageRequest] {
        lines.compactMap { line in
            // Most lines are messages, tool results and progress; only an assistant's carries usage.
            guard TokenUsageLines.contains(line, usageKey), TokenUsageLines.contains(line, assistantKey),
                  let object = TokenUsageLines.object(line) else { return nil }
            return request(object)
        }
    }

    static func request(_ object: [String: Any]) -> TokenUsageRequest? {
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let date = TokenUsageLines.date(object["timestamp"]) else { return nil }
        let writes = TokenUsageLines.int(usage["cache_creation_input_tokens"])
        let split = usage["cache_creation"] as? [String: Any]
        let longWrites = TokenUsageLines.int(split?["ephemeral_1h_input_tokens"])
        return TokenUsageRequest(
            harness: .claudeCode, date: date, model: model,
            session: object["sessionId"] as? String ?? "", folder: object["cwd"] as? String ?? "",
            freshInput: TokenUsageLines.int(usage["input_tokens"]), cacheWrite: max(0, writes - longWrites),
            longCacheWrite: min(longWrites, writes), cacheRead: TokenUsageLines.int(usage["cache_read_input_tokens"]),
            output: TokenUsageLines.int(usage["output_tokens"]),
            fast: usage["speed"] as? String == "fast", usOnly: usage["inference_geo"] as? String == "us",
            messageID: message["id"] as? String ?? object["requestId"] as? String)
    }
}

/// Codex's rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): the running totals each
/// `token_count` event carries, as the difference from the one before. A subagent's rollout first
/// replays its parent's history up to `subagent_history_start_ordinal`; nothing there is counted.
enum CodexUsageReader {
    /// What a rollout said before the lines being read: its session, folder and model, and the totals
    /// its last count gave.
    struct Carry: Codable, Equatable, Sendable {
        var session = ""
        var folder = ""
        var model = ""
        var historyStart: Int?
        var hasMeta = false
        var totals: Totals?
    }

    struct Totals: Codable, Equatable, Sendable {
        var input: Int64
        var cached: Int64
        var written: Int64
        var output: Int64

        init(_ value: [String: Any]) {
            input = TokenUsageLines.int(value["input_tokens"])
            cached = TokenUsageLines.int(value["cached_input_tokens"])
            written = TokenUsageLines.int(value["cache_write_input_tokens"])
            output = TokenUsageLines.int(value["output_tokens"])
        }

        init(input: Int64, cached: Int64, written: Int64, output: Int64) {
            (self.input, self.cached, self.written, self.output) = (input, cached, written, output)
        }

        func minus(_ other: Totals) -> Totals? {
            let difference = Totals(input: input - other.input, cached: cached - other.cached,
                                    written: written - other.written, output: output - other.output)
            return [difference.input, difference.cached, difference.written, difference.output].allSatisfy { $0 >= 0 }
                ? difference : nil
        }
    }

    private static let keys = [#""session_meta""#, #""turn_context""#, #""token_count""#].map { Array($0.utf8) }

    static func requests(in lines: [Data], carry: inout Carry) -> [TokenUsageRequest] {
        var requests: [TokenUsageRequest] = []
        for line in lines {
            guard keys.contains(where: { TokenUsageLines.contains(line, $0) }),
                  let object = TokenUsageLines.object(line),
                  let payload = object["payload"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "session_meta":
                // A replayed parent's meta follows the rollout's own; only the first is this session.
                guard !carry.hasMeta else { continue }
                carry.hasMeta = true
                carry.session = payload["id"] as? String ?? payload["session_id"] as? String ?? ""
                carry.folder = payload["cwd"] as? String ?? ""
                carry.historyStart = (payload["subagent_history_start_ordinal"] as? NSNumber)?.intValue
            case "turn_context":
                if let model = payload["model"] as? String { carry.model = model }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { continue }
                let totals = Totals(total)
                let replayed = (object["ordinal"] as? NSNumber).map { $0.intValue < (carry.historyStart ?? 0) } ?? false
                defer { carry.totals = totals }
                guard !replayed, totals != carry.totals, let date = TokenUsageLines.date(object["timestamp"]) else {
                    continue
                }
                // A count that went back (a compacted or restarted thread) starts over from its last request.
                let last = (info["last_token_usage"] as? [String: Any]).map(Totals.init)
                guard let used = carry.totals.flatMap(totals.minus) ?? last ?? (carry.totals == nil ? totals : nil),
                      used.input + used.output > 0 else { continue }
                requests.append(TokenUsageRequest(
                    harness: .codex, date: date, model: carry.model, session: carry.session, folder: carry.folder,
                    freshInput: max(0, used.input - used.cached - used.written), cacheWrite: used.written,
                    cacheRead: used.cached, output: used.output))
            default:
                continue
            }
        }
        return requests
    }
}
