import Darwin
import Foundation

/// A copy that shares the original's blocks where the file system can (an APFS clone), with its
/// metadata.
enum FileCloning {
    static func clone(_ source: URL, to destination: URL) -> Bool {
        source.path().withCString { sourcePath in
            destination.path().withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) == 0
            }
        }
    }
}
