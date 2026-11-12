import SwiftUI

/// The one card for a request a provider asks the person to answer, for every harness (plan B4,
/// M12a): an approval with the provider's own options, a choice or free-text question, a plan to
/// review, and what the request would do (a change preview, the command, Codex's own context).
///
/// It draws `ConversationRequest` alone. Its answers are the request's `responses`, laid out the
/// same way for every harness (the denial first, the prominent answer last), and each goes back by
/// its route through `ConversationActions.respond(_:_:)`. A host that cannot carry a form's answer
/// or a provider option gets the plain answers instead (`offeredResponses`). A request Yardlet does
/// not answer offers nothing and says why. Once answered, the card keeps what was asked and reads as
/// the answer it got: a question form as each question and its answer, as the provider recorded it
/// (`ConversationRequest.recordedAnswers`), or as the card sent it until the record arrives.
struct ConversationRequestCard: View {
    let request: ConversationRequest
    let actions: ConversationActions

    @State private var input: ConversationRequestFormInput
    /// Which keys allow a request from the composer (`ComposerApprovalKey`).
    @AppStorage(SendShortcut.preferenceKey) private var sendShortcut = SendShortcut.return
    @State private var questionIndex: Int
    /// What the card sent for a question form, which it reads as until the provider's record arrives.
    @State private var sent: ConversationRequestFormInput?

    /// - Parameters:
    ///   - input: what the form starts with (renders only). A waiting question that takes one answer
    ///     starts on its first option, as both apps start it.
    ///   - questionIndex: the question a form of several starts on (renders only).
    init(request: ConversationRequest, actions: ConversationActions, input: ConversationRequestFormInput = .init(),
         questionIndex: Int = 0) {
        self.request = request
        self.actions = actions
        var start = input
        if request.state == .pending, let form = request.form { start.preselect(form.questionSteps) }
        _input = State(initialValue: start)
        _questionIndex = State(initialValue: questionIndex)
        _sent = State(initialValue: nil)
    }

