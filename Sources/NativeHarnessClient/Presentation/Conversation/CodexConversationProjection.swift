import Foundation
import YardletAgentTools

/// A Codex task's typed state as the conversation model (plan A3.1): one turn per provider turn,
/// its items placed by `CodexTurnLayout`, its requests, changes and history matches looked up per
/// turn, and what the turn offers.
///
/// It draws what `CodexTaskTimeline` draws, with the decided differences (plan A10): requests whose
/// turn is unknown stay hidden, and an approval that is also a server request is drawn once, as
/// the server request; a waiting request is pinned under its turn while an answered one joins the
/// turn's work and folds with it (D1, M12a), every request answered through the one request card
/// (`CodexRequestResponseProjection`). A message steered into the turn after its work began is in
/// the work where the provider took it, as the Codex app shows it (D13), and so is everything Codex
/// wrote but the answer that closes the turn: the turn is laid out and folded by the rule every
/// harness shares (`ConversationTurnLayout`). Codex's own part is how it reads its messages: a
/// `commentary` message is working notes, a message sent while the work went on (`delivery: "async"`)
/// is said to the person but never answers the turn, and any other message answers.
enum CodexConversationProjection {
    /// Everything one turn's projection reads. Equal inputs project equal turns, so a cache keeps
    /// a turn for as long as its input stays the same.
    struct TurnInput: Equatable, Sendable {
        let turn: CodexTurnState
        let workspaceURL: URL
        /// The thread has more than one turn.
        let showsTurnLabel: Bool
        let isLatest: Bool
        /// The turn is the one whose request can be edited now.
        let isEditable: Bool
        let canRetry: Bool
        /// The turn's approvals and server requests, by ID.
        let approvals: [CodexApprovalState]
        let serverRequests: [CodexServerRequestState]
        let history: HistoryMatch
        /// What the person sent first after a turn that ended on questions: the next turn's first
        /// message, which may be the reply to them. Nil for any other turn.
        var nextMessage: String? = nil
    }

    /// Which items a history result marks.
    enum HistoryMatch: Equatable, Sendable {
        case none
        /// The result names one provider item that the thread holds.
        case item(turnID: String, itemID: String)
        /// Items whose text holds the query.
        case query(String)
    }

    static func presentation(
        _ state: CodexTaskState,
        workspaceURL: URL,
        historySelection: CodexHistorySearchSelection?
    ) -> ConversationPresentation {
        presentation(state, workspaceURL: workspaceURL, historySelection: historySelection) { inputs in
            inputs.map(turn)
        }
    }

    /// The presentation with its turns projected by `projectTurns`, which a cache uses to keep
    /// unchanged turns.
    static func presentation(
        _ state: CodexTaskState,
        workspaceURL: URL,
        historySelection: CodexHistorySearchSelection?,
        projectTurns: ([TurnInput]) -> [ConversationTurn]
    ) -> ConversationPresentation {
        guard let thread = state.thread else { return ConversationPresentation(harness: .codex, turns: []) }
        return ConversationPresentation(
            harness: .codex,
            turns: projectTurns(turnInputs(state, workspaceURL: workspaceURL, historySelection: historySelection)),
            earlier: thread.turnsNextCursor.map { .provider(cursor: $0) } ?? .none,
            pendingRequestIDs: pendingRequestIDs(in: state),
            tokenUsage: thread.turns.last?.tokenUsage
        )
    }

    static func turnInputs(
        _ state: CodexTaskState,
        workspaceURL: URL,
        historySelection: CodexHistorySearchSelection?
    ) -> [TurnInput] {
        guard let thread = state.thread else { return [] }
        let editableTurnID = CodexTurnLayout.editableTurnID(in: thread)
        let latestTurnID = thread.turns.last?.id
        let retryableTurnID = latestTurnID.flatMap {
            CodexTurnRecoveryProjection.canRetry($0, in: state) ? $0 : nil
        }
        let (approvals, serverRequests) = requestsByTurn(state)
        let history = historyMatch(in: thread, selection: historySelection)
        return thread.turns.enumerated().map { index, turn in
            let next = thread.turns.indices.contains(index + 1) ? thread.turns[index + 1] : nil
            return TurnInput(
                turn: turn,
                workspaceURL: workspaceURL,
                showsTurnLabel: thread.turns.count > 1,
                isLatest: turn.id == latestTurnID,
                isEditable: turn.id == editableTurnID,
                canRetry: turn.id == retryableTurnID,
                approvals: approvals[turn.id] ?? [],
                serverRequests: serverRequests[turn.id] ?? [],
                history: history,
                nextMessage: askedQuestions(in: turn).questions.isEmpty ? nil : next.flatMap { firstMessage(in: $0) }
            )
        }
    }

