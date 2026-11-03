import Foundation

/// Session-local correlations for Claude's stream-json. Task identity, background state and
/// terminal outcome come from the CLI, including task_updated when no notification follows.
struct ClaudeSessionProjection: Sendable {
    private struct TaskState: Sendable {
        var activity: HarnessActivity
        var terminal = false
        var foregroundTurnEnded = false
    }

    private var activities: [String: HarnessActivity] = [:]
    private var toolInputs: [String: (name: String, input: JSONValue)] = [:]
    private var tasks: [String: TaskState] = [:]
    private var taskOrder: [String] = []
    private var hiddenTaskIDs: Set<String> = []
    /// A subagent's own tasks the session has shown: only while they run in the background, in the
    /// line above the composer (`HarnessSubtaskReference.isSubagentWork`).
    private var shownSubagentTaskIDs: Set<String> = []
    /// The model each Agent call asked for or its result reported, by the call's ID.
    private var agentModels: [String: String] = [:]
    private var taskList = ClaudeTaskListProjection()
    private let projector = ClaudeEventProjector()
    /// The CLI repeats its compacting status while it works; only the first one starts a marker.
    private var isCompacting = false
    /// The latest plan-limit report, which the CLI sends only when something in it changes.
    private var latestRateLimit: HarnessRateLimit?
    /// A rejection reported since the last turn ended, with no paid usage covering it.
    private var rejectedThisTurn = false
    /// The card the current turn shows for the limit that stopped it.
    private var turnLimit: HarnessRateLimit?
    var hasLiveTasks: Bool { tasks.values.contains { !$0.terminal } }

