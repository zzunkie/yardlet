import Foundation
import YardletRemote

/// Schedule editing stays on the host's center. The wire definition is a presentation value;
/// identity, history, account and filesystem authority always come from the host (§15.35).
extension AppModelRemoteBridge {
    /// A schedule's wire definition and listed name, and what they were masked from. Masking reads nothing but
    /// its inputs, so a list read can do it off the main actor.
    struct MaskedSchedule: Sendable {
        let schedule: ScheduledTask
        let projectID: UUID?
        let root: URL?
        let definition: Data?
        let name: String

        init(_ schedule: ScheduledTask, projectID: UUID?, root: URL?) {
            self.schedule = schedule
            self.projectID = projectID
            self.root = root
            definition = AppModelRemoteBridge.scheduleDefinition(schedule, projectID: projectID, root: root)
            name = AppModelRemoteBridge.scheduleText(RemoteText.capped(schedule.name, RemoteText.titleLimit).text, root: root)
        }

        func masks(_ schedule: ScheduledTask, projectID: UUID?, root: URL?) -> Bool {
            self.schedule == schedule && self.projectID == projectID && self.root == root
        }
    }

    /// `projectID` and `root` are the schedule's `sharedProjectID` and `sharedRoot`.
    nonisolated static func scheduleDefinition(_ schedule: ScheduledTask, projectID: UUID?, root: URL?) -> Data? {
        var copy = schedule
        copy.origin = nil
        copy.name = Self.scheduleText(copy.name, root: root)
        copy.prompt = Self.scheduleText(copy.prompt, root: root)
        copy.destination.accountID = nil
        // A project travels by ID; the host folder itself never does (§15.35).
        copy.destination.projectID = projectID
        copy.destination.workspacePath = schedule.destination.workspacePath == nil ? nil : hostFolder
        for index in copy.state.runs.indices {
            if let account = copy.state.runs[index].account {
                // Keep the history's explanation without exporting routing identifiers or usage data.
                func displayAccount(_ name: String) -> AccountChoice {
                    AccountChoice(harness: schedule.destination.harness, connection: nil, snapshot: nil,
                                  knownLabel: Self.scheduleText(name, root: root))
                }
                copy.state.runs[index].account = AccountAssignment(
                    choice: displayAccount(account.accountName), origin: account.origin,
                    replacing: account.replacedAccountName.map(displayAccount), at: account.assignedAt)
            }
            copy.state.runs[index].failure = copy.state.runs[index].failure.map { Self.scheduleText($0, root: root) }
        }
        return try? JSONEncoder().encode(copy)
    }

    func sessionSchedules() async -> [RemoteSessionSchedule] {
        guard let model else { return [] }
        let listed = Set(model.sidebarSessions.map(\.id))
        return model.scheduledSessionJobs.compactMap { item in
            // Only the tasks this device can see; paths stay visible only inside the task's listed project.
            guard listed.contains(item.session.id) else { return nil }
            let root = model.project(for: item.session)?.primaryRoot
            let original = item.job
            let job = ClaudeSessionJob(id: original.id, kind: original.kind, cron: original.cron,
                schedule: original.schedule.map { Self.scheduleText($0, root: root) },
                prompt: Self.scheduleText(original.prompt, root: root),
                createdAt: original.createdAt, reportedRun: original.reportedRun)
            guard let data = try? JSONEncoder().encode(job) else { return nil }
            return RemoteSessionSchedule(taskId: item.session.id.uuidString, job: data)
        }
    }

    /// What a schedule's unregistered or hidden folder is called on the wire.
    nonisolated static let hostFolder = "yardlet-host-folder"

    /// The project other devices see a schedule start in: none when the host hides it or it is gone,
    /// so the schedule reads like one in an unregistered folder and keeps its place when saved back.
    static func sharedProjectID(_ destination: ScheduleDestination, model: AppModel) -> UUID? {
        model.projects.project(id: destination.projectID).flatMap { $0.isHidden ? nil : $0.id }
    }

    /// The folder whose paths a schedule's text may show: its project's, when other devices see that project.
    static func sharedRoot(_ destination: ScheduleDestination, model: AppModel) -> URL? {
        sharedProjectID(destination, model: model).flatMap { model.projects.project(id: $0)?.primaryRoot }
    }

