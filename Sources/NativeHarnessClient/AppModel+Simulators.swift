import Foundation

/// The tasks' attached devices, kept in their workspace snapshots (`TaskWorkspaceSnapshot.simulator`).
@MainActor
final class TaskWorkspaceSimulatorAttachments: SimulatorAttachmentStore {
    private weak var workspaces: TaskWorkspaceStore?
    /// The tasks that are not archived, whose snapshots can attach a device.
    private let taskIDs: @MainActor () -> [UUID]

    init(workspaces: TaskWorkspaceStore, taskIDs: @escaping @MainActor () -> [UUID]) {
        self.workspaces = workspaces
        self.taskIDs = taskIDs
    }

    func simulatorAttachment(of task: UUID) -> SimulatorDeviceIdentity? {
        workspaces?.simulatorAttachment(of: task)
    }

    func setSimulatorAttachment(_ device: SimulatorDeviceIdentity?, of task: UUID) {
        guard let workspaces, workspaces.simulatorAttachment(of: task) != device else { return }
        workspaces.state(for: task).simulator = device
    }

    func tasksAttaching(_ device: SimulatorDeviceIdentity) -> Set<UUID> {
        guard let workspaces else { return [] }
        return Set(taskIDs().filter { workspaces.simulatorAttachment(of: $0) == device })
    }
}

extension AppModel {
    /// Hands the simulator center the tasks' workspaces and turns. It stays off, running nothing, until the Simulator
    /// switch turns it on (`SimulatorCenter.setEnabled(_:)`).
    func wireSimulators() {
        simulators.attachmentStore = TaskWorkspaceSimulatorAttachments(
            workspaces: taskWorkspaces, taskIDs: { [weak self] in self?.store.sessions.map(\.id) ?? [] })
        simulators.isTurnRunning = { [weak self] id in self?.isRunning(id) ?? false }
    }
}

extension AppModel {
    /// Follows Settings › General › Simulator from now on: on, the simulator center checks the platforms off the
    /// main thread, stops what an earlier Yardlet started and left unused, and lists the devices; off, it stops the
    /// devices Yardlet started and the screens' helper ends. Called once the saved tasks are read, since the center
    /// reads their attachments.
    func startSimulators(defaults: UserDefaults = .yardlet) {
        guard simulatorPreferenceObserver == nil else { return }
        nonisolated(unsafe) let watched = defaults
        simulatorPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.followSimulatorPreference(defaults: watched) }
        }
        followSimulatorPreference(defaults: defaults)
    }

    func followSimulatorPreference(defaults: UserDefaults = .yardlet) {
        // Any setting posts the change; only the switch's own turns the center on or off.
        let isOn = SimulatorPreference.isOn(in: defaults)
        guard isOn != followedSimulatorPreference else { return }
        followedSimulatorPreference = isOn
        if !isOn { endSimulatorScreens() }
        Task { await simulators.setEnabled(isOn) }
    }
}
