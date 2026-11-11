import Foundation

/// Desktop apps that bundle a harness runtime update it on their own schedule and may move it or
/// delete the version Yardlet chose. A saved path inside such an app names where the same runtime
/// now lives, not a runtime that is gone. Paths the user manages are never guessed.
enum RuntimeRelocation {
    /// Where the runtime recorded at `url` lives now, when `url` no longer exists and belongs to
    /// a desktop app Yardlet knows how that app lays out its bundled runtime.
    static func successor(
        of url: URL,
        for harness: HarnessKind,
        fileManager: FileManager = .default
    ) -> URL? {
        let recorded = url.standardizedFileURL
        guard !fileManager.isExecutableFile(atPath: recorded.path(percentEncoded: false)) else { return nil }
        let candidates: [URL]
        switch harness {
        case .codex:
            candidates = chatGPTCodexCandidates(near: recorded)
        case .claudeCode:
            candidates = claudeDesktopCandidates(near: recorded, fileManager: fileManager)
        default:
            candidates = []
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The Codex runtime inside a ChatGPT app bundle, newest layout first. ChatGPT moved it from
    /// `Resources/codex` to `Resources/codex-cli/bin/codex` in September 2026.
    static func chatGPTCodexLayouts(inAppAt appURL: URL) -> [URL] {
        let resources = appURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        return [
            resources.appending(path: "codex-cli/bin/codex"),
            resources.appending(path: "codex")
        ]
    }

    private static func chatGPTCodexCandidates(near recorded: URL) -> [URL] {
        guard let appURL = enclosingBundle(named: "ChatGPT.app", of: recorded) else { return [] }
        return chatGPTCodexLayouts(inAppAt: appURL).filter { $0 != recorded }
    }

    /// Claude Desktop also uses verified hash directories inside each version. Discovery and
    /// relocation must agree on both layouts, without selecting an unfinished extraction.
    static func claudeDesktopLayouts(inVersionsRoot versionsRoot: URL,
        fileManager: FileManager = .default) -> [URL] {
        guard let versions = try? fileManager.contentsOfDirectory(at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return versions.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.flatMap { version -> [URL] in
            let legacy = version.appending(path: "claude.app/Contents/MacOS/claude").standardizedFileURL
            let packages = (try? fileManager.contentsOfDirectory(at: version,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            let ready = packages.filter { package in
                guard let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let marker = try? package.appending(path: ".verified").resourceValues(forKeys: [.isRegularFileKey]),
                      marker.isRegularFile == true else { return false }
                return true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return [legacy] + ready.map { $0.appending(path: "claude.app/Contents/MacOS/claude").standardizedFileURL }
        }.filter { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// A missing app-managed choice follows the newest completed package in the same root.
    private static func claudeDesktopCandidates(near recorded: URL, fileManager: FileManager) -> [URL] {
        let components = recorded.pathComponents
        guard let index = components.lastIndex(of: "claude-code"), index > 0,
              components[index - 1] == "Claude" else { return [] }
        let versionsRoot = URL(filePath: NSString.path(withComponents: Array(components[...index])), directoryHint: .isDirectory)
        return claudeDesktopLayouts(inVersionsRoot: versionsRoot, fileManager: fileManager)
    }

    private static func enclosingBundle(named name: String, of url: URL) -> URL? {
        let components = url.pathComponents
        guard let index = components.lastIndex(of: name) else { return nil }
        return URL(filePath: NSString.path(withComponents: Array(components[...index])), directoryHint: .isDirectory)
    }
}
