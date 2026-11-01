import AppKit
import SwiftUI

/// What the detail reads beside the schedule: its tasks, places and accounts by name.
struct ScheduledTaskContext {
    var task: (UUID) -> SessionRecord? = { _ in nil }
    var projectName: (ScheduledTask) -> String = { _ in "" }
    var accountName: (ScheduledTask) -> String? = { _ in nil }
}

/// A run's line in the history: when, how it came about, how its task stands now (the Codex
/// app's run states: running now, completed, failed, needs you), and the account it went to when its
/// own was nearly spent.
struct ScheduledRunRow: Identifiable, Equatable {
    enum State: Equatable {
        case running, waiting, completed, failed, skipped(ScheduledTaskRun.SkipReason), notStarted(String), gone
    }

    let id: UUID
    let at: Date
    let trigger: ScheduledTaskRun.Trigger
    let state: State
    let taskID: UUID?
    let title: String?
    let isUnread: Bool
    let switchLine: String?

    static func rows(for schedule: ScheduledTask, task: (UUID) -> SessionRecord?) -> [ScheduledRunRow] {
        schedule.state.runs.map { run in
            let session = run.taskID.flatMap(task)
            let state: State
            switch run.outcome {
            case .skipped: state = .skipped(run.skipReason ?? .previousRunActive)
            case .failed: state = .notStarted(run.failure ?? "")
            case .started:
                switch session?.status {
                case nil: state = .gone
                case .running?: state = .running
                case .waitingForApproval?: state = .waiting
                case .failed?: state = .failed
                case .completed?, .ready?: state = .completed
                }
            }
            return ScheduledRunRow(id: run.id, at: run.at, trigger: run.trigger, state: state,
                                   taskID: session?.id, title: session?.title,
                                   isUnread: session?.hasUnreadUpdate == true, switchLine: run.account?.switchLine)
        }
    }

    /// Today, Yesterday, Previous 7 days, Older — the Codex app's run history groups.
    static func groups(_ rows: [ScheduledRunRow], now: Date, calendar: Calendar = .autoupdatingCurrent)
        -> [(title: String, rows: [ScheduledRunRow])] {
        let today = calendar.startOfDay(for: now)
        func group(_ row: ScheduledRunRow) -> Int {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: row.at), to: today).day ?? 0
            switch days {
            case ...0: return 0
            case 1: return 1
            case 2...7: return 2
            default: return 3
            }
        }
        let titles = [L10n.string("Today"), L10n.string("Yesterday"), L10n.string("Previous 7 days"), L10n.string("Older")]
        let grouped = Dictionary(grouping: rows, by: group)
        return (0..<4).compactMap { index in grouped[index].map { (titles[index], $0) } }
    }

    var stateText: String {
        switch state {
        case .running: L10n.string("Running now")
        case .waiting: L10n.string("Needs your attention")
        case .completed: L10n.string("Run completed")
        case .failed: L10n.string("Run failed")
        case let .skipped(reason): ScheduleText.skipReason(reason)
        case let .notStarted(message):
            message.isEmpty ? L10n.string("Could not start") : L10n.format("Could not start: %@", message)
        case .gone: L10n.string("Its task is no longer in the sidebar")
        }
    }

    /// The line under the title: how the run stands, how it came about, and the account it switched to.
    var detailText: String {
        ([title == nil ? nil : stateText, ScheduleText.trigger(trigger), switchLine].compactMap { $0 })
            .joined(separator: " · ")
    }
}

/// The schedule shown beside the sidebar's list: what it runs, where and when, its actions, and its
/// run history grouped by day.
struct ScheduledTaskDetail: View {
    let schedule: ScheduledTask
    let nextRun: Date?
    let isStarting: Bool
    let now: Date
    let context: ScheduledTaskContext
    let actions: ScheduledTaskActions

