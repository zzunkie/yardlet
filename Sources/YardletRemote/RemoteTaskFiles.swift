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

/// Where `writeFile` writes (§15.27): a regular file below the task's working folder, by names that hold no link.
public struct RemoteFileWriteTarget: Equatable, Sendable {
    /// The task's working folder, with its links resolved.
    public var folder: URL
    /// The file below it, its names joined with `/`, as `index` lists it.
    public var path: String
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

    /// The rules a request's path is judged by: this platform's, with POSIX names compared byte for byte, since two
    /// spellings Swift's strings call one name can be two folders on disk (`PathRules.comparesBytes`).
    static let rules = PathRules.current.comparingBytes

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
        // A conversation writes the home folder as `~`; anything else not absolute is read from the task's folder.
        let absolute = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst()
            : path.hasPrefix("/") ? path : folder + "/" + path
        let requested = lexical(absolute)
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
        let (named, placedOutputs) = outputNames(scope.outputs)
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

    /// Whether a browser tab may show the page at `path`, a `file:` address's path, to a phone (§15.25): what `read` would
    /// serve, or a folder inside one of the task's folders (a folder's listing), with every link resolved. Anything else,
    /// and anything not there, is not shown.
    public static func allowsPage(_ path: String, in scope: RemoteFileScope, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maxPathBytes, !path.utf8.contains(0) else { return false }
        #if canImport(Darwin)
        let requested = lexical(path)
        let realHome = realPath(home) ?? lexical(home)
        var written: [String] = []
        var roots: [String] = []
        for root in [scope.folder] + scope.otherFolders {
            let raw = lexical(root.path(percentEncoded: false))
            guard let real = realPath(raw), !holdsHome(real, home: realHome) else { continue }
            written.append(raw)
            roots.append(real)
        }
        // As `read`: nothing is looked up before the path, by its text, is under one of the folders or is an output.
        if (written + roots).contains(where: { isInside(requested, $0) }),
           let real = realPath(requested), roots.contains(where: { isInside(real, $0) }) { return true }
        guard outputNames(scope.outputs).named.contains(Array(requested.utf8)) else { return false }
        if case .success = read(requested, offset: max(0, (fileSize(requested) ?? 1) - 1), in: scope, home: home) { return true }
        return false
        #else
        return false
        #endif
    }

    /// `path`, absolute or relative to `folder`, as a path inside `folder` with every link resolved; nil when it lies
    /// anywhere else. This is `read`'s boundary for what names a task's file to a phone, previews it, or writes it back
    /// at a phone's word (§15.31). A file that is not there is judged by where it would land, through the links in the
    /// folders above it, since writing it back would follow them. A `..` is refused: what it leads to depends on who
    /// reads the path, the kernel through a link or a provider by its text. A folder that is the home folder or holds
    /// it gives nothing.
    public static func relativePath(_ path: String, in folder: URL, home: String = NSHomeDirectory()) -> String? {
        guard !path.isEmpty, path.utf8.count <= maxPathBytes, !path.utf8.contains(0),
              rules.isAbsolute(path) || rules.isRelative(path), !rules.names(path).contains("..") else { return nil }
        #if canImport(Darwin)
        let written = lexical(folder.path(percentEncoded: false))
        guard let root = realPath(written), !holdsHome(root, home: realPath(home) ?? lexical(home)),
              let resolved = landing(path.hasPrefix("/") ? path : written + "/" + path) else { return nil }
        #else
        // No `realpath` here, and no reads of a task's files either: Foundation's own resolving, by these rules.
        func resolving(_ url: URL) -> String { rules.path(of: url.resolvingSymlinksInPath().standardizedFileURL) }
        let root = resolving(folder)
        let resolved = resolving(rules.url(for: path, in: folder))
        guard !rules.isInside(resolving(URL(filePath: home)), folder: root) else { return nil }
        #endif
        guard let relative = rules.relativePath(of: resolved, in: root), !relative.isEmpty else { return nil }
        return relative
    }

    /// `path` as `writeTarget` takes it, by its text alone under `rules`: the names below `folder` joined with `/`, as
    /// `index` lists them. Nil for a path that is absolute, starts at the home folder (`~`), climbs (`..`), names
    /// nothing (`.`, an empty name) or names what Windows reads as another name, and for every path when `folder` is
    /// the home folder or holds it. Nothing is looked up.
    static func writePath(_ path: String, in folder: String, home: String,
                          rules: PathRules = RemoteFileReader.rules) -> String? {
        guard !path.isEmpty, path.utf8.count <= maxPathBytes, !path.utf8.contains(0), rules.isRelative(path),
              !rules.isInside(home, folder: folder) else { return nil }
        let names = rules.names(path)
        guard names.first != "~", !names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let joined = names.joined(separator: "/")
        guard let relative = rules.relativePath(of: folder + "/" + joined, in: folder), !relative.isEmpty else { return nil }
        return relative
    }

