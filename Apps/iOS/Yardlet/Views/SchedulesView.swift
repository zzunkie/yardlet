import SwiftUI
import YardletRemote

/// Which screen of a Mac's navigation stack shows its scheduled tasks.
struct SchedulesRoute: Hashable {}

/// The Mac's scheduled tasks (docs/REMOTE_PROTOCOL.md §15.21), in its order and its own words: when each runs, its
/// status and its latest run, a mark while the task of that run works, and Pause or Resume as a switch. Run now is a
/// swipe or the row's menu away, and a row opens the task its latest run started. Creating, editing and deleting stay
/// on the Mac.
struct SchedulesView: View {
    let session: HostSession
    @State private var list: ScheduleList
    @Environment(\.openTask) private var openTask

    init(session: HostSession) {
        self.session = session
        _list = State(initialValue: ScheduleList(session: session))
    }

    var body: some View {
        List {
            if list.isLoaded && list.schedules.isEmpty {
                ContentUnavailableView("No Scheduled Tasks", systemImage: "clock",
                                       description: Text("Scheduled tasks you make on \(session.name) show up here."))
                    .listRowSeparator(.hidden)
            } else if !list.isLoaded && list.failedToLoad && session.isConnected {
                ContentUnavailableView {
                    Label("Couldn't Load the Scheduled Tasks", systemImage: "clock")
                } actions: {
                    Button("Retry") { list.read() }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(list.schedules, id: \.id) { schedule in
                row(schedule)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YardletPalette.background)
        .overlay {
            if !list.isLoaded && !list.failedToLoad && session.isConnected { ProgressView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(session: session) }
        .safeAreaInset(edge: .bottom, spacing: 0) { CommandErrorBanner(session: session).padding(.bottom, 8) }
        .refreshable { await list.refresh() }
        .navigationTitle("Scheduled Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(YardletPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // Read when the screen opens and on every connection; the Mac tells of changes only to a connection that asked.
        .onChange(of: session.isConnected, initial: true) { _, connected in
            if connected { list.read() }
        }
        .onChange(of: session.schedulesChanges) { list.read() }
    }

    private func row(_ schedule: RemoteSchedule) -> some View {
        let task = schedule.lastRun?.taskId.flatMap { session.task($0) }
        let words = ScheduleRow(schedule: schedule, isStarting: list.starting.contains(schedule.id))
        return HStack(alignment: .center, spacing: 12) {
            if let task {
                Button {
                    openTask(task.id)
                } label: {
                    words.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the task its latest run started"))
            } else {
                words
            }
            Toggle(schedule.name, isOn: Binding(get: { schedule.enabled },
                                                set: { list.setEnabled(schedule.id, $0) }))
                .labelsHidden()
                // A one-off that ran or whose time passed is edited on the Mac, not resumed (§15.21).
                .disabled(!session.isConnected || (!schedule.enabled && schedule.canResume != true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(YardletPalette.surfaceContainerLow,
                    in: RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.6)
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .leading) {
            Button {
                list.runNow(schedule.id)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .tint(YardletPalette.swipePrimary)
            .disabled(!session.isConnected || list.starting.contains(schedule.id))
        }
        .contextMenu {
            Button {
                list.runNow(schedule.id)
            } label: {
                Label("Run Now", systemImage: "play")
            }
            .disabled(!session.isConnected || list.starting.contains(schedule.id))
            if schedule.enabled {
                Button {
                    list.setEnabled(schedule.id, false)
                } label: {
                    Label("Pause", systemImage: "pause")
                }
            } else if schedule.canResume == true {
                Button {
                    list.setEnabled(schedule.id, true)
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
            }
            if let task {
                Button {
                    openTask(task.id)
                } label: {
                    Label("Open Task", systemImage: "arrow.forward.circle")
                }
            }
        }
    }
}

/// One schedule as the Mac's list words it: its name (quieter while off), when it runs and its status, and its latest
/// run with a mark while that run's task works, or, for a run that did not start, the failure mark. Under them the
/// harness and project, as the task list says them.
private struct ScheduleRow: View {
    let schedule: RemoteSchedule
    let isStarting: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TaskMark(indicator: schedule.running ? .running : nil)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.name)
                    .foregroundStyle(schedule.enabled ? .primary : .secondary)
                    .lineLimit(2)
                Text(verbatim: [schedule.when, isStarting ? String(localized: "Starting a run…") : schedule.status]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let run = schedule.lastRun, !run.line.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // Only a run that did not start is marked, in red as the task list marks a failure.
                        if run.outcome == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Failed")
                        }
                        Text(run.line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Text(verbatim: [schedule.harnessName, schedule.projectName].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
