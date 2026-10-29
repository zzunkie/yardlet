import Foundation
import YardletAgentTools

// The scheduled-task tools (`ScheduleToolCatalog`, docs/AGENT_BROWSER_TOOLS.md, "Scheduled-task tools"): an agent in a Yardlet task
// creates, lists, changes, deletes and runs the person's schedules, as the Claude app's agents do
// through its `scheduled-tasks` server. Every call is answered here against the one scheduler the
// person's own Scheduled tasks use, so a schedule an agent makes is the same record, runs the same
// way and is changed, paused or deleted in the same place. What a call leaves out comes from the task
// that made it, as the Claude app fills `cwd` and `notifySessionId` from the calling session: its
// harness, the folder it came from, its project and account, and its Auto or Bypass permissions.
//
// Where the Claude app and the Codex app ask before a change, the harness's own approval asks in
// Yardlet too (Claude Code's request card; Codex as its approval setting and the tool's annotations
// decide), so a call that arrives here was allowed. Yardlet adds two cards of its own. One is the
// Claude app's rule for a session a schedule started: a change from it is asked in every permission
// mode, and it may not run a schedule or delete the one that started it. The other is
// `send_message_to_task`'s rule for a schedule whose runs continue another task, since each run is a
// message into that task. What an agent writes runs as its task's message, never as the person's,
// and a schedule runs no more freely than the task that made it.

