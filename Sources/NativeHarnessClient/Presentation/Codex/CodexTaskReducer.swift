import Foundation

struct CodexTaskDecoder: Sendable {
    func thread(from value: JSONValue) -> CodexThreadState? {
        guard let id = value["id"]?.stringValue else { return nil }
        let turns = (value["turns"]?.arrayValue ?? []).enumerated().compactMap { index, turn in
            self.turn(from: turn, fallbackID: "\(id):turn:\(index)")
        }
        return CodexThreadState(
            id: id,
            sessionID: value["sessionId"]?.stringValue,
            name: value["name"]?.stringValue,
            preview: value["preview"]?.stringValue ?? "",
            workspacePath: value["cwd"]?.stringValue,
            cliVersion: value["cliVersion"]?.stringValue,
            modelProvider: value["modelProvider"]?.stringValue,
            parentThreadID: value["parentThreadId"]?.stringValue,
            forkedFromID: value["forkedFromId"]?.stringValue,
            status: threadStatus(from: value["status"]),
            canAcceptDirectInput: value["canAcceptDirectInput"]?.boolValue,
            createdAt: secondsDate(value["createdAt"]),
            updatedAt: secondsDate(value["updatedAt"]),
            turns: turns,
            turnsNextCursor: nil,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            raw: value
        )
    }

    func turn(from value: JSONValue, fallbackID: String) -> CodexTurnState? {
        let id = value["id"]?.stringValue ?? fallbackID
        let items = (value["items"]?.arrayValue ?? []).enumerated().map { index, item in
            self.item(
                from: item,
                fallbackID: "\(id):item:\(index)",
                lifecycle: .historical
            )
        }
        return CodexTurnState(
            id: id,
            status: turnStatus(from: value["status"]?.stringValue),
            startedAt: secondsDate(value["startedAt"]),
            completedAt: secondsDate(value["completedAt"]),
            durationMilliseconds: value["durationMs"]?.integerValue,
            itemsView: itemsView(from: value["itemsView"]?.stringValue),
            items: items,
            itemsNextCursor: nil,
            plan: nil,
            tokenUsage: nil,
            error: value["error"],
            raw: value
        )
    }

    func item(
        from value: JSONValue,
        fallbackID: String,
        lifecycle: CodexItemLifecycle
    ) -> CodexItemState {
        let id = value["id"]?.stringValue ?? fallbackID
        return CodexItemState(
            id: id,
            lifecycle: lifecycle,
            startedAt: nil,
            completedAt: nil,
            content: itemContent(from: value),
            raw: value
        )
    }

