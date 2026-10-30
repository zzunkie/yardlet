import Foundation
import YardletAgentTools

/// A JavaScript dialog opened while a tool waited on the page. The page is paused until the
/// agent answers it, so the tool reports the dialog instead of waiting out its time limit.
struct BrowserAgentDialogOpened: Error {}

/// Lets exactly one of two racing callbacks resume a continuation.
@MainActor
final class BrowserAgentOnce {
    private var isClaimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

/// Files the agent may hand to a page's file chooser: only inside the task's project folders,
/// after `..` and symbolic links are resolved, so an upload cannot reach the rest of the disk. The same
/// reading tells which `file:` pages the agent opens are in those folders (`BrowserAgentTools`).
enum BrowserAgentWorkspaceFile {
    /// A file the task's folders do not hold is refused: one inside them goes.
    private static func outsideFolders(retry: AgentToolFailure.Retry) -> AgentToolFailure {
        AgentToolFailure(.refused, retry: retry)
    }

    static func resolve(_ path: String, roots: [URL], mode: BrowserFileDialog.Mode) throws -> String {
        guard let primary = roots.first else {
            throw BrowserAgentToolError("This task has no project folder, so no file can be uploaded.", outsideFolders(retry: .no))
        }
        let requested = path.hasPrefix("/") ? URL(filePath: path) : primary.appending(path: path)
        let standardized = requested.standardizedFileURL
        // A file to be saved need not exist yet; its folder must.
        let resolved = mode == .save
            ? standardized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: standardized.lastPathComponent)
            : standardized.resolvingSymlinksInPath()
        let resolvedRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard resolvedRoots.contains(where: { contains($0, resolved) }) else {
            throw BrowserAgentToolError("\(path) is outside this task's project folders.", outsideFolders(retry: .withChanges))
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false), isDirectory: &isDirectory)
        switch mode {
        case .open, .openMultiple:
            guard exists, !isDirectory.boolValue else { throw BrowserAgentToolError("\(path) is not a file.") }
        case .openFolder:
            guard exists, isDirectory.boolValue else { throw BrowserAgentToolError("\(path) is not a folder.") }
        case .save:
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resolved.deletingLastPathComponent().path(percentEncoded: false), isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue, !isDirectory.boolValue else {
                throw BrowserAgentToolError("\(path) cannot be saved there.")
            }
        }
        return resolved.path(percentEncoded: false)
    }

    /// A private copy of a file `resolve` let through, for the chooser. The file's real path as the system
    /// gives it (`realpath`) must still be in one of `roots`, and the file is opened along that path one folder
    /// at a time without following a link, so a link swapped in after the check cannot lead outside the task's
    /// folders. Only a regular file is copied, and it is opened without waiting, so a pipe cannot hold the open.
    /// Chromium reads the copy, which nothing can change before the page takes it. The copy keeps the file's
    /// name, in a folder of its own under `folder`. It reads and writes the disk: run it off the main thread.
    static func privateCopy(of path: String, roots: [URL], in folder: URL) throws -> String {
        #if os(Windows)
        // Opening one folder at a time without following a link needs the Windows layer
        // (FILE_FLAG_OPEN_REPARSE_POINT); until it has that, nothing is copied.
        throw BrowserAgentToolError("Yardlet cannot hand \(path) to the page on this platform yet.")
        #else
        guard let real = canonicalPath(path),
              roots.compactMap({ canonicalPath($0.path(percentEncoded: false)) })
                .contains(where: { contains(URL(filePath: $0), URL(filePath: real)) }) else {
            throw BrowserAgentToolError("\(path) is outside this task's project folders.", outsideFolders(retry: .withChanges))
        }
        let parts = real.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw BrowserAgentToolError("\(path) is not a file.") }
        var directory = open("/", O_RDONLY | O_DIRECTORY)
        for part in parts.dropLast() where directory >= 0 {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(directory)
            directory = next
        }
        let source = directory >= 0 ? openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) : -1
        if directory >= 0 { close(directory) }
        guard source >= 0 else {
            throw BrowserAgentToolError("\(path) changed while it was being read; try again.")
        }
        let input = FileHandle(fileDescriptor: source, closeOnDealloc: true)
        var status = stat()
        guard fstat(source, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw BrowserAgentToolError("\(path) is not a file.")
        }
        let place = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copy = place.appending(path: name)
        guard FileManager.default.createFile(atPath: copy.path(percentEncoded: false), contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BrowserAgentToolError("Yardlet could not prepare \(name) for the upload.")
        }
        let output = try FileHandle(forWritingTo: copy)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        return copy.path(percentEncoded: false)
        #endif
    }

    /// The path with every link and `..` resolved by the system, `/private` included; nil when it does not exist.
    static func canonicalPath(_ path: String) -> String? {
        CanonicalPath.resolve(path)
    }

    /// The file a `file:` address opens, as a real path: read as Chromium reads it (tabs and line breaks dropped,
    /// "\" as "/", no host, query or fragment, escapes decoded, `..` taken out), with symbolic links resolved as
    /// far as the path exists. Nil for an address of another scheme.
    static func realPath(ofFileAddress address: String) -> String? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines).filter { !"\t\n\r".contains($0) }
        guard BrowserURLPolicy.scheme(of: value) == "file" else { return nil }
        var rest = Substring(value.dropFirst("file:".count).replacingOccurrences(of: "\\", with: "/"))
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            rest = rest[(rest.firstIndex(of: "/") ?? rest.endIndex)...]
        }
        let encoded = String(rest.prefix { $0 != "?" && $0 != "#" })
        let path = encoded.removingPercentEncoding ?? encoded
        let url = URL(filePath: path.hasPrefix("/") ? path : "/" + path).standardizedFileURL
        // A path that does not exist yet still resolves through the folders it names.
        var existing = url, missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }.path(percentEncoded: false)
    }

    /// Whether a real path is in one of the task's folders, as `resolve` reads them.
    static func isInside(_ path: String, roots: [URL]) -> Bool {
        let candidate = URL(filePath: path)
        return roots.contains { contains($0.standardizedFileURL.resolvingSymlinksInPath(), candidate) }
    }

    /// Compares whole path components, so `/work/app` does not contain `/work/application`.
    static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = candidate.pathComponents
        return components.count >= rootComponents.count && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}
