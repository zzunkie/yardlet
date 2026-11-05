import Foundation

/// The requests and tool calls of a transcript's turns, counted over them, for what the conversation
/// reads across turns: the calls an allowed request marks on the call's own card, decided over the
/// whole transcript since a request and its call can sit in different turns (the rule of
/// `TranscriptConversationProjection.approvedToolCallIDs(in:)`), and the requests that wait.
///
/// Moving to a later update's turns (`update(to:)`) counts only the turns that came and went. The turns
/// a transcript kept from the update before are the very same turns (`TranscriptTurns`), so an answer
/// streaming at the end of a long conversation counts its last turn, not the whole history.
struct TranscriptRequestIndex {
    private var turns: [TranscriptTurn] = []
    /// How many of the turns' allowed requests name each call, and how many of their cards show it.
    private var allowed: [String: Int] = [:]
    private var calls: [String: Int] = [:]
    /// How many of the turns hold each waiting request.
    private var waiting: [String: Int] = [:]
    /// The requests that wait for an answer.
    private(set) var pendingRequestIDs: Set<String> = []

    init() {}

    /// An allowed request names the call and a card shows it.
    func isApproved(_ toolCallID: String) -> Bool {
        (allowed[toolCallID] ?? 0) > 0 && (calls[toolCallID] ?? 0) > 0
    }

    /// The calls the turn's cards or requests name that read as approved.
    func approvedToolCallIDs(in turn: TranscriptTurn) -> Set<String> {
        allowed.isEmpty ? [] : turn.toolCallIDs.filter(isApproved)
    }

    /// Moves to `newTurns`, counting the turns that are not the turns it had at the same place, and
    /// returns the calls whose approval changed. Turns kept in order are passed over; the oldest turn
    /// going, or giving way to the rest of it, does not stop the turns after it from being kept.
    mutating func update(to newTurns: [TranscriptTurn]) -> Set<String> {
        var gone: [TranscriptTurn] = []
        var came: [TranscriptTurn] = []
        var next = turns.startIndex
        for turn in newTurns {
            if next < turns.endIndex, turns[next] === turn {
                next += 1
            } else if next + 1 < turns.endIndex, turns[next + 1] === turn {
                gone.append(turns[next])
                next += 2
            } else {
                came.append(turn)
            }
        }
        gone += turns[next...]
        turns = newTurns
        guard !gone.isEmpty || !came.isEmpty else { return [] }

        let changed = gone + came
        let touchedCalls = changed.reduce(into: Set<String>()) {
            $0.formUnion($1.allowedToolCallIDs)
            $0.formUnion($1.activityIDs)
        }
        let approvedBefore = touchedCalls.filter(isApproved)
        for (turns, step) in [(gone, -1), (came, 1)] {
            for turn in turns {
                for id in turn.allowedToolCallIDs { Self.count(id, step, in: &allowed) }
                for id in turn.activityIDs { Self.count(id, step, in: &calls) }
                for id in turn.pendingRequestIDs { Self.count(id, step, in: &waiting) }
            }
        }
        for turn in changed {
            for id in turn.pendingRequestIDs {
                if waiting[id] == nil { pendingRequestIDs.remove(id) } else { pendingRequestIDs.insert(id) }
            }
        }
        return approvedBefore.symmetricDifference(touchedCalls.filter(isApproved))
    }

    private static func count(_ id: String, _ step: Int, in counts: inout [String: Int]) {
        let count = (counts[id] ?? 0) + step
        counts[id] = count > 0 ? count : nil
    }
}
