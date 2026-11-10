import Foundation
import YardletRemote

/// A task's conversation as the phone draws it (docs/REMOTE_PROTOCOL.md §6), read from the one
/// conversation model the Mac's `ConversationTimeline` draws for every harness. Nothing is
/// interpreted again: each turn keeps the Mac's order (what was sent, notices, the header, the plan
/// and work, the answers, the outcome, the requests still waiting), each call reads the line the
/// Mac shows (`ConversationLineWording`), and each request offers only the answers the Mac's card
/// offers that the phone may give (`RemoteApprovalPolicy`). Outputs, file contents and diffs are left
/// out, and fetched one line at a time by `itemDetail` (§15.8); text is capped.
///
/// A subscription's full detail (§15.24) adds what the Mac's own cards read beyond a line: a sent message's
/// pictures as small previews, a subagent's card, a compaction's marker, a provider's notice and a plan limit's
/// windows, each from the same normalized item, and text capped far higher. What a turn offers to do (its next
/// steps, stopping or opening a subagent, a created schedule's row) comes in either detail.
enum RemoteConversationProjection {
    /// What full detail reads from the app beside a turn.
    struct Full {
        /// Previews of the turn's sent pictures, by their URL; a picture without one counts in `imageCount` only.
        var previews: [URL: Data] = [:]
    }

    static func conversation(_ presentation: ConversationPresentation, workspaceURL: URL?) -> RemoteConversation {
        conversation(presentation, workspaceURL: workspaceURL) {
            turn($0, harness: presentation.harness, workspaceURL: workspaceURL)
        }
    }

    /// The conversation with its turns projected by `project`, which a caller uses to keep the turns
    /// that did not change since it last projected them.
    static func conversation(
        _ presentation: ConversationPresentation, workspaceURL: URL?, project: (ConversationTurn) -> RemoteTurn
    ) -> RemoteConversation {
        RemoteConversation(turns: uniqued(presentation.turns.map(project)), hasEarlier: presentation.earlier != .none)
    }

