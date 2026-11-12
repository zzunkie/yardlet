import Foundation

/// How a Claude Code session job reads in a task's rail and in the scheduled tasks list: its schedule,
/// when it runs next and, for a recurring one, when it ends.
enum SessionJobText {
    /// A recurring job's schedule in the person's language where the CLI's own words (`humanSchedule`,
    /// English) have a form here, else as the CLI put it, which may be the cron itself; "Once" or
    /// "/loop wakeup".
    static func schedule(_ job: ClaudeSessionJob, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch job.kind {
        case .recurring: job.cron.flatMap { summary(cron: $0, calendar: calendar) } ?? job.schedule ?? job.cron ?? ""
        case .once: L10n.string("Once")
        case .wakeup: L10n.string("Loop wakeup")
        }
    }

    /// The forms the CLI names (`sC`): every minute or N minutes, every hour at some minutes, every N
    /// hours, every day, a weekday or weekdays at a time. Nil for any other cron.
    static func summary(cron: String, calendar: Calendar = .autoupdatingCurrent) -> String? {
        let fields = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }
        let (minute, hour, day, month, weekday) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard day == "*", month == "*" else { return nil }
        func every(_ field: String) -> Int? {
            field == "*" ? 1 : field.hasPrefix("*/") ? Int(field.dropFirst(2)).flatMap { $0 >= 1 ? $0 : nil } : nil
        }
        let minutes = minute.split(separator: ",").compactMap { Int($0) }
        let isMinuteList = !minutes.isEmpty && minutes.count == minute.split(separator: ",").count
            && minutes.allSatisfy { (0...59).contains($0) }
        if hour == "*", weekday == "*" {
            if let step = every(minute) {
                return step == 1 ? L10n.string("Every minute") : L10n.format("Every %lld minutes", Int64(step))
            }
            guard isMinuteList else { return nil }
            return minutes == [0] ? L10n.string("Every hour")
                : L10n.format("Every hour at minute %@", minutes.map(String.init).joined(separator: ", "))
        }
        if weekday == "*", let step = every(hour), isMinuteList, minutes.count == 1 {
            return step == 1 ? L10n.string("Every hour") : L10n.format("Every %lld hours", Int64(step))
        }
        guard isMinuteList, minutes.count == 1, let hours = Int(hour), (0...23).contains(hours) else { return nil }
        let time = ScheduleText.timeText(ScheduleTime(hour: hours, minute: minutes[0]), calendar: calendar)
        if weekday == "*" { return L10n.format("Every day at %@", time) }
        if weekday == "1-5" { return L10n.format("Weekdays at %@", time) }
        guard let number = Int(weekday), (0...7).contains(number),
              let day = ScheduleWeekday(rawValue: number % 7 + 1) else { return nil }
        return L10n.format("Every %@ at %@", ScheduleText.dayList([day], calendar: calendar), time)
    }

    /// "Next run in 6 min". A one-shot job past its time runs once the CLI is idle.
    static func nextRun(_ job: ClaudeSessionJob, now: Date) -> String? {
        job.nextRun(after: now).map { nextRun(at: $0.date, now: now) }
    }

    /// "Next run in 6 min", as the rail says it of a session job and of a schedule that continues the task.
    static func nextRun(at run: Date, now: Date) -> String {
        guard run.timeIntervalSince(now) >= 60 else { return L10n.string("Next run in under a minute") }
        return L10n.format("Next run %@", run.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
    }

    /// "Ends: Oct 30": a recurring job's last run comes a week after it was made; the time once it is
    /// that day.
    static func ends(_ job: ClaudeSessionJob, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let end = job.endsAt else { return nil }
        let text = calendar.isDate(end, inSameDayAs: now) ? ScheduleText.moment(end, relativeTo: now, calendar: calendar)
            : end.formatted(.dateTime.month(.abbreviated).day())
        return L10n.format("Ends: %@", text)
    }

    /// The line under a job's name: its schedule, next run and end, as far as each is known.
    static func detail(_ job: ClaudeSessionJob, now: Date) -> String {
        [schedule(job), nextRun(job, now: now), ends(job, now: now)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A job's prompt on one line, or what kind of job it is when it has none.
    static func title(_ job: ClaudeSessionJob) -> String {
        let line = job.prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // `/loop` with no prompt of its own schedules the CLI's stand-in (`<<autonomous-loop>>`).
        guard !line.isEmpty, !(line.hasPrefix("<<") && line.hasSuffix(">>")) else {
            return job.kind == .wakeup ? schedule(job) : "/loop"
        }
        return line
    }
}
