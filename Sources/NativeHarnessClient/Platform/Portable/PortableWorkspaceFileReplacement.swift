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
