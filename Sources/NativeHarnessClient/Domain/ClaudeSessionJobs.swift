import Foundation

/// The jobs Claude Code keeps for a session in its process alone (CLI 2.1.299): a
/// `CronCreate` job that is not `durable`, which `/loop` with an interval makes too, and the next
/// `ScheduleWakeup` of a `/loop` without one. They fire only while the CLI runs and is idle, so a
/// restart that ends the CLI stops them until it runs again.
///
/// Resuming the conversation (`--resume`, print mode included) brings the `CronCreate` jobs back
/// (`xi`/`Mi`): the CLI reads the records it resumes, from its last compaction on, and keeps each
/// `CronCreate` call whose result names a job that is not durable and no `CronDelete` call or
/// compaction note ended. The note a compaction writes (`session_cron_carry`, its last one) carries the
/// jobs made before it. A recurring job comes back until a week after it was made
/// (`recurringMaxAgeMs`), counted from its call's record, and runs on from the resume without
/// catching up on the runs it missed; a one-shot job only while its time has not passed. A wakeup
/// only a background session's takeover re-arms, never a plain resume: it lives in the process that
/// armed it.
///
/// The CLI announces none of this on its stream and answers no request for it. What a running CLI
/// holds is read from the same records it writes as it goes, by the same rule (`held`).
enum ClaudeSessionJobs {
    /// A recurring job's lifetime, from when it was made (`recurringMaxAgeMs`, 604,800,000 ms).
    static let recurringMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// The tools that make, end or list a session job; a turn that called one changes what the CLI holds.
    static let toolNames: Set<String> = ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"]
    /// The words a transcript holds only where a session job was made, carried over, armed or fired: a
    /// job's result, a compaction's note, a wakeup's result, a fired job's prompt. Bytes without any
    /// hold no job.
    static let markers = [#""humanSchedule""#, #""session_cron_carry""#, #""clampedDelaySeconds""#,
                          #""turnOrigin":"scheduled""#].map { Data($0.utf8) }

    /// The jobs the CLI brings back on resuming a conversation whose resumed records, oldest first,
    /// are `records`, at `now`.
    static func broughtBack(from records: [JSONValue], now: Date) -> [ClaudeSessionJob] {
        held(in: records, now: now, runningSince: nil)
    }

    /// The jobs a CLI running since `runningSince` holds, by the records of its conversation: those a
    /// resume brings back, which are those it made since, and the wakeup it armed since that has not
    /// fired, been stopped or been cancelled by the person stopping a turn. With no running CLI
    /// (`runningSince` nil), what a resume brings back.
    static func held(in records: [JSONValue], now: Date, runningSince: Date?) -> [ClaudeSessionJob] {
        var calls: [(toolUseID: String, cron: String?, prompt: String?, createdAt: Date?)] = []
        var results: [String: JSONValue] = [:]
        var reported: [String: Date] = [:]
        var ended = Set<String>()
        var carried: [JSONValue] = []
        var wakeup: (toolUseID: String, prompt: String?, createdAt: Date?)?
        for record in records {
            switch record["type"]?.stringValue {
            case "assistant":
                guard let blocks = record["message"]?["content"]?.arrayValue else { continue }
                let createdAt = record["timestamp"]?.stringValue.flatMap(ClaudeSubagentTranscriptReader.timestamp)
                for block in blocks where block["type"]?.stringValue == "tool_use" {
                    let input = block["input"]
                    guard let id = block["id"]?.stringValue else { continue }
                    switch block["name"]?.stringValue {
                    case "CronCreate": calls.append((id, input?["cron"]?.stringValue, input?["prompt"]?.stringValue, createdAt))
                    case "CronDelete": if let job = input?["id"]?.stringValue { ended.insert(job) }
                    // Each call takes the place of the wakeup armed before it (`y` in `C`).
                    case "ScheduleWakeup": wakeup = (id, input?["prompt"]?.stringValue, createdAt)
                    default: break
                    }
                }
            case "user":
                // Stopping a turn cancels the pending wakeup (`TQn`); the CLI notes the stop as below.
                if Self.isTurnStop(record) { wakeup = nil }
                // The CLI keeps a call's typed result beside the message that answers it.
                guard let blocks = record["message"]?["content"]?.arrayValue, let result = record["toolUseResult"],
                      result.objectValue != nil else { continue }
                for block in blocks where block["type"]?.stringValue == "tool_result" && block["is_error"]?.boolValue != true {
                    if let id = block["tool_use_id"]?.stringValue { results[id] = result }
                }
                // What the CLI says of a job's next run, as it made or listed it.
                if let id = result["id"]?.stringValue, let next = result["nextFireAt"]?.doubleValue {
                    reported[id] = Date(timeIntervalSince1970: next / 1_000)
                }
                for job in result["jobs"]?.arrayValue ?? [] {
                    if let id = job["id"]?.stringValue, let next = job["nextFireAt"]?.doubleValue {
                        reported[id] = Date(timeIntervalSince1970: next / 1_000)
                    }
                }
            case "attachment" where record["attachment"]?["type"]?.stringValue == "session_cron_carry":
                carried = record["attachment"]?["tasks"]?.arrayValue ?? []
                for id in record["attachment"]?["ended"]?.arrayValue ?? [] { if let id = id.stringValue { ended.insert(id) } }
            default:
                break
            }
        }
        for task in carried {
            guard let id = task["id"]?.stringValue, !id.isEmpty, let cron = task["cron"]?.stringValue,
                  let prompt = task["prompt"]?.stringValue, let createdAt = task["createdAt"]?.doubleValue,
                  let recurring = task["recurring"]?.boolValue else { continue }
            let key = "carried:\(id)"
            calls.append((key, cron, prompt, Date(timeIntervalSince1970: createdAt / 1_000)))
            results[key] = .object(["id": .string(id), "recurring": .bool(recurring), "durable": .bool(false)])
        }
        var jobs: [ClaudeSessionJob] = []
        for call in calls {
            guard let result = results[call.toolUseID], let id = result["id"]?.stringValue,
                  result["durable"]?.boolValue != true, !ended.contains(id),
                  let cron = call.cron, let prompt = call.prompt, !jobs.contains(where: { $0.id == id }) else { continue }
            let recurring = result["recurring"]?.boolValue != false
            if recurring {
                // A call saved without a time is kept, as the CLI's comparison with no time keeps it.
                if let createdAt = call.createdAt, now.timeIntervalSince(createdAt) >= recurringMaxAge { continue }
            } else {
                guard let createdAt = call.createdAt,
                      let fire = ClaudeCron(cron)?.oneShotFire(after: createdAt, jobID: id), fire >= now else { continue }
            }
            jobs.append(ClaudeSessionJob(id: id, kind: recurring ? .recurring : .once, cron: cron,
                                         schedule: result["humanSchedule"]?.stringValue, prompt: prompt,
                                         createdAt: call.createdAt, reportedRun: reported[id]))
        }
        if let runningSince, let wakeup, let createdAt = wakeup.createdAt, createdAt >= runningSince,
           let result = results[wakeup.toolUseID], result["stopped"]?.boolValue != true,
           let scheduledFor = result["scheduledFor"]?.doubleValue, scheduledFor > 0 {
            let run = Date(timeIntervalSince1970: scheduledFor / 1_000)
            if run > now {
                jobs.append(ClaudeSessionJob(id: wakeup.toolUseID, kind: .wakeup, cron: nil, schedule: nil,
                                             prompt: wakeup.prompt ?? "", createdAt: createdAt, reportedRun: run))
            }
        }
        return jobs
    }

    /// The note Claude Code saves where the person stopped a turn: "[Request interrupted by user]",
    /// or "… for tool use]".
    private static func isTurnStop(_ record: JSONValue) -> Bool {
        let content = record["message"]?["content"]
        let texts = content?.stringValue.map { [$0] }
            ?? (content?.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        return texts.contains { $0.hasPrefix("[Request interrupted by user") }
    }
}

/// A session job a task's CLI holds, as the task's rail and the scheduled tasks list show it.
struct ClaudeSessionJob: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case recurring
        case once
        /// The next wakeup of a `/loop` without an interval (`ScheduleWakeup`).
        case wakeup
    }

