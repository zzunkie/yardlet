import Foundation

public struct RemoteTaskPullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var url: String
    public var repository: String?
    public var state: String?
    public var checks: String?
    public var review: String?
    public init(number: Int, url: String, repository: String?, state: String?, checks: String?, review: String?) {
        self.number = number; self.url = url; self.repository = repository
        self.state = state; self.checks = checks; self.review = review
    }
}

/// Sidebar mutations use host IDs only; values are never audit-log fields (§15.32).
public struct RemoteTaskAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case rename, markUnread, move, nest, delete, unarchive, resume, chooseAccount }
    public var kind: Kind
    public var value: String?
    public var confirmed: Bool
    public init(_ kind: Kind, value: String? = nil, confirmed: Bool = false) {
        self.kind = kind; self.value = value; self.confirmed = confirmed
    }
}

extension RemoteAccount {
    /// Presentation only. A state introduced by a newer host is unavailable to this client.
    public enum State: String, Codable, Sendable {
        case signedIn, signedOut, actionRequired, unavailable, unknown

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = (try? container.decode(String.self)).flatMap(Self.init(rawValue:)) ?? .unavailable
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

public struct RemoteArchivedTask: Codable, Equatable, Sendable {
    public var task: RemoteTask
    public var archivedAt: Int64
    public var projectName: String?
    public init(task: RemoteTask, archivedAt: Int64, projectName: String? = nil) {
        self.task = task; self.archivedAt = archivedAt; self.projectName = projectName
    }
}

public struct RemoteArchivePage: Sendable {
    public var tasks: [RemoteArchivedTask]
    public var cursor: String?
    public init(tasks: [RemoteArchivedTask], cursor: String?) { self.tasks = tasks; self.cursor = cursor }
}
