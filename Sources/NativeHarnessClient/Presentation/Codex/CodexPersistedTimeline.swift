import Foundation

/// The app-local Codex cards a task keeps across launches (`CodexPersistedTimelineItem`): which
/// of a presentation's items are saved, and which saved ones supplement a presentation the
/// provider loaded without them.
///
/// Both run on the main actor for every presentation a streaming task publishes. Successive
/// presentations share the storage of every turn they did not change, so each remembers what a
/// turn gave last time and redoes only the turns whose items or status changed; the cost follows
/// what changed rather than the conversation's length.
struct CodexPersistedTimeline {
    static let limit = 500

    private struct SavedTurn {
        let interrupted: Bool
        let items: [CodexItemState]
        /// The turn's kept items and the saved card each gave, oldest first.
        let sources: [CodexItemState]
        let cards: [CodexPersistedTimelineItem]
    }

    private var savedTurns: [String: SavedTurn] = [:]
    /// The last window, and the turns it came from, newest first.
    private var lastItems: [CodexPersistedTimelineItem] = []
    private var lastTurnIDs: [String] = []

    /// The newest `limit` cards of `state` worth keeping across a resume, oldest first. While no
    /// turn's cards changed, as while an answer streams, it is the last window itself, so comparing it
    /// with the cards saved before is immediate.
    mutating func items(from state: CodexTaskState) -> [CodexPersistedTimelineItem] {
        guard let turns = state.thread?.turns else {
            savedTurns.removeAll()
            lastItems = []
            lastTurnIDs = []
            return []
        }
        var newestFirst: [ArraySlice<CodexPersistedTimelineItem>] = []
        var count = 0
        var visited: [String: SavedTurn] = [:]
        var turnIDs: [String] = []
        var changed = false
        for turnIndex in turns.indices.reversed() {
            guard count < Self.limit else { break }
            let saved = savedTurn(turns[turnIndex])
            let turnID = turns[turnIndex].id
            if savedTurns[turnID]?.cards != saved.cards { changed = true }
            visited[turnID] = saved
            turnIDs.append(turnID)
            let cards = saved.cards.suffix(Self.limit - count)
            newestFirst.append(cards)
            count += cards.count
        }
        savedTurns = visited
        guard changed || turnIDs != lastTurnIDs else { return lastItems }
        var items: [CodexPersistedTimelineItem] = []
        items.reserveCapacity(count)
        for cards in newestFirst.reversed() { items.append(contentsOf: cards) }
        lastItems = items
        lastTurnIDs = turnIDs
        return items
    }

    private func savedTurn(_ turn: CodexTurnState) -> SavedTurn {
        let interrupted = turn.status == .interrupted
        let previous = savedTurns[turn.id]
        // An equal turn in other storage is kept as this one, so the next state's comparison is
        // immediate rather than item by item.
        if let previous, previous.interrupted == interrupted, previous.items == turn.items {
            return SavedTurn(interrupted: interrupted, items: turn.items, sources: previous.sources, cards: previous.cards)
        }
        // A changed turn keeps the cards of its items that did not change.
        var reusable: [String: Int] = [:]
        for index in (previous?.sources ?? []).indices.reversed() { reusable[previous!.sources[index].id] = index }
        var sources: [CodexItemState] = []
        var cards: [CodexPersistedTimelineItem] = []
        for index in turn.items.indices where Self.isKept(turn.items[index].content, interrupted: interrupted) {
            let item = turn.items[index]
            if let previous, let kept = reusable[item.id], previous.sources[kept] == item {
                cards.append(previous.cards[kept])
            } else {
                cards.append(CodexPersistedTimelineItem(turnID: turn.id, item: item))
            }
            sources.append(item)
        }
        return SavedTurn(interrupted: interrupted, items: turn.items, sources: sources, cards: cards)
    }

    private static func isKept(_ content: CodexItemContent, interrupted: Bool) -> Bool {
        if content.shouldPersistAcrossResume { return true }
        if interrupted, case let .agentMessage(message) = content, !message.text.isEmpty { return true }
        return false
    }

    /// The saved cards that belong in `state` and are missing from it, or that got further than
    /// its copy, such as a finished card the provider's history leaves as started. A saved copy
    /// of a still-running card lags its live output and is left out. A saved answer only fills an
    /// interrupted turn whose provider omitted it; a provider's own item, even an intentionally
    /// empty one, always wins. Cards never manufacture a turn the presentation has not loaded.
    mutating func supplementEntries(
        for state: CodexTaskState,
        saved: [CodexPersistedTimelineItem]
    ) -> [CodexItemPageEntry] {
        updateSupplements(for: state, saved: saved)
        return (supplements?.results.values.flatMap(\.entries) ?? [])
            .sorted { $0.position < $1.position }.map(\.entry)
    }

