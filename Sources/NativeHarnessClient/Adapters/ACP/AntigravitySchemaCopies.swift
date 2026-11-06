import Foundation

/// The copies of Yardlet's tool schemas that Antigravity CLI leaves in its data folder, and when they
/// go (docs/NATIVE_SESSION_STORAGE.md, "Antigravity CLI conversations").
///
/// `agy` writes each MCP server's tool schemas (`<toolName>.json` and `instructions.md`) to
/// `mcp/<server>/` when the server starts for a session and again when its tool list changes, and its
/// prompt tells the model to read a tool's schema there, so they have to stay while the process runs.
/// It does not remove them afterwards. It names servers per process: the first spec named `yardlet`
/// keeps the name, and a different one gets `yardlet_` and the first 8, 16 or all 64 hex digits of its
/// fingerprint. Each task's server carries its own token and task ID, so every task attached to an
/// `agy acp` process leaves a folder of about 2 MB.
///
/// A copy is unused once no running `agy` can have written it: a process writes the copies its
/// sessions read after it starts, so a copy last written before the oldest running `agy` started (any
/// copy, when none runs) belongs to none of them, and a later process that needs one writes it again.
/// Those go after an `agy acp` process Yardlet started has exited, and once at launch for what an
/// earlier run left. `mcp/yardlet/`, other servers' folders and copies written since are left alone,
/// and nothing goes while the process table cannot be read. Only `AppModel.live` turns this on for the
/// real folder: QA runs, fixtures and tests remove nothing there.
struct AntigravitySchemaCopies: Sendable {
    let directory: URL
    let table: any ProcessTableReading
    /// The names a process runs under to count as `agy`: the CLI's own, and the executable Yardlet runs.
    let executableNames: Set<String>

    static var live: AntigravitySchemaCopies {
        AntigravitySchemaCopies(
            directory: AntigravityConversationStore.live.root.appending(path: "mcp", directoryHint: .isDirectory),
            table: LiveProcessTable(),
            executableNames: ["agy"])
    }

    /// The same copies, counting processes of `executableURL` as `agy` too.
    func counting(_ executableURL: URL) -> AntigravitySchemaCopies {
        AntigravitySchemaCopies(directory: directory, table: table,
                                executableNames: executableNames.union([executableURL.lastPathComponent]))
    }

    /// `yardlet_` and 8, 16 or 64 lowercase hex digits, as `agy` names a second spec called `yardlet`.
    static func isCopy(named name: String) -> Bool {
        let prefix = "yardlet_"
        guard name.hasPrefix(prefix) else { return false }
        let digits = name.dropFirst(prefix.count)
        return [8, 16, 64].contains(digits.count) && digits.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Removes the unused copies and returns their names.
    @discardableResult
    func removeUnused(fileManager: FileManager = .default) -> [String] {
        guard let start = oldestRunningAgentStart() else { return [] }
        return Self.removeCopies(in: directory, writtenBefore: start, fileManager: fileManager)
    }

    /// When the oldest running `agy` started: `.distantFuture` when none runs, nil when the process
    /// table cannot be read, which is when it does not list Yardlet itself.
    func oldestRunningAgentStart() -> Date? {
        let entries = table.entries()
        let own = ProcessInfo.processInfo.processIdentifier
        guard entries.contains(where: { $0.processID == own }) else { return nil }
        let starts = entries.compactMap { entry -> Int64? in
            guard let name = table.name(of: entry.processID), executableNames.contains(name) else { return nil }
            return entry.startMicroseconds
        }
        guard let oldest = starts.min() else { return .distantFuture }
        return Date(timeIntervalSince1970: TimeInterval(oldest) / 1_000_000)
    }

    /// Removes the copies in `directory` whose newest file was written before `cutoff`.
    static func removeCopies(in directory: URL, writtenBefore cutoff: Date, fileManager: FileManager = .default) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        var removed: [String] = []
        for name in names.sorted() where isCopy(named: name) {
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            guard let written = lastWrite(of: folder, fileManager: fileManager), written < cutoff else { continue }
            do {
                try fileManager.removeItem(at: folder)
                removed.append(name)
            } catch {
                NSLog("Yardlet could not remove Antigravity's schema copy %@: %@", name, error.localizedDescription)
            }
        }
        return removed
    }

    /// The newest modification of the folder and the files in it; nil for anything but a folder, or
    /// when one of them cannot be read. `agy` rewrites the files in place, which leaves the folder's
    /// own date alone.
    private static func lastWrite(of folder: URL, fileManager: FileManager) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? folder.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true,
              var newest = values.contentModificationDate,
              let files = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        for file in files {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            newest = max(newest, date)
        }
        return newest
    }
}

// MARK: - Sweeps

extension AntigravitySchemaCopies {
    /// Sweeps run one after another, and an `agy` process Yardlet starts waits for the one queued
    /// (`waitForSweeps`), so the process never writes a copy while a sweep is deciding about it.
    private static let queue = SweepQueue()

    /// Removes the unused copies in the background once `ended` has finished (the process it stops
    /// has exited), after any sweep already queued. The sweep is queued before this returns.
    @discardableResult
    func sweep(after ended: Task<Void, Never>? = nil) -> Task<Void, Never> {
        Self.queue.append { [self] in
            await ended?.value
            removeUnused()
        }
    }

    /// Returns once the sweeps queued so far are done.
    static func waitForSweeps() async {
        await queue.last?.value
    }
}

private final class SweepQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func append(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = tail
            let task = Task.detached(priority: .utility) {
                await previous?.value
                await work()
            }
            tail = task
            return task
        }
    }

    var last: Task<Void, Never>? {
        lock.withLock { tail }
    }
}
