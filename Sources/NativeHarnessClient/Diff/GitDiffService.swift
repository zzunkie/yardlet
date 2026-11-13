import Foundation

actor GitDiffService {
    private let outputLimit = 2 * 1024 * 1024
    /// A workspace can be outside the app's current file-access grant (for example, a Desktop
    /// folder opened by a fixture). Apple Git may then block while resolving the cwd instead of
    /// returning an error. Keep the task-owned diff process bounded so a Changes surface cannot
    /// spin forever or leave an orphan after the window closes.
    private let processTimeout: Duration
    private let executableURL: URL
    private let arguments: [String]?
    private let parser = UnifiedDiffParser()

    init(
        processTimeout: Duration = .seconds(10),
        executableURL: URL = GitExecutableLocator.preferredURL(),
        arguments: [String]? = nil
    ) {
        self.processTimeout = processTimeout
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func load(workspaceURL: URL, target: GitDiffTarget = .unstaged) async throws -> DiffSnapshot {
        let deadline = ContinuousClock.now + processTimeout
        if let arguments {
            let result = try await read(workspaceURL: workspaceURL, arguments: arguments, deadline: deadline)
            try check(result, allowed: [0])
            return parser.parse(result.text, isTruncated: result.isTruncated)
        }
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        // Revisions follow --end-of-options so a remembered value can never be read as an option.
        let comparison: [String]
        switch target {
        case .unstaged:
            // Compare working tree to index, or index to HEAD. --cached also handles an unborn HEAD.
            comparison = []
        case .staged:
            comparison = ["--cached"]
        case let .commit(hash):
            // The first parent keeps a merge to what it brought into its branch. A root commit has
            // no parent and compares with the empty tree.
            let parents = try await read(
                workspaceURL: root,
                arguments: ["rev-list", "--parents", "-n", "1", "--end-of-options", hash, "--"],
                deadline: deadline
            )
            try check(parents, allowed: [0])
            let base: String
            if let parent = parents.text.split(whereSeparator: \.isWhitespace).dropFirst().first {
                base = String(parent)
            } else {
                let emptyTree = try await read(
                    workspaceURL: root,
                    arguments: ["hash-object", "-t", "tree", "/dev/null"],
                    deadline: deadline
                )
                try check(emptyTree, allowed: [0])
                base = firstLine(emptyTree.text)
            }
            comparison = ["--end-of-options", base, hash, "--"]
        case let .branch(base):
            // Three dots compare HEAD with its merge base, so later commits on the base stay out.
            comparison = ["--end-of-options", "\(base)...HEAD", "--"]
        }
        let diff = try await read(
            workspaceURL: root,
            arguments: ["-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3"]
                + comparison,
            deadline: deadline
        )
        try check(diff, allowed: [0])
        var text = diff.text
        var truncated = diff.isTruncated
        if target == .unstaged && !truncated {
            let listing = try await read(
                workspaceURL: root,
                arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
                deadline: deadline
            )
            try check(listing, allowed: [0])
            var paths = listing.text.components(separatedBy: "\0")
            if paths.last == "" { paths.removeLast() }
            else if listing.isTruncated { paths.removeLast() }
            var seen: Set<String> = []
            paths = paths.filter { seen.insert($0).inserted }
            truncated = listing.isTruncated || paths.count > 200
            for path in paths.prefix(200) {
                if text.utf8.count >= outputLimit { truncated = true; break }
                try Task.checkCancellation()
                let added = try await read(
                    workspaceURL: root,
                    arguments: ["-c", "core.quotePath=false", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", "--", "/dev/null", path],
                    deadline: deadline
                )
                try check(added, allowed: [0, 1])
                let remaining = outputLimit - text.utf8.count
                let bytes = Array(added.text.utf8)
                if bytes.count > remaining || added.isTruncated { truncated = true }
                text += String(decoding: bytes.prefix(remaining), as: UTF8.self)
            }
        }
        return parser.parse(text, isTruncated: truncated)
    }

    /// How many files in the folder's checkout are changed, staged or untracked (`git status
    /// --porcelain`, one line per file). `--no-optional-locks` keeps Git from refreshing the index,
    /// so reading this writes nothing.
    func uncommittedFileCount(workspaceURL: URL) async throws -> Int {
        try await statusLineCount(workspaceURL, deadline: ContinuousClock.now + processTimeout)
    }

    /// What the folder's checkout left unfinished: files not committed, commits its branch has not
    /// pushed to its upstream, and linked worktrees whose commits the default branch does not hold yet
    /// or with files not committed (at most `worktreeLimit` of them are read). Every command only
    /// reads, and `--no-optional-locks` keeps `status` from refreshing the index.
    func leftWork(workspaceURL: URL, worktreeLimit: Int = 24) async throws -> GitLeftWork {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        var work = GitLeftWork()
        work.uncommittedFiles = try await statusLineCount(root, deadline: deadline)

        // No upstream (a local branch, a detached HEAD) ends with 128: nothing to push to.
        let ahead = try await read(workspaceURL: root, arguments: ["rev-list", "--count", "@{upstream}..HEAD"],
                                   deadline: deadline)
        if ahead.status == 0 { work.unpushedCommits = Int(firstLine(ahead.text)) ?? 0 }

        // The default branch the worktrees' commits are looked for in: the remote's, where merged work
        // lands, else local main or master.
        let remoteHead = try await read(workspaceURL: root, arguments: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
                                        deadline: deadline)
        var candidates = ["refs/heads/main", "refs/heads/master"]
        if remoteHead.status == 0, firstLine(remoteHead.text).hasPrefix("refs/") {
            candidates.insert(firstLine(remoteHead.text), at: 0)
        }
        let listing = try await read(workspaceURL: root, arguments: ["for-each-ref", "--format=%(refname)"] + candidates,
                                     deadline: deadline)
        let existing = Set(listing.text.split(separator: "\n").map(String.init))
        let base = candidates.first(where: existing.contains)

        let worktrees = try await read(workspaceURL: root, arguments: ["worktree", "list", "--porcelain"], deadline: deadline)
        try check(worktrees, allowed: [0])
        // Blocks of `worktree <path>`, `HEAD <sha>`, `branch …`/`detached`, `prunable …`; the first is
        // the main checkout.
        let linked = worktrees.text.components(separatedBy: "\n\n").dropFirst().compactMap { block -> (URL, String)? in
            var path: String?, head: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                if line.hasPrefix("prunable") || line == "bare" { return nil }
            }
            guard let path, let head, FileManager.default.fileExists(atPath: path) else { return nil }
            return (URL(filePath: path, directoryHint: .isDirectory), head)
        }
        for (folder, head) in linked.prefix(worktreeLimit) {
            if let base {
                let merged = try await read(workspaceURL: root, arguments: ["merge-base", "--is-ancestor", head, base],
                                            deadline: deadline)
                if merged.status == 1 { work.openWorktrees += 1; continue }
            }
            if (try? await statusLineCount(folder, deadline: deadline)) ?? 0 > 0 { work.openWorktrees += 1 }
        }
        return work
    }

    private func statusLineCount(_ folder: URL, deadline: ContinuousClock.Instant) async throws -> Int {
        let result = try await read(
            workspaceURL: folder,
            arguments: ["--no-optional-locks", "-c", "core.quotePath=false", "status", "--porcelain=v1",
                        "--untracked-files=normal"],
            deadline: deadline
        )
        try check(result, allowed: [0])
        return result.text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// The distinct repositories that hold `roots`, in root order. A folder outside Git is skipped.
    func repositories(containing roots: [URL]) async throws -> [URL] {
        var repositories: [URL] = []
        for root in roots {
            do {
                let repository = try await repositoryRoot(of: root, deadline: ContinuousClock.now + processTimeout)
                if !repositories.contains(repository) { repositories.append(repository) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return repositories
    }

    /// The latest commits reachable from HEAD, newest first. An unborn HEAD has none.
    func recentCommits(workspaceURL: URL, limit: Int = 50) async throws -> [GitCommitSummary] {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        let head = try await read(
            workspaceURL: root,
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            deadline: deadline
        )
        try check(head, allowed: [0, 1])
        guard head.status == 0 else { return [] }
        let log = try await read(
            workspaceURL: root,
            arguments: ["log", "-z", "-n", String(limit), "--no-color", "--no-show-signature",
                        "--format=%H%x1f%h%x1f%at%x1f%s", "HEAD", "--"],
            deadline: deadline
        )
        try check(log, allowed: [0])
        return log.text.split(separator: "\0").compactMap { record in
            let fields = record.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return GitCommitSummary(
                id: String(fields[0]),
                shortID: String(fields[1]),
                subject: String(fields[3]),
                date: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    /// The branch the Branch scope compares with: the one origin/HEAD names, then local main, then
    /// local master.
    func baseBranch(workspaceURL: URL) async throws -> GitBaseBranch {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        var candidates = ["refs/heads/main", "refs/heads/master"]
        // A clone without origin/HEAD, or a repository without origin, simply has no remote choice.
        let remoteHead = try await read(
            workspaceURL: root,
            arguments: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
            deadline: deadline
        )
        let remoteTarget = firstLine(remoteHead.text)
        if remoteHead.status == 0, remoteTarget.hasPrefix("refs/") { candidates.insert(remoteTarget, at: 0) }
        let listing = try await read(
            workspaceURL: root,
            arguments: ["for-each-ref", "--format=%(refname)"] + candidates,
            deadline: deadline
        )
        try check(listing, allowed: [0])
        let existing = Set(listing.text.split(separator: "\n").map(String.init))
        guard let base = candidates.first(where: existing.contains) else { return .missing }
        let head = try await read(
            workspaceURL: root,
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            deadline: deadline
        )
        try check(head, allowed: [0, 1])
        // A detached HEAD is compared like any branch. Local main tracking origin/main is the base.
        if head.status == 0, branchName(firstLine(head.text)) == branchName(base) { return .current }
        return .found(base)
    }

    func branches(workspaceURL: URL) async throws -> [String] {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        let result = try await read(workspaceURL: root, arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], deadline: deadline)
        try check(result, allowed: [0])
        return result.text.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    func mutate(_ action: GitMutation, workspaceURL: URL, expected: DiffSnapshot) async throws {
        try await mutate(action, workspaceURL: workspaceURL, expected: expected, authorizing: {})
    }

    /// `authorize` runs immediately before each step that writes, after every read, so a permission withdrawn
    /// meanwhile stops the change before Git or the file system is touched.
    func mutate(_ action: GitMutation, workspaceURL: URL, expected: DiffSnapshot,
                authorizing authorize: @Sendable () throws -> Void) async throws {
        guard !expected.isTruncated, !expected.isEmpty else { throw GitDiffServiceError.changedSinceReview }
        let target: GitDiffTarget = action == .unstage ? .staged : .unstaged
        let fresh = try await load(workspaceURL: workspaceURL, target: target)
        guard fresh == expected else { throw GitDiffServiceError.changedSinceReview }
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        let paths = Array(Set(expected.files.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } })).sorted()
        for path in paths {
            let parts = PathRules.current.names(path)
            guard PathRules.current.isRelative(path), !path.contains("\0"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw GitDiffServiceError.changedSinceReview }
            var parent = root
            for part in parts.dropLast() {
                parent.append(path: String(part))
                if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw GitDiffServiceError.changedSinceReview
                }
            }
        }
        switch action {
        case .stage:
            try authorize()
            try check(try await read(workspaceURL: root, arguments: ["add", "--all", "--"] + paths, deadline: deadline), allowed: [0])
        case .unstage:
            let head = try await read(workspaceURL: root, arguments: ["rev-parse", "--verify", "HEAD"], deadline: deadline)
            let args = head.status == 0 ? ["reset", "--quiet", "HEAD", "--"] : ["rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--"]
            try authorize()
            try check(try await read(workspaceURL: root, arguments: args + paths, deadline: deadline), allowed: [0])
        case .discard:
            let indexed = try await read(workspaceURL: root, arguments: ["ls-files", "--cached", "-z", "--"] + paths, deadline: deadline)
            try check(indexed, allowed: [0])
            let tracked = Set(indexed.text.split(separator: "\0").map(String.init))
            let trackedPaths = paths.filter(tracked.contains)
            // No reset --hard or git clean: only the reviewed snapshot's exact paths change.
            if !trackedPaths.isEmpty {
                try authorize()
                try check(try await read(workspaceURL: root, arguments: ["restore", "--worktree", "--"] + trackedPaths, deadline: deadline), allowed: [0])
            }
            for path in paths where !tracked.contains(path) {
                let file = root.appending(path: path)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true || values.isSymbolicLink == true else { throw GitDiffServiceError.changedSinceReview }
                try authorize()
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func branchName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/origin/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// What the session rail's Changes card says about the folder's uncommitted work: the tracked
    /// files that differ from HEAD with their added and removed lines, and the new files Git does not
    /// track yet. A repository without a first commit compares the index and the working tree.
    func changeSummary(workspaceURL: URL) async throws -> GitChangeSummary {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        let numstat = ["-c", "core.quotePath=false", "diff", "--numstat", "--no-ext-diff", "--no-textconv", "--no-color"]
        var summary: GitChangeSummary
        let head = try await read(workspaceURL: root, arguments: numstat + ["HEAD", "--"], deadline: deadline)
        if head.status == 0 {
            summary = GitChangeSummary(numstat: head.text)
        } else {
            let staged = try await read(workspaceURL: root, arguments: numstat + ["--cached", "--"], deadline: deadline)
            try check(staged, allowed: [0])
            let unstaged = try await read(workspaceURL: root, arguments: numstat + ["--"], deadline: deadline)
            try check(unstaged, allowed: [0])
            summary = GitChangeSummary(numstat: staged.text + "\n" + unstaged.text)
        }
        let listing = try await read(workspaceURL: root, arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
                                     deadline: deadline)
        try check(listing, allowed: [0])
        summary.untrackedFiles = listing.text.split(separator: "\0").count
        return summary
    }

    /// A file's text as `revision` holds it (`HEAD`, a commit's hash, or "" for the index), for the
    /// review's rendered view of a Markdown change. Nil when the revision has no such file, or it is
    /// longer than a diff's own limit. `path` is relative to the repository's top folder.
    func fileText(workspaceURL: URL, revision: String, path: String) async throws -> String? {
        let deadline = ContinuousClock.now + processTimeout
        let root = try await repositoryRoot(of: workspaceURL, deadline: deadline)
        let result = try await read(workspaceURL: root, arguments: ["cat-file", "blob", "\(revision):\(path)"],
                                    deadline: deadline)
        // Git ends with 128 when the revision holds no such file.
        if result.status == 128 { return nil }
        try check(result, allowed: [0])
        return result.isTruncated ? nil : result.text
    }

    /// The repository's top folder, which the paths in its diff are relative to.
    func repositoryRoot(workspaceURL: URL) async throws -> URL {
        try await repositoryRoot(of: workspaceURL, deadline: ContinuousClock.now + processTimeout)
    }

    private func repositoryRoot(of workspaceURL: URL, deadline: ContinuousClock.Instant) async throws -> URL {
        let result = try await read(workspaceURL: workspaceURL, arguments: ["rev-parse", "--show-toplevel"], deadline: deadline)
        // Git ends with 128 when no repository holds the folder, or the folder cannot be reached.
        if result.status == 128 { throw GitDiffServiceError.notARepository }
        try check(result, allowed: [0])
        return URL(filePath: result.text.hasSuffix("\n") ? String(result.text.dropLast()) : result.text)
    }

    private struct Output {
        let text: String
        let errorText: String
        let isTruncated: Bool
        let status: Int32
    }

    private func check(_ result: Output, allowed: Set<Int32>) throws {
        guard allowed.contains(result.status) else {
            let message = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitDiffServiceError.commandFailed(
                code: result.status,
                message: message.isEmpty ? result.text.trimmingCharacters(in: .whitespacesAndNewlines) : message
            )
        }
    }

    private func firstLine(_ text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    private func read(workspaceURL: URL, arguments: [String], deadline: ContinuousClock.Instant) async throws -> Output {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "nhc-diff-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        // Warnings stay out of the output that is parsed; they only explain a failure.
        let errorURL = temporaryURL.deletingPathExtension().appendingPathExtension("err")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }

        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? fileHandle.close() }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspaceURL.standardizedFileURL
        process.arguments = arguments
        process.environment = GitExecutableLocator.environment(for: executableURL, overrides: [
            "GIT_PAGER": "cat",
            "PAGER": "cat"
        ])
        process.standardOutput = fileHandle
        process.standardError = errorHandle
        try NativeProcessTree.run(process)

        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    terminate(process)
                    throw GitDiffServiceError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            terminate(process)
            throw error
        }
        try fileHandle.synchronize()

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let reader = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: outputLimit) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }
        let errorText = String(decoding: try errorReader.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)

        return Output(
            text: text,
            errorText: errorText,
            isTruncated: size > outputLimit,
            status: process.terminationStatus
        )
    }

    private func terminate(_ process: Process) {
        // Foundation owns this child; do not separately waitpid and steal its exit status.
        if process.isRunning { NativeProcessTree.terminate(process: process) }
    }

}

/// What a project's checkout left unfinished (`GitDiffService.leftWork`), as the home names it for a
/// project left alone for a while.
struct GitLeftWork: Equatable, Sendable {
    var uncommittedFiles = 0
    /// Commits the branch has that its upstream does not.
    var unpushedCommits = 0
    /// Linked worktrees whose commits the default branch does not hold, or with files not committed.
    var openWorktrees = 0

    var isEmpty: Bool { uncommittedFiles == 0 && unpushedCommits == 0 && openWorktrees == 0 }
}

/// A folder's uncommitted work in numbers (`GitDiffService.changeSummary`).
struct GitChangeSummary: Equatable, Sendable {
    /// Tracked files that differ from HEAD.
    var changedFiles = 0
    var additions = 0
    var deletions = 0
    /// New files Git does not track yet.
    var untrackedFiles = 0

    var fileCount: Int { changedFiles + untrackedFiles }
    var isEmpty: Bool { fileCount == 0 }

    init(changedFiles: Int = 0, additions: Int = 0, deletions: Int = 0, untrackedFiles: Int = 0) {
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.untrackedFiles = untrackedFiles
    }

    /// `git diff --numstat` lines: `added<TAB>removed<TAB>path`, `-` for a binary file. A path listed
    /// twice (staged and unstaged) counts once.
    init(numstat: String) {
        var paths = Set<String>()
        for line in numstat.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            paths.insert(String(fields[2]))
            additions += Int(fields[0]) ?? 0
            deletions += Int(fields[1]) ?? 0
        }
        changedFiles = paths.count
    }
}

/// What one diff load compares.
enum GitDiffTarget: Equatable, Sendable {
    case unstaged, staged
    /// One commit, by full hash, against its first parent.
    case commit(String)
    /// The commits HEAD made since it left `base`, a full ref name. Uncommitted work stays with
    /// the Unstaged and Staged targets.
    case branch(base: String)
}

struct GitCommitSummary: Equatable, Identifiable, Sendable {
    /// The full hash.
    let id: String
    let shortID: String
    let subject: String
    let date: Date
}

enum GitBaseBranch: Equatable, Sendable {
    /// The full ref name to compare with.
    case found(String)
    case missing
    /// HEAD is on the base branch itself.
    case current
}

enum GitDiffServiceError: LocalizedError, Equatable, Sendable {
    case timedOut
    case changedSinceReview
    /// No repository holds the folder, or the folder cannot be reached.
    case notARepository
    case commandFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return L10n.string("Diff loading timed out. Try Refresh again.")
        case .changedSinceReview:
            return L10n.string("Changes have changed. Refresh and review them again.")
        case .notARepository:
            return L10n.string("Changes need a Git repository")
        case let .commandFailed(code, message):
            return L10n.format("Git failed (%d): %@", code, message)
        }
    }
}
