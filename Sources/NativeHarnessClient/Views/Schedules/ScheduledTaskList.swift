import SwiftUI

/// The sidebar's scheduled tasks. Like archived tasks, it takes the task list's place and Back
/// returns to it. Each row names the schedule, its harness and
/// when it runs next or why it does not; the detail beside it holds the rest. The schedules that will
/// run come first, soonest first (`ScheduleListSections`); under them, while any Claude Code task's
/// CLI holds one, "Session schedules": each such job with its task, which a click opens. Yardlet's own
/// addition, so it is not there at all without one. Last come two folded groups, the schedules that
/// are off and the one-offs that ran, as the Claude app's routines list hides completed ones until
/// asked; choosing a schedule in a folded group opens it.
struct ScheduledTaskList: View {
    let schedules: [ScheduledTask]
    var sessionJobs: [ScheduledSessionJob] = []
    let selection: UUID?
    let startingIDs: Set<UUID>
    let now: Date
    let nextRun: (ScheduledTask) -> Date?
    /// The folded groups that are open.
    @Binding var expandedSections: Set<ScheduleListSections.Section>
    let onBack: () -> Void
    let actions: ScheduledTaskActions
    var calendar: Calendar = .autoupdatingCurrent

    var body: some View {
        let sections = ScheduleListSections(schedules, nextRun: nextRun)
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
            .disabled(!actions.canEdit)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 4)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    if schedules.isEmpty, sessionJobs.isEmpty {
                        emptyLine(L10n.string("No scheduled tasks."))
                    } else if sections.upcoming.isEmpty, sessionJobs.isEmpty {
                        emptyLine(L10n.string("No scheduled task will run."))
                    }
                    ForEach(sections.upcoming) { row($0) }
                    if !sessionJobs.isEmpty {
                        Text(L10n.string("Session schedules"))
                            .font(.system(size: SidebarMetrics.projectHeaderFontSize))
                            .foregroundStyle(.secondary)
                            .frame(height: SidebarMetrics.projectHeaderHeight)
                            .padding(.leading, SidebarMetrics.projectHeaderLeading)
                            .padding(.top, sections.upcoming.isEmpty ? 0 : SidebarMetrics.groupBottomSpacing)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(sessionJobs.sorted {
                            ($0.job.nextRun(after: now)?.date ?? .distantFuture) < ($1.job.nextRun(after: now)?.date ?? .distantFuture)
                        }) { item in
                            ScheduledSessionJobRow(item: item, now: now, open: { actions.openTask(item.session.id) })
                                .padding(.horizontal, 4)
                        }
                    }
                    folded(.off, sections.off)
                    folded(.finished, sections.finished)
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
            .disabled(!actions.canImport)
        }
        .background(ParityTheme.sidebar)
        .onExitCommand(perform: onBack)
        .focusSection()
        .onChange(of: selection, initial: true) { _, id in
            // A schedule chosen from elsewhere, as a conversation's Open does, shows even in a folded group.
            guard let id, let schedule = schedules.first(where: { $0.id == id }) else { return }
            let section = ScheduleListSections.section(of: schedule)
            if section != .upcoming, !expandedSections.contains(section) { expandedSections.insert(section) }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
    }

    private func row(_ entry: ScheduleListSections.Entry) -> some View {
        let schedule = entry.schedule
        let isStarting = startingIDs.contains(schedule.id)
        return ScheduledTaskRow(
            schedule: schedule,
            status: ScheduleText.row(schedule, nextRun: entry.nextRun, isStarting: isStarting, now: now, calendar: calendar),
            isSelected: selection == schedule.id,
            isStarting: isStarting,
            actions: actions)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func folded(_ section: ScheduleListSections.Section, _ entries: [ScheduleListSections.Entry]) -> some View {
        if !entries.isEmpty {
            let isExpanded = expandedSections.contains(section)
            ScheduleSectionHeader(
                section: section, count: entries.count, isExpanded: isExpanded,
                // A schedule that turned itself off without doing its work wants the person, folded or not.
                warns: section == .off && entries.contains { $0.schedule.hasStoppedItself },
                onToggle: {
                    if isExpanded { expandedSections.remove(section) } else { expandedSections.insert(section) }
                },
                onDeleteAll: section == .finished && actions.canEdit ? actions.deleteCompleted : nil)
            if isExpanded {
                ForEach(entries) { row($0) }
            }
        }
    }
}

