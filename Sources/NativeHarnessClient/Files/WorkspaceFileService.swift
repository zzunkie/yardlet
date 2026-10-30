import Foundation

struct WorkspaceFileLocation: Equatable, Sendable {
    /// Relative to the task's folder; for a file elsewhere that the person opened (`opening`), its
    /// absolute path.
    let relativePath: String
    var line: Int?
    var column: Int?

    /// A file outside the task's folder, which the panel shows read-only.
    var isOutsideWorkspace: Bool { relativePath.hasPrefix("/") }

    static func url(for path: String, in workspace: URL) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : workspace.appending(path: path)
    }

    /// A file inside the task's folder; anything else throws.
    static func resolve(_ url: URL, in workspace: URL) throws -> Self {
        let (path, line, column) = try target(of: url, in: workspace)
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix), file.count > prefix.count else { throw WorkspaceFileError.outsideWorkspace }
        return Self(relativePath: String(file.dropFirst(prefix.count)), line: line, column: column)
    }

    /// A file the person opens from a link, as the Codex and Claude apps open any file on the Mac:
    /// inside the task's folder as `resolve` reads it, and elsewhere by its absolute path. Only the
    /// person sees it; nothing reaches the agent, and the panel saves only files inside the folder.
    static func opening(_ url: URL, in workspace: URL) throws -> Self {
        if let inside = try? resolve(url, in: workspace) { return inside }
        let (path, line, column) = try target(of: url, in: workspace)
        return Self(relativePath: URL(filePath: path).standardizedFileURL.path(percentEncoded: false),
                    line: line, column: column)
    }

    /// The folder a link names, when one is there.
    static func folder(_ url: URL, in workspace: URL) -> URL? {
        guard let path = try? target(of: url, in: workspace).path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }

    /// The absolute path a local file link names, and the line and column it points at.
    private static func target(of url: URL, in workspace: URL) throws -> (path: String, line: Int?, column: Int?) {
        let directory = URL(filePath: workspace.path(percentEncoded: false), directoryHint: .isDirectory)
        guard let target = url.scheme == nil ? URL(string: url.relativeString, relativeTo: directory)?.absoluteURL : url else {
            throw WorkspaceFileError.outsideWorkspace
        }
        guard target.isFileURL, target.host == nil || target.host == "" || target.host == "localhost" else {
            throw WorkspaceFileError.outsideWorkspace
        }
        var path = target.path(percentEncoded: false)
        var line: Int?, column: Int?
        if let fragment = target.fragment,
           let match = fragment.firstMatch(of: /^L?([0-9]+)(?:C([0-9]+))?(?:-L?[0-9]+)?$/) {
            line = Int(match.1)
            column = match.2.flatMap { Int($0) }
        }
        // Preserve real filenames containing colons. Interpret a line suffix only when the
        // full path is not a file, as used by Markdown links to /path/file.swift:42:5.
        if !FileManager.default.fileExists(atPath: path),
           let match = path.firstMatch(of: /:([0-9]+)(?::([0-9]+))?$/) {
            line = line ?? Int(match.1)
            column = column ?? match.2.flatMap { Int($0) }
            path.removeSubrange(match.range)
        }
        return (path, line.map { max(1, $0) }, column.map { max(1, $0) })
    }
}

/// A file that is not text which the panel shows as the Codex and Claude apps show one: an image
/// or a PDF.
struct WorkspaceFileMedia: Equatable, Sendable {
    enum Kind: Sendable { case image, pdf }
    let url: URL
    let kind: Kind

    init?(_ url: URL) {
        guard let kind = FileTypes.mediaKind(forExtension: url.pathExtension) else { return nil }
        self.kind = kind
        self.url = url
    }
}

