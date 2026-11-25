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
    @Environment(\.yardletInterfaceScale) private var interfaceScale
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
        let usesDescriptionAsHeadline = request.descriptionHeadline != nil
        return VStack(alignment: .leading, spacing: ConversationRequestSurface.blockSpacing) {
            if let headline = request.descriptionHeadline {
                Text(headline)
                    .font(.parity(.control, weight: .semibold, scale: interfaceScale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !usesDescriptionAsHeadline, let detail = request.detail,
               request.preview?.repeats(detail) != true {
                Text(detail)
                    .font(.parity(.control, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = request.preview {
                PermissionRequestPreviewView(preview: preview, showsDescription: !usesDescriptionAsHeadline)
            } else if let command = request.command {
                CodexBoundedOutput(text: command, folds: false, onRequestPanel: true)
            }
            if showsProviderContext, let context = request.codexContext {
                providerContext(context)
            }

            switch request.form {
            case let .choices(questions):
                questionForm(ConversationRequestForm.choices(questions).questionSteps, responses: responses)
            case let .planReview(plan):
                planBody(plan, onPanel: true)
                if answersForm(responses) {
                    TextField(L10n.string("Tell Claude what to change"), text: $input.reason, axis: .vertical)
                        .lineLimit(1...4)
                        .wrapsBetweenWords()
                        .conversationRequestField()
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
                        .font(.parity(.caption, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    responseButtons(responses)
                }
            }
        }
        .modifier(ConversationRequestSurface(header: AnyView(header)))
    }

    /// An answered request as both apps leave one in the conversation: no panel of its own. A question form
    /// reads as its questions and answers, and a form as the values it sent, under how it ended
    /// (`ConversationAnsweredBlock`); a plan as the plan under how it ended; anything else as one muted line
    /// saying how it ended, with the provider's words when it gave any.
    @ViewBuilder
    private var answered: some View {
        switch request.form {
        case .choices, .freeText:
            ConversationAnsweredBlock { outcomeLine } content: {
                questionForm(request.form?.questionSteps ?? [], responses: [])
            }
        case let .planReview(plan):
            VStack(alignment: .leading, spacing: ParitySpace.s8) {
                outcomeLine
                planBody(plan, onPanel: false)
            }
        case let .mcpForm(form):
            // The form as it was sent, read-only, as an answered question reads as its answers.
            ConversationAnsweredBlock { outcomeLine } content: {
                CodexMCPElicitationFormView(form: form, input: $input.fields, isAnswerable: false)
            }
        case nil:
            outcomeLine
        }
    }

    /// How the request ended and what it was about, in the secondary colour, with the provider's message under it.
    private var outcomeLine: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            ConversationOutcomeLabel(symbol: outcomeSymbol, state: stateTitle, title: request.title,
                                     detail: request.outcomeDetail)
            stateNote
        }
        .help(request.method ?? "")
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

    /// The panel's header band, as the Claude app heads its question card: the accent symbol for what the request
    /// waits for and the request's title, or the tool's name when the provider described the call (its description
    /// then heads the body). A question form's band also carries the question's label and its place among several
    /// (`ConversationQuestionBand`).
    @ViewBuilder
    private var header: some View {
        if let steps = request.form?.questionSteps, !steps.isEmpty {
            ConversationQuestionBand(title: request.title, steps: steps, index: $questionIndex)
                .help(request.method ?? "")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ConversationRequestBandTitle(symbol: waitingSymbol, title: request.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(request.method ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// What the waiting request asks for: a plan's review, a form, or an approval (a question's band is
    /// `ConversationQuestionBand`'s).
    private var waitingSymbol: String {
        switch request.form {
        case .choices, .freeText: "questionmark.bubble"
        case .planReview: "list.bullet.clipboard"
        case .mcpForm: "square.and.pencil"
        case nil: "hand.raised"
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
                .font(.parity(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .rejected(message) where !message.isEmpty:
            Text(message)
                .font(.parity(.caption, scale: interfaceScale))
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
                .font(.parity(.control, scale: interfaceScale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(fields) { field in
            VStack(alignment: .leading, spacing: ParitySpace.s4) {
                if let title = field.titleKey {
                    Text(L10n.string(title))
                        .font(.parity(.caption, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                }
                CodexBoundedOutput(text: field.text, folds: false, onRequestPanel: true)
            }
        }
        if context.isEmpty, request.command == nil, let method = request.method {
            Text(method)
                .font(.system(size: ParityType.caption.size * interfaceScale, design: .monospaced)).fontDesign(nil)
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

    /// The plan exactly as the provider wrote it, in its own markdown: on a waiting request's panel in a well
    /// of the elevated surface, which stands off the panel's shade, and in the conversation on the subtle fill.
    private func planBody(_ plan: String, onPanel: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.row)
        return TranscriptMarkdownText(text: plan)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ParitySpace.s16)
            .padding(.vertical, ParitySpace.s12)
            .background(onPanel ? ParityTheme.elevated : ParityTheme.subtleFill, in: shape)
            .overlay { if onPanel { shape.strokeBorder(ParityTheme.separator) } }
            .accessibilityLabel(L10n.string("Proposed plan"))
    }

    // MARK: - Answers

    /// The answers right-aligned in one row, the prominent one last; stacked when the row does not
    /// fit the card.
    private func responseButtons(_ responses: [ConversationRequestResponse]) -> some View {
        let controls = ConversationRequestResponses.controls(responses)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: ParitySpace.s8) {
                Spacer(minLength: 0)
                ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                    answerControl(control)
                }
            }
            VStack(alignment: .trailing, spacing: ParitySpace.s8) {
                ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                    answerControl(control)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func answerControl(_ control: ConversationRequestResponses.AnswerControl) -> some View {
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
        let label = HStack(spacing: ParitySpace.s8) {
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

/// The panel a waiting request sits on (`ConversationRequestPanel`), under its header band when it has one, as the
/// Claude app heads its question card. No control on it draws a focus ring: the focused question shows its picked
/// option by the selection fill, a field its caret, and an answer button the key that gives it
/// (docs/DESIGN_SYSTEM.md, "Semantic colors").
struct ConversationRequestSurface: ViewModifier {
    var header: AnyView? = nil

    /// The panel's inset, inside its header band and its body.
    static let inset = ParitySpace.s16
    /// The gap between the body's blocks: what it asks, what it would do, the form and the answers.
    static let blockSpacing = ParitySpace.s12
    /// The band's content height: the question pager's buttons, so a band with them and one without are as tall.
    static let bandContentHeight: CGFloat = 20
    /// An option row's inset beside its words, for a question's options and a form's choices alike.
    static let optionInset = ParitySpace.s12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.surface)
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                header
                    .frame(minHeight: Self.bandContentHeight)
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, ParitySpace.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ParityTheme.subtleFill)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(ParityTheme.separator).frame(height: 1)
                    }
            }
            content
                .padding(Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { ConversationRequestPanel() }
        .clipShape(shape)
        .focusEffectDisabled()
    }
}

/// A waiting request's panel, as the Codex app draws its request panel: a neutral surface a shade off the
/// conversation's and the composer's, with a hairline border, never tinted by the request's state or kind. The
/// elevated surface alone is the light canvas's white, where a waiting request read as more of the conversation.
struct ConversationRequestPanel: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.surface)
        shape.fill(ParityTheme.elevated)
            .overlay { shape.fill(ParityTheme.requestPanelFill) }
            .overlay { shape.strokeBorder(ParityTheme.strongSeparator) }
    }
}

/// A key inside a button, as both apps draw one: the key's glyph in a small outlined box ("Esc" for escape), a
/// caption beside the button's label.
struct ConversationKeyCap: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let shortcut: KeyboardShortcut

    var body: some View {
        Text(verbatim: shortcut.key == .escape && shortcut.modifiers.isEmpty ? "Esc" : shortcut.displayText)
            .font(.parity(.caption, weight: .medium, scale: interfaceScale))
            .fixedSize()
            .padding(.horizontal, ParitySpace.s4)
            .frame(minWidth: 16 * interfaceScale, minHeight: 16 * interfaceScale)
            // A key's corner, rounder than a control's would look on a box this small.
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(.foreground.opacity(0.3)) }
            .opacity(0.85)
            .accessibilityHidden(true)
    }
}

/// How a request ended, on one secondary line: the outcome's symbol and words, what the request was, and the
/// provider's words about it, cut to the line.
struct ConversationOutcomeLabel: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let symbol: String
    let state: String
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(state)
            Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.parity(.control, scale: interfaceScale))
        .foregroundStyle(.secondary)
    }
}

/// An answered question or form as it stays in the conversation: one quiet block on the subtle fill, with how
/// it ended on its first line and what was answered under it, so the questions and their answers read as one
/// record rather than as more of the conversation.
struct ConversationAnsweredBlock<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s12) {
            header()
            content()
        }
        .padding(.horizontal, ParitySpace.s16)
        .padding(.vertical, ParitySpace.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityRadius.surface))
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// A text field on a waiting request's panel, drawn as the composer draws its own: plain text on the
    /// input surface with a hairline edge and the row radius, no bezel and no focus ring; the caret shows
    /// where typing goes (docs/DESIGN_SYSTEM.md, "Semantic colors").
    func conversationRequestField() -> some View {
        modifier(ConversationRequestFieldStyle())
    }
}

private struct ConversationRequestFieldStyle: ViewModifier {
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ParityRadius.row)
        content
            .textFieldStyle(.plain)
            .font(.parity(.control, scale: interfaceScale))
            .padding(.horizontal, ParitySpace.s12)
            .padding(.vertical, ParitySpace.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.input, in: shape)
            .overlay { shape.strokeBorder(ParityTheme.strongSeparator) }
            .focusEffectDisabled()
    }
}
