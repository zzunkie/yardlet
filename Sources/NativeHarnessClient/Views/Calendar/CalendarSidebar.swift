import SwiftUI

/// The calendar's inner left rail inside the detail surface: what comes next today and in the coming
/// days, every account's calendars to show or hide, and Yardlet's scheduled runs as a layer of their own.
struct CalendarListRail: View {
    let center: CalendarCenter
    let window: CalendarWindowState
    let schedules: [ScheduledTask]
    let onSelectEvent: (CalendarEvent) -> Void
    let onOpenConnectors: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    /// Upcoming rows listed at most.
    static let upcomingLimit = 8

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                if center.accounts.isEmpty {
                    noAccounts
                } else {
                    heading(L10n.string("Upcoming"))
                    upcoming
                    heading(L10n.string("Calendars")).padding(.top, 14)
                    calendarList
                }
                heading("Yardlet").padding(.top, center.accounts.isEmpty ? 0 : 8)
                CalendarToggleRow(title: L10n.string("Scheduled runs"), color: .secondary, isOn: center.showsSchedules,
                                  showsClock: true) { center.setShowsSchedules(!center.showsSchedules) }
            }
            .padding(.horizontal, SidebarMetrics.rowInset + 2)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(ParityTheme.innerRail)
    }

    // MARK: - Upcoming

    private enum Item: Identifiable {
        case event(CalendarEvent)
        /// A day's runs still to come, folded into one row: how many, from the first one's time.
        case runs(count: Int, from: Date)

        var id: String {
            switch self {
            case let .event(event): "\(event.id.calendar.accountID) \(event.id.calendar.calendarID) \(event.id.eventID) \(event.start.timeIntervalSinceReferenceDate)"
            case let .runs(_, from): "runs \(from.timeIntervalSinceReferenceDate)"
            }
        }

        var start: Date {
            switch self {
            case let .event(event): event.start
            case let .runs(_, from): from
            }
        }
    }

    /// What has not ended yet in the upcoming days, by day: events, all-day ones first, then the day's runs folded
    /// into one row while their layer shows, so the runs leave the events their rows.
    private var upcomingByDay: [(day: Date, items: [Item])] {
        let now = Date()
        let calendar = window.calendar
        let range = window.upcomingRange
        var items: [Item] = center.events(in: range).filter { $0.end > now }.map(Item.event)
        if center.showsSchedules {
            var runs: [(day: Date, count: Int, from: Date)] = []
            let toCome = DateInterval(start: max(now, range.start), end: range.end)
            for slot in CalendarScheduleSlot.slots(of: schedules, in: toCome, calendar: calendar) {
                let day = calendar.startOfDay(for: slot.at)
                if runs.last?.day == day { runs[runs.count - 1].count += 1 } else { runs.append((day, 1, slot.at)) }
            }
            items += runs.map { Item.runs(count: $0.count, from: $0.from) }
        }
        items.sort { first, second in
            let firstDay = calendar.startOfDay(for: max(first.start, range.start))
            let secondDay = calendar.startOfDay(for: max(second.start, range.start))
            if firstDay != secondDay { return firstDay < secondDay }
            if case .runs = first { return false }
            if case .runs = second { return true }
            if case let .event(event) = first, event.isAllDay { return true }
            if case let .event(event) = second, event.isAllDay { return false }
            return first.start < second.start
        }
        var days: [(day: Date, items: [Item])] = []
        for item in items.prefix(Self.upcomingLimit) {
            let day = calendar.startOfDay(for: max(item.start, range.start))
            if days.last?.day == day { days[days.count - 1].items.append(item) } else { days.append((day, [item])) }
        }
        return days
    }

    @ViewBuilder
    private var upcoming: some View {
        let days = upcomingByDay
        if days.isEmpty {
            Text(L10n.string(center.loading.isEmpty ? "Nothing in the coming days" : "Reading the calendar…"))
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .padding(.leading, SidebarMetrics.gutterWidth)
                .frame(height: SidebarMetrics.secondaryLineHeight)
        }
        let colors = CalendarColors.byCalendar(center)
        ForEach(days, id: \.day) { day in
            Text(CalendarText.day(day.day, today: window.today, calendar: window.calendar))
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .padding(.leading, SidebarMetrics.gutterWidth)
                .frame(height: 22 * scale)
                .accessibilityAddTraits(.isHeader)
            ForEach(day.items) { item in
                switch item {
                case let .event(event):
                    CalendarUpcomingRow(title: CalendarText.title(event), color: colors[event.id.calendar] ?? ParityTheme.accent,
                                        note: event.awaitsAnswer ? L10n.string("Not replied") : nil,
                                        time: event.isAllDay ? L10n.string("All day") : CalendarText.time(event.start, calendar: window.calendar),
                                        isSelected: window.selection == event.id) { onSelectEvent(event) }
                case let .runs(count, from):
                    CalendarUpcomingRow(title: L10n.format("%lld scheduled runs", count), color: nil, note: nil,
                                        time: L10n.format("from %@",
                                                          CalendarText.time(from, calendar: window.calendar)),
                                        isSelected: false) {
                        window.show(from, as: .day)
                        window.selection = nil
                    }
                    .accessibilityHint(L10n.string("Show the day's runs"))
                }
            }
        }
    }

    // MARK: - Calendars

    /// Every account's calendars under its heading; the Mac's under each account Calendar keeps them in.
    @ViewBuilder
    private var calendarList: some View {
        ForEach(center.accounts) { account in
            let calendars = center.calendars.filter { $0.id.accountID == account.id }
            let groups = account.provider == .apple
                ? Dictionary(grouping: calendars, by: { $0.source ?? "" }).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                : [(key: "", value: calendars)]
            // A lazy stack lists every account's groups together, so each is told apart by its account too.
            ForEach(groups.map { (id: account.id.uuidString + " " + $0.key, source: $0.key, calendars: $0.value) }, id: \.id) { group in
                Text(CalendarText.account(account, source: group.source))
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, SidebarMetrics.projectHeaderLeading - SidebarMetrics.rowInset)
                    .frame(height: 24 * scale)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.calendars) { calendar in
                    CalendarToggleRow(title: calendar.name, color: Color(calendarHex: calendar.color) ?? ParityTheme.accent,
                                      isOn: center.isShown(calendar)) {
                        center.setShown(!center.isShown(calendar), for: calendar)
                    }
                }
            }
            if let failure = center.failures[account.id] {
                Button(action: onOpenConnectors) {
                    Text(failure.message)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, SidebarMetrics.gutterWidth)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityHint(L10n.string("Opens Settings › Connectors"))
            }
        }
    }

    private var noAccounts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Connect Google Calendar, Outlook Calendar or Apple Calendar in Settings › Connectors to see your calendars here."))
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Open Connectors"), action: onOpenConnectors)
                .controlSize(.small)
        }
        .padding(.horizontal, SidebarMetrics.projectHeaderLeading - SidebarMetrics.rowInset)
        .padding(.bottom, 12)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: SidebarMetrics.projectHeaderFontSize * scale, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.projectHeaderLeading - SidebarMetrics.rowInset)
            .frame(height: SidebarMetrics.projectHeaderHeight * scale)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A coming event, or a day's runs: its calendar's color or a clock, its title, "Not replied" for an invitation to
