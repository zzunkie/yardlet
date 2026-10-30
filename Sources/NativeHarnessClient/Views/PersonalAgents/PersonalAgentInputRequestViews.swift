import SwiftUI

/// What the conversation's request cards and option questions ask of their window.
struct PersonalAgentRequestActions {
    var respond: (PersonalAgentInputRequest, DotsInputResult) -> Void = { _, _ in }
    var check: (PersonalAgentInputRequest) -> Void = { _ in }
    var choose: (_ messageID: String, _ index: Int) -> Void = { _, _ in }
    var retryOption: () -> Void = {}
}

/// An input request in a dot's message, where the message asks it: an approval to allow or deny, a
/// form to fill in, or a request Yardlet shows but cannot answer, with a way to the dot's own page.
/// It is drawn as the coding task's request card is, and answers only through its own buttons: a
/// reply in the conversation never answers it.
struct PersonalAgentRequestCard: View {
    @Bindable var item: PersonalAgentInputRequest
    let actions: PersonalAgentRequestActions
    var openWeb: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: ParityTheme.proseBlockSpacing) {
            header
            content
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(tint.opacity(0.24)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stateTitle)
    }

    private var phase: PersonalAgentInputRequest.Phase { item.phase }
    private var isWaiting: Bool { phase == .answerable || phase == .sending }

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
                Text(title)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch item.request.kind {
        case let .approval(approval) where approval.family == .tool:
            [approval.toolName, approval.connectorName].compactMap { $0 }.first ?? L10n.string("Tool request")
        case let .approval(approval): approval.message
        case let .form(_, _): message ?? L10n.string("Information requested")
        case let .unsupported(request): request.message.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("Request from your dot")
        }
    }

    private var message: String? { item.request.params["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    private var isQuestion: Bool {
        if case .form = item.request.kind { return true }
        return false
    }

    private var stateTitle: String {
        switch phase {
        case .closed(.allowed): isQuestion ? L10n.string("Answered") : L10n.string("Allowed")
        case .closed(.denied): isQuestion ? L10n.string("Declined") : L10n.string("Denied")
        case .closed(.answered), .closed(.resolved): L10n.string("Resolved")
        case .closed(.expired): L10n.string("Expired")
        case .unconfirmed: L10n.string("Status unknown")
        default:
            switch item.request.kind {
            case .unsupported: L10n.string("Can't be answered here")
            case .form: L10n.string("Answer required")
            case .approval: L10n.string("Approval required")
            }
        }
    }

    private var icon: String {
        switch phase {
        case .closed(.allowed): isQuestion ? "checkmark.bubble.fill" : "checkmark.shield.fill"
        case .closed(.denied): "xmark.shield.fill"
        case .closed(.answered), .closed(.resolved): "checkmark.circle.fill"
        case .closed(.expired): "clock.badge.exclamationmark"
        case .unconfirmed: "questionmark.circle.fill"
        default:
            switch item.request.kind {
            case .unsupported: "arrow.up.right.square"
            case .form: "questionmark.bubble.fill"
            case .approval: "lock.shield.fill"
            }
        }
    }

    private var tint: Color {
        switch phase {
        case .closed(.allowed): .green
        case .closed(.denied): .red
        case .closed: .secondary
        case .unconfirmed: .orange
        default:
            if case .unsupported = item.request.kind { .secondary } else { .orange }
        }
    }

    // MARK: - What is asked

    @ViewBuilder
    private var content: some View {
        switch item.request.kind {
        case let .approval(approval):
            approvalContent(approval)
        case let .form(form, _):
            if case .closed = phase {
                EmptyView()
            } else {
                CodexMCPElicitationFormView(form: form, input: $item.formInput, isAnswerable: phase == .answerable)
            }
        case let .unsupported(request):
            if let detail = request.detail, !detail.isEmpty { bodyText(detail) }
            note(Self.reason(request.reason))
            if let openWeb {
                Button(L10n.string("Open This Dot on the Web"), action: openWeb)
                    .buttonStyle(.link)
                    .font(.caption)
                    .parityPointer()
            }
        }
    }

    @ViewBuilder
    private func approvalContent(_ approval: DotsApproval) -> some View {
        if approval.family == .tool, !approval.message.isEmpty { bodyText(approval.message) }
        if let subtitle = approval.presentation.subtitle, !subtitle.isEmpty { note(subtitle) }
        if let origin = approval.origin { detailRow(L10n.string("Site"), origin) }
        if !approval.details.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(approval.details.enumerated()), id: \.offset) { _, detail in
                    detailRow(detail.name, detail.value)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        }
        if approval.presentation.isHighRisk, isWaiting {
            Label(L10n.string("Check the details before allowing this."), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if approval.approveDisabled, isWaiting {
            note(L10n.string("Yardlet can't confirm what this change would do, so it can't be allowed here. You can deny it, or open the dot on the web."))
        } else if approval.isExecutionBound, isWaiting {
            note(L10n.string("This change runs once. Allowing it can't be remembered."))
        }
        if let parameters = approval.parameters {
            DisclosureGroup(L10n.string("Full parameters")) {
                ScrollView {
                    Text(DotsJSONText.pretty(parameters))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func reason(_ reason: DotsUnsupportedRequest.Reason) -> String {
        switch reason {
        case .location: L10n.string("This request asks for your location. Yardlet can't share it.")
        case .userVerification: L10n.string("This request needs verification on your device. Yardlet can't complete it.")
        case .link: L10n.string("This request opens a sign-in or web page. Yardlet doesn't open it from here.")
        case .openAIForm, .form: L10n.string("This form has fields Yardlet can't fill in yet.")
        case .wallet: L10n.string("This request sets up a payment method. Yardlet can't complete it.")
        case .browserSignIn: L10n.string("This request signs in to a site in your dot's browser. Yardlet can't complete it.")
        case .emailCode: L10n.string("This request fills in an email verification code. Yardlet can't complete it.")
        case .toolSetup: L10n.string("This request connects or turns on a tool. Yardlet can't set it up yet.")
        case .unknownApproval, .unrecognized: L10n.string("Yardlet can't answer this kind of request yet.")
        }
    }

    // MARK: - Answers

    @ViewBuilder
    private var footer: some View {
        if case .unsupported = item.request.kind {
            EmptyView()
        } else {
            switch phase {
            case .answerable, .sending:
                if let attempt = item.attempt { attemptNote(attempt) }
                buttons
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    note(L10n.string("Checking this request…"))
                }
            case .unavailable:
                statusRow(L10n.string("This request can't be answered right now."))
            case .unconfirmed:
                statusRow(L10n.string("Couldn't confirm this request's status."))
            case .closed:
                EmptyView()
            }
        }
    }

    private func attemptNote(_ attempt: PersonalAgentInputRequest.Attempt) -> some View {
        let text = switch attempt {
        case let .notSent(failure): L10n.format("The answer was not sent. %@", failure.message)
        case .storage: L10n.string("Yardlet couldn't record this answer, so it was not sent.")
        case .uncertain: L10n.string("Couldn't confirm this request's status.")
        }
        return Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    /// Why the request cannot be answered now, and a way to read it again; nothing is sent from here.
    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            note(text)
            Spacer(minLength: 8)
            if item.isChecking { ProgressView().controlSize(.small) }
            Button(L10n.string("Check status")) { actions.check(item) }
                .buttonStyle(.bordered)
                .parityPointer()
                .disabled(item.isChecking)
        }
    }

    private struct Answer: Identifiable {
        let id: String
        let title: String
        let result: DotsInputResult?
        var role: ButtonRole?
        var isPrimary = false
    }

    private var answers: [Answer] {
        switch item.request.kind {
        case let .approval(approval):
            var answers = [Answer(id: "deny", title: L10n.string("Deny"), result: approval.deny, role: .destructive)]
            if let cancel = approval.cancel { answers.append(.init(id: "cancel", title: L10n.string("Cancel"), result: cancel)) }
            if approval.persist.contains(.always), let allow = approval.allow(.always) {
                answers.append(.init(id: "always", title: L10n.string("Always allow"), result: allow))
            }
            if approval.persist.contains(.session), let allow = approval.allow(.session) {
                answers.append(.init(id: "session", title: L10n.string("Allow this conversation"), result: allow))
            }
            let once = approval.family == .tool || !approval.persist.isEmpty
            answers.append(.init(id: "allow", title: once ? L10n.string("Allow once") : L10n.string("Allow"),
                                 result: approval.allow(), isPrimary: true))
            return answers
        case let .form(form, _):
            return [
                .init(id: "decline", title: L10n.string("Decline"), result: .decline, role: .destructive),
                .init(id: "cancel", title: L10n.string("Cancel"), result: .cancel),
                .init(id: "submit", title: L10n.string("Submit"), result: DotsInputResult.submit(form, item.formInput), isPrimary: true)
            ]
        case .unsupported:
            return []
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if phase == .sending { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                ForEach(answers) { answerButton($0) }
            }
            VStack(alignment: .trailing, spacing: 6) {
                if phase == .sending { ProgressView().controlSize(.small) }
                ForEach(answers) { answerButton($0) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func answerButton(_ answer: Answer) -> some View {
        let send = { if let result = answer.result { actions.respond(item, result) } }
        let disabled = answer.result == nil || phase != .answerable
        if answer.isPrimary {
            Button(answer.title, role: answer.role, action: send)
                .parityProminentButton()
                .parityPointer()
                .disabled(disabled)
                .accessibilityLabel(answer.title)
        } else {
            Button(answer.title, role: answer.role, action: send)
                .buttonStyle(.bordered)
                .parityPointer()
                .disabled(disabled)
                .accessibilityLabel(answer.title)
        }
    }
}

/// The state of option answers above the editor, when the question view cannot show it: an answer
/// that could not be saved or read, which locks the options until it is, or a waiting answer whose
/// question is no longer shown, deleted or without its options. It names neither question nor answer,
/// and sends nothing.
struct PersonalAgentOptionAnswerStatus: View {
    @Bindable var reply: PersonalAgentOptionReply
    /// Whether the waiting answer's question is shown, with its own way to stop waiting.
    let showsQuestion: Bool
    let actions: PersonalAgentRequestActions
    @State private var confirming: PersonalAgentConfirmation?
    @Environment(\.personalAgentConfirmationPrompt) private var prompt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if reply.needsRecovery {
                Button(L10n.string("Keep as a backup")) { ask(.keepUnreadableAnswer) }
            } else if reply.storageFailed {
                // Saving again sends nothing; it only lets the options take an answer again.
                Button(L10n.string("Try again")) { reply.retrySave() }
            }
            if reply.pending != nil, !showsQuestion {
                Button(L10n.string("Stop waiting")) { if let id = reply.pending?.requestID { ask(.stopWaiting(id)) } }
            }
        }
        .disabled(reply.isSending)
        .font(.caption)
        .foregroundStyle(.secondary)
        .modifier(PersonalAgentConfirmationAlert(confirming: $confirming, confirm: confirm))
    }

    private var message: String {
        if reply.needsRecovery {
            return L10n.string("A saved answer to a question could not be read. Keep it as a backup to answer questions again.")
        }
        if reply.storageFailed { return PersonalAgentFailure.draftStorage.message }
        return L10n.string("An answer to a question that is no longer shown could not be confirmed. It may already have arrived.")
    }

    private func ask(_ confirmation: PersonalAgentConfirmation) {
        if let prompt { prompt.ask(confirmation) { confirm(confirmation) } } else { confirming = confirmation }
    }

    private func confirm(_ confirmation: PersonalAgentConfirmation) {
        switch confirmation {
        case let .stopWaiting(id): reply.discard(requestID: id)
        case .keepUnreadableAnswer: reply.recoverStorage()
        }
    }
}

/// What the person confirms before an option answer is let go.
enum PersonalAgentConfirmation: Identifiable, Hashable {
    /// Stops waiting for the answer with this request identity, which may already have arrived.
    case stopWaiting(String)
    /// Keeps an unreadable saved answer as a backup, then starts with none.
    case keepUnreadableAnswer
    var id: Self { self }
}

/// The confirmation every way to let an option answer go passes through.
struct PersonalAgentConfirmationAlert: ViewModifier {
    @Binding var confirming: PersonalAgentConfirmation?
    let confirm: @MainActor (PersonalAgentConfirmation) -> Void

    func body(content: Content) -> some View {
        let shown = confirming
        content.alert(title(shown), isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
                      presenting: shown) { confirmation in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(action(confirmation)) { confirm(confirmation) }
        } message: { confirmation in
            Text(confirmation != .keepUnreadableAnswer
                 ? L10n.string("The answer may already have arrived. Check the conversation before choosing again.")
                 : L10n.string("The unreadable answer will be kept as a backup beside it. Nothing is sent."))
        }
    }

    private func title(_ confirmation: PersonalAgentConfirmation?) -> String {
        confirmation == .keepUnreadableAnswer ? L10n.string("Keep the unreadable answer as a backup?")
            : L10n.string("Stop waiting for this answer?")
    }

    private func action(_ confirmation: PersonalAgentConfirmation) -> String {
        confirmation == .keepUnreadableAnswer ? L10n.string("Keep as a backup") : L10n.string("Stop waiting")
    }
}

/// Where a render receives a request to confirm, instead of an alert on a window that is never shown;
/// `confirm` runs only if the render confirms.
@MainActor
struct PersonalAgentConfirmationPrompt {
    var ask: @MainActor (_ confirmation: PersonalAgentConfirmation, _ confirm: @escaping @MainActor () -> Void) -> Void
}

private struct PersonalAgentConfirmationPromptKey: EnvironmentKey {
    static let defaultValue: PersonalAgentConfirmationPrompt? = nil
}

extension EnvironmentValues {
    var personalAgentConfirmationPrompt: PersonalAgentConfirmationPrompt? {
        get { self[PersonalAgentConfirmationPromptKey.self] }
        set { self[PersonalAgentConfirmationPromptKey.self] = newValue }
    }
}

/// A dot's question with options under its message. Choosing one sends its exact text as a reply to
/// the question, after reading the question again; the draft in the editor is left as it is.
struct PersonalAgentOptionQuestion: View {
    let messageID: String
    let picker: DotsOptionPicker
    /// The option the provider records, or a reply chose.
    let chosen: Int?
    let isAnswered: Bool
    @Bindable var reply: PersonalAgentOptionReply
    let actions: PersonalAgentRequestActions
    @State private var confirming: PersonalAgentConfirmation?
    @Environment(\.personalAgentConfirmationPrompt) private var prompt

    /// Whether the waiting answer is this question's.
    private var waitsHere: Bool { reply.pending?.replyToMessageID == messageID }
    private var isEnabled: Bool { !isAnswered && reply.pending == nil && !reply.isSending && !reply.storageFailed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(picker.options.enumerated()), id: \.offset) { index, option in
                let isChosen = chosen == index || (waitsHere && reply.pending?.optionSelection == index)
                Button { actions.choose(messageID, index) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        Text(option)
                            .font(.callout.weight(isChosen ? .semibold : .regular))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isChosen ? ParityTheme.selectedFill : ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .disabled(!isEnabled)
                .accessibilityLabel(option)
                .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            }
            status
        }
        .frame(maxWidth: 420, alignment: .leading)
        .modifier(PersonalAgentConfirmationAlert(confirming: $confirming) { confirmation in
            if case let .stopWaiting(id) = confirmation { reply.discard(requestID: id) }
        })
    }

    @ViewBuilder
    private var status: some View {
        if reply.isSending, waitsHere || reply.question == messageID {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Sending your answer…"))
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if waitsHere, let problem = reply.problem {
            VStack(alignment: .leading, spacing: 6) {
                Text(problem == .failure(.deliveryUnknown)
                     ? L10n.string("Delivery of your answer could not be confirmed. Refresh the conversation or send the same answer again.")
                     : Self.text(problem))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.string("Send the same answer again"), action: actions.retryOption)
                    Button(L10n.string("Stop waiting")) {
                        // The answer stopped is the one waiting when the person asked, bound to this reply.
                        guard let id = reply.pending?.requestID else { return }
                        if let prompt { prompt.ask(.stopWaiting(id)) { [reply] in reply.discard(requestID: id) } }
                        else { confirming = .stopWaiting(id) }
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if !waitsHere, reply.pending == nil, reply.question == messageID, let problem = reply.problem {
            Text(Self.text(problem))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func text(_ problem: PersonalAgentOptionReply.Problem) -> String {
        switch problem {
        case .changed: L10n.string("This question has changed or has already been answered.")
        case .unchecked: L10n.string("The question could not be checked. Try again.")
        case let .failure(failure): failure.message
        }
    }
}
