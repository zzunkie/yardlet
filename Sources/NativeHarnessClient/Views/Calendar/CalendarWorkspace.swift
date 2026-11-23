import SwiftUI

/// The calendar beside its sidebar: the month and the days shown in the title bar's row with Today, the arrows and
/// Day or Week, and the days below, with a day's scheduled runs listed beside it in Day and the chosen event's
/// details in their place. While it shows, the calendar reads the days shown and the sidebar's upcoming
/// days (`CalendarCenter.show`), and nothing once it goes.
struct CalendarWorkspace: View {
    let center: CalendarCenter
    @Bindable var window: CalendarWindowState
    let schedules: [ScheduledTask]
    /// The window's title bar with the calendar's own row in it.
    let titleBar: (AnyView) -> AnyView
    let onOpenSchedule: (UUID) -> Void
    var showsList = true
    var onSelectEvent: ((CalendarEvent) -> Void)? = nil
    var onOpenConnectors: (() -> Void)? = nil
    /// "Hand to an agent…": a chat whose draft names the event.
    let onAskAgent: (CalendarEvent, CalendarAccount) -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        let events = center.events(in: window.range)
        let colors = CalendarColors.byCalendar(center)
        let chosen = window.selection.flatMap { key in events.first { $0.id == key } }
        let slots = center.showsSchedules
            ? CalendarScheduleSlot.slots(of: schedules, in: window.range, calendar: window.calendar) : []
        VStack(spacing: 0) {
            titleBar(AnyView(titleRow))
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            HStack(spacing: 0) {
                if showsList {
                    CalendarListRail(
                        center: center,
                        window: window,
                        schedules: schedules,
                        onSelectEvent: { event in
                            if let onSelectEvent {
                                onSelectEvent(event)
                            } else {
                                if !window.range.contains(event.start) { window.show(event.start, as: window.span) }
                                window.selection = event.id
                            }
                        },
                        onOpenConnectors: { onOpenConnectors?() }
                    )
                    .frame(width: 224)
                    Rectangle().fill(ParityTheme.separator).frame(width: 1)
                }
                CalendarDaysView(days: window.days, today: window.today, events: events, slots: slots,
                                 colors: colors, selection: window.selection, calendar: window.calendar,
                                 onSelect: { window.selection = window.selection == $0.id ? nil : $0.id },
                                 onOpenSchedule: onOpenSchedule,
                                 onShowDay: { day in
                                     window.show(day, as: .day)
                                     window.selection = nil
                                 })
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
                if chosen == nil, window.span == .day, !slots.isEmpty {
                    CalendarDayRunsList(slots: slots, calendar: window.calendar, onOpenSchedule: onOpenSchedule)
                        .id(window.range.start)
                } else if let chosen {
                    let account = center.account(chosen.id.calendar.accountID)
                    CalendarEventDetail(event: chosen,
                                        info: center.accountCalendars[chosen.id.calendar.accountID]?.first { $0.id == chosen.id.calendar },
                                        account: account, color: colors[chosen.id.calendar] ?? ParityTheme.accent,
                                        calendar: window.calendar,
                                        onRespond: { try await center.respond(to: chosen, $0) },
                                        onAskAgent: { if let account { onAskAgent(chosen, account) } },
                                        onClose: { window.selection = nil })
                }
            }
        }
        .onChange(of: window.readRanges, initial: true) { _, ranges in show(ranges) }
        .onDisappear {
            center.stopShowing(for: window.daysViewer)
            center.stopShowing(for: window.upcomingViewer)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            window.noteDayChanged()
        }
    }

    /// The days shown, and the upcoming days unless one range holds both.
    private func show(_ ranges: [DateInterval]) {
        center.show(ranges[0], for: window.daysViewer)
        if ranges.count > 1 {
            center.show(ranges[1], for: window.upcomingViewer)
        } else {
            center.stopShowing(for: window.upcomingViewer)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(CalendarText.month(window.range.start, calendar: window.calendar))
                    .font(.system(size: 15 * scale, weight: .semibold))
                Text(CalendarText.days(window.range, span: window.span, calendar: window.calendar))
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            WindowDragRegion().frame(maxWidth: .infinity)
            // Only the first read of the days shows; reading them again keeps what is shown.
            if center.loading.contains(where: { $0.contains(window.range) }),
               !center.shownEvents.keys.contains(where: { $0.contains(window.range) }) {
                ProgressView().controlSize(.mini).accessibilityLabel(L10n.string("Reading the calendar…"))
            }
            Button(L10n.string("Today")) { window.showToday() }
                .controlSize(.small)
                .disabled(window.showsToday && window.span == .week)
            ParityIconButton(systemName: "chevron.left",
                             help: L10n.string(window.span == .day ? "Previous day" : "Previous week")) { window.move(-1) }
            ParityIconButton(systemName: "chevron.right",
                             help: L10n.string(window.span == .day ? "Next day" : "Next week")) { window.move(1) }
            Picker(L10n.string("Calendar span"), selection: $window.span) {
                Text(L10n.string("Calendar day")).tag(CalendarSpan.day)
                Text(L10n.string("Calendar week")).tag(CalendarSpan.week)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Each calendar's color as its service gives it, else the accent.
@MainActor
enum CalendarColors {
    static func byCalendar(_ center: CalendarCenter) -> [CalendarKey: Color] {
        var colors: [CalendarKey: Color] = [:]
        for calendars in center.accountCalendars.values {
            for calendar in calendars { colors[calendar.id] = Color(calendarHex: calendar.color) ?? ParityTheme.accent }
        }
        return colors
    }
}

private struct CalendarCenterKey: EnvironmentKey {
    static let defaultValue: CalendarCenter? = nil
}

extension EnvironmentValues {
    /// The app's calendar, for the sidebar's Calendar word.
    var calendarCenter: CalendarCenter? {
        get { self[CalendarCenterKey.self] }
        set { self[CalendarCenterKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// Whether the sidebar's words offer Personal agents: another Mac's window shows its host's tasks, mail and calendar,
    /// and no personal agents.
    @Entry var offersPersonalAgents = true
}
