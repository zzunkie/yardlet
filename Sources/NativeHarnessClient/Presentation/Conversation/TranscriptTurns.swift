import Foundation

/// A transcript in its turns: every request opens one (`TranscriptEntry.opensTurn`), and what comes
/// before the first request is a head turn. Each turn keeps its entries in storage of its own, and a
/// transcript updated from the one before it (`updated(to:change:)`) keeps the turns the change left as
/// they were, so whatever compares or projects turns tells those by their storage instead of comparing
/// their entries. A streaming answer at the end of a long conversation then costs the conversation's
/// projection and the session rail the turn it changed, not the whole history: comparing 600 entries
/// one by one alone took half a millisecond of a debug build's main thread, and the window compared
/// the history several times for each publication.
///
/// Entries given as they are split into turns when the turns are first read. Turns are classes that
/// the views of a task share on the main thread; each works out what the conversation and the rail read
/// of it once, when they first ask.
struct TranscriptTurns: Equatable {
    static var empty: TranscriptTurns { TranscriptTurns([]) }

    let entries: [TranscriptEntry]
    private let split: Split

    init(_ entries: [TranscriptEntry]) {
        self.entries = entries
        split = Split()
    }

    private init(entries: [TranscriptEntry], turns: [TranscriptTurn], starts: [Int]) {
        self.entries = entries
        split = Split(turns: turns, starts: starts)
    }

    var turns: [TranscriptTurn] { split.turns(of: entries).turns }

    /// The same transcript after `change`: the turns it left as they were are kept without being
    /// compared, the rest are split again, and a turn whose entries came out the same keeps its turn.
    func updated(to newEntries: [TranscriptEntry], change: TranscriptChange) -> TranscriptTurns {
        if newEntries.sharesStorage(with: entries) { return self }
        let (turns, starts) = split.turns(of: entries)
        // A change that does not fit these entries says nothing.
        let fits = change.dropped + change.kept <= entries.count
        let dropped = fits ? change.dropped : 0
        let known = fits ? min(change.kept, newEntries.count) : 0
        var kept: [TranscriptTurn] = []
        var keptStarts: [Int] = []
        var splitStart = 0
        var keeping = true
        var earlier: [String: (turn: TranscriptTurn, start: Int)] = [:]
        for (index, turn) in turns.enumerated() {
            let start = starts[index] - dropped
            let end = start + turn.entries.count
            // The turn went with the entries dropped before it.
            guard end > 0 else { continue }
            // A turn is kept while all of it is among the entries that stayed the same, and what follows
            // it still opens a turn: entries may have been added at its end.
            if keeping, end <= known, end == newEntries.count || newEntries[end].opensTurn {
                // A turn whose oldest entries were dropped is the rest of it.
                kept.append(start >= 0 ? turn : TranscriptTurn(entries: Array(newEntries[0..<end])))
                keptStarts.append(max(start, 0))
                splitStart = end
            } else {
                keeping = false
                if start >= 0 { earlier[turn.entries[0].id.uuidString] = (turn, start) }
            }
        }
        var start = splitStart
        while start < newEntries.endIndex {
            let end = Split.end(ofTurnAt: start, in: newEntries)
            kept.append(Self.turn(newEntries[start..<end], reusing: earlier, known: known))
            keptStarts.append(start)
            start = end
        }
        return TranscriptTurns(entries: newEntries, turns: kept, starts: keptStarts)
    }

    /// The turn of `entries`: the earlier turn that starts where they do with the same entries, told by
    /// comparing only those after the first `known` of the transcript, which stayed the same.
    private static func turn(_ entries: ArraySlice<TranscriptEntry>,
                             reusing earlier: [String: (turn: TranscriptTurn, start: Int)], known: Int) -> TranscriptTurn {
        if let first = entries.first, let match = earlier[first.id.uuidString], match.start == entries.startIndex,
           match.turn.entries.count == entries.count {
            let compared = min(max(known - entries.startIndex, 0), entries.count)
            if match.turn.entries[compared...].elementsEqual(entries[(entries.startIndex + compared)...]) {
                return match.turn
            }
        }
        return TranscriptTurn(entries: Array(entries))
    }

    /// The same entries, or the same turns of entries of the same length: a transcript updated from
    /// another keeps its turns. Entries that were never split are not compared.
    static func == (lhs: TranscriptTurns, rhs: TranscriptTurns) -> Bool {
        if lhs.entries.sharesStorage(with: rhs.entries) { return true }
        guard lhs.entries.count == rhs.entries.count, let left = lhs.split.made, let right = rhs.split.made,
              left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0 === $1 }
    }

    /// The entries the session rail, the composer and its line of background tasks read
    /// (`SessionRailContent.reads`), in order.
    var railEntries: [TranscriptEntry] {
        turns.flatMap(\.railEntries)
    }

    /// The turns, made when first read.
    private final class Split {
        private(set) var made: [TranscriptTurn]?
        private var starts: [Int] = []

        init() {}

        init(turns: [TranscriptTurn], starts: [Int]) {
            made = turns
            self.starts = starts
        }

        func turns(of entries: [TranscriptEntry]) -> (turns: [TranscriptTurn], starts: [Int]) {
            if let made { return (made, starts) }
            var turns: [TranscriptTurn] = []
            var start = entries.startIndex
            while start < entries.endIndex {
                let end = Self.end(ofTurnAt: start, in: entries)
                turns.append(TranscriptTurn(entries: Array(entries[start..<end])))
                starts.append(start)
                start = end
            }
            made = turns
            return (turns, starts)
        }

        /// Where the turn that starts at `start` ends: at the next request, or at the end.
        static func end(ofTurnAt start: Int, in entries: [TranscriptEntry]) -> Int {
            entries[(start + 1)...].firstIndex(where: \.opensTurn) ?? entries.endIndex
        }
    }
}

/// One turn of a transcript (`TranscriptTurns`), with what the conversation and the rail read of it.
final class TranscriptTurn {
    let entries: [TranscriptEntry]

    init(entries: [TranscriptEntry]) {
        self.entries = entries
    }

    /// The entries the rail and the composer read (`SessionRailContent.reads`).
    private(set) lazy var railEntries: [TranscriptEntry] = entries.filter(SessionRailContent.reads)

    /// The requests that wait for an answer.
    private(set) lazy var pendingRequestIDs: Set<String> = Set(entries.compactMap { entry in
        guard case let .permission(request, .pending) = entry.content else { return nil }
        return request.id
    })

    /// The tool calls an allowed request of the turn names, which read as a mark on the call's card
    /// wherever the call is (`TranscriptConversationProjection.approvedToolCallIDs(in:)`).
    private(set) lazy var allowedToolCallIDs: Set<String> = Set(entries.compactMap { entry in
        guard case let .permission(request, .allowed) = entry.content, request.structured == nil else { return nil }
        return request.toolCallID
    })

    /// The tool calls the turn's cards show.
    private(set) lazy var activityIDs: Set<String> = Set(entries.compactMap { entry in
        guard case let .activity(activity, _) = entry.content else { return nil }
        return activity.id
    })

    /// The tool calls the turn's cards and requests name.
    private(set) lazy var toolCallIDs: Set<String> = Set(entries.compactMap { entry in
        switch entry.content {
        case let .activity(activity, _): activity.id
        case let .permission(request, _): request.toolCallID
        default: nil
        }
    })
}
