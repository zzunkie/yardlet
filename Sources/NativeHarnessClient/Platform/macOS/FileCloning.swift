import Darwin
import Foundation

/// A copy that shares the original's blocks where the file system can (an APFS clone), with its
/// metadata.
enum FileCloning {
    static func clone(_ source: URL, to destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) == 0
            }
        }
    }
}
