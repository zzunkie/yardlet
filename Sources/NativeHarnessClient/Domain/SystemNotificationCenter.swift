import Foundation
import Observation

enum SystemNotificationAuthorization: String, CaseIterable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var isDeliverable: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied, .unknown:
            false
        }
    }

    var displayName: String {
        switch self {
        case .notDetermined: L10n.string("Not requested")
        case .denied: L10n.string("Notifications disabled")
        case .authorized: L10n.string("Notifications enabled")
        case .provisional: L10n.string("Notifications enabled quietly")
        case .ephemeral: L10n.string("Notifications enabled temporarily")
        case .unknown: L10n.string("Notification status unavailable")
        }
    }
}

/// The task a notification is about, carried in its `userInfo` so a click or an action finds the
/// task again, as the Claude app's notifications carry `sessionId` and `requestId`. A personal agent's
/// notification names its dot and account choice in place of a task.
struct SystemNotificationTarget: Equatable, Sendable {
    static let sessionKey = "yardletSessionID"
    static let requestKey = "yardletRequestID"
    static let browserTabKey = "yardletBrowserTab"
    static let personalAgentKey = "yardletPersonalAgent"
    static let mailThreadKey = "yardletMailThread"
    static let remoteHostKey = "yardletRemoteHost"
    static let remoteTaskKey = "yardletRemoteTask"

    /// The task; nil for a personal agent's notification.
    let sessionID: UUID?
    /// The request an approval notification asks about; nil for every other notification.
    var requestID: String?
    /// The browser tab a notification is about (the task's side-panel tab key): a click shows it in the task's panel.
    var browserTab: UUID?
    var personalAgent: PersonalAgentReveal?
    /// The mailbox thread a new-mail notification is about.
    var mailThread: MailThreadKey?
    /// A task of another Mac this one follows, by the host's ID here and the task's ID there.
    var remoteTask: RemoteTaskReveal?

    init(sessionID: UUID, requestID: String? = nil, browserTab: UUID? = nil) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.browserTab = browserTab
    }

    init(personalAgent: PersonalAgentReveal) {
        sessionID = nil
        self.personalAgent = personalAgent
    }

    init(mailThread: MailThreadKey) {
        sessionID = nil
        self.mailThread = mailThread
    }

    /// A host task's notification; an approval's names its request, which "Allow once" answers there.
    init(remoteTask: RemoteTaskReveal, requestID: String? = nil) {
        sessionID = nil
        self.remoteTask = remoteTask
        self.requestID = requestID
    }

    /// Reads a target back from a delivered notification; nil for one Yardlet did not post.
    init?(userInfo: [AnyHashable: Any]) {
        if let text = userInfo[Self.personalAgentKey] as? String,
           let reveal = try? JSONDecoder().decode(PersonalAgentReveal.self, from: Data(text.utf8)) {
            self.init(personalAgent: reveal)
            return
        }
        if let text = userInfo[Self.mailThreadKey] as? String,
           let thread = try? JSONDecoder().decode(MailThreadKey.self, from: Data(text.utf8)) {
            self.init(mailThread: thread)
            return
        }
        if let host = userInfo[Self.remoteHostKey] as? String, let task = userInfo[Self.remoteTaskKey] as? String {
            self.init(remoteTask: RemoteTaskReveal(hostID: host, taskID: task),
                      requestID: (userInfo[Self.requestKey] as? String).flatMap { $0.isEmpty ? nil : $0 })
            return
        }
        guard let text = userInfo[Self.sessionKey] as? String, let id = UUID(uuidString: text) else { return nil }
        self.init(sessionID: id, requestID: (userInfo[Self.requestKey] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  browserTab: (userInfo[Self.browserTabKey] as? String).flatMap(UUID.init(uuidString:)))
    }

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let sessionID { info[Self.sessionKey] = sessionID.uuidString }
        if let requestID { info[Self.requestKey] = requestID }
        if let browserTab { info[Self.browserTabKey] = browserTab.uuidString }
        if let personalAgent, let data = try? JSONEncoder().encode(personalAgent) {
            info[Self.personalAgentKey] = String(decoding: data, as: UTF8.self)
        }
        if let mailThread, let data = try? JSONEncoder().encode(mailThread) {
            info[Self.mailThreadKey] = String(decoding: data, as: UTF8.self)
        }
        if let remoteTask {
            info[Self.remoteHostKey] = remoteTask.hostID
            info[Self.remoteTaskKey] = remoteTask.taskID
        }
        return info
    }
}

