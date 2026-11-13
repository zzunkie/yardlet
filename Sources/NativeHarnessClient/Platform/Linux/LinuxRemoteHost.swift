import Foundation
import Glibc
import YardletRemote

extension RemoteHostPlatform {
    /// The Linux host's, keeping to private networks.
    static var current: RemoteHostPlatform { linux(reach: .privateNetworks) }

    /// The Linux host's: the direct-path listener on BSD sockets (`RemoteLinuxListener`), on loopback, private and
    /// Tailscale addresses unless the person chose every address; the interfaces from `getifaddrs` and their changes
    /// from netlink; the computer named by its host name, always on power, and nothing to keep awake. The relay the
    /// build carries is in files beside its executable, as the Windows app's is.
    static func linux(reach: RemoteLinuxListener.Reach) -> RemoteHostPlatform {
        RemoteHostPlatform(
            makeListener: { server, identity in
                RemoteLinuxListener(server: server, staticKey: identity.noise, reach: reach)
            },
            watchNetwork: { changed in RemoteAddressSelection.watchSystemInterfaces(changed) },
            interfaces: RemoteAddressSelection.systemInterfaces,
            resolveName: RemoteAddressSelection.magicDNSName(for:),
            isOnPower: { true },
            holdAwake: { _ in nil },
            computerName: { LinuxHostName.current },
            builtInRelay: { RemoteHostPlatform.relay(besides: Bundle.main.executableURL) },
            advertisesPublicAddresses: reach == .everyAddress)
    }
}

extension RemoteControlService {
    /// The remote for the Linux host: the paired devices and the audit log under the data folder's `remote/`
    /// (`LinuxHostPaths`), in the Mac's format, and the keys in a file there or in the session's keyring
    /// (`LinuxRemoteIdentityStore`). Signing in to a relay account is not offered, so no account token is kept.
    static func live(model: AppModel, name: String? = nil,
                     reach: RemoteLinuxListener.Reach = .privateNetworks) -> RemoteControlService {
        let folder = LinuxHostPaths.remoteFolder()
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: LinuxRemoteIdentityStore.live(folder: folder),
            platform: .linux(reach: reach),
            macName: name,
            appVersion: LinuxHostVersion.current)
    }
}

/// The name devices see for this computer when the person gives none: its host name, as `hostname` prints it.
enum LinuxHostName {
    static var current: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "Linux" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "Linux" : name
    }
}

/// The host's version: the first line of `YardletVersion` beside its executable, which the release's packaging writes
/// from the Mac app's version (scripts/linux/package-host.sh), else "dev".
enum LinuxHostVersion {
    static let current: String = {
        guard let folder = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
              let text = try? String(contentsOf: folder.appending(path: "YardletVersion"), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return "dev" }
        return line
    }()
}
