import Foundation

public enum RemoteFileRewindAction: String, Codable, Sendable {
    case points, preview, restore
}

/// A task-scoped checkpoint and reviewed receipt. Provider storage and file fingerprints stay on the host.
public struct RemoteFileRewind: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public var points: [Point]?
    public var receipt: String?
    public var canRewind: Bool?
    public var files: [String]?
    public var insertions: Int?
    public var deletions: Int?
    public var skippedLinks: Int?
    public var inFlight: Bool?
    public init() {}
}
