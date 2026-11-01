import Foundation

/// The thumbnails of the pictures in a dot's conversation, for one connection to one account: decoded
/// off the main thread at a bounded size (`TranscriptImageThumbnails`), kept in memory only, within a
/// cost limit, and dropped with the whole object when the connection or account changes. Pictures are
/// read only as their rows ask, at most two at a time as the provider's room does, and a row that
/// leaves before its turn comes reads nothing.
@MainActor
final class PersonalAgentThumbnails {
    static let concurrentReads = 2
    static let costLimit = 64 * 1_048_576

    private let previews: TranscriptImageThumbnails
    /// Pictures whose last read or decoding failed, by key and size; each waits for its retry.
    private var failed: Set<String> = []
    private var reading = 0
    private var waiting: [(id: UUID, resume: CheckedContinuation<Bool, Never>)] = []
    /// How many pictures were read from the room, and the most read at once; tests read them.
    private(set) var reads = 0
    private(set) var mostAtOnce = 0

    init(keepsEntriesForTesting: Bool = false) {
        previews = TranscriptImageThumbnails(costLimit: Self.costLimit, keepsEntriesForTesting: keepsEntriesForTesting)
    }

    /// Names a room file's picture across the room and its reply threads.
    static func key(room: String, file: String) -> String { room + "/" + file }

    private static func entry(_ key: String, _ size: TranscriptImageThumbnails.Size) -> String {
        key + "#" + size.rawValue
    }

    /// The thumbnail already decoded, or `.unavailable` while its failure waits for a retry; nil
    /// when it is still to be read.
    func cached(_ key: String, size: TranscriptImageThumbnails.Size) -> TranscriptImageThumbnails.Preview? {
        if failed.contains(Self.entry(key, size)) { return .unavailable }
        if case let .image(image)? = previews.cachedPreview(forKey: key, size: size) { return .image(image) }
        return nil
    }

    func fail(_ key: String, size: TranscriptImageThumbnails.Size) { failed.insert(Self.entry(key, size)) }
    func retry(_ key: String, size: TranscriptImageThumbnails.Size) { failed.remove(Self.entry(key, size)) }
    /// A new connection to the same account may read what the last one could not.
    func forgetFailures() { failed = [] }

    func decode(_ data: Data, key: String, size: TranscriptImageThumbnails.Size) async -> TranscriptImageThumbnails.Preview {
        await previews.preview(of: data, forKey: key, size: size)
    }

    /// Waits for one of the reading slots; false when the waiting task was cancelled first.
    func slot() async -> Bool {
        if reading < Self.concurrentReads {
            take()
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiting(id) }
        }
    }

    /// Hands the slot to the next waiting read, or frees it.
    func release() {
        if waiting.isEmpty { reading -= 1 }
        else { waiting.removeFirst().resume.resume(returning: true) }
    }

    func noteRead() { reads += 1 }

    private func take() {
        reading += 1
        mostAtOnce = max(mostAtOnce, reading)
    }

    private func stopWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(returning: false)
    }
}
