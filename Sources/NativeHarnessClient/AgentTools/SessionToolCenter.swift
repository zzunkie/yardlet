import Foundation
import Observation
import YardletAgentTools
import YardletRemote

/// The limits of the session tools (docs/AGENT_BROWSER_TOOLS.md, "Session tools"). One place, so a policy change is one edit.
enum SessionToolPolicy {
    /// How deep what the session tools start may nest, two limits counted apart
    /// (`AppModel.sessionToolSpawnRefusal`):
    /// - Tasks: a task sits at most this many levels down in the sidebar (`AppModel.sessionToolDepth(of:)`,
    ///   0 at the top level), so one at this level takes no child task, nor a schedule whose new tasks
    ///   go under it. Where a task sits counts, not who started it. Three, not two, since 2026-10-23:
    ///   children often offer task chips, and the person starts them under the child.
    /// - Subagents: a task at any level may run them. Subagents started by subagents stop this many
    ///   below their task, so a model's loop cannot fork without end, as Claude Code 2.1.291–2.1.299
    ///   stops its own Agent tool at depth 3 (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, else GrowthBook
    ///   `tengu_hazel_trellis`), which Yardlet leaves alone.
    static let maximumDepth = 3

    /// How many children and subagents one caller has running at once is the Mac's to say, not a
    /// fixed number. A start beyond what fits waits in request order and goes on
    /// its own once there is room (`AppModel.admitQueuedSessionToolStarts`); none is refused for it.
    /// - Below `concurrentChildrenFloor` a caller's start always goes, whatever the load: the Claude
    ///   app 3.1623.3 keeps at least 6 Claude Code processes on any Mac and Codex 0.163 lets a session
    ///   run 4 threads (`multi_agent_v2`), neither holding one back for load.
    /// - Above it, up to `concurrentChildrenCeiling`, a start goes while the Mac has room
    ///   (`macHasRoom`), one at a time and `startSpacing` apart, so each one's load shows before the
    ///   next.
    /// Each caller counts its own, as Codex and Claude Code count per session, so one task's many
    /// never take another's floor; beyond the floor, request order across callers.
    static let concurrentChildrenFloor = 6

    /// What this Mac's memory holds: one harness process per 3 GiB, never fewer than the floor. It is
    /// the Claude app's own size for its Claude Code processes (`Math.max(6, totalmem / 3 GiB)`), so on
    /// any Mac a task here may run as many as that app runs there. The cores bound how busy they may get
    /// (`macHasRoom`), not how many there are.
    static func concurrentChildrenCeiling(_ load: MacLoad) -> Int {
        max(concurrentChildrenFloor, Int(load.physicalMemory / (3 << 30)))
    }

    /// The Mac takes one more now: not running hot, no memory pressure, and fewer threads running or
    /// waiting for a core than it has cores (the kernel's one-minute load average, as `make -l` reads it).
    static func macHasRoom(_ load: MacLoad) -> Bool {
        load.thermalState != .serious && load.thermalState != .critical
            && load.memoryPressure == .normal
            && load.loadAverage < Double(load.cores)
    }

    /// How long a start beyond the floor waits after the previous one: the kernel's load average
    /// moves every 5 seconds and a new harness takes a few to load.
    static let startSpacing: Duration = .seconds(10)
    /// How often what waits is looked at again: a child that ended frees its place within this.
    static let admissionInterval: Duration = .seconds(2)

    /// Which of the waiting starts go now, in request order, and whether one of them goes beyond its
    /// caller's floor. `running` is each caller's running children and subagents; a caller's starts
    /// go in its own order, and another caller's wait does not hold them back.
    static func admitted(_ waiting: [(id: UUID, callerID: UUID)], running: [UUID: Int], load: MacLoad,
                         mayStartAboveFloor: Bool) -> (ids: [UUID], aboveFloor: Bool) {
        var counts = running
        var roomAboveFloor = mayStartAboveFloor && macHasRoom(load)
        var blocked = Set<UUID>()
        var ids: [UUID] = []
        var aboveFloor = false
        for entry in waiting where !blocked.contains(entry.callerID) {
            let count = counts[entry.callerID, default: 0]
            if count < concurrentChildrenFloor {
                ids.append(entry.id)
            } else if roomAboveFloor, count < concurrentChildrenCeiling(load) {
                ids.append(entry.id)
                roomAboveFloor = false
                aboveFloor = true
            } else {
                blocked.insert(entry.callerID)
                continue
            }
            counts[entry.callerID] = count + 1
        }
        return (ids, aboveFloor)
    }

    /// A message within the caller's project goes without asking, as in the Claude app; a task the
    /// caller shares a split view with counts as within it, since the person put them side by side.
    static let splitNeighborsShareProject = true
    /// How long the app waits for the person's answer to a session tool's approval before refusing.
    static let approvalTimeout: Duration = .seconds(600)
    /// How long a notification for a child task the agent asked about may wait for its first turn's end.
    static let notificationWatchLimit: Duration = .seconds(6 * 60 * 60)
    /// A person's message up to this many characters goes whole with a quote from it: a chat message,
    /// even several short paragraphs of one. A longer one is mostly a brief or a paste, and only its
    /// paragraphs that hold the quoted words go, so the receiving task gets their context without the
    /// rest of what the person asked of the sending task.
    static let wholeQuotedMessageLength = 1_000