    var body: some View {
        let responses = offeredResponses
        VStack(alignment: .leading, spacing: ParityTheme.proseBlockSpacing) {
            header

            if let detail = request.detail,
               !(request.preview.map { PermissionRequestPreviewView.repeats(detail, in: $0) } ?? false) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let preview = request.preview {
                PermissionRequestPreviewView(preview: preview)
            } else if let command = request.command {
                labeledBox(L10n.string("Command")) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if showsProviderContext, let context = request.codexContext {
                providerContext(context)
            }

            switch request.form {
            case let .choices(questions):
                questionForm(ConversationRequestForm.choices(questions).questionSteps, responses: responses)
            case let .planReview(plan):
                planBody(plan)
                if answersForm(responses) {
                    TextField(L10n.string("Tell Claude what to change"), text: $input.reason)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.string("Tell Claude what to change"))
                }
            case let .freeText(questions):
                questionForm(ConversationRequestForm.freeText(questions).questionSteps, responses: responses)
            case let .mcpForm(form):
                CodexMCPElicitationFormView(form: form, input: $input.fields, isAnswerable: answersForm(responses))
            case nil:
                EmptyView()
            }

            if request.state == .pending, !drawsAnswersInForm(responses) {
                if responses.isEmpty {
                    Text(request.unanswerableReason ?? L10n.string("This Codex request needs a structured response."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    responseButtons(responses)
                }
            } else {
                stateNote
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(tint.opacity(0.24))
        }
    }

    /// What the card offers while the request waits, by what the host can carry back.
    private var offeredResponses: [ConversationRequestResponse] {
        guard request.state == .pending else { return [] }
        return request.offeredResponses(canChooseOption: actions.chooseOption != nil, canAnswer: actions.answer != nil)
    }

    /// The form takes input only while one of the offered answers sends it.
    private func answersForm(_ responses: [ConversationRequestResponse]) -> Bool {
        responses.contains { $0.route == .structured }
    }

    /// A waiting question form draws the answers in its last question's row.
    private func drawsAnswersInForm(_ responses: [ConversationRequestResponse]) -> Bool {
        guard answersForm(responses) else { return false }
        switch request.form {
        case .choices, .freeText: return true
        case .planReview, .mcpForm, nil: return false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(stateTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(request.title)
                    .font(.callout.weight(.semibold))
            }
            Spacer()
        }
        .help(request.method ?? "")
    }

    private enum FormKind {
        case question
        case plan
        case none
    }

    private var formKind: FormKind {
        switch request.form {
        case .choices, .freeText, .mcpForm: .question
        case .planReview: .plan
        case nil: .none
        }
    }

    /// An answerable card is not an approval, so its resolved state reads as the answer it was.
    private var stateTitle: String { request.stateTitle }

    private var icon: String {
        switch (formKind, request.state) {
        case (.question, .pending): "questionmark.bubble.fill"
        case (.question, .allowed), (.question, .answered): "checkmark.bubble.fill"
        case (.plan, .pending): "list.bullet.clipboard.fill"
        case (_, .pending): "lock.shield.fill"
        case (_, .allowed): "checkmark.shield.fill"
        case (_, .answered): "checkmark.circle.fill"
        case (_, .denied): "xmark.shield.fill"
        case (_, .expired): "clock.badge.exclamationmark"
        case (_, .rejected): "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch request.state {
        case .pending: .orange
        case .allowed, .answered: .green
        case .denied, .rejected: .red
        case .expired: .secondary
        }
    }

    /// Why an answered card ended the way it did, in the provider's words.
    @ViewBuilder
    private var stateNote: some View {
        switch request.state {
        case let .expired(message?) where !message.isEmpty:
            Label(message, systemImage: "clock.badge.xmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .rejected(message) where !message.isEmpty:
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    // MARK: - What the request would do

    /// The provider's own decision context (Codex): its reasons and fields. A free-text question
    /// shows its questions instead.
    private var showsProviderContext: Bool {
        if case .freeText = request.form { return false }
        return true
    }

    @ViewBuilder
    private func providerContext(_ context: CodexRequestContextProjection) -> some View {
        let fields = context.fields.filter { $0.id != "command" || request.command == nil }
        ForEach(context.messages, id: \.self) { message in
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                if let title = field.titleKey {
                    Text(L10n.string(title))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                CodexBoundedOutput(text: field.text, folds: false)
            }
        }
        if context.isEmpty, request.command == nil, let method = request.method {
            Text(method)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Forms

    /// The provider's own questions, one at a time while the request waits, and each with its answer
    /// once it is answered. Every question, header, option label and description is the text the
    /// request carried.
    @ViewBuilder
    private func questionForm(_ steps: [ConversationQuestionStep], responses: [ConversationRequestResponse]) -> some View {
        if request.state == .pending {
            let isAnswerable = answersForm(responses)
            ConversationQuestionStepsView(
                steps: steps, input: $input, index: $questionIndex, isAnswerable: isAnswerable,
                submit: submitForm
            ) {
                // In the row the form ends with, after its Skip.
                ForEach(Array(responses.enumerated()), id: \.offset) { _, response in
                    responseButton(response)
                }
            }
        } else {
            ConversationQuestionSummary(
                steps: steps,
                answers: request.recordedAnswers ?? sent.map { $0.answers(for: steps) }
            )
        }
    }

    /// Sends the form by its prominent answer, if one of the answers offered now sends the form.
    private func submitForm() {
        let responses = offeredResponses
        guard let response = responses.first(where: { $0.route == .structured && $0.role == .primary })
            ?? responses.first(where: { $0.route == .structured }) else { return }
        send(response)
    }

    /// The plan exactly as the provider wrote it, in its own markdown.
    private func planBody(_ plan: String) -> some View {
        TranscriptMarkdownText(text: plan)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.string("Proposed plan"))
    }

    // MARK: - Answers

    /// The answers right-aligned in one row, the prominent one last; stacked when the row does not
    /// fit the card.
    private func responseButtons(_ responses: [ConversationRequestResponse]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(responses.enumerated()), id: \.offset) { _, response in
                    responseButton(response)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(responses.enumerated()), id: \.offset) { _, response in
                    responseButton(response)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Sends `response` with what the form holds; a question form keeps what it sent.
    private func send(_ response: ConversationRequestResponse) {
        guard let route = request.route(for: response, input: input) else { return }
        if response.route == .structured, request.form?.questionSteps.isEmpty == false { sent = input }
        actions.respond(request.id, route)
    }

    @ViewBuilder
    private func responseButton(_ response: ConversationRequestResponse) -> some View {
        let route = request.route(for: response, input: input)
        let role: ButtonRole? = response.role == .destructive ? .destructive : nil
        let send = { self.send(response) }
        let help = ShortcutHelp.text(response.title, keys(for: response))
        if response.role == .primary {
            Button(response.title, role: role, action: send)
                .parityProminentButton()
                .parityPointer()
                .disabled(route == nil)
                .accessibilityLabel(response.title)
                .help(help)
        } else {
            Button(response.title, role: role, action: send)
                .buttonStyle(.bordered)
                .parityPointer()
                .disabled(route == nil)
                .accessibilityLabel(response.title)
                .help(help)
        }
    }

    /// The composer's keys that give this answer (`ComposerApprovalKey`): "Allow once" and the
    /// one-time denial of a request a notification could answer.
    private func keys(for response: ConversationRequestResponse) -> [KeyboardShortcut] {
        guard actions.answersFromComposer, let pending = NotificationApprovalProjection.pendingRequest(for: request)
        else { return [] }
        if response.route == pending.allowOnce { return ComposerApprovalKey.allow(sendShortcut) }
        if response.route == pending.deny { return ComposerApprovalKey.deny }
        return []
    }
}