    /// The requests waiting for an answer, as the timeline counts them.
    static func pendingRequestIDs(in state: CodexTaskState) -> Set<String> {
        Set(state.approvalsByID.values.filter { $0.turnID != nil && $0.resolution == .pending }.map(\.id))
            .union(state.serverRequestsByID.values.filter { $0.turnID != nil && $0.resolution == .pending }.map(\.id))
    }

    /// Each turn's approvals and server requests, by turn ID. Grouped by ID, so the dictionaries'
    /// order never changes a turn's input (the turn orders its requests itself).
    static func requestsByTurn(_ state: CodexTaskState)
        -> (approvals: [String: [CodexApprovalState]], serverRequests: [String: [CodexServerRequestState]]) {
        func byID(_ lhs: String, _ rhs: String) -> Bool { lhs.compare(rhs, options: [.numeric, .literal]) == .orderedAscending }
        var approvals: [String: [CodexApprovalState]] = [:]
        for approval in state.approvalsByID.values.sorted(by: { byID($0.id, $1.id) }) {
            if let turnID = approval.turnID { approvals[turnID, default: []].append(approval) }
        }
        var serverRequests: [String: [CodexServerRequestState]] = [:]
        for request in state.serverRequestsByID.values.sorted(by: { byID($0.id, $1.id) }) {
            if let turnID = request.turnID { serverRequests[turnID, default: []].append(request) }
        }
        return (approvals, serverRequests)
    }

    /// A turn's requests in the order the turn draws them. An approval that is also a server request
    /// is drawn once, as the server request. Requests keep one order however the state's
    /// dictionaries hold them: by the item each asks about, then by ID.
    static func requests(
        in turn: CodexTurnState, approvals: [CodexApprovalState], serverRequests: [CodexServerRequestState]
    ) -> [ConversationRequest] {
        guard !approvals.isEmpty || !serverRequests.isEmpty else { return [] }
        var itemPositions: [String: Int] = [:]
        for (index, item) in turn.items.enumerated() where itemPositions[item.id] == nil { itemPositions[item.id] = index }
        return (approvals
            .filter { approval in !serverRequests.contains { $0.id == approval.id } }
            .map(CodexRequestResponseProjection.request)
            + serverRequests.map(CodexRequestResponseProjection.request))
            .sorted { ConversationRequest.providerOrder($0, $1, itemPositions: itemPositions) }
    }

    /// The requests waiting under the turns `presentation` draws, in its order, read without
    /// projecting any turn's items: what a subagent waits on the person for, checked on every
    /// state it streams.
    static func pendingRequests(in state: CodexTaskState) -> [ConversationRequest] {
        guard let thread = state.thread else { return [] }
        let waitingTurnIDs = Set(state.approvalsByID.values.filter { $0.resolution == .pending }.compactMap(\.turnID))
            .union(state.serverRequestsByID.values.filter { $0.resolution == .pending }.compactMap(\.turnID))
        guard !waitingTurnIDs.isEmpty else { return [] }
        let (approvals, serverRequests) = requestsByTurn(state)
        return thread.turns.filter { waitingTurnIDs.contains($0.id) }.flatMap { turn in
            requests(in: turn, approvals: approvals[turn.id] ?? [], serverRequests: serverRequests[turn.id] ?? [])
                .filter { $0.state == .pending }
        }
    }

    /// The latest turn's items after its request, as `turn` arranges them, and how each one shows,
    /// for the readers below that project only the few items they need. An item is shown without
    /// what "Copy item details" copies, and a file change without its handoffs, which none reads.
    private static func latestWork(in state: CodexTaskState, workspaceURL: URL)
        -> (turn: CodexTurnState, items: [CodexItemState], shown: (CodexItemState) -> ConversationItem?)? {
        guard let turn = state.thread?.turns.last else { return nil }
        let isFinished = turn.status.isTerminal
        let inHeartbeatTurn = isHeartbeatTurn(turn)
        let workIDs = Set(CodexTurnLayout(turn: turn).workItems.map(\.id)).union(steeredMessageIDs(in: turn))
        return (turn, turn.items.filter { workIDs.contains($0.id) }, { item in
            shownItem(item, turnID: turn.id, isTurnFinished: isFinished, workspaceURL: workspaceURL, changes: [],
                      isHistoryMatch: false, inHeartbeatTurn: inHeartbeatTurn, copiesDetails: false)
        })
    }

