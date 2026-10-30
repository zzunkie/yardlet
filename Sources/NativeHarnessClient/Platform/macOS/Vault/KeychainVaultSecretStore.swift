import Foundation
import Security

/// Vault secrets as generic passwords in the login keychain, one item per vault item: service
/// `<bundle identifier>.vault`, account the item's ID, labelled without the site's name. An item the
/// app adds trusts the app's designated requirement, which for a team-signed build names the team
/// (docs/BROWSER_VAULT_DESIGN.md §4.3); a QA bundle's own identifier keeps its items apart.
struct KeychainVaultSecretStore: VaultSecretStoring {
    struct KeychainError: Error, LocalizedError {
        var status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return L10n.format("The keychain refused the password item: %@", message)
        }
    }

    let service: String

    static func live(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainVaultSecretStore(service: "\(bundleIdentifier).vault")
    }

    private func query(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    func load(_ id: UUID) throws -> VaultSecret? {
        var search = query(id)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(VaultSecret.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ secret: VaultSecret, for id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet vault item"
            item[kSecAttrDescription] = "Yardlet vault for agents"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The person's addresses and cards (design §18): one item of this service, account `wallet`.
    private var walletQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "wallet"]
    }

    func loadWallet() throws -> VaultWallet? {
        var search = walletQuery
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(VaultWallet.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Saves the wallet, or deletes its item when there is none (nil or empty).
    func saveWallet(_ wallet: VaultWallet?) throws {
        guard let wallet, !wallet.isEmpty else {
            let status = SecItemDelete(walletQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = try JSONEncoder().encode(wallet)
        let status = SecItemUpdate(walletQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = walletQuery
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet addresses and cards"
            item[kSecAttrDescription] = "Yardlet browser autofill"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Every item of this service, the wallet's too: on macOS a delete removes all that match.
    func deleteAll() throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
