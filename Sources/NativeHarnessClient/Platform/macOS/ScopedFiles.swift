import Darwin
import Foundation

/// openat/O_NOFOLLOW protects every descendant, including directories swapped during a
/// live append. O_NONBLOCK plus fstat refuses FIFOs/devices before attempting a read.
struct ScopedFiles {
    let root: URL
    func open(_ path: [String], directory: Bool) -> Int32 {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return -1 }
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        for (index, component) in path.enumerated() {
            let isDirectory = directory || index < path.count - 1
            let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (isDirectory ? O_DIRECTORY : 0))
            Darwin.close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }
    func isDirectory(_ path: [String]) -> Bool {
        let fd = open(path, directory: true)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }
    func isRegularFile(_ path: [String]) -> Bool {
        let fd = open(path, directory: false)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var value = stat()
        return fstat(fd, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }
    func directories(_ path: [String], limit: Int) throws -> [String] {
        try names(path, limit: limit).filter { isDirectory(path + [$0]) }
    }
    func names(_ path: [String], limit: Int) throws -> [String] {
        let fd = open(path, directory: true)
        guard fd >= 0 else { return [] }
        guard let directory = fdopendir(fd) else { Darwin.close(fd); return [] }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
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
        return OpenFile(handle: handle, identity: .init(device: Int64(value.st_dev), inode: UInt64(value.st_ino)),
                        size: value.st_size)
    }

    func data(_ path: [String], maximumBytes: Int, tail: Bool) throws -> (data: Data, truncated: Bool)? {
        let fd = open(path, directory: false)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { return nil }
        let offset = max(0, value.st_size - Int64(maximumBytes))
        if offset > 0 && !tail { return nil }
        if offset > 0 { try file.seek(toOffset: UInt64(offset)) }
        var data = try file.read(upToCount: maximumBytes) ?? Data()
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return (Data(), true) }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        return (data, offset > 0)
    }
}

/// A transcript open for reading in parts, with what it was when opened. It closes when released.
struct OpenFile {
    let handle: FileHandle
    let identity: ClaudeTranscriptWindow.FileIdentity
    let size: Int64

    /// The whole lines in `start..<end`, which must end at a line's end, and where the first
    /// begins: a line `start` falls inside belongs to the part before. None, and `end`, when
    /// one line holds the whole range.
    func lines(from start: Int64, to end: Int64) throws -> (data: Data, start: Int64) {
        guard start < end else { return (Data(), end) }
        let data = try read(Int(end - start), at: start)
        guard start > 0 else { return (data, 0) }
        guard let newline = data.firstIndex(of: 10) else { return (Data(), end) }
        return (Data(data[(newline + 1)...]), start + Int64(newline - data.startIndex) + 1)
    }

    /// The line at `offset`, nil when the file no longer holds all of it.
    func line(at offset: Int64, length: Int) throws -> Data? {
        let data = try read(length, at: offset)
        return data.count == length ? data : nil
    }

    /// FileHandle hands its data over autoreleased; a read of many parts of a large file must
    /// not keep every part until the thread's autorelease pool drains.
    private func read(_ count: Int, at offset: Int64) throws -> Data {
        try autoreleasepool {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }
}