    /// What `AppModel.latestAnswer` reads in the latest turn `presentation` draws, without projecting
    /// the turn's other items: the messages said to the person in its work, and of what follows the
    /// last of them only as much as decides whether that one closes the turn (`ConversationTurnLayout`).
    static func latestAnswer(in state: CodexTaskState, workspaceURL: URL) -> String? {
        guard case let (_, items, shown)? = latestWork(in: state, workspaceURL: workspaceURL) else { return nil }
        var said: [ConversationItem] = []
        var lastSaidIndex = 0
        for (index, item) in items.enumerated() {
            guard case .agentMessage = item.content, let shown = shown(item), case .answer = shown.kind else { continue }
            said.append(shown)
            lastSaidIndex = index
        }
        guard let last = said.last else { return nil }
        let closes = !last.isSentWhileWorking
            && items[(lastSaidIndex + 1)...].lazy.compactMap(shown).allSatisfy(ConversationTurnLayout.leavesAnswerLast)
        return ConversationTurnLayout.latestAnswer(answers: closes ? [last] : [],
                                                   work: closes ? Array(said.dropLast()) : said)
    }

    /// The last item of the latest turn `presentation` draws, the last of its work and answers, read
    /// without projecting the turn's other items: what a running subagent's card says it does.
    static func lastItem(in state: CodexTaskState, workspaceURL: URL) -> ConversationItem? {
        guard case let (turn, items, shown)? = latestWork(in: state, workspaceURL: workspaceURL) else { return nil }
        // The answers go under the work: the closing answer and every proposed plan, in order.
        var lastShown: ConversationItem?
        var closing: (index: Int, item: ConversationItem)?
        for index in items.indices.reversed() {
            guard let item = shown(items[index]) else { continue }
            if lastShown == nil { lastShown = item }
            if ConversationTurnLayout.leavesAnswerLast(item) { continue }
            if case .answer = item.kind, !item.isSentWhileWorking { closing = (index, item) }
            break
        }
        let lastPlan = items.lastIndex { if case .plan = $0.content { true } else { false } }
        if let lastPlan, lastPlan > closing?.index ?? -1 { return shown(items[lastPlan]) }
        if let closing { return closing.item }
        // No answers: the work ends with its last item, or an answered request placed after it or
        // at the work's end.
        let (approvals, serverRequests) = requestsByTurn(state)
        let answered = requests(in: turn, approvals: approvals[turn.id] ?? [],
                                serverRequests: serverRequests[turn.id] ?? []).filter { $0.state != .pending }
        guard !answered.isEmpty else { return lastShown }
        let workIDs = Set(items.filter { item in
            guard case .agentMessage = item.content else { return true }
            return shown(item) != nil
        }.map(\.id))
        let atEnd = answered.filter { request in request.toolCallID.map { !workIDs.contains($0) } ?? true }
        let placed = atEnd.isEmpty ? answered.filter { $0.toolCallID != nil && $0.toolCallID == lastShown?.id } : atEnd
        guard let request = placed.last else { return lastShown }
        return placingAnsweredRequests([request], in: [], turnID: turn.id).last
    }