    /// Merges into `state` the saved cards `supplementEntries` finds for it, as
    /// `CodexTaskReducer.mergeItemPage` merges them. A turn whose loaded items, status and cards
    /// are those of the last state gets the items it merged to then, in the same storage: a state
    /// then shares with the last one every turn the provider did not change, and what compares turns
    /// after the merge (settling cards, choosing the cards to save, the views) finds them equal at
    /// once rather than item by item.
    mutating func merge(_ saved: [CodexPersistedTimelineItem], into state: inout CodexTaskState) {
        updateSupplements(for: state, saved: saved)
        guard supplements != nil, state.thread != nil else { return }
        let reducer = CodexTaskReducer()
        for (turnID, result) in supplements!.results where !result.entries.isEmpty {
            // The first turn with the ID, which the reducer merges a page into. Read in place.
            guard let index = state.thread!.turns.indices.first(where: { state.thread!.turns[$0].id == turnID }) else {
                continue
            }
            if let merged = result.merged {
                state.thread!.turns[index].items = merged
                state.thread!.turns[index].itemsNextCursor = nil
            } else {
                reducer.mergeItemPage(
                    CodexItemPage(entries: result.entries.map(\.entry), nextCursor: nil, backwardsCursor: nil),
                    into: &state)
                supplements!.results[turnID]!.merged = state.thread!.turns[index].items
            }
        }
    }

    /// Which saved cards each loaded turn takes, worked out again only for the turns whose items or
    /// status changed.
    private mutating func updateSupplements(for state: CodexTaskState, saved: [CodexPersistedTimelineItem]) {
        guard !saved.isEmpty, let turns = state.thread?.turns, !turns.isEmpty else {
            supplements = nil
            return
        }
        // The saved cards come back from the repository as the array saved last, so other storage means
        // other cards; the turns whose cards are the same keep their results (`Supplements.init`).
        if supplements.map({ !Self.sameStorage($0.saved, saved) }) ?? true {
            supplements = Supplements(saved: saved, keeping: supplements)
        }
        var indicesByTurnID: [String: [Int]] = [:]
        for index in turns.indices where supplements!.cardsByTurnID[turns[index].id] != nil {
            indicesByTurnID[turns[index].id, default: []].append(index)
        }
        var results: [String: Supplements.TurnResult] = [:]
        for (turnID, indices) in indicesByTurnID {
            let itemsByIndex = indices.map { turns[$0].items }
            let firstStatus = turns[indices[0]].status
            let result: Supplements.TurnResult
            if var previous = supplements!.results[turnID],
               previous.firstStatus == firstStatus, previous.items == itemsByIndex {
                // The same items in other storage are kept as these, so the next comparison is immediate.
                previous.items = itemsByIndex
                result = previous
            } else {
                result = Supplements.TurnResult(
                    items: itemsByIndex,
                    firstStatus: firstStatus,
                    entries: Self.supplement(
                        supplements!.cardsByTurnID[turnID] ?? [],
                        turns: indices.map { turns[$0] }
                    )
                )
            }
            results[turnID] = result
        }
        supplements!.results = results
    }

    private var supplements: Supplements?

    private static func sameStorage<T>(_ first: [T], _ second: [T]) -> Bool {
        first.withUnsafeBufferPointer { first in second.withUnsafeBufferPointer { $0.baseAddress == first.baseAddress } }
            && first.count == second.count
    }

    /// The saved cards grouped by turn, and what each loaded turn took from them last time.
    private struct Supplements {
        struct TurnResult {
            var items: [[CodexItemState]]
            let firstStatus: CodexTurnStatus
            let entries: [(position: Int, entry: CodexItemPageEntry)]
            /// The first turn's items once `entries` were merged into them (`merge`).
            var merged: [CodexItemState]?
        }

        let saved: [CodexPersistedTimelineItem]
        let cardsByTurnID: [String: [(position: Int, card: CodexPersistedTimelineItem)]]
        var results: [String: TurnResult] = [:]

        /// The cards are saved again whenever a card of the running turn starts, settles or streams
        /// for a second: the turns whose cards are the same keep what they took and merged.
        init(saved: [CodexPersistedTimelineItem], keeping previous: Supplements? = nil) {
            self.saved = saved
            var cards: [String: [(position: Int, card: CodexPersistedTimelineItem)]] = [:]
            for (position, card) in saved.enumerated() {
                cards[card.turnID, default: []].append((position, card))
            }
            cardsByTurnID = cards
            guard let previous else { return }
            results = previous.results.filter { turnID, _ in
                guard let before = previous.cardsByTurnID[turnID], let now = cards[turnID],
                      before.count == now.count else { return false }
                return zip(before, now).allSatisfy { $0.position == $1.position && $0.card == $1.card }
            }
        }
    }

    /// `turns` are every loaded turn with the cards' turn ID, in thread order.
    private static func supplement(
        _ cards: [(position: Int, card: CodexPersistedTimelineItem)],
        turns: [CodexTurnState]
    ) -> [(position: Int, entry: CodexItemPageEntry)] {
        var live: [String: CodexItemLifecycle] = [:]
        for turn in turns {
            for index in turn.items.indices {
                let id = turn.items[index].id
                let lifecycle = turn.items[index].lifecycle
                live[id] = max(live[id] ?? lifecycle, lifecycle)
            }
        }
        var entries: [(position: Int, entry: CodexItemPageEntry)] = []
        for (position, card) in cards {
            let itemID = card.raw["id"]?.stringValue ?? card.id
            let lifecycle = CodexItemLifecycle(rawValue: card.lifecycleRawValue) ?? .historical
            if let current = live[itemID], current >= lifecycle { continue }
            let entry = card.pageEntry
            if case .agentMessage = entry.item.content {
                guard turns[0].status == .interrupted,
                      !turns[0].items.contains(where: { $0.id == entry.item.id }) else { continue }
            }
            entries.append((position, entry))
        }
        return entries
    }
}
