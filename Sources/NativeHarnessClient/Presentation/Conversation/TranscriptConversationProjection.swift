import Foundation

/// The common transcript as the conversation model:
/// - every request (a sent message, or a Claude bash command) starts a turn; what comes before
///   the first request is a head turn with no prompt. A message the provider read into the running
///   turn (`TranscriptEntry.joinsRunningTurn`) stays in that turn's work where it was read, as the
///   Codex app keeps a steered message (D13);
/// - a turn that is over and ends on a settled assistant message has that message as its answer, and
///   so does one a message read into the running turn or a question the provider asked followed;
///   every other assistant message is commentary. A note Claude's API sent back as thinking
///   (`TranscriptEntry.isProgressUpdate`) is an assistant message, in a summary. That is the
///   transcript's part: the turn is laid out and folded by the rule every harness shares
///   (`ConversationTurnLayout`), which draws the closing answer under the work and keeps everything
///   else where it happened;
/// - an allowed request whose tool call has a card is a mark on that card, not a card of its own;
/// - a message reads what the Codex app shows of it (`ConversationAutomationText`): a Codex
///   automation's heartbeat is its instructions, and its reply and directives read as the app shows
///   them (by the app's rules in a Codex transcript, and only for exactly those shapes elsewhere).
/// Each turn keeps its entries' order (`recordOrder`); since M12e every turn is drawn in the turn
/// order (plan A5.1), its work in that order.
enum TranscriptConversationProjection {
    /// Everything one turn's projection reads. Equal inputs project equal turns, so a cache keeps a
    /// turn for as long as its input stays the same. What only the last turn reads is left empty
    /// for the others, so a new request or a status change does not project every turn again.
    struct TurnInput: Equatable, Sendable {
        /// The turn's entries as the transcript has them, folded requests included.
        let entries: [TranscriptEntry]
        /// The transcript's approved tool calls that this turn's cards or requests name. Approval
        /// is decided over the whole transcript (a request and its call can sit in different turns).
        let approvedToolCallIDs: Set<String>
        let harness: HarnessKind
        let isHead: Bool
        let isLast: Bool
        /// A later request follows, or the task marked its latest turn complete.
        let isComplete: Bool
        /// The session's status, for the last turn; nil for the others, which do not read it.
        let status: SessionStatus?
        /// Claude: the turn holds the latest message (its request, or one read into it), the one whose
        /// files can be restored.
        let isLatestMessage: Bool

        var id: String { entries[0].id.uuidString }
    }

    static func presentation(
        from entries: [TranscriptEntry],
        harness: HarnessKind,
        status: SessionStatus,
        latestTurnIsComplete: Bool
    ) -> ConversationPresentation {
        presentation(from: entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete) {
            $0.map(turn)
        }
    }

    /// The presentation with its turns projected by `projectTurns`, which a cache uses to keep
    /// unchanged turns.
    static func presentation(
        from entries: [TranscriptEntry],
        harness: HarnessKind,
        status: SessionStatus,
        latestTurnIsComplete: Bool,
        projectTurns: ([TurnInput]) -> [ConversationTurn]
    ) -> ConversationPresentation {
        ConversationPresentation(
            harness: harness,
            turns: projectTurns(turnInputs(
                entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete
            )),
            earlier: .none,
            pendingRequestIDs: Set(entries.compactMap { entry in
                guard case let .permission(request, .pending) = entry.content else { return nil }
                return request.id
            }),
            tokenUsage: nil
        )
    }

    static func turnInputs(
        _ entries: [TranscriptEntry],
        harness: HarnessKind,
        status: SessionStatus,
        latestTurnIsComplete: Bool
    ) -> [TurnInput] {
        let approved = approvedToolCallIDs(in: entries)
        let latestMessageID = harness == .claudeCode ? entries.last(where: isMessage)?.id : nil
        var inputs: [TurnInput] = []
        var start = entries.startIndex
        while start < entries.endIndex {
            let next = entries[entries.index(after: start)...].firstIndex(where: isRequest) ?? entries.endIndex
            let turn = entries[start..<next]
            let isLast = next == entries.endIndex
            inputs.append(TurnInput(
                entries: Array(turn),
                approvedToolCallIDs: approved.isEmpty ? [] : approved.intersection(turn.lazy.compactMap(toolCallID)),
                harness: harness,
                isHead: start == entries.startIndex && !isRequest(turn[start]),
                isLast: isLast,
                isComplete: !isLast || latestTurnIsComplete,
                status: isLast ? status : nil,
                isLatestMessage: latestMessageID.map { id in turn.contains { $0.id == id } } ?? false
            ))
            start = next
        }
        return inputs
    }

