import UserNotifications

/// Opens a push from a Mac (docs/REMOTE_PROTOCOL.md §16) and shows what it says. The push itself carries only the
/// app's fallback words and the sealed event; Apple and the relay never see the task's title or the request. A push
/// this phone cannot open (a key it no longer holds) keeps the fallback words. A task's notification sets the app
/// icon's badge to the tasks notified with it (`PushNotice.badge`).
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if let opened = PushNotice.open(content.userInfo) {
            PushNotice.fill(content, with: opened.event, hostID: PushNotice.hostID(forKeyID: opened.keyID))
        }
        guard content.userInfo[PushNotice.taskKey] != nil else { return contentHandler(content) }
        // Handed to the center's queue and back, used only there.
        nonisolated(unsafe) let notice = content
        nonisolated(unsafe) let deliver = contentHandler
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            notice.badge = NSNumber(value: PushNotice.badge(delivered.map(\.request.content) + [notice]))
            deliver(notice)
        }
    }
}
