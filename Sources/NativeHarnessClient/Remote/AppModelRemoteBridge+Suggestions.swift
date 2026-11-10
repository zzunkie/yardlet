import Foundation
import YardletRemote

/// A suggested task's Options from another device (docs/REMOTE_PROTOCOL.md §15.9): what the chip's Start starts with
/// after the client's picks, read as the Mac's Options shows it, and Start with those picks, through the path the
/// Mac's Options and Start take (`TaskSuggestionStartOptions`, `AppModel.startTaskSuggestion`). The picks are checked
/// as `createTask` checks the same choices (§15.16): a choice the Mac asks to confirm starts only with `confirmed`.
extension AppModelRemoteBridge {
    func suggestionOptions(taskID: String, suggestionID: String, harness: String?, settings: [String: String],
                           projectID: String?, accountID: String?, composer: Bool) async -> Result<RemoteNewTaskOptions, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        let found: SuggestionChoice
        switch await suggestionChoice(taskID: taskID, suggestionID: suggestionID, harness: harness, settings: settings,
                                      projectID: projectID, accountID: accountID, worktree: nil, allowsConfirmed: composer,
                                      opening: true, checksAccounts: composer) {
        case let .success(value): found = value
        case let .failure(error): return .failure(error)
        }
        let choice = found.choice
        let options = TaskSuggestionStartOptions.sessionOptions(for: choice, catalogs: model.modelCatalogs)
        let folder = choice.place.folder
        var result = RemoteNewTaskOptions(
            harness: Self.option(choice.harness),
            harnesses: model.runtimeSelections.connectedDescriptors.map { Self.option($0.id) },
            settings: composer ? Self.taskSettings(options) : Self.settings(options),
            worktree: folder.map(SuggestedTaskPlace.isInRepository) == true ? choice.place.startsInNewWorktree : nil)
        if composer {
            // The Mac's Options lists the new-task screen's accounts for the harness by the names its control shows.
            let accounts = model.connections.choices(for: [choice.harness])
            result.accounts = accounts.map { account in
                RemoteAccount(id: account.id, name: account.composerTitle, detail: account.subtitle,
                              current: account.connection?.id == choice.connection?.id ? true : nil,
                              available: account.canSelect ? true : nil)
            }
        }
        if let folder {
            // A listed project, as the sidebar names it; a folder the agent named outside them goes by its name only.
            let groups = model.projects.visibleGroups(sessions: model.store.sessions)
            let group = groups.first { group in
                choice.place.project.map { group.project?.id == $0.id } ?? (group.project == nil && Project.isSamePath(group.workspaceURL, folder))
            }
            result.projectID = group.map(RemoteTaskProjection.projectID(for:))
            result.placeName = choice.place.project?.name ?? group?.project?.name ?? folder.lastPathComponent
        } else {
            result.projectID = RemoteTaskProjection.chatsProjectID
        }
        return .success(result)
    }

    /// Start with the chip's Options: the client's choices become the chip's, as the Mac's Options keeps them for
    /// its Start, and the task starts as that Start starts it. The chip says what became of it (`starting`, `failed`,
    /// `started`).
    func startSuggestion(taskID: String, suggestionID: String, with start: RemoteSuggestionStart) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable, "Yardlet is closing") }
        let found: SuggestionChoice
        switch await suggestionChoice(taskID: taskID, suggestionID: suggestionID, harness: start.harness, settings: start.settings,
                                      projectID: start.projectID, accountID: start.accountID, worktree: start.worktree,
                                      allowsConfirmed: start.confirmed, opening: false, checksAccounts: false) {
        case let .success(value): found = value
        case let .failure(error): return error
        }
        let options = TaskSuggestionStartOptions.sessionOptions(for: found.choice, catalogs: model.modelCatalogs)
        guard start.confirmed || !Self.newTaskRequiresConfirmation(options) else {
            let setting = options.permission?.selector?.id
            return RemoteError(.notAllowed, "\(setting ?? "The permission") is confirmed first", reason: .confirmation, setting: setting)
        }
        model.taskSuggestions.setChoice(found.choice, of: suggestionID, in: found.source.id)
        let suggestion = found.suggestion, source = found.source.id
        Task { await model.startTaskSuggestion(suggestion, from: source) }
        return nil
    }

    struct SuggestionChoice {
        var source: SessionRecord
        var suggestion: ConversationTaskSuggestion
        var choice: TaskSuggestionStartChoice
    }

    /// What the chip's Start starts with after the client's picks, made as the Mac's Options makes them: another
    /// harness takes that harness's options at the task's permission level and its account, another project moves
    /// the place, an account replaces the account, the settings apply as the new-task menus take them, then the
    /// worktree. Without `allowsConfirmed`, a setting that names a choice the Mac asks to confirm is refused, and one
    /// the chip holds from the task it nests under gives way to the harness's default (§15.16). `opening` reads what
    /// opening the Mac's Options reads first: the harness's model list where none is known yet, and with
    /// `checksAccounts` its accounts.
    func suggestionChoice(taskID: String, suggestionID: String, harness named: String?, settings picks: [String: String],
                          projectID: String?, accountID: String?, worktree: Bool?, allowsConfirmed: Bool,
                          opening: Bool, checksAccounts: Bool) async -> Result<SuggestionChoice, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        guard let source = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard let suggestion = suggestion(suggestionID, in: source) else { return .failure(RemoteError(.notFound)) }
        guard model.taskSuggestions.resolution(of: suggestionID, in: source.id) == nil,
              model.taskSuggestions.progress(of: suggestionID, in: source.id)?.isUnderWay != true else {
            return .failure(RemoteError(.notAllowed, "The suggestion was already acted on"))
        }
        let start: SuggestedTaskStart
        switch model.suggestedTaskStart(for: suggestion, from: source) {
        case let .success(value): start = value
        case let .failure(failure): return .failure(RemoteError(.unavailable, failure.message))
        }
        var choice = model.suggestedTaskChoice(for: suggestion, start: start, in: source.id)
        if let named {
            switch Self.harness(named, in: model) {
            case let .success(harness):
                choice = TaskSuggestionStartOptions.choosing(
                    harness: harness, in: choice, options: model.suggestedTaskOptions(harness: harness, parent: start.parent),
                    connection: model.suggestedTaskConnection(harness: harness, parent: start.parent)) ?? choice
            case let .failure(error): return .failure(error)
            }
        }
        if let projectID {
            switch place(projectID, in: model) {
            case let .success(place):
                choice = choice.moving(to: place.folder, project: place.project, isRepository: SuggestedTaskPlace.isInRepository)
            case let .failure(error): return .failure(error)
            }
        }
        if opening, checksAccounts {
            // This starts no sign-in or model turn; concurrent reads join the store's check.
            let harness = choice.harness
            await RemoteServer.waitAtMost(8) { @MainActor in
                await model.connections.checkNewTaskAccounts(for: harness, runtimeSelections: model.runtimeSelections)
            }
        }
        if let accountID {
            guard let account = model.connections.choices(for: [choice.harness]).first(where: { $0.id == accountID && $0.canSelect }) else {
                return .failure(RemoteError(.notAllowed, "The account is unavailable", reason: .account))
            }
            choice.connection = account.connection
        }
        // As opening the Mac's Options does, the harness's model list is read first where none is known yet.
        if opening, let menu = TaskSuggestionStartOptions.sessionOptions(for: choice, catalogs: model.modelCatalogs).model?.menu,
           !menu.canChoose || menu.isEmpty, let runtime = model.runtimeSelections.selectedURL(for: choice.harness) {
            let harness = choice.harness, connection = choice.connection, folder = choice.place.folder
            await RemoteServer.waitAtMost(10) { @MainActor in
                await model.loadNewTaskModels(harness: harness, runtimeURL: runtime, connection: connection, workspaceURL: folder)
            }
        }
        let held = TaskSuggestionStartOptions.modelChoice(from: choice.providerOptions, harness: choice.harness)
        var picked: NewTaskModelChoice?
        switch Self.choosing(picks, harness: choice.harness, from: held, model: model, connection: choice.connection,
                             folder: choice.place.folder, allowsConfirmed: allowsConfirmed) {
        case let .success(value): picked = value
        case let .failure(error): return .failure(error)
        }
        if !allowsConfirmed {
            picked = Self.unconfirmed(picked, harness: choice.harness, model: model, connection: choice.connection,
                                      folder: choice.place.folder)
        }
        if picked != held {
            choice.providerOptions = TaskSuggestionStartOptions.providerOptions(choice.providerOptions, harness: choice.harness,
                                                                                choice: picked)
        }
        if let worktree {
            guard !worktree || choice.place.folder.map(SuggestedTaskPlace.isInRepository) == true else {
                return .failure(RemoteError(.notAllowed, "The folder is not in a Git repository", reason: .worktree))
            }
            choice = choice.startingInNewWorktree(worktree, isRepository: SuggestedTaskPlace.isInRepository)
        }
        return .success(SuggestionChoice(source: source, suggestion: suggestion, choice: choice))
    }
}
