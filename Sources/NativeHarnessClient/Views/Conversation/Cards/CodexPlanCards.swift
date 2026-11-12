import SwiftUI

struct CodexPlanCard: View {
    let plan: CodexPlanState

    init(plan: CodexPlanState) {
        self.plan = plan
    }

    /// A conversation's step plan, drawn as the Codex plan card.
    init(plan: ConversationPlan) {
        self.plan = CodexPlanState(explanation: plan.explanation, steps: plan.steps.map { step in
            let status: CodexPlanStepStatus = switch step.status {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            case let .unknown(value): .unknown(value)
            }
            return CodexPlanStep(id: step.id, text: step.text, status: status)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.string("Plan"), systemImage: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let explanation = plan.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.steps) { step in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: planSymbol(step.status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(planTint(step.status))
                        .frame(width: 14)
                    Text(step.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Plan"))
        .accessibilityValue(
            plan.steps.map { step in
                switch step.status {
                case .completed: L10n.string("Completed")
                case .inProgress: L10n.string("In progress")
                case .pending, .unknown: L10n.string("Pending")
                }
            }
            .joined(separator: ", ")
        )
    }

    private func planSymbol(_ status: CodexPlanStepStatus) -> String {
        switch status {
        case .pending, .unknown: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func planTint(_ status: CodexPlanStepStatus) -> Color {
        switch status {
        case .pending, .unknown: Color.secondary.opacity(0.55)
        case .inProgress: ParityTheme.accent
        case .completed: .green
        }
    }
}

/// The plan a Plan mode turn proposes, shown in the answer area as the Codex app's Plan card.
struct CodexProposedPlanCard: View {
    let text: String
    let isWriting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(
                    isWriting ? L10n.string("Writing plan") : L10n.string("Plan"),
                    systemImage: "list.bullet.clipboard"
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                if isWriting {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                if !isWriting {
                    TranscriptCopyButton(title: L10n.string("Copy plan")) { text }
                }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TranscriptMarkdownText(text: text, characterLimit: 5_000)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isWriting ? L10n.string("Writing plan") : L10n.string("Plan"))
    }
}

/// The questions a Codex turn ended on (`request_user_input_async`), asked as the Codex app's input
/// panel asks them and as the request card asks a provider's questions (`ConversationQuestionStepsView`):
/// one at a time, each with its options and the person's own answer, skipped or answered, then sent
/// at once as the Codex app's reply message (`CodexAsyncQuestionReply`). Typing in the composer
/// instead answers with a message of the person's own. Once answered, the card reads as each
/// question's answer, from the reply the thread holds (`answers`), or as it sent them until the
/// reply arrives.
struct CodexQuestionOptions: View {
    let questions: [CodexAsyncQuestion]
    /// The answers the reply recorded, by each question's `itemID`; nil while the questions wait.
    var answers: [String: ConversationQuestionAnswer]? = nil
    /// Sends the reply as the next message; nil while the task cannot take one.
    var onAnswer: ((String) -> Void)? = nil

    @State private var input: ConversationRequestFormInput
    @State private var index = 0
    @State private var sent: ConversationRequestFormInput?

    init(questions: [CodexAsyncQuestion], answers: [String: ConversationQuestionAnswer]? = nil,
         onAnswer: ((String) -> Void)? = nil, input: ConversationRequestFormInput = .init()) {
        self.questions = questions
        self.answers = answers
        self.onAnswer = onAnswer
        var start = input
        start.preselect(questions.map(ConversationQuestionStep.init))
        _input = State(initialValue: start)
    }

    private var steps: [ConversationQuestionStep] { questions.map(ConversationQuestionStep.init) }

    var body: some View {
        let steps = steps
        Group {
            if let answered = answers ?? sent.map({ $0.answers(for: steps) }) {
                ConversationQuestionSummary(steps: steps, answers: answered)
            } else {
                ConversationQuestionStepsView(
                    steps: steps, input: $input, index: $index, isAnswerable: onAnswer != nil,
                    submit: send
                ) {
                    Button(L10n.string("Send")) { send() }
                        .parityProminentButton()
                        .parityPointer()
                        .disabled(!canSend)
                        .help(ConversationQuestionStepper(steps: steps, index: index).blocker(input) ?? "")
                        .accessibilityLabel(L10n.string("Send"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(ParityTheme.separator) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Every question is answered or skipped.
    private var canSend: Bool {
        onAnswer != nil && steps.allSatisfy(input.isSettled)
    }

    private func send() {
        guard canSend, let onAnswer else { return }
        sent = input
        onAnswer(Self.reply(questions, input: input))
    }

    /// The Codex app's reply for what the form holds: each question answered, with its option or the
    /// person's own words, in the questions' order; a skipped one left out.
    static func reply(_ questions: [CodexAsyncQuestion], input: ConversationRequestFormInput) -> String {
        CodexAsyncQuestionReply.message(questions.compactMap { question in
            guard let value = input.answer(for: ConversationQuestionStep(question))?.values.first else { return nil }
            return CodexAsyncQuestionReply.Answer(questionItemID: question.itemID, question: question.title, answer: value)
        })
    }
}

struct CodexImplementPlanPrompt: View {
    let onImplement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Implement this plan?"))
                .font(.system(size: 12.5, weight: .medium))
            Button(L10n.string("Yes, implement this plan"), action: onImplement)
                .parityProminentButton()
                .parityPointer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