/// A task of another Mac a notification leads to: the host as this Mac saved it, and the task's ID there.
struct RemoteTaskReveal: Equatable, Sendable {
    let hostID: String
    let taskID: String
}

/// The dot a notification leads to, and the account choice its watch read it under.
struct PersonalAgentReveal: Codable, Equatable, Sendable {
    let agent: PersonalAgentIdentity
    let accountChoiceID: String
}

/// A notification that leads back to its task.
struct SystemNotification: Equatable, Sendable {
    let title: String
    let body: String
    let identifier: String
    let target: SystemNotificationTarget
    /// Offers "Allow once" for `target.requestID` (`SystemNotificationAction.allowOnce`).
    var offersAllowOnce = false
    /// Shown while Yardlet is in front too, where a notification otherwise only goes to Notification Center.
    var showsWhileActive = false
}

/// What the person did with a notification: clicked it, or chose "Allow once".
enum SystemNotificationAction: Equatable, Sendable {
    case open
    case allowOnce
}

struct SystemNotificationResponse: Equatable, Sendable {
    let target: SystemNotificationTarget
    let action: SystemNotificationAction
}

extension SystemNotificationResponse {
    private static let actionKey = "yardletAction"
    /// Letters, digits and `-._~`: what a URL leaves unescaped, so `&` and `=` only ever separate.
    private static let unescaped = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The click's words where a notification carries text rather than a dictionary (a Windows app notification's
    /// `launch` and its button's `arguments`): the target's `userInfo` and the action, each escaped as in a URL's
    /// query.
    var argument: String {
        var pairs = target.userInfo.sorted { $0.key < $1.key }
        pairs.append((Self.actionKey, action == .allowOnce ? "allowOnce" : "open"))
        return pairs.map { Self.escaped($0.key) + "=" + Self.escaped($0.value) }.joined(separator: "&")
    }

    /// The click `argument` names; nil for words Yardlet did not write.
    init?(argument: String) {
        var info: [AnyHashable: Any] = [:]
        for pair in argument.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = parts[0].removingPercentEncoding,
                  let value = parts[1].removingPercentEncoding else { return nil }
            info[key] = value
        }
        guard let target = SystemNotificationTarget(userInfo: info) else { return nil }
        switch info[Self.actionKey] as? String {
        case "open": self.init(target: target, action: .open)
        case "allowOnce": self.init(target: target, action: .allowOnce)
        default: return nil
        }
    }

    private static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unescaped) ?? ""
    }
}

@MainActor
protocol SystemNotificationCenter: AnyObject {
    func authorization() async -> SystemNotificationAuthorization
    func requestAuthorization() async -> Bool
    func post(title: String, body: String, identifier: String) async
    /// Posts a notification carrying the task (and request) it is about. Every Yardlet notification
    /// is in one group in Notification Center, as the Codex app's (the Claude app groups by session).
    func post(_ notification: SystemNotification) async
    /// Withdraws delivered notifications, such as an approval answered in the app.
    func removeNotifications(identifiers: [String])
    /// Whether macOS lets Yardlet badge its Dock icon (Notifications › Yardlet › Badges).
    func allowsBadges() async -> Bool
    /// Receives each click on, and each action from, a notification Yardlet posted.
    func setResponseHandler(_ handler: @escaping @MainActor (SystemNotificationResponse) -> Void)
}

/// A center that only shows text, such as a test double, posts without a target, never badges,
/// and reports no responses.
extension SystemNotificationCenter {
    func post(_ notification: SystemNotification) async {
        await post(title: notification.title, body: notification.body, identifier: notification.identifier)
    }