    /// The longest a call may wait (`wait`, a foreground `run_agent`, `wait_tasks`, the person's
    /// approval) before it answers with the state instead, below each caller harness's limit on
    /// one MCP call. Claude Code (2.1.291–2.1.299): a hard limit `MCP_TOOL_TIMEOUT` of 10^8 ms by
    /// default, and an idle limit for stdio of 30 minutes (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`) that
    /// every progress notification restarts — `yardlet-mcp` sends one every 20 seconds
    /// (`MCPStdioLoop`). Codex: the server's `tool_timeout_sec`, which Yardlet sets to 30 minutes for
    /// its own server. Other harnesses keep their own limits, unknown here; the MCP SDK's usual
    /// default is 60 seconds, so they wait less and poll with `wait_tasks`.
    static func waitCeiling(for harness: HarnessKind) -> Duration {
        switch harness {
        case .claudeCode, .codex: .seconds(25 * 60)
        default: .seconds(50)
        }
    }

    /// How long `wait_tasks` waits when the call does not say, as the Codex app's `wait_threads`.
    static let waitDefault: Duration = .seconds(120)

    /// After `archive_task` answers "self": how long Yardlet waits for the harness to record that
    /// result (Claude Code's `tool_result`, Codex's `item/completed`) before it stops the turn
    /// anyway, how long it waits when it never saw the harness start the call, and how long the
    /// stopped turn may take to end before the archive closes the session regardless.
    static let selfArchiveResultWait: Duration = .seconds(10)
    static let selfArchiveUnseenCallWait: Duration = .seconds(3)
    static let selfArchiveStopWait: Duration = .seconds(15)

    /// What `read_task` returns at most.
    static let readCharacterLimit = 16_000
    static let readDefaultTurns = 4
    static let readMaximumTurns = 10
    static let listDefaultLimit = 30
    static let listMaximumLimit = 100
}

/// An approval a session tool asks the person for in the calling task: a message or a child into
/// another project, a subagent in another folder. It draws as the request card every harness draws
/// (`TranscriptConversationProjection.conversationRequest`) at the end of the task's running turn.
struct SessionToolApproval: Identifiable, Equatable, Sendable {
    static let idPrefix = "yardlet-session-tool-"

    let id: String
    let taskID: UUID
    let request: PermissionRequest

    var conversationRequest: ConversationRequest {
        TranscriptConversationProjection.conversationRequest(
            request, state: .pending, entry: TranscriptEntry(content: .permission(request, state: .pending))
        )
    }
}

