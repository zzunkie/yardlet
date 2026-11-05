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

extension RemoteHostPlatform {
    /// Windows': the v2 listener on Winsock advertised with DNS-SD, the interfaces and the MagicDNS name, network
    /// changes from IP Helper, and this computer named as Windows names it. Nothing keeps the computer awake yet. The
    /// relay the build carries is in files beside its executable.
    static var current: RemoteHostPlatform {
        RemoteHostPlatform(
            makeListener: { server, identity in
                RemoteWinsockListener(server: server, staticKey: identity.noise, advertisement: .of(identity))
            },
            watchNetwork: { changed in RemoteAddressSelection.watchSystemInterfaces(changed) },
            interfaces: RemoteAddressSelection.systemInterfaces,
            resolveName: RemoteAddressSelection.magicDNSName(for:),
            isOnPower: { false },
            holdAwake: { _ in nil },
            computerName: { ProcessInfo.processInfo.environment["COMPUTERNAME"] ?? "Windows" },
            builtInRelay: { RemoteHostPlatform.relay(besides: Bundle.main.executableURL) })
    }
}

extension RemoteControlService {
    /// The remote for the Windows app: the paired devices and the audit log under `%LOCALAPPDATA%\Yardlet\remote` as
    /// the Mac keeps them under `~/.yardlet/remote`, and the keys in Credential Manager. Signing in to a relay account
    /// is not offered, so no account token is kept.
    static func live(model: AppModel) -> RemoteControlService {
        let folder = ((try? AppModel.windowsStorageRootURL()) ?? FileManager.default.temporaryDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: WindowsRemoteIdentityStore.live())
    }
}
