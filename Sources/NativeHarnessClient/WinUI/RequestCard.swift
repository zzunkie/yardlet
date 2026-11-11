import Foundation
import UWP
import WinUI

/// The one card for a request a provider asks the person to answer, drawn from the same `ConversationRequest` the
/// Mac's `ConversationRequestCard` draws: an approval with the provider's own options, a choice or free-text
/// question asked one at a time (`ConversationQuestionStepper`), a plan to review with what to change, and an MCP
/// form field by field (`CodexMCPElicitationForm`). Each answer goes back by its route; a form's route is made from
/// what was entered (`ConversationRequest.route(for:input:)`), and an answer stays off until the form can be sent.
/// Once answered, the card reads as the answer it got. The timeline keeps one card per request, so what a form
/// holds stays while its turn redraws.
@MainActor
final class RequestCard {
    let view = Border()
    private let content = StackPanel()
    private(set) var request: ConversationRequest
    /// Carries out an answer, with the route the form made; nil where the conversation cannot be answered here,
    /// and then `note` says where it is.
    private var respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?
    private var note: String?
    private var input = ConversationRequestFormInput()
    private var questionIndex = 0
    /// What the card sent for a question form, which it reads as until the provider's record arrives.
    private var sent: ConversationRequestFormInput?
    /// The questions whose own answer the person chose before typing it.
    private var customChosen: Set<String> = []
    /// The panel the card was placed in, which it leaves when it is placed again.
    private var host: StackPanel?
    /// What follows the form's input without being drawn again, so a field keeps its focus while the person types.
    private var refreshers: [() -> Void] = []
    /// The fields whose handlers read them back. A handler holds its field weakly, as a field holding its own
    /// handler's closure would never be freed, so the card keeps the field's Swift object while it is drawn.
    private var fields: [Control] = []

    init(request: ConversationRequest, respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?,
         note: String?) {
        self.request = request
        self.respond = respond
        self.note = note
        // A waiting question that takes one answer starts on its first option, as both apps start it.
        if request.state == .pending, let form = request.form { input.preselect(form.questionSteps) }
        content.spacing = 8
        view.child = content
        view.padding = Thickness(left: 12, top: 12, right: 12, bottom: 12)
        view.cornerRadius = CornerRadius(topLeft: 8, topRight: 8, bottomRight: 8, bottomLeft: 8)
        view.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        draw()
    }

    /// The request as it stands; the card draws again only when it changed, keeping what its form holds.
    func update(_ request: ConversationRequest, respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?,
                note: String?) {
        self.respond = respond
        guard request != self.request || note != self.note else { return }
        self.request = request
        self.note = note
        draw()
    }

    /// Puts the card at the end of `panel`, out of the panel it was in.
    func place(in panel: StackPanel) {
        if let host {
            var index: UInt32 = 0
            if host.children.indexOf(view, &index) { host.children.removeAt(index) }
        }
        panel.children.append(view)
        host = panel
    }

    // MARK: - Drawing

    /// The answers the card offers while the request waits: all of them where the conversation is answered here.
    private var responses: [ConversationRequestResponse] {
        respond != nil && request.state == .pending ? request.responses : []
    }

    /// The form takes input only while one of the offered answers sends it.
    private var answersForm: Bool { responses.contains { $0.route == .structured } }

