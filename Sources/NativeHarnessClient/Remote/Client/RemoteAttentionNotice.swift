import Foundation
import YardletRemote

/// A notification for a host's task while its window is open (docs/REMOTE_PROTOCOL.md §5.2): when the task
/// starts waiting on the person, or finishes or fails. Its title names the host before the task, and a
/// click opens the task in the host's window; an approval offers "Allow once" as a local one does
/// (`RemoteHostModel.offersAllowOnce`). A finish the host keeps quiet about is not announced here either
/// (`announces`), and a task that stops waiting takes its notification back, as the host's own do. Nothing comes
/// while no window of the host is open; the phone's pushes are the host's own.
enum RemoteAttentionNotice {
    /// One notification per task of a host: the latest replaces the one before.
    static func identifier(hostID: String, taskID: String) -> String {
        "yardlet.remote.\(hostID).\(taskID)"
    }

    /// The notification to take back: the task's own, once it no longer waits or stays unread and nothing replaces it.
    static func withdrawn(hostID: String, event: RemoteEvent) -> String? {
        guard let taskID = event.taskId,
              event.previousState == .waiting || event.previousState == .unread,
              event.state != .waiting,
              notification(hostID: hostID, hostName: "", event: event) == nil else { return nil }
        return identifier(hostID: hostID, taskID: taskID)
    }

    static func notification(hostID: String, hostName: String, event: RemoteEvent,
                             offersAllowOnce: Bool = false) -> SystemNotification? {
        guard let taskID = event.taskId, let state = event.state else { return nil }
        let body: String
        switch state {
        case .waiting:
            body = event.summary ?? (event.pendingRequest == .input ? L10n.string("Waiting for your answer")
                                                                    : L10n.string("Waiting for your approval"))
        case .unread where (event.previousState == .active || event.previousState == .waiting) && event.announces != false:
            body = event.indicator == .failed ? L10n.string("Failed") : L10n.string("Finished")
        default:
            return nil
        }
        let title = [hostName, event.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let allowsOnce = offersAllowOnce && state == .waiting && event.requestId != nil
        return SystemNotification(title: title, body: body, identifier: identifier(hostID: hostID, taskID: taskID),
                                  target: SystemNotificationTarget(remoteTask: RemoteTaskReveal(hostID: hostID, taskID: taskID),
                                                                   requestID: allowsOnce ? event.requestId : nil),
                                  offersAllowOnce: allowsOnce)
    }
}
