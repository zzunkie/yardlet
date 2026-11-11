import Crypto
import Foundation
import YardletRemote

/// One turn another Mac's Yardlet sent (docs/REMOTE_PROTOCOL.md §6), read back into the conversation model
/// the app draws for every harness (`ConversationPresentation`), so the same timeline, messages, lines and
/// request cards draw it. The host already laid the turn out in its order; this keeps that order and only
/// sorts its parts into what was sent, the notices, the work and answers, the plan, the outcome and the
/// requests still waiting. Lines keep the host's words (`ConversationTool.Kind.worded`) and read their output
/// and changes when opened (§15.8). Each request offers the answers the host's card gives (§15.19), sent
/// back by the routes `RemoteConversationActions` reads.
///
/// What a host sends in full detail (§15.24) becomes the item the host's own card draws: a sent message's
/// pictures, a subagent, a created schedule, a compaction, a provider's notice and a plan limit's windows. A
/// proposed plan and a notice are drawn by the card a Codex item has, so one is made from the host's fields.
enum RemoteTurnProjection {
    /// Answers carried by a provider option, by the prefix of its ID.
    enum Route {
        static let choice = "choice:"
        static let answer = "answer:"
        static let handoff = "handoff:"
        /// Shows the handed tab in the window's browser panel (§15.25); nothing goes to the host.
        static let showTab = "showTab:"
        /// The kind of an option whose answer leaves a rule behind (`RemoteChoice.standing`).
        static let standing = "standing"
    }

    static func turn(_ items: [RemoteItem], turnID: String, details: [String: RemoteItemDetail],
                     hostName: String) -> ConversationTurn {
        var turn = ConversationTurn(id: turnID, status: .completed, timing: ConversationTurnTiming())
        let header = items.firstIndex { $0.kind == .turn }
        var flow: [ConversationItem] = []
        var lastOutcome: Int?
        for (index, item) in items.enumerated() {
            let isBeforeHeader = header.map { index < $0 } ?? false
            switch item.kind {
            case .turn:
                apply(header: item, to: &turn)
            case .user where item.queued == true:
                // Drawn as the queue's chips above the composer, as on the Mac.
                continue
            case .user where isBeforeHeader:
                turn.prompt.append(message(item))
            case .notice where isBeforeHeader:
                turn.notices.append(card(item) ?? line(item, details: details))
            case .plan:
                turn.plan = plan(item)
            case .error where item.inWork != true:
                lastOutcome = index
            case .approval where item.status == "pending":
                turn.requests.append(request(item, hostName: hostName))
            default:
                if let converted = self.item(item, details: details, hostName: hostName) { flow.append(converted) }
            }
        }
        if let lastOutcome { turn.outcome = outcome(items[lastOutcome]) }
        // What the host's turn offers (§15.23): the edit of the message that opened it, and its fork.
        let offered = header.flatMap { items[$0].options } ?? []
        if offered.contains("edit"), let request = turn.prompt.last(where: \.isPersonMessage),
           case let .userMessage(text, _) = request.kind {
            turn.actions.editLatest = ConversationMessageTarget(entryID: uuid(request.id), text: text)
        }
        turn.actions.canFork = offered.contains("fork")
        turn.actions.canRetry = offered.contains("retry")
        if let header {
            if let answered = items[header].answeredQuestions {
                turn.actions.answeredQuestions = ConversationAnsweredAsyncQuestions(
                    questions: answered.map { CodexAsyncQuestion(title: $0.title, options: $0.options, itemID: $0.itemID) },
                    answers: Dictionary(answered.compactMap { question in
                        guard question.answerOptions != nil || question.customAnswer != nil else { return nil }
                        return (question.itemID, ConversationQuestionAnswer(options: question.answerOptions ?? [], custom: question.customAnswer))
                    }, uniquingKeysWith: { _, newer in newer }))
            }
            turn.actions.planToImplement = items[header].planToImplement
            turn.actions.questionsToAnswer = (items[header].nextQuestions ?? []).map {
                CodexAsyncQuestion(title: $0.title, options: $0.options, itemID: $0.itemID)
            }
        }
        if offered.contains("restoreFiles"), let sent = turn.prompt.last(where: \.isPersonMessage),
           case let .userMessage(text, _) = sent.kind {
            turn.actions.restoreFiles = ConversationMessageTarget(entryID: uuid(sent.id), text: text)
        }
        (turn.work, turn.answers) = ConversationTurnLayout.arrange(flow)
        turn.hasWorkDetails = !turn.work.isEmpty || turn.plan != nil
        turn.showsHeader = header != nil && (turn.hasWorkDetails || turn.timing.durationMilliseconds != nil)
        return turn
    }

