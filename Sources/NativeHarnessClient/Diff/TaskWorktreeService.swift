import Foundation

/// Makes, removes, and remakes the linked worktrees Yardlet runs new tasks in.
///
/// Every Git command runs off the main actor with a deadline, as the review panel's do, and like
/// the Codex app's without the repository's hooks. A checkout needs neither the network nor any
/// program but Git: Git LFS's filter is left out of it, as both apps leave it out of theirs, and the
/// LFS files are then filled from what this Mac already downloaded, as the Claude app fills them. Removal is deliberately narrow: only a folder
/// inside Yardlet's own worktree folder that Git confirms is a linked worktree, only when nothing
/// in it is uncommitted, and only when its HEAD and its `yardlet/` branch have no commit that
/// another local branch lacks. Removal never forces, and no branch is ever deleted: the branch is
/// what lets an unarchived task get its worktree back.
actor TaskWorktreeService {
    nonisolated let layout: TaskWorktreeLayout
    private let executableURL: URL
    private let timeout: Duration
    /// Checking out, or deleting, a large worktree can take far longer than a query.
    private let checkoutTimeout: Duration
    private let environment: [String: String]
    private let outputLimit = 1024 * 1024

    init(
        layout: TaskWorktreeLayout = .live(),
        executableURL: URL = GitExecutableLocator.preferredURL(),
        timeout: Duration = .seconds(30),
        checkoutTimeout: Duration = .seconds(300),
        environment: [String: String] = [:]
    ) {
        self.layout = layout
        self.executableURL = executableURL
        self.timeout = timeout
        self.checkoutTimeout = checkoutTimeout
        self.environment = environment
    }

    // MARK: - Creating

    /// Makes a linked worktree from the current HEAD of the repository holding `folder`, on a new
    /// `yardlet/` branch named after `prompt`. When anything fails, whatever this call made is
    /// taken back before the error is thrown.
    func create(from folder: URL, prompt: String) async throws -> TaskWorktree {
        do {
            return try await makeWorktree(from: folder, prompt: prompt)
        } catch TaskWorktreeError.timedOut {
            throw TaskWorktreeError.gitFailed(TaskWorktreeError.timedOut.localizedDescription)
        }
    }

    private func makeWorktree(from folder: URL, prompt: String) async throws -> TaskWorktree {
        let location = try await run(["rev-parse", "--show-prefix", "--path-format=absolute",
                                      "--show-toplevel", "--git-common-dir"], in: folder)
        guard location.status == 0 else { throw TaskWorktreeError.notARepository }
        let lines = location.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, !lines[1].isEmpty, !lines[2].isEmpty else { throw TaskWorktreeError.notARepository }
        let prefix = lines[0]
        let toplevel = URL(filePath: lines[1], directoryHint: .isDirectory)
        let commonDirectory = URL(filePath: lines[2], directoryHint: .isDirectory)

        let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: toplevel)
        let baseCommit = firstLine(head.text)
        guard head.status == 0, !baseCommit.isEmpty else { throw TaskWorktreeError.noCommits }

        // A worktree made from another worktree still belongs to the repository both came from.
        let repository = commonDirectory.lastPathComponent == ".git"
            ? commonDirectory.deletingLastPathComponent()
            : toplevel
        let repositoryFolder = TaskWorktreeNaming.slug(from: repository.lastPathComponent, fallback: "repository")
        let branches = try await run(["for-each-ref", "--format=%(refname)", "refs/heads/"], in: toplevel)
        try check(branches)
        let existingBranches = Set(branches.text.split(separator: "\n").map(String.init))
        let registered = try await registeredWorktreePaths(in: toplevel)
        let slug = TaskWorktreeNaming.slug(from: prompt)
        guard let name = TaskWorktreeNaming.candidates(for: slug).first(where: { name in
            let url = layout.worktreeURL(repositoryFolder: repositoryFolder, name: name)
            return !existingBranches.contains("refs/heads/" + TaskWorktreeLayout.branchPrefix + name)
                && !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                && !registered.contains(Self.comparablePath(url))
        }) else {
            throw TaskWorktreeError.gitFailed(L10n.string("Every worktree name for this task is already taken."))
        }
        let worktreeURL = layout.worktreeURL(repositoryFolder: repositoryFolder, name: name)
        let branch = TaskWorktreeLayout.branchPrefix + name
        do {
            try prepareFolder(for: worktreeURL)
        } catch {
            throw TaskWorktreeError.gitFailed(error.localizedDescription)
        }

        do {
            let added = try await run(
                Self.withoutLargeFileFilter + ["worktree", "add", "-b", branch, Self.argument(worktreeURL), baseCommit],
                in: toplevel, timeout: checkoutTimeout
            )
            try check(added)
        } catch {
            await discardCreated(worktreeURL: worktreeURL, branch: branch, baseCommit: baseCommit, in: toplevel)
            throw error
        }

        let workspaceURL = prefix.isEmpty
            ? worktreeURL
            : worktreeURL.appending(path: prefix, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceURL.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            await discardCreated(worktreeURL: worktreeURL, branch: branch, baseCommit: baseCommit, in: toplevel)
            throw TaskWorktreeError.missingFolder(folder.lastPathComponent)
        }
        return TaskWorktree(
            workspaceURL: URL(filePath: ProjectSidebarPresentation.normalizedPath(for: workspaceURL)),
            worktreeURL: URL(filePath: ProjectSidebarPresentation.normalizedPath(for: worktreeURL)),
            sourceURL: toplevel,
            branch: branch,
            baseCommit: baseCommit,
            largeFilesLeftAsPointers: await fillLargeFiles(in: worktreeURL)
        )
    }

    /// Git LFS's filter, off for a checkout: LFS files come out as their pointers, and nothing needs
    /// `git-lfs` or the network (the Claude app's and the Codex app's `worktree add`).
    private static let withoutLargeFileFilter = ["-c", "filter.lfs.clean=", "-c", "filter.lfs.smudge=",
                                                 "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false"]

    /// Fills a new checkout's Git LFS files from the content this Mac already downloaded
    /// (`git lfs checkout`, which never downloads), as the Claude app fills a new worktree. Returns
    /// how many stay pointers: their content was never downloaded here, or Git LFS is not installed.
    private func fillLargeFiles(in worktreeURL: URL) async -> Int {
        guard let listed = try? await run(["ls-files", "-z", ":(attr:filter=lfs)"], in: worktreeURL),
              listed.status == 0 else { return 0 }
        let count = listed.text.split(separator: "\0").count
        guard count > 0 else { return 0 }
        guard let filled = try? await run(["lfs", "checkout"], in: worktreeURL, timeout: checkoutTimeout),
              filled.status == 0,
              let local = try? await run(["lfs", "ls-files"], in: worktreeURL), local.status == 0 else { return count }
        // "<oid> * <path>" for a file whose content is here, "<oid> - <path>" for one whose is not.
        return local.text.split(separator: "\n").filter { $0.split(separator: " ").dropFirst().first == "-" }.count
    }

    /// Takes back a worktree `create` made when the task it was for never came to exist. Nothing
    /// should have touched it since; if anything did, Git refuses and it stays. The branch is
    /// deleted only while it still points at the commit it started from.
    func discard(_ worktree: TaskWorktree) async {
        let removed = try? await run(["worktree", "remove", Self.argument(worktree.worktreeURL)],
                                     in: worktree.sourceURL, timeout: checkoutTimeout)
        guard removed?.status == 0 else { return }
        _ = try? await run(["update-ref", "-d", "refs/heads/" + worktree.branch, worktree.baseCommit],
                           in: worktree.sourceURL)
        removeEmptyRepositoryFolder(of: worktree.worktreeURL)
    }

    private func discardCreated(worktreeURL: URL, branch: String, baseCommit: String, in repository: URL) async {
        let path = Self.argument(worktreeURL)
        // Only this call's own, just-made folder is forced: a checkout cut off part way reads as
        // changed. `remove` also clears Git's record of a folder that never fully appeared.
        _ = try? await run(["worktree", "remove", "--force", path], in: repository)
        // Only what Git left of its own checkout goes: an empty folder, or one holding a worktree's
        // `.git` file. Anything else at that path is not this call's to delete.
        var gitIsDirectory: ObjCBool = false
        let hasWorktreeGitFile = FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &gitIsDirectory)
            && !gitIsDirectory.boolValue
        let isEmptyFolder = (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true
        if hasWorktreeGitFile || isEmptyFolder { try? FileManager.default.removeItem(at: worktreeURL) }
        // `git worktree add -b` keeps the branch it made even when the checkout then fails.
        _ = try? await run(["update-ref", "-d", "refs/heads/" + branch, baseCommit], in: repository)
        removeEmptyRepositoryFolder(of: worktreeURL)
    }

    // MARK: - Archive clean-up

    /// Removes the Yardlet worktree `workspaceURL` runs in when nothing in it would be lost: no
    /// uncommitted or untracked files (ignored ones do not count), and no commit on its HEAD or its
    /// `yardlet/` branch that another local branch lacks. Anything else leaves the worktree exactly
    /// as it was. The branch always stays.
    func cleanUp(workspaceURL: URL, recordedBranch: String?) async -> TaskWorktreeCleanup {
        guard let worktreeURL = layout.worktreeURL(containing: workspaceURL) else { return .untouched }
        let path = Self.argument(worktreeURL)
        guard FileManager.default.fileExists(atPath: path) else { return .untouched }
        do {
            guard try await isLinkedWorktree(worktreeURL) else { return .untouched }
            let status = try await run(["status", "--porcelain=v1", "-z",
                                        "--untracked-files=normal", "--ignore-submodules=none"], in: worktreeURL)
            try check(status)
            guard status.text.isEmpty else { return .keptUncommittedChanges }

            let headBranch = try await self.headBranch(of: worktreeURL)
            var ownBranches: [String] = []
            for candidate in [headBranch, recordedBranch].compactMap({ $0 })
            where candidate.hasPrefix(TaskWorktreeLayout.branchPrefix) && !ownBranches.contains(candidate) {
                if try await branchExists(candidate, in: worktreeURL) { ownBranches.append(candidate) }
            }
            // Commits HEAD or Yardlet's own branches reach that no other local branch does. HEAD
            // goes first: on a detached HEAD such commits are on no branch at all.
            let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: worktreeURL)
            let tips = (head.status == 0 ? [(firstLine(head.text), headBranch)] : [])
                + ownBranches.map { ("refs/heads/" + $0, Optional($0)) }
            for (tip, branch) in tips {
                let unique = try await run(
                    ["rev-list", "--count", tip, "--not"] + ownBranches.map { "--exclude=" + $0 } + ["--branches"],
                    in: worktreeURL
                )
                try check(unique)
                guard firstLine(unique.text) == "0" else { return .keptUnmergedCommits(branch: branch) }
            }

            let removed = try await run(["worktree", "remove", path], in: worktreeURL, timeout: checkoutTimeout)
            guard removed.status == 0 else { return .failed(message(of: removed)) }
            removeEmptyRepositoryFolder(of: worktreeURL)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Making a worktree again

    /// Puts back the worktree a task ran in when its folder has gone, checking out the task's own
    /// branch again in the same place: an unarchived task's Yardlet worktree, and a worktree the person
    /// asks back for a task whose folder is gone (`worktreeName`).
    func restore(workspaceURL: URL, repositoryURL: URL?, branch: String?,
                 worktreeName: String? = nil) async -> TaskWorktreeRestoration {
        guard let worktreeURL = worktreeURL(containing: workspaceURL, named: worktreeName) else { return .notNeeded }
        let path = Self.argument(worktreeURL)
        guard !FileManager.default.fileExists(atPath: path) else { return .notNeeded }
        guard let repositoryURL,
              FileManager.default.fileExists(atPath: repositoryURL.path(percentEncoded: false)) else {
            return .repositoryMissing(repositoryURL?.path(percentEncoded: false) ?? "")
        }
        do {
            guard let branch, try await branchExists(branch, in: repositoryURL) else { return .branchMissing(branch) }
            try prepareFolder(for: worktreeURL)
            let add = Self.withoutLargeFileFilter + ["worktree", "add", path, branch]
            var added = try await run(add, in: repositoryURL, timeout: checkoutTimeout)
            if added.status != 0,
               try await registeredWorktreePaths(in: repositoryURL).contains(Self.comparablePath(worktreeURL)) {
                // The folder was deleted without Git hearing of it. Forget that one record only;
                // a repository-wide prune would also forget worktrees on a drive that is not mounted.
                _ = try await run(["worktree", "remove", path], in: repositoryURL)
                added = try await run(add, in: repositoryURL, timeout: checkoutTimeout)
            }
            guard added.status == 0 else {
                removeEmptyRepositoryFolder(of: worktreeURL)
                return .failed(message(of: added))
            }
            _ = await fillLargeFiles(in: worktreeURL)
            return .recreated
        } catch {
            removeEmptyRepositoryFolder(of: worktreeURL)
            return .failed(error.localizedDescription)
        }
    }

    /// The branch `restore` would check out again for the task, when it has something to make: the
    /// worktree's folder is gone, its repository is there and has the branch, and no other worktree
    /// has the branch checked out. Nil otherwise. It changes nothing.
    func restorableBranch(workspaceURL: URL, repositoryURL: URL?, branch: String?,
                          worktreeName: String?) async -> String? {
        guard let worktreeURL = worktreeURL(containing: workspaceURL, named: worktreeName),
              !FileManager.default.fileExists(atPath: Self.argument(worktreeURL)),
              let repositoryURL, let branch,
              FileManager.default.fileExists(atPath: repositoryURL.path(percentEncoded: false)) else { return nil }
        do {
            guard try await branchExists(branch, in: repositoryURL) else { return nil }
            let list = try await run(["worktree", "list", "--porcelain"], in: repositoryURL)
            try check(list)
            // The record of the worktree that went without Git hearing of it may still name the branch.
            let own = Self.comparablePath(worktreeURL)
            var path: String?
            for line in list.text.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") {
                    path = Self.comparablePath(URL(filePath: String(line.dropFirst("worktree ".count))))
                } else if line == "branch refs/heads/" + branch, path != own {
                    return nil
                }
            }
            return branch
        } catch {
            return nil
        }
    }

    /// The worktree a task's folder is in: Yardlet's own by its layout, or, given the name the task
    /// recorded for it (`WorkspaceGitOrigin.worktreeName`), the nearest folder of that name holding it.
    nonisolated func worktreeURL(containing workspaceURL: URL, named name: String?) -> URL? {
        if let worktreeURL = layout.worktreeURL(containing: workspaceURL) { return worktreeURL }
        guard let name, !name.isEmpty else { return nil }
        var folder = URL(filePath: ProjectSidebarPresentation.normalizedPath(for: workspaceURL), directoryHint: .isDirectory)
        while folder.path(percentEncoded: false) != "/" {
            if folder.lastPathComponent == name { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Git queries

    /// Whether the folder is the top of a linked worktree — not a main checkout, a plain folder,
    /// or a folder inside something else.
    private func isLinkedWorktree(_ worktreeURL: URL) async throws -> Bool {
        let result = try await run(["rev-parse", "--path-format=absolute", "--show-toplevel",
                                    "--git-common-dir", "--git-dir"], in: worktreeURL)
        guard result.status == 0 else { return false }
        let lines = result.text.split(separator: "\n").map(String.init)
        return lines.count >= 3
            && Self.comparablePath(URL(filePath: lines[0])) == Self.comparablePath(worktreeURL)
            && Self.comparablePath(URL(filePath: lines[1])) != Self.comparablePath(URL(filePath: lines[2]))
    }

    private func headBranch(of worktreeURL: URL) async throws -> String? {
        let result = try await run(["symbolic-ref", "--quiet", "HEAD"], in: worktreeURL)
        let reference = firstLine(result.text)
        guard result.status == 0, reference.hasPrefix("refs/heads/") else { return nil }
        return String(reference.dropFirst("refs/heads/".count))
    }

    private func branchExists(_ branch: String, in directory: URL) async throws -> Bool {
        let result = try await run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], in: directory)
        return result.status == 0
    }

    private func registeredWorktreePaths(in directory: URL) async throws -> Set<String> {
        let result = try await run(["worktree", "list", "--porcelain"], in: directory)
        try check(result)
        return Set(result.text.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ")
                ? Self.comparablePath(URL(filePath: String(line.dropFirst("worktree ".count))))
                : nil
        })
    }

    /// Makes the folder the worktree goes in, `~/.yardlet/worktrees/<repository>` for Yardlet's own.
    /// Spotlight is kept out of Yardlet's whole folder, as the Codex app keeps it out of its own: these
    /// are copies of repositories it already indexes.
    private func prepareFolder(for worktreeURL: URL) throws {
        try FileManager.default.createDirectory(at: worktreeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard layout.worktreeURL(containing: worktreeURL) != nil else { return }
        let marker = layout.rootURL.appending(path: ".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: marker.path(percentEncoded: false), contents: nil)
        }
    }

    /// `~/.yardlet/worktrees/<repository>` goes once its last worktree has.
    private func removeEmptyRepositoryFolder(of worktreeURL: URL) {
        let folder = worktreeURL.deletingLastPathComponent()
        guard Self.comparablePath(folder.deletingLastPathComponent()) == Self.comparablePath(layout.rootURL),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)),
              contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A folder as Git is given it. Git matches a missing worktree's record by the exact path it
    /// was made with, so a trailing slash would make the record unrecognisable.
    private static func argument(_ url: URL) -> String {
        ProjectSidebarPresentation.normalizedPath(for: url)
    }

    /// Git reports real paths, and the temporary folder and some homes are reached through
    /// symlinks. The deepest folder that exists is resolved, so a missing worktree compares too.
    static func comparablePath(_ url: URL) -> String {
        var existing = URL(filePath: ProjectSidebarPresentation.normalizedPath(for: url))
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)),
              existing.path(percentEncoded: false) != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.path(percentEncoded: false)
        if let real = CanonicalPath.resolve(resolved) { resolved = real }
        return ([resolved == "/" ? "" : resolved] + missing).joined(separator: "/")
    }

    // MARK: - Running Git

    private struct Output {
        let text: String
        let errorText: String
        let status: Int32
    }

    private func check(_ output: Output) throws {
        guard output.status == 0 else { throw TaskWorktreeError.gitFailed(message(of: output)) }
    }

    /// Git's own explanation: its `fatal:` and `error:` lines when it wrote any, which leaves out
    /// progress lines and hints in whatever language Git speaks.
    private func message(of output: Output) -> String {
        let lines = output.errorText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let failures = lines.compactMap { line -> String? in
            for prefix in ["fatal:", "error:"] where line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        let message = (failures.isEmpty ? lines : failures).joined(separator: " ")
        return message.isEmpty ? L10n.format("Git exited with status %d.", output.status) : message
    }

    private func firstLine(_ text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    private func run(_ arguments: [String], in directory: URL, timeout: Duration? = nil) async throws -> Output {
        let deadline = ContinuousClock.now + (timeout ?? self.timeout)
        // Output goes to files rather than pipes so a chatty command can never block on a full pipe.
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "nhc-worktree-\(UUID().uuidString).out")
        let errorURL = outputURL.deletingPathExtension().appendingPathExtension("err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        // The repository's hooks stay out of Yardlet's own bookkeeping, as they do in the Codex app.
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        // No pager, no credential prompt, and no index refresh racing a task's own Git use.
        process.environment = GitExecutableLocator.environment(
            for: executableURL,
            overrides: ["GIT_PAGER": "cat", "PAGER": "cat", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        ).merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        do {
            try process.run()
        } catch {
            throw TaskWorktreeError.gitFailed(error.localizedDescription)
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    NativeProcessTree.terminate(process: process)
                    throw TaskWorktreeError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if process.isRunning { NativeProcessTree.terminate(process: process) }
            throw error
        }
        let outputReader = try FileHandle(forReadingFrom: outputURL)
        defer { try? outputReader.close() }
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }
        return Output(
            text: String(decoding: try outputReader.read(upToCount: outputLimit) ?? Data(), as: UTF8.self),
            errorText: String(decoding: try errorReader.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self),
            status: process.terminationStatus
        )
    }
}