enum WorkspaceFileError: LocalizedError {
    case outsideWorkspace, tooLarge, unsupported, notAFile, changedOnDisk, notWritable
    var errorDescription: String? {
        switch self {
        case .outsideWorkspace: L10n.string("Path is outside the task workspace")
        case .tooLarge: L10n.string("File is too large to preview")
        case .unsupported: L10n.string("Preview unavailable for this file")
        case .notAFile: L10n.string("File unavailable")
        case .changedOnDisk: L10n.string("This file changed on disk. Your edits are preserved.")
        case .notWritable: L10n.string("This file cannot be saved.")
        }
    }
}

struct WorkspaceFileDocument: Sendable {
    /// When the syntax colors of a new text are worked out.
    enum Highlight: Sendable {
        /// Now, with the text: a read or a draft, off the main thread.
        case now
        /// After the person stops typing, off the main thread. Until then the reader keeps the
        /// colors it shows, `keeping` the ID of the colors it drew.
        case later(keeping: UUID)
    }

    let id: UUID
    /// A new value for every text: a read, an edit or a save.
    let revision: UUID
    let path: String
    let text: String
    let utf16Length: Int
    let lineStarts: [Int]
    /// Syntax colors: none past `WorkspaceFileService.highlightedBytes` or while the colors of an
    /// edit are worked out.
    private(set) var tokens: [TranscriptCodeSyntax.Token]
    /// Changes when the colors are worked out again; the reader colors the text again only then.
    private(set) var highlightID: UUID
    let sourceDigest: String?
    let encoding: WorkspaceFileEncoding
    /// Only the file's first `WorkspaceFileService.partialBytes` are shown: it is over
    /// `wholeTextBytes`.
    let isPartial: Bool
    /// Text that is not UTF-8, shown with U+FFFD for what does not decode and never saved.
    let isLossy: Bool
    /// Whether the panel edits and saves it: a whole file within `editableBytes`, or a draft.
    let isEditable: Bool

    /// - Parameter text: kept as given. Hand in a string over an immutable `NSString` when it is
    ///   large, so the reader shows it without copying it on the main thread.
    init(id: UUID = UUID(), path: String, text: String, sourceDigest: String? = nil, encoding: WorkspaceFileEncoding = .utf8,
         isPartial: Bool = false, isLossy: Bool = false, isEditable: Bool = true, highlight: Highlight = .now) {
        self.id = id
        revision = UUID()
        self.path = path
        self.text = text
        self.sourceDigest = sourceDigest
        self.encoding = encoding
        self.isPartial = isPartial
        self.isLossy = isLossy
        self.isEditable = isEditable && !isPartial && !isLossy
        (utf16Length, lineStarts) = Self.lines(in: text)
        switch highlight {
        case .now:
            tokens = Self.tokens(in: text, path: path, utf16Length: utf16Length, isPartial: isPartial)
            highlightID = UUID()
        case let .later(keeping):
            tokens = []
            highlightID = keeping
        }
    }

    /// The same text with the colors worked out after an edit.
    func highlighted(_ tokens: [TranscriptCodeSyntax.Token]) -> Self {
        var document = self
        document.tokens = tokens
        document.highlightID = UUID()
        return document
    }

    /// The colors for `text`, or none past `WorkspaceFileService.highlightedBytes`.
    static func tokens(in text: String, path: String, utf16Length: Int? = nil, isPartial: Bool = false) -> [TranscriptCodeSyntax.Token] {
        // Every UTF-16 unit is at least one UTF-8 byte, so the cheap count rules out most large text.
        guard !isPartial, (utf16Length ?? text.utf16.count) <= WorkspaceFileService.highlightedBytes,
              text.utf8.count <= WorkspaceFileService.highlightedBytes else { return [] }
        return TranscriptCodeSyntax.tokens(in: text, language: URL(filePath: path).pathExtension)
    }

