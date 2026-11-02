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
/// read any file on the Mac. A path is served only when it names a regular file that is one of the task's outputs or,
/// with every symbolic link resolved, lies inside one of the task's folders (whole path components, compared byte for
/// byte). An output is matched by its folder with links resolved and its own name, never through a link in its place.
/// Nothing a request names is looked up before its path, by its text alone, is one of those files or under one of
/// those folders, so a request elsewhere learns nothing, raises no privacy prompt and waits on no network folder. A
/// folder that is the person's home folder or holds it (`/`, `/Users`, in any form) gives no files of its own: a task
/// there serves only its outputs. Whatever is refused answers `notFound`, as a file that is not there does, and no
/// answer or log line carries a path. Reading blocks: callers run it with `perform`, off their actor.
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

    /// One serial queue for file work, apart from Swift's cooperative threads: a read that hangs on a network folder
    /// holds up only the reads behind it.
    private static let queue = DispatchQueue(label: "yardlet.remote.files", qos: .userInitiated)

    /// Runs blocking file work on the reader's queue.
    public static func perform<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

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
        let requested = lexical(path.hasPrefix("/") ? path : folder + "/" + path)
        // The task's folders, each as written and with its links resolved.
        let realHome = realPath(home) ?? lexical(home)
        var written: [String] = []
        var roots: [String] = []
        for root in [scope.folder] + scope.otherFolders {
            let raw = lexical(root.path(percentEncoded: false))
            guard let real = realPath(raw), !holdsHome(real, home: realHome) else { continue }
            written.append(raw)
            roots.append(real)
        }
        // Each output as written and as placed: its folder's links resolved, its own name kept.
        var named: Set<[UInt8]> = []
        var placedOutputs: Set<[UInt8]> = []
        for output in scope.outputs {
            let raw = lexical(output.path(percentEncoded: false))
            named.insert(Array(raw.utf8))
            if let placed = placed(raw) {
                named.insert(Array(placed.utf8))
                placedOutputs.insert(Array(placed.utf8))
            }
        }
        let isOutput = named.contains(Array(requested.utf8))
        let isUnderRoot = (written + roots).contains { isInside(requested, $0) }
        guard isOutput || isUnderRoot else { return .failure(refused()) }
        var candidates: [String] = []
        if isOutput, let placed = placed(requested), placedOutputs.contains(Array(placed.utf8)) { candidates.append(placed) }
        if isUnderRoot, let real = realPath(requested), roots.contains(where: { isInside(real, $0) }) { candidates.append(real) }
        // Only a regular file is opened: a link, a FIFO, a device or a socket is never touched.
        guard let target = candidates.first(where: { candidate in
            var info = stat()
            return lstat(candidate, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }) else { return .failure(refused()) }
        return serve(target, from: offset)
        #else
        return .failure(RemoteError(.unavailable))
        #endif
    }

    #if canImport(Darwin)
    /// `target` holds no link but in its folders, which are resolved, so a link put into any part of it since is
    /// refused (O_NOFOLLOW_ANY), and the descriptor is checked again: what is read is what was checked.
    private static func serve(_ target: String, from offset: Int) -> Result<RemoteFilePart, RemoteError> {
        let descriptor = open(target, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(refused()) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(refused()) }
        let size = Int(info.st_size)
        guard size <= RemoteProtocol.maxReadFileBytes else { return .failure(RemoteError(.tooLarge, "A file is at most 100 MiB")) }
        guard offset <= size else { return .failure(RemoteError(.badRequest, "The offset is past the end of the file")) }
        guard let data = read(descriptor, from: offset, count: min(RemoteProtocol.maxReadPartBytes, size - offset)) else {
            return .failure(RemoteError(.internal, "The file could not be read"))
        }
        let name = (target as NSString).lastPathComponent
        let modified = info.st_mtimespec
        return .success(RemoteFilePart(
            path: target, name: name, mediaType: mediaType(name: name, descriptor: descriptor), size: size,
            offset: offset, data: data,
            modifiedAt: Int64(modified.tv_sec) * 1_000 + Int64(modified.tv_nsec) / 1_000_000))
    }
    #endif

    /// The outputs with the size of each that is a regular file now; a file that is gone has none.
    public static func sized(_ outputs: [RemoteOutput]) -> [RemoteOutput] {
        #if canImport(Darwin)
        outputs.map { output in
            var sized = output
            var info = stat()
            // As `read` serves them: a link in an output's place is not followed.
            sized.size = lstat(output.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG ? Int(info.st_size) : nil
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

    /// `path` is `root` or lies under it, by whole path components (`/a/bc` is not under `/a/b`), compared byte for byte:
    /// two spellings of a name that Swift's strings call equal (NFC and NFD) are two names here.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let slash = UInt8(ascii: "/")
        let path = Array(path.utf8)
        var root = Array(root.utf8)
        while root.count > 1, root.last == slash { root.removeLast() }
        if root == [slash] { return path.first == slash }
        guard path.starts(with: root) else { return false }
        return path.count == root.count || path[root.count] == slash
    }

    /// An absolute path with `.`, `..` and repeated slashes taken out by its text alone, nothing looked up.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    #if canImport(Darwin)
    /// The path with its folder's links resolved and its own name kept, so a link in the file's place is not followed;
    /// nil when its folder is not there.
    static func placed(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let name = path[path.index(after: slash)...]
        guard !name.isEmpty, let folder = realPath(slash == path.startIndex ? "/" : String(path[..<slash])) else { return nil }
        return (folder == "/" ? "" : folder) + "/" + name
    }

    /// The folder is the home folder or holds it: by its path, in the form `realpath` gives and the form the data
    /// volume gives (`/System/Volumes/Data/Users/…`, a firmlink `realpath` keeps), or as the same folder on disk as the
    /// home folder or one above it.
    static func holdsHome(_ folder: String, home: String) -> Bool {
        if [home, "/System/Volumes/Data" + home].contains(where: { isInside($0, folder) }) { return true }
        guard let id = FileID(folder) else { return false }
        var path = home
        while true {
            if FileID(path) == id { return true }
            guard path != "/" else { return false }
            path = lexical(path + "/..")
        }
    }

    /// A folder or file on disk, whatever path names it.
    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

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
