import Foundation
import YardletRemote

/// Notifications, the Dock badge share, and menu bar items from other Macs whose windows are open
/// (`RemoteHostDirectory`).
extension AppModel {
    /// Connects the open host windows (`RemoteHostDirectory`) to this Mac's notifications, Dock
    /// badge and menu bar item.
    func followRemoteHosts(_ directory: RemoteHostDirectory) {
        remoteHosts = directory
        openRemoteTask = { [weak directory] hostID, taskID in
            directory?.reveal(hostID: hostID, taskID: taskID)
        }
        allowRemoteOnce = { [weak directory] hostID, taskID, requestID in
            await directory?.allowOnce(hostID: hostID, taskID: taskID, requestID: requestID) ?? false
        }
        directory.onWithdrawTaskNotification = { [weak self] hostID, taskID in
            self?.withdrawRemoteTaskNotification(hostID: hostID, taskID: taskID)
        }
        directory.onAttention = { [weak self] host, event in
            self?.handleRemoteHostAttention(host: host, event: event)
        }
    }

    /// How many tasks in open host windows count toward this Mac's Dock badge.
    var remoteAttentionBadgeCount: Int {
        remoteHosts?.attentionBadgeCount ?? 0
    }

    /// Open, connected host windows' tasks for the menu bar menu (`MenuBarMenuProjection`).
    func remoteMenuBarHostTasks() -> [MenuBarMenuProjection.RemoteHostTasks] {
        guard let remoteHosts else { return [] }
        return remoteHosts.connectedModels.compactMap { host in
            guard !host.attentionTaskIDs.isEmpty else { return nil }
            let mirror = host.sidebar
            return MenuBarMenuProjection.RemoteHostTasks(
                hostID: host.id,
                hostName: host.name,
                sessions: mirror.sessions,
                details: mirror.details,
                place: { mirror.place(of: $0) }
            )
        }
    }

    /// Handles an `.attention` event from an open host window.
    func handleRemoteHostAttention(host: RemoteHostModel, event: RemoteEvent) {
        if RemoteAttentionNotice.withdrawn(hostID: host.id, event: event) != nil {
            if let taskID = event.taskId {
                withdrawRemoteTaskNotification(hostID: host.id, taskID: taskID)
            }
            return
        }
        guard let taskID = event.taskId else { return }
        if event.state == .waiting {
            dockAttention?.announceApproval(
                event.requestId ?? "",
                in: Self.remoteApprovalSessionID(hostID: host.id, taskID: taskID)
            )
        }
        // The task shown in the window in front needs no banner, and clears any earlier one for it.
        if isRemoteTaskShownInFront(host: host, taskID: taskID) {
            withdrawRemoteTaskNotification(hostID: host.id, taskID: taskID, forgetApprovals: event.state != .waiting)
            return
        }
        guard let notice = RemoteAttentionNotice.notification(
            hostID: host.id,
            hostName: host.name,
            event: event,
            offersAllowOnce: host.offersAllowOnce(event)
        ) else { return }
        let key = Self.remoteNotificationKey(hostID: host.id, taskID: taskID)
        remoteNotificationWithdrawn.remove(key)
        remoteNotificationTasks.removeValue(forKey: key)?.cancel()
        let generation = advanceRemoteNotificationGeneration(hostID: host.id, taskID: taskID)
        remoteNotificationTasks[key] = Task { [weak self, weak host] in
            guard let self else { return }
            defer {
                if self.remoteNotificationGenerations[key] == generation {
                    self.remoteNotificationTasks[key] = nil
                }
            }
            guard (await self.systemNotificationCenter.authorization()).isDeliverable else { return }
            guard !Task.isCancelled,
                  self.remoteNotificationGenerations[key] == generation,
                  !self.remoteNotificationWithdrawn.contains(key),
                  self.remoteTaskStillNeedsNotification(host: host, taskID: taskID) else { return }
            await self.systemNotificationCenter.post(notice)
            if self.remoteNotificationWithdrawn.contains(key)
                || !self.remoteTaskStillNeedsNotification(host: host, taskID: taskID) {
                self.systemNotificationCenter.removeNotifications(identifiers: [notice.identifier])
            }
        }
    }

    /// Withdraws a remote task's notification once its wait is answered, its unread turn is read, or
    /// the task leaves the host's list.
    func withdrawRemoteTaskNotification(hostID: String, taskID: String, forgetApprovals: Bool = true) {
        let key = Self.remoteNotificationKey(hostID: hostID, taskID: taskID)
        remoteNotificationWithdrawn.insert(key)
        remoteNotificationTasks.removeValue(forKey: key)?.cancel()
        advanceRemoteNotificationGeneration(hostID: hostID, taskID: taskID)
        let identifier = RemoteAttentionNotice.identifier(hostID: hostID, taskID: taskID)
        systemNotificationCenter.removeNotifications(identifiers: [identifier])
        if forgetApprovals {
            dockAttention?.forgetApprovals(in: Self.remoteApprovalSessionID(hostID: hostID, taskID: taskID))
        }
    }

    @discardableResult
    private func advanceRemoteNotificationGeneration(hostID: String, taskID: String) -> UInt64 {
        let key = Self.remoteNotificationKey(hostID: hostID, taskID: taskID)
        let next = (remoteNotificationGenerations[key] ?? 0) &+ 1
        remoteNotificationGenerations[key] = next
        return next
    }

    private func remoteTaskStillNeedsNotification(host: RemoteHostModel?, taskID: String) -> Bool {
        guard let host,
              remoteHosts?.openHostIDs.contains(host.id) == true,
              host.isConnected,
              !isRemoteTaskShownInFront(host: host, taskID: taskID),
              let current = host.task(taskID),
              RemoteSidebarMirror.needsAttention(current) else {
            return false
        }
        return true
    }

    private func isRemoteTaskShownInFront(host: RemoteHostModel, taskID: String) -> Bool {
        applicationAttention?.isActive == true
            && host.isWindowInFront
            && host.selection == .task(taskID)
    }

    private static func remoteNotificationKey(hostID: String, taskID: String) -> String {
        "\(hostID)/\(taskID)"
    }

    private static func remoteApprovalSessionID(hostID: String, taskID: String) -> UUID {
        RemoteSidebarMirror.sessionID(for: "\(hostID)/\(taskID)")
    }
}