    static func turn(_ input: TurnInput) -> ConversationTurn {
        let turn = input.turn
        let layout = CodexTurnLayout(turn: turn)
        let isFinished = turn.status.isTerminal
        let historyItemIDs = historyItemIDs(in: turn, match: input.history)
        let changes = CodexWorkSurfaceProjection.changes(in: turn, workspaceURL: input.workspaceURL)
        let inHeartbeatTurn = isHeartbeatTurn(turn)
        func project(_ items: [CodexItemState]) -> [ConversationItem] {
            items.compactMap { codexItem in
                shownItem(
                    codexItem, turnID: turn.id, isTurnFinished: isFinished, workspaceURL: input.workspaceURL,
                    changes: changes, isHistoryMatch: historyItemIDs.contains(codexItem.id),
                    inHeartbeatTurn: inHeartbeatTurn
                )
            }
        }

        var result = ConversationTurn(
            id: turn.id,
            status: status(turn.status),
            timing: ConversationTurnTiming(
                startedAt: turn.startedAt, completedAt: turn.completedAt,
                durationMilliseconds: turn.durationMilliseconds, isApproximate: false
            )
        )
        let steered = steeredMessageIDs(in: turn)
        result.prompt = project(layout.userItems.filter { !steered.contains($0.id) })
        result.notices = project(layout.noticeItems)
        result.plan = turn.plan.map(plan)
        // Everything after the request in the order Codex wrote it, laid out by the rule every harness
        // shares: only the answer that closes the turn goes under the work.
        let workIDs = Set(layout.workItems.map(\.id)).union(steered)
        let arranged = ConversationTurnLayout.arrange(project(turn.items.filter { workIDs.contains($0.id) }))
        result.answers = arranged.answers
        // A waiting request is pinned under the turn; an answered one joins the work after the item
        // it asked about, or at the end of the work (D1).
        let requests = requests(in: turn, approvals: input.approvals, serverRequests: input.serverRequests)
        result.requests = requests.filter { $0.state == .pending }
        result.work = placingAnsweredRequests(requests.filter { $0.state != .pending }, in: arranged.work, turnID: turn.id)
        result.outcome = outcome(turn)
        // A message whose words are all markup the app does not show (a heartbeat reply being written)
        // has not written yet, as the Codex app keeps its placeholder up for it.
        let hasAgentOutput = layout.hasAgentOutput
            && (result.work + result.answers).contains(where: \.isVisibleAgentOutput)
        if turn.status == .inProgress, let reconnecting = CodexTurnErrorPresentation.reconnectStatus(turn.retryingError) {
            result.progress = .reconnecting(reconnecting)
        } else if CodexTurnProgressProjection.showsThinking(status: turn.status, hasAgentOutput: hasAgentOutput),
                  result.requests.isEmpty {
            // A turn waiting on the person is not thinking (D12), as the Codex app stops its
            // thinking line while a request blocks the turn.
            result.progress = .thinking
        }
        result.hasWorkDetails = turn.plan != nil || !result.work.isEmpty || turn.itemsNextCursor != nil
        result.hasMoreItems = turn.itemsNextCursor.map { !$0.isEmpty } ?? false
        result.showsHeader = CodexTurnLayout.showsHeader(
            turn, showsTurnLabel: input.showsTurnLabel, hasUserMessage: layout.hasUserMessage,
            hasWorkDetails: result.hasWorkDetails
        )
        // A heartbeat's request is the automation's XML, which the Codex app offers no edit of: the turn
        // puts nothing back in the composer, from its menu or its error card. Nor does a reply to
        // questions, whose words are the reply's JSON.
        let isReplyTurn = firstMessage(in: turn).map { CodexAsyncQuestionReply.answers(in: $0) != nil } ?? false
        let editDraft = inHeartbeatTurn || isReplyTurn ? nil : turn.userInputDraft
        let asked = askedQuestions(in: turn)
        let reply = asked.reply ?? input.nextMessage
        let replyAnswers = reply.flatMap { answers(to: asked.questions, in: $0) }
        result.actions = ConversationTurnActions(
            editDraft: editDraft,
            canEdit: input.isEditable && !inHeartbeatTurn,
            canFork: isFinished,
            canRetry: input.canRetry,
            planToImplement: input.isLatest ? CodexPlanImplementation.offeredPlan(in: turn) : nil,
            // While the turn runs, the questions it asked that no reply answered yet, as the Codex app
            // offers them in its question panel; once it ended, those of its last message.
            questionsToAnswer: !input.isLatest ? [] : isFinished ? (reply == nil ? asked.questions : [])
                : pendingQuestions(in: turn),
            answeredQuestions: replyAnswers.map { ConversationAnsweredAsyncQuestions(questions: asked.questions, answers: $0) },
            editsTurnInComposer: editDraft != nil
        )
        return result
    }

    /// The item as the conversation shows it, after the Codex app's markup (`ConversationAutomationText`):
    /// a message reads what the app shows of it, and one the app shows nothing of is left out (nil).
    static func shownItem(
        _ item: CodexItemState,
        turnID: String,
        isTurnFinished: Bool,
        workspaceURL: URL,
        changes: [CodexChangeHandoff],
        isHistoryMatch: Bool,
        inHeartbeatTurn: Bool,
        copiesDetails: Bool = true
    ) -> ConversationItem? {
        var projected = self.item(
            item, turnID: turnID, isTurnFinished: isTurnFinished, workspaceURL: workspaceURL, changes: changes,
            isHistoryMatch: isHistoryMatch, copiesDetails: copiesDetails
        )
        guard case let .agentMessage(message) = item.content else { return projected }
        // The app reads a message as being written only while its turn runs.
        let isStreaming = item.lifecycle == .inProgress && !isTurnFinished
        // A message that asks questions reads as their titles; their options are answered below the
        // turn, as the Codex app shows them (`requestUserInputAsync`).
        let source = message.questions.isEmpty ? message.text : message.questions.map(\.title).joined(separator: "\n\n")
        guard let text = ConversationAutomationText.agentMessage(
            source, harness: .codex, inHeartbeatTurn: inHeartbeatTurn, isStreaming: isStreaming
        ) else { return nil }
        switch projected.kind {
        case let .answer(_, isStreaming): projected.kind = .answer(text: text, isStreaming: isStreaming)
        case let .commentary(_, isStreaming): projected.kind = .commentary(text: text, isStreaming: isStreaming)
        default: break
        }
        return projected
    }

