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

    /// Open host windows' tasks for the menu bar menu (`MenuBarMenuProjection`).
    func remoteMenuBarHostTasks() -> [MenuBarMenuProjection.RemoteHostTasks] {
        guard let remoteHosts else { return [] }
        return remoteHosts.openModels.map { host in
            MenuBarMenuProjection.RemoteHostTasks(
                hostID: host.id,
                hostName: host.name,
                sessions: host.sidebar.sessions,
                details: host.sidebar.details,
                place: { host.sidebar.place(of: $0) }
            )
        }
    }

    /// Handles an `.attention` event from an open host window.
    func handleRemoteHostAttention(host: RemoteHostModel, event: RemoteEvent) {
        if let withdrawn = RemoteAttentionNotice.withdrawn(hostID: host.id, event: event) {
            systemNotificationCenter.removeNotifications(identifiers: [withdrawn])
            if let taskID = event.taskId {
                dockAttention?.forgetApprovals(in: Self.remoteApprovalSessionID(hostID: host.id, taskID: taskID))
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
        // The task shown in the window in front needs no banner.
        if isRemoteTaskShownInFront(host: host, taskID: taskID) { return }
        guard let notice = RemoteAttentionNotice.notification(
            hostID: host.id,
            hostName: host.name,
            event: event,
            offersAllowOnce: host.offersAllowOnce(event)
        ) else { return }
        Task { [weak self, weak host] in
            guard let self else { return }
            guard (await self.systemNotificationCenter.authorization()).isDeliverable else { return }
            guard let host,
                  self.remoteHosts?.openHostIDs.contains(host.id) == true,
                  !self.isRemoteTaskShownInFront(host: host, taskID: taskID) else { return }
            // An approval answered or an unread turn read while authorization was checked is not announced.
            if let current = host.task(taskID), !RemoteSidebarMirror.needsAttention(current) { return }
            await self.systemNotificationCenter.post(notice)
        }
    }

    /// Withdraws a remote task's notification once its wait is answered, its unread turn is read, or
    /// the task leaves the host's list.
    func withdrawRemoteTaskNotification(hostID: String, taskID: String) {
        let identifier = RemoteAttentionNotice.identifier(hostID: hostID, taskID: taskID)
        systemNotificationCenter.removeNotifications(identifiers: [identifier])
        dockAttention?.forgetApprovals(in: Self.remoteApprovalSessionID(hostID: hostID, taskID: taskID))
    }

    private func isRemoteTaskShownInFront(host: RemoteHostModel, taskID: String) -> Bool {
        applicationAttention?.isActive == true
            && host.isWindowInFront
            && host.selection == .task(taskID)
    }

    private static func remoteApprovalSessionID(hostID: String, taskID: String) -> UUID {
        RemoteSidebarMirror.sessionID(for: "\(hostID)/\(taskID)")
    }
}