    // MARK: - Header

    private static func apply(header item: RemoteItem, to turn: inout ConversationTurn) {
        turn.status = switch item.status {
        case "running": .running
        case "completed": .completed
        case "interrupted": .interrupted
        case "failed": .failed
        default: .unknown(item.status)
        }
        turn.timing = ConversationTurnTiming(
            startedAt: item.startedAt.map(date), completedAt: item.completedAt.map(date),
            durationMilliseconds: item.durationMs, isApproximate: item.approximate == true)
        guard turn.status == .running else { return }
        switch item.progress {
        case "thinking": turn.progress = .thinking
        case "reconnecting": turn.progress = .reconnecting(item.progressText ?? "")
        default: turn.progress = .none
        }
    }

    // MARK: - Items

    static func item(_ item: RemoteItem, details: [String: RemoteItemDetail], hostName: String) -> ConversationItem? {
        if let body = bodyItem(item) { return body }
        switch item.kind {
        case .user:
            return message(item)
        case .assistant:
            let text = item.text ?? ""
            let streaming = item.streaming == true
            if item.role == "proposedPlan" { return proposedPlan(item, text: text, isWriting: streaming) }
            let kind: ConversationItemKind = switch item.role {
            case "commentary": .commentary(text: text, isStreaming: streaming)
            default: .answer(text: text, isStreaming: streaming)
            }
            var result = ConversationItem(id: item.id, kind: kind, phase: streaming ? .running : .completed,
                                    source: source(item, .assistant(text: text, isStreaming: streaming)))
            result.isSentWhileWorking = item.sentWhileWorking == true
            result.isUnmarkedAnswer = item.unmarkedAnswer == true
            return result
        case .activity where item.activity == "reasoning":
            var result = ConversationItem(id: item.id, kind: .reasoning(summary: item.detail, detail: item.body?.reasoning, isStreaming: item.status == "running"),
                                    phase: phase(item.status), source: source(item, .reasoning(text: item.detail ?? "", isStreaming: false)))
            result.copyDetails = bodyCopyText(item)
            return result
        case .activity where item.activity == "taskSuggestion" && item.suggestionId != nil:
            return taskSuggestion(item)
        case .activity, .notice:
            return card(item) ?? line(item, details: details)
        case .approval:
            return ConversationItem(id: item.id, kind: .request(request(item, hostName: hostName)), phase: .completed,
                                    source: source(item, .plan("")))
        case .error:
            return ConversationItem(id: item.id, kind: .outcome(outcome(item)), phase: .completed,
                                    source: source(item, .error(message: item.message ?? "", recoverable: item.recoverable == true)))
        case .plan, .turn:
            return nil
        }
    }

    /// A sent message: the person's, or one someone else sent as the host draws it (§15.24): another task's under its
    /// name, a background command's notice, a schedule's prompt.
    private static func message(_ item: RemoteItem) -> ConversationItem {
        if let body = bodyItem(item) { return body }
        let text = item.text ?? ""
        let record = source(item, .user(text: text))
        if item.scheduled == true {
            var claude: ClaudeScheduledPrompt.Kind?
            if item.sender?.kind == "claudeSchedule" { claude = item.sender?.name.map { .task(name: $0) } ?? .checkIn }
            let message = ConversationScheduledTaskMessage(instructions: text, automationID: nil, currentTimeISO: "",
                                                           claudeSchedule: claude)
            return ConversationItem(id: item.id, kind: .scheduledTaskMessage(message), phase: .completed, source: record)
        }
        var sent = ConversationItem(id: item.id, kind: .userMessage(text: text, images: images(item)), phase: .completed,
                                    source: record)
        switch item.sender?.kind {
        case "task":
            let relation: TaskMessage.Relation = switch item.sender?.relation {
            case "parent": .parent
            case "itself": .itself
            default: .task
            }
            sent.taskMessage = TaskMessage(senderID: item.sender?.taskId ?? "", senderName: item.sender?.name, body: text,
                                           relation: relation,
                                           quotes: (item.sender?.quotes ?? []).map { .init(text: $0.text, sentAt: $0.sentAt) })
        case "backgroundTask":
            sent.backgroundTaskNotice = ClaudeTaskNotification(summary: text, status: item.sender?.status)
        default:
            break
        }
        return sent
    }

