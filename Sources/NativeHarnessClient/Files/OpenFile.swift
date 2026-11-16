import Foundation

/// A file `ScopedFiles` opened for reading in parts, with what it was when opened. It closes when released.
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

    /// Up to `count` bytes from `offset`. FileHandle hands its data over autoreleased; a read of
    /// many parts of a large file must not keep every part until the thread's autorelease pool
    /// drains.
    func read(_ count: Int, at offset: Int64) throws -> Data {
        try autoreleasepool {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }
}

extension ScopedFiles {
    /// The regular file at `path`, nil when there is none. A file larger than `maximumBytes` is
    /// nil, or with `tail` its last `maximumBytes` from the first line that starts in them, and
    /// `truncated`.
    func data(_ path: [String], maximumBytes: Int, tail: Bool) throws -> (data: Data, truncated: Bool)? {
        guard let file = openRegularFile(path) else { return nil }
        let offset = max(0, file.size - Int64(maximumBytes))
        if offset > 0 && !tail { return nil }
        var data = try file.read(maximumBytes, at: offset)
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return (Data(), true) }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        return (data, offset > 0)
    }
}
