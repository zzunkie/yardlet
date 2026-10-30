import Foundation

#if DEBUG
extension AppModel {
    /// A visual fixture's next frame of a Codex task (`ShowcasePlayback`), put in place as the
    /// task's provider events would leave it.
    func showVisualFixtureCodexState(_ state: CodexTaskState, for sessionID: UUID) {
        guard isVisualFixture else { return }
        codexPresentations[sessionID] = state
    }

    func updateWorkspaceReadingFixture(addTurn: Bool) {
        guard isVisualFixture, CommandLine.arguments.contains("--ui-fixture=workspace"),
              let session = store.selectedSession else { return }
        if session.harness == .codex {
            guard var state = codexPresentationBySessionID[session.id],
                  let turn = state.thread?.turns.indices.last,
                  let item = state.thread?.turns[turn].items.indices.last else { return }
            if addTurn {
                state.thread?.turns.append(CodexReadingFixtureView.turn(turn + 2))
            } else if case var .agentMessage(message) = state.thread?.turns[turn].items[item].content {
                message.text += String(repeating: "\n\nA latest-response update. Keep reading earlier content.", count: 10)
                state.thread?.turns[turn].items[item].content = .agentMessage(message)
            }
            codexPresentations[session.id] = state
        } else {
            guard var entries = transcriptBySessionID[session.id], let last = entries.indices.last else { return }
            if addTurn {
                entries.append(TranscriptEntry(content: .user(text: "A new request")))
                entries.append(TranscriptEntry(content: .assistant(text: "A new answer", isStreaming: false)))
            } else if case let .assistant(text, _) = entries[last].content {
                entries[last].content = .assistant(text: text + String(repeating: "\n\nA latest-response update.", count: 12), isStreaming: true)
            }
            transcripts[session.id] = entries
        }
    }
}
#endif