    /// The questions Codex asked in a running turn that no reply in it answered yet, in the order it
    /// asked them, which the Codex app offers in its question panel while the work goes on (`y7t`): a
    /// reply names the questions it answers (`CodexAsyncQuestionReply`).
    static func pendingQuestions(in turn: CodexTurnState) -> [CodexAsyncQuestion] {
        guard turn.status == .inProgress else { return [] }
        var answered: Set<String> = []
        for item in turn.items {
            guard case let .userMessage(message) = item.content,
                  let replied = CodexAsyncQuestionReply.answers(in: message.sentContent.text) else { continue }
            answered.formUnion(replied.map(\.questionItemID))
        }
        return turn.items.flatMap { item -> [CodexAsyncQuestion] in
            guard case let .agentMessage(message) = item.content else { return [] }
            return message.questions.filter { !answered.contains($0.itemID) }
        }
    }

    /// The questions of the turn's last message when that message asks any and nothing the person
    /// sent follows it.
    static func questionsToAnswer(in turn: CodexTurnState) -> [CodexAsyncQuestion] {
        let asked = askedQuestions(in: turn)
        return asked.reply == nil ? asked.questions : []
    }

    /// The questions the turn's last message asks, and the first message the person sent after it in
    /// the turn (steered in while it ran), which may be the reply to them.
    static func askedQuestions(in turn: CodexTurnState) -> (questions: [CodexAsyncQuestion], reply: String?) {
        var reply: String?
        for item in turn.items.reversed() {
            switch item.content {
            case let .agentMessage(message):
                return (message.questions, reply)
            case let .userMessage(message):
                reply = message.sentContent.text
            default:
                continue
            }
        }
        return ([], nil)
    }

    /// The turn's first message from the person.
    static func firstMessage(in turn: CodexTurnState) -> String? {
        for item in turn.items {
            if case let .userMessage(message) = item.content { return message.sentContent.text }
        }
        return nil
    }