extension AppModel: ScheduleToolHandling {
    func callScheduleTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
        let arguments = JSONValue(arguments)
        guard let caller = sessionToolCaller(callerID) else {
            return .error("Yardlet no longer has the task that made this call.")
        }
        if ScheduleToolCatalog.changingTools.contains(name),
           let refusal = await scheduledRunRefusal(name, arguments: arguments, caller: caller) {
            return .error(refusal)
        }
        switch name {
        case ScheduleToolCatalog.create: return await createScheduleFromTool(arguments, caller: caller)
        case ScheduleToolCatalog.list: return listSchedulesForTool()
        case ScheduleToolCatalog.update: return await updateScheduleFromTool(arguments, caller: caller)
        case ScheduleToolCatalog.delete: return deleteScheduleFromTool(arguments)
        case ScheduleToolCatalog.run: return await runScheduleFromTool(arguments)
        case ScheduleToolCatalog.listRuns: return listScheduleRunsForTool(arguments)
        default: return .error("Unknown tool: \(name)")
        }
    }

    // MARK: - From a scheduled run

    /// The schedule whose run started this task as a new task, if one did.
    func scheduleThatStarted(_ taskID: UUID) -> ScheduledTask? {
        scheduledTasks.schedules.first { schedule in
            schedule.destination.mode == .newTask
                && schedule.state.runs.contains { $0.outcome == .started && $0.taskID == taskID }
        }
    }

    /// Why a change from a task a schedule started may not go ahead, or nil. As the Claude app refuses
    /// in a scheduled-run session: no run of a schedule, no deleting the schedule that started it, and
    /// any other change asked of the person even where Claude Code would not ask (Auto or Bypass
    /// permissions).
    private func scheduledRunRefusal(_ tool: String, arguments: JSONValue, caller: SessionToolCaller) async -> String? {
        guard let origin = scheduleThatStarted(caller.hostTaskID) else { return nil }
        if tool == ScheduleToolCatalog.run {
            return "Refusing to run a scheduled task from a task a scheduled run started. Run it from a regular "
                + "task instead."
        }
        if tool == ScheduleToolCatalog.delete,
           arguments[ScheduleToolCatalog.Key.scheduleID]?.stringValue.flatMap(UUID.init(uuidString:)) == origin.id {
            return "Refusing to delete the scheduled task whose run started this task. Delete it from a regular "
                + "task instead."
        }
        guard let host = store.sessions.first(where: { $0.id == caller.hostTaskID }),
              Self.unaskedPermissionMode(of: host) != nil,
              let text = ScheduleToolApproval.request(
                toolName: "mcp__\(AgentToolEnvironment.serverName)__\(tool)", input: arguments,
                calendar: scheduledTasks.calendar(), now: scheduledTasks.now()) else { return nil }
        let allowed = await askPerson(title: text.title, detail: text.detail, caller: caller)
        return allowed ? nil : "\(tool) needs the person's approval in a task a scheduled run started, and it was "
            + "not given. Carry on without it."
    }

    // MARK: - create_scheduled_task

    private func createScheduleFromTool(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        typealias Key = ScheduleToolCatalog.Key
        let prompt: String
        switch Self.schedulePrompt(arguments[Key.prompt]?.stringValue ?? "") {
        case let .success(value): prompt = value
        case let .failure(error): return error.result("Nothing was created")
        }
        let now = scheduledTasks.now()
        let trigger: ScheduleTrigger
        switch scheduleToolTrigger(arguments, now: now) {
        case let .success(value?): trigger = value
        case .success(nil):
            return .error("Nothing was created: give cronExpression (repeating) or fireAt (one run).")
        case let .failure(error): return error.result("Nothing was created")
        }
        let destination: ScheduleDestination
        switch scheduleToolDestination(arguments, caller: caller, base: nil) {
        case let .success(value): destination = value
        case let .failure(error): return error.result("Nothing was created")
        }
        let name = Self.scheduleName(arguments[Key.name]?.stringValue, prompt: prompt)
        if let refusal = await scheduleAgentRefusal(destination, previous: nil, promptChanged: true, prompt: prompt,
                                                    trigger: trigger, name: name, caller: caller) {
            return .failure("Nothing was created: \(refusal)", .refused, retry: .no)
        }
        scheduledTasks.create(ScheduledTask(name: name, prompt: prompt, trigger: trigger, destination: destination,
                                            createdAt: now, agentTaskID: caller.hostTaskID))
        guard let schedule = scheduledTasks.schedules.last else {
            return .error("Nothing was created: Yardlet could not keep the schedule.")
        }
        await announceAgentSchedule(schedule, caller: caller)
        return .text(ScheduleToolCatalog.createdResult(scheduleID: schedule.id.uuidString, name: schedule.name,
                                                       body: scheduleToolSummary(schedule)))
    }

    /// The Claude app's notice for a schedule an agent made without a card (Bypass permissions, or Auto
    /// whose classifier let it through): "Claude scheduled a task: “{name}”" and the mode its runs use.
    /// It leads to the task that made it, where the schedule's row opens it. A caller that asks before a
    /// change saw the request card, so it gets none.
    private func announceAgentSchedule(_ schedule: ScheduledTask, caller: SessionToolCaller) async {
        guard let host = store.sessions.first(where: { $0.id == caller.hostTaskID }),
              let mode = Self.unaskedPermissionMode(of: host) else { return }
        guard (await systemNotificationCenter.authorization()).isDeliverable else { return }
        await systemNotificationCenter.post(SystemNotification(
            title: L10n.format("%@ scheduled a task: “%@”", host.harness.displayName, schedule.name),
            body: L10n.format("Its runs will use %@ mode.", ClaudePermissionMode.displayName(mode) ?? mode),
            identifier: "yardlet-agent-schedule-\(schedule.id.uuidString)",
            target: SystemNotificationTarget(sessionID: host.id)))
    }

    /// The mode a Claude Code task runs changes in without a card (Bypass permissions, or Auto, whose
    /// classifier decides), which a new schedule it makes carries over as the Claude app's does; nil
    /// for any other mode or harness.
    static func unaskedPermissionMode(of session: SessionRecord) -> String? {
        guard session.harness == .claudeCode,
              let mode = session.providerOptions[ClaudeLaunchOption.permissionMode],
              mode == ClaudePermissionMode.bypassPermissions || mode == "auto" else { return nil }
        return mode
    }

    static func schedulePrompt(_ text: String) -> Result<String, SessionToolError> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(SessionToolError(message: "prompt is required.")) }
        guard prompt.count <= ScheduleToolCatalog.maximumPromptLength else {
            return .failure(SessionToolError(
                message: "the prompt is longer than \(ScheduleToolCatalog.maximumPromptLength) characters."))
        }
        // Each run sends it as this task's message, as `send_message_to_task` and `create_task` send theirs.
        guard !prompt.hasPrefix("/") else {
            return .failure(SessionToolError(message: "the prompt must be words, not a slash command; each run "
                + "sends it as this task's message."))
        }
        return .success(prompt)
    }

    /// Why what an agent makes or changes in a schedule may not stand, asking the person where a session tool
    /// would, or nil. Each run does what the caller could do itself: a new task's run is a child task it starts
    /// later (`create_task`'s nesting limit and its card for another project or a folder outside the caller's),
    /// no freer than the caller; a run that continues another task is a message to it (`send_message_to_task`'s
    /// card). `previous` is where the runs went before, for a change: only what changed is weighed.
    private func scheduleAgentRefusal(_ destination: ScheduleDestination, previous: ScheduleDestination?,
                                      promptChanged: Bool, prompt: String, trigger: ScheduleTrigger, name: String,
                                      caller: SessionToolCaller) async -> String? {
        let when = ScheduleText.summary(trigger, calendar: scheduledTasks.calendar(), now: scheduledTasks.now())
        switch destination.mode {
        case .newTask:
            let becameNew = previous?.mode != .newTask
            if becameNew, let refusal = sessionToolSpawnRefusal(caller: caller) { return refusal }
            let modeChanged = becameNew || destination.harness != previous?.harness
                || destination.modelChoice?.permissionMode != previous?.modelChoice?.permissionMode
            if promptChanged || modeChanged, let refusal = scheduleFreedomRefusal(destination, caller: caller) {
                return refusal
            }
            let placeChanged = becameNew || destination.workspacePath != previous?.workspacePath
                || destination.projectID != previous?.projectID
            let project = projects.project(id: destination.projectID)
            let origin = store.sessions.first { $0.id == caller.hostTaskID }?.originWorkspaceURL
            guard placeChanged, !harnessAskedBeforeScheduleCall(caller), sessionToolAsksPerson(caller),
                  sessionToolPlaceReachesPast(folder: destination.workspaceURL, project: project, caller: caller,
                                              alsoWithin: origin.map { [$0] } ?? []) else { return nil }
            let place = project?.name ?? destination.workspacePath ?? ""
            let detail = "“\(name)” · \(when)\n" + L10n.format("%@ → %@", caller.title, place) + "\n\n"
                + Self.cardPreview(prompt)
            let allowed = await askPerson(title: L10n.string("Schedule a task in another project"), detail: detail,
                                          caller: caller)
            return allowed ? nil : "the person did not approve a scheduled task in another project."
        case .continueTask:
            guard promptChanged || destination.targetTaskID != previous?.targetTaskID,
                  !harnessAskedBeforeScheduleCall(caller), let id = destination.targetTaskID, id != caller.hostTaskID,
                  let target = store.sessions.first(where: { $0.id == id }),
                  let reach = sessionToolMessageReach(to: target, caller: caller) else { return nil }
            let title = reach == .raisesPermission
                ? L10n.string("Schedule messages to a task that runs without asking")
                : L10n.string("Schedule messages to another project's task")
            let detail = "“\(name)” · \(when)\n" + sessionToolMessageDetail(to: target, prompt, caller: caller)
            let allowed = await askPerson(title: title, detail: detail, caller: caller)
            return allowed ? nil : "the person did not approve sending its runs to that task."
        }
    }

    /// Whether the caller's harness asked the person before this call came: Claude Code asks before every
    /// changing scheduled-task call, on a card that names the place or the task each run goes to, unless it
    /// runs in Auto or Bypass permissions. Whether another harness asks is its own setting, so Yardlet asks
    /// for it where a session tool would.
    private func harnessAskedBeforeScheduleCall(_ caller: SessionToolCaller) -> Bool {
        guard caller.id == caller.hostTaskID, caller.harness == .claudeCode,
              let host = store.sessions.first(where: { $0.id == caller.hostTaskID }) else { return false }
        return Self.unaskedPermissionMode(of: host) == nil
    }

    /// Why a new task's runs would do more without asking than the caller may, or nil: a Claude Code run in a
    /// mode freer than the caller's (`scheduleModeCeiling`), or any other harness's run from a read-only caller,
    /// since only Claude Code's mode is kept with a schedule.
    private func scheduleFreedomRefusal(_ destination: ScheduleDestination, caller: SessionToolCaller) -> String? {
        if destination.harness == .claudeCode {
            let mode = destination.modelChoice?.permissionMode
            guard ClaudePermissionMode.freedom(mode) > scheduleModeCeiling(caller) else { return nil }
            return "its runs would use \(mode.map(Self.claudeAppMode) ?? "default") mode, which does more without "
                + "asking than this task may; the person can change it in Scheduled tasks."
        }
        guard caller.permission == .readOnly else { return nil }
        return "a read-only task schedules new tasks only on Claude Code, whose runs keep plan mode; the person can "
            + "schedule others in Scheduled tasks."
    }

    /// A schedule's name: the one given, on one line, or the prompt's first words.
    static func scheduleName(_ given: String?, prompt: String) -> String {
        let line = ScheduleToolCatalog.oneLine(given ?? "").trimmingCharacters(in: .whitespaces)
        let name = line.isEmpty ? SessionTitleProjection.provisionalTitle(from: prompt) : line
        return String(name.prefix(ScheduleToolCatalog.maximumNameLength))
    }

    // MARK: - list_scheduled_tasks

    private func listSchedulesForTool() -> AgentToolResult {
        let entries = scheduledTasks.schedules.map(scheduleToolEntry)
        guard !entries.isEmpty else { return .text("No scheduled tasks in Yardlet.") }
        return .text(SessionToolText.json(entries))
    }

    // MARK: - update_scheduled_task

    private func updateScheduleFromTool(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        typealias Key = ScheduleToolCatalog.Key
        let schedule: ScheduledTask
        switch scheduleForTool(arguments) {
        case let .success(value): schedule = value
        case let .failure(error): return error.result("Nothing was updated")
        }
        var edited = schedule
        var parts: [String] = []
        if let text = arguments[Key.prompt]?.stringValue {
            switch Self.schedulePrompt(text) {
            case let .success(prompt):
                if prompt != edited.prompt { parts.append("prompt") }
                edited.prompt = prompt
            case let .failure(error): return error.result("Nothing was updated")
            }
        }
        if let given = arguments[Key.name]?.stringValue {
            let name = Self.scheduleName(given, prompt: edited.prompt)
            if name != edited.name { parts.append("name") }
            edited.name = name
        }
        switch scheduleToolTrigger(arguments, now: scheduledTasks.now()) {
        case let .success(trigger?):
            edited.trigger = trigger
            parts.append("schedule (\(ScheduleToolText.summary(trigger, calendar: scheduledTasks.calendar())))")
        case .success(nil): break
        case let .failure(error): return error.result("Nothing was updated")
        }
        if Key.destination.contains(where: { arguments[$0] != nil }) {
            switch scheduleToolDestination(arguments, caller: caller, base: schedule.destination) {
            case let .success(value):
                if value != edited.destination { parts.append("where each run goes") }
                edited.destination = value
            case let .failure(error): return error.result("Nothing was updated")
            }
        }
        let enabled = Self.bool(arguments[Key.enabled])
        guard !parts.isEmpty || enabled != nil else {
            return .error("Nothing was updated for scheduled task \(schedule.id.uuidString): give at least one of "
                + "name, prompt, cronExpression, fireAt, enabled, or where each run goes.")
        }
        // A prompt the agent wrote runs as this task's message; one the person wrote stays theirs wherever it goes.
        let promptChanged = edited.prompt != schedule.prompt
        if promptChanged { edited.agentTaskID = caller.hostTaskID }
        if promptChanged || edited.destination != schedule.destination {
            if let refusal = await scheduleAgentRefusal(edited.destination, previous: schedule.destination,
                                                        promptChanged: promptChanged, prompt: edited.prompt,
                                                        trigger: edited.trigger, name: edited.name, caller: caller) {
                return .failure("Nothing was updated: \(refusal)", .refused, retry: .no)
            }
            // The schedule may have changed or gone while the card waited.
            guard scheduledTasks.schedule(id: schedule.id) == schedule else {
                return .error("Nothing was updated: the schedule changed meanwhile; list it and try again.")
            }
        }
        if edited != schedule { scheduledTasks.update(edited) }
        if let enabled {
            // Resuming one that turned itself off clears why, as Resume in Scheduled tasks does.
            if enabled != schedule.isEnabled || (enabled && schedule.state.stopReason != nil) {
                scheduledTasks.setEnabled(enabled, for: schedule.id)
            }
            parts.append(enabled ? "enabled" : "paused")
        }
        guard let updated = scheduledTasks.schedule(id: schedule.id) else {
            return .error("Nothing was updated: the schedule is gone.")
        }
        return .text("Scheduled task \"\(ScheduleToolCatalog.oneLine(updated.name))\" (scheduleId: "
            + "\(updated.id.uuidString)) updated: \(parts.joined(separator: ", ")).\n\n" + scheduleToolSummary(updated))
    }

    // MARK: - delete_scheduled_task

    private func deleteScheduleFromTool(_ arguments: JSONValue) -> AgentToolResult {
        let schedule: ScheduledTask
        switch scheduleForTool(arguments) {
        case let .success(value): schedule = value
        case let .failure(error): return error.result("Nothing was deleted")
        }
        scheduledTasks.delete(schedule.id)
        return .text("Scheduled task \"\(ScheduleToolCatalog.oneLine(schedule.name))\" (scheduleId: "
            + "\(schedule.id.uuidString)) deleted. It will not run again; the tasks its runs started stay.")
    }

    // MARK: - run_scheduled_task

    private func runScheduleFromTool(_ arguments: JSONValue) async -> AgentToolResult {
        let schedule: ScheduledTask
        switch scheduleForTool(arguments) {
        case let .success(value): schedule = value
        case let .failure(error): return error.result("Not run")
        }
        guard !scheduledTasks.startingIDs.contains(schedule.id) else {
            return .error("Not run: a run of scheduled task \(schedule.id.uuidString) is starting now.")
        }
        let before = schedule.state.runs.first?.id
        await scheduledTasks.runNow(schedule.id)
        guard let run = scheduledTasks.schedule(id: schedule.id)?.state.runs.first, run.id != before else {
            return .error("Not run: the schedule is gone.")
        }
        let name = ScheduleToolCatalog.oneLine(schedule.name)
        switch run.outcome {
        case .started:
            let task = run.taskID?.uuidString ?? ""
            let verb = schedule.destination.mode == .continueTask ? "continued" : "started"
            return .text("Scheduled task \"\(name)\" ran now: it \(verb) task \(task). read_task or wait_tasks "
                + "show what it does, and list_task_runs lists its runs.")
        case .skipped:
            return .error("Not run: \(run.skipReason.map(Self.skipWords) ?? "it was skipped").")
        case .failed:
            return .error("The run of scheduled task \"\(name)\" did not start: \(run.failure ?? "no reason given")")
        }
    }

    private static func skipWords(_ reason: ScheduledTaskRun.SkipReason) -> String {
        switch reason {
        case .previousRunActive: "the task its previous run started is still working or waiting on the person"
        case .targetBusy: "the task it continues is working, waiting on the person, or being edited"
        }
    }

    // MARK: - list_task_runs

    private func listScheduleRunsForTool(_ arguments: JSONValue) -> AgentToolResult {
        let schedule: ScheduledTask
        switch scheduleForTool(arguments) {
        case let .success(value): schedule = value
        case let .failure(error): return .error(error.message)
        }
        let limit = Self.integer(arguments[ScheduleToolCatalog.Key.limit])
            .map { min(max($0, 1), ScheduleToolCatalog.maximumRunLimit) } ?? ScheduleToolCatalog.defaultRunLimit
        let runs = schedule.state.runs.prefix(limit).map { run in
            let task = run.taskID.flatMap { id in store.sessions.first { $0.id == id } }
            return ScheduleToolRun(
                at: scheduleToolISO(run.at), scheduledFor: run.slot.map(scheduleToolISO),
                trigger: run.trigger.rawValue, outcome: run.outcome.rawValue,
                skipReason: run.skipReason.map(Self.skipWords), failure: run.failure,
                taskId: run.taskID?.uuidString, taskTitle: task?.title,
                taskLink: task.map { SessionToolText.link(title: $0.title, taskID: $0.id) })
        }
        return .text(SessionToolText.json(ScheduleToolRuns(
            scheduleId: schedule.id.uuidString, totalRuns: schedule.state.runs.count, runs: Array(runs))))
    }

    // MARK: - What a schedule reads as

    struct ScheduleToolEntry: Encodable, Equatable {
        var scheduleId: String
        var name: String
        var schedule: String
        var cronExpression: String?
        var fireAt: String?
        var enabled: Bool
        var nextRunAt: String?
        var lastRunAt: String?
        var stoppedBecause: String?
        var eachRun: String
        var continuesTaskId: String?
        var harness: String
        var folder: String?
        var project: String?
        var useWorktree: Bool?
        /// The task each new task nests under; nil for a top-level task.
        var nestedUnderTaskId: String?
        var model: String?
        var effort: String?
        var permissionMode: String?
        var prompt: String
    }

    struct ScheduleToolRun: Encodable, Equatable {
        var at: String
        var scheduledFor: String?
        var trigger: String
        var outcome: String
        var skipReason: String?
        var failure: String?
        var taskId: String?
        var taskTitle: String?
        var taskLink: String?
    }

    struct ScheduleToolRuns: Encodable, Equatable {
        var scheduleId: String
        var totalRuns: Int
        var runs: [ScheduleToolRun]
    }

    func scheduleToolEntry(_ schedule: ScheduledTask) -> ScheduleToolEntry {
        let destination = schedule.destination
        let calendar = scheduledTasks.calendar()
        var fireAt: String?
        if case let .once(moment) = schedule.trigger { fireAt = scheduleToolISO(moment) }
        let isNew = destination.mode == .newTask
        return ScheduleToolEntry(
            scheduleId: schedule.id.uuidString, name: schedule.name,
            schedule: ScheduleToolText.summary(schedule.trigger, calendar: calendar),
            cronExpression: ScheduleToolText.cronExpression(schedule.trigger, calendar: calendar), fireAt: fireAt,
            enabled: schedule.isEnabled,
            nextRunAt: scheduledTasks.nextRun(of: schedule).map(scheduleToolISO),
            lastRunAt: schedule.state.lastRunAt.map(scheduleToolISO),
            stoppedBecause: Self.stopWords(schedule.state.stopReason),
            eachRun: isNew ? "new task" : "continues a task",
            continuesTaskId: isNew ? nil : destination.targetTaskID?.uuidString,
            harness: destination.harness.rawValue,
            folder: isNew ? destination.workspacePath ?? "(a new chat folder)" : nil,
            project: isNew ? projects.project(id: destination.projectID)?.name : nil,
            useWorktree: isNew && destination.workspacePath != nil ? destination.startsInNewWorktree : nil,
            nestedUnderTaskId: isNew ? destination.parentTaskID?.uuidString : nil,
            model: isNew ? destination.modelChoice?.model : nil,
            effort: isNew ? destination.modelChoice?.effort : nil,
            permissionMode: isNew ? destination.modelChoice?.permissionMode.map(Self.claudeAppMode) : nil,
            prompt: schedule.prompt)
    }

    /// Lines as the Claude app's create answer has them: the schedule, the next run, where each run
    /// goes, and that it runs while Yardlet is open.
    func scheduleToolSummary(_ schedule: ScheduledTask) -> String {
        let calendar = scheduledTasks.calendar()
        let destination = schedule.destination
        var lines: [String] = []
        if case let .once(moment) = schedule.trigger {
            lines.append("**Will run once at:** \(scheduleToolISO(moment))")
        } else {
            lines.append("**Schedule:** \(ScheduleToolText.summary(schedule.trigger, calendar: calendar))")
        }
        if let stopped = Self.stopWords(schedule.state.stopReason) {
            lines.append("**Off:** \(stopped)")
        } else if !schedule.isEnabled {
            lines.append("**Paused**")
        } else if let next = scheduledTasks.nextRun(of: schedule), !schedule.trigger.isOnce {
            lines.append("**Next run:** \(scheduleToolISO(next))")
        }
        switch destination.mode {
        case .continueTask:
            let title = destination.targetTaskID.flatMap { id in store.sessions.first { $0.id == id }?.title }
            lines.append("**Each run:** the next message of task \(destination.targetTaskID?.uuidString ?? "")"
                + (title.map { " (\(ScheduleToolCatalog.oneLine($0)))" } ?? ""))
        case .newTask:
            var place = destination.workspacePath.map { "in \($0)" } ?? "in a new chat folder"
            if destination.startsInNewWorktree { place += ", in a new worktree" }
            var words = "a new \(destination.harness.displayName) task \(place)"
            if let model = destination.modelChoice?.model { words += ", on \(model)" }
            if destination.harness == .claudeCode {
                let mode = destination.modelChoice?.permissionMode.map(Self.claudeAppMode)
                words += mode.map { ", in \($0) mode" } ?? ", in the default permission mode"
            }
            words += destination.parentTaskID.map { ", nested under task \($0.uuidString)" } ?? ", as a top-level task"
            lines.append("**Each run:** \(words)")
        }
        lines.append("")
        lines.append("It runs while Yardlet is open; a run missed while Yardlet was closed runs once when it opens "
            + "again, within \(Int(ScheduleRunPolicy.catchUpWindow / 86_400)) days. The person changes, pauses or "
            + "deletes it in Scheduled tasks in Yardlet's sidebar.")
        return lines.joined(separator: "\n")
    }

    private static func stopWords(_ reason: ScheduleStopReason?) -> String? {
        switch reason {
        case .repeatedFailures?: "its runs failed to start \(ScheduleRunPolicy.failureLimit) times in a row"
        case .finished?: "it ran once"
        case .expired?: "its time passed while it could not run"
        case nil: nil
        }
    }

    /// Yardlet's Manual is the Claude app's `default`.
    static func claudeAppMode(_ mode: String) -> String {
        mode == ClaudePermissionMode.manual ? "default" : mode
    }

    /// A time as the tools spell it: ISO 8601 in the Mac's local time, with its offset.
    func scheduleToolISO(_ date: Date) -> String {
        ScheduleToolText.iso(date, calendar: scheduledTasks.calendar())
    }

    // MARK: - Arguments

    /// The schedule a call names by its ID.
    private func scheduleForTool(_ arguments: JSONValue) -> Result<ScheduledTask, SessionToolError> {
        let key = ScheduleToolCatalog.Key.scheduleID
        guard let reference = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !reference.isEmpty else {
            return .failure(SessionToolError(message: "\(key) is required."))
        }
        guard let id = UUID(uuidString: reference), let schedule = scheduledTasks.schedule(id: id) else {
            return .failure(SessionToolError(
                message: "scheduled task \(reference) not found; list_scheduled_tasks gives the ids."))
        }
        return .success(schedule)
    }

    /// The trigger a call gives: a cron expression or a moment, not both. Nil when it gives neither.
    func scheduleToolTrigger(_ arguments: JSONValue, now: Date) -> Result<ScheduleTrigger?, SessionToolError> {
        typealias Key = ScheduleToolCatalog.Key
        let cron = arguments[Key.cronExpression]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let fireAt = arguments[Key.fireAt]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let calendar = scheduledTasks.calendar()
        switch (cron.flatMap { $0.isEmpty ? nil : $0 }, fireAt.flatMap { $0.isEmpty ? nil : $0 }) {
        case (nil, nil):
            return .success(nil)
        case (_?, _?):
            return .failure(SessionToolError(
                message: "give either cronExpression (repeating) or fireAt (one run), not both."))
        case let (cron?, nil):
            guard let trigger = OtherAppScheduleImport.cronTrigger(cron, calendar: calendar) else {
                return .failure(SessionToolError(message: ScheduleToolCatalog.unsupportedCron(cron)))
            }
            return .success(trigger)
        case let (nil, text?):
            guard let moment = ScheduleToolText.moment(text, calendar: calendar) else {
                return .failure(SessionToolError(message: "invalid fireAt \"\(text)\": give an ISO 8601 time "
                    + "such as \"2026-10-18T09:00:00+09:00\"."))
            }
            guard moment > now else {
                return .failure(SessionToolError(message: "fireAt must be in the future; \"\(text)\" is "
                    + "\(scheduleToolISO(moment)) and it is now \(scheduleToolISO(now))."))
            }
            return .success(.once(moment))
        }
    }

    /// Where each run goes: the call's choices over `base` (the schedule being changed) or, for a new
    /// schedule, over the calling task — its harness, the folder it came from, its project, account and
    /// Auto or Bypass permissions.
    func scheduleToolDestination(_ arguments: JSONValue, caller: SessionToolCaller,
                                 base: ScheduleDestination?) -> Result<ScheduleDestination, SessionToolError> {
        typealias Key = ScheduleToolCatalog.Key
        let host = store.sessions.first { $0.id == caller.hostTaskID }
        // Continuing a task: each run is that task's next message, on its own harness and settings.
        if let reference = arguments[Key.continueTaskID]?.stringValue?.trimmingCharacters(in: .whitespaces),
           !reference.isEmpty {
            let id = reference == SessionToolCatalog.selfReference ? caller.hostTaskID : UUID(uuidString: reference)
            guard let id, let target = store.sessions.first(where: { $0.id == id }) else {
                return .failure(SessionToolError(message: "no task \(reference); list_tasks gives the task ids, "
                    + "and \"self\" names this one."))
            }
            for key in [Key.harness, Key.project, Key.chat, Key.model, Key.effort, Key.permissionMode, Key.useWorktree,
                        Key.topLevel] where arguments[key] != nil {
                return .failure(SessionToolError(message: "\(key) is for a new task each run; a run that "
                    + "continues a task uses that task's own."))
            }
            var destination = ScheduleDestination(mode: .continueTask, harness: target.harness)
            destination.targetTaskID = target.id
            return .success(destination)
        }

        let fallbackHarness = base.flatMap { $0.mode == .newTask ? $0.harness : nil } ?? caller.harness
        let harness: HarnessKind
        switch sessionToolHarness(arguments[Key.harness], default: fallbackHarness) {
        case let .success(value): harness = value
        case let .failure(error): return .failure(error)
        }
        let keepsBase = base?.mode == .newTask
        var destination = keepsBase ? base! : ScheduleDestination(harness: harness)
        let harnessChanged = keepsBase && destination.harness != harness
        destination.mode = .newTask
        destination.targetTaskID = nil
        destination.harness = harness

        // The place: a project by name or a folder by path, or a chat (Scheduled tasks' "Chat (no project)":
        // no folder, so each run makes its own), else the schedule's own, else the folder the caller came
        // from (a task in a worktree schedules in its repository, as the Claude app takes the session's
        // `originCwd`).
        let chat = Self.bool(arguments[Key.chat])
        if let place = arguments[Key.project]?.stringValue, !place.trimmingCharacters(in: .whitespaces).isEmpty {
            guard chat != true else {
                return .failure(SessionToolError(message: "chat starts each run with no project, so it takes no project."))
            }
            switch sessionToolPlace(place, caller: caller) {
            case let .success(value):
                destination.workspacePath = ProjectSidebarPresentation.normalizedPath(for: value.folder)
                destination.projectID = value.project?.id
            case let .failure(error): return .failure(error)
            }
        } else if chat == true {
            destination.workspacePath = nil
            destination.projectID = nil
            destination.startsInNewWorktree = false
        } else if !keepsBase || (chat == false && destination.workspacePath == nil) {
            let folder = host?.originWorkspaceURL ?? caller.workspaceURL
            destination.workspacePath = ProjectSidebarPresentation.normalizedPath(for: folder)
            destination.projectID = caller.projectID
        }
        if let worktree = Self.bool(arguments[Key.useWorktree]) {
            guard destination.workspacePath != nil || !worktree else {
                return .failure(SessionToolError(message: "a chat has no repository for a worktree."))
            }
            destination.startsInNewWorktree = worktree
        }

        // The account: the caller's own when it is the same harness, else the harness's new-task account
        // when the run starts.
        if !keepsBase || harnessChanged {
            if let host, host.harness == harness {
                destination.accountID = host.connection?.id ?? AccountChoice.nativeID(for: harness)
            } else {
                destination.accountID = nil
            }
        }

        // Model, effort and permission mode, in the harness's own values. A new Claude Code schedule made
        // from a Claude Code task in Auto or Bypass permissions keeps that mode, as the Claude app's does;
        // otherwise its runs start in the default mode.
        var choice = (keepsBase && !harnessChanged ? destination.modelChoice : nil) ?? NewTaskModelChoice(model: nil)
        if !keepsBase || harnessChanged {
            // A caller that reads only makes runs that read only, as its child tasks do.
            let readsOnly = scheduleModeCeiling(caller) < ClaudePermissionMode.freedom(nil)
            choice.permissionMode = harness == .claudeCode
                ? host.flatMap(Self.unaskedPermissionMode) ?? (readsOnly ? ClaudePermissionMode.plan : nil) : nil
        }
        if let model = arguments[Key.model]?.stringValue?.trimmingCharacters(in: .whitespaces) {
            choice.model = model.isEmpty ? nil : model
        }
        if let effort = arguments[Key.effort]?.stringValue?.trimmingCharacters(in: .whitespaces) {
            choice.effort = effort.isEmpty ? nil : effort
        }
        if let mode = arguments[Key.permissionMode]?.stringValue?.trimmingCharacters(in: .whitespaces) {
            guard harness == .claudeCode else {
                return .failure(SessionToolError(message: "permissionMode is for Claude Code; a "
                    + "\(harness.displayName) run uses that harness's own default permissions."))
            }
            guard let value = OtherAppScheduleImport.claudePermissionMode(mode) else {
                return .failure(SessionToolError(message: "permissionMode must be one of "
                    + ScheduleToolCatalog.permissionModes.joined(separator: ", ") + "."))
            }
            // A schedule does not do more without asking than the task that makes it may.
            if ClaudePermissionMode.freedom(value) > scheduleModeCeiling(caller) {
                return .failure(SessionToolError(message: "permissionMode \(mode) lets each run do more without "
                    + "asking than this task may; the person can choose it in Scheduled tasks."))
            }
            choice.permissionMode = value
        }
        if harness == .codex, choice.model == nil, choice.effort != nil {
            return .failure(SessionToolError(message: "Codex takes an effort only with its model."))
        }
        let hasChoice = choice.model != nil || choice.effort != nil || choice.permissionMode != nil
        if hasChoice, choice.providerOptions(for: harness).isEmpty {
            return .failure(SessionToolError(
                message: "Yardlet does not choose a model or permission mode for \(harness.displayName) here."))
        }
        destination.modelChoice = hasChoice ? choice : nil
        // New runs nest under the task that made the schedule, as a Claude app schedule reports to the
        // session that made it (`notifySessionId`), unless they are top-level tasks, as a schedule made in
        // Scheduled tasks starts them.
        if let topLevel = Self.bool(arguments[Key.topLevel]) {
            destination.parentTaskID = topLevel ? nil : caller.hostTaskID
        } else if !keepsBase {
            destination.parentTaskID = caller.hostTaskID
        }
        return .success(destination)
    }
}

