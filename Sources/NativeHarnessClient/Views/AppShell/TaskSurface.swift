import SwiftUI

struct TaskDetail: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.codexStatusPanel) private var codexStatus
    @Environment(\.terminalShellLaunch) private var terminalShellLaunch
    @Environment(\.sessionRail) private var railServices
    @Environment(\.composerConnectors) private var composerConnectors
    @Environment(\.taskFolderMissing) private var folderMissing
    /// The header the task's area draws (the title bar, or a split pane's header), which the raised rail
    /// leaves uncovered.
    @Environment(\.taskAreaHeader) private var areaHeader
    var conversationOnly = false
    var sideChat: AnyView? = nil
    var onOpenSideChat: (() -> Void)? = nil
    /// Other tasks' conversations as side-panel tabs; nil where the panel shows none (a side chat, a
    /// conversation shown in another task's panel).
    var sidePanelTasks: SidePanelTaskServices? = nil
    let session: SessionRecord
    let composerDraft: TaskComposerDraft
    @Bindable var workspaceState: TaskWorkspaceState
    @Binding var panelState: TaskSurfaceNavigationProjection.PanelState
    var focusedSurface: FocusState<TaskSurface?>.Binding
    let entries: [TranscriptEntry]
    /// The task's saved conversation is being read from the provider's own history.
    var isReadingSavedConversation = false
    let errorMessage: String?
    let codexTaskState: CodexTaskState?
    let codexHistorySelection: CodexHistorySearchSelection?
    let codexQueue: [CodexQueuedSubmission]
    var isCodexQueuePaused = false
    let codexCapabilities: CodexCapabilityState
    let providerCapabilities: ProviderCapabilityState?
    let providerUsage: HarnessProtocolUsage?
    /// A Codex task's token usage read back after a restart (the index, then the rollout), shown
    /// until its thread reports its own.
    var restoredCodexTokenUsage: CodexThreadTokenUsage? = nil
    let isProviderAttached: Bool
    /// Codex's own settings, which the error under an empty Codex conversation opens. The
    /// conversation's `showHarnessSettings` opens the provider settings.
    let onShowCodexCapabilities: () -> Void
    /// What the conversation and the composer can ask of the app, as the window built them.
    let conversationActions: ConversationActions
    let composerActions: ComposerActions
    @State private var editingDraft: CodexComposerDraft?
    @State private var editingDraftID = UUID()
    @State private var selectedSubtaskID: String?
    /// The side-panel surface shown before a subtask opened over it, or nil when the panel was hidden.
    @State private var subtaskReturnSurfaceID: String?
    @State private var stoppingSubtaskIDs: Set<String> = []
    @State private var subtaskErrors: [String: String] = [:]
    /// Codex background terminals asked to stop, until the rail no longer lists them.
    @State private var stoppingTerminalIDs: Set<String> = []

    /// The Codex thread's newest turn usage, else what was read back for it.
    private var shownCodexTokenUsage: CodexThreadTokenUsage? {
        codexTaskState?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage ?? restoredCodexTokenUsage
    }

    private func restoreDraft(_ draft: CodexComposerDraft) {
        editingDraft = draft
        editingDraftID = UUID()
    }

    var body: some View {
        Group {
            if conversationOnly, let activity = selectedSubtask, let onReadSubtask = conversationActions.readSubtask {
                subtaskPane(activity, reader: onReadSubtask)
                    .environment(\.workSurfaceNavigation, nil)
            } else if conversationOnly { chatSurface }
            else { dockedWorkspace }
        }
        .onChange(of: entries) { _, _ in
            stoppingSubtaskIDs = stoppingSubtaskIDs.filter { id in
                entries.contains { entry in
                    if case let .activity(activity, state) = entry.content { return activity.id == id && state == .running }
                    return false
                }
            }
        }
        .onChange(of: session.providerSessionID) { _, _ in clearSubtask() }
        .onChange(of: session.connection) { _, _ in clearSubtask() }
        .onChange(of: session.environmentScope) { _, _ in clearSubtask() }
        .onDisappear {
            if !conversationOnly {
                workspaceState.leaveTerminal()
                railServices?.window.forget(session.id)
            }
        }
    }

    private var dockedWorkspace: some View {
        TaskWorkspaceLayout(
            showsTrailing: panelState.trailingSurfaceID != nil,
            showsTerminal: panelState.isTerminalPresented,
            preferences: $workspaceState.layout,
            wantsRail: railServices?.window.visibility.isShown ?? false,
            onRailFitChange: { fits in railServices?.window.setFits(fits, for: session.id) },
            onReturnToChat: closeTrailingSurface,
            onCloseTrailing: closeTrailingSurface,
            onCloseTerminal: closeTerminal,
            chat: { chatSurface },
            rail: { railHost(isRaised: false) },
            trailing: {
                Group {
                    if panelState.trailingSurfaceID == "subtask" {
                        if let activity = selectedSubtask, let onReadSubtask = conversationActions.readSubtask {
                            subtaskPane(activity, reader: onReadSubtask)
                        } else {
                            Color.clear.onAppear(perform: returnFromSubtask)
                        }
                    } else if panelState.trailingSurfaceID == TaskPanelDetail.surfaceID {
                        if let detail = workspaceState.panelDetail {
                            detailPane(detail)
                        } else {
                            Color.clear.onAppear(perform: workspaceState.closePanelDetail)
                        }
                    } else if panelState.trailingSurfaceID == TaskSurfaceNavigationProjection.launcherID {
                        SidePanelLauncher(
                            workspaceURL: session.workspaceURL, choices: sidePanelChoices,
                            pages: { [workspaceState] in
                                TaskSidePanelTabs.visitedPageTabs(workspaceState.browserTabs,
                                                                  icons: workspaceState.browserClient?.addressHistory,
                                                                  limit: SidePanelLauncher.pageCount)
                            },
                            tasks: { [sidePanelTasks] in sidePanelTasks?.choiceTabs() ?? [] },
                            onOpen: openSidePanel,
                            onOpenPage: openLauncherPage,
                            onRemovePage: { workspaceState.browserTabs.removeVisited($0) },
                            onClose: { closeSidePanelTab(TaskSurfaceNavigationProjection.launcherID) })
                    } else if let id = panelState.trailingSurfaceID,
                              let taskID = TaskSurfaceNavigationProjection.taskID(inTab: id) {
                        // A tab whose task was archived or deleted closes.
                        if let sidePanelTasks, let record = sidePanelTasks.record(taskID) {
                            sidePanelTasks.tab(record) { closeSidePanelTab(id) }
                        } else {
                            Color.clear.onAppear { closeSidePanelTab(id) }
                        }
                    } else if let key = TaskSurfaceNavigationProjection.browserKey(inTab: panelState.trailingSurfaceID) {
                        browserTabPane(key)
                    } else if panelState.trailingSurfaceID == "files" {
                        FilesPane(workspaceURL: session.workspaceURL, state: workspaceState.files,
                                  onClose: { closeSidePanelTab("files") })
                    } else if panelState.trailingSurfaceID == "sideChat", let sideChat {
                        sideChat
                    } else if let id = panelState.trailingSurfaceID, let surface = TaskSurface(rawValue: id) {
                        auxiliarySurface(surface)
                    }
                }
                .environment(\.workSurfaceNavigation, sidePanelNavigation)
            },
            bottom: { auxiliarySurface(.terminal) }
        )
        .overlay(alignment: .topTrailing) {
            if let railServices, railServices.window.visibility.isRaised(session.id) {
                SessionRailRaisedLayer(onDismiss: railServices.window.dismissRaised) { railHost(isRaised: true) }
                    .padding(.top, areaHeader?.height ?? 0)
            }
        }
        // Whether Review is offered is read again each time the side panel shows.
        .task(id: panelState.trailingSurfaceID != nil) {
            guard panelState.trailingSurfaceID != nil else { return }
            guard let found = try? await GitDiffService().repositories(
                containing: [session.workspaceURL] + session.additionalRootURLs) else { return }
            workspaceState.hasRepository = !found.isEmpty
        }
#if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: BrowserHostQAFixture.openBrowserPanel)) { _ in
            showBrowserTab(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserHostQAFixture.closeBrowserPanel)) { _ in
            closeTrailingSurface()
        }
        .onAppear {
            BrowserHostQAFixture.composerDraft = composerDraft
            BrowserHostQAFixture.startIfRequested(session: session.id)
        }
