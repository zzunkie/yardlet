import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    /// Resolve every ID again on the host, then use the local menu's own operation.
    func performTaskAction(_ taskID: String, action: RemoteTaskAction) async -> RemoteError? {
        guard let model, let id = UUID(uuidString: taskID) else { return RemoteError(.notFound) }
        if action.kind == .unarchive {
            await model.loadArchivedTasks()
            guard let record = model.store.archivedSessions?.first(where: { $0.id == id }),
                  Self.listsArchived(record, model: model) else { return RemoteError(.notFound) }
            await model.unarchive(record)
            return model.store.sessions.contains(where: { $0.id == id }) ? nil : RemoteError(.unavailable)
        }
        guard let session = session(taskID) else { return RemoteError(.notFound) }
        switch action.kind {
        case .chooseAccount:
            let mode = AccountListMode.switchTask(session)
            guard let choice = AccountListProjection.choices(mode, store: model.connections)
                .first(where: { $0.id == action.value }),
                  AccountListProjection.canChoose(choice, mode: mode), let connection = choice.connection else {
                return RemoteError(.notAllowed)
            }
            await model.chooseAccount(connection, for: session)
            guard model.store.sessions.first(where: { $0.id == id })?.connection == connection
                    || model.accountSwitchesAfterTurn[id] == connection else { return RemoteError(.unavailable) }
        case .rename:
            guard let title = action.value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return RemoteError(.badRequest)
            }
            await model.rename(session, to: title)
            return model.store.sessions.first(where: { $0.id == id })?.title == title ? nil : RemoteError(.unavailable)
        case .markUnread:
            await model.store.markUnread(id: id)
        case .move:
            let project = action.value.flatMap(UUID.init(uuidString:)).flatMap { model.projects.project(id: $0) }
            guard action.value == nil || project != nil else { return RemoteError(.notFound) }
            guard await model.moveTask(session, to: project) != nil else { return RemoteError(.notAllowed) }
        case .nest:
            let parent = action.value.flatMap(UUID.init(uuidString:))
            guard action.value == nil || parent != nil else { return RemoteError(.badRequest) }
            if let parent, self.session(parent.uuidString) == nil { return RemoteError(.notFound) }
            await model.nest(id, under: parent)
            guard let updated = model.store.sessions.first(where: { $0.id == id }),
                  updated.parentTaskID == parent, updated.isLineageDetached else { return RemoteError(.notAllowed) }
        case .delete:
            guard action.confirmed else { return RemoteError(.notAllowed) }
            await model.delete(session)
            if model.store.sessions.contains(where: { $0.id == id }) { return RemoteError(.unavailable) }
        case .resume:
            guard !model.isAttached(id), session.status != .running, session.status != .waitingForApproval else {
                return RemoteError(.busy)
            }
            await model.resume(session)
            guard model.isAttached(id) else { return RemoteError(.unavailable) }
        case .unarchive: break
        }
        return nil
    }
}

extension AppModelRemoteBridge {
    func archivedTasks(cursor: String?) async -> Result<RemoteArchivePage, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable)) }
        await model.loadArchivedTasks()
        if model.archivedTaskError != nil { return .failure(RemoteError(.unavailable)) }
        let records = (model.store.archivedSessions ?? []).filter { Self.listsArchived($0, model: model) }
        let start: Int
        if let cursor {
            guard let index = records.firstIndex(where: { $0.id.uuidString == cursor }) else {
                return .failure(RemoteError(.invalidCursor))
            }
            start = index + 1
        } else { start = 0 }
        let page = records.dropFirst(start).prefix(100)
        let tasks = page.map { record in
            RemoteArchivedTask(task: RemoteTaskProjection.task(record.session,
                projectID: model.project(for: record.session)?.id.uuidString,
                detail: nil, isShellBusy: false, isPinned: record.session.isPinned, nestedUnder: nil),
                archivedAt: RemoteJSON.milliseconds(record.archivedAt ?? record.session.updatedAt),
                projectName: model.project(for: record.session)?.name ?? model.projects.displayName(for: record.session.workspaceURL))
        }
        return .success(RemoteArchivePage(tasks: tasks,
            cursor: start + page.count < records.count ? page.last?.id.uuidString : nil))
    }

    /// A task in a project the person hid stays off other devices, archived or not: restoring it would reveal the project.
    static func listsArchived(_ record: ArchivedSessionRecord, model: AppModel) -> Bool {
        model.project(for: record.session)?.isHidden != true
    }
}