    mutating func payloads(from frame: JSONValue) -> [HarnessEventPayload] {
        guard frame["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return [] }
        if frame["type"]?.stringValue == "rate_limit_event" {
            return rateLimitPayloads(from: frame)
        }
        if frame["type"]?.stringValue == "prompt_suggestion" {
            return ClaudeProtocol.promptSuggestion(in: frame).map { [.nextMessageSuggestion($0)] } ?? []
        }
        if frame["type"]?.stringValue == "system" {
            switch frame["subtype"]?.stringValue {
            case "local_command_output":
                return projector.payloads(from: frame)
            case "status":
                return compactionStatusPayloads(from: frame)
            case "compact_boundary":
                isCompacting = false
                return [.contextCompaction(ClaudeEventProjector.compactionBoundary(from: frame))]
            case "api_retry":
                return ClaudeEventProjector.retry(from: frame).map { [.providerRetrying($0)] } ?? []
            default:
                return taskPayloads(from: frame)
            }
        }
        // The CLI words a refused request as an assistant message marked with the error's
        // category. A plan limit is shown as its own card, not as the model's answer.
        if frame["type"]?.stringValue == "assistant", frame["error"]?.stringValue == "rate_limit" {
            return [.usageLimitReached(stoppedTurn(message: assistantText(frame), in: frame))]
        }

        if frame["type"]?.stringValue == "assistant" {
            for block in frame["message"]?["content"]?.arrayValue ?? [] {
                guard block["type"]?.stringValue == "tool_use",
                      let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue else { continue }
                toolInputs[id] = (name, block["input"] ?? .object([:]))
                if ["Agent", "Task"].contains(name), let model = block["input"]?["model"]?.stringValue, !model.isEmpty {
                    agentModels[id] = model
                }
            }
        }
        correlateAgentResult(frame)

        // A foreground agent's task can end before its tool result arrives. The result still
        // completes the card the call opened, not a new generic one.
        let started = taskOrder.reduce(into: activities) { known, id in
            if let activity = tasks[id]?.activity, known[activity.id] == nil { known[activity.id] = activity }
        }
        var result: [HarnessEventPayload] = []
        for payload in projector.payloads(from: frame, activities: started) {
            switch payload {
            case let .activityStarted(activity):
                if let taskID = taskOrder.first(where: { tasks[$0]?.activity.id == activity.id }),
                   tasks[taskID]?.terminal == true {
                    continue
                }
                var started = activity
                if let tool = toolInputs[activity.id], ["Agent", "Task"].contains(tool.name),
                   let description = tool.input["description"]?.stringValue {
                    started = replacing(activity, title: description)
                }
                if let previous = activities[started.id] {
                    started = TranscriptBuilder.merging(started, with: previous)
                }
                activities[started.id] = started
                result.append(.activityStarted(started))

            case let .activityCompleted(activity):
                let taskID = taskOrder.first { tasks[$0]?.activity.id == activity.id }
                let previous = activities[activity.id] ?? taskID.flatMap { tasks[$0]?.activity }
                var completed = previous.map { TranscriptBuilder.merging($0, with: activity) } ?? activity
                if let report = agentReport(in: frame, for: completed) { completed.output = report }
                if let applied = appliedFileChange(in: frame, for: completed) { completed.diff = applied }
                // A question call keeps what it asked and the answers its result recorded, which its
                // answered card reads, live and when the conversation is read back.
                if let tool = toolInputs[completed.id], tool.name == ClaudeAnswerableTool.askUserQuestion,
                   let answered = ClaudeProtocol.answeredQuestions(
                       input: tool.input, result: typedResult(in: frame, for: completed.id)) {
                    completed.answeredQuestions = answered
                }
                if let taskID, var task = tasks[taskID] {
                    if task.terminal {
                        // A background tool's launch acknowledgement can arrive after its actual
                        // terminal event. It must not replace failure or the final task report.
                        completed.outcome = task.activity.outcome ?? completed.outcome
                        completed.output = task.activity.output ?? completed.output
                    }
                    if !task.terminal && completed.isBackground == true && completed.outcome == nil {
                        task.activity = completed
                        tasks[taskID] = task
                        activities[completed.id] = completed
                        result.append(.activityUpdated(completed))
                    } else {
                        task.activity = completed
                        task.terminal = true
                        tasks[taskID] = task
                        activities.removeValue(forKey: completed.id)
                        result.append(.activityCompleted(completed))
                    }
                } else {
                    activities.removeValue(forKey: completed.id)
                    result.append(.activityCompleted(completed))
                }
                if completed.outcome == nil, let tool = toolInputs.removeValue(forKey: completed.id) {
                    if let plan = taskList.completedTool(
                        name: tool.name, input: tool.input,
                        result: typedResult(in: frame, for: completed.id)
                    ) {
                        result.append(.planUpdated(plan))
                    }
                } else {
                    toolInputs.removeValue(forKey: completed.id)
                }

            case .error where frame["type"]?.stringValue == "result":
                // The limit card already stands for this failure. A rejection the CLI reported
                // without its own limit message becomes that card instead of a generic error.
                if turnLimit != nil { continue }
                if rejectedThisTurn {
                    result.append(.usageLimitReached(stoppedTurn(message: frame["result"]?.stringValue, in: frame)))
                } else {
                    result.append(payload)
                }

            default:
                result.append(payload)
            }
        }

        if frame["type"]?.stringValue == "result" {
            isCompacting = false
            rejectedThisTurn = false
            turnLimit = nil
            // Foreground completion does not end provider-declared background work. Keep its
            // correlation so a late progress/completion still updates the same card.
            for id in taskOrder {
                guard var task = tasks[id], !task.terminal,
                      task.activity.isBackground != true else { continue }
                task.foregroundTurnEnded = true
                task.activity.outcome = .stopped
                tasks[id] = task
            }
            activities = activities.filter { $0.value.isBackground == true }
            toolInputs.removeAll()
        }
        trimTerminalTasks()
        return result
    }

    private mutating func rateLimitPayloads(from frame: JSONValue) -> [HarnessEventPayload] {
        guard let limit = ClaudeEventProjector.rateLimit(from: frame["rate_limit_info"]) else { return [] }
        latestRateLimit = limit
        var payloads: [HarnessEventPayload] = [.rateLimitUpdated(limit)]
        guard limit.status == .rejected, !limit.isUsingOverage else { return payloads }
        rejectedThisTurn = true
        // A report that follows the CLI's limit message names the window and reset the card
        // the turn already shows is missing.
        if let shown = turnLimit {
            payloads.append(.usageLimitReached(stoppedTurn(message: shown.message)))
        }
        return payloads
    }

    /// The limit that stopped this turn: the latest rejection the CLI reported, or the one its own
    /// words name when it reported none, as in a saved conversation, which keeps the words but not
    /// the report. The words' reset is read as of when the record was written.
    private mutating func stoppedTurn(message: String?, in frame: JSONValue? = nil) -> HarnessRateLimit {
        var limit = latestRateLimit.flatMap { $0.status == .rejected ? $0 : nil }
            ?? HarnessRateLimit(status: .rejected)
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        limit.message = trimmed.isEmpty ? turnLimit?.message : trimmed
        if limit.resetsAt == nil, let words = limit.message, let named = ClaudeEventProjector.rateLimit(inMessage: words,
            writtenAt: frame?["timestamp"]?.stringValue.flatMap(ClaudeSubagentTranscriptReader.timestamp) ?? Date()) {
            limit.window = limit.window ?? named.window
            limit.model = limit.model ?? named.model
            limit.resetsAt = named.resetsAt
        }
        turnLimit = limit
        return limit
    }

    private func assistantText(_ frame: JSONValue) -> String {
        (frame["message"]?["content"]?.arrayValue ?? []).compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }

    /// `system/status` reports `compacting` when a compaction starts and every half minute while
    /// it runs, and `compact_result` when it ends. The same frame may also carry the permission
    /// mode, which the adapter reads on its own.
    private mutating func compactionStatusPayloads(from frame: JSONValue) -> [HarnessEventPayload] {
        if let outcome = frame["compact_result"]?.stringValue {
            isCompacting = false
            return [.contextCompaction(HarnessContextCompaction(
                phase: outcome == "failed" ? .failed : .completed,
                message: frame["compact_error"]?.stringValue
            ))]
        }
        guard frame["status"]?.stringValue == "compacting", !isCompacting else { return [] }
        isCompacting = true
        return [.contextCompaction(HarnessContextCompaction(phase: .started))]
    }

    private mutating func taskPayloads(from frame: JSONValue) -> [HarnessEventPayload] {
        guard let subtype = frame["subtype"]?.stringValue,
              ["task_started", "task_progress", "task_updated", "task_notification"].contains(subtype),
              let id = frame["task_id"]?.stringValue else { return [] }
        if frame["skip_transcript"]?.boolValue == true || frame["ambient"]?.boolValue == true {
            hiddenTaskIDs.insert(id)
        }
        if hiddenTaskIDs.contains(id) {
            if subtype == "task_notification" || terminalStatus(frame["patch"]?["status"]?.stringValue) {
                hiddenTaskIDs.remove(id)
            }
            return []
        }
        let payloads = sessionTaskPayloads(subtype: subtype, id: id, frame: frame)
        // A subagent's own task — its background command, or an agent it started — is the
        // subagent's work, not the session's (CLI 2.1.291 `owned_by_subagent`, 2.1.295
        // `parent_task_id` naming the subagent's task). Its foreground calls are the subagent's
        // conversation, read in the subtask panel; while it runs in the background it is a row of
        // the line above the composer under its subagent, never a card in the session, where it
        // would pile up and cut the answer streaming beside it.
        guard let task = tasks[id], task.activity.subtask?.isSubagentWork == true else { return payloads }
        if shownSubagentTaskIDs.contains(id) {
            if task.terminal { shownSubagentTaskIDs.remove(id) }
            return payloads
        }
        guard !task.terminal, task.activity.isBackground == true else { return [] }
        shownSubagentTaskIDs.insert(id)
        return [.activityStarted(task.activity)]
    }

    /// The payloads of a task the session shows, or holds for a subagent.
    private mutating func sessionTaskPayloads(subtype: String, id: String, frame: JSONValue) -> [HarnessEventPayload] {
        var task = tasks[id]
        if subtype == "task_started" {
            guard task?.terminal != true else { return [] }
            let toolID = frame["tool_use_id"]?.stringValue
            let previous = toolID.flatMap { activities[$0] }
            let parentTaskID = frame["parent_task_id"]?.stringValue
            let isSubagentWork = frame["owned_by_subagent"]?.boolValue == true
                || (frame["spawn_depth"]?.integerValue ?? 1) > 1 || parentTaskID != nil
            let activity = HarnessActivity(
                id: toolID ?? "claude-task:\(id)",
                kind: previous?.kind ?? (frame["task_type"]?.stringValue == "local_agent" ? "Agent" : "Task"),
                title: frame["description"]?.stringValue ?? previous?.title ?? "Task",
                detail: previous?.detail,
                input: previous?.input ?? frame["prompt"]?.stringValue,
                output: previous?.output,
                isBackground: frame["is_backgrounded"]?.boolValue ?? previous?.isBackground,
                subtask: HarnessSubtaskReference(
                    taskID: id,
                    agentID: frame["agent_id"]?.stringValue ?? previous?.subtask?.agentID,
                    toolUseID: toolID ?? previous?.subtask?.toolUseID,
                    taskType: frame["task_type"]?.stringValue ?? previous?.subtask?.taskType
                        ?? toolID.flatMap { toolInputs[$0] }.flatMap {
                            ["Agent", "Task"].contains($0.name) ? "local_agent" : nil
                        },
                    ownedBySubagent: isSubagentWork ? true : nil,
                    parentTaskID: parentTaskID,
                    // The model the call asked for, until its result reports the one it resolved.
                    model: previous?.subtask?.model ?? toolID.flatMap { agentModels[$0] }
                )
            )
            task = TaskState(activity: activity)
            if tasks[id] == nil { taskOrder.append(id) }
        }
        guard var task else { return [] }
        if let toolID = frame["tool_use_id"]?.stringValue {
            task.activity.subtask?.toolUseID = toolID
        }
        let wasStarted = tasks[id] != nil || activities[task.activity.id] != nil
        let status = subtype == "task_notification"
            ? frame["status"]?.stringValue : frame["patch"]?["status"]?.stringValue
        let isTerminal = terminalStatus(status)
        guard !task.terminal || isTerminal else { return [] }

        if let background = frame["patch"]?["is_backgrounded"]?.boolValue {
            task.activity.isBackground = background
        }
        // A main-turn result is not an authoritative task terminal event. A later explicit
        // background patch can keep the task alive; late ordinary progress cannot reopen it.
        guard !task.foregroundTurnEnded || task.activity.isBackground == true || isTerminal else {
            return []
        }
        if !isTerminal { task.activity.outcome = nil }
        if let title = frame["patch"]?["description"]?.stringValue {
            task.activity = replacing(task.activity, title: title)
        }
        if let output = taskOutput(frame) { task.activity.output = output }
        if isTerminal {
            task.terminal = true
            task.activity.outcome = switch status {
            case "failed": .failed
            case "stopped", "killed": .stopped
            default: nil
            }
            activities.removeValue(forKey: task.activity.id)
        } else {
            activities[task.activity.id] = task.activity
        }
        tasks[id] = task
        trimTerminalTasks()
        if isTerminal { return [.activityCompleted(task.activity)] }
        return [wasStarted ? .activityUpdated(task.activity) : .activityStarted(task.activity)]
    }

    private func terminalStatus(_ status: String?) -> Bool {
        status.map { ["completed", "failed", "stopped", "killed"].contains($0) } ?? false
    }

    private func taskOutput(_ frame: JSONValue) -> String? {
        var lines: [String] = []
        if let summary = frame["summary"]?.stringValue ?? frame["patch"]?["error"]?.stringValue,
           !summary.isEmpty { lines.append(summary) }
        if let tool = frame["last_tool_name"]?.stringValue { lines.append(tool) }
        if let usage = frame["usage"], let line = usageLine(
            tools: usage["tool_uses"], tokens: usage["total_tokens"], duration: usage["duration_ms"]
        ) { lines.append(line) }
        return lines.isEmpty ? nil : String(lines.joined(separator: "\n").prefix(16_384))
    }

    private func usageLine(tools: JSONValue?, tokens: JSONValue?, duration: JSONValue?) -> String? {
        guard let tools = tools?.integerValue, let tokens = tokens?.integerValue,
              let duration = duration?.integerValue,
              tools >= 0, tokens >= 0, duration >= 0 else { return nil }
        return L10n.format(
            "%@ tool uses · %@ tokens · %@ s", String(tools), String(tokens),
            String(format: "%.1f", Double(duration) / 1_000)
        )
    }

    /// A typed tool_use_result belongs to the single tool-result block in its frame. With
    /// multiple blocks the association is ambiguous; never guess.
    private func typedResult(in frame: JSONValue, for toolUseID: String) -> JSONValue? {
        let results = (frame["message"]?["content"]?.arrayValue ?? []).filter {
            $0["type"]?.stringValue == "tool_result"
        }
        guard results.count == 1, results[0]["tool_use_id"]?.stringValue == toolUseID else { return nil }
        return frame["tool_use_result"]
    }

    /// An Agent/Task result's text wraps the child's report in the CLI's hand-back framing for
    /// the model. The typed result carries the report itself and the child's own totals.
    private func agentReport(in frame: JSONValue, for activity: HarnessActivity) -> String? {
        guard ["Agent", "Task"].contains(activity.kind), activity.outcome == nil,
              let typed = typedResult(in: frame, for: activity.id),
              let report = typed["content"]?.contentText else { return nil }
        let totals = usageLine(
            tools: typed["totalToolUseCount"], tokens: typed["totalTokens"], duration: typed["totalDurationMs"]
        )
        return String(([report] + (totals.map { [$0] } ?? [])).joined(separator: "\n").prefix(16_384))
    }

    /// An `Edit` or `Write` result's typed form names the hunks it applied and their lines in the
    /// file (`structuredPatch`). They replace the text the call sent, so the file change card and
    /// the review panel's Last turn show where the change landed. A new file's result has no hunks;
    /// its contents stay as the call sent them.
    private func appliedFileChange(in frame: JSONValue, for activity: HarnessActivity) -> HarnessActivityDiff? {
        guard let diff = activity.diff, activity.outcome == nil,
              let typed = typedResult(in: frame, for: activity.id),
              let hunks = typed["structuredPatch"]?.arrayValue, !hunks.isEmpty else { return nil }
        var lines: [String] = []
        for hunk in hunks {
            guard let oldStart = hunk["oldStart"]?.integerValue, let oldLines = hunk["oldLines"]?.integerValue,
                  let newStart = hunk["newStart"]?.integerValue, let newLines = hunk["newLines"]?.integerValue,
                  let body = hunk["lines"]?.arrayValue else { return nil }
            lines.append("@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@")
            lines += body.compactMap(\.stringValue)
        }
        return HarnessActivityDiff(path: diff.path, unified: lines.joined(separator: "\n") + "\n")
    }

    private func replacing(_ activity: HarnessActivity, title: String) -> HarnessActivity {
        HarnessActivity(
            id: activity.id, kind: activity.kind, title: title, detail: activity.detail,
            outcome: activity.outcome, input: activity.input, output: activity.output,
            diff: activity.diff, isBackground: activity.isBackground, subtask: activity.subtask
        )
    }

    /// Only a live, nonterminal correlation can authorize a task-specific control request.
    func activeTaskID(for activityID: String) -> String? {
        taskOrder.first { id in
            guard let task = tasks[id] else { return false }
            return task.activity.id == activityID && !task.terminal
                && (!task.foregroundTurnEnded || task.activity.isBackground == true)
        }
    }

    /// An Agent call's result names the subagent (`agentId`) and the model it runs on
    /// (`resolvedModel`, CLI 2.1.291), whether it was launched in the background or ran to its end.
    private mutating func correlateAgentResult(_ frame: JSONValue) {
        guard frame["type"]?.stringValue == "user",
              let block = frame["message"]?["content"]?.arrayValue?.first(where: {
                  $0["type"]?.stringValue == "tool_result"
              }),
              block["is_error"]?.boolValue != true,
              let id = block["tool_use_id"]?.stringValue,
              let typed = typedResult(in: frame, for: id) else { return }
        let agentID = typed["agentId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let model = typed["resolvedModel"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard agentID != nil || model != nil else { return }
        if let model { agentModels[id] = model }
        let taskIDs = taskOrder.filter { tasks[$0]?.activity.id == id }
        guard let activity = activities[id] ?? taskIDs.first.flatMap({ tasks[$0]?.activity }),
              ["Agent", "Task"].contains(activity.kind) else { return }
        var reference = activity.subtask ?? HarnessSubtaskReference(toolUseID: id, taskType: "local_agent")
        if let agentID { reference.agentID = agentID }
        if let model { reference.model = model }
        activities[id]?.subtask = reference
        for taskID in taskIDs { tasks[taskID]?.activity.subtask = reference }
    }

    private mutating func trimTerminalTasks() {
        // Active tasks retain their identity; only old terminal correlations are bounded.
        let terminalIDs = taskOrder.filter {
            guard let task = tasks[$0] else { return true }
            return task.terminal || (task.foregroundTurnEnded && task.activity.isBackground != true)
        }
        let expired = Set(terminalIDs.prefix(max(0, terminalIDs.count - 128)))
        for id in expired { tasks.removeValue(forKey: id) }
        taskOrder.removeAll { expired.contains($0) }
    }
}
