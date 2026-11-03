import Foundation
#if canImport(os)
import os
#endif

/// The remote's connection log: the relay room and each phone's connection opening and closing, the close
/// code and reason, and how long each was up, so a dropped phone leaves a reason on the Mac. Read it with
/// `log show --info --predicate 'subsystem == "com.zzunkie.yardlet" AND category == "remote"'`. It names devices by
/// the start of their ID and paths by kind, never keys, addresses, device names or what a connection carries.
/// Notice level, which the system keeps on disk; a platform without `os` logs nothing.
enum RemoteLog {
#if canImport(os)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zzunkie.yardlet", category: "remote")
#endif

    static func notice(_ message: @autoclosure () -> String) {
#if canImport(os)
        let text = message()
        logger.notice("\(text, privacy: .public)")
#endif
    }

    /// A device as the log names it: the start of its ID.
    static func device(_ id: String?) -> String {
        id.map { String($0.prefix(8)) } ?? "unpaired"
    }

    /// Seconds, to a tenth.
    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", interval)
    }

    /// An error as its domain and code, which name no address.
    static func error(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
