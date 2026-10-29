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
