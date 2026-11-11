import Foundation

/// System notifications: none are shown. The Windows app has its own (Platform/Windows/WindowsNotifications.swift).
final class LocalSystemNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(title: String, body: String, identifier: String) async {}
}
