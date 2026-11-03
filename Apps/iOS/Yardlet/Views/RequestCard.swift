import SwiftUI
import YardletRemote

/// A request the task waits on, answered with the same choices the Mac's card gives (docs/REMOTE_PROTOCOL.md §6.5,
/// §15.2–§15.4, §15.13, §15.18, §15.19): an approval, a question, a plan to review, an MCP form or a browser tab.
struct RequestCard: View {
    let item: RemoteItem
    let context: ItemContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(heading, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            switch item.requestKind {
            case "question" where item.questionSteps?.isEmpty == false && answers:
                QuestionForm(item: item, context: context)
            case "form" where item.formFields?.isEmpty == false && item.choices?.isEmpty == false:
                FieldsForm(item: item, context: context)
            case "form" where item.questionSteps?.isEmpty == false && answers:
                QuestionForm(item: item, context: context)
            case "planReview":
                PlanReview(item: item, context: context)
            case "browserHandoff":
                HandoffAnswer(item: item, context: context)
            default:
                ApprovalAnswer(item: item, context: context)
            }
            if item.moreOnMac == true, let note = macNote {
                Label(note, systemImage: "desktopcomputer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The phone may answer the questions itself (§15.2, §15.19).
    private var answers: Bool {
        let options = item.options ?? []
        return options.contains("answer") || options.contains("answerSecret")
    }

    /// What only the Mac's card does. A card with `choices` gives every answer here already (§15.19), so its
    /// note is for phones that do not read them.
    private var macNote: String? {
        if item.choices?.isEmpty == false && (item.requestKind == "approval" || item.formFields?.isEmpty == false) {
            return nil
        }
        if let note = item.macNote, !note.isEmpty { return note }
        return String(localized: "More answers are on your Mac.")
    }

    private var heading: String {
        switch item.requestKind {
        case "question": String(localized: "Question")
        case "planReview": String(localized: "Plan ready for review")
        case "form": String(localized: "Input requested")
        case "browserHandoff": String(localized: "Browser tab waiting")
        default: item.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Approval requested")
        }
    }

    private var symbol: String {
        switch item.requestKind {
        case "question": "questionmark.bubble"
        case "planReview": "list.bullet.clipboard"
        case "form": "square.and.pencil"
        case "browserHandoff": "safari"
        default: "hand.raised"
        }
    }
}

// MARK: - Approval

private struct ApprovalAnswer: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var standing: RemoteChoice?
    @State private var noteFor: RemoteChoice?
    @State private var isAskingNote = false
    @State private var note = ""
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = item.command, !command.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let choices = item.choices, !choices.isEmpty {
                ForEach(orderedChoices(choices), id: \.id) { choice in
                    button(choice.title, role: choice.role) {
                        if choice.standing == true { standing = choice } else { choose(choice, note: nil) }
                    }
                }
                if let deny = choices.first(where: { $0.role == "destructive" }) {
                    Button("Deny and Say What to Do Instead…") {
                        noteFor = deny
                        note = ""
                        isAskingNote = true
                    }
                    .font(.footnote)
                }
            } else {
                legacyButtons
            }
        }
        .disabled(isSending || !context.session.isConnected)
        .confirmationDialog(standing?.title ?? "", isPresented: Binding(get: { standing != nil },
                                                                        set: { if !$0 { standing = nil } }),
                            titleVisibility: .visible, presenting: standing) { choice in
            Button(choice.title) { choose(choice, note: nil) }
        } message: { _ in
            Text("This answer leaves a rule on your Mac beyond this task.")
        }
        .alert("What should it do instead?", isPresented: $isAskingNote, presenting: noteFor) { choice in
            TextField("Run only the unit tests", text: $note, axis: .vertical)
            Button("Deny") { choose(choice, note: note.isEmpty ? nil : note) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The primary answer last, nearest the thumb; the card's own order otherwise.
    private func orderedChoices(_ choices: [RemoteChoice]) -> [RemoteChoice] {
        choices.filter { $0.role != "primary" } + choices.filter { $0.role == "primary" }
    }

    @ViewBuilder
    private var legacyButtons: some View {
        let options = item.options ?? []
        if options.contains("deny") {
            button(item.optionTitles?["deny"] ?? String(localized: "Deny"), role: "destructive") { answer(.deny) }
        }
        if options.contains("allowForSession") {
            button(item.optionTitles?["allowForSession"] ?? String(localized: "Allow for This Session"), role: "secondary") {
                answer(.allowForSession)
            }
        }
        if options.contains("allowOnce") {
            button(item.optionTitles?["allowOnce"] ?? String(localized: "Allow Once"), role: "primary") { answer(.allowOnce) }
        }
    }

    private func button(_ title: String, role: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(CardButtonStyle(role: role))
    }

    private func choose(_ choice: RemoteChoice, note: String?) {
        guard let requestID = item.requestId else { return }
        isSending = true
        Task {
            await context.session.perform(.chooseAnswer(taskID: context.taskID, requestID: requestID, choice: choice.id,
                                                        note: note))
            isSending = false
        }
    }

    private func answer(_ answer: RemoteApprovalAnswer) {
        guard let requestID = item.requestId else { return }
        isSending = true
        Task {
            await context.session.perform(.answerApproval(taskID: context.taskID, requestID: requestID, answer: answer))
            isSending = false
        }
    }
}

/// A card's answer: the primary one filled, the rest tinted.
struct CardButtonStyle: ButtonStyle {
    let role: String
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(role == "primary" ? .semibold : .regular))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
    }

    private var foreground: Color {
        switch role {
        case "primary": Color(.systemBackground)
        case "destructive": .red
        default: .primary
        }
    }

    private var background: Color {
        role == "primary" ? Color.primary : Color(.tertiarySystemFill)
    }
}

// MARK: - Questions

private struct QuestionForm: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var picked: [String: Set<String>] = [:]
    @State private var written: [String: String] = [:]
    @State private var skipped: Set<String> = []
    @State private var isSending = false

