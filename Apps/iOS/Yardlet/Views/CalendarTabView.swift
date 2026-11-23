import SwiftUI
import YardletRemote

/// Live Calendar tab consuming `mailCalendarV2` over the connected Mac's remote channel.
struct CalendarTabView: View {
    let session: HostSession
    let store: MailCalendarStore
    let isActive: Bool
    var onOpenConnectors: () -> Void = {}

    @State private var selectedEventSheet: EventSheetItem?
    @State private var isRefreshingState = false

    private struct EventSheetItem: Identifiable {
        let id: String
        let snapshot: RemoteCalendarV2Event
    }

    private var dayEvents: [RemoteCalendarV2Event] {
        store.events(on: store.selectedDate)
    }

    var body: some View {
        Group {
            if store.calendarReady {
                readyContent
            } else {
                gateContent
            }
        }
        .background(YardletPalette.background)
        .sheet(item: $selectedEventSheet) { item in
            CalendarEventDetailSheet(store: store, eventKey: item.id, fallbackEvent: item.snapshot)
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                store.activateCalendarTab()
            }
        }
        .onChange(of: store.calendarReady) { _, ready in
            if !ready {
                selectedEventSheet = nil
            } else if isActive {
                store.activateCalendarTab()
            }
        }
    }

    // MARK: - Ready State

    private var readyContent: some View {
        VStack(spacing: 0) {
            monthAndNavigationHeader
            weekStrip
            if store.calendars.count >= 2 {
                calendarFilterChips
            }
            eventsList
        }
    }

    private var monthAndNavigationHeader: some View {
        HStack(spacing: 8) {
            Text(store.selectedDate.formatted(.dateTime.year().month(.wide)))
                .font(.headline)
                .foregroundStyle(YardletPalette.onSurface)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Today") {
                store.selectToday()
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(YardletPalette.onSurface)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(YardletPalette.surfaceContainer, in: Capsule())
            .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button {
                    store.moveWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurface)
                        .frame(width: 32, height: 32)
                        .background(YardletPalette.surfaceContainerLow, in: Circle())
                        .overlay(Circle().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous Week")

                Button {
                    store.moveWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurface)
                        .frame(width: 32, height: 32)
                        .background(YardletPalette.surfaceContainerLow, in: Circle())
                        .overlay(Circle().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next Week")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var weekStrip: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return HStack(spacing: 4) {
            ForEach(store.weekDays, id: \.timeIntervalSinceReferenceDate) { day in
                let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
                let isToday = cal.isDate(day, inSameDayAs: today)
                let hasEvents = store.hasEvents(on: day)

                Button {
                    store.selectDate(day)
                } label: {
                    VStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isSelected ? YardletPalette.onPrimary.opacity(0.85) : YardletPalette.onSurfaceVariant)
                            .lineLimit(1)

                        Text(day.formatted(.dateTime.day()))
                            .font(.subheadline.weight(isSelected || isToday ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? YardletPalette.onPrimary : YardletPalette.onSurface)

                        Circle()
                            .fill(hasEvents
                                  ? (isSelected ? YardletPalette.onPrimary : YardletPalette.onSurfaceVariant)
                                  : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(YardletPalette.primary)
                        } else if isToday {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(YardletPalette.surfaceContainer)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(YardletPalette.outline, lineWidth: 0.75)
                                )
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
        }
    }

    private var calendarFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                calendarChip(
                    title: String(localized: "All Calendars"),
                    colorHex: nil,
                    showDot: false,
                    isSelected: store.selectedCalendarKey == nil
                ) {
                    store.selectCalendar(nil)
                }
                ForEach(store.calendars, id: \.compositeKey) { calendar in
                    calendarChip(
                        title: calendar.name,
                        colorHex: calendar.color,
                        showDot: true,
                        isSelected: store.selectedCalendarKey == calendar.compositeKey
                    ) {
                        store.selectCalendar(calendar.compositeKey)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func calendarChip(
        title: String,
        colorHex: String?,
        showDot: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showDot {
                    Circle()
                        .fill(MailCalendarStore.calendarColor(hex: colorHex))
                        .frame(width: 7, height: 7)
                }
                Text(verbatim: title)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? YardletPalette.onPrimary : YardletPalette.onSurfaceVariant)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isSelected ? YardletPalette.primary : YardletPalette.surfaceContainerLow,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : YardletPalette.outlineVariant,
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var eventsList: some View {
        List {
            if store.eventsTruncated {
                Text("Showing the first \(RemoteMailCalendarV2Limits.maxEvents) events in this period.")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
            }

            if let error = store.calendarError, !store.events.isEmpty {
                inlineErrorRow(error) {
                    store.loadCalendar(clearEvents: false)
                }
            }

            if store.calendarLoading && store.events.isEmpty {
                HStack(spacing: 10) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading events…")
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                    Spacer()
                }
                .padding(.vertical, 36)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if let error = store.calendarError, store.events.isEmpty {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Couldn't Load Calendar")
                            .font(.headline)
                            .foregroundStyle(YardletPalette.onSurface)
                        Text(verbatim: error)
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Button("Retry") {
                            store.loadCalendar(clearEvents: true)
                        }
                        .prominentButton()
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } else if dayEvents.isEmpty {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.title2)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Text("No Events")
                            .font(.headline)
                            .foregroundStyle(YardletPalette.onSurface)
                        Text("You have no scheduled events on \(store.selectedDate.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } else {
                ForEach(dayEvents, id: \.compositeKey) { event in
                    eventRow(event)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YardletPalette.background)
        .refreshable {
            await store.refreshCalendar()
        }
    }

    private func eventRow(_ event: RemoteCalendarV2Event) -> some View {
        Button {
            selectedEventSheet = EventSheetItem(id: event.compositeKey, snapshot: event)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(MailCalendarStore.calendarColor(hex: event.calendarColor))
                        .frame(width: 8, height: 8)
                    Text(timeRangeLabel(for: event))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                    Spacer(minLength: 8)
                    if let badge = rsvpBadgeLabel(for: event.responseStatus) {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                    }
                }

                Text(event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? String(localized: "(No title)")
                     : event.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(event.responseStatus == .declined ? YardletPalette.onSurfaceVariant : YardletPalette.onSurface)
                    .strikethrough(event.responseStatus == .declined)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text(verbatim: location)
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                }

                Text(verbatim: event.calendarName)
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                YardletPalette.surfaceContainerLow,
                in: RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func inlineErrorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        MonochromeCard(fill: YardletPalette.errorContainer, border: YardletPalette.error.opacity(0.35), padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(YardletPalette.error)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurface)
                Spacer(minLength: 8)
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurface)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func timeRangeLabel(for event: RemoteCalendarV2Event) -> String {
        if event.allDay { return String(localized: "All day") }
        let start = Date(timeIntervalSince1970: Double(event.startMs) / 1_000)
        if event.endMs <= event.startMs {
            return start.formatted(date: .omitted, time: .shortened)
        }
        let end = Date(timeIntervalSince1970: Double(event.endMs) / 1_000)
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func rsvpBadgeLabel(for status: RemoteCalendarV2ResponseStatus) -> LocalizedStringKey? {
        switch status {
        case .accepted: "Accepted"
        case .tentative: "Maybe"
        case .declined: "Declined"
        case .needsAction: "Invited"
        case .none: nil
        }
    }

    // MARK: - Gate Cards

    private var gateContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.title3)
                                .foregroundStyle(YardletPalette.onSurface)
                                .frame(width: 34, height: 34)
                                .background(YardletPalette.surfaceContainerHigh,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text("Calendar")
                                .font(.headline)
                                .foregroundStyle(YardletPalette.onSurface)
                            Spacer(minLength: 8)
                            gateStatusBadge
                        }

                        Text(gateMessage)
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)

                        gateActions
                    }
                }
            }
            .padding(16)
        }
        .background(YardletPalette.background)
        .refreshable {
            if session.isConnected {
                await store.refreshState()
            } else {
                await session.refresh()
            }
        }
    }

    @ViewBuilder
    private var gateStatusBadge: some View {
        if !session.isConnected {
            pillBadge(color: YardletPalette.Status.running, title: "Offline")
        } else if let state = store.v2State {
            if !state.permitted {
                pillBadge(color: YardletPalette.Status.question, title: "Permission Off")
            } else {
                pillBadge(color: YardletPalette.Status.running, title: "Not Set Up")
            }
        } else if store.stateLoading {
            ProgressView().controlSize(.mini)
        } else if store.stateError != nil {
            pillBadge(color: YardletPalette.Status.failed, title: "Unavailable")
        } else {
            pillBadge(color: YardletPalette.Status.running, title: "Unavailable")
        }
    }

    private func pillBadge(color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(YardletPalette.surfaceContainer, in: Capsule())
        .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
    }

    private var gateMessage: String {
        if !session.isConnected {
            return String(localized: "Connect to \(session.name) to view your schedule.")
        }
        if let state = store.v2State {
            if !state.permitted {
                return String(localized: "To use Mail and Calendar from here, allow Mail and Calendar for this device in Settings › Remote › Paired devices on \(session.name).")
            }
            if !state.calendarEnabled {
                return String(localized: "Turn on Calendar in Yardlet on \(session.name) to view your schedule here.")
            }
            return String(localized: "Connect a calendar account in Yardlet on \(session.name) to view your schedule here.")
        }
        if let error = store.stateError {
            return error
        }
        if store.stateLoading {
            return String(localized: "Checking Mail and Calendar access on \(session.name)…")
        }
        return String(localized: "Couldn't check Mail and Calendar status on \(session.name).")
    }

    @ViewBuilder
    private var gateActions: some View {
        if !session.isConnected {
            Button("Retry") { session.reconnectNow() }
                .prominentButton()
        } else if store.v2State == nil && !store.stateLoading {
            Button("Retry") {
                Task { await store.refreshState() }
            }
            .prominentButton()
        } else if let state = store.v2State {
            HStack(spacing: 10) {
                if state.permitted && (!state.calendarEnabled || !state.calendarConnected) && session.capabilities.hostAccounts {
                    Button("Manage Connectors", action: onOpenConnectors)
                        .prominentButton()
                }
                Button {
                    isRefreshingState = true
                    Task {
                        await store.refreshState()
                        isRefreshingState = false
                    }
                } label: {
                    if isRefreshingState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh Status")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingState)
            }
        }
    }
}

// MARK: - Event Detail Sheet

private struct CalendarEventDetailSheet: View {
    let store: MailCalendarStore
    let eventKey: String
    let fallbackEvent: RemoteCalendarV2Event

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var event: RemoteCalendarV2Event {
        store.events.first(where: { $0.compositeKey == eventKey }) ?? fallbackEvent
    }

    private var meetingURL: URL? {
        MailCalendarStore.safeMeetingURL(event.meetingUrl)
    }

    private var isResponding: Bool {
        store.rsvpBusyKey == event.compositeKey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = store.calendarActionError {
                        MonochromeCard(fill: YardletPalette.errorContainer, border: YardletPalette.error.opacity(0.35), padding: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(YardletPalette.error)
                                Text(verbatim: error)
                                    .font(.footnote)
                                    .foregroundStyle(YardletPalette.onSurface)
                                Spacer(minLength: 8)
                                Button {
                                    store.calendarActionError = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss")
                            }
                        }
                    }

                    summaryCard

                    if let meetingURL {
                        Button {
                            openURL(meetingURL)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "video")
                                Text("Join Meeting")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .prominentButton()
                    }

                    if event.canRespond {
                        rsvpCard
                    }

                    if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        notesCard(notes)
                    }

                    if event.organizer != nil || !event.attendees.isEmpty {
                        peopleCard
                    }
                }
                .padding(16)
            }
            .background(YardletPalette.background)
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            store.calendarActionError = nil
        }
        .onChange(of: store.calendarReady) { _, ready in
            if !ready { dismiss() }
        }
    }

    private var summaryCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? String(localized: "(No title)")
                     : event.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock")
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .frame(width: 18)
                    Text(verbatim: detailedScheduleText)
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(MailCalendarStore.calendarColor(hex: event.calendarColor))
                        .frame(width: 9, height: 9)
                        .frame(width: 18)
                    Text(verbatim: event.calendarName)
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }

                if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .frame(width: 18)
                        Text(verbatim: location)
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurface)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var rsvpCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Response")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                    Spacer()
                    if isResponding {
                        ProgressView().controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    rsvpButton("Accept", target: .accepted, activeStatus: .accepted)
                    rsvpButton("Maybe", target: .tentative, activeStatus: .tentative)
                    rsvpButton("Decline", target: .declined, activeStatus: .declined)
                }
            }
        }
    }

    private func rsvpButton(
        _ title: LocalizedStringKey,
        target: RemoteCalendarV2InvitationResponse,
        activeStatus: RemoteCalendarV2ResponseStatus
    ) -> some View {
        let isSelected = event.responseStatus == activeStatus
        return Button {
            Task {
                _ = await store.respondToEvent(event, response: target)
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? YardletPalette.onPrimary : YardletPalette.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    isSelected ? YardletPalette.primary : YardletPalette.surfaceContainer,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : YardletPalette.outlineVariant, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .disabled(store.rsvpBusyKey != nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func notesCard(_ notes: String) -> some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Text(verbatim: notes)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurface)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var peopleCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                if let organizer = event.organizer {
                    Text("Organizer")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                    personRow(organizer)
                }

                if !event.attendees.isEmpty {
                    if event.organizer != nil {
                        Rectangle()
                            .fill(YardletPalette.outlineVariant)
                            .frame(height: 0.5)
                            .padding(.vertical, 2)
                    }
                    Text("Attendees")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                    ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                        personRow(attendee)
                    }
                    if event.attendeesTruncated == true {
                        Text("Additional attendees not shown.")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func personRow(_ person: RemoteCalendarV2Person) -> some View {
        let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let primary = !name.isEmpty ? name : email
        let secondary = (!name.isEmpty && !email.isEmpty && name != email) ? email : nil

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: primary.isEmpty ? String(localized: "Unknown") : primary)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurface)
                    .lineLimit(1)
                if let secondary {
                    Text(verbatim: secondary)
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let status = person.responseStatus, let label = attendeeStatusLabel(status) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(YardletPalette.surfaceContainerHigh, in: Capsule())
            }
        }
    }

    private func attendeeStatusLabel(_ status: RemoteCalendarV2ResponseStatus) -> LocalizedStringKey? {
        switch status {
        case .accepted: "Accepted"
        case .tentative: "Maybe"
        case .declined: "Declined"
        case .needsAction: "Invited"
        case .none: nil
        }
    }

    private var detailedScheduleText: String {
        if event.allDay {
            return MailCalendarStore.allDayRangeLabel(startDate: event.startDate, endDate: event.endDate)
        }
        let start = Date(timeIntervalSince1970: Double(event.startMs) / 1_000)
        if event.endMs <= event.startMs {
            return start.formatted(date: .abbreviated, time: .shortened)
        }
        let end = Date(timeIntervalSince1970: Double(event.endMs) / 1_000)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))"
    }
}
