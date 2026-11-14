import Foundation

public enum RemoteTerminalUpdate: Sendable {
    case output(Data)
    /// The shell's size from the next output on (§15.29).
    case resized(columns: Int, rows: Int)
    case exited(Int32?)
}

public struct RemoteTerminalStatus: Equatable, Sendable {
    public var isAtPrompt: Bool
    public var isRunningProgram: Bool
    public var workspaceRoot: String?
    public init(isAtPrompt: Bool, isRunningProgram: Bool, workspaceRoot: String? = nil) {
        self.isAtPrompt = isAtPrompt
        self.isRunningProgram = isRunningProgram
        self.workspaceRoot = workspaceRoot
    }
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
    private var pending: [RemoteTerminalUpdate] = []
    private var notified = false
    private var waiting: (RemoteTerminalUpdate, CheckedContinuation<EnqueueResult, Never>)?
    enum EnqueueResult: Sendable { case notify, queued, overflow, ended }

    var isWaitingForCapacity: Bool { lock.withLock { waiting != nil } }
    var bufferedByteCount: Int { lock.withLock { bytes } }

    public func revoke() {
        let continuation = lock.withLock {
            valid = false
            pending.removeAll()
            let continuation = waiting?.1
            waiting = nil
            return continuation
        }
        continuation?.resume(returning: .ended)
    }

    /// One producer awaits each chunk before reading more from its PTY. At most one extra chunk waits
    /// for room, outside the 256 KiB/64-chunk budget. Neither the main actor nor an actor thread blocks.
    func enqueue(_ update: RemoteTerminalUpdate) async -> EnqueueResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result: EnqueueResult? = lock.withLock {
                    guard valid else { return .ended }
                    guard waiting == nil else { return .overflow }
                    if case let .output(data) = update {
                        guard !data.isEmpty else { return .queued }
                        guard !exited, data.count <= RemoteProtocol.maxTerminalChunkBytes else { return .overflow }
                        if chunks >= 64 || bytes + data.count > 256 * 1024 {
                            waiting = (update, continuation)
                            return nil
                        }
                    }
                    return append(update)
                }
                if let result {
                    if case .overflow = result { revoke() }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { self.revoke() }
    }

    /// Called with the lock held.
    private func append(_ update: RemoteTerminalUpdate) -> EnqueueResult {
        switch update {
        case let .output(data): bytes += data.count; chunks += 1
        case .resized:
            // Only the latest size before the next output matters, so these take no room.
            if case .resized = pending.last { pending.removeLast() }
        case .exited:
            guard !exited else { return .ended }
            exited = true
        }
        pending.append(update)
        guard !notified else { return .queued }
        notified = true
        return .notify
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
        let resumed: (CheckedContinuation<EnqueueResult, Never>, EnqueueResult)? = lock.withLock {
            bytes = max(0, bytes - count)
            chunks = max(0, chunks - 1)
            guard valid, let (update, continuation) = waiting else { return nil }
            if case let .output(data) = update, chunks >= 64 || bytes + data.count > 256 * 1024 { return nil }
            waiting = nil
            return (continuation, append(update))
        }
        if let (continuation, result) = resumed { continuation.resume(returning: result) }
    }

}

extension RemoteProtocol {
    public static let maxTerminalChunkBytes = 16 * 1024
    public static let maxTerminalsPerConnection = 4
    public static let maxTerminalsTotal = 16
    public static let terminalColumns = 2...500
    public static let terminalRows = 2...300
}
