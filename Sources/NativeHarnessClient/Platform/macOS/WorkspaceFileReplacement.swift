import CryptoKit
import Darwin
import Foundation

/// The macOS part of saving a workspace file. The replacement goes through no-follow directory
/// descriptors so a concurrent link swap cannot move the write outside the workspace, and it
/// happens only while the file still holds the bytes the person reviewed. `authorize` runs last,
/// immediately before the new file takes the old one's place, and stops the save by throwing.
enum WorkspaceFileReplacement {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func replace(path: String, in root: URL, with data: Data, expectedDigest: String, maximumBytes: Int,
                        authorize: () throws -> Void = {}) throws {
        // Hold no-follow directory descriptors so a concurrent link replacement cannot move
        // the write outside this workspace. Replace through the same parent descriptor.
        var parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw WorkspaceFileError.notWritable }
        defer { Darwin.close(parent) }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw WorkspaceFileError.notWritable }
        for part in parts.dropLast() {
            let next = Darwin.openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw WorkspaceFileError.notWritable }
            Darwin.close(parent); parent = next
        }
        let source = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw WorkspaceFileError.notWritable }
        let handle = FileHandle(fileDescriptor: source, closeOnDealloc: true)
        var original = stat()
        guard Darwin.fstat(source, &original) == 0, original.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.notAFile }
        guard digest(try handle.read(upToCount: maximumBytes + 1) ?? Data()) == expectedDigest else { throw WorkspaceFileError.changedOnDisk }
        let temporary = ".yardlet-save-\(UUID().uuidString)"
        let output = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, original.st_mode & 0o777)
        guard output >= 0 else { throw WorkspaceFileError.notWritable }
        defer { Darwin.close(output); Darwin.unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw WorkspaceFileError.notWritable }
                offset += written
            }
        }
        guard Darwin.fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
              Darwin.fsync(output) == 0 else { throw WorkspaceFileError.notWritable }
        var current = stat()
        guard Darwin.fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == original.st_ino, current.st_dev == original.st_dev else { throw WorkspaceFileError.changedOnDisk }
        try handle.seek(toOffset: 0)
        guard digest(try handle.read(upToCount: maximumBytes + 1) ?? Data()) == expectedDigest else { throw WorkspaceFileError.changedOnDisk }
        try Task.checkCancellation()
        try authorize()
        guard Darwin.renameat(parent, temporary, parent, name) == 0 else { throw WorkspaceFileError.notWritable }
    }
}
