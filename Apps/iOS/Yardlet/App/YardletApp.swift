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

/// Push registration, opened notifications, and background pushes that withdraw a notification. The notification
/// center calls its delegate on the main thread, and UIKit wants a response's completion called there too.
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// A notification opened, or its Allow Once chosen (`PushNotice.allowOnceAction`).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let taskID = info[PushNotice.taskKey] as? String
        let hostID = info[PushNotice.hostKey] as? String
        if response.actionIdentifier == PushNotice.allowOnceAction, let taskID, let hostID,
           let requestID = info[PushNotice.requestKey] as? String {
            PhoneModel.shared.allowOnceFromNotification(taskID: taskID, hostID: hostID, requestID: requestID)
        } else {
            // A tab handed to the person opens over its task (§15.18).
            let browser = response.notification.request.content.categoryIdentifier == PushNotice.Kind.browser.rawValue
            PhoneModel.shared.openNotification(taskID: taskID, hostID: hostID, browser: browser)
        }
        completionHandler()
    }
}
