import Foundation

/// Keeps the app-local Codex cards each task has saved in memory. A streaming Codex task merges
/// them into every timeline state it publishes; reading and decoding them from storage each
/// time cost the main thread more than anything else the stream did. Every read and write of
/// the app model goes through this cache, so it always matches what is stored.
///
/// Saving writes in the background: a task's cards are a JSON file of several megabytes, and a
/// streaming turn saves them as cards are added and settle. Writes for a task keep their order,
/// a write still waiting gives way to a newer one, and `flushed()` returns once all are done.
final class CachedCodexTimelineItemRepository: CodexTimelineItemRepository {
    private let base: any CodexTimelineItemRepository
    private let writer: CodexCardWriter
    private var items: [UUID: [CodexPersistedTimelineItem]] = [:]

    init(_ base: any CodexTimelineItemRepository) {
        self.base = base
        self.writer = CodexCardWriter(base)
    }

    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem] {
        if let cached = items[sessionID] { return cached }
        // Nothing waits to be written for a task that is not cached yet.
        let loaded = base.load(for: sessionID)
        items[sessionID] = loaded
        return loaded
    }

    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID) {
        self.items[sessionID] = items
        writer.enqueue(.save(items), for: sessionID)
    }

    func remove(for sessionID: UUID) {
        items[sessionID] = []
        writer.enqueue(.remove, for: sessionID)
    }

    /// Returns once every save and removal handed over so far is written.
    @MainActor
    func flushed() async {
        await writer.flushed()
    }
}

/// The background half of `CachedCodexTimelineItemRepository`. `waiting` holds each task's newest
/// write not yet started; a task has at most one block on the queue for it.
private final class CodexCardWriter: @unchecked Sendable {
    enum Write {
        case save([CodexPersistedTimelineItem])
        case remove
    }

    private let base: any CodexTimelineItemRepository
    private let queue = DispatchQueue(label: "Yardlet.CodexCards", qos: .utility)
    private let lock = NSLock()
    private var waiting: [UUID: Write] = [:]

    init(_ base: any CodexTimelineItemRepository) {
        self.base = base
    }

    func enqueue(_ write: Write, for sessionID: UUID) {
        let queued = lock.withLock {
            defer { waiting[sessionID] = write }
            return waiting[sessionID] != nil
        }
        guard !queued else { return }
        queue.async { [self] in
            guard let write = lock.withLock({ waiting.removeValue(forKey: sessionID) }) else { return }
            switch write {
            case let .save(items): base.save(items, for: sessionID)
            case .remove: base.remove(for: sessionID)
            }
        }
    }

    func flushed() async {
        let queue = queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }
}

/// The same in-memory copy for the Codex approvals and questions a task has saved.
final class CachedCodexPendingServerRequestRepository: CodexPendingServerRequestRepository {
    private let base: any CodexPendingServerRequestRepository
    private var requests: [UUID: [CodexPendingServerRequest]] = [:]

    init(_ base: any CodexPendingServerRequestRepository) {
        self.base = base
    }

    func load(for sessionID: UUID) -> [CodexPendingServerRequest] {
        if let cached = requests[sessionID] { return cached }
        let loaded = base.load(for: sessionID)
        requests[sessionID] = loaded
        return loaded
    }

    func save(_ requests: [CodexPendingServerRequest], for sessionID: UUID) {
        self.requests[sessionID] = requests
        base.save(requests, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        requests[sessionID] = []
        base.remove(for: sessionID)
    }
}
