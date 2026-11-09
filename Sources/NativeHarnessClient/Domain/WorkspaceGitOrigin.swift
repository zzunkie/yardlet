import Foundation

/// What Yardlet records about a task folder's Git identity when the task is created.
///
/// A task made in a linked worktree keeps its own folder as the cwd and additionally remembers
/// where that worktree came from, so the sidebar can show it under the original project instead
/// of inventing a second project for the worktree folder.
struct WorkspaceGitOrigin: Equatable, Sendable {
    /// The origin repository's toplevel folder. Only a linked worktree has one; an ordinary
    /// repository and a folder outside Git both keep this nil.
    var originWorkspacePath: String?
    /// The worktree folder's own name, set only for a linked worktree.
    var worktreeName: String?
    /// The branch HEAD points at, when it points at one. A detached HEAD keeps this nil.
    var branch: String?

    static let none = WorkspaceGitOrigin()

    var isWorktree: Bool { originWorkspacePath != nil }
    var isEmpty: Bool { originWorkspacePath == nil && worktreeName == nil && branch == nil }

    var originWorkspaceURL: URL? {
        originWorkspacePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

/// The read-only filesystem access the origin resolver needs. Injected so the rules can be
/// checked against a written-out layout without a repository on disk.
struct GitMetadataReader: Sendable {
    enum EntryKind: Equatable, Sendable {
        case file
        case directory
    }

    var kind: @Sendable (String) -> EntryKind?
    var text: @Sendable (String) -> String?

    static let live = GitMetadataReader(
        kind: { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return nil
            }
            return isDirectory.boolValue ? .directory : .file
        },
        text: { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    )
}

/// Decides whether a task folder is a linked Git worktree, and where it came from.
///
/// The decision reads Git's own on-disk records — the `.git` file's `gitdir:` line, the linked
/// directory's `commondir`, and `HEAD` — which is what `git rev-parse --git-common-dir` and
/// `--show-toplevel` report. No process is started and no shell is consulted, so creating a task
/// never waits on a runtime. Anything unreadable or unexpected resolves to nothing.
enum GitWorktreeOriginResolver {
    static func resolve(
        workspaceURL: URL,
        reader: GitMetadataReader = .live
    ) -> WorkspaceGitOrigin {
        guard let marker = repositoryMarker(from: workspaceURL, reader: reader) else {
            return .none
        }
        // An ordinary checkout keeps a `.git` directory: no origin, but a branch worth recording.
        if marker.kind == .directory {
            return WorkspaceGitOrigin(branch: branch(inGitDirectory: marker.gitPath, reader: reader))
        }
        guard let gitDirectory = linkedGitDirectory(
            fromFile: marker.gitPath,
            toplevel: marker.toplevel,
            reader: reader
        ) else { return .none }
        let branch = branch(inGitDirectory: gitDirectory, reader: reader)
        // A submodule also uses a `.git` file, and it is not a worktree of anything.
        guard let commonDirectory = commonGitDirectory(for: gitDirectory, reader: reader),
              commonDirectory != gitDirectory,
              URL(filePath: commonDirectory).lastPathComponent == ".git"
        else { return WorkspaceGitOrigin(branch: branch) }
        let origin = normalized(URL(filePath: commonDirectory).deletingLastPathComponent())
        guard origin != marker.toplevel else { return WorkspaceGitOrigin(branch: branch) }
        return WorkspaceGitOrigin(
            originWorkspacePath: origin,
            worktreeName: URL(filePath: marker.toplevel).lastPathComponent,
            branch: branch
        )
    }

    /// Whether the folder is in a Git checkout — an ordinary one, a linked worktree, or a
    /// submodule — which is what lets a new task start in a worktree of it. Read the same way,
    /// without starting Git, so the new-task composer can ask each time its folder changes.
    static func isInRepository(_ workspaceURL: URL, reader: GitMetadataReader = .live) -> Bool {
        repositoryMarker(from: workspaceURL, reader: reader) != nil
    }

    /// The repository's own Git directory (shared by its linked worktrees), nil outside Git.
    private static func sharedGitDirectory(_ workspaceURL: URL, reader: GitMetadataReader) -> String? {
        guard let marker = repositoryMarker(from: workspaceURL, reader: reader) else { return nil }
        if marker.kind == .directory { return marker.gitPath }
        guard let linked = linkedGitDirectory(fromFile: marker.gitPath, toplevel: marker.toplevel,
                                              reader: reader) else { return nil }
        return commonGitDirectory(for: linked, reader: reader) ?? linked
    }

    /// The branches the repository's remotes say are their default (`refs/remotes/<remote>/HEAD`,
    /// which `git clone` and `git remote set-head` write), for `origin` and `upstream`. Without
    /// either, `main` and `master`.
    static func defaultBranches(_ workspaceURL: URL, reader: GitMetadataReader = .live) -> Set<String> {
        guard let gitDirectory = sharedGitDirectory(workspaceURL, reader: reader) else { return [] }
        var names = Set<String>()
        for remote in ["origin", "upstream"] {
            guard let text = reader.text(gitDirectory + "/refs/remotes/\(remote)/HEAD") else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "ref: refs/remotes/\(remote)/"
            if trimmed.hasPrefix(prefix), trimmed.count > prefix.count { names.insert(String(trimmed.dropFirst(prefix.count))) }
        }
        return names.isEmpty ? ["main", "master"] : names
    }

    /// The URLs of the remotes the folder's repository names in its `config` (`url` and `pushurl`
    /// under `[remote "…"]`), read the same way, without starting Git. A linked worktree shares its
    /// repository's config.
    static func remoteURLs(_ workspaceURL: URL, reader: GitMetadataReader = .live) -> [String] {
        guard let gitDirectory = sharedGitDirectory(workspaceURL, reader: reader),
              let config = reader.text(gitDirectory + "/config") else { return [] }
        var urls: [String] = []
        var inRemote = false
        for line in config.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inRemote = trimmed.lowercased().hasPrefix("[remote ")
                continue
            }
            guard inRemote, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if (key == "url" || key == "pushurl"), !value.isEmpty { urls.append(value) }
        }
        return urls
    }

