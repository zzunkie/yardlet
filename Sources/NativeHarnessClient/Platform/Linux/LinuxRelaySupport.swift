import Foundation
import Glibc

/// Whether this computer's libcurl can open the relay's socket (docs/LINUX_HOST.md, "The relay"). Foundation on Linux
/// opens a WebSocket through the system's libcurl, which speaks it only when it was built with WebSocket support:
/// curl 8.11 and later by default, earlier ones only when the distribution turned on what was then experimental.
/// libcurl lists the protocols it speaks in `curl_version_info`; the host reads that list once, from the libcurl
/// Foundation already loaded, and leaves the relay off when `ws` is not in it.
enum LinuxRelaySupport {
    struct Reading: Equatable, Sendable {
        /// libcurl's version, nil when it could not be loaded.
        var version: String?
        var speaksWebSocket: Bool
    }

    static let current: Reading = read()

    /// Why the relay cannot be used here, nil when it can.
    static var unavailableReason: String? {
        guard !current.speaksWebSocket else { return nil }
        guard let version = current.version else { return "libcurl could not be loaded" }
        return "this computer's libcurl \(version) has no WebSocket support (curl 8.11 or later has it)"
    }

    private static func read() -> Reading {
        guard let library = dlopen("libcurl.so.4", RTLD_NOW | RTLD_NOLOAD) ?? dlopen("libcurl.so.4", RTLD_NOW),
              let symbol = dlsym(library, "curl_version_info") else { return Reading(version: nil, speaksWebSocket: false) }
        typealias VersionInfo = @convention(c) (Int32) -> UnsafeRawPointer?
        // CURLVERSION_FIRST: the fields read here are in every version of the struct, which libcurl returns whole.
        guard let info = unsafeBitCast(symbol, to: VersionInfo.self)(0) else {
            return Reading(version: nil, speaksWebSocket: false)
        }
        return Reading(version: string(at: Layout.version, in: info), speaksWebSocket: protocols(in: info).contains("ws"))
    }

    /// Where `curl_version_info_data`'s fields sit on a 64-bit Linux (LP64): `age` (an int, then padding), `version`,
    /// `version_num` (an unsigned int, then padding), `host`, `features` (an int, then padding), `ssl_version`,
    /// `ssl_version_num` (a long), `libz_version`, `protocols`.
    private enum Layout {
        static let version = 8
        static let protocols = 64
    }

    private static func string(at offset: Int, in info: UnsafeRawPointer) -> String? {
        info.load(fromByteOffset: offset, as: UnsafePointer<CChar>?.self).map { String(cString: $0) }
    }

    private static func protocols(in info: UnsafeRawPointer) -> [String] {
        guard var entry = info.load(fromByteOffset: Layout.protocols, as: UnsafePointer<UnsafePointer<CChar>?>?.self)
        else { return [] }
        var names: [String] = []
        while let name = entry.pointee, names.count < 128 {
            names.append(String(cString: name))
            entry += 1
        }
        return names
    }
}