    private func draw() {
        content.children.clear()
        refreshers = []
        fields = []
        view.isHitTestVisible = true
        content.opacity = 1
        let tint = Self.tint(request.state)
        view.background = SolidColorBrush(tint.withAlpha(0x0D))
        view.borderBrush = SolidColorBrush(tint.withAlpha(0x3D))
        let state = Self.text(request.stateTitle, size: 12, semibold: true)
        state.foreground = SolidColorBrush(tint)
        content.children.append(state)
        content.children.append(Self.text(request.title, semibold: true))
        if let detail = request.detail, !detail.isEmpty { content.children.append(Self.text(detail, muted: true)) }
        if let command = request.command { content.children.append(Self.code(command)) }
        // The provider's own reasons (Codex); a free-text question shows its questions instead.
        if !isFreeText, let context = request.codexContext {
            for message in context.messages { content.children.append(Self.text(message)) }
        }

        var drawsAnswers = false
        switch request.form {
        case let .choices(questions):
            drawsAnswers = questionForm(ConversationRequestForm.choices(questions).questionSteps)
        case let .freeText(questions):
            drawsAnswers = questionForm(ConversationRequestForm.freeText(questions).questionSteps)
        case let .planReview(plan):
            planReview(plan)
        case let .mcpForm(form):
            mcpForm(form)
        case nil:
            break
        }

        if request.state == .pending, !drawsAnswers {
            if !responses.isEmpty {
                content.children.append(answerRow(responses))
            } else if respond == nil {
                if let note { content.children.append(Self.text(note, muted: true)) }
            } else {
                content.children.append(Self.text(request.unanswerableReason
                    ?? L10n.string("This Codex request needs a structured response."), muted: true))
            }
        } else {
            stateNote()
        }
        refresh()
    }

    private var isFreeText: Bool {
        if case .freeText = request.form { return true }
        return false
    }

    /// Every control that follows the form's input, as it stands now.
    private func refresh() {
        for refresher in refreshers { refresher() }
    }

    /// Why an answered card ended the way it did, in the provider's words.
    private func stateNote() {
        switch request.state {
        case let .expired(message?) where !message.isEmpty:
            content.children.append(Self.text(message, muted: true))
        case let .rejected(message) where !message.isEmpty:
            let line = Self.text(message)
            line.foreground = SolidColorBrush(Self.red)
            content.children.append(line)
        default:
            break
        }
    }

    // MARK: - Questions

    /// The provider's own questions, one at a time while the request waits, and each with its answer once it is
    /// answered. Returns whether the answers are drawn in the form, in its last question's row.
    private func questionForm(_ steps: [ConversationQuestionStep]) -> Bool {
        guard request.state == .pending else {
            questionSummary(steps, answers: request.recordedAnswers ?? sent.map { $0.answers(for: steps) })
            return false
        }
        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        guard let step = stepper.current else { return false }
        let isAnswerable = answersForm
        if stepper.isStepped || step.header?.isEmpty == false {
            content.children.append(stepHeader(step, stepper: stepper))
        }
        if let text = step.text, !text.isEmpty { content.children.append(Self.text(text, semibold: true)) }
        if step.allowsMultipleSelections {
            content.children.append(Self.text(L10n.string("Choose one or more"), size: 12, muted: true))
        }
        if step.isFreeTextOnly {
            let field = answerField(step, placeholder: L10n.string("Answer"), steps: steps, isAnswerable: isAnswerable)
            try? AutomationProperties.setName(field, step.text ?? L10n.string("Answer"))
            content.children.append(field)
        } else {
            for option in step.options { content.children.append(optionControl(step, option, isAnswerable: isAnswerable)) }
            if step.allowsCustomAnswer { content.children.append(customAnswerRow(step, steps: steps, isAnswerable: isAnswerable)) }
        }
        guard isAnswerable else { return false }
        content.children.append(stepButtons(step, stepper: stepper, steps: steps))
        return true
    }

    /// The provider's label for the question, and its place among several between the previous and next question.
    private func stepHeader(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper) -> StackPanel {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        if let header = step.header, !header.isEmpty {
            let label = Self.text(header.uppercased(), size: 11, semibold: true, muted: true)
            label.verticalAlignment = .center
            row.children.append(label)
        }
        if stepper.isStepped {
            row.children.append(pagerButton("‹", label: L10n.string("Previous question"), isEnabled: stepper.hasPrevious) {
                [weak self] in self?.move(to: stepper.index - 1)
            })
            let place = Self.text(L10n.format("Question %lld of %lld", Int64(stepper.index + 1), Int64(stepper.steps.count)),
                                  size: 12, muted: true)
            place.verticalAlignment = .center
            row.children.append(place)
            row.children.append(pagerButton("›", label: L10n.string("Next question"), isEnabled: !stepper.isLast) {
                [weak self] in self?.move(to: stepper.index + 1)
            })
        }
        return row
    }

