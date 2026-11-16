import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The Mac app's and the Linux host's part of saving a workspace file. The replacement goes through no-follow
/// directory descriptors so a concurrent link swap cannot move the write outside the workspace, and it happens only
/// while the file still holds the bytes the person reviewed. `authorize` runs last, immediately before the new file
/// takes the old one's place, and stops the save by throwing.
enum WorkspaceFileReplacement {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func replace(path: String, in root: URL, with data: Data, expectedDigest: String, maximumBytes: Int,
                        authorize: () throws -> Void = {}) throws {
        // Hold no-follow directory descriptors so a concurrent link replacement cannot move
        // the write outside this workspace. Replace through the same parent descriptor.
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw WorkspaceFileError.notWritable }
        defer { close(parent) }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw WorkspaceFileError.notWritable }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw WorkspaceFileError.notWritable }
            close(parent); parent = next
        }
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw WorkspaceFileError.notWritable }
        let handle = FileHandle(fileDescriptor: source, closeOnDealloc: true)
        var original = stat()
        guard fstat(source, &original) == 0, original.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.notAFile }
        guard digest(try handle.read(upToCount: maximumBytes + 1) ?? Data()) == expectedDigest else { throw WorkspaceFileError.changedOnDisk }
        let temporary = ".yardlet-save-\(UUID().uuidString)"
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, original.st_mode & 0o777)
        guard output >= 0 else { throw WorkspaceFileError.notWritable }
        defer { close(output); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw WorkspaceFileError.notWritable }
                offset += written
            }
        }
        guard keepMetadata(of: source, original, on: output), fsync(output) == 0 else { throw WorkspaceFileError.notWritable }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == original.st_ino, current.st_dev == original.st_dev else { throw WorkspaceFileError.changedOnDisk }
        try handle.seek(toOffset: 0)
        guard digest(try handle.read(upToCount: maximumBytes + 1) ?? Data()) == expectedDigest else { throw WorkspaceFileError.changedOnDisk }
        try Task.checkCancellation()
        try authorize()
        guard renameat(parent, temporary, parent, name) == 0 else { throw WorkspaceFileError.notWritable }
    }

    /// Gives the new file what the old one had beyond its bytes: on the Mac everything `copyfile` copies as metadata,
    /// on Linux its permissions, which the process's umask may have narrowed when the new file was made.
    private static func keepMetadata(of source: Int32, _ original: stat, on output: Int32) -> Bool {
        #if canImport(Darwin)
        fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0
        #else
        fchmod(output, original.st_mode & 0o777) == 0
        #endif
    }
}