    /// The job's ID (`CronCreate`'s), or the call that armed a wakeup.
    let id: String
    let kind: Kind
    /// A `CronCreate` job's cron expression, in local time.
    let cron: String?
    /// How the CLI put the schedule (`humanSchedule`: "Every 15 minutes", or the cron itself).
    let schedule: String?
    let prompt: String
    let createdAt: Date?
    /// The next run the CLI itself reported (`nextFireAt` when it made or listed the job, a wakeup's
    /// `scheduledFor`), however long ago.
    let reportedRun: Date?

    /// When a recurring job ends: the first run a week after it was made is its last.
    var endsAt: Date? {
        kind == .recurring ? createdAt.map { $0.addingTimeInterval(ClaudeSessionJobs.recurringMaxAge) } : nil
    }

    /// When it runs next after `now`: the run the CLI reported while that is still ahead (a wakeup's is
    /// exact), else worked out here from the cron by the CLI's own rule, which `isReported` false says.
    /// A one-shot job's run is fixed when it is made and stays, overdue, until the CLI is idle to fire it.
    func nextRun(after now: Date, calendar: Calendar = .current) -> (date: Date, isReported: Bool)? {
        if let reportedRun, reportedRun > now { return (reportedRun, true) }
        guard let parsed = cron.flatMap(ClaudeCron.init) else { return nil }
        switch kind {
        case .recurring: return parsed.recurringRun(after: now, jobID: id, calendar: calendar).map { ($0, false) }
        case .once: return parsed.oneShotFire(after: createdAt ?? now, jobID: id, calendar: calendar).map { ($0, false) }
        case .wakeup: return nil
        }
    }
}

