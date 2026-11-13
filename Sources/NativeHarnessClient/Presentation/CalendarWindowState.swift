import Foundation
import Observation

/// What the calendar screen shows: one day, or a week.
enum CalendarSpan: String, Hashable, Sendable {
    case day
    case week
}

/// One window's view of the calendar: the days shown and the event chosen. The calendar itself (`CalendarCenter`)
/// is the app's; each window keeps its own days.
@MainActor @Observable
final class CalendarWindowState {
    var span: CalendarSpan = .week
    /// A day of what is shown: the day, or a day of the week.
    private(set) var anchor: Date
    /// The event whose details show beside the days.
    var selection: CalendarEventKey?
    /// The start of today, moved on when the day changes (`noteDayChanged`).
    private(set) var today: Date
    /// The screen's two readers of the calendar: the days shown, and the upcoming days in the sidebar.
    @ObservationIgnored let daysViewer = UUID()
    @ObservationIgnored let upcomingViewer = UUID()
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let now: () -> Date

    /// The upcoming days the sidebar lists: today and the six after it.
    static let upcomingDays = 7

    init(calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = { Date() }) {
        self.calendar = calendar
        self.now = now
        anchor = calendar.startOfDay(for: now())
        today = calendar.startOfDay(for: now())
    }

    /// The start of each day shown.
    var days: [Date] {
        let range = range
        var days: [Date] = []
        var day = range.start
        while day < range.end, days.count < 7 {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? range.end
        }
        return days
    }

    /// The days shown: the anchor's day, or its week as the Mac's calendar starts a week.
    var range: DateInterval {
        switch span {
        case .day:
            return DateInterval(start: anchor, end: calendar.date(byAdding: .day, value: 1, to: anchor) ?? anchor.addingTimeInterval(86_400))
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor)
                ?? DateInterval(start: anchor, duration: 7 * 86_400)
        }
    }

    var upcomingRange: DateInterval {
        DateInterval(start: today, end: calendar.date(byAdding: .day, value: Self.upcomingDays, to: today)
                     ?? today.addingTimeInterval(Double(Self.upcomingDays) * 86_400))
    }

    /// What the screen reads: the days shown and the upcoming days, as one range when they meet.
    var readRanges: [DateInterval] {
        let shown = range, upcoming = upcomingRange
        guard shown.start <= upcoming.end, upcoming.start <= shown.end else { return [shown, upcoming] }
        return [DateInterval(start: min(shown.start, upcoming.start), end: max(shown.end, upcoming.end))]
    }

    var showsToday: Bool { range.contains(today) }

    /// The day or week before or after.
    func move(_ steps: Int) {
        anchor = calendar.date(byAdding: span == .day ? .day : .weekOfYear, value: steps, to: anchor) ?? anchor
        selection = nil
    }

    func showToday() {
        anchor = today
    }

    func show(_ day: Date, as span: CalendarSpan) {
        anchor = calendar.startOfDay(for: day)
        self.span = span
    }

    /// The Mac's day changed while the window was open.
    func noteDayChanged() {
        let start = calendar.startOfDay(for: now())
        guard start != today else { return }
        // A window that showed today goes on showing it.
        if range.contains(today) && !range.contains(start) { anchor = start }
        today = start
    }

    /// The calendar was turned off: the window starts again at today.
    func reset() {
        today = calendar.startOfDay(for: now())
        anchor = today
        span = .week
        selection = nil
    }
}

/// A Yardlet scheduled run on the calendar's layer of them.
struct CalendarScheduleSlot: Identifiable, Hashable, Sendable {
    let scheduleID: UUID
    let name: String
    let at: Date

    var id: String { scheduleID.uuidString + " \(at.timeIntervalSinceReferenceDate)" }

    /// How long a run is drawn: it has no end of its own.
    static let drawnLength: TimeInterval = 25 * 60

    /// Each enabled schedule's runs in the range by time, as its trigger comes due: none before the schedule was made,
    /// and at most `limit` of one schedule.
    static func slots(of schedules: [ScheduledTask], in range: DateInterval, calendar: Calendar,
                      limit: Int = 200) -> [CalendarScheduleSlot] {
        var slots: [CalendarScheduleSlot] = []
        for schedule in schedules where schedule.isEnabled {
            var cursor = max(range.start, calendar.startOfMinute(schedule.createdAt)).addingTimeInterval(-0.001)
            var count = 0
            while count < limit, let next = schedule.trigger.nextSlot(after: cursor, calendar: calendar), next < range.end {
                slots.append(CalendarScheduleSlot(scheduleID: schedule.id, name: schedule.name, at: next))
                cursor = next
                count += 1
            }
        }
        return slots.sorted { $0.at < $1.at }
    }
}

/// Where each item of a day goes among those whose times overlap it: its column, and how many columns its group of
/// overlapping items shares, as calendars set meetings side by side.
enum CalendarDayLayout {
    struct Placement: Hashable, Sendable {
        var column: Int
        var columns: Int
    }