    /// The UTF-16 length and the offset each line starts at, read in blocks.
    private static func lines(in text: String) -> (length: Int, starts: [Int]) {
        let string = text as NSString
        let length = string.length
        var starts = [0]
        let block = 1 << 16
        var buffer = [unichar](repeating: 0, count: block)
        var location = 0
        while location < length {
            let count = min(block, length - location)
            buffer.withUnsafeMutableBufferPointer { units in
                string.getCharacters(units.baseAddress!, range: NSRange(location: location, length: count))
                for index in 0..<count where units[index] == 10 { starts.append(location + index + 1) }
            }
            location += count
        }
        return (length, starts)
    }

    func range(line: Int, column: Int? = nil) -> NSRange {
        let index = min(max(1, line) - 1, lineStarts.count - 1)
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : utf16Length
        if let column { return NSRange(location: min(end, start + min(max(1, column) - 1, end - start)), length: 0) }
        return NSRange(location: start, length: end - start)
    }

    func line(atUTF16Offset offset: Int) -> Int {
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(1, lower)
    }
}

enum WorkspaceFileEncoding: String, Codable, Sendable {
    case utf8, utf16LittleEndian, utf16BigEndian

    func data(_ text: String) -> Data? {
        switch self {
        case .utf8: text.data(using: .utf8)
        case .utf16LittleEndian: text.data(using: .utf16LittleEndian).map { Data([0xff, 0xfe]) + $0 }
        case .utf16BigEndian: text.data(using: .utf16BigEndian).map { Data([0xfe, 0xff]) + $0 }
        }
    }
}

struct WorkspaceFileIndex: Sendable {
    var paths: [String]
    var isLimited: Bool
}

enum WorkspaceFileService {
    /// A text file up to this size opens whole. Over it, the panel shows its first `partialBytes`
    /// (2026-10-23, the Claude app reads 10 MiB and Codex 256 MiB).
    static let wholeTextBytes = 20 * 1024 * 1024
    static let partialBytes = 2 * 1024 * 1024
    /// Syntax colors stop here: the main thread draws them.
    static let highlightedBytes = 2 * 1024 * 1024
    /// The panel edits and saves files up to this size, its bound from the start (2026-09-13).
    static let editableBytes = 2 * 1024 * 1024
    private static let skippedDirectories: Set<String> = [".git", ".build", "node_modules", ".next", ".venv", "__pycache__", ".swiftpm"]

