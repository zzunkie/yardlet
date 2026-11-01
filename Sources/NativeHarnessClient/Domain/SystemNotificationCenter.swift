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

    /// The task; nil for a personal agent's notification.
    let sessionID: UUID?
    /// The request an approval notification asks about; nil for every other notification.
    var requestID: String?
    /// The browser tab a notification is about (the task's side-panel tab key): a click shows it in the task's panel.
    var browserTab: UUID?
    var personalAgent: PersonalAgentReveal?

    init(sessionID: UUID, requestID: String? = nil, browserTab: UUID? = nil) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.browserTab = browserTab
    }

    init(personalAgent: PersonalAgentReveal) {
        sessionID = nil
        self.personalAgent = personalAgent
    }

    /// Reads a target back from a delivered notification; nil for one Yardlet did not post.
    init?(userInfo: [AnyHashable: Any]) {
        if let text = userInfo[Self.personalAgentKey] as? String,
           let reveal = try? JSONDecoder().decode(PersonalAgentReveal.self, from: Data(text.utf8)) {
            self.init(personalAgent: reveal)
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
        return info
    }
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