/// Claude Code's five-field cron in local time (`W6`): minute, hour, day of month, month, day of week,
/// each `*`, `*/n`, `a-b`, `a-b/n` or a number, comma-separated; 7 is Sunday too.
struct ClaudeCron: Equatable, Sendable {
    let minutes: [Int]
    let hours: [Int]
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>

    init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, let minutes = Self.field(fields[0], 0...59), let hours = Self.field(fields[1], 0...23),
              let days = Self.field(fields[2], 1...31), let months = Self.field(fields[3], 1...12),
              let weekdays = Self.field(fields[4], 0...6) else { return nil }
        self.minutes = minutes
        self.hours = hours
        daysOfMonth = Set(days)
        self.months = Set(months)
        daysOfWeek = Set(weekdays)
    }

    private static func field(_ text: String, _ range: ClosedRange<Int>) -> [Int]? {
        let isWeekday = range == 0...6
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let halves = part.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let base = halves[0]
            let step = halves.count == 2 ? number(halves[1]) : 1
            if base == "*" {
                guard let step, step >= 1 else { return nil }
                values.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
            } else if let dash = base.firstIndex(of: "-"), let low = number(base[..<dash]),
                      let high = number(base[base.index(after: dash)...]) {
                guard let step, low <= high, step >= 1, low >= range.lowerBound,
                      high <= (isWeekday ? 7 : range.upperBound) else { return nil }
                values.formUnion(stride(from: low, through: high, by: step).map { isWeekday && $0 == 7 ? 0 : $0 })
            } else if halves.count == 1, var value = number(base) {
                if isWeekday, value == 7 { value = 0 }
                guard range.contains(value) else { return nil }
                values.insert(value)
            } else {
                return nil
            }
        }
        return values.isEmpty ? nil : values.sorted()
    }

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// The first minute after `date`'s that the expression matches, within a year (`RPt` in one-shot
    /// mode). With both day fields restricted, either may match, as in cron.
    func nextMatch(after date: Date, calendar: Calendar = .current) -> Date? {
        let start = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
        let everyDay = daysOfMonth.count == 31, everyWeekday = daysOfWeek.count == 7
        var day = calendar.startOfDay(for: start)
        for _ in 0...366 {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            let date = parts.day ?? 0, weekday = (parts.weekday ?? 1) - 1
            let matchesDay = everyDay && everyWeekday ? true
                : everyDay ? daysOfWeek.contains(weekday)
                : everyWeekday ? daysOfMonth.contains(date)
                : daysOfMonth.contains(date) || daysOfWeek.contains(weekday)
            if months.contains(parts.month ?? 0), matchesDay {
                for hour in hours {
                    for minute in minutes {
                        if let match = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), match >= start {
                            return match
                        }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// When a one-shot job made at `date` fires (`Buo`): at its match, or up to 90 seconds earlier by
    /// the job's own offset when that falls on :00 or :30, never before it was made.
    func oneShotFire(after date: Date, jobID: String, calendar: Calendar = .current) -> Date? {
        guard let match = nextMatch(after: date, calendar: calendar) else { return nil }
        guard calendar.component(.minute, from: match) % 30 == 0 else { return match }
        return max(match.addingTimeInterval(-Self.offsetShare(jobID) * 90), date)
    }

    /// A recurring job's first run after `now`, worked out as the CLI schedules it (`Y7t`): a match,
    /// put off by the job's own share of the gap to the match after it, half the gap and 30 minutes at
    /// most (`recurringFrac`, `recurringCapMs`). The CLI counts from its last run, which no record
    /// names; counting from the matches gives the same run unless the CLI was busy at the last one, or
    /// for `*/5 * * * *`, which it runs 15 seconds short of five minutes after its last run
    /// (`cacheLeadMs`), up to a few minutes from what this says.
    func recurringRun(after now: Date, jobID: String, calendar: Calendar = .current) -> Date? {
        var match = nextMatch(after: now.addingTimeInterval(-31 * 60), calendar: calendar)
        for _ in 0..<64 {
            guard let current = match else { return nil }
            guard let following = nextMatch(after: current, calendar: calendar) else { return current > now ? current : nil }
            let delay = min(Self.offsetShare(jobID) * 0.5 * following.timeIntervalSince(current), 30 * 60)
            let run = current.addingTimeInterval(delay)
            if run > now { return run }
            match = following
        }
        return nil
    }

    /// The job's own fraction of its offset (`C`): its ID's first eight hex digits over 2³².
    private static func offsetShare(_ jobID: String) -> Double {
        let hex = jobID.prefix(8).prefix(while: \.isHexDigit)
        return Double(UInt64(hex, radix: 16) ?? 0) / 4_294_967_296
    }
}

/// A task's session job, as the scheduled tasks list shows it beside Yardlet's own schedules.
struct ScheduledSessionJob: Identifiable, Equatable {
    let session: SessionRecord
    let job: ClaudeSessionJob
    var id: String { "\(session.id.uuidString)|\(job.id)" }
}
