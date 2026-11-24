import Foundation

/// A Simulator tab's device menu, as what it offers: another device to show, taking the device's input from
/// another task, letting go of the device, taking back the person's approval for agents to use it, and shutting down a
/// device Yardlet started, which says that Yardlet shuts it down once it is unused. Built from what the simulator center knows, so it is checked without opening a
/// menu.
struct SimulatorDeviceMenu: Equatable {
    enum Item: Equatable {
        /// The task attached a real device while another task has its input: "Use in This Task" takes it, naming
        /// the task that has it.
        case useInThisTask(heldBy: String)
        case disconnect
        /// The person let agents use the device (`SimulatorApprovals`): taking it back makes the next tool ask again.
        case revokeAgentAccess
        /// Shuts down a device Yardlet started.
        case shutDown
        /// Yardlet started the device and shuts it down once no task uses it.
        case startedByYardletNote
    }

    /// The devices "Switch Device" lists: those that are on first, then by runtime, as the panel's list.
    var devices: [SimulatorListEntry]
    var items: [Item]

    /// - Parameter taskTitle: another task's title, or nil when it is gone.
    /// - Parameter approvals: the devices the person let agents use; nil offers no item for them.
    @MainActor
    static func make(for task: UUID, tab: UUID, in center: SimulatorCenter, taskTitle: (UUID) -> String?,
                     approvals: SimulatorApprovals? = nil) -> Self {
        let entries = center.entries(for: task, tab: tab)
        guard let attached = entries.first(where: \.isAttachedHere) else { return Self(devices: entries, items: []) }
        var items: [Item] = []
        // A simulator or emulator another task uses is not taken from it: the tab offers this task a copy.
        if let holder = attached.claimingTask, holder != task, attached.device.identity.kind.isPhysical {
            items.append(.useInThisTask(heldBy: taskTitle(holder) ?? L10n.string("Another task")))
        }
        items.append(.disconnect)
        if approvals?.isApprovedAnywhere(center.original(of: attached.device.identity)) == true {
            items.append(.revokeAgentAccess)
        }
        // Another task's simulator is not this tab's to shut down.
        if attached.isStartedByYardlet, !center.attachesCopy(attached.device.identity, for: task) {
            if attached.device.state.isRunning { items.append(.shutDown) }
            items.append(.startedByYardletNote)
        }
        return Self(devices: entries, items: items)
    }
}
