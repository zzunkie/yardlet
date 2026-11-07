import Foundation

/// A local record of how a Claude login read, so a report like "Terminal is signed in and Yardlet
/// says it isn't" can be settled from the Mac it happened on: `~/.yardlet/logs/account-checks.log`,
/// one JSON object a line, the newest half kept once it passes 512 KiB. It names the program, the
/// config folder and what they answered, and how long each took. It holds no credential, no address
/// and no CLI output, and leaves the machine only if the person sends it. Tests never write it: it
/// is on only when the live app sets `fileURL`.
enum AccountCheckLog {
    struct Entry: Encodable, Sendable {
        var event = "status"
        var harness: String
        /// "default", or the saved connection's id.
        var account: String
        var runtime: String?
        /// The config folder, or "default" for `~/.claude`.
        var configHome: String
        var state: String?
        var exitCode: Int32?
        var milliseconds: Int?
        var authMethod: String?
        var apiProvider: String?
        /// Whether the login's Keychain item exists, read as metadata: "found", "missing" or "unreadable".
        var credentialItem: String?
        var credentialItemMilliseconds: Int?
        /// Names only: the variables a login shell sets that decide how Claude Code signs in.
        var shellVariables: [String]?
        var failure: String?
    }

    private struct Line: Encodable {
        let time: String
        let entry: Entry
        func encode(to encoder: any Encoder) throws {
            try entry.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(time, forKey: .time)
        }
        enum Key: String, CodingKey { case time }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var fileURL: URL?
    }

    private static let state = State()
    static let limit = 512 * 1024

    static var fileURL: URL? {
        get { state.lock.withLock { state.fileURL } }
        set { state.lock.withLock { state.fileURL = newValue } }
    }

    static func record(_ entry: Entry, at date: Date = Date()) {
        state.lock.withLock {
            guard let file = state.fileURL else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let time = ISO8601DateFormatter().string(from: date)
            guard var data = try? encoder.encode(Line(time: time, entry: entry)) else { return }
            data.append(0x0A)
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var kept = (try? Data(contentsOf: file)) ?? Data()
            if kept.count + data.count > limit {
                kept = Data(kept.suffix(limit / 2))
                if let line = kept.firstIndex(of: 0x0A) { kept = Data(kept[kept.index(after: line)...]) }
            }
            kept.append(data)
            try? kept.write(to: file, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
