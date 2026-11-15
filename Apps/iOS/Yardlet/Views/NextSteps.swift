import SwiftUI
import YardletRemote

/// What the latest turn asks of the person once Codex is done with it, above the composer as the Codex app keeps its
/// panel there (docs/REMOTE_PROTOCOL.md §15.31): the questions it asked, answered as Codex's reply, or else the plan it
/// offers to implement. A waiting request comes first, as on the Mac, and a Mac that does not take `nextStep` shows
/// neither. Typing in the composer instead still answers with a message of the person's own.
struct NextStepDock: View {
    let session: HostSession
    let taskID: String
    let conversation: ConversationState
    /// Turns whose step the person took here, kept out of view until the conversation moves past them.
    @State private var taken: Set<String> = []

    var body: some View {
        if session.nextSteps, session.isConnected, conversation.pendingRequests.isEmpty,
           let header = conversation.turns.last?.header, !taken.contains(header.turnId) {
            let turnID = header.turnId
            if let questions = header.nextQuestions, !questions.isEmpty {
                CodexQuestionsDock(questions: questions) { reply in
                    // The turn named when the person chose, so an answer never reaches a newer turn.
                    let action: RemoteNextStep = header.status == "running" ? .answerWhileWorking : .answer
                    guard let reply else {
                        taken.insert(turnID)
                        return true
                    }
                    let sent = await session.nextStep(taskID, turnID: turnID, action: action, text: reply)
                    if sent { taken.insert(turnID) }
                    return sent
                }
                .id(turnID)
            } else if header.planToImplement != nil, session.task(taskID)?.running != true, conversation.queued.isEmpty {
                ImplementPlanDock {
                    let sent = await session.nextStep(taskID, turnID: turnID, action: .implementPlan, text: nil)
                    if sent { taken.insert(turnID) }
                }
                .id(turnID)
            }
        }
    }
}

/// Codex's questions, one at a time as the Mac's panel asks them: one of its options or the person's own words, or
/// skipped. Sending gives `send` Codex's reply, or nil when every question was skipped.
private struct CodexQuestionsDock: View {
    let questions: [RemoteNextQuestion]
    let send: (String?) async -> Bool
    @State private var index = 0
    @State private var picked: [String: String] = [:]
    @State private var written: [String: String] = [:]
    @State private var skipped: Set<String> = []
    @State private var isSending = false

    /// `text` is at most 4,000 characters (§15.3).
    private static let maxText = 4_000

    private var question: RemoteNextQuestion { questions[min(index, questions.count - 1)] }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(questions.count > 1 ? String(localized: "Question \(index + 1) of \(questions.count)")
                                      : String(localized: "Question"),
                  systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                // As tall as the options, scrolling past a few lines so the conversation stays in view.
                ScrollView { options }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(question.options.isEmpty ? "Answer" : "Other answer", text: Binding(
                get: { written[question.itemID] ?? "" },
                set: { text in
                    let clipped = String(text.prefix(Self.maxText))
                    written[question.itemID] = clipped
                    if !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { picked[question.itemID] = nil }
                    skipped.remove(question.itemID)
                }), axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                if index > 0 {
                    Button("Previous") { index -= 1 }
                        .buttonStyle(.borderless)
                }
                Button("Skip") { skip() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    if isLast { submit() } else { index += 1 }
                } label: {
                    Text(isLast ? "Send" : "Next").frame(minWidth: 80)
                }
                .buttonStyle(CardButtonStyle(role: "primary"))
                .disabled(!isAnswered(question) || (isLast && !isComplete))
            }
        }
        .disabled(isSending)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(question.options, id: \.self) { option in
                let isPicked = picked[question.itemID] == option
                Button {
                    picked[question.itemID] = isPicked ? nil : option
                    if !isPicked { written[question.itemID] = nil }
                    skipped.remove(question.itemID)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                        Text(option).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isAnswered(_ question: RemoteNextQuestion) -> Bool {
        picked[question.itemID] != nil
            || !(written[question.itemID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every question answered or skipped.
    private var isComplete: Bool {
        questions.allSatisfy { skipped.contains($0.itemID) || isAnswered($0) }
    }

    /// Leaves the question out and moves on; on the last one, sends what was answered.
    private func skip() {
        skipped.insert(question.itemID)
        picked[question.itemID] = nil
        written[question.itemID] = nil
        if isLast { submit() } else { index += 1 }
    }

    private func submit() {
        guard isComplete else { return }
        let answers = questions.compactMap { question -> CodexQuestionReply.Answer? in
            guard !skipped.contains(question.itemID) else { return nil }
            let words = picked[question.itemID]
                ?? (written[question.itemID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : CodexQuestionReply.Answer(questionItemID: question.itemID, question: question.title,
                                                                   answer: words)
        }
        isSending = true
        Task {
            _ = await send(answers.isEmpty ? nil : CodexQuestionReply.message(answers))
            isSending = false
        }
    }
}

/// Codex's plan, once its turn ended on one: "Implement this plan?", as the Mac asks it.
private struct ImplementPlanDock: View {
    let implement: () async -> Void
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Implement this plan?").font(.body.weight(.medium))
            Button {
                isSending = true
                Task {
                    await implement()
                    isSending = false
                }
            } label: {
                Text("Yes, Implement This Plan").frame(maxWidth: .infinity)
            }
            .buttonStyle(CardButtonStyle(role: "primary"))
            .disabled(isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The Codex app's reply to a turn's questions, which the Mac takes as `nextStep`'s `text` (§15.31): one message, its
/// whole text the answers as a JSON array of `{questionItemId, question, answer}` between
/// `<send_user_message_question_reply>` and its closing tag, only the questions answered.
enum CodexQuestionReply {
    struct Answer {
        let questionItemID: String
        let question: String
        let answer: String
    }

    static func message(_ answers: [Answer]) -> String {
        let entries = answers.map { answer in
            "{\"questionItemId\":\(json(answer.questionItemID)),\"question\":\(json(answer.question)),"
                + "\"answer\":\(json(answer.answer))}"
        }
        return "<send_user_message_question_reply>\n[\(entries.joined(separator: ","))]\n</send_user_message_question_reply>"
    }

    /// `text` as a JSON string, as JavaScript's `JSON.stringify` writes it.
    private static func json(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }
}
