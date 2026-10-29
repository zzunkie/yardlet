import Foundation
import Observation
import YardletRemote

/// The phone remote's view of the app model: it reads the sidebar's tasks and a task's conversation
/// the way the window does, and carries out a phone's command through the same model calls the
/// window's controls make — the composer's send, the request card's answer, the stop button and
/// opening a task's read state. It runs on the main actor; the server calls it from its own.
///
/// Reads are cached until Observation says what they read changed, then the server is told
/// (`RemoteBridgeChange`) and reads again when it needs to, so a task streaming in the background
/// costs nothing until a phone follows it.
@MainActor
final class AppModelRemoteBridge: RemoteBridge {
    private weak var model: AppModel?
    private var changeHandler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var cachedSnapshot: RemoteSnapshot?
    private var cachedConversations: [UUID: RemoteConversation] = [:]
    private var projectionCaches: [UUID: ConversationProjectionCache] = [:]
    private var turnMemos: [UUID: [String: (turn: ConversationTurn, remote: RemoteTurn)]] = [:]
    private var watched: Set<UUID> = []

    init(model: AppModel) {
        self.model = model
    }

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) {
        changeHandler = handler
    }

    // MARK: - Reading

    func snapshot() -> RemoteSnapshot {
        guard let model else { return .empty }
        var snapshot = cachedSnapshot ?? withObservationTracking {
            Self.snapshot(of: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.tasksChanged() }
        }
        cachedSnapshot = snapshot
        // A setting, which Observation does not see change: read each time.
        snapshot.followUp = model.followUpMode == .steer ? .steer : .queue
        return snapshot
    }

    static func snapshot(of model: AppModel) -> RemoteSnapshot {
        let sessions = model.store.sessions
        var snapshot = RemoteTaskProjection.snapshot(
            groups: model.projects.visibleGroups(sessions: sessions),
            chats: model.projects.chats(sessions: sessions),
            pinnedIDs: model.pinnedSidebarSessionIDs,
            details: model.taskAttentionDetails,
            shellBusy: model.shellBusySessionIDs,
            newestRequestID: { model.newestPendingApproval(in: $0)?.id },
            requestSummary: { requestSummary(of: $0, in: model) }
        )
        snapshot.newTask = newTaskHarness(in: model).map { RemoteNewTask(harness: $0.rawValue, harnessName: $0.displayName) }
        let listed = Dictionary(model.sidebarSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in snapshot.tasks.indices {
            guard let id = UUID(uuidString: snapshot.tasks[index].id), let session = listed[id] else { continue }
            if acceptsImages(session, in: model) { snapshot.tasks[index].acceptsImages = true }
            if inputPolicy(session, in: model).showsMentionControl { snapshot.tasks[index].acceptsFiles = true }
            if FollowUpPolicy(harness: session.harness)?.steers == true { snapshot.tasks[index].steers = true }
            // A tab handed to the person is a wait on the phone (§15.18); the Mac shows it in the panel's bar.
            if snapshot.tasks[index].attention != .waiting, let wait = model.browserHandoffWaits[id]?.last {
                let summary = RemoteSummary.line([model.browserHandoffSite(wait, in: id), wait.reason])
                snapshot.tasks[index].attention = .waiting
                snapshot.tasks[index].pendingRequest = .input
                snapshot.tasks[index].indicator = .needsInput
                snapshot.tasks[index].pendingKind = "browserHandoff"
                snapshot.tasks[index].pendingSummary = summary
                snapshot.newestRequestIDs[snapshot.tasks[index].id] = wait.notice
                snapshot.requestSummaries[snapshot.tasks[index].id] = summary
            }
        }
        return snapshot
    }

    /// A message to the task can carry images: the task composer's own rule for its harness and session.
    static func acceptsImages(_ session: SessionRecord, in model: AppModel) -> Bool {
        inputPolicy(session, in: model).carriesImages
    }

    /// What the task's composer takes: images where its harness carries them, other files as references to
    /// their paths where it has the `@` picker (§15.20).
    static func inputPolicy(_ session: SessionRecord, in model: AppModel) -> HarnessComposerInputPolicy {
        HarnessComposerInputPolicy(harness: session.harness,
                                   negotiatedImageInput: model.providerCapabilitiesBySessionID[session.id]?.acceptsImageInput)
    }

    /// The files a phone sent as the composer takes dropped ones (`ComposerAttachmentIntake`): an image as an
    /// attachment, anything else as a reference to its path. Nil when the harness takes one of them in neither way.
    static func inputs(for files: [RemoteFile], policy: HarnessComposerInputPolicy) -> [CodexUserInput]? {
        guard !files.isEmpty else { return [] }
        let intake = ComposerAttachmentIntake.inputs(forFiles: files.map(\.url), policy: policy, isDirectory: { _ in false })
        return intake.notice == nil && intake.inputs.count == files.count ? intake.inputs : nil
    }

    /// The harness the Mac's new-task composer starts on now, when it can start one.
    static func newTaskHarness(in model: AppModel) -> HarnessKind? {
        guard let harness = model.composerDrafts.home.harness, model.runtimeSelections.selectedURL(for: harness) != nil else {
            return nil
        }
        return harness
    }

    /// The summary and kind of the newest request a task waits on, read from the request itself.
    static func requestSummary(of session: SessionRecord, in model: AppModel) -> (summary: String?, kind: String)? {
        guard let requestID = model.newestPendingApproval(in: session)?.id else { return nil }
        if let request = model.heldRequests(in: session.id).first(where: { $0.id == requestID }) {
            return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
        }
        if let state = model.codexPresentationBySessionID[session.id]?.serverRequestsByID[requestID] {
            let request = CodexRequestResponseProjection.request(state)
            return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
        }
        for entry in (model.transcriptBySessionID[session.id] ?? []).reversed() {
            if case let .permission(request, .pending) = entry.content, request.id == requestID {
                return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
            }
        }
        return nil
    }

    func conversation(of taskID: String) -> RemoteConversation? {
        guard let model, let id = UUID(uuidString: taskID) else { return nil }
        if let cached = cachedConversations[id] { return cached }
        let conversation: RemoteConversation? = withObservationTracking {
            listedSession(id).map { self.conversation(of: $0, in: model) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.conversationChanged(id) }
        }
        if let conversation { cachedConversations[id] = conversation }
        return conversation
    }

    /// The conversation the task's `ConversationTimeline` draws: the Codex thread once it has turns,
    /// else the shared transcript, with the earlier history the provider still holds and a provider
    /// retry on the running turn's status line, as the timeline adds them.
    private func conversation(of session: SessionRecord, in model: AppModel) -> RemoteConversation {
        let cache = projectionCaches[session.id] ?? ConversationProjectionCache()
        projectionCaches[session.id] = cache
        var presentation: ConversationPresentation
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           let state = model.codexPresentationBySessionID[session.id], state.thread?.turns.isEmpty == false {
            presentation = cache.codex(state, workspaceURL: session.workspaceURL, historySelection: nil)
        } else {
            presentation = cache.transcript(
                model.transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
                latestTurnIsComplete: session.completionState == .completed)
            if model.hasEarlierClaudeHistory(session) { presentation.earlier = .providerFile }
        }
        if let retry = model.providerRetryBySessionID[session.id], let last = presentation.turns.indices.last,
           presentation.turns[last].status == .running {
            presentation.turns[last].progress = .reconnecting(ProviderNoticeText.retry(retry))
        }
        // What Yardlet holds in the task, as the Mac's timeline draws it.
        presentation.appendHeldRequests(model.heldRequests(in: session.id))
        var memos = turnMemos[session.id] ?? [:]
        var kept: [String: (turn: ConversationTurn, remote: RemoteTurn)] = [:]
        let conversation = RemoteConversationProjection.conversation(presentation, workspaceURL: session.workspaceURL) { turn in
            if let memo = memos[turn.id], memo.turn == turn {
                kept[turn.id] = memo
                return memo.remote
            }
            let remote = RemoteConversationProjection.turn(turn, harness: presentation.harness, workspaceURL: session.workspaceURL)
            kept[turn.id] = (turn, remote)
            return remote
        }
        memos = kept
        turnMemos[session.id] = memos
        var result = RemoteConversationProjection.queued(model.followUps.queue(for: session.id),
                                                         policy: FollowUpPolicy(harness: session.harness), into: conversation)
        for wait in model.browserHandoffWaits[session.id] ?? [] {
            result = RemoteConversationProjection.handoff(wait, site: model.browserHandoffSite(wait, in: session.id), into: result)
        }
        return withLimitActions(withSuggestionStates(result, of: session, in: model), presentation: presentation, of: session,
                                in: model)
    }

    /// The latest limit card's actions while the task can act on it (§15.17), as the Mac's card
    /// offers them: another account that shares its history, and continuing once the limit resets.
    private func withLimitActions(_ conversation: RemoteConversation, presentation: ConversationPresentation,
                                  of session: SessionRecord, in model: AppModel) -> RemoteConversation {
        guard let card = Self.latestLimit(presentation, of: session, in: model),
              let turn = conversation.turns.firstIndex(where: { $0.id == card.turnID }),
              let index = conversation.turns[turn].items.lastIndex(where: { $0.errorKind == "usageLimit" }) else {
            return conversation
        }
        var options: [String] = []
        if !model.usageLimitAccounts(for: session).isEmpty { options.append("continueWithAccount") }
        if card.resetsAt != nil { options.append("autoContinue") }
        guard !options.isEmpty else { return conversation }
        var conversation = conversation
        conversation.turns[turn].items[index].options = options
        if model.usageLimitAutoContinue[session.id]?.entryID == card.entryID {
            conversation.turns[turn].items[index].autoContinue = true
        }
        return conversation
    }

    /// The limit card that may act now: the transcript's last entry, of a Claude Code task that is
    /// idle and not being moved, as the Mac's card decides (`TaskProviderNotices.canContinue`).
    private static func latestLimit(_ presentation: ConversationPresentation, of session: SessionRecord,
                                    in model: AppModel) -> (turnID: String, entryID: UUID, resetsAt: Date?)? {
        guard session.harness == .claudeCode, session.status != .running, session.status != .waitingForApproval,
              !model.switchingAccounts.contains(session.id), !model.sessionMutations.contains(session.id),
              let turn = presentation.turns.last, case let .usageLimit(limit, entryID)? = turn.outcome,
              model.transcriptBySessionID[session.id]?.last?.id == entryID else { return nil }
        return (turn.id, entryID, limit.resetsAt.flatMap { $0 > Date() ? $0 : nil })
    }

    /// What became of each suggested task, which the chip reads from the app rather than the turn
    /// (§15.9): the actions the chip offers now, or its outcome.
    private func withSuggestionStates(_ conversation: RemoteConversation, of session: SessionRecord,
                                      in model: AppModel) -> RemoteConversation {
        var conversation = conversation
        for turn in conversation.turns.indices {
            for index in conversation.turns[turn].items.indices {
                guard let id = conversation.turns[turn].items[index].suggestionId else { continue }
                var item = conversation.turns[turn].items[index]
                let resolution = model.taskSuggestions.resolution(of: id, in: session.id)
                let progress = model.taskSuggestions.progress(of: id, in: session.id)
                switch (resolution?.outcome, progress) {
                case (.started?, _):
                    item.suggestionState = "started"
                    item.startedTaskId = resolution?.startedTaskID?.uuidString
                    item.options = nil
                case (.dismissed?, _):
                    item.suggestionState = "dismissed"
                    item.options = nil
                case (.sentHere?, _):
                    item.suggestionState = "sentHere"
                    item.options = nil
                case (nil, .starting?), (nil, .sending?):
                    item.suggestionState = "starting"
                    item.options = nil
                case (nil, .failed?):
                    item.suggestionState = "failed"
                    item.options = RemoteSuggestionAction.allCases.map(\.rawValue)
                case (nil, nil):
                    item.suggestionState = "open"
                    item.options = RemoteSuggestionAction.allCases.map(\.rawValue)
                }
                conversation.turns[turn].items[index] = item
            }
        }
        return conversation
    }

    /// Opening a task on the Mac reads its latest saved history (a Claude transcript the CLI wrote,
    /// a detached Codex thread's newest page); a phone opening it reads the same way. No turn starts.
    func prepareConversation(of taskID: String) async {
        guard let model, let id = UUID(uuidString: taskID), let session = listedSession(id) else { return }
        await model.refreshConversationStatus(for: session)
    }

    /// Scrolling up to the top on the Mac: a Codex thread's earlier page, or more of a Claude transcript.
    func loadEarlierConversation(of taskID: String) async {
        guard let model, let id = UUID(uuidString: taskID), let session = listedSession(id) else { return }
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           model.codexPresentationBySessionID[session.id]?.thread?.turnsNextCursor != nil {
            await model.loadMoreCodexTurns(for: session)
        } else if model.hasEarlierClaudeHistory(session) {
            await model.readEarlierClaudeHistory(for: session)
        }
    }

    func setWatchedTasks(_ taskIDs: Set<String>) {
        watched = Set(taskIDs.compactMap(UUID.init(uuidString:)))
        model?.remoteWatchedTaskIDs = watched
        for id in Array(projectionCaches.keys) where !watched.contains(id) {
            projectionCaches[id] = nil
            turnMemos[id] = nil
            cachedConversations[id] = nil
        }
    }

    private func tasksChanged() {
        cachedSnapshot = nil
        changeHandler?(.tasks)
    }

    private func conversationChanged(_ id: UUID) {
        cachedConversations[id] = nil
        changeHandler?(.conversation(id.uuidString))
    }

    private func listedSession(_ id: UUID) -> SessionRecord? {
        model?.sidebarSessions.first { $0.id == id }
    }

    // MARK: - Commands

    func perform(_ command: RemoteCommand) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable, "Yardlet is closing") }
        switch command {
        case let .sendMessage(taskID, text, images, followUp, files):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The composer's own send would take the text as the edited message, or drop it.
            if model.composerDrafts.tasks.draft(for: session.id).editState != nil {
                return RemoteError(.busy, "A message is being edited on the Mac")
            }
            if model.switchingAccounts.contains(session.id) || model.sessionMutations.contains(session.id) {
                return RemoteError(.busy, "The task is changing on the Mac")
            }
            switch model.sendRefusal(for: session) {
            case .heldElsewhere?: return RemoteError(.busy, "Another app holds this conversation")
            case .folderMissing?: return RemoteError(.unavailable, "The task's folder no longer exists")
            case nil: break
            }
            var input = HarnessUserInput(text: text)
            // Everything is checked before an image is written, so a refused message leaves nothing behind.
            guard let fileInputs = Self.inputs(for: files, policy: Self.inputPolicy(session, in: model)) else {
                return RemoteError(.notAllowed, "This task takes no such files")
            }
            if !images.isEmpty {
                guard Self.acceptsImages(session, in: model) else { return RemoteError(.notAllowed, "This task takes no images") }
                guard let attached = Self.store(images) else { return RemoteError(.internal, "The images could not be saved") }
                input.images = attached
            }
            for file in fileInputs {
                switch file {
                case let .localImage(url, _): input.images += HarnessUserInput.ImageAttachment(url: url).map { [$0] } ?? []
                case let .mention(_, path): input.mentions.append(path)
                case let .localAudio(url): input.mentions.append(url)
                default: break
                }
            }
            // As the composer sends: an idle task starts a turn, a running one takes a follow-up, steered or
            // queued as the phone chose (the composer's Return and ⌘Return) or as the Mac's setting says.
            if let followUp, session.status == .running || session.status == .waitingForApproval {
                Task { await model.submitFollowUp(input, action: followUp == .steer ? .steer : .queue, to: session) }
            } else {
                Task { await model.send(input, to: session) }
            }
            return nil
        case let .answerApproval(taskID, requestID, answer, note):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            guard let route = RemoteApprovalPolicy.route(for: answer, to: request) else {
                return RemoteError(.notAllowed, "Answer this request on the Mac")
            }
            guard model.isAttached(session.id) else { return RemoteError(.unavailable, "The task is not connected") }
            // Claude Code reads a denial's note as its message, as its own "tell Claude what to do differently",
            // whether the task's own session asks or a subagent it runs does.
            if let note, case .transcript = request.source, Self.readsDenialNotes(request, in: session, model: model) {
                await model.respond(to: request.id, answer: .denial(reason: note), in: session)
                return nil
            }
            // The request card's route (`ConversationActions.respond`).
            switch route {
            case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
            case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
            case let .codex(response): await model.respondCodex(to: request.id, response: response, in: session)
            case .answer, .structured: return RemoteError(.notAllowed)
            }
            // Every other harness gets the note as the task's next message, as the composer sends one.
            if let note { Task { await model.send(HarnessUserInput(text: note), to: session) } }
            return nil
        case let .stopTurn(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The stop button: a running bash command first, then the turn.
            if model.isShellCommandRunning(in: session) {
                model.stopShellCommand(in: session)
                return nil
            }
            guard session.status == .running || session.status == .waitingForApproval else {
                return RemoteError(.notRunning)
            }
            await model.interrupt(session)
            return nil
        case let .markRead(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            await model.store.markRead(id: session.id)
            return nil
        case let .answerQuestion(taskID, requestID, answers):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            let offered = RemoteApprovalPolicy.formAnswers(for: request)
            guard offered.contains(RemoteProtocol.answerOption) || offered.contains(RemoteProtocol.answerSecretOption),
                  let response = request.responses.first(where: { $0.route == .structured }),
                  let input = Self.formInput(answers, for: request.form?.questionSteps ?? []),
                  let route = request.route(for: response, input: input) else {
                return RemoteError(.notAllowed, "Those answers do not answer this request")
            }
            return await answer(request, in: session, by: route)
        case let .reviewPlan(taskID, requestID, decision, reason):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            guard !RemoteApprovalPolicy.formAnswers(for: request).isEmpty, case .planReview = request.form else {
                return RemoteError(.notAllowed, "Review this plan on the Mac")
            }
            let route: ConversationRequestRoute?
            switch decision {
            case .approve:
                route = request.responses.first { $0.route == .decision(.allow) }?.route
            case .keepPlanning:
                var input = ConversationRequestFormInput()
                input.reason = reason ?? ""
                route = request.responses.first { $0.route == .structured }.flatMap { request.route(for: $0, input: input) }
            }
            guard let route else { return RemoteError(.notAllowed) }
            return await answer(request, in: session, by: route)
        case let .actOnSuggestion(taskID, suggestionID, action):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let suggestion = suggestion(suggestionID, in: session) else { return RemoteError(.notFound) }
            guard model.taskSuggestions.resolution(of: suggestionID, in: session.id) == nil,
                  model.taskSuggestions.progress(of: suggestionID, in: session.id)?.isUnderWay != true else {
                return RemoteError(.notAllowed, "The suggestion was already acted on")
            }
            // The chip's buttons.
            switch action {
            case .start: Task { await model.startTaskSuggestion(suggestion, from: session.id) }
            case .here: Task { await model.doTaskSuggestionHere(suggestion, in: session.id) }
            case .dismiss: model.dismissTaskSuggestion(suggestionID, in: session.id)
            }
            return nil
        case let .setPinned(taskID, pinned):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The sidebar's Pin and Unpin.
            if model.pinnedSidebarSessionIDs.contains(session.id) != pinned { await model.togglePinned(session) }
            return nil
        case let .archiveTask(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            if session.status == .running || session.status == .waitingForApproval || model.isShellCommandRunning(in: session) {
                return RemoteError(.busy, "Stop the task before archiving it")
            }
            await model.archive(session)
            return nil
        case let .actOnQueued(taskID, itemID, action):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard itemID.hasPrefix("queued:"), let id = UUID(uuidString: String(itemID.dropFirst("queued:".count))),
                  let item = model.followUps.item(id, in: session.id) else { return RemoteError(.notFound) }
            guard !model.followUps.isClaimed(id) else { return RemoteError(.busy, "The message is on its way") }
            let queue = model.followUps.queue(for: session.id)
            guard TaskMessage.parse(item.draft.text) == nil, let policy = FollowUpPolicy(harness: session.harness),
                  let index = queue.firstIndex(where: { $0.id == id }) else { return RemoteError(.notAllowed) }
            // The queue chip's actions (`ComposerQueueChip`).
            let chip = ComposerQueueChip.make(policy: policy, queue: queue, at: index, canSend: true)
            switch action {
            case .sendNow:
                guard chip.send != nil else { return RemoteError(.notAllowed) }
                Task { await model.sendQueuedNow(id, for: session) }
            case .stopAndSend:
                guard chip.stopAndSend != nil else { return RemoteError(.notAllowed) }
                Task { await model.stopAndSendQueued(id, for: session) }
            case .remove:
                Task { await model.removeQueued(id, for: session) }
            }
            return nil
        case let .continueWithAccount(taskID, accountID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard Self.latestLimit(presentation(of: session, in: model), of: session, in: model) != nil else {
                return RemoteError(.notAllowed, "The task cannot continue now")
            }
            let mode = AccountListMode.continueAfterLimit(session)
            guard let choice = AccountListProjection.choices(mode, store: model.connections)
                    .first(where: { $0.connection?.id == accountID }),
                  AccountListProjection.canChoose(choice, mode: mode), let connection = choice.connection else {
                return RemoteError(.notAllowed, "That account cannot take the task")
            }
            // The limit card's list.
            Task { await model.continueAfterUsageLimit(using: connection, for: session) }
            return nil
        case let .setAutoContinue(taskID, enabled):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let card = Self.latestLimit(presentation(of: session, in: model), of: session, in: model),
                  let resetsAt = card.resetsAt else { return RemoteError(.notAllowed) }
            model.setUsageLimitAutoContinue(enabled, entryID: card.entryID, resetsAt: resetsAt, for: session)
            return nil
        case let .answerHandoff(taskID, requestID, answer):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The panel bar's I'm done and Decline.
            guard model.answerBrowserHandoff(requestID, done: answer == .done, in: session.id) else {
                return RemoteError(.requestNotFound)
            }
            return nil
        case let .chooseAnswer(taskID, requestID, choice, note, values):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            // The card's own answers, as the phone was offered them (`RemoteApprovalPolicy.choices`).
            guard RemoteApprovalPolicy.choices(for: request) != nil, let index = Int(choice),
                  request.responses.indices.contains(index) else { return RemoteError(.notAllowed, "No such answer") }
            let response = request.responses[index]
            guard note == nil || response.role == .destructive else {
                return RemoteError(.notAllowed, "A note goes with a denial only")
            }
            guard model.isAttached(session.id) else { return RemoteError(.unavailable, "The task is not connected") }
            var route = response.route
            if route == .structured {
                guard case let .mcpForm(form) = request.form else { return RemoteError(.notAllowed) }
                var input = ConversationRequestFormInput()
                switch Self.fieldValues(values, for: form) {
                case let .success(fields): input.fields = fields
                case let .failure(error): return error
                }
                if let field = form.fields.first(where: { form.issue(of: $0, in: input.fields) != nil }),
                   let issue = form.issue(of: field, in: input.fields) {
                    return RemoteError(.notAllowed, "\(field.label): \(issue.message)")
                }
                guard let formed = request.route(for: response, input: input) else { return RemoteError(.notAllowed) }
                route = formed
            }
            if let note, case .transcript = request.source, Self.isPlainDenial(route),
               Self.readsDenialNotes(request, in: session, model: model) {
                await model.respond(to: request.id, answer: .denial(reason: note), in: session)
                return nil
            }
            if let error = await answer(request, in: session, by: route) { return error }
            if let note { Task { await model.send(HarnessUserInput(text: note), to: session) } }
            return nil
        }
    }

    /// A denial that leaves nothing behind: the plain deny, or the provider's one-time one.
    private static func isPlainDenial(_ route: ConversationRequestRoute) -> Bool {
        switch route {
        case .decision(.deny): true
        case let .providerAction(action):
            action.decision == .deny && PermissionActionPreference.scope(id: action.id, intent: action.kind) != .broad
        default: false
        }
    }

    /// A phone's MCP form values as the card's form holds them (§15.19): words and numbers as typed, a switch,
    /// the options picked. A value for no field, or of the wrong shape for its field, is refused rather than left
    /// out, so the form never sends a default in place of what the person meant.
    static func fieldValues(_ values: [String: RemoteFormValue],
                            for form: CodexMCPElicitationForm) -> Result<[String: CodexMCPElicitationFieldValue], RemoteError> {
        if let unknown = values.keys.sorted().first(where: { id in !form.fields.contains { $0.id == id } }) {
            return .failure(RemoteError(.notAllowed, "\(unknown): no such field"))
        }
        var fields: [String: CodexMCPElicitationFieldValue] = [:]
        for field in form.fields {
            guard let value = values[field.id] else { continue }
            switch (field.kind, value) {
            case let (.text, .text(text)): fields[field.id] = .text(text)
            case let (.number, .text(text)): fields[field.id] = .text(text)
            case let (.number, .number(number)):
                // A whole number that fits is written as one; any other (1e20, 2.5) as the form's checks read it.
                fields[field.id] = .text(number.rounded() == number && abs(number) < 9_007_199_254_740_992
                    ? String(Int64(number)) : String(number))
            case let (.boolean, .flag(flag)): fields[field.id] = .flag(flag)
            case let (.choice, .text(choice)): fields[field.id] = .picked([choice])
            case let (.choices, .list(list)): fields[field.id] = .picked(Set(list))
            default: return .failure(RemoteError(.notAllowed, "\(field.label): \(L10n.string("Wrong kind of value"))"))
            }
        }
        return .success(fields)
    }

    /// The images a phone sent, written where the composer writes a pasted one (§15.14). None stays
    /// behind when one cannot be written.
    private static func store(_ images: [RemoteImage]) -> [HarnessUserInput.ImageAttachment]? {
        var attached: [HarnessUserInput.ImageAttachment] = []
        for image in images {
            let format = image.format == "png" ? ("png", "image/png") : ("jpg", "image/jpeg")
            guard let url = try? ComposerAttachmentIntake.storePastedImage(image.data, fileExtension: format.0) else {
                discard(attached)
                return nil
            }
            attached.append(HarnessUserInput.ImageAttachment(url: url, mimeType: format.1))
        }
        return attached
    }

    /// Removes images `store` wrote that no message took, each with its own folder.
    private static func discard(_ images: [HarnessUserInput.ImageAttachment]) {
        for image in images where ComposerAttachmentIntake.isPastedImage(image.url) {
            try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent())
        }
    }

    /// Whoever asks reads a denial's own message: the task's Claude Code session, or the subagent
    /// whose request the task holds when its harness takes structured answers.
    private static func readsDenialNotes(_ request: ConversationRequest, in session: SessionRecord, model: AppModel) -> Bool {
        guard model.heldRequests(in: session.id).contains(where: { $0.id == request.id }) else {
            return session.harness == .claudeCode
        }
        let run = model.sessionTools.runs(hostedBy: session.id).first { $0.pendingRequests.contains { $0.id == request.id } }
        return run?.adapter is any HarnessStructuredPermissionResponding
    }

    /// Sends a request's answer by its route, as the card does (`ConversationActions.respond`).
    private func answer(_ request: ConversationRequest, in session: SessionRecord,
                        by route: ConversationRequestRoute) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable) }
        guard model.isAttached(session.id) else { return RemoteError(.unavailable, "The task is not connected") }
        switch route {
        case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
        case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
        case let .answer(answer): await model.respond(to: request.id, answer: answer, in: session)
        case let .codex(response): await model.respondCodex(to: request.id, response: response, in: session)
        case .structured: return RemoteError(.notAllowed)
        }
        return nil
    }

    /// A phone's answers as the card's form input (§15.3), or nil when they do not fit the steps: an
    /// unknown question or label, several picks for a one-answer question, own words where none are
    /// taken, a skip where none is allowed.
    static func formInput(_ answers: [RemoteQuestionAnswer], for steps: [ConversationQuestionStep]) -> ConversationRequestFormInput? {
        var input = ConversationRequestFormInput()
        for answer in answers {
            guard let step = steps.first(where: { $0.id == answer.questionId }) else { return nil }
            if answer.skipped == true {
                guard step.canSkip else { return nil }
                input.skipped.insert(step.id)
                continue
            }
            let picked = answer.options ?? []
            guard picked.allSatisfy({ label in step.options.contains { $0.label == label } }),
                  step.allowsMultipleSelections || picked.count <= 1 else { return nil }
            if !picked.isEmpty { input.selections[step.id] = Set(picked) }
            if let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                guard step.allowsCustomAnswer else { return nil }
                input.text[step.id] = text
            }
        }
        return input
    }

    /// Where a task started in the project goes: its folder and project, nil for a chat.
    private func place(_ projectID: String, in model: AppModel) -> Result<(folder: URL?, project: Project?), RemoteError> {
        guard projectID != RemoteTaskProjection.chatsProjectID else { return .success((nil, nil)) }
        guard let group = model.projects.visibleGroups(sessions: model.store.sessions)
            .first(where: { RemoteTaskProjection.projectID(for: $0) == projectID }) else { return .failure(RemoteError(.notFound)) }
        let folder = group.project?.primaryRoot ?? group.workspaceURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(RemoteError(.unavailable, "The project's folder no longer exists"))
        }
        return .success((folder, group.project))
    }

    /// The harness a phone's new task runs on: the one it named, among those the Mac's new-task composer
    /// offers, else the composer's own.
    private static func harness(_ named: String?, in model: AppModel) -> Result<HarnessKind, RemoteError> {
        let offered = model.runtimeSelections.connectedDescriptors.map(\.id)
        if let named {
            guard let harness = offered.first(where: { $0.rawValue == named }) else {
                return .failure(RemoteError(.notAllowed, "The Mac does not offer \(named)"))
            }
            return .success(harness)
        }
        guard let harness = newTaskHarness(in: model) ?? offered.first else {
            return .failure(RemoteError(.unavailable, "No harness can start a task"))
        }
        return .success(harness)
    }

    /// The new-task screen's model menu and permission mode for the harness as the phone sees them
    /// (§15.16): each selector's value now and its choices, without those the Mac asks to confirm.
    static func settings(_ options: ComposerSessionOptions) -> [RemoteSetting] {
        var selectors: [(ProviderCapabilitySelector, Set<String>)] = [options.model?.menu.model, options.model?.menu.effort]
            .compactMap { $0.map { ($0, []) } }
        if let permission = options.permission, let selector = permission.selector {
            selectors.append((selector, Set(permission.confirmations.keys)))
        }
        return selectors.map { selector, asked in
            RemoteSetting(id: selector.id, name: selector.name, value: selector.currentValue,
                          choices: selector.choices.filter { !asked.contains($0.value) }.map {
                              RemoteSetting.Choice(value: $0.value, name: $0.name,
                                                   description: RemoteText.short($0.description, RemoteText.detailLimit))
                          })
        }
    }

    /// The new-task choice after the phone's picks, each as the menus take it, in the order they list their
    /// settings (§15.16); refused when one names a setting or value the menus do not offer then.
    private static func choosing(_ picks: [String: String], harness: HarnessKind, from start: NewTaskModelChoice?,
                                 model: AppModel, connection: ProviderConnection?,
                                 folder: URL?) -> Result<NewTaskModelChoice?, RemoteError> {
        var choice = start
        var left = picks
        while !left.isEmpty {
            let settings = Self.settings(ComposerSessionOptionsProjection.newTask(
                harness: harness, choice: choice, catalogs: model.modelCatalogs, connection: connection, workspaceURL: folder))
            guard let setting = settings.first(where: { left[$0.id] != nil }), let value = left.removeValue(forKey: setting.id),
                  setting.choices.contains(where: { $0.value == value }),
                  let chosen = NewTaskModelProjection.choosing(setting.id, value: value, harness: harness, choice: choice,
                                                               catalogs: model.modelCatalogs, connection: connection,
                                                               workspaceURL: folder) else {
                return .failure(RemoteError(.notAllowed, "The Mac does not offer that choice now"))
            }
            choice = chosen
        }
        return .success(choice)
    }

    private static func option(_ harness: HarnessKind) -> RemoteHarnessOption {
        let policy = HarnessComposerInputPolicy(harness: harness)
        return RemoteHarnessOption(harness: harness.rawValue, harnessName: harness.displayName,
                                   acceptsImages: policy.carriesImages ? true : nil,
                                   acceptsFiles: policy.showsMentionControl ? true : nil)
    }

    func newTaskOptions(projectID: String?, harness named: String?,
                        settings picked: [String: String]) async -> Result<RemoteNewTaskOptions, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        let place: (folder: URL?, project: Project?)
        switch self.place(projectID ?? RemoteTaskProjection.chatsProjectID, in: model) {
        case let .success(found): place = found
        case let .failure(error): return .failure(error)
        }
        let harness: HarnessKind
        switch Self.harness(named, in: model) {
        case let .success(found): harness = found
        case let .failure(error): return .failure(error)
        }
        let connection = model.connections.selected(for: harness)
        var choice = model.composerDrafts.home.modelChoices[harness]
        func options() -> ComposerSessionOptions {
            ComposerSessionOptionsProjection.newTask(harness: harness, choice: choice, catalogs: model.modelCatalogs,
                                                     connection: connection, workspaceURL: place.folder)
        }
        // As opening the menu does, the harness's model list is read first where none is known yet.
        if options().model?.menu.canChoose == false, let runtime = model.runtimeSelections.selectedURL(for: harness) {
            let folder = place.folder
            await RemoteServer.waitAtMost(10) { @MainActor in
                await model.loadNewTaskModels(harness: harness, runtimeURL: runtime, connection: connection, workspaceURL: folder)
            }
        }
        // What the phone picked so far, so the menus answer as they would after those picks.
        switch Self.choosing(picked, harness: harness, from: choice, model: model, connection: connection, folder: place.folder) {
        case let .success(chosen): choice = chosen
        case let .failure(error): return .failure(error)
        }
        let worktree = place.project.flatMap { project in
            place.folder.map(SuggestedTaskPlace.isInRepository) == true
                ? model.composerDrafts.home.startsInNewWorktree(projectID: project.id) : nil
        }
        return .success(RemoteNewTaskOptions(
            harness: Self.option(harness), harnesses: model.runtimeSelections.connectedDescriptors.map { Self.option($0.id) },
            settings: Self.settings(options()), worktree: worktree))
    }

    func createTask(_ start: RemoteTaskStart) async -> Result<String, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        let place: (folder: URL?, project: Project?)
        switch self.place(start.projectID, in: model) {
        case let .success(found): place = found
        case let .failure(error): return .failure(error)
        }
        let (folder, project) = place
        // As the Mac's home composer would start it with this project chosen, and what the phone picked.
        let draft = model.composerDrafts.home
        let harness: HarnessKind
        switch Self.harness(start.harness, in: model) {
        case let .success(found): harness = found
        case let .failure(error): return .failure(error)
        }
        guard let runtime = model.runtimeSelections.selectedURL(for: harness) else {
            return .failure(RemoteError(.unavailable, "No harness can start a task"))
        }
        let connection = model.connections.selected(for: harness)
        let choice: NewTaskModelChoice?
        switch Self.choosing(start.settings, harness: harness, from: draft.modelChoices[harness], model: model,
                             connection: connection, folder: folder) {
        case let .success(chosen): choice = chosen
        case let .failure(error): return .failure(error)
        }
        var worktree = folder != nil && draft.startsInNewWorktree(projectID: project?.id)
        if let asked = start.worktree {
            guard !asked || (project != nil && folder.map(SuggestedTaskPlace.isInRepository) == true) else {
                return .failure(RemoteError(.notAllowed, "The project is not in a Git repository"))
            }
            worktree = asked
        }
        var stored: [HarnessUserInput.ImageAttachment] = []
        if !start.images.isEmpty {
            guard HarnessComposerInputPolicy(harness: harness).carriesImages else {
                return .failure(RemoteError(.notAllowed, "\(harness.displayName) takes no images"))
            }
            guard let written = Self.store(start.images) else { return .failure(RemoteError(.internal, "The images could not be saved")) }
            stored = written
        }
        guard let fileInputs = Self.inputs(for: start.attachedFiles, policy: HarnessComposerInputPolicy(harness: harness)) else {
            Self.discard(stored)
            return .failure(RemoteError(.notAllowed, "\(harness.displayName) takes no such files"))
        }
        let attachments = stored.compactMap { CodexUserInput.localAttachment(for: $0.url) } + fileInputs
        let text = start.text
        let submission = NewTaskDraft.Submission(
            originalText: text, attachments: attachments, harness: harness, workspaceURL: folder, projectID: project?.id,
            runtimeURL: runtime, connection: connection, startsInNewWorktree: worktree,
            providerOptions: choice?.providerOptions(for: harness) ?? [:],
            selectsTask: false)
        let previousError = model.bootstrapError
        do {
            guard let created = try await model.createTask(submission) else {
                Self.discard(stored)
                let reason = model.bootstrapError != previousError ? model.bootstrapError : nil
                return .failure(RemoteError(.internal, reason ?? "The task did not start"))
            }
            return .success(created.id.uuidString)
        } catch {
            Self.discard(stored)
            return .failure(RemoteError(.internal, error.localizedDescription))
        }
    }

    func limitAccounts(taskID: String) async -> Result<[RemoteAccount], RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard Self.latestLimit(presentation(of: session, in: model), of: session, in: model) != nil else {
            return .failure(RemoteError(.unavailable, "The task's limit card offers no accounts now"))
        }
        // As the list does when it opens: limits not confirmed within the last minute are read again.
        await RemoteServer.waitAtMost(15) { @MainActor in await model.refreshUsageLimitAccounts(for: session) }
        let mode = AccountListMode.continueAfterLimit(session)
        return .success(AccountListProjection.choices(mode, store: model.connections).map { choice in
            RemoteAccount(
                id: choice.id, name: choice.title, detail: AccountListProjection.accountLine(choice),
                usage: choice.quotas.map(AccountLimitWindow.init(metric:)).map { window in
                    RemoteAccount.Usage(label: window.name, usedPercent: window.remainingPercent.map { Int((100 - $0).rounded()) },
                                        resetsAt: window.resetsAt.map(RemoteJSON.milliseconds))
                },
                current: choice.connection == session.connection ? true : nil,
                available: AccountListProjection.canChoose(choice, mode: mode) ? true : nil)
        })
    }

    func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard let item = item(itemID, in: presentation(of: session, in: model)) else { return .failure(RemoteError(.notFound)) }
        var detail = RemoteItemDetail()
        switch item.kind {
        case let .command(command):
            (detail.output, detail.outputTruncated) = Self.tail(command.output)
        case let .tool(tool):
            (detail.output, detail.outputTruncated) = Self.tail(tool.output)
            if let diff = tool.diff, let patch = ConversationFileChangeProjection.unifiedDiff(for: diff, workspaceURL: session.workspaceURL) {
                detail.diffs = [Self.diff(path: diff.path, patch: patch, counts: nil)]
            }
        case let .fileChange(change):
            let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: session.workspaceURL) } : change.rows
            detail.diffs = rows.prefix(RemoteItemDetail.diffCount).compactMap { row in
                let patch = CodexFileChangeDiff.unifiedDiff(for: row.change, workspaceURL: nil)
                    ?? Self.patch(from: row.previewLines)
                return patch.map { Self.diff(path: row.displayPath, patch: $0, counts: row.lineCounts) }
            }
        default:
            break
        }
        guard detail.output != nil || !detail.diffs.isEmpty else { return .failure(RemoteError(.unavailable)) }
        return .success(detail)
    }

    /// The line a phone's item ID names (`i:` and the item's own ID).
    private func item(_ itemID: String, in presentation: ConversationPresentation) -> ConversationItem? {
        guard itemID.hasPrefix("i:") else { return nil }
        for turn in presentation.turns {
            let items: [ConversationItem] = turn.prompt + turn.notices + turn.work + turn.answers
            if let item = items.first(where: { "i:\($0.id)" == itemID }) { return item }
        }
        return nil
    }

    private static func tail(_ output: String?) -> (String?, Bool) {
        guard let output, !output.isEmpty else { return (nil, false) }
        guard output.count > RemoteItemDetail.outputLimit else { return (output, false) }
        return (String(output.suffix(RemoteItemDetail.outputLimit)), true)
    }

    private static func diff(path: String, patch: String, counts: CodexFileChangeCardProjection.LineCounts?) -> RemoteDiff {
        let capped = RemoteText.capped(patch, RemoteItemDetail.diffLimit)
        return RemoteDiff(path: path, patch: capped.text, additions: counts?.additions, deletions: counts?.deletions,
                          truncated: capped.truncated ? true : nil)
    }

    /// The lines a card draws, as diff text, where the change holds no diff of its own.
    private static func patch(from preview: CodexFileChangeCardProjection.Preview) -> String? {
        guard !preview.lines.isEmpty else { return nil }
        return preview.lines.map { line in
            switch line.kind {
            case .addition: "+" + line.text
            case .deletion: "-" + line.text
            case .context: " " + line.text
            case .separator: "@@"
            }
        }.joined(separator: "\n")
    }

    private func suggestion(_ id: String, in session: SessionRecord) -> ConversationTaskSuggestion? {
        guard let model else { return nil }
        for turn in presentation(of: session, in: model).turns {
            for item in turn.work + turn.answers {
                if case let .taskSuggestion(suggestion) = item.kind, suggestion.id == id { return suggestion }
            }
        }
        return nil
    }

    private func session(_ taskID: String) -> SessionRecord? {
        UUID(uuidString: taskID).flatMap(listedSession)
    }

    /// The request still waiting under that ID, as the task's conversation draws it now.
    private func pendingRequest(_ requestID: String, in session: SessionRecord) -> ConversationRequest? {
        guard let model else { return nil }
        if let request = model.heldRequests(in: session.id).first(where: { $0.id == requestID }) {
            return request
        }
        return presentation(of: session, in: model).turns.lazy.flatMap(\.requests)
            .first { $0.id == requestID && $0.state == .pending }
    }

    /// The task's conversation as the timeline draws it now, uncached.
    private func presentation(of session: SessionRecord, in model: AppModel) -> ConversationPresentation {
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           let state = model.codexPresentationBySessionID[session.id], state.thread?.turns.isEmpty == false {
            return CodexConversationProjection.presentation(state, workspaceURL: session.workspaceURL, historySelection: nil)
        }
        return TranscriptConversationProjection.presentation(
            from: model.transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
            latestTurnIsComplete: session.completionState == .completed)
    }
}
