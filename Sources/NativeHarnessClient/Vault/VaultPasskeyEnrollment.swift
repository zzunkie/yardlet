import Foundation

/// The person makes a Yardlet passkey for the page in front of them (design §5.2, §8.3 "Make a Vault
/// Passkey"): for two minutes the tab's next passkey registration goes to an empty virtual authenticator,
/// and the credential it makes, private key included, goes into the vault.
@MainActor
enum VaultPasskeyEnrollment {
    static let window: Duration = .seconds(120)

    enum Outcome: Equatable {
        case saved(itemName: String)
        case timedOut
        case failed(String)
    }

    /// Waits for the page's registration on `cdp` (the tab's own connection) and saves the passkey: to
    /// the one item saved for the page if there is one, else to a new item named after the site.
    static func enroll(on cdp: any BrowserAgentCDP, pageAddress: String, vault: VaultCenter,
                       timeout: Duration = .seconds(15), cancelled: @escaping @MainActor () -> Bool = { false }) async -> Outcome {
        guard let origin = VaultSite.origin(of: pageAddress), let site = VaultSite.suggestion(for: pageAddress, suffixes: vault.suffixes) else {
            return .failed(L10n.string("Passkeys can be made only on https sites."))
        }
        let authenticator: String
        do {
            authenticator = try await VaultPasskeyAuthenticator.attach(cdp, timeout: timeout)
        } catch {
            return .failed(L10n.string("The browser did not make an authenticator for the passkey."))
        }
        let mark = cdp.eventLog.count
        let added = await VaultPasskeyAuthenticator.event("WebAuthn.credentialAdded", on: cdp, after: mark, limit: window,
                                                          stop: cancelled)
        var credential = added?["credential"]
        if credential?["privateKey"]?.stringValue == nil, added != nil {
            let listed = try? await cdp.send("WebAuthn.getCredentials", ["authenticatorId": .string(authenticator)], timeout: timeout)
            credential = listed?["credentials"]?.arrayValue?.last
        }
        await VaultPasskeyAuthenticator.detach(cdp, authenticator, timeout: timeout)
        guard let credential else { return .timedOut }
        guard let id = credential["credentialId"]?.stringValue, let key = credential["privateKey"]?.stringValue,
              let rp = credential["rpId"]?.stringValue else {
            return .failed(L10n.string("The browser did not hand over the new passkey."))
        }
        let passkey = VaultPasskey(credentialID: id, relyingPartyID: rp, userHandle: credential["userHandle"]?.stringValue ?? "",
                                   privateKey: key, signCount: Int(credential["signCount"]?.integerValue ?? 0))
        await vault.beginChange()
        defer { vault.endChange() }
        guard !cancelled() else { return .timedOut }
        let matching = vault.items(for: origin)
        var item: VaultItem
        var secret = VaultSecret()
        if matching.count == 1, let only = matching.first {
            item = only
            guard let saved = try? await vault.trustedSecret(of: only) else {
                return .failed(L10n.string("Yardlet could not read this sign-in from the keychain."))
            }
            secret = saved
        } else {
            item = VaultItem(name: VaultSite.host(of: origin), sites: [site],
                             username: credential["userName"]?.stringValue ?? "", policy: .always)
        }
        secret.passkey = passkey
        do {
            guard !cancelled() else { return .timedOut }
            try await vault.saveItem(item, secret: secret)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .saved(itemName: item.name)
    }
}
