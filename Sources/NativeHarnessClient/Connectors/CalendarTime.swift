import Foundation

enum CalendarTime {
    /// A parsed argument: the instant, and whether it named its own offset or only a date.
    static func parse(_ text: String, in zone: TimeZone) -> (date: Date, hasOffset: Bool, dateOnly: Bool)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let date = absolute(value) { return (date, true, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        for (format, dateOnly) in [("yyyy-MM-dd'T'HH:mm:ss.SSS", false), ("yyyy-MM-dd'T'HH:mm:ss", false),
                                   ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm:ss", false),
                                   ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return (date, false, dateOnly) }
        }
        return nil
    }

    /// A time with its own offset or `Z`.
    static func absolute(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func rfc3339(_ date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func day(_ date: Date, in zone: TimeZone) -> Date {
        calendar(zone).startOfDay(for: date)
    }

    static func nextDay(_ date: Date, in zone: TimeZone) -> Date {
        calendar(zone).date(byAdding: .day, value: 1, to: day(date, in: zone)) ?? date.addingTimeInterval(86_400)
    }

    static func dateString(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Working hours, "HH:mm" to "HH:mm", as minutes into the day.
    struct Window: Equatable {
        var start: Int?
        var end: Int?

        init(start: String?, end: String?) throws {
            func minutes(_ text: String?, _ name: String) throws -> Int? {
                guard let text else { return nil }
                let parts = text.split(separator: ":").map { Int($0) }
                guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0...24).contains(hour), (0..<60).contains(minute),
                      hour * 60 + minute <= 1_440 else {
                    throw ConnectorToolArguments.Problem.invalid("\(name) is a time of day such as 09:00.")
                }
                return hour * 60 + minute
            }
            self.start = try minutes(start, "preferences.startHour")
            self.end = try minutes(end, "preferences.endHour")
            if let first = self.start, let last = self.end, last <= first {
                throw ConnectorToolArguments.Problem.invalid("preferences.endHour is after startHour.")
            }
        }
    }

    /// Free times of `minutes` between `from` and `to` outside every busy period, within the
    /// window each day and on weekdays if asked, starting on a quarter hour, at most one an hour
    /// apart so they spread over the free time, `limit` at most.
    static func freeSlots(from: Date, to: Date, busy: [DateInterval], minutes: Int, window: Window,
                          excludeWeekends: Bool, zone: TimeZone, limit: Int) -> [DateInterval] {
        let calendar = calendar(zone)
        let length = TimeInterval(minutes * 60)
        let merged = busy.sorted { $0.start < $1.start }.reduce(into: [DateInterval]()) { list, period in
            if let last = list.last, period.start <= last.end {
                list[list.count - 1] = DateInterval(start: last.start, end: max(last.end, period.end))
            } else {
                list.append(period)
            }
        }
        var slots: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to, slots.count < limit {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? to }
            let weekday = calendar.component(.weekday, from: day)
            if excludeWeekends, weekday == 1 || weekday == 7 { continue }
            let open = max(from, day.addingTimeInterval(TimeInterval((window.start ?? 0) * 60)))
            let close = min(to, day.addingTimeInterval(TimeInterval((window.end ?? 1_440) * 60)))
            guard close > open else { continue }
            var cursor = quarterHour(open, calendar: calendar)
            while cursor.addingTimeInterval(length) <= close, slots.count < limit {
                let candidate = DateInterval(start: cursor, duration: length)
                if let blocking = merged.first(where: { $0.start < candidate.end && $0.end > candidate.start }) {
                    cursor = quarterHour(blocking.end, calendar: calendar)
                    continue
                }
                slots.append(candidate)
                cursor = cursor.addingTimeInterval(max(length, 3_600))
            }
        }
        return slots
    }

    /// The next quarter hour from `date`, or `date` itself on one.
    private static func quarterHour(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let into = TimeInterval((parts.minute ?? 0) * 60 + (parts.second ?? 0)) + TimeInterval(parts.nanosecond ?? 0) / 1e9
        let rounded = (into / 900).rounded(.up) * 900
        return date.addingTimeInterval(rounded - into)
    }
}
