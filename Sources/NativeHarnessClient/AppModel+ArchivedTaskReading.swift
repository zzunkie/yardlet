import Foundation

/// Reading an archived task's conversation without unarchiving it (docs/NATIVE_SESSION_STORAGE.md,
/// "Archive and unarchive"). The reads are the ones opening a detached task makes, with the task's
/// provider session ID, account and storage scope, and the readers they use: the newest part of
/// Claude Code's transcript and then earlier parts, Codex's `thread/read` and its turn pages,
/// Antigravity CLI's log, or the session another ACP agent replays when it loads. What they read goes
/// to the window's `ArchivedTaskReading` and nowhere else: no reading cache, task state or index row
/// is written, the provider is not asked to unarchive, resume or start anything, and the task stays
/// archived.
extension AppModel {
    func readArchivedConversation(_ reading: ArchivedTaskReading) async {
        defer { reading.finishReading() }
        guard reading.outcome == .reading, !isVisualFixture, let providerID = reading.session.providerSessionID
        else { return }
        var session = reading.session
        // As restoring the task would: a runtime its desktop app moved is read where it lives now.
        if let runtime = runtimeReplacement(for: session) { session.runtimeExecutableURL = runtime }
        switch session.harness {
        case .claudeCode:
            let reader = claudeSessionReader(for: session)
            guard let read = try? await Task.detached(priority: .utility, operation: {
                try reader.refreshConversation(sessionID: providerID, window: nil, shown: [], keeping: nil)
            }).value else { return }
            reading.claudeWindow = read.window
            reading.show(read.entries)
        case .codex:
            guard let reader = await detachedCodexThreadReader(for: session),
                  var state = try? await reader.readThreadPresentation(
                      threadID: providerID, newestTurns: CodexThreadPaging.newestTurns),
                  state.thread?.id == providerID else { return }
            // No runtime holds the thread: a turn it left open stopped with it.
            CodexTaskReducer().endRuntime(in: &state)
            reading.show(state)
        case .antigravityCLI:
            let store = antigravityConversationStore
            guard let read = try? await Task.detached(priority: .utility, operation: {
                try store.readTranscript(conversationID: providerID)
            }).value else { return }
            reading.show(read.entries)
        default:
            guard ACPSessionHistory.reads(session.harness) else { return }
            let history = acpSessionHistory
            let executable = await registry.startedExecutable(for: session.harness, requested: session.runtimeExecutableURL)
            guard let entries = try? await Task.detached(priority: .utility, operation: {
                try await history.conversation(of: session.harness, executableURL: executable,
                    connection: session.connection, providerSessionID: providerID, workspaceURL: session.workspaceURL)
            }).value else { return }
            reading.show(entries)
        }
    }

    /// The turns before the ones read, as the person scrolls up to them: a Claude transcript read
    /// further back (`ClaudeSubagentTranscriptReader.readEarlierTurns`) or the Codex thread's page before
    /// the turns loaded, put before what is shown.
    func readEarlierArchivedHistory(_ reading: ArchivedTaskReading) async {
        guard reading.outcome == .shown, reading.hasEarlierHistory, !reading.isReadingEarlier,
              let providerID = reading.session.providerSessionID else { return }
        reading.isReadingEarlier = true
        defer { reading.isReadingEarlier = false }
        var session = reading.session
        if let runtime = runtimeReplacement(for: session) { session.runtimeExecutableURL = runtime }
        if var state = reading.codexState, let cursor = state.thread?.turnsNextCursor {
            guard let reader = await detachedCodexThreadReader(for: session),
                  let page = try? await reader.readThreadTurns(threadID: providerID, cursor: cursor,
                                                               limit: CodexThreadPaging.earlierTurns),
                  reading.codexState?.thread?.turnsNextCursor == cursor else { return }
            CodexTaskReducer().mergeTurnPage(page, prepending: true, into: &state)
            CodexTaskReducer().endRuntime(in: &state)
            reading.show(state)
        } else if let window = reading.claudeWindow, window.hasEarlierRecords {
            let reader = claudeSessionReader(for: session)
            guard let read = try? await Task.detached(priority: .utility, operation: {
                try reader.readEarlierTurns(window)
            }).value, reading.claudeWindow == window else { return }
            reading.show(read.applied(to: reading.transcript.entries))
            reading.claudeWindow = read.window
        }
    }
}