#endif
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            TaskConversationView(
                harness: session.harness,
                workspaceURL: session.workspaceURL,
                entries: entries,
                sessionStatus: session.status,
                latestTurnIsComplete: session.completionState == .completed,
                codexTaskState: codexTaskState,
                codexHistorySelection: codexHistorySelection,
                providerSessionID: session.providerSessionID,
                transcriptReading: workspaceState.transcript,
                codexReading: workspaceState.codex,
                actions: chatActions,
                isReadingSavedConversation: isReadingSavedConversation,
                diagnosticID: session.id.uuidString,
                renderState: workspaceState.conversationRender
            )
            .environment(\.transcriptWorkspaceURL, session.workspaceURL)
            .environment(\.conversationFind, workspaceState.conversationFind)
            // A web link opens in the task's browser; a file and the rest go where the window sends them.
            .environment(\.openURL, OpenURLAction { url in
                if ConversationLinkRoute(url) == .taskBrowser {
                    openInTaskBrowser(url)
                } else {
                    openURL(url)
                }
                return .handled
            })
            .overlay(alignment: .topTrailing) {
                ConversationFindBar(find: workspaceState.conversationFind)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
            }

            if let errorMessage = TaskErrorNotice.message(errorMessage, harness: session.harness, entries: entries,
                                                          codexTaskState: codexTaskState) {
                TranscriptErrorCard(
                    harness: session.harness, message: errorMessage, recoverable: true,
                    onShowHarnessSettings: session.harness == .codex
                        ? onShowCodexCapabilities : conversationActions.showHarnessSettings
                )
                // The composer's column, so the reason sits over the message it kept.
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }

            if let folderMissing {
                TaskFolderMissingBanner(notice: folderMissing)
            }

            if let edit = composerDraft.editState, let rewindActions = conversationActions.rewind {
                ConversationEditBanner(edit: edit, onCancel: rewindActions.cancelEdit)
            }

            // A retry shows on the running turn's status line (D6); this line keeps the limit warning.
            if let providerNotices = conversationActions.providerNotices,
               ProviderNoticeLines.showsAnything(providerNotices) {
                ProviderNoticeLines(notices: providerNotices)
            }

            if session.harness == .codex, let codexStatus {
                codexStatusPanel(codexStatus)
            }

            // The task's background agents and tasks while they run, on the composer rail — but for what
            // the session rail on screen lists in its Agents and Background tasks cards.
            let backgroundTasks = BackgroundTasksProjection(entries: entries, includesAgents: !railLists(.agents),
                                                            includesTasks: !railLists(.backgroundTasks))
            if backgroundTasks.isShown {
                BackgroundTasksBar(projection: backgroundTasks, actions: activityActions)
                    .attachedAboveComposer()
            }

            PromptComposer(
                harness: session.harness,
                composerDraft: composerDraft,
                skills: codexCapabilities.skills.filter(\.enabled),
                modes: codexCapabilities.modes,
                selectedModeID: codexCapabilities.selectedModeID,
                modelCatalog: codexCapabilities.modelCatalog,
                runLocation: codexCapabilities.selectedRunLocation,
                providerSession: session,
                providerEntries: entries,
                providerCapabilities: providerCapabilities,
                providerUsage: providerUsage,
                isProviderAttached: isProviderAttached,
                isRunning: session.status == .running
                    || session.status == .waitingForApproval,
                canSteer: presentationPolicy.showsCodexComposerControls
                    ? codexTaskState?.activeTurnID != nil
                    : session.harness == .claudeCode && isProviderAttached,
                prefilledDraft: editingDraft,
                prefilledDraftID: editingDraftID,
                // The composer shows the queue where its harness has one.
                codexQueue: codexQueue,
                isCodexQueuePaused: isCodexQueuePaused,
                mentionRoots: [session.workspaceURL] + session.additionalRootURLs,
                codexHasThread: session.providerSessionID != nil,
                codexTokenUsage: shownCodexTokenUsage,
                canOpenSideChat: onOpenSideChat != nil,
                workspaceURL: session.workspaceURL,
                actions: promptActions
            )
            // Drawn again when what it shows changed, not for every fragment the conversation streams.
            .equatable()
            .accessibilitySortPriority(ParityAccessibility.composer)
            // The status tray tucks under the composer's top edge.
            .zIndex(1)
        }
    }

    /// The conversation's actions with what this view owns: restoring a request into the
    /// composer, the subtask controls, running a command in the task's terminal, and when the task
    /// may retry a turn or Codex implement its plan.
    private var chatActions: ConversationActions {
        var actions = conversationActions
        actions.restoreDraft = { restoreDraft($0) }
        actions.subtaskControls = activityActions
        // A conversation shown without its task's panels (a side chat) has no terminal to hand to.
        actions.runInTerminal = conversationOnly ? nil : { runInTerminal($0) }
        let allowsRetry = (session.status == .ready || session.status == .failed)
            && composerDraft.editState == nil && codexQueue.isEmpty
        if !allowsRetry { actions.retryTurn = nil }
        if !canStartCodexTurn {
            actions.implementCodexPlan = nil
            actions.answerQuestion = nil
        }
        return actions
    }

    /// The composer's actions; sending lets go of a restored draft, and editing a queued message
    /// brings it back into the composer.
    private var promptActions: ComposerActions {
        var actions = composerActions
        let send = composerActions.send
        actions.send = { input in
            editingDraft = nil
            send(input)
        }
        actions.submitCodex = composerActions.submitCodex.map { submit in
            { draft, action in
                editingDraft = nil
                submit(draft, action)
            }
        }
        actions.submitFollowUp = composerActions.submitFollowUp.map { submit in
            { input, action in
                editingDraft = nil
                submit(input, action)
            }
        }
        actions.editQueued = composerActions.editQueued.map { edit in
            { itemID in
                // The model has already moved it into the draft; this focuses the composer.
                let draft = edit(itemID)
                if let draft { restoreDraft(draft) }
                return draft
            }
        }
        return actions
    }

    /// The Codex app's status panel, attached above the composer.
    private func codexStatusPanel(_ status: CodexStatusPanelState) -> some View {
        CodexStatusPanel(
            projection: CodexStatusProjection(
                sessionID: codexTaskState?.thread?.sessionID,
                threadID: session.providerSessionID,
                descendantThreadIDs: CodexStatusProjection.descendantThreadIDs(in: codexTaskState),
                tokenUsage: shownCodexTokenUsage,
                rateLimits: status.reading.rateLimits,
                isReadingRateLimits: status.reading.isReading,
                selectedModel: codexCapabilities.modelCatalog.selection?.model
            ),
            onClose: status.close
        )
        .attachedAboveComposer()
    }

    // MARK: - Session rail

    /// The session rail on screen lists these in its card, so the composer's line does not.
    private func railLists(_ card: SessionRailCardKind) -> Bool {
        guard !conversationOnly, let railServices else { return false }
        return railServices.window.visibility.isOnScreen(session.id)
            && !railServices.preferences.preferences.isHidden(card)
    }

    /// The composer's options for this task, read the same way the composer reads them, for the
    /// rail's Settings, Context and Connectors cards.
    private var railOptions: ComposerSessionOptions {
        ComposerSessionOptionsProjection.make(
            harness: session.harness, session: session, codexCapabilities: codexCapabilities,
            providerCapabilities: providerCapabilities, providerUsage: providerUsage,
            codexTokenUsage: shownCodexTokenUsage,
            entries: entries, isAttached: isProviderAttached)
    }

    @ViewBuilder
    private func railHost(isRaised: Bool) -> some View {
        if let railServices {
            let options = railOptions
            SessionRailHost(
                services: railServices, session: session, entries: entries,
                codexPlan: codexTaskState?.thread?.turns.last(where: { $0.plan != nil })?.plan,
                codexState: codexTaskState,
                codexChanges: codexChanges,
                options: options,
                connectors: ComposerConnectorList.make(options.connectors, connectors: composerConnectors?.records ?? [],
                                                       taskState: composerConnectors?.taskState ?? { _ in .on },
                                                       standInServerNames: composerConnectors?.standInServerNames ?? []),
                folds: $workspaceState.railFolds,
                actions: railActions(options: options),
                isRaised: isRaised,
                panelBrowserKey: TaskSurfaceNavigationProjection.browserKey(inTab: panelState.trailingSurfaceID))
        }
    }

    private func railActions(options: ComposerSessionOptions) -> SessionRailActions {
        let isRunning = session.status == .running || session.status == .waitingForApproval
        return SessionRailActions(
            onChoose: { composerActions.apply($0) },
            onPrepareSettings: composerActions.prepareProviderSettings,
            chooseAccount: railServices?.chooseAccount,
            compact: .make(options: options, actions: promptActions, isRunning: isRunning,
                           isAttached: isProviderAttached),
            connectors: composerConnectors,
            refreshConnectors: composerActions.refreshConnectors,
            backgroundTasks: activityActions,
            openTaskOutput: session.harness == .claudeCode ? { activity in
                workspaceState.showPanelDetail(.claudeTaskOutput(activityID: activity.id, title: activity.title))
            } : nil,
            terminals: railTerminalActions,
            agents: railAgentActions,
            openBrowser: { showBrowserTab(railServices?.agents.browserPreviewTab()?.key) },
            openChanges: { openSurface(.diff) },
            pullRequest: railPullRequestActions)
    }

    // MARK: Agents and background work in the rail

    /// The Agents card's controls: a row opens the agent's conversation beside the task (a Claude Code
    /// subagent in its subtask panel), or goes to a child task; its requests answer as the
    /// conversation's do.
    private var railAgentActions: SessionRailAgentActions? {
        guard let railServices else { return nil }
        let subtasks = activityActions
        return SessionRailAgentActions(
            open: { agent in
                switch agent.kind {
                case let .harnessSubtask(activity): subtasks?.open(activity)
                case let .codexThread(threadID):
                    workspaceState.showPanelDetail(.codexThread(threadID, title: agent.title))
                case let .yardletAgent(agentID?, _):
                    workspaceState.showPanelDetail(.agentRun(agentID, title: agent.title))
                case .yardletAgent(nil, _): break
                case let .childTask(id): railServices.agents.openTask(id)
                }
            },
            stop: { agent in
                switch agent.kind {
                case let .harnessSubtask(activity): subtasks?.stop?(activity)
                case let .yardletAgent(agentID?, _):
                    if let run = railServices.agents.agentRun(agentID) { railServices.agents.stopAgentRun(run) }
                default: break
                }
            },
            isStopping: { agent in
                if case let .harnessSubtask(activity) = agent.kind { return stoppingSubtaskIDs.contains(activity.id) }
                return false
            },
            requests: conversationActions,
            childRequests: { id in railServices.agents.childRequests(id) })
    }

    /// Codex's background terminals: a row opens its output beside the task, and stops it.
    private var railTerminalActions: SessionRailTerminalActions? {
        guard session.harness == .codex, let railServices, let stop = railServices.agents.stopTerminal,
              let stopAll = railServices.agents.stopAllTerminals else { return nil }
        return SessionRailTerminalActions(
            open: { terminal in
                workspaceState.showPanelDetail(.codexTerminal(processID: terminal.processID, itemID: terminal.itemID,
                                                              title: terminal.command))
            },
            stop: { terminal in
                stoppingTerminalIDs.insert(terminal.id)
                Task {
                    do { try await stop(terminal) } catch { stoppingTerminalIDs.remove(terminal.id) }
                }
            },
            stopAll: { Task { try? await stopAll() } },
            isStopping: { stoppingTerminalIDs.contains($0) })
    }

    @ViewBuilder
    private func detailPane(_ detail: TaskPanelDetail) -> some View {
        switch detail {
        case let .agentRun(id, title):
            AgentRunPane(title: title, run: railServices?.agents.agentRun(id),
                         kept: railServices?.agents.agentRun(id) == nil ? railServices?.agents.keptAgentRun(id) : nil,
                         workspaceURL: session.workspaceURL, actions: conversationActions.answeringRequestsOnly,
                         onStop: railServices.map { services in { services.agents.stopAgentRun($0) } },
                         onClose: workspaceState.closePanelDetail)
                .id(id)
        case let .codexThread(threadID, title):
            CodexChildThreadPane(
                threadID: threadID, title: title, workspaceURL: session.workspaceURL,
                refreshKey: "\(codexTaskState?.activeTurnID ?? "")|\(codexTaskState?.thread?.turns.last?.items.count ?? 0)",
                load: { [railServices] in
                    guard let railServices else {
                        throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
                    }
                    return try await railServices.agents.readCodexThread(threadID)
                },
                onClose: workspaceState.closePanelDetail)
                .id(threadID)
        case let .claudeTaskOutput(activityID, title):
            let activity = runningOrLatestActivity(activityID)
            BackgroundOutputPane(
                title: title, workspaceURL: session.workspaceURL,
                isRunning: activity.map { isRunningActivity($0.id) } ?? false,
                read: { [railServices] in
                    guard let activity, let output = await railServices?.agents.readTaskOutput(activity) else {
                        return activity?.output.map { ($0, false) }
                    }
                    return (output.text, output.isTruncated)
                },
                onClose: workspaceState.closePanelDetail)
                .id(activityID)
        case let .codexTerminal(processID, itemID, title):
            let output = codexCommandOutput(itemID)
            BackgroundOutputPane(
                title: title, workspaceURL: session.workspaceURL, isRunning: !stoppingTerminalIDs.contains(processID),
                read: { output.map { ($0, false) } ?? ("", false) },
                onClose: workspaceState.closePanelDetail)
                .id(processID)
        }
    }

    private func runningOrLatestActivity(_ id: String) -> HarnessActivity? {
        entries.compactMap { entry -> HarnessActivity? in
            if case let .activity(activity, _) = entry.content, activity.id == id { return activity }
            return nil
        }.last
    }

    private func isRunningActivity(_ id: String) -> Bool {
        entries.contains { entry in
            if case let .activity(activity, .running) = entry.content { return activity.id == id }
            return false
        }
    }

    /// What a Codex command item printed, as the thread holds it.
    private func codexCommandOutput(_ itemID: String) -> String? {
        for turn in (codexTaskState?.thread?.turns ?? []).reversed() {
            for item in turn.items where item.id == itemID {
                if case let .commandExecution(command) = item.content { return command.aggregatedOutput }
            }
        }
        return nil
    }

    /// The Changes card's pull request controls, through the app's `PullRequestDetailCenter`.
    private var railPullRequestActions: SessionRailPullRequestActions? {
        guard let details = railServices?.details else { return nil }
        let id = session.id
        return SessionRailPullRequestActions(
            refresh: { Task { await details.refresh(id) } },
            loadLog: { check in Task { await details.loadLog(taskID: id, check: check) } },
            closeLog: { details.closeLog(taskID: id, check: $0) },
            rerunFailed: { checks in Task { await details.rerunFailed(taskID: id, checks: checks) } },
            requestMerge: { details.requestMerge(taskID: id, $0) },
            confirmMerge: { Task { await details.confirmMerge(taskID: id) } },
            cancelMerge: { details.cancelMerge(taskID: id) },
            setAutoFix: { details.setAutoFix($0, taskID: id) },
            draftFix: { draftIntoComposer($0) })
    }

    /// "Fix CI" puts its request in the composer for the person to send; what they had typed stays,
    /// with the request after it.
    private func draftIntoComposer(_ text: String) {
        let typed = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        composerDraft.text = typed.isEmpty ? text : composerDraft.text + "\n\n" + text
        workspaceState.keyboardFocus.move(to: .chat)
    }

    private var selectedSubtask: HarnessActivity? {
        entries.compactMap { entry -> HarnessActivity? in
            if case let .activity(activity, _) = entry.content, activity.id == selectedSubtaskID { return activity }
            return nil
        }.last
    }

    private var activityActions: HarnessActivityActions? {
        guard session.harness == .claudeCode, conversationActions.readSubtask != nil else { return nil }
        var stop: (@MainActor @Sendable (HarnessActivity) -> Void)?
        if isProviderAttached && conversationActions.stopSubtask != nil { stop = { activity in stopSubtask(activity) } }
        return HarnessActivityActions(
            open: { activity in
                selectedSubtaskID = activity.id
                guard !conversationOnly else { return }
                if panelState.trailingSurfaceID != "subtask" { subtaskReturnSurfaceID = panelState.trailingSurfaceID }
                panelState.trailingSurfaceID = "subtask"
            },
            stop: stop,
            isStopping: { stoppingSubtaskIDs.contains($0) },
            error: { subtaskErrors[$0] }
        )
    }

    private func stopSubtask(_ activity: HarnessActivity) {
        guard !stoppingSubtaskIDs.contains(activity.id), let stop = conversationActions.stopSubtask else { return }
        stoppingSubtaskIDs.insert(activity.id)
        subtaskErrors.removeValue(forKey: activity.id)
        Task {
            do { try await stop(activity) }
            catch {
                stoppingSubtaskIDs.remove(activity.id)
                subtaskErrors[activity.id] = error.localizedDescription
            }
        }
    }

    private func clearSubtask() {
        selectedSubtaskID = nil
        stoppingSubtaskIDs.removeAll()
        subtaskErrors.removeAll()
        subtaskReturnSurfaceID = nil
        if panelState.trailingSurfaceID == "subtask" { panelState.trailingSurfaceID = nil }
    }

    /// Closing a subtask returns the side panel to the tab it covered, or hides the panel again.
    private func returnFromSubtask() {
        let returnID = subtaskReturnSurfaceID.flatMap {
            panelState.trailingTabs.contains($0) || $0 == TaskSurfaceNavigationProjection.launcherID ? $0 : nil
        }
        subtaskReturnSurfaceID = nil
        guard panelState.trailingSurfaceID == "subtask" else { return }
        panelState.trailingSurfaceID = returnID
    }

    private func subtaskPane(_ activity: HarnessActivity,
        reader: @escaping @MainActor @Sendable (HarnessActivity) async throws -> HarnessSubtaskTranscript
    ) -> some View {
        HarnessSubtaskPane(activity: activity, session: session,
            readingPosition: workspaceState.subtaskReading(for:
                "\(session.providerSessionID ?? "")|\(session.connection?.homePath ?? "native")|\(activity.id)"),
            // The child conversation is read only: editing or restoring files from it would act on
            // the parent task, so it gets no rewind actions, no subtask controls and answers no
            // request. Limit notices still read the parent's state.
            actions: conversationActions.readOnlyChild,
            load: { try await reader(activity) },
            onClose: {
                selectedSubtaskID = nil
                if !conversationOnly { returnFromSubtask() }
            })
            .id(activity.id)
    }

    @ViewBuilder
    private func auxiliarySurface(_ surface: TaskSurface) -> some View {
        switch surface {
        case .chat:
            EmptyView()
        case .diff:
            DiffPane(
                workspaceURL: session.workspaceURL,
                additionalRootURLs: session.additionalRootURLs,
                review: $workspaceState.review,
                codexChanges: codexChanges,
                lastTurn: presentationPolicy.usesCodexTimeline ? .offered(codexLastTurn) : transcriptLastTurn,
                comments: Binding(get: { composerDraft.diffComments }, set: { composerDraft.diffComments = $0 }),
                onClose: { closeSidePanelTab(TaskSurface.diff.rawValue) }
            )
            .id(session.id)
        case .terminal:
            // The task's workspace keeps the shell: a shell the new-task screen opened goes on here.
            let _ = workspaceState.terminalRevision
            let shell = workspaceState.terminal(in: session.workspaceURL, launch: terminalShellLaunch, taskID: session.id)
            TerminalPane(
                session: shell,
                handoff: workspaceState.terminalHandoff,
                startsAutomatically: workspaceState.terminalStartRequested,
                folder: TerminalFolderContext(folders: [session.workspaceURL] + session.additionalRootURLs,
                                              restart: { workspaceState.restartTerminal() }),
                onHandoffDone: { workspaceState.finishTerminalHandoff($0) },
                onClose: closeTerminal
            )
            .id(ObjectIdentifier(shell))
        case .browser:
            // Each browser tab is a side-panel tab of its own (`browserTabPane`).
            EmptyView()
        }
    }

    /// One of the task's browser tabs. Bundles built with CEF show Chromium; a plain `swift run` build
    /// keeps a WebKit preview page per tab.
    @ViewBuilder
    private func browserTabPane(_ key: UUID) -> some View {
        if let client = workspaceState.browserClient {
            BrowserHostPane(
                session: session.id, key: key, workspace: workspaceState, client: client,
                workspaceURL: session.workspaceURL,
                onNewTab: openNewBrowserTab,
                onCloseTab: { closeSidePanelTab(TaskSurfaceNavigationProjection.browserTabID($0)) },
                onShowTab: { showSidePanelTab(TaskSurfaceNavigationProjection.browserTabID($0)) },
                onPickElement: { composerDraft.browserComments.append($0) }
            )
            // The same pane shows the next browser tab, so the page keeps the keyboard.
            .id(session.id)
        } else {
            BrowserPane(
                workspaceURL: session.workspaceURL,
                model: workspaceState.browserTabs.preview(for: key),
                onClose: { closeSidePanelTab(TaskSurfaceNavigationProjection.browserTabID(key)) }
            )
            .id(key)
        }
    }

    private func openSurface(_ surface: TaskSurface) {
        if surface == .terminal { panelState.isTerminalPresented = true }
        else if surface == .browser { return showBrowserTab(nil) }
        else { panelState.trailingSurfaceID = surface.rawValue }
        workspaceState.keyboardFocus.move(to: .destination(for: surface, panels: panelState))
    }

    /// A browser tab of the task: `key`'s, else the one used last, else a new one.
    private func showBrowserTab(_ key: UUID?) {
        let id = key.map(TaskSurfaceNavigationProjection.browserTabID).flatMap { panelState.trailingTabs.contains($0) ? $0 : nil }
            ?? TaskSurfaceNavigationProjection.latestBrowserTab(in: panelState)
        if let id { showSidePanelTab(id) } else { openNewBrowserTab() }
    }

    /// The launcher's and the + menu's Browser, and ⌘T on a page: a new browser tab, as the Codex app's
    /// Browser always opens one, with its address field ready.
    private func openNewBrowserTab() {
        guard workspaceState.openBrowserTab() != nil else { return NSSound.beep() }
        workspaceState.keyboardFocus.move(to: .browser)
    }

    /// A page of the task the launcher offers, in a new browser tab, as its Browser opens one.
    private func openLauncherPage(_ address: String) {
        guard let url = URL(string: address), workspaceState.openBrowserPage(url) else { return NSSound.beep() }
        workspaceState.keyboardFocus.move(to: .browser)
    }

    /// A web link from the conversation in a new browser tab of the task, shown, with the panel open. A
    /// task with no room for another tab opens it in the default browser.
    private func openInTaskBrowser(_ url: URL) {
        guard workspaceState.openBrowserPage(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        workspaceState.keyboardFocus.move(to: .browser)
    }

    /// "Run in terminal" on any harness's command card: the task's terminal opens and runs it.
    private func runInTerminal(_ command: String) {
        workspaceState.handOffToTerminal(command)
        openSurface(.terminal)
    }

    private var sidePanelNavigation: WorkSurfaceNavigation {
        let tasks = sidePanelTasks
        return WorkSurfaceNavigation(
            tabs: panelState.trailingTabs.compactMap { id in
                if let taskID = TaskSurfaceNavigationProjection.taskID(inTab: id) {
                    return tasks?.record(taskID).map { TaskSidePanelTabs.taskTab($0) }
                }
                return TaskSidePanelTabs.tab(id, selectedFilePath: workspaceState.files.preferences.selectedPath,
                                             browserTabs: workspaceState.browserTabs)
            },
            activeID: panelState.trailingSurfaceID,
            choices: sidePanelChoices,
            taskChoices: { tasks?.choiceTabs(limit: SidePanelTaskServices.menuCount) ?? [] },
            select: { id in showSidePanelTab(id) },
            open: { id in openSidePanel(id) },
            closeTab: { id in closeSidePanelTab(id) },
            closeTabs: { ids in closeSidePanelTabs(ids) },
            closePanel: closeTrailingSurface,
            browserMenu: .make(for: workspaceState),
            owner: session.id
        )
    }

    /// The launcher's and the + menu's choices. Review is left out, as the Codex app leaves Changes
    /// out, once no repository was found for the task's folders and no turn reported its changes.
    private var sidePanelChoices: [WorkSurfaceTab] {
        var offersReview = workspaceState.hasRepository
        if offersReview == false {
            let lastTurn = presentationPolicy.usesCodexTimeline ? .offered(codexLastTurn) : transcriptLastTurn
            if lastTurn.diff != nil { offersReview = true }
        }
        return TaskSidePanelTabs.choices(canOpenSideChat: onOpenSideChat != nil, offersReview: offersReview)
    }

    /// A tab in the strip only shows its panel; it never starts a side chat or a shell.
    private func showSidePanelTab(_ id: String) {
        panelState = TaskSurfaceNavigationProjection.showing(id, in: panelState)
        workspaceState.keyboardFocus.move(to: .visibleContent(in: panelState))
    }

    private func openSidePanel(_ id: String) {
        switch id {
        case "files", TaskSurfaceNavigationProjection.launcherID:
            showSidePanelTab(id)
        case "sideChat":
            onOpenSideChat?()
        case TaskSurfaceNavigationProjection.browserChoiceID:
            openNewBrowserTab()
        case TaskSurface.terminal.rawValue:
            // The terminal opens below the conversation; a launcher it was chosen from has done its job.
            if panelState.trailingSurfaceID == TaskSurfaceNavigationProjection.launcherID {
                panelState = TaskSurfaceNavigationProjection.closingTrailingTab(
                    TaskSurfaceNavigationProjection.launcherID, in: panelState)
            }
            openSurface(.terminal)
        default:
            if TaskSurfaceNavigationProjection.taskID(inTab: id) != nil { showSidePanelTab(id) }
            else if let surface = TaskSurface(rawValue: id) { openSurface(surface) }
        }
    }

    private func closeSidePanelTab(_ id: String) {
        closeSidePanelTabs([id])
    }

    /// Closing a browser tab closes its page; the panel moves to the tab used before, as for any tab.
    private func closeSidePanelTabs(_ ids: [String]) {
        workspaceState.closeSidePanelTabs(ids)
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .visibleContent(in: workspaceState.panels))
    }

    private func closeTrailingSurface() {
        panelState.trailingSurfaceID = nil
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .destination(for: .browser, panels: panelState))
    }

    private func closeTerminal() {
        panelState.isTerminalPresented = false
        focusedSurface.wrappedValue = nil
        workspaceState.keyboardFocus.move(to: .destination(for: .terminal, panels: panelState))
    }

    private var canStartCodexTurn: Bool {
        session.status != .running && session.status != .waitingForApproval
            && codexTaskState?.activeTurnID == nil
            && composerDraft.editState == nil && codexQueue.isEmpty
    }

    private var codexChanges: [CodexChangeHandoff] {
        guard presentationPolicy.usesCodexTimeline, let codexTaskState else { return [] }
        return CodexWorkSurfaceProjection.changes(
            from: codexTaskState,
            workspaceURL: session.workspaceURL
        )
    }

    private var codexLastTurn: CodexLastTurnDiff? {
        guard let codexTaskState else { return nil }
        return CodexWorkSurfaceProjection.lastTurnDiff(from: codexTaskState, workspaceURL: session.workspaceURL)
    }

    /// Another harness offers Last turn once its calls report the file changes they made (D8).
    private var transcriptLastTurn: ReviewLastTurn {
        ReviewLastTurn.transcript(entries, harness: session.harness,
                                  isRunning: session.status == .running || session.status == .waitingForApproval,
                                  workspaceURL: session.workspaceURL)
    }

    private var presentationPolicy: HarnessPresentationPolicy {
        HarnessPresentationPolicy(harness: session.harness)
    }
}


