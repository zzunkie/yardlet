import Foundation

/// Which part of its turn a row of the conversation draws (`ConversationTurnRows`).
enum ConversationRowPart: Equatable, Sendable {
    /// The whole turn.
    case whole
    /// Its request, notices, plan, header and first runs of work. The row is named after the turn,
    /// so whatever goes to the turn (the rail, find, a saved place) goes to its start.
    case head
    /// Runs of its work.
    case middle
    /// Its last runs of work, its answers, the live line with the calls the turn made before them
    /// (`stepsBefore`) counted in, the status, more items, the outcome and the requests waiting.
    case tail(stepsBefore: Int)

    /// The row goes on from the row before, a part of the same turn: the two are as far apart as the
    /// parts of one turn are (`ConversationLayout.itemSpacing`), not as two turns.
    var continuesTurn: Bool {
        switch self {
        case .middle, .tail: true
        case .whole, .head: false
        }
    }

    /// The row draws what closes the turn: its answers, live line, status, outcome and requests.
    var drawsEnd: Bool {
        switch self {
        case .whole, .tail: true
        case .head, .middle: false
        }
    }
}

/// The conversation as the rows it is drawn in: a turn in one row, or a long turn whose work shows
/// (it does not fold) in a row for each few runs of its work. The rows read as turns to whatever
/// works on turns, so the window draws the latest rows (`ConversationTurnWindow`) and scrolling up
/// brings earlier ones in, a few each display cycle, with the place being read kept as they arrive.
/// A conversation shown again builds and lays out only the rows its window draws: a running turn of
/// hundreds of calls and messages, laid out whole on every opening, held the main thread for about a
/// second each time a task the window had let go was opened again. A row is drawn again only when
/// its own part changed, so a streaming turn draws again its last part, not all of it.
struct ConversationTurnRows {
    /// The runs of work in each part.
    static let runsPerPart = 3
    /// A turn whose work runs to more than this is drawn in parts.
    static let partsAbove = 6

    /// The rows, each a turn: a whole turn, or a part named after its turn (`partID`).
    let presentation: ConversationPresentation
    /// The conversation's turns.
    let turns: ConversationPresentation
    private let partOf: [String: (turnID: String, part: ConversationRowPart)]

    init(turns: ConversationPresentation, split: (ConversationTurn) -> Split?) {
        self.turns = turns
        // The rows are the turns themselves until a turn is split.
        var rows: [ConversationTurn]?
        var partOf: [String: (turnID: String, part: ConversationRowPart)] = [:]
        for (index, turn) in turns.turns.enumerated() {
            guard let split = split(turn) else {
                rows?.append(turn)
                continue
            }
            if rows == nil { rows = Array(turns.turns[..<index]) }
            for (index, part) in split.parts.enumerated() {
                let kind: ConversationRowPart = index == 0 ? .head
                    : index == split.parts.count - 1 ? .tail(stepsBefore: split.stepsBeforeTail) : .middle
                partOf[part.id] = (turn.id, kind)
                rows?.append(part)
            }
        }
        var presentation = turns
        if let rows { presentation.turns = rows }
        self.presentation = presentation
        self.partOf = partOf
    }

    /// A turn in parts, and the calls its parts before the tail hold.
    struct Split {
        let parts: [ConversationTurn]
        let stepsBeforeTail: Int
    }

    /// The turn the row `rowID` draws or draws part of.
    func turnID(of rowID: String) -> String { partOf[rowID]?.turnID ?? rowID }

    func part(of rowID: String) -> ConversationRowPart { partOf[rowID]?.part ?? .whole }

    /// The turns `rows` draw all or part of, in their order.
    func turns(drawnIn rows: [ConversationTurn]) -> [ConversationTurn] {
        let drawn = Set(rows.map { turnID(of: $0.id) })
        return turns.turns.filter { drawn.contains($0.id) }
    }

    /// The row a part after a turn's head is named: the turn's ID and the part's place.
    static func partID(turnID: String, index: Int) -> String { "\(turnID)#part\(index)" }

