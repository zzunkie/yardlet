#if DEBUG
/// How often the window's widest views worked out their bodies: the window itself, each sidebar
/// row, each composer, and a dot's picture. Plain counters the redraw tests read while a task
/// streams or a pet plays; off unless a test turns them on, and absent from release builds.
@MainActor
enum ViewBodyCensus {
    enum Body: Hashable, Sendable {
        case mainWindow
        case sidebarRow
        case composer
        /// A conversation turn drawn again in its own hosting view (`ConversationTurnHosting`).
        case conversationTurn
        /// A conversation turn's hosting view made, not found kept with its task.
        case conversationTurnHosting
        /// A dot's picture, which plays its pet on a layer without being worked out again.
        case personalAgentAvatar
        /// The conversation's timeline (`ConversationTimeline`), which projects and lays out its turns.
        case conversationTimeline
        /// The dots' content: the conversation beside its details. A new state of the room leaves it
        /// as it is.
        case personalAgentContent
        /// A dot's Outputs list, drawn again only when what it lists or how far it read changes.
        case personalAgentOutputs
        /// A dot's conversation with its messages, which a new state of its room leaves as it is.
        case personalAgentConversation
        /// The words in a dot's header for what its room says it is doing.
        case personalAgentStatus
        /// A message of a dot's reply dialog prepared for drawing: its inputs worked out and handed to
        /// its hosting view, which may find nothing changed.
        case personalAgentReplyRow
        /// A message of a dot's reply dialog drawn again in its hosting view.
        case personalAgentReplyRowGraph
        /// A hosting view made for a message of a dot's reply dialog.
        case personalAgentReplyRowHosting
    }

    static var isEnabled = false
    private(set) static var counts: [Body: Int] = [:]

    static func note(_ body: Body) {
        guard isEnabled else { return }
        counts[body, default: 0] += 1
    }

    static func reset() { counts = [:] }

    static subscript(body: Body) -> Int { counts[body] ?? 0 }
}
#endif