/// The header of a folded group: its name, how many it holds, and the caret; for the one-offs that
/// ran, "Delete All…" in its menu, as a project's options sit in its header's.
struct ScheduleSectionHeader: View {
    let section: ScheduleListSections.Section
    let count: Int
    let isExpanded: Bool
    let warns: Bool
    let onToggle: () -> Void
    let onDeleteAll: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var title: String {
        switch section {
        case .upcoming: ""
        case .off: L10n.string("Off scheduled tasks group")
        case .finished: L10n.string("Completed scheduled tasks group")
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Text(title)
                        .foregroundStyle(isHovering ? .primary : .secondary)
                    Text(count, format: .number)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    if warns {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9 * interfaceScale))
                            .foregroundStyle(.orange)
                    }
                    DisclosureCaret(isOpen: isExpanded, size: 8 * interfaceScale)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                .font(.system(size: SidebarMetrics.projectHeaderFontSize * interfaceScale))
                .lineLimit(1)
                .padding(.leading, SidebarMetrics.projectHeaderLeading - SidebarMetrics.rowInset)
                .padding(.trailing, onDeleteAll != nil && isHovering ? 30 : SidebarMetrics.rowTrailingPadding)
                .frame(height: SidebarMetrics.projectHeaderHeight * interfaceScale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .accessibilityLabel(title)
            .accessibilityValue([L10n.format("%lld scheduled tasks", Int64(count)),
                                 L10n.string(isExpanded ? "Expanded" : "Collapsed")].joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)

            if let onDeleteAll, isHovering {
                Menu {
                    menuItems(onDeleteAll)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .parityPointer()
                .padding(.trailing, 3)
                .accessibilityLabel(L10n.format("%@ options", title))
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onDeleteAll { menuItems(onDeleteAll) }
        }
        .padding(.top, SidebarMetrics.groupBottomSpacing)
        .padding(.horizontal, SidebarMetrics.rowInset)
    }

    @ViewBuilder
    private func menuItems(_ onDeleteAll: @escaping () -> Void) -> some View {
        Button(L10n.string("Delete All…"), role: .destructive, action: onDeleteAll)
    }
}

/// One schedule: its harness, its name (with a mark when each run continues a task, as the Codex app's
/// heartbeat rows name the thread), and when it runs next and how it repeats, or why it does not.
struct ScheduledTaskRow: View {
    let schedule: ScheduledTask
    /// `ScheduleText.row`.
    let status: String
    let isSelected: Bool
    let isStarting: Bool
    let actions: ScheduledTaskActions
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var isQuiet: Bool { !schedule.isEnabled }
    private var continuesTask: Bool { schedule.destination.mode == .continueTask }
    private var eachRun: String {
        L10n.string(continuesTask ? "Each run continues a task." : "Each run starts a new task.")
    }

    var body: some View {
        Button { actions.select(schedule.id) } label: {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    HarnessIdentityIcon(harness: schedule.destination.harness,
                                        size: SidebarMetrics.nestedIconSize * interfaceScale)
                        .opacity(isQuiet ? 0.5 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(schedule.name)
                            .font(.system(size: 13 * interfaceScale))
                            .foregroundStyle(isQuiet ? .secondary : .primary)
                            .lineLimit(1)
                        if continuesTask {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9 * interfaceScale, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
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
        .help([schedule.name, ScheduleText.summary(schedule.trigger), status, eachRun].joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(schedule.name)
        .accessibilityValue("\(schedule.destination.harness.displayName), \(status), \(eachRun)")
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
            .disabled(!actions.canEdit)
        Divider()
        Button(L10n.string("Delete…"), role: .destructive) { actions.delete(schedule.id) }
            .disabled(!actions.canEdit)
    }
}