    /// Whether one of the folder's remotes is on GitHub (github.com or a GitHub Enterprise host
    /// named for it), which is when `gh` can say anything about its branch.
    static func hasGitHubRemote(_ workspaceURL: URL, reader: GitMetadataReader = .live) -> Bool {
        remoteURLs(workspaceURL, reader: reader).contains { url in
            let lowered = url.lowercased()
            // https://github.com/o/r.git, ssh://git@github.com/o/r, git@github.com:o/r.git
            let host: Substring
            if let scheme = lowered.range(of: "://") {
                let rest = lowered[scheme.upperBound...]
                let authority = rest.prefix { $0 != "/" }
                host = authority.split(separator: "@").last?.split(separator: ":").first ?? authority
            } else {
                let authority = lowered.prefix { $0 != ":" }
                host = authority.split(separator: "@").last ?? authority
            }
            return host == "github.com" || host.hasSuffix(".github.com") || host.contains("github")
        }
    }

    /// The branch the folder's HEAD is on now, nil when detached or outside Git.
    static func currentBranch(_ workspaceURL: URL, reader: GitMetadataReader = .live) -> String? {
        resolve(workspaceURL: workspaceURL, reader: reader).branch
    }

    // MARK: - Internals

    private struct Marker {
        let toplevel: String
        let gitPath: String
        let kind: GitMetadataReader.EntryKind
    }

    /// The nearest enclosing folder that carries a `.git` entry — the toplevel a task's cwd
    /// belongs to, whether the cwd is the checkout itself or a folder inside it.
    private static func repositoryMarker(
        from workspaceURL: URL,
        reader: GitMetadataReader
    ) -> Marker? {
        var current = normalized(workspaceURL)
        for _ in 0..<64 {
            let gitPath = current == "/" ? "/.git" : current + "/.git"
            if let kind = reader.kind(gitPath) {
                return Marker(toplevel: current, gitPath: gitPath, kind: kind)
            }
            guard current != "/" else { return nil }
            current = normalized(
                URL(filePath: current, directoryHint: .isDirectory).deletingLastPathComponent()
            )
        }
        return nil
    }

    private static func linkedGitDirectory(
        fromFile path: String,
        toplevel: String,
        reader: GitMetadataReader
    ) -> String? {
        guard let contents = reader.text(path) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let value = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return resolved(value, relativeTo: toplevel)
        }
        return nil
    }

    /// The shared repository directory behind a linked worktree: `commondir` when Git wrote one,
    /// otherwise the `.git` folder that owns the `worktrees/<name>` entry.
    private static func commonGitDirectory(
        for gitDirectory: String,
        reader: GitMetadataReader
    ) -> String? {
        if let contents = reader.text(gitDirectory + "/commondir") {
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return resolved(value, relativeTo: gitDirectory) }
        }
        let url = URL(filePath: gitDirectory, directoryHint: .isDirectory)
        guard url.deletingLastPathComponent().lastPathComponent == "worktrees" else { return nil }
        return normalized(url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private static func branch(inGitDirectory path: String, reader: GitMetadataReader) -> String? {
        guard let contents = reader.text(path + "/HEAD") else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else { return nil }
        let reference = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard reference.hasPrefix("refs/heads/") else { return nil }
        let name = String(reference.dropFirst("refs/heads/".count))
        return name.isEmpty ? nil : name
    }

    private static func resolved(_ path: String, relativeTo base: String) -> String {
        normalized(PathRules.current.url(for: path, in: URL(filePath: base, directoryHint: .isDirectory)))
    }

    private static func normalized(_ url: URL) -> String {
        ProjectSidebarPresentation.normalizedPath(for: url)
    }
}

/// The small secondary line a sidebar row shows for a task that runs in a linked worktree.
/// A task in an ordinary checkout shows nothing, so ordinary rows gain no new text.
enum SidebarWorktreeProjection {
    static func detail(for session: SessionRecord) -> String? {
        guard session.originWorkspacePath != nil else { return nil }
        if let name = trimmed(session.worktreeName) { return name }
        return trimmed(session.branch)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