extension AppModelRemoteBridge {
    func taskAccounts(taskID: String, refresh: Bool) async -> Result<[RemoteAccount], RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        let modeBeforeRead = AccountListMode.switchTask(session)
        let choices = AccountListProjection.choices(modeBeforeRead, store: model.connections)
        let scope = AccountListProjection.checkScope(modeBeforeRead, choices: choices)
        await RemoteServer.waitAtMost(15) { @MainActor in
            await model.connections.check(defaultsOf: scope.defaults, savedOf: scope.saved,
                connectionIDs: scope.connectionIDs, policy: refresh ? .refresh : .ifStale,
                runtimeSelections: model.runtimeSelections)
        }
        guard let current = self.session(taskID) else { return .failure(RemoteError(.notFound)) }
        let mode = AccountListMode.switchTask(current)
        return .success(AccountListProjection.choices(mode, store: model.connections)
            .map { Self.remoteAccount($0, current: current, mode: mode) })
    }
}

extension AppModelRemoteBridge {
    func openOriginalConversation(taskID: String) async -> Result<String, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard model.canOpenOriginalConversation(in: session) else { return .failure(RemoteError(.notAllowed)) }
        guard let original = await model.openOriginalClaudeConversation(from: session, selectsSession: false) else {
            return .failure(RemoteError(.unavailable))
        }
        return .success(original.id.uuidString)
    }
}

extension AppModelRemoteBridge {
    static func decorateProjectActions(_ snapshot: inout RemoteSnapshot, model: AppModel) {
        for index in snapshot.projects.indices {
            snapshot.projects[index].pinned = UUID(uuidString: snapshot.projects[index].id)
                .flatMap { model.projects.project(id: $0) }?.isPinned
        }
        snapshot.taskActions = true
    }

    static func decorateTaskActions(_ task: inout RemoteTask, session: SessionRecord, model: AppModel) {
        let id = session.id
        task.canReturnToChats = model.projectMoveOptions(for: session, visibleProjects: []).removableFrom != nil
        task.attached = model.isAttached(id)
        task.hasProviderSession = session.providerSessionID != nil
        task.originalConversation = session.harness == .claudeCode && session.inheritedContext?.nativeConversationOrigin != nil
        task.canOpenOriginalConversation = model.canOpenOriginalConversation(in: session)
        task.accountName = session.connection?.name
        if let pr = model.pullRequests.pullRequest(for: id) {
            task.pullRequest = RemoteTaskPullRequest(number: pr.number, url: pr.url.absoluteString,
                repository: pr.repository, state: pr.state?.rawValue, checks: pr.checks?.rawValue, review: pr.review?.rawValue)
        }
    }

    func performProjectAction(_ projectID: String, pinned: Bool?, archive: Bool) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable) }
        guard let group = model.projects.visibleGroups(sessions: model.store.listedSessions)
            .first(where: { RemoteTaskProjection.projectID(for: $0) == projectID }) else { return RemoteError(.notFound) }
        if let pinned {
            guard let project = group.project else { return RemoteError(.notAllowed) }
            if project.isPinned != pinned { model.projects.togglePinned(project.id) }
        } else if archive {
            let outcomes = await model.archive(group.sessions)
            if outcomes.contains(where: { $0.failure != nil }) { return RemoteError(.unavailable, "Some tasks could not be archived") }
        } else { return RemoteError(.badRequest) }
        return nil
    }
}

extension AppModelRemoteBridge {
    static func remoteAccount(_ choice: AccountChoice, current: SessionRecord, mode: AccountListMode) -> RemoteAccount {
        var account = RemoteAccount(id: choice.id, name: choice.title, detail: AccountListProjection.accountLine(choice),
            usage: choice.quotas.map(AccountLimitWindow.init(metric:)).map { window in
                RemoteAccount.Usage(label: window.name, usedPercent: window.remainingPercent.map { Int((100 - $0).rounded()) },
                    resetsAt: window.resetsAt.map(RemoteJSON.milliseconds))
            }, current: choice.connection == current.connection ? true : nil,
            available: AccountListProjection.canChoose(choice, mode: mode) ? true : nil)
        account.state = choice.snapshot.flatMap { RemoteAccount.State(rawValue: $0.state.rawValue) }
        account.checkedAt = choice.snapshot.map { RemoteJSON.milliseconds($0.checkedAt) }
        return account
    }
}
