import Foundation

/// Whether a task's review offers Last turn, and the diff when the task has a turn.
enum ReviewLastTurn: Equatable, Sendable {
    case notOffered
    case offered(CodexLastTurnDiff?)

    var isOffered: Bool { self != .notOffered }

    var diff: CodexLastTurnDiff? {
        if case let .offered(diff) = self { diff } else { nil }
    }

    /// A shared transcript's Last turn: offered once a call in it reported the file change it made
    /// (Claude Code's Edit and Write, an ACP or Pi edit), with the latest turn's applied changes (D8).
    static func transcript(
        _ entries: [TranscriptEntry], harness: HarnessKind, isRunning: Bool, workspaceURL: URL
    ) -> ReviewLastTurn {
        guard ConversationFileChangeProjection.carriesFileChanges(entries) else { return .notOffered }
        return .offered(ConversationFileChangeProjection.lastTurnDiff(
            entries: entries, harness: harness, isRunning: isRunning, workspaceURL: workspaceURL
        ))
    }
}

/// The Review pane's reads and its Stage, Unstage and Discard, independent of where its repository lives.
protocol GitDiffReading: Sendable {
    var isRemote: Bool { get }
    /// Why Stage, Unstage and Discard cannot be offered here, in the person's words; nil when they are.
    var mutationUnavailableReason: String? { get }
    func lastTurn() async throws -> ReviewLastTurn?
    func repositories(containing roots: [URL]) async throws -> [URL]
    func load(workspaceURL: URL, target: GitDiffTarget) async throws -> DiffSnapshot
    func recentCommits(workspaceURL: URL, limit: Int) async throws -> [GitCommitSummary]
    func baseBranch(workspaceURL: URL) async throws -> GitBaseBranch
    func repositoryRoot(workspaceURL: URL) async throws -> URL
    func fileText(workspaceURL: URL, revision: String, path: String) async throws -> String?
    func workingText(_ url: URL) async throws -> String?
    /// Applies `action` to the changes `expected` shows, refusing when they have changed since.
    func mutate(_ action: GitMutation, workspaceURL: URL, expected: DiffSnapshot) async throws
}

extension GitDiffReading {
    func lastTurn() async throws -> ReviewLastTurn? { nil }
}

extension GitDiffService: GitDiffReading {
    nonisolated var isRemote: Bool { false }
    nonisolated var mutationUnavailableReason: String? { nil }
    func workingText(_ url: URL) async throws -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
