import SwiftUI

/// What the schedule views do, in one place for the sidebar list, the detail and the menus.
struct ScheduledTaskActions {
    var select: (UUID) -> Void = { _ in }
    var create: () -> Void = {}
    var importFromApps: () -> Void = {}
    var runNow: (UUID) -> Void = { _ in }
    var setEnabled: (UUID, Bool) -> Void = { _, _ in }
    var edit: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var openTask: (UUID) -> Void = { _ in }
}

/// The sidebar's scheduled tasks. Like archived tasks, it takes the task list's place and Back
/// returns to it. Each row names the schedule, its harness and
/// when it runs next or why it does not; the detail beside it holds the rest. Under them, while any
/// Claude Code task's CLI holds one, "Session schedules": each such job with its task, which a click
/// opens. Yardlet's own addition, so it is not there at all without one.
struct ScheduledTaskList: View {
    let schedules: [ScheduledTask]
    var sessionJobs: [ScheduledSessionJob] = []
    let selection: UUID?
    let startingIDs: Set<UUID>
    let now: Date
    let nextRun: (ScheduledTask) -> Date?
    let onBack: () -> Void
    let actions: ScheduledTaskActions

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onBack) {
                SidebarActionRow(systemName: "chevron.left", title: L10n.string("Scheduled tasks"),
                                 symbolWeight: .semibold, titleWeight: .medium, height: 32)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .help(L10n.string("Back to tasks"))
            .accessibilityLabel(L10n.string("Back to tasks"))
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary)

            Button(action: actions.create) {
                SidebarActionRow(systemName: "plus", title: L10n.string("New scheduled task"), symbolWeight: .bold,
                                 titleWeight: .medium, height: 32, isFilled: true)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 4)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    if schedules.isEmpty, sessionJobs.isEmpty {
                        Text(L10n.string("No scheduled tasks."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                    } else {
                        ForEach(schedules) { schedule in
                            ScheduledTaskRow(
                                schedule: schedule,
                                status: ScheduleText.status(schedule, nextRun: nextRun(schedule),
                                                            isStarting: startingIDs.contains(schedule.id), now: now),
                                isSelected: selection == schedule.id,
                                isStarting: startingIDs.contains(schedule.id),
                                actions: actions)
                                .padding(.horizontal, 4)
                        }
                    }
                    if !sessionJobs.isEmpty {
                        Text(L10n.string("Session schedules"))
                            .font(.system(size: SidebarMetrics.projectHeaderFontSize))
                            .foregroundStyle(.secondary)
                            .frame(height: SidebarMetrics.projectHeaderHeight)
                            .padding(.leading, SidebarMetrics.projectHeaderLeading)
                            .padding(.top, schedules.isEmpty ? 0 : SidebarMetrics.groupBottomSpacing)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(sessionJobs.sorted {
                            ($0.job.nextRun(after: now)?.date ?? .distantFuture) < ($1.job.nextRun(after: now)?.date ?? .distantFuture)
                        }) { item in
                            ScheduledSessionJobRow(item: item, now: now, open: { actions.openTask(item.session.id) })
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)

            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            Button(action: actions.importFromApps) {
                SidebarActionRow(systemName: "square.and.arrow.down",
                                 title: L10n.string("Import Schedules from Other Apps…"), height: 32)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.vertical, 5)
        }
        .background(ParityTheme.sidebar)
        .onExitCommand(perform: onBack)
        .focusSection()
    }
}

struct ScheduledTaskRow: View {
    let schedule: ScheduledTask
    let status: String
    let isSelected: Bool
    let isStarting: Bool
    let actions: ScheduledTaskActions
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var isQuiet: Bool { !schedule.isEnabled }

    var body: some View {
        Button { actions.select(schedule.id) } label: {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    HarnessIdentityIcon(harness: schedule.destination.harness,
                                        size: SidebarMetrics.nestedIconSize * interfaceScale)
                        .opacity(isQuiet ? 0.5 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(schedule.name)
                        .font(.system(size: 13 * interfaceScale))
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if schedule.state.stopReason == .repeatedFailures {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        } else if !schedule.isEnabled, schedule.state.stopReason == nil {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        Text(status)
                            .font(.system(size: 11 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                if isStarting {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                }
            }
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.twoLineRowHeight * interfaceScale)
            .contentShape(Rectangle())
            .background(isSelected ? ParityTheme.selectedFill : isHovering ? ParityTheme.hoverFill : .clear,
                        in: SidebarMetrics.rowShape())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { ScheduledTaskMenuItems(schedule: schedule, isStarting: isStarting, actions: actions) }
        .help([schedule.name, ScheduleText.summary(schedule.trigger), status].joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(schedule.name)
        .accessibilityValue("\(schedule.destination.harness.displayName), \(status)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: L10n.string("Run now")) { actions.runNow(schedule.id) }
    }
}

/// A session job in the scheduled tasks list: its task's title, then the job's schedule, next run and
/// end. A click opens the task; the job itself is the CLI's, which takes no request to change it.
struct ScheduledSessionJobRow: View {
    let item: ScheduledSessionJob
    let now: Date
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let detail = SessionJobText.detail(item.job, now: max(now, context.date))
            Button(action: open) {
                HStack(spacing: 0) {
                    SidebarRowLeading {
                        HarnessIdentityIcon(harness: item.session.harness,
                                            size: SidebarMetrics.nestedIconSize * interfaceScale)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.session.title)
                            .font(.system(size: 13 * interfaceScale))
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 11 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 3)
                }
                .padding(.trailing, SidebarMetrics.rowTrailingPadding)
                .frame(height: SidebarMetrics.twoLineRowHeight * interfaceScale)
                .contentShape(Rectangle())
                .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help([item.session.title, SessionJobText.title(item.job), detail].joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.session.title)
            .accessibilityValue(detail)
            .accessibilityHint(L10n.string("Open task"))
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Run now, Pause or Resume, Edit and Delete, as a row's menu and the detail's "…" menu list them.
struct ScheduledTaskMenuItems: View {
    let schedule: ScheduledTask
    let isStarting: Bool
    let actions: ScheduledTaskActions

    var body: some View {
        Button(L10n.string("Run now")) { actions.runNow(schedule.id) }
            .disabled(isStarting)
        if schedule.isEnabled {
            Button(L10n.string("Pause")) { actions.setEnabled(schedule.id, false) }
        } else if schedule.canResume {
            Button(L10n.string("Resume")) { actions.setEnabled(schedule.id, true) }
        }
        Button(L10n.string("Edit…")) { actions.edit(schedule.id) }
        Divider()
        Button(L10n.string("Delete…"), role: .destructive) { actions.delete(schedule.id) }
    }
}
