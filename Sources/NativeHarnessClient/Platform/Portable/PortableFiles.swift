import Crypto
import Foundation

/// Saving a reviewed workspace file: refused here.
enum WorkspaceFileReplacement {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func replace(path: String, in root: URL, with data: Data, expectedDigest: String, maximumBytes: Int,
                        authorize: () throws -> Void = {}) throws {
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
