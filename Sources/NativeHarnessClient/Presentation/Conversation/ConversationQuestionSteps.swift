import Foundation

// A request's questions as the one question card asks them, for every harness, as the Claude app's
// Code question card and the Codex app's input panel do: one question at a time with its place among
// them, the provider's options, the person's own answer under them where the provider takes one, a
// question skipped where the provider allows it, and every answer sent at once after the last.

/// One question of a form as the card steps through it, from any provider's question.
struct ConversationQuestionStep: Identifiable, Equatable, Sendable {
    /// What the form's input and the recorded answers know the question by: its text (Claude Code,
    /// Muse) or the provider's ID for it (Codex).
    let id: String
    let header: String?
    /// The provider's question; nil when it sent none.
    let text: String?
    let options: [PermissionQuestionOption]
    let allowsMultipleSelections: Bool
    /// The person can answer in their own words: besides the options, or instead of options the
    /// question does not have.
    let allowsCustomAnswer: Bool
    /// The provider takes an answer that leaves the question out.
    let canSkip: Bool
    let isSecret: Bool

    /// The question has only a free-text answer.
    var isFreeTextOnly: Bool { options.isEmpty }

    /// The card shows the picked option's preview, as Claude Code and the Claude app do: for a
    /// question that takes one answer and has an option with a preview.
    var showsPreviews: Bool {
        !allowsMultipleSelections && options.contains { $0.preview != nil }
    }

    /// The preview of the option `answer` picked, where the card shows previews.
    func preview(for answer: ConversationQuestionAnswer?) -> String? {
        guard showsPreviews, let picked = answer?.options.first else { return nil }
        return options.first { $0.label == picked }?.preview
    }
}

extension ConversationRequestForm {
    /// The form's questions as the card steps through them; none for a plan review or MCP form.
    var questionSteps: [ConversationQuestionStep] {
        switch self {
        case let .choices(questions):
            questions.map(ConversationQuestionStep.init)
        case let .freeText(questions):
            questions.map(ConversationQuestionStep.init)
        case .planReview, .mcpForm:
            []
        }
    }
}

extension ConversationQuestionStep {
    /// A Claude Code or Muse question, known by its text.
    init(_ question: PermissionQuestion) {
        self.init(
            id: question.question, header: question.header, text: question.question, options: question.options,
            allowsMultipleSelections: question.allowsMultipleSelections,
            allowsCustomAnswer: question.allowsCustomAnswer, canSkip: !question.requiresAnswer, isSecret: false
        )
    }

    /// A Codex question, known by its ID. Codex takes one answer per question, and an answer that
    /// leaves a question out.
    init(_ question: ConversationRequestQuestion) {
        self.init(
            id: question.id, header: question.header, text: question.text, options: question.options,
            allowsMultipleSelections: false,
            allowsCustomAnswer: question.options.isEmpty || question.allowsCustomAnswer, canSkip: true,
            isSecret: question.isSecret
        )
    }

    /// A question a Codex message asks (`request_user_input_async`), known by its `itemID`. The Codex
    /// app answers it with one option or the person's own words, or leaves it out.
    init(_ question: CodexAsyncQuestion) {
        self.init(
            id: question.itemID, header: nil, text: question.title,
            options: question.options.map { PermissionQuestionOption(label: $0) },
            allowsMultipleSelections: false, allowsCustomAnswer: true, canSkip: true, isSecret: false
        )
    }
}