    private func pagerButton(_ symbol: String, label: String, isEnabled: Bool,
                             action: @escaping @MainActor () -> Void) -> Button {
        let button = Self.button(symbol, action: action)
        button.isEnabled = isEnabled
        try? AutomationProperties.setName(button, label)
        return button
    }

    /// One of the provider's options: a radio button for a question that takes one answer, a check box for one
    /// that takes several.
    private func optionControl(_ step: ConversationQuestionStep, _ option: PermissionQuestionOption,
                               isAnswerable: Bool) -> UIElement {
        let label = StackPanel()
        label.spacing = 2
        label.children.append(Self.text(option.label))
        if let description = option.description, !description.isEmpty {
            label.children.append(Self.text(description, size: 12, muted: true))
        }
        let isPicked = { [unowned self] in self.input.answer(for: step)?.options.contains(option.label) == true }
        let pick = { [weak self] in
            guard let self else { return }
            self.input.toggle(option.label, for: step)
            self.customChosen.remove(step.id)
            self.refresh()
        }
        if step.allowsMultipleSelections {
            let box = CheckBox()
            box.content = label
            box.isEnabled = isAnswerable
            try? AutomationProperties.setName(box, option.label)
            box.click.addHandler { _, _ in pick() }
            refreshers.append { box.isChecked = isPicked() }
            return box
        }
        let radio = RadioButton()
        radio.content = label
        radio.groupName = groupName(step.id)
        radio.isEnabled = isAnswerable
        try? AutomationProperties.setName(radio, option.label)
        radio.click.addHandler { _, _ in pick() }
        refreshers.append { radio.isChecked = isPicked() }
        return radio
    }

    /// The person's own answer, as the last option: Claude Code's "Other", the Codex app's field under the options.
    /// Typing chooses it over the options of a question that takes one answer.
    private func customAnswerRow(_ step: ConversationQuestionStep, steps: [ConversationQuestionStep],
                                 isAnswerable: Bool) -> UIElement {
        let field = answerField(step, placeholder: L10n.string("Type your own answer"), steps: steps,
                                isAnswerable: isAnswerable)
        try? AutomationProperties.setName(field, L10n.string("Other"))
        let isChosen = { [unowned self] in
            self.input.isCustomAnswerChosen(for: step)
                || (self.customChosen.contains(step.id) && self.input.answer(for: step) == nil)
        }
        let choose = { [weak self] in
            guard let self else { return }
            self.input.chooseCustomAnswer(for: step)
            self.customChosen.insert(step.id)
            self.refresh()
            _ = try? field.focus(.programmatic)
        }
        let mark: UIElement
        if step.allowsMultipleSelections {
            let box = CheckBox()
            box.isEnabled = isAnswerable
            box.click.addHandler { _, _ in choose() }
            refreshers.append { box.isChecked = isChosen() }
            mark = box
        } else {
            let radio = RadioButton()
            radio.groupName = groupName(step.id)
            radio.isEnabled = isAnswerable
            radio.click.addHandler { _, _ in choose() }
            refreshers.append { radio.isChecked = isChosen() }
            mark = radio
        }
        try? AutomationProperties.setName(mark, L10n.string("Other"))
        let row = Grid()
        let markColumn = ColumnDefinition()
        markColumn.width = GridLength(value: 0, gridUnitType: .auto)
        let fieldColumn = ColumnDefinition()
        fieldColumn.width = GridLength(value: 1, gridUnitType: .star)
        row.columnDefinitions.append(markColumn)
        row.columnDefinitions.append(fieldColumn)
        row.children.append(mark)
        try? Grid.setColumn(field, 1)
        row.children.append(field)
        return row
    }

