import Foundation
import Glibc
import YardletRemote

extension RemoteHostPlatform {
    /// The Linux host's: the relay where this computer's libcurl can open its socket (`LinuxRelaySupport`), the computer
    /// named by its host name, always on power, and nothing to keep awake. The relay the build carries is in files
    /// beside its executable, as the Windows app's is.
    static var current: RemoteHostPlatform {
        RemoteHostPlatform(
            makeListener: { _, _ in nil },
            watchNetwork: { _ in nil },
            interfaces: { [] },
            resolveName: { _ in nil },
            isOnPower: { true },
            holdAwake: { _ in nil },
            computerName: { LinuxHostName.current },
            builtInRelay: { RemoteHostPlatform.relay(besides: Bundle.main.executableURL) },
            relayUnavailable: { LinuxRelaySupport.unavailableReason })
    }
}

extension RemoteControlService {
    /// The remote for the Linux host: the paired devices, the audit log and the keys under the data folder's `remote/`
    /// (`LinuxHostPaths`), in the Mac's format. Signing in to a relay account is not offered, so no account token is
    /// kept.
    static func live(model: AppModel, name: String? = nil) -> RemoteControlService {
        let folder = LinuxHostPaths.remoteFolder()
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: RemoteFileIdentityStore(fileURL: folder.appending(path: "identity.json")),
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
