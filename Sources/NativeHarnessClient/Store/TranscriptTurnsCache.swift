import Foundation

/// The turns of the transcripts the window draws (`TranscriptTurns`), kept between publications with
/// what changed since, so that a publication of a long conversation is split and compared only where it
/// changed. Only the tasks read lately are kept: a task read again after it was let go is split anew,
/// once. Nothing observes it; the views that read it observe the transcript itself.
@MainActor
final class TranscriptTurnsCache {
    /// The tasks kept: as many as a window keeps the views of, and a few more.
    static let limit = 8

    private var kept: [UUID: (turns: TranscriptTurns, change: TranscriptChange)] = [:]
    /// The tasks kept, the latest read last.
    private var order: [UUID] = []
    private var publishing: (id: UUID, change: TranscriptChange)?

    /// The next time `id`'s transcript is set, it is a publication that made `change`.
    func willPublish(_ change: TranscriptChange, for id: UUID) {
        publishing = (id, change)
    }

    /// `id`'s transcript was set: by a publication, which said what it changed, or by anything else,
    /// which says nothing.
    func transcriptChanged(_ id: UUID) {
        let change = publishing?.id == id ? publishing?.change ?? .unknown : .unknown
        publishing = nil
        guard let earlier = kept[id] else { return }
        kept[id]?.change = earlier.change.then(change)
    }

    /// The turns of `entries`, `id`'s transcript as it is now.
    func turns(_ entries: [TranscriptEntry], of id: UUID) -> TranscriptTurns {
        let turns = kept[id].map { $0.turns.updated(to: entries, change: $0.change) } ?? TranscriptTurns(entries)
        if kept[id] == nil {
            order.append(id)
            if order.count > Self.limit { kept.removeValue(forKey: order.removeFirst()) }
        } else if order.last != id {
            order.removeAll { $0 == id }
            order.append(id)
        }
        kept[id] = (turns, .none(entries.count))
        return turns
    }
}
