import Foundation
import YardletRemote

struct RemoteGitDiffReading: GitDiffReading {
    let isRemote = true
    let taskID: String
    let workspaceURL: URL
    private let hostName: String
    let read: @MainActor @Sendable (RemoteRequest) async -> RemoteResponse

    @MainActor init(model: RemoteHostModel, taskID: String, workspaceURL: URL) {
        self.taskID = taskID; self.workspaceURL = workspaceURL; hostName = model.name
        read = { [weak model] request in
            guard let model else { return .failure("", RemoteError(.unavailable)) }
            return await model.response(to: request)
        }
    }

    init(taskID: String, workspaceURL: URL,
         read: @escaping @MainActor @Sendable (RemoteRequest) async -> RemoteResponse) {
        self.taskID = taskID; self.workspaceURL = workspaceURL; self.read = read; hostName = "Host"
    }

    private struct ReadFailure: LocalizedError { let errorDescription: String? }

    private func request(_ query: RemoteReviewQuery) async throws -> RemoteReviewResult {
        let response = await read(.readReview(taskID: taskID, query: query))
        guard response.ok, let review = response.review else {
            if response.error?.code == .notFound { throw GitDiffServiceError.notARepository }
            let message = await MainActor.run {
                response.error?.code == .notAllowed
                    ? L10n.string("This repository is outside the task's folders.")
                    : RemoteHostModel.message(for: response.error, host: hostName)
            }
            throw ReadFailure(errorDescription: message)
        }
        return review
    }
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
