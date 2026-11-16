import Crypto
import Foundation
import WinSDK

/// The Windows part of saving a workspace file, with the Mac's guarantees: nothing beneath the folder is followed
/// when it is a link, and the file is replaced only while it still holds the bytes the person reviewed. The folders on
/// the way are held as `ScopedFiles` holds them, so none can be renamed or replaced by a link meanwhile. The file is
/// opened as itself and shared for reading and removing only, so nothing writes to it from the check until the new
/// file takes its place. The new file is written beside it with its attributes and access list, and renamed over it
/// through its own handle. `authorize` runs last, immediately before that rename, and stops the save by throwing.
enum WorkspaceFileReplacement {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func replace(path: String, in root: URL, with data: Data, expectedDigest: String, maximumBytes: Int,
                        authorize: () throws -> Void = {}) throws {
        let names = PathRules.windows.names(path)
        guard let name = names.last, ScopedFiles.isPlainName(name) else { throw WorkspaceFileError.notWritable }
        let replaced = try ScopedFiles(root: root).inFolder(Array(names.dropLast())) { folder -> Bool? in
            try replaceFile(folder + "\\" + name, in: folder, with: data, expectedDigest: expectedDigest,
                            maximumBytes: maximumBytes, authorize: authorize)
            return true
        }
        guard replaced == true else { throw WorkspaceFileError.notWritable }
    }

