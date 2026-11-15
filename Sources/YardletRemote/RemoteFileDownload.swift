import Foundation

/// A client reading one of a task's files down in parts (docs/REMOTE_PROTOCOL.md §15.22): the phone's file viewer.
/// Each part is asked for from where the last one ended, until the file's size, and written as it comes into a file
/// named as the host names it, in a folder of the caller's. When the size or the modification time changes between
/// parts, the file changed on the host, so it starts over, a few times at most. `rateLimited` (the host's read budget)
/// is waited out a second at a time, and so is a connection that drops after the first part, for as long as
/// `reconnected` waits. Whatever did not finish is deleted with the folder, also when the task is cancelled.
public enum RemoteFileDownload {
    public enum Failure: Error, Equatable, Sendable {
        /// The host refused it (its error): for a file it does not serve, or one not there, `notFound` (§15.22). Nil for
        /// an answer that does not carry the file forward.
        case refused(RemoteError?)
        /// Over `RemoteProtocol.maxReadFileBytes`.
        case tooLarge
        /// The file kept changing on the host while it was read.
        case changing
        /// No connection, before the first part or for longer than `reconnected` waited.
        case notConnected
        /// It could not be written here (no room left).
        case unwritable
        /// The task reading it was cancelled.
        case cancelled
    }

    /// The file read whole.
    public struct File: Equatable, Sendable {
        /// Where it was written.
        public var url: URL
        /// The absolute path the host read, and the file's name, type, size and modification time there.
        public var path: String
        public var name: String
        public var mediaType: String
        public var size: Int
        public var modifiedAt: Int64?
    }

    /// How far it came: `received` of `size` bytes of the file the host names `name`.
    public struct Progress: Equatable, Sendable {
        public var name: String
        public var received: Int
        public var size: Int
    }

    /// Restarts after a change, waits for the host's budget and dropped connections, before giving up.
    static let maxRestarts = 3
    static let maxRateLimitedWaits = 20
    static let maxDrops = 3

    /// Reads the file `read` answers parts of (`readFile` at the offset it is given) into `folder`, which it creates
    /// and, unless the file is read whole, removes.
    @concurrent
    public static func read(into folder: URL, pause: Duration = .seconds(1),
                            through read: @Sendable (_ offset: Int) async -> RemoteResponse,
                            reconnected: @Sendable () async -> Bool,
                            progress: @Sendable (Progress) async -> Void = { _ in }) async -> Result<File, Failure> {
        var handle: FileHandle?
        var target: URL?
        var done = false
        defer {
            try? handle?.close()
            if !done { try? FileManager.default.removeItem(at: folder) }
        }
        // The first part of the version of the file being read.
        var first: RemoteResponse?
        var offset = 0
        var restarts = 0
        var waits = 0
        var drops = 0
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            let part = await read(offset)
            if Task.isCancelled { return .failure(.cancelled) }
            guard part.ok else {
                switch part.error?.code {
                case .unavailable?:
                    drops += 1
                    guard first != nil, drops <= maxDrops, await reconnected() else { return .failure(.notConnected) }
                case .rateLimited? where waits < maxRateLimitedWaits:
                    waits += 1
                    try? await Task.sleep(for: pause)
                case .tooLarge?:
                    return .failure(.tooLarge)
                default:
                    return .failure(.refused(part.error))
                }
                continue
            }
            waits = 0
            guard let size = part.size, let data = part.data, part.offset == offset, offset + data.count <= size else {
                return .failure(.refused(nil))
            }
            guard size <= RemoteProtocol.maxReadFileBytes else { return .failure(.tooLarge) }
            if let base = first, size != base.size || part.modifiedAt != base.modifiedAt {
                restarts += 1
                guard restarts <= maxRestarts else { return .failure(.changing) }
                first = nil
                offset = 0
                do { try handle?.truncate(atOffset: 0) } catch { return .failure(.unwritable) }
                continue
            }
            if first == nil { first = part }
            if handle == nil {
                let url = folder.appending(path: safeName(part.name ?? ""))
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
                        return .failure(.unwritable)
                    }
                    handle = try FileHandle(forWritingTo: url)
                } catch {
                    return .failure(.unwritable)
                }
                target = url
            }
            do {
                try handle?.seek(toOffset: UInt64(offset))
                try handle?.write(contentsOf: data)
            } catch {
                return .failure(.unwritable)
            }
            offset += data.count
            await progress(Progress(name: first?.name ?? "", received: offset, size: size))
            if offset >= size { break }
            // A part with no bytes before the end would ask for the same part forever.
            if data.isEmpty { return .failure(.refused(nil)) }
        }
        guard let first, let target else { return .failure(.refused(nil)) }
        done = true
        return .success(File(url: target, path: first.path ?? "", name: first.name ?? target.lastPathComponent,
                             mediaType: first.mediaType ?? "application/octet-stream", size: first.size ?? offset,
                             modifiedAt: first.modifiedAt))
    }

    /// The host's name for a file as a name here: no folder separators or control characters, at most 200 bytes, its
    /// extension kept.
    public static func safeName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { $0 != "/" && $0 != "\\" && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "file" }
        guard cleaned.utf8.count > maxNameBytes else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.count <= 16 ? "." + ext : ""
        var stem = ""
        for character in cleaned.dropLast(suffix.count) {
            guard stem.utf8.count + String(character).utf8.count + suffix.utf8.count <= maxNameBytes else { break }
            stem.append(character)
        }
        let trimmed = stem.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? "file" : trimmed) + suffix
    }

    static let maxNameBytes = 200
}
