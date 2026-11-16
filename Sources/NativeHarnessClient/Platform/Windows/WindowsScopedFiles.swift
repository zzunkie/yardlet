import Foundation
import ucrt
import WinSDK

/// Files beneath `root`, reached without following links: Claude's transcripts, a restore's files and a reviewed
/// workspace file's save (`WorkspaceFileReplacement`). Each name beneath the root is opened as itself
/// (`FILE_FLAG_OPEN_REPARSE_POINT`), one at a time, and refused when it is a reparse point: a symbolic link, a junction
/// or any other. The folders on the way stay open without `FILE_SHARE_DELETE` until the name after them is open, so
/// none can be renamed, or removed and replaced by a link, meanwhile. The root itself may be a link, as on the Mac.
/// Only regular files on a disk are read.
struct ScopedFiles {
    let root: URL

    func isDirectory(_ path: [String]) -> Bool {
        guard let item = open(path, directory: true) else { return false }
        CloseHandle(item.handle)
        return true
    }

    func isRegularFile(_ path: [String]) -> Bool {
        guard let item = open(path, directory: false) else { return false }
        CloseHandle(item.handle)
        return true
    }

    /// The folders in `path`, as its listing describes them, so a link to a folder is not one.
    func directories(_ path: [String], limit: Int) throws -> [String] {
        try entries(path, limit: limit).filter(\.isDirectory).map(\.name)
    }

    func names(_ path: [String], limit: Int) throws -> [String] {
        try entries(path, limit: limit).map(\.name)
    }

    /// The regular file at `path`, open for reading parts of it, nil when there is none.
    func openRegularFile(_ path: [String]) -> OpenFile? {
        guard let item = open(path, directory: false) else { return nil }
        // Foundation makes a FileHandle from a C runtime descriptor, not a handle: the descriptor takes the handle
        // over, and the FileHandle the descriptor.
        let descriptor = _open_osfhandle(intptr_t(bitPattern: item.handle), _O_RDONLY)
        guard descriptor >= 0 else {
            CloseHandle(item.handle)
            return nil
        }
        let information = item.information
        return OpenFile(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                        identity: .init(device: Int64(information.dwVolumeSerialNumber),
                                        inode: UInt64(information.nFileIndexHigh) << 32 | UInt64(information.nFileIndexLow)),
                        size: Int64(information.nFileSizeHigh) << 32 | Int64(information.nFileSizeLow))
    }

    struct Item {
        let handle: HANDLE
        let information: BY_HANDLE_FILE_INFORMATION
    }

    /// `path` beneath the root, a folder when `directory` and otherwise a regular file, with a handle the caller
    /// closes. Nil when a name is not a plain one, or a name on the way is missing, a reparse point or not a folder.
    private func open(_ path: [String], directory: Bool) -> Item? {
        guard let last = path.last else {
            return directory ? Self.open(PathRules.windows.nativePath(of: root), directory: true, asItself: false) : nil
        }
        guard Self.isPlainName(last) else { return nil }
        return inFolder(Array(path.dropLast())) { Self.open($0 + "\\" + last, directory: directory, asItself: true) }
    }

    /// `body`'s result, run with the folder at `folders` beneath the root open: its location, the root's own path with
    /// its links resolved and then the names, in the `\\?\` form, which has no MAX_PATH. That folder and each on the
    /// way to it stay open until `body` returns, so the location names the same folder all along. Nil when a name is
    /// not a plain one, or a folder on the way is missing, a reparse point or not a folder.
    func inFolder<Value>(_ folders: [String], _ body: (String) throws -> Value?) rethrows -> Value? {
        guard folders.allSatisfy(Self.isPlainName),
              let top = Self.open(PathRules.windows.nativePath(of: root), directory: true, asItself: false) else {
            return nil
        }
        var held = [top.handle]
        defer { held.forEach { CloseHandle($0) } }
        guard var location = Self.finalPath(of: top.handle) else { return nil }
        for name in folders {
            location += "\\" + name
            guard let folder = Self.open(location, directory: true, asItself: true) else { return nil }
            held.append(folder.handle)
        }
        return try body(location)
    }

    /// `location` opened for `access`, as itself when `asItself`, which refuses a reparse point; nil when it is not
    /// the kind asked for. A folder is shared for reading and writing only, so it is neither renamed nor removed while
    /// open. A file is shared as `fileSharing` says, by default for everything, so Claude goes on appending to it, or
    /// replaces or removes it, while it is read.
    static func open(_ location: String, directory: Bool, asItself: Bool, access: DWORD = DWORD(GENERIC_READ),
                     fileSharing: DWORD = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)) -> Item? {
        let share = directory ? DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE) : fileSharing
        let flags = DWORD((directory ? FILE_FLAG_BACKUP_SEMANTICS : 0) | (asItself ? FILE_FLAG_OPEN_REPARSE_POINT : 0))
        let handle = location.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, share, nil, DWORD(OPEN_EXISTING), flags, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information),
              !asItself || information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              (information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0) == directory,
              directory || GetFileType(handle) == DWORD(FILE_TYPE_DISK) else {
            CloseHandle(handle)
            return nil
        }
        return Item(handle: handle, information: information)
    }

    /// The path of what `handle` has open, with its links resolved, in the `\\?\` form.
    private static func finalPath(of handle: HANDLE) -> String? {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        var length = Int(GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED)))
        // Too small: the length it needs, with the terminating zero.
        if length >= buffer.count {
            buffer = [WCHAR](repeating: 0, count: length)
            length = Int(GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED)))
        }
        guard length > 0, length < buffer.count else { return nil }
        return String(decoding: buffer[..<length], as: UTF16.self)
    }

    /// One name in a folder: not empty, not `.` or `..`, and nothing Windows reads as a separator, a drive, a stream
    /// or a pattern.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0.value < 32 || "\\/:*?\"<>|".unicodeScalars.contains($0) }
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
    }

    /// The folder at `path`, listed through its own handle; nothing when it cannot be opened.
    private func entries(_ path: [String], limit: Int) throws -> [Entry] {
        guard let item = open(path, directory: true) else { return [] }
        defer { CloseHandle(item.handle) }
        let size = 64 * 1_024
        // Room past the end, as the last entry's fixed part is read whole however short its name.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size + MemoryLayout<FILE_FULL_DIR_INFO>.stride,
                                                      alignment: MemoryLayout<FILE_FULL_DIR_INFO>.alignment)
        defer { buffer.deallocate() }
        let nameOffset = MemoryLayout<FILE_FULL_DIR_INFO>.offset(of: \.FileName)!
        var result: [Entry] = []
        // Each call gives the entries after the last call's, and fails once there are none.
        while GetFileInformationByHandleEx(item.handle, FileFullDirectoryInfo, buffer, DWORD(size)) {
            var entry = buffer
            while true {
                let information = entry.load(as: FILE_FULL_DIR_INFO.self)
                let name = String(decoding: UnsafeBufferPointer(
                    start: (entry + nameOffset).assumingMemoryBound(to: WCHAR.self),
                    count: Int(information.FileNameLength) / MemoryLayout<WCHAR>.size), as: UTF16.self)
                if name != "." && name != ".." {
                    let attributes = information.FileAttributes
                    result.append(Entry(name: name, isDirectory: attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
                                            && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0))
                    guard result.count <= limit else {
                        throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
                    }
                }
                guard information.NextEntryOffset != 0 else { break }
                entry += Int(information.NextEntryOffset)
            }
        }
        return result
    }
}
