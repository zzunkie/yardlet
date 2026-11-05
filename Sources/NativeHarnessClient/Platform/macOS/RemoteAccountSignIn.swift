import AppKit
import AuthenticationServices
import Foundation
import Security

/// The browser sign-in sheet for the relay's accounts (docs/REMOTE_PROTOCOL.md §14.4), as apps sign in
/// with a provider: the system's web authentication session, returning to `yardlet-remote://auth`.
@MainActor
final class RemoteAccountSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // The session calls back on its own XPC queue, not the main actor this class runs on.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    continuation.resume(throwing: error)
                } else {
                    // The person closed the sheet: the sign-in ends without an error.
                    continuation.resume(throwing: CancellationError())
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: CancellationError()) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

/// The account token in the login keychain under the remote's own service (`<bundle identifier>.remote`).
struct KeychainRemoteSecret: RemoteSecretStoring {
    let service: String
    let account: String

    static func accountToken(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainRemoteSecret(service: "\(bundleIdentifier).remote", account: "account-token")
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func load() -> String? {
        var search = query
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet remote account"
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    func delete() {
        _ = SecItemDelete(query as CFDictionary)
    }
}
