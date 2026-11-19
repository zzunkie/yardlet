import SwiftUI

/// What a conversation's created-schedule rows read from the app: the schedule as it is now, and
/// Open, which shows it in Scheduled tasks.
struct ScheduledTaskRowActions {
    /// The schedule now; nil once it was deleted.
    var schedule: @MainActor (UUID) -> ScheduledTask?
    /// When it runs next, as Scheduled tasks says it.
    var nextRun: @MainActor (ScheduledTask) -> Date?
    var isStarting: @MainActor (UUID) -> Bool = { _ in false }
    var now: @MainActor () -> Date = Date.init
    /// Shows the schedule in Scheduled tasks.
    var open: @MainActor (UUID) -> Void
}

private struct ScheduledTaskRowActionsKey: EnvironmentKey {
    static let defaultValue: ScheduledTaskRowActions? = nil
}

extension EnvironmentValues {
    /// The window's schedules. Nil where the conversation has none to open (a row then shows the
    /// name the call gave).
    var scheduledTaskRowActions: ScheduledTaskRowActions? {
        get { self[ScheduledTaskRowActionsKey.self] }
        set { self[ScheduledTaskRowActionsKey.self] = newValue }
    }
}

/// A schedule an agent created (`create_scheduled_task`), as one outlined row where the call happened:
/// a clock, the schedule's name over its rule and next run, and Open, which shows it in Scheduled
/// tasks. It reads the schedule as it draws, so a pause, change or delete made since shows; a deleted
/// one reads "Deleted" without Open.
struct ScheduledTaskCreatedRow: View {
    let creation: ConversationScheduleCreation

    static let maximumWidth: CGFloat = 480

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.scheduledTaskRowActions) private var actions

    var body: some View {
        let schedule = actions?.schedule(creation.scheduleID)
        let name = schedule?.name ?? creation.name
        let detail = detail(schedule)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 13 * interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13 * interfaceScale, weight: .medium))
                    .foregroundStyle(schedule == nil && actions != nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actions, schedule != nil {
                Button(L10n.string("Open")) { actions.open(creation.scheduleID) }
                    .parityLinkButton()
                    .font(.system(size: 12 * interfaceScale))
                    .parityPointer()
                    .help(L10n.format("Open %@ in Scheduled tasks", name))
                    .accessibilityLabel(L10n.format("Open %@ in Scheduled tasks", name))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.strongSeparator)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Scheduled task %@", name))
    }

    /// The rule and when it runs next ("Every day at 9:00 AM · Next run Tomorrow at 9:00 AM"), or why
    /// it does not; "Deleted" once it is gone.
    private func detail(_ schedule: ScheduledTask?) -> String {
        guard let actions else { return L10n.string("Scheduled task") }
        guard let schedule else { return L10n.string("Deleted") }
        let now = actions.now()
        let status = ScheduleText.status(schedule, nextRun: actions.nextRun(schedule),
                                         isStarting: actions.isStarting(schedule.id), now: now)
        // A one-off's rule is its next run, said once.
        if case .once = schedule.trigger { return L10n.string("Once") + " · " + status }
        return ScheduleText.summary(schedule.trigger, now: now) + " · " + status
    }
}
