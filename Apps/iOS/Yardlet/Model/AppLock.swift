import Foundation
import LocalAuthentication
import Observation

/// App Lock: off unless the person turns it on. When on, the app locks each time it goes to the background and asks
/// for Face ID, Touch ID or the passcode to open again. It guards a phone left unlocked; the Mac's own approvals and
/// the end-to-end encryption do not depend on it.
@MainActor
@Observable
final class AppLock {
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAsking = false
    /// Ask for the owner by itself the next time the app comes to the front: at launch and after the background, not
    /// after the Face ID prompt itself (which also takes the app out of the front), so a cancelled prompt does not
    /// come straight back; Unlock asks again.
    private var asksWhenInFront: Bool

    init() {
        let enabled = UserDefaults.standard.bool(forKey: "appLock")
        isEnabled = enabled
        isLocked = enabled
        asksWhenInFront = enabled
    }

    func appWentAway() {
        guard isEnabled else { return }
        isLocked = true
        asksWhenInFront = true
    }

    /// The app is in front again: a locked app asks for the owner at once.
    func appCameToFront() {
        guard isLocked, asksWhenInFront else { return }
        asksWhenInFront = false
        Task { await unlock() }
    }

    func unlock() async {
        guard isLocked, !isAsking else { return }
        if await confirm(String(localized: "Unlock Yardlet")) { isLocked = false }
    }

    /// Turning it on or off asks for the owner first, as unlocking does.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        guard await confirm(enabled ? String(localized: "Turn on App Lock") : String(localized: "Turn off App Lock")) else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "appLock")
    }

    /// Whether this phone can lock the app at all (a passcode is set).
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private func confirm(_ reason: String) async -> Bool {
        isAsking = true
        defer { isAsking = false }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
