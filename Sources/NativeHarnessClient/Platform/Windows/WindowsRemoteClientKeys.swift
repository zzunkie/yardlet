import Foundation
import WinSDK
import YardletRemote

/// This computer's private key for each host it follows as a client (docs/REMOTE_PROTOCOL.md §11.2), each a
/// generic credential in Windows Credential Manager, as the Mac keeps one in its keychain: target
/// `<bundle identifier>.remote/client-<host ID>`, kept for this user on this computer and never roamed.
/// Removing a host deletes its key.
struct WindowsRemoteClientKeys: RemoteClientKeyStoring {
    let prefix: String

    static func live() -> Self {
        WindowsRemoteClientKeys(prefix: "\(YardletProduct.bundleIdentifier).remote/")
    }

    func load(hostID: String) -> RemoteKeyPair? {
        guard let blob = WindowsCredential.read(target(hostID)), let text = String(data: blob, encoding: .utf8),
              let key = RemoteEncoding.data(base64url: text) else { return nil }
        return try? RemoteKeyPair(privateKey: key)
    }

    func save(_ key: RemoteKeyPair, hostID: String) {
        WindowsCredential.write(Data(RemoteEncoding.base64url(key.privateKey).utf8), to: target(hostID))
    }

    func delete(hostID: String) {
        WindowsCredential.delete(target(hostID))
    }

    private func target(_ hostID: String) -> String { "\(prefix)client-\(hostID)" }
}

/// A generic credential of this user's in Windows Credential Manager, kept on this computer and never roamed:
/// what the Mac keeps as a generic password in its keychain.
enum WindowsCredential {
    static func read(_ target: String) -> Data? {
        target.withCString(encodedAs: UTF16.self) { target in
            var credential: PCREDENTIALW?
            guard CredReadW(target, DWORD(CRED_TYPE_GENERIC), 0, &credential), let credential else { return nil }
            defer { CredFree(credential) }
            guard let blob = credential.pointee.CredentialBlob, credential.pointee.CredentialBlobSize > 0 else { return nil }
            return Data(bytes: blob, count: Int(credential.pointee.CredentialBlobSize))
        }
    }

    @discardableResult
    static func write(_ data: Data, to target: String) -> Bool {
        var secret = Array(data)
        return target.withCString(encodedAs: UTF16.self) { target in
            "Yardlet".withCString(encodedAs: UTF16.self) { user in
                secret.withUnsafeMutableBufferPointer { blob in
                    var credential = CREDENTIALW()
                    credential.`Type` = DWORD(CRED_TYPE_GENERIC)
                    credential.TargetName = UnsafeMutablePointer(mutating: target)
                    credential.UserName = UnsafeMutablePointer(mutating: user)
                    credential.CredentialBlob = blob.baseAddress
                    credential.CredentialBlobSize = DWORD(blob.count)
                    credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&credential, 0)
                }
            }
        }
    }

    static func delete(_ target: String) {
        _ = target.withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
    }
}

extension RemoteHostDirectory {
    /// The Windows app's: the hosts in `%LOCALAPPDATA%\Yardlet\remote\hosts.json`, their keys in Credential
    /// Manager, what their windows last showed under `%LOCALAPPDATA%\Yardlet\Cache\remote`, and this computer
    /// named as Windows names it. Nothing looks for hosts on the network: a host is reached at the direct
    /// addresses it named (on the same network or over Tailscale) or through its relay (§11.4).
    static func live() -> RemoteHostDirectory {
        let root = (try? AppModel.windowsStorageRootURL()) ?? FileManager.default.temporaryDirectory
        let file = root.appending(path: "remote", directoryHint: .isDirectory).appending(path: "hosts.json")
        let caches = root.appending(path: "Cache", directoryHint: .isDirectory).appending(path: "remote", directoryHint: .isDirectory)
        let hello = RemoteHandshakeHello(
            name: ProcessInfo.processInfo.environment["COMPUTERNAME"] ?? "Windows", platform: "windows",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        return RemoteHostDirectory(store: .file(file), keys: WindowsRemoteClientKeys.live(), hello: hello,
                                   cacheRoot: caches)
    }
}