    static func index(in workspace: URL, limit: Int = 20_000) throws -> WorkspaceFileIndex {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw WorkspaceFileError.notAFile }
        let bound = min(max(1, limit), 20_000)
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]) else { throw WorkspaceFileError.notAFile }
        var paths: [String] = []
        var visited = 0
        var limited = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            guard visited <= bound * 5 else { limited = true; break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) || values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
            } else if values?.isRegularFile == true || values?.isSymbolicLink == true {
                guard let location = try? WorkspaceFileLocation.resolve(url, in: root),
                      (try? root.appending(path: location.relativePath).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                paths.append(location.relativePath)
                if paths.count >= bound { limited = true; break }
            }
        }
        return WorkspaceFileIndex(paths: Array(Set(paths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                                  isLimited: limited)
    }

    static func read(_ location: WorkspaceFileLocation, in workspace: URL) throws -> WorkspaceFileDocument {
        let url: URL
        if location.isOutsideWorkspace {
            // Through a link such as `~/.codex/AGENTS.md`, whose own values say no regular file.
            url = URL(filePath: location.relativePath).resolvingSymlinksInPath()
        } else {
            let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
            url = root.appending(path: location.relativePath)
            let verified = try WorkspaceFileLocation.resolve(url, in: root)
            guard verified.relativePath == location.relativePath else { throw WorkspaceFileError.outsideWorkspace }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceFileError.notAFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // One byte past the whole-file bound notices a file that grew since it was measured.
        var data = try handle.read(upToCount: (values.fileSize ?? 0) > wholeTextBytes ? partialBytes : wholeTextBytes + 1) ?? Data()
        try Task.checkCancellation()
        let isPartial = (values.fileSize ?? 0) > wholeTextBytes || data.count > wholeTextBytes
        let encoding: WorkspaceFileEncoding = data.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian
            : data.starts(with: [0xfe, 0xff]) ? .utf16BigEndian : .utf8
        // A NUL byte in what was read makes a file binary, before a large one is cut to its beginning.
        let isBinary = encoding == .utf8 && data.withUnsafeBytes { bytes in
            bytes.baseAddress.map { memchr($0, 0, bytes.count) != nil } ?? false
        }
        if isPartial { data = beginning(of: data.prefix(partialBytes), encoding: encoding) }
        let decoded: String?
        var isLossy = false
        if encoding != .utf8 {
            decoded = String(data: data, encoding: .utf16)
        } else if isBinary {
            decoded = nil
        } else if let text = String(data: data, encoding: .utf8) {
            decoded = text
        } else {
            // Text in another encoding, such as zsh's history with its own bytes for Korean: shown as the
            // Codex and Claude apps decode it, with U+FFFD where it does not decode.
            decoded = String(decoding: data, as: UTF8.self)
            isLossy = true
        }
        guard let decoded else { throw WorkspaceFileError.unsupported }
        try Task.checkCancellation()
        // An immutable NSString the reader hands to its text storage as it is.
        let text = decoded.utf8.count > 65_536 ? NSString(string: decoded) as String : decoded
        return WorkspaceFileDocument(path: location.relativePath, text: text, sourceDigest: isPartial ? nil : digest(data),
                                     encoding: encoding, isPartial: isPartial, isLossy: isLossy,
                                     isEditable: !location.isOutsideWorkspace && data.count <= editableBytes)
    }

    /// `data` up to its last line break, or its last whole character when it has none.
    private static func beginning(of data: Data, encoding: WorkspaceFileEncoding) -> Data {
        let bytes = [UInt8](data)
        if encoding == .utf8 {
            if let newline = bytes.lastIndex(of: 10) { return Data(bytes[...newline]) }
            // Drop a character whose bytes run past the end.
            var end = bytes.count
            var start = end - 1
            while start > 0, end - start < 4, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            if start >= 0, start < end {
                let lead = bytes[start]
                let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
                if start + length > end { end = start }
            }
            return Data(bytes[..<end])
        }
        let units = (bytes.count - 2) / 2
        func unit(_ index: Int) -> UInt16 {
            let first = UInt16(bytes[2 + 2 * index]), second = UInt16(bytes[3 + 2 * index])
            return encoding == .utf16LittleEndian ? first | second << 8 : first << 8 | second
        }
        var end = units
        if let newline = (0..<units).last(where: { unit($0) == 10 }) { end = newline + 1 }
        else if end > 0, (0xD800...0xDBFF).contains(unit(end - 1)) { end -= 1 }
        return Data(bytes[..<(2 + 2 * end)])
    }

    static func digest(_ data: Data) -> String { WorkspaceFileReplacement.digest(data) }

    static func save(path: String, text: String, expectedDigest: String, encoding: WorkspaceFileEncoding,
        in workspace: URL) throws -> WorkspaceFileDocument {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appending(path: path).standardizedFileURL
        let verified = try WorkspaceFileLocation.resolve(file, in: root)
        guard verified.relativePath == path, file.resolvingSymlinksInPath() == file else { throw WorkspaceFileError.outsideWorkspace }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkspaceFileError.notAFile }
        guard FileManager.default.isWritableFile(atPath: file.path), let data = encoding.data(text) else { throw WorkspaceFileError.notWritable }
        guard data.count <= editableBytes else { throw WorkspaceFileError.tooLarge }
        try WorkspaceFileReplacement.replace(path: path, in: root, with: data, expectedDigest: expectedDigest,
            maximumBytes: editableBytes)
        let saved = try read(.init(relativePath: path), in: root)
        guard saved.sourceDigest == digest(data) else { throw WorkspaceFileError.changedOnDisk }
        return saved
    }
}
