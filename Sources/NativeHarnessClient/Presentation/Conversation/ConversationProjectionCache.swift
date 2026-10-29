import Foundation

/// Remembers one conversation's projected turns between updates, so an update projects again only
/// the turns whose input changed (plan A3.4). The renderer owns one per task as `@State`; nothing
/// observes it.
///
/// A turn is kept while its input equals the input it was projected from. A Codex turn's input
/// holds its `CodexTurnState`, which an untouched turn shares with the previous update, so comparing
/// an unchanged turn stops at the shared storage, as `CodexPresentationPatches` diffs a long thread.
/// Each source adds its entry point in an extension (`codex(_:workspaceURL:historySelection:)`).
final class ConversationProjectionCache {
    struct Counts: Equatable, Sendable {
        /// Turns kept from an earlier update.
        var reused = 0
        /// Turns projected.
        var projected = 0
    }

    /// Every update since the cache was made.
    private(set) var counts = Counts()

    private struct Memo {
        let input: Any
        let turn: ConversationTurn
        /// The update that last asked for the turn.
        var update: UInt64
    }

    private var memos: [String: Memo] = [:]
    private var update: UInt64 = 0
    /// The items of the Codex turns projected again (`codex(_:workspaceURL:historySelection:)`).
    let codexItems = CodexItemMemo()
    /// The last shared-transcript conversation and the very record it came from. The record is kept,
    /// so a changed record is a copy with storage of its own, and an unchanged one is known without
    /// comparing its entries: a long conversation shown again is not projected again.
    var lastTranscript: (entries: [TranscriptEntry], harness: HarnessKind, status: SessionStatus,
                         latestTurnIsComplete: Bool, presentation: ConversationPresentation)?

    init() {}

    /// An unchanged conversation shown again: its turns count as kept, as projecting it would have
    /// kept each of them.
    func keptWhole(_ presentation: ConversationPresentation) -> ConversationPresentation {
        counts.reused += presentation.turns.count
        return presentation
    }

    /// One update's turns, in order, each from its ID and input. Turns the update no longer asks
    /// for are forgotten.
    func turns<Input: Equatable>(
        _ inputs: [(id: String, input: Input)],
        project: (Input) -> ConversationTurn
    ) -> [ConversationTurn] {
        update &+= 1
        var kept = 0
        let turns = inputs.map { id, input -> ConversationTurn in
            if let memo = memos[id], let previous = memo.input as? Input, previous == input {
                counts.reused += 1
                if memo.update != update {
                    memos[id]?.update = update
                    kept += 1
                }
                return memo.turn
            }
            counts.projected += 1
            let turn = project(input)
            if memos[id]?.update != update { kept += 1 }
            memos[id] = Memo(input: input, turn: turn, update: update)
            return turn
        }
        if memos.count > kept {
            memos = memos.filter { $0.value.update == update }
        }
        return turns
    }
}
