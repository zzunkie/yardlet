import Crypto
import Foundation

// File access that must not follow a link swapped in beneath a folder. Each platform builds it on
// its own no-follow primitives (Platform/macOS: openat with O_NOFOLLOW). Foundation alone cannot
// promise that, so here nothing is read or written through them.

/// Files beneath `root`, reached without following links: none here.
struct ScopedFiles {
    let root: URL
    func isDirectory(_ path: [String]) -> Bool { false }
    func isRegularFile(_ path: [String]) -> Bool { false }
    func directories(_ path: [String], limit: Int) throws -> [String] { [] }
    func names(_ path: [String], limit: Int) throws -> [String] { [] }
    func openRegularFile(_ path: [String]) -> OpenFile? { nil }
    func data(_ path: [String], maximumBytes: Int, tail: Bool) throws -> (data: Data, truncated: Bool)? { nil }
}

/// A transcript open for reading in parts, with what it was when opened.
struct OpenFile {
    let handle: FileHandle
    let identity: ClaudeTranscriptWindow.FileIdentity
    let size: Int64

    func lines(from start: Int64, to end: Int64) throws -> (data: Data, start: Int64) { (Data(), end) }
    func line(at offset: Int64, length: Int) throws -> Data? { nil }
}

/// Saving a reviewed workspace file: refused here.
enum WorkspaceFileReplacement {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func replace(path: String, in root: URL, with data: Data, expectedDigest: String, maximumBytes: Int) throws {
        throw WorkspaceFileError.notWritable
    }
}

/// No block-sharing copy here; the caller copies the file itself.
enum FileCloning {
    static func clone(_ source: URL, to destination: URL) -> Bool { false }
}

/// No trash here: nothing is moved, and the caller keeps what it would have deleted.
enum Trash {
    static func move(_ url: URL) throws {
        throw CocoaError(.featureUnsupported)
    }
}