    /// The turn a part's row is named after; nil for a row that is a whole turn or a turn's head.
    static func turnID(ofPart rowID: String) -> String? {
        guard let mark = rowID.range(of: "#part", options: .backwards),
              !rowID[mark.upperBound...].isEmpty, rowID[mark.upperBound...].allSatisfy(\.isNumber) else { return nil }
        return String(rowID[..<mark.lowerBound])
    }

    /// `turn` in parts of `runsPerPart` runs of its work, or nil when it is drawn whole: its work
    /// folds, or runs to no more than `partsAbove`. The parts end where runs end, so each groups its
    /// work as the whole turn did; a part fills before the next begins, so earlier parts stay as they
    /// are while the turn streams.
    static func split(_ turn: ConversationTurn) -> Split? {
        guard turn.work.count > partsAbove else { return nil }
        let bounds = ConversationWorkGrouping.runBounds(turn.work)
        guard bounds.count > partsAbove, !turn.foldsWork else { return nil }
        let chunks = stride(from: 0, to: bounds.count, by: runsPerPart).map { first in
            let last = min(first + runsPerPart, bounds.count) - 1
            return Array(turn.work[bounds[first].lowerBound..<bounds[last].upperBound])
        }
        let parts = chunks.enumerated().map { index, work in
            if index == 0 { return head(of: turn, work: work) }
            let id = partID(turnID: turn.id, index: index)
            if index == chunks.count - 1 { return tail(of: turn, id: id, work: work) }
            return ConversationTurn(id: id, status: turn.status, timing: ConversationTurnTiming(), work: work)
        }
        let steps = chunks.dropLast().reduce(0) { total, work in
            total + work.count { ConversationWorkSummary.category(of: $0) != nil }
        }
        return Split(parts: parts, stepsBeforeTail: steps)
    }

    /// The turn's start: what was sent and the header, with the actions the request draws. A fork goes
    /// on the answer, in the tail, when the turn has one.
    private static func head(of turn: ConversationTurn, work: [ConversationItem]) -> ConversationTurn {
        var head = turn
        head.work = work
        head.answers = []
        head.requests = []
        head.outcome = nil
        head.progress = .none
        head.hasMoreItems = false
        head.recordOrder = []
        // A running turn reads its time on its live line; the header reads it once the turn ends.
        if turn.status == .running { head.timing = ConversationTurnTiming() }
        head.actions.canFork = turn.answers.isEmpty && turn.actions.canFork
        head.actions.canRetry = false
        head.actions.planToImplement = nil
        head.actions.questionsToAnswer = []
        head.actions.answeredQuestions = nil
        return head
    }

    private static func tail(of turn: ConversationTurn, id: String, work: [ConversationItem]) -> ConversationTurn {
        ConversationTurn(
            id: id, status: turn.status, timing: turn.timing, work: work, answers: turn.answers,
            requests: turn.requests, outcome: turn.outcome, progress: turn.progress, hasMoreItems: turn.hasMoreItems,
            actions: turn.actions
        )
    }
}

/// The parts each turn was last drawn in, kept with the conversation (`ConversationRenderState`) so
/// an update splits again only the turns it changed, and tells the others by their storage, not by
/// comparing their items: the conversation is drawn again for every update of any of its turns.
@MainActor
final class ConversationTurnRowCache {
    private var splits: [String: (turn: ConversationTurn, split: ConversationTurnRows.Split?)] = [:]

    func rows(of presentation: ConversationPresentation) -> ConversationTurnRows {
        var kept: [String: (turn: ConversationTurn, split: ConversationTurnRows.Split?)] = [:]
        let rows = ConversationTurnRows(turns: presentation) { turn in
            // A turn too short to be split is told at once.
            guard turn.work.count > ConversationTurnRows.partsAbove else { return nil }
            let split = if let cached = splits[turn.id], turn.isUnchanged(from: cached.turn) {
                cached.split
            } else {
                ConversationTurnRows.split(turn)
            }
            kept[turn.id] = (turn, split)
            return split
        }
        splits = kept
        return rows
    }
}
