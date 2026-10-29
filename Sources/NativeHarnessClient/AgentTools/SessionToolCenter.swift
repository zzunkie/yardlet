import Foundation
import Observation
import YardletAgentTools
import YardletRemote

/// The limits of the session tools (docs/AGENT_BROWSER_TOOLS.md, "Session tools"). One place, so a policy change is one edit.
enum SessionToolPolicy {
    /// How deep tasks and subagents the session tools start may nest: a task (depth 0) may start a
    /// child or a subagent (depth 1), and so on down to depth 3 and no further. Three, not two, since
    /// 2026-10-23: children often offer task chips, and the person starts them under the child. The
    /// harnesses' own subagents are their own (Claude Code 2.1.291–2.1.299 stops its Agent tool at
    /// depth 3 — `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, else GrowthBook `tengu_hazel_trellis` —
    /// which Yardlet leaves alone).
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
    /// How long a notification for a child or subagent the agent asked about may wait for its end.
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

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .stopped: true
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
            case .failed: "failed"
            case .stopped: "stopped"
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
    /// What it may do without asking: read only when its caller is, else the harness's default.
    let permission: TaskPermissionLevel
    /// When it started: when it was asked for, or when it left the line for room.
    var startedAt: Date
    var notifiesCaller = false
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

    var state: State = .starting
    /// The subagent's conversation: the shared transcript, or a Codex thread's.
    var entries: [TranscriptEntry] = []
    var codexState: CodexTaskState?
    /// Its last answer.
    var answer: String?

    /// The line its card shows while it works: its latest call or message, in the Mac's words.
    var progressLine: String? {
        guard let turn = presentation().turns.last else { return nil }
        let items = turn.work + turn.answers
        guard let item = items.last,
              let remote = RemoteConversationProjection.item(item, turnID: turn.id, harness: harness,
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
    @ObservationIgnored var builder = TranscriptBuilder()
    @ObservationIgnored var hasStartedTurn = false
    /// The harness reported work for the prompt, so a "ready" it reports next ends the turn rather
    /// than reporting the connection.
    @ObservationIgnored var sawWork = false
    @ObservationIgnored var lastError: String?
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
        if let codexState, codexState.thread?.turns.isEmpty == false {
            return CodexConversationProjection.presentation(codexState, workspaceURL: workspaceURL,
                                                            historySelection: nil)
        }
        return TranscriptConversationProjection.presentation(
            from: entries, harness: harness, status: state.isFinished ? .ready : .running,
            latestTurnIsComplete: state == .completed)
    }

    /// Its name where it is shown: what it was asked, as its card and the rail's Agents card name it.
    var name: String { ConversationSubagent.name(asked: prompt) ?? label }

    /// The requests it waits on the person for, named for it: they wait in the calling task's
    /// conversation beside the task's own.
    var pendingRequests: [ConversationRequest] {
        presentation().turns.flatMap(\.requests).filter { $0.state == .pending }.map { request in
            var request = request
            request.title = L10n.format("%@: %@", name, request.title)
            return request
        }
    }
}

/// What the session tools keep while the app runs: the approvals they wait on, the subagents they
/// run, and how deep each task they started sits. Depth is kept across launches in Yardlet's
/// defaults; nothing is written to a harness's files.
@MainActor
@Observable
final class SessionToolCenter {
    private(set) var approvals: [UUID: [SessionToolApproval]] = [:]
    private(set) var runs: [UUID: AgentRun] = [:]

    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let depthKey = "Yardlet.sessionTools.depth"
    /// Where a finished subagent's conversation is kept, under its host task; nil keeps none (tests).
    @ObservationIgnored var runDirectory: URL?
    /// A shorter wait than the caller harness's limit, for tests.
    @ObservationIgnored var waitCeilingOverride: Duration?
    /// Shorter waits than `SessionToolPolicy`'s self-archive waits, for tests.
    @ObservationIgnored var selfArchiveWaitOverride: Duration?
    /// The tasks archiving themselves: `archive_task` answered "self", and their turn stops before
    /// they are archived.
    @ObservationIgnored private(set) var archivingSelf: Set<UUID> = []

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