    /// A sent message's pictures: the host's previews (§15.24), and for each one it sent no preview of, the name
    /// a picture shows on the Mac once its file is gone.
    private static func images(_ item: RemoteItem) -> [TranscriptImageAttachment] {
        let previews = (item.images ?? []).compactMap { image in
            URL(string: "data:\(image.type);base64,\(image.data.base64EncodedString())")
                .map { TranscriptImageAttachment(url: $0, name: image.name) }
        }
        let missing = max(0, (item.imageCount ?? 0) - previews.count)
        return previews + Array(repeating: TranscriptImageAttachment(url: nil, name: nil), count: missing)
    }

    /// A proposed plan in its card, which reads the plan as a Codex item does: one made from the host's words,
    /// written while they stream.
    private static func proposedPlan(_ item: RemoteItem, text: String, isWriting: Bool) -> ConversationItem {
        let record = CodexItemState(id: item.id, lifecycle: isWriting ? .inProgress : .completed, content: .plan(text: text),
                                    raw: .null)
        return ConversationItem(id: item.id, kind: .proposedPlan(text: text, isWriting: isWriting),
                                phase: isWriting ? .running : .completed, source: .codex(record, turnID: item.turnId))
    }

    /// What the host's own card draws, when it sent it in full detail (§15.24): a subagent, a created schedule, a
    /// compaction or a provider's notice. Nil leaves the item a line in the host's words.
    private static func card(_ item: RemoteItem) -> ConversationItem? {
        var record = source(item, .activity(HarnessActivity(id: item.id, kind: item.activity ?? "other", title: item.title ?? ""),
                                            state: activityState(item.status)))
        let kind: ConversationItemKind
        if let subagent = item.subagent {
            kind = .subagent(ConversationSubagent(
                title: item.title ?? "", status: nil, detail: subagent.detail,
                // A child thread opens as the host's task it runs in.
                routes: (subagent.taskIds ?? []).map(ConversationSubagentRoute.codexThread)
                    + (subagent.activityId.map { [.harnessSubtask(HarnessSubtaskReference(taskID: subagent.canStop == true ? $0 : nil, taskType: "local_agent"), activityID: $0)] } ?? []), isApproved: item.approved == true,
                kind: subagent.kind, input: subagent.input, output: subagent.output, isBackground: subagent.background == true,
                model: subagent.model, harnessLabel: subagent.harnessLabel))
        } else if let schedule = item.schedule, let id = UUID(uuidString: schedule.id) {
            kind = .scheduleCreated(ConversationScheduleCreation(scheduleID: id, name: schedule.name))
        } else if let compaction = item.compaction, let phase = HarnessContextCompaction.Phase(rawValue: compaction.phase) {
            kind = .compaction(HarnessContextCompaction(phase: phase, tokensBefore: compaction.tokensBefore,
                                                        tokensAfter: compaction.tokensAfter, message: compaction.message,
                                                        whileIdle: compaction.whileIdle))
        } else if let notice = item.providerNotice, let noticeKind = CodexNoticeItem.Kind(rawValue: notice.kind) {
            let content = CodexNoticeItem(kind: noticeKind, message: notice.message, details: notice.details,
                                          fromModel: notice.fromModel, reason: notice.reason, path: notice.path)
            kind = .notice(content)
            record = .codex(CodexItemState(id: item.id, lifecycle: .completed, content: .notice(content), raw: .null),
                            turnID: item.turnId)
        } else {
            return nil
        }
        var card = ConversationItem(id: item.id, kind: kind, phase: phase(item.status), source: record)
        card.copyDetails = item.subagent?.copyText
        return card
    }

