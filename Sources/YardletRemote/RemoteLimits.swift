import Foundation
#if canImport(Network)
import Network
#endif

/// A token bucket: `capacity` at once, refilled at `perSecond`.
public struct RemoteRateBucket: Sendable {
    public let capacity: Double
    public let perSecond: Double
    private var tokens: Double
    private var updatedAt: Date

    public init(capacity: Double, perSecond: Double, now: Date = Date()) {
        self.capacity = capacity
        self.perSecond = perSecond
        tokens = capacity
        updatedAt = now
    }

    /// Takes one token when there is one.
    public mutating func take(now: Date = Date()) -> Bool {
        tokens = min(capacity, tokens + max(0, now.timeIntervalSince(updatedAt)) * perSecond)
        updatedAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// The rates a connection may send at (§7): every request, and commands apart.
public struct RemoteRateLimiter: Sendable {
    private var requests: RemoteRateBucket
    private var commands: RemoteRateBucket
    /// Requests refused in a row; this many closes the connection.
    public private(set) var refusedInARow = 0
    public static let refusalsBeforeClosing = 20

    public init(now: Date = Date()) {
        requests = RemoteRateBucket(capacity: 30, perSecond: 10, now: now)
        commands = RemoteRateBucket(capacity: 10, perSecond: 1.0 / 3.0, now: now)
    }

    /// Whether the request may go on.
    public mutating func admit(isCommand: Bool, now: Date = Date()) -> Bool {
        var admitted = requests.take(now: now)
        if admitted, isCommand { admitted = commands.take(now: now) }
        refusedInARow = admitted ? 0 : refusedInARow + 1
        return admitted
    }
}

/// How a listener holds connections that have not finished their handshake (§7): at most
/// `maxWaitingPerHost` from one address and `maxWaiting` in all, the oldest closing for a new one, and none
/// longer than `handshakeTimeout`. Only the Mac's own limits; a phone needs one connection per path.
public enum RemoteHandshakeAdmission {
    public static let maxWaiting = 16
    public static let maxWaitingPerHost = 4
    public static let handshakeTimeout: TimeInterval = 10

    /// The waiting connections to close so that a new one from `host` fits.
    public static func displaced<ID: Hashable>(waiting: [(id: ID, host: String, since: Date)], host: String) -> [ID] {
        var remaining = waiting.sorted { $0.since < $1.since }
        var closing: [ID] = []
        if let oldest = remaining.first(where: { $0.host == host }),
           remaining.count(where: { $0.host == host }) >= maxWaitingPerHost {
            closing.append(oldest.id)
            remaining.removeAll { $0.id == oldest.id }
        }
        if remaining.count >= maxWaiting, let oldest = remaining.first { closing.append(oldest.id) }
        return closing
    }

    #if canImport(Network)
    /// The address part of a connection's remote endpoint.
    public static func host(of endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case let .ipv4(value): return "\(value)"
        case let .ipv6(value): return "\(value)"
        case let .name(name, _): return name
        @unknown default: return "\(host)"
        }
    }
    #endif
}

/// A local record of what remote devices did: when, which device, the request's type, its task and
/// the result. Never a message's text. One JSON object per line, trimmed to the latest lines.
public final class RemoteAuditLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var device: String?
        public var type: String
        public var task: String?
        public var result: String
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "yardlet.remote.audit")
    private let keptLines: Int

    public init(fileURL: URL, keptLines: Int = 2_000) {
        self.fileURL = fileURL
        self.keptLines = keptLines
    }

    public func record(device: String?, type: String, task: String?, result: String, at: Date = Date()) {
        let entry = Entry(at: at, device: device, type: type, task: task, result: result)
        queue.async { [fileURL, keptLines] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            // Trim to the latest lines once the file holds a quarter more than it keeps.
            if let size = try? handle.offset(), size > UInt64(keptLines * 200),
               let data = try? Data(contentsOf: fileURL) {
                let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
                if lines.count > keptLines + keptLines / 4 {
                    let kept = lines.suffix(keptLines).joined(separator: [0x0A]) + [0x0A]
                    try? Data(kept).write(to: fileURL, options: .atomic)
                    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                }
            }
        }
    }

    /// Waits for every entry recorded so far to be written (tests).
    public func flush() {
        queue.sync {}
    }

    public func entries() -> [Entry] {
        flush()
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }
}
