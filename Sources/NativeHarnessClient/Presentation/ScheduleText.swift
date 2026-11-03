import Foundation

/// How schedules read in the list, the detail, the editor and the import sheet.
enum ScheduleText {
    /// "Every day at 9:00 AM", "Weekdays at 9:00 AM", "Every Mon, Wed at 9:00 AM", "Every 3 hours",
    /// "Once, Oct 18 at 2:30 PM".
    static func summary(_ trigger: ScheduleTrigger, calendar: Calendar = .autoupdatingCurrent,
                        now: Date = Date()) -> String {
        switch trigger {
        case let .daily(time):
            return L10n.format("Every day at %@", timeText(time, calendar: calendar))
        case let .weekly(days, time):
            if days == ScheduleWeekday.everyDay { return L10n.format("Every day at %@", timeText(time, calendar: calendar)) }
            if days == ScheduleWeekday.weekdays { return L10n.format("Weekdays at %@", timeText(time, calendar: calendar)) }
            return L10n.format("Every %@ at %@", dayList(days, calendar: calendar), timeText(time, calendar: calendar))
        case let .interval(hours, _, days):
            let every = hours == 1 ? L10n.string("Every hour") : L10n.format("Every %lld hours", Int64(hours))
            guard !days.isEmpty, days != ScheduleWeekday.everyDay else { return every }
            let on = days == ScheduleWeekday.weekdays ? L10n.string("Weekdays") : dayList(days, calendar: calendar)
            return L10n.format("%@ on %@", every, on)
        case let .once(date):
            return L10n.format("Once, %@", moment(date, relativeTo: now, calendar: calendar))
        }
    }