    func removeNotifications(identifiers: [String]) {}

    func allowsBadges() async -> Bool { false }

    func setResponseHandler(_ handler: @escaping @MainActor (SystemNotificationResponse) -> Void) {}
}

@MainActor
@Observable
final class SystemNotificationSettingsModel {
    private let center: any SystemNotificationCenter
    private(set) var authorization: SystemNotificationAuthorization = .notDetermined
    private(set) var isLoading = false

    init(center: any SystemNotificationCenter) {
        self.center = center
    }

    var statusLabel: String {
        authorization.displayName
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        authorization = await center.authorization()
        isLoading = false
    }

    func requestAuthorization() async {
        guard !isLoading else { return }
        isLoading = true
        _ = await center.requestAuthorization()
        authorization = await center.authorization()
        isLoading = false
    }
}

/// What a task's notification is about, each kind with its own switch in Settings › Notifications, as the Codex app
/// has them: a finished or failed turn, a request for approval, and a question.
enum TaskNotificationKind: Equatable, Sendable {
    case turnEnded
    case approval
    case question

    static let turnEndedKey = "YardletTurnCompletionNotifications"
    static let approvalsKey = "YardletApprovalNotifications"
    static let questionsKey = "YardletQuestionNotifications"

    /// What a task in `status` notifies about; a waiting task's newest request says whether it asks a question.
    init?(_ status: SessionStatus, asksQuestion: Bool) {
        switch status {
        case .completed, .failed: self = .turnEnded
        case .waitingForApproval: self = asksQuestion ? .question : .approval
        case .ready, .running: return nil
        }
    }

    /// Whether Settings lets it notify now, for a task on screen (`AppModel.isSessionVisible`) or not. Out of the
    /// box a task notifies only while it is not on screen, as before these settings.
    func notifies(whileShown isShown: Bool, in defaults: UserDefaults) -> Bool {
        switch self {
        case .turnEnded:
            switch TurnCompletionNotifications.current(in: defaults) {
            case .always: true
            case .whenNotShown: !isShown
            case .never: false
            }
        case .approval: !isShown && defaults.object(forKey: Self.approvalsKey) as? Bool ?? true
        case .question: !isShown && defaults.object(forKey: Self.questionsKey) as? Bool ?? true
        }
    }

    /// Shown while Yardlet is in front as well: a finished turn the person asked to hear about always.
    func showsWhileActive(in defaults: UserDefaults) -> Bool {
        self == .turnEnded && TurnCompletionNotifications.current(in: defaults) == .always
    }
}

/// When a task's finished or failed turn notifies, as the Codex app's "Turn completion notifications" offers.
enum TurnCompletionNotifications: String, CaseIterable, Sendable {
    case always
    /// While the task is not on screen, which is how Yardlet notified before.
    case whenNotShown
    case never

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        defaults.string(forKey: TaskNotificationKind.turnEndedKey).flatMap(Self.init(rawValue:)) ?? .whenNotShown
    }

    var title: String {
        switch self {
        case .always: L10n.string("Always")
        case .whenNotShown: L10n.string("When not on screen")
        case .never: L10n.string("Never")
        }
    }
}

/// The sound Yardlet's notifications play: macOS's notification sound, one of macOS's alert sounds, or none.
enum NotificationSound {
    static let key = "YardletNotificationSound"
    static let standard = "default"
    static let none = "none"
    /// macOS's alert sounds in /System/Library/Sounds, by the names macOS plays them by.
    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop",
                               "Purr", "Sosumi", "Submarine", "Tink"]

    static func current(in defaults: UserDefaults = .yardlet) -> String {
        offered(defaults.string(forKey: key))
    }

    /// A stored choice, the standard sound for anything not offered.
    static func offered(_ stored: String?) -> String {
        stored.flatMap { $0 == none || systemSounds.contains($0) ? $0 : nil } ?? standard
    }
}
