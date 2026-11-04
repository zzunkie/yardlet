import Foundation
import Observation
import YardletRemote

/// A host's scheduled tasks as its window lists them (docs/REMOTE_PROTOCOL.md §15.21): read when the list
/// first shows and again on each `schedulesChanged`, which the host sends only to a connection that asked;
/// Reading and editing go through the host's own paths; this Mac keeps only presentation state.
@MainActor
@Observable
final class RemoteHostSchedules {
    /// In the host list's order: the ones that will run, soonest first, then those that are off, then the
    /// one-offs that ran. Nil until read.
    private(set) var list: [RemoteSchedule]?
    var canEdit = false
    var timeZone: String?
    var sessionJobs: [ScheduledSessionJob] = []
    var window = ScheduledTasksWindowState()
    /// Schedules whose Run now is on its way to the host.
    private(set) var starting: Set<String> = []
    /// The list was asked for on this window, so it follows the host's changes.
    @ObservationIgnored private(set) var isFollowing = false
    @ObservationIgnored weak var model: RemoteHostModel?

    func schedule(_ id: String) -> RemoteSchedule? {
        list?.first { $0.id == id }
    }

    /// Reads the list; while connected, the host tells of each change from then on.
    func load() {
        isFollowing = true
        model?.request(.scheduledTasks) { [weak self] response in
            guard let self else { return }
            refused(response)
            guard response.ok else { return }
            canEdit = response.scheduleEditing == true
            timeZone = response.scheduleTimeZone
            sessionJobs = (response.sessionSchedules ?? []).compactMap { item in
                guard let session = model?.sidebar.sessions.first(where: { $0.id.uuidString == item.taskId }),
                      let job = try? JSONDecoder().decode(ClaudeSessionJob.self, from: item.job) else { return nil }
                return ScheduledSessionJob(session: session, job: job)
            }
            let schedules = response.schedules ?? []
            if schedules != list { list = schedules }
        }
    }

    /// Run now, as the host's list and detail run it, also while it is paused.
    func runNow(_ id: String) {
        guard !starting.contains(id) else { return }
        starting.insert(id)
        model?.request(.runScheduledTask(scheduleID: id)) { [weak self] response in
            self?.starting.remove(id)
            self?.refused(response)
        }
    }

    /// Pause or Resume, as the host offers them.
    func setEnabled(_ id: String, _ enabled: Bool) {
        model?.request(.setScheduledTaskEnabled(scheduleID: id, enabled: enabled)) { [weak self] response in
            self?.refused(response)
        }
    }

    func refused(_ response: RemoteResponse) {
        guard !response.ok, let model else { return }
        model.commandError = response.error?.code == .busy
            ? L10n.string("This scheduled task is starting already.")
            : RemoteHostModel.message(for: response.error, host: model.name)
    }
}

/// Which group of the Mac's list a host's schedule is in (`ScheduleListSections`): the ones that will
/// run, those that are off (paused, stopped by themselves, or a one-off whose time passed unrun) and the
/// one-offs that ran.
extension RemoteSchedule {
    var section: ScheduleListSections.Section {
        if enabled { return .upcoming }
        return canResume == true || lastRun == nil ? .off : .finished
    }
}