/// A subagent the `run_agent` tool started: one harness session Yardlet runs headless for the
/// length of one prompt, in the calling task's folder, with no sidebar row. Its approvals wait in
/// the calling task's conversation; its conversation is kept with that task.
@MainActor
@Observable
final class AgentRun: Identifiable {
    enum State: Equatable, Sendable {
        /// It waits for room to start (`SessionToolPolicy.admitted`).
        case queued
        case starting
        case running
        case waitingForApproval
        case completed
        case failed(String)
        case stopped
        /// Yardlet quit while it waited for room or worked. It keeps no history with its harness
        /// (`keepsNoProviderHistory`), so nothing is left to continue; its caller is told instead
        /// (`AppModel.interruptAgentRunsForQuit`).
        case interrupted

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .stopped, .interrupted: true
            case .queued, .starting, .running, .waitingForApproval: false
            }
        }

        var word: String {
            switch self {
            case .queued: "queued"
            case .starting: "starting"
            case .running: "running"
            case .waitingForApproval: "waiting for the person's approval"
            case .completed: "completed"
            // Its reason goes with it to whoever reads the state: `wait_tasks`, the caller's message, its record.
            case let .failed(reason): "failed: \(reason)"
            case .stopped: "stopped"
            case .interrupted: "interrupted when Yardlet quit; it cannot continue"
            }
        }
    }

    let id: UUID
    /// The task, or the subagent, that called `run_agent`.
    let callerID: UUID
    /// The sidebar task whose conversation shows it: the caller, or the caller's own host.
    let hostTaskID: UUID
    let harness: HarnessKind
    /// The model the call named; nil runs the harness's default.
    let model: String?
    let prompt: String
    let workspaceURL: URL
    let depth: Int
    /// What it may do without asking: the level its harness runs at, chosen or inherited, never freer than its caller.
    let permission: TaskPermissionLevel
    /// The options its harness started with, its permission mode among them.
    @ObservationIgnored var options: [String: String] = [:]
    /// When it started: when it was asked for, or when it left the line for room.
    var startedAt: Date
    /// Its calling task gets a message when it ends with no call waiting for it (`AppModel.finishAgentRun`),
    /// unless the call said `notify: false`, the caller is a subagent, or the caller's turn stopped it.
    var notifiesCaller = false
    /// Calls waiting for it now (its own `run_agent`, `wait_tasks`): an end while one waits is in that
    /// call's answer.
    @ObservationIgnored var waitingCalls = 0
    /// The harness keeps this session out of its own history (Claude Code
    /// `--no-session-persistence`, an ephemeral Codex thread, Pi `--no-session`); false where it
    /// has no way to, and its history then has the session as any other.
    var keepsNoProviderHistory = false
    /// A judge of the routing evaluation: no Yardlet tools or instructions, no
    /// conversation kept, no ledger line, and it stops rather than wait on a request.
    var isEvaluationJudge = false
    /// The account it runs on, and why; nil runs the account new tasks start on.
    var accountStart: AppModel.AccountStart?
    var connection: ProviderConnection? { accountStart?.connection }

    var state: State = .starting {
        didSet { if state != oldValue { stateDidChange?(self) } }
    }
    /// Called on every change of `state` (`SessionToolCenter.add`).
    @ObservationIgnored var stateDidChange: (@MainActor (AgentRun) -> Void)?
    /// The subagent's conversation: the shared transcript, or a Codex thread's.
    private(set) var entries: [TranscriptEntry] = []
    private var pendingPermissionEntries: [TranscriptEntry] = []
    /// Set on every state the thread streams, and each differs from the last: its observers hear of it
    /// without the two being compared first, which in a long turn cost as much as the state itself.
    var codexState: CodexTaskState? {
        get {
            access(keyPath: \.codexState)
            return storedCodexState
        }
        set {
            withMutation(keyPath: \.codexState) { storedCodexState = newValue }
        }
    }
    @ObservationIgnored private var storedCodexState: CodexTaskState?
    /// Its answer once it ended (`AppModel.finishAgentRun`).
    var answer: String?
    /// Its latest answer: the one it ended on, or while it waits for the person what it has said so
    /// far, read when asked rather than on every state or event it streams.
    var currentAnswer: String? {
        if state.isFinished { return answer }
        // One that still works has not answered yet; one that waits for the person has, for now.
        return state == .waitingForApproval ? latestAnswer ?? answer : nil
    }

    /// The line its card shows while it works: its latest call or message, in the Mac's words.
    var progressLine: String? {
        let latest: (item: ConversationItem, turnID: String)?
        if let codexThread, let turnID = codexThread.thread?.turns.last?.id {
            latest = CodexConversationProjection.lastItem(in: codexThread, workspaceURL: workspaceURL)
                .map { ($0, turnID) }
        } else {
            latest = presentation().turns.last.flatMap { turn in (turn.work + turn.answers).last.map { ($0, turn.id) } }
        }
        guard let latest,
              let remote = RemoteConversationProjection.item(latest.item, turnID: latest.turnID, harness: harness,
                                                             workspaceURL: workspaceURL, inWork: false)
        else { return nil }
        let text = remote.title ?? remote.text ?? ""
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }

    /// The first line of its answer, for its card once it ended.
    var answerLine: String? {
        answer?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    @ObservationIgnored var adapter: (any HarnessAdapter)?
    @ObservationIgnored var handle: HarnessSessionHandle?
    @ObservationIgnored var builder = TranscriptBuilder() {
        didSet {
            entries = builder.entries
            // A transcript delta leaves observers of requests alone unless a request itself changed.
            let pending = builder.pendingPermissionEntries
            if pendingPermissionEntries != pending { pendingPermissionEntries = pending }
        }
    }
    @ObservationIgnored var hasStartedTurn = false
    /// The harness reported work for the prompt, so a "ready" it reports next ends the turn rather
    /// than reporting the connection.
    @ObservationIgnored var sawWork = false
    @ObservationIgnored var lastError: String?
    /// The plan limit that stopped its turn, as its harness reported it: the turn ends as failed with it
    /// (`AppModel.endAgentRunTurn`).
    @ObservationIgnored var usageLimit: HarnessRateLimit?
    @ObservationIgnored var consumers: [Task<Void, Never>] = []

    init(id: UUID = UUID(), callerID: UUID, hostTaskID: UUID, harness: HarnessKind, model: String? = nil,
         prompt: String, workspaceURL: URL, depth: Int, permission: TaskPermissionLevel = .standard,
         startedAt: Date = Date()) {
        self.id = id
        self.callerID = callerID
        self.hostTaskID = hostTaskID
        self.harness = harness
        self.model = model
        self.prompt = prompt
        self.workspaceURL = workspaceURL
        self.depth = depth
        self.permission = permission
        self.startedAt = startedAt
    }

    /// The card's name for it: the harness, and the model when the call named one.
    var label: String {
        AgentRun.label(harness: harness, model: model)
    }

    /// Its harness and model as a subagent's card and the rail's Agents card name them beside its
    /// name: "Codex · gpt-5.5", or the harness alone.
    nonisolated static func harnessLabel(harness: HarnessKind?, model: String?) -> String {
        let name = harness?.displayName ?? L10n.string("Subagent")
        guard let model, !model.isEmpty else { return name }
        return "\(name) · \(model)"
    }

    nonisolated static func label(harness: HarnessKind?, model: String?) -> String {
        let name = harness?.displayName ?? L10n.string("Subagent")
        guard let model, !model.isEmpty else { return L10n.format("%@ agent", name) }
        return L10n.format("%@ agent · %@", name, model)
    }

    /// Its conversation as every conversation draws: the Codex thread once it has turns, else the
    /// transcript.
    func presentation() -> ConversationPresentation {
        if let codexThread {
            return CodexConversationProjection.presentation(codexThread, workspaceURL: workspaceURL,
                                                            historySelection: nil)
        }
        return TranscriptConversationProjection.presentation(
            from: entries, harness: harness, status: state.isFinished ? .ready : .running,
            latestTurnIsComplete: state == .completed)
    }

    /// The Codex thread its conversation draws, once it has turns.
    private var codexThread: CodexTaskState? {
        codexState?.thread?.turns.isEmpty == false ? codexState : nil
    }

    /// The last answer of its latest turn, read when a tool returns its result or the run ends.
    var latestAnswer: String? {
        if let codexThread { return CodexConversationProjection.latestAnswer(in: codexThread, workspaceURL: workspaceURL) }
        return AppModel.latestAnswer(in: presentation())
    }

    /// What it said last in its latest turn, a working note too: the answer so far of one that ended
    /// before it answered.
    var lastWords: String? {
        guard let turn = presentation().turns.last else { return nil }
        for item in (turn.work + turn.answers).reversed() {
            switch item.kind {
            case let .answer(text, _), let .commentary(text, _):
                if !text.isEmpty { return text }
            default:
                continue
            }
        }
        return nil
    }

    /// Its name where it is shown: what it was asked, as its card and the rail's Agents card name it.
    var name: String { ConversationSubagent.name(asked: prompt) ?? label }

    /// The requests it waits on the person for, named for it: they wait in the calling task's
    /// conversation beside the task's own. One that ended waits on no one: the runtime that would
    /// hear an answer ended with it.
    var pendingRequests: [ConversationRequest] {
        guard !state.isFinished else { return [] }
        let requests = if let codexThread {
            CodexConversationProjection.pendingRequests(in: codexThread)
        } else {
            pendingPermissionEntries.compactMap { entry -> ConversationRequest? in
                guard let request = entry.pendingPermission else { return nil }
                return TranscriptConversationProjection.conversationRequest(request, state: .pending, entry: entry)
            }
        }
        return requests.map { request in
            var request = request
            request.title = L10n.format("%@: %@", name, request.title)
            return request
        }
    }

    /// Once it ended, what it still asked can no longer be answered: its conversation, shown and
    /// kept, reads those requests as expired, as a task's do when its turn ends.
    func finishTranscript(_ entries: [TranscriptEntry]) {
        var expired = entries
        for index in expired.indices {
            guard case let .permission(request, .pending) = expired[index].content else { continue }
            expired[index].content = .permission(request, state: .expired)
        }
        self.entries = expired
        pendingPermissionEntries = []
    }
}

