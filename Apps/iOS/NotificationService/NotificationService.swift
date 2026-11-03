import UserNotifications

/// Opens a push from a Mac (docs/REMOTE_PROTOCOL.md §16) and shows what it says. The push itself carries only the
/// app's fallback words and the sealed event; Apple and the relay never see the task's title or the request. A push
/// this phone cannot open (a key it no longer holds) keeps the fallback words.
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
        contentHandler(content)
    }
}
