import Foundation
import YardletAgentTools

/// What a waiting task waits for, after the Codex app's two row chips: an approval
/// (`codex.localTaskRow.awaitingApproval`) or an answer to a question it asked
/// (`codex.localTaskRow.needsInput`, Codex `requestUserInput` and MCP elicitation, Claude's
/// questions).
enum TaskPendingRequest: Equatable, Sendable {
    case approval
    case input
}

/// What the sidebar needs to know about a task beyond its record: the request its latest turn
/// waits on, and how that turn ended. `AppModel` keeps one per task, read from the task's
/// transcript and Codex timeline whenever they change, so the sidebar never reads either.
struct TaskAttentionDetail: Equatable, Sendable {
    /// The request the latest turn waits on, if it has one still open.
    var pendingRequest: TaskPendingRequest?
    /// The plan limit that stopped the latest turn.
    var usageLimit: HarnessRateLimit?
    /// The latest turn's error, in the provider's words.
    var errorMessage: String?
    /// When the latest turn started: its request's time, or Codex's own.
    var turnStartedAt: Date?
    /// The tasks the latest turn suggested (`spawn_task`), oldest first. Whether each was started or
    /// dismissed is the suggestion store's.
    var suggestions: [TaskAttentionSuggestion] = []
    /// What the task waits on while no turn runs, answered by the person's next message: a question
    /// a restart cut off (`RestartResumePolicy.Plan.questions`).
    var idleRequest: TaskPendingRequest?
    /// A lost connection cut the latest turn off, and the task continues once the network is back
    /// (`ConnectionResumePolicy`): it waits on nothing the person does.
    var isReconnecting = false
    /// A tab of the task's browser waits on the person (a passkey, a site's sign-in, a dialog, a file chooser, a
    /// permission, the agent's handoff), whatever its turn does: the live browser says so, not the transcript.
    var browserWait: BrowserPersonWait?

    static let none = TaskAttentionDetail()

    /// The latest turn of a transcript: everything after the last request the person sent. A
    /// message read into the running turn belongs to it.
    static func reading(_ entries: [TranscriptEntry]) -> TaskAttentionDetail {
        var detail = TaskAttentionDetail()
        for entry in entries.reversed() {
            switch entry.content {
            case .user:
                if entry.joinsRunningTurn == true { continue }
                detail.turnStartedAt = entry.createdAt
                return detail
            case let .permission(request, state) where state == .pending:
                let kind: TaskPendingRequest
                if case .questions = request.structured { kind = .input } else { kind = .approval }
                if detail.pendingRequest != .approval { detail.pendingRequest = kind }
            case let .usageLimit(limit):
                if detail.usageLimit == nil { detail.usageLimit = limit }
            case let .error(message, _, _):
                if detail.errorMessage == nil { detail.errorMessage = message }
            // Claude Code names the call `mcp__yardlet__spawn_task`, an ACP agent titles it `yardlet_spawn_task`.
            case let .activity(activity, _) where activity.kind.hasSuffix(TaskSuggestionToolCatalog.spawnTask)
                || activity.title.hasSuffix(TaskSuggestionToolCatalog.spawnTask):
                if let suggestion = ConversationTaskSuggestionProjection.suggestion(from: activity) {
                    detail.suggestions.insert(TaskAttentionSuggestion(suggestion), at: 0)
                }
            default:
                break
            }
        }
        return detail
    }

    /// A Codex timeline: the requests still open in the running turn (an approval first, as the
    /// Codex row shows its approval chip before its input chip), and how the last turn ended.
    static func reading(_ state: CodexTaskState) -> TaskAttentionDetail {
        var detail = TaskAttentionDetail()
        if let activeTurn = state.activeTurnID {
            func isOpen(_ turnID: String?) -> Bool { turnID == nil || turnID == activeTurn }
            let requests = state.serverRequestsByID.values.filter { $0.resolution == .pending && isOpen($0.turnID) }
            if requests.contains(where: \.kind.isApproval)
                || state.approvalsByID.values.contains(where: { $0.resolution == .pending && isOpen($0.turnID) }) {
                detail.pendingRequest = .approval
            } else if requests.contains(where: { $0.kind == .toolUserInput || $0.kind == .mcpElicitation }) {
                detail.pendingRequest = .input
            }
        }
        if let last = state.thread?.turns.last, last.status != .inProgress {
            switch CodexConversationProjection.outcome(last) {
            case let .usageLimit(limit, _)?: detail.usageLimit = limit
            case let .error(error)?: detail.errorMessage = CodexTurnErrorPresentation(last.error)?.text ?? error.message
            case nil: break
            }
        }
        if let last = state.thread?.turns.last {
            detail.turnStartedAt = last.startedAt
            for item in last.items.reversed() where item.lifecycle != .inProgress {
                switch item.content {
                case let .mcpToolCall(tool):
                    if let suggestion = ConversationTaskSuggestionProjection.suggestion(from: tool) {
                        detail.suggestions.insert(TaskAttentionSuggestion(suggestion), at: 0)
                    }
                default:
                    break
                }
            }
        }
        return detail
    }