    /// `childTasks`: the listed tasks the turn's Codex child threads run in, by thread ID, which "Open child task" opens.
    static func turn(_ turn: ConversationTurn, harness: HarnessKind, workspaceURL: URL?, full: Full? = nil,
                     childTasks: [String: String] = [:]) -> RemoteTurn {
        var items: [RemoteItem] = []
        func add(_ item: RemoteItem?) { if let item { items.append(item) } }
        for item in turn.prompt + turn.notices {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL, inWork: false, full: full,
                          childTasks: childTasks))
        }
        let headerIndex = items.count
        if let plan = turn.plan { add(self.plan(plan, turnID: turn.id)) }
        let kept = Set(turn.workKeptWhenFolded.map(\.id))
        for item in turn.work {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL,
                          inWork: !kept.contains(item.id), full: full, childTasks: childTasks))
        }
        for item in turn.answers {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL, inWork: false, full: full,
                          childTasks: childTasks))
        }
        if let outcome = turn.outcome {
            add(self.outcome(outcome, id: "outcome:\(turn.id)", turnID: turn.id, inWork: false, isFull: full != nil))
        }
        for request in turn.requests { add(self.request(request, turnID: turn.id, inWork: false, isFull: full != nil)) }
        var heading = header(turn, workCount: items.filter { $0.inWork == true }.count)
        addNextSteps(turn.actions, to: &heading, isFull: full != nil)
        items.insert(heading, at: headerIndex)
        return RemoteTurn(id: turn.id, items: items)
    }

    /// Messages waiting in the task's follow-up queue — on the Mac, the queue chips above the composer
    /// — as `queued` user items at the end of the last turn, with the chip's actions (§15.15). Each
    /// leaves when the provider takes it, and the message then reads as an ordinary sent message in its
    /// turn. A message another task sent is not the person's to manage, so it offers none.
    static func queued(_ followUps: [QueuedFollowUp], policy: FollowUpPolicy? = nil,
                       into conversation: RemoteConversation) -> RemoteConversation {
        guard !followUps.isEmpty else { return conversation }
        var conversation = conversation
        if conversation.turns.isEmpty { conversation.turns.append(RemoteTurn(id: "queue", items: [])) }
        let last = conversation.turns.count - 1
        let turnID = conversation.turns[last].id
        conversation.turns[last].items += followUps.enumerated().map { index, followUp in
            var item = RemoteItem(id: "queued:\(followUp.id.uuidString)", turnId: turnID, kind: .user)
            let sent = DiffCommentPrompt.parse(followUp.draft.text)
            setText(&item, sent?.request ?? followUp.draft.text, RemoteText.userLimit)
            if let comments = sent?.comments.count, comments > 0 { item.diffCommentCount = comments }
            let images = followUp.draft.inputs.filter { input in
                switch input {
                case .image, .localImage: true
                default: false
                }
            }.count
            if images > 0 { item.imageCount = images }
            item.queued = true
            if followUp.state == .failed { item.queueFailed = true }
            if let policy, TaskMessage.parse(followUp.draft.text) == nil {
                let chip = ComposerQueueChip.make(policy: policy, queue: followUps, at: index, canSend: true)
                item.options = [chip.send == nil ? nil : RemoteQueuedAction.sendNow, chip.stopAndSend == nil ? nil : .stopAndSend,
                                .remove].compactMap { $0?.rawValue }
                if chip.canMoveUp { item.options?.append("moveUp") }
                if chip.canMoveDown { item.options?.append("moveDown") }
                if followUp.state == .failed { item.options?.append("retry") }
                if followUp.state != .sent, followUp.draft.text.count <= RemoteText.userLimit,
                   sent == nil { item.options?.append("edit") }
            }
            return item
        }
        return conversation
    }

    /// A tab the agent handed to the person and waits on, as a waiting request at the end of the last
    /// turn (§15.18): the site, the agent's reason, and the bar's two answers.
    static func handoff(_ wait: BrowserHandoffWait, site: String?, into conversation: RemoteConversation) -> RemoteConversation {
        var conversation = conversation
        if conversation.turns.isEmpty { conversation.turns.append(RemoteTurn(id: "handoff", items: [])) }
        let last = conversation.turns.count - 1
        var item = RemoteItem(id: "req:\(wait.notice)", turnId: conversation.turns[last].id, kind: .approval)
        item.requestId = wait.notice
        item.requestKind = "browserHandoff"
        item.status = "pending"
        item.title = RemoteText.short(site ?? L10n.string("Browser"), RemoteText.titleLimit)
        item.detail = RemoteText.short(wait.reason, RemoteText.requestDetailLimit)
        item.options = [RemoteHandoffAnswer.done.rawValue, RemoteHandoffAnswer.decline.rawValue]
        // The tab `watchTab` shows (§15.25).
        item.tabId = wait.tabKey?.uuidString
        conversation.turns[last].items.append(item)
        return conversation
    }

    // MARK: - Turn

    private static func header(_ turn: ConversationTurn, workCount: Int) -> RemoteItem {
        var item = RemoteItem(id: "turn:\(turn.id)", turnId: turn.id, kind: .turn)
        item.status = switch turn.status {
        case .running: "running"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case .unknown: "unknown"
        }
        item.startedAt = turn.timing.startedAt.map(RemoteJSON.milliseconds)
        item.completedAt = turn.timing.completedAt.map(RemoteJSON.milliseconds)
        item.durationMs = turn.timing.durationMilliseconds
        if turn.timing.isApproximate { item.approximate = true }
        item.foldsWork = turn.foldsWork && workCount > 0
        item.workCount = workCount
        if turn.status == .running {
            switch turn.progress {
            case .none: break
            case .thinking: item.progress = "thinking"
            case let .reconnecting(text):
                item.progress = "reconnecting"
                item.progressText = RemoteText.short(text, RemoteText.detailLimit)
            }
        }
        return item
    }

    // MARK: - Items

    static func item(
        _ item: ConversationItem, turnID: String, harness: HarnessKind, workspaceURL: URL?, inWork: Bool, full: Full? = nil,
        childTasks: [String: String] = [:]
    ) -> RemoteItem? {
        var result = RemoteItem(id: "i:\(item.id)", turnId: turnID, kind: .activity)
        if inWork { result.inWork = true }
        if full != nil {
            result.sentWhileWorking = item.isSentWhileWorking ? true : nil
            result.unmarkedAnswer = item.isUnmarkedAnswer ? true : nil
        }
        let userLimit = full == nil ? RemoteText.userLimit : RemoteText.fullTextLimit
        switch item.kind {
        case let .userMessage(text, images):
            result.kind = .user
            setText(&result, text, userLimit)
            if !images.isEmpty { result.imageCount = images.count }
            if let full {
                let previews = images.compactMap { image in
                    image.url.flatMap { full.previews[$0] }.map { RemoteImagePreview(data: $0, name: image.name) }
                }
                if !previews.isEmpty { result.images = previews }
            }
            if let comments = item.promptAttachments?.comments.count, comments > 0 { result.diffCommentCount = comments }
            result.sender = sender(of: item, textLimit: userLimit)
        case let .scheduledTaskMessage(message):
            result.kind = .user
            setText(&result, message.instructions, userLimit)
            result.scheduled = true
            if let schedule = message.claudeSchedule {
                if case let .task(name) = schedule {
                    result.sender = RemoteSender(kind: "claudeSchedule", name: name)
                } else {
                    result.sender = RemoteSender(kind: "claudeSchedule")
                }
            }
        case let .shellCommand(command, _):
            result.kind = .user
            setText(&result, command.command, userLimit)
            result.shell = true
        case let .answer(text, isStreaming):
            assistant(&result, text, role: "answer", isStreaming: isStreaming, isFull: full != nil)
        case let .commentary(text, isStreaming):
            assistant(&result, text, role: "commentary", isStreaming: isStreaming, isFull: full != nil)
        case let .proposedPlan(text, isWriting):
            assistant(&result, text, role: "proposedPlan", isStreaming: isWriting, isFull: full != nil)
        case let .reasoning(summary, detail, isStreaming):
            // The Mac draws a summary row, or a "Thinking" line while it streams or has a body.
            let summary = RemoteText.short(summary, full == nil ? RemoteText.detailLimit : RemoteText.fullTextLimit)
            guard summary != nil || isStreaming || detail?.isEmpty == false else { return nil }
            let verb = isStreaming ? L10n.string("Thinking") : L10n.string("Thought process")
            activity(&result, "reasoning", verb, item.phase)
            result.words = words([ConversationLineWords(verb: verb)])
            result.detail = summary
        case let .command(command):
            let words = ConversationLineWording.command(command, phase: item.phase, harness: harness)
            activity(&result, "command", words.map(\.text).joined(separator: ", "), item.phase)
            result.words = self.words(words)
            if !ConversationLineWording.showsWholeCommand(command, words: words) {
                result.detail = RemoteText.short(firstLine(command.command), RemoteText.detailLimit)
            }
            if item.phase != .running, let code = command.exitCode { result.exitCode = code }
            if command.isApproved { result.approved = true }
            if command.output?.isEmpty == false { result.hasDetail = true }
        case let .fileChange(change):
            let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: workspaceURL) } : change.rows
            let verb = rows.first?.verb ?? L10n.string("Edited")
            activity(&result, "fileChange", [verb, rows.map(\.fileName).joined(separator: ", ")]
                .filter { !$0.isEmpty }.joined(separator: " "), item.phase)
            result.words = words([ConversationLineWords(verb: verb, trailing: rows.map(\.fileName).joined(separator: ", "))])
            let counts = rows.compactMap(\.lineCounts)
            if !counts.isEmpty {
                result.additions = counts.reduce(0) { $0 + $1.additions }
                result.deletions = counts.reduce(0) { $0 + $1.deletions }
            }
            result.detail = RemoteText.short(change.errorMessage, RemoteText.detailLimit)
            if change.isApproved { result.approved = true }
            if rows.contains(where: \.canExpand) { result.hasDetail = true }
        case let .tool(tool):
            let words = ConversationLineWording.tool(tool, phase: item.phase, harness: harness, workspaceURL: workspaceURL)
            activity(&result, "tool", words.text, item.phase)
            result.words = self.words([words])
            result.detail = RemoteText.short(tool.errorMessage, RemoteText.detailLimit)
            if tool.isApproved { result.approved = true }
            if tool.output?.isEmpty == false || tool.diff != nil { result.hasDetail = true }
        case let .subagent(subagent):
            activity(&result, "subagent", subagent.title, item.phase)
            result.detail = RemoteText.short(subagent.detail ?? subagent.status, RemoteText.detailLimit)
            if subagent.isApproved { result.approved = true }
            // What the card does comes in either detail: Stop, and Open child task; what it reads, in full detail.
            var card = full == nil ? RemoteSubagent() : self.subagent(subagent)
            for route in subagent.routes {
                switch route {
                case let .harnessSubtask(reference, activityID):
                    card.activityId = activityID
                    card.canStop = reference.taskID != nil && item.phase == .running ? true : nil
                case let .codexThread(threadID):
                    if let task = childTasks[threadID] { card.taskIds = (card.taskIds ?? []) + [task] }
                default:
                    continue
                }
            }
            if full != nil { card.copyText = RemoteText.short(item.copyDetails, RemoteText.fullSubagentLimit) }
            if card != RemoteSubagent() { result.subagent = card }
        case let .taskSuggestion(suggestion):
            activity(&result, "taskSuggestion", suggestion.title ?? firstLine(suggestion.prompt), item.phase)
            result.detail = RemoteText.short(suggestion.tldr, RemoteText.detailLimit)
            // What became of it is the app's, set after projection (`AppModelRemoteBridge`).
            result.suggestionId = suggestion.id
        case let .scheduleCreated(creation):
            // A tool line on the phone, which has no Scheduled tasks to open.
            activity(&result, "tool", L10n.format("Created scheduled task: %@", creation.name), item.phase)
            result.schedule = RemoteScheduleCreation(id: creation.scheduleID.uuidString, name: creation.name)
        case let .settingChanged(change):
            // A tool line on the phone, which has no Settings to open.
            activity(&result, "tool", L10n.format("Changed setting: %@", change.title), item.phase)
            result.detail = RemoteText.short(L10n.format("%@ → %@", change.from, change.to), RemoteText.detailLimit)
        case let .notice(notice):
            result.kind = .notice
            result.text = RemoteText.short(notice.displayMessage, RemoteText.detailLimit)
            if full != nil {
                result.providerNotice = RemoteProviderNotice(
                    kind: notice.kind.rawValue, message: RemoteText.capped(notice.message, RemoteText.requestDetailLimit).text,
                    details: RemoteText.short(notice.details, RemoteText.requestDetailLimit), fromModel: notice.fromModel,
                    reason: notice.reason, path: notice.path)
            }
        case let .compaction(compaction):
            result.kind = .notice
            result.text = RemoteText.short(ProviderNoticeText.compaction(compaction), RemoteText.detailLimit)
            if full != nil {
                result.compaction = RemoteCompaction(
                    phase: compaction.phase.rawValue, tokensBefore: compaction.tokensBefore, tokensAfter: compaction.tokensAfter,
                    message: RemoteText.short(compaction.message, RemoteText.errorLimit))
            }
        case let .request(request):
            return self.request(request, turnID: turnID, inWork: inWork, isFull: full != nil)
        case let .outcome(outcome):
            return self.outcome(outcome, id: "i:\(item.id)", turnID: turnID, inWork: inWork, isFull: full != nil)
        }
        if let full { result.body = body(item, full: full, workspaceURL: workspaceURL)
            if case let .tool(tool) = item.kind {
                result.imageCount = tool.images.isEmpty ? nil : tool.images.count
                result.images = tool.images.prefix(4).compactMap { image in
                    image.url.flatMap { full.previews[$0] }.map { RemoteImagePreview(data: $0, name: image.name) }
                }
            }
        }
        return result
    }

    private static func assistant(_ item: inout RemoteItem, _ text: String, role: String, isStreaming: Bool, isFull: Bool) {
        item.kind = .assistant
        item.role = role
        setText(&item, text, isFull ? RemoteText.fullTextLimit : RemoteText.assistantLimit)
        if isStreaming { item.streaming = true }
    }

    /// Who sent a message that is not the person's (§6.2), in either detail: another task, by its ID when it is another
    /// Yardlet task and with the person's words it passed on, cut as the message's text is, or a background command's
    /// notice.
    private static func sender(of item: ConversationItem, textLimit: Int) -> RemoteSender? {
        if let message = item.taskMessage {
            let relation = switch message.relation {
            case .task: "task"
            case .parent: "parent"
            case .itself: "itself"
            }
            let quotes = message.quotes.map {
                RemoteSender.Quote(text: RemoteText.capped($0.text, textLimit).text, sentAt: $0.sentAt)
            }
            return RemoteSender(kind: "task", name: RemoteText.short(message.senderName, RemoteText.titleLimit),
                                relation: relation,
                                taskId: message.relation == .itself ? nil : UUID(uuidString: message.senderID)?.uuidString,
                                quotes: quotes.isEmpty ? nil : quotes)
        }
        if let notice = item.backgroundTaskNotice {
            return RemoteSender(kind: "backgroundTask", status: RemoteText.short(notice.status, RemoteText.titleLimit))
        }
        return nil
    }

    /// A subagent's card as the Mac draws it (§15.24): what it was asked and reported, and its model.
    private static func subagent(_ subagent: ConversationSubagent) -> RemoteSubagent {
        RemoteSubagent(
            kind: subagent.kind, detail: RemoteText.short(subagent.detail, RemoteText.requestDetailLimit),
            input: RemoteText.short(subagent.input, RemoteText.fullSubagentLimit),
            output: RemoteText.short(subagent.output, RemoteText.fullSubagentLimit),
            model: subagent.model, harnessLabel: subagent.harnessLabel, background: subagent.isBackground ? true : nil)
    }

    /// A line's words as the Mac draws them (§6.4), each part capped as the title is.
    private static func words(_ lines: [ConversationLineWords]) -> [RemoteLineWords]? {
        let words = lines.prefix(8).map { line in
            RemoteLineWords(leading: RemoteText.short(oneLine(line.leading), RemoteText.titleLimit),
                            verb: RemoteText.capped(oneLine(line.verb), RemoteText.titleLimit).text,
                            trailing: RemoteText.short(oneLine(line.trailing), RemoteText.titleLimit))
        }
        return words.isEmpty ? nil : words
    }

    private static func activity(_ item: inout RemoteItem, _ kind: String, _ title: String, _ phase: ConversationItemPhase) {
        item.kind = .activity
        item.activity = kind
        item.title = RemoteText.capped(oneLine(title), RemoteText.titleLimit).text
        item.status = switch phase {
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    private static func setText(_ item: inout RemoteItem, _ text: String, _ limit: Int) {
        let capped = RemoteText.capped(text, limit)
        item.text = capped.text
        if capped.truncated { item.truncated = true }
    }

    // MARK: - Requests, plans, outcomes

    static func request(_ request: ConversationRequest, turnID: String, inWork: Bool, isFull: Bool = false) -> RemoteItem {
        var item = RemoteItem(id: "req:\(request.id)", turnId: turnID, kind: .approval)
        if inWork { item.inWork = true }
        item.requestId = request.id
        item.requestKind = switch request.form {
        case .choices: "question"
        case .planReview: "planReview"
        case .freeText, .mcpForm: "form"
        case nil: "approval"
        }
        item.status = switch request.state {
        case .pending: "pending"
        case .allowed: "allowed"
        case .denied: "denied"
        case .answered: "answered"
        case .expired: "expired"
        case .rejected: "rejected"
        }
        item.title = RemoteText.short(request.title, RemoteText.titleLimit)
        item.detail = RemoteText.short(request.detail, isFull ? RemoteText.fullTextLimit : RemoteText.requestDetailLimit)
        // The sentences the card shows above its form or answers, such as the one an MCP form asks with (§6.5).
        item.message = RemoteText.short(request.codexContext?.messages.joined(separator: "\n\n"),
                                        isFull ? RemoteText.fullTextLimit : RemoteText.requestDetailLimit)
        if let command = RemoteText.short(request.command, .max) {
            // A phone must not take a cut command for the whole one (§6). A pending one comes as whole as full detail
            // sends it, since the person reads it to answer; an answered one is history and keeps the shorter cap.
            let whole = isFull || request.state == .pending
            let capped = RemoteText.capped(command, whole ? RemoteText.fullTextLimit : RemoteText.commandLimit)
            item.command = capped.text
            if capped.truncated { item.truncated = true }
        }
        switch request.form {
        case let .choices(questions):
            item.questions = questions.compactMap { RemoteText.short($0.question, RemoteText.questionLimit) }
        case let .planReview(plan):
            item.text = RemoteText.short(plan, isFull ? RemoteText.fullTextLimit : RemoteText.planTextLimit)
        case let .freeText(questions):
            item.questions = questions.compactMap { RemoteText.short($0.text, RemoteText.questionLimit) }
        case let .mcpForm(form):
            item.questions = form.fields.compactMap { RemoteText.short($0.label, RemoteText.questionLimit) }
        case nil:
            break
        }
        if request.state == .pending {
            let answers = RemoteApprovalPolicy.answers(for: request)
            let formAnswers = RemoteApprovalPolicy.formAnswers(for: request)
            item.options = answers.map(\.rawValue) + formAnswers
            if let route = RemoteApprovalPolicy.allowForSession(request),
               let title = request.responses.first(where: { $0.route == route })?.title {
                item.optionTitles = [RemoteApprovalAnswer.allowForSession.rawValue: title]
            }
            item.choices = RemoteApprovalPolicy.choices(for: request)
            if case let .mcpForm(form)? = request.form, item.choices != nil { item.formFields = form.fields.map(formField) }
            if formAnswers.contains(RemoteProtocol.answerSecretOption) {
                // A phone that masks a secret answers it; one that does not reads it as the Mac's (§15.19).
                item.questionSteps = request.form?.questionSteps.map(questionStep)
                item.moreOnMac = true
                item.macNote = RemoteText.short(L10n.string("This question takes a secret answer. Answer it on the Mac."),
                                                RemoteText.requestDetailLimit)
            } else if !formAnswers.isEmpty {
                if formAnswers.contains(RemoteProtocol.answerOption) {
                    item.questionSteps = request.form?.questionSteps.map(questionStep)
                }
            } else if RemoteApprovalPolicy.hasMoreOnMac(request, phoneAnswers: answers.count) {
                item.moreOnMac = true
                item.macNote = RemoteText.short(RemoteApprovalPolicy.macNote(request, phoneAnswers: answers),
                                                RemoteText.requestDetailLimit)
            }
        }
        return item
    }

    private static func questionStep(_ step: ConversationQuestionStep) -> RemoteQuestionStep {
        RemoteQuestionStep(
            id: step.id, header: RemoteText.short(step.header, RemoteText.titleLimit),
            text: RemoteText.short(step.text, RemoteText.questionLimit),
            options: step.options.map {
                .init(label: $0.label, description: RemoteText.short($0.description, RemoteText.questionLimit))
            },
            multiple: step.allowsMultipleSelections, custom: step.allowsCustomAnswer, skippable: step.canSkip,
            secret: step.isSecret ? true : nil)
    }

    /// An MCP form field as the phone draws it (§15.19), with the limits the card checks.
    private static func formField(_ field: CodexMCPElicitationForm.Field) -> RemoteFormField {
        var result = RemoteFormField(id: field.id, label: RemoteText.capped(field.label, RemoteText.titleLimit).text, type: "text")
        result.description = RemoteText.short(field.description, RemoteText.questionLimit)
        result.required = field.isRequired ? true : nil
        switch field.kind {
        case let .text(format, minLength, maxLength):
            result.format = format?.rawValue
            result.minLength = minLength
            result.maxLength = maxLength
        case let .number(isInteger, minimum, maximum):
            result.type = isInteger ? "integer" : "number"
            result.minimum = minimum
            result.maximum = maximum
        case .boolean:
            result.type = "boolean"
        case let .choice(options):
            result.type = "choice"
            result.options = options.map { .init(value: $0.value, title: $0.title) }
        case let .choices(options, minItems, maxItems):
            result.type = "choices"
            result.options = options.map { .init(value: $0.value, title: $0.title) }
            result.minItems = minItems
            result.maxItems = maxItems
        }
        switch field.defaultValue {
        case let .text(text)?: result.default = .text(text)
        case let .flag(flag)?: result.default = .flag(flag)
        case let .picked(values)?:
            if case .choice = field.kind { result.default = values.first.map(RemoteFormValue.text) } else {
                result.default = .list(values.sorted())
            }
        case nil: break
        }
        return result
    }

    private static func plan(_ plan: ConversationPlan, turnID: String) -> RemoteItem {
        var item = RemoteItem(id: "plan:\(turnID)", turnId: turnID, kind: .plan)
        item.inWork = true
        item.explanation = RemoteText.short(plan.explanation, RemoteText.requestDetailLimit)
        item.steps = plan.steps.prefix(RemoteText.stepCount).map { step in
            let status = switch step.status {
            case .pending: "pending"
            case .inProgress: "inProgress"
            case .completed: "completed"
            case .unknown: "pending"
            }
            return RemotePlanStep(text: RemoteText.capped(step.text, RemoteText.stepLimit).text, status: status)
        }
        return item
    }

    private static func outcome(_ outcome: ConversationTurnOutcome, id: String, turnID: String, inWork: Bool,
                                isFull: Bool) -> RemoteItem {
        var item = RemoteItem(id: id, turnId: turnID, kind: .error)
        if inWork { item.inWork = true }
        switch outcome {
        case let .error(error):
            item.errorKind = "error"
            item.title = RemoteText.short(error.title, RemoteText.titleLimit)
            // The card's details and copy keep the provider's whole text.
            item.message = isFull ? RemoteText.short(error.message, RemoteText.fullTextLimit)
                : RemoteText.short(error.summary.isEmpty ? error.message : error.summary, RemoteText.errorLimit)
            item.recoverable = error.isRecoverable
        case let .usageLimit(limit, _):
            item.errorKind = "usageLimit"
            item.title = RemoteText.short(ProviderNoticeText.limitHeadline(limit), RemoteText.titleLimit)
            item.message = RemoteText.short(limit.message ?? ProviderNoticeText.limitReset(limit), RemoteText.errorLimit)
            item.resetsAt = limit.resetsAt.map(RemoteJSON.milliseconds)
            if isFull { item.limit = self.limit(limit) }
        }
        return item
    }

    /// The limit as the provider reported it, which the card words in the reader's language (§15.24).
    private static func limit(_ limit: HarnessRateLimit) -> RemoteLimit {
        RemoteLimit(
            status: limit.status.rawValue, window: limit.window?.rawValue, model: limit.model, usedFraction: limit.usedFraction,
            overage: limit.isUsingOverage ? true : nil,
            windows: limit.windows.isEmpty ? nil : limit.windows.map {
                RemoteLimit.Window(window: $0.window.rawValue, model: $0.model, usedFraction: $0.usedFraction,
                                   resetsAt: $0.resetsAt.map(RemoteJSON.milliseconds))
            },
            message: RemoteText.short(limit.message, RemoteText.errorLimit))
    }

    // MARK: - Text

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Item IDs are unique across the conversation, as the phone's changes name items by ID. A repeat
    /// (one provider ID drawn twice) gets a suffix by its order.
    private static func uniqued(_ turns: [RemoteTurn]) -> [RemoteTurn] {
        var seen: [String: Int] = [:]
        return turns.map { turn in
            var turn = turn
            for index in turn.items.indices {
                let id = turn.items[index].id
                let count = seen[id, default: 0]
                seen[id] = count + 1
                if count > 0 { turn.items[index].id = "\(id)#\(count + 1)" }
            }
            return turn
        }
    }
}

/// The answers the phone may give a waiting request (§4.4 `answerApproval`, §15.13): "Allow once", the
/// narrowest allow the Mac's card offers — the same one the Mac notification's "Allow once" gives
/// (`NotificationApprovalProjection`) —, the card's allow for the rest of the session, and its plain
/// deny. Questions, plan reviews and forms go their own ways (§15.2); answers that write a standing
/// rule to a file or policy, and requests for more permissions, stay on the Mac.
enum RemoteApprovalPolicy {
    static func answers(for request: ConversationRequest) -> [RemoteApprovalAnswer] {
        [allowOnce(request) == nil ? nil : RemoteApprovalAnswer.allowOnce,
         allowForSession(request) == nil ? nil : .allowForSession,
         deny(request) == nil ? nil : .deny].compactMap { $0 }
    }

    static func route(for answer: RemoteApprovalAnswer, to request: ConversationRequest) -> ConversationRequestRoute? {
        switch answer {
        case .allowOnce: allowOnce(request)
        case .allowForSession: allowForSession(request)
        case .deny: deny(request)
        }
    }

    /// The card's allow that lasts for the rest of the task's session: Codex's "Allow for session" on
    /// a command or file change, Claude Code's suggestion kept for the session (which may switch its
    /// mode for the session too). Nil where the card has none, where its broader allow is kept in a
    /// settings file or a policy, and for a mode switch or a Codex request for more permissions.
    static func allowForSession(_ request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending, request.form == nil else { return nil }
        let route: ConversationRequestRoute
        switch request.source {
        case let .transcript(entry):
            guard case let .permission(permission, _) = entry.content, permission.structured == nil,
                  !permission.requiresInAppAnswer, permission.detail != "switch_mode",
                  let action = permission.actions.first(where: { $0.decision == .allow && isSessionScoped($0) })
            else { return nil }
            route = .providerAction(action)
        case let .codexServerRequest(state):
            switch state.kind {
            case .commandExecutionApproval: route = .codex(.command(.acceptForSession))
            case .fileChangeApproval: route = .codex(.fileChange(.acceptForSession))
            case .applyPatchApproval, .execCommandApproval: route = .codex(.legacyReview(.approvedForSession))
            default: return nil
            }
        case .codexApproval:
            return nil
        }
        // Only an answer the card itself offers.
        return request.responses.contains { $0.route == route } ? route : nil
    }

    /// Every answer the Mac's card gives a request without a question or plan form (§15.19), in its order and
    /// words, marking those that leave a rule beyond the task. Nil where the phone answers another way (questions
    /// and plan reviews), for one Yardlet answers nothing for, and for an MCP form Yardlet cannot fill.
    static func choices(for request: ConversationRequest) -> [RemoteChoice]? {
        guard request.state == .pending, request.unanswerableReason == nil, !request.responses.isEmpty else { return nil }
        switch request.form {
        case nil, .mcpForm?: break
        case .choices?, .freeText?, .planReview?: return nil
        }
        return request.responses.enumerated().map { index, response in
            let role = switch response.role {
            case .primary: "primary"
            case .secondary: "secondary"
            case .destructive: "destructive"
            }
            return RemoteChoice(id: String(index), title: RemoteText.capped(response.title, RemoteText.titleLimit).text,
                                role: role, standing: leavesStandingRule(response.route) ? true : nil,
                                text: response.text.map(RemoteLocalizedText.init))
        }
    }

    /// The answer approves later calls nobody has seen yet, beyond this task: a rule kept in a settings file or a
    /// policy, a Codex exec or network policy amendment, an MCP tool allowed for good. A one-time answer, one for
    /// the session, and a denial for this call only do not.
    static func leavesStandingRule(_ route: ConversationRequestRoute) -> Bool {
        switch route {
        case let .providerAction(action):
            return PermissionActionPreference.scope(id: action.id, intent: action.kind) == .broad && !isSessionScoped(action)
        case let .codex(response):
            switch response {
            case .command(.acceptWithExecpolicyAmendment), .command(.applyNetworkPolicyAmendment),
                 .legacyReview(.approvedExecpolicyAmendment), .legacyReview(.approvedMCPPolicyAmendment),
                 .legacyReview(.networkPolicyAmendment):
                return true
            case let .mcpElicitation(_, _, meta):
                return meta?["persist"]?.stringValue == "always"
            default:
                return false
            }
        case .decision, .answer, .structured:
            return false
        }
    }

    /// The answer allows more than the one call it answers: for the rest of the session, or by a rule kept beyond the
    /// task. A device chooses one only with its Terminal permission (§15.28); a one-time answer and a denial for this
    /// call need none.
    static func allowsBeyondCall(_ route: ConversationRequestRoute) -> Bool {
        if leavesStandingRule(route) { return true }
        switch route {
        case let .providerAction(action):
            return action.decision == .allow && isSessionScoped(action)
        case let .codex(response):
            switch response {
            case .command(.acceptForSession), .fileChange(.acceptForSession), .legacyReview(.approvedForSession):
                return true
            case let .permissions(_, scope, _):
                return scope == .session
            case let .mcpElicitation(action, _, meta):
                return action == .accept && meta?["persist"]?.stringValue == "session"
            default:
                return false
            }
        case .decision, .answer, .structured:
            return false
        }
    }

    /// A provider action that names the session as its scope and no standing rule.
    private static func isSessionScoped(_ action: PermissionRequestAction) -> Bool {
        let token = [action.kind ?? "", action.id].joined(separator: " ").lowercased()
        return token.contains("session") && !token.contains("always") && !token.contains("policy")
            && !token.contains("forever")
    }

    /// What only the Mac's card does, in one line (§15.13): the card's own reason when Yardlet answers
    /// nothing for it, the form or secret answer the phone does not take, or the answers it does not give.
    static func macNote(_ request: ConversationRequest, phoneAnswers: [RemoteApprovalAnswer]) -> String? {
        if let reason = request.unanswerableReason { return reason }
        switch request.form {
        case .mcpForm?:
            return L10n.string("Fill in this form on the Mac.")
        case .choices?, .freeText?:
            guard request.form?.questionSteps.contains(where: \.isSecret) == true else { return nil }
            return L10n.string("This question takes a secret answer. Answer it on the Mac.")
        case .planReview?:
            return L10n.string("Review this plan on the Mac.")
        case nil:
            let phone = phoneAnswers.compactMap { route(for: $0, to: request) }
            let others = request.responses.filter { !phone.contains($0.route) }.map(\.title)
            return others.isEmpty ? nil : L10n.format("Only on the Mac: %@", others.joined(separator: ", "))
        }
    }

    static func allowOnce(_ request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending, request.form == nil else { return nil }
        switch request.source {
        case let .transcript(entry):
            guard case let .permission(permission, _) = entry.content else { return nil }
            return NotificationApprovalProjection.allowOnce(for: permission)
        case let .codexServerRequest(state):
            return NotificationApprovalProjection.allowOnce(for: state)
        case .codexApproval:
            return nil
        }
    }

    static func deny(_ request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending, request.form == nil else { return nil }
        let routes = request.responses.filter { $0.role == .destructive }.map(\.route)
        if let action = PermissionActionPreference.preferred(from: request.providerActions, decision: .deny) {
            guard PermissionActionPreference.scope(id: action.id, intent: action.kind) != .broad,
                  routes.contains(.providerAction(action)) else { return nil }
            return .providerAction(action)
        }
        return routes.first { route in
            switch route {
            case .decision(.deny), .codex: true
            default: false
            }
        }
    }

    /// What a v2 phone may answer a form with (§15.2): a question form's answers, unless one is a
    /// secret, and a plan review's two answers. MCP forms stay on the Mac.
    static func formAnswers(for request: ConversationRequest) -> [String] {
        guard request.state == .pending, request.unanswerableReason == nil else { return [] }
        let structured = request.responses.contains { $0.route == .structured }
        switch request.form {
        case .choices?, .freeText?:
            let steps = request.form?.questionSteps ?? []
            guard structured, !steps.isEmpty else { return [] }
            // Only a phone that masks a secret answer is offered it (§15.19).
            return [steps.contains(where: \.isSecret) ? RemoteProtocol.answerSecretOption : RemoteProtocol.answerOption]
        case .planReview?:
            let approves = request.responses.contains { $0.route == .decision(.allow) }
            return structured && approves ? [RemoteProtocol.keepPlanningOption, RemoteProtocol.approvePlanOption] : []
        case .mcpForm?, nil:
            return []
        }
    }

    /// The Mac's card offers more than the phone does.
    static func hasMoreOnMac(_ request: ConversationRequest, phoneAnswers: Int) -> Bool {
        guard request.state == .pending else { return false }
        return request.form != nil || request.unanswerableReason != nil || request.responses.count > phoneAnswers
    }
}

extension RemoteLocalizedText {
    /// Words the Mac made from its catalog, as a client reads them (§15.19).
    init(_ text: LocalizedText) {
        self.init(key: text.isVerbatim ? nil : text.key, text: text.isVerbatim ? text.key : nil,
                  args: text.args.isEmpty ? nil : text.args.map(RemoteLocalizedText.init))
    }
}

extension LocalizedText {
    /// Words another Mac sent with their key; nil when they carry neither a key nor words.
    init?(_ remote: RemoteLocalizedText) {
        if let key = remote.key {
            var args: [LocalizedText] = []
            for arg in remote.args ?? [] {
                guard let text = LocalizedText(arg) else { return nil }
                args.append(text)
            }
            self.init(key)
            self.args = args
        } else if let text = remote.text {
            self = .verbatim(text)
        } else {
            return nil
        }
    }
}
