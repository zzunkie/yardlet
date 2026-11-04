import SwiftUI

/// What the Agents card asks of the task's window.
@MainActor
struct SessionRailAgentActions {
    /// Opens an agent's conversation beside the task, or goes to a child task.
    var open: (SessionRailAgents.Agent) -> Void = { _ in }
    /// Whether this window can open the agent conversation.
    var canOpen: (SessionRailAgents.Agent) -> Bool = { _ in true }
    /// Stops a running agent the way its card in the conversation does.
    var stop: ((SessionRailAgents.Agent) -> Void)? = nil
    var isStopping: (SessionRailAgents.Agent) -> Bool = { _ in false }
    /// The conversation's own answers, for the requests a subagent waits on (they route to the
    /// subagent by request, as at the end of the conversation's turn).
    var requests: ConversationActions = ConversationActions()
    /// A child task's own conversation's answers, for what it waits on the person for.
    var childRequests: (UUID) -> ConversationActions = { _ in ConversationActions() }
}

/// The agents working for the task (`SessionRailAgents`): the Codex app's "Subagents" and "Created
/// chats" in one card. A row names the agent, its harness and model, and how it is: working (with
/// how long), waiting on the person, or how it ended, the ended ones quieter. What a subagent or a
/// child task waits on the person for waits under its row and is answered there as in the
/// conversation it belongs to. A row opens the agent's conversation beside the task; a child task's
/// row goes to that task.
struct SessionRailAgentsCard: View {
    let agents: SessionRailAgents
    let actions: SessionRailAgentActions?

    var body: some View {
        SessionRailLimitedList(items: agents.agents, limit: 5) { agent in
            SessionRailAgentRow(agent: agent, actions: actions)
        }
    }
}

struct SessionRailAgentRow: View {
    let agent: SessionRailAgents.Agent
    let actions: SessionRailAgentActions?
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var isStopping: Bool { actions?.isStopping(agent) == true }
    private var opens: Bool {
        guard let actions, actions.canOpen(agent) else { return false }
        if case .childTask = agent.kind { return true }
        return agent.opensPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title
                Spacer(minLength: 6)
                status
                if agent.canStop, agent.status.isUnderWay, let stop = actions?.stop {
                    BackgroundTasksGhostButton(action: { stop(agent) }) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .disabled(isStopping)
                    .help(L10n.string("Stop this task"))
                    .accessibilityLabel(L10n.string("Stop this task"))
                }
            }
            .frame(minHeight: 24)
            let answers = requestActions
            ForEach(agent.requests) { request in
                ConversationRequestCard(request: request, actions: answers)
                    .font(.system(size: 12 * interfaceScale))
            }
            if !agent.questions.isEmpty {
                // The answer goes into the child's running turn, or as its next message once it ended.
                CodexQuestionOptions(questions: agent.questions,
                                     onAnswer: answers.answerQuestionWhileWorking ?? answers.answerQuestion)
                    .font(.system(size: 12 * interfaceScale))
            }
        }
        .padding(.leading, CGFloat(agent.depth) * 16)
        .accessibilityElement(children: .contain)
    }

    /// A child task's requests are its own conversation's; a subagent's are answered by the task's.
    /// A row that waits on nothing asks for neither.
    private var requestActions: ConversationActions {
        guard let actions, !agent.requests.isEmpty || !agent.questions.isEmpty else { return ConversationActions() }
        if case let .childTask(id) = agent.kind { return actions.childRequests(id) }
        return actions.requests
    }

    @ViewBuilder
    private var title: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            // The harness and model beside the name where both fit; the name alone where they do not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    name.fixedSize()
                    harnessModel
                }
                name
            }
        }
        .help(agent.title)
        if opens, let actions {
            Button { actions.open(agent) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityHint(L10n.string(isChildTask ? "Open task" : "Open conversation"))
        } else {
            label
        }
    }

    private var name: some View {
        Text(agent.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(agent.status.isUnderWay || agent.status == .idle ? AnyShapeStyle(.primary)
                                                                            : AnyShapeStyle(.secondary))
    }

    @ViewBuilder
    private var harnessModel: some View {
        if let label = agent.harnessLabel {
            Text(label)
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        } else {
            HarnessModelLabel(model: agent.model)
        }
    }

    private var isChildTask: Bool {
        if case .childTask = agent.kind { return true }
        return false
    }

    private var symbol: String {
        if agent.depth > 0 { return "arrow.turn.down.right" }
        switch agent.kind {
        case .childTask: return "bubble.left.and.text.bubble.right"
        default: return "person.crop.circle"
        }
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch agent.status {
            case .pending:
                Text(L10n.string("Pending"))
            case .running:
                if isStopping {
                    Text(L10n.string("Stopping…"))
                } else if let startedAt = agent.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(BackgroundTasksProjection.elapsedText(since: startedAt, now: context.date))
                            .monospacedDigit()
                    }
                } else {
                    Text(L10n.string("Working"))
                }
            case .waiting:
                Text(L10n.string(agent.waitingFor == .input ? "Needs input" : "Needs approval")).foregroundStyle(.orange)
            case .completed:
                Text(L10n.string("Completed")).foregroundStyle(.tertiary)
            case .failed:
                Text(L10n.string("Failed")).foregroundStyle(.red.opacity(0.8))
            case .stopped:
                Text(L10n.string("Stopped")).foregroundStyle(.tertiary)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 11.5 * interfaceScale))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}