    /// What `reply` answered of `questions`, by each question's `itemID`, or nil when it is no reply
    /// to them: the Codex app's reply (`CodexAsyncQuestionReply`) naming them, or the reply Yardlet
    /// sent before it wrote that one (an option alone, or a question's title over its option). An
    /// answer that names one of the question's options is that option, any other the person's own
    /// words.
    static func answers(to questions: [CodexAsyncQuestion], in reply: String) -> [String: ConversationQuestionAnswer]? {
        guard !questions.isEmpty else { return nil }
        func answer(_ value: String, to question: CodexAsyncQuestion) -> ConversationQuestionAnswer {
            question.options.contains(value) ? ConversationQuestionAnswer(options: [value])
                : ConversationQuestionAnswer(custom: value)
        }
        if let replied = CodexAsyncQuestionReply.answers(in: reply) {
            var answers: [String: ConversationQuestionAnswer] = [:]
            for entry in replied {
                guard let question = questions.first(where: { $0.itemID == entry.questionItemID }) else { continue }
                let value = entry.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { answers[question.itemID] = answer(value, to: question) }
            }
            return replied.contains { entry in questions.contains { $0.itemID == entry.questionItemID } } ? answers : nil
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if questions.count == 1, questions[0].options.contains(text) {
            return [questions[0].itemID: ConversationQuestionAnswer(options: [text])]
        }
        for question in questions {
            if let option = question.options.first(where: { text == "\(question.title)\n\($0)" }) {
                return [question.itemID: ConversationQuestionAnswer(options: [option])]
            }
        }
        return nil
    }

    /// A turn a Codex app automation opened: its first sent message is a heartbeat.
    static func isHeartbeatTurn(_ turn: CodexTurnState) -> Bool {
        for item in turn.items {
            if case let .userMessage(message) = item.content {
                return ConversationScheduledTaskMessage.parse(message.sentContent.text) != nil
            }
        }
        return false
    }

    static func item(
        _ item: CodexItemState,
        turnID: String,
        isTurnFinished: Bool,
        workspaceURL: URL,
        changes: [CodexChangeHandoff],
        isHistoryMatch: Bool,
        copiesDetails: Bool = true
    ) -> ConversationItem {
        let isRunning = item.lifecycle == .inProgress
        var phase: ConversationItemPhase = isRunning ? (isTurnFinished ? .stopped : .running) : .completed
        let kind: ConversationItemKind
        var prompt: CodexUserPrompt?
        var taskMessage: TaskMessage?
        switch item.content {
        case let .userMessage(message):
            let sent = message.sentContent
            // A heartbeat is a whole message; any other is read for the request the Codex app wrote
            // its context around. A message another task sent (`send_message`) is its body.
            if let message = TaskMessage.parse(sent.text) {
                taskMessage = message
                kind = .userMessage(text: message.body, images: sent.images)
            } else if let scheduled = ConversationScheduledTaskMessage.parse(sent.text) {
                kind = .scheduledTaskMessage(scheduled)
            } else if let replied = CodexAsyncQuestionReply.answers(in: sent.text) {
                // A reply to questions reads as what it answered, not its JSON.
                kind = .userMessage(text: CodexAsyncQuestionReply.readableText(replied), images: sent.images)
            } else if let request = CodexUserPrompt.parse(sent.text, harness: .codex) {
                prompt = request
                kind = .userMessage(text: request.request, images: sent.images)
            } else {
                kind = .userMessage(text: sent.text, images: sent.images)
            }
        case let .agentMessage(message):
            // Working notes read as commentary; anything else is said to the person, whether it closes
            // the turn or the turn went on past it (a question asked while the work went on).
            if message.isCommentary {
                kind = .commentary(text: message.text, isStreaming: isRunning)
            } else {
                kind = .answer(text: message.text, isStreaming: isRunning)
            }
        case let .plan(text):
            kind = .proposedPlan(text: text, isWriting: isRunning && !isTurnFinished)
        case let .reasoning(summary, content):
            kind = .reasoning(
                summary: CodexReasoningProjection.text(from: summary),
                detail: CodexReasoningProjection.text(from: content),
                isStreaming: isRunning
            )
        case let .commandExecution(command):
            kind = .command(ConversationCommand(
                command: command.command, workingDirectory: command.workspacePath, status: command.status,
                output: command.aggregatedOutput, exitCode: command.exitCode,
                durationMilliseconds: command.durationMilliseconds,
                liveOutputHeadByteCount: command.liveOutputHeadByteCount,
                actions: ConversationCommandAction.actions(from: command.actions)
            ))
            phase = commandPhase(command.status, isTurnFinished: isTurnFinished) ?? phase
        case let .fileChange(change):
            let rows = CodexFileChangeCardProjection.rows(
                for: change, isTurnFinished: isTurnFinished, workspaceURL: workspaceURL
            )
            kind = .fileChange(ConversationFileChange(rows: rows, handoffs: changes.filter { $0.itemID == item.id }))
            switch CodexFileChangeCardProjection.state(for: change.status, isTurnFinished: isTurnFinished) {
            case .inProgress: phase = .running
            case .stopped: phase = .stopped
            case .applied: phase = .completed
            case .rejected: phase = .failed
            }
        case let .mcpToolCall(tool):
            let failed = isFailure(tool.status) || tool.errorMessage != nil
            if !failed, tool.status == "completed", let suggestion = ConversationTaskSuggestionProjection.suggestion(from: tool) {
                kind = .taskSuggestion(suggestion)
            } else if !failed, tool.status == "completed", let creation = ConversationScheduleProjection.creation(from: tool) {
                kind = .scheduleCreated(creation)
            } else if let run = ConversationAgentRunProjection.subagent(from: tool) {
                kind = .subagent(run)
            } else {
                // A Yardlet connector's tool reads as the connector's, not the `yardlet` server's.
                let connector = tool.server == AgentToolEnvironment.serverName
                    ? ConnectorToolLabels.shared.label(forTool: tool.tool) : nil
                kind = .tool(ConversationTool(
                    kind: .mcp, name: connector.map { "\($0.connector) · \($0.tool)" } ?? "\(tool.server) · \(tool.tool)",
                    status: tool.status, input: tool.arguments.readableText, errorMessage: tool.errorMessage,
                    mcpResult: CodexMCPResultProjection(result: tool.result, itemID: item.id),
                    connector: connector
                ))
            }
            if failed { phase = .failed }
        case let .dynamicToolCall(tool):
            kind = .tool(ConversationTool(
                kind: .dynamic, name: tool.tool, status: tool.status, input: tool.arguments.readableText,
                output: text(of: tool.contentItems)
            ))
            if isFailure(tool.status) || tool.succeeded == false { phase = .failed }
        case let .collaboration(collaboration):
            // A spawned agent is named by what it was asked, as the rail's Agents card names it; the
            // call keeps its own name as the card's kind.
            let isSpawn = SessionRailAgents.spawnTools.contains(collaboration.tool)
            kind = .subagent(ConversationSubagent(
                title: (isSpawn ? ConversationSubagent.name(asked: collaboration.prompt) : nil) ?? collaboration.tool,
                status: collaboration.status,
                detail: collaboration.receiverThreadIDs.joined(separator: ", "),
                routes: collaboration.receiverThreadIDs.map(ConversationSubagentRoute.codexThread),
                kind: isSpawn ? collaboration.tool : nil,
                // Each child's own status and result; the call's status stays the card's status.
                input: collaboration.prompt, output: CodexWorkSurfaceProjection.childResults(collaboration),
                model: collaboration.model
            ))
        case let .subagentActivity(activity):
            kind = .subagent(ConversationSubagent(
                title: SessionRailAgents.agentName(activity.agentPath) ?? activity.kind, status: nil,
                detail: activity.agentPath, routes: [.codexThread(activity.agentThreadID)], kind: activity.kind
            ))
        case let .webSearch(query, _, _):
            kind = .tool(ConversationTool(kind: .webSearch, name: query))
        case let .imageView(path):
            kind = .tool(ConversationTool(kind: .imageView, name: path, images: Self.image(at: path).map { [$0] } ?? []))
        case let .imageGeneration(image):
            // The file Codex saved it to, else the image it returned inline.
            let generated = image.savedPath.flatMap(Self.image(at:))
                ?? (image.result.isEmpty ? nil : Self.image(at: image.result.hasPrefix("data:")
                    ? image.result : "data:image/png;base64," + image.result))
            kind = .tool(ConversationTool(
                kind: .imageGeneration, name: image.savedPath ?? image.revisedPrompt ?? "", status: image.status,
                output: image.savedPath == nil ? nil : image.revisedPrompt, images: generated.map { [$0] } ?? []
            ))
            if isFailure(image.status) { phase = .failed }
        case let .sleep(durationMilliseconds):
            kind = .tool(ConversationTool(kind: .sleep, name: L10n.format("Sleeping %lld ms", durationMilliseconds)))
        case let .enteredReviewMode(review), let .exitedReviewMode(review):
            kind = .tool(ConversationTool(kind: .review, name: review))
        case let .hookPrompt(fragments):
            kind = .tool(ConversationTool(
                kind: .hook, name: item.content.typeName, input: JSONValue.array(fragments).readableText
            ))
        case .contextCompaction:
            kind = .compaction(HarnessContextCompaction(phase: isRunning && !isTurnFinished ? .started : .completed))
        case let .notice(notice):
            kind = .notice(notice)
        case let .unknown(type, raw):
            kind = .tool(ConversationTool(kind: .unknown(type: type), name: type ?? "", input: raw.readableText))
        }
        var result = ConversationItem(
            id: item.id, kind: kind, phase: phase, isHistoryMatch: isHistoryMatch,
            source: .codex(item, turnID: turnID)
        )
        if let attachments = prompt?.attachments, !attachments.isEmpty { result.promptAttachments = attachments }
        result.taskMessage = taskMessage
        switch item.content {
        case let .agentMessage(message):
            result.isSentWhileWorking = message.isDeliveredAsync
            result.isUnmarkedAnswer = message.isUnmarkedAnswer
        case let .mcpToolCall(tool):
            result.wasRefusedForApproval = tool.wasRefusedForApproval
        default:
            break
        }
        switch kind {
        case .command, .fileChange, .tool, .subagent, .answer, .commentary, .reasoning:
            // A message offers it in its context menu, the rest on the card.
            if copiesDetails {
                result.copyDetails = CodexWorkSurfaceProjection.itemHandoff(for: item, turnID: turnID)?.payload
            }
        default:
            break
        }
        return result
    }

    /// The text blocks a dynamic tool returned.
    private static func text(of contentItems: [JSONValue]) -> String? {
        let texts = contentItems.compactMap { $0["text"]?.stringValue }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    // MARK: - Parts

    /// The namespace of a Codex limit card's ID. The card is no transcript entry; the ID only names
    /// it, the same way on every projection of the turn.
    private static let usageLimitNamespace = UUID(uuidString: "6E0C4D1A-6B0E-4F39-9C61-3D2B8B7A4C15")!

    /// The turn's error card. A plan limit (`usageLimitExceeded`) reads as the same limit card every
    /// harness shows (D7): the provider's words as its detail, no reset time (the turn error names
    /// none, so the card offers no automatic continue), and no other account (Codex tasks do not
    /// move between accounts). Any other error keeps the error card.
    static func outcome(_ turn: CodexTurnState) -> ConversationTurnOutcome? {
        guard let details = TranscriptRecoveryProjection.codexErrorDetails(turn.error) else { return nil }
        let presentation = CodexTurnErrorPresentation(turn.error)
        if presentation?.category == .usageLimit {
            let message = presentation?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .usageLimit(
                HarnessRateLimit(status: .rejected, message: message.isEmpty ? presentation?.headline : message),
                entryID: NameBasedUUID.make(namespace: usageLimitNamespace, name: turn.id)
            )
        }
        return .error(ConversationTurnError(title: presentation?.headline, message: details, isRecoverable: true))
    }

    private static func status(_ status: CodexTurnStatus) -> ConversationTurnStatus {
        switch status {
        case .inProgress: .running
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed
        case let .unknown(value): .unknown(value)
        }
    }

    private static func plan(_ plan: CodexPlanState) -> ConversationPlan {
        ConversationPlan(explanation: plan.explanation, steps: plan.steps.map { step in
            let status: ConversationPlan.StepStatus = switch step.status {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            case let .unknown(value): .unknown(value)
            }
            return ConversationPlan.Step(id: step.id, text: step.text, status: status)
        })
    }

    /// The messages the person sent into the turn after its work began (`turn/steer`): every user
    /// message after the turn's first item that is neither a sent message nor a provider notice.
    /// The ones before it are the turn's request (D13, as the Codex app splits a turn's items).
    static func steeredMessageIDs(in turn: CodexTurnState) -> Set<String> {
        guard let workStart = turn.items.firstIndex(where: { item in
            switch item.content {
            case .userMessage, .notice: false
            default: true
            }
        }) else { return [] }
        return Set(turn.items[workStart...].compactMap { item in
            if case .userMessage = item.content { return item.id }
            return nil
        })
    }

    /// The work with each answered request after the item it asked about, in the requests' order;
    /// a request whose item is not in the work goes at its end. The request item keeps the
    /// request's ID, so it names the same request wherever it is drawn.
    static func placingAnsweredRequests(
        _ requests: [ConversationRequest], in work: [ConversationItem], turnID: String
    ) -> [ConversationItem] {
        guard !requests.isEmpty else { return work }
        var afterItem: [String: [ConversationItem]] = [:]
        var atEnd: [ConversationItem] = []
        let workIDs = Set(work.map(\.id))
        for request in requests {
            let phase: ConversationItemPhase = switch request.state {
            case .expired: .stopped
            case .rejected: .failed
            default: .completed
            }
            // A Codex request is no item of the thread, but every item names the record it came from
            // (`source`), so a placeholder record under the request's ID stands in for one. The card
            // draws the `.request` kind.
            let placeholder = CodexItemState(
                id: request.id, lifecycle: .completed, content: .unknown(type: "serverRequest", raw: .null), raw: .null
            )
            let item = ConversationItem(
                id: request.id, kind: .request(request), phase: phase, source: .codex(placeholder, turnID: turnID)
            )
            if let itemID = request.toolCallID, workIDs.contains(itemID) {
                afterItem[itemID, default: []].append(item)
            } else {
                atEnd.append(item)
            }
        }
        return work.flatMap { [$0] + (afterItem.removeValue(forKey: $0.id) ?? []) } + atEnd
    }

    /// A command the turn's stop ended reads as stopped, as the Codex app's command card does.
    private static func commandPhase(_ status: String, isTurnFinished: Bool) -> ConversationItemPhase? {
        switch status.lowercased() {
        case "interrupted", "cancelled", "canceled": .stopped
        case "inprogress" where isTurnFinished: .stopped
        case "failed", "failure", "error", "declined": .failed
        default: nil
        }
    }

    /// The image a Codex item names: a file by its absolute path, or a `data:`, file or web URL. A web
    /// image is shown by its name and never fetched; a relative path names no file Yardlet can find.
    private static func image(at reference: String) -> TranscriptImageAttachment? {
        if reference.hasPrefix("/") { return TranscriptImageAttachment(url: URL(filePath: reference)) }
        guard let url = URL(string: reference), let scheme = url.scheme?.lowercased(),
              ["data", "file", "http", "https"].contains(scheme) else { return nil }
        return TranscriptImageAttachment(url: url)
    }

    private static func isFailure(_ status: String) -> Bool {
        ["failed", "failure", "error"].contains(status.lowercased())
    }

    private static func historyMatch(in thread: CodexThreadState, selection: CodexHistorySearchSelection?) -> HistoryMatch {
        guard let selection else { return .none }
        if let turnID = selection.turnID, let itemID = selection.itemID,
           thread.turns.contains(where: { turn in turn.id == turnID && turn.items.contains { $0.id == itemID } }) {
            return .item(turnID: turnID, itemID: itemID)
        }
        return .query(selection.query)
    }

    private static func historyItemIDs(in turn: CodexTurnState, match: HistoryMatch) -> Set<String> {
        switch match {
        case .none: []
        case let .item(turnID, itemID): turn.id == turnID ? [itemID] : []
        case let .query(query): Set(CodexHistorySearchProjection.hits(in: turn, query: query).map(\.itemID))
        }
    }
}

extension ConversationProjectionCache {
    /// A Codex task's conversation, projecting again only the turns whose input changed.
    func codex(
        _ state: CodexTaskState,
        workspaceURL: URL,
        historySelection: CodexHistorySearchSelection?
    ) -> ConversationPresentation {
        CodexConversationProjection.presentation(
            state, workspaceURL: workspaceURL, historySelection: historySelection
        ) { inputs in
            turns(inputs.map { (id: $0.turn.id, input: $0) }, project: CodexConversationProjection.turn)
        }
    }
}
