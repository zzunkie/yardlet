import CryptoKit
import Darwin
import Foundation

struct CodexEnvironmentPaths: Equatable, Sendable {
    let nativeHomeURL: URL
    let yardletRootURL: URL

    var harnessRootURL: URL {
        yardletRootURL
            .appending(path: "harnesses", directoryHint: .isDirectory)
            .appending(path: "codex", directoryHint: .isDirectory)
    }

    var runtimeHomeURL: URL {
        harnessRootURL.appending(path: "home", directoryHint: .isDirectory)
    }

    var overlayURL: URL {
        harnessRootURL.appending(path: "overlay", directoryHint: .isDirectory)
    }

    var manifestURL: URL {
        harnessRootURL.appending(path: "environment-snapshot.json")
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexEnvironmentPaths {
        let yardletRoot = environment["YARDLET_HOME"].flatMap {
            Self.expandedURL($0, homeURL: homeURL)
        }
            ?? homeURL.appending(path: ".yardlet", directoryHint: .isDirectory)
        let nativeHome = environment["YARDLET_NATIVE_CODEX_HOME"].flatMap {
            Self.expandedURL($0, homeURL: homeURL)
        } ?? environment["CODEX_HOME"].flatMap {
            Self.expandedURL($0, homeURL: homeURL)
        }
            ?? homeURL.appending(path: ".codex", directoryHint: .isDirectory)
        return CodexEnvironmentPaths(
            nativeHomeURL: nativeHome.standardizedFileURL,
            yardletRootURL: yardletRoot.standardizedFileURL
        )
    }

    private static func expandedURL(_ value: String, homeURL: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "~" { return homeURL }
        if value.hasPrefix("~/") {
            return homeURL.appending(path: String(value.dropFirst(2)))
        }
        return URL(filePath: value)
    }
}

struct CodexEnvironmentSnapshot: Codable, Equatable, Sendable {
    let sourceHomePath: String
    let runtimeHomePath: String
    let fingerprint: String
    let inheritedPaths: [String]
    let overlayPaths: [String]
    let refreshedAt: Date
}

struct CodexProcessEnvironment: @unchecked Sendable {
    let values: [String: String]
}

enum CodexEnvironmentError: Error, Equatable, Sendable {
    case sourceAndRuntimeHomesOverlap(String, String)
    case unsupportedSourceItem(String)
}

extension CodexEnvironmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .sourceAndRuntimeHomesOverlap(source, runtime):
            "Codex source and Yardlet runtime homes overlap: \(source) and \(runtime)"
        case let .unsupportedSourceItem(path):
            "Codex capability snapshot contains an unsupported item: \(path)"
        }
    }
}