    func turnPage(from result: JSONValue?) -> CodexTurnPage {
        let turns = (result?["data"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            turn(from: value, fallbackID: "page:turn:\(index)")
        }
        return CodexTurnPage(
            turns: turns,
            nextCursor: result?["nextCursor"]?.stringValue,
            backwardsCursor: result?["backwardsCursor"]?.stringValue
        )
    }

    func itemPage(from result: JSONValue?) -> CodexItemPage {
        let entries = (result?["data"]?.arrayValue ?? []).enumerated().map { index, value in
            let turnID = value["turnId"]?.stringValue ?? "unknown-turn"
            return CodexItemPageEntry(
                turnID: turnID,
                item: item(
                    from: value["item"] ?? value,
                    fallbackID: "page:\(turnID):item:\(index)",
                    lifecycle: .historical
                )
            )
        }
        return CodexItemPage(
            entries: entries,
            nextCursor: result?["nextCursor"]?.stringValue,
            backwardsCursor: result?["backwardsCursor"]?.stringValue
        )
    }

    func plan(from params: JSONValue, turnID: String) -> CodexPlanState {
        let steps: [CodexPlanStep] = (params["plan"]?.arrayValue ?? [])
            .enumerated()
            .compactMap { index, value -> CodexPlanStep? in
            guard let text = value["step"]?.stringValue else { return nil }
            return CodexPlanStep(
                id: "\(turnID):plan:\(index)",
                text: text,
                status: planStepStatus(from: value["status"]?.stringValue)
            )
            }
        return CodexPlanState(
            explanation: params["explanation"]?.stringValue,
            steps: steps
        )
    }

    func tokenUsage(from value: JSONValue?) -> CodexThreadTokenUsage? {
        guard let value,
              let total = tokenUsageBreakdown(from: value["total"]),
              let last = tokenUsageBreakdown(from: value["last"])
        else { return nil }
        return CodexThreadTokenUsage(
            total: total,
            last: last,
            modelContextWindow: value["modelContextWindow"]?.integerValue
        )
    }

    private func itemContent(from value: JSONValue) -> CodexItemContent {
        let type = value["type"]?.stringValue
        switch type {
        case "userMessage":
            guard let content = value["content"]?.arrayValue else {
                return .unknown(type: type, raw: value)
            }
            return .userMessage(CodexUserMessageItem(
                content: content,
                clientID: value["clientId"]?.stringValue
            ))
        case "hookPrompt":
            guard let fragments = value["fragments"]?.arrayValue else {
                return .unknown(type: type, raw: value)
            }
            return .hookPrompt(fragments: fragments)
        case "agentMessage":
            guard let text = value["text"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .agentMessage(CodexAgentMessageItem(
                text: text,
                phase: messagePhase(from: value["phase"]?.stringValue),
                memoryCitation: value["memoryCitation"],
                questions: CodexAsyncQuestion.parse(value["questions"], messageID: value["id"]?.stringValue),
                delivery: value["delivery"]?.stringValue
            ))
        case "plan":
            guard let text = value["text"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .plan(text: text)
        case "reasoning":
            return .reasoning(
                summary: value["summary"]?.arrayValue ?? [],
                content: value["content"]?.arrayValue ?? []
            )
        case "commandExecution":
            guard let command = value["command"]?.stringValue,
                  let cwd = value["cwd"]?.stringValue,
                  let status = value["status"]?.stringValue
            else { return .unknown(type: type, raw: value) }
            return .commandExecution(CodexCommandItem(
                command: command,
                workspacePath: cwd,
                status: status,
                aggregatedOutput: value["aggregatedOutput"]?.stringValue,
                exitCode: value["exitCode"]?.integerValue,
                durationMilliseconds: value["durationMs"]?.integerValue,
                processID: value["processId"]?.stringValue,
                source: value["source"]?.stringValue,
                actions: value["commandActions"]?.arrayValue ?? []
            ))
        case "fileChange":
            guard let changes = value["changes"]?.arrayValue,
                  let status = value["status"]?.stringValue
            else { return .unknown(type: type, raw: value) }
            return .fileChange(CodexFileChangeItem(changes: changes, status: status))
        case "mcpToolCall":
            guard let server = value["server"]?.stringValue,
                  let tool = value["tool"]?.stringValue,
                  let status = value["status"]?.stringValue,
                  let arguments = value["arguments"]
            else { return .unknown(type: type, raw: value) }
            return .mcpToolCall(CodexMCPToolItem(
                server: server,
                tool: tool,
                status: status,
                arguments: arguments,
                result: value["result"],
                error: value["error"],
                pluginID: value["pluginId"]?.stringValue,
                durationMilliseconds: value["durationMs"]?.integerValue
            ))
        case "dynamicToolCall":
            guard let tool = value["tool"]?.stringValue,
                  let status = value["status"]?.stringValue,
                  let arguments = value["arguments"]
            else { return .unknown(type: type, raw: value) }
            return .dynamicToolCall(CodexDynamicToolItem(
                tool: tool,
                namespace: value["namespace"]?.stringValue,
                status: status,
                arguments: arguments,
                contentItems: value["contentItems"]?.arrayValue ?? [],
                succeeded: value["success"]?.boolValue,
                durationMilliseconds: value["durationMs"]?.integerValue
            ))
        case "collabAgentToolCall":
            guard let tool = value["tool"]?.stringValue,
                  let status = value["status"]?.stringValue,
                  let sender = value["senderThreadId"]?.stringValue,
                  let receivers = value["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue),
                  let agentStates = value["agentsStates"]?.objectValue
            else { return .unknown(type: type, raw: value) }
            return .collaboration(CodexCollaborationItem(
                tool: tool,
                status: status,
                senderThreadID: sender,
                receiverThreadIDs: receivers,
                prompt: value["prompt"]?.stringValue,
                model: value["model"]?.stringValue,
                reasoningEffort: value["reasoningEffort"]?.stringValue,
                agentStates: agentStates
            ))
        case "subAgentActivity":
            guard let threadID = value["agentThreadId"]?.stringValue,
                  let path = value["agentPath"]?.stringValue,
                  let kind = value["kind"]?.stringValue
            else { return .unknown(type: type, raw: value) }
            return .subagentActivity(CodexSubagentActivityItem(
                agentThreadID: threadID,
                agentPath: path,
                kind: kind
            ))
        case "webSearch":
            guard let query = value["query"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .webSearch(
                query: query,
                action: value["action"],
                results: value["results"]?.arrayValue
            )
        case "imageView":
            guard let path = value["path"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .imageView(path: path)
        case "sleep":
            guard let duration = value["durationMs"]?.integerValue else {
                return .unknown(type: type, raw: value)
            }
            return .sleep(durationMilliseconds: duration)
        case "imageGeneration":
            guard let status = value["status"]?.stringValue,
                  let result = value["result"]?.stringValue
            else { return .unknown(type: type, raw: value) }
            return .imageGeneration(CodexImageGenerationItem(
                status: status,
                result: result,
                revisedPrompt: value["revisedPrompt"]?.stringValue,
                savedPath: value["savedPath"]?.stringValue,
                failure: value["failure"]
            ))
        case "enteredReviewMode":
            guard let review = value["review"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .enteredReviewMode(review: review)
        case "exitedReviewMode":
            guard let review = value["review"]?.stringValue else {
                return .unknown(type: type, raw: value)
            }
            return .exitedReviewMode(review: review)
        case "contextCompaction":
            return .contextCompaction
        case CodexNoticeItem.itemType:
            guard let kind = value["kind"]?.stringValue.flatMap(CodexNoticeItem.Kind.init(rawValue:)),
                  let message = value["message"]?.stringValue
            else { return .unknown(type: type, raw: value) }
            return .notice(CodexNoticeItem(
                kind: kind,
                message: message,
                details: value["details"]?.stringValue,
                fromModel: value["fromModel"]?.stringValue,
                reason: value["reason"]?.stringValue,
                path: value["path"]?.stringValue
            ))
        default:
            return .unknown(type: type, raw: value)
        }
    }

    private func threadStatus(from value: JSONValue?) -> CodexThreadRuntimeStatus {
        switch value?["type"]?.stringValue {
        case "notLoaded": .notLoaded
        case "idle": .idle
        case "active": .active(flags: value?["activeFlags"]?.arrayValue?.compactMap {
            $0.stringValue ?? $0["type"]?.stringValue
        } ?? [])
        case "systemError": .systemError
        default: .unknown(value)
        }
    }

    private func turnStatus(from value: String?) -> CodexTurnStatus {
        switch value {
        case "inProgress": .inProgress
        case "completed": .completed
        case "interrupted": .interrupted
        case "failed": .failed
        default: .unknown(value ?? "missing")
        }
    }

    private func itemsView(from value: String?) -> CodexItemsView {
        switch value {
        case "notLoaded": .notLoaded
        case "summary": .summary
        case "full", nil: .full
        default: .unknown(value ?? "missing")
        }
    }

    private func messagePhase(from value: String?) -> CodexMessagePhase {
        switch value {
        case "commentary": .commentary
        case "final_answer": .finalAnswer
        default: .unknown(value)
        }
    }

    private func planStepStatus(from value: String?) -> CodexPlanStepStatus {
        switch value {
        case "pending": .pending
        case "inProgress": .inProgress
        case "completed": .completed
        default: .unknown(value ?? "missing")
        }
    }

    private func tokenUsageBreakdown(from value: JSONValue?) -> CodexTokenUsageBreakdown? {
        guard let input = value?["inputTokens"]?.integerValue,
              let cached = value?["cachedInputTokens"]?.integerValue,
              let output = value?["outputTokens"]?.integerValue,
              let reasoning = value?["reasoningOutputTokens"]?.integerValue,
              let total = value?["totalTokens"]?.integerValue
        else { return nil }
        return CodexTokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: value?["cacheWriteInputTokens"]?.integerValue ?? 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    private func secondsDate(_ value: JSONValue?) -> Date? {
        value?.integerValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct CodexTaskReducer: Sendable {
    private let decoder = CodexTaskDecoder()

    /// Notifications that only extend or replace text on a running card. Their publications may
    /// be coalesced; lifecycle, approval, and completion changes still publish immediately.
    static let streamingTextMethods: Set<String> = [
        "item/agentMessage/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/plan/delta",
        "item/commandExecution/outputDelta",
        "item/fileChange/patchUpdated",
        "turn/diff/updated"
    ]

    /// Provider notifications the timeline shows inline in a turn. `configWarning` and
    /// `deprecationNotice` (and a `warning` without a thread) name no thread; the adapter hands
    /// them to each attached thread with its `threadId`.
    static let noticeMethods: Set<String> = [
        "model/rerouted", "warning", "configWarning", "deprecationNotice"
    ]

    @discardableResult
    func applySnapshot(_ value: JSONValue, to state: inout CodexTaskState) -> Bool {
        guard let thread = decoder.thread(from: value) else { return false }
        state.thread = thread
        state.lastAppliedSequence = nil
        return true
    }

    @discardableResult
    func applyNotification(
        method: String,
        params: JSONValue,
        sequence: UInt64,
        to state: inout CodexTaskState
    ) -> Bool {
        if let last = state.lastAppliedSequence, sequence <= last { return false }
        state.lastAppliedSequence = sequence

        if method == "thread/started", let thread = params["thread"],
           let decoded = decoder.thread(from: thread) {
            state.thread = decoded
            state.lastAppliedSequence = sequence
            return true
        }

        guard let threadID = params["threadId"]?.stringValue else { return false }
        if Self.noticeMethods.contains(method) {
            // A notice never opens a thread or a turn of its own; before the thread loads it waits.
            if let thread = state.thread, thread.id != threadID { return false }
            return applyNotice(method: method, params: params, in: &state)
        }
        ensureThread(threadID, params: params, state: &state)
        guard state.thread?.id == threadID else { return false }

        // Output on a turn means its response stream is flowing again.
        let resumedStream = Self.streamProgressMethods.contains(method)
            && clearRetryingError(onTurn: params["turnId"]?.stringValue, in: &state)
        return applyThreadNotification(
            method: method,
            params: params,
            threadID: threadID,
            sequence: sequence,
            to: &state
        ) || resumedStream
    }

    /// Notifications that show a turn's response stream is producing output again.
    static let streamProgressMethods = streamingTextMethods.union([
        "item/started",
        "item/completed",
        "turn/plan/updated"
    ])

    private func applyThreadNotification(
        method: String,
        params: JSONValue,
        threadID: String,
        sequence: UInt64,
        to state: inout CodexTaskState
    ) -> Bool {
        switch method {
        case "turn/started", "turn/completed":
            guard let turnValue = params["turn"],
                  var turn = decoder.turn(
                    from: turnValue,
                    fallbackID: "\(threadID):turn:\(sequence)"
                  )
            else { return false }
            if method == "turn/completed", !turn.status.isTerminal {
                turn.status = .completed
            }
            upsert(turn: turn, in: &state)
            if method == "turn/started", !state.pendingNotices.isEmpty,
               let index = state.thread?.turns.firstIndex(where: { $0.id == turn.id }) {
                for notice in state.pendingNotices {
                    appendNotice(notice.objectValue ?? [:], toTurnAt: index, in: &state)
                }
                state.pendingNotices = []
            }
            if method == "turn/completed" {
                _ = clearRetryingError(onTurn: turn.id, in: &state)
                // A native review wrapper starts before its worker turn and completes after it.
                // Its result is the latest turn even when it was inserted into the timeline first.
                if let index = state.thread?.turns.firstIndex(where: { $0.id == turn.id }),
                   let completed = state.thread?.turns[index], completed.items.contains(where: {
                       if case .exitedReviewMode = $0.content { return true }; return false
                   }) {
                    state.thread?.turns.remove(at: index)
                    state.thread?.turns.append(completed)
                }
                for request in state.serverRequestsByID.values
                    where request.turnID == turn.id && request.resolution == .pending {
                    rejectServerRequest(id: request.id, code: CodexPendingServerRequest.expiredRuntimeCode,
                        message: L10n.string("Approval expired because the turn ended."), in: &state)
                }
                reconcileResolvedServerRequestItems(in: &state)
                reconcileTerminalActivityItems(in: &state)
            }
            return true

        case "item/started", "item/completed":
            guard let turnID = params["turnId"]?.stringValue,
                  let itemValue = params["item"]
            else { return false }
            var item = decoder.item(
                from: itemValue,
                fallbackID: "\(turnID):item:\(sequence)",
                lifecycle: method == "item/completed" ? .completed : .inProgress
            )
            item.startedAt = millisecondsDate(params["startedAtMs"])
            item.completedAt = millisecondsDate(params["completedAtMs"])
            upsert(item: item, turnID: turnID, in: &state)
            return true

        case "item/agentMessage/delta":
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue
            else { return false }
            appendAgentDelta(delta, itemID: itemID, turnID: turnID, params: params, state: &state)
            return true

        case "item/reasoning/summaryPartAdded":
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let index = params["summaryIndex"]?.integerValue
            else { return false }
            return mutateLiveItem(itemID, turnID: turnID, in: &state) { content in
                guard case .reasoning(var summary, let parts) = content,
                      Self.appendPart("", at: index, to: &summary)
                else { return false }
                content = .reasoning(summary: summary, content: parts)
                return true
            }

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let indexKey = method == "item/reasoning/textDelta" ? "contentIndex" : "summaryIndex"
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue,
                  let index = params[indexKey]?.integerValue
            else { return false }
            return mutateLiveItem(itemID, turnID: turnID, in: &state) { content in
                guard case .reasoning(var summary, var parts) = content else { return false }
                let appended = method == "item/reasoning/textDelta"
                    ? Self.appendPart(delta, at: index, to: &parts)
                    : Self.appendPart(delta, at: index, to: &summary)
                guard appended else { return false }
                content = .reasoning(summary: summary, content: parts)
                return true
            }

        case "item/commandExecution/outputDelta":
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue
            else { return false }
            return mutateLiveItem(itemID, turnID: turnID, in: &state) { content in
                guard case var .commandExecution(command) = content, !delta.isEmpty else { return false }
                CodexLiveCommandOutput.append(delta, to: &command)
                content = .commandExecution(command)
                return true
            }

        case "item/plan/delta":
            // Plan mode streams its proposed plan into the `plan` item `item/started` opened.
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue
            else { return false }
            return mutateLiveItem(itemID, turnID: turnID, in: &state) { content in
                guard case let .plan(text) = content, !delta.isEmpty else { return false }
                content = .plan(text: text + delta)
                return true
            }

        case "item/fileChange/patchUpdated":
            guard let turnID = params["turnId"]?.stringValue,
                  let itemID = params["itemId"]?.stringValue,
                  let changes = params["changes"]?.arrayValue
            else { return false }
            return applyPatchUpdate(changes, itemID: itemID, turnID: turnID, state: &state)

        // `item/mcpToolCall/progress` is left out on purpose: the Codex app logs it and does
        // not show it, so the card shows only the call's status and, when done, its result.

        case "turn/diff/updated":
            // The whole turn's diff so far, for the review panel's Last turn. An unknown turn
            // gets no phantom turn.
            guard let turnID = params["turnId"]?.stringValue,
                  let diff = params["diff"]?.stringValue,
                  let index = state.thread?.turns.firstIndex(where: { $0.id == turnID }),
                  state.thread?.turns[index].diff != diff
            else { return false }
            state.thread?.turns[index].diff = diff
            return true

        case "turn/plan/updated":
            guard let turnID = params["turnId"]?.stringValue else { return false }
            mutateTurn(turnID, in: &state) { turn in
                turn.plan = decoder.plan(from: params, turnID: turnID)
            }
            return true

        case "thread/name/updated":
            let name = params["threadName"]?.stringValue
            guard state.thread?.name != name else { return false }
            state.thread?.name = name
            return true

        case "thread/tokenUsage/updated":
            guard let turnID = params["turnId"]?.stringValue,
                  let usage = decoder.tokenUsage(from: params["tokenUsage"])
            else { return false }
            mutateTurn(turnID, in: &state) { $0.tokenUsage = usage }
            return true

        case "serverRequest/resolved":
            guard let requestID = params["requestId"] else { return false }
            let externalID = externalRequestID(requestID)
            return resolveServerRequest(id: externalID, response: params["response"], in: &state)

        case "error":
            // An error for a turn this thread does not hold gets no phantom turn; the task-level
            // error still reports it.
            guard let turnID = params["turnId"]?.stringValue,
                  let index = state.thread?.turns.firstIndex(where: { $0.id == turnID }),
                  let error = CodexTurnErrorPresentation.notificationError(params),
                  var turn = state.thread?.turns[index]
            else { return false }
            if params["willRetry"]?.boolValue == true {
                guard turn.retryingError != error else { return false }
                turn.retryingError = error
            } else {
                // `turn/completed` brings the same error; showing it now does not wait on that frame.
                turn.retryingError = nil
                turn.error = turn.error ?? error
            }
            state.thread?.turns[index] = turn
            return true

        default:
            return false
        }
    }

    private func clearRetryingError(onTurn turnID: String?, in state: inout CodexTaskState) -> Bool {
        guard let turnID,
              let index = turnIndex(turnID, in: state),
              state.thread?.turns[index].retryingError != nil else { return false }
        state.thread?.turns[index].retryingError = nil
        return true
    }

    @discardableResult
    func applyServerRequest(
        id: CodexRPCID,
        method: String,
        params: JSONValue?,
        sequence: UInt64,
        to state: inout CodexTaskState
    ) -> Bool {
        if let last = state.lastAppliedSequence, sequence <= last { return false }
        state.lastAppliedSequence = sequence
        let externalID = externalRequestID(id)
        let kind = serverRequestKind(for: method)
        let threadID = params?["threadId"]?.stringValue
        if let threadID {
            ensureThread(threadID, params: params ?? .object([:]), state: &state)
        }
        state.serverRequestsByID[externalID] = CodexServerRequestState(
            id: externalID,
            method: method,
            kind: kind,
            threadID: threadID,
            turnID: params?["turnId"]?.stringValue,
            itemID: params?["itemId"]?.stringValue,
            params: params,
            resolution: .pending
        )
        guard kind.isApproval, let threadID else { return true }
        state.approvalsByID[externalID] = CodexApprovalState(
            id: externalID,
            method: method,
            threadID: threadID,
            turnID: params?["turnId"]?.stringValue,
            itemID: params?["itemId"]?.stringValue,
            resolution: .pending,
            raw: params
        )
        return true
    }

    @discardableResult
    func resolveServerRequest(
        id: String,
        response: JSONValue?,
        in state: inout CodexTaskState
    ) -> Bool {
        guard var request = state.serverRequestsByID[id] else { return false }
        request.resolution = .resolved(response)
        state.serverRequestsByID[id] = request
        if request.kind == .commandExecutionApproval,
           response?["decision"]?.stringValue == "decline" {
            resolveDeclinedCommand(for: request, in: &state)
        }
        if var approval = state.approvalsByID[id] {
            approval.resolution = .resolved(response)
            state.approvalsByID[id] = approval
        }
        return true
    }

    /// Provider notifications normally finish a declined command. After an app restart the old
    /// provider request no longer has a live turn to publish that notification, so the explicit
    /// user decision is the authoritative terminal state for the retained command card.
    private func resolveDeclinedCommand(
        for request: CodexServerRequestState,
        in state: inout CodexTaskState
    ) {
        guard let turnID = request.turnID, let itemID = request.itemID else { return }
        mutateTurn(turnID, in: &state) { turn in
            guard let index = turn.items.firstIndex(where: { $0.id == itemID }) else { return }
            var item = turn.items[index]
            guard case var .object(raw) = item.raw else { return }
            raw["status"] = .string("declined")
            item.raw = .object(raw)
            item.content = CodexTaskDecoder().item(
                from: item.raw,
                fallbackID: item.id,
                lifecycle: .completed
            ).content
            item.lifecycle = .completed
            turn.items[index] = item
        }
    }

    /// Reapply persisted decisions after provider and app-local history are merged. This closes
    /// the ordering gap where the approval resolution can arrive before its retained command card.
    func reconcileResolvedServerRequestItems(in state: inout CodexTaskState) {
        let resolved = state.serverRequestsByID.values.compactMap { request -> (String, JSONValue?)? in
            guard case let .resolved(result) = request.resolution else { return nil }
            return (request.id, result)
        }
        for (id, result) in resolved {
            _ = resolveServerRequest(id: id, response: result, in: &state)
        }
    }

    /// EOF ends the runtime's ability to answer approvals; retain the partial typed history.
    func endRuntime(in state: inout CodexTaskState) {
        for request in state.serverRequestsByID.values where request.resolution == .pending {
            rejectServerRequest(id: request.id, code: CodexPendingServerRequest.expiredRuntimeCode,
                message: L10n.string("Approval expired because the provider runtime stopped."), in: &state)
        }
        if var turns = state.thread?.turns {
            for index in turns.indices where !turns[index].status.isTerminal {
                turns[index].status = .failed
                turns[index].error = .object(["message": .string(L10n.format("Connection to %@ ended.", "Codex"))])
            }
            state.thread?.turns = turns
        }
        reconcileResolvedServerRequestItems(in: &state)
        reconcileTerminalActivityItems(in: &state)
    }

    /// A terminal provider turn cannot still own a running local activity. Keep an activity live
    /// only while a matching approval is genuinely pending; otherwise close the stale spinner as
    /// interrupted. This is especially important when the provider omits item history on resume.
    func reconcileTerminalActivityItems(in state: inout CodexTaskState) {
        var settledTurns = CodexSettledTurns()
        reconcileTerminalActivityItems(in: &state, settledTurns: &settledTurns)
    }

    /// `settledTurns` remembers the terminal turns found with no running card. A turn whose items
    /// are still those has nothing to close, whatever is pending, and is not walked again.
    func reconcileTerminalActivityItems(
        in state: inout CodexTaskState,
        settledTurns: inout CodexSettledTurns
    ) {
        let pendingItemIDs = Set<String>(state.serverRequestsByID.values.compactMap { request in
            guard case .pending = request.resolution else { return nil }
            return request.itemID
        })
        guard var turns = state.thread?.turns else {
            settledTurns.items.removeAll()
            return
        }
        var changed = false
        var settled: [String: [CodexItemState]] = [:]
        for turnIndex in turns.indices where turns[turnIndex].status.isTerminal {
            let turnID = turns[turnIndex].id
            if let known = settledTurns.items[turnID], known == turns[turnIndex].items {
                // Kept in this state's storage, so the next comparison is immediate rather than item by item.
                settled[turnID] = turns[turnIndex].items
                continue
            }
            var stillRunning = false
            for itemIndex in turns[turnIndex].items.indices {
                // Read in place: a long thread's settled items would otherwise be copied.
                guard turns[turnIndex].items[itemIndex].lifecycle == .inProgress else { continue }
                guard !pendingItemIDs.contains(turns[turnIndex].items[itemIndex].id) else {
                    stillRunning = true
                    continue
                }
                var item = turns[turnIndex].items[itemIndex]
                changed = true
                if case var .object(raw) = item.raw {
                    raw["status"] = .string("interrupted")
                    item.raw = .object(raw)
                    // Narrative deltas live in content; their initial raw frame can still be empty.
                    switch item.content {
                    case .agentMessage, .reasoning, .plan:
                        break
                    default:
                        // The rendered payload keeps command output streamed before the stop.
                        item.content = CodexTaskDecoder().item(
                            from: item.renderedPayload, fallbackID: item.id, lifecycle: .completed
                        ).content
                    }
                }
                item.lifecycle = .completed
                turns[turnIndex].items[itemIndex] = item
            }
            if !stillRunning { settled[turnID] = turns[turnIndex].items }
        }
        settledTurns.items = settled
        if changed { state.thread?.turns = turns }
    }

    @discardableResult
    func rejectServerRequest(
        id: String,
        code: Int64,
        message: String,
        in state: inout CodexTaskState
    ) -> Bool {
        guard var request = state.serverRequestsByID[id] else { return false }
        request.resolution = .rejected(code: code, message: message)
        state.serverRequestsByID[id] = request
        if var approval = state.approvalsByID[id] {
            approval.resolution = .resolved(.object([
                "error": .string(message),
                "code": .integer(code)
            ]))
            state.approvalsByID[id] = approval
        }
        return true
    }

    func mergeTurnPage(
        _ page: CodexTurnPage,
        prepending: Bool = false,
        into state: inout CodexTaskState
    ) {
        for turn in page.turns {
            upsert(turn: turn, in: &state)
        }
        if var turns = state.thread?.turns {
            let pageIDs = Set(page.turns.map(\.id))
            let turnByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
            let pageTurns = page.turns.compactMap { turnByID[$0.id] }
            turns.removeAll { pageIDs.contains($0.id) }
            state.thread?.turns = prepending ? pageTurns + turns : turns + pageTurns
        }
        state.thread?.turnsNextCursor = page.nextCursor
    }

    /// Merge a fresh newest page of the thread's turns (the provider's first page, oldest first)
    /// into the turns loaded so far, as a followed thread changes. The page's turns replace their
    /// loaded copies, and a loaded turn after the oldest of them that the page no longer holds is
    /// gone. Earlier turns stay with their cursor. A page that shares no turn with the loaded ones
    /// (more turns arrived than a page holds) starts the turns over from it, with its cursor.
    func mergeNewestTurnPage(_ page: CodexTurnPage, into state: inout CodexTaskState) {
        guard let loaded = state.thread?.turns else { return }
        let pageIDs = Set(page.turns.map(\.id))
        let earlier = loaded.firstIndex { pageIDs.contains($0.id) }.map { Array(loaded[..<$0]) } ?? []
        let cursor = earlier.isEmpty ? page.nextCursor : state.thread?.turnsNextCursor
        state.thread?.turns = earlier + page.turns
        state.thread?.turnsNextCursor = cursor
    }

    /// Merge the optional bootstrap page returned by `thread/resume` without replacing the
    /// authoritative thread snapshot. The locked resume response carries the page and its head
    /// cursors beside `thread`, so keeping them here makes the first history screen page-aware
    /// even when the provider intentionally excludes turns from the snapshot.
    func mergeResumePage(
        _ page: CodexTurnPage?,
        prependingTurns: Bool = false,
        turnsBackwardsCursor: String?,
        itemsBackwardsCursor: String?,
        into state: inout CodexTaskState
    ) {
        if let page {
            mergeTurnPage(page, prepending: prependingTurns, into: &state)
        }
        state.thread?.turnsBackwardsCursor = turnsBackwardsCursor
        state.thread?.itemsBackwardsCursor = itemsBackwardsCursor
    }

    /// Each turn takes its entries at once. A task's saved cards are merged as a page into every
    /// state it streams, a few hundred cards into turns of as many items.
    func mergeItemPage(_ page: CodexItemPage, into state: inout CodexTaskState) {
        var turnIDs: [String] = []
        var itemsByTurnID: [String: [CodexItemState]] = [:]
        for entry in page.entries {
            if itemsByTurnID[entry.turnID] == nil { turnIDs.append(entry.turnID) }
            itemsByTurnID[entry.turnID, default: []].append(entry.item)
        }
        for turnID in turnIDs {
            mutateTurn(turnID, in: &state) { turn in
                upsert(items: itemsByTurnID[turnID] ?? [], in: &turn)
                turn.itemsNextCursor = page.nextCursor
            }
        }
    }

    private func ensureThread(_ id: String, params: JSONValue, state: inout CodexTaskState) {
        guard state.thread == nil else { return }
        state.thread = CodexThreadState(
            id: id,
            sessionID: nil,
            name: nil,
            preview: "",
            workspacePath: nil,
            cliVersion: nil,
            modelProvider: nil,
            parentThreadID: nil,
            forkedFromID: nil,
            status: .unknown(nil),
            canAcceptDirectInput: nil,
            createdAt: nil,
            updatedAt: nil,
            turns: [],
            turnsNextCursor: nil,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil,
            raw: params
        )
    }

    private func upsert(turn: CodexTurnState, in state: inout CodexTaskState) {
        guard let index = turnIndex(turn.id, in: state) else {
            state.thread?.turns.append(turn)
            return
        }
        guard var current = state.thread?.turns[index] else { return }
        let wouldRegressTerminalState = current.status.isTerminal && !turn.status.isTerminal
        upsert(items: turn.items, in: &current)
        if !wouldRegressTerminalState {
            current.status = turn.status
        }
        current.startedAt = turn.startedAt ?? current.startedAt
        current.completedAt = turn.completedAt ?? current.completedAt
        current.durationMilliseconds = turn.durationMilliseconds ?? current.durationMilliseconds
        if !wouldRegressTerminalState {
            current.itemsView = turn.itemsView
            current.raw = turn.raw
        }
        current.error = turn.error ?? current.error
        state.thread?.turns[index] = current
    }

    private func upsert(item: CodexItemState, turnID: String, in state: inout CodexTaskState) {
        mutateTurn(turnID, in: &state) { turn in
            upsert(item: item, in: &turn)
        }
    }

    private func upsert(item: CodexItemState, in turn: inout CodexTurnState) {
        upsert(item: item, at: turn.items.firstIndex(where: { $0.id == item.id }), in: &turn)
    }

    /// Each of `items` in order, as `upsert(item:in:)` puts it, with the turn's items indexed by ID
    /// once instead of searched for each.
    private func upsert(items: [CodexItemState], in turn: inout CodexTurnState) {
        var indexByID: [String: Int] = [:]
        for index in turn.items.indices.reversed() { indexByID[turn.items[index].id] = index }
        for item in items {
            let index = indexByID[item.id]
            if index == nil { indexByID[item.id] = turn.items.count }
            upsert(item: item, at: index, in: &turn)
        }
    }

    /// `index` is the turn's first item with `item`'s ID, if it has one.
    private func upsert(item: CodexItemState, at index: Int?, in turn: inout CodexTurnState) {
        guard let index else {
            turn.items.append(item)
            return
        }
        let existing = turn.items[index]
        if existing.lifecycle > item.lifecycle {
            var preserved = existing
            preserved.startedAt = item.startedAt ?? existing.startedAt
            preserved.completedAt = existing.completedAt ?? item.completedAt
            turn.items[index] = preserved
            return
        }
        var merged = item
        merged.lifecycle = max(existing.lifecycle, item.lifecycle)
        merged.startedAt = item.startedAt ?? existing.startedAt
        merged.completedAt = item.completedAt ?? existing.completedAt
        turn.items[index] = merged
    }

    /// The first turn with `id`. IDs are read in place: every streamed fragment looks its turn up,
    /// and copying each turn of a long thread to compare its ID cost more than the fragment.
    private func turnIndex(_ id: String, in state: CodexTaskState) -> Int? {
        state.thread?.turns.withUnsafeBufferPointer { turns in
            for index in turns.indices where turns[index].id == id { return index }
            return nil
        }
    }

    private func mutateTurn(
        _ id: String,
        in state: inout CodexTaskState,
        mutation: (inout CodexTurnState) -> Void
    ) {
        var found = turnIndex(id, in: state)
        if found == nil, state.thread != nil {
            found = state.thread?.turns.count
            state.thread?.turns.append(CodexTurnState(
                id: id,
                status: .inProgress,
                startedAt: nil,
                completedAt: nil,
                durationMilliseconds: nil,
                itemsView: .full,
                items: [],
                itemsNextCursor: nil,
                plan: nil,
                tokenUsage: nil,
                error: nil,
                raw: .object(["id": .string(id)])
            ))
        }
        guard let index = found else { return }
        // The turn changes where it lies. A copy taken out shares its items with the turn left
        // behind, so the copy's first change to them copied every item of the turn, on every call.
        mutation(&state.thread!.turns[index])
    }

    private func appendAgentDelta(
        _ delta: String,
        itemID: String,
        turnID: String,
        params: JSONValue,
        state: inout CodexTaskState
    ) {
        mutateTurn(turnID, in: &state) { turn in
            if let index = turn.items.firstIndex(where: { $0.id == itemID }),
               case var .agentMessage(message) = turn.items[index].content {
                guard turn.items[index].lifecycle != .completed else { return }
                message.text += delta
                turn.items[index].content = .agentMessage(message)
                turn.items[index].lifecycle = max(turn.items[index].lifecycle, .inProgress)
                return
            }
            turn.items.append(CodexItemState(
                id: itemID,
                lifecycle: .inProgress,
                startedAt: nil,
                completedAt: nil,
                content: .agentMessage(CodexAgentMessageItem(
                    text: delta,
                    phase: .unknown(nil),
                    memoryCitation: nil
                )),
                raw: params
            ))
        }
    }

    /// Places a notice in the turn it names, else in the running turn. With no turn running, it
    /// waits for the next `turn/started`, so a warning raised while idle still reaches the person.
    private func applyNotice(
        method: String,
        params: JSONValue,
        in state: inout CodexTaskState
    ) -> Bool {
        var fields: [String: JSONValue] = [:]
        switch method {
        case "model/rerouted":
            guard let toModel = params["toModel"]?.stringValue, !toModel.isEmpty else { return false }
            fields = [
                "kind": .string(CodexNoticeItem.Kind.modelRerouted.rawValue),
                "message": .string(toModel)
            ]
            fields["fromModel"] = params["fromModel"]?.stringValue.map(JSONValue.string)
            fields["reason"] = params["reason"]?.stringValue.map(JSONValue.string)
        case "warning":
            guard let message = params["message"]?.stringValue,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            fields = ["kind": .string(CodexNoticeItem.Kind.warning.rawValue), "message": .string(message)]
        case "configWarning", "deprecationNotice":
            guard let summary = params["summary"]?.stringValue,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            fields = ["kind": .string(method), "message": .string(summary)]
            fields["details"] = params["details"]?.stringValue.map(JSONValue.string)
            fields["path"] = params["path"]?.stringValue.map(JSONValue.string)
        default:
            return false
        }
        let turns = state.thread?.turns ?? []
        let named = params["turnId"]?.stringValue.flatMap { id in turns.firstIndex { $0.id == id } }
        guard let index = named ?? turns.lastIndex(where: { $0.status == .inProgress }) else {
            guard !state.pendingNotices.contains(where: { Self.isSameNotice($0.objectValue ?? [:], fields) })
            else { return false }
            state.pendingNotices.append(.object(fields))
            // Nothing visible changed, but the caller must keep the state that now holds it.
            return true
        }
        return appendNotice(fields, toTurnAt: index, in: &state)
    }

    @discardableResult
    private func appendNotice(
        _ fields: [String: JSONValue],
        toTurnAt index: Int,
        in state: inout CodexTaskState
    ) -> Bool {
        guard var turn = state.thread?.turns[index] else { return false }
        let notices = turn.items.filter { item in
            if case .notice = item.content { return true }
            return false
        }
        // The provider can repeat a notice, such as a reroute for each request in a turn.
        guard !notices.contains(where: { Self.isSameNotice($0.raw.objectValue ?? [:], fields) }) else {
            return false
        }
        var raw = fields
        let id = "\(turn.id):notice:\(notices.count)"
        raw["id"] = .string(id)
        raw["type"] = .string(CodexNoticeItem.itemType)
        turn.items.append(decoder.item(from: .object(raw), fallbackID: id, lifecycle: .completed))
        state.thread?.turns[index] = turn
        return true
    }

    private static func isSameNotice(_ lhs: [String: JSONValue], _ rhs: [String: JSONValue]) -> Bool {
        lhs["kind"] == rhs["kind"] && lhs["message"] == rhs["message"]
    }

    /// Streamed reasoning and command output extend only an item the provider already started. A delta for an unknown or finished item is dropped without creating a
    /// turn or a card; `item/completed` carries the authoritative value either way.
    private func mutateLiveItem(
        _ itemID: String,
        turnID: String,
        in state: inout CodexTaskState,
        mutation: (inout CodexItemContent) -> Bool
    ) -> Bool {
        guard let turnIndex = turnIndex(turnID, in: state),
              let itemIndex = state.thread?.turns[turnIndex].items.firstIndex(where: { $0.id == itemID }),
              var item = state.thread?.turns[turnIndex].items[itemIndex],
              item.lifecycle != .completed
        else { return false }
        guard mutation(&item.content) else { return false }
        state.thread?.turns[turnIndex].items[itemIndex] = item
        return true
    }

    /// `item/fileChange/patchUpdated` carries the whole patch so far, so it replaces the card's
    /// changes rather than appending. Codex streams the patch while the model writes it, which
    /// can be before `item/started`; an update for an unknown item in a known turn therefore opens
    /// an in-progress file change card, as the Codex app does, and the provider's own item frames
    /// replace it. A finished card or an item of another kind is left alone.
    private func applyPatchUpdate(
        _ changes: [JSONValue],
        itemID: String,
        turnID: String,
        state: inout CodexTaskState
    ) -> Bool {
        guard let turnIndex = state.thread?.turns.firstIndex(where: { $0.id == turnID }) else {
            return false
        }
        guard state.thread?.turns[turnIndex].items.contains(where: { $0.id == itemID }) == true else {
            let opened = decoder.item(
                from: .object([
                    "id": .string(itemID),
                    "type": .string("fileChange"),
                    "changes": .array(changes),
                    "status": .string("inProgress")
                ]),
                fallbackID: itemID,
                lifecycle: .inProgress
            )
            state.thread?.turns[turnIndex].items.append(opened)
            return true
        }
        return mutateLiveItem(itemID, turnID: turnID, in: &state) { content in
            guard case var .fileChange(change) = content, change.changes != changes else {
                return false
            }
            change.changes = changes
            content = .fileChange(change)
            return true
        }
    }

    /// Appends to the part the provider indexed. A new part may only follow the last one, so a
    /// gap in the provider's indices is dropped instead of shifting later text into it.
    private static func appendPart(_ delta: String, at index: Int64, to parts: inout [JSONValue]) -> Bool {
        guard index >= 0, index <= Int64(parts.count) else { return false }
        let position = Int(index)
        if position == parts.count {
            parts.append(.string(delta))
            return true
        }
        guard !delta.isEmpty else { return false }
        parts[position] = .string((parts[position].stringValue ?? "") + delta)
        return true
    }

    private func millisecondsDate(_ value: JSONValue?) -> Date? {
        value?.integerValue.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    private func externalRequestID(_ value: JSONValue) -> String {
        if let string = value.stringValue { return "s:\(string)" }
        if let integer = value.integerValue { return "i:\(integer)" }
        return "unknown-request"
    }

    private func externalRequestID(_ id: CodexRPCID) -> String {
        switch id {
        case let .integer(value): "i:\(value)"
        case let .string(value): "s:\(value)"
        }
    }

    private func serverRequestKind(for method: String) -> CodexServerRequestKind {
        switch method {
        case "item/commandExecution/requestApproval": .commandExecutionApproval
        case "item/fileChange/requestApproval": .fileChangeApproval
        case "item/tool/requestUserInput": .toolUserInput
        case "mcpServer/elicitation/request": .mcpElicitation
        case "item/permissions/requestApproval": .permissionsApproval
        case "item/tool/call": .dynamicToolCall
        case "account/chatgptAuthTokens/refresh": .authenticationRefresh
        case "attestation/generate": .attestation
        case "currentTime/read": .currentTime
        case "applyPatchApproval": .applyPatchApproval
        case "execCommandApproval": .execCommandApproval
        default: .unknown(method)
        }
    }
}

/// Terminal turns a reconciliation found with no running card, by their items. A streaming task
/// reconciles every presentation it publishes; keeping this per task lets that skip the settled
/// history it already walked.
struct CodexSettledTurns: Sendable {
    fileprivate var items: [String: [CodexItemState]] = [:]
}