    /// The first line of the latest turn's last finished message, as the home shows a result under
    /// its task. A message still streaming is not read. Kept apart from the detail
    /// (`AppModel.answerLineBySessionID`, one task at a time) because it changes as each message of a
    /// running turn ends, which must not redraw the sidebar.
    static func answerLine(_ entries: [TranscriptEntry]) -> String? {
        for entry in entries.reversed() {
            switch entry.content {
            case .user where entry.joinsRunningTurn != true: return nil
            case let .assistant(text, isStreaming: false): if let line = firstLine(text) { return line }
            default: break
            }
        }
        return nil
    }

    /// A Codex timeline's: its latest turn's last finished message Codex did not send while working on.
    static func answerLine(_ state: CodexTaskState) -> String? {
        for item in state.thread?.turns.last?.items.reversed() ?? [] where item.lifecycle != .inProgress {
            if case let .agentMessage(message) = item.content, !message.isDeliveredAsync,
               let line = firstLine(message.text) { return line }
        }
        return nil
    }

    /// A message's first line of words, without the Markdown around them: no heading, quote or list
    /// mark, no emphasis or code marks, and a link as its text.
    static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("```") }) else { return nil }
        let unmarked = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)+"#, with: "",
                                                 options: .regularExpression)
        let inline = (try? AttributedString(markdown: unmarked, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? unmarked
        let words = inline.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > 240 ? String(words.prefix(240)) + "…" : words
    }

    /// A Codex task has both; its own timeline speaks first.
    func merged(over other: TaskAttentionDetail) -> TaskAttentionDetail {
        TaskAttentionDetail(
            pendingRequest: pendingRequest ?? other.pendingRequest,
            usageLimit: usageLimit ?? other.usageLimit,
            errorMessage: errorMessage ?? other.errorMessage,
            turnStartedAt: turnStartedAt ?? other.turnStartedAt,
            suggestions: suggestions.isEmpty ? other.suggestions : suggestions,
            idleRequest: idleRequest ?? other.idleRequest,
            isReconnecting: isReconnecting || other.isReconnecting,
            browserWait: browserWait ?? other.browserWait
        )
    }
}

/// A task the latest turn suggested, as the home lists one not yet started or dismissed.
struct TaskAttentionSuggestion: Equatable, Sendable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// Its chip's title (`TaskSuggestionCard`).
    init(_ suggestion: ConversationTaskSuggestion) {
        self.init(id: suggestion.id, title: suggestion.title ?? L10n.string("Untitled task"))
    }
}

/// The Codex app's thread attention states (`Jtr`), in the order it sorts them (`Lkr`): a thread
/// waiting for the person comes first, then one with an unread result, then one still working.
/// "Next task needing attention" (`⌥⌘A`), the Dock badge, the activity view and the sidebar read it
/// (`TaskAttentionProjection.state`).
enum TaskAttentionState: Int, Comparable, Sendable {
    case waiting = 0
    case unread = 1
    case active = 2
    case idle = 3

    /// Codex `needsAttention`: waiting for the person or holding a result they have not read.
    /// `⌥⌘A` goes only to these; the activity view also lists tasks still working.
    var needsAttention: Bool { self == .waiting || self == .unread }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a task sits in attention order: its state, then the most recently active first.
struct TaskAttentionPlace: Equatable, Sendable {
    var state: TaskAttentionState
    var recency: Date
}

/// The one definition of "needs attention" and its order. `⌥⌘A` opens the first task that needs
/// attention, the Dock badge counts them, and the activity view lists every task that is not idle
/// in the same order.
enum TaskAttentionProjection {
    /// Waiting while a request is open, else active while a turn runs, else unread while a finished
    /// result (a failed one included) is unread, else active while a bash-mode command runs, else
    /// idle. A task can wait without its status saying so: Codex keeps a turn running while it asks
    /// the person a question. Unlike the Codex app's `Jtr`, a running turn is not unread: the Dock
    /// badge counted only finished results first, and this keeps that.
    static func state(
        of session: SessionRecord,
        detail: TaskAttentionDetail? = nil,
        isShellBusy: Bool = false
    ) -> TaskAttentionState {
        if waitingRequest(of: session, detail: detail) != nil || detail?.browserWait != nil { return .waiting }
        // A turn a lost connection cut off continues on its own: the task is still working.
        if session.status == .running || detail?.isReconnecting == true { return .active }
        if session.hasUnreadUpdate { return .unread }
        if isShellBusy { return .active }
        return .idle
    }

