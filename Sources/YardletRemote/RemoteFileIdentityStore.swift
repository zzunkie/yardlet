import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A host's remote keys (§11.2) in a file its owner alone may read (0600) in a folder of theirs alone (0700), for a
/// computer with no keychain to keep them in: the Linux host without a Secret Service (docs/LINUX_HOST.md, "Keys").
/// The file holds what the Mac keeps in its keychain item. It is written whole through a temporary file beside it
/// (`RemotePrivateFile`), and a file that others may read is narrowed to its owner before it is read.
public struct RemoteFileIdentityStore: RemoteIdentityStoring {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> RemoteIdentity? {
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        #if canImport(Glibc)
        var status = stat()
        if stat(path, &status) == 0, status.st_mode & 0o077 != 0 { _ = chmod(path, 0o600) }
        #endif
        return try RemoteIdentity(stored: Data(contentsOf: fileURL))
    }

    public func save(_ identity: RemoteIdentity) throws {
        try RemotePrivateFile.write(identity.stored, to: fileURL)
    }
}