/// What the session tools keep while the app runs: the approvals they wait on, the subagents they
/// run, and which tasks `create_task` made. That list is kept across launches in Yardlet's
/// defaults; nothing is written to a harness's files.
@MainActor
@Observable
final class SessionToolCenter {
    private(set) var approvals: [UUID: [SessionToolApproval]] = [:]
    private(set) var runs: [UUID: AgentRun] = [:]

    /// The call waiting on each card, by the card's ID.
    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<CardEnd, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    /// The tasks `create_task` made, under the key that once kept how deep each sat: only whether a
    /// task is there is read, not the number an older Yardlet wrote for it.
    @ObservationIgnored private let madeTasksKey = "Yardlet.sessionTools.depth"
    /// Where a finished subagent's conversation is kept, under its host task; nil keeps none (tests).
    @ObservationIgnored var runDirectory: URL?
    /// A long conversation must not delay unrelated state files such as composer drafts.
    let keptRunWriter = StateFileWriter()
    @ObservationIgnored private var pendingRunWrites: [URL: UUID] = [:]
    /// A shorter wait than the caller harness's limit, for tests.
    @ObservationIgnored var waitCeilingOverride: Duration?
    /// Shorter waits than `SessionToolPolicy`'s self-archive waits, for tests.
    @ObservationIgnored var selfArchiveWaitOverride: Duration?
    /// The tasks archiving themselves: `archive_task` answered "self", and their turn stops before
    /// they are archived.
    @ObservationIgnored private(set) var archivingSelf: Set<UUID> = []
    /// The tasks whose latest `send_message_to_task` this turn went to their parent task, which took it
    /// at once (`TaskMessageDelivery.delivered` or `.steered`). A turn that ends on that call ends with a
    /// result its parent has (`AppModel.turnEndReachedParent`); the turn's end forgets it. Kept in memory
    /// only: after a relaunch such a result reads as unread, as any other.
    @ObservationIgnored var reportedToParent: Set<UUID> = []

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
    }

    // MARK: Archiving a task's own

    /// False when the task already archives itself.
    func beginArchivingSelf(_ taskID: UUID) -> Bool {
        archivingSelf.insert(taskID).inserted
    }

    func endArchivingSelf(_ taskID: UUID) {
        archivingSelf.remove(taskID)
    }

    func isArchivingSelf(_ taskID: UUID) -> Bool {
        archivingSelf.contains(taskID)
    }

    // MARK: Approvals

    func approvals(for taskID: UUID) -> [SessionToolApproval] {
        approvals[taskID] ?? []
    }

    func approval(_ id: String) -> SessionToolApproval? {
        approvals.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Adds an approval and waits for its answer: true to go ahead. Nobody answering within `timeout` is no.
    func ask(_ request: PermissionRequest, in taskID: UUID, callerID: UUID? = nil,
             timeout: Duration = SessionToolPolicy.approvalTimeout,
             onChange: @escaping @MainActor () -> Void) async -> Bool {
        await choose(request, in: taskID, callerID: callerID, timeout: timeout, onChange: onChange) != nil
    }

    /// As `ask`, for a card that offers more than one allow (`PermissionRequest.actions`): the allow the person
    /// chose, an answer that named none (a notification's Allow) taking the narrowest, or nil for no.
    func choose(_ request: PermissionRequest, in taskID: UUID, callerID: UUID? = nil,
                timeout: Duration = SessionToolPolicy.approvalTimeout,
                onChange: @escaping @MainActor () -> Void) async -> String? {
        if case let .allowed(action) = await decide(request, in: taskID, callerID: callerID, wait: timeout,
                                                    onChange: onChange) {
            return action
        }
        return nil
    }

    /// What a call that waited on a card got.
    enum CardAnswer: Equatable, Sendable {
        /// Allowed, with the allow the person chose ("" where the card offered none of its own).
        case allowed(String)
        case denied(String)
        case declined
        case cancelled
        /// Nobody answered while the call could wait. The card stays up for `cardStays` more, nil once its own time
        /// ended and it went; the call's `ApprovalWait.record` says so too.
        case unanswered(cardStays: Duration?)
    }

    /// Puts a card up in `taskID` and waits up to `wait` for the person's answer (docs/AGENT_BROWSER_TOOLS.md,
    /// "Approvals"). A card lives `cardLife`, the call waits on it no longer than that, and the card goes once answered.
    /// A tool call (`ApprovalWait.record`) that may wait less leaves the card up when its wait ends: the same call made
    /// again (the same caller, title, detail and answers) waits on that card, or takes the answer the person gave
    /// meanwhile, once. A question asked outside a tool call (a download the agent's act started) takes its card away
    /// then. A call cancelled meanwhile (a stopped turn, a script stopped) takes its card away at once and is answered no.
    func decide(_ request: PermissionRequest, in taskID: UUID, callerID: UUID?, wait: Duration, boundToCall: Bool = false,
                onChange: @escaping @MainActor () -> Void) async -> CardAnswer {
        guard !Task.isCancelled else { return .declined }
        let key = boundToCall ? request.id : Self.cardKey(request, taskID: taskID, callerID: callerID)
        let now = ContinuousClock.now
        leftAnswers = leftAnswers.filter { $0.value.until > now }
        if let left = leftAnswers.removeValue(forKey: key) { return left.answer }
        let id: String
        if let leftID = leftCards.removeValue(forKey: key), cards[leftID] != nil {
            id = leftID
        } else {
            id = request.id
            let expires = now + cardLife
            approvals[taskID, default: []].append(SessionToolApproval(id: id, taskID: taskID, request: request))
            cards[id] = Card(key: key, boundToCall: boundToCall, taskID: taskID, callerID: callerID, expires: expires, onChange: onChange,
                             life: Task { @MainActor [weak self] in
                                 try? await Task.sleep(until: expires)
                                 guard !Task.isCancelled else { return }
                                 self?.expire(id)
                             })
            onChange()
        }
        guard let expires = cards[id]?.expires else { return .declined }
        let callEnds = now + max(.zero, wait)
        let staysUp = !boundToCall && ApprovalWait.record != nil
        let leaving = callEnds < expires ? Task { @MainActor [weak self] in
            try? await Task.sleep(until: callEnds)
            guard !Task.isCancelled else { return }
            if staysUp { self?.leave(id) } else { self?.cancelWaiter(id) }
        } : nil
        // The waiter is in place before the cancellation's hop to the main actor can run.
        let end = await ApprovalWait.whilePersonReads {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    approvalWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelWaiter(id) }
            }
        }
        leaving?.cancel()
        onChange()
        switch end {
        case let .answered(answer):
            return answer
        case .left:
            let stays = max(.zero, expires - .now)
            ApprovalWait.record?.note(.init(cardStays: stays))
            return .unanswered(cardStays: stays)
        case .expired:
            ApprovalWait.record?.note(.init(cardStays: nil))
            return .unanswered(cardStays: nil)
        }
    }

    /// Answers an approval, with the action the person chose where its card offered several. One no call waits on
    /// any more keeps its answer for the same call made again. False when no card is up under this ID.
    @discardableResult
    func answer(_ id: String, allow: Bool, actionID: String? = nil) -> Bool {
        guard let request = approval(id)?.request, let card = takeCard(id) else { return false }
        let answer: CardAnswer
        let decision: PermissionDecision = allow ? .allow : .deny
        if let actionID, request.actions.contains(where: { $0.id == actionID && $0.decision == decision }) {
            answer = allow ? .allowed(actionID) : .denied(actionID)
        } else if allow && !card.boundToCall {
            answer = .allowed(PermissionActionPreference.preferred(from: request.actions, decision: .allow)?.id ?? "")
        } else {
            answer = .declined
        }
        if let waiter = approvalWaiters.removeValue(forKey: id) {
            waiter.resume(returning: .answered(answer))
        } else {
            leftAnswers[card.key] = (answer, card.taskID, card.callerID, ContinuousClock.now + cardLife)
            card.onChange()
        }
        return true
    }

    func isBoundForm(_ id: String) -> Bool { cards[id]?.boundToCall == true }

    /// A new message closes the outstanding form without choosing any of the server's options.
    func dismissBoundForm(_ id: String) -> Bool {
        guard isBoundForm(id) else { return false }
        return answer(id, allow: false)
    }

    /// Refuses every approval a task waits on, and takes away the cards no call waits on any more: its turn stopped,
    /// or it went away.
    func refuseApprovals(in taskID: UUID, stopping: Bool = false) {
        for approval in approvals(for: taskID) {
            if stopping, cards[approval.id]?.boundToCall == true {
                cancelWaiter(approval.id, answer: .cancelled)
            } else if approvalWaiters[approval.id] != nil {
                answer(approval.id, allow: false)
            } else {
                withdraw(approval.id)
            }
        }
        leftAnswers = leftAnswers.filter { $0.value.taskID != taskID }
    }

    /// The caller's turn ended: the cards it left up and the answers they got meanwhile go, since no call of that turn
    /// comes again to take them.
    func withdrawLeftApprovals(of callerID: UUID) {
        for (id, card) in cards where card.callerID == callerID && approvalWaiters[id] == nil { withdraw(id) }
        leftAnswers = leftAnswers.filter { $0.value.callerID != callerID }
    }

    /// The caller ended (a subagent finished): every card its calls put up goes, and a call still waiting on one is
    /// answered no.
    func refuseApprovals(of callerID: UUID) {
        for (id, card) in cards where card.callerID == callerID {
            if approvalWaiters[id] != nil { answer(id, allow: false) } else { withdraw(id) }
        }
        leftAnswers = leftAnswers.filter { $0.value.callerID != callerID }
    }

    /// How long a card stays up for the person: `SessionToolPolicy.approvalTimeout`; tests shorten it.
    @ObservationIgnored var cardLife: Duration = SessionToolPolicy.approvalTimeout

    private enum CardEnd {
        case answered(CardAnswer)
        /// The call that waited on it could wait no longer; it stays up.
        case left
        /// Its own time ended and it went.
        case expired
    }

    private struct Card {
        let key: String
        let boundToCall: Bool
        let taskID: UUID
        let callerID: UUID?
        let expires: ContinuousClock.Instant
        let onChange: @MainActor () -> Void
        let life: Task<Void, Never>
    }

    /// Each card that is up, by its approval's ID.
    @ObservationIgnored private var cards: [String: Card] = [:]
    /// The cards no call waits on any more, by `cardKey`.
    @ObservationIgnored private var leftCards: [String: String] = [:]
    /// The answers such cards got, by `cardKey`, kept for the same call made again until `until`.
    @ObservationIgnored private var leftAnswers: [String: (answer: CardAnswer, taskID: UUID, callerID: UUID?,
                                                           until: ContinuousClock.Instant)] = [:]

    private static func cardKey(_ request: PermissionRequest, taskID: UUID, callerID: UUID?) -> String {
        [taskID.uuidString, callerID?.uuidString ?? "", request.title, request.detail ?? "", request.command ?? "",
         request.actions.map(\.id).joined(separator: ",")].joined(separator: "\u{1}")
    }

    /// Takes the card down: off its task's list and out of the cards no call waits on.
    private func takeCard(_ id: String) -> Card? {
        guard let card = cards.removeValue(forKey: id) else { return nil }
        card.life.cancel()
        if leftCards[card.key] == id { leftCards[card.key] = nil }
        let kept = (approvals[card.taskID] ?? []).filter { $0.id != id }
        approvals[card.taskID] = kept.isEmpty ? nil : kept
        return card
    }

    /// The call waiting on the card could wait no longer: the card stays up for the same call made again.
    private func leave(_ id: String) {
        guard let card = cards[id], let waiter = approvalWaiters.removeValue(forKey: id) else { return }
        // The same card another call left before this one goes: the same call made again finds this one.
        if let earlier = leftCards[card.key], earlier != id { withdraw(earlier) }
        leftCards[card.key] = id
        waiter.resume(returning: .left)
    }

    /// The card's own time ended.
    private func expire(_ id: String) {
        guard let card = takeCard(id) else { return }
        if let waiter = approvalWaiters.removeValue(forKey: id) {
            waiter.resume(returning: .expired)
        } else {
            card.onChange()
        }
    }

    /// The call waiting on the card was cancelled: the card goes, and the call is answered no.
    private func cancelWaiter(_ id: String, answer: CardAnswer = .declined) {
        guard let waiter = approvalWaiters.removeValue(forKey: id) else { return }
        _ = takeCard(id)
        waiter.resume(returning: .answered(answer))
    }

    /// Takes down a card no call waits on.
    private func withdraw(_ id: String) {
        guard approvalWaiters[id] == nil, let card = takeCard(id) else { return }
        card.onChange()
    }

    // MARK: Subagents

    func add(_ run: AgentRun) {
        runs[run.id] = run
        // What waits on the subagent, or on the task that shows it, may look again.
        run.stateDidChange = { [weak self] run in
            self?.taskMayHaveSettled?(run.id)
            self?.taskMayHaveSettled?(run.hostTaskID)
        }
    }

    func run(_ id: UUID) -> AgentRun? {
        runs[id]
    }

    func runs(hostedBy taskID: UUID) -> [AgentRun] {
        runs.values.filter { $0.hostTaskID == taskID }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The run a host task's `run_agent` call is: by the agent ID its answer named, else the newest
    /// run of that prompt.
    func run(agentID: String?, prompt: String, hostTaskID: UUID?) -> AgentRun? {
        if let agentID, let id = UUID(uuidString: agentID), let run = runs[id] { return run }
        guard let hostTaskID else { return nil }
        return runs(hostedBy: hostTaskID).last { $0.prompt == prompt }
    }

    // MARK: Children

    /// Which caller started each child task and subagent, while the app runs: admission counts the
    /// running ones.
    @ObservationIgnored private var starters: [UUID: UUID] = [:]

    func noteStarted(_ id: UUID, by callerID: UUID) {
        starters[id] = callerID
    }

    func started(by callerID: UUID) -> [UUID] {
        starters.filter { $0.value == callerID }.map(\.key)
    }

    // MARK: Waiting for room

    /// A child task or subagent that waits for room to start (`SessionToolPolicy.admitted`).
    struct QueuedStart {
        /// The child task's or the subagent's ID.
        let id: UUID
        let callerID: UUID
        /// A child task's first message, as it goes to the task; nil for a subagent.
        let firstMessage: String?
        /// Messages sent to the child task while it waited, delivered after its first, in order.
        var laterMessages: [String] = []
        /// What starts it once there is room.
        let start: @MainActor (QueuedStart) async -> Void
    }

    /// What waits for room, in request order. A row reads `isQueued`.
    private(set) var queue: [QueuedStart] = []
    /// Admitted and still starting: they count as running until their start returns.
    @ObservationIgnored var starting: Set<UUID> = [] {
        didSet { for id in oldValue.subtracting(starting) { taskMayHaveSettled?(id) } }
    }
    /// Called when a subagent's state changes, or a child task or subagent leaves the line for room or its start
    /// returns: what waits on it may look again (`AppModel.taskMayHaveSettled`).
    @ObservationIgnored var taskMayHaveSettled: (@MainActor (UUID) -> Void)?
    /// When the last start beyond a caller's floor went, so the next one waits for its load to show.
    @ObservationIgnored var lastStartAboveFloor: ContinuousClock.Instant?
    /// Where admission reads the Mac's load; tests give their own.
    @ObservationIgnored var loadReader: any MacLoadReading = LiveMacLoadReader()
    /// Runs admission while something waits (`AppModel.admitQueuedSessionToolStarts`).
    @ObservationIgnored var admissionLoop: Task<Void, Never>?
    @ObservationIgnored private let queueKey = "Yardlet.sessionTools.queued"

    func isQueued(_ id: UUID) -> Bool {
        queue.contains { $0.id == id }
    }

    func enqueue(_ start: QueuedStart) {
        queue.append(start)
        persistQueue()
    }

    @discardableResult
    func dequeue(_ id: UUID) -> QueuedStart? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = queue.remove(at: index)
        persistQueue()
        taskMayHaveSettled?(id)
        return removed
    }

    /// A message for a child task that waits: it follows the first message. False when it does not wait.
    func appendMessage(_ text: String, toQueued id: UUID) -> Bool {
        guard let index = queue.firstIndex(where: { $0.id == id }), queue[index].firstMessage != nil else { return false }
        queue[index].laterMessages.append(text)
        persistQueue()
        return true
    }

    /// The child tasks that waited when the app last ran, in request order: a quit or a restart does
    /// not lose their first message. A subagent does not outlive the app: the quit interrupts one that
    /// waits as it interrupts one that works (`noteInterrupted`).
    func keptQueuedChildren() -> [(id: UUID, callerID: UUID, firstMessage: String, laterMessages: [String])] {
        (defaults.array(forKey: queueKey) as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let caller = (item["caller"] as? String).flatMap(UUID.init(uuidString:)),
                  let first = item["first"] as? String else { return nil }
            return (id, caller, first, item["later"] as? [String] ?? [])
        }
    }

    private func persistQueue() {
        let kept: [[String: Any]] = queue.compactMap { start in
            guard let first = start.firstMessage else { return nil }
            return ["id": start.id.uuidString, "caller": start.callerID.uuidString, "first": first,
                    "later": start.laterMessages]
        }
        if kept.isEmpty { defaults.removeObject(forKey: queueKey) } else { defaults.set(kept, forKey: queueKey) }
    }

    // MARK: Tasks made

    func noteMadeTask(_ taskID: UUID) {
        var stored = defaults.dictionary(forKey: madeTasksKey) ?? [:]
        stored[taskID.uuidString] = true
        defaults.set(stored, forKey: madeTasksKey)
    }

    /// Whether a session tool (`create_task`) made the task.
    func madeTask(_ taskID: UUID) -> Bool {
        defaults.dictionary(forKey: madeTasksKey)?[taskID.uuidString] != nil
    }

    /// A subagent's conversation as it was kept when it ended, for one that is no longer held (a
    /// subagent of an earlier launch). Nil where none was kept.
    func keptRun(_ id: UUID, hostTaskID: UUID) -> KeptAgentRun? {
        guard let runDirectory else { return nil }
        let url = runDirectory.appending(path: hostTaskID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString.lowercased()).json")
        // The rail normally reads an earlier launch's file. Opening one should not wait for
        // another run's transcript to finish saving.
        if pendingRunWrites[url] != nil { keptRunWriter.flush() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeptAgentRun.self, from: data)
    }

    /// A deleted task's record and its subagents' kept conversations go with it.
    func forget(_ taskID: UUID) {
        var stored = defaults.dictionary(forKey: madeTasksKey) ?? [:]
        if stored.removeValue(forKey: taskID.uuidString) != nil { defaults.set(stored, forKey: madeTasksKey) }
        dequeue(taskID)
        for run in runs(hostedBy: taskID) {
            dequeue(run.id)
            runs[run.id] = nil
        }
        if let folder = runDirectory?.appending(path: taskID.uuidString.lowercased(), directoryHint: .isDirectory) {
            keptRunWriter.flush()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Keeps a finished subagent's conversation with its host task, readable only by the user.
    func keep(_ run: AgentRun) {
        guard let runDirectory else { return }
        let folder = runDirectory.appending(path: run.hostTaskID.uuidString.lowercased(), directoryHint: .isDirectory)
        let file = folder.appending(path: "\(run.id.uuidString.lowercased()).json")
        let record = KeptAgentRun(id: run.id, callerID: run.callerID, harness: run.harness.rawValue,
                                  model: run.model, prompt: run.prompt, workspacePath: run.workspaceURL.path(percentEncoded: false),
                                  startedAt: run.startedAt, state: run.state.word, answer: run.answer,
                                  entries: run.entries)
        let writeID = UUID()
        pendingRunWrites[file] = writeID
        keptRunWriter.write(file, done: { [weak self] _ in
            if self?.pendingRunWrites[file] == writeID { self?.pendingRunWrites[file] = nil }
        }) { [codexState = run.codexState] in
            var snapshot = record
            if let codexState { snapshot.entries = CodexTranscriptSnapshotProjection.entries(from: codexState) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try StateFile.write(encoder.encode(snapshot), to: file, isPrivate: true)
        }
    }

    // MARK: Antigravity conversations

    private nonisolated static let antigravityConversationsName = "antigravity-conversations.json"

    /// Notes the Antigravity conversation a subagent runs and the folder it runs in, with its host task's
    /// subagents and gone with them: `agy acp` lists in a conversation every folder its process served,
    /// so only this says which one is the subagent's (`AntigravityConversationStore.ownFolder`).
    /// `{conversation ID: folder}`, the ID in lower case.
    func noteAntigravityConversation(_ conversationID: String, of run: AgentRun) {
        guard let runDirectory else { return }
        let file = runDirectory.appending(path: run.hostTaskID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: Self.antigravityConversationsName)
        var folders = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            ?? [:]
        folders[conversationID.lowercased()] = run.workspaceURL.path(percentEncoded: false)
        try? StateFile.write(JSONEncoder().encode(folders), to: file, isPrivate: true)
    }

    /// Every folder `noteAntigravityConversation` noted under `runDirectory`, by conversation ID. It reads
    /// one small file per task that ran an Antigravity subagent, off the main thread.
    nonisolated static func antigravityConversationFolders(in runDirectory: URL) -> [String: URL] {
        let hosts = (try? FileManager.default.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)) ?? []
        var folders: [String: URL] = [:]
        for host in hosts {
            guard let data = try? Data(contentsOf: host.appending(path: antigravityConversationsName)),
                  let noted = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            for (id, path) in noted where PathRules.current.isAbsolute(path) {
                folders[id] = URL(filePath: path, directoryHint: .isDirectory)
            }
        }
        return folders
    }
}

extension SessionToolCenter {
    /// A subagent a quit cut off, as the quit writes it down for the next launch.
    struct InterruptedRun: Codable, Equatable {
        var id: UUID
        var hostTaskID: UUID
        var interruptedAt: Date
        /// Its calling task is told when it ends (`AgentRun.notifiesCaller`).
        var tellsCaller: Bool
    }

    private static let interruptedKey = "Yardlet.sessionTools.interrupted"

    /// Writes down the subagents a quit cut off (each already kept with its host task) for the next
    /// launch to read once (`takeInterrupted`). A quit that cut none off writes nothing.
    func noteInterrupted(_ runs: [InterruptedRun]) {
        guard !runs.isEmpty, let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: Self.interruptedKey)
    }

    /// What the last quit wrote down, read once.
    func takeInterrupted() -> [InterruptedRun] {
        defer { defaults.removeObject(forKey: Self.interruptedKey) }
        guard let data = defaults.data(forKey: Self.interruptedKey) else { return [] }
        return (try? JSONDecoder().decode([InterruptedRun].self, from: data)) ?? []
    }
}

