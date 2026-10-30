import Foundation

/// A path with `..` and every symbolic link resolved, as `realpath(3)` gives it (`/tmp` is `/private/tmp`
/// on macOS); nil when nothing is there.
enum CanonicalPath {
    static func resolve(_ path: String) -> String? {
        #if os(Windows)
        // Windows has no realpath. Until its layer reads an opened file's final path
        // (GetFinalPathNameByHandleW), Foundation resolves the links, and the path must exist.
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url.path(percentEncoded: false) : nil
        #else
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
        #endif
    }
}
