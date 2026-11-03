import Foundation
import Security
import YardletRemote

/// This Mac's private key for each host it follows as a client (docs/REMOTE_PROTOCOL.md §11.2), each a
/// generic password in the login keychain: service `<bundle identifier>.remote`, account `client-<host ID>`.
/// Removing a host deletes its key.
struct KeychainRemoteClientKeys: RemoteClientKeyStoring {
    let service: String

    static func live(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainRemoteClientKeys(service: "\(bundleIdentifier).remote")
    }

    private func query(_ hostID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "client-\(hostID)"]
    }

    func load(hostID: String) -> RemoteKeyPair? {
        var search = query(hostID)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), let key = RemoteEncoding.data(base64url: text) else { return nil }
        return try? RemoteKeyPair(privateKey: key)
    }

    func save(_ key: RemoteKeyPair, hostID: String) {
        let data = Data(RemoteEncoding.base64url(key.privateKey).utf8)
        if SecItemUpdate(query(hostID) as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = query(hostID)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet remote"
            item[kSecAttrDescription] = "Yardlet key for another Mac"
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    func delete(hostID: String) {
        _ = SecItemDelete(query(hostID) as CFDictionary)
    }
}

extension RemoteHostDirectory {
    /// The app's: the hosts in `~/.yardlet/remote/hosts.json`, their keys in the Keychain, what their
    /// windows last showed in `~/Library/Caches/<bundle identifier>/remote/`, Bonjour to find them, and this
    /// Mac named as it names itself.
    static func live() -> RemoteHostDirectory {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
            .appending(path: "hosts.json")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
        let hello = RemoteHandshakeHello(
            name: Host.current().localizedName ?? "Mac", platform: "macos",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        return RemoteHostDirectory(store: RemoteHostStore(fileURL: file), keys: KeychainRemoteClientKeys.live(), hello: hello,
                                   cacheRoot: caches, discovery: .bonjour)
    }
}