/// A finished subagent as it is kept on disk with its host task.
struct KeptAgentRun: Codable, Equatable {
    var id: UUID
    var callerID: UUID
    var harness: String
    var model: String?
    var prompt: String
    var workspacePath: String
    var startedAt: Date
    var state: String
    var answer: String?
    var entries: [TranscriptEntry]
}

extension ConversationPresentation {
    /// The requests Yardlet holds in the task (`AppModel.heldRequests`), at the end of the latest
    /// turn, where the calling turn waits on them or the cut-off question was asked; the follow and
    /// permission controls count them as waiting.
    mutating func appendHeldRequests(_ requests: [ConversationRequest]) {
        guard !requests.isEmpty, let last = turns.indices.last else { return }
        let known = Set(turns[last].requests.map(\.id))
        let added = requests.filter { !known.contains($0.id) }
        // A question asked again stands for the call that asked it, as an answered question's card
        // stands for its call: the call's own row (the CLI's refusal written as it quit) and the same
        // request's earlier card (a Codex request the stopped runtime left expired) are left out.
        let calls = Set(added.compactMap(\.toolCallID))
        let ids = Set(added.map(\.id))
        turns[last].work.removeAll { item in
            if case let .request(request) = item.kind { return ids.contains(request.id) }
            guard !calls.isEmpty, case let .transcript(entry) = item.source,
                  case let .activity(activity, _) = entry.content else { return false }
            return calls.contains(activity.id)
        }
        turns[last].requests += added
        pendingRequestIDs.formUnion(added.map(\.id))
    }
}
