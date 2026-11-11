import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// A file of the remote's that only its owner may read: paired devices, saved hosts, limits, uploads.
enum RemotePrivateFile {
    /// Replaces `fileURL` with `data` through a temporary file beside it, synced and then renamed over it, so a
    /// reader sees the old contents or the new ones; the folder is made, private, when it is missing. On macOS and
    /// Linux the temporary file is readable by its owner alone (0600) from the moment it is created: a file written
    /// and then narrowed has the process's default permissions until it is narrowed.
    static func write(_ data: Data, to fileURL: URL) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".remote-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        try Data().write(to: temporary, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        #endif
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        #if canImport(Darwin) || canImport(Glibc)
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #elseif os(Windows)
        let source = Array(temporary.path.utf16) + [0]
        let destination = Array(fileURL.path.utf16) + [0]
        let replaced = source.withUnsafeBufferPointer { from in
            destination.withUnsafeBufferPointer { to in
                MoveFileExW(from.baseAddress, to.baseAddress, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard replaced else { throw NSError(domain: "Win32", code: Int(GetLastError())) }
        #else
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary, options: [.usingNewMetadataOnly])
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
        #endif
    }
}
