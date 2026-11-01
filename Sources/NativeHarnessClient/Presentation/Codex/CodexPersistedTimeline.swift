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
    /// The last window's cards by turn, in the storage of each turn's saved cards, or nil when a
    /// turn ID repeats in it. The window is compared with the one before it by these, and saved and
    /// read back, it is taken apart by them instead of card by card (`updateSupplements`): a turn
    /// whose cards did not change is the same storage.
    private var lastWindow: [String: ArraySlice<CodexPersistedTimelineItem>]? = [:]

    /// How a window differs from the one before it.
    enum Change: Int, Comparable {
        /// It is that window.
        case none
        /// It holds the same cards in the same places, with the same lifecycles; only what they
        /// show, such as a running command's output, changed.
        case content
        /// Cards came, went, moved or settled.
        case cards

        static func < (lhs: Change, rhs: Change) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How the window `items(from:)` returned last differs from the one it returned before.
    private(set) var lastChange = Change.none

    /// Whether `items` is the window `items(from:)` returned last, as cards saved from it come back.
    func isLastWindow(_ items: [CodexPersistedTimelineItem]) -> Bool {
        Self.sameStorage(items, lastItems)
    }

    /// The newest `limit` cards of `state` worth keeping across a resume, oldest first. While none
    /// of them changed, as while an answer streams, it is the last window itself, so comparing it
    /// with the cards saved before is immediate. `lastChange` says what changed.
    mutating func items(from state: CodexTaskState) -> [CodexPersistedTimelineItem] {
        guard let turns = state.thread?.turns else {
            lastChange = lastItems.isEmpty ? .none : .cards
            savedTurns.removeAll()
            lastItems = []
            lastTurnIDs = []
            lastWindow = [:]
            return []
        }
        var newestFirst: [ArraySlice<CodexPersistedTimelineItem>] = []
        var count = 0
        var visited: [String: SavedTurn] = [:]
        var turnIDs: [String] = []
        var window: [String: ArraySlice<CodexPersistedTimelineItem>]? = [:]
        var change = Change.none
        for turnIndex in turns.indices.reversed() {
            guard count < Self.limit else { break }
            let saved = savedTurn(turns[turnIndex])
            let turnID = turns[turnIndex].id
            if visited.updateValue(saved, forKey: turnID) != nil { window = nil }
            turnIDs.append(turnID)
            let cards = saved.cards.suffix(Self.limit - count)
            newestFirst.append(cards)
            count += cards.count
            if !cards.isEmpty { window?[turnID] = cards }
            // Cards of the turn outside the window, as the oldest turn's, may change without changing it.
            change = max(change, Self.change(from: lastWindow?[turnID] ?? [], to: cards))
        }
        savedTurns = visited
        if window == nil || lastWindow == nil || turnIDs != lastTurnIDs { change = .cards }
        lastChange = change
        // An equal turn in other storage is kept as this one, so the next comparison is immediate.
        lastWindow = window
        guard change != .none else { return lastItems }
        var items: [CodexPersistedTimelineItem] = []
        items.reserveCapacity(count)
        for cards in newestFirst.reversed() { items.append(contentsOf: cards) }
        lastItems = items
        lastTurnIDs = turnIDs
        return items
    }

    private static func change(
        from before: ArraySlice<CodexPersistedTimelineItem>,
        to now: ArraySlice<CodexPersistedTimelineItem>
    ) -> Change {
        if before == now { return .none }
        guard before.count == now.count, zip(before, now).allSatisfy({
            $0.id == $1.id && $0.lifecycleRawValue == $1.lifecycleRawValue
        }) else { return .cards }
        return .content
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
        guard let results = supplements?.results else { return [] }
        // Each turn's entries follow its cards; they are read back in the order the cards were saved.
        var next: [String: (card: Int, entries: ArraySlice<(card: Int, entry: CodexItemPageEntry)>)] = [:]
        var entries: [CodexItemPageEntry] = []
        for card in saved {
            guard let result = results[card.turnID] else { continue }
            var turn = next[card.turnID] ?? (result.dropped, result.entries)
            if let entry = turn.entries.first, entry.card == turn.card {
                entries.append(entry.entry)
                turn.entries.removeFirst()
            }
            turn.card += 1
            next[card.turnID] = turn
        }
        return entries
    }

    /// Merges into `state` the saved cards `supplementEntries` finds for it, as
    /// `CodexTaskReducer.mergeItemPage` merges them. A turn whose loaded items, status and cards
    /// are those of the last state, wherever its cards now sit among the saved ones, gets the items
    /// it merged to then, in the same storage: a state then shares with the last one every turn the
    /// provider did not change, and what compares turns after the merge (settling cards, choosing the
    /// cards to save, the views) finds them equal at once rather than item by item. A turn whose
    /// oldest cards left the window gets those cards' items back as loaded, and keeps the rest.
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
        // other cards; the turns whose cards are the same keep their results (`Supplements.init`). The
        // window this timeline built last is taken apart by turn as it was put together.
        if supplements.map({ !Self.sameStorage($0.saved, saved) }) ?? true {
            let window = isLastWindow(saved) ? lastWindow : nil
            supplements = Supplements(
                saved: saved, cardsByTurnID: window ?? Self.cardsByTurnID(saved), keeping: supplements)
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
                    )[...]
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

    private static func cardsByTurnID(
        _ saved: [CodexPersistedTimelineItem]
    ) -> [String: ArraySlice<CodexPersistedTimelineItem>] {
        var cards: [String: [CodexPersistedTimelineItem]] = [:]
        for card in saved { cards[card.turnID, default: []].append(card) }
        return cards.mapValues { $0[...] }
    }

    /// The saved cards grouped by turn, and what each loaded turn took from them last time.
    private struct Supplements {
        struct TurnResult {
            var items: [[CodexItemState]]
            let firstStatus: CodexTurnStatus
            /// Each entry with its card's place among the turn's cards it was taken from, of which
            /// the first `dropped` are no longer saved.
            var entries: ArraySlice<(card: Int, entry: CodexItemPageEntry)>
            var dropped = 0
            /// The first turn's items once `entries` were merged into them (`merge`).
            var merged: [CodexItemState]?

            /// What the turn takes once its oldest `count` cards are no longer saved, as the window
            /// moves on: their entries go, and an item only they set in `merged` is the loaded one
            /// again. False when the turn must be worked out anew: an entry that goes shares its item
            /// with one that stays, or the merge added its item to the turn.
            mutating func dropOldest(_ count: Int) -> Bool {
                dropped += count
                let leaving = entries.prefix(while: { $0.card < dropped })
                let staying = entries.dropFirst(leaving.count)
                if merged != nil {
                    for (_, entry) in leaving {
                        let id = entry.item.id
                        guard !staying.contains(where: { $0.entry.item.id == id }),
                              let index = items[0].firstIndex(where: { $0.id == id }) else { return false }
                        merged![index] = items[0][index]
                    }
                }
                entries = staying
                return true
            }
        }

        let saved: [CodexPersistedTimelineItem]
        let cardsByTurnID: [String: ArraySlice<CodexPersistedTimelineItem>]
        var results: [String: TurnResult] = [:]

        /// The cards are saved again whenever a card of the running turn starts, settles or streams
        /// for a second, and once the window is full each new card pushes the oldest out. A turn whose
        /// cards are the same keeps what it took and merged, wherever its cards now sit, and a turn
        /// that lost its oldest cards keeps the rest.
        init(
            saved: [CodexPersistedTimelineItem],
            cardsByTurnID: [String: ArraySlice<CodexPersistedTimelineItem>],
            keeping previous: Supplements? = nil
        ) {
            self.saved = saved
            self.cardsByTurnID = cardsByTurnID
            guard let previous else { return }
            for (turnID, result) in previous.results {
                guard let before = previous.cardsByTurnID[turnID], let now = cardsByTurnID[turnID],
                      now.count <= before.count, before.suffix(now.count) == now else { continue }
                var kept = result
                if kept.dropOldest(before.count - now.count) { results[turnID] = kept }
            }
        }
    }

    /// `turns` are every loaded turn with the cards' turn ID, in thread order. Each entry comes with
    /// its card's place among `cards`.
    private static func supplement(
        _ cards: ArraySlice<CodexPersistedTimelineItem>,
        turns: [CodexTurnState]
    ) -> [(card: Int, entry: CodexItemPageEntry)] {
        var live: [String: CodexItemLifecycle] = [:]
        for turn in turns {
            for index in turn.items.indices {
                let id = turn.items[index].id
                let lifecycle = turn.items[index].lifecycle
                live[id] = max(live[id] ?? lifecycle, lifecycle)
            }
        }
        var entries: [(card: Int, entry: CodexItemPageEntry)] = []
        for (index, card) in cards.enumerated() {
            let itemID = card.raw["id"]?.stringValue ?? card.id
            let lifecycle = CodexItemLifecycle(rawValue: card.lifecycleRawValue) ?? .historical
            if let current = live[itemID], current >= lifecycle { continue }
            let entry = card.pageEntry
            if case .agentMessage = entry.item.content {
                guard turns[0].status == .interrupted,
                      !turns[0].items.contains(where: { $0.id == entry.item.id }) else { continue }
            }
            entries.append((index, entry))
        }
        return entries
    }
}
