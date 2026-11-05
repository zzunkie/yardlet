import Foundation
import YardletRemote

/// This computer's remote keys (docs/REMOTE_PROTOCOL.md §11.2) as one generic credential in Credential Manager,
/// target `<bundle identifier>.remote/identity`, in the form the Mac keeps in its keychain.
struct WindowsRemoteIdentityStore: RemoteIdentityStoring {
    let target: String

    static func live() -> Self {
        WindowsRemoteIdentityStore(target: "\(YardletProduct.bundleIdentifier).remote/identity")
    }

    func load() throws -> RemoteIdentity? {
        try WindowsCredential.read(target).map(RemoteIdentity.init(stored:))
    }

    func save(_ identity: RemoteIdentity) throws {
        guard WindowsCredential.write(identity.stored, to: target) else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension RemoteControlService {
    /// The remote for the Windows app: the relay alone for now, the paired devices and the audit log under
    /// `%LOCALAPPDATA%\Yardlet\remote` as the Mac keeps them under `~/.yardlet/remote`, the keys in Credential
    /// Manager, and this computer named as Windows names it. Signing in to a relay account is not offered, so no
    /// account token is kept.
    static func live(model: AppModel) -> RemoteControlService {
        let folder = ((try? AppModel.windowsStorageRootURL()) ?? FileManager.default.temporaryDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: WindowsRemoteIdentityStore.live(),
            macName: ProcessInfo.processInfo.environment["COMPUTERNAME"] ?? "Windows")
    }
}