    /// Where a device's `writeFile` may write (§15.27): `path`, relative to the task's working folder as `index` lists
    /// it, below that folder with its links resolved. Only the folder `workspaceFiles` lists counts, not the task's
    /// other folders or its outputs, as the Mac's Files panel saves only in the task's folder. The file must be a
    /// regular file there already, at most `maxWriteFileBytes`, with no symbolic link below the folder on the way to it
    /// or in its own place; nothing is created. Anything else, and every file of a folder that is the home folder or
    /// holds it, is refused (`notAllowed`) the same whether or not it exists, by `writePath` before anything is looked
    /// up. The writer goes down from the folder through no-follow descriptors (`WorkspaceFileReplacement`), so a link put
    /// in place since this check is refused there. Blocks: callers run it with `perform`.
    public static func writeTarget(_ path: String, in scope: RemoteFileScope,
                                   home: String = NSHomeDirectory()) -> Result<RemoteFileWriteTarget, RemoteError> {
        guard !path.isEmpty, path.utf8.count <= maxPathBytes, !path.utf8.contains(0) else {
            return .failure(RemoteError(.badRequest, "Unreadable path"))
        }
        #if canImport(Darwin)
        let refused = RemoteError(.notAllowed, "Not a file of the task's folder that can be written")
        let written = scope.folder.path(percentEncoded: false)
        let realHome = realPath(home) ?? lexical(home)
        guard written.hasPrefix("/"), let folder = realPath(lexical(written)), !holdsHome(folder, home: realHome),
              let relative = writePath(path, in: folder, home: realHome) else { return .failure(refused) }
        let target = (folder == "/" ? "" : folder) + "/" + relative
        var info = stat()
        // The resolved path is the path itself, byte for byte: no link below the folder, the file's own place included.
        guard let real = realPath(target), real.utf8.elementsEqual(target.utf8),
              lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(refused) }
        guard info.st_size <= RemoteProtocol.maxWriteFileBytes else {
            return .failure(RemoteError(.tooLarge, "A file written is at most 4 MiB"))
        }
        return .success(RemoteFileWriteTarget(folder: URL(filePath: folder, directoryHint: .isDirectory), path: relative))
        #else
        return .failure(RemoteError(.unavailable))
        #endif
    }

    #if canImport(Darwin)
    /// Each output as written and as placed: its folder's links resolved, its own name kept. `placed` holds the second.
    private static func outputNames(_ outputs: [URL]) -> (named: Set<[UInt8]>, placed: Set<[UInt8]>) {
        var named: Set<[UInt8]> = []
        var placedOutputs: Set<[UInt8]> = []
        for output in outputs {
            let raw = lexical(output.path(percentEncoded: false))
            named.insert(Array(raw.utf8))
            if let placed = placed(raw) {
                named.insert(Array(placed.utf8))
                placedOutputs.insert(Array(placed.utf8))
            }
        }
        return (named, placedOutputs)
    }

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

    /// `path` is `root` or lies under it, by whole path components (`/a/bc` is not under `/a/b`), under `rules`: on
    /// POSIX compared byte for byte, so two spellings of a name that Swift's strings call equal (NFC and NFD) are two
    /// names here, and on Windows as NTFS compares them.
    static func isInside(_ path: String, _ root: String) -> Bool {
        rules.isInside(path, folder: root)
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

    /// Where a path without `..` leads: the deepest part of it that exists with every link resolved, then the names
    /// below that, which no link can change yet. Nil when what is there leads nowhere, as a link to nothing does.
    private static func landing(_ path: String) -> String? {
        var existing = lexical(path)
        var missing: [String] = []
        while true {
            var info = stat()
            if lstat(existing, &info) == 0 {
                guard let real = realPath(existing) else { return nil }
                return lexical(([real] + missing.reversed()).joined(separator: "/"))
            }
            guard errno == ENOENT, let slash = existing.lastIndex(of: "/"), existing != "/" else { return nil }
            missing.append(String(existing[existing.index(after: slash)...]))
            existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
        }
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

    /// The size of the regular file at `path`, not following a link in its place.
    private static func fileSize(_ path: String) -> Int? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(info.st_size)
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