    /// Secrets and absolute paths outside the schedule's project are presentation-only masks.
    /// Unchanged masked instructions are resolved back to the host's original on save.
    nonisolated static func scheduleText(_ text: String, root: URL?) -> String {
        var result = RemoteSummary.masked(text)
        for match in absolutePath.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let path = String(result[range])
            if let root, PathRules.current.isInside(URL(filePath: path).standardizedFileURL, folder: root.standardizedFileURL) {
                continue
            }
            result.replaceSubrange(range, with: "•••")
        }
        return result
    }

    nonisolated private static let absolutePath = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9:/])(?:/|~/)[^\s\"'<>]+"#)

    /// The same selectors as a new task, including the permission choices the local menu confirms.
    static func scheduleSettings(_ options: ComposerSessionOptions) -> [RemoteSetting] {
        var result = settings(options)
        for index in result.indices {
            result[index].role = result[index].id == options.model?.menu.model?.id ? "model" : "effort"
        }
        if let permission = options.permission, let selector = permission.selector {
            var setting = RemoteSetting(id: selector.id, name: selector.name, value: selector.currentValue,
                choices: selector.choices.map { choice in
                    RemoteSetting.Choice(value: choice.value, name: choice.name, description: choice.description,
                        confirm: permission.confirmations[choice.value].map {
                            .init(title: $0.title, message: $0.message, button: $0.confirm)
                        })
                })
            setting.role = "permission"
            setting.elevated = permission.confirmations[selector.currentValue] != nil ? true : nil
            result.removeAll { $0.id == selector.id }
            result.append(setting)
        }
        return result
    }

    static func choosingSchedule(_ picks: [String: String], harness: HarnessKind, from start: NewTaskModelChoice?,
                                 model: AppModel, connection: ProviderConnection?, folder: URL?) -> Result<NewTaskModelChoice?, RemoteError> {
        guard picks.count <= 16, picks.allSatisfy({ $0.key.utf8.count <= 100 && $0.value.utf8.count <= 1_000 }) else {
            return .failure(RemoteError(.badRequest))
        }
        var choice = start
        var remaining = picks
        while !remaining.isEmpty {
            let offered = scheduleSettings(ComposerSessionOptionsProjection.newTask(
                harness: harness, choice: choice, catalogs: model.modelCatalogs, connection: connection, workspaceURL: folder))
            guard let setting = offered.first(where: { remaining[$0.id] != nil }),
                  let value = remaining.removeValue(forKey: setting.id), setting.choices.contains(where: { $0.value == value }),
                  let selected = NewTaskModelProjection.choosing(setting.id, value: value, harness: harness, choice: choice,
                      catalogs: model.modelCatalogs, connection: connection, workspaceURL: folder) else {
                return .failure(RemoteError(.notAllowed, "The Mac does not offer that choice now"))
            }
            choice = selected
        }
        return .success(choice)
    }

    /// A schedule pinned to the native login or a removed account does not inherit another account.
    static func scheduleConnection(accountID: String?, harness: HarnessKind, connections: ProviderConnectionStore) -> ProviderConnection? {
        guard let accountID else { return connections.selected(for: harness) }
        guard accountID != AccountChoice.nativeID(for: harness) else { return nil }
        return connections.connections(for: harness).first { $0.id == accountID }
    }

    func scheduledTaskOptions(projectID: String?, harness named: String?, settings picked: [String: String], scheduleID: String? = nil, accountID requestedAccountID: String? = nil) async
        -> Result<RemoteNewTaskOptions, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }
        do {
            let place = try place(projectID ?? RemoteTaskProjection.chatsProjectID, in: model).get()
            let existing: ScheduledTask?
            if let scheduleID {
                guard let id = UUID(uuidString: scheduleID), let schedule = model.scheduledTasks.schedule(id: id) else {
                    return .failure(RemoteError(.notFound))
                }
                existing = schedule
            } else { existing = nil }
            let harness: HarnessKind
            if let existing, named == nil || named == existing.destination.harness.rawValue {
                harness = existing.destination.harness
            } else { harness = try Self.harness(named, in: model).get() }
            let sameHarness = existing?.destination.harness == harness
            let accounts = model.connections.choices(for: [harness]).filter(\.canSelect)
            if let requestedAccountID, !accounts.contains(where: { $0.id == requestedAccountID }) {
                return .failure(RemoteError(.notAllowed, "The Mac does not offer that account now"))
            }
            let savedAccountID = sameHarness ? existing?.destination.accountID : nil
            let accountID = requestedAccountID ?? savedAccountID
            let defaultAccountID = model.connections.selection[harness] ?? AccountChoice.nativeID(for: harness)
            let changedAccount = requestedAccountID.map { $0 != (savedAccountID ?? defaultAccountID) } ?? false
            let connection = Self.scheduleConnection(accountID: accountID, harness: harness, connections: model.connections)
            let samePlace = existing.map { (Self.sharedProjectID($0.destination, model: model)?.uuidString
                ?? RemoteTaskProjection.chatsProjectID) == (projectID ?? RemoteTaskProjection.chatsProjectID) } ?? false
            let folder = samePlace ? existing?.destination.workspaceURL ?? place.folder : place.folder
            let baseline = changedAccount ? nil : (sameHarness ? existing?.destination.modelChoice : model.composerDrafts.home.modelChoices[harness])
            // Opening the host's own new-task menu loads its model catalog without starting a turn.
            let initial = ComposerSessionOptionsProjection.newTask(harness: harness, choice: baseline,
                catalogs: model.modelCatalogs, connection: connection, workspaceURL: folder)
            if initial.model?.menu.canChoose == false, let runtime = model.runtimeSelections.selectedURL(for: harness) {
                await RemoteServer.waitAtMost(10) { @MainActor in
                    await model.loadNewTaskModels(harness: harness, runtimeURL: runtime, connection: connection, workspaceURL: folder)
                }
            }
            let choice = try Self.choosingSchedule(picked, harness: harness, from: baseline,
                model: model, connection: connection, folder: folder).get()
            let options = ComposerSessionOptionsProjection.newTask(harness: harness, choice: choice, catalogs: model.modelCatalogs,
                connection: connection, workspaceURL: folder)
            let worktree: Bool? = folder.map(SuggestedTaskPlace.isInRepository) == true
                ? (samePlace ? existing?.destination.startsInNewWorktree
                    : model.composerDrafts.home.startsInNewWorktree(projectID: place.project?.id)) : nil
            var result = RemoteNewTaskOptions(harness: Self.option(harness),
                harnesses: model.runtimeSelections.connectedDescriptors.map { Self.option($0.id) },
                settings: Self.scheduleSettings(options), worktree: worktree)
            let account = accountID ?? model.connections.selection[harness] ?? AccountChoice.nativeID(for: harness)
            result.scheduleAccountName = model.connections.choices(for: [harness], includingMoving: true)
                .first { $0.id == account }.map { Self.scheduleText($0.title, root: nil) }
            result.scheduleAccountID = account
            result.scheduleAccounts = accounts.map { RemoteAccount(id: $0.id, name: Self.scheduleText($0.title, root: nil),
                current: $0.id == account ? true : nil, available: true) }
            return .success(result)
        } catch { return .failure(error) }
    }

    func saveScheduledTask(scheduleID: String?, definition: Data, settings: [String: String], confirmed: Bool) async
        -> Result<String, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }
        let center = model.scheduledTasks
        guard definition.count <= 256_000, let supplied = try? JSONDecoder().decode(ScheduledTask.self, from: definition),
              !supplied.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              supplied.prompt.utf8.count <= 200_000, supplied.name.utf8.count <= 1_200, supplied.trigger.isValid else {
            return .failure(RemoteError(.badRequest))
        }
        let existing: ScheduledTask?
        if let scheduleID {
            guard let id = UUID(uuidString: scheduleID), let found = center.schedule(id: id) else { return .failure(RemoteError(.notFound)) }
            existing = found
        } else { existing = nil }
        if case let .once(time) = supplied.trigger, time <= center.now() {
            return .failure(RemoteError(.notAllowed, "Choose a time that has not passed"))
        }
        var destination = ScheduleDestination(mode: supplied.destination.mode, harness: supplied.destination.harness)
        do {
            switch destination.mode {
            case .continueTask:
                guard let id = supplied.destination.targetTaskID,
                      let task = model.sidebarSessions.first(where: { $0.id == id }) else { return .failure(RemoteError(.notFound)) }
                destination.targetTaskID = id
                destination.harness = task.harness
            case .newTask:
                let harness: HarnessKind
                if existing?.destination.harness == destination.harness {
                    harness = destination.harness
                } else { harness = try Self.harness(destination.harness.rawValue, in: model).get() }
                let projectID = supplied.destination.projectID?.uuidString ?? RemoteTaskProjection.chatsProjectID
                let place = try place(projectID, in: model).get()
                destination.projectID = place.project?.id
                destination.workspacePath = place.folder?.path(percentEncoded: false)
                // Unregistered, hidden or removed projects' folders stay on the host, including edits to their instructions.
                if let existing, Self.sharedProjectID(existing.destination, model: model) == supplied.destination.projectID,
                   supplied.destination.projectID != nil || supplied.destination.workspacePath == Self.hostFolder {
                    destination.projectID = existing.destination.projectID
                    destination.workspacePath = existing.destination.workspacePath
                }
                let savedAccountID = existing?.destination.harness == harness ? existing?.destination.accountID : nil
                let defaultAccountID = model.connections.selection[harness] ?? AccountChoice.nativeID(for: harness)
                let requestedAccountID = supplied.destination.accountID
                if let requestedAccountID, !model.connections.choices(for: [harness]).contains(where: { $0.id == requestedAccountID && $0.canSelect }) {
                    return .failure(RemoteError(.notAllowed, "The Mac does not offer that account now"))
                }
                destination.accountID = requestedAccountID ?? savedAccountID ?? (existing?.destination.harness == harness ? nil : model.connections.selection[harness])
                let changedAccount = requestedAccountID.map { $0 != (savedAccountID ?? defaultAccountID) } ?? false
                let connection = Self.scheduleConnection(accountID: destination.accountID, harness: harness, connections: model.connections)
                let folder = destination.workspaceURL
                let baseline = changedAccount ? nil : (existing?.destination.harness == harness ? existing?.destination.modelChoice : model.composerDrafts.home.modelChoices[harness])
                destination.modelChoice = try Self.choosingSchedule(settings, harness: harness, from: baseline,
                    model: model, connection: connection, folder: folder).get()
                let options = ComposerSessionOptionsProjection.newTask(harness: harness, choice: destination.modelChoice,
                    catalogs: model.modelCatalogs, connection: connection, workspaceURL: folder)
                if !confirmed, Self.newTaskRequiresConfirmation(options) {
                    return .failure(RemoteError(.notAllowed, "Confirm the unattended schedule's permissions",
                                                reason: .confirmation, setting: options.permission?.selector?.id))
                }
                guard !supplied.destination.startsInNewWorktree || folder.map(SuggestedTaskPlace.isInRepository) == true else {
                    return .failure(RemoteError(.notAllowed, "The project is not in a Git repository", reason: .worktree))
                }
                destination.startsInNewWorktree = supplied.destination.startsInNewWorktree
                destination.parentTaskID = existing?.destination.parentTaskID
            }
            var schedule = existing ?? ScheduledTask(name: supplied.name, prompt: supplied.prompt,
                trigger: supplied.trigger, destination: destination, createdAt: center.now())
            let root = existing.flatMap { Self.sharedRoot($0.destination, model: model) }
            schedule.name = existing.map { supplied.name == Self.scheduleText($0.name, root: root) ? $0.name : supplied.name } ?? supplied.name
            let prompt = existing.map { supplied.prompt == Self.scheduleText($0.prompt, root: root) ? $0.prompt : supplied.prompt } ?? supplied.prompt
            if schedule.prompt != prompt { schedule.agentTaskID = nil }
            schedule.prompt = prompt
            schedule.trigger = supplied.trigger
            schedule.destination = destination
            if existing == nil { center.create(schedule) } else { center.update(schedule) }
            return .success(schedule.id.uuidString)
        } catch { return .failure(error) }
    }

    /// Whether the schedule starts its task in a permission the Mac asks to confirm (Bypass permissions, Full access), read
    /// as saving it checks; a schedule that continues a task runs in that task's.
    static func startsElevated(_ schedule: ScheduledTask, in model: AppModel) -> Bool {
        let destination = schedule.destination
        guard destination.mode == .newTask else { return false }
        let connection = scheduleConnection(accountID: destination.accountID, harness: destination.harness,
                                            connections: model.connections)
        return newTaskRequiresConfirmation(ComposerSessionOptionsProjection.newTask(
            harness: destination.harness, choice: destination.modelChoice, catalogs: model.modelCatalogs,
            connection: connection, workspaceURL: destination.workspaceURL))
    }

    func deleteScheduledTasks(scheduleIDs: [String], completedOnly: Bool, confirmed: Bool) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable) }
        guard confirmed else { return RemoteError(.notAllowed, "Confirm deleting the schedules") }
        guard !scheduleIDs.isEmpty, scheduleIDs.count <= RemoteProtocol.maxSchedules else { return RemoteError(.badRequest) }
        let ids = scheduleIDs.compactMap(UUID.init(uuidString:))
        guard ids.count == scheduleIDs.count else { return RemoteError(.badRequest) }
        let center = model.scheduledTasks
        if !completedOnly, ids.contains(where: { center.schedule(id: $0) == nil }) { return RemoteError(.notFound) }
        center.delete(Set(ids.filter { id in
            !completedOnly || center.schedule(id: id).map(ScheduleListSections.section(of:)) == .finished
        }))
        return nil
    }
}