/// A task's conversation, drawn by the one conversation renderer (`ConversationTimeline`).
///
/// Every Codex conversation is one `ConversationTimeline` (plan M6, M7). Its source is the thread
/// once the thread has turns, and the task's transcript before that (the sent message, or the
/// detached snapshot). The view stays the same view when the source changes, so following and
/// scrolling go on, and the task reads one bookmark, `codexReading`; the transcript bookmark it kept
/// before is read once and folded into it. Every other harness's conversation (Claude Code in M9,
/// the rest in M10) is the same renderer, in the same look (M12f), reading `transcriptReading`,
/// whose row places the renderer reads as the turns that hold them.
struct TaskConversationView: View {
    let harness: HarnessKind
    let workspaceURL: URL
    let entries: [TranscriptEntry]
    var sessionStatus: SessionStatus = .ready
    var latestTurnIsComplete = false
    var codexTaskState: CodexTaskState? = nil
    var codexHistorySelection: CodexHistorySearchSelection? = nil
    /// The provider's session: for Codex, the thread a detached snapshot was flattened from.
    var providerSessionID: String? = nil
    /// The task's reading positions: the shared transcript's and the Codex timeline's.
    var transcriptReading: TranscriptReadingPosition? = nil
    var codexReading: TranscriptReadingPosition? = nil
    var actions = ConversationActions()
    /// How many of the latest turns the renderer draws at first (D11); a benchmark draws every turn
    /// to measure what the window saves.
    var turnWindowCount = ConversationTurnWindow.initialTurnCount
    /// The task's saved conversation is being read from the provider's own history: until it
    /// arrives, a conversation with nothing to show says it is loading.
    var isReadingSavedConversation = false
    /// The task, for the blank-viewport log (`ConversationBlankViewportLog`).
    var diagnosticID: String? = nil
    /// What the task keeps of its conversation between the times it is shown.
    var renderState: ConversationRenderState? = nil

    var body: some View {
        if HarnessPresentationPolicy(harness: harness).usesCodexTimeline {
            let codexThread = codexTaskState?.thread?.turns.isEmpty == false ? codexTaskState : nil
            ConversationTimeline(
                source: codexThread.map {
                    .codex($0, workspaceURL: workspaceURL, historySelection: codexHistorySelection)
                } ?? .transcript(
                    entries: entries, harness: harness, status: sessionStatus,
                    latestTurnIsComplete: latestTurnIsComplete
                ),
                snapshotThreadID: providerSessionID,
                readingPosition: codexReading,
                earlierReadingPosition: transcriptReading,
                actions: actions,
                turnWindowCount: turnWindowCount,
                isLoading: isReadingSavedConversation,
                diagnosticID: diagnosticID,
                renderState: renderState
            )
        } else {
            TranscriptConversationView(
                harness: harness,
                entries: entries,
                latestTurnIsComplete: latestTurnIsComplete,
                sessionStatus: sessionStatus,
                readingPosition: transcriptReading,
                actions: actions,
                placement: .task,
                turnWindowCount: turnWindowCount,
                isLoading: isReadingSavedConversation,
                diagnosticID: diagnosticID,
                renderState: renderState
            )
        }
    }
}
