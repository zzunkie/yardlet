import Foundation
import Observation
import YardletRemote

/// A host's scheduled tasks as its window lists them (docs/REMOTE_PROTOCOL.md §15.21): read when the list
/// first shows and again on each `schedulesChanged`, which the host sends only to a connection that asked;
/// Run now, Pause and Resume go through the host's own paths. Creating, editing and deleting stay on the
/// host.
@MainActor
@Observable
final class RemoteHostSchedules {
    /// In the host list's order: the ones that will run, soonest first, then those that are off, then the
    /// one-offs that ran. Nil until read.
    private(set) var list: [RemoteSchedule]?
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
            guard let self, response.ok else { return }
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

    private func refused(_ response: RemoteResponse) {
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
