import SwiftUI
import YardletRemote

/// The host's scheduled tasks in its window's sidebar, as the Mac's sidebar lists its own
/// (`ScheduledTaskList`): Back to the tasks, then the ones that will run, soonest first, and two folded
/// groups, those that are off and the one-offs that ran, in the host's order and words
/// (docs/REMOTE_PROTOCOL.md §15.21). Run now, Pause and Resume act through the host; creating, editing and
/// deleting are the host's, so they show without acting.
struct LegacyRemoteScheduleList: View {
    let model: RemoteHostModel
    @State private var expanded: Set<ScheduleListSections.Section> = []
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var schedules: [RemoteSchedule] { model.schedules.list ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: back) {
                SidebarActionRow(systemName: "chevron.left", title: L10n.string("Scheduled tasks"),
                                 symbolWeight: .semibold, titleWeight: .medium, height: 32)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 10)
            .help(L10n.string("Back to tasks"))
            .accessibilityLabel(L10n.string("Back to tasks"))

            SidebarActionRow(systemName: "plus", title: L10n.string("New scheduled task"), symbolWeight: .bold,
                             titleWeight: .medium, height: 32, isFilled: true)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 4)
                .help(L10n.format("Create scheduled tasks on %@.", model.name))
                .accessibilityElement(children: .combine)
                .accessibilityHint(L10n.format("Create scheduled tasks on %@.", model.name))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    let upcoming = schedules.filter { $0.section == .upcoming }
                    if model.schedules.list == nil {
                        line(L10n.string("Loading…"))
                    } else if schedules.isEmpty {
                        line(L10n.string("No scheduled tasks."))
                    } else if upcoming.isEmpty {
                        line(L10n.string("No scheduled task will run."))
                    }
                    ForEach(upcoming, id: \.id) { row($0) }
                    folded(.off)
                    folded(.finished)
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
        .onExitCommand(perform: back)
        .onChange(of: model.selection, initial: true) { _, selection in
            // A schedule chosen while its group is folded shows, as on the Mac.
            guard case let .schedule(id) = selection, let section = model.schedules.schedule(id)?.section,
                  section != .upcoming else { return }
            expanded.insert(section)
        }
    }

    /// Back to the tasks, as the Mac's Back returns from its list, leaving no schedule shown.
    private func back() {
        model.showsSchedules = false
        if case .schedule = model.selection { model.select(.none) }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
    }

    private func row(_ schedule: RemoteSchedule) -> some View {
        RemoteScheduleRow(schedule: schedule, isSelected: model.selection == .schedule(schedule.id),
                          isStarting: model.schedules.starting.contains(schedule.id), model: model)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func folded(_ section: ScheduleListSections.Section) -> some View {
        let entries = schedules.filter { $0.section == section }
        if !entries.isEmpty {
            let isExpanded = expanded.contains(section)
            ScheduleSectionHeader(
                section: section, count: entries.count, isExpanded: isExpanded,
                warns: section == .off && entries.contains(where: Self.stoppedItself),
                onToggle: { if isExpanded { expanded.remove(section) } else { expanded.insert(section) } },
                onDeleteAll: nil)
            if isExpanded {
                ForEach(entries, id: \.id) { row($0) }
            }
        }
    }

    /// Off without being paused: it turned itself off after its starts failed.
    static func stoppedItself(_ schedule: RemoteSchedule) -> Bool {
        !schedule.enabled && schedule.lastRun?.outcome == .failed
    }
}

/// One of the host's schedules, as the Mac's row draws one (`ScheduledTaskRow`): its harness, its name, and
/// the host's line for when it runs next or why it does not.
private struct RemoteScheduleRow: View {
    let schedule: RemoteSchedule
    let isSelected: Bool
    let isStarting: Bool
    let model: RemoteHostModel
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var status: String { isStarting ? L10n.string("Starting a run…") : schedule.status ?? schedule.when }

