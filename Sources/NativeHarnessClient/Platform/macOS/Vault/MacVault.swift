import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The macOS parts of the vault for agents: the keychain, Touch ID (or the login password), the
/// keyed hash for one-time codes, whether this build is team-signed, and the screen locking.
@MainActor
enum MacVault {
    static func makeCenter() -> VaultCenter {
#if DEBUG
        // QA runs keep the vault in memory (a temporary home has no login keychain) and allow it in
        // an ad-hoc build; YARDLET_VAULT_QA_CONFIRM=1 answers Touch ID with yes, else it is a no.
        if ProcessInfo.processInfo.environment["YARDLET_VAULT_QA"] == "1"
            || CommandLine.arguments.contains("--ui-fixture-browser-check-only=vault") {
            let confirms = ProcessInfo.processInfo.environment["YARDLET_VAULT_QA_CONFIRM"] == "1"
            return VaultCenter(environment: VaultCenter.Environment(
                secrets: InMemoryVaultSecretStore(), repository: InMemoryVaultRepository(), hmac: hmac,
                isAllowedBuild: true, confirm: { _ in confirms }, randomBytes: randomBytes))
        }
#endif
        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: KeychainVaultSecretStore.live(), repository: FileVaultRepository.live(), hmac: hmac,
            isAllowedBuild: isTeamSigned, confirm: confirm, randomBytes: randomBytes))
        observeLocks(of: center)
        return center
    }

    nonisolated static func hmac(_ algorithm: OneTimeCodeSecret.Algorithm, key: Data, message: Data) -> Data {
        let symmetric = SymmetricKey(data: key)
        switch algorithm {
        case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
    }

    /// Bytes from the system's secure random source, for new passwords; nil when it fails.
    nonisolated static func randomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? bytes : nil
    }

    /// Whether the running app is signed by a team (Developer ID or Apple Development): its keychain
    /// items then trust only builds of that team.
    static var isTeamSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        else { return false }
        return !team.isEmpty
    }

    /// Touch ID, or the login password on a Mac without it. Unanswered for two minutes, it is a no.
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { context.invalidate() }
        }
        defer { timeout.cancel() }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// The vault locks when the screen locks or the Mac sleeps (design §6.4).
    private static func observeLocks(of center: VaultCenter) {
        let lock: @Sendable (Notification) -> Void = { [weak center] _ in
            Task { @MainActor in center?.lock() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main, using: lock)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                                          object: nil, queue: .main, using: lock)
    }
}
