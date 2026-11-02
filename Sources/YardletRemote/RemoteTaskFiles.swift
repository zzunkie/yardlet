import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What a phone may open of a task's files (docs/REMOTE_PROTOCOL.md §15.22): the files in the task's own folders and
/// the files its Outputs card lists, wherever those are. The bridge says what they are; `RemoteFileReader` decides.
public struct RemoteFileScope: Equatable, Sendable {
    /// The task's working folder or worktree. A relative path is read from here.
    public var folder: URL
    /// The project's other folders the task was given.
    public var otherFolders: [URL]
    /// The files of the task's Outputs card (`taskOutputs`).
    public var outputs: [URL]

    public init(folder: URL, otherFolders: [URL] = [], outputs: [URL] = []) {
        self.folder = folder
        self.otherFolders = otherFolders
        self.outputs = outputs
    }
}

/// One part of a file `readFile` serves (§15.22).
public struct RemoteFilePart: Equatable, Sendable {
    /// The absolute path the Mac read, with symbolic links resolved.
    public var path: String
    public var name: String
    public var mediaType: String
    public var size: Int
    public var offset: Int
    public var data: Data
    public var modifiedAt: Int64

    public init(path: String, name: String, mediaType: String, size: Int, offset: Int, data: Data, modifiedAt: Int64) {
        self.path = path
        self.name = name
        self.mediaType = mediaType
        self.size = size
        self.offset = offset
        self.data = data
        self.modifiedAt = modifiedAt
    }
}