/// answer, and its time.
private struct CalendarUpcomingRow: View {
    let title: String
    let color: Color?
    let note: String?
    let time: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.self) private var environment
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    if let color {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).frame(width: 3, height: 14 * scale)
                    } else {
                        Image(systemName: "clock").font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Text(title)
                    .font(.system(size: 13 * scale, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(ParityTheme.accentText) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let note {
                    Text(note)
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(ThemeContrast.readableTint(.orange,
                            over: ThemeSurface.canvas.resolve(in: environment), in: environment))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 6)
                }
                Text(time).font(.system(size: 12 * scale).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.rowHeight * scale)
            .background(isSelected ? AnyShapeStyle(ParityTheme.accentSoftFill)
                        : (isHovering ? AnyShapeStyle(ParityTheme.hoverFill) : AnyShapeStyle(.clear)),
                        in: SidebarMetrics.rowShape())
            .contentShape(SidebarMetrics.rowShape())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A calendar, or the scheduled runs' layer, with a box in its color that shows or hides it.
private struct CalendarToggleRow: View {
    let title: String
    let color: Color
    let isOn: Bool
    var showsClock = false
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundStyle(isOn ? color : Color.secondary)
                }
                if showsClock {
                    Image(systemName: "clock").font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.trailing, 5)
                }
                Text(title)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: SidebarMetrics.rowHeight * scale)
            .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
            .contentShape(SidebarMetrics.rowShape())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(L10n.string(isOn ? "Shown" : "Hidden"))
    }
}
