import Foundation

public struct RemoteSubtaskTranscript: Codable, Equatable, Sendable {
    public var items: [RemoteItem]
    public var truncated: Bool
    public init(items: [RemoteItem] = [], truncated: Bool = false) {
        self.items = items; self.truncated = truncated
    }
}