    /// `minimumLength` is the shortest an item is drawn, so a short one does not overlap the next.
    static func place<Key: Hashable>(_ items: [(key: Key, start: Date, end: Date)],
                                     minimumLength: TimeInterval) -> [Key: Placement] {
        let sorted = items.map { (key: $0.key, start: $0.start, end: max($0.end, $0.start.addingTimeInterval(minimumLength))) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var placements: [Key: Placement] = [:]
        var group: [(key: Key, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func close() {
            for member in group { placements[member.key] = Placement(column: member.column, columns: columnEnds.count) }
            group = []
            columnEnds = []
        }
        for item in sorted {
            if item.start >= groupEnd { close() }
            let column = columnEnds.firstIndex { $0 <= item.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(item.end) } else { columnEnds[column] = item.end }
            group.append((item.key, column))
            groupEnd = max(groupEnd, item.end)
        }
        close()
        return placements
    }
}

/// The calendar's dates and times, as the Mac's language and region write them.
@MainActor
enum CalendarText {
    private static var intervals: [String: DateIntervalFormatter] = [:]

    private static func format(_ date: Date, _ template: String, calendar: Calendar) -> String {
        ScheduleDateFormatters.shared.formatter(.template(template), calendar: calendar).string(from: date)
    }

    private static func interval(_ start: Date, _ end: Date, _ template: String, calendar: Calendar) -> String {
        let formatter = intervals[template] ?? {
            let formatter = DateIntervalFormatter()
            formatter.dateTemplate = template
            intervals[template] = formatter
            return formatter
        }()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        return formatter.string(from: start, to: end)
    }

    /// "November 2026".
    static func month(_ date: Date, calendar: Calendar) -> String { format(date, "yMMMM", calendar: calendar) }

    /// The days shown after the month: "Nov 9 – 15", or "Monday, Nov 9" for one day.
    static func days(_ range: DateInterval, span: CalendarSpan, calendar: Calendar) -> String {
        switch span {
        case .day: format(range.start, "MMMdEEEE", calendar: calendar)
        case .week: interval(range.start, range.end.addingTimeInterval(-1), "MMMd", calendar: calendar)
        }
    }

    static func weekday(_ date: Date, calendar: Calendar) -> String { format(date, "EEE", calendar: calendar) }

    /// "9 AM", as the Mac shows an hour.
    static func hour(_ date: Date, calendar: Calendar) -> String { format(date, "j", calendar: calendar) }

    static func time(_ date: Date, calendar: Calendar) -> String { format(date, "jmm", calendar: calendar) }

    /// "11:00 – 12:00 PM".
    static func times(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        interval(start, end, "jmm", calendar: calendar)
    }

    /// "Today", "Tomorrow", else "Mon, Nov 16".
    static func day(_ date: Date, today: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: today) { return L10n.string("Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.string("Tomorrow")
        }
        return format(date, "MMMdEEE", calendar: calendar)
    }

    /// "Monday, November 9 · 4:30 – 5:00 PM", or the days of an all-day event.
    static func when(_ event: CalendarEvent, calendar: Calendar) -> String {
        guard event.isAllDay else {
            let day = format(event.start, "MMMMdEEEE", calendar: calendar)
            return calendar.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1))
                ? day + " · " + times(event.start, event.end, calendar: calendar)
                : interval(event.start, event.end, "MMMdEEEjmm", calendar: calendar)
        }
        let last = event.end.addingTimeInterval(-1)
        let days = calendar.isDate(event.start, inSameDayAs: last)
            ? format(event.start, "MMMMdEEEE", calendar: calendar)
            : interval(event.start, last, "MMMdEEE", calendar: calendar)
        return days + " · " + L10n.string("All day")
    }

    /// What an agent is told of an event it is asked about: its title and time, its account, calendar and ID, and
    /// the connector tool that reads it. Its description stays out; the agent reads it with the tool.
    static func handoff(_ event: CalendarEvent, account: CalendarAccount, calendar: Calendar) -> String {
        let tool = account.connectorSlug.map { "`\($0)_get_event`" } ?? account.provider.serviceName
        let reference: String = switch account.provider {
        case .google, .outlook:
            L10n.format("Calendar handoff %@ %@ %@ %@", account.address ?? "", event.id.calendar.calendarID, event.id.eventID, tool)
        case .apple:
            L10n.format("Calendar handoff Mac %@ %@", event.id.occurrence.map {
                "\(event.id.eventID)@\(CalendarTime.rfc3339($0, in: TimeZone(identifier: "UTC")!))"
            } ?? event.id.eventID, tool)
        }
        return [L10n.format("Calendar event %@", title(event)), L10n.format("Calendar event time %@", when(event, calendar: calendar)),
                reference].joined(separator: "\n") + "\n\n"
    }

    static func title(_ event: CalendarEvent) -> String {
        event.title.isEmpty ? L10n.string("(No title)") : event.title
    }

    /// The service a meeting link joins, as people name it.
    static func conference(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        if host.hasSuffix("meet.google.com") { return "Google Meet" }
        if host.contains("teams.microsoft") || host.contains("teams.live") { return "Microsoft Teams" }
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host.hasSuffix("webex.com") { return "Webex" }
        return L10n.string("Join online")
    }

    /// An account's heading in the calendar list: "person@example.com · Google", or "Mac Calendar · iCloud" for one of
    /// the Mac's accounts.
    static func account(_ account: CalendarAccount, source: String?) -> String {
        switch account.provider {
        case .google: (account.address ?? "") + " · Google"
        case .outlook: (account.address ?? "") + " · Outlook"
        case .apple: [L10n.string("Mac Calendar"), source].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        }
    }
}

extension Calendar {
    /// The minute the date falls in.
    func startOfMinute(_ date: Date) -> Date {
        dateInterval(of: .minute, for: date)?.start ?? date
    }
}
