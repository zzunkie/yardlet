import Foundation

/// Read-only Review operations. All paths are host paths, scoped to the named task.
public struct RemoteReviewQuery: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case repositories, commits, baseBranch, root, diff, text, lastTurn }
    public var operation: Operation
    public var repository: String?
    public var target: String?
    public var revision: String?
    public var path: String?
    public init(_ operation: Operation, repository: String? = nil, target: String? = nil,
                revision: String? = nil, path: String? = nil) {
        self.operation = operation; self.repository = repository; self.target = target
        self.revision = revision; self.path = path
    }
    public var isValid: Bool {
        [repository, path].allSatisfy { $0 == nil || ($0!.utf8.count <= 4096 && !$0!.utf8.contains(0)) }
            && (revision == nil || (revision!.utf8.count <= 256 && !revision!.utf8.contains(0)))
            && (target == nil || ["unstaged", "staged", "commit", "branch"].contains(target!))
    }
}

public struct RemoteReviewCommit: Codable, Equatable, Sendable {
    public var id: String
    public var shortID: String
    public var subject: String
    public var timestamp: Int64
    public init(id: String, shortID: String, subject: String, timestamp: Int64) {
        self.id = id; self.shortID = shortID; self.subject = subject; self.timestamp = timestamp
    }
}

public struct RemoteReviewResult: Codable, Equatable, Sendable {
    public var lastTurnOffered: Bool?
    public var turnID: String?
    public var isRunning: Bool?
    public var repositories: [String]?
    public var commits: [RemoteReviewCommit]?
    public var root: String?
    /// A ref name, or "missing" / "current".
    public var baseBranch: String?
    /// Unified diff, or the Markdown file's new text for a text request.
    public var text: String?
    public var truncated: Bool?
    public init() {}
}
