import Foundation

/// A finished `gh` command.
struct GitHubCLIOutput: Equatable, Sendable {
    let status: Int32
    let output: Data
    let errorText: String
}

enum GitHubCLIFailure: Error, Equatable, Sendable {
    /// No `gh` where it is installed.
    case missing
    case timedOut
    case couldNotStart
}

/// Runs GitHub's CLI. Yardlet only reads with it (`gh pr view --json …`); tests give a fake one so
/// they never start the real `gh`.
protocol GitHubCLIRunning: Sendable {
    func run(_ arguments: [String], in directory: URL, timeout: Duration) async throws -> GitHubCLIOutput
}

/// The `gh` the person installed, started off the main actor without a terminal: it never prompts,
/// never pages, never checks for updates, and is stopped (with what it started) at the timeout.
/// Its sign-in is the person's own; Yardlet does not run `gh auth` or change its configuration.
struct LocalGitHubCLI: GitHubCLIRunning {
    /// Where Homebrew, MacPorts and a manual install put it. A GUI launch does not inherit the shell's
    /// PATH, so these are looked at directly, as `GitExecutableLocator` looks for Git.
    static let standardPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]

    /// What keeps `gh` from waiting on a person: no prompt, pager, colour, spinner or update notice.
    static let environment = [
        "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1", "GH_PAGER": "cat", "PAGER": "cat", "NO_COLOR": "1", "CLICOLOR": "0",
        "GIT_TERMINAL_PROMPT": "0"
    ]

    var executableURL: URL?

    init(executableURL: URL? = LocalGitHubCLI.locate()) {
        self.executableURL = executableURL
    }

    static func locate(
        candidates: [String] = standardPaths,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let paths = candidates + [homeURL.appending(path: ".local/bin/gh").path(percentEncoded: false)]
        return paths.first(where: isExecutableFile).map { URL(filePath: $0) }
    }

    func run(_ arguments: [String], in directory: URL, timeout: Duration) async throws -> GitHubCLIOutput {
        guard let executableURL else { throw GitHubCLIFailure.missing }
        return try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = RuntimeProcessEnvironment.values(executableURL: executableURL,
                                                                    overrides: Self.environment)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            let exit: ProcessExit
            do {
                exit = try ProcessExit(running: process)
            } catch {
                throw GitHubCLIFailure.couldNotStart
            }
            let timeoutTask = Task {
                do { try await Task.sleep(for: timeout) } catch { return false }
                guard process.isRunning else { return false }
                NativeProcessTree.terminate(process: process)
                return true
            }
            // Both pipes drain at once, so neither fills while the other is read.
            let errorRead = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = await errorRead.value
            let ended = await exit.wait(timeout: timeout)
            timeoutTask.cancel()
            if await timeoutTask.value || !ended {
                NativeProcessTree.terminate(process: process)
                throw GitHubCLIFailure.timedOut
            }
            return GitHubCLIOutput(status: process.terminationStatus, output: data,
                                   errorText: String(decoding: errorData.prefix(16 * 1024), as: UTF8.self))
        }.value
    }
}

/// Asks GitHub, through the person's `gh`, for a pull request's state, its checks and its review.
struct GitHubPullRequestClient: Sendable {
    enum Answer: Equatable, Sendable {
        case found(TaskPullRequest)
        /// GitHub says the branch has no pull request.
        case none
        /// No `gh`, signed out of it, offline, too slow, or an answer Yardlet cannot read. What was
        /// known stays; nothing prompts.
        case unavailable
    }

    let cli: any GitHubCLIRunning
    var timeout: Duration = .seconds(20)

    /// The pull request a transcript named, by its link.
    func pullRequest(at url: URL, in folder: URL) async -> Answer {
        await view([url.absoluteString], in: folder, source: .transcriptLink)
    }

    /// The pull request of the folder's current branch, as `gh pr view` finds it (the branch's
    /// upstream when it has one).
    func pullRequest(forBranch branch: String, in folder: URL) async -> Answer {
        await view([], in: folder, source: .branch(branch))
    }

    private func view(_ selector: [String], in folder: URL, source: TaskPullRequest.Source) async -> Answer {
        let output: GitHubCLIOutput
        do {
            output = try await cli.run(["pr", "view"] + selector + ["--json", GitHubPullRequestStatus.fields],
                                       in: folder, timeout: timeout)
        } catch {
            return .unavailable
        }
        guard output.status == 0 else {
            // `gh pr view` on a branch without one: "no pull requests found for branch …".
            if case .branch = source, output.errorText.lowercased().contains("no pull requests found") {
                return .none
            }
            return .unavailable
        }
        return GitHubPullRequestStatus.parse(output.output, source: source).map(Answer.found) ?? .unavailable
    }
}

