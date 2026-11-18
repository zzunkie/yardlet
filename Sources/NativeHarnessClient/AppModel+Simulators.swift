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
