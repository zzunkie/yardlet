#if DEBUG
import SwiftUI

/// Large typed history with deterministic prepend and stream mutations. No runtime is created.
struct CodexReadingFixtureView: View {
    @State private var state = Self.makeState()
    @State private var selection: CodexHistorySearchSelection?
    @State private var pages = 0
    @State private var updates = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HarnessIdentityLabel(harness: .codex)
                Text("History fixture · No provider").font(.caption)
                Spacer()
                Button("Find 140") {
                    selection = CodexHistorySearchSelection(query: "Response 140", snippet: nil,
                        turnID: "turn-140", itemID: "answer-140")
                }
                Button("Grow latest") {
                    guard let turn = state.thread?.turns.indices.last,
                          let item = state.thread?.turns[turn].items.indices.last,
                          case var .agentMessage(message) = state.thread?.turns[turn].items[item].content
                    else { return }
                    updates += 1
                    message.text += "\n\nLive update \(updates): keep reading the earlier response."
                    state.thread?.turns[turn].items[item].content = .agentMessage(message)
                }
                Button("Add turn") {
                    let next = (Int(state.thread?.turns.last?.id.dropFirst(5) ?? "180") ?? 180) + 1
                    state.thread?.turns.append(Self.turn(next))
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            // A Codex task's conversation, as a task draws it.
            TaskConversationView(
                harness: .codex, workspaceURL: URL(filePath: "/tmp/codex-reading-fixture"), entries: [],
                codexTaskState: state, codexHistorySelection: selection,
                actions: ConversationActions(
                    loadMoreCodexTurns: prepend, retryTurn: { _ in }, restoreDraft: { _ in }
                )
            )
            Divider()
            Text("Loaded turns: \(state.thread?.turns.count ?? 0) · Pages: \(pages) · Updates: \(updates)")
                .font(.caption).padding(8)
        }
        .padding(.top, 28)
    }

    private func prepend() {
        guard let first = state.thread?.turns.first,
              let number = Int(first.id.dropFirst(5)), number > 1 else { return }
        let start = max(1, number - 50)
        state.thread?.turns.insert(contentsOf: (start..<number).map(Self.turn), at: 0)
        state.thread?.turnsNextCursor = start > 1 ? "older-\(start)" : nil
        pages += 1
    }

    private static func makeState() -> CodexTaskState {
        var thread = CodexTaskDecoder().thread(from: .object(["id": .string("reading-fixture")]))!
        thread.turns = (101...180).map(turn)
        thread.turnsNextCursor = "older-101"
        return CodexTaskState(thread: thread)
    }

    nonisolated static func turn(_ number: Int) -> CodexTurnState {
        let text = "## Response \(number)\n\n" + (1...8).map {
            "Paragraph \($0) of response \(number). Read this text without losing your place. 한글 👩🏽‍💻"
        }.joined(separator: "\n\n")
        return CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-\(number)"), "status": .string("completed"),
            "durationMs": .integer(2_000), "itemsView": .string("full"),
            "items": .array([
                .object(["id": .string("user-\(number)"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"),
                                                    "text": .string("Request \(number)")])])]),
                .object(["id": .string("change-\(number)"), "type": .string("fileChange"),
                         "status": .string("completed"), "changes": .array([
                            .object(["path": .string("Sources/File\(number).swift"), "kind": .string("update")])])]),
                .object(["id": .string("answer-\(number)"), "type": .string("agentMessage"),
                         "phase": .string("final_answer"), "text": .string(text)])
            ])
        ]), fallbackID: "turn-\(number)")!
    }
}
#endif
