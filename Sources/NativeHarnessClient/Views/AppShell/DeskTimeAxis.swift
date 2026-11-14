import SwiftUI

/// Today on a time axis, the third of the desk's three zones: the hours, the calendar's timed events in their
/// calendars' colors, Yardlet's scheduled runs dashed with a clock, an invitation not answered outlined dashed in
/// its calendar's color, and a line at the time now. Equal when it would draw the same to the minute, so a home
/// redraw that changed none of it leaves it alone, and the time line moving draws the axis alone.
struct DeskTimeAxis: View, @MainActor Equatable {
    /// Today's runs and timed events.
    let items: [DeskTodayItem]
    let colors: [CalendarKey: Color]
    /// The time now, to the minute.
    let minute: Date
    let day: DateInterval
    /// The line the keyboard is on.
    var highlighted: String?
    let onOpenEvent: (CalendarEvent) -> Void
    let onOpenSchedule: (UUID) -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.colors == rhs.colors && lhs.minute == rhs.minute && lhs.day == rhs.day
            && lhs.highlighted == rhs.highlighted
    }

    /// The hours shown at least, a working day's; an earlier or later item widens them.
    static let hours = 9...23
    /// The fewest points an hour is given; a shorter column scrolls, to the time now.
    static let minimumHourHeight: CGFloat = 26
    static let labelWidth: CGFloat = 38
    /// Room over the first hour's line for its label.
    private static let inset: CGFloat = 8

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.deskAxis)
#endif
        let calendar = Calendar.current
        let hours = shownHours(calendar: calendar)
        GeometryReader { geometry in
            let available = geometry.size.height - Self.inset
            let hourHeight = max(Self.minimumHourHeight, available / CGFloat(hours.count - 1))
            let height = hourHeight * CGFloat(hours.count - 1) + Self.inset
            ScrollView(.vertical) {
                canvas(hours: hours, hourHeight: hourHeight, width: geometry.size.width, calendar: calendar)
            }
            .scrollDisabled(height <= geometry.size.height)
            .scrollIndicators(.never)
            .defaultScrollAnchor(UnitPoint(x: 0, y: min(1, max(0, (hour(of: minute, calendar: calendar) - Double(hours.lowerBound) - 1)
                                                                / Double(max(1, hours.count - 1))))))
        }
    }

    private func canvas(hours: ClosedRange<Int>, hourHeight: CGFloat, width: CGFloat, calendar: Calendar) -> some View {
        let y = { (date: Date) -> CGFloat in
            Self.inset + CGFloat(hour(of: date, calendar: calendar) - Double(hours.lowerBound)) * hourHeight
        }
        let placements = CalendarDayLayout.place(items.map { (key: $0.id, start: $0.start, end: $0.end) },
                                                 minimumLength: CalendarScheduleSlot.drawnLength)
        let blocksWidth = width - Self.labelWidth - 2
        return ZStack(alignment: .topLeading) {
            ForEach(Array(hours), id: \.self) { hour in
                let lineY = Self.inset + CGFloat(hour - hours.lowerBound) * hourHeight
                Rectangle()
                    .fill(ParityTheme.separator)
                    .frame(width: max(0, width - Self.labelWidth), height: 1)
                    .offset(x: Self.labelWidth, y: lineY)
                if (hour - hours.lowerBound) % 2 == 0, hour < hours.upperBound {
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10.5 * scale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .offset(y: lineY - 6)
                        .accessibilityHidden(true)
                }
            }
            ForEach(items) { item in
                let placement = placements[item.id] ?? .init(column: 0, columns: 1)
                let columnWidth = blocksWidth / CGFloat(max(1, placement.columns))
                let top = y(max(item.start, day.start))
                let height = max(18, y(min(max(item.end, item.start.addingTimeInterval(CalendarScheduleSlot.drawnLength)), day.end)) - top - 2)
                block(item, height: height)
                    .frame(width: max(0, columnWidth - 2), height: height)
                    .offset(x: Self.labelWidth + 2 + CGFloat(placement.column) * columnWidth, y: top + 1)
            }
            if day.contains(minute) {
                let nowY = y(minute)
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Rectangle().fill(Color.red).frame(width: max(0, width - Self.labelWidth), height: 1.5)
                }
                .offset(x: Self.labelWidth - 5, y: nowY - 3.5)
                .accessibilityElement()
                .accessibilityLabel(L10n.format("Time axis now %@", DeskTodayZone.time(minute)))
            }
        }
        .frame(width: width, height: Self.inset + hourHeight * CGFloat(hours.count - 1), alignment: .topLeading)
    }

    @ViewBuilder
    private func block(_ item: DeskTodayItem, height: CGFloat) -> some View {
        let isPast = item.end <= minute
        switch item {
        case let .event(event):
            let color = colors[event.id.calendar] ?? ParityTheme.accent
            Button { onOpenEvent(event) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(CalendarText.title(event))
                        .font(.system(size: 11 * scale, weight: .medium))
                        .lineLimit(height >= 34 ? 2 : 1)
                    if event.awaitsAnswer, height >= 30 {
                        Text(L10n.string("Not replied"))
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.leading, 7)
                .padding(.trailing, 4)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(isPast ? 0.10 : 0.18))
                        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(isPast ? 0.5 : 1)).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .overlay {
                    // Not answered yet: the calendar's color as a dashed outline, as the week draws it.
                    if event.awaitsAnswer {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    }
                }
                .overlay { highlight(item) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(CalendarText.title(event) + ", " + DeskTodayZone.time(event.start))
            .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        case let .run(run):
            Button { onOpenSchedule(run.schedule.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 9 * scale, weight: .semibold))
                    Text(run.schedule.name).font(.system(size: 11 * scale, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(run.kind == .failed ? AnyShapeStyle(.red) : isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ParityTheme.subtleFill)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(ParityTheme.strongSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .overlay { highlight(item) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(run.schedule.name + ", " + DeskTodayZone.time(run.at))
            .accessibilityValue(DeskTodayZone.note(run.kind))
        }
    }

    @ViewBuilder
    private func highlight(_ item: DeskTodayItem) -> some View {
        if highlighted == item.id {
            RoundedRectangle(cornerRadius: 4).strokeBorder(ParityTheme.accent, lineWidth: 2)
        }
    }

    /// The hours shown: the working day's, widened to the earliest start and the latest end of today's items.
    private func shownHours(calendar: Calendar) -> ClosedRange<Int> {
        var first = Self.hours.lowerBound, last = Self.hours.upperBound
        for item in items {
            first = min(first, Int(hour(of: max(item.start, day.start), calendar: calendar)))
            last = max(last, Int(hour(of: min(item.end, day.end), calendar: calendar).rounded(.up)))
        }
        return min(first, 23)...min(max(last, first + 1), 24)
    }

    /// The hours since the day began, by the day's clock; the day's end is 24.
    private func hour(of date: Date, calendar: Calendar) -> Double {
        if date >= day.end { return 24 }
        if date <= day.start { return 0 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }
}
