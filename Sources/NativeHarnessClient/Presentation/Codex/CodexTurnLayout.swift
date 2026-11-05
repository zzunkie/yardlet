import Foundation

/// What a Codex turn sent, what Codex noticed beside it, and what came after, and what the turn
/// offers. The timeline draws a turn's sent messages first, then the provider's notices, the turn
/// header, the work, and the answer; the projection lays out the work and the answer by the rule
/// every harness shares (`ConversationTurnLayout`).
///
/// Each item goes to exactly one part, so the parts together hold every item of the turn, each in
/// the order Codex wrote it.
struct CodexTurnLayout: Equatable, Sendable {
    enum Section: Equatable, Sendable {
        /// What the person sent.
        case prompt
        /// The provider's notices beside the turn, such as a model reroute.
        case notice
        /// What Codex wrote and did: its messages, plans and every tool.
        case work
    }

    let userItems: [CodexItemState]
    let noticeItems: [CodexItemState]
    /// What Codex wrote and did, in the order it did it.
    let workItems: [CodexItemState]
    /// The turn carries a request the person sent that the composer can read back.
    let hasUserMessage: Bool
    /// Codex wrote an answer, commentary or plan with text; a running turn reads "Thinking" until it does.
    let hasAgentOutput: Bool

    init(turn: CodexTurnState) {
        var user: [CodexItemState] = []
        var notices: [CodexItemState] = []
        var work: [CodexItemState] = []
        for item in turn.items {
            switch Self.section(for: item.content) {
            case .prompt: user.append(item)
            case .notice: notices.append(item)
            case .work: work.append(item)
            }
        }
        userItems = user
        noticeItems = notices
        workItems = work
        hasUserMessage = turn.userInputDraft != nil
        hasAgentOutput = turn.items.contains { item in
            switch item.content {
            case let .agentMessage(message):
                return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .plan(text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    static func section(for content: CodexItemContent) -> Section {
        switch content {
        case .userMessage: .prompt
        case .notice: .notice
        default: .work
        }
    }

    /// The turn draws its header (work summary, menu, divider): it has a label, a request, work to
    /// fold, or a time.
    static func showsHeader(_ turn: CodexTurnState, showsTurnLabel: Bool, hasUserMessage: Bool, hasWorkDetails: Bool) -> Bool {
        showsTurnLabel || hasUserMessage || hasWorkDetails || turn.durationMilliseconds != nil || turn.startedAt != nil
    }

    /// The one turn whose request can be edited: the latest turn the person sent a message in,
    /// once every turn has finished. A turn that runs is looked for from the end, where it is while
    /// the thread streams.
    static func editableTurnID(in thread: CodexThreadState) -> String? {
        guard thread.turns.lastIndex(where: { !$0.status.isTerminal }) == nil else { return nil }
        return thread.turns.last(where: \.hasNativeUserMessage)?.id
    }

    /// The plan `turn` asks to implement. Only the latest turn asks; any later message, including
    /// a typed reply, answers it.
    static func offeredPlan(for turn: CodexTurnState, in thread: CodexThreadState) -> String? {
        guard thread.turns.last?.id == turn.id else { return nil }
        return CodexPlanImplementation.offeredPlan(in: turn)
    }
}
