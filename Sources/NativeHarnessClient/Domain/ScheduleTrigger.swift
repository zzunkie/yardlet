import Foundation

/// A time of day on the Mac's clock.
struct ScheduleTime: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    static func < (lhs: ScheduleTime, rhs: ScheduleTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// "09:05", as the stored form spells it.
    var text: String { String(format: "%02d:%02d", hour, minute) }

    init?(text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let time = ScheduleTime(text: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"))
        }
        self = time
    }

    /// Times of day once each, earliest first, as a trigger keeps them.
    static func ordered(_ times: some Sequence<ScheduleTime>) -> [ScheduleTime] {
        Set(times).sorted()
    }
}

/// Foundation's weekday numbers: Sunday 1 … Saturday 7.
enum ScheduleWeekday: Int, Codable, CaseIterable, Comparable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    static let weekdays: Set<ScheduleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let everyDay = Set(allCases)

    /// The order the editor and summaries list days in: the calendar's first weekday first.
    static func ordered(_ days: Set<ScheduleWeekday>, calendar: Calendar = .current) -> [ScheduleWeekday] {
        let first = calendar.firstWeekday
        return days.sorted { ($0.rawValue - first + 7) % 7 < ($1.rawValue - first + 7) % 7 }
    }

    static func < (lhs: ScheduleWeekday, rhs: ScheduleWeekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When a schedule comes due. Times of day are the Mac's local time, read when the slot is worked
/// out, so a schedule follows the clock across time zones and daylight saving time as cron does.
enum ScheduleTrigger: Hashable, Sendable {
    /// Every day at one or more times, earliest first.
    case daily([ScheduleTime])
    /// On the chosen days at one or more times, earliest first (weekdays are Monday to Friday).
    case weekly(days: Set<ScheduleWeekday>, times: [ScheduleTime])
    /// Every `hours` hours counted from `anchor`, in elapsed time, on the chosen days (all when
    /// empty). At most once an hour, the Claude app's floor.
    case interval(hours: Int, anchor: Date, days: Set<ScheduleWeekday>)
    /// Once, at a moment.
    case once(Date)

    static let intervalHours = 1...24
    /// The most times of day a daily or weekly trigger holds: one for each hour.
    static let maxTimes = 24

    /// Every day at one time.
    static func daily(_ time: ScheduleTime) -> ScheduleTrigger { .daily([time]) }

    /// On the chosen days at one time.
    static func weekly(days: Set<ScheduleWeekday>, time: ScheduleTime) -> ScheduleTrigger {
        .weekly(days: days, times: [time])
    }

    var isRecurring: Bool {
        if case .once = self { return false }
        return true
    }

    /// Whether the trigger can be saved: a time and a day to run on, and no more than once an hour.
    var isValid: Bool {
        switch self {
        case let .daily(times): Self.timesAreValid(times)
        case let .weekly(days, times): !days.isEmpty && Self.timesAreValid(times)
        case let .interval(hours, _, _): Self.intervalHours.contains(hours)
        case .once: true
        }
    }

    /// Whether a daily or weekly trigger's times can be saved: at least one, and at most `maxTimes`.
    static func timesAreValid(_ times: [ScheduleTime]) -> Bool {
        (1...maxTimes).contains(times.count)
    }
}

// MARK: - Slots

extension ScheduleTrigger {
    /// The first slot strictly after `date`, or nil when there is none (a one-off already past).
    func nextSlot(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case let .daily(times):
            return Self.nextWallClockSlot(after: date, times: times, days: ScheduleWeekday.everyDay, calendar: calendar)
        case let .weekly(days, times):
            return Self.nextWallClockSlot(after: date, times: times, days: days, calendar: calendar)
        case let .interval(hours, anchor, days):
            let step = TimeInterval(max(hours, 1) * 3_600)
            var index = date < anchor ? 0 : Int(floor(date.timeIntervalSince(anchor) / step)) + 1
            // A week of hourly slots finds one on any chosen day.
            for _ in 0...(7 * 24) {
                let slot = anchor.addingTimeInterval(Double(index) * step)
                if slot > date, Self.allows(days, slot, calendar: calendar) { return slot }
                index += 1
            }
            return nil
        case let .once(moment):
            return moment > date ? moment : nil
        }
    }

    /// The latest slot in `(lower, upper]`, or nil when none falls there.
    func latestSlot(after lower: Date, notAfter upper: Date, calendar: Calendar) -> Date? {
        guard lower < upper else { return nil }
        switch self {
        case let .daily(times):
            return Self.latestWallClockSlot(after: lower, notAfter: upper, times: times, days: ScheduleWeekday.everyDay,
                                            calendar: calendar)
        case let .weekly(days, times):
            return Self.latestWallClockSlot(after: lower, notAfter: upper, times: times, days: days, calendar: calendar)
        case let .interval(hours, anchor, days):
            guard upper >= anchor else { return nil }
            let step = TimeInterval(max(hours, 1) * 3_600)
            var index = Int(floor(upper.timeIntervalSince(anchor) / step))
            while index >= 0 {
                let slot = anchor.addingTimeInterval(Double(index) * step)
                if slot <= lower { return nil }
                if Self.allows(days, slot, calendar: calendar) { return slot }
                index -= 1
            }
            return nil
        case let .once(moment):
            return moment > lower && moment <= upper ? moment : nil
        }
    }

    private static func allows(_ days: Set<ScheduleWeekday>, _ date: Date, calendar: Calendar) -> Bool {
        days.isEmpty || ScheduleWeekday(rawValue: calendar.component(.weekday, from: date)).map(days.contains) == true
    }

    /// The slot on a day: its time, or — where daylight saving time skips that time — the first
    /// moment after the gap; where the clock repeats it, the first of the two.
    static func slot(on day: Date, time: ScheduleTime, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: calendar.startOfDay(for: day),
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// The earliest of the times after `date`, on the first chosen day that has one.
    private static func nextWallClockSlot(after date: Date, times: [ScheduleTime], days: Set<ScheduleWeekday>,
                                          calendar: Calendar) -> Date? {
        guard !days.isEmpty, !times.isEmpty else { return nil }
        let start = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  allows(days, day, calendar: calendar) else { continue }
            let slots = times.compactMap { slot(on: day, time: $0, calendar: calendar) }
            if let next = slots.filter({ $0 > date }).min() { return next }
        }
        return nil
    }

    /// The latest of the times not after `upper`, on the last chosen day that has one, while it is after `lower`.
    private static func latestWallClockSlot(after lower: Date, notAfter upper: Date, times: [ScheduleTime],
                                            days: Set<ScheduleWeekday>, calendar: Calendar) -> Date? {
        guard !days.isEmpty, !times.isEmpty else { return nil }
        let start = calendar.startOfDay(for: upper)
        // The catch-up window is a week; a little over a year bounds anything a caller could pass.
        for offset in 0...400 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            let slots = times.compactMap { slot(on: day, time: $0, calendar: calendar) }
            guard let slot = slots.filter({ $0 <= upper }).max() else { continue }
            if slot <= lower { return nil }
            if allows(days, day, calendar: calendar) { return slot }
        }
        return nil
    }
}