    /// The person's words for `step`, or a hidden field for a secret. Enter goes on, as Next does.
    private func answerField(_ step: ConversationQuestionStep, placeholder: String, steps: [ConversationQuestionStep],
                             isAnswerable: Bool) -> Control {
        let goOn = { [weak self] in self?.goOn(from: step, steps: steps) }
        if step.isSecret {
            let field = PasswordBox()
            field.placeholderText = placeholder
            field.password = input.text[step.id] ?? ""
            field.isEnabled = isAnswerable
            field.passwordChanged.addHandler { [weak self, weak field] _, _ in
                guard let self, let field, field.password != (self.input.text[step.id] ?? "") else { return }
                self.input.setCustomAnswer(field.password, for: step)
                if !field.password.isEmpty { self.customChosen.remove(step.id) }
                self.refresh()
            }
            field.keyDown.addHandler { _, args in
                guard let args, args.key == .enter else { return }
                args.handled = true
                goOn()
            }
            fields.append(field)
            return field
        }
        let field = TextBox()
        field.placeholderText = placeholder
        field.text = input.text[step.id] ?? ""
        field.textWrapping = .wrap
        field.isEnabled = isAnswerable
        field.textChanged.addHandler { [weak self, weak field] _, _ in
            guard let self, let field, field.text != (self.input.text[step.id] ?? "") else { return }
            self.input.setCustomAnswer(field.text, for: step)
            if !field.text.isEmpty { self.customChosen.remove(step.id) }
            self.refresh()
        }
        field.keyDown.addHandler { _, args in
            guard let args, args.key == .enter else { return }
            args.handled = true
            goOn()
        }
        fields.append(field)
        return field
    }

    /// Skip where the provider allows it, then Next, or on the last question the answers. Next waits for an
    /// answer or a skip.
    private func stepButtons(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper,
                             steps: [ConversationQuestionStep]) -> StackPanel {
        let row = Self.buttonRow()
        if step.canSkip {
            row.children.append(Self.button(L10n.string("Skip")) { [weak self] in
                guard let self else { return }
                self.input.skip(step)
                self.goOn(from: step, steps: steps)
            })
        }
        if stepper.isLast {
            for response in responses { row.children.append(answerButton(response)) }
        } else {
            let next = Self.button(L10n.string("Next")) { [weak self] in self?.goOn(from: step, steps: steps) }
            refreshers.append { [unowned self] in next.isEnabled = self.input.isSettled(step) }
            row.children.append(next)
        }
        return row
    }

    private func move(to index: Int) {
        questionIndex = index
        draw()
    }

    /// Next, or on the last question the answers once every question is settled; nothing while the question waits.
    private func goOn(from step: ConversationQuestionStep, steps: [ConversationQuestionStep]) {
        guard answersForm, input.isSettled(step) else { return }
        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        if !stepper.isLast {
            move(to: stepper.index + 1)
        } else if let waiting = stepper.firstUnsettled(input) {
            move(to: waiting)
        } else if let submit = responses.first(where: { $0.route == .structured && $0.role == .primary })
                    ?? responses.first(where: { $0.route == .structured }) {
            send(submit)
        }
    }

    /// An answered form as both apps show one: each question, and under it what it was answered with, or that it
    /// was not answered. With no answers known it lists the questions alone.
    private func questionSummary(_ steps: [ConversationQuestionStep], answers: [String: ConversationQuestionAnswer]?) {
        for step in steps {
            let block = StackPanel()
            block.spacing = 2
            block.children.append(Self.text(step.text ?? step.header ?? L10n.string("Question"), muted: true))
            if let answers {
                if let answer = answers[step.id], !answer.values.isEmpty {
                    block.children.append(Self.text(answer.text(isSecret: step.isSecret), semibold: true))
                } else {
                    block.children.append(Self.text(L10n.string("Not answered"), muted: true))
                }
            }
            content.children.append(block)
        }
    }

    // MARK: - Plan review

    /// The plan exactly as the provider wrote it, and while it waits, what to change if planning goes on.
    private func planReview(_ plan: String) {
        let box = Border()
        box.background = SolidColorBrush(Self.gray.withAlpha(0x18))
        box.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        box.padding = Thickness(left: 12, top: 8, right: 12, bottom: 8)
        box.child = MarkdownView.element(plan)
        try? AutomationProperties.setName(box, L10n.string("Proposed plan"))
        content.children.append(box)
        guard answersForm else { return }
        let reason = TextBox()
        reason.placeholderText = L10n.string("Tell Claude what to change")
        reason.text = input.reason
        reason.textWrapping = .wrap
        try? AutomationProperties.setName(reason, L10n.string("Tell Claude what to change"))
        reason.textChanged.addHandler { [weak self, weak reason] _, _ in
            guard let self, let reason else { return }
            self.input.reason = reason.text
        }
        fields.append(reason)
        content.children.append(reason)
    }

