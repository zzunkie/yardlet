import Foundation
import Security

/// The app's secrets in the Keychain: each paired Mac's client key, and the push keys the notification service
/// extension opens pushes with. Kept on this device only (never in a backup), and readable after the first unlock,
/// so a push that arrives while the phone is locked can still be read.
///
/// No query names an access group: a new item goes to the first group of the target's `keychain-access-groups`,
/// which the app and its notification service extension share, and a read searches every group the target has.
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Saves `data`, replacing what the account held. `label` lets `delete(service:label:)` find the items that
    /// belong together (one Mac's push key).
    @discardableResult
    static func write(_ data: Data, service: String, account: String, label: String? = nil) -> Bool {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
        var item = base(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let label { item[kSecAttrLabel as String] = label }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }

    /// Deletes every item of `service` saved with `label`.
    static func delete(service: String, label: String) {
        var query = base(service: service, account: nil)
        query[kSecAttrLabel as String] = label
        SecItemDelete(query as CFDictionary)
    }

    private static func base(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
