import Foundation
import YardletAgentTools

// Suggested tasks (`spawn_task`, docs/AGENT_BROWSER_TOOLS.md, "Task suggestion tools"): the agent's call is answered here, a chip's
// Start and Do it here act here, and a task started from a chip or its draft is that suggestion's.

extension AppModel: TaskSuggestionToolHandling {
    /// `spawn_task` and `dismiss_task` from `sessionID`'s harness. Neither starts a turn. A place the
    /// agent named (`cwd`, `parent_task_id`) is checked now, so a folder or task that is not there is
    /// the call's error rather than a chip that cannot start.
    func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult {
        let arguments = JSONValue(arguments)
        var place: String?
        if name == TaskSuggestionToolCatalog.spawnTask,
           case let .success(suggestion) = TaskSuggestionToolCall.suggestion(from: arguments) {
            switch await suggestedPlaceCheck(suggestion, caller: sessionID) {
            case let .success(words): place = words
            case let .failure(refusal): return .error(refusal.message)
            }
        }
        return TaskSuggestionToolCall.respond(to: name, arguments: arguments, taskID: sessionID,
                                              store: taskSuggestions, place: place)
    }

    private struct PlaceRefusal: Error {
        let message: String
    }

    /// Whether the place a suggestion names is there: a folder for `cwd` (the Claude app's words), an
    /// open task for `parent_task_id` — not archived, not deleted. Success words where Start starts
    /// the task, for the answer, or nil when the agent named no place.
    private func suggestedPlaceCheck(_ suggestion: TaskSuggestionToolCall.Suggestion,
                                     caller: UUID) async -> Result<String?, PlaceRefusal> {
        if suggestion.startsAsChat { return .success("as a chat with no project, nested under this one") }
        if let cwd = suggestion.cwd {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure(PlaceRefusal(message:
                    "cwd \"\(cwd)\" does not exist or is not a directory. Omit cwd to use the current project."))
            }
            return .success("in \(cwd), nested under this one")
        }
        guard let reference = suggestion.parentTaskReference else { return .success(nil) }
        let id = reference == TaskSuggestionToolCatalog.selfReference ? caller : UUID(uuidString: reference)
        guard let id, id != caller else { return .success(nil) }
        if let parent = store.sessions.first(where: { $0.id == id }) {
            let project = project(for: parent).map { " in \($0.name)" } ?? ""
            return .success("nested under task \(id.uuidString) (\(parent.title))\(project)")
        }
        if store.archivedSessions == nil { try? await store.loadArchivedSessions() }
        if store.archivedSessions?.contains(where: { $0.id == id }) == true {
            return .failure(PlaceRefusal(message: "Task \(reference) is archived, so nothing can start under it. Omit "
                + "parent_task_id to start it under this task, or name an open task from list_tasks."))
        }
        return .failure(PlaceRefusal(message: "No task \(reference). list_tasks gives the task ids; omit "
            + "parent_task_id to start it under this task."))
    }

    /// A chip's Start, or the draft its Options opened, started `startedTask`: the chip reads
    /// "Started" and opens it, and the new task nests under the task that suggested it, or the one
    /// the agent named, as the Claude app nests a session started from a suggestion
    /// (`spawnedFrom.taskId`).
    func recordSuggestedTaskStart(_ origin: NewTaskSuggestionOrigin, startedTask: SessionRecord) async {
        taskSuggestions.markStarted(origin.suggestionID, in: origin.sourceTaskID, startedTaskID: startedTask.id)
        let parent = origin.parentTaskID ?? origin.sourceTaskID
        guard store.sessions.contains(where: { $0.id == parent }) else { return }
        _ = try? await store.linkParents([startedTask.id: parent])
    }

    /// The chip's ✕: the chip leaves the conversation, and stays gone after the app restarts.
    func dismissTaskSuggestion(_ suggestionID: String, in taskID: UUID) {
        taskSuggestions.dismiss(suggestionID, in: taskID)
    }

    /// Where a suggestion from `source` starts (`SuggestedTaskStart`): under the task the agent named,
    /// or `source`, in the place `SuggestedTaskPlace` gives — a new worktree also when the agent left
    /// that to the person and they start that project's tasks in one — or why it cannot start now.
    func suggestedTaskStart(for suggestion: ConversationTaskSuggestion,
                            from source: SessionRecord) -> Result<SuggestedTaskStart, SuggestedTaskStartFailure> {
        var parent = source
        if let id = suggestion.parentTaskID, id != source.id {
            guard let named = store.sessions.first(where: { $0.id == id }) else {
                return .failure(SuggestedTaskStartFailure(message:
                    L10n.string("The task it would start under is no longer open in Yardlet.")))
            }
            parent = named
        }
        let draft = composerDrafts.home
        let place = SuggestedTaskPlace.of(suggestion, from: parent, in: projects.projects,
                                          worktreeByDefault: { draft.startsInNewWorktree(projectID: $0) })
        if let folder = place.folder, suggestion.cwd != nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(SuggestedTaskStartFailure(message:
                    L10n.format("The folder %@ is no longer there.", folder.path(percentEncoded: false))))
            }
        }
        return .success(SuggestedTaskStart(parent: parent, place: place))
    }

    struct SuggestedTaskStartFailure: Error {
        let message: String
    }

    /// The options a suggestion's task starts with on `harness`, nested under `parent`: the
    /// parent's own on its harness (13.25 child tasks), else that harness's defaults at the parent's
    /// permission level in its words (`permissionOptions(for:level:)`).
    func suggestedTaskOptions(harness: HarnessKind, parent: SessionRecord) -> [String: String] {
        harness == parent.harness
            ? Self.inheritedOptions(parent.providerOptions, harness: harness, chosen: [:])
            : Self.permissionOptions(for: harness, level: sessionToolPermission(of: parent))
    }

    /// The account a suggestion's task starts on: the parent's on the parent's harness, else the one
    /// chosen for that harness.
    func suggestedTaskConnection(harness: HarnessKind, parent: SessionRecord) -> ProviderConnection? {
        harness == parent.harness ? parent.connection : connections.selected(for: harness)
    }

    /// What Start starts a suggestion with: the person's choice in the chip's Options, else the
    /// parent's harness, options and account and the start's place.
    func suggestedTaskChoice(for suggestion: ConversationTaskSuggestion, start: SuggestedTaskStart,
                             in sourceID: UUID) -> TaskSuggestionStartChoice {
        taskSuggestions.choice(of: suggestion.id, in: sourceID) ?? TaskSuggestionStartChoice(
            harness: start.parent.harness,
            providerOptions: suggestedTaskOptions(harness: start.parent.harness, parent: start.parent),
            place: start.place,
            connection: suggestedTaskConnection(harness: start.parent.harness, parent: start.parent))
    }

    /// The chip's quiet words for what Start starts with: "Claude Code · Opus High · Bypass permissions",
    /// led by "Local" when the agent asked for a worktree and the folder is not in Git.
    func suggestedTaskSettingsLabel(_ choice: TaskSuggestionStartChoice, for suggestion: ConversationTaskSuggestion) -> String {
        let options = TaskSuggestionStartOptions.sessionOptions(for: choice, catalogs: modelCatalogs)
        let local = suggestion.startsInNewWorktree && choice.place.folder.map { !SuggestedTaskPlace.isInRepository($0) } == true
        return [local ? L10n.string("Local") : nil, TaskSuggestionStartOptions.summary(harness: choice.harness, options: options)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The words a chip leads its summary with when the agent or the person's Options named where
    /// the task starts: "As a subtask of ‘{task}’" for another task, "Starts in {project}" for
    /// another folder. Nil where it starts as it would under the task that suggested it.
    func suggestedTaskPlaceLabel(for suggestion: ConversationTaskSuggestion, start: SuggestedTaskStart,
                                 choice: TaskSuggestionStartChoice? = nil, from source: SessionRecord) -> String? {
        var words: [String] = []
        if start.parent.id != source.id { words.append(L10n.format("As a subtask of ‘%@’", start.parent.title)) }
        let place = choice?.place ?? start.place
        let moved = switch (place.folder, start.place.folder) {
        case let (chosen?, given?): !Project.isSamePath(chosen, given)
        case (nil, nil): false
        default: true
        }
        if suggestion.cwd != nil || suggestion.startsAsChat || moved {
            words.append(place.folder.map { L10n.format("Starts in %@", place.project?.name ?? $0.lastPathComponent) }
                ?? L10n.string("Chat (no project)"))
        }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// Start on a chip, as the Claude app's Start: the task starts now, nested under the task that
    /// suggested it or the one the agent named, in its place (`suggestedTaskStart`; a folder outside
    /// Git starts locally), with that task's harness, model, effort and permission mode and the account
    /// automatic assignment picks, or what the person chose in Options (`suggestedTaskChoice`),
    /// the suggestion's prompt as its first
    /// message and its title as its name. Pressing Start is the person's approval, another project's
    /// folder or task included. The window stays where it is; the chip's row reads "Starting…", then
    /// "Started", which opens the new task. A start that fails says why on the row, and Start tries again.
    func startTaskSuggestion(_ suggestion: ConversationTaskSuggestion, from sourceID: UUID) async {
        guard let source = store.sessions.first(where: { $0.id == sourceID }),
              taskSuggestions.resolution(of: suggestion.id, in: sourceID) == nil,
              taskSuggestions.progress(of: suggestion.id, in: sourceID)?.isUnderWay != true else { return }
        let start: SuggestedTaskStart
        switch suggestedTaskStart(for: suggestion, from: source) {
        case let .success(value): start = value
        case let .failure(failure):
            taskSuggestions.setProgress(.failed(failure.message), of: suggestion.id, in: sourceID)
            return
        }
        let parent = start.parent
        let choice = suggestedTaskChoice(for: suggestion, start: start, in: sourceID)
        let harness = choice.harness, place = choice.place
        guard let runtime = runtimeSelections.selectedURL(for: harness) else {
            taskSuggestions.setProgress(.failed(L10n.format("%@ is not available in Yardlet.", harness.displayName)),
                                        of: suggestion.id, in: sourceID)
            return
        }
        taskSuggestions.setProgress(.starting, of: suggestion.id, in: sourceID)
        // An account the person chose in Options stands; otherwise automatic assignment picks one, as for a
        // child an agent starts.
        var connection = choice.connection
        var assignment: AccountAssignment?
        if taskSuggestions.choice(of: suggestion.id, in: sourceID) == nil,
           case let .success(start) = await assignAccount(
            harness: harness, model: Self.modelOption(choice.providerOptions, harness: harness), requested: nil) {
            connection = start.connection
            assignment = start.assignment
        }
        let submission = NewTaskDraft.Submission(
            originalText: TaskMessage.disarmed(suggestion.prompt), attachments: [], harness: harness, workspaceURL: place.folder,
            projectID: place.project?.id, runtimeURL: runtime, connection: connection, accountAssignment: assignment,
            startsInNewWorktree: place.folder != nil && place.startsInNewWorktree,
            providerOptions: choice.providerOptions,
            suggestion: NewTaskSuggestionOrigin(sourceTaskID: sourceID, suggestionID: suggestion.id,
                                                title: suggestion.title, prompt: suggestion.prompt,
                                                parentTaskID: parent.id == sourceID ? nil : parent.id),
            selectsTask: false, parentTaskID: parent.id)
        let previousError = bootstrapError
        let failure: String?
        do {
            let created = try await createTask(submission)
            failure = created == nil
                ? (bootstrapError != previousError ? bootstrapError : nil) ?? L10n.string("The task could not start.")
                : nil
        } catch {
            failure = error.localizedDescription
        }
        taskSuggestions.setProgress(failure.map { .failed($0) }, of: suggestion.id, in: sourceID)
    }

    /// Do it here on a chip, as the Claude app's: the person's message "Do this task here: “{title}”"
    /// goes to the task that suggested it the way a message from another task goes (a running task
    /// gets it in its turn), and the chip's row reads "Sent to this session".
    func doTaskSuggestionHere(_ suggestion: ConversationTaskSuggestion, in sourceID: UUID) async {
        guard let source = store.sessions.first(where: { $0.id == sourceID }),
              taskSuggestions.resolution(of: suggestion.id, in: sourceID) == nil,
              taskSuggestions.progress(of: suggestion.id, in: sourceID)?.isUnderWay != true else { return }
        taskSuggestions.setProgress(.sending, of: suggestion.id, in: sourceID)
        let message = TaskSuggestionHereMessage.text(for: suggestion)
        switch await deliverMessage(to: source, text: { _ in message }) {
        case .delivered, .steered, .queued, .afterStart:
            taskSuggestions.markSentHere(suggestion.id, in: sourceID)
        case .undelivered:
            taskSuggestions.setProgress(.failed(L10n.string("The message could not be sent.")),
                                        of: suggestion.id, in: sourceID)
        }
    }
}
