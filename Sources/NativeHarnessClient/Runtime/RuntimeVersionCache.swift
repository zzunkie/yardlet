import Foundation

/// The version each runtime file reports with `--version`, read off the main thread and read again
/// only when the file changes: another file behind the path (a link that moved to a new version),
/// or another size, modification time or file number. Choosing the newest install then runs one
/// `--version` per install the first time and none after; the versions are kept in Yardlet's
/// preferences, so the choice at launch needs no process.
final class RuntimeVersionCache: @unchecked Sendable {
    private struct Entry: Codable, Equatable {
        var stamp: Stamp
        var version: String
    }

    private struct Stamp: Codable, Equatable {
        var size: UInt64
        var modified: Double
        var fileNumber: UInt64
    }

    static let defaultsKey = "runtime.versions"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let read: @Sendable (URL) async -> String?
    private var entries: [String: Entry]
    private var reading: [String: Task<String?, Never>] = [:]

    init(defaults: UserDefaults?, read: @escaping @Sendable (URL) async -> String? = RuntimeVersionCache.readVersion) {
        self.defaults = defaults
        self.read = read
        entries = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// The version recorded for the file at `url` while it is unchanged. Nothing is run.
    func cachedVersion(of url: URL) -> String? {
        guard let (path, stamp) = Self.stamp(of: url) else { return nil }
        return lock.withLock { entries[path].flatMap { $0.stamp == stamp ? $0.version : nil } }
    }

    /// The version of the file at `url`, read with `--version` when it changed since the last read.
    /// A version that could not be read is not kept, so the next look tries again.
    func version(of url: URL) async -> String? {
        guard let (path, stamp) = Self.stamp(of: url) else { return nil }
        var known: String?
        let task: Task<String?, Never>? = lock.withLock {
            if let entry = entries[path], entry.stamp == stamp {
                known = entry.version
                return nil
            }
            if let running = reading[path] { return running }
            let read = self.read
            let task = Task { await read(url) }
            reading[path] = task
            return task
        }
        guard let task else { return known }
        let version = await task.value
        lock.withLock {
            reading[path] = nil
            guard let version else { return }
            entries[path] = Entry(stamp: stamp, version: version)
            // Versions an installer or app removed since go with them.
            entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
            if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: Self.defaultsKey) }
        }
        return version
    }

    /// `<runtime> --version`, read as the CLI update check reads it.
    static func readVersion(_ url: URL) async -> String? {
        let result = await CLIProcess.run(CLICommand(executable: url, arguments: ["--version"],
                                                     timeout: CLIUpdatePlan.versionTimeout, asAgent: true))
        return result.succeeded ? CLIVersion.parse(result.stdout + "\n" + result.stderr) : nil
    }

    private static func stamp(of url: URL) -> (String, Stamp)? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return (path, Stamp(size: size, modified: modified.timeIntervalSince1970, fileNumber: fileNumber))
    }
}
