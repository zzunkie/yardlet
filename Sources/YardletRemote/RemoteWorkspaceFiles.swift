import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct RemoteWorkspaceFileIndex: Sendable {
    public var paths: [String]
    public var isLimited: Bool
}

extension RemoteFileReader {
    /// Names only in the task's primary folder. Descriptor-relative traversal never follows links,
    /// including when a folder is replaced during enumeration. Files are still read through `readFile`.
    public static func index(in scope: RemoteFileScope, home: String = NSHomeDirectory()) -> Result<RemoteWorkspaceFileIndex, RemoteError> {
        #if canImport(Darwin)
        guard let root = realPath(scope.folder.path(percentEncoded: false)),
              !holdsHome(root, home: realPath(home) ?? lexical(home)) else { return .failure(refused()) }
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(refused()) }
        defer { close(descriptor) }
        let skipped: Set<String> = [".git", ".build", "node_modules", ".next", ".venv", "__pycache__", ".swiftpm"]
        var paths: [String] = []
        var visited = 0, bytes = 0
        var limited = false
        func walk(_ descriptor: Int32, _ prefix: String, depth: Int) {
            guard depth < 64 else { limited = true; return }
            let copy = dup(descriptor)
            guard copy >= 0 else { return }
            guard let directory = fdopendir(copy) else { close(copy); return }
            defer { closedir(directory) }
            while !limited, let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= 100_000 else { limited = true; break }
                let path = prefix + name
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard !skipped.contains(name) else { continue }
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child >= 0 { walk(child, path + "/", depth: depth + 1); close(child) }
                } else if info.st_mode & S_IFMT == S_IFREG {
                    // Leave headroom for JSON escaping and the encrypted frame's envelope.
                    guard paths.count < 20_000, bytes + path.utf8.count <= 128 * 1024 else { limited = true; break }
                    paths.append(path)
                    bytes += path.utf8.count
                }
            }
        }
        walk(descriptor, "", depth: 0)
        return .success(.init(paths: paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, isLimited: limited))
        #else
        return .failure(RemoteError(.unavailable))
        #endif
    }
}
