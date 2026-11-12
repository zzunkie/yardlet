import Foundation

/// Scheduled tasks in the order Scheduled tasks and `list_scheduled_tasks` give them, after the
/// Claude app's routines list (sorted by next run, completed ones hidden until asked for): the ones
/// that will run, soonest first; then the ones that are off, paused or stopped by themselves; then
/// the one-offs that ran. The last two hold the latest change first.
struct ScheduleListSections: Equatable {
    struct Entry: Equatable, Identifiable {
        var schedule: ScheduledTask
        var nextRun: Date?
        var id: UUID { schedule.id }
    }

    enum Section: CaseIterable {
        case upcoming
        case off
        case finished
    }

    var upcoming: [Entry] = []
    var off: [Entry] = []
    var finished: [Entry] = []

    init(_ schedules: [ScheduledTask], nextRun: (ScheduledTask) -> Date?) {
        for schedule in schedules {
            let entry = Entry(schedule: schedule, nextRun: schedule.isEnabled ? nextRun(schedule) : nil)
            switch Self.section(of: schedule) {
            case .upcoming: upcoming.append(entry)
            case .off: off.append(entry)
            case .finished: finished.append(entry)
            }
        }
        upcoming.sort { a, b in
            switch (a.nextRun, b.nextRun) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return Self.byName(a, b)
            }
        }
        off.sort(by: Self.latestFirst)
        finished.sort(by: Self.latestFirst)
    }

    static func section(of schedule: ScheduledTask) -> Section {
        if schedule.isEnabled { return .upcoming }
        return schedule.state.stopReason == .finished ? .finished : .off
    }

    subscript(section: Section) -> [Entry] {
        switch section {
        case .upcoming: upcoming
        case .off: off
        case .finished: finished
        }
    }

    /// Every schedule, in the list's order.
    var all: [Entry] { upcoming + off + finished }

    /// The day a schedule that will run runs next, which the list groups them by, as a run history groups
    /// its runs by the day they ran.
    enum Day: CaseIterable {
        case today
        case tomorrow
        case nextSevenDays
        /// A week or more ahead, or with no next run.
        case later

        init(_ nextRun: Date?, now: Date, calendar: Calendar) {
            guard let nextRun else { self = .later; return }
            switch calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: nextRun)).day ?? 0 {
            case ...0: self = .today
            case 1: self = .tomorrow
            case 2...6: self = .nextSevenDays
            default: self = .later
            }
        }
    }

    /// The schedules that will run, by the day they run next, soonest first; days with none are left out.
    func upcomingByDay(now: Date, calendar: Calendar) -> [(day: Day, entries: [Entry])] {
        var byDay: [Day: [Entry]] = [:]
        for entry in upcoming { byDay[Day(entry.nextRun, now: now, calendar: calendar), default: []].append(entry) }
        return Day.allCases.compactMap { day in byDay[day].map { (day, $0) } }
    }

    private static func byName(_ a: Entry, _ b: Entry) -> Bool {
        switch a.schedule.name.localizedStandardCompare(b.schedule.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id.uuidString < b.id.uuidString
        }
    }

    /// When it was last paused, run, failed or passed.
    private static func lastChange(_ schedule: ScheduledTask) -> Date {
        [schedule.updatedAt, schedule.state.lastRunAt, schedule.state.lastSlot].compactMap { $0 }.max() ?? schedule.updatedAt
    }

    private static func latestFirst(_ a: Entry, _ b: Entry) -> Bool {
        let x = lastChange(a.schedule), y = lastChange(b.schedule)
        return x != y ? x > y : byName(a, b)
    }
}

extension ScheduledTaskCenter {
    var sections: ScheduleListSections {
        ScheduleListSections(schedules) { nextRun(of: $0) }
    }
}
