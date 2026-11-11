import Foundation

/// A subscription plan limit as the provider reported it on its own stream: the window that
/// limits the account now, and every window the same response measured.
struct HarnessRateLimit: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case allowed
        /// Still served, but close to the limiting window's cap.
        case warning
        /// Refused until the limiting window resets.
        case rejected
    }

    /// The plan limit a provider named. A weekly limit that covers one model keeps that model's
    /// name beside it.
    enum Window: String, Codable, Sendable {
        case session
        case weekly
        case model
        case overage
    }

    struct WindowUsage: Codable, Equatable, Sendable {
        let window: Window
        let model: String?
        /// The fraction of the window used. Above 1 when usage legitimately ran past the cap.
        let usedFraction: Double
        let resetsAt: Date?
    }

    var status: Status
    var window: Window?
    var model: String?
    var resetsAt: Date?
    var usedFraction: Double?
    /// Paid extra usage is covering the request, so nothing is cut off.
    var isUsingOverage = false
    var windows: [WindowUsage] = []
    /// The provider's own words for a request the limit stopped, when it wrote any.
    var message: String?
}

/// A provider request that failed in a way the provider retries on its own.
struct HarnessProviderRetry: Codable, Equatable, Sendable {
    enum Cause: String, Codable, Sendable {
        case overloaded
        case rateLimited
        case serverError
        case connection
        case other
    }

    let attempt: Int
    let maxRetries: Int
    let cause: Cause
}

/// The provider summarizing earlier conversation to free its context window.
struct HarnessContextCompaction: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case started
        case completed
        case failed
    }

    var phase: Phase
    var tokensBefore: UInt64? = nil
    var tokensAfter: UInt64? = nil
    /// The provider's reason, for a compaction that failed.
    var message: String? = nil
    /// Yardlet compacted the idle task before its prompt cache expired (`IdleCompaction`), as Claude
    /// Code notes its own. Nil for every other compaction, and left out of the saved shape then.
    var whileIdle: Bool? = nil
    /// The provider's own ID for it, which its saved conversation keeps (Claude Code's `compact_boundary`
    /// uuid). Nil where the provider gives none, and left out of the saved shape then.
    var providerID: String? = nil

    var savedTokens: UInt64? {
        guard let tokensBefore, let tokensAfter, tokensBefore > tokensAfter else { return nil }
        return tokensBefore - tokensAfter
    }
}