extension ConversationRequestFormInput {
    /// What the form holds as `step`'s answer, nil when it holds none: the options picked in the
    /// provider's order and the person's own words, trimmed. A question that takes one answer is
    /// answered by its option when one is picked, otherwise by the words.
    func answer(for step: ConversationQuestionStep) -> ConversationQuestionAnswer? {
        let picked = step.options.map(\.label).filter { selections[step.id]?.contains($0) == true }
        let words = (text[step.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = step.allowsCustomAnswer && !words.isEmpty && (step.allowsMultipleSelections || picked.isEmpty)
            ? words : nil
        guard !picked.isEmpty || custom != nil else { return nil }
        return ConversationQuestionAnswer(options: step.allowsMultipleSelections ? picked : Array(picked.prefix(1)),
                                          custom: custom)
    }

    /// The person answered `step` or skipped it.
    func isSettled(_ step: ConversationQuestionStep) -> Bool {
        answer(for: step) != nil || (step.canSkip && skipped.contains(step.id))
    }

    /// The person's own words count as `step`'s answer: typed, and no option picked for a question
    /// that takes one answer.
    func isCustomAnswerChosen(for step: ConversationQuestionStep) -> Bool {
        answer(for: step)?.custom != nil
    }

    /// Both apps start a question that takes one answer on its first option, as the Codex tool tells
    /// the model ("the first option is preselected by default").
    mutating func preselect(_ steps: [ConversationQuestionStep]) {
        for step in steps where !step.allowsMultipleSelections && selections[step.id] == nil
            && (text[step.id] ?? "").isEmpty && !skipped.contains(step.id) {
            if let first = step.options.first { selections[step.id] = [first.label] }
        }
    }

    /// Picks or drops `label`. A question that takes one answer keeps the option picked (a radio
    /// button), and the person's words stay typed but no longer answer it.
    mutating func toggle(_ label: String, for step: ConversationQuestionStep) {
        var picked = selections[step.id] ?? []
        if step.allowsMultipleSelections {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
        }
        selections[step.id] = picked
        skipped.remove(step.id)
    }

    /// The person's own words for `step`. Typing answers a question that takes one answer with the
    /// words instead of its option, as the Codex app does.
    mutating func setCustomAnswer(_ words: String, for step: ConversationQuestionStep) {
        text[step.id] = words
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !step.allowsMultipleSelections { selections[step.id] = [] }
        skipped.remove(step.id)
    }

    /// Chooses the person's own words for a question that takes one answer, letting go of its option.
    mutating func chooseCustomAnswer(for step: ConversationQuestionStep) {
        guard !step.allowsMultipleSelections else { return }
        selections[step.id] = []
    }

    /// Leaves `step` out of the answer, as both apps' Skip does.
    mutating func skip(_ step: ConversationQuestionStep) {
        guard step.canSkip else { return }
        selections[step.id] = []
        text[step.id] = ""
        skipped.insert(step.id)
    }

    /// The answers for every step the form holds one for, by step ID.
    func answers(for steps: [ConversationQuestionStep]) -> [String: ConversationQuestionAnswer] {
        var answers: [String: ConversationQuestionAnswer] = [:]
        for step in steps { if let answer = answer(for: step) { answers[step.id] = answer } }
        return answers
    }
}

/// Where the card is among a form's questions, and where Next, Skip and the last answer lead.
struct ConversationQuestionStepper: Equatable, Sendable {
    let steps: [ConversationQuestionStep]
    private(set) var index: Int = 0

    init(steps: [ConversationQuestionStep], index: Int = 0) {
        self.steps = steps
        self.index = steps.isEmpty ? 0 : min(max(index, 0), steps.count - 1)
    }

    var current: ConversationQuestionStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isLast: Bool { index >= steps.count - 1 }
    var hasPrevious: Bool { index > 0 }
    /// Several questions: the card shows its place among them and moves between them.
    var isStepped: Bool { steps.count > 1 }

    mutating func move(to index: Int) {
        guard !steps.isEmpty else { return }
        self.index = min(max(index, 0), steps.count - 1)
    }

    /// The first question the person neither answered nor skipped, if any.
    func firstUnsettled(_ input: ConversationRequestFormInput) -> Int? {
        steps.firstIndex { !input.isSettled($0) }
    }

    /// Why the card cannot go on from this question, as the Claude app says it: the question waits
    /// for an option or a skip, or (on the last) an earlier question still waits.
    func blocker(_ input: ConversationRequestFormInput) -> String? {
        guard let current else { return nil }
        if !input.isSettled(current) {
            return current.canSkip ? L10n.string("Choose an option or skip this question")
                : L10n.string("Choose an option")
        }
        if isLast, let waiting = firstUnsettled(input) {
            return L10n.format("Question %lld is unanswered", Int64(waiting + 1))
        }
        return nil
    }
}
