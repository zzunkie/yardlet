import Foundation

/// The latest turns a conversation draws (plan A5.3, D11): the 10 most recent. The renderer draws the
/// window's turns and counts the rest as `earlier = .local`, which scrolling up to the top and the
/// turn rail's "Load more history" bring in 10 at a time. Going back to the latest output draws the
/// latest 10 again (`ConversationTimeline`).
///
/// The renderer lays the window's turns out whole, in an eager stack (`ConversationTimeline`), so the
/// window is what a conversation costs to draw: 10 turns of a working conversation are several
/// screens, and drawing them whole cost about what drawing the latest 40 lazily did.
///
/// A shared transcript holds every turn it has (a Claude conversation read from its saved file, as
/// far back as its reads went, `ClaudeTranscriptTail`). A Codex thread holds the pages
/// it loaded, and the window applies to those: the provider's earlier pages (`earlier = .provider`)
/// are asked for only once every loaded turn is drawn.
struct ConversationTurnWindow: Equatable, Sendable {
    static let initialTurnCount = 10
    /// The turns "Load more history" and scrolling up to the top add.
    static let step = 10

    /// How many of the latest turns are drawn.
    var turnCount: Int = Self.initialTurnCount
    /// A turn kept in the window however many turns follow it, with every turn after it: one the
    /// reader went to (a find match, a saved place).
    var earliestTurnID: String? = nil

    /// `presentation` with only the window's turns, the rest counted as earlier turns. Turns the
    /// provider still holds behind its cursor stay its own until the window holds every loaded turn.
    func apply(to presentation: ConversationPresentation) -> ConversationPresentation {
        let turns = presentation.turns
        var start = max(0, turns.count - max(1, turnCount))
        if let earliestTurnID, let index = turns.firstIndex(where: { $0.id == earliestTurnID }) {
            start = min(start, index)
        }
        guard start > 0 else { return presentation }
        var windowed = presentation
        windowed.turns = Array(turns[start...])
        windowed.earlier = .local(hiddenCount: start)
        return windowed
    }

    /// The window with `step` more turns.
    func widened() -> ConversationTurnWindow {
        var window = self
        window.turnCount += Self.step
        return window
    }

    /// Whether `presentation` holds `turnID` but the window leaves it out.
    func hides(_ turnID: String, in presentation: ConversationPresentation) -> Bool {
        presentation.turns.contains { $0.id == turnID }
            && !apply(to: presentation).turns.contains { $0.id == turnID }
    }
}

/// Earlier turns the reader brings in arrive above the first turn drawn all at once: the window's
/// next step, a Codex thread's earlier page, more of a Claude file. Each turn is built and measured
/// as it is first drawn, and ten turns of a working conversation built in one display cycle held the
/// main thread for well over a tenth of a second. So once the reader asks for earlier turns, the turns
/// that arrive before the earliest one drawn are drawn over `cycles` display cycles, the nearest first,
/// at least one each cycle, while the reader holds the view still: a place kept while their scrolling
/// moves the view would be read from before it moved. Asking for earlier turns again draws the rest at
/// once. The reader's place is kept as each few arrive above it (`TranscriptScrollFollowing`), as it
/// was kept for all of them at once, and the turns drawn in the end are the same.
struct ConversationTurnReveal: Equatable, Sendable {
    /// The display cycles the turns that arrive are drawn over.
    static let cycles = 10

    /// What a display cycle draws of the turns that arrived.
    struct Progress: Equatable, Sendable {
        /// Arrived turns not drawn yet.
        var hidden = 0
        /// The earliest turn drawn.
        var earliestDrawn: String?
    }

    /// The earliest turn drawn as of the last display cycle; nil until the reader asks for earlier
    /// turns, and once they go back to the latest output or to a place.
    private(set) var boundary: String?
    /// Display cycles since the turns drawing now began to arrive.
    private var cycle = 0

    /// The reader asked for the turns before `turnID`, the earliest loaded turn the window draws: any
    /// still waiting after it are drawn now.
    mutating func begin(before turnID: String?) {
        self = ConversationTurnReveal(boundary: turnID)
    }

    /// The next display cycle draws on from what this one drew; with nothing left, turns that arrive
    /// later have their own cycles.
    mutating func advance(_ progress: Progress) {
        boundary = progress.earliestDrawn
        cycle = progress.hidden > 0 ? cycle + 1 : 0
    }

    /// Every turn is drawn at once: the reader went back to the latest output or to a place.
    mutating func end() {
        if boundary != nil { self = ConversationTurnReveal() }
    }

    /// `presentation` with what this display cycle draws of the turns that arrived, the rest counted
    /// as earlier turns loaded here.
    func apply(to presentation: ConversationPresentation) -> (presentation: ConversationPresentation, progress: Progress) {
        guard let boundary, let arrived = presentation.turns.firstIndex(where: { $0.id == boundary }), arrived > 0
        else { return (presentation, Progress(earliestDrawn: boundary)) }
        let cyclesLeft = max(1, Self.cycles - cycle)
        let hidden = arrived - (arrived + cyclesLeft - 1) / cyclesLeft
        let earliest = presentation.turns[hidden].id
        guard hidden > 0 else { return (presentation, Progress(earliestDrawn: earliest)) }
        var drawn = presentation
        drawn.turns = Array(presentation.turns[hidden...])
        if case let .local(hiddenCount) = presentation.earlier {
            drawn.earlier = .local(hiddenCount: hiddenCount + hidden)
        } else {
            drawn.earlier = .local(hiddenCount: hidden)
        }
        return (drawn, Progress(hidden: hidden, earliestDrawn: earliest))
    }
}
