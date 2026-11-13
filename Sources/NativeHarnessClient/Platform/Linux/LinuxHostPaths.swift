import Foundation
import Glibc

/// Where the Linux host keeps what stays on the computer (docs/LINUX_HOST.md, "What it keeps"): its data folder,
/// `$XDG_DATA_HOME/yardlet` or `~/.local/share/yardlet`, readable by the person alone (0700). The task index,
/// transcripts and drafts are in it as the Mac keeps them in `~/.yardlet`, the remote's devices, audit log and keys in
/// `remote/`, and the running host's lock and control socket at its top.
enum LinuxHostPaths {
    /// The data folder, made on first use.
    static func dataRoot(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let root = dataRootLocation(environment: environment)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(root.path(percentEncoded: false), 0o700)
        return root
    }

    /// The data folder's place, made or not: `$XDG_DATA_HOME/yardlet` when that names an absolute folder, as the XDG
    /// Base Directory rules ask, else `~/.local/share/yardlet`.
    static func dataRootLocation(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let base = environment["XDG_DATA_HOME"], base.hasPrefix("/") {
            return URL(filePath: base, directoryHint: .isDirectory).appending(path: "yardlet", directoryHint: .isDirectory)
        }
        return home(environment: environment).appending(path: ".local/share/yardlet", directoryHint: .isDirectory)
    }

    static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["HOME"], home.hasPrefix("/") { return URL(filePath: home, directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func remoteFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        dataRootLocation(environment: environment).appending(path: "remote", directoryHint: .isDirectory)
    }

    /// The running host's control socket, which `yardlet host status` and `pair` reach.
    static func controlSocket(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        dataRootLocation(environment: environment).appending(path: "host.sock").path(percentEncoded: false)
    }

    /// The lock the running host holds, with its process ID, so a second one does not start.
    static func lockFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        dataRootLocation(environment: environment).appending(path: "host.lock").path(percentEncoded: false)
    }
}