/// Resolves the original Codex home and preserves the old isolated-home compatibility path.
///
/// Native launches use the original home directly. For old isolated tasks only, the snapshot
/// inherits capability paths and applies the saved Yardlet overlay. Credentials, sessions,
/// history, SQLite, logs and generated files never enter that compatibility snapshot.
actor CodexEnvironmentManager {
    static let inheritedRelativePaths = [
        "config.toml",
        "AGENTS.md",
        "AGENTS.override.md",
        "skills",
        "plugins/cache",
        "rules"
    ]

    let paths: CodexEnvironmentPaths
    private let fileManager: FileManager
    private let isolatesAccountEnvironment: Bool

    init(paths: CodexEnvironmentPaths, fileManager: FileManager = .default, isolatesAccountEnvironment: Bool = false) {
        self.isolatesAccountEnvironment = isolatesAccountEnvironment
        self.paths = paths
        self.fileManager = fileManager
    }

    func prepare() throws -> CodexEnvironmentSnapshot {
        let sourceHome = paths.nativeHomeURL.standardizedFileURL
        let runtimeHome = paths.runtimeHomeURL.standardizedFileURL
        guard !Self.pathsOverlap(sourceHome, runtimeHome) else {
            throw CodexEnvironmentError.sourceAndRuntimeHomesOverlap(
                sourceHome.path(),
                runtimeHome.path()
            )
        }

        try fileManager.createDirectory(at: paths.harnessRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.overlayURL, withIntermediateDirectories: true)

        let inherited = existingRelativePaths(in: sourceHome)
        let overlays = existingRelativePaths(in: paths.overlayURL)
        let fingerprint = try snapshotFingerprint(
            sourceHome: sourceHome,
            inherited: inherited,
            overlayHome: paths.overlayURL,
            overlays: overlays
        )

        let effectivePaths = Set(inherited).union(overlays)
        if let current = try? readManifest(),
           current.fingerprint == fingerprint,
           current.sourceHomePath == sourceHome.path(),
           current.runtimeHomePath == runtimeHome.path(),
           effectivePaths.allSatisfy({
               fileManager.fileExists(atPath: runtimeHome.appending(path: $0).path())
           }) {
            return current
        }

        let stagingRoot = paths.harnessRootURL.appending(
            path: ".environment-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        for relativePath in Self.inheritedRelativePaths {
            let inheritedSource = sourceHome.appending(path: relativePath)
            let overlaySource = paths.overlayURL.appending(path: relativePath)
            let stagedTarget = stagingRoot.appending(path: relativePath)

            if fileManager.fileExists(atPath: inheritedSource.path()) {
                try copySnapshotItem(at: inheritedSource, to: stagedTarget)
            }
            if fileManager.fileExists(atPath: overlaySource.path()) {
                try applyOverlay(at: overlaySource, to: stagedTarget)
            }
            if relativePath == "config.toml",
               fileManager.fileExists(atPath: stagedTarget.path()) {
                try isolateSQLiteHome(in: stagedTarget, runtimeHome: runtimeHome)
            }
        }

        for relativePath in Self.inheritedRelativePaths {
            let stagedTarget = stagingRoot.appending(path: relativePath)
            let runtimeTarget = runtimeHome.appending(path: relativePath)
            if fileManager.fileExists(atPath: runtimeTarget.path()) {
                try fileManager.removeItem(at: runtimeTarget)
            }
            if fileManager.fileExists(atPath: stagedTarget.path()) {
                try fileManager.createDirectory(
                    at: runtimeTarget.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: stagedTarget, to: runtimeTarget)
            }
        }

        let snapshot = CodexEnvironmentSnapshot(
            sourceHomePath: sourceHome.path(),
            runtimeHomePath: runtimeHome.path(),
            fingerprint: fingerprint,
            inheritedPaths: inherited,
            overlayPaths: overlays,
            refreshedAt: Date()
        )
        try writeManifest(snapshot)
        return snapshot
    }

    func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        scope: SessionEnvironmentScope = .native
    ) throws -> CodexProcessEnvironment {
        if scope == .yardlet, materializedSnapshot() == nil {
            _ = try prepare()
        }
        var environment = base
        environment["CODEX_HOME"] = (scope == .native
            ? paths.nativeHomeURL : paths.runtimeHomeURL).path()
        environment["YARDLET_NATIVE_CODEX_HOME"] = paths.nativeHomeURL.path()
        if isolatesAccountEnvironment { environment["YARDLET_ACCOUNT_ENVIRONMENT"] = "isolated" }
        return CodexProcessEnvironment(values: RuntimeProcessEnvironment.accountScoped(environment))
    }

    func currentSnapshot() -> CodexEnvironmentSnapshot? {
        materializedSnapshot()
    }

    private func materializedSnapshot() -> CodexEnvironmentSnapshot? {
        guard let snapshot = try? readManifest(),
              snapshot.sourceHomePath == paths.nativeHomeURL.standardizedFileURL.path(),
              snapshot.runtimeHomePath == paths.runtimeHomeURL.standardizedFileURL.path() else {
            return nil
        }
        let relativePaths = Set(snapshot.inheritedPaths).union(snapshot.overlayPaths)
        guard relativePaths.allSatisfy({
            fileManager.fileExists(atPath: paths.runtimeHomeURL.appending(path: $0).path())
        }) else { return nil }
        return snapshot
    }

    private func existingRelativePaths(in root: URL) -> [String] {
        Self.inheritedRelativePaths.filter {
            fileManager.fileExists(atPath: root.appending(path: $0).path())
        }
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        let firstComponents = first.standardizedFileURL.pathComponents
        let secondComponents = second.standardizedFileURL.pathComponents
        return isPrefix(firstComponents, of: secondComponents)
            || isPrefix(secondComponents, of: firstComponents)
    }

    private static func isPrefix(_ prefix: [String], of value: [String]) -> Bool {
        guard prefix.count <= value.count else { return false }
        return zip(prefix, value).allSatisfy { left, right in left == right }
    }

    private func copySnapshotItem(at source: URL, to destination: URL) throws {
        var ancestry = Set<String>()
        try copySnapshotItem(at: source, to: destination, ancestry: &ancestry)
    }

    private func copySnapshotItem(
        at source: URL,
        to destination: URL,
        ancestry: inout Set<String>
    ) throws {
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        if values.isSymbolicLink == true {
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path()) else {
                // Stale optional capability links are omitted instead of blocking Codex launch.
                return
            }
            let identity = resolved.path()
            guard ancestry.insert(identity).inserted else {
                throw CodexEnvironmentError.unsupportedSourceItem(source.path())
            }
            defer { ancestry.remove(identity) }
            try copySnapshotItem(at: resolved, to: destination, ancestry: &ancestry)
            return
        }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try copySnapshotItem(
                    at: child,
                    to: destination.appending(path: child.lastPathComponent),
                    ancestry: &ancestry
                )
            }
            return
        }
        guard values.isRegularFile == true else {
            throw CodexEnvironmentError.unsupportedSourceItem(source.path())
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let copied = source.path().withCString { sourcePath in
            destination.path().withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
            }
        }
        if copied != 0 {
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func applyOverlay(at source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            if fileManager.fileExists(atPath: destination.path()) {
                try fileManager.removeItem(at: destination)
            }
            try copySnapshotItem(at: source, to: destination)
            return
        }

        if !fileManager.fileExists(atPath: destination.path()) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            let target = destination.appending(path: child.lastPathComponent)
            try applyOverlay(at: child, to: target)
        }
    }

    private func isolateSQLiteHome(in configURL: URL, runtimeHome: URL) throws {
        let original = try String(contentsOf: configURL, encoding: .utf8)
        let escapedPath = runtimeHome.path().replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let replacement = "sqlite_home = \"\(escapedPath)\""
        var lines = original.components(separatedBy: .newlines)
        let rootEnd = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.endIndex
        var replaced = false
        for index in lines.indices where index < rootEnd {
            if lines[index].range(
                of: #"^\s*(?:sqlite_home|"sqlite_home"|'sqlite_home')\s*="#,
                options: .regularExpression
            ) != nil {
                lines[index] = replacement
                replaced = true
            }
        }
        if !replaced {
            lines.insert(replacement, at: rootEnd)
        }
        try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func snapshotFingerprint(
        sourceHome: URL,
        inherited: [String],
        overlayHome: URL,
        overlays: [String]
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data(sourceHome.path().utf8))
        for relativePath in inherited {
            try hashItem(sourceHome.appending(path: relativePath), relativePath: "native/\(relativePath)", into: &hasher)
        }
        for relativePath in overlays {
            try hashItem(overlayHome.appending(path: relativePath), relativePath: "overlay/\(relativePath)", into: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hashItem(
        _ url: URL,
        relativePath: String,
        into hasher: inout SHA256
    ) throws {
        var ancestry = Set<String>()
        try hashItem(url, relativePath: relativePath, into: &hasher, ancestry: &ancestry)
    }

    private func hashItem(
        _ url: URL,
        relativePath: String,
        into hasher: inout SHA256,
        ancestry: inout Set<String>
    ) throws {
        hasher.update(data: Data(relativePath.utf8))
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        if values.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path()) else {
                hasher.update(data: Data("broken-link".utf8))
                return
            }
            let identity = resolved.path()
            guard ancestry.insert(identity).inserted else {
                throw CodexEnvironmentError.unsupportedSourceItem(url.path())
            }
            defer { ancestry.remove(identity) }
            hasher.update(data: Data("resolved-link:\(identity)".utf8))
            try hashItem(
                resolved,
                relativePath: relativePath,
                into: &hasher,
                ancestry: &ancestry
            )
            return
        }
        if values.isDirectory == true {
            let children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try hashItem(
                    child,
                    relativePath: "\(relativePath)/\(child.lastPathComponent)",
                    into: &hasher,
                    ancestry: &ancestry
                )
            }
            return
        }
        if relativePath.hasPrefix("native/plugins/cache/") {
            let size = values.fileSize ?? -1
            let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? -1
            hasher.update(data: Data("size:\(size);mtime:\(modifiedAt)".utf8))
        } else {
            hasher.update(data: try Data(contentsOf: url))
        }
    }

    private func readManifest() throws -> CodexEnvironmentSnapshot {
        try JSONDecoder().decode(
            CodexEnvironmentSnapshot.self,
            from: Data(contentsOf: paths.manifestURL)
        )
    }

    private func writeManifest(_ snapshot: CodexEnvironmentSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: paths.manifestURL, options: .atomic)
    }
}
