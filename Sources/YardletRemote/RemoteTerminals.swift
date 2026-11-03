import Foundation

public enum RemoteTerminalUpdate: Sendable {
    case output(Data)
    case exited(Int32?)
}

/// The bridge checks this immediately before starting or writing the PTY. Revocation is synchronous,
/// including while an actor call is suspended. Output reservations bound callbacks before they enqueue work.
public final class RemoteTerminalPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var bytes = 0
    private var chunks = 0
    private var exited = false

    public init() {}
    public var isValid: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
    private var pending: [RemoteTerminalUpdate] = []
    private var notified = false
    enum EnqueueResult { case notify, queued, overflow, ended }

    /// At most one callback task waits on the server, preserving byte order even across actor hops.
    func enqueue(_ update: RemoteTerminalUpdate) -> EnqueueResult {
        lock.withLock {
            guard valid else { return .ended }
            switch update {
            case let .output(data):
                guard !data.isEmpty else { return .queued }
                guard !exited, data.count <= RemoteProtocol.maxTerminalChunkBytes,
                      chunks < 64, bytes + data.count <= 256 * 1024 else {
                    valid = false
                    pending.removeAll()
                    return .overflow
                }
                bytes += data.count
                chunks += 1
            case .exited:
                guard !exited else { return .ended }
                exited = true
            }
            pending.append(update)
            guard !notified else { return .queued }
            notified = true
            return .notify
        }
    }

    func takeUpdates() -> [RemoteTerminalUpdate] {
        lock.withLock {
            let updates = pending
            pending.removeAll(keepingCapacity: true)
            notified = false
            return updates
        }
    }

    func release(_ count: Int) {
        lock.withLock { bytes = max(0, bytes - count); chunks = max(0, chunks - 1) }
    }
}

extension RemoteProtocol {
    public static let maxTerminalChunkBytes = 16 * 1024
    public static let maxTerminalsPerConnection = 4
    public static let maxTerminalsTotal = 16
    public static let terminalColumns = 2...500
    public static let terminalRows = 2...300
}
