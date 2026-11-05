import Foundation

/// How this platform names, finds and recognizes the programs Yardlet starts (docs/PLATFORM_PORTABILITY.md,
/// "Paths and executable lookup"). macOS and Linux keep POSIX's rules: `PATH` split at `:`, `HOME` as the home
/// folder, and a program is a file that may be executed. Windows has its own: variable names are the same in
/// any case, the search path is `Path` split at `;`, the home folder is `USERPROFILE`, and a name without a
/// program's extension is tried with each of PATHEXT's that Windows starts, a program's (`.exe`, `.com`)
/// before a batch file's (`.cmd`, `.bat`), which Yardlet starts only as npm's shims (`NPMCommandShim`).
struct ExecutableLookup: Equatable, Sendable {
    /// Windows' rules rather than POSIX's.
    let isWindows: Bool
    /// On Windows, the extensions a name is tried with, lowercased, a program's before a batch file's.
    let extensions: [String]

    static let posix = ExecutableLookup(isWindows: false, extensions: [])

    /// Windows' rules with the extensions `pathExtensions` (PATHEXT's value) lists that Windows starts, or
    /// Windows' own list without one.
    static func windows(pathExtensions: String? = nil) -> ExecutableLookup {
        let listed = (pathExtensions ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let ordered = listed.filter { programExtensions.contains($0) } + listed.filter { batchExtensions.contains($0) }
        var seen = Set<String>()
        let extensions = ordered.filter { seen.insert($0).inserted }
        return ExecutableLookup(isWindows: true, extensions: extensions.isEmpty ? [".com", ".exe", ".bat", ".cmd"] : extensions)
    }

    /// This platform's rules.
    static let current: ExecutableLookup = {
        #if os(Windows)
        return .windows(pathExtensions: ExecutableLookup.windows().value(of: "PATHEXT", in: ProcessInfo.processInfo.environment))
        #else
        return .posix
        #endif
    }()

    private static let programExtensions: Set<String> = [".exe", ".com"]
    private static let batchExtensions: Set<String> = [".cmd", ".bat"]

    /// The same rules with programs only, no batch files.
    var programsOnly: ExecutableLookup {
        ExecutableLookup(isWindows: isWindows, extensions: extensions.filter { Self.programExtensions.contains($0) })
    }

    /// What separates the folders of a search path.
    var separator: String { isWindows ? ";" : ":" }

    /// The name the search path is kept under: on Windows `Path`, as Windows writes it and as Foundation's
    /// `Process` looks for it, adding the app's own `Path` to a child's environment without one in that case.
    var pathName: String { isWindows ? "Path" : "PATH" }

    /// The variable `name` in `environment`; on Windows in whichever case it is written, the first name in
    /// code-point order when there are several.
    func value(of name: String, in environment: [String: String]) -> String? {
        guard isWindows else { return environment[name] }
        let upper = name.uppercased()
        return environment.filter { $0.key.uppercased() == upper }.min { $0.key < $1.key }?.value
    }

    /// The search path `environment` holds, or an empty one.
    func searchPath(in environment: [String: String]) -> String {
        value(of: "PATH", in: environment) ?? ""
    }

    /// The home folder `environment` names: `HOME`, on Windows `USERPROFILE`; nil when it is missing or empty.
    func homePath(in environment: [String: String]) -> String? {
        value(of: isWindows ? "USERPROFILE" : "HOME", in: environment).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The folders of the search path `path`, in order.
    func folders(in path: String) -> [String] {
        path.split(separator: isWindows ? ";" : ":").map(String.init)
    }

    /// Sets the variable `name`; on Windows it replaces the variable in whatever case it was written, and the
    /// search path is named `Path`.
    func set(_ name: String, to value: String, in environment: inout [String: String]) {
        guard isWindows else {
            environment[name] = value
            return
        }
        let upper = name.uppercased()
        for key in environment.keys.filter({ $0.uppercased() == upper }) {
            environment[key] = nil
        }
        environment[upper == "PATH" ? pathName : name] = value
    }

    /// `environment` with each variable once: on Windows, names that differ only in case are one variable,
    /// kept with the value of the first in code-point order, and the search path is named `Path`.
    func normalized(_ environment: [String: String]) -> [String: String] {
        guard isWindows else { return environment }
        var result: [String: String] = [:]
        var seen = Set<String>()
        for key in environment.keys.sorted() where seen.insert(key.uppercased()).inserted {
            result[key.uppercased() == "PATH" ? pathName : key] = environment[key]
        }
        return result
    }

    /// `url`'s path as this platform writes it; on Windows with `\` and the drive letter first (`C:\Users`),
    /// where a file URL's path is `/C:/Users`.
    func nativePath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard isWindows else { return path }
        let start = Array(path.utf8.prefix(3))
        let drive = start.count == 3 && start[0] == UInt8(ascii: "/") && start[2] == UInt8(ascii: ":")
            && ((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(start[1]) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(start[1]))
        return String(path.dropFirst(drive ? 1 : 0)).replacingOccurrences(of: "/", with: "\\")
    }

    /// The program `url` names, or nil when there is none: `url` itself when it is one, and on Windows, for a
    /// name without one of `extensions`, the first file found with one added (`claude` is `claude.exe`).
    func program(at url: URL, fileManager: FileManager = .default) -> URL? {
        guard isWindows else {
            return fileManager.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        if !url.pathExtension.isEmpty, extensions.contains("." + url.pathExtension.lowercased()) {
            return Self.isFile(url, fileManager) ? url : nil
        }
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return extensions.lazy.map { folder.appending(path: name + $0) }.first { Self.isFile($0, fileManager) }
    }

    /// Whether `url` names a program (`program(at:)`).
    func isProgram(_ url: URL, fileManager: FileManager = .default) -> Bool {
        program(at: url, fileManager: fileManager) != nil
    }

    /// The first program named `name` in the folders of the search path `path`.
    func find(_ name: String, inSearchPath path: String, fileManager: FileManager = .default) -> URL? {
        folders(in: path).lazy
            .compactMap { program(at: URL(filePath: $0).appending(path: name), fileManager: fileManager) }
            .first
    }

    /// Whether `url` is a Windows batch file, which `CreateProcessW` would start through `cmd.exe`.
    func isBatchFile(_ url: URL) -> Bool {
        isWindows && Self.batchExtensions.contains("." + url.pathExtension.lowercased())
    }

    private static func isFile(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
