import Foundation

/// How a schedule's run starts. A new-task run is the new-task screen's start
/// (`createTask`) with the schedule's prompt and choices — harness, account, model and effort,
/// permission mode, folder, project, local or new worktree — so its status dots, notifications,
/// the phone remote and resuming after a restart are those of any task. A continuing run is the
/// task's next message, the way auto-fix's message goes (`deliverAutoFix`). Nothing here wakes a
/// task that is busy: the center skips the slot instead. A run whose account is nearly spent goes to
/// the one automatic assignment picks instead (`accountReplacing`): a new task starts there, and a
/// continued task first moves there as Continue with another account moves it.
extension AppModel {
    /// Gives the center its start and busy checks. The loop itself starts with the app.
    func wireScheduledTasks() {
        scheduledTasks.start = { [weak self] schedule, trigger, slot in
            guard let self else { return .failed(L10n.string("Yardlet is closing.")) }
            return await self.startScheduledRun(schedule, trigger: trigger, slot: slot)
        }
        scheduledTasks.busyReason = { [weak self] schedule in self?.scheduledRunBusyReason(schedule) }
    }

    /// Starts running schedules, after the index is restored.
    func startScheduledTasks() {
        guard !usesVisualFixture else { return }
        scheduledTasks.startLoop()
    }

    /// Why the schedule may not run now: the task its previous run started is still working or
    /// waiting on the person, or the task it continues is busy.
    func scheduledRunBusyReason(_ schedule: ScheduledTask) -> ScheduledTaskRun.SkipReason? {
        switch schedule.destination.mode {
        case .continueTask:
            guard let id = schedule.destination.targetTaskID, store.sessions.contains(where: { $0.id == id }) else {
                return nil
            }
            return canTakeAutoFix(id) && followUps.queue(for: id).isEmpty ? nil : .targetBusy
        case .newTask:
            guard let taskID = schedule.latestStartedRun?.taskID,
                  let task = store.sessions.first(where: { $0.id == taskID }) else { return nil }
            return Self.isWorking(task) ? .previousRunActive : nil
        }
    }

    func startScheduledRun(_ schedule: ScheduledTask, trigger: ScheduledTaskRun.Trigger,
                           slot: Date?) async -> ScheduleStartResult {
        let result: ScheduleStartResult
        switch schedule.destination.mode {
        case .continueTask:
            guard let id = schedule.destination.targetTaskID, let target = store.sessions.first(where: { $0.id == id }) else {
                return .failed(L10n.string("The task this schedule continues is no longer in Yardlet."))
            }
            let previousError = errorBySessionID[id]
            let account = await moveToAccountWithRoom(target)
            let text = schedule.runText(sender: scheduleSenderName(schedule),
                                        relation: TaskMessage.relation(of: schedule.agentTaskID?.uuidString ?? "", to: target))
            guard await deliverAutoFix(text, to: id) else {
                let error = errorBySessionID[id]
                return .failed(error != previousError ? error ?? "" : L10n.string("The message could not be sent."))
            }
            result = .started(taskID: id, account: account)
        case .newTask:
            var submission: NewTaskDraft.Submission
            switch scheduledSubmission(for: schedule, at: slot ?? scheduledTasks.now()) {
            case let .success(value): submission = value
            case let .failure(failure): return .failed(failure.message)
            }
            let harness = submission.harness
            let account = await accountReplacing(
                submission.connection, harness: harness,
                model: Self.modelOption(submission.providerOptions, harness: harness)) {
                automaticAssignmentCandidates(harness: harness).map(\.choice)
            }
            if let account { submission.connection = account.connection }
            let previousError = bootstrapError
            do {
                guard let created = try await createTask(submission) else {
                    let error = bootstrapError != previousError ? bootstrapError : nil
                    return .failed(error ?? L10n.string("The task could not start."))
                }
                if let account { accountAssignments.record(account.assignment, for: created.id) }
                result = .started(taskID: created.id, account: account?.assignment)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if trigger == .missed, let slot, case let .started(taskID, _) = result {
            await announceMissedRun(of: schedule, slot: slot, taskID: taskID)
        }
        return result
    }

    struct ScheduleStartFailure: Error, Equatable {
        let message: String
    }

    /// The new-task start a schedule's run makes, with the schedule's own choices, or why it cannot.
    func scheduledSubmission(for schedule: ScheduledTask, at date: Date) -> Result<NewTaskDraft.Submission, ScheduleStartFailure> {
        let destination = schedule.destination
        let harness = destination.harness
        guard let runtimeURL = runtimeSelections.selectedURL(for: harness) else {
            return .failure(.init(message: L10n.format("%@ is not available in Yardlet.", harness.displayName)))
        }
        let connection: ProviderConnection?
        switch destination.accountID {
        case nil:
            connection = connections.selected(for: harness)
        case AccountChoice.nativeID(for: harness)?:
            connection = nil
        case let id?:
            guard let saved = connections.connections(for: harness).first(where: { $0.id == id }) else {
                return .failure(.init(message: L10n.string("The schedule's account is no longer in Yardlet.")))
            }
            connection = saved
        }
        var folder: URL?
        if let path = destination.workspacePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(.init(message: L10n.format("The folder %@ is no longer there.", path)))
            }
            folder = URL(filePath: path, directoryHint: .isDirectory)
        }
        let projectID = folder == nil ? nil : projects.project(id: destination.projectID)?.id
        let parent = destination.parentTaskID.flatMap { id in store.sessions.contains { $0.id == id } ? id : nil }
        let text = schedule.runText(sender: scheduleSenderName(schedule),
                                    relation: parent != nil && parent == schedule.agentTaskID ? .parent : .task)
        return .success(NewTaskDraft.Submission(
            originalText: text, attachments: [], harness: harness, workspaceURL: folder,
            projectID: projectID, runtimeURL: runtimeURL, connection: connection,
            startsInNewWorktree: folder != nil && destination.startsInNewWorktree,
            providerOptions: destination.modelChoice?.providerOptions(for: harness) ?? [:],
            titleOverride: ScheduleText.runTitle(schedule.name, at: date),
            selectsTask: false, parentTaskID: parent))
    }

