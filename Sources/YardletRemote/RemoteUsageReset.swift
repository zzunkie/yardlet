import Foundation

/// The task account's banked-reset confirmation (§15.31), without login or provider reset identifiers.
public struct RemoteUsageReset: Codable, Equatable, Sendable {
    public struct Metric: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var usedFraction: Double?
        public var detail: String
        public var resetsAt: Int64?
        public var windowMinutes: Double?
        public var model: String?
        public init(id: String, label: String, usedFraction: Double?, detail: String, resetsAt: Int64?, windowMinutes: Double?, model: String?) {
            self.id = id; self.label = label; self.usedFraction = usedFraction; self.detail = detail
            self.resetsAt = resetsAt; self.windowMinutes = windowMinutes; self.model = model
        }
    }
    public var token: String
    public var title: String
    public var availableCount: Int
    public var resetTitle: String?
    public var expiresAt: Int64?
    public var metrics: [Metric]
    /// `using`, `reset`, `nothingToReset`, `noResets`, or `failed`; absent before confirmation.
    public var state: String?
    public var left: Int?
    public init(token: String, title: String, availableCount: Int, resetTitle: String?, expiresAt: Int64?, metrics: [Metric], state: String?, left: Int?) {
        self.token = token; self.title = title; self.availableCount = availableCount
        self.resetTitle = resetTitle; self.expiresAt = expiresAt; self.metrics = metrics; self.state = state; self.left = left
    }
}