    /// Replaces the file at `location`, in the held `folder`, as `replace(path:in:with:)` describes.
    private static func replaceFile(_ location: String, in folder: String, with data: Data, expectedDigest: String,
                                    maximumBytes: Int, authorize: () throws -> Void) throws {
        // A writer that has the file open already makes this fail, and none can open it for writing after.
        guard let source = ScopedFiles.open(location, directory: false, asItself: true,
                                            fileSharing: DWORD(FILE_SHARE_READ | FILE_SHARE_DELETE)) else {
            throw WorkspaceFileError.notWritable
        }
        var sourceOpen = true
        defer { if sourceOpen { CloseHandle(source.handle) } }
        let original = source.information
        // A read-only file stays as it is, as the rename would refuse it.
        guard original.dwFileAttributes & DWORD(FILE_ATTRIBUTE_READONLY) == 0 else { throw WorkspaceFileError.notWritable }
        guard digest(try contents(of: source.handle, upTo: maximumBytes + 1)) == expectedDigest else {
            throw WorkspaceFileError.changedOnDisk
        }

        let kept = original.dwFileAttributes
            & DWORD(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED)
        let temporary = folder + "\\.yardlet-save-\(UUID().uuidString)"
        let output = temporary.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE) | DWORD(DELETE) | DWORD(WRITE_DAC), DWORD(FILE_SHARE_READ), nil,
                        DWORD(CREATE_NEW), DWORD(FILE_FLAG_OPEN_REPARSE_POINT) | (kept == 0 ? DWORD(FILE_ATTRIBUTE_NORMAL) : kept),
                        nil)
        }
        guard let output, output != INVALID_HANDLE_VALUE else { throw WorkspaceFileError.notWritable }
        var renamed = false
        defer {
            if !renamed { removeOnClose(output) }
            CloseHandle(output)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                guard WriteFile(output, bytes.baseAddress! + offset, DWORD(min(bytes.count - offset, 1 << 20)), &written, nil),
                      written > 0 else { throw WorkspaceFileError.notWritable }
                offset += Int(written)
            }
        }
        guard copyAccessList(from: source.handle, to: output), FlushFileBuffers(output) else {
            throw WorkspaceFileError.notWritable
        }

        // The name still holds the file that was checked: it could have been renamed away, as the rename below needs
        // it shared for removing.
        guard let current = ScopedFiles.open(location, directory: false, asItself: true,
                                             access: DWORD(FILE_READ_ATTRIBUTES)) else {
            throw WorkspaceFileError.changedOnDisk
        }
        let now = current.information
        CloseHandle(current.handle)
        guard now.dwVolumeSerialNumber == original.dwVolumeSerialNumber, now.nFileIndexHigh == original.nFileIndexHigh,
              now.nFileIndexLow == original.nFileIndexLow else { throw WorkspaceFileError.changedOnDisk }
        try Task.checkCancellation()
        try authorize()

        if let error = move(output, over: location, whileOpen: true) {
            // A volume without POSIX renames (FAT, some network shares) replaces only a file nobody has open.
            guard error == DWORD(ERROR_NOT_SUPPORTED) || error == DWORD(ERROR_INVALID_PARAMETER)
                    || error == DWORD(ERROR_INVALID_FUNCTION) else { throw WorkspaceFileError.notWritable }
            CloseHandle(source.handle)
            sourceOpen = false
            guard move(output, over: location, whileOpen: false) == nil else { throw WorkspaceFileError.notWritable }
        }
        renamed = true
    }

    /// Up to `count` bytes from the start of the file `handle` has open.
    private static func contents(of handle: HANDLE, upTo count: Int) throws -> Data {
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { buffer in
            while total < count {
                var chunk: DWORD = 0
                guard ReadFile(handle, buffer.baseAddress! + total, DWORD(min(count - total, 1 << 20)), &chunk, nil) else {
                    throw WorkspaceFileError.notWritable
                }
                if chunk == 0 { break }
                total += Int(chunk)
            }
        }
        return data.prefix(total)
    }

    /// The file `handle` has open renamed to `location`, replacing the file there: with `whileOpen`, at once and while
    /// that file is still open, as long as each handle on it shares removing (FileRenameInfoEx with POSIX semantics).
    /// Nil once done, else the error Windows gave.
    private static func move(_ handle: HANDLE, over location: String, whileOpen: Bool) -> DWORD? {
        let name = Array(location.utf16)
        let size = MemoryLayout<FILE_RENAME_INFO>.stride + name.count * MemoryLayout<WCHAR>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<FILE_RENAME_INFO>.alignment)
        defer { buffer.deallocate() }
        _ = buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        // The first field is FileRenameInfoEx's flags (FILE_RENAME_FLAG_REPLACE_IF_EXISTS and
        // FILE_RENAME_FLAG_POSIX_SEMANTICS), or FileRenameInfo's ReplaceIfExists in its first byte. No root folder.
        buffer.storeBytes(of: whileOpen ? DWORD(0x3) : DWORD(0x1), as: DWORD.self)
        buffer.storeBytes(of: DWORD(name.count * MemoryLayout<WCHAR>.size),
                          toByteOffset: MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileNameLength)!, as: DWORD.self)
        name.withUnsafeBytes {
            (buffer + MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileName)!).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        return SetFileInformationByHandle(handle, whileOpen ? FileRenameInfoEx : FileRenameInfo, buffer, DWORD(size))
            ? nil : GetLastError()
    }

    /// The access list of the file `source` has open, given to the one `target` has open, as the Mac keeps a file's
    /// permissions and ACL. A volume that keeps none (FAT) has nothing to give.
    private static func copyAccessList(from source: HANDLE, to target: HANDLE) -> Bool {
        var volumeFlags: DWORD = 0
        guard GetVolumeInformationByHandleW(source, nil, 0, nil, nil, &volumeFlags, nil, 0) else { return false }
        guard volumeFlags & DWORD(FILE_PERSISTENT_ACLS) != 0 else { return true }
        let information = SECURITY_INFORMATION(DACL_SECURITY_INFORMATION)
        var needed: DWORD = 0
        _ = GetKernelObjectSecurity(source, information, nil, 0, &needed)
        guard needed > 0 else { return false }
        let descriptor = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 8)
        defer { descriptor.deallocate() }
        return GetKernelObjectSecurity(source, information, descriptor, needed, &needed)
            && SetKernelObjectSecurity(target, information, descriptor)
    }

    /// The file `handle` has open, marked to be removed once it is closed.
    private static func removeOnClose(_ handle: HANDLE) {
        var information = FILE_DISPOSITION_INFO()
        // Its one field, DeleteFile, which the header's DeleteFile macro may rename.
        withUnsafeMutableBytes(of: &information) { $0[0] = 1 }
        _ = SetFileInformationByHandle(handle, FileDispositionInfo, &information,
                                       DWORD(MemoryLayout<FILE_DISPOSITION_INFO>.size))
    }
}