    /// The request a task waits on: a waiting status is an approval unless the turn says it asked a
    /// question, a running turn waits when it has a request open, and a task with no turn running
    /// waits when its question waits for the person's next message.
    static func waitingRequest(of session: SessionRecord, detail: TaskAttentionDetail?) -> TaskPendingRequest? {
        switch session.status {
        case .waitingForApproval: detail?.pendingRequest ?? .approval
        case .running: detail?.pendingRequest
        case .ready, .completed, .failed: detail?.idleRequest
        }
    }

    static func place(
        of session: SessionRecord,
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> TaskAttentionPlace {
        TaskAttentionPlace(
            state: state(of: session, detail: details[session.id], isShellBusy: shellBusy.contains(session.id)),
            recency: session.updatedAt
        )
    }

    /// The task "Next task needing attention" opens: the first that needs attention, never the one
    /// already shown.
    static func nextSession(
        in sessions: [SessionRecord],
        excluding current: UUID?,
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> UUID? {
        ordered(sessions.filter { $0.id != current }, details: details, shellBusy: shellBusy)
            .first { $0.place.state.needsAttention }?
            .session.id
    }

    /// Whether a task needs the person: it waits for an approval or an answer, or it finished,
    /// failed included, with a result they have not read. "Next task needing attention", the Dock
    /// badge, the activity view's button and the sidebar read this one definition.
    static func needsAttention(
        _ session: SessionRecord,
        detail: TaskAttentionDetail? = nil,
        isShellBusy: Bool = false
    ) -> Bool {
        state(of: session, detail: detail, isShellBusy: isShellBusy).needsAttention
    }

    /// How many of these tasks need the person: the Dock badge's number, and whether the activity
    /// view's button shows its badge.
    static func count(
        in sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> Int {
        sessions.reduce(0) { total, session in
            total + (needsAttention(session, detail: details[session.id],
                                    isShellBusy: shellBusy.contains(session.id)) ? 1 : 0)
        }
    }

    /// Every task that needs the person, in attention order: `nextSession` opens the first, `count`
    /// counts them, and the new-task screen shows them on their projects' lines.
    static func attentionList(
        in sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> [SessionRecord] {
        ordered(sessions, details: details, shellBusy: shellBusy)
            .filter { $0.place.state.needsAttention }
            .map(\.session)
    }

    /// The activity view's list: every task that is waiting, unread or working, in attention order.
    /// A task listed while the view is open keeps the place it was listed at (`kept`), so a task
    /// does not jump or leave the list when it is opened and read, or finishes, as the Codex app
    /// keeps its priority list until the view is closed. A task archived or deleted leaves.
    static func activityList(
        in sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = [],
        kept: [UUID: TaskAttentionPlace] = [:]
    ) -> [SessionRecord] {
        ordered(sessions, details: details, shellBusy: shellBusy, kept: kept)
            .filter { $0.place.state != .idle }
            .map(\.session)
    }

    /// The places of the tasks the activity view lists now, to keep while it stays open.
    static func places(
        of sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = [],
        kept: [UUID: TaskAttentionPlace] = [:]
    ) -> [UUID: TaskAttentionPlace] {
        var places = kept
        for entry in ordered(sessions, details: details, shellBusy: shellBusy, kept: kept)
        where entry.place.state != .idle {
            places[entry.session.id] = entry.place
        }
        return places
    }

    /// Codex `Fkr`: by state, then the most recently active first; the ID breaks ties.
    private static func ordered(
        _ sessions: [SessionRecord],
        details: [UUID: TaskAttentionDetail],
        shellBusy: Set<UUID>,
        kept: [UUID: TaskAttentionPlace] = [:]
    ) -> [(session: SessionRecord, place: TaskAttentionPlace)] {
        sessions
            .map { session in
                (session, kept[session.id] ?? place(of: session, details: details, shellBusy: shellBusy))
            }
            .sorted { lhs, rhs in
                if lhs.1.state != rhs.1.state { return lhs.1.state < rhs.1.state }
                if lhs.1.recency != rhs.1.recency { return lhs.1.recency > rhs.1.recency }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .map { (session: $0.0, place: $0.1) }
    }
}
