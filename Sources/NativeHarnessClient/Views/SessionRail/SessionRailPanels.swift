import SwiftUI

/// A `run_agent` subagent's conversation in the side panel, as the Codex app opens a subagent as a
/// side-panel tab: live while the app holds it, else as it was kept when it ended. Its requests are
/// answered here as at the end of the calling task's turn; nothing else in it acts on the task.
struct AgentRunPane: View {
    let title: String
    let run: AgentRun?
    let kept: KeptAgentRun?
    let workspaceURL: URL
    /// The task's conversation actions, narrowed to answering the subagent's requests.
    var actions = ConversationActions()
    var onStop: ((AgentRun) -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: title, systemName: "person.2", workspaceURL: workspaceURL,
                              onClose: onClose) {
                if let run, !run.state.isFinished, let onStop {
                    ParityIconButton(systemName: "stop.circle", help: L10n.string("Stop agent")) { onStop(run) }
                }
            }
            if let run {
                if let state = run.codexState, state.thread?.turns.isEmpty == false {
                    ConversationTimeline(source: .codex(state, workspaceURL: run.workspaceURL, historySelection: nil),
                                         placement: .panel, actions: actions)
                } else if !run.entries.isEmpty {
                    ConversationTimeline(
                        source: .transcript(entries: run.entries, harness: run.harness,
                                            status: run.state.isFinished ? .ready : .running,
                                            latestTurnIsComplete: run.state == .completed),
                        placement: .panel, actions: actions)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let kept, !kept.entries.isEmpty {
                ConversationTimeline(
                    source: .transcript(entries: kept.entries, harness: HarnessKind(rawValue: kept.harness),
                                        status: .ready, latestTurnIsComplete: kept.state == "completed"),
                    placement: .panel)
            } else {
                WorkSurfaceEmptyState(title: L10n.string("Child conversation unavailable"),
                                      message: L10n.string("This subagent's conversation was not kept."),
                                      systemName: "text.bubble")
            }
        }
        .environment(\.transcriptWorkspaceURL, workspaceURL)
    }
}

/// A Codex child thread in the side panel, read from the thread (`thread/read`): nothing loads or
/// resumes it. It reads again when its task's thread moves and on Refresh.
struct CodexChildThreadPane: View {
    let threadID: String
    let title: String
    let workspaceURL: URL
    /// Changes when the task's thread does, which may say the child moved on.
    let refreshKey: String
    let load: @MainActor () async throws -> CodexTaskState
    let onClose: () -> Void
    @State private var state: CodexTaskState?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: title, systemName: "person.2", workspaceURL: workspaceURL, onClose: onClose) {
                ParityIconButton(systemName: "arrow.clockwise", help: L10n.string("Refresh")) {
                    Task { await refresh() }
                }
                .disabled(loading)
            }
            if let state, state.thread?.turns.isEmpty == false {
                ConversationTimeline(source: .codex(state, workspaceURL: workspaceURL, historySelection: nil),
                                     placement: .panel)
            } else if let error {
                WorkSurfaceEmptyState(title: L10n.string("Child conversation unavailable"), message: error,
                                      systemName: "text.bubble")
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkSurfaceEmptyState(title: L10n.string("No child conversation yet"), systemName: "text.bubble")
            }
        }
        .environment(\.transcriptWorkspaceURL, workspaceURL)
        .task(id: "\(threadID)|\(refreshKey)") { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let read = try await load()
            guard !Task.isCancelled else { return }
            if read != state { state = read }
            error = nil
        } catch {
            guard !Task.isCancelled, state == nil else { return }
            self.error = error.localizedDescription
        }
    }
}

/// A background task's output in the side panel: the Claude app's Background tasks pane ("View live
/// output") and the Codex app's background terminal tab ("No output yet"). It follows the output
/// while the task runs and keeps to its newest part.
struct BackgroundOutputPane: View {
    let title: String
    let workspaceURL: URL
    /// The task still runs: its output is read again every second.
    let isRunning: Bool
    /// Reads the output now; nil where none can be read.
    let read: @MainActor () async -> (text: String, isTruncated: Bool)?
    let onClose: () -> Void
    @State private var output: (text: String, isTruncated: Bool)?
    @State private var hasRead = false

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: title, systemName: "terminal", workspaceURL: workspaceURL, onClose: onClose) {
                if let output, !output.text.isEmpty {
                    ParityIconButton(systemName: "doc.on.doc", help: L10n.string("Copy output")) {
                        TranscriptClipboard.copy(output.text)
                    }
                }
            }
            if let output, !output.text.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if output.isTruncated {
                                Text(L10n.string("(Earlier output not shown)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(output.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(12)
                    }
                    .onChange(of: output.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else if hasRead {
                WorkSurfaceEmptyState(title: L10n.string(output == nil ? "Output unavailable" : "No output yet"),
                                      systemName: "terminal")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ParityTheme.canvas)
        .task(id: "\(title)|\(isRunning)") { await follow() }
    }

    private func follow() async {
        while !Task.isCancelled {
            let next = await read()
            guard !Task.isCancelled else { return }
            if next?.text != output?.text || next?.isTruncated != output?.isTruncated { output = next }
            hasRead = true
            guard isRunning else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
