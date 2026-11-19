import Foundation
import YardletAgentTools

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
    /// devices Yardlet started, the screens' helper ends, installs stop, and Yardlet offers to remove what it
    /// installed. Called once the saved tasks are read, since the center reads their attachments.
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
        let wasOn = followedSimulatorPreference == true
        followedSimulatorPreference = isOn
        if !isOn {
            endSimulatorScreens()
            // The person's approvals of devices go with the feature (`SimulatorApprovals`).
            simulatorTools.approvals.removeAll()
            simulatorTools.handoffs.removeAll()
            simulatorInstalls.cancelAll()
        }
        Task {
            await simulators.setEnabled(isOn)
            // Turned off, not merely found off at launch: once the devices Yardlet started have stopped, which an
            // emulator does by writing its snapshot into its AVD, offer to remove what Yardlet installed and is still
            // as it left it.
            if wasOn, !isOn { await offerToRemoveSimulatorInstalls() }
        }
    }

    func offerToRemoveSimulatorInstalls() async {
        let items = await simulatorInstalls.removableItems()
        guard !items.isEmpty, await askToRemoveSimulatorInstalls(items) else { return }
        let failures = await simulatorInstalls.remove(items)
        if !failures.isEmpty { reportSimulatorRemovalFailures(failures) }
    }
}

/// The agents' simulator tools (`SimulatorAgentTools`, docs/SIMULATOR.md, "Agent tools"), answered against the same
/// simulator center the Simulator tab uses.
extension AppModel: SimulatorToolHandling {
    var simulatorSwitchIsOn: Bool { SimulatorPreference.isOn(in: preferences) }

    var simulatorPlatformIsUsable: Bool { simulators.offersDevices }

    func callSimulatorTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
        await simulatorTools.run(tool: name, arguments: arguments, task: callerID)
    }

    func makeSimulatorTools() -> SimulatorAgentTools {
        let tools = SimulatorAgentTools(center: { [unowned self] in simulators },
                                        approvals: SimulatorApprovals(defaults: preferences))
        tools.askPerson = { [weak self] device, task in await self?.asksToUseSimulator(device, task: task) ?? false }
        tools.taskTitle = { [weak self] id in self?.store.sessions.first { $0.id == id }?.title }
        tools.showPanel = { [weak self] task in self?.showSimulatorTab(for: task) ?? .notShown }
        tools.lastPersonInput = { [weak self] device in self?.simulators.lastPersonInput(on: device) }
        tools.handoffStarted = { [weak self] task, device, handoff in
            self?.simulatorHandoffStarted(task, device: device, handoff: handoff)
        }
        tools.handoffWaitCeiling = { [weak self] task in self?.handoffWaitCeiling(for: task) ?? .seconds(25 * 60) }
        tools.handoffs.onSettled = { [weak self] notice in
            self?.systemNotificationCenter.removeNotifications(identifiers: [notice])
        }
        return tools
    }

    /// The agent handed the task's device to the person (`simulator_handoff`), as `browser_handoff` hands a tab over:
    /// the task's panel shows its Simulator tab, with the agent's reason and Done and Decline in a bar above the device,
    /// and a notification tells the person; a click opens the task with its panel on the tab. The notification goes
    /// when the handoff is answered or ends (`SimulatorHandoffs.onSettled`).
    func simulatorHandoffStarted(_ task: UUID, device: SimulatorDevice, handoff: SimulatorHandoff) {
        guard store.sessions.contains(where: { $0.id == task }) else { return }
        showHandedOverSimulator(of: task)
        let title = store.sessions.first { $0.id == task }?.title ?? ""
        let handoffs = simulatorTools.handoffs
        Task {
            guard (await systemNotificationCenter.authorization()).isDeliverable,
                  handoffs.waiting(for: task)?.id == handoff.id else { return }
            await systemNotificationCenter.post(SystemNotification(
                title: L10n.format("The agent needs you on %@", device.name),
                body: title.isEmpty ? handoff.reason : "\(title): \(handoff.reason)",
                identifier: handoff.notice, target: SystemNotificationTarget(sessionID: task, simulator: true)))
            // The handoff may have ended while the notification was on its way.
            if handoffs.waiting(for: task)?.id != handoff.id {
                systemNotificationCenter.removeNotifications(identifiers: [handoff.notice])
            }
        }
    }

    /// The task's panel shows its Simulator tab, the task in front staying: a device handed to the person, and a click on
    /// its notification.
    func showHandedOverSimulator(of task: UUID) {
        let workspace = taskWorkspaces.state(for: task)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.simulatorID,
                                                                    in: workspace.panels))
    }

    /// `simulator_attach` shows the task's Simulator tab, as the Claude app's attach shows its device, unless the
    /// person is using another tab of the task's side panel: the Simulator tab then joins the strip, and the panel
    /// stays on theirs. A subagent's call opens no panel.
    func showSimulatorTab(for task: UUID) -> SimulatorPanelShowing {
        guard store.sessions.contains(where: { $0.id == task }) else { return .notShown }
        let workspace = taskWorkspaces.state(for: task)
        let id = TaskSurfaceNavigationProjection.simulatorID
        if let shown = workspace.panels.trailingSurfaceID, shown != id, shown != TaskSurfaceNavigationProjection.launcherID {
            workspace.setPanels(TaskSurfaceNavigationProjection.addingTrailingTab(id, in: workspace.panels))
            return .besidePersonsTab
        }
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(id, in: workspace.panels))
        return .shown
    }

    /// Asks the person, on the request card in the calling task, to let its agent use the device, whatever the task's
    /// permission mode, and waits for the answer as the browser's file approval does (`allowsBrowserFile`): with no
    /// answer, the card is refused when the turn stops. A real device's card says what it can reach.
    func asksToUseSimulator(_ device: SimulatorDevice, task: UUID) async -> Bool {
        guard let caller = sessionToolCaller(task) else { return false }
        let request = SimulatorApprovalCard(device: device)
        return await askPerson(title: request.title, detail: request.detail, caller: caller)
    }
}

/// The words of the card that asks the person to let a task's agent use a device.
struct SimulatorApprovalCard: Equatable {
    var title: String
    var detail: String

    init(device: SimulatorDevice) {
        title = switch device.identity.kind {
        case .iOSSimulator: L10n.format("Let this task use the %@ simulator?", device.name)
        case .androidEmulator: L10n.format("Let this task use the %@ emulator?", device.name)
        case .androidDevice: L10n.format("Let this task use %@?", device.name)
        }
        var lines = device.osName.isEmpty ? [] : [device.osName]
        if device.identity.kind.isPhysical {
            lines.append(L10n.string("If real accounts are signed in on it, the agent can send messages or make payments."))
            lines.append(L10n.string("Pictures and text from its screen are sent to the model's provider."))
            lines.append(L10n.string("Allowed for this task only."))
        } else {
            lines.append(L10n.string("Once allowed, any task's agent can use it until you take that back in the Simulator tab."))
        }
        detail = lines.joined(separator: "\n")
    }
}