/// When Yardlet asks GitHub again about a task's pull request. It asks only about tasks on screen —
/// the one in the title bar and the sidebar rows in view: once when a task comes into view, and again
/// after `refreshInterval` (the title bar's) or `rowRefreshInterval` (a row's) while it stays.
struct TaskPullRequestRefreshPolicy: Equatable, Sendable {
    enum Occasion: Equatable, Sendable {
        /// The task has just come into view.
        case shown
        /// A periodic look at a task that stayed in view, or its turn just ended.
        case stillShown
    }

    /// How long the task in the title bar goes before GitHub is asked again.
    var refreshInterval: TimeInterval = 180
    /// How long a task only a sidebar row shows goes before GitHub is asked again.
    var rowRefreshInterval: TimeInterval = 300
    /// A task shown again within this long of the last answer is not asked again.
    var minimumInterval: TimeInterval = 60
    /// How many `gh` commands run at once; the rest wait their turn.
    var maximumConcurrentQueries = 2

    /// - Parameters:
    ///   - lastAsked: when GitHub was last asked about what the task names now, nil if never.
    ///   - isFocused: the task is in the title bar, not only in a sidebar row.
    ///   - subjectChanged: the transcript names another pull request, or the folder is on another
    ///     branch, than the last time GitHub was asked.
    ///   - settled: what GitHub last said cannot change any more (merged).
    func shouldAsk(lastAsked: Date?, now: Date, occasion: Occasion, isFocused: Bool = true,
                   subjectChanged: Bool, settled: Bool) -> Bool {
        if subjectChanged { return true }
        guard let lastAsked else { return true }
        if settled { return false }
        let elapsed = now.timeIntervalSince(lastAsked)
        if occasion == .shown { return elapsed >= minimumInterval }
        return elapsed >= (isFocused ? refreshInterval : rowRefreshInterval)
    }
}

/// A task Yardlet shows, as the pull request lookup needs it.
struct TaskPullRequestTarget: Equatable, Sendable {
    let taskID: UUID
    let workspaceURL: URL
    /// A Claude Code task's conversation, whose transcript may name its pull request.
    let claudeConversation: ClaudeConversationReference?
    /// A turn is running. When it ends, the transcript is read again: the turn may have opened one.
    let isWorking: Bool

    init(taskID: UUID, workspaceURL: URL, claudeConversation: ClaudeConversationReference?, isWorking: Bool) {
        self.taskID = taskID
        self.workspaceURL = workspaceURL
        self.claudeConversation = claudeConversation
        self.isWorking = isWorking
    }

    /// The task's folder, and for a Claude Code task its conversation in its account's config folder.
    init(session: SessionRecord, environment: [String: String] = TaskPullRequestTarget.environment) {
        let conversation: ClaudeConversationReference? = session.harness == .claudeCode
            ? session.providerSessionID.flatMap { id in
                id.isEmpty ? nil : ClaudeConversationReference(
                    taskID: session.id, providerSessionID: id,
                    configDirectory: ClaudeSubagentTranscriptReader.configDirectory(
                        connection: session.connection, environment: environment, workspaceURL: session.workspaceURL))
            }
            : nil
        self.init(taskID: session.id, workspaceURL: session.workspaceURL, claudeConversation: conversation,
                  isWorking: session.status == .running || session.status == .waitingForApproval)
    }

    /// Yardlet's own environment, read once: rows build targets as they draw.
    static let environment = ProcessInfo.processInfo.environment
}

/// Where the lookup reads, each run off the main actor.
struct TaskPullRequestSources: Sendable {
    /// The newest `pr-link` of a Claude conversation, continuing the last scan of its transcript;
    /// nil when there is no transcript to read.
    var scanLink: @Sendable (ClaudeConversationReference, ClaudePullRequestLinkScan?) -> ClaudePullRequestLinkScan?
    /// The folder's branch to ask GitHub about (`branchToAsk(in:)`).
    var gitHubBranch: @Sendable (URL) -> String?
    var gitHub: GitHubPullRequestClient

    /// The person's own `gh` and the folder's Git files; `scanLink` reads Claude's transcripts.
    static func live(
        scanLink: @escaping @Sendable (ClaudeConversationReference, ClaudePullRequestLinkScan?) -> ClaudePullRequestLinkScan?
    ) -> TaskPullRequestSources {
        TaskPullRequestSources(scanLink: scanLink, gitHubBranch: { branchToAsk(in: $0) },
                               gitHub: GitHubPullRequestClient(cli: LocalGitHubCLI()))
    }

    /// The branch a folder is on, when GitHub could have a pull request from it: the folder is in a
    /// repository with a GitHub remote, HEAD is on a branch, and the branch is not the remote's
    /// default one (`main` in most), which a pull request goes into rather than comes from. Read from
    /// Git's files, without starting Git.
    static func branchToAsk(in folder: URL, reader: GitMetadataReader = .live) -> String? {
        guard GitWorktreeOriginResolver.hasGitHubRemote(folder, reader: reader),
              let branch = GitWorktreeOriginResolver.currentBranch(folder, reader: reader),
              !GitWorktreeOriginResolver.defaultBranches(folder, reader: reader).contains(branch) else { return nil }
        return branch
    }
}
