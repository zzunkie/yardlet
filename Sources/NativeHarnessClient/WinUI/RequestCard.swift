import Foundation
import UWP
import WinUI

/// The one card for a request a provider asks the person to answer, drawn from the same `ConversationRequest` the
/// Mac's `ConversationRequestCard` draws and in its look: a tile with the request's mark in its state's color, the
/// state ("Approval needed") over the request's title, what the request would do (an edit's diff as the file change
/// card draws it, a file's new contents, a command), and the provider's own options as the Mac's gray buttons, the
/// prominent one in Yardlet's accent and last. A choice or free-text question is asked one at a time
/// (`ConversationQuestionStepper`) with its options as filled rows, the picked option's preview beside them where
/// they have previews, and Skip; a plan comes to review with what to change, and an MCP form field by field
/// (`CodexMCPElicitationForm`). Each answer goes back by its route; a form's route is made from what was entered
/// (`ConversationRequest.route(for:input:)`), and an answer stays off until the form can be sent. Once answered, the
/// card reads as the answer it got. The timeline keeps one card per request, so what a form holds stays while its
/// turn redraws.
@MainActor
final class RequestCard {
    let view = Border()
    private let content = StackPanel()
    private(set) var request: ConversationRequest
    /// Carries out an answer, with the route the form made; nil where the conversation cannot be answered here,
    /// and then `note` says where it is.
    private var respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?
    /// Asks before an answer goes, where one needs it; false leaves the card as it was.
    var confirm: (@MainActor (ConversationRequest, ConversationRequestResponse) async -> Bool)?
    private var note: String?
    /// The task's folder, which a previewed edit's path is read against.
    private let workspaceURL: URL?
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
         note: String?, workspaceURL: URL? = nil) {
        self.request = request
        self.respond = respond
        self.note = note
        self.workspaceURL = workspaceURL
        // A waiting question that takes one answer starts on its first option, as both apps start it.
        if request.state == .pending, let form = request.form { input.preselect(form.questionSteps) }
        content.spacing = WindowsTheme.proseBlockSpacing
        view.child = content
        view.padding = Thickness(left: 12, top: 12, right: 12, bottom: 12)
        view.cornerRadius = ConversationStyle.corners(11)
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
        view.background = tint.opacity(0.05).brush
        view.borderBrush = tint.opacity(0.24).brush
        content.children.append(header(tint: tint))
        if let detail = request.detail, !detail.isEmpty, request.preview?.repeats(detail) != true {
            content.children.append(Self.text(detail, size: ConversationStyle.calloutSize, muted: true))
        }
        if let preview = request.preview {
            content.children.append(previewView(preview))
        } else if let command = request.command {
            content.children.append(Self.labeledBox(L10n.string("Command"), Self.code(command)))
        }
        // The provider's own reasons and fields (Codex); a free-text question shows its questions instead.
        if !isFreeText, let context = request.codexContext { providerContext(context) }

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
                if let note { content.children.append(Self.text(note, size: ConversationStyle.captionSize, muted: true)) }
            } else {
                content.children.append(Self.text(request.unanswerableReason
                    ?? L10n.string("This Codex request needs a structured response."),
                    size: ConversationStyle.captionSize, muted: true))
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

    /// The request's mark on a tile in its state's color, and the state over the title (the Mac's header).
    private func header(tint: Tint) -> UIElement {
        let mark = ConversationStyle.icon(icon, size: 14, brush: tint.solid.brush)
        mark.horizontalAlignment = .center
        let tile = Border()
        tile.width = 28
        tile.height = 28
        tile.cornerRadius = ConversationStyle.corners(7)
        tile.background = tint.opacity(0.1).brush
        tile.verticalAlignment = .top
        tile.child = mark
        let state = Self.text(request.stateTitle, size: ConversationStyle.captionSize, semibold: true)
        state.foreground = tint.solid.brush
        let words = StackPanel()
        words.spacing = 3
        words.children.append(state)
        words.children.append(Self.text(request.title, size: ConversationStyle.calloutSize, semibold: true))
        let row = Grid()
        row.columnSpacing = 10
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        row.children.append(tile)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        if let method = request.method, !method.isEmpty { try? ToolTipService.setToolTip(row, method) }
        return row
    }

    /// The request's mark, as the Mac's for its kind and state.
    private var icon: String {
        let (isQuestion, isPlan): (Bool, Bool) = switch request.form {
        case .choices, .freeText, .mcpForm: (true, false)
        case .planReview: (false, true)
        case nil: (false, false)
        }
        typealias Glyph = ConversationStyle.Glyph
        switch request.state {
        case .pending: return isQuestion ? Glyph.question : isPlan ? Glyph.list : Glyph.shield
        case .allowed, .answered: return Glyph.check
        case .denied: return Glyph.cancel
        case .expired: return Glyph.clock
        case .rejected: return Glyph.error
        }
    }

    // MARK: - What the request would do

    /// The change a tool request would make (the Mac's `PermissionRequestPreviewView`): a file's edits or new
    /// contents in the file change card's box, or a command with its description.
    private func previewView(_ preview: PermissionRequestPreview) -> UIElement {
        switch preview {
        case let .edits(path, edits, omittedEditCount):
            let diff = PermissionRequestPreviewProjection.diff(edits: edits, omittedEditCount: omittedEditCount)
            let counts = FileChangeView.counts(.init(additions: diff.additions, deletions: diff.deletions),
                                               size: ConversationStyle.captionSize)
            return diffBox(path: path, diff: diff, emptyText: L10n.string("No changes"), summary: counts)
        case let .write(path, content):
            let diff = PermissionRequestPreviewProjection.content(content)
            let lines = Self.text(L10n.format("%lld lines", Int64(diff.additions + content.omittedLineCount)),
                                  size: ConversationStyle.captionSize, muted: true)
            lines.verticalAlignment = .center
            return diffBox(path: path, diff: diff, emptyText: L10n.string("Empty file"), summary: lines)
        case let .command(command, description):
            let stack = StackPanel()
            stack.spacing = 6
            if let description {
                stack.children.append(Self.text(description, size: ConversationStyle.calloutSize, muted: true))
            }
            stack.children.append(ConversationStyle.text(L10n.string("Command"), size: ConversationStyle.captionSize,
                                                         tone: .tertiary, semibold: true))
            stack.children.append(Self.code(command.text))
            if command.omittedLineCount > 0 {
                stack.children.append(Self.text(L10n.format("%lld more lines", Int64(command.omittedLineCount)),
                                                size: ConversationStyle.captionSize, muted: true))
            }
            return stack
        }
    }

    private func diffBox(path: String, diff: PermissionRequestPreviewProjection.Diff, emptyText: String,
                         summary: UIElement) -> UIElement {
        let hasChanges = diff.additions + diff.deletions > 0
        var content: [UIElement] = [hasChanges ? FileChangeView.lines(diff.lines) : Self.notice(emptyText)]
        if hasChanges, diff.hiddenLineCount > 0 {
            content += [Self.rule(), Self.notice(L10n.format("%lld more lines", Int64(diff.hiddenLineCount)))]
        }
        if diff.omittedEditCount > 0 {
            content += [Self.rule(), Self.notice(L10n.format("%lld more edits", Int64(diff.omittedEditCount)))]
        }
        return FileChangeView.box(title: CodexFileChangeDiff.displayPath(path, workspaceURL: workspaceURL),
                                  summary: [summary], content: content)
    }

    /// The provider's own decision context (Codex): its reasons, and its fields under their titles.
    private func providerContext(_ context: CodexRequestContextProjection) {
        for message in context.messages {
            content.children.append(Self.text(message, size: ConversationStyle.calloutSize))
        }
        for field in context.fields where field.id != "command" || request.command == nil {
            let stack = StackPanel()
            stack.spacing = 4
            if let title = field.titleKey {
                stack.children.append(ConversationStyle.text(L10n.string(title), size: ConversationStyle.captionSize,
                                                             tone: .tertiary, semibold: true))
            }
            stack.children.append(Self.code(field.text))
            content.children.append(stack)
        }
        if context.isEmpty, request.command == nil, let method = request.method {
            let line = Self.text(method, size: ConversationStyle.captionSize, muted: true)
            line.fontFamily = ConversationStyle.codeFont()
            content.children.append(line)
        }
    }

    /// Every control that follows the form's input, as it stands now.
    private func refresh() {
        for refresher in refreshers { refresher() }
    }

    /// Why an answered card ended the way it did, in the provider's words.
    private func stateNote() {
        switch request.state {
        case let .expired(message?) where !message.isEmpty:
            content.children.append(Self.text(message, size: ConversationStyle.captionSize, muted: true))
        case let .rejected(message) where !message.isEmpty:
            let line = Self.text(message, size: ConversationStyle.captionSize)
            line.foreground = ConversationStyle.red.solid.brush
            content.children.append(line)
        default:
            break
        }
    }

    // MARK: - Questions

    /// The provider's own questions, one at a time while the request waits, and each with its answer once it is
    /// answered, as the Mac's question form (`ConversationQuestionStepsView`): the question's label and its place among
    /// several, the question, its options as filled rows (the picked one's preview beside them where they have
    /// previews), the person's own answer, then Skip and Next, or on the last question the answers. Returns whether
    /// the answers are drawn in the form, in its last question's row.
    private func questionForm(_ steps: [ConversationQuestionStep]) -> Bool {
        guard request.state == .pending else {
            questionSummary(steps, answers: request.recordedAnswers ?? sent.map { $0.answers(for: steps) })
            return false
        }
        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        guard let step = stepper.current else { return false }
        let isAnswerable = answersForm
        let form = StackPanel()
        form.spacing = 8
        content.children.append(form)
        if stepper.isStepped || step.header?.isEmpty == false {
            form.children.append(stepHeader(step, stepper: stepper))
        }
        if let text = step.text, !text.isEmpty {
            form.children.append(Self.text(text, size: ConversationStyle.calloutSize, semibold: true))
        }
        if step.allowsMultipleSelections {
            form.children.append(ConversationStyle.text(L10n.string("Choose one or more"), size: ConversationStyle.captionSize,
                                                        tone: .tertiary))
        }
        if step.isFreeTextOnly {
            let field = answerField(step, placeholder: L10n.string("Answer"), steps: steps, isAnswerable: isAnswerable)
            try? AutomationProperties.setName(field, step.text ?? L10n.string("Answer"))
            form.children.append(field)
        } else {
            let options = StackPanel()
            options.spacing = 6
            for option in step.options { options.children.append(optionControl(step, option, isAnswerable: isAnswerable)) }
            if step.allowsCustomAnswer {
                options.children.append(customAnswerRow(step, steps: steps, isAnswerable: isAnswerable))
            }
            form.children.append(step.showsPreviews ? withPreview(options, step: step) : options)
        }
        guard isAnswerable else { return false }
        form.children.append(stepButtons(step, stepper: stepper, steps: steps))
        return true
    }

    /// The provider's label for the question on the left; its place among several, between the previous and next
    /// question, on the right.
    private func stepHeader(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper) -> Grid {
        let row = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        if let header = step.header, !header.isEmpty {
            let label = ConversationStyle.text(header.uppercased(), size: ConversationStyle.captionSize, tone: .tertiary,
                                               semibold: true, wraps: false)
            label.verticalAlignment = .center
            row.children.append(label)
        }
        if stepper.isStepped {
            let place = ConversationStyle.text(
                L10n.format("Question %lld of %lld", Int64(stepper.index + 1), Int64(stepper.steps.count)),
                size: ConversationStyle.captionSize, tone: .secondary, wraps: false
            )
            place.verticalAlignment = .center
            let pager = ConversationStyle.row([
                pagerButton(ConversationStyle.Glyph.chevronLeft, label: L10n.string("Previous question"),
                            isEnabled: stepper.hasPrevious) { [weak self] in self?.move(to: stepper.index - 1) },
                place,
                pagerButton(ConversationStyle.Glyph.chevronRight, label: L10n.string("Next question"),
                            isEnabled: !stepper.isLast) { [weak self] in self?.move(to: stepper.index + 1) }
            ], spacing: 2)
            try? Grid.setColumn(pager, 1)
            row.children.append(pager)
        }
        return row
    }

    private func pagerButton(_ glyph: String, label: String, isEnabled: Bool,
                             action: @escaping @MainActor () -> Void) -> Button {
        let mark = ConversationStyle.icon(glyph, size: 10, brush: WindowsTheme.secondaryText.brush)
        mark.horizontalAlignment = .center
        let frame = Border()
        frame.width = 20
        frame.height = 20
        frame.child = mark
        let button = ConversationStyle.plainButton(frame, name: label, action: action)
        button.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.isEnabled = isEnabled
        if !isEnabled { mark.opacity = 0.35 }
        try? ToolTipService.setToolTip(button, label)
        return button
    }

    /// The options on the left and the picked option's preview on the right, which says when the option has none
    /// (Claude Code's layout, the Mac's `ConversationQuestionPreview`).
    private func withPreview(_ options: UIElement, step: ConversationQuestionStep) -> UIElement {
        let grid = Grid()
        grid.columnSpacing = 12
        for width in [GridLength(value: 220, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            grid.columnDefinitions.append(column)
        }
        grid.children.append(options)
        let preview = Border()
        preview.background = WindowsTheme.elevated.brush
        preview.borderBrush = WindowsTheme.separator.brush
        preview.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        preview.cornerRadius = ConversationStyle.corners(8)
        preview.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        preview.minWidth = 160
        preview.verticalAlignment = .top
        try? AutomationProperties.setName(preview, L10n.string("Preview"))
        try? Grid.setColumn(preview, 1)
        grid.children.append(preview)
        var shown: String??
        refreshers.append { [unowned self] in
            let markdown = step.preview(for: self.input.answer(for: step))
            guard shown != .some(markdown) else { return }
            shown = .some(markdown)
            if let markdown {
                preview.child = MarkdownView.element(markdown)
            } else {
                let none = ConversationStyle.text(L10n.string("No preview"), size: ConversationStyle.captionSize,
                                                  tone: .tertiary)
                none.minHeight = 48
                none.horizontalAlignment = .center
                none.textAlignment = .center
                preview.child = none
            }
        }
        return grid
    }

    /// One of the provider's options as the Mac's filled row: a radio button for a question that takes one answer,
    /// a check box for one that takes several, its label (semibold once picked) over its description, on a fill
    /// that darkens once it is picked.
    private func optionControl(_ step: ConversationQuestionStep, _ option: PermissionQuestionOption,
                               isAnswerable: Bool) -> UIElement {
        let label = StackPanel()
        label.spacing = 2
        // Words a click picks the option by, not a selection.
        let title = ConversationStyle.text(option.label, size: ConversationStyle.calloutSize, selectable: false)
        label.children.append(title)
        if let description = option.description, !description.isEmpty {
            label.children.append(ConversationStyle.text(description, size: ConversationStyle.captionSize, tone: .secondary,
                                                         selectable: false))
        }
        let isPicked = { [unowned self] in self.input.answer(for: step)?.options.contains(option.label) == true }
        let pick = { [weak self] in
            guard let self else { return }
            self.input.toggle(option.label, for: step)
            self.customChosen.remove(step.id)
            self.refresh()
        }
        let row = Self.optionRow()
        refreshers.append {
            let picked = isPicked()
            row.background = (picked ? WindowsTheme.selectedFill : WindowsTheme.subtleFill).brush
            title.fontWeight = UWP.FontWeight(weight: picked ? 600 : 400)
        }
        if step.allowsMultipleSelections {
            let box = CheckBox()
            box.content = label
            box.isEnabled = isAnswerable
            box.minWidth = 0
            box.horizontalAlignment = .stretch
            try? AutomationProperties.setName(box, option.label)
            box.click.addHandler { _, _ in pick() }
            refreshers.append { box.isChecked = isPicked() }
            row.child = box
            return row
        }
        let radio = RadioButton()
        radio.content = label
        radio.groupName = groupName(step.id)
        radio.isEnabled = isAnswerable
        radio.minWidth = 0
        radio.horizontalAlignment = .stretch
        try? AutomationProperties.setName(radio, option.label)
        radio.click.addHandler { _, _ in pick() }
        refreshers.append { radio.isChecked = isPicked() }
        row.child = radio
        return row
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
        if let control = mark as? Control { control.minWidth = 0 }
        let grid = Grid()
        let markColumn = ColumnDefinition()
        markColumn.width = GridLength(value: 0, gridUnitType: .auto)
        let fieldColumn = ColumnDefinition()
        fieldColumn.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(markColumn)
        grid.columnDefinitions.append(fieldColumn)
        grid.children.append(mark)
        try? Grid.setColumn(field, 1)
        grid.children.append(field)
        let row = Self.optionRow()
        row.child = grid
        refreshers.append { row.background = (isChosen() ? WindowsTheme.selectedFill : WindowsTheme.subtleFill).brush }
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
                             steps: [ConversationQuestionStep]) -> UIElement {
        var buttons: [Button] = []
        if step.canSkip {
            buttons.append(ConversationStyle.grayButton(L10n.string("Skip")) { [weak self] in
                guard let self else { return }
                self.input.skip(step)
                self.goOn(from: step, steps: steps)
            })
        }
        if stepper.isLast {
            buttons += responses.map { answerButton($0) }
        } else {
            let next = ConversationStyle.prominentButton(L10n.string("Next")) { [weak self] in
                self?.goOn(from: step, steps: steps)
            }
            refreshers.append { [unowned self] in next.isEnabled = self.input.isSettled(step) }
            buttons.append(next)
        }
        return Self.buttonRow(buttons)
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
        let list = StackPanel()
        list.spacing = 10
        for step in steps {
            let block = StackPanel()
            block.spacing = 3
            block.children.append(Self.text(step.text ?? step.header ?? L10n.string("Question"),
                                            size: ConversationStyle.calloutSize, muted: true))
            if let answers {
                if let answer = answers[step.id], !answer.values.isEmpty {
                    block.children.append(Self.text(answer.text(isSecret: step.isSecret), size: ConversationStyle.calloutSize,
                                                    semibold: true))
                } else {
                    block.children.append(ConversationStyle.text(L10n.string("Not answered"),
                                                                 size: ConversationStyle.calloutSize, tone: .tertiary))
                }
            }
            if let preview = step.preview(for: answers?[step.id]) {
                // The Claude app keeps the picked option's preview with the answer.
                let box = Border()
                box.background = WindowsTheme.elevated.brush
                box.borderBrush = WindowsTheme.separator.brush
                box.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
                box.cornerRadius = ConversationStyle.corners(8)
                box.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
                box.child = MarkdownView.element(preview)
                block.children.append(box)
            }
            list.children.append(block)
        }
        content.children.append(list)
    }

    // MARK: - Plan review

    /// The plan exactly as the provider wrote it, and while it waits, what to change if planning goes on.
    private func planReview(_ plan: String) {
        let box = Border()
        box.background = WindowsTheme.subtleFill.brush
        box.cornerRadius = ConversationStyle.corners(8)
        box.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
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
        row.children.append(Self.text(field.label, size: ConversationStyle.captionSize, muted: true))
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
            let need = Self.text(field.isRequired ? L10n.string("Required") : L10n.string("Optional"), size: ConversationStyle.captionSize, muted: true)
            need.verticalAlignment = .center
            label.children.append(need)
            panel.children.append(label)
        }
        if let description = field.description, !description.isEmpty {
            panel.children.append(Self.text(description, size: ConversationStyle.captionSize, muted: true))
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
            panel.children.append(Self.text(hint, size: ConversationStyle.captionSize, muted: true))
        }
        let issue = Self.text("", size: ConversationStyle.captionSize)
        issue.foreground = ConversationStyle.red.solid.brush
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
    private func answerRow(_ responses: [ConversationRequestResponse]) -> UIElement {
        Self.buttonRow(responses.map { answerButton($0) })
    }

    /// An answer, on only while the form can be sent with it: the prominent one in Yardlet's accent, the others gray.
    private func answerButton(_ response: ConversationRequestResponse) -> Button {
        let send: @MainActor () -> Void = { [weak self] in self?.send(response) }
        let button = response.role == .primary
            ? ConversationStyle.prominentButton(response.title, action: send)
            : ConversationStyle.grayButton(response.title, action: send)
        refreshers.append { [unowned self] in button.isEnabled = self.request.route(for: response, input: self.input) != nil }
        return button
    }

    /// Sends `response` by the route the form makes of it, once the person agreed where `confirm` asks. One answer per
    /// request: the card stops taking clicks, and draws again once the task takes the answer.
    private func send(_ response: ConversationRequestResponse) {
        guard respond != nil, let route = request.route(for: response, input: input) else { return }
        let recordsForm = response.route == .structured && request.form?.questionSteps.isEmpty == false
        var answer = response
        answer.route = route
        guard let confirm else { return carryOut(answer, recordsForm: recordsForm) }
        let request = request
        Task { @MainActor [weak self] in
            guard await confirm(request, answer), let self, self.request.id == request.id else { return }
            self.carryOut(answer, recordsForm: recordsForm)
        }
    }

    private func carryOut(_ answer: ConversationRequestResponse, recordsForm: Bool) {
        guard let respond else { return }
        if recordsForm { sent = input }
        view.isHitTestVisible = false
        content.opacity = 0.6
        respond(request, answer)
    }

    // MARK: - Pieces

    /// Radio buttons answer one question or field of this request together.
    private func groupName(_ id: String) -> String { "\(request.id)\n\(id)" }

    private static func tint(_ state: ConversationRequestState) -> Tint {
        switch state {
        case .pending: ConversationStyle.orange
        case .allowed, .answered: ConversationStyle.green
        case .denied, .rejected: ConversationStyle.red
        case .expired: ConversationStyle.gray
        }
    }

    private static func text(_ string: String, size: Double = ConversationStyle.bodySize, semibold: Bool = false,
                             muted: Bool = false) -> TextBlock {
        ConversationStyle.text(string, size: size, tone: muted ? .secondary : .primary, semibold: semibold)
    }

    /// A command or a field's text in the code font, in a box.
    private static func code(_ string: String) -> Border {
        let block = ConversationStyle.text(string, size: ConversationStyle.smallCodeSize)
        block.fontFamily = ConversationStyle.codeFont()
        let box = Border()
        box.background = WindowsTheme.subtleFill.brush
        box.cornerRadius = ConversationStyle.corners(6)
        box.padding = Thickness(left: 10, top: 8, right: 10, bottom: 8)
        box.child = block
        return box
    }

    /// `content` under a small title (the Mac's labeled box).
    private static func labeledBox(_ title: String, _ content: UIElement) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 6
        stack.children.append(ConversationStyle.text(title, size: ConversationStyle.captionSize, tone: .tertiary,
                                                     semibold: true))
        stack.children.append(content)
        return stack
    }

    /// The fill an option's row sits on.
    private static func optionRow() -> Border {
        let row = Border()
        row.background = WindowsTheme.subtleFill.brush
        row.cornerRadius = ConversationStyle.corners(8)
        row.padding = Thickness(left: 10, top: 4, right: 10, bottom: 4)
        return row
    }

    private static func notice(_ text: String) -> UIElement {
        let block = ConversationStyle.text(text, size: ConversationStyle.captionSize, tone: .secondary)
        block.margin = Thickness(left: 10, top: 8, right: 10, bottom: 8)
        return block
    }

    private static func rule() -> Border {
        let rule = Border()
        rule.height = 1
        rule.background = WindowsTheme.separator.brush
        return rule
    }

    /// `buttons` in one row on the right, or where they do not fit side by side, stacked on the right, as the Mac's
    /// card stacks its answers. The buttons keep their own widths either way, which is what the row is measured by.
    private static func buttonRow(_ buttons: [Button]) -> Grid {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        row.horizontalAlignment = .right
        for button in buttons {
            button.horizontalAlignment = .right
            row.children.append(button)
        }
        let holder = Grid()
        holder.children.append(row)
        let stacked = Stacked()
        holder.sizeChanged.addHandler { sender, _ in
            guard let width = (sender as? FrameworkElement)?.actualWidth else { return }
            let needed = buttons.reduce(0) { $0 + $1.actualWidth } + 8 * Double(max(0, buttons.count - 1))
            guard (needed > width) != stacked.value else { return }
            stacked.value = needed > width
            row.orientation = stacked.value ? .vertical : .horizontal
            row.spacing = stacked.value ? 6 : 8
        }
        return holder
    }

    private final class Stacked {
        var value = false
    }
}