    /// "Mon, Wed, Fri" in the calendar's order and the person's language.
    static func dayList(_ days: Set<ScheduleWeekday>, calendar: Calendar = .autoupdatingCurrent) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return ScheduleWeekday.ordered(days, calendar: calendar)
            .map { symbols[$0.rawValue - 1] }
            .joined(separator: ", ")
    }

    static func timeText(_ time: ScheduleTime, calendar: Calendar = .autoupdatingCurrent) -> String {
        let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0,
                                 of: calendar.startOfDay(for: Date())) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Today at 9:00 AM", "Tomorrow at 9:00 AM", "Sat 9:00 AM" within the week, else the date.
    static func moment(_ date: Date, relativeTo now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if (-1...1).contains(days) {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        } else if (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd EEE jmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMd jmm")
        }
        return formatter.string(from: date)
    }

    /// A run's task title: the schedule's name and when it was due.
    static func runTitle(_ name: String, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return "\(name) · \(formatter.string(from: date))"
    }

    /// The line under a schedule's name: when it runs next, or why it does not.
    static func status(_ schedule: ScheduledTask, nextRun: Date?, isStarting: Bool, now: Date = Date(),
                       calendar: Calendar = .autoupdatingCurrent) -> String {
        if isStarting { return L10n.string("Starting a run…") }
        switch schedule.state.stopReason {
        case .repeatedFailures?:
            return L10n.format("Turned off after %lld failed starts", Int64(ScheduleRunPolicy.failureLimit))
        case .finished?:
            return L10n.string("Ran once")
        case .expired?:
            return L10n.string("Its time passed while it could not run")
        case nil:
            break
        }
        guard schedule.isEnabled else { return L10n.string("Paused") }
        if schedule.state.runs.contains(where: { $0.outcome == .deferred }) {
            return L10n.string("Waiting until the task is available")
        }
        guard let nextRun else { return L10n.string("No next run") }
        return L10n.format("Next run %@", moment(nextRun, relativeTo: now, calendar: calendar))
    }

    /// How a schedule repeats in a few words, beside its next run in the list: "Every day", "Weekdays",
    /// "Every Mon, Wed", "Every 3 hours", "Once".
    static func cadence(_ trigger: ScheduleTrigger, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch trigger {
        case .daily:
            return L10n.string("Every day")
        case let .weekly(days, _):
            if days == ScheduleWeekday.everyDay { return L10n.string("Every day") }
            if days == ScheduleWeekday.weekdays { return L10n.string("Weekdays") }
            return L10n.format("Every %@", dayList(days, calendar: calendar))
        case let .interval(hours, _, _):
            return hours == 1 ? L10n.string("Every hour") : L10n.format("Every %lld hours", Int64(hours))
        case .once:
            return L10n.string("Once")
        }
    }

    /// The line under a schedule's name in the list, as both apps' rows pair the next run with a readable
    /// schedule: "Tomorrow at 9:00 AM · Every day". A schedule that is off says why, a paused one keeps
    /// how it repeats, and a one-off that ran says when it ran.
    static func row(_ schedule: ScheduledTask, nextRun: Date?, isStarting: Bool, now: Date = Date(),
                    calendar: Calendar = .autoupdatingCurrent) -> String {
        if isStarting { return L10n.string("Starting a run…") }
        let cadence = cadence(schedule.trigger, calendar: calendar)
        switch schedule.state.stopReason {
        case .finished?:
            return schedule.state.lastRunAt.map { L10n.format("Ran %@", moment($0, relativeTo: now, calendar: calendar)) }
                ?? L10n.string("Ran once")
        case .repeatedFailures?, .expired?:
            return status(schedule, nextRun: nil, isStarting: false, now: now, calendar: calendar)
        case nil:
            break
        }
        guard schedule.isEnabled else { return "\(L10n.string("Paused")) · \(cadence)" }
        if schedule.state.runs.contains(where: { $0.outcome == .deferred }) {
            return L10n.string("Waiting until the task is available")
        }
        guard let nextRun else { return "\(L10n.string("No next run")) · \(cadence)" }
        return "\(moment(nextRun, relativeTo: now, calendar: calendar)) · \(cadence)"
    }

    static func lastRun(_ schedule: ScheduledTask, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String? {
        schedule.state.lastRunAt.map { lastRun(at: $0, now: now, calendar: calendar) }
    }

    /// "Last run Today at 9:00 AM".
    static func lastRun(at date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        L10n.format("Last run %@", moment(date, relativeTo: now, calendar: calendar))
    }

    /// A schedule's latest run in one line, for the phone (§15.21): when it was, and for a run that started
    /// nothing, why, in the run history's words.
    static func latestRun(_ run: ScheduledTaskRun, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let when = lastRun(at: run.at, now: now, calendar: calendar)
        switch run.outcome {
        case .started: return when
        case .deferred: return L10n.string("Waiting until the task is available")
        case .expired: return L10n.string("Missed: the task was unavailable for 24 hours")
        case .skipped: return "\(when) · \(skipReason(run.skipReason ?? .previousRunActive))"
        case .failed: return "\(when) · \(couldNotStart(run.failure ?? ""))"
        }
    }

    static func skipReason(_ reason: ScheduledTaskRun.SkipReason) -> String {
        switch reason {
        case .previousRunActive: L10n.string("Skipped: the previous run is still going")
        case .targetBusy: L10n.string("Skipped: the task was busy")
        }
    }

    static func couldNotStart(_ message: String) -> String {
        message.isEmpty ? L10n.string("Could not start") : L10n.format("Could not start: %@", message)
    }

    static func trigger(_ trigger: ScheduledTaskRun.Trigger) -> String {
        switch trigger {
        case .scheduled: L10n.string("On schedule")
        case .missed: L10n.string("Missed, ran late")
        case .manual: L10n.string("Run now")
        }
    }

    static func origin(_ origin: ScheduleOrigin) -> String {
        switch origin.app {
        case .claudeApp: L10n.string("Imported from the Claude app.")
        case .codexApp: L10n.string("Imported from the Codex app.")
        }
    }
}
