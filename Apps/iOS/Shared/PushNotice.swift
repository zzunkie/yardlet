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

    enum Kind: String {
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
        case .unread? where event.previousState == .active || event.previousState == .waiting:
            return event.indicator == .failed ? .failed : .finished
        default:
            return nil
        }
    }

    /// A change that takes back what an earlier notice of its task said: it stopped waiting without a new notice.
    static func withdraws(_ event: RemoteEvent) -> Bool {
        event.event == .attention && event.previousState == .waiting && event.state != .waiting && kind(of: event) == nil
    }

    /// Fills a notification from the event: the task's title, what waits (with the request's line) or how it ended,
    /// and the Mac's name.
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
        content.userInfo = info
    }

    /// The categories that give each kind its locked-screen line. The app registers them at launch.
    static var categories: Set<UNNotificationCategory> {
        Set([Kind.approval, .question, .browser, .finished, .failed, .link].map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: $0.placeholder, options: [])
        })
    }

    /// "482913" as "482 913".
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
