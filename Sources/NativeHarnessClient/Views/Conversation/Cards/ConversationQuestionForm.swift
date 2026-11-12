import SwiftUI

/// A request's questions as the Claude app's Code question card and the Codex app's input panel ask
/// them (`ConversationQuestionStepper`): one question at a time, its place among several ("2 of 3")
/// with the previous and next question beside it, the provider's options, and the person's own
/// answer under them where the provider takes one. Skip and Next lead to the last question, whose
/// row ends with the caller's answer buttons, which send every answer at once.
///
/// Keys, once the person has clicked into the form, are the Codex app's: 1–9 picks an option (the
/// number after the options goes to the person's own answer), ← → move between questions, and
/// Return goes on (Next, or the answer on the last question). Return in the answer field does the
/// same.
struct ConversationQuestionStepsView<Finish: View>: View {
    let steps: [ConversationQuestionStep]
    @Binding var input: ConversationRequestFormInput
    @Binding var index: Int
    /// The form takes input; otherwise it reads as the questions and their options.
    let isAnswerable: Bool
    /// Sends the answers: Return, or Skip on the last question, once every question is settled.
    /// Called when the person goes on, so the caller decides then whether it can send them.
    let submit: () -> Void
    /// The last question's answer buttons.
    @ViewBuilder let finish: () -> Finish

    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case form
        case customAnswer(String)
    }

    private var stepper: ConversationQuestionStepper { ConversationQuestionStepper(steps: steps, index: index) }

    var body: some View {
        let stepper = stepper
        if let step = stepper.current {
            // One container for every question, so the keys keep reaching it as the questions change.
            VStack(alignment: .leading, spacing: 8) {
                if stepper.isStepped || step.header?.isEmpty == false {
                    stepHeader(step, stepper: stepper)
                }
                if let text = step.text, !text.isEmpty {
                    Text(text)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if step.allowsMultipleSelections {
                    Text(L10n.string("Choose one or more"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if step.isFreeTextOnly {
                    answerField(step)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(step.options, id: \.label) { option in
                            optionRow(step, option: option)
                        }
                        if step.allowsCustomAnswer {
                            customAnswerRow(step)
                        }
                    }
                }
                if isAnswerable {
                    stepButtons(step, stepper: stepper)
                }
            }
            .focusable(isAnswerable)
            .focused($focus, equals: .form)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press, step: step) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityTitle(step, stepper: stepper))
        }
    }

    // MARK: - Header

    /// The provider's label for the question on the left; its place among several, between the
    /// previous and next question, on the right.
    private func stepHeader(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let header = step.header, !header.isEmpty {
                Text(header)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if stepper.isStepped {
                HStack(spacing: 2) {
                    pagerButton(systemImage: "chevron.left", label: L10n.string("Previous question"),
                                isEnabled: stepper.hasPrevious) { move(by: -1) }
                    Text(L10n.format("Question %lld of %lld", Int64(stepper.index + 1), Int64(steps.count)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    pagerButton(systemImage: "chevron.right", label: L10n.string("Next question"),
                                isEnabled: !stepper.isLast) { move(by: 1) }
                }
            }
        }
    }

    private func pagerButton(systemImage: String, label: String, isEnabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!isEnabled)
        .parityPointer()
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Options

    private func optionRow(_ step: ConversationQuestionStep, option: PermissionQuestionOption) -> some View {
        let isSelected = input.answer(for: step)?.options.contains(option.label) == true
        return Button {
            input.toggle(option.label, for: step)
            focus = .form
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.indicator(multiple: step.allowsMultipleSelections, isOn: isSelected))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? ParityTheme.selectedFill : ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .disabled(!isAnswerable)
        .accessibilityLabel(option.label)
        .accessibilityValue(option.description ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The person's own answer, as the last option: Claude Code's "Other", the Codex app's field
    /// under the options. Typing chooses it over the options of a question that takes one answer.
    private func customAnswerRow(_ step: ConversationQuestionStep) -> some View {
        let isChosen = input.isCustomAnswerChosen(for: step)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                input.chooseCustomAnswer(for: step)
                focus = .customAnswer(step.id)
            } label: {
                Image(systemName: Self.indicator(multiple: step.allowsMultipleSelections, isOn: isChosen))
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .parityPointer()
            .disabled(!isAnswerable)
            .accessibilityHidden(true)
            textField(step, placeholder: L10n.string("Type your own answer"), isBordered: false)
                .font(.callout)
                .accessibilityLabel(L10n.string("Other"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isChosen ? ParityTheme.selectedFill : ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    /// A question with no options, answered only in the person's words.
    private func answerField(_ step: ConversationQuestionStep) -> some View {
        textField(step, placeholder: L10n.string("Answer"), isBordered: true)
            .accessibilityLabel(step.text ?? L10n.string("Answer"))
    }

    /// The person's words for `step`, up to four lines, or a hidden field for a secret. Return goes on.
    @ViewBuilder
    private func textField(_ step: ConversationQuestionStep, placeholder: String, isBordered: Bool) -> some View {
        let text = Binding(
            get: { input.text[step.id] ?? "" },
            set: { input.setCustomAnswer($0, for: step) }
        )
        let field = Group {
            if step.isSecret {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .disabled(!isAnswerable)
        .focused($focus, equals: .customAnswer(step.id))
        .onSubmit { goOn(from: step) }
        if isBordered {
            field.textFieldStyle(.roundedBorder)
        } else {
            field.textFieldStyle(.plain)
        }
    }

    static func indicator(multiple: Bool, isOn: Bool) -> String {
        if multiple { return isOn ? "checkmark.square.fill" : "square" }
        return isOn ? "largecircle.fill.circle" : "circle"
    }

    // MARK: - Skip, Next and the answer

    /// Skip where the provider allows it, then Next, or on the last question the caller's answer
    /// buttons. Next waits for an answer or a skip, and says so.
    private func stepButtons(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if step.canSkip {
                Button(L10n.string("Skip")) { skip(step) }
                    .buttonStyle(.bordered)
                    .parityPointer()
                    .accessibilityLabel(L10n.string("Skip"))
            }
            if stepper.isLast {
                finish()
            } else {
                Button(L10n.string("Next")) { goOn(from: step) }
                    .parityProminentButton()
                    .parityPointer()
                    .disabled(!input.isSettled(step))
                    .help(stepper.blocker(input) ?? "")
                    .accessibilityLabel(L10n.string("Next"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func move(by offset: Int) {
        var stepper = stepper
        stepper.move(to: stepper.index + offset)
        index = stepper.index
        focus = .form
    }

    /// Next, or on the last question the answer once every question is settled; nothing while the
    /// question waits.
    private func goOn(from step: ConversationQuestionStep) {
        guard input.isSettled(step) else { return }
        let stepper = stepper
        if !stepper.isLast {
            move(by: 1)
        } else if let waiting = stepper.firstUnsettled(input) {
            index = waiting
        } else {
            submit()
        }
    }

    /// Both apps' Skip: the question is left out and the card goes on; on the last question the
    /// answers go, or the card goes back to a question still waiting.
    private func skip(_ step: ConversationQuestionStep) {
        input.skip(step)
        goOn(from: step)
    }

    private func handle(_ press: KeyPress, step: ConversationQuestionStep) -> KeyPress.Result {
        guard isAnswerable, focus == .form else { return .ignored }
        switch press.key {
        case .leftArrow:
            move(by: -1)
            return .handled
        case .rightArrow:
            move(by: 1)
            return .handled
        case .return:
            goOn(from: step)
            return .handled
        default:
            break
        }
        guard press.modifiers.isEmpty, let number = Int(press.characters), (1...9).contains(number) else {
            return .ignored
        }
        if step.options.indices.contains(number - 1) {
            input.toggle(step.options[number - 1].label, for: step)
            return .handled
        }
        if number == step.options.count + 1, step.allowsCustomAnswer, !step.isFreeTextOnly {
            input.chooseCustomAnswer(for: step)
            focus = .customAnswer(step.id)
            return .handled
        }
        return .ignored
    }

    private func accessibilityTitle(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper) -> String {
        let question = [step.header, step.text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        guard stepper.isStepped else { return question }
        return L10n.format("Question %lld of %lld", Int64(stepper.index + 1), Int64(steps.count)) + ", " + question
    }
}

/// An answered form as both apps show one: each question, and under it what it was answered with
/// (the options picked, joined, then the person's own words), or that it was not answered. Nothing
/// on it can be pressed. With no answers known (`answers` nil) it lists the questions alone.
struct ConversationQuestionSummary: View {
    let steps: [ConversationQuestionStep]
    let answers: [String: ConversationQuestionAnswer]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                // A selection across the conversation takes the question and its answer as they read.
                VStack(alignment: .leading, spacing: 3) {
                    let question = step.text ?? step.header ?? L10n.string("Question")
                    Text(question)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .conversationSelectionText(question)
                    if let answers {
                        if let answer = answers[step.id], !answer.values.isEmpty {
                            let text = Self.text(answer, isSecret: step.isSecret)
                            Text(text)
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .conversationSelectionText(text)
                        } else {
                            Text(L10n.string("Not answered"))
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .conversationSelectionText(L10n.string("Not answered"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Read as the question and its answer: selectable text does not combine into one.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(step.text ?? step.header ?? L10n.string("Question"))
                .accessibilityValue(answers.map { answers in
                    answers[step.id].flatMap { $0.values.isEmpty ? nil : Self.text($0, isSecret: step.isSecret) }
                        ?? L10n.string("Not answered")
                } ?? "")
            }
        }
    }

    /// What a question was answered with as the card reads it: the values joined with ", ", a
    /// secret hidden.
    static func text(_ answer: ConversationQuestionAnswer, isSecret: Bool) -> String {
        answer.text(isSecret: isSecret)
    }
}
