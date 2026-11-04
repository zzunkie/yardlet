import Foundation

/// How a harness CLI was installed, which decides how Yardlet checks it for updates, updates it, and
/// keeps the version before an update available (product document 13.22). Read from where the
/// selected runtime's path leads once symbolic links are followed; nothing is run to detect it.
enum CLIInstallMethod: Equatable, Sendable {
    /// `<prefix>/Cellar/<name>/<version>/…`, updated with `brew upgrade --formula`.
    case homebrewFormula(name: String, brew: URL)
    /// `<prefix>/Caskroom/<token>/<version>/…`, updated with `brew upgrade --cask`.
    case homebrewCask(token: String, brew: URL, versionDirectory: URL)
    /// `<prefix>/lib/node_modules/<package>/…`, updated with `npm install --global`.
    case npmGlobal(package: String, npm: URL, packageDirectory: URL)
    /// The CLI's own updater (`agy update`, `claude update`, …).
    case selfUpdater(CLISelfUpdater)
    /// Inside a desktop app, which replaces it on its own schedule.
    case appBundled(appName: String)
    /// Anything else: the person updates it.
    case manual

    /// Whether Yardlet can run an update for this install.
    var canUpdate: Bool {
        switch self {
        case .homebrewFormula, .homebrewCask, .npmGlobal, .selfUpdater: true
        case .appBundled, .manual: false
        }
    }

    var displayText: String {
        switch self {
        case let .homebrewFormula(name, _): L10n.format("Homebrew formula %@", name)
        case let .homebrewCask(token, _, _): L10n.format("Homebrew cask %@", token)
        case let .npmGlobal(package, _, _): L10n.format("npm global package %@", package)
        case let .selfUpdater(updater): L10n.format("Updates itself (%@)", updater.commandText)
        case let .appBundled(app): L10n.format("Comes with the %@ app", app)
        case .manual: L10n.string("Installed by hand")
        }
    }
}

/// A CLI that updates itself, and what its installer leaves behind.
struct CLISelfUpdater: Equatable, Sendable {
    enum Kind: String, Sendable {
        case antigravity, claudeNative, cursor, grok, openCode, hermes
    }

    let kind: Kind
    /// The update command after the executable.
    let updateArguments: [String]
    /// A check that installs nothing, when the CLI has one (`grok update --check --json`).
    let checkArguments: [String]?
    /// How the version before an update stays available.
    let retention: CLIPreviousVersionRetention

    var commandText: String {
        let name = switch kind {
        case .antigravity: "agy"
        case .claudeNative: "claude"
        case .cursor: "cursor-agent"
        case .grok: "grok"
        case .openCode: "opencode"
        case .hermes: "hermes"
        }
        return ([name] + updateArguments).joined(separator: " ")
    }
}

/// How the version before an update stays available for Yardlet to go back to.
enum CLIPreviousVersionRetention: Equatable, Sendable {
    /// The installer keeps earlier versions beside the new one (a versions folder, or Homebrew's
    /// Cellar while `HOMEBREW_NO_INSTALL_CLEANUP` is set), so the old path still runs.
    case installerKeepsEarlierVersions
    /// The installer replaces it, so Yardlet copies `root` first (an APFS clone on one volume).
    /// `executable` is the runtime inside `root`, or `root` itself for a single file.
    case yardletCopy(root: URL, executable: URL)
    /// Neither: an update could not be undone, so Yardlet does not update it automatically.
    case none
}

