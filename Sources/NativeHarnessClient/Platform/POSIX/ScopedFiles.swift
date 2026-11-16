#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// openat/O_NOFOLLOW protects every descendant, including directories swapped during a
/// live append. O_NONBLOCK plus fstat refuses FIFOs/devices before attempting a read.
/// The Mac app's and the Linux host's, on the same POSIX calls.
struct ScopedFiles {
    let root: URL
    func open(_ path: [String], directory: Bool) -> Int32 {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return -1 }
        var fd = openRoot(root.path)
        guard fd >= 0 else { return -1 }
        for (index, component) in path.enumerated() {
            let isDirectory = directory || index < path.count - 1
            let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (isDirectory ? O_DIRECTORY : 0))
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }
    func isDirectory(_ path: [String]) -> Bool {
        let fd = open(path, directory: true)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
    func isRegularFile(_ path: [String]) -> Bool {
        let fd = open(path, directory: false)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var value = stat()
        return fstat(fd, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }
    func directories(_ path: [String], limit: Int) throws -> [String] {
        try names(path, limit: limit).filter { isDirectory(path + [$0]) }
    }
    func names(_ path: [String], limit: Int) throws -> [String] {
        let fd = open(path, directory: true)
        guard fd >= 0 else { return [] }
        guard let directory = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= limit else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
            }
        }
        return result
    }
    /// The regular file at `path`, open for reading parts of it, nil when there is none.
    func openRegularFile(_ path: [String]) -> OpenFile? {
        let fd = open(path, directory: false)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { return nil }
        return OpenFile(handle: handle, identity: .init(device: Int64(truncatingIfNeeded: value.st_dev),
                                                        inode: UInt64(value.st_ino)),
                        size: Int64(value.st_size))
    }
}

/// The root as it is, a link included; outside `ScopedFiles`, whose own `open` would hide the C library's.
private func openRoot(_ path: String) -> Int32 {
    open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
}