extension AppModel {
    /// The freest Claude Code mode a schedule the caller makes may run in: a Claude Code task's own
    /// mode, else the mode that matches the caller's permission level (a harness's default edits its
    /// folder as acceptEdits does).
    func scheduleModeCeiling(_ caller: SessionToolCaller) -> Int {
        if caller.id == caller.hostTaskID, caller.harness == .claudeCode,
           let host = store.sessions.first(where: { $0.id == caller.hostTaskID }) {
            return ClaudePermissionMode.freedom(host.providerOptions[ClaudeLaunchOption.permissionMode])
        }
        switch caller.permission {
        case .readOnly: return ClaudePermissionMode.freedom(ClaudePermissionMode.plan)
        case .standard: return ClaudePermissionMode.freedom(ClaudePermissionMode.acceptEdits)
        case .elevated: return ClaudePermissionMode.freedom(ClaudePermissionMode.bypassPermissions)
        }
    }
}

private extension ScheduleTrigger {
    var isOnce: Bool {
        if case .once = self { return true }
        return false
    }
}

/// How the scheduled-task tools spell a trigger for the agent: in English and the Mac's local time,
/// with the cron expression or moment the tools take.
enum ScheduleToolText {
    static func summary(_ trigger: ScheduleTrigger, calendar: Calendar) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func days(_ set: Set<ScheduleWeekday>) -> String {
            set.sorted().map { names[$0.rawValue - 1] }.joined(separator: ", ")
        }
        switch trigger {
        case let .daily(time):
            return "every day at \(time.text)"
        case let .weekly(set, time):
            if set == ScheduleWeekday.weekdays { return "weekdays at \(time.text)" }
            return "every \(days(set)) at \(time.text)"
        case let .interval(hours, _, set):
            let every = hours == 1 ? "every hour" : "every \(hours) hours"
            return set.isEmpty || set == ScheduleWeekday.everyDay ? every : "\(every) on \(days(set))"
        case let .once(moment):
            return "once at \(iso(moment, calendar: calendar))"
        }
    }

    /// The five-field cron expression a repeating trigger is, in local time; nil for a one-off and for
    /// an interval that does not keep to cron's hours.
    static func cronExpression(_ trigger: ScheduleTrigger, calendar: Calendar) -> String? {
        func dayField(_ set: Set<ScheduleWeekday>) -> String {
            set.isEmpty || set == ScheduleWeekday.everyDay
                ? "*" : set.sorted().map { String($0.rawValue - 1) }.joined(separator: ",")
        }
        switch trigger {
        case let .daily(time):
            return "\(time.minute) \(time.hour) * * *"
        case let .weekly(set, time):
            return "\(time.minute) \(time.hour) * * \(dayField(set))"
        case let .interval(hours, anchor, set):
            let parts = calendar.dateComponents([.hour, .minute], from: anchor)
            guard 24 % hours == 0, let hour = parts.hour, let minute = parts.minute, hour % hours == 0 else { return nil }
            return "\(minute) \(hours == 1 ? "*" : "*/\(hours)") * * \(dayField(set))"
        case .once:
            return nil
        }
    }

    static func iso(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    /// An ISO 8601 time; one without an offset is read in the calendar's time zone.
    static func moment(_ text: String, calendar: Calendar) -> Date? {
        let withOffset = ISO8601DateFormatter()
        withOffset.formatOptions = [.withInternetDateTime]
        if let date = withOffset.date(from: text) { return date }
        withOffset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withOffset.date(from: text) { return date }
        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}
