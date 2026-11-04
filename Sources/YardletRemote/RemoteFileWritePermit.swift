import Foundation

/// A live device grant for one pending write, revoked synchronously when permission or connection ends.
/// The caller checks immediately before dispatching the irreversible operation, after any awaited preparation.
public final class RemoteFileWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isValid: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
}
