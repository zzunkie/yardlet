import AppKit
import Foundation
import UserNotifications

@MainActor
final class LocalSystemNotificationCenter: SystemNotificationCenter {
    /// The category of an approval notification that offers "Allow once", as the Claude app's
    /// `PERMISSION_REQUEST` category carries its `ALLOW_ONCE` action.
    nonisolated static let approvalCategoryIdentifier = "yardlet.approval"
    nonisolated static let allowOnceActionIdentifier = "yardlet.allowOnce"
    /// In a notification's `userInfo`: shown while Yardlet is in front too (`SystemNotification.showsWhileActive`).
    nonisolated static let showsWhileActiveKey = "yardletShowsWhileActive"

    private let injectedCenter: UNUserNotificationCenter?
    /// The center's delegate. `UNUserNotificationCenter` keeps its delegate weakly.
    private var responseRelay: NotificationResponseRelay?
    private var hasAskedForBadges = false

    init(center: UNUserNotificationCenter? = nil) {
        injectedCenter = center
    }

    func authorization() async -> SystemNotificationAuthorization {
        guard let center = resolvedCenter() else { return .unknown }
        return await Self.settings(of: center).authorization
    }

    func requestAuthorization() async -> Bool {
        guard let center = resolvedCenter() else { return false }
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: Self.requestedOptions) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func post(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        await deliver(content, identifier: identifier)
    }

    func post(_ notification: SystemNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        var userInfo = notification.target.userInfo
        if notification.showsWhileActive { userInfo[Self.showsWhileActiveKey] = "1" }
        content.userInfo = userInfo
        if notification.offersAllowOnce {
            content.categoryIdentifier = Self.approvalCategoryIdentifier
        }
        await deliver(content, identifier: notification.identifier)
    }

    func removeNotifications(identifiers: [String]) {
        guard let center = resolvedCenter(), !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Badges follow Notifications › Yardlet › Badges. Installs that allowed notifications before
    /// Yardlet asked for badges ask once more: the person already allowed them (not provisional,
    /// which a new request would prompt to upgrade), so macOS shows no prompt and adds the Badges
    /// switch, which then decides.
    func allowsBadges() async -> Bool {
        guard let center = resolvedCenter() else { return false }
        var settings = await Self.settings(of: center)
        if settings.authorization == .authorized, settings.badges == .notSupported, !hasAskedForBadges {
            hasAskedForBadges = true
            _ = await requestAuthorization()
            settings = await Self.settings(of: center)
        }
        return settings.authorization.isDeliverable && settings.badges == .enabled
    }

    func setResponseHandler(_ handler: @escaping @MainActor (SystemNotificationResponse) -> Void) {
        guard let center = resolvedCenter() else { return }
        let relay = NotificationResponseRelay { response in
            Task { @MainActor in handler(response) }
        }
        responseRelay = relay
        center.delegate = relay
        let allowOnce = UNNotificationAction(
            identifier: Self.allowOnceActionIdentifier,
            title: L10n.string("Allow once"),
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategoryIdentifier,
                actions: [allowOnce],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// A click or an action on a Yardlet notification; nil for a dismissal or a notification
    /// Yardlet did not post.
    nonisolated static func response(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> SystemNotificationResponse? {
        guard let target = SystemNotificationTarget(userInfo: userInfo) else { return nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return SystemNotificationResponse(target: target, action: .open)
        case allowOnceActionIdentifier:
            return SystemNotificationResponse(target: target, action: .allowOnce)
        default:
            return nil
        }
    }

    private static let requestedOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    private struct Settings: Sendable {
        let authorization: SystemNotificationAuthorization
        let badges: UNNotificationSetting
    }

    private static func settings(of center: UNUserNotificationCenter) async -> Settings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Settings(
                    authorization: authorization(settings.authorizationStatus),
                    badges: settings.badgeSetting
                ))
            }
        }
    }

    nonisolated private static func authorization(_ status: UNAuthorizationStatus) -> SystemNotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) async {
        guard let center = resolvedCenter() else { return }
        guard (await authorization()).isDeliverable else { return }
        content.sound = Self.sound(NotificationSound.current())
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.add(request) { _ in
                continuation.resume()
            }
        }
    }

    /// Settings › Notifications › Notification sound: macOS's notification sound, one of its alert sounds by name
    /// (as the Codex app names them to macOS), or none.
    nonisolated static func sound(_ choice: String) -> UNNotificationSound? {
        switch choice {
        case NotificationSound.none: nil
        case NotificationSound.standard: .default
        default: UNNotificationSound(named: UNNotificationSoundName(choice))
        }
    }

    private func resolvedCenter() -> UNUserNotificationCenter? {
        if let injectedCenter { return injectedCenter }
        // XCTest and SwiftPM executables do not have an application bundle proxy. Avoid touching
        // UNUserNotificationCenter.current() outside the packaged Yardlet app. A QA copy has its own
        // identifier and a QA run (QABackground) may launch any bundle; neither asks for permission
        // or lands in System Settings › Notifications.
        guard Bundle.main.bundleIdentifier == YardletProduct.bundleIdentifier, !QABackground.isOn else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }
}

/// Hands a click or an action to the app on the main actor. While Yardlet is frontmost a
/// notification is not shown, as before the center had a delegate, unless it asks to be
/// (`SystemNotification.showsWhileActive`).
private final class NotificationResponseRelay: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let deliver: @Sendable (SystemNotificationResponse) -> Void

    init(deliver: @escaping @Sendable (SystemNotificationResponse) -> Void) {
        self.deliver = deliver
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let parsed = LocalSystemNotificationCenter.response(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) {
            deliver(parsed)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        completionHandler(userInfo[LocalSystemNotificationCenter.showsWhileActiveKey] == nil ? [] : [.banner, .list, .sound])
    }
}

extension SystemNotificationSettingsModel {
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }
}