    private var steps: [RemoteQuestionStep] { item.questionSteps ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(steps, id: \.id) { step in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = step.header, !header.isEmpty {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    if let text = step.text, !text.isEmpty {
                        Text(MarkdownView.inline(text)).font(.body).textSelection(.enabled)
                    }
                    ForEach(step.options, id: \.label) { option in
                        optionRow(option, step: step)
                    }
                    if step.custom {
                        Group {
                            if step.secret == true {
                                SecureField("Answer", text: binding(step.id))
                            } else {
                                TextField(step.options.isEmpty ? "Answer" : "Other answer", text: binding(step.id),
                                          axis: .vertical)
                            }
                        }
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if step.skippable {
                        Toggle("Skip this question", isOn: Binding(
                            get: { skipped.contains(step.id) },
                            set: { if $0 { skipped.insert(step.id) } else { skipped.remove(step.id) } }))
                            .font(.footnote)
                    }
                }
            }
            Button {
                submit()
            } label: {
                Text("Send Answer").frame(maxWidth: .infinity)
            }
            .buttonStyle(CardButtonStyle(role: "primary"))
            .disabled(!isComplete || isSending || !context.session.isConnected)
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { written[id] ?? "" }, set: { written[id] = $0 })
    }

    private func optionRow(_ option: RemoteQuestionStep.Option, step: RemoteQuestionStep) -> some View {
        let isPicked = picked[step.id, default: []].contains(option.label)
        return Button {
            var set = picked[step.id, default: []]
            if step.multiple {
                if isPicked { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = isPicked ? [] : [option.label]
            }
            picked[step.id] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: step.multiple ? (isPicked ? "checkmark.square.fill" : "square")
                      : (isPicked ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isComplete: Bool {
        steps.allSatisfy { step in
            skipped.contains(step.id) || !picked[step.id, default: []].isEmpty
                || (step.custom && !(written[step.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        guard let requestID = item.requestId else { return }
        let answers = steps.map { step -> RemoteQuestionAnswer in
            if skipped.contains(step.id) { return RemoteQuestionAnswer(questionId: step.id, skipped: true) }
            let options = step.options.map(\.label).filter { picked[step.id, default: []].contains($0) }
            let text = step.custom ? (written[step.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return RemoteQuestionAnswer(questionId: step.id, options: options.isEmpty ? nil : options,
                                        text: text.isEmpty ? nil : text)
        }
        isSending = true
        Task {
            let sent = await context.session.perform(.answerQuestion(taskID: context.taskID, requestID: requestID,
                                                                     answers: answers))
            isSending = false
            // A secret answer is kept only until it is sent (§15.19).
            if sent { written = [:] }
        }
    }
}

// MARK: - Plan review

private struct PlanReview: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var isExpanded = false
    @State private var isAskingReason = false
    @State private var reason = ""
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = item.text, !text.isEmpty {
                MarkdownView(text: text, font: .subheadline)
                    .frame(maxHeight: isExpanded ? nil : 220, alignment: .top)
                    .clipped()
                Button(isExpanded ? "Show Less" : "Show Whole Plan") { isExpanded.toggle() }
                    .font(.footnote)
            }
            if (item.options ?? []).contains("keepPlanning") {
                Button {
                    reason = ""
                    isAskingReason = true
                } label: {
                    Text("Keep Planning…").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(role: "secondary"))
            }
            if (item.options ?? []).contains("approvePlan") {
                Button {
                    review(.approve, reason: nil)
                } label: {
                    Text("Approve Plan").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(role: "primary"))
            }
        }
        .disabled(isSending || !context.session.isConnected)
        .alert("What should change?", isPresented: $isAskingReason) {
            TextField("Split the migration first", text: $reason, axis: .vertical)
            Button("Keep Planning") { review(.keepPlanning, reason: reason.isEmpty ? nil : reason) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func review(_ decision: RemotePlanDecision, reason: String?) {
        guard let requestID = item.requestId else { return }
        isSending = true
        Task {
            await context.session.perform(.reviewPlan(taskID: context.taskID, requestID: requestID, decision: decision,
                                                      reason: reason))
            isSending = false
        }
    }
}

// MARK: - Browser tab

private struct HandoffAnswer: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let site = item.title, !site.isEmpty {
                Text(site).font(.body.weight(.medium))
            }
            if let reason = item.detail, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("The tab is open on your Mac. Choose I'm Done once you finished the step there or elsewhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    answer(.decline)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(role: "destructive"))
                Button {
                    answer(.done)
                } label: {
                    Text("I'm Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(role: "primary"))
            }
        }
        .disabled(isSending || !context.session.isConnected)
    }

    private func answer(_ answer: RemoteHandoffAnswer) {
        guard let requestID = item.requestId else { return }
        isSending = true
        Task {
            await context.session.perform(.answerHandoff(taskID: context.taskID, requestID: requestID, answer: answer))
            isSending = false
        }
    }
}

// MARK: - MCP form

private struct FieldsForm: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var values: [String: RemoteFormValue] = [:]
    @State private var isSending = false

    private var fields: [RemoteFormField] { item.formFields ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(fields, id: \.id) { field in
                fieldView(field)
            }
            ForEach(orderedChoices, id: \.id) { choice in
                Button {
                    send(choice)
                } label: {
                    Text(choice.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(role: choice.role))
            }
        }
        .disabled(isSending || !context.session.isConnected)
        .onAppear {
            for field in fields where values[field.id] == nil {
                if let value = field.default { values[field.id] = value }
            }
        }
    }

    private var orderedChoices: [RemoteChoice] {
        let choices = item.choices ?? []
        return choices.filter { $0.role != "primary" } + choices.filter { $0.role == "primary" }
    }

    @ViewBuilder
    private func fieldView(_ field: RemoteFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.required == true ? "\(field.label) *" : field.label).font(.subheadline.weight(.medium))
            if let description = field.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            switch field.type {
            case "boolean":
                Toggle(field.label, isOn: Binding(get: { if case let .flag(on)? = values[field.id] { on } else { false } },
                                                  set: { values[field.id] = .flag($0) }))
                    .labelsHidden()
            case "choice":
                Picker(field.label, selection: Binding(
                    get: { if case let .text(value)? = values[field.id] { value } else { "" } },
                    set: { values[field.id] = .text($0) })) {
                    Text("Choose").tag("")
                    ForEach(field.options ?? [], id: \.value) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.menu)
            case "choices":
                ForEach(field.options ?? [], id: \.value) { option in
                    let list: [String] = if case let .list(list)? = values[field.id] { list } else { [] }
                    Toggle(option.title, isOn: Binding(
                        get: { list.contains(option.value) },
                        set: { on in
                            var next = list.filter { $0 != option.value }
                            if on { next.append(option.value) }
                            values[field.id] = .list(next)
                        }))
                }
            case "number", "integer":
                TextField(field.label, text: Binding(
                    get: { if case let .number(number)? = values[field.id] { number.formatted() } else { "" } },
                    set: { text in
                        if let number = Double(text) { values[field.id] = .number(number) } else { values[field.id] = nil }
                    }))
                    .keyboardType(field.type == "integer" ? .numberPad : .decimalPad)
                    .textFieldStyle(.roundedBorder)
            default:
                TextField(field.label, text: Binding(
                    get: { if case let .text(text)? = values[field.id] { text } else { "" } },
                    set: { values[field.id] = $0.isEmpty ? nil : .text($0) }), axis: .vertical)
                    .textInputAutocapitalization(field.format == "email" || field.format == "uri" ? .never : .sentences)
                    .keyboardType(field.format == "email" ? .emailAddress : field.format == "uri" ? .URL : .default)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func send(_ choice: RemoteChoice) {
        guard let requestID = item.requestId else { return }
        isSending = true
        let values = choice.role == "primary" ? values : [:]
        Task {
            await context.session.perform(.chooseAnswer(taskID: context.taskID, requestID: requestID, choice: choice.id,
                                                        values: values))
            isSending = false
        }
    }
}