    // MARK: - MCP form

    /// Each field under the server's title and description, with what it takes and, once something is entered,
    /// why it cannot be sent yet. An answered form shows what was sent.
    private func mcpForm(_ form: CodexMCPElicitationForm) {
        for field in form.fields {
            content.children.append(form.recorded != nil ? sentRow(form, field) : fieldView(form, field))
        }
    }

    private func sentRow(_ form: CodexMCPElicitationForm, _ field: CodexMCPElicitationForm.Field) -> StackPanel {
        let row = StackPanel()
        row.spacing = 2
        row.children.append(Self.text(field.label, size: 12, muted: true))
        let sent = form.sentText(of: field)
        row.children.append(Self.text(sent ?? L10n.string("Not answered"), muted: sent == nil))
        return row
    }

    private func fieldView(_ form: CodexMCPElicitationForm, _ field: CodexMCPElicitationForm.Field) -> StackPanel {
        let isAnswerable = answersForm
        let panel = StackPanel()
        panel.spacing = 4
        if case .boolean = field.kind {
            let box = CheckBox()
            box.content = field.label
            box.isEnabled = isAnswerable
            try? AutomationProperties.setName(box, field.label)
            box.click.addHandler { [weak self, weak box] _, _ in
                guard let self, let box else { return }
                self.input.fields[field.id] = .flag(box.isChecked == true)
                self.refresh()
            }
            refreshers.append { [unowned self] in
                if case let .flag(flag)? = form.value(of: field, in: self.input.fields) { box.isChecked = flag }
                else { box.isChecked = false }
            }
            fields.append(box)
            panel.children.append(box)
        } else {
            let label = StackPanel()
            label.orientation = .horizontal
            label.spacing = 6
            label.children.append(Self.text(field.label, semibold: true))
            let need = Self.text(field.isRequired ? L10n.string("Required") : L10n.string("Optional"), size: 11, muted: true)
            need.verticalAlignment = .center
            label.children.append(need)
            panel.children.append(label)
        }
        if let description = field.description, !description.isEmpty {
            panel.children.append(Self.text(description, size: 12, muted: true))
        }
        switch field.kind {
        case .text, .number:
            let box = TextBox()
            box.placeholderText = CodexMCPElicitationForm.placeholder(field.kind)
            if case let .text(text)? = form.value(of: field, in: input.fields) { box.text = text }
            box.isEnabled = isAnswerable
            try? AutomationProperties.setName(box, field.label)
            box.textChanged.addHandler { [weak self, weak box] _, _ in
                guard let self, let box else { return }
                self.input.fields[field.id] = .text(box.text)
                self.refresh()
            }
            fields.append(box)
            panel.children.append(box)
        case let .choice(options):
            choiceControls(form, field, options, isMultiple: false, isAnswerable: isAnswerable, in: panel)
        case let .choices(options, _, _):
            choiceControls(form, field, options, isMultiple: true, isAnswerable: isAnswerable, in: panel)
        case .boolean:
            break
        }
        if let hint = CodexMCPElicitationForm.hint(field.kind) {
            panel.children.append(Self.text(hint, size: 11, muted: true))
        }
        let issue = Self.text("", size: 12)
        issue.foreground = SolidColorBrush(Self.red)
        refreshers.append { [unowned self] in
            let shown = form.shownIssue(of: field, in: self.input.fields)
            issue.text = shown?.message ?? ""
            issue.visibility = shown == nil ? .collapsed : .visible
        }
        panel.children.append(issue)
        return panel
    }

