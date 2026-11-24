import Foundation
import UWP
import WinUI

/// A provider's pending request and its answers. Once the person answers, the same card moves into
/// the turn as a compact record, keeping its form input until the provider records the answer.
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
    private var answeredByComposerKeys: Bool
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
         note: String?, workspaceURL: URL? = nil, answeredByComposerKeys: Bool = false) {
        self.request = request
        self.respond = respond
        self.note = note
        self.workspaceURL = workspaceURL
        self.answeredByComposerKeys = answeredByComposerKeys
        // A waiting question that takes one answer starts on its first option, as both apps start it.
        if request.state == .pending, let form = request.form { input.preselect(form.questionSteps) }
        view.child = content
        draw()
    }

    /// The request as it stands; the card draws again only when it changed, keeping what its form holds.
    func update(_ request: ConversationRequest, respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?,
                note: String?, answeredByComposerKeys: Bool = false) {
        let canRespondChanged = (self.respond == nil) != (respond == nil)
        self.respond = respond
        guard request != self.request || note != self.note || canRespondChanged
                || answeredByComposerKeys != self.answeredByComposerKeys else { return }
        self.answeredByComposerKeys = answeredByComposerKeys
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
        let pending = request.state == .pending
        content.spacing = pending ? 0 : 8
        view.background = pending ? WindowsTheme.requestPanelFill.brush : nil
        view.borderBrush = pending ? WindowsTheme.strongSeparator.brush : nil
        view.cornerRadius = ConversationStyle.corners(WindowsTheme.panelCornerRadius)
        let line: Double = pending ? 1 : 0
        view.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        view.borderThickness = Thickness(left: line, top: line, right: line, bottom: line)
        guard pending else {
            drawAnswered()
            return
        }

        content.children.append(headerBand())
        let body = StackPanel()
        body.spacing = 12
        body.margin = Thickness(left: 16, top: 16, right: 16, bottom: 16)
        content.children.append(body)

        if let headline = request.descriptionHeadline {
            body.children.append(Self.text(headline, size: ConversationStyle.calloutSize, semibold: true))
        }
        if request.descriptionHeadline == nil, let detail = request.detail, !detail.isEmpty,
           request.preview?.repeats(detail) != true {
            body.children.append(Self.text(detail, size: ConversationStyle.calloutSize, muted: true))
        }
        if let preview = request.preview {
            body.children.append(previewView(preview))
        } else if let command = request.command {
            body.children.append(Self.code(command))
        }
        // The provider's own reasons and fields (Codex); a free-text question shows its questions instead.
        if !isFreeText, let context = request.codexContext { providerContext(context, in: body) }

        var drawsAnswers = false
        switch request.form {
        case let .choices(questions):
            drawsAnswers = questionForm(ConversationRequestForm.choices(questions).questionSteps, in: body)
        case let .freeText(questions):
            drawsAnswers = questionForm(ConversationRequestForm.freeText(questions).questionSteps, in: body)
        case let .planReview(plan):
            planReview(plan, in: body)
        case let .mcpForm(form):
            mcpForm(form, in: body)
        case nil:
            break
        }

        if !drawsAnswers {
            if !responses.isEmpty {
                body.children.append(answerRow(responses))
            } else if respond == nil {
                if let note { body.children.append(Self.text(note, size: ConversationStyle.captionSize, muted: true)) }
            } else {
                body.children.append(Self.text(request.unanswerableReason
                    ?? L10n.string("This Codex request needs a structured response."),
                    size: ConversationStyle.captionSize, muted: true))
            }
        }
        refresh()
    }

    private var isFreeText: Bool {
        if case .freeText = request.form { return true }
        return false
    }

    private var waitingSymbol: String {
        switch request.form {
        case .choices, .freeText: ConversationStyle.Glyph.question
        case .planReview: ConversationStyle.Glyph.list
        case .mcpForm: ConversationStyle.Glyph.edit
        case nil: ConversationStyle.Glyph.shield
        }
    }

    /// The panel's header band, as the Mac's `ConversationRequestSurface`: an accent symbol for what the request waits
    /// for and its title (or the tool's name when the provider described the call), plus a question form's label and
    /// pager on the same band.
    private func headerBand() -> Border {
        let headerContent: FrameworkElement
        if let steps = request.form?.questionSteps, !steps.isEmpty {
            headerContent = Self.questionBand(title: request.title, steps: steps, index: questionIndex) { [weak self] next in
                self?.move(to: next)
            }
        } else {
            headerContent = Self.bandTitle(symbol: waitingSymbol, title: request.title)
        }
        return Self.panelHeaderBand(headerContent, tooltip: request.method)
    }

    private func drawAnswered() {
        let outcome = StackPanel()
        outcome.spacing = 4
        let line = Grid()
        line.columnSpacing = 6
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            line.columnDefinitions.append(column)
        }
        let symbol: String = switch request.state {
        case .allowed, .answered: ConversationStyle.Glyph.check
        case .denied, .rejected: ConversationStyle.Glyph.cancel
        case .pending, .expired: ConversationStyle.Glyph.clock
        }
        line.children.append(ConversationStyle.icon(symbol, size: 13))
        let detail = request.outcomeDetail ?? ""
        let subject = [request.title, detail].filter { !$0.isEmpty }.joined(separator: " ")
        let words = ConversationStyle.text("\(request.stateTitle) · \(subject)", size: ConversationStyle.calloutSize,
                                           tone: .secondary, wraps: false)
        try? Grid.setColumn(words, 1)
        line.children.append(words)
        if let method = request.method, !method.isEmpty { try? ToolTipService.setToolTip(line, method) }
        outcome.children.append(line)
        switch request.state {
        case let .expired(message?), let .rejected(message):
            if !message.isEmpty { outcome.children.append(Self.text(message, size: ConversationStyle.captionSize, muted: true)) }
        default:
            break
        }
        content.children.append(outcome)
        switch request.form {
        case .choices, .freeText:
            let steps = request.form?.questionSteps ?? []
            let answers = request.recordedAnswers ?? sent.map { $0.answers(for: steps) }
            content.children.append(Self.answerDetail(Self.questionSummary(steps, answers: answers)))
        case let .mcpForm(form):
            let fields = StackPanel()
            fields.spacing = 12
            mcpForm(form, in: fields)
            content.children.append(Self.answerDetail(fields))
        case let .planReview(plan):
            planReview(plan, in: content)
        case nil:
            break
        }
    }

    static func answerDetail(_ detail: UIElement) -> Border {
        let bar = Border()
        bar.borderBrush = WindowsTheme.strongSeparator.brush
        bar.borderThickness = Thickness(left: 2, top: 0, right: 0, bottom: 0)
        bar.padding = Thickness(left: 10, top: 0, right: 0, bottom: 0)
        bar.child = detail
        return bar
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
            stack.spacing = 8
            if request.descriptionHeadline == nil, let description {
                stack.children.append(Self.text(description, size: ConversationStyle.calloutSize, muted: true))
            }
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
    private func providerContext(_ context: CodexRequestContextProjection, in panel: StackPanel) {
        for message in context.messages {
            panel.children.append(Self.text(message, size: ConversationStyle.calloutSize))
        }
        for field in context.fields where field.id != "command" || request.command == nil {
            let stack = StackPanel()
            stack.spacing = 4
            if let title = field.titleKey {
                stack.children.append(ConversationStyle.text(L10n.string(title), size: ConversationStyle.captionSize,
                                                             tone: .tertiary, semibold: true))
            }
            stack.children.append(Self.code(field.text))
            panel.children.append(stack)
        }
        if context.isEmpty, request.command == nil, let method = request.method {
            let line = Self.text(method, size: ConversationStyle.captionSize, muted: true)
            line.fontFamily = ConversationStyle.codeFont()
            panel.children.append(line)
        }
    }

    /// Every control that follows the form's input, as it stands now.
    private func refresh() {
        for refresher in refreshers { refresher() }
    }

    // MARK: - Questions

    /// Shows one pending question and its choices. The question's label and pager live in the panel's header band, so
    /// the body opens directly on the question's text at 14 pt semibold.
    private func questionForm(_ steps: [ConversationQuestionStep], in panel: StackPanel) -> Bool {
        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        guard let step = stepper.current else { return false }
        let isAnswerable = answersForm
        let form = StackPanel()
        form.spacing = 8
        panel.children.append(form)
        if let text = step.text, !text.isEmpty {
            form.children.append(Self.text(text, size: ConversationStyle.bodySize, semibold: true))
        }
        if step.allowsMultipleSelections {
            form.children.append(ConversationStyle.text(L10n.string("Choose one or more"), size: ConversationStyle.captionSize,
                                                        tone: .secondary))
        }
        if step.isFreeTextOnly {
            let field = answerField(step, placeholder: L10n.string("Answer"), steps: steps, isAnswerable: isAnswerable)
            try? AutomationProperties.setName(field, step.text ?? L10n.string("Answer"))
            form.children.append(field)
        } else {
            let options = StackPanel()
            options.spacing = 4
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

    /// The shared header band of a waiting request panel (`subtleFill` + hairline bottom divider) at a stable height.
    static func panelHeaderBand(_ content: FrameworkElement, tooltip: String? = nil) -> Border {
        content.minHeight = 20
        let band = Border()
        band.background = WindowsTheme.subtleFill.brush
        band.borderBrush = WindowsTheme.separator.brush
        band.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 1)
        let topRadius = max(0, WindowsTheme.panelCornerRadius - 1)
        band.cornerRadius = CornerRadius(topLeft: topRadius, topRight: topRadius, bottomRight: 0, bottomLeft: 0)
        band.padding = Thickness(left: 16, top: 8, right: 16, bottom: 8)
        band.child = content
        if let tooltip, !tooltip.isEmpty { try? ToolTipService.setToolTip(band, tooltip) }
        return band
    }

    /// The start of a waiting request's header band: the accent symbol and title.
    static func bandTitle(symbol: String, title: String, wraps: Bool = true) -> Grid {
        let row = Grid()
        row.columnSpacing = 6
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        row.children.append(ConversationStyle.icon(symbol, size: 13, brush: WindowsTheme.accent.brush))
        let label = ConversationStyle.text(title, size: ConversationStyle.calloutSize, semibold: true, wraps: wraps)
        label.verticalAlignment = .center
        try? Grid.setColumn(label, 1)
        row.children.append(label)
        return row
    }

    /// A waiting question panel's header band (`ConversationQuestionBand`): the accent question symbol, title,
    /// optional question label on the left, and the pager (`1 / N` with prev/next) on the right when multi-question.
    static func questionBand(title: String, steps: [ConversationQuestionStep], index: Int,
                             onMove: @escaping @MainActor (Int) -> Void) -> Grid {
        let stepper = ConversationQuestionStepper(steps: steps, index: index)
        let row = Grid()
        row.columnSpacing = 8
        row.minHeight = 20
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let leading = Grid()
        leading.columnSpacing = 6
        leading.verticalAlignment = .center
        let hasHeader = stepper.current?.header?.isEmpty == false
        let leadingWidths: [GridLength] = hasHeader
            ? [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto),
               GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)]
            : [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)]
        for width in leadingWidths {
            let column = ColumnDefinition()
            column.width = width
            leading.columnDefinitions.append(column)
        }
        leading.children.append(ConversationStyle.icon(ConversationStyle.Glyph.question, size: 13,
                                                       brush: WindowsTheme.accent.brush))
        let titleLabel = ConversationStyle.text(title, size: ConversationStyle.calloutSize, semibold: true, wraps: false)
        titleLabel.verticalAlignment = .center
        try? Grid.setColumn(titleLabel, 1)
        leading.children.append(titleLabel)
        if let header = stepper.current?.header, !header.isEmpty {
            let dot = ConversationStyle.text("·", size: ConversationStyle.calloutSize, tone: .tertiary,
                                             selectable: false, wraps: false)
            dot.verticalAlignment = .center
            try? Grid.setColumn(dot, 2)
            leading.children.append(dot)
            let headerLabel = ConversationStyle.text(header, size: ConversationStyle.calloutSize, tone: .secondary,
                                                     wraps: false)
            headerLabel.verticalAlignment = .center
            try? Grid.setColumn(headerLabel, 3)
            leading.children.append(headerLabel)
        }
        row.children.append(leading)
        if stepper.isStepped {
            let place = ConversationStyle.text(
                L10n.format("Question %lld of %lld", Int64(stepper.index + 1), Int64(stepper.steps.count)),
                size: ConversationStyle.captionSize, tone: .secondary, selectable: false, wraps: false
            )
            place.verticalAlignment = .center
            let pager = ConversationStyle.row([
                pagerButton(ConversationStyle.Glyph.chevronLeft, label: L10n.string("Previous question"),
                            isEnabled: stepper.hasPrevious) { onMove(stepper.index - 1) },
                place,
                pagerButton(ConversationStyle.Glyph.chevronRight, label: L10n.string("Next question"),
                            isEnabled: !stepper.isLast) { onMove(stepper.index + 1) }
            ], spacing: 2)
            pager.verticalAlignment = .center
            try? Grid.setColumn(pager, 1)
            row.children.append(pager)
        }
        return row
    }

    private static func pagerButton(_ glyph: String, label: String, isEnabled: Bool,
                                    action: @escaping @MainActor () -> Void) -> Button {
        let mark = ConversationStyle.icon(glyph, size: 10, brush: WindowsTheme.secondaryText.brush)
        mark.horizontalAlignment = .center
        let frame = Border()
        frame.width = 20
        frame.height = 20
        frame.child = mark
        let button = ConversationStyle.plainButton(frame, name: label, action: action)
        suppressFocusVisual(button)
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

    /// A radio or check box, with the provider's label above its description.
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
        let row = optionRow(isAnswerable: isAnswerable, isPicked: isPicked)
        refreshers.append { title.fontWeight = UWP.FontWeight(weight: isPicked() ? 600 : 400) }
        if step.allowsMultipleSelections {
            let box = CheckBox()
            Self.suppressFocusVisual(box)
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
        Self.suppressFocusVisual(radio)
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
        if let control = mark as? Control {
            control.minWidth = 0
            Self.suppressFocusVisual(control)
        }
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
        let row = optionRow(isAnswerable: isAnswerable, isPicked: isChosen)
        row.child = grid
        return row
    }

    /// The person's words for `step`, or a hidden field for a secret. Enter goes on, as Next does.
    private func answerField(_ step: ConversationQuestionStep, placeholder: String, steps: [ConversationQuestionStep],
                             isAnswerable: Bool) -> Control {
        let goOn = { [weak self] in self?.goOn(from: step, steps: steps) }
        if step.isSecret {
            let field = PasswordBox()
            Self.suppressFocusVisual(field)
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
        Self.suppressFocusVisual(field)
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
            let skip = ConversationStyle.grayButton(L10n.string("Skip")) { [weak self] in
                guard let self else { return }
                self.input.skip(step)
                self.goOn(from: step, steps: steps)
            }
            Self.suppressFocusVisual(skip)
            buttons.append(skip)
        }
        if stepper.isLast {
            buttons += responses.map { answerButton($0) }
        } else {
            let next = ConversationStyle.prominentButton(L10n.string("Next")) { [weak self] in
                self?.goOn(from: step, steps: steps)
            }
            Self.suppressFocusVisual(next)
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
    static func questionSummary(_ steps: [ConversationQuestionStep], answers: [String: ConversationQuestionAnswer]?) -> StackPanel {
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
        return list
    }

    // MARK: - Plan review

    /// The plan exactly as the provider wrote it, and while it waits, what to change if planning goes on.
    private func planReview(_ plan: String, in panel: StackPanel) {
        let box = Border()
        box.background = WindowsTheme.subtleFill.brush
        box.cornerRadius = ConversationStyle.corners(8)
        box.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        box.child = MarkdownView.element(plan)
        try? AutomationProperties.setName(box, L10n.string("Proposed plan"))
        panel.children.append(box)
        guard answersForm else { return }
        let reason = TextBox()
        Self.suppressFocusVisual(reason)
        reason.placeholderText = L10n.string("Tell Claude what to change")
        reason.text = input.reason
        reason.textWrapping = .wrap
        try? AutomationProperties.setName(reason, L10n.string("Tell Claude what to change"))
        reason.textChanged.addHandler { [weak self, weak reason] _, _ in
            guard let self, let reason else { return }
            self.input.reason = reason.text
        }
        fields.append(reason)
        panel.children.append(reason)
    }

    // MARK: - MCP form

    /// Each field under the server's title and description, with what it takes and, once something is entered,
    /// why it cannot be sent yet. An answered form shows what was sent.
    private func mcpForm(_ form: CodexMCPElicitationForm, in panel: StackPanel) {
        for field in form.fields {
            panel.children.append(form.recorded != nil ? sentRow(form, field) : fieldView(form, field))
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
            Self.suppressFocusVisual(box)
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
            Self.suppressFocusVisual(box)
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
                Self.suppressFocusVisual(box)
                box.content = option.title
                box.isEnabled = isAnswerable
                box.click.addHandler { _, _ in pick() }
                refreshers.append { box.isChecked = isPicked() }
                panel.children.append(box)
            } else {
                let radio = RadioButton()
                Self.suppressFocusVisual(radio)
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
        let controls = ConversationRequestResponses.controls(responses).map { control -> FrameworkElement in
            switch control {
            case let .answer(response): answerButton(response)
            case let .widerAllows(wider): widerAllowsButton(wider)
            }
        }
        return Self.buttonRow(controls)
    }

    /// The narrowest broad allow on the face, and every choice with its scope in the native split menu.
    private func widerAllowsButton(_ wider: [ConversationRequestResponse]) -> SplitButton {
        let first = wider[0]
        let button = SplitButton()
        Self.suppressFocusVisual(button)
        let title = ConversationAllowScope(first)?.name ?? first.title
        button.content = title
        button.cornerRadius = ConversationStyle.corners(6)
        button.click.addHandler { [weak self] _, _ in self?.send(first) }
        try? AutomationProperties.setName(button, title)
        try? AutomationProperties.setHelpText(button, L10n.string("More allow options"))
        try? ToolTipService.setToolTip(button, first.title)
        let menu = MenuFlyout()
        for response in wider {
            let scope = ConversationAllowScope(response)
            let text = scope.map { $0.name + "\n" + $0.scope } ?? response.title
            let item = ComposerParts.menuItem(text) { [weak self] in self?.send(response) }
            try? ToolTipService.setToolTip(item, response.title)
            refreshers.append { [unowned self] in
                item.isEnabled = self.request.route(for: response, input: self.input) != nil
            }
            menu.items.append(item)
        }
        button.flyout = menu
        refreshers.append { [unowned self] in
            button.isEnabled = wider.contains { self.request.route(for: $0, input: self.input) != nil }
        }
        return button
    }

    /// An answer, on only while the form can be sent with it: the prominent one in Yardlet's accent, the others gray.
    private func answerButton(_ response: ConversationRequestResponse) -> Button {
        let send: @MainActor () -> Void = { [weak self] in self?.send(response) }
        let button = response.role == .primary
            ? ConversationStyle.prominentButton(response.title, action: send)
            : ConversationStyle.grayButton(response.title, action: send)
        Self.suppressFocusVisual(button)
        if let key = composerKey(for: response) {
            let words = TextBlock()
            words.text = response.title
            words.verticalAlignment = .center
            let cap = Border()
            cap.cornerRadius = ConversationStyle.corners(4)
            cap.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
            let keyColor = response.role == .primary ? ConversationStyle.prominentForeground : WindowsTheme.secondaryText
            cap.borderBrush = keyColor.brush
            cap.padding = Thickness(left: 4, top: 0, right: 4, bottom: 0)
            cap.verticalAlignment = .center
            cap.opacity = 0.85
            let keyText = TextBlock()
            keyText.text = key
            keyText.fontSize = ConversationStyle.captionSize
            keyText.foreground = keyColor.brush
            cap.child = keyText
            button.content = ConversationStyle.row([words, cap])
            try? ToolTipService.setToolTip(button, "\(response.title) (\(key))")
        }
        refreshers.append { [unowned self] in button.isEnabled = self.request.route(for: response, input: self.input) != nil }
        return button
    }

    /// The two keys the empty Windows task composer can give, only on the request they answer.
    private func composerKey(for response: ConversationRequestResponse) -> String? {
        guard answeredByComposerKeys,
              let pending = NotificationApprovalProjection.pendingRequest(for: request) else { return nil }
        if response.route == pending.allowOnce { return "Enter" }
        if response.route == pending.deny { return "Esc" }
        return nil
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

    /// Suppresses Windows' heavy focus ring on request card controls; selection fills, carets and keycaps show focus.
    static func suppressFocusVisual(_ control: Control) {
        control.useSystemFocusVisuals = false
    }

    /// Radio buttons answer one question or field of this request together.
    private func groupName(_ id: String) -> String { "\(request.id)\n\(id)" }

    static func text(_ string: String, size: Double = ConversationStyle.bodySize, semibold: Bool = false,
                     muted: Bool = false) -> TextBlock {
        ConversationStyle.text(string, size: size, tone: muted ? .secondary : .primary, semibold: semibold)
    }

    private static func code(_ string: String) -> TextBlock {
        let block = ConversationStyle.text(string, size: ConversationStyle.codeSize)
        block.fontFamily = ConversationStyle.codeFont()
        return block
    }

    /// The card keeps the row alive in its refresher. The native pointer event's generic sender
    /// need not be the same Swift wrapper as the border that paints the option.
    private func optionRow(isAnswerable: Bool, isPicked: @escaping () -> Bool) -> Border {
        Self.makeOptionRow(isAnswerable: isAnswerable, isPicked: isPicked, refreshers: &refreshers)
    }

    static func makeOptionRow(isAnswerable: Bool, isPicked: @escaping () -> Bool,
                              refreshers: inout [() -> Void]) -> Border {
        let row = Border()
        row.cornerRadius = ConversationStyle.corners(8)
        row.padding = Thickness(left: 12, top: 6, right: 12, bottom: 6)
        var hovered = false
        var picked = false
        func paint(_ target: Border) {
            let idle = hovered && isAnswerable ? WindowsTheme.hoverFill : ConversationStyle.clear
            target.background = (picked ? WindowsTheme.selectedFill : idle).brush
        }
        row.pointerEntered.addHandler { [weak row] _, _ in
            guard let row else { return }
            hovered = true
            paint(row)
        }
        row.pointerExited.addHandler { [weak row] _, _ in
            guard let row else { return }
            hovered = false
            paint(row)
        }
        refreshers.append {
            picked = isPicked()
            paint(row)
        }
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
    static func buttonRow(_ buttons: [FrameworkElement]) -> Grid {
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

/// The questions a Codex turn asks (`request_user_input_async`), on the same waiting panel and header band as
/// `RequestCard` (matching the Mac's `CodexQuestionOptions`). Once answered, reads as each question's answer under
/// the answered request's 2 pt rule.
@MainActor
final class CodexQuestionCard {
    let view = Border()
    private let content = StackPanel()
    private let cardID = UUID().uuidString
    private var questions: [CodexAsyncQuestion]
    private var answers: [String: ConversationQuestionAnswer]?
    private var onAnswer: (@MainActor (String) -> Void)?
    private var input = ConversationRequestFormInput()
    private var questionIndex = 0
    private var sent: ConversationRequestFormInput?
    private var customChosen: Set<String> = []
    private var host: StackPanel?
    private var refreshers: [() -> Void] = []
    private var fields: [Control] = []

    init(questions: [CodexAsyncQuestion], answers: [String: ConversationQuestionAnswer]? = nil,
         onAnswer: (@MainActor (String) -> Void)? = nil) {
        self.questions = questions
        self.answers = answers
        self.onAnswer = onAnswer
        if answers == nil { input.preselect(questions.map(ConversationQuestionStep.init)) }
        view.child = content
        draw()
    }

    func update(questions: [CodexAsyncQuestion], answers: [String: ConversationQuestionAnswer]?,
                onAnswer: (@MainActor (String) -> Void)?) {
        let canAnswerChanged = (self.onAnswer == nil) != (onAnswer == nil)
        self.onAnswer = onAnswer
        guard questions != self.questions || answers != self.answers || canAnswerChanged else { return }
        if questions != self.questions {
            self.questions = questions
            sent = nil
            questionIndex = 0
            customChosen = []
            input = ConversationRequestFormInput()
            if answers == nil { input.preselect(questions.map(ConversationQuestionStep.init)) }
        }
        self.answers = answers
        draw()
    }

    func place(in panel: StackPanel) {
        if let host {
            var index: UInt32 = 0
            if host.children.indexOf(view, &index) { host.children.removeAt(index) }
        }
        panel.children.append(view)
        host = panel
    }

    private var steps: [ConversationQuestionStep] { questions.map(ConversationQuestionStep.init) }

    private func draw() {
        content.children.clear()
        refreshers = []
        fields = []
        let steps = self.steps
        if let answered = answers ?? sent.map({ $0.answers(for: steps) }) {
            content.spacing = 0
            view.background = nil
            view.borderBrush = nil
            view.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
            view.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
            content.children.append(RequestCard.answerDetail(RequestCard.questionSummary(steps, answers: answered)))
            return
        }

        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        guard let step = stepper.current else { return }
        content.spacing = 0
        view.background = WindowsTheme.requestPanelFill.brush
        view.borderBrush = WindowsTheme.strongSeparator.brush
        view.cornerRadius = ConversationStyle.corners(WindowsTheme.panelCornerRadius)
        view.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        view.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)

        let band = RequestCard.questionBand(title: L10n.string("Questions"), steps: steps, index: questionIndex) { [weak self] next in
            self?.move(to: next)
        }
        content.children.append(RequestCard.panelHeaderBand(band))

        let body = StackPanel()
        body.spacing = 12
        body.margin = Thickness(left: 16, top: 16, right: 16, bottom: 16)
        content.children.append(body)

        let isAnswerable = onAnswer != nil
        let form = StackPanel()
        form.spacing = 8
        body.children.append(form)
        if let text = step.text, !text.isEmpty {
            form.children.append(RequestCard.text(text, size: ConversationStyle.bodySize, semibold: true))
        }
        if step.isFreeTextOnly {
            let field = answerField(step, placeholder: L10n.string("Answer"), steps: steps, isAnswerable: isAnswerable)
            try? AutomationProperties.setName(field, step.text ?? L10n.string("Answer"))
            form.children.append(field)
        } else {
            let options = StackPanel()
            options.spacing = 4
            for option in step.options { options.children.append(optionControl(step, option, isAnswerable: isAnswerable)) }
            if step.allowsCustomAnswer {
                options.children.append(customAnswerRow(step, steps: steps, isAnswerable: isAnswerable))
            }
            form.children.append(options)
        }
        if isAnswerable {
            form.children.append(stepButtons(step, stepper: stepper, steps: steps))
        }
        refresh()
    }

    private func optionControl(_ step: ConversationQuestionStep, _ option: PermissionQuestionOption,
                               isAnswerable: Bool) -> UIElement {
        let title = ConversationStyle.text(option.label, size: ConversationStyle.calloutSize, selectable: false)
        let isPicked = { [unowned self] in self.input.answer(for: step)?.options.contains(option.label) == true }
        let row = RequestCard.makeOptionRow(isAnswerable: isAnswerable, isPicked: isPicked, refreshers: &refreshers)
        refreshers.append { title.fontWeight = UWP.FontWeight(weight: isPicked() ? 600 : 400) }
        let radio = RadioButton()
        RequestCard.suppressFocusVisual(radio)
        radio.content = title
        radio.groupName = "\(cardID)\n\(step.id)"
        radio.isEnabled = isAnswerable
        radio.minWidth = 0
        radio.horizontalAlignment = .stretch
        try? AutomationProperties.setName(radio, option.label)
        radio.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.input.toggle(option.label, for: step)
            self.customChosen.remove(step.id)
            self.refresh()
        }
        refreshers.append { radio.isChecked = isPicked() }
        row.child = radio
        return row
    }

    private func customAnswerRow(_ step: ConversationQuestionStep, steps: [ConversationQuestionStep],
                                 isAnswerable: Bool) -> UIElement {
        let field = answerField(step, placeholder: L10n.string("Type your own answer"), steps: steps,
                                isAnswerable: isAnswerable)
        try? AutomationProperties.setName(field, L10n.string("Other"))
        let isChosen = { [unowned self] in
            self.input.isCustomAnswerChosen(for: step)
                || (self.customChosen.contains(step.id) && self.input.answer(for: step) == nil)
        }
        let radio = RadioButton()
        RequestCard.suppressFocusVisual(radio)
        radio.groupName = "\(cardID)\n\(step.id)"
        radio.isEnabled = isAnswerable
        radio.minWidth = 0
        try? AutomationProperties.setName(radio, L10n.string("Other"))
        radio.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.input.chooseCustomAnswer(for: step)
            self.customChosen.insert(step.id)
            self.refresh()
            _ = try? field.focus(.programmatic)
        }
        refreshers.append { radio.isChecked = isChosen() }
        let grid = Grid()
        let markColumn = ColumnDefinition()
        markColumn.width = GridLength(value: 0, gridUnitType: .auto)
        let fieldColumn = ColumnDefinition()
        fieldColumn.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(markColumn)
        grid.columnDefinitions.append(fieldColumn)
        grid.children.append(radio)
        try? Grid.setColumn(field, 1)
        grid.children.append(field)
        let row = RequestCard.makeOptionRow(isAnswerable: isAnswerable, isPicked: isChosen, refreshers: &refreshers)
        row.child = grid
        return row
    }

    private func answerField(_ step: ConversationQuestionStep, placeholder: String, steps: [ConversationQuestionStep],
                             isAnswerable: Bool) -> Control {
        let field = TextBox()
        RequestCard.suppressFocusVisual(field)
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
        field.keyDown.addHandler { [weak self] _, args in
            guard let args, args.key == .enter else { return }
            args.handled = true
            self?.goOn(from: step, steps: steps)
        }
        fields.append(field)
        return field
    }

    private func stepButtons(_ step: ConversationQuestionStep, stepper: ConversationQuestionStepper,
                             steps: [ConversationQuestionStep]) -> UIElement {
        var buttons: [Button] = []
        if step.canSkip {
            let skip = ConversationStyle.grayButton(L10n.string("Skip")) { [weak self] in
                guard let self else { return }
                self.input.skip(step)
                self.goOn(from: step, steps: steps)
            }
            RequestCard.suppressFocusVisual(skip)
            buttons.append(skip)
        }
        if stepper.isLast {
            let send = ConversationStyle.prominentButton(L10n.string("Send")) { [weak self] in self?.submit() }
            RequestCard.suppressFocusVisual(send)
            refreshers.append { [unowned self] in
                send.isEnabled = self.onAnswer != nil && steps.allSatisfy(self.input.isSettled)
            }
            buttons.append(send)
        } else {
            let next = ConversationStyle.prominentButton(L10n.string("Next")) { [weak self] in
                self?.goOn(from: step, steps: steps)
            }
            RequestCard.suppressFocusVisual(next)
            refreshers.append { [unowned self] in next.isEnabled = self.input.isSettled(step) }
            buttons.append(next)
        }
        return RequestCard.buttonRow(buttons)
    }

    private func move(to index: Int) {
        questionIndex = index
        draw()
    }

    private func goOn(from step: ConversationQuestionStep, steps: [ConversationQuestionStep]) {
        guard onAnswer != nil, input.isSettled(step) else { return }
        let stepper = ConversationQuestionStepper(steps: steps, index: questionIndex)
        if !stepper.isLast {
            move(to: stepper.index + 1)
        } else if let waiting = stepper.firstUnsettled(input) {
            move(to: waiting)
        } else {
            submit()
        }
    }

    private func submit() {
        let steps = self.steps
        guard let onAnswer, steps.allSatisfy(input.isSettled) else { return }
        sent = input
        let reply = CodexAsyncQuestionReply.message(questions.compactMap { question in
            guard let value = input.answer(for: ConversationQuestionStep(question))?.values.first else { return nil }
            return CodexAsyncQuestionReply.Answer(questionItemID: question.itemID, question: question.title, answer: value)
        })
        draw()
        onAnswer(reply)
    }

    private func refresh() {
        for refresher in refreshers { refresher() }
    }
}
