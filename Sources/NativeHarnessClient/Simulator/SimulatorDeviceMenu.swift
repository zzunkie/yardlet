import Foundation

/// The Simulator tab's device menu, as what it offers: another device to show, taking the device's input from
/// another task, letting go of the device, and shutting down a device Yardlet started, which says that Yardlet
/// shuts it down once it is unused. Built from what the simulator center knows, so it is checked without opening a
/// menu.
struct SimulatorDeviceMenu: Equatable {
    enum Item: Equatable {
        /// The task attached the device while another task has its input: "Use in This Task" takes it, naming
        /// the task that has it.
        case useInThisTask(heldBy: String)
        case disconnect
        /// Shuts down a device Yardlet started.
        case shutDown
        /// Yardlet started the device and shuts it down once no task uses it.
        case startedByYardletNote
    }

    /// The devices "Switch Device" lists: those that are on first, then by runtime, as the panel's list.
    var devices: [SimulatorListEntry]
    var items: [Item]

    /// - Parameter taskTitle: another task's title, or nil when it is gone.
    @MainActor
    static func make(for task: UUID, in center: SimulatorCenter, taskTitle: (UUID) -> String?) -> Self {
        let entries = center.entries(for: task)
        guard let attached = entries.first(where: \.isAttachedHere) else { return Self(devices: entries, items: []) }
        var items: [Item] = []
        if let holder = attached.claimingTask, holder != task {
            items.append(.useInThisTask(heldBy: taskTitle(holder) ?? L10n.string("Another task")))
        }
        items.append(.disconnect)
        if attached.isStartedByYardlet {
            if attached.device.state.isRunning { items.append(.shutDown) }
            items.append(.startedByYardletNote)
        }
        return Self(devices: entries, items: items)
    }
}