enum CLIInstallDetector {
    /// The install behind `executable`, the selected runtime of `harness`.
    static func detect(
        harness: HarnessKind,
        executable: URL,
        fileManager: FileManager = .default
    ) -> CLIInstallMethod {
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        func url(_ parts: ArraySlice<String>) -> URL {
            URL(filePath: NSString.path(withComponents: Array(parts)))
        }
        func executableFile(_ url: URL) -> URL? {
            fileManager.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
        }

        // Claude's desktop app keeps its Claude Code under Application Support, inside a
        // `claude.app` of its own; the app that replaces it is Claude, not that inner bundle.
        if let index = components.lastIndex(of: "claude-code"), index > 0, components[index - 1] == "Claude" {
            return .appBundled(appName: "Claude")
        }
        if let app = components.firstIndex(where: { $0.hasSuffix(".app") }),
           components.indices.contains(app + 1), components[app + 1] == "Contents" {
            return .appBundled(appName: String(components[app].dropLast(4)))
        }
        if let index = components.lastIndex(of: "Caskroom"), index > 0, components.count > index + 3,
           let brew = executableFile(url(components[..<index]).appending(path: "bin/brew")) {
            return .homebrewCask(token: components[index + 1], brew: brew,
                versionDirectory: url(components[...(index + 2)]))
        }
        if let index = components.lastIndex(of: "Cellar"), index > 0, components.count > index + 3,
           let brew = executableFile(url(components[..<index]).appending(path: "bin/brew")) {
            return .homebrewFormula(name: components[index + 1], brew: brew)
        }
        if let index = components.firstIndex(of: "node_modules"), index > 1, components[index - 1] == "lib",
           components.count > index + 1 {
            let scoped = components[index + 1].hasPrefix("@")
            let end = scoped ? index + 2 : index + 1
            if components.count > end,
               let npm = executableFile(url(components[..<(index - 1)]).appending(path: "bin/npm")) {
                let package = components[(index + 1)...end].joined(separator: "/")
                return .npmGlobal(package: package, npm: npm, packageDirectory: url(components[...end]))
            }
        }
        return selfUpdater(harness: harness, resolved: resolved, components: components).map(CLIInstallMethod.selfUpdater)
            ?? .manual
    }

    /// The executable inside a copy of `root`, for a cask's version directory or an npm package.
    static func executable(_ resolved: URL, inside root: URL) -> URL {
        let rootComponents = root.pathComponents
        let components = resolved.pathComponents
        guard components.starts(with: rootComponents) else { return root }
        return components.dropFirst(rootComponents.count).reduce(root) { $0.appending(path: $1) }
    }

    private static func selfUpdater(harness: HarnessKind, resolved: URL, components: [String]) -> CLISelfUpdater? {
        func parent(_ offset: Int) -> String? {
            components.indices.contains(components.count - 1 - offset) ? components[components.count - 1 - offset] : nil
        }
        switch harness {
        case .antigravityCLI where resolved.lastPathComponent == "agy":
            // One file that `agy update` replaces in place.
            return CLISelfUpdater(kind: .antigravity, updateArguments: ["update"], checkArguments: nil,
                retention: .yardletCopy(root: resolved, executable: resolved))
        case .claudeCode where parent(1) == "versions" && parent(2) == "claude":
            // The native installer: `~/.local/share/claude/versions/<version>`, earlier ones kept.
            return CLISelfUpdater(kind: .claudeNative, updateArguments: ["update"], checkArguments: nil,
                retention: .installerKeepsEarlierVersions)
        case .cursorAgent where parent(2) == "versions" && parent(3) == "cursor-agent":
            // `~/.local/share/cursor-agent/versions/<version>/cursor-agent`, earlier ones kept.
            return CLISelfUpdater(kind: .cursor, updateArguments: ["update"], checkArguments: nil,
                retention: .installerKeepsEarlierVersions)
        case .grokBuild where parent(1) == "downloads" && parent(2) == ".grok":
            // `~/.grok/downloads/grok-<version>-<platform>`, earlier ones kept.
            return CLISelfUpdater(kind: .grok, updateArguments: ["update"], checkArguments: ["update", "--check", "--json"],
                retention: .installerKeepsEarlierVersions)
        case .openCode where parent(1) == "bin" && parent(2) == ".opencode":
            return CLISelfUpdater(kind: .openCode, updateArguments: ["upgrade"], checkArguments: nil,
                retention: .yardletCopy(root: resolved, executable: resolved))
        case .hermes where components.contains("hermes-agent") && parent(1) == "bin" && parent(2) == "venv":
            // A git checkout with a virtual environment: no copy runs elsewhere, so no going back.
            return CLISelfUpdater(kind: .hermes, updateArguments: ["update"], checkArguments: nil, retention: .none)
        default:
            return nil
        }
    }
}
