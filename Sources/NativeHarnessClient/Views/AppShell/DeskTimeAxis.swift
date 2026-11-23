import SwiftUI

/// Today on a time axis, the third of the desk's three zones: the hours, the calendar's timed events in their
/// calendars' colors, Yardlet's scheduled runs dashed with a clock (those that already ran folded by the hour until
/// chosen), an invitation not answered outlined dashed in its calendar's color, and a line at the time now. It opens
/// an hour before the time now, as a calendar's day opens on its hours: the hours before stand above, to scroll up
/// to, and the rest of the day fills the column. It keeps that hour, and where the person scrolled, while it shows.
/// Equal when it would draw the same to the minute, so a home redraw that changed none of it leaves it alone, and
/// the time line moving draws the axis alone.
struct DeskTimeAxis: View, @MainActor Equatable {
    /// Today's runs and timed events, as `Desk.axisItems` folds them.
    let items: [DeskAxisItem]
    let colors: [CalendarKey: Color]
    /// The time now, to the minute.
    let minute: Date
    let day: DateInterval
    /// The line the keyboard is on.
    var highlighted: String?
    let onOpenEvent: (CalendarEvent) -> Void
    let onOpenSchedule: (UUID) -> Void
    /// A folded block of runs that ran was chosen.
    var onShowRan: () -> Void = {}
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    /// The hour the axis opened on, which it keeps while it shows.
    @State private var openedOn: Int?
    /// The hour at the axis's top: the one it opened on, then where the person scrolled. A column that grows or
    /// shrinks, whose hours change height with it, keeps it at the top.
    @State private var topHour: Int?
    /// The scrolls the axis asked for that have not run yet: what the scroll view scrolls meanwhile is not the person.
    /// A count, not a flag: a scroll that runs while the column changes again asks for another one before it ends.
    @State private var pendingScrolls = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.colors == rhs.colors && lhs.minute == rhs.minute && lhs.day == rhs.day
            && lhs.highlighted == rhs.highlighted
    }

    /// The hours shown at least, a working day's; an earlier or later item widens them.
    static let hours = 9...23
    /// The fewest points an hour is given: a run's 25 minutes at its block's least height, 18 points, so a run does
    /// not run into the next one's block. A shorter column scrolls.
    static let minimumHourHeight: CGFloat = 44
    /// The fewest hours the rest of the day is spread over, so a day's last hours do not grow to fill the column.
    static let fewestHours = 6
    static let labelWidth: CGFloat = 38
    /// Room over the first hour's line for its label.
    private static let inset: CGFloat = 8

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.deskAxis)
#endif
        let calendar = Calendar.current
        let hours = shownHours(calendar: calendar)
        // An hour before the time now, among the hours shown.
        let opening = openedOn ?? min(max(hours.lowerBound, Int(hour(of: minute, calendar: calendar)) - 1), hours.upperBound - 1)
        let rest = hours.upperBound - opening
        GeometryReader { geometry in
            let hourHeight = Self.hourHeight(column: geometry.size.height, rest: rest)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // One place to scroll to for each hour, with the hours drawn over them.
                        ForEach(hours.lowerBound..<hours.upperBound, id: \.self) { hour in
                            Color.clear.frame(height: hourHeight).id(hour)
                        }
                        // Room under the day's end, so the hour it opens on can stand at the top.
                        Color.clear.frame(height: max(Self.inset, geometry.size.height - CGFloat(rest) * hourHeight))
                    }
                    .overlay(alignment: .topLeading) {
                        canvas(hours: hours, hourHeight: hourHeight, width: geometry.size.width, calendar: calendar)
                    }
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: DeskAxisScroll.self, of: { DeskAxisScroll(column: $0.containerSize.height, offset: $0.contentOffset.y) }) { old, new in
                    if old.column != new.column {
                        // A taller or shorter column, whose hours change height: the same hour at the top.
                        scroll(proxy, to: topHour ?? opening)
                    } else if pendingScrolls == 0 {
                        let hourHeight = Self.hourHeight(column: new.column, rest: rest)
                        topHour = hours.lowerBound + Int((new.offset / hourHeight).rounded())
                    }
                }
                .onAppear {
                    guard openedOn == nil else { return }
                    openedOn = opening
                    topHour = opening
                    scroll(proxy, to: opening)
                }
            }
        }
    }

    /// Scrolls once this update is over and the column has its size, so the scroll view does not cut the offset
    /// short to the height it had.
    private func scroll(_ proxy: ScrollViewProxy, to hour: Int) {
        pendingScrolls += 1
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                proxy.scrollTo(hour, anchor: .top)
                pendingScrolls -= 1
            }
        }
    }

    /// The points an hour is given: the rest of the day over the column, spread over `fewestHours` at least, and
    /// never fewer than `minimumHourHeight`.
    static func hourHeight(column: CGFloat, rest: Int) -> CGFloat {
        max(minimumHourHeight, ((column - inset) / CGFloat(max(rest, fewestHours))).rounded(.down))
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
                if hour < hours.upperBound {
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 11 * scale).monospacedDigit())
                        .foregroundStyle(.secondary)
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
    private func block(_ item: DeskAxisItem, height: CGFloat) -> some View {
        let isPast = item.end <= minute
        switch item {
        case let .line(.event(event)):
            let color = colors[event.id.calendar] ?? ParityTheme.accent
            let isDark = colorScheme == .dark
            let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
            Button { onOpenEvent(event) } label: {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(CalendarText.title(event))
                        .font(.system(size: 11.5 * scale, weight: .semibold))
                        .lineLimit(height >= 34 ? 2 : 1)
                    if event.awaitsAnswer, height >= 30 {
                        Text(L10n.string("Not replied"))
                            .font(.system(size: 10 * scale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.top, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    if event.awaitsAnswer {
                        ZStack {
                            shape.fill(color.opacity(isDark ? 0.14 : 0.08))
                            CalendarDiagonalStripes(spacing: 8)
                                .stroke(color.opacity(isDark ? 0.24 : 0.16), lineWidth: 1)
                        }
                        .clipShape(shape)
                    } else {
                        shape
                            .fill(color.opacity(isPast ? (isDark ? 0.14 : 0.10) : (isDark ? 0.25 : 0.16)))
                            .overlay(shape.strokeBorder(color.opacity(isPast ? 0.18 : 0.28), lineWidth: 0.5))
                            .overlay(alignment: .leading) { Rectangle().fill(color.opacity(isPast ? 0.5 : 1)).frame(width: 3) }
                            .clipShape(shape)
                    }
                }
                .overlay {
                    // Not answered yet: the calendar's color as a dashed outline, as the week draws it.
                    if event.awaitsAnswer {
                        shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1.25, dash: [4, 2]))
                    }
                }
                .opacity(isPast ? 0.62 : 1)
                .overlay { highlight(item) }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(CalendarText.title(event) + ", " + DeskTodayZone.time(event.start))
            .accessibilityValue(event.awaitsAnswer ? L10n.string("Not replied") : "")
        case let .line(.run(run)):
            Button { onOpenSchedule(run.schedule.id) } label: {
                runLabel(run.schedule.name, item: item,
                         style: run.kind == .failed ? AnyShapeStyle(.red) : isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(run.schedule.name + ", " + DeskTodayZone.time(run.at))
            .accessibilityValue(DeskTodayZone.note(run.kind))
        case let .ran(start, _, count):
            let title = L10n.format("%lld of today's runs already ran", count)
            Button(action: onShowRan) {
                runLabel(title, item: item, style: AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(title + ", " + DeskTodayZone.time(start))
        }
    }

    /// A run's block, or a folded hour's: a clock and a name with a subtle diagonal hatch.
    private func runLabel(_ name: String, item: DeskAxisItem, style: AnyShapeStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
        return HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 9 * scale, weight: .semibold))
            Text(name).font(.system(size: 11 * scale, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(style)
        .padding(.horizontal, 6)
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
        .overlay { highlight(item) }
        .contentShape(shape)
    }

    @ViewBuilder
    private func highlight(_ item: DeskAxisItem) -> some View {
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

/// What the time axis reads of its scroll view: how tall its column stands, and how far down it is scrolled.
private struct DeskAxisScroll: Equatable {
    let column: CGFloat
    let offset: CGFloat
}