/// Reads a part of a task's file for a phone (§15.22). A paired phone steers tasks, but this must not become a way to
/// read any file on the Mac, so a path is served only when, with every symbolic link resolved, it names a regular file
/// inside one of the task's folders (whole path components, not a prefix of a name) or is one of its outputs. A folder
/// that is the person's home folder or holds it (`/`, `/Users`) gives no files of its own: a task there serves only
/// its outputs. Whatever is refused answers `notFound`, as a file that is not there does, and no answer or log line
/// carries a path. Reading blocks, so callers run it off their actor.
public enum RemoteFileReader {
    /// This platform reads files for phones; elsewhere a snapshot does not offer it.
    public static var isSupported: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }

    /// The longest path a request may name, in bytes (the Mac's own `PATH_MAX` is shorter).
    static let maxPathBytes = 4_096

    static func refused() -> RemoteError { RemoteError(.notFound, "No such file, or not one of the task's files") }

    /// Up to `maxReadPartBytes` of the file at `path` from `offset`. `home` is the person's home folder (tests give
    /// their own).
    public static func read(_ path: String, offset: Int, in scope: RemoteFileScope,
                            home: String = NSHomeDirectory()) -> Result<RemoteFilePart, RemoteError> {
        guard offset >= 0, !path.isEmpty, path.utf8.count <= maxPathBytes, !path.utf8.contains(0) else {
            return .failure(RemoteError(.badRequest, "Unreadable path or offset"))
        }
        #if canImport(Darwin)
        let folder = scope.folder.path(percentEncoded: false)
        guard folder.hasPrefix("/") else { return .failure(refused()) }
        let requested = path.hasPrefix("/") ? path : (folder.hasSuffix("/") ? folder : folder + "/") + path
        // The kernel resolves every link and `..` here, as the open below would.
        guard let resolved = realPath(requested) else { return .failure(refused()) }
        let realHome = realPath(home) ?? home
        let roots = ([scope.folder] + scope.otherFolders)
            .compactMap { realPath($0.path(percentEncoded: false)) }
            .filter { !isInside(realHome, $0) }
        let outputs = Set(scope.outputs.compactMap { realPath($0.path(percentEncoded: false)) })
        guard outputs.contains(resolved) || roots.contains(where: { isInside(resolved, $0) }) else {
            return .failure(refused())
        }
        // Only a regular file is opened: a FIFO, a device or a socket is never touched.
        var info = stat()
        guard lstat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(refused()) }
        // `resolved` holds no link, so a link put into any part of it since is refused (O_NOFOLLOW_ANY), and the
        // descriptor is checked again: what is read is what was checked.
        let descriptor = open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(refused()) }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(refused()) }
        let size = Int(info.st_size)
        guard size <= RemoteProtocol.maxReadFileBytes else { return .failure(RemoteError(.tooLarge, "A file is at most 100 MiB")) }
        guard offset <= size else { return .failure(RemoteError(.badRequest, "The offset is past the end of the file")) }
        guard let data = read(descriptor, from: offset, count: min(RemoteProtocol.maxReadPartBytes, size - offset)) else {
            return .failure(RemoteError(.internal, "The file could not be read"))
        }
        let name = (resolved as NSString).lastPathComponent
        let modified = info.st_mtimespec
        return .success(RemoteFilePart(
            path: resolved, name: name, mediaType: mediaType(name: name, descriptor: descriptor), size: size,
            offset: offset, data: data,
            modifiedAt: Int64(modified.tv_sec) * 1_000 + Int64(modified.tv_nsec) / 1_000_000))
        #else
        return .failure(RemoteError(.unavailable))
        #endif
    }

    /// The outputs with the size of each that is a regular file now; a file that is gone has none.
    public static func sized(_ outputs: [RemoteOutput]) -> [RemoteOutput] {
        #if canImport(Darwin)
        outputs.map { output in
            var sized = output
            var info = stat()
            sized.size = stat(output.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG ? Int(info.st_size) : nil
            return sized
        }
        #else
        outputs
        #endif
    }

    /// What the audit log keeps of a path a phone asked for: its last part, never the folders above it.
    static func auditName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        return String(cleaned.prefix(120))
    }

    /// `path` is `root` or lies under it, by whole path components (`/a/bc` is not under `/a/b`).
    static func isInside(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    #if canImport(Darwin)
    /// The path with every symbolic link, `.` and `..` resolved by the kernel; nil when something on the way is not
    /// there or not readable.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Up to `count` bytes from `offset`, fewer when the file ends first.
    private static func read(_ descriptor: Int32, from offset: Int, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < count {
                let got = pread(descriptor, base + total, count - total, off_t(offset + total))
                if got > 0 {
                    total += got
                } else if got == 0 {
                    break
                } else if errno != EINTR {
                    return -1
                }
            }
            return total
        }
        guard read >= 0 else { return nil }
        data.count = read
        return data
    }

    /// The file's type from its extension, else text when its beginning reads as UTF-8 text.
    private static func mediaType(name: String, descriptor: Int32) -> String {
        if let known = mediaTypes[(name as NSString).pathExtension.lowercased()] { return known }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count >= 0 else { return "application/octet-stream" }
        let start = bytes.prefix(count)
        guard !start.contains(0) else { return "application/octet-stream" }
        // A character the 512 bytes cut in two is still text.
        let isText = (0...min(3, start.count)).contains { String(bytes: start.dropLast($0), encoding: .utf8) != nil }
        return isText ? "text/plain" : "application/octet-stream"
    }
    #endif

    /// The documents and media the Outputs card lists, and a few other common types.
    static let mediaTypes: [String: String] = [
        "pdf": "application/pdf",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "heif": "image/heif", "svg": "image/svg+xml", "bmp": "image/bmp", "tif": "image/tiff",
        "tiff": "image/tiff",
        "txt": "text/plain", "log": "text/plain", "md": "text/markdown", "markdown": "text/markdown", "csv": "text/csv",
        "tsv": "text/tab-separated-values", "html": "text/html", "htm": "text/html", "json": "application/json",
        "xml": "application/xml", "rtf": "application/rtf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "key": "application/vnd.apple.keynote", "pages": "application/vnd.apple.pages",
        "numbers": "application/vnd.apple.numbers",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "aac": "audio/aac",
        "zip": "application/zip"
    ]
}
