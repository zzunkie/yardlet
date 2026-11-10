import Foundation

public struct RemoteTaskNotices: Codable, Equatable, Sendable {
    public var resumedAfterRestart: Bool?
    public var reconnecting: Bool?
    public var warning: RemoteLimit?
    public var warningReset: Int64?
    public var missingFolder: String?
    public var worktreeBranch: String?
    public var accountName: String?
    public var accountMoveInTurn: Bool?
    /// The task's last error where the host shows it above the composer, in the host's words (§15.31).
    public var error: String?
    public init() {}
}
