import Foundation
import YardletRemote

struct RemoteGitDiffReading: GitDiffReading {
    let isRemote = true
    let taskID: String
    /// An older host reads its Review for this window but does not change it (§15.26).
    let mutationUnavailableReason: String?
    private let hostName: String
    let read: @MainActor @Sendable (RemoteRequest) async -> RemoteResponse

    @MainActor init(model: RemoteHostModel, taskID: String) {
        self.taskID = taskID; hostName = model.name
        mutationUnavailableReason = model.offersReviewChanges
            ? nil : L10n.string("Update Yardlet on the host to use this panel.")
        read = { [weak model] request in
            guard let model else { return .failure("", RemoteError(.unavailable)) }
            return await model.response(to: request)
        }
    }

    init(taskID: String,
         read: @escaping @MainActor @Sendable (RemoteRequest) async -> RemoteResponse) {
        self.taskID = taskID; self.read = read; hostName = "Host"; mutationUnavailableReason = nil
    }

    private struct ReadFailure: LocalizedError { let errorDescription: String? }

    private func request(_ query: RemoteReviewQuery) async throws -> RemoteReviewResult {
        let response = await read(.readReview(taskID: taskID, query: query))
        guard response.ok, let review = response.review else { throw await failure(response.error) }
        return review
    }

    /// A refusal in the local Review's words where it has them: no repository, or changes that changed since.
    private func failure(_ error: RemoteError?) async -> any Error {
        if error?.code == .notFound { return GitDiffServiceError.notARepository }
        if error?.code == .notAllowed, error?.reason == .changing { return GitDiffServiceError.changedSinceReview }
        let message = await MainActor.run {
            error?.code == .notAllowed && error?.reason == nil
                ? L10n.string("This repository is outside the task's folders.")
                : RemoteHostModel.message(for: error, host: hostName)
        }
        return ReadFailure(errorDescription: message)
    }

    /// Names no path: the host acts on its own diff when it is still the one `expected` shows (§15.26).
    func mutate(_ action: GitMutation, workspaceURL: URL, expected: DiffSnapshot) async throws {
        if let mutationUnavailableReason { throw ReadFailure(errorDescription: mutationUnavailableReason) }
        let kind: RemoteReviewChange.Action = switch action {
        case .stage: .stage
        case .unstage: .unstage
        case .discard: .discard
        }
        let change = RemoteReviewChange(kind, repository: workspaceURL.path,
                                        expected: RemoteReviewChange.fingerprint(expected.text))
        // Discard reaches here only from its confirmation sheet.
        let response = await read(.writeReview(taskID: taskID, change: change, confirmed: action == .discard))
        if !response.ok { throw await failure(response.error) }
    }
    func context() async throws -> RemoteReviewResult { try await request(.init(.context)) }

    func lastTurn() async throws -> ReviewLastTurn? {
        let result = try await request(.init(.lastTurn))
        guard result.lastTurnOffered == true else { return .notOffered }
        return .offered(result.turnID.map {
            CodexLastTurnDiff(turnID: $0, text: result.text ?? "", isRunning: result.isRunning == true,
                              isTruncated: result.truncated == true)
        })
    }
    func repositories(containing roots: [URL]) async throws -> [URL] {
        try await request(.init(.repositories)).repositories?.map { URL(filePath: $0) } ?? []
    }
    func repositoryRoot(workspaceURL: URL) async throws -> URL {
        let result = try await request(.init(.root, repository: workspaceURL.path))
        guard let root = result.root else { throw RemoteError(.unavailable) }
        return URL(filePath: root)
    }
    func load(workspaceURL: URL, target: GitDiffTarget) async throws -> DiffSnapshot {
        var query = RemoteReviewQuery(.diff, repository: workspaceURL.path)
        switch target {
        case .unstaged: query.target = "unstaged"
        case .staged: query.target = "staged"
        case let .commit(hash): query.target = "commit"; query.revision = hash
        case .branch: query.target = "branch"
        }
        let result = try await request(query)
        return UnifiedDiffParser().parse(result.text ?? "", isTruncated: result.truncated == true)
    }
    func recentCommits(workspaceURL: URL, limit: Int) async throws -> [GitCommitSummary] {
        try await request(.init(.commits, repository: workspaceURL.path)).commits?.prefix(limit).map {
            GitCommitSummary(id: $0.id, shortID: $0.shortID, subject: $0.subject,
                             date: Date(timeIntervalSince1970: Double($0.timestamp) / 1000))
        } ?? []
    }
    func baseBranch(workspaceURL: URL) async throws -> GitBaseBranch {
        switch try await request(.init(.baseBranch, repository: workspaceURL.path)).baseBranch {
        case "missing", nil: return .missing
        case "current": return .current
        case let ref?: return .found(ref)
        }
    }
    func fileText(workspaceURL: URL, revision: String, path: String) async throws -> String? {
        try await request(.init(.text, repository: workspaceURL.path, revision: revision, path: path)).text
    }
    func workingText(_ url: URL) async throws -> String? {
        try await request(.init(.text, path: url.path)).text
    }
}
