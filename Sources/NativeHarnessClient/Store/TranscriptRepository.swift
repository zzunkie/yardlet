import Foundation

/// A bounded, app-owned reading snapshot. Provider state remains authoritative after a task is
/// resumed; this repository only lets a detached task show its last observed conversation.
protocol TranscriptRepository {
    func load(for sessionID: UUID) -> [TranscriptEntry]
    func save(_ entries: [TranscriptEntry], for sessionID: UUID)
    func remove(for sessionID: UUID)
}

struct UserDefaultsTranscriptRepository: TranscriptRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(
        defaults: UserDefaults = .yardlet,
        keyPrefix: String = "NativeHarnessClient.transcript."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return [] }
        return (try? JSONDecoder().decode([TranscriptEntry].self, from: data)) ?? []
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        let bounded = Array(entries.suffix(500))
        guard !bounded.isEmpty,
              let data = try? JSONEncoder().encode(bounded) else {
            remove(for: sessionID)
            return
        }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    /// Writes only when there is something to remove. A UserDefaults write posts
    /// `didChangeNotification`, which waits for its main-queue observers; posted from the snapshot
    /// queue while the main thread waits on that queue, it hung the app (2026-10-22).
    func remove(for sessionID: UUID) {
        let key = keyPrefix + sessionID.uuidString
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
    }
}