// MARK: - Storage

extension ScheduleTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, time, times, days, hours, anchor, at
    }

    private enum Kind: String, Codable {
        case daily, weekly, interval, once
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .daily(times):
            try container.encode(Kind.daily, forKey: .kind)
            try Self.encode(times, in: &container)
        case let .weekly(days, times):
            try container.encode(Kind.weekly, forKey: .kind)
            try container.encode(days.map(\.rawValue).sorted(), forKey: .days)
            try Self.encode(times, in: &container)
        case let .interval(hours, anchor, days):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(hours, forKey: .hours)
            try container.encode(anchor, forKey: .anchor)
            if !days.isEmpty { try container.encode(days.map(\.rawValue).sorted(), forKey: .days) }
        case let .once(moment):
            try container.encode(Kind.once, forKey: .kind)
            try container.encode(moment, forKey: .at)
        }
    }

    /// One time as `time`, as it always was. Several go in `times` too, the earliest also in `time`, so a
    /// build that reads only `time` runs the schedule at that one rather than losing it.
    private static func encode(_ times: [ScheduleTime], in container: inout KeyedEncodingContainer<CodingKeys>) throws {
        let times = ScheduleTime.ordered(times)
        try container.encodeIfPresent(times.first, forKey: .time)
        if times.count > 1 { try container.encode(times, forKey: .times) }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func days() throws -> Set<ScheduleWeekday> {
            Set(try container.decodeIfPresent([Int].self, forKey: .days)?.compactMap(ScheduleWeekday.init(rawValue:)) ?? [])
        }
        func times() throws -> [ScheduleTime] {
            let times = try container.decodeIfPresent([ScheduleTime].self, forKey: .times) ?? []
            return times.isEmpty ? [try container.decode(ScheduleTime.self, forKey: .time)] : ScheduleTime.ordered(times)
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .daily:
            self = .daily(try times())
        case .weekly:
            self = .weekly(days: try days(), times: try times())
        case .interval:
            self = .interval(hours: try container.decode(Int.self, forKey: .hours),
                             anchor: try container.decode(Date.self, forKey: .anchor), days: try days())
        case .once:
            self = .once(try container.decode(Date.self, forKey: .at))
        }
    }
}
