import Foundation
import UserNotifications
import YardletRemote

/// What a push from a Mac says (docs/REMOTE_PROTOCOL.md §16) and how a notification shows it. The app and its
/// notification service extension both read pushes here: the extension for an alert, the app for a background push
/// that withdraws one.
enum PushNotice {
    /// The Keychain service of the push keys, one item per key, named by its key ID and labeled with its Mac's ID.
    static let keyService = "com.zzunkie.yardlet.remote.push-key"

    /// `userInfo` keys a notification carries for the app.
    static let taskKey = "yardletTask"
    static let hostKey = "yardletHost"
    /// The request an approval's Allow Once names (`allowOnceRequest`).
    static let requestKey = "yardletRequest"

    /// The action that allows an ordinary approval once from its notification (§4.4), and the category that offers it.
    static let allowOnceAction = "allowOnce"
    static let allowOnceCategory = "approval.allowOnce"

    /// Opens the sealed event a push carries (`v`, `k`, `y`) with the push key it names.
    static func open(_ userInfo: [AnyHashable: Any]) -> (event: RemoteEvent, keyID: String)? {
        guard userInfo["v"] as? String == "1", let keyID = userInfo["k"] as? String, let sealed = userInfo["y"] as? String,
              let key = Keychain.read(service: keyService, account: keyID),
              let plaintext = try? RemotePushSeal.open(sealed, key: key),
              let event = try? JSONDecoder().decode(RemoteEvent.self, from: plaintext) else { return nil }
        return (event, keyID)
    }

    /// The Mac that a push key belongs to, as the app saved it beside the key.
    static func hostID(forKeyID keyID: String) -> String? {
        Keychain.read(service: keyService + ".host", account: keyID).map { String(decoding: $0, as: UTF8.self) }
    }

    enum Kind: String, CaseIterable {
        case approval, question, browser, finished, failed, link

        /// What a locked phone shows in place of the details.
        var placeholder: String {
            switch self {
            case .approval: String(localized: "Approval requested", table: "Push")
            case .question: String(localized: "Question", table: "Push")
            case .browser: String(localized: "Waiting on a browser tab", table: "Push")
            case .finished: String(localized: "A task finished", table: "Push")
            case .failed: String(localized: "A task failed", table: "Push")
            case .link: String(localized: "Connection request", table: "Push")
            }
        }

        var line: String {
            switch self {
            case .approval: String(localized: "Approval requested", table: "Push")
            case .question: String(localized: "Question", table: "Push")
            case .browser: String(localized: "Browser tab", table: "Push")
            case .finished: String(localized: "Finished", table: "Push")
            case .failed: String(localized: "Failed", table: "Push")
            case .link: String(localized: "Connection request", table: "Push")
            }
        }

        var isRequest: Bool { self == .approval || self == .question || self == .browser || self == .link }
    }

    /// Which notice an attention change is, as the Android app and the Mac decide it: a task that starts waiting,
    /// or one that finished or failed after it worked or waited. Nil for a change that notifies nothing (a task
    /// that stopped waiting withdraws its notice instead).
    static func kind(of event: RemoteEvent) -> Kind? {
        if event.event == .linkRequest { return .link }
        guard event.event == .attention else { return nil }
        switch event.state {
        case .waiting?:
            if event.pendingKind == "browserHandoff" { return .browser }
            return event.pendingRequest == .input ? .question : .approval
        case .unread? where (event.previousState == .active || event.previousState == .waiting) && event.announces != false:
            return event.indicator == .failed ? .failed : .finished
        default:
            return nil
        }
    }

    /// A change that takes back what an earlier notice of its task said (§16): it stopped waiting without a new
    /// notice, or became unread in a turn the Mac does not announce (`announces: false`).
    static func withdraws(_ event: RemoteEvent) -> Bool {
        guard event.event == .attention, kind(of: event) == nil else { return false }
        return (event.previousState == .waiting && event.state != .waiting)
            || (event.state == .unread && event.announces == false)
    }