/// Keeps each task's snapshot in two files: `<task>.json`, the whole snapshot as a JSON array, and
/// `<task>.jsonl`, the entries added or changed since, one JSON object a line. A streaming task is
/// saved about once a second, and a save adds to the second file only what changed since the last:
/// rewriting a long conversation each second came to 8.6 GB in 18 minutes across a few tasks
/// (2026-11-09). The whole snapshot is written again, and the second file removed, once that file
/// has grown as large as the first, or when a save removes or reorders entries other than the
/// oldest (a rewound conversation). A reader that knows only the first file reads the snapshot as
/// it was then.
final class FileTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    /// The newest entries a snapshot keeps.
    static let limit = 500
    /// The changes file may grow to this before the snapshot is written whole again, however small
    /// the snapshot.
    static let minimumChangesBytes = 64 * 1024

    let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    /// What the files hold for each snapshot this repository wrote or read, so a save can find what
    /// changed. A snapshot not here is written whole.
    private var stored: [UUID: Stored] = [:]

    private struct Stored {
        var entries: [TranscriptEntry]
        /// The size of `<task>.json`, which the first line of the changes file names.
        var snapshotBytes: Int
        var changesBytes: Int
    }

    /// One line of the changes file: the size of the snapshot file it follows (the first line), the
    /// entry the snapshot now starts from (the ones before it dropped out), or an entry added or
    /// changed.
    private struct Change: Codable {
        var snapshot: Int?
        var from: UUID?
        var entry: TranscriptEntry?
    }

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        stored[sessionID] = nil
        guard let snapshot = try? Data(contentsOf: snapshotURL(for: sessionID)),
              var entries = try? JSONDecoder().decode([TranscriptEntry].self, from: snapshot) else {
            removeChanges(for: sessionID)
            return []
        }
        guard let changes = try? Data(contentsOf: changesURL(for: sessionID)) else {
            stored[sessionID] = Stored(entries: entries, snapshotBytes: snapshot.count, changesBytes: 0)
            return entries
        }
        let decoder = JSONDecoder()
        var lines = changes.split(separator: 10, omittingEmptySubsequences: false)
        let isComplete = lines.last?.isEmpty == true
        if isComplete { lines.removeLast() }
        // Changes written after another snapshot file (an older Yardlet wrote it) are not this one's.
        guard let first = lines.first, (try? decoder.decode(Change.self, from: first))?.snapshot == snapshot.count else {
            removeChanges(for: sessionID)
            stored[sessionID] = Stored(entries: entries, snapshotBytes: snapshot.count, changesBytes: 0)
            return entries
        }
        var index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var readAll = isComplete
        for line in lines.dropFirst() {
            // A save cut off part way leaves its last line unfinished; what came before still holds.
            guard let change = try? decoder.decode(Change.self, from: line) else { readAll = false; break }
            if let from = change.from, let start = index[from] {
                entries.removeFirst(start)
                index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            if let entry = change.entry {
                if let position = index[entry.id] { entries[position] = entry } else {
                    index[entry.id] = entries.count
                    entries.append(entry)
                }
            }
        }
        let result = Array(entries.suffix(Self.limit))
        // Changes added after an unfinished line would not be read, so the next save writes it all.
        if readAll {
            stored[sessionID] = Stored(entries: result, snapshotBytes: snapshot.count, changesBytes: changes.count)
        }
        return result
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        let bounded = Array(entries.suffix(Self.limit))
        guard !bounded.isEmpty else {
            remove(for: sessionID)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if let previous = stored[sessionID], let changes = Self.changes(from: previous.entries, to: bounded) {
            if changes.isEmpty {
                stored[sessionID]?.entries = bounded
                return
            }
            let encoder = JSONEncoder()
            var data = Data()
            for change in (previous.changesBytes == 0 ? [Change(snapshot: previous.snapshotBytes)] : []) + changes {
                guard let line = try? encoder.encode(change) else { data.removeAll(); break }
                data.append(line)
                data.append(10)
            }
            if !data.isEmpty,
               previous.changesBytes + data.count <= max(previous.snapshotBytes, Self.minimumChangesBytes),
               appendChanges(data, creating: previous.changesBytes == 0, for: sessionID) {
                stored[sessionID] = Stored(entries: bounded, snapshotBytes: previous.snapshotBytes,
                                           changesBytes: previous.changesBytes + data.count)
                return
            }
        }
        writeSnapshot(bounded, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        stored[sessionID] = nil
        removeChanges(for: sessionID)
        let url = snapshotURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// The lines that turn `old` into `new`, or nil when only writing `new` whole does: `new` keeps
    /// `old`'s entries in their order, less some at the start, and adds entries after them.
    private static func changes(from old: [TranscriptEntry], to new: [TranscriptEntry]) -> [Change]? {
        guard let first = new.first, Set(new.lazy.map(\.id)).count == new.count else { return nil }
        let start: Int? = old.isEmpty ? 0 : old.firstIndex(where: { $0.id == first.id })
        guard let start, old.count - start <= new.count else { return nil }
        var changes = start > 0 ? [Change(from: first.id)] : []
        for (offset, entry) in old[start...].enumerated() {
            guard new[offset].id == entry.id else { return nil }
            // Unchanged entries share their text with the saved ones, which compares at once.
            if new[offset] != entry { changes.append(Change(entry: new[offset])) }
        }
        changes += new[(old.count - start)...].map { Change(entry: $0) }
        return changes
    }

    private func writeSnapshot(_ entries: [TranscriptEntry], for sessionID: UUID) {
        stored[sessionID] = nil
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            // The changes go first: stopped between the two, the folder holds the older snapshot
            // whole rather than changes made to it read onto the newer one.
            removeChanges(for: sessionID)
            try data.write(to: snapshotURL(for: sessionID), options: .atomic)
            stored[sessionID] = Stored(entries: entries, snapshotBytes: data.count, changesBytes: 0)
        } catch {
            // The provider remains authoritative; an unavailable reading cache must not break a
            // task's live lifecycle.
        }
    }

    private func appendChanges(_ data: Data, creating: Bool, for sessionID: UUID) -> Bool {
        let url = changesURL(for: sessionID)
        if creating { return (try? data.write(to: url)) != nil }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func removeChanges(for sessionID: UUID) {
        let url = changesURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func snapshotURL(for sessionID: UUID) -> URL {
        directoryURL.appending(path: "\(sessionID.uuidString).json")
    }

    private func changesURL(for sessionID: UUID) -> URL {
        directoryURL.appending(path: "\(sessionID.uuidString).jsonl")
    }
}

/// Moves the brief UserDefaults-backed development snapshot into the product storage directory
/// without making migration success part of task restoration. Only loading migrates: a save
/// writes the file alone, so the snapshot queue does not touch UserDefaults or read back what it
/// just wrote on every save of a streaming task.
struct MigratingTranscriptRepository: TranscriptRepository {
    let primary: any TranscriptRepository
    let legacy: any TranscriptRepository

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        let current = primary.load(for: sessionID)
        guard current.isEmpty else { return current }
        let previous = legacy.load(for: sessionID)
        guard !previous.isEmpty else { return [] }
        primary.save(previous, for: sessionID)
        if !primary.load(for: sessionID).isEmpty {
            legacy.remove(for: sessionID)
        }
        return previous
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        primary.save(entries, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        primary.remove(for: sessionID)
        legacy.remove(for: sessionID)
    }
}
