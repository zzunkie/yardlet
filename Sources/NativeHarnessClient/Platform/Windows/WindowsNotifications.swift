import Crypto
import Foundation
import WinAppSDK
@preconcurrency import WindowsFoundation
import WinSDK

/// System notifications in the Windows app, through the Windows App SDK's app notifications
/// (`AppNotificationManager`), as the Mac's go through UserNotifications. The engine decides when to post, by the
/// Mac's rules (`AppModel+SystemNotifications.swift`): a task that waits for the person or finished a turn they asked
/// for, when it is not the task shown. Each notification leads back to its task, an approval's offers "Allow once",
/// and one is withdrawn by the identifier it was posted under. While a Yardlet window is in front, none is shown, as
/// the Mac shows none while Yardlet is the active app.
///
/// Windows asks no permission first: whether Yardlet's notifications show is the person's switch in Settings ›
/// System › Notifications, which `authorization()` reads. An app without a package registers at launch, handing
/// Windows the way back to the running app for a click; its name and icon come from its Start menu shortcut, else
/// from its executable. Registering writes the app's entry under `HKCU\Software\Classes` (`AppUserModelId` and the
/// activator's `CLSID`), which `AppNotificationManager.UnregisterAll()` removes. A click while the app runs comes to
/// `NotificationInvoked`; a click after it quit opens it without choosing the task.
@MainActor
final class LocalSystemNotificationCenter: SystemNotificationCenter {
    /// Whether the app registered, once it tried: one try a launch, so a failed one adds no second click handler.
    private var registration: Bool?
    private var isRegistered: Bool { registration == true }
    private var responseHandler: (@MainActor (SystemNotificationResponse) -> Void)?

    func authorization() async -> SystemNotificationAuthorization {
        guard register() else { return .unknown }
        switch AppNotificationManager.default.setting {
        case .enabled: return .authorized
        case .disabledForApplication, .disabledForUser, .disabledByGroupPolicy, .disabledByManifest: return .denied
        default: return .unknown
        }
    }

    /// Windows shows no prompt; the switch is the person's, in Settings.
    func requestAuthorization() async -> Bool {
        await authorization().isDeliverable
    }

    func post(title: String, body: String, identifier: String) async {
        show(title: title, body: body, identifier: identifier, launch: nil, allowOnce: nil)
    }

    func post(_ notification: SystemNotification) async {
        let open = SystemNotificationResponse(target: notification.target, action: .open)
        let allowOnce = notification.offersAllowOnce
            ? SystemNotificationResponse(target: notification.target, action: .allowOnce) : nil
        show(title: notification.title, body: notification.body, identifier: notification.identifier,
             launch: open.argument, allowOnce: allowOnce?.argument)
    }

    func removeNotifications(identifiers: [String]) {
        guard isRegistered, !identifiers.isEmpty else { return }
        let tags = identifiers.map(Self.tag)
        Task {
            for tag in tags { _ = try? await AppNotificationManager.default.removeByTagAsync(tag)?.get() }
        }
    }

    /// Registers the app with the handler for clicks, which must come first: a click on a notification of an app
    /// registered without one starts another copy of the app.
    func setResponseHandler(_ handler: @escaping @MainActor (SystemNotificationResponse) -> Void) {
        responseHandler = handler
        register()
    }

    @discardableResult
    private func register() -> Bool {
        if let registration { return registration }
        registration = false
        guard (try? AppNotificationManager.isSupported()) == true, let manager = AppNotificationManager.default else {
            QAEventLog.shared.write("notifications: not supported")
            return false
        }
        // Windows raises the click on a thread of its own; the words go to the main actor.
        _ = manager.notificationInvoked.addHandler { @Sendable [weak self] _, args in
            let argument = args?.argument ?? ""
            let center = self
            Task { @MainActor in center?.invoked(argument) }
        }
        do {
            try manager.register()
        } catch {
            QAEventLog.shared.write("notifications: not registered: \(error)")
            return false
        }
        registration = true
        QAEventLog.shared.write("notifications: registered")
        return true
    }

    private func invoked(_ argument: String) {
        guard let response = SystemNotificationResponse(argument: argument) else { return }
        QAEventLog.shared.write("notification clicked: \(response.action == .allowOnce ? "allow once" : "open")")
        responseHandler?(response)
    }

    private func show(title: String, body: String, identifier: String, launch: String?, allowOnce: String?) {
        guard register(), AppNotificationManager.default.setting == .enabled else { return }
        guard !WindowsForeground.isYardlet else {
            QAEventLog.shared.write("notification held: Yardlet is in front")
            return
        }
        let notification = AppNotification(Self.payload(title: title, body: body, launch: launch, allowOnce: allowOnce))
        notification.tag = Self.tag(identifier)
        do {
            try AppNotificationManager.default.show(notification)
            QAEventLog.shared.write("notification shown: \(title)")
        } catch {
            QAEventLog.shared.write("notification not shown: \(error)")
        }
    }

    /// The notification's XML (Windows' toast schema): its title and words, the click's words, and "Allow once" as
    /// a button where it is offered.
    private static func payload(title: String, body: String, launch: String?, allowOnce: String?) -> String {
        var xml = "<toast" + (launch.map { " launch=\"\(escaped($0))\"" } ?? "") + ">"
        xml += "<visual><binding template=\"ToastGeneric\"><text>\(escaped(title))</text><text>\(escaped(body))</text>"
        xml += "</binding></visual>"
        if let allowOnce {
            xml += "<actions><action content=\"\(escaped(L10n.string("Allow once")))\" arguments=\"\(escaped(allowOnce))\"/>"
            xml += "</actions>"
        }
        return xml + "</toast>"
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// The tag a notification is withdrawn by: Windows takes at most 64 characters, so the identifier's digest.
    private static func tag(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which app is in front.
enum WindowsForeground {
    /// One of this app's windows is the foreground window.
    static var isYardlet: Bool {
        guard let window = GetForegroundWindow() else { return false }
        var process: DWORD = 0
        _ = GetWindowThreadProcessId(window, &process)
        return process == GetCurrentProcessId()
    }
}
