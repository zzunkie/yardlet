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
    /// Whether the composer's keys answer this request: only the oldest of the ones waiting, so the
    /// keys show on that one card.
    var answeredByComposerKeys = true

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
    init(request: ConversationRequest, actions: ConversationActions, answeredByComposerKeys: Bool = true,
         input: ConversationRequestFormInput = .init(), questionIndex: Int = 0) {
        self.request = request
        self.actions = actions
        self.answeredByComposerKeys = answeredByComposerKeys
        var start = input
        if request.state == .pending, let form = request.form { start.preselect(form.questionSteps) }
        _input = State(initialValue: start)
        _questionIndex = State(initialValue: questionIndex)
        _sent = State(initialValue: nil)
    }

    var body: some View {
        if request.state == .pending {
            pendingCard
        } else {
            answered
        }
    }

    /// A request waiting for the person, on the neutral panel both apps draw one on: what it asks, what it would
    /// do, and its answers.
    private var pendingCard: some View {
        let responses = offeredResponses
        let usesDescriptionAsHeadline = descriptionHeadline != nil
        return VStack(alignment: .leading, spacing: 12) {
            header

            if !usesDescriptionAsHeadline, let detail = request.detail,
               request.preview?.repeats(detail) != true {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = request.preview {
                PermissionRequestPreviewView(preview: preview, showsDescription: !usesDescriptionAsHeadline)
            } else if let command = request.command {
                CodexBoundedOutput(text: command, folds: false)
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

            if !drawsAnswersInForm(responses) {
                if responses.isEmpty {
                    Text(request.unanswerableReason ?? L10n.string("This Codex request needs a structured response."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    responseButtons(responses)
                }
            }
        }
        .modifier(ConversationRequestSurface())
    }

    /// An answered request as both apps leave one in the conversation: no panel of its own. A question form
    /// reads as its questions and answers, a plan as the plan under how it ended, anything else as one muted
    /// line saying how it ended, with the provider's words when it gave any.
    @ViewBuilder
    private var answered: some View {
        switch request.form {
        case .choices, .freeText:
            VStack(alignment: .leading, spacing: 8) {
                outcomeLine
                questionForm(request.form?.questionSteps ?? [], responses: [])
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(ParityTheme.strongSeparator).frame(width: 2)
                    }
            }
        case let .planReview(plan):
            VStack(alignment: .leading, spacing: 8) {
                outcomeLine
                planBody(plan)
            }
        case let .mcpForm(form):
            // The form as it was sent, read-only, as an answered question reads as its answers.
            VStack(alignment: .leading, spacing: 8) {
                outcomeLine
                CodexMCPElicitationFormView(form: form, input: $input.fields, isAnswerable: false)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(ParityTheme.strongSeparator).frame(width: 2)
                    }
            }
        case nil:
            outcomeLine
        }
    }

    /// How the request ended and what it was about, in the secondary colour, with the provider's message under it.
    private var outcomeLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: outcomeSymbol)
                    .accessibilityHidden(true)
                Text(stateTitle)
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(request.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = outcomeDetail {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            stateNote
        }
        .help(request.method ?? "")
    }

    /// What the request was about, on its outcome line: the provider's own words (a Codex request's reason or
    /// question) when it gave any, otherwise the request's detail.
    private var outcomeDetail: String? {
        if let message = request.codexContext?.messages.first { return message }
        if let detail = request.detail, !detail.isEmpty { return detail }
        return nil
    }

    /// The headline is the provider's description of a call (Claude Code's "Run the unit tests") when it gave
    /// one, under the tool's name; otherwise the request's own title.
    private var descriptionHeadline: String? {
        guard formKind == .none, case let .command(_, description)? = request.preview,
              let description, !description.isEmpty else { return nil }
        return description
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

    /// The request's title as both apps head their cards: a 13 pt semibold line, under the tool's name in the
    /// secondary colour when the provider described the call.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let headline = descriptionHeadline {
                Text(request.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(request.method ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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

    private var outcomeSymbol: String {
        switch request.state {
        case .pending: "hourglass"
        case .allowed, .answered: "checkmark.circle"
        case .denied, .rejected: "xmark.circle"
        case .expired: "clock"
        }
    }

    /// Why an answered card ended the way it did, in the provider's words.
    @ViewBuilder
    private var stateNote: some View {
        switch request.state {
        case let .expired(message?) where !message.isEmpty:
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .rejected(message) where !message.isEmpty:
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                CodexBoundedOutput(text: field.text, folds: false)
            }
        }
        if context.isEmpty, request.command == nil, let method = request.method {
            Text(method)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            .padding(12)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.string("Proposed plan"))
    }

    // MARK: - Answers

    /// The answers right-aligned in one row, the prominent one last; stacked when the row does not
    /// fit the card.
    private func responseButtons(_ responses: [ConversationRequestResponse]) -> some View {
        let controls = Self.controls(responses)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                    answerControl(control)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                    answerControl(control)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// One control of the card's row: an answer's own button, or the wider allows as one split button.
    enum AnswerControl {
        case answer(ConversationRequestResponse)
        case widerAllows([ConversationRequestResponse])
    }

    /// The answers as the row draws them. The wider allows (the secondary answers between the denials and
    /// "Allow") become one split button when Yardlet can name their scope or there are several, as the
    /// Claude app keeps "Always allow" short and its scopes in the button's menu; otherwise each keeps its
    /// own button.
    static func controls(_ responses: [ConversationRequestResponse]) -> [AnswerControl] {
        let wider = responses.filter { $0.role == .secondary }
        guard let first = wider.first, wider.count > 1 || ConversationAllowScope(first) != nil
        else { return responses.map(AnswerControl.answer) }
        var controls: [AnswerControl] = []
        for response in responses {
            if response.role != .secondary {
                controls.append(.answer(response))
            } else if response == first {
                controls.append(.widerAllows(wider))
            }
        }
        return controls
    }

    @ViewBuilder
    private func answerControl(_ control: AnswerControl) -> some View {
        switch control {
        case let .answer(response): responseButton(response)
        case let .widerAllows(wider): widerAllowsButton(wider)
        }
    }

    /// The wider allows as one split button: the narrowest by its short name, which its click gives, and
    /// all of them in the menu, each with its scope on a second line. The tooltip keeps the full words.
    @ViewBuilder
    private func widerAllowsButton(_ wider: [ConversationRequestResponse]) -> some View {
        let first = wider[0]
        let name = ConversationAllowScope(first)?.name ?? first.title
        Menu {
            ForEach(Array(wider.enumerated()), id: \.offset) { _, response in
                let scope = ConversationAllowScope(response)
                Button { send(response) } label: {
                    Text(scope?.name ?? response.title)
                    if let scope { Text(scope.scope) }
                }
                .disabled(request.route(for: response, input: input) == nil)
            }
        } label: {
            Text(name)
        } primaryAction: {
            send(first)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .parityPointer()
        .disabled(wider.allSatisfy { request.route(for: $0, input: input) == nil })
        .accessibilityLabel(name)
        .accessibilityHint(L10n.string("More allow options"))
        .help(first.title)
    }

    /// Sends `response` with what the form holds; a question form keeps what it sent.
    private func send(_ response: ConversationRequestResponse) {
        guard let route = request.route(for: response, input: input) else { return }
        if response.route == .structured, request.form?.questionSteps.isEmpty == false { sent = input }
        actions.respond(request.id, route)
    }

    /// An answer's button, with the key that gives it inside, as both apps show "Esc" and "⏎" in theirs.
    @ViewBuilder
    private func responseButton(_ response: ConversationRequestResponse) -> some View {
        let route = request.route(for: response, input: input)
        let role: ButtonRole? = response.role == .destructive ? .destructive : nil
        let send = { self.send(response) }
        let keys = keys(for: response)
        let help = ShortcutHelp.text(response.title, keys)
        let label = HStack(spacing: 6) {
            Text(response.title)
            if let key = keys.first { ConversationKeyCap(shortcut: key) }
        }
        if response.role == .primary {
            Button(role: role, action: send) { label }
                .parityProminentButton()
                .parityPointer()
                .disabled(route == nil)
                .accessibilityLabel(response.title)
                .help(help)
        } else {
            Button(role: role, action: send) { label }
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
        guard actions.answersFromComposer, answeredByComposerKeys,
              let pending = NotificationApprovalProjection.pendingRequest(for: request) else { return [] }
        if response.route == pending.allowOnce { return ComposerApprovalKey.allow(sendShortcut) }
        if response.route == pending.deny { return ComposerApprovalKey.deny }
        return []
    }
}

/// The panel a waiting request sits on, as both apps draw theirs: a neutral surface with a hairline border, never
/// tinted by the request's state or kind.
struct ConversationRequestSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius)
                    .stroke(ParityTheme.strongSeparator)
            }
    }
}

/// A key inside a button, as both apps draw one: the key's glyph in a small outlined box ("Esc" for escape).
struct ConversationKeyCap: View {
    let shortcut: KeyboardShortcut

    var body: some View {
        Text(verbatim: shortcut.key == .escape && shortcut.modifiers.isEmpty ? "Esc" : shortcut.displayText)
            .font(.system(size: 10.5, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(.foreground.opacity(0.3)) }
            .opacity(0.85)
            .accessibilityHidden(true)
    }
}