    var body: some View {
        Button { model.select(.schedule(schedule.id)) } label: {
            HStack(spacing: 0) {
                SidebarRowLeading {
                    HarnessIdentityIcon(harness: HarnessCatalog.harness(named: schedule.harnessName) ?? .claudeCode,
                                        size: SidebarMetrics.nestedIconSize * interfaceScale)
                        .opacity(schedule.enabled ? 1 : 0.5)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(schedule.name)
                        .font(.system(size: 13 * interfaceScale))
                        .foregroundStyle(schedule.enabled ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if LegacyRemoteScheduleList.stoppedItself(schedule) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        } else if !schedule.enabled, schedule.canResume == true {
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
                if isStarting || schedule.running {
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
        .contextMenu { RemoteScheduleMenuItems(schedule: schedule, isStarting: isStarting, model: model) }
        .help([schedule.name, schedule.when, schedule.status].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(schedule.name)
        .accessibilityValue("\(schedule.harnessName), \(status)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: L10n.string("Run now")) { model.schedules.runNow(schedule.id) }
    }
}

/// Run now and Pause or Resume through the host; Edit and Delete, which are the host's, shown without acting.
private struct RemoteScheduleMenuItems: View {
    let schedule: RemoteSchedule
    let isStarting: Bool
    let model: RemoteHostModel

    var body: some View {
        Button(L10n.string("Run now")) { model.schedules.runNow(schedule.id) }
            .disabled(isStarting)
        if schedule.enabled {
            Button(L10n.string("Pause")) { model.schedules.setEnabled(schedule.id, false) }
        } else if schedule.canResume == true {
            Button(L10n.string("Resume")) { model.schedules.setEnabled(schedule.id, true) }
        }
        Button(L10n.string("Edit…")) {}
            .disabled(true)
        Divider()
        Button(L10n.string("Delete…"), role: .destructive) {}
            .disabled(true)
    }
}

/// A schedule of the host beside the list, as the Mac's detail heads one (`ScheduledTaskDetail`): its name,
/// when it runs and its status, Run now and Pause or Resume, then where it runs, its next run and its latest
/// run, which opens the task it started. Its instructions, full run history, Edit and Delete stay on the host.
struct LegacyRemoteScheduleDetail: View {
    let model: RemoteHostModel
    let schedule: RemoteSchedule

    private var isStarting: Bool { model.schedules.starting.contains(schedule.id) }
    private var elsewhere: String { L10n.format("See its instructions and runs, or edit or delete it, on %@.", model.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if LegacyRemoteScheduleList.stoppedItself(schedule), let line = schedule.lastRun?.line {
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
                }
                details
                if let run = schedule.lastRun { latestRun(run) }
                Text(elsewhere)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ParityTheme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(schedule.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(verbatim: [schedule.when, schedule.status].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                model.schedules.runNow(schedule.id)
            } label: {
                Label(L10n.string("Run now"), systemImage: "play.fill")
            }
            .disabled(isStarting)
            .parityPointer()
            if schedule.enabled {
                Button(L10n.string("Pause")) { model.schedules.setEnabled(schedule.id, false) }
                    .parityPointer()
            } else if schedule.canResume == true {
                Button(L10n.string("Resume")) { model.schedules.setEnabled(schedule.id, true) }
                    .parityPointer()
            }
            Button(L10n.string("Edit…")) {}
                .disabled(true)
                .help(elsewhere)
        }
    }

    /// The latest run as the Mac's run history draws a run: when, the task it started, and the host's line for
    /// it; it opens that task when the host lists it.
    private func latestRun(_ run: RemoteSchedule.Run) -> some View {
        let taskID = run.taskId.flatMap { model.task($0) == nil ? nil : $0 }
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ScheduleText.moment(Date(timeIntervalSince1970: TimeInterval(run.at) / 1000)))
                .font(.callout.monospacedDigit())
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let title = taskID.flatMap({ model.task($0)?.title }) {
                    Text(title).font(.callout).lineLimit(1)
                }
                Text(run.line)
                    .font(.caption)
                    .foregroundStyle(run.outcome == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if taskID != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Runs"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if let taskID {
                    Button { model.select(.task(taskID)) } label: { content }
                        .buttonStyle(.plain)
                        .parityPointer()
                        .help(L10n.string("Open task"))
                } else {
                    content
                }
            }
            .parityCard(cornerRadius: 10)
            .accessibilityElement(children: .combine)
        }
    }

    private var details: some View {
        let rows = detailRows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(row.1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if index < rows.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .parityCard(cornerRadius: 10)
    }

    private var detailRows: [(String, String)] {
        let next = schedule.nextRunAt.map { ScheduleText.moment(Date(timeIntervalSince1970: TimeInterval($0) / 1000)) }
        return [(L10n.string("Project"), schedule.projectName ?? L10n.string("Chats")),
                (L10n.string("Harness"), schedule.harnessName),
                (L10n.string("Next run"), next ?? "—")]
    }
}
