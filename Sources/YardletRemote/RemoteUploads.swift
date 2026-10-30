import Foundation

/// Files a phone sends in parts (docs/REMOTE_PROTOCOL.md §15.20), each in a folder of its own under the Mac's
/// temporary folder, never a task's folder: the parts land in a hidden file that becomes the named file once the
/// last one arrives, readable by the person only and never executable. A message takes finished files by their
/// upload IDs and marks their folders taken; an unfinished or untaken upload is removed 30 minutes after its last
/// part, and one an earlier run left untaken when this one starts.
struct RemoteUploadStore {
    struct Upload {
        let deviceID: String
        let name: String
        let mediaType: String?
        let size: Int
        var received: Int
        var lastPartAt: Date
        let folder: URL

        var isFinished: Bool { received == size }
        var file: URL { folder.appending(path: name) }
        var partial: URL { folder.appending(path: ".part") }
        var taken: URL { folder.appending(path: ".taken") }
    }

    static let idleLimit: TimeInterval = 30 * 60
    static let openPerDevice = 4
    /// The disk an upload must leave free.
    static let diskFloor: Int64 = 2_000_000_000

    let directory: URL
    private(set) var uploads: [String: Upload] = [:]
    /// The free space on the directory's volume; tests set their own.
    var freeSpace: (URL) -> Int64? = { url in
        #if canImport(Darwin)
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #else
        ((try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? NSNumber)?.int64Value
        #endif
    }

    /// What an earlier run left that no message took is removed; files a message took stay for their tasks.
    init(directory: URL) {
        self.directory = directory
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !FileManager.default.fileExists(atPath: folder.appending(path: ".taken").path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Yardlet Phone Files", directoryHint: .isDirectory)
    }

    /// Takes a part and returns how many bytes the Mac holds. A part at another offset adds nothing, so a phone
    /// that lost its connection sends again from what this answers.
    mutating func receive(_ part: RemoteUploadPart, from deviceID: String, now: Date) -> Result<Int, RemoteError> {
        guard part.data.count <= RemoteProtocol.maxUploadPartBytes else {
            return .failure(RemoteError(.tooLarge, "A part holds at most 4 MiB"))
        }
        if var upload = uploads[part.uploadID] {
            guard upload.deviceID == deviceID else { return .failure(RemoteError(.notFound)) }
            upload.lastPartAt = now
            defer { uploads[part.uploadID] = upload }
            guard part.offset == upload.received, !upload.isFinished else { return .success(upload.received) }
            guard upload.received + part.data.count <= upload.size else {
                return .failure(RemoteError(.badRequest, "The part runs past the file's size"))
            }
            do {
                try append(part.data, to: upload.partial)
                upload.received += part.data.count
                if upload.isFinished { try finish(upload) }
            } catch {
                // What was written cannot be trusted any more: the phone starts the file again.
                drop(part.uploadID)
                return .failure(RemoteError(.internal, "The file could not be written"))
            }
            return .success(upload.received)
        }
        guard part.offset == 0 else { return .failure(RemoteError(.notFound, "No such upload, or it expired")) }
        guard let size = part.size, size >= 0, let name = part.name else {
            return .failure(RemoteError(.badRequest, "The first part names the file and its size"))
        }
        guard size <= RemoteProtocol.maxFileBytes else { return .failure(RemoteError(.tooLarge, "A file is at most 500 MiB")) }
        guard part.data.count <= size else { return .failure(RemoteError(.badRequest, "The part runs past the file's size")) }
        guard uploads.values.filter({ $0.deviceID == deviceID && !$0.isFinished }).count < Self.openPerDevice else {
            return .failure(RemoteError(.busy, "At most four uploads at once"))
        }
        let folder = directory.appending(path: part.uploadID, directoryHint: .isDirectory)
        // An ID once used names a folder another message may still read: never reuse or remove it.
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            return .failure(RemoteError(.badRequest, "That upload ID was used already"))
        }
        let upload = Upload(deviceID: deviceID, name: Self.safeName(name), mediaType: part.mediaType, size: size,
                            received: part.data.count, lastPartAt: now, folder: folder)
        let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: owner)
        } catch {
            return .failure(RemoteError(.internal, "The folder for files could not be made"))
        }
        let held = uploads.values.reduce(Int64(0)) { $0 + Int64($1.size - $1.received) }
        guard (freeSpace(directory) ?? .max) - held - Int64(size) >= Self.diskFloor else {
            return .failure(RemoteError(.tooLarge, "The Mac's disk would keep less than 2 GB free"))
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        } catch {
            return .failure(RemoteError(.internal, "The file could not be written"))
        }
        do {
            guard FileManager.default.createFile(atPath: upload.partial.path(percentEncoded: false), contents: part.data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if upload.isFinished { try finish(upload) }
        } catch {
            // Only the folder this part made goes.
            try? FileManager.default.removeItem(at: folder)
            return .failure(RemoteError(.internal, "The file could not be written"))
        }
        uploads[part.uploadID] = upload
        return .success(upload.received)
    }

    /// The finished files the device sent under these IDs, in that order, or why one cannot be taken.
    func files(_ ids: [String], from deviceID: String) -> Result<[RemoteFile], RemoteError> {
        guard ids.count <= RemoteProtocol.maxFiles else { return .failure(RemoteError(.tooLarge, "At most 20 files")) }
        var files: [RemoteFile] = []
        for id in ids {
            guard let upload = uploads[id.uppercased()], upload.deviceID == deviceID, upload.isFinished else {
                return .failure(RemoteError(.notFound, "An upload is not finished or has expired"))
            }
            files.append(RemoteFile(url: upload.file, name: upload.name, mediaType: upload.mediaType))
        }
        return .success(files)
    }

    /// A message took these files: they stay on disk for the task to read, marked taken, and the store lets them go.
    mutating func release(_ ids: [String]) {
        for id in ids {
            guard let upload = uploads.removeValue(forKey: id.uppercased()) else { continue }
            FileManager.default.createFile(atPath: upload.taken.path(percentEncoded: false), contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    private mutating func drop(_ id: String) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: upload.folder)
    }

    /// Removes uploads idle for 30 minutes, finished or not, with their folders.
    mutating func sweep(now: Date) {
        for (id, upload) in uploads where now.timeIntervalSince(upload.lastPartAt) >= Self.idleLimit { drop(id) }
    }

    /// The file's own name without any path, control characters or leading dots, at most 120 characters and 200
    /// bytes (a file system name holds 255) with its extension kept; "file" when nothing is left.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        })).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return "file" }
        guard cleaned.count > 120 || cleaned.utf8.count > 200 else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let keep = ext.isEmpty || ext.count > 16 ? "" : "." + ext
        var stem = String(cleaned.dropLast(keep.count).prefix(120 - keep.count))
        while stem.utf8.count + keep.utf8.count > 200 { stem.removeLast() }
        return stem.isEmpty ? "file" + keep : stem + keep
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func finish(_ upload: Upload) throws {
        try FileManager.default.moveItem(at: upload.partial, to: upload.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: upload.file.path(percentEncoded: false))
    }
}
