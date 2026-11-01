import Foundation

/// Reads a saved reading place against the conversation shown now (plan A3.5). The unified
/// renderer reads by turn, and a saved place may name something else:
///
/// - a row of the old shared transcript (an entry's UUID): the turn holding that entry, at its top
///   unless the entry is the one that opened the turn;
/// - an entry of a detached Codex snapshot, once the thread has attached: the Codex turn it was
///   flattened from (`CodexTranscriptSnapshotProjection`'s name-based IDs);
/// - a Codex turn, while only the detached snapshot is shown: the snapshot entry that opened it.
///
/// Nothing here writes a bookmark; the reading tracker saves a place again once it has shown it.
struct ConversationAnchorResolver {
    /// Where a saved anchor lands.
    struct Anchor: Equatable, Sendable {
        let turnID: String
        /// The anchor named the turn itself (or the message that opened it), so the saved position
        /// within it still applies; otherwise reading starts at the top of the turn.
        let keepsFraction: Bool
    }

    let presentation: ConversationPresentation
    /// The Codex thread the conversation is, or was flattened from while detached.
    let threadID: String?

    /// The turn a saved anchor names, or nil when this conversation does not hold it.
    func anchor(for id: String) -> Anchor? {
        let turns = presentation.turns
        if turns.contains(where: { $0.id == id }) { return Anchor(turnID: id, keepsFraction: true) }
        // A part of a turn drawn in parts (`ConversationTurnRows`) that is drawn whole now.
        if let turnID = ConversationTurnRows.turnID(ofPart: id), turns.contains(where: { $0.id == turnID }) {
            return Anchor(turnID: turnID, keepsFraction: false)
        }
        if let turn = turns.first(where: { Self.holdsEntry(id, in: $0) }) {
            return Anchor(turnID: turn.id, keepsFraction: false)
        }
        guard let threadID else { return nil }
        // A Codex turn, shown as the detached snapshot that names its opening message after it.
        let opening = CodexTranscriptSnapshotProjection.turnEntryID(threadID: threadID, turnID: id).uuidString
        if turns.contains(where: { $0.id == opening }) { return Anchor(turnID: opening, keepsFraction: true) }
        // A detached snapshot's entry, shown as the Codex turn it came from.
        guard UUID(uuidString: id) != nil else { return nil }
        for turn in turns where CodexTranscriptSnapshotProjection.turnEntryID(threadID: threadID, turnID: turn.id)
            .uuidString == id {
            return Anchor(turnID: turn.id, keepsFraction: true)
        }
        for turn in turns {
            if CodexTranscriptSnapshotProjection.errorEntryID(threadID: threadID, turnID: turn.id).uuidString == id {
                return Anchor(turnID: turn.id, keepsFraction: false)
            }
            for item in Self.items(of: turn) {
                guard case let .codex(codexItem, _) = item.source else { continue }
                let name = CodexTranscriptSnapshotProjection.itemEntryID(
                    threadID: threadID, turnID: turn.id, itemID: codexItem.id
                )
                if name.uuidString == id { return Anchor(turnID: turn.id, keepsFraction: false) }
            }
        }
        return nil
    }

    /// `bookmark` in this conversation's turn IDs, or nil when the conversation does not hold its
    /// place. A bookmark that follows the latest output reads as it is.
    func resolve(_ bookmark: TranscriptReadingBookmark) -> TranscriptReadingBookmark? {
        guard !bookmark.followsLatest else { return bookmark }
        guard let id = bookmark.anchorID, let anchor = anchor(for: id) else { return nil }
        return TranscriptReadingBookmark(
            anchorID: anchor.turnID, fraction: anchor.keepsFraction ? bookmark.fraction : 0, followsLatest: false
        )
    }

    /// Where reading starts. The conversation's own bookmark comes first, resolved where it can be
    /// and otherwise as saved (the tracker keeps a place it cannot show yet). A bookmark an earlier
    /// renderer kept for the same conversation (a Codex task's shared-transcript bookmark) is read
    /// only when the conversation's own follows the latest output and the earlier place is here.
    func startingBookmark(
        saved: TranscriptReadingBookmark, earlier: TranscriptReadingBookmark?
    ) -> TranscriptReadingBookmark {
        if !saved.followsLatest { return resolve(saved) ?? saved }
        if let earlier, !earlier.followsLatest, let resolved = resolve(earlier) { return resolved }
        return saved
    }

    /// `newTurnID` is `oldTurnID` under its new name: the conversation renamed its turns (a
    /// detached snapshot hydrated), it did not move on to a new one.
    func isRenamed(_ oldTurnID: String, as newTurnID: String) -> Bool {
        guard oldTurnID != newTurnID, !presentation.turns.contains(where: { $0.id == oldTurnID }) else { return false }
        return anchor(for: oldTurnID)?.turnID == newTurnID
    }

    // MARK: - Turns

    private static func items(of turn: ConversationTurn) -> [ConversationItem] {
        turn.prompt + turn.notices + turn.work + turn.answers
    }

    /// The turn shows the shared-transcript entry `id`: an item, a request, its plan or its outcome.
    private static func holdsEntry(_ id: String, in turn: ConversationTurn) -> Bool {
        if items(of: turn).contains(where: { $0.id == id }) { return true }
        if turn.requests.contains(where: { request in
            if case let .transcript(entry) = request.source { return entry.id.uuidString == id }
            return false
        }) { return true }
        if case let .transcript(entry)? = turn.plan?.source, entry.id.uuidString == id { return true }
        switch turn.outcome {
        case let .error(error)?: return error.entryID?.uuidString == id
        case let .usageLimit(_, entryID)?: return entryID.uuidString == id
        case nil: return false
        }
    }
}