    /// Moves an idle task whose account is nearly spent to the account `accountReplacing` picks among the
    /// ones it may go on under (`TaskAccountSwitch`, as Continue with another account offers) that
    /// automatic assignment may use and that are signed in, and says why when it moved. With none, or
    /// when the move is refused, the task stays where it was and its message goes there, as before
    /// (sending clears the refusal's error).
    private func moveToAccountWithRoom(_ task: SessionRecord) async -> AccountAssignment? {
        let account = await accountReplacing(
            task.connection, harness: task.harness, model: Self.modelOption(task.providerOptions, harness: task.harness)) {
            usageLimitAccounts(for: task).map { accountChoice(harness: task.harness, connection: $0) }.filter {
                $0.canSelect && $0.snapshot?.state == .signedIn && connections.isInAutomaticAssignment($0)
            }
        }
        guard let account, let connection = account.connection else { return nil }
        await switchAccount(to: connection, for: task)
        guard store.sessions.first(where: { $0.id == task.id })?.connection == connection else { return nil }
        accountAssignments.record(account.assignment, for: task.id)
        return account.assignment
    }

    /// The name an agent's schedule sends its runs under: its task's title, while the task is here.
    private func scheduleSenderName(_ schedule: ScheduledTask) -> String? {
        schedule.agentTaskID.flatMap { id in store.sessions.first { $0.id == id }?.title }
    }

    /// The Claude app's notice for a run that comes late: "Scheduled task “{name}” missed at
    /// {time}. Running now." It leads to the run's task.
    private func announceMissedRun(of schedule: ScheduledTask, slot: Date, taskID: UUID) async {
        guard (await systemNotificationCenter.authorization()).isDeliverable else { return }
        await systemNotificationCenter.post(SystemNotification(
            title: L10n.string("Scheduled task"),
            body: L10n.format("Scheduled task “%@” missed at %@. Running now.", schedule.name,
                              ScheduleText.moment(slot, relativeTo: scheduledTasks.now())),
            identifier: "yardlet-schedule-\(schedule.id.uuidString)-\(Int(slot.timeIntervalSince1970))",
            target: SystemNotificationTarget(sessionID: taskID)))
    }
}