    /// Tool calls whose allowed request reads as a mark on the call's own card instead of a
    /// second card for the same action. A pending, denied or expired request keeps its card, as
    /// does an answered question or plan, whose answer is what its card shows.
    static func approvedToolCallIDs(in entries: [TranscriptEntry]) -> Set<String> {
        var activityIDs: Set<String> = []
        var approved: Set<String> = []
        for entry in entries {
            switch entry.content {
            case let .activity(activity, _):
                activityIDs.insert(activity.id)
            case let .permission(request, .allowed) where request.structured == nil:
                if let toolCallID = request.toolCallID { approved.insert(toolCallID) }
            default:
                break
            }
        }
        return approved.intersection(activityIDs)
    }

    // MARK: - Turns

    static func turn(_ input: TurnInput) -> ConversationTurn {
        let approved = input.approvedToolCallIDs
        // What the turn draws. An allowed request is a mark on its call's card, and a subagent's own
        // background task is a row of the line above the composer, under its subagent
        // (`BackgroundTasksProjection`). Neither is in the turn, so neither is its last word: a task a
        // background subagent starts after Claude answered leaves that answer the turn's answer
        // (2026-10-24: a final report read as a working note when one did).
        func isDrawn(_ entry: TranscriptEntry) -> Bool {
            if case let .activity(activity, _) = entry.content, activity.subtask?.isSubagentWork == true { return false }
            return approved.isEmpty || !isFolded(entry, approved: approved)
        }
        let shown = input.entries.allSatisfy(isDrawn) ? input.entries : input.entries.filter(isDrawn)
        let isBusy = input.status == .running || input.status == .waitingForApproval
        // The part of a turn a read began inside answers too once a later turn follows it: what it
        // ended with is that turn's answer (a final report shown above a background task's notice).
        let answerID: UUID? = if !input.isHead || !input.isLast, input.isComplete, let last = shown.last,
                                 let words = words(last), !words.isStreaming { last.id } else { nil }
        let outcomeID = shown.last(where: isOutcome)?.id
        // What the provider wrote right before a message read into the turn, with no call after it,
        // answered what came before that message, as a Codex final answer the person's next message
        // followed: the turn reads on with the next message, so that answer is not its last words. So
        // did what it wrote right before asking the person a question, which the question goes on from
        // ("change C and D to the wording above?").
        var answersBeforeReplies: Set<UUID> = []
        var lastWords: UUID?
        for entry in shown {
            if let words = words(entry) {
                if !words.isStreaming { lastWords = entry.id }
                continue
            }
            switch entry.content {
            case .reasoning: break
            case .user:
                if entry.joinsRunningTurn == true, let lastWords { answersBeforeReplies.insert(lastWords) }
                lastWords = nil
            default:
                if isQuestion(entry), let lastWords { answersBeforeReplies.insert(lastWords) }
                lastWords = nil
            }
        }
        // A Codex app automation's turn: its request is a heartbeat (`ConversationAutomationText`).
        let inHeartbeatTurn: Bool = if !input.isHead, case let .user(text, _) = input.entries[0].content {
            ConversationScheduledTaskMessage.parse(text) != nil
        } else {
            false
        }

        var prompt: [ConversationItem] = []
        var plan: ConversationPlan?
        // Everything after the request, in the order it happened; laid out below.
        var work: [ConversationItem] = []
        var requests: [ConversationRequest] = []
        var outcome: ConversationTurnOutcome?
        // A question call whose result recorded its answers reads as its answered card, read from
        // that record live and when the conversation is read back; the answered request the live
        // stream held for the same call is that card already.
        var answeredQuestionRequests: [String: PermissionRequest] = [:]
        var recordedQuestionCalls: Set<String> = []
        for entry in shown {
            switch entry.content {
            case let .activity(activity, _) where activity.answeredQuestions != nil:
                recordedQuestionCalls.insert(activity.id)
            case let .permission(request, state) where state != .pending:
                if case .questions = request.structured, let call = request.toolCallID {
                    answeredQuestionRequests[call] = request
                }
            default:
                break
            }
        }

        for entry in shown {
            switch entry.content {
            case .user where entry.origin == .provider:
                // A turn the provider started itself, whose request is not read yet: it shows none.
                continue
            case let .user(text, _) where entry.origin == .scheduled:
                // A prompt Claude Code's own schedule sent opens its turn as the schedule's, drawn as the
                // Claude app draws it, never as the person's bubble (`ClaudeScheduledPrompt`).
                let schedule = ClaudeScheduledPrompt.reading(text)
                let sent = item(entry, .scheduledTaskMessage(ConversationScheduledTaskMessage(
                    instructions: schedule.instructions, automationID: nil,
                    currentTimeISO: entry.createdAt.ISO8601Format(), claudeSchedule: schedule.kind
                )), .completed)
                if entry.id == input.entries[0].id, !input.isHead { prompt.append(sent) } else { work.append(sent) }
            case let .user(text, images):
                // A heartbeat, a Codex app automation's message, is its instructions in every harness.
                // Any other message is read for the request the Codex app wrote its context around:
                // every message of a Codex task, only that exact shape in another harness.
                // A message another task sent (`send_message`) is its body, from that task.
                let fromTask = TaskMessage.parse(text)
                // A background command's notice, which Claude Code wrote to start this turn.
                let notice = fromTask == nil && input.harness == .claudeCode ? ClaudeTaskNotification.parse(text) : nil
                let scheduled = fromTask == nil && notice == nil ? ConversationScheduledTaskMessage.parse(text) : nil
                let request = scheduled == nil && fromTask == nil && notice == nil
                    ? CodexUserPrompt.parse(text, harness: input.harness) : nil
                let message: ConversationItemKind = scheduled.map(ConversationItemKind.scheduledTaskMessage)
                    ?? .userMessage(text: fromTask?.body ?? notice?.summary ?? request?.request ?? text, images: images ?? [])
                var sent = item(entry, message, .completed)
                sent.taskMessage = fromTask
                sent.backgroundTaskNotice = notice
                if let attachments = request?.attachments, !attachments.isEmpty { sent.promptAttachments = attachments }
                if input.harness == .claudeCode, let command = ClaudeBashMessage.parse(text) {
                    prompt.append(item(entry, .shellCommand(command, entryID: entry.id), .completed))
                } else if entry.id == input.entries[0].id, !input.isHead {
                    prompt.append(sent)
                } else {
                    // Read into the running turn: in the work, where it was read (D13).
                    work.append(sent)
                }
            case .assistant,
                 .reasoning where entry.isProgressUpdate == true:
                // What the provider wrote: a message, or a note the API sent back as thinking, in a
                // summary, which the item marks (`ConversationItem.isSummary`). What the Codex app
                // shows of the message; a message it shows nothing of is left out.
                guard let words = words(entry), let text = ConversationAutomationText.agentMessage(
                    words.text, harness: input.harness, inHeartbeatTurn: inHeartbeatTurn, isStreaming: words.isStreaming
                ) else { continue }
                var said = if entry.id == answerID || answersBeforeReplies.contains(entry.id) {
                    item(entry, .answer(text: text, isStreaming: false), .completed)
                } else {
                    item(entry, .commentary(text: text, isStreaming: words.isStreaming),
                         words.isStreaming ? .running : .completed)
                }
                said.isSummary = entry.isProgressUpdate == true
                work.append(said)
            case let .reasoning(text, isStreaming):
                work.append(item(entry, .reasoning(summary: nil, detail: text, isStreaming: isStreaming),
                                 isStreaming ? .running : .completed))
            case let .activity(activity, _) where activity.answeredQuestions != nil:
                let request = answeredQuestions(activity, asked: answeredQuestionRequests[activity.id], entry: entry)
                work.append(item(entry, .request(request), .completed))
            case let .activity(activity, state):
                let kind = ConversationActivityProjection.kind(
                    activity, harness: input.harness, phase: phase(of: state), isApproved: approved.contains(activity.id)
                )
                var activityItem = item(entry, kind, phase(of: state))
                activityItem.copyDetails = ConversationActivityProjection.copyDetails(activity)
                work.append(activityItem)
            case let .permission(request, .pending):
                requests.append(conversationRequest(request, state: .pending, entry: entry))
            case let .permission(request, _) where request.toolCallID.map(recordedQuestionCalls.contains) == true
                && answeredQuestionRequests[request.toolCallID ?? ""]?.id == request.id:
                continue
            case let .permission(request, state):
                work.append(item(entry, .request(conversationRequest(request, state: state, entry: entry)),
                                 state == .expired ? .stopped : .completed))
            case let .plan(text):
                // The builder replaces a turn's plan as it changes; the latest one stands.
                var parsed = ConversationPlan.parse(text, stepIDPrefix: entry.id.uuidString)
                parsed.source = .transcript(entry)
                plan = parsed
            case let .error(message, recoverable, _):
                let error = ConversationTurnOutcome.error(ConversationTurnError(
                    title: nil, message: message, isRecoverable: recoverable, entryID: entry.id
                ))
                if entry.id == outcomeID { outcome = error } else { work.append(item(entry, .outcome(error), .failed)) }
            case let .usageLimit(limit):
                let stop = ConversationTurnOutcome.usageLimit(limit, entryID: entry.id)
                if entry.id == outcomeID { outcome = stop } else { work.append(item(entry, .outcome(stop), .failed)) }
            case let .compaction(compaction):
                let phase: ConversationItemPhase = switch compaction.phase {
                case .started: .running
                case .completed: .completed
                case .failed: .failed
                }
                work.append(item(entry, .compaction(compaction), phase))
            }
        }

        let status: ConversationTurnStatus = if input.isLast, isBusy {
            .running
        } else if outcome != nil {
            .failed
        } else if input.isComplete {
            .completed
        } else {
            .unknown(nil)
        }

        let arranged = ConversationTurnLayout.arrange(work)
        var result = ConversationTurn(
            id: input.id,
            status: status,
            timing: timing(shown, status: status),
            prompt: prompt,
            plan: plan,
            work: arranged.work,
            answers: arranged.answers,
            requests: requests,
            outcome: outcome
        )
        result.hasWorkDetails = plan != nil || !arranged.work.isEmpty
        // A running turn reads "Thinking" until the provider writes, as a Codex turn does (D12): the
        // one sign that a provider is responding, for every harness. A turn waiting on the person
        // is not thinking.
        if status == .running, requests.isEmpty, !work.contains(where: \.isVisibleAgentOutput) {
            result.progress = .thinking
        }
        result.actions = actions(input, outcome: outcome, isBusy: isBusy)
        // The turn header, as every harness draws it: the work time of a finished turn when its
        // entries' times give one (D4), the fold of its settled work, and the turn menu with what
        // the provider offers on the turn (D3).
        let showsWorkTime = !prompt.isEmpty && status.isTerminal && result.timing.durationMilliseconds != nil
        let offersMenu = result.actions.editLatest != nil || result.actions.restoreFiles != nil || result.actions.canFork
        result.showsHeader = (result.hasWorkDetails && result.foldsWork) || showsWorkTime || offersMenu
        result.recordOrder = shown.map(\.id.uuidString)
        return result
    }

