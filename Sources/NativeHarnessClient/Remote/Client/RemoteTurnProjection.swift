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
enum RemoteTurnProjection {
    /// Answers carried by a provider option, by the prefix of its ID.
    enum Route {
        static let choice = "choice:"
        static let answer = "answer:"
        static let handoff = "handoff:"
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
                turn.notices.append(line(item, details: details))
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
        switch item.kind {
        case .user:
            return message(item)
        case .assistant:
            let text = item.text ?? ""
            let streaming = item.streaming == true
            let kind: ConversationItemKind = switch item.role {
            case "commentary": .commentary(text: text, isStreaming: streaming)
            // A proposed plan is the agent's Markdown, drawn as its message.
            default: .answer(text: text, isStreaming: streaming)
            }
            return ConversationItem(id: item.id, kind: kind, phase: streaming ? .running : .completed,
                                    source: source(item, .assistant(text: text, isStreaming: streaming)))
        case .activity where item.activity == "reasoning":
            return ConversationItem(id: item.id, kind: .reasoning(summary: item.detail, detail: nil, isStreaming: item.status == "running"),
                                    phase: phase(item.status), source: source(item, .reasoning(text: item.detail ?? "", isStreaming: false)))
        case .activity, .notice:
            return line(item, details: details)
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

    private static func message(_ item: RemoteItem) -> ConversationItem {
        let text = item.text ?? ""
        return ConversationItem(id: item.id, kind: .userMessage(text: text, images: []), phase: .completed,
                                source: source(item, .user(text: text)))
    }

    /// A call, a step or a notice as one line in the host's words, which reads its output and changes once
    /// opened.
    private static func line(_ item: RemoteItem, details: [String: RemoteItemDetail]) -> ConversationItem {
        let title = item.kind == .notice ? item.text ?? "" : item.title ?? ""
        // The host's words, its verb drawn muted as here (§6.4); a host that sends none gives the whole title.
        let lines = item.words.map { $0.map { ConversationLineWords(leading: $0.leading ?? "", verb: $0.verb, trailing: $0.trailing ?? "") } }
        var tool = ConversationTool(kind: .worded(lines ?? [ConversationLineWords(verb: "", trailing: title)]), name: "",
                                    status: item.status)
        tool.isApproved = item.approved == true
        tool.detail = item.detail
        if let additions = item.additions, let deletions = item.deletions {
            tool.lineCounts = .init(additions: additions, deletions: deletions)
        }
        if let code = item.exitCode, code != 0 { tool.errorMessage = L10n.format("Exit code %lld", code) }
        let detail = item.hasDetail == true ? details[item.id] : nil
        if item.hasDetail == true {
            tool.loadsDetailOnOpen = true
            if let detail {
                // A change's line shows its diff; its output, when it has one, beside it.
                tool.output = detail.output ?? (detail.diffs.isEmpty ? "" : nil)
                tool.diffs = detail.diffs.map { HarnessActivityDiff(path: $0.path, unified: $0.patch) }
            }
        }
        let activity = HarnessActivity(id: item.id, kind: item.activity ?? "other", title: title, detail: item.detail)
        var line = ConversationItem(id: item.id, kind: .tool(tool), phase: phase(item.status),
                                    source: source(item, .activity(activity, state: activityState(item.status))))
        // What "Copy item details" takes, as a local line copies what it ran and returned.
        line.copyDetails = [title, item.detail, detail?.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return line
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
        // A plan limit reads as the turn's error here; the limit's own actions sit above the composer.
        let message = [item.message, item.resetsAt.map { L10n.format("Resets %@", date($0).formatted(date: .omitted, time: .shortened)) }]
            .compactMap { $0 }.joined(separator: "\n")
        return .error(ConversationTurnError(title: item.title, message: message, isRecoverable: item.recoverable == true,
                                            entryID: uuid(item.id)))
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
        let options = item.options ?? []
        let steps = item.questionSteps ?? []
        switch item.requestKind {
        case "planReview":
            request.form = .planReview(item.text ?? "")
            if options.contains(RemoteProtocol.approvePlanOption) { request.responses = ConversationRequestResponses.planReview }
        case "question", "form" where !steps.isEmpty || item.formFields == nil:
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
            }
        default:
            if item.formFields == nil, let choices = item.choices, !choices.isEmpty {
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
