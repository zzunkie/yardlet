import Foundation

enum GitExecutableLocator {
    static let standardPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git"
    ]

    /// Where Git for Windows' installer (and winget's and Chocolatey's, which run it) puts it for everyone, where it puts
    /// it for one person, and where Scoop puts it, under the variable that names each folder.
    static let windowsInstallPaths = [
        ("ProgramFiles", "Git\\cmd\\git.exe"),
        ("ProgramFiles(x86)", "Git\\cmd\\git.exe"),
        ("LOCALAPPDATA", "Programs\\Git\\cmd\\git.exe"),
        ("USERPROFILE", "scoop\\apps\\git\\current\\cmd\\git.exe")
    ]

    // GUI launches do not inherit the user's shell PATH. Prefer an independently
    // installed Git, without executing a shell or searching the workspace.
    static func preferredURL(
        candidates: [String] = defaultCandidates(),
        isExecutableFile: (String) -> Bool = isExecutableFile
    ) -> URL {
        URL(filePath: candidates.first(where: isExecutableFile) ?? fallbackPath)
    }

    /// This platform's places to look, in order.
    static func defaultCandidates() -> [String] {
        #if os(Windows)
        return windowsCandidates(environment: ProcessInfo.processInfo.environment)
        #else
        return standardPaths
        #endif
    }

    /// On Windows: `git.exe` in the folders of `Path` that are absolute, then Git for Windows where it is installed
    /// when `Path` does not reach it (`windowsInstallPaths`). A relative folder in `Path` would be read from wherever
    /// Yardlet runs Git, a task's folder among them, so it is not looked in.
    static func windowsCandidates(environment: [String: String], lookup: ExecutableLookup = .windows()) -> [String] {
        let rules = PathRules.windows
        let inPath = lookup.folders(in: lookup.searchPath(in: environment))
            .filter(rules.isAbsolute)
            .map { join($0, "git.exe") }
        let installed = windowsInstallPaths.compactMap { name, rest in
            lookup.value(of: name, in: environment).flatMap { rules.isAbsolute($0) ? join($0, rest) : nil }
        }
        var seen = Set<String>()
        return (inPath + installed).filter { seen.insert($0.lowercased()).inserted }
    }

    /// What Git is started as when none is found, so the failure names it.
    private static var fallbackPath: String {
        #if os(Windows)
        return "C:\\Program Files\\Git\\cmd\\git.exe"
        #else
        return "/usr/bin/git"
        #endif
    }

    /// What every Git Yardlet runs is started with: the app's environment with a harness's PATH
    /// (`RuntimeProcessEnvironment`: Git's own folder, Homebrew, `/usr/local/bin`, `~/.local/bin`),
    /// then `overrides`. Git starts programs of its own by name: Git LFS's filter on a checkout or a
    /// status, a credential helper, a signing program. A GUI launch's PATH has only the system's
    /// folders, so with it a Homebrew Git cannot find the `git-lfs` installed beside it, and a
    /// checkout in a repository with LFS files fails with "the remote end hung up unexpectedly".
    static func environment(for executableURL: URL, overrides: [String: String] = [:]) -> [String: String] {
        RuntimeProcessEnvironment.values(executableURL: executableURL, overrides: overrides)
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("\\") || folder.hasSuffix("/") ? folder + name : folder + "\\" + name
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        #if os(Windows)
        // Windows has no execute permission to read; a program is a file with a program's extension.
        return true
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }
}
