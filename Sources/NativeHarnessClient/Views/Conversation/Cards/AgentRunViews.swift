import SwiftUI

/// What a `run_agent` card asks of the app, bound to the task whose conversation shows it.
struct AgentRunActions {
    /// The subagent a card is: by the agent ID its answer named, else by its prompt.
    var run: @MainActor (_ agentID: String?, _ prompt: String) -> AgentRun?
    var stop: @MainActor (AgentRun) -> Void
    /// Opens its conversation beside the task, as the session rail's Agents card does; nil shows it
    /// in a sheet (a conversation without its task's panels).
    var open: (@MainActor (AgentRun) -> Void)? = nil
}

private struct AgentRunActionsKey: EnvironmentKey {
    static let defaultValue: AgentRunActions? = nil
}

extension EnvironmentValues {
    /// The task's subagent actions. Nil where the conversation is read alone; a card then shows what
    /// the call recorded.
    var agentRunActions: AgentRunActions? {
        get { self[AgentRunActionsKey.self] }
        set { self[AgentRunActionsKey.self] = newValue }
    }
}

/// The controls a `run_agent` card adds: the subagent's live line while it works, its
/// conversation, and Stop.
struct AgentRunControls: View {
    let agentID: String?
    let prompt: String

    @Environment(\.agentRunActions) private var actions
    @State private var showsConversation = false

    var body: some View {
        if let actions, let run = actions.run(agentID, prompt) {
            HStack(spacing: 12) {
                // Its request waits at the end of this turn, where every request waits.
                if run.state == .waitingForApproval {
                    Label(L10n.string("Needs approval"), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if run.state == .queued {
                    // It waits for room to start (`SessionToolPolicy.admitted`).
                    Text(L10n.string("Pending"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let line = run.state.isFinished ? run.answerLine : run.progressLine {
                    // While it works, its latest step; once it ended, the first line of its answer.
                    Text(TranscriptInlineContent(line: line).attributed)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let open = actions.open { open(run) } else { showsConversation = true }
                } label: {
                    HarnessSubtaskActionLabel(title: "Open conversation", systemName: "text.bubble")
                }
                if !run.state.isFinished {
                    Button { actions.stop(run) } label: {
                        HarnessSubtaskActionLabel(title: "Stop task", systemName: "stop.circle")
                    }
                }
            }
            .sheet(isPresented: $showsConversation) {
                AgentRunConversationSheet(run: run)
            }
        }
    }
}

/// A subagent's conversation, read only, in the one conversation renderer.
struct AgentRunConversationSheet: View {
    let run: AgentRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.label)
                        .font(.headline)
                    Text(run.workspaceURL.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L10n.string("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let state = run.codexState, state.thread?.turns.isEmpty == false {
                ConversationTimeline(source: .codex(state, workspaceURL: run.workspaceURL, historySelection: nil),
                                     placement: .panel)
            } else {
                ConversationTimeline(
                    source: .transcript(entries: run.entries, harness: run.harness,
                                        status: run.state.isFinished ? .ready : .running,
                                        latestTurnIsComplete: run.state == .completed),
                    placement: .panel)
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 640)
        .background(ParityTheme.canvas)
        // Its images open over this sheet, not over the window behind it.
        .imageViewerHost()
    }
}
