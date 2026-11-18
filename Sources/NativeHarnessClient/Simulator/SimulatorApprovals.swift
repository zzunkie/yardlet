import Foundation

/// The devices the person let agents use. Yardlet asks before a task's agent first uses a device, whatever the task's
/// permission mode, as the Claude app asks once per device. A simulator's or an emulator's approval holds for every
/// task, and is kept in Yardlet's preferences, so turning the Simulator switch off or removing Yardlet takes it with
/// it. A real device's holds only for the task it was given in, and only while Yardlet runs: kept for every task, it
/// would let any later task, a scheduled run's or one that asks nothing, reach a phone signed in to real accounts
/// (`SimulatorDeviceKind.approvalHoldsForEveryTask`).
@MainActor
final class SimulatorApprovals {
    static let key = "YardletSimulatorApprovedDevices"

    private let defaults: UserDefaults
    private var perTask: [UUID: Set<SimulatorDeviceIdentity>] = [:]

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
    }

    func isApproved(_ device: SimulatorDeviceIdentity, for task: UUID) -> Bool {
        device.kind.approvalHoldsForEveryTask ? saved.contains(device) : perTask[task]?.contains(device) == true
    }

    func approve(_ device: SimulatorDeviceIdentity, for task: UUID) {
        if device.kind.approvalHoldsForEveryTask {
            var devices = saved
            guard devices.insert(device).inserted else { return }
            save(devices)
        } else {
            perTask[task, default: []].insert(device)
        }
    }

    /// The person takes the approval back, in every task: the next tool on the device asks again.
    func revoke(_ device: SimulatorDeviceIdentity) {
        var devices = saved
        if devices.remove(device) != nil { save(devices) }
        for task in Array(perTask.keys) {
            perTask[task]?.remove(device)
            if perTask[task]?.isEmpty == true { perTask[task] = nil }
        }
    }

    /// Whether the person approved the device for every task, or for any task now.
    func isApprovedAnywhere(_ device: SimulatorDeviceIdentity) -> Bool {
        saved.contains(device) || perTask.values.contains { $0.contains(device) }
    }

    /// The Simulator switch turned off: every approval goes.
    func removeAll() {
        perTask = [:]
        defaults.removeObject(forKey: Self.key)
    }

    func taskRemoved(_ task: UUID) {
        perTask[task] = nil
    }

    /// Each approval as "<kind>:<id>", the kind first: an AVD's name may hold a colon, a kind never does.
    private var saved: Set<SimulatorDeviceIdentity> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap { entry in
            guard let colon = entry.firstIndex(of: ":"),
                  let kind = SimulatorDeviceKind(rawValue: String(entry[..<colon])), kind.approvalHoldsForEveryTask
            else { return nil }
            return SimulatorDeviceIdentity(kind: kind, value: String(entry[entry.index(after: colon)...]))
        })
    }

    private func save(_ devices: Set<SimulatorDeviceIdentity>) {
        guard !devices.isEmpty else { return defaults.removeObject(forKey: Self.key) }
        defaults.set(devices.map { "\($0.kind.rawValue):\($0.value)" }.sorted(), forKey: Self.key)
    }
}
