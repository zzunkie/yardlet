import Foundation

/// One update's turns as a projection reads them (`CodexConversationProjection.TurnInputs`,
/// `TranscriptConversationProjection.TurnInputs`): what every turn reads alike, read once, and each
/// turn's ID and input, read only when asked.
protocol ConversationTurnInputs {
    associatedtype ID: Hashable
    associatedtype Shared: Equatable
    associatedtype Input

    var count: Int { get }
    /// What every turn reads alike: an update that changes it projects every turn again.
    var shared: Shared { get }
    func id(at index: Int) -> ID
    func input(at index: Int) -> Input
    /// Whether `previous`, the input of the turn with the same ID in an update with the same `shared`,
    /// is the input of the turn at `index` now. It compares only what the turn's own input is made of,
    /// which an untouched turn shares with the update before, and never says yes to an input that
    /// `input(at:)` would not equal.
    func keeps(_ previous: Input, at index: Int) -> Bool
}

/// Remembers one conversation's projected turns between updates, so an update projects again only
/// the turns whose input changed (plan A3.4). The renderer owns one per task as `@State`; nothing
/// observes it.
///
/// It keeps the last update's turns in order, so an update reads each turn against the one at the same
/// place before it and asks the source whether that turn's input still holds (`ConversationTurnInputs`),
/// without reading the input again: a turn the update left alone costs one comparison of what its
/// input is made of, which an untouched turn shares with the update before (a Codex turn's
/// `CodexTurnState`, a transcript turn's entries), and the turns kept stay where they were. A long
/// conversation streaming into its last turn is then projected in proportion to that turn. Each
/// source adds its entry point in an extension (`codex(_:workspaceURL:historySelection:)`,
/// `transcript(_:harness:status:latestTurnIsComplete:)`).
final class ConversationProjectionCache {
    struct Counts: Equatable, Sendable {
        /// Turns kept from an earlier update.
        var reused = 0
        /// Turns projected.
        var projected = 0
    }

    /// Every update since the cache was made.
    private(set) var counts = Counts()

    /// The last update's turns, in order: their IDs, what every turn read alike, what each was
    /// projected from, and the turns.
    private struct Kept<ID: Hashable, Shared, Input> {
        var ids: [ID] = []
        var shared: Shared?
        var inputs: [Input] = []
        var turns: [ConversationTurn] = []
    }

    private final class KeptBox<ID: Hashable, Shared, Input> {
        var kept: Kept<ID, Shared, Input>

        init(_ kept: Kept<ID, Shared, Input>) {
            self.kept = kept
        }
    }

    private var kept: AnyObject?
    /// The items of the Codex turns projected again (`codex(_:workspaceURL:historySelection:)`).
    let codexItems = CodexItemMemo()
    /// The last Codex conversation and the state it came from.
    var lastCodex: (state: CodexTaskState, workspaceURL: URL, historySelection: CodexHistorySearchSelection?,
                    presentation: ConversationPresentation)?
    /// The requests and tool calls of the last shared transcript projected, counted over its turns.
    var transcriptRequests = TranscriptRequestIndex()
    /// The last shared-transcript conversation and the very turns it came from. The turns are kept, so
    /// an unchanged transcript is known by its turns without comparing its entries: a long conversation
    /// shown again is not projected again.
    var lastTranscript: (transcript: TranscriptTurns, harness: HarnessKind, status: SessionStatus,
                         latestTurnIsComplete: Bool, latestTurnWasCutOff: Bool, presentation: ConversationPresentation)?

    init() {}

    /// An unchanged conversation shown again: its turns count as kept, as projecting it would have
    /// kept each of them.
    func keptWhole(_ presentation: ConversationPresentation) -> ConversationPresentation {
        counts.reused += presentation.turns.count
        return presentation
    }

    /// One update's turns, in order. A turn the last update had under the same ID, with the same
    /// `shared`, is kept while the source keeps its input; any other turn is projected. `forgotten` is
    /// given the IDs the last update had and this one has not.
    func turns<Inputs: ConversationTurnInputs>(
        of source: Inputs,
        project: (Inputs.Input) -> ConversationTurn,
        forgotten: ([Inputs.ID]) -> Void = { _ in }
    ) -> [ConversationTurn] {
        // The last update's turns, taken so that they are changed in place.
        var kept = Kept<Inputs.ID, Inputs.Shared, Inputs.Input>()
        if let box = self.kept as? KeptBox<Inputs.ID, Inputs.Shared, Inputs.Input> { swap(&kept, &box.kept) }
        let shared = source.shared
        let keepsAny = kept.shared == shared
        var reused = 0
        defer {
            counts.reused += reused
            counts.projected += source.count - reused
        }
        // While the turns line up with the last update's, each stays where it is or is projected there.
        var index = 0
        while index < min(source.count, kept.ids.count), kept.ids[index] == source.id(at: index) {
            if keepsAny, source.keeps(kept.inputs[index], at: index) {
                reused += 1
            } else {
                kept.inputs[index] = source.input(at: index)
                kept.turns[index] = project(kept.inputs[index])
            }
            index += 1
        }
        if index < kept.ids.count || index < source.count {
            // The rest does not line up: a page read in before them, turns gone from the start or the end,
            // or turns added at the end. Each is read against the turn the last update had under its ID.
            let rest = kept.ids.indices.suffix(from: index)
            var positions: [Inputs.ID: Int]?
            var offset = 0
            var matched = Array(repeating: false, count: rest.count)
            var ids: [Inputs.ID] = [], inputs: [Inputs.Input] = [], turns: [ConversationTurn] = []
            for current in index..<source.count {
                let id = source.id(at: current)
                var at = current + offset
                if !rest.contains(at) || kept.ids[at] != id {
                    positions = positions ?? Dictionary(rest.map { (kept.ids[$0], $0) }, uniquingKeysWith: { first, _ in first })
                    at = positions?[id] ?? -1
                    if at >= 0 { offset = at - current }
                }
                ids.append(id)
                if at >= 0 {
                    matched[at - index] = true
                    if keepsAny, source.keeps(kept.inputs[at], at: current) {
                        reused += 1
                        inputs.append(kept.inputs[at])
                        turns.append(kept.turns[at])
                        continue
                    }
                }
                let input = source.input(at: current)
                inputs.append(input)
                turns.append(project(input))
            }
            if matched.contains(false) {
                forgotten(rest.filter { !matched[$0 - index] }.map { kept.ids[$0] })
            }
            kept.ids.replaceSubrange(rest, with: ids)
            kept.inputs.replaceSubrange(rest, with: inputs)
            kept.turns.replaceSubrange(rest, with: turns)
        }
        kept.shared = shared
        if let box = self.kept as? KeptBox<Inputs.ID, Inputs.Shared, Inputs.Input> {
            box.kept = kept
        } else {
            self.kept = KeptBox(kept)
        }
        return kept.turns
    }
}