    /// A call, a step or a notice as one line in the host's words, which reads its output and changes once
    /// opened.
    private static func line(_ item: RemoteItem, details: [String: RemoteItemDetail]) -> ConversationItem {
        let title = item.kind == .notice ? item.text ?? "" : item.title ?? ""
        // The host's words, its verb drawn muted as here (§6.4); a host that sends none gives the whole title.
        let lines = item.words.map { $0.map { ConversationLineWords(leading: $0.leading ?? "", verb: $0.verb, trailing: $0.trailing ?? "") } }
        var tool = ConversationTool(kind: .worded(lines ?? [ConversationLineWords(verb: "", trailing: title)]), name: "",
                                    status: item.status)
        tool.images = images(item)
        tool.mcpResult = mcpBody(item.body?.mcp, itemID: item.id)
        if item.body?.mcp != nil { tool.kind = .mcp }
        tool.isApproved = item.approved == true
        tool.detail = item.body == nil ? item.detail : item.body?.detail
        tool.name = item.body?.toolName ?? ""
        tool.output = item.body?.output
        tool.errorMessage = item.body?.error
        if let additions = item.additions, let deletions = item.deletions {
            tool.lineCounts = .init(additions: additions, deletions: deletions)
        }
        if let code = item.exitCode, code != 0 { tool.errorMessage = L10n.format("Exit code %lld", code) }
        let detail = item.hasDetail == true ? details[item.id] : nil
        if item.hasDetail == true {
            tool.loadsDetailOnOpen = true
            if let detail {
                // A change's line shows its diff; its output, when it has one, beside it.
                tool.output = item.body?.output ?? detail.output ?? (detail.diffs.isEmpty ? "" : nil)
                tool.diffs = detail.diffs.map { HarnessActivityDiff(path: $0.path, unified: $0.patch) }
            }
        }
        let activity = HarnessActivity(id: item.id, kind: item.activity ?? "other", title: title, detail: item.detail)
        var line = ConversationItem(id: item.id, kind: .tool(tool), phase: phase(item.status),
                                    source: source(item, .activity(activity, state: activityState(item.status))))
        // What "Copy item details" takes, as a local line copies what it ran and returned.
        line.copyDetails = bodyCopyText(item) ?? [title, item.detail, detail?.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return line
    }

    /// A suggested task as the app's chip draws it (§15.9). The host sends its title and summary, not the
    /// prompt, which the chip's popover shows; what became of it is read from the item as it changes
    /// (`RemoteSuggestionState`).
    private static func taskSuggestion(_ item: RemoteItem) -> ConversationItem {
        let title = item.title ?? ""
        let suggestion = ConversationTaskSuggestion(id: item.suggestionId ?? item.id, title: item.title, tldr: item.detail,
                                                    prompt: title, startsInNewWorktree: false)
        let activity = HarnessActivity(id: item.id, kind: "taskSuggestion", title: title, detail: item.detail)
        return ConversationItem(id: item.id, kind: .taskSuggestion(suggestion), phase: phase(item.status),
                                source: source(item, .activity(activity, state: activityState(item.status))))
    }

    private static func plan(_ item: RemoteItem) -> ConversationPlan {
        ConversationPlan(explanation: item.explanation, steps: (item.steps ?? []).enumerated().map { index, step in
            ConversationPlan.Step(id: "\(index)", text: step.text, status: stepStatus(step.status))
        })
    }

    private static func stepStatus(_ status: String) -> ConversationPlan.StepStatus {
        switch status {
        case "pending": .pending
        case "inProgress": .inProgress
        case "completed": .completed
        default: .unknown(status)
        }
    }

    private static func outcome(_ item: RemoteItem) -> ConversationTurnOutcome {
        if item.errorKind == "usageLimit" { return .usageLimit(limit(item), entryID: uuid(item.id)) }
        return .error(ConversationTurnError(title: item.title, message: item.message ?? "", isRecoverable: item.recoverable == true,
                                            entryID: uuid(item.id)))
    }

    /// A plan limit as the host's card reads it: the provider's report when the host sent it (§15.24), else when
    /// it resets and the host's words, which name the reset only when it knows none.
    private static func limit(_ item: RemoteItem) -> HarnessRateLimit {
        let resetsAt = item.resetsAt.map(date)
        guard let limit = item.limit else {
            return HarnessRateLimit(status: .rejected, resetsAt: resetsAt, message: resetsAt == nil ? item.message : nil)
        }
        let windows = (limit.windows ?? []).compactMap { window in
            HarnessRateLimit.Window(rawValue: window.window).map {
                HarnessRateLimit.WindowUsage(window: $0, model: window.model, usedFraction: window.usedFraction,
                                             resetsAt: window.resetsAt.map(date))
            }
        }
        return HarnessRateLimit(status: HarnessRateLimit.Status(rawValue: limit.status) ?? .rejected,
                                window: limit.window.flatMap(HarnessRateLimit.Window.init(rawValue:)), model: limit.model,
                                resetsAt: resetsAt, usedFraction: limit.usedFraction, isUsingOverage: limit.overage == true,
                                windows: windows, message: limit.message)
    }

    // MARK: - Requests

    static func request(_ item: RemoteItem, hostName: String) -> ConversationRequest {
        let id = item.requestId ?? item.id
        let state: ConversationRequestState = switch item.status {
        case "allowed": .allowed
        case "denied": .denied
        case "answered": .answered
        case "expired": .expired(message: nil)
        case "rejected": .rejected(message: "")
        default: .pending
        }
        let permission = PermissionRequest(id: id, title: item.title ?? "", detail: item.detail, command: item.command)
        var request = ConversationRequest(
            id: id, title: item.title ?? L10n.string("Request"), detail: item.detail, command: item.command, state: state,
            source: .transcript(TranscriptEntry(id: uuid(item.id), createdAt: Date(timeIntervalSince1970: 0),
                                                content: .permission(permission, state: permissionState(state)))))
        request.hostMessage = item.message
        let options = item.options ?? []
        let steps = item.questionSteps ?? []
        switch item.requestKind {
        case "planReview":
            request.form = .planReview(item.text ?? "")
            if options.contains(RemoteProtocol.approvePlanOption) { request.responses = ConversationRequestResponses.planReview }
        case "question":
            fallthrough
        case "form" where !steps.isEmpty || item.formFields == nil:
            if steps.contains(where: { $0.secret == true }) {
                request.form = .freeText(steps.map { step in
                    ConversationRequestQuestion(id: step.id, text: step.text, header: step.header,
                                                options: step.options.map { PermissionQuestionOption(label: $0.label, description: $0.description) },
                                                allowsCustomAnswer: step.custom || step.options.isEmpty, isSecret: step.secret == true)
                })
            } else if !steps.isEmpty {
                request.form = .choices(steps.map(question))
            } else if let questions = item.questions, !questions.isEmpty {
                request.form = .choices(questions.map { PermissionQuestion(question: $0, options: []) })
            }
            if options.contains(RemoteProtocol.answerOption) || options.contains(RemoteProtocol.answerSecretOption) {
                request.responses = ConversationRequestResponses.questions
            }
        case "browserHandoff":
            if options.contains(RemoteHandoffAnswer.done.rawValue) {
                let decline = PermissionRequestAction(id: Route.handoff + RemoteHandoffAnswer.decline.rawValue,
                                                      label: L10n.string("Decline"), decision: .deny, kind: nil)
                let done = PermissionRequestAction(id: Route.handoff + RemoteHandoffAnswer.done.rawValue,
                                                   label: L10n.string("I'm done"), decision: .allow, kind: nil)
                request.providerActions = [decline, done]
                request.responses = [.init(title: decline.label, role: .destructive, route: .providerAction(decline)),
                                     .init(title: done.label, role: .primary, route: .providerAction(done))]
                // A host that shows its tabs names the handed one: the person takes the step in it here.
                if let tabID = item.tabId {
                    let show = PermissionRequestAction(id: Route.showTab + tabID, label: L10n.string("Show Tab"),
                                                       decision: .allow, kind: nil)
                    request.responses.insert(.init(title: show.label, role: .secondary, route: .providerAction(show)), at: 1)
                }
            }
        default:
            if let fields = item.formFields, let choices = item.choices, !choices.isEmpty {
                // An MCP form (§15.19): the card's own form, which its Submit sends back with the values.
                let form = form(fields)
                if let form { request.form = .mcpForm(form) }
                let submit = submitChoice(item)
                var responses: [ConversationRequestResponse] = []
                var actions: [PermissionRequestAction] = []
                for choice in choices {
                    let title = title(of: choice)
                    if choice.id == submit?.id {
                        // A field this Mac cannot draw leaves the form to the host, as the card leaves a form it
                        // cannot read: declined or cancelled here, never sent without it.
                        if form != nil { responses.append(.init(title: title, role: .primary, route: .structured)) }
                        continue
                    }
                    let action = PermissionRequestAction(id: Route.choice + choice.id, label: title,
                                                         decision: choice.role == "destructive" ? .deny : .allow,
                                                         kind: choice.standing == true ? Route.standing : nil)
                    actions.append(action)
                    responses.append(.init(title: title, role: role(choice.role), route: .providerAction(action)))
                }
                request.providerActions = actions
                request.responses = responses
            } else if item.formFields == nil, let choices = item.choices, !choices.isEmpty {
                let actions = choices.map { choice in
                    PermissionRequestAction(id: Route.choice + choice.id, label: title(of: choice),
                                            decision: choice.role == "destructive" ? .deny : .allow,
                                            kind: choice.standing == true ? Route.standing : nil)
                }
                request.providerActions = actions
                request.responses = zip(choices, actions).map { choice, action in
                    .init(title: action.label, role: role(choice.role), route: .providerAction(action))
                }
            } else if item.formFields == nil, item.choices == nil {
                // A host from before every answer of its card was offered (§15.13).
                let titles = item.optionTitles ?? [:]
                let actions = options.compactMap(RemoteApprovalAnswer.init(rawValue:)).map { answer in
                    PermissionRequestAction(id: Route.answer + answer.rawValue, label: titles[answer.rawValue] ?? answerTitle(answer),
                                            decision: answer == .deny ? .deny : .allow, kind: nil)
                }
                request.providerActions = actions
                request.responses = ConversationRequestResponses.plain(providerActions: actions)
                    .filter { if case .providerAction = $0.route { true } else { false } }
            }
        }
        if state == .pending, request.responses.isEmpty {
            request.unanswerableReason = item.macNote ?? L10n.format("Answer this on %@.", hostName)
        }
        return request
    }

    /// An answer in this Mac's language when the host sent the key it was made from and this Mac's catalog has
    /// it (§15.19); otherwise the host's own words.
    static func title(of choice: RemoteChoice, lookup: (String) -> String? = L10n.lookup) -> String {
        choice.text.flatMap(LocalizedText.init).flatMap { $0.resolved(lookup) } ?? choice.title
    }

    /// The choice that sends an MCP form's values: the card's prominent Submit. A form without fields has
    /// none; its Submit is an answer like the others.
    static func submitChoice(_ item: RemoteItem) -> RemoteChoice? {
        guard item.formFields?.isEmpty == false else { return nil }
        return item.choices?.first { $0.role == "primary" }
    }

    /// The host's MCP form as the card's own (`CodexMCPElicitationForm`), which checks each field as the
    /// host's card does before Submit; nil when a field is of a kind this Mac does not know.
    static func form(_ fields: [RemoteFormField]) -> CodexMCPElicitationForm? {
        var form: [CodexMCPElicitationForm.Field] = []
        for field in fields {
            let options = (field.options ?? []).map { CodexMCPElicitationForm.Option(value: $0.value, title: $0.title) }
            let kind: CodexMCPElicitationForm.Kind
            switch field.type {
            case "text":
                kind = .text(format: field.format.flatMap(CodexMCPElicitationForm.TextFormat.init(rawValue:)),
                             minLength: field.minLength, maxLength: field.maxLength)
            case "number", "integer":
                kind = .number(isInteger: field.type == "integer", minimum: field.minimum, maximum: field.maximum)
            case "boolean":
                kind = .boolean
            case "choice":
                kind = .choice(options)
            case "choices":
                kind = .choices(options, minItems: field.minItems, maxItems: field.maxItems)
            default:
                return nil
            }
            form.append(.init(id: field.id, title: field.label, description: field.description,
                              isRequired: field.required == true, kind: kind,
                              defaultValue: field.default.flatMap { value($0, for: kind) }))
        }
        return CodexMCPElicitationForm(fields: form)
    }

    /// A field's default as the card's form holds it: words and numbers as text, the options picked.
    private static func value(_ value: RemoteFormValue, for kind: CodexMCPElicitationForm.Kind) -> CodexMCPElicitationFieldValue? {
        switch (kind, value) {
        case let (.text, .text(text)), let (.number, .text(text)): .text(text)
        case let (.number, .number(number)): .text(CodexMCPElicitationForm.text(number))
        case let (.boolean, .flag(flag)): .flag(flag)
        case let (.choice, .text(choice)): .picked([choice])
        case let (.choices, .list(list)): .picked(Set(list))
        default: nil
        }
    }

    /// The values the card's form sent as `content`, as `chooseAnswer` carries them (§15.19).
    static func formValues(_ content: JSONValue) -> [String: RemoteFormValue] {
        guard case let .object(fields) = content else { return [:] }
        return fields.compactMapValues { value in
            switch value {
            case let .string(text): .text(text)
            case let .integer(number): .number(Double(number))
            case let .number(number): .number(number)
            case let .bool(flag): .flag(flag)
            case let .array(items): .list(items.compactMap(\.stringValue))
            case .object, .null: nil
            }
        }
    }

    private static func question(_ step: RemoteQuestionStep) -> PermissionQuestion {
        PermissionQuestion(question: step.text ?? step.header ?? step.id, header: step.header,
                           options: step.options.map { PermissionQuestionOption(label: $0.label, description: $0.description) },
                           allowsMultipleSelections: step.multiple, allowsCustomAnswer: step.custom,
                           requiresAnswer: !step.skippable)
    }

    private static func role(_ role: String) -> ConversationRequestResponse.Role {
        switch role {
        case "primary": .primary
        case "destructive": .destructive
        default: .secondary
        }
    }

    private static func answerTitle(_ answer: RemoteApprovalAnswer) -> String {
        switch answer {
        case .allowOnce: L10n.string("Allow once")
        case .allowForSession: L10n.string("Allow for session")
        case .deny: L10n.string("Deny")
        }
    }

    private static func permissionState(_ state: ConversationRequestState) -> TranscriptPermissionState {
        switch state {
        case .pending: .pending
        case .allowed, .answered: .allowed
        case .denied, .rejected: .denied
        case .expired: .expired
        }
    }

    // MARK: - Records

    private static func phase(_ status: String?) -> ConversationItemPhase {
        switch status {
        case "running": .running
        case "failed": .failed
        case "stopped": .stopped
        default: .completed
        }
    }

    private static func activityState(_ status: String?) -> TranscriptActivityState {
        switch status {
        case "running": .running
        case "failed": .failed
        case "stopped": .stopped
        default: .completed
        }
    }

    /// The record a card reads where it reads one: a shared-transcript entry named after the item.
    private static func source(_ item: RemoteItem, _ content: TranscriptEntryContent) -> ConversationItemSource {
        .transcript(TranscriptEntry(id: uuid(item.id), createdAt: Date(timeIntervalSince1970: 0), content: content))
    }

    /// The same UUID for the same item ID, every time.
    static func uuid(_ id: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(id.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6] & 0x0F | 0x50, bytes[7],
                           bytes[8] & 0x3F | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

/// What became of a host's suggested task (§15.9), as the chip reads it: started, sent here or dismissed, or
/// starting, or a start that failed, with why where the host says.
enum RemoteSuggestionState {
    static func resolution(_ item: RemoteItem) -> TaskSuggestionResolution? {
        let at = Date(timeIntervalSince1970: 0)
        switch item.suggestionState {
        case "started": return TaskSuggestionResolution(outcome: .started, at: at, startedTaskID: item.startedTaskId.flatMap(UUID.init))
        case "sentHere": return TaskSuggestionResolution(outcome: .sentHere, at: at)
        case "dismissed": return TaskSuggestionResolution(outcome: .dismissed, at: at)
        default: return nil
        }
    }

    static func progress(_ item: RemoteItem, host: String) -> TaskSuggestionStore.Progress? {
        switch item.suggestionState {
        case "starting": .starting
        case "failed": .failed(item.suggestionFailure ?? L10n.format("%@ couldn't start this task.", host))
        default: nil
        }
    }
}

extension ConversationPresentation {
    /// The presentation without the pending request `id`, which a host sets at the end of its turn (§6.5): another
    /// place answers it.
    func withoutRequest(_ id: String) -> ConversationPresentation {
        guard pendingRequestIDs.contains(id),
              let index = turns.lastIndex(where: { $0.requests.contains { $0.id == id } }) else { return self }
        var presentation = self
        presentation.turns[index].requests.removeAll { $0.id == id }
        presentation.pendingRequestIDs.remove(id)
        return presentation
    }
}
