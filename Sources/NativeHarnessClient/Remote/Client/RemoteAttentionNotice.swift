import Foundation
import YardletRemote

/// A notification for a host's task while its window is open (docs/REMOTE_PROTOCOL.md §5.2): when the task
/// starts waiting on the person, or finishes or fails. Its title names the host before the task, and a
/// click opens the task in the host's window. Nothing comes while no window of the host is open; the
/// phone's pushes are the host's own.
enum RemoteAttentionNotice {
    static func notification(hostID: String, hostName: String, event: RemoteEvent) -> SystemNotification? {
        guard let taskID = event.taskId, let state = event.state else { return nil }
        let body: String
        switch state {
        case .waiting:
            body = event.summary ?? (event.pendingRequest == .input ? L10n.string("Waiting for your answer")
                                                                    : L10n.string("Waiting for your approval"))
        case .unread where event.previousState == .active || event.previousState == .waiting:
            body = event.indicator == .failed ? L10n.string("Failed") : L10n.string("Finished")
        default:
            return nil
        }
        let title = [hostName, event.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return SystemNotification(title: title, body: body, identifier: "yardlet.remote.\(hostID).\(taskID)",
                                  target: SystemNotificationTarget(remoteTask: RemoteTaskReveal(hostID: hostID, taskID: taskID)))
    }
}
