import SwiftUI
import UIKit
import UserNotifications

@main
struct YardletApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = PhoneModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

/// Push registration, opened notifications, and background pushes that withdraw a notification.
/// The notification center's delegate methods are `nonisolated`: the center is documented to call them on the main
/// thread, but a cold launch from a tapped notification must not depend on it, since Swift 6 stops the app on a main
/// actor method entered from another thread. They read the notification where they are called and do the app's part
/// on the main actor, calling the completion handler once that is done.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(PushNotice.categories)
        Task {
            // Asked for once a Mac is paired; registered again on each launch once allowed.
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PhoneModel.shared.registeredForPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// A background push (docs/REMOTE_PROTOCOL.md §16): a task stopped waiting, so its notification goes, and its count
    /// on the badge with it. Or the push target a relay sent while the app registers with it (§14.5).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any])
        async -> UIBackgroundFetchResult {
        if let target = userInfo["pushTarget"] as? String, let room = userInfo["room"] as? String {
            PushTargets.received(target: target, room: room)
            return .newData
        }
        guard let opened = PushNotice.open(userInfo), let taskID = opened.event.taskId,
              PushNotice.withdraws(opened.event) else { return .noData }
        await PushNotice.withdraw { $1 == taskID }
        return .newData
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// A notification opened, or its Allow Once chosen (`PushNotice.allowOnceAction`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let opened = OpenedNotification(response)
        let done = UncheckedSendable(completionHandler)
        Self.onMain {
            opened.open()
            done.value()
        }
    }

    /// Runs `work` on the main actor: right away when already on the main thread, so a cold launch sets the task to
    /// open before the first frame, and otherwise as soon as the main queue runs.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

/// What the app needs of an opened notification, read where the notification center hands it over.
private struct OpenedNotification: Sendable {
    let taskID: String?
    let hostID: String?
    let requestID: String?
    let allowOnce: Bool
    let browser: Bool

    init(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        let info = content.userInfo
        taskID = info[PushNotice.taskKey] as? String
        hostID = info[PushNotice.hostKey] as? String
        requestID = info[PushNotice.requestKey] as? String
        allowOnce = response.actionIdentifier == PushNotice.allowOnceAction
        // A tab handed to the person opens over its task (§15.18).
        browser = content.categoryIdentifier == PushNotice.Kind.browser.rawValue
    }

    @MainActor func open() {
        if allowOnce, let taskID, let hostID, let requestID {
            PhoneModel.shared.allowOnceFromNotification(taskID: taskID, hostID: hostID, requestID: requestID)
        } else {
            PhoneModel.shared.openNotification(taskID: taskID, hostID: hostID, browser: browser)
        }
    }
}

/// A completion handler the notification center hands over without marking it `Sendable`; it is called once, on the
/// main actor.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
