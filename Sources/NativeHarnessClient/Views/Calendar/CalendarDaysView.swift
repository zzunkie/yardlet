import SwiftUI

/// The days the calendar shows side by side: each day's name, its all-day events, and its hours with the events
/// and Yardlet's one-off scheduled runs at their times, overlapping ones side by side. The runs of schedules that come
/// due again stay out of the hours: the all-day row sums up each day's in one line, which shows that day with its
/// runs listed (`CalendarDayRunsList`). The hours scroll; the names and all-day events stay above them.
struct CalendarDaysView: View {
    let days: [Date]
    let today: Date
    let events: [CalendarEvent]
    let slots: [CalendarScheduleSlot]
    let colors: [CalendarKey: Color]
    let selection: CalendarEventKey?
    let calendar: Calendar
    let onSelect: (CalendarEvent) -> Void
    let onOpenSchedule: (UUID) -> Void
    /// A day's line of recurring runs was chosen.
    let onShowDay: (Date) -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    /// The hour at the top of the hours: the morning's work hours at first, or an earlier event's.
    @State private var topHour: Int?

    static let gutter: CGFloat = 60
    /// Room above each hour's line for its name, so the hour scrolled to the top shows it.
    static let hourNameRoom: CGFloat = 10
    static let hourHeight: CGFloat = 46
    static let allDayLimit = 3

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.calendarDays)
#endif
        let runs = CalendarDayRuns.byDay(slots, days: days, calendar: calendar)
        VStack(spacing: 0) {
            dayNames
            allDayRow(runs)
            Rectangle().fill(ParityTheme.strongSeparator).frame(height: 1)
            hours(runs)
        }
    }

    // MARK: - Names and all-day events

    private var dayNames: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                let isWeekend = calendar.isDateInWeekend(day)
                HStack(alignment: .center, spacing: 5) {
                    Text(CalendarText.weekday(day, calendar: calendar))
                        .font(.system(size: 12 * scale, weight: isToday ? .semibold : .medium))
                        .foregroundStyle(isToday ? AnyShapeStyle(ParityTheme.accentText) : AnyShapeStyle(.secondary))
                    Text(String(calendar.component(.day, from: day)))
                        .font(.system(size: isToday ? 13.5 * scale : 15 * scale, weight: isToday ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(isToday ? AnyShapeStyle(ParityTheme.onAccentButton)
                                         : isWeekend ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(minWidth: isToday ? 24 * scale : 0, minHeight: isToday ? 24 * scale : 0)
                        .background {
                            if isToday {
                                Circle().fill(ParityTheme.accentButtonFill)
                            }
                        }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .frame(height: 40 * scale)
    }

    private var allDayEvents: [[CalendarEvent]] {
        days.map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            return events.filter { $0.isAllDay && $0.start < end && $0.end > day }
        }
    }

    /// The all-day events, then each day's line of recurring runs.
    private func allDayRow(_ runs: [CalendarDayRuns]) -> some View {
        let perDay = allDayEvents
        let summed = runs.contains { !$0.recurring.isEmpty }
        let rows = min(perDay.map(\.count).max() ?? 0, Self.allDayLimit) + (summed ? 1 : 0)
        return HStack(alignment: .top, spacing: 0) {
            Text(L10n.string("All day"))
                .font(.system(size: 10.5 * scale))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 5)
            ForEach(Array(zip(days.indices, perDay)), id: \.0) { index, list in
                VStack(spacing: 2) {
                    ForEach(list.prefix(list.count > Self.allDayLimit ? Self.allDayLimit - 1 : Self.allDayLimit)) { event in
                        CalendarAllDayBlock(event: event, color: color(of: event), isSelected: selection == event.id) { onSelect(event) }
                    }
                    if list.count > Self.allDayLimit {
                        Text(L10n.format("%lld more", list.count - Self.allDayLimit + 1))
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                            .frame(height: 20 * scale)
                    }
                    if index < runs.count, !runs[index].recurring.isEmpty {
                        recurringLine(runs[index].recurring, day: days[index])
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.separator).frame(width: 1) }
            }
        }
        .frame(height: max(26, CGFloat(rows) * 22 + 6) * scale, alignment: .top)
    }

    /// A day's recurring runs: how many, and on today's how many are still to come, as the minutes pass.
    @ViewBuilder
    private func recurringLine(_ runs: [CalendarScheduleSlot], day: Date) -> some View {
        if calendar.isDate(day, inSameDayAs: today) {
            TimelineView(.everyMinute) { context in
                CalendarRecurringLine(count: runs.count, left: runs.count { $0.at >= context.date }) { onShowDay(day) }
            }
        } else {
            CalendarRecurringLine(count: runs.count, left: day > today ? runs.count : 0) { onShowDay(day) }
        }
    }

    // MARK: - Hours

    private var firstHour: Int {
        let earliest = events.filter { !$0.isAllDay }.map { calendar.component(.hour, from: $0.start) }.min() ?? 8
        return max(0, min(8, earliest))
    }

    private func hours(_ runs: [CalendarDayRuns]) -> some View {
        ScrollView(.vertical) {
            // One place to scroll to an hour, with the hours drawn over them.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: Self.hourHeight * scale).id(hour) }
            }
            .scrollTargetLayout()
            .padding(.bottom, Self.hourNameRoom)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in grid(width: geometry.size.width, runs: runs) }
                    .padding(.top, Self.hourNameRoom)
            }
        }
        .scrollPosition(id: $topHour, anchor: .top)
        .onAppear { if topHour == nil { topHour = firstHour } }
    }

    private func grid(width: CGFloat, runs: [CalendarDayRuns]) -> some View {
        let perHour = Self.hourHeight * scale
        let columnWidth = max(0, (width - Self.gutter) / CGFloat(max(days.count, 1)))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                let isWeekend = calendar.isDateInWeekend(day)
                if isToday {
                    Rectangle()
                        .fill(ParityTheme.accent.opacity(colorScheme == .dark ? 0.065 : 0.04))
                        .frame(width: columnWidth, height: perHour * 24)
                        .offset(x: Self.gutter + CGFloat(index) * columnWidth)
                        .allowsHitTesting(false)
                } else if isWeekend {
                    Rectangle()
                        .fill(ParityTheme.subtleFill)
                        .frame(width: columnWidth, height: perHour * 24)
                        .offset(x: Self.gutter + CGFloat(index) * columnWidth)
                        .allowsHitTesting(false)
                }
            }
            ForEach(0..<24, id: \.self) { hour in
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
                    .padding(.leading, Self.gutter)
                    .offset(y: CGFloat(hour) * perHour)
                if hour > 0 {
                    Text(CalendarText.hour(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today, calendar: calendar))
                        .font(.system(size: 11 * scale).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                        .offset(y: CGFloat(hour) * perHour - 7 * scale)
                        .accessibilityHidden(true)
                }
            }
            ForEach(0...days.count, id: \.self) { index in
                Rectangle().fill(ParityTheme.separator).frame(width: 1, height: perHour * 24)
                    .offset(x: Self.gutter + CGFloat(index) * columnWidth)
            }
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                dayItems(day, once: index < runs.count ? runs[index].once : [],
                         x: Self.gutter + CGFloat(index) * columnWidth, width: columnWidth, perHour: perHour)
            }
            if let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: today) }) {
                CalendarNowLine(day: days[index], calendar: calendar, perHour: perHour, width: columnWidth)
                    .offset(x: Self.gutter + CGFloat(index) * columnWidth - 3.5)
            }
        }
    }

    private enum ItemKey: Hashable {
        case event(CalendarEventKey)
        case slot(String)
    }

    /// One day's events and one-off runs, each cut to the day, side by side where they overlap.
    private func dayItems(_ day: Date, once runs: [CalendarScheduleSlot], x: CGFloat, width: CGFloat,
                          perHour: CGFloat) -> some View {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let timed = events.filter { !$0.isAllDay && $0.start < end && $0.end > day }
        let placements = CalendarDayLayout.place(
            timed.map { (key: ItemKey.event($0.id), start: max($0.start, day), end: min($0.end, end)) }
                + runs.map { (key: ItemKey.slot($0.id), start: $0.at, end: $0.at.addingTimeInterval(CalendarScheduleSlot.drawnLength)) },
            minimumLength: 20 * 60)
        let frame = { (key: ItemKey, start: Date, finish: Date) -> CGRect in
            let placement = placements[key] ?? .init(column: 0, columns: 1)
            let share = (width - 5) / CGFloat(placement.columns)
            let top = CGFloat(start.timeIntervalSince(day) / 3_600) * perHour
            let height = max(CGFloat(finish.timeIntervalSince(start) / 3_600) * perHour - 2, 18 * scale)
            return CGRect(x: x + 2.5 + CGFloat(placement.column) * share, y: top + 1, width: share - 1, height: height)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(timed) { event in
                let rect = frame(.event(event.id), max(event.start, day), min(event.end, end))
                CalendarEventBlock(event: event, color: color(of: event), isSelected: selection == event.id,
                                   showsTimes: rect.height >= 34 * scale, calendar: calendar) { onSelect(event) }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            ForEach(runs) { slot in
                let rect = frame(.slot(slot.id), slot.at, slot.at.addingTimeInterval(CalendarScheduleSlot.drawnLength))
                CalendarRunBlock(slot: slot, calendar: calendar) { onOpenSchedule(slot.scheduleID) }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private func color(of event: CalendarEvent) -> Color {
        colors[event.id.calendar] ?? ParityTheme.accent
    }
}

/// The red line at the time now, on today's column. Only it redraws as the minutes pass.
private struct CalendarNowLine: View {
    let day: Date
    let calendar: Calendar
    let perHour: CGFloat
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let hours = context.date.timeIntervalSince(calendar.startOfDay(for: day)) / 3_600
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Rectangle().fill(Color.red).frame(width: max(0, width - 3), height: 1.5)
            }
            .offset(y: CGFloat(hours) * perHour - 3.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An event at its time: its calendar's color, and an invitation not answered yet drawn as an outline in it, as
/// Calendar draws one.
struct CalendarEventBlock: View {
    let event: CalendarEvent
    let color: Color
    let isSelected: Bool
    let showsTimes: Bool
    let calendar: Calendar
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(CalendarText.title(event))
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .lineLimit(showsTimes ? 2 : 1)
                if showsTimes {
                    Text(CalendarText.time(event.start, calendar: calendar))
                        .font(.system(size: 11 * scale).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { background }
            .clipShape(RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(CalendarText.title(event) + ", " + CalendarText.times(event.start, event.end, calendar: calendar))
        .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
        let isDark = colorScheme == .dark
        if event.awaitsAnswer {
            ZStack {
                shape.fill(color.opacity(isSelected ? (isDark ? 0.30 : 0.22) : (isDark ? 0.14 : 0.08)))
                CalendarDiagonalStripes(spacing: 8)
                    .stroke(color.opacity(isDark ? 0.24 : 0.16), lineWidth: 1)
            }
            .overlay(shape.strokeBorder(color, style: StrokeStyle(lineWidth: isSelected ? 2 : 1.25, dash: isSelected ? [] : [4, 2])))
        } else {
            shape.fill(color.opacity(isSelected ? (isDark ? 0.40 : 0.32) : (isDark ? 0.26 : 0.17)))
                .overlay(shape.strokeBorder(color.opacity(isSelected ? 0.65 : 0.30), lineWidth: 0.5))
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        }
    }
}

/// An all-day event in the row above the hours.
struct CalendarAllDayBlock: View {
    let event: CalendarEvent
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
        let isDark = colorScheme == .dark
        Button(action: action) {
            Text(CalendarText.title(event))
                .font(.system(size: 11.5 * scale, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20 * scale)
                .background {
                    shape.fill(color.opacity(isSelected ? (isDark ? 0.40 : 0.32) : (isDark ? 0.26 : 0.18)))
                        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
                }
                .clipShape(shape)
                .overlay {
                    if event.awaitsAnswer {
                        shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(CalendarText.title(event) + ", " + L10n.string("All day"))
        .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Subtle diagonal hatch pattern distinguishing scheduled agent runs and pending invitations.
struct CalendarDiagonalStripes: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// A Yardlet scheduled run on its layer: diagonal hatch with a clock, which opens the schedule.
struct CalendarRunBlock: View {
    let slot: CalendarScheduleSlot
    let calendar: Calendar
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 8.5 * scale, weight: .semibold))
                Text(slot.name).font(.system(size: 10.5 * scale, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.trailing, 3)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    shape.fill(ParityTheme.subtleFill)
                    CalendarDiagonalStripes()
                        .stroke(Color.primary.opacity(0.055), lineWidth: 1)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(ParityTheme.separator, lineWidth: 1))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("Open the scheduled task"))
        .accessibilityLabel(slot.name + ", " + CalendarText.time(slot.at, calendar: calendar))
        .accessibilityHint(L10n.string("Open the scheduled task"))
    }
}

/// A day's recurring runs in the all-day row: "12 recurring runs · 5 left". Choosing it shows the
/// day, whose runs stand listed beside its hours.
struct CalendarRecurringLine: View {
    let count: Int
    /// How many are still to come: some on today's, all on a day to come, none on a day gone.
    let left: Int
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
        let text = left > 0 && left < count ? L10n.format("%lld recurring runs · %lld left", count, left)
            : L10n.format("%lld recurring runs", count)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 9 * scale, weight: .semibold))
                Text(text).font(.system(size: 11 * scale, weight: .medium).monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20 * scale)
            .background {
                ZStack {
                    shape.fill(ParityTheme.subtleFill)
                    CalendarDiagonalStripes()
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(ParityTheme.separator, lineWidth: 1))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("Show the day's runs"))
        .accessibilityLabel(text)
        .accessibilityHint(L10n.string("Show the day's runs"))
    }
}

extension Color {
    /// A calendar's `#RRGGBB` color, as its service gives it.
    init?(calendarHex: String?) {
        guard let hex = calendarHex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), hex.count == 6,
              let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
