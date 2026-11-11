import Foundation

/// Where a harness keeps its login on this platform is not known here. The Windows app has its own
/// (Platform/Windows/WindowsAccounts.swift).
extension HarnessAccountBroker {
    static func antigravityCredentialState() -> AccountAuthState { .unknown }
    static func claudeCredentialItem(configDirectory: String?) -> String { "unreadable" }
}
