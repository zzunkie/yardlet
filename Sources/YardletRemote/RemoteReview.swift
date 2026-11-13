import Crypto
import Foundation

/// Review reads (`readReview`). All paths are host paths, scoped to the named task.
public struct RemoteReviewQuery: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case context, repositories, commits, baseBranch, root, diff, text, lastTurn }
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
    /// Disclosed only when the task's Review panel asks, never in the general task snapshot.
    public var workspace: String?
    public var additionalRoots: [String]?
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

/// A Review change: Stage all, Unstage all or Discard, on the changes the client last read (§15.26). It names no
/// path: the host acts on its own fresh diff of the repository, and only when that diff is still the one the client
/// reviewed, which `expected` identifies.
public struct RemoteReviewChange: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable, CaseIterable { case stage, unstage, discard }
    public var action: Action
    /// A host repository as `readReview` names it; nil for the task's folder.
    public var repository: String?
    /// `fingerprint(_:)` of the `diff` text the client reviewed: unstaged changes for stage and discard, staged ones
    /// for unstage.
    public var expected: String
    public init(_ action: Action, repository: String? = nil, expected: String) {
        self.action = action; self.repository = repository; self.expected = expected
    }

    public var isValid: Bool {
        (repository.map { $0.utf8.count <= 4096 && !$0.utf8.contains(0) } ?? true)
            && expected.utf8.count == 64 && expected.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The lowercase hexadecimal SHA-256 of a review's unified diff text.
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