    /// Adds an approval and waits for its answer: true to go ahead.
    func ask(_ request: PermissionRequest, in taskID: UUID, timeout: Duration = SessionToolPolicy.approvalTimeout,
             onChange: @escaping @MainActor () -> Void) async -> Bool {
        let approval = SessionToolApproval(id: request.id, taskID: taskID, request: request)
        approvals[taskID, default: []].append(approval)
        onChange()
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.answer(approval.id, allow: false)
        }
        let allowed = await withCheckedContinuation { continuation in
            approvalWaiters[approval.id] = continuation
        }
        timer.cancel()
        onChange()
        return allowed
    }

    /// Answers a waiting approval. False when none waits under this ID.
    @discardableResult
    func answer(_ id: String, allow: Bool) -> Bool {
        guard let continuation = approvalWaiters.removeValue(forKey: id) else { return false }
        for (taskID, list) in approvals {
            let kept = list.filter { $0.id != id }
            approvals[taskID] = kept.isEmpty ? nil : kept
        }
        continuation.resume(returning: allow)
        return true
    }

    /// Refuses every approval a task waits on: its turn stopped, or it went away.
    func refuseApprovals(in taskID: UUID) {
        for approval in approvals(for: taskID) { answer(approval.id, allow: false) }
    }

    // MARK: Subagents

    func add(_ run: AgentRun) {
        runs[run.id] = run
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
    @ObservationIgnored var starting: Set<UUID> = []
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
    /// not lose their first message. A subagent does not outlive the app, so none is kept.
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

    // MARK: Depth

    func depth(of taskID: UUID) -> Int {
        if let run = runs[taskID] { return run.depth }
        return (defaults.dictionary(forKey: depthKey)?[taskID.uuidString] as? Int) ?? 0
    }

    func setDepth(_ depth: Int, of taskID: UUID) {
        var stored = defaults.dictionary(forKey: depthKey) ?? [:]
        stored[taskID.uuidString] = depth
        defaults.set(stored, forKey: depthKey)
    }

    /// Whether a session tool (`create_task`) made the task: only those have a depth on record.
    func madeTask(_ taskID: UUID) -> Bool {
        defaults.dictionary(forKey: depthKey)?[taskID.uuidString] != nil
    }

    /// A subagent's conversation as it was kept when it ended, for one that is no longer held (a
    /// subagent of an earlier launch). Nil where none was kept.
    func keptRun(_ id: UUID, hostTaskID: UUID) -> KeptAgentRun? {
        guard let runDirectory else { return nil }
        let url = runDirectory.appending(path: hostTaskID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString.lowercased()).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeptAgentRun.self, from: data)
    }

    /// A deleted task's record and its subagents' kept conversations go with it.
    func forget(_ taskID: UUID) {
        var stored = defaults.dictionary(forKey: depthKey) ?? [:]
        if stored.removeValue(forKey: taskID.uuidString) != nil { defaults.set(stored, forKey: depthKey) }
        dequeue(taskID)
        for run in runs(hostedBy: taskID) {
            dequeue(run.id)
            runs[run.id] = nil
        }
        if let folder = runDirectory?.appending(path: taskID.uuidString.lowercased(), directoryHint: .isDirectory) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Keeps a finished subagent's conversation with its host task, readable only by the user.
    func keep(_ run: AgentRun) {
        guard let runDirectory else { return }
        let folder = runDirectory.appending(path: run.hostTaskID.uuidString.lowercased(), directoryHint: .isDirectory)
        let record = KeptAgentRun(id: run.id, callerID: run.callerID, harness: run.harness.rawValue,
                                  model: run.model, prompt: run.prompt, workspacePath: run.workspaceURL.path(percentEncoded: false),
                                  startedAt: run.startedAt, state: run.state.word, answer: run.answer,
                                  entries: run.codexState.map(CodexTranscriptSnapshotProjection.entries(from:))
                                      ?? run.entries)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            let url = folder.appending(path: "\(run.id.uuidString.lowercased()).json")
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: data,
                                           attributes: [.posixPermissions: 0o600])
        } catch {}
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
