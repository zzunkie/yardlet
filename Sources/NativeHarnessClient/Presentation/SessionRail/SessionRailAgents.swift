import Foundation
import YardletAgentTools

/// The agents working for a task, the rail's Agents card: the Codex app's thread summary sections
/// "Subagents" (`background-subagents`, every child thread of the conversation, the done ones muted)
/// and "Created chats" (`created-tasks`) in one list. It holds:
/// - a provider's own subagent the shared transcript reports — Claude Code's Agent or Task call and
///   the agents it keeps running in the background (`HarnessSubtaskReference.isAgent`); a subagent's
///   own agent is listed under it;
/// - a Codex child thread its `spawnAgent` call or `subAgentActivity` names, with the state the
///   thread's calls last reported (`agentsStates`), which is all Yardlet's Codex timeline has;
/// - a subagent Yardlet's `run_agent` ran (`AgentRun`), its requests to the person with it;
/// - a child task `create_task` made, nested under the task in the sidebar, with what it waits on the
///   person for: its requests, and the questions a Codex child asked (`request_user_input_async`),
///   which wait even after its turn ended.
/// Running ones come first in the order they started, then the rest newest first. A task with
/// none has no card. Background shells stay with the Background tasks card
/// (`BackgroundTasksProjection`).
struct SessionRailAgents: Equatable {
    struct Agent: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A provider subagent in the shared transcript, read in the subtask panel.
            case harnessSubtask(HarnessActivity)
            /// A Codex child thread, read in the side panel from the thread itself.
            case codexThread(String)
            /// A `run_agent` subagent: by its ID once the call named it, else by its prompt.
            case yardletAgent(agentID: UUID?, prompt: String)
            /// A child task; opening it goes to the task, as the Codex app opens a created chat.
            case childTask(UUID)
        }

        enum Status: Equatable {
            /// A `run_agent` subagent or a child task that waits for room to start.
            case pending
            case running
            /// It waits on the person (a `run_agent` request, a child task's approval or question).
            case waiting
            case completed
            case failed
            case stopped
            /// Nothing says how it is now: a child task between turns, or a Codex child thread its
            /// task's thread last reported running before its own turn ended.
            case idle

            var isActive: Bool { self == .running || self == .waiting }
            /// Not ended: working, waiting on the person, or waiting for room.
            var isUnderWay: Bool { isActive || self == .pending }
        }

        let id: String
        var kind: Kind
        var title: String
        /// The harness and model, named in full where the agent runs on another harness than its task
        /// ("Codex · gpt-5.5"); nil where the row names the task's harness with `model`.
        var harnessLabel: String?
        var model: String?
        var status: Status
        var startedAt: Date?
        /// 1 for a subagent's own agent listed under it.
        var depth = 0
        /// The provider or Yardlet can stop it from the row.
        var canStop = false
        /// The requests it waits on the person for, answered from the row as from the conversation.
        var requests: [ConversationRequest] = []
        /// A Codex child task's questions, answered from the row as under its turn.
        var questions: [CodexAsyncQuestion] = []
        /// What it waits on the person for while it waits: an answer only to questions, or an approval.
        var waitingFor: TaskPendingRequest = .approval

        /// Whether the row opens a conversation beside the task (all but a child task, which is a task).
        var opensPanel: Bool {
            switch kind {
            case let .harnessSubtask(activity): activity.subtask?.hasConversation == true
            case .codexThread: true
            case let .yardletAgent(agentID, _): agentID != nil
            case .childTask: false
            }
        }
    }

    /// A `run_agent` subagent as the app holds it while it runs (`AgentRun`), read once per draw.
    struct Run: Equatable {
        var id: UUID
        var harness: HarnessKind
        var model: String?
        var prompt: String
        var state: AgentRun.State
        var startedAt: Date
        /// The task itself called it, rather than one of its subagents.
        var isTasksOwn = true
        var requests: [ConversationRequest] = []

        @MainActor
        init(_ run: AgentRun) {
            id = run.id
            harness = run.harness
            model = run.model
            prompt = run.prompt
            state = run.state
            startedAt = run.startedAt
            isTasksOwn = run.callerID == run.hostTaskID
            // Its conversation is read for requests only while it waits on the person.
            requests = run.state == .waitingForApproval ? run.pendingRequests : []
        }

        init(id: UUID, harness: HarnessKind, model: String? = nil, prompt: String, state: AgentRun.State,
             startedAt: Date, isTasksOwn: Bool = true, requests: [ConversationRequest] = []) {
            self.id = id
            self.harness = harness
            self.model = model
            self.prompt = prompt
            self.state = state
            self.startedAt = startedAt
            self.isTasksOwn = isTasksOwn
            self.requests = requests
        }
    }

    /// A child task `create_task` made for the task.
    struct Child: Equatable {
        var id: UUID
        var title: String
        var harness: HarnessKind
        var status: Agent.Status
        var createdAt: Date
        /// What it waits on the person for (`Wait`), answered from its row as in its own conversation.
        var requests: [ConversationRequest] = []
        var questions: [CodexAsyncQuestion] = []
        var waitingFor: TaskPendingRequest = .approval

        init(id: UUID, title: String, harness: HarnessKind, status: Agent.Status, createdAt: Date) {
            self.id = id
            self.title = title
            self.harness = harness
            self.status = status
            self.createdAt = createdAt
        }

        /// A task's state as its row reads it: working, waiting on the person, or how its last turn ended.
        init(_ session: SessionRecord, waitsForPerson: Bool = false) {
            let status: Agent.Status = switch session.status {
            case .running: waitsForPerson ? .waiting : .running
            case .waitingForApproval: .waiting
            case .failed: .failed
            case .completed, .ready:
                session.completionState == .failed ? .failed : session.completionState == .completed ? .completed : .idle
            }
            self.init(id: session.id, title: session.title, harness: session.harness, status: status,
                      createdAt: session.createdAt)
        }

        /// A task's state with what it waits on the person for. A wait the task's status does not
        /// show (a question a Codex turn ended on) still makes the row wait. One that waits for room
        /// to start is pending.
        init(_ session: SessionRecord, wait: Wait?, isQueued: Bool = false) {
            self.init(session, waitsForPerson: wait != nil)
            if isQueued { status = .pending }
            guard let wait else { return }
            status = .waiting
            requests = wait.requests
            questions = wait.questions
            waitingFor = wait.kind
        }
    }

    /// What a child task waits on the person for, as its own conversation draws it at the end of its
    /// latest turn: its requests (the harness's and its session tools'), and the questions a Codex
    /// turn asked that no reply answered. Either may be empty where the conversation is not read yet
    /// while the task's state says it waits.
    struct Wait: Equatable {
        var requests: [ConversationRequest] = []
        var questions: [CodexAsyncQuestion] = []
        /// An answer to questions only, or an approval (`TaskAttentionDetail`'s kind where neither
        /// says).
        var kind: TaskPendingRequest = .approval

        init(requests: [ConversationRequest] = [], questions: [CodexAsyncQuestion] = [],
             attention: TaskPendingRequest? = nil) {
            self.requests = requests
            self.questions = questions
            kind = if requests.isEmpty, questions.isEmpty {
                attention ?? .approval
            } else {
                requests.allSatisfy(\.asksForAnswer) ? .input : .approval
            }
        }
    }

    let agents: [Agent]

    var activeCount: Int { agents.filter(\.status.isActive).count }

    /// - Parameters:
    ///   - harness: the task's harness, against which a `run_agent` subagent or a child task on
    ///     another harness is named in full.
    ///   - codexState: a Codex task's thread.
    ///   - runs: the `run_agent` subagents the app holds for the task.
    ///   - children: the child tasks `create_task` made for it.
    /// - Returns: nil when the task has no agents.
    static func make(harness: HarnessKind, entries: [TranscriptEntry], codexState: CodexTaskState?,
                     runs: [Run] = [], children: [Child] = []) -> SessionRailAgents? {
        var agents = subtasks(in: entries, harness: harness)
        agents += codexThreads(in: codexState)
        agents += yardletAgents(harness: harness, entries: entries, codexState: codexState, runs: runs)
        agents += children.map { child in
            Agent(id: "task:\(child.id.uuidString)", kind: .childTask(child.id), title: child.title,
                  harnessLabel: child.harness == harness ? nil : child.harness.displayName,
                  status: child.status, startedAt: child.createdAt, requests: child.requests,
                  questions: child.questions, waitingFor: child.waitingFor)
        }
        guard !agents.isEmpty else { return nil }
        return SessionRailAgents(agents: ordered(agents))
    }

    /// Running ones first in the order they started, the rest newest first; a nested agent follows
    /// the one it belongs to.
    private static func ordered(_ agents: [Agent]) -> [Agent] {
        let top = agents.filter { $0.depth == 0 }
        let nested = agents.filter { $0.depth > 0 }
        let active = top.filter(\.status.isUnderWay)
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let rest = top.filter { !$0.status.isUnderWay }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        var result: [Agent] = []
        var placed = Set<String>()
        for agent in active + rest {
            result.append(agent)
            placed.insert(agent.id)
            for child in nested where parentID(of: child) == agent.id {
                result.append(child)
                placed.insert(child.id)
            }
        }
        // A nested agent whose parent is not listed keeps its own place, at the top level.
        for var child in nested where !placed.contains(child.id) {
            child.depth = 0
            result.append(child)
        }
        return result
    }

    private static func parentID(of agent: Agent) -> String? {
        guard case let .harnessSubtask(activity) = agent.kind, let parent = activity.subtask?.parentTaskID else {
            return nil
        }
        return "subtask:\(parent)"
    }

    // MARK: - Provider subagents (shared transcript)

    /// Claude Code's subagent calls, which carry their subtask once the CLI names the agent.
    static let claudeAgentTools: Set<String> = ["Agent", "Task"]

    private static func subtasks(in entries: [TranscriptEntry], harness: HarnessKind) -> [Agent] {
        var order: [String] = []
        var latest: [String: (activity: HarnessActivity, state: TranscriptActivityState, startedAt: Date)] = [:]
        for entry in entries {
            guard case let .activity(activity, state) = entry.content else { continue }
            // A Claude Code Agent call before the CLI named its agent is an agent all the same.
            let isAgent = activity.subtask.map(\.isAgent)
                ?? (harness == .claudeCode && claudeAgentTools.contains(activity.kind))
            guard isAgent else { continue }
            if let known = latest[activity.id] {
                latest[activity.id] = (activity, state, known.startedAt)
            } else {
                order.append(activity.id)
                latest[activity.id] = (activity, state, entry.createdAt)
            }
        }
        let taskIDs = Set(order.compactMap { latest[$0]?.activity.subtask?.taskID })
        return order.compactMap { id -> Agent? in
            guard let (activity, state, startedAt) = latest[id] else { return nil }
            let status: Agent.Status = switch state {
            case .running: .running
            case .completed:
                switch activity.outcome {
                case .failed?: .failed
                case .stopped?: .stopped
                case nil: .completed
                }
            case .failed: .failed
            case .stopped: .stopped
            }
            let nested = activity.subtask?.parentTaskID.map(taskIDs.contains) == true
            return Agent(id: activity.subtask?.taskID.map { "subtask:\($0)" } ?? "activity:\(activity.id)",
                         kind: .harnessSubtask(activity), title: activity.title, model: activity.subtask?.model,
                         status: status, startedAt: startedAt, depth: nested ? 1 : 0,
                         canStop: status == .running && activity.subtask?.taskID != nil)
        }
    }

    // MARK: - Codex child threads

    /// Codex's agent states (`CollabAgentStatus`) as a row's.
    static func codexStatus(_ value: String?) -> Agent.Status? {
        switch value {
        case "pendingInit", "running": .running
        case "completed", "shutdown": .completed
        case "interrupted": .stopped
        case "errored", "notFound": .failed
        default: nil
        }
    }

    private static func codexThreads(in state: CodexTaskState?) -> [Agent] {
        guard let turns = state?.thread?.turns else { return [] }
        var order: [String] = []
        var agents: [String: Agent] = [:]
        func add(_ threadID: String, title: String?, model: String?, startedAt: Date?) {
            guard agents[threadID] == nil else { return }
            order.append(threadID)
            let fallback = L10n.format("Subagent %@", String(threadID.prefix(8)))
            agents[threadID] = Agent(id: "codex:\(threadID)", kind: .codexThread(threadID),
                                     title: ConversationSubagent.name(asked: title) ?? fallback, model: model,
                                     status: .running, startedAt: startedAt)
        }
        for turn in turns {
            for item in turn.items {
                let startedAt = item.startedAt ?? turn.startedAt
                switch item.content {
                case let .collaboration(call):
                    if spawnTools.contains(call.tool) {
                        for id in call.receiverThreadIDs { add(id, title: call.prompt, model: call.model, startedAt: startedAt) }
                    }
                    for (id, value) in call.agentStates {
                        if let status = codexStatus(value["status"]?.stringValue) { agents[id]?.status = status }
                    }
                case let .subagentActivity(activity):
                    switch activity.kind {
                    case "started":
                        add(activity.agentThreadID, title: agentName(activity.agentPath), model: nil, startedAt: startedAt)
                        agents[activity.agentThreadID]?.status = .running
                    case "completed": agents[activity.agentThreadID]?.status = .completed
                    case "interrupted": agents[activity.agentThreadID]?.status = .stopped
                    default: break
                    }
                default:
                    break
                }
            }
        }
        // Yardlet hears a child thread only through its task's thread: once that thread's turn has
        // ended, a child it last reported running may have ended too, unreported.
        let parentIsWorking = state?.activeTurnID != nil
        return order.compactMap { id in
            guard var agent = agents[id] else { return nil }
            if agent.status == .running, !parentIsWorking { agent.status = .idle }
            return agent
        }
    }

    /// Codex's call that starts a child thread, in the App Server's spelling and the older one.
    static let spawnTools: Set<String> = ["spawnAgent", "spawn_agent"]

    /// An agent path's last part, as the Codex app names a subagent by it (`/root/explorer` → explorer).
    static func agentName(_ path: String) -> String? {
        path.split(separator: "/").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - run_agent

    private static func yardletAgents(harness: HarnessKind, entries: [TranscriptEntry], codexState: CodexTaskState?,
                                      runs: [Run]) -> [Agent] {
        struct Call {
            var agentID: UUID?
            var prompt: String
            var harness: HarnessKind?
            var model: String?
            var phase: Agent.Status
            var startedAt: Date?
        }
        var calls: [Call] = []
        for entry in entries {
            guard case let .activity(activity, state) = entry.content,
                  let subagent = ConversationAgentRunProjection.subagent(from: activity, phase: .running, isApproved: false),
                  case let .yardletAgent(agentID, prompt)? = subagent.routes.first else { continue }
            let arguments = ConversationAgentRunProjection.arguments(in: activity.input)
            let status: Agent.Status = switch state {
            case .running: .running
            case .completed: .completed
            case .failed: .failed
            case .stopped: .stopped
            }
            let call = Call(agentID: agentID.flatMap(UUID.init(uuidString:)), prompt: prompt,
                            harness: arguments?["harness"]?.stringValue.map(HarnessKind.init(rawValue:)),
                            model: arguments?["model"]?.stringValue, phase: status, startedAt: entry.createdAt)
            // The same call reported again (its result) replaces what it said while it ran.
            if let index = calls.lastIndex(where: { $0.prompt == prompt && ($0.agentID == nil || $0.agentID == call.agentID) }),
               calls[index].phase == .running {
                calls[index].agentID = call.agentID ?? calls[index].agentID
                calls[index].phase = status
            } else {
                calls.append(call)
            }
        }
        for turn in codexState?.thread?.turns ?? [] {
            for item in turn.items {
                guard case let .mcpToolCall(tool) = item.content,
                      let subagent = ConversationAgentRunProjection.subagent(from: tool),
                      case let .yardletAgent(agentID, prompt)? = subagent.routes.first else { continue }
                let status: Agent.Status = switch tool.status {
                case "inProgress": turn.status == .inProgress ? .running : .stopped
                case "failed": .failed
                default: tool.errorMessage == nil ? .completed : .failed
                }
                calls.append(Call(agentID: agentID.flatMap(UUID.init(uuidString:)), prompt: prompt,
                                  harness: tool.arguments["harness"]?.stringValue.map(HarnessKind.init(rawValue:)),
                                  model: tool.arguments["model"]?.stringValue, phase: status,
                                  startedAt: item.startedAt ?? turn.startedAt))
            }
        }

        var unmatched = runs
        var agents: [Agent] = []
        for call in calls {
            let index = call.agentID.flatMap { id in unmatched.firstIndex { $0.id == id } }
                ?? unmatched.firstIndex { $0.prompt == call.prompt }
            let run = index.map { unmatched.remove(at: $0) }
            agents.append(agent(harness: harness, run: run, call: (call.agentID, call.prompt, call.harness, call.model,
                                                                    call.phase, call.startedAt)))
        }
        // Subagents its own subagents ran, which its transcript does not show.
        for run in unmatched {
            agents.append(agent(harness: harness, run: run, call: nil))
        }
        return agents
    }

    private static func agent(
        harness: HarnessKind, run: Run?,
        call: (agentID: UUID?, prompt: String, harness: HarnessKind?, model: String?, phase: Agent.Status, startedAt: Date?)?
    ) -> Agent {
        let agentID = run?.id ?? call?.agentID
        let prompt = run?.prompt ?? call?.prompt ?? ""
        let agentHarness = run?.harness ?? call?.harness
        let model = run?.model ?? call?.model
        let status: Agent.Status = if let run {
            switch run.state {
            case .queued: .pending
            case .starting, .running: .running
            case .waitingForApproval: .waiting
            case .completed: .completed
            case .failed: .failed
            case .stopped, .interrupted: .stopped
            }
        } else {
            call?.phase ?? .completed
        }
        let requests = run?.requests ?? []
        return Agent(id: agentID.map { "agent:\($0.uuidString)" } ?? "agent-prompt:\(prompt.hashValue)",
                     kind: .yardletAgent(agentID: agentID, prompt: prompt),
                     title: ConversationSubagent.name(asked: prompt) ?? AgentRun.label(harness: agentHarness, model: model),
                     harnessLabel: AgentRun.harnessLabel(harness: agentHarness ?? harness, model: model),
                     model: model, status: status,
                     startedAt: run?.startedAt ?? call?.startedAt,
                     canStop: run != nil && status.isUnderWay, requests: requests,
                     waitingFor: Wait(requests: requests).kind)
    }
}

extension HarnessSubtaskReference {
    /// The task is an agent rather than a shell or a watcher: Claude Code's local, remote and
    /// teammate agents, and any task with a conversation of its own. Commands, monitors, workflows
    /// and the CLI's own housekeeping are background tasks (`BackgroundTasksProjection`).
    var isAgent: Bool {
        hasConversation || ["remote_agent", "in_process_teammate"].contains(taskType ?? "")
    }
}
