import Foundation
import YardletRemote

/// This phone's private key for each paired Mac (docs/REMOTE_PROTOCOL.md §11.2): one per Mac, in the Keychain on
/// this device only. A key is the device the Mac knows, so a backup restored on another phone pairs again.
struct KeychainClientKeys: RemoteClientKeyStoring {
    static let service = "com.zzunkie.yardlet.remote.client-key"

    func load(hostID: String) -> RemoteKeyPair? {
        Keychain.read(service: Self.service, account: hostID).flatMap { try? RemoteKeyPair(privateKey: $0) }
    }

    func save(_ key: RemoteKeyPair, hostID: String) {
        Keychain.write(key.privateKey, service: Self.service, account: hostID)
    }

    func delete(hostID: String) {
        Keychain.delete(service: Self.service, account: hostID)
    }
}

/// The push keys the Macs made for this phone (§15.6), kept where the notification service extension reads them:
/// the key under its key ID, and beside it which Mac it belongs to.
enum PushKeys {
    static func save(_ key: Data, keyID: String, hostID: String) {
        Keychain.write(key, service: PushNotice.keyService, account: keyID, label: hostID)
        Keychain.write(Data(hostID.utf8), service: PushNotice.keyService + ".host", account: keyID, label: hostID)
    }

    static func delete(hostID: String) {
        Keychain.delete(service: PushNotice.keyService, label: hostID)
        Keychain.delete(service: PushNotice.keyService + ".host", label: hostID)
    }
}
