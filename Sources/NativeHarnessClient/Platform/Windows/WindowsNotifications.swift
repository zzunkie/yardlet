import Crypto
import Foundation
import WinAppSDK
@preconcurrency import WindowsFoundation
import WinSDK
import WinUIApplication

/// System notifications in the Windows app, through the Windows App SDK's app notifications
/// (`AppNotificationManager`), as the Mac's go through UserNotifications. The engine decides when to post, by the
/// Mac's rules (`AppModel+SystemNotifications.swift`): a task that waits for the person or finished a turn they asked
/// for, when it is not the task shown. Each notification leads back to its task, an approval's offers "Allow once",
/// and one is withdrawn by the identifier it was posted under. While a Yardlet window is in front, none is shown, as
/// the Mac shows none while Yardlet is the active app.
///
/// Windows asks no permission first: whether Yardlet's notifications show is the person's switch in Settings ›
/// System › Notifications, which `authorization()` reads. An app without a package registers at launch, handing
/// Windows the way back to the running app for a click. Packed builds supply the name "Yardlet" and the icon packed
/// beside the executable: the SDK's automatic lookup can miss the shortcut and uses the executable's filename,
/// even with a version resource. Each registration refreshes the app's entry under `HKCU\Software\Classes`
/// (`AppUserModelId` and the activator's `CLSID`), which removing the app takes away
/// (`WindowsNotificationRegistration`). A click while the app runs comes to `NotificationInvoked`; a click after it
/// quit opens it without choosing the task.
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

    /// Any app may show a count over its taskbar button (`WindowsTaskbarBadge`); whether Windows shows it is the
    /// person's switch in Settings › Personalization › Taskbar, which Windows applies itself.
    func allowsBadges() async -> Bool { true }

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
            if let icon = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Yardlet.ico"),
               FileManager.default.fileExists(atPath: icon.nativePath) {
                try manager.register("Yardlet", Uri(icon.nativePath))
            } else {
                try manager.register()
            }
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

/// What notifications leave for this Windows user, taken away when the app is removed, in Velopack's uninstall hook
/// (`VelopackStart`), as its shortcut and its entry in Settings › Apps are: the app's notifications still in Windows'
/// notification center, then its registration, through `AppNotificationManager.UnregisterAll()`, which removes the
/// entry under `HKCU\Software\Classes\AppUserModelId`, the activator's `CLSID` and the notification platform's record
/// of the app. The Windows App SDK names the app by the process's AppUserModelID, which Velopack sets only after its
/// hooks have run, so the hook sets the one the app registered under first; without one the SDK would name the app by
/// its executable's path and write an entry for that. Nothing is asked of the SDK when the app never registered, since
/// `UnregisterAll()` would then write the entry before it fails. The Windows App SDK has notifications only for a
/// process that is not elevated, so an app run elevated registered nothing, and a removal run elevated removes nothing.
enum WindowsNotificationRegistration {
    /// Takes the notifications and the registration away, waiting at most `seconds`, and says what it did, for the
    /// QA log.
    static func remove(appUserModelID: String, within seconds: Int) -> String {
        guard isRegistered(appUserModelID) else { return "notifications: none registered" }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        // On a thread of its own in the multithreaded apartment, as the runtime's packages are added
        // (`WindowsAppRuntimeDeployment`), so the hook can give up waiting in time.
        let worker = Thread {
            _ = RoInitialize(RO_INIT_MULTITHREADED)
            outcome.set(unregister(appUserModelID, within: seconds))
            RoUninitialize()
            finished.signal()
        }
        worker.start()
        guard finished.wait(timeout: .now() + .seconds(seconds)) == .success else {
            return "notifications: still removing after \(seconds) s"
        }
        return outcome.words
    }

    /// Whether an app registered for notifications under `appUserModelID` for this user.
    private static func isRegistered(_ appUserModelID: String) -> Bool {
        var key: HKEY?
        let opened = ("Software\\Classes\\AppUserModelId\\" + appUserModelID).withCString(encodedAs: UTF16.self) {
            RegOpenKeyExW(HKEY_CURRENT_USER, $0, 0, REGSAM(KEY_QUERY_VALUE), &key)
        }
        guard opened == ERROR_SUCCESS else { return false }
        RegCloseKey(key)
        return true
    }

    private static func unregister(_ appUserModelID: String, within seconds: Int) -> String {
        do {
            try XamlApplication.startWindowsAppRuntimeWithoutWindow()
        } catch {
            return "notifications: not removed: \(error)"
        }
        let named = appUserModelID.withCString(encodedAs: UTF16.self) { SetCurrentProcessExplicitAppUserModelID($0) }
        guard named >= 0 else { return "notifications: not removed: SetCurrentProcessExplicitAppUserModelID \(named)" }
        guard (try? AppNotificationManager.isSupported()) == true, let manager = AppNotificationManager.default else {
            return "notifications: not supported"
        }
        var words: [String] = []
        do {
            if let removal = try manager.removeAllAsync() {
                let deadline = Date().addingTimeInterval(Double(seconds) / 2)
                while removal.status == .started, Date() < deadline { Sleep(50) }
                try removal.getResults()
            }
            words.append("removed the notifications")
        } catch {
            words.append("notifications not removed: \(error)")
        }
        do {
            try manager.unregisterAll()
            words.append("unregistered")
        } catch {
            words.append("not unregistered: \(error)")
        }
        return "notifications: " + words.joined(separator: ", ")
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""

        var words: String { lock.withLock { stored } }

        func set(_ words: String) {
            lock.withLock { stored = words }
        }
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
