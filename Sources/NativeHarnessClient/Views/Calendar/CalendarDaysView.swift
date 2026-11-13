import SwiftUI

/// The days the calendar shows side by side: each day's name, its all-day events, and its hours with the events
/// and Yardlet's scheduled runs at their times, overlapping ones side by side. The hours scroll; the names and
/// all-day events stay above them.
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
    @Environment(\.yardletInterfaceScale) private var scale
    /// The hour at the top of the hours: the morning's work hours at first, or an earlier event's.
    @State private var topHour: Int?

    static let gutter: CGFloat = 52
    /// Room above each hour's line for its name, so the hour scrolled to the top shows it.
    static let hourNameRoom: CGFloat = 10
    static let hourHeight: CGFloat = 46
    static let allDayLimit = 3

    var body: some View {
        VStack(spacing: 0) {
            dayNames
            allDayRow
            Rectangle().fill(ParityTheme.strongSeparator).frame(height: 1)
            hours
        }
    }

    // MARK: - Names and all-day events

    private var dayNames: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                let isWeekend = calendar.isDateInWeekend(day)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(CalendarText.weekday(day, calendar: calendar))
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(isToday ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.secondary))
                    Text(String(calendar.component(.day, from: day)))
                        .font(.system(size: 17 * scale, weight: isToday ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isToday ? AnyShapeStyle(ParityTheme.accent)
                                         : isWeekend ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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

    private var allDayRow: some View {
        let perDay = allDayEvents
        let rows = min(perDay.map(\.count).max() ?? 0, Self.allDayLimit)
        return HStack(alignment: .top, spacing: 0) {
            Text(L10n.string("All day"))
                .font(.system(size: 10.5 * scale))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 5)
            ForEach(Array(zip(days.indices, perDay)), id: \.0) { _, list in
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
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.separator).frame(width: 1) }
            }
        }
        .frame(height: max(26, CGFloat(rows) * 22 + 6) * scale, alignment: .top)
    }

    // MARK: - Hours

    private var firstHour: Int {
        let earliest = events.filter { !$0.isAllDay }.map { calendar.component(.hour, from: $0.start) }.min() ?? 8
        return max(0, min(8, earliest))
    }

    private var hours: some View {
        ScrollView(.vertical) {
            // One place to scroll to an hour, with the hours drawn over them.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: Self.hourHeight * scale).id(hour) }
            }
            .scrollTargetLayout()
            .padding(.bottom, Self.hourNameRoom)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in grid(width: geometry.size.width) }
                    .padding(.top, Self.hourNameRoom)
            }
        }
        .scrollPosition(id: $topHour, anchor: .top)
        .onAppear { if topHour == nil { topHour = firstHour } }
    }

    private func grid(width: CGFloat) -> some View {
        let perHour = Self.hourHeight * scale
        let columnWidth = max(0, (width - Self.gutter) / CGFloat(max(days.count, 1)))
        return ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
                    .padding(.leading, Self.gutter)
                    .offset(y: CGFloat(hour) * perHour)
                if hour > 0 {
                    Text(CalendarText.hour(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today, calendar: calendar))
                        .font(.system(size: 10.5 * scale).monospacedDigit())
                        .foregroundStyle(.tertiary)
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
                dayItems(day, x: Self.gutter + CGFloat(index) * columnWidth, width: columnWidth, perHour: perHour)
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

    /// One day's events and runs, each cut to the day, side by side where they overlap.
    private func dayItems(_ day: Date, x: CGFloat, width: CGFloat, perHour: CGFloat) -> some View {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let timed = events.filter { !$0.isAllDay && $0.start < end && $0.end > day }
        let runs = slots.filter { $0.at >= day && $0.at < end }
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarText.title(event))
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .lineLimit(showsTimes ? 2 : 1)
                if showsTimes {
                    Text(CalendarText.time(event.start, calendar: calendar))
                        .font(.system(size: 10.5 * scale).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 3)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { background }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(CalendarText.title(event) + ", " + CalendarText.times(event.start, event.end, calendar: calendar))
        .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        if event.awaitsAnswer {
            RoundedRectangle(cornerRadius: 4).fill(color.opacity(isSelected ? 0.22 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4, 2])))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(color.opacity(isSelected ? 0.34 : 0.18))
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

    var body: some View {
        Button(action: action) {
            Text(CalendarText.title(event))
                .font(.system(size: 11 * scale, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20 * scale)
                .background(color.opacity(isSelected ? 0.34 : 0.18), in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if event.awaitsAnswer {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(CalendarText.title(event) + ", " + L10n.string("All day"))
        .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A Yardlet scheduled run on its layer: a dashed outline with a clock, which opens the schedule.
struct CalendarRunBlock: View {
    let slot: CalendarScheduleSlot
    let calendar: Calendar
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 8.5 * scale, weight: .semibold))
                Text(slot.name).font(.system(size: 10.5 * scale, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 5)
            .padding(.trailing, 3)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 4).fill(ParityTheme.subtleFill)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ParityTheme.strongSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("Open the scheduled task"))
        .accessibilityLabel(slot.name + ", " + CalendarText.time(slot.at, calendar: calendar))
        .accessibilityHint(L10n.string("Open the scheduled task"))
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
