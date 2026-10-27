import Foundation
import Observation

/// The runtime each harness's new tasks start with. One the person chose (Settings › Harnesses ›
/// Choose…) stays until they choose another. Any other harness uses the newest version among the
/// installs found on this Mac, as the Codex and Claude apps run their newest bundled runtime: the
/// version read when the file changed (`RuntimeVersionCache`), and among equal or unreadable
/// versions the first in candidate order. A task keeps the runtime it was created with.
@MainActor
@Observable
final class RuntimeSelectionStore {
    /// A runtime found on this Mac and the version it reports.
    struct Install: Equatable, Sendable {
        let url: URL
        let version: String
    }

    private(set) var selectedURLs: [HarnessKind: URL]
    /// For a harness whose runtime the person chose, a newer install found elsewhere; Settings ›
    /// CLI Updates offers it. Filled by `findNewest()`.
    private(set) var newerInstalls: [HarnessKind: Install] = [:]
    /// The harnesses whose runtime the person chose.
    @ObservationIgnored private var chosen: Set<HarnessKind>
    private let defaults: UserDefaults
    private let discoversRuntimes: Bool
    private let candidates: @Sendable (HarnessKind) -> [URL]
    private let versions: RuntimeVersionCache

    init(
        defaults: UserDefaults = .yardlet,
        discoversRuntimes: Bool = true,
        loadsPersistedSelections: Bool = true,
        candidates: @escaping @Sendable (HarnessKind) -> [URL] = { RuntimeSelectionStore.candidates(for: $0) },
        versions: RuntimeVersionCache? = nil
    ) {
        self.defaults = defaults
        self.discoversRuntimes = discoversRuntimes
        self.candidates = candidates
        let versions = versions ?? RuntimeVersionCache(defaults: defaults)
        self.versions = versions
        if loadsPersistedSelections {
            for harness in HarnessCatalog.retired { defaults.removeObject(forKey: Self.key(for: harness)) }
        }
        var selections: [HarnessKind: URL] = [:]
        var chosen: Set<HarnessKind> = []
        for harness in HarnessCatalog.builtIns.map(\.id) {
            if loadsPersistedSelections,
               let path = defaults.string(forKey: Self.key(for: harness)) {
                let url = URL(filePath: path).standardizedFileURL
                if FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)),
                   Self.isCompatibleRuntime(url, for: harness) {
                    selections[harness] = url
                    chosen.insert(harness)
                    continue
                }
                // A desktop app that bundles the chosen runtime may have moved it; the choice
                // follows the runtime instead of silently falling back to another install.
                if let moved = RuntimeRelocation.successor(of: url, for: harness),
                   Self.isCompatibleRuntime(moved, for: harness) {
                    selections[harness] = moved
                    chosen.insert(harness)
                    defaults.set(moved.path(percentEncoded: false), forKey: Self.key(for: harness))
                    continue
                }
                defaults.removeObject(forKey: Self.key(for: harness))
            }
            // The versions read at an earlier launch, without running anything; `findNewest()`
            // reads the installs that changed since.
            if discoversRuntimes,
               let newest = Self.newest(of: Self.installs(candidates(harness), for: harness), version: versions.cachedVersion(of:)) {
                selections[harness] = newest
            }
        }
        self.selectedURLs = selections
        self.chosen = chosen
    }

    func selectedURL(for harness: HarnessKind) -> URL? {
        guard let url = selectedURLs[harness], Self.isCompatibleRuntime(url, for: harness) else { return nil }
        if FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) { return url }
        // A desktop app replaced the runtime it bundles while Yardlet ran (Claude Desktop deletes the
        // previous version on update): the choice follows it, as on the next launch.
        guard let moved = RuntimeRelocation.successor(of: url, for: harness), Self.isCompatibleRuntime(moved, for: harness) else { return nil }
        return moved
    }

    var connectedDescriptors: [HarnessDescriptor] {
        HarnessCatalog.builtIns.filter { selectedURL(for: $0.id) != nil }
    }

    /// The person's choice: kept until they choose another, whatever newer install appears.
    func select(_ url: URL, for harness: HarnessKind) {
        let standardized = url.standardizedFileURL
        guard Self.isCompatibleRuntime(standardized, for: harness) else {
            return
        }
        selectedURLs[harness] = standardized
        chosen.insert(harness)
        newerInstalls[harness] = nil
        defaults.set(
            standardized.path(percentEncoded: false),
            forKey: Self.key(for: harness)
        )
    }

    /// Drops the person's choice for `harness`, so its new tasks use the newest install again:
    /// the newer one Settings offered, and later whichever install is newest.
    func useNewest(for harness: HarnessKind) {
        guard let newer = newerInstalls[harness] else { return }
        chosen.remove(harness)
        defaults.removeObject(forKey: Self.key(for: harness))
        selectedURLs[harness] = newer.url
        newerInstalls[harness] = nil
    }

    /// Reads the versions of each harness's installs, off the main thread and each file only when
    /// it changed, and points every harness whose runtime the person did not choose at its newest
    /// install. For one the person chose, a newer install elsewhere goes to `newerInstalls`; the
    /// choice stays. Called at launch and when Settings › CLI Updates opens.
    func findNewest() async {
        guard discoversRuntimes else { return }
        // Each harness's installs, the chosen runtime first where the person chose one.
        var lookups: [HarnessKind: (installs: [URL], chosen: Bool)] = [:]
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let isChosen = chosen.contains(harness)
            var installs = Self.installs(candidates(harness), for: harness)
            if isChosen {
                guard let selected = selectedURL(for: harness) else { continue }
                installs = Self.installs([selected] + installs, for: harness)
            }
            if installs.count > 1 {
                lookups[harness] = (installs, isChosen)
            } else if isChosen {
                if newerInstalls[harness] != nil { newerInstalls[harness] = nil }
            } else if let only = installs.first, selectedURLs[harness] != only {
                // The only install is the only choice: no version to read.
                selectedURLs[harness] = only
            }
        }
        let versions = self.versions
        let read = await withTaskGroup(of: (URL, String?).self) { group in
            for url in Set(lookups.values.flatMap(\.installs)) {
                group.addTask { (url, await versions.version(of: url)) }
            }
            var read: [URL: String] = [:]
            for await (url, version) in group { read[url] = version }
            return read
        }
        // A runtime the person chose or dropped meanwhile is theirs: it is left as it is now.
        for (harness, lookup) in lookups where chosen.contains(harness) == lookup.chosen {
            if lookup.chosen {
                guard selectedURL(for: harness) == lookup.installs[0] else { continue }
                var newer: Install?
                if let current = read[lookup.installs[0]],
                   let newest = Self.newest(of: Array(lookup.installs.dropFirst()), version: { read[$0] }),
                   let version = read[newest], CLIVersion.isNewer(version, than: current) {
                    newer = Install(url: newest, version: version)
                }
                if newerInstalls[harness] != newer { newerInstalls[harness] = newer }
            } else if let newest = Self.newest(of: lookup.installs, version: { read[$0] }), selectedURLs[harness] != newest {
                selectedURLs[harness] = newest
            }
        }
    }

    private static func key(for harness: HarnessKind) -> String {
        "runtime.\(harness.rawValue).executablePath"
    }

    /// Where `harness` may be installed, in the order that breaks a tie between equal versions:
    /// installs the person manages before a desktop app's bundle (Codex), the Claude app's newest
    /// version first (Claude Code). The installs the person manages are looked for where their
    /// shell would find them, not only in Yardlet's own `PATH` (`installedPrograms(named:home:)`).
    nonisolated static func candidates(
        for harness: HarnessKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        if harness == .codex {
            return codexCandidates(home: home)
        } else if harness == .claudeCode {
            return claudeDesktopCandidates(home: home) + installedPrograms(named: "claude", home: home)
        } else if harness == .museCode {
            // `muse` is a generic executable name. Auto-discover only Meta's
            // documented installer location; a custom binary can still be
            // selected explicitly in Harness Center.
            return [home.appending(path: ".local/bin/muse")]
        } else if let descriptor = HarnessCatalog.descriptor(for: harness) {
            return descriptor.relativeExecutablePaths.map {
                append(relativePath: $0, to: home)
            } + installedPrograms(named: descriptor.executableName, home: home)
        }
        return []
    }

    /// The executable, compatible installs among `urls`, in their order, each file once (a link
    /// and the file it leads to are one install; the first path that names it is kept).
    nonisolated static func installs(_ urls: [URL], for harness: HarnessKind) -> [URL] {
        var files: Set<String> = []
        return urls.map(\.standardizedFileURL).filter { url in
            guard isCompatibleRuntime(url, for: harness),
                  FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else { return false }
            return files.insert(url.resolvingSymlinksInPath().path(percentEncoded: false)).inserted
        }
    }

    /// The newest of `installs` by the version each reports; an install whose version is unknown
    /// loses to one whose version is known, and among equals the first in order wins.
    nonisolated static func newest(of installs: [URL], version: (URL) -> String?) -> URL? {
        var best: (url: URL, version: String?)?
        for url in installs {
            let found = version(url)
            guard let current = best else {
                best = (url, found)
                continue
            }
            if let found, current.version.map({ CLIVersion.isNewer(found, than: $0) }) ?? true {
                best = (url, found)
            }
        }
        return best?.url
    }

    /// The legacy `antigravity` executable is an IDE launcher. The supported
    /// structured headless runtime is the official `agy` CLI.
    nonisolated static func isCompatibleRuntime(_ url: URL, for harness: HarnessKind) -> Bool {
        if harness == .antigravityCLI {
            return url.lastPathComponent == "agy"
        }
        return true
    }

    /// Installs the person manages before the ChatGPT app's bundled runtime. Since 2026-10-27 the
    /// newest version wins and this order only breaks a tie (product document 13.100).
    nonisolated static func codexCandidates(
        home: URL,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        installedPrograms(named: "codex", home: home, searchPath: searchPath)
            + RuntimeRelocation.chatGPTCodexLayouts(inAppAt: URL(filePath: "/Applications/ChatGPT.app"))
    }

    nonisolated static func claudeDesktopCandidates(
        home: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let versionsRoot = home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Claude", directoryHint: .isDirectory)
            .appending(path: "claude-code", directoryHint: .isDirectory)
        return RuntimeRelocation.claudeDesktopLayouts(inVersionsRoot: versionsRoot, fileManager: fileManager)
    }

    /// `executable` in each folder a person's own install may be in: a GUI launch's `PATH` has only
    /// the system's folders, so the package managers' folders (nvm, Volta, bun, pnpm, …) and
    /// Homebrew come first, then `searchPath` (`RuntimeProcessEnvironment.searchDirectories`).
    nonisolated private static func installedPrograms(
        named executable: String,
        home: URL,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        RuntimeProcessEnvironment.searchDirectories(home: home, path: searchPath)
            .map { $0.appending(path: executable) }
    }

    nonisolated private static func append(relativePath: String, to root: URL) -> URL {
        relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appending(path: String(component))
        }
    }
}