    /// From the request (or the head's first entry) to the turn's last entry: the times the
    /// entries were made, not the provider's own (D4). A finished turn whose entries span less than
    /// a second (one read back at once, or with one entry) has no work time to show.
    private static func timing(_ entries: [TranscriptEntry], status: ConversationTurnStatus) -> ConversationTurnTiming {
        let startedAt = entries.first?.createdAt
        guard status == .completed || status == .failed, let startedAt, let endedAt = entries.last?.createdAt,
              endedAt.timeIntervalSince(startedAt) >= 1 else {
            return ConversationTurnTiming(startedAt: startedAt, isApproximate: true)
        }
        let milliseconds = max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
        return ConversationTurnTiming(
            startedAt: startedAt, completedAt: endedAt,
            durationMilliseconds: Int64(milliseconds.rounded()), isApproximate: true
        )
    }

    /// The rules for the request's menu and the error card:
    /// - Claude edits only its latest request, while idle, and never a bash command. The latest
    ///   request opens the last turn, so only the last turn can offer it.
    /// - File restore stays on the latest message, after any bash commands.
    /// - Claude forks from its latest turn only, while idle (D10).
    /// - "Edit request" puts back the failed request `TranscriptRecoveryProjection.editableRequest`
    ///   names. A later request rules it out, so it too is only the last turn's, and the rule
    ///   reads nothing past the turn. It reads as the turn's editable request (`failedRequestDraft`).
    /// - "Retry" is the last turn's, while idle, when the turn ended on an error its provider called
    ///   transient (`HarnessEventPayload.error`) and nothing came after it.
    /// Whether the host can carry these out is the actions' business, not the projection's.
    private static func actions(_ input: TurnInput, outcome: ConversationTurnOutcome?, isBusy: Bool) -> ConversationTurnActions {
        var actions = ConversationTurnActions()
        // A heartbeat is an automation's XML, which no edit puts back in the composer (the Codex app
        // offers none on it).
        func isHeartbeat(_ text: String) -> Bool {
            ConversationScheduledTaskMessage.parse(text) != nil || ClaudeTaskNotification.parse(text) != nil
        }
        if !input.isHead, case let .user(text, _) = input.entries[0].content, input.harness == .claudeCode {
            // The turn's latest message: its request, or the last one read into it.
            let latest = input.entries.last(where: isMessage)
            let target = latest.flatMap { entry -> ConversationMessageTarget? in
                guard case let .user(text, _) = entry.content else { return nil }
                return ConversationMessageTarget(entryID: entry.id, text: text)
            }
            if input.isLast, !isBusy, ClaudeBashMessage.parse(text) == nil, let target, !isHeartbeat(target.text) {
                actions.editLatest = target
            }
            if input.isLatestMessage, let target, !isHeartbeat(target.text) { actions.restoreFiles = target }
            // Claude forks its whole saved conversation, so only the latest turn offers it, once the
            // task is idle (D10).
            if input.isLast, !isBusy { actions.canFork = true }
        }
        if input.isLast, !isBusy, case .error(_, _, true?)? = input.entries.last?.content { actions.canRetry = true }
        if input.isLast, let status = input.status, case let .error(error)? = outcome, let entryID = error.entryID,
           let text = TranscriptRecoveryProjection.editableRequest(for: entryID, entries: input.entries, status: status),
           !isHeartbeat(text) {
            // A message another task sent edits as its body, and the edit goes as the person's.
            actions.editDraft = CodexComposerDraft(inputs: [.text(TaskMessage.parse(text)?.body ?? text)])
            actions.canEdit = true
        }
        return actions
    }