    private var destination: ScheduleDestination { schedule.destination }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let notice { noticeView(notice) }
                details
                promptCard
                history
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
                Text(verbatim: "\(ScheduleText.summary(schedule.trigger, now: now)) · "
                     + ScheduleText.status(schedule, nextRun: nextRun, isStarting: isStarting, now: now))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                actions.runNow(schedule.id)
            } label: {
                Label(L10n.string("Run now"), systemImage: "play.fill")
            }
            .disabled(isStarting)
            .parityPointer()
            if schedule.isEnabled {
                Button(L10n.string("Pause")) { actions.setEnabled(schedule.id, false) }
                    .parityPointer()
            } else if schedule.trigger.isRecurring || schedule.state.stopReason == nil {
                Button(L10n.string("Resume")) { actions.setEnabled(schedule.id, true) }
                    .parityPointer()
            }
            Button(L10n.string("Edit…")) { actions.edit(schedule.id) }
                .parityPointer()
            Menu {
                Button(L10n.string("Delete…"), role: .destructive) { actions.delete(schedule.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.string("More"))
        }
    }

    private struct Notice {
        let text: String
        let systemImage: String
        let tint: Color
    }

    private var notice: Notice? {
        if schedule.state.stopReason == .repeatedFailures {
            let failure = schedule.state.runs.first { $0.outcome == .failed }?.failure
            let text = L10n.format("Turned off after %lld failed starts", Int64(ScheduleRunPolicy.failureLimit))
                + (failure.map { ": \($0)" } ?? ".")
            return Notice(text: text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let origin = schedule.origin {
            return Notice(text: ScheduleText.origin(origin) + " " + L10n.string(
                "To keep it from running twice, turn the original off in that app or keep that app closed; it runs schedules only while it is open."),
                systemImage: "square.and.arrow.down", tint: .secondary)
        }
        return nil
    }

    private func noticeView(_ notice: Notice) -> some View {
        Label {
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: notice.systemImage).foregroundStyle(notice.tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detailRows.enumerated()), id: \.offset) { index, row in
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
                if index < detailRows.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .parityCard(cornerRadius: 10)
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        switch destination.mode {
        case .continueTask:
            let title = destination.targetTaskID.flatMap(context.task)?.title
            rows.append((L10n.string("Each run"), title.map { L10n.format("Continues “%@”", $0) }
                         ?? L10n.string("Continues a task that is no longer in Yardlet")))
        case .newTask:
            rows.append((L10n.string("Each run"), L10n.string("Starts a new task")))
            rows.append((L10n.string("Project"), context.projectName(schedule)))
            if destination.workspacePath != nil {
                rows.append((L10n.string("Runs in"), destination.startsInNewWorktree
                             ? L10n.string("New worktree") : L10n.string("Local")))
            }
            var harness = destination.harness.displayName
            if let account = context.accountName(schedule) { harness += " · " + account }
            rows.append((L10n.string("Harness"), harness))
            let choice = destination.modelChoice
            let model = [choice?.model, choice?.effort].compactMap { $0 }.joined(separator: " · ")
            rows.append((L10n.string("Model"), model.isEmpty ? L10n.string("Default") : model))
            if let mode = choice?.permissionMode {
                rows.append((L10n.string("Permissions"), ClaudePermissionMode.displayName(mode) ?? mode))
            }
        }
        rows.append((L10n.string("Next run"), nextRun.map { ScheduleText.moment($0, relativeTo: now) } ?? "—"))
        rows.append((L10n.string("Last run"), schedule.state.lastRunAt.map { ScheduleText.moment($0, relativeTo: now) } ?? "—"))
        return rows
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Instructions"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(schedule.prompt)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .parityCard(cornerRadius: 10)
        }
    }

    private var history: some View {
        let rows = ScheduledRunRow.rows(for: schedule, task: context.task)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Runs"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(L10n.string("No runs yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ScheduledRunRow.groups(rows, now: now), id: \.title) { group in
                    Text(group.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(group.rows) { row in
                            runRow(row)
                            if row.id != group.rows.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                    .parityCard(cornerRadius: 10)
                }
            }
        }
    }

    private func runRow(_ row: ScheduledRunRow) -> some View {
        // The time, the dot and the chevron on the run's first line, not between its two lines.
        let capHeightSize = NSFont.preferredFont(forTextStyle: .callout).pointSize
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(row.isUnread ? ParityTheme.accent : .clear)
                .frame(width: 6, height: 6)
                .centeredOnCapHeight(ofTextSize: capHeightSize)
            Text(ScheduleText.moment(row.at, relativeTo: now))
                .font(.callout.monospacedDigit())
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title ?? row.stateText)
                    .font(.callout)
                    .lineLimit(1)
                Text(row.detailText)
                    .font(.caption)
                    .foregroundStyle(stateTint(row.state))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if row.taskID != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .centeredOnCapHeight(ofTextSize: capHeightSize)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        return Group {
            if let taskID = row.taskID {
                Button { actions.openTask(taskID) } label: { content }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .help(L10n.string("Open task"))
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stateTint(_ state: ScheduledRunRow.State) -> Color {
        switch state {
        case .failed, .notStarted: .red
        case .waiting: .orange
        default: .secondary
        }
    }
}

/// The detail's place when no schedule is chosen: what scheduled tasks are and the two ways to add one.
struct ScheduledTaskEmptyDetail: View {
    let hasSchedules: Bool
    let actions: ScheduledTaskActions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.string(hasSchedules ? "Choose a scheduled task." : "No scheduled tasks."))
                .font(.title3.weight(.semibold))
            Text(L10n.string("Yardlet starts a scheduled task while it is open. A run missed while it was closed runs once when it opens again."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button(L10n.string("New scheduled task"), action: actions.create)
                    .parityProminentButton()
                    .parityPointer()
                Button(L10n.string("Import Schedules from Other Apps…"), action: actions.importFromApps)
                    .parityPointer()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
    }
}
