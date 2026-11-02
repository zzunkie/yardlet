import Foundation

/// What the session rail reads of each Codex task's state: the thread's turns with the items the rail
/// shows (`SessionRailContent.reads(_:)`) and the few things it reads of each turn. The app sets a task's
/// rail state whenever its Codex state is set and publishes it only when it changed, so a state that
/// streams words or a command's output into the conversation leaves the rail as it is. A turn the new
/// state left as it was keeps what was made of it before, so only the turns that changed are read again.
/// Nothing observes it.
@MainActor
final class CodexRailStates {
    private var made: [UUID: [String: (turn: CodexTurnState, rail: CodexTurnState)]] = [:]

    /// The rail's part of `state`, `id`'s Codex state as it is now; for no state, nothing, and the task's
    /// turns are let go.
    func state(of state: CodexTaskState?, for id: UUID) -> CodexTaskState? {
        guard let state else {
            made.removeValue(forKey: id)
            return nil
        }
        guard let thread = state.thread else {
            made.removeValue(forKey: id)
            return CodexTaskState()
        }
        let earlier = made[id] ?? [:]
        var kept: [String: (turn: CodexTurnState, rail: CodexTurnState)] = [:]
        kept.reserveCapacity(thread.turns.count)
        let turns = thread.turns.map { turn -> CodexTurnState in
            if let known = earlier[turn.id], known.turn == turn {
                // Kept as this turn: a state that brought the same turn in other storage is compared
                // whole once, and the next one that keeps it stops at the shared storage.
                kept[turn.id] = (turn, known.rail)
                return known.rail
            }
            let rail = Self.rail(turn)
            kept[turn.id] = (turn, rail)
            return rail
        }
        made[id] = kept
        // Of the thread the rail reads its identity and turns.
        return CodexTaskState(thread: CodexThreadState(id: thread.id, preview: "", status: .notLoaded, turns: turns,
                                                       raw: .null))
    }

    /// What the rail reads of a turn.
    private static func rail(_ turn: CodexTurnState) -> CodexTurnState {
        CodexTurnState(id: turn.id, status: turn.status, startedAt: turn.startedAt, itemsView: turn.itemsView,
                       items: turn.items.filter(SessionRailContent.reads), plan: turn.plan, tokenUsage: turn.tokenUsage,
                       raw: .null)
    }
}