    // MARK: - Items

    private static func item(
        _ entry: TranscriptEntry,
        _ kind: ConversationItemKind,
        _ phase: ConversationItemPhase
    ) -> ConversationItem {
        ConversationItem(id: entry.id.uuidString, kind: kind, phase: phase, source: .transcript(entry))
    }

    private static func phase(of state: TranscriptActivityState) -> ConversationItemPhase {
        switch state {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
    }

    /// The card a request draws: the provider's own question form or plan, its own options when
    /// it sent them, and otherwise allow and deny.
    static func conversationRequest(
        _ request: PermissionRequest,
        state: TranscriptPermissionState,
        entry: TranscriptEntry
    ) -> ConversationRequest {
        let form: ConversationRequestForm? = switch request.structured {
        case let .questions(questions): .choices(questions)
        case let .plan(plan): .planReview(plan)
        case nil: nil
        }
        let requestState: ConversationRequestState = switch state {
        case .pending: .pending
        case .allowed: if case .questions = request.structured { .answered } else { .allowed }
        case .denied: .denied
        case .expired: .expired(message: nil)
        }
        return ConversationRequest(
            id: request.id,
            title: request.title,
            detail: request.detail,
            command: request.command,
            preview: request.preview,
            form: form,
            state: requestState,
            responses: state == .pending ? responses(for: request) : [],
            toolCallID: request.toolCallID,
            providerActions: request.actions,
            source: .transcript(entry)
        )
    }

    /// The answered card of a question call whose result recorded its answers: the questions it
    /// asked, read back from the call, with what each was answered with. Its title and heading are
    /// the request's the live stream held, when it held one.
    static func answeredQuestions(
        _ activity: HarnessActivity,
        asked request: PermissionRequest?,
        entry: TranscriptEntry
    ) -> ConversationRequest {
        let record = activity.answeredQuestions ?? HarnessAnsweredQuestions(questions: [], answers: [])
        var answers: [String: ConversationQuestionAnswer] = [:]
        for answer in record.answers {
            answers[answer.question] = ConversationQuestionAnswer(options: answer.selectedLabels, custom: answer.customAnswer)
        }
        return ConversationRequest(
            id: request?.id ?? activity.id,
            title: request?.title ?? L10n.string("Questions"),
            detail: request?.detail,
            form: .choices(record.questions),
            state: .answered,
            toolCallID: activity.id,
            recordedAnswers: answers,
            source: .transcript(entry)
        )
    }

    private static func responses(for request: PermissionRequest) -> [ConversationRequestResponse] {
        switch request.structured {
        case .questions: ConversationRequestResponses.questions
        case .plan: ConversationRequestResponses.planReview
        case nil: ConversationRequestResponses.plain(providerActions: request.actions)
        }
    }

    // MARK: - Entry kinds

    /// What starts a turn: a request, unless the provider read it into the turn already running.
    private static func isRequest(_ entry: TranscriptEntry) -> Bool {
        entry.opensTurn
    }

    /// A message the person sent, a request or one read into a turn, rather than a bash command or a
    /// prompt someone else sent (`TranscriptEntry.origin`), which is no message to edit or restore to.
    private static func isMessage(_ entry: TranscriptEntry) -> Bool {
        guard entry.origin == nil else { return false }
        if case let .user(text, _) = entry.content { return ClaudeBashMessage.parse(text) == nil }
        return false
    }

    /// What the provider wrote to the person: a message, or a note it wrote between tool calls that
    /// the API sent back as thinking (`TranscriptEntry.isProgressUpdate`).
    private static func words(_ entry: TranscriptEntry) -> (text: String, isStreaming: Bool)? {
        switch entry.content {
        case let .assistant(text, isStreaming): (text, isStreaming)
        case let .reasoning(text, isStreaming) where entry.isProgressUpdate == true: (text, isStreaming)
        default: nil
        }
    }

    /// The provider asking the person a question: Claude Code's `AskUserQuestion` call, or the
    /// question form a request brought.
    private static func isQuestion(_ entry: TranscriptEntry) -> Bool {
        switch entry.content {
        case let .activity(activity, _):
            activity.kind == ClaudeAnswerableTool.askUserQuestion || activity.answeredQuestions != nil
        case let .permission(request, _):
            if case .questions = request.structured { true } else { false }
        default:
            false
        }
    }

    private static func isOutcome(_ entry: TranscriptEntry) -> Bool {
        switch entry.content {
        case .error, .usageLimit: true
        default: false
        }
    }

    /// The tool call an entry names: an activity's own ID, or the call an allowed request is for.
    private static func toolCallID(_ entry: TranscriptEntry) -> String? {
        switch entry.content {
        case let .activity(activity, _): activity.id
        case let .permission(request, _): request.toolCallID
        default: nil
        }
    }

    /// An allowed request shown as the mark on its tool call's card.
    private static func isFolded(_ entry: TranscriptEntry, approved: Set<String>) -> Bool {
        guard case let .permission(request, .allowed) = entry.content, request.structured == nil,
              let toolCallID = request.toolCallID else { return false }
        return approved.contains(toolCallID)
    }
}

extension ConversationProjectionCache {
    /// A shared-transcript conversation, projecting again only the turns whose input changed.
    func transcript(
        _ entries: [TranscriptEntry],
        harness: HarnessKind,
        status: SessionStatus,
        latestTurnIsComplete: Bool
    ) -> ConversationPresentation {
        if let last = lastTranscript, last.harness == harness, last.status == status,
           last.latestTurnIsComplete == latestTurnIsComplete, last.entries.sharesStorage(with: entries) {
            return keptWhole(last.presentation)
        }
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete
        ) { inputs in
            turns(inputs.map { (id: $0.id, input: $0) }, project: TranscriptConversationProjection.turn)
        }
        lastTranscript = (entries, harness, status, latestTurnIsComplete, presentation)
        return presentation
    }
}

extension Array {
    /// The very same array handed on: the same storage and count, known without comparing elements.
    func sharesStorage(with other: [Element]) -> Bool {
        count == other.count && withUnsafeBufferPointer { mine in
            other.withUnsafeBufferPointer { $0.baseAddress == mine.baseAddress }
        }
    }
}

extension TranscriptEntry {
    /// A request, which opens a turn: a message the person sent or a Claude bash command, other than
    /// a message the provider read into the turn that was running (`joinsRunningTurn`).
    var opensTurn: Bool {
        if case .user = content { return joinsRunningTurn != true }
        return false
    }
}
