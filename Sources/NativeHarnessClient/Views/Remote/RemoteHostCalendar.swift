import SwiftUI
import YardletRemote

/// The host's calendar in its window (docs/REMOTE_PROTOCOL.md §15.38): the local calendar's sidebar and days over the
/// host's accounts, its scheduled runs the host's schedules, an event handed to an agent in a new chat on the host, and
/// the host's Settings for a sign-in. A device without the Mail and Calendar permission is told where to allow it.
extension RemoteHostView {
    /// The calendar shows in place of the tasks while the host's is on and the person chose it.
    var showsCalendar: Bool { shell.section == .calendar && model.calendar.isEnabled && !model.showsSchedules }

    func selectSection(_ section: ShellSection) {
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            model.showsSchedules = false
            model.showsArchive = false
            shell.isSidebarVisible = true
            shell.section = section
        }
        if section == .calendar, model.offersSchedules { model.schedules.load() }
        if section == .mail { model.mailbox.noteShown() }
    }

    @ViewBuilder var calendarDetail: some View {
        if model.needsMailCalendarPermission {
            VStack(spacing: 0) {
                RemoteTitleBar(context: titleBarContext) { WindowDragRegion().frame(maxWidth: .infinity) }
                RemoteConnectionBanner(model: model, directory: directory)
                RemotePermissionNote(text: permissionWords)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            CalendarWorkspace(
                center: model.calendar, window: shell.calendarWindow, schedules: model.schedules.definitions,
                titleBar: { accessory in
                    AnyView(VStack(spacing: 0) {
                        RemoteTitleBar(context: titleBarContext) { accessory }
                        RemoteConnectionBanner(model: model, directory: directory)
                    })
                },
                onOpenSchedule: openHostSchedule,
                onSelectEvent: showEvent,
                onOpenConnectors: { model.openSettings(section: SettingsSection.connectors.rawValue) },
                onAskAgent: { event, account in
                    askAgent(CalendarText.handoff(event, account: account, calendar: shell.calendarWindow.calendar))
                })
        }
    }

    /// One of the host's schedules, among the scheduled tasks.
    func openHostSchedule(_ id: UUID) {
        shell.section = .tasks
        model.showsArchive = false
        model.showsSchedules = true
        model.schedules.load()
        model.select(.schedule(id.uuidString))
    }

    /// The calendar at the event's day, the event chosen beside the days.
    func showEvent(_ event: CalendarEvent) {
        let window = shell.calendarWindow
        if !window.range.contains(event.start) { window.show(event.start, as: window.span) }
        window.selection = event.id
        selectSection(.calendar)
    }

    /// "Hand to an agent…": a new chat on the host whose draft names it, as the local window starts one.
    func askAgent(_ reference: String) {
        drafts.newTaskProjectID = RemoteTaskProjection.chatsProjectID
        let draft = drafts.newTask
        if !draft.text.contains(reference) {
            let kept = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.text = kept.isEmpty ? reference : kept + "\n\n" + reference
        }
        showHome()
    }

    var permissionWords: String {
        RemoteHostModel.message(for: RemoteError(.notAllowed, reason: .mailCalendar), host: model.name)
    }
}

/// What this device may not use until the host allows it, and where.
struct RemotePermissionNote: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }
}
