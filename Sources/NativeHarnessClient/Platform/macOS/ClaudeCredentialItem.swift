import CryptoKit
import Foundation
import Security

extension HarnessAccountBroker {
    /// The Keychain item Claude Code keeps a login in (2.1.318): `Claude Code-credentials`, with the
    /// first eight hex digits of the config folder's SHA-256 when `CLAUDE_CONFIG_DIR` names one.
    static func claudeCredentialService(configDirectory: String?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// Whether the login's item exists, for `AccountCheckLog`. Only the item's identity is asked,
    /// as for Antigravity's; its value is never requested, so macOS asks nothing.
    static func claudeCredentialItem(configDirectory: String?, keychainStatus: OSStatus? = nil) -> String {
        let status = keychainStatus ?? SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: claudeCredentialService(configDirectory: configDirectory),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: false
        ] as CFDictionary, nil)
        switch status {
        case errSecSuccess: return "found"
        case errSecItemNotFound: return "missing"
        default: return "unreadable"
        }
    }
}
