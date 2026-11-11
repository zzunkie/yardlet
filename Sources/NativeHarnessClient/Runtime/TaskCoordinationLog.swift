import Foundation

/// A local record of what Yardlet decided about a task's runtime and turns, so that "why did this
/// task lose its CLI" or "what ended its turn" can be answered from the Mac it happened on instead of
/// guessed at:
/// `~/.yardlet/logs/task-coordination.log`, one JSON object a line, the newest half kept once it
/// passes 512 KiB. A line names the task by its ID, its harness, what happened and why. It holds
/// nothing of the conversation, no path, no account and no credential, and leaves the machine only
/// if the person sends it. Lines are written in order off the caller's thread. Tests never write the
/// person's file: the log is on only once the live app gives it one.
final class TaskCoordinationLog: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// What happened, such as "runtime-detached".
        var event: String
        /// The task's ID.
        var task: String
        var harness: String?
        /// Why, in a fixed word: a `RuntimeDetachReason` or a `TurnEndCause`.
        var reason: String?
        /// For a turn's end, the status it left the task in.
        var status: String?
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

    static let limit = 512 * 1024

    private let lock = NSLock()
    private var file: URL?
    private let queue = DispatchQueue(label: "app.yardlet.task-coordination-log", qos: .utility)

    /// Where lines go; nil, as in tests and fixtures, records nothing.
    var fileURL: URL? {
        get { lock.withLock { file } }
        set { lock.withLock { file = newValue } }
    }

    func record(_ entry: Entry, at date: Date = Date()) {
        guard let file = fileURL else { return }
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var data = try? encoder.encode(Line(time: ISO8601DateFormatter().string(from: date), entry: entry))
            else { return }
            data.append(0x0A)
            Self.append(data, to: file)
        }
    }

    /// Returns once every line recorded so far is written.
    func flush() {
        queue.sync {}
    }

    private static func append(_ data: Data, to file: URL) {
        let manager = FileManager.default
        let path = file.path(percentEncoded: false)
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if size + data.count > limit, var kept = try? Data(contentsOf: file) {
            kept = Data(kept.suffix(limit / 2))
            if let line = kept.firstIndex(of: 0x0A) { kept = Data(kept[kept.index(after: line)...]) }
            kept.append(data)
            try? kept.write(to: file, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