    /// A choice field's options: radio buttons for one value, check boxes for several.
    private func choiceControls(_ form: CodexMCPElicitationForm, _ field: CodexMCPElicitationForm.Field,
                                _ options: [CodexMCPElicitationForm.Option], isMultiple: Bool, isAnswerable: Bool,
                                in panel: StackPanel) {
        for option in options {
            let pick = { [weak self] in
                guard let self else { return }
                self.input.fields[field.id] = form.toggling(option.value, in: field, input: self.input.fields)
                self.refresh()
            }
            let isPicked = { [unowned self] in form.picked(field, in: self.input.fields).contains(option.value) }
            if isMultiple {
                let box = CheckBox()
                box.content = option.title
                box.isEnabled = isAnswerable
                box.click.addHandler { _, _ in pick() }
                refreshers.append { box.isChecked = isPicked() }
                panel.children.append(box)
            } else {
                let radio = RadioButton()
                radio.content = option.title
                radio.groupName = groupName(field.id)
                radio.isEnabled = isAnswerable
                radio.click.addHandler { _, _ in pick() }
                refreshers.append { radio.isChecked = isPicked() }
                panel.children.append(radio)
            }
        }
    }

    // MARK: - Answers

    /// The answers in one row, the prominent one last.
    private func answerRow(_ responses: [ConversationRequestResponse]) -> StackPanel {
        let row = Self.buttonRow()
        for response in responses { row.children.append(answerButton(response)) }
        return row
    }

    /// An answer, on only while the form can be sent with it.
    private func answerButton(_ response: ConversationRequestResponse) -> Button {
        let button = Self.button(response.title) { [weak self] in self?.send(response) }
        refreshers.append { [unowned self] in button.isEnabled = self.request.route(for: response, input: self.input) != nil }
        return button
    }

    /// Sends `response` by the route the form makes of it. One answer per request: the card stops taking clicks,
    /// and draws again once the task takes the answer.
    private func send(_ response: ConversationRequestResponse) {
        guard let respond, let route = request.route(for: response, input: input) else { return }
        if response.route == .structured, request.form?.questionSteps.isEmpty == false { sent = input }
        var answer = response
        answer.route = route
        view.isHitTestVisible = false
        content.opacity = 0.6
        respond(request, answer)
    }

    // MARK: - Pieces

    /// Radio buttons answer one question or field of this request together.
    private func groupName(_ id: String) -> String { "\(request.id)\n\(id)" }

    private static func tint(_ state: ConversationRequestState) -> UWP.Color {
        switch state {
        case .pending: UWP.Color(a: 0xFF, r: 0xE0, g: 0x80, b: 0x00)
        case .allowed, .answered: UWP.Color(a: 0xFF, r: 0x2E, g: 0x9E, b: 0x4F)
        case .denied, .rejected: red
        case .expired: gray
        }
    }

    private static let red = UWP.Color(a: 0xFF, r: 0xC4, g: 0x2B, b: 0x1C)
    /// A gray that reads on a light and a dark window alike.
    private static let gray = UWP.Color(a: 0xFF, r: 0x80, g: 0x80, b: 0x80)

    private static func text(_ string: String, size: Double = 14, semibold: Bool = false, muted: Bool = false) -> TextBlock {
        let block = TextBlock()
        block.text = string
        block.fontSize = size
        block.textWrapping = .wrap
        block.isTextSelectionEnabled = true
        if semibold { block.fontWeight = UWP.FontWeight(weight: 600) }
        if muted { block.opacity = 0.65 }
        return block
    }

    private static func code(_ string: String) -> Border {
        let block = text(string, size: 13)
        block.fontFamily = FontFamily("Consolas")
        let box = Border()
        box.background = SolidColorBrush(gray.withAlpha(0x18))
        box.cornerRadius = CornerRadius(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
        box.padding = Thickness(left: 10, top: 6, right: 10, bottom: 6)
        box.child = block
        return box
    }

    private static func buttonRow() -> StackPanel {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        row.horizontalAlignment = .right
        return row
    }

    private static func button(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.click.addHandler { _, _ in action() }
        return button
    }
}

private extension UWP.Color {
    func withAlpha(_ alpha: UInt8) -> UWP.Color { UWP.Color(a: alpha, r: r, g: g, b: b) }
}
