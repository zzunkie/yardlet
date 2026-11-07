import Foundation

enum RuntimeProcessEnvironment {
    /// The app's own environment, with `PATH` as the person's login shell sets it once that has been
    /// read (`LoginShellPath`): the shell's folders first, then any of the app's it lacks. The base
    /// of every program Yardlet starts, agents included.
    static var app: [String: String] {
        withLoginShellPath(LoginShellPath.value, base: ProcessInfo.processInfo.environment)
    }

    static func withLoginShellPath(_ loginPath: String?, base: [String: String]) -> [String: String] {
        guard let loginPath else { return base }
        var values = base
        var seen = Set<String>()
        values["PATH"] = (loginPath.split(separator: ":") + (base["PATH"] ?? "").split(separator: ":"))
            .filter { seen.insert(String($0)).inserted }
            .joined(separator: ":")
        return values
    }

    static func values(
        executableURL: URL,
        base: [String: String] = app,
        overrides: [String: String] = [:],
        lookup: ExecutableLookup = .current
    ) -> [String: String] {
        var values = lookup.normalized(base)
        let preferredPaths = lookup.isWindows
            ? windowsPreferredPaths(executableURL: executableURL, base: base, lookup: lookup)
            : posixPreferredPaths(executableURL: executableURL, base: base)
        let existingPaths = lookup.folders(in: lookup.searchPath(in: base))
            .map { normalizedPath($0, lookup: lookup) }
        var seen = Set<String>()
        lookup.set("PATH", to: (preferredPaths + existingPaths)
            .filter { !$0.isEmpty && seen.insert(lookup.isWindows ? $0.lowercased() : $0).inserted }
            .joined(separator: lookup.separator), in: &values)
        if CLIRuntimeOverrides.isYardletCopy(executableURL) {
            // An earlier version Yardlet kept after an update failed its check must stay that
            // version: its own updater would replace it with the one that failed.
            lookup.set("AGY_CLI_DISABLE_AUTO_UPDATE", to: "true", in: &values)
            lookup.set("DISABLE_AUTOUPDATER", to: "1", in: &values)
        }
        for (name, value) in overrides {
            lookup.set(name, to: value, in: &values)
        }
        return accountScoped(values, lookup: lookup)
    }

    /// The runtime's own folder, the folders installers put programs in and the system's, ahead of `PATH`.
    private static func posixPreferredPaths(executableURL: URL, base: [String: String]) -> [String] {
        let home = base["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return [
            executableURL.deletingLastPathComponent().path(percentEncoded: false),
            URL(filePath: home).appending(path: ".local/bin").path(percentEncoded: false),
            URL(filePath: home).appending(path: ".bun/bin").path(percentEncoded: false),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].map { normalizedPath($0) }
    }

    /// On Windows, the runtime's own folder, then where Claude Code's installer, bun and npm put programs
    /// (`%USERPROFILE%\.local\bin`, `%USERPROFILE%\.bun\bin`, `%APPDATA%\npm`), ahead of `Path`, which on
    /// Windows already holds the system's folders.
    private static func windowsPreferredPaths(executableURL: URL, base: [String: String],
                                              lookup: ExecutableLookup) -> [String] {
        let home = normalizedPath(lookup.homePath(in: base)
            ?? lookup.nativePath(FileManager.default.homeDirectoryForCurrentUser), lookup: lookup)
        var paths = [lookup.nativePath(executableURL.deletingLastPathComponent()), home + "\\.local\\bin", home + "\\.bun\\bin"]
        if let appData = lookup.value(of: "APPDATA", in: base), !appData.isEmpty {
            paths.append(normalizedPath(appData, lookup: lookup) + "\\npm")
        }
        return paths.map { normalizedPath($0, lookup: lookup) }
    }

    /// Where Yardlet looks for a program a GUI app's `PATH` does not have, as a person's shell
    /// would find it: the package managers' own folders, Homebrew, nvm's Node versions newest
    /// first, Docker Desktop, then `path` (with the login shell's folders once read) and the system. Harness runtimes and connector programs
    /// are both looked for here. Windows has its own folders (`windowsSearchDirectories`).
    static func searchDirectories(home: URL,
                                  path: String = ExecutableLookup.current.searchPath(in: RuntimeProcessEnvironment.app),
                                  fileManager: FileManager = .default, lookup: ExecutableLookup = .current) -> [URL] {
        if lookup.isWindows {
            return windowsSearchDirectories(home: home, path: path, environment: ProcessInfo.processInfo.environment,
                                            lookup: lookup)
        }
        // `.claude/local` is Claude Code's older local install, which a shell alias alone reaches.
        var directories = [".local/bin", ".bun/bin", ".volta/bin", ".cargo/bin", ".deno/bin", ".npm-global/bin",
                           "Library/pnpm", ".asdf/shims", ".local/share/mise/shims", ".claude/local"]
            .map { home.appending(path: $0) }
        directories += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0) }
        let nvm = home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        let versions = ((try? fileManager.contentsOfDirectory(atPath: nvm.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix("v") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        directories += versions.map { nvm.appending(path: "\($0)/bin") }
        directories.append(URL(filePath: "/Applications/Docker.app/Contents/Resources/bin"))
        directories += path.split(separator: ":").map { URL(filePath: String($0)) }
        directories += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { URL(filePath: $0) }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path(percentEncoded: false)).inserted }
    }

    /// On Windows, the folders installers put programs in, which `Path` may not reach (a program installed
    /// after Yardlet started): Claude Code's installer's `.local\bin`, bun's, npm's global folder
    /// (`%APPDATA%\npm`), pnpm's (`%LOCALAPPDATA%\pnpm`), Cargo's, Deno's and Scoop's shims, then `path`,
    /// which holds the system's folders.
    private static func windowsSearchDirectories(home: URL, path: String, environment: [String: String],
                                                 lookup: ExecutableLookup) -> [URL] {
        var directories = [".local/bin", ".bun/bin"].map { home.appending(path: $0) }
        if let appData = lookup.value(of: "APPDATA", in: environment), !appData.isEmpty {
            directories.append(URL(filePath: appData).appending(path: "npm"))
        }
        if let localAppData = lookup.value(of: "LOCALAPPDATA", in: environment), !localAppData.isEmpty {
            directories.append(URL(filePath: localAppData).appending(path: "pnpm"))
        }
        directories += [".cargo/bin", ".deno/bin", "scoop/shims"].map { home.appending(path: $0) }
        directories += lookup.folders(in: path).map { URL(filePath: $0) }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path(percentEncoded: false).lowercased()).inserted }
    }

    static func accountScoped(_ environment: [String: String], lookup: ExecutableLookup = .current) -> [String: String] {
        guard lookup.value(of: "YARDLET_ACCOUNT_ENVIRONMENT", in: environment) == "isolated" else { return environment }
        let removed: Set<String> = [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
            "OPENAI_CODEX_OAUTH_TOKEN", "OPENROUTER_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
            "XAI_API_KEY", "AZURE_OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE",
            "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT"
        ]
        // Windows reads a variable's name in any case.
        return environment.filter { !removed.contains(lookup.isWindows ? $0.key.uppercased() : $0.key) }
    }

    /// `path` without a trailing separator, except where it is the root (`/`, on Windows `C:\`).
    private static func normalizedPath(_ path: String, lookup: ExecutableLookup = .posix) -> String {
        guard lookup.isWindows else {
            guard path.count > 1, path.hasSuffix("/") else { return path }
            return String(path.dropLast())
        }
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.last == "\\" || trimmed.last == "/",
              !(trimmed.count == 3 && trimmed.dropFirst().first == ":") {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }
}