    /// A change seen on a live connection after which its task's notification says something no longer true: the task
    /// stopped waiting, or it holds no unread result now (read, or a new turn began). The Mac pushes nothing to a phone
    /// connected to it (§16), so the app takes the notification back itself, as Android does.
    static func outdates(_ event: RemoteEvent) -> Bool {
        guard event.event == .attention, let state = event.state else { return false }
        return (event.previousState == .waiting && state != .waiting) || state == .active || state == .idle
    }

    /// The request a notification may allow once: an ordinary approval with its request ID (§5.2), never a plan review,
    /// a question, a form or a browser tab. Whether its command may be allowed unread is decided on the task's page
    /// when the action runs (`HostSession.allowOnceFromNotification`), since a push does not carry the command.
    static func allowOnceRequest(_ event: RemoteEvent) -> String? {
        guard kind(of: event) == .approval, event.pendingRequest == .approval,
              event.pendingKind == nil || event.pendingKind == "approval",
              let requestID = event.requestId, !requestID.isEmpty else { return nil }
        return requestID
    }

    /// Fills a notification from the event: the task's title, what waits (with the request's line) or how it ended,
    /// and the Mac's name. An ordinary approval of a known Mac also offers Allow Once.
    static func fill(_ content: UNMutableNotificationContent, with event: RemoteEvent, hostID: String?) {
        guard let kind = kind(of: event) else { return }
        content.categoryIdentifier = kind.rawValue
        if kind == .link {
            let device = event.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "A new device", table: "Push")
            content.title = String(localized: "Connection request · \(device)", table: "Push")
            content.body = event.code.map { String(localized: "Number \(spaced($0))", table: "Push") }
                ?? String(localized: "Tap to review", table: "Push")
        } else {
            content.title = event.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled task", table: "Push")
            if kind.isRequest, let summary = event.summary, !summary.isEmpty {
                content.body = "\(kind.line) · \(summary)"
            } else {
                content.body = kind.line
            }
        }
        content.subtitle = [event.projectName, event.macName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        content.threadIdentifier = event.taskId ?? "link"
        content.sound = kind.isRequest ? .default : nil
        var info = content.userInfo
        info[taskKey] = event.taskId
        info[hostKey] = hostID
        if hostID != nil, let requestID = allowOnceRequest(event) {
            content.categoryIdentifier = allowOnceCategory
            info[requestKey] = requestID
        }
        content.userInfo = info
    }

    /// The categories that give each kind its locked-screen line, and an approval its Allow Once. The action opens the
    /// app and asks for the phone to be unlocked first; the app sends nothing until App Lock is open too. The app
    /// registers them at launch.
    static var categories: Set<UNNotificationCategory> {
        let allowOnce = UNNotificationAction(identifier: allowOnceAction, title: String(localized: "Allow Once", table: "Push"),
                                             options: [.foreground, .authenticationRequired])
        return Set(Kind.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: $0.placeholder, options: [])
        } + [UNNotificationCategory(identifier: allowOnceCategory, actions: [allowOnce], intentIdentifiers: [],
                                    hiddenPreviewsBodyPlaceholder: Kind.approval.placeholder, options: [])])
    }

    // MARK: - Badge

    /// The app icon's badge, as Android's launcher counts it: one for each task with a notification in Notification
    /// Center, not every unread task. A notification the person cleared, or one taken back, no longer counts.
    static func badge(_ notices: [UNNotificationContent]) -> Int {
        Set(notices.compactMap { notice -> String? in
            guard let taskID = notice.userInfo[taskKey] as? String else { return nil }
            return "\(notice.userInfo[hostKey] as? String ?? "")/\(taskID)"
        }).count
    }

    /// Takes back the task notifications `matching` picks by their Mac and task, and sets the badge to the tasks still
    /// notified.
    static func withdraw(matching: @Sendable (_ hostID: String?, _ taskID: String) -> Bool) async {
        let center = UNUserNotificationCenter.current()
        var kept: [UNNotificationContent] = []
        var gone: [String] = []
        for notice in await center.deliveredNotifications() {
            let info = notice.request.content.userInfo
            if let taskID = info[taskKey] as? String, matching(info[hostKey] as? String, taskID) {
                gone.append(notice.request.identifier)
            } else {
                kept.append(notice.request.content)
            }
        }
        if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
        try? await center.setBadgeCount(badge(kept))
    }

    /// "482913" as "482 913".
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
