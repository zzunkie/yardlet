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
    public init() {}
}
