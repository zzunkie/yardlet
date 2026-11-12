import AppKit
import SwiftUI

/// The task composer, one for every harness. What differs between harnesses — the session
/// controls' choices, the command list, the follow-up queue, bash mode and the send path — comes
/// from `ComposerSessionOptions`; this view reads it and never compares harnesses. The editing
/// (text, chips, the typed `/` and `@` lists, paste and drop, bash mode) is `ComposerEditor`'s,
/// shared with the new-task composer; this view adds the queue, the bottom row and the sends.
struct PromptComposer: View {
    private enum ComposerMenu: Hashable {
        case attachments
        case commands
        case connectors
        case queueOrSteer
    }

    private enum ComposerFocus: Hashable {
        case attachmentsTrigger
        case commandSearch
        case queueOrSteerTrigger
        case queueAction
        case steerAction
    }

    @Bindable var composerDraft: TaskComposerDraft
    let skills: [CodexSkillSummary]
    let modes: [CodexCollaborationPreset]
    let selectedModeID: CodexCollaborationPreset.ID?
    let modelCatalog: CodexModelCatalog
    let providerSession: SessionRecord?
    let isProviderAttached: Bool
    let isRunning: Bool
    let canSteer: Bool
    let prefilledDraft: CodexComposerDraft?
    let prefilledDraftID: UUID?
    /// The task's follow-up queue: Codex's, or Claude's, whose sent messages Claude Code holds
    /// until it reads them.
    let codexQueue: [CodexQueuedSubmission]
    /// The queue's messages the person wrote, without the ones other tasks sent.
    private var personQueue: [CodexQueuedSubmission] {
        codexQueue.filter { !$0.isFromAnotherTask }
    }
    let isCodexQueuePaused: Bool
    /// The task's folders, searched by a typed `@` mention.
    let mentionRoots: [URL]
    /// What the Codex app's slash commands need from the task around this composer.
    let codexHasThread: Bool
    let codexTokenUsage: CodexThreadTokenUsage?
    let canOpenSideChat: Bool
    let workspaceURL: URL?
    let actions: ComposerActions
    /// What this harness's composer offers, read once per update.
    private let options: ComposerSessionOptions

    init(
        harness: HarnessKind,
        composerDraft: TaskComposerDraft,
        skills: [CodexSkillSummary] = [],
        modes: [CodexCollaborationPreset] = [],
        selectedModeID: CodexCollaborationPreset.ID? = nil,
        modelCatalog: CodexModelCatalog = CodexModelCatalog(),
        runLocation: CodexRunLocation = .askForApproval,
        providerSession: SessionRecord? = nil,
        providerEntries: [TranscriptEntry] = [],
        providerCapabilities: ProviderCapabilityState? = nil,
        providerUsage: HarnessProtocolUsage? = nil,
        isProviderAttached: Bool = false,
        isRunning: Bool,
        canSteer: Bool = false,
        prefilledDraft: CodexComposerDraft? = nil,
        prefilledDraftID: UUID? = nil,
        codexQueue: [CodexQueuedSubmission] = [],
        isCodexQueuePaused: Bool = false,
        mentionRoots: [URL] = [],
        codexHasThread: Bool = false,
        codexTokenUsage: CodexThreadTokenUsage? = nil,
        canOpenSideChat: Bool = false,
        workspaceURL: URL? = nil,
        actions: ComposerActions = ComposerActions()
    ) {
        _composerDraft = Bindable(composerDraft)
        self.skills = skills
        self.modes = modes
        self.selectedModeID = selectedModeID
        self.modelCatalog = modelCatalog
        self.providerSession = providerSession
        self.isProviderAttached = isProviderAttached
        self.isRunning = isRunning
        self.canSteer = canSteer
        self.prefilledDraft = prefilledDraft
        self.prefilledDraftID = prefilledDraftID
        self.codexQueue = codexQueue
        self.isCodexQueuePaused = isCodexQueuePaused
        self.mentionRoots = mentionRoots
        self.codexHasThread = codexHasThread
        self.codexTokenUsage = codexTokenUsage
        self.canOpenSideChat = canOpenSideChat
        self.workspaceURL = workspaceURL
        self.actions = actions
        var codex = CodexCapabilityState()
        codex.modelCatalog = modelCatalog
        codex.modes = modes
        codex.selectedModeID = selectedModeID
        codex.selectedRunLocation = runLocation
        codex.skills = skills
        options = ComposerSessionOptionsProjection.make(
            harness: harness, session: providerSession, codexCapabilities: codex,
            providerCapabilities: providerCapabilities, providerUsage: providerUsage,
            codexTokenUsage: codexTokenUsage, entries: providerEntries, isAttached: isProviderAttached)
    }

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var openComposerMenu: ComposerMenu?
    @State private var keyboardOpenedComposerMenu: ComposerMenu?
    @State private var requestedMenuReturn: ComposerMenu?
    @State private var commandSearch = ""
    @State private var isPreparingCommands = false
    @State private var isSelectingCommand = false
    @State private var modelPickerRequest: CodexModelPickerRequest?
    @State private var isWorkspaceGitRepository = false
    @FocusState private var isPromptFocused: Bool
    @FocusState private var focusedComposerControl: ComposerFocus?
    @Environment(\.claudeShellCommands) private var shellCommands
    @Environment(\.composerConnectors) private var yardletConnectors
    @Environment(\.taskAccountMove) private var accountMove
    /// What the send key sends while a turn runs; the key that sends the other way sends the other.
    @AppStorage(FollowUpMode.preferenceKey) private var followUpModeValue = FollowUpMode.steer.rawValue
    /// Which keys send, as the placeholder, the send button and the follow-up menu name them.
    @AppStorage(SendShortcut.preferenceKey) private var sendShortcut = SendShortcut.return
    /// Whether the empty composer shows the suggested next message as its faint text, for Tab or →.
    @AppStorage(NextMessageSuggestionPreference.key) private var showsNextMessageSuggestions = true

    private var followUpMode: FollowUpMode {
        // A task about to move to another account queues on Return, to send after the move.
        accountMove != nil ? .queue : FollowUpMode(rawValue: followUpModeValue) ?? .steer
    }

    /// The queue and steering a message typed now can take: while the turn runs, outside bash mode
    /// (a shell command runs on its own), where the window gave the composer their submit.
    private var runningFollowUp: ComposerFollowUpOptions? {
        guard isRunning, !isBashMode, let followUp = options.followUp, canSubmit(followUp.delivery) else { return nil }
        return followUp
    }

    /// The key that sends the other way while a turn runs: the follow-up setting's other way. Nil where
    /// it sends as the send key does. Where Return sends, it is ⌘Return, which in the empty composer
    /// allows a waiting tool approval as the send key does (`ComposerApprovalKey`). With the ⌘Return send
    /// shortcuts it is ⇧⌘Return, which answers none, so it is there even where it sends as the send key
    /// does: the send key in the empty composer would allow the approval.
    private var alternateSubmit: (() -> Void)? {
        let action = runningFollowUp.flatMap { $0.alternateAction(preferred: followUpMode, canSteer: canSteer) }
        let allows = sendShortcut == .return
        guard action != nil || (!allows && actions.answerApproval != nil) else { return nil }
        return {
            if allows, allowsWaitingApproval() { return }
            submit(action ?? .automatic)
        }
    }

    /// The send keys in the empty composer allow the oldest tool approval the task waits on, once
    /// (`ComposerApprovalKey`); with a draft they send it. Not in bash mode, where Return runs a command.
    private func allowsWaitingApproval() -> Bool { answersWaitingApproval(allowing: true) }

    private func answersWaitingApproval(allowing: Bool) -> Bool {
        guard isRunning, currentDraft.isEmpty, !isBashMode, let answer = actions.answerApproval else { return false }
        return answer(allowing)
    }

    /// The "+" menu's connectors: Yardlet's own, each with this task's switch, and the session's
    /// MCP servers, read-only.
    private var connectorList: ComposerConnectorList? {
        ComposerConnectorList.make(options.connectors, connectors: yardletConnectors?.records ?? [],
                                   taskState: yardletConnectors?.taskState ?? { _ in .on },
                                   standInServerNames: yardletConnectors?.standInServerNames ?? [])
    }

    /// The context window's "Compact session": Claude Code's `/compact` as the next message, or
    /// Codex's Compact command, once the turn has finished.
    private var compactAction: ComposerContextUsageDetails.Compact? {
        ComposerContextUsageDetails.Compact.make(options: options, actions: actions, isRunning: isRunning,
                                                 isAttached: isProviderAttached)
    }

    /// Bash mode exists where the harness has it and the window can run the command.
    private var bashModeAvailable: Bool {
        options.bashMode && shellCommands != nil
    }

    private var isBashMode: Bool {
        bashModeAvailable && composerDraft.isBashMode
    }

    private var isShellCommandRunning: Bool {
        bashModeAvailable && shellCommands?.isRunning == true
    }

    /// While a turn runs the placeholder says what the send keys send, as the Claude app's composer
    /// does while Claude works.
    private var promptPlaceholder: String {
        if isBashMode { return L10n.string("Enter a shell command") }
        return runningFollowUp?.runningPlaceholder(preferred: followUpMode, keys: sendShortcut) ?? options.placeholder
    }

    private func triggerFocus(for menu: ComposerMenu) -> ComposerFocus {
        switch menu {
        case .attachments: .attachmentsTrigger
        case .commands: .attachmentsTrigger
        case .connectors: .attachmentsTrigger
        case .queueOrSteer: .queueOrSteerTrigger
        }
    }

    private var isInputMenu: Bool {
        openComposerMenu == .attachments || openComposerMenu == .commands || openComposerMenu == .connectors
    }

    private func composerMenuBinding(_ menu: ComposerMenu) -> Binding<Bool> {
        Binding(
            get: { openComposerMenu == menu },
            set: { isPresented in
                if isPresented {
                    openComposerMenu = menu
                } else if openComposerMenu == menu {
                    openComposerMenu = nil
                }
            }
        )
    }

    private var inputMenuBinding: Binding<Bool> {
        Binding(
            get: { isInputMenu },
            set: { shown in
                if !shown, isInputMenu {
                    openComposerMenu = nil
                }
            }
        )
    }

    private func presentComposerMenu(_ menu: ComposerMenu) {
        keyboardOpenedComposerMenu = ParityInteraction.currentEventIsKeyboard ? menu : nil
        focusedComposerControl = nil
        openComposerMenu = menu
    }

    private func dismissComposerMenu() {
        requestedMenuReturn = openComposerMenu
        openComposerMenu = nil
    }

    /// Moves the open "+" menu to one of its lists, or back to its first page.
    private func showMenuPage(_ menu: ComposerMenu) {
        requestedMenuReturn = nil
        presentComposerMenu(menu)
    }

    /// What the "+" menu's rows do. A typed `@` still searches the task's files; there is no
    /// second button for it.
    private var plusMenuActions: ComposerPlusMenu.Actions {
        ComposerPlusMenu.Actions(
            addFiles: {
                dismissComposerMenu()
                chooseFiles()
            },
            addFolder: {
                dismissComposerMenu()
                chooseFolders()
            },
            openCommands: options.commands == nil ? nil : {
                commandSearch = ""
                showMenuPage(.commands)
                Task { await prepareCommands() }
            },
            openConnectors: connectorList == nil ? nil : { showMenuPage(.connectors) })
    }

    /// "+" → "Slash commands": the search and the list, with the way back.
    private var commandsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerMenuBackHeader(title: L10n.string("Slash commands")) { showMenuPage(.attachments) }
            TextField(L10n.string("Search commands"), text: $commandSearch)
                .textFieldStyle(.roundedBorder)
                .focused($focusedComposerControl, equals: .commandSearch)
                .onSubmit {
                    if let command = ComposerCommands.matching(providerCommands, query: commandSearch).first {
                        insertCommand(command)
                    }
                }
                .padding(.horizontal, 3)
            ComposerCommandPicker(
                commands: providerCommands, query: commandSearch, isLoading: isPreparingCommands,
                error: options.commands?.error, onSelect: insertCommand
            )
        }
        .padding(5)
        .frame(width: 340)
        .onAppear {
            if keyboardOpenedComposerMenu == .commands { focusedComposerControl = .commandSearch }
        }
        .onExitCommand { dismissComposerMenu() }
    }

    private var showsPausedCodexQueue: Bool {
        options.followUp != nil && isCodexQueuePaused && !codexQueue.isEmpty
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.composer)
#endif
        ComposerEditor(
            draft: composerDraft, placeholder: promptPlaceholder,
            accessibilityHint: isBashMode
                ? L10n.string("Bash mode. Press Escape to return to chat.")
                : runningFollowUp?.returnHint(preferred: followUpMode, keys: sendShortcut)
                    ?? L10n.format("Press %@ to send", sendShortcut.sendKeyName),
            metrics: .task(chipsTop: showsPausedCodexQueue ? 6 : 9),
            input: inputPolicy, mentionRoots: mentionRoots, commands: editorCommands,
            bashModeAvailable: bashModeAvailable,
            isCommandMenuOpen: openComposerMenu == .commands, isMenuOpen: openComposerMenu != nil,
            showsChips: !composerDraft.diffComments.isEmpty || !composerDraft.browserComments.isEmpty,
            isFocused: $isPromptFocused,
            onSubmit: { if !allowsWaitingApproval() { submit(.automatic) } },
            onAlternateSubmit: alternateSubmit,
            takeSuggestion: takeNextMessageSuggestion,
            suggestion: isBashMode ? nil : composerDraft.shownNextMessageSuggestion(
                isEnabled: showsNextMessageSuggestions, isRunning: isRunning),
            onEscape: {
                // In the home's reply, Escape is the home's: nothing the task runs stops.
                if let escape = actions.escape { escape() }
                else if isShellCommandRunning { shellCommands?.stop() }
                // A waiting tool approval is denied first, as the Codex app's Escape denies one.
                else if isRunning, actions.answerApproval?(false) == true { return }
                else if isRunning { actions.interrupt() }
                else if isBashMode { composerDraft.leaveBashMode() }
            },
            onTab: actions.tab,
            onCommandQueryChange: { old, query in
                // Opening the list reads what its commands need (Codex: Plan mode, Fast, skills).
                if options.commands?.preparesWhenListOpens == true, old == nil, query != nil {
                    Task { await prepareCommands() }
                }
            }
        ) {
            if showsPausedCodexQueue {
                ComposerQueuePausedRow(resume: actions.resumeQueue)
            }
            // Queued messages, one full-width row each above the text, as the Codex and Claude
            // apps list them: a long message shortens and its actions stay in view.
            // A message another task sent waits here only until the provider reads it; it is not
            // the person's to manage, so it shows in the conversation once read, not in this list.
            if let followUp = options.followUp, !personQueue.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(codexQueue.enumerated()).filter { !$0.element.isFromAnotherTask },
                            id: \.element.id) { index, item in
                        queueChip(item, chip: ComposerQueueChip.make(policy: followUp.policy, queue: codexQueue,
                                                                     at: index, canSend: actions.sendQueuedNow != nil),
                                  at: index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, showsPausedCodexQueue ? 6 : 8)
            }
        } chips: {
            if !composerDraft.diffComments.isEmpty {
                DiffCommentsChip(comments: composerDraft.diffComments) { composerDraft.diffComments = [] }
            }
            ForEach(composerDraft.browserComments) { comment in
                BrowserCommentChip(comment: comment, onMarkedUp: { composerDraft.replaceCapture(of: comment.id, with: $0) }) {
                    composerDraft.browserComments.removeAll { $0.id == comment.id }
                }
            }
        } footer: {
            composerFooterLayout {
                composerInputControls
                composerActionControls
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.bottom, 9)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .frame(maxWidth: ParityTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .task(id: statusRefreshKey) {
            // Detached, this rereads the settings that name the task's model and, for Codex, the
            // saved thread to show; no session or turn starts.
            if options.refreshesStatusOnAttach { await actions.refreshProviderStatus() }
        }
        .task(id: options.commands?.readsGitRepository == true ? workspaceURL : nil) {
            guard options.commands?.readsGitRepository == true, let workspaceURL else { return }
            isWorkspaceGitRepository = await Task.detached(priority: .utility) {
                CodexComposerCommands.isInsideGitRepository(workspaceURL)
            }.value
        }
        .onChange(of: inputPolicy.carriesImages, initial: true) { _, carriesImages in
            // An agent can settle its handshake while the composer already holds an image —
            // a restored draft, or one typed before the session attached. The attachment stays
            // put and the user is told, rather than the control vanishing without explanation.
            guard !carriesImages,
                  !HarnessUserInput.projecting(currentDraft).input.images.isEmpty else { return }
            composerDraft.notice = inputPolicy.attachmentRefusalNotice
        }
        .onChange(of: openComposerMenu) { old, new in
            guard let old, new == nil else { return }
            let shouldReturn = !isSelectingCommand
                && (requestedMenuReturn == old || ParityInteraction.currentEventIsKeyboard)
            isSelectingCommand = false
            requestedMenuReturn = nil
            keyboardOpenedComposerMenu = nil
            guard shouldReturn else { return }
            focusedComposerControl = nil
            DispatchQueue.main.async {
                guard openComposerMenu == nil else { return }
                focusedComposerControl = triggerFocus(for: old)
            }
        }
        .task(id: prefilledDraftID) {
            guard prefilledDraft != nil else { return }
            applyPrefilledDraft()
            // Transfer focus after the clicked error/turn action finishes dispatching.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isPromptFocused = true
        }
    }

    /// The task and whether it is attached: the session controls reread its status when either changes.
    private var statusRefreshKey: String {
        "\(providerSession?.id.uuidString ?? "")-\(isProviderAttached)"
    }

    /// One queued message: what it says, shortened to the row, then where it goes and its actions,
    /// which keep their size so a long message never pushes them out of view.
    private func queueChip(_ item: CodexQueuedSubmission, chip: ComposerQueueChip, at index: Int) -> some View {
        ComposerQueueRow(title: Self.queueTitle(item.draft), failed: item.state == .failed,
                         fromTask: TaskMessage.parse(item.draft.text) != nil, chip: chip,
                         moveUp: { actions.moveQueued?(item.id, index - 1) },
                         moveDown: { actions.moveQueued?(item.id, index + 1) },
                         retry: { actions.retryQueued?(item.id) },
                         sendNow: actions.sendQueuedNow.map { action in { action(item.id) } },
                         stopAndSend: actions.stopAndSendQueued.map { action in { action(item.id) } },
                         edit: actions.editQueued.map { action in { _ = action(item.id) } },
                         remove: { actions.removeQueued?(item.id) })
    }

    private var composerFooterLayout: AnyLayout {
        AnyLayout(ControlRowLayout(pinsTrailingActions: true))
    }

    /// `+` and `@` follow the protocol, not the harness name: every harness whose protocol
    /// carries image input keeps them, and one that cannot carry them never shows them. For a
    /// family that negotiates image input, the agent's own answer decides `+` once it arrives.
    private var inputPolicy: HarnessComposerInputPolicy {
        options.input
    }

    private var composerInputControls: some View {
        Group {
            // One "+" for everything that is added to a message, as in the Codex and Claude apps.
            if inputPolicy.showsMentionControl {
                Button {
                    presentComposerMenu(.attachments)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .focused($focusedComposerControl, equals: .attachmentsTrigger)
                // The Codex app's tooltip for its "+", which also says `@` reaches the files.
                .accessibilityLabel(L10n.string("Add files and more"))
                .help(L10n.string("Add files and more · Type @ to mention a file"))
                .popover(isPresented: inputMenuBinding) {
                    switch openComposerMenu {
                    case .commands?:
                        commandsPage
                    case .connectors?:
                        if let connectorList {
                            ComposerConnectorsMenu(
                                list: connectorList,
                                onManage: yardletConnectors?.openSettings.map { open in
                                    {
                                        dismissComposerMenu()
                                        open()
                                    }
                                },
                                onAdd: yardletConnectors?.addConnector.map { add in
                                    {
                                        dismissComposerMenu()
                                        add()
                                    }
                                },
                                onSwitch: yardletConnectors?.setOn, onReconnect: yardletConnectors?.reconnect,
                                onBack: { showMenuPage(.attachments) },
                                highlightsFirstRow: keyboardOpenedComposerMenu == .connectors,
                                onDismiss: dismissComposerMenu)
                            .task { await actions.refreshConnectors() }
                        }
                    default:
                        ComposerMenuList(
                            entries: ComposerPlusMenu.entries(
                                carriesImages: inputPolicy.carriesImages, connectors: connectorList,
                                actions: plusMenuActions),
                            highlightsFirstRow: keyboardOpenedComposerMenu == .attachments,
                            onDismiss: dismissComposerMenu)
                    }
                }
            }
            ComposerSessionControls(
                options: options, placement: .leading, onChoose: { actions.apply($0) },
                onPrepare: actions.prepareProviderSettings,
                onTurnOffPlanMode: actions.runCodexCommand.map { run in { run(.planMode) } },
                onInsertSkill: insertSkill
            )
        }
    }

    private var composerActionControls: some View {
        HStack(spacing: 7) {
            ComposerSessionControls(
                options: options, placement: .trailing, modelOpenRequest: modelPickerRequest,
                onChoose: { actions.apply($0) }, onPrepare: actions.prepareProviderSettings,
                compact: compactAction
            )
            if isRunning || isShellCommandRunning {
                // A shell command runs on its own; it is not queued or steered into a turn.
                if let followUp = runningFollowUp {
                    Button {
                        presentComposerMenu(.queueOrSteer)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "text.append")
                            if !personQueue.isEmpty {
                                Text("\(personQueue.count)")
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(ParityTheme.subtleFill, in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                    .focused($focusedComposerControl, equals: .queueOrSteerTrigger)
                    .accessibilityLabel(L10n.string("Queue or steer"))
                    .accessibilityHint(followUp.returnHint(preferred: followUpMode, keys: sendShortcut))
                    // Its name, then the keys, which stay in view once the draft has text and the
                    // placeholder is gone.
                    .help("\(L10n.string("Queue or steer")) · \(followUp.runningPlaceholder(preferred: followUpMode, keys: sendShortcut))")
                    .popover(isPresented: composerMenuBinding(.queueOrSteer)) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Each row says where the message goes, as the placeholder does.
                            Button {
                                dismissComposerMenu()
                                submit(.queue)
                            } label: {
                                followUpMenuRow(FollowUpPolicy.afterTurnPhrase, systemImage: "text.append",
                                                mode: .queue, policy: followUp.policy)
                            }
                            .buttonStyle(.borderless)
                            .parityPointer()
                            .focused($focusedComposerControl, equals: .queueAction)
                            if let steer = followUp.policy.steerPhrase {
                                Button {
                                    dismissComposerMenu()
                                    submit(.steer)
                                } label: {
                                    followUpMenuRow(steer, systemImage: "arrow.turn.up.right", mode: .steer,
                                                    policy: followUp.policy)
                                }
                                .buttonStyle(.borderless)
                                .parityPointer()
                                .focused($focusedComposerControl, equals: .steerAction)
                                .disabled(!canSteer)
                            }
                        }
                        .padding(8)
                        .frame(minWidth: 150, alignment: .leading)
                        .onAppear {
                            if keyboardOpenedComposerMenu == .queueOrSteer {
                                focusedComposerControl = .queueAction
                            }
                        }
                        .onExitCommand { dismissComposerMenu() }
                    }
                }
                // Stop stops what was started last: a running shell command before the turn.
                Button {
                    if isShellCommandRunning { shellCommands?.stop() } else { actions.interrupt() }
                } label: {
                    // Send's size, so the button keeps its place when one replaces the other.
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.red, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(isShellCommandRunning ? L10n.string("Stop shell command") : L10n.string("Stop"))
                .accessibilityHint(L10n.string("Press Escape to stop the active task"))
                .help(ShortcutHelp.text(isShellCommandRunning ? L10n.string("Stop shell command") : L10n.string("Stop"),
                                        ComposerShortcut.stop))
            } else {
                ParityIconButton(
                    systemName: "arrow.up",
                    help: L10n.string("Send"),
                    isProminent: true,
                    shortcut: ComposerShortcut.send(sendShortcut),
                    action: { submit(.automatic) }
                )
                .disabled(currentDraft.isEmpty)
            }
        }
    }

    private var currentDraft: CodexComposerDraft {
        composerDraft.submission
    }

    /// A row of the queue-or-steer menu with its key: the send key for the follow-up setting's way,
    /// the key that sends the other way for the other.
    private func followUpMenuRow(_ title: String, systemImage: String, mode: FollowUpMode,
                                 policy: FollowUpPolicy) -> some View {
        // A harness that cannot steer queues on the send key.
        let returnMode = policy.steers ? followUpMode : .queue
        return ComposerFollowUpMenuRow(title: title, systemImage: systemImage,
                                       key: mode == returnMode ? sendShortcut.sendSymbol : sendShortcut.alternateSymbol)
    }

    /// A queued message's words: its request, or the count of the comments it carries alone.
    static func queueTitle(_ draft: CodexComposerDraft) -> String {
        if let message = TaskMessage.parse(draft.text) {
            return L10n.format("%@: %@", ConversationSentMessage.senderLabel(message), message.body)
        }
        if let sent = DiffCommentPrompt.parse(draft.text) {
            guard sent.request.isEmpty else { return sent.request }
            return sent.comments.isEmpty ? BrowserCommentChip.title(count: sent.browserComments.count)
                : DiffCommentsChip.title(count: sent.comments.count)
        }
        return draft.text.isEmpty ? L10n.string("Attached context") : draft.text
    }

    /// Whether the window gave this composer the submit its queue and steering take.
    private func canSubmit(_ path: ComposerSubmissionPath) -> Bool {
        switch path {
        case .codexDraft: actions.submitCodex != nil
        case .providerInput: actions.submitFollowUp != nil
        }
    }

    private func submit(_ action: CodexComposerAction) {
        let draft = currentDraft
        guard !draft.isEmpty else { return }
        if isBashMode {
            runShellCommand()
            return
        }
        if options.submission == .codexDraft, let submitCodex = actions.submitCodex {
            if composerDraft.editState == nil && !options.draftRetention.keepsDraft(afterSending: draft.text) {
                composerDraft.clear()
            }
            submitCodex(draft, action)
            return
        }
        guard action == .automatic else {
            guard options.followUp?.delivery == .providerInput, let submitFollowUp = actions.submitFollowUp else { return }
            switch inputPolicy.submission(for: draft) {
            case let .refuse(notice):
                composerDraft.notice = notice
            case let .send(input):
                // An edited message is refused by the model, which says why; the draft stays.
                if composerDraft.editState == nil { composerDraft.clear() }
                submitFollowUp(input, action)
            }
            return
        }
        // A draft restored on a harness that cannot carry its attachment is not sent silently
        // without it. The attachment stays in the composer and the user is told why.
        switch inputPolicy.submission(for: draft) {
        case let .refuse(notice):
            composerDraft.notice = notice
        case let .send(input):
            // A chat transition consumes its command only after local creation succeeds.
            // Rejected arguments/attachments and alias metadata failures retain the draft.
            if composerDraft.editState == nil && !options.draftRetention.keepsDraft(afterSending: input.text) {
                composerDraft.clear()
            }
            actions.send(input)
        }
    }

    /// The command runs on its own, whether or not a turn is running; the composer returns to chat.
    private func runShellCommand() {
        guard let shellCommands else { return }
        let command = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard composerDraft.attachments.isEmpty else {
            composerDraft.notice = L10n.string("A shell command takes plain text only, so nothing was run. Remove the attachments.")
            return
        }
        guard !shellCommands.isRunning else {
            composerDraft.notice = L10n.string("A shell command is already running")
            return
        }
        composerDraft.clear()
        shellCommands.run(command)
    }

    /// Tab in the empty composer: the suggested next message becomes the text, with the caret after
    /// it, for the person to edit or send. Nothing is sent.
    private func takeNextMessageSuggestion() -> Bool {
        guard composerDraft.takeNextMessageSuggestion(isEnabled: showsNextMessageSuggestions,
                                                      isRunning: isRunning) != nil else { return false }
        ComposerFieldEditor.placeCaret(at: nil, in: composerDraft, isFocused: $isPromptFocused)
        return true
    }

    private func applyPrefilledDraft() {
        guard let prefilledDraft else { return }
        composerDraft.restore(prefilledDraft)
        openComposerMenu = nil
    }

    /// A skill joins the next message as Codex's own skill input.
    private func insertSkill(_ skill: CodexSkillSummary) {
        composerDraft.attachments.append(.skill(name: skill.name, path: URL(filePath: skill.path)))
    }

    private var providerCommands: [ProviderComposerCommand] {
        switch options.commands?.source {
        case .codexCatalog?:
            actions.runCodexCommand == nil ? [] : CodexComposerCommands.catalog(codexCommandContext)
        case let .provider(commands)?:
            commands
        case nil:
            []
        }
    }

    private var codexCommandContext: CodexComposerCommandContext {
        let text = composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexComposerCommandContext(
            hasThread: codexHasThread, isRunning: isRunning,
            hasDraftContent: composerDraft.editState != nil
                || (!text.isEmpty && ComposerCommands.query(in: composerDraft.text) == nil),
            canOpenSideChat: canOpenSideChat, isGitRepository: isWorkspaceGitRepository, workspaceURL: workspaceURL,
            modelCatalog: modelCatalog, modes: modes, selectedModeID: selectedModeID,
            tokenUsage: codexTokenUsage, skills: skills)
    }

    /// The typed `/` list: the provider's commands or Codex's own, read when the list opens
    /// (Codex) or when a slash is typed into a detached Claude task.
    private var editorCommands: ComposerEditorCommands? {
        guard let commands = options.commands else { return nil }
        return ComposerEditorCommands(
            commands: providerCommands, isLoading: isPreparingCommands, error: commands.error,
            choose: insertCommand,
            textEdited: {
                // A restored draft does not attach a provider. An explicit slash typed into the
                // focused editor may read the session catalog, like choosing Slash commands from +.
                guard commands.readsCatalogWhenTypedDetached, !isProviderAttached, !isPreparingCommands else { return }
                Task { await prepareCommands() }
            })
    }

    private func prepareCommands() async {
        switch options.commands?.preparation {
        case .codexCommands?:
            await actions.prepareCodexCommands()
        case .providerSettings?:
            guard !isPreparingCommands else { return }
            isPreparingCommands = true
            defer { isPreparingCommands = false }
            if isProviderAttached { await actions.refreshProviderStatus() }
            else { await actions.prepareProviderSettings() }
        case nil:
            return
        }
    }

    private func insertCommand(_ command: ProviderComposerCommand) {
        isSelectingCommand = openComposerMenu != nil
        requestedMenuReturn = nil
        openComposerMenu = nil
        if options.commands?.selection == .runCodexCommand,
           let codexCommand = CodexComposerCommands.command(for: command, in: codexCommandContext) {
            runCodexCommand(codexCommand)
            return
        }
        ComposerFieldEditor.insert(command, into: composerDraft, isFocused: $isPromptFocused)
    }

    /// As in the Codex app, a chosen command takes the typed `/name` out of the draft and runs;
    /// nothing is sent, and other draft content (attachments, text when chosen from +) stays.
    private func runCodexCommand(_ command: CodexComposerCommand) {
        if ComposerCommands.query(in: composerDraft.text) != nil { composerDraft.text = "" }
        switch command {
        case .model:
            modelPickerRequest = CodexModelPickerRequest(list: .models)
        case .reasoning:
            modelPickerRequest = CodexModelPickerRequest(list: .effort)
        case let .skill(_, path):
            if let skill = skills.first(where: { $0.path == path }) { insertSkill(skill) }
            isPromptFocused = true
        default:
            // Return keeps the editor; a sheet, alert, side chat or other task takes focus itself.
            isPromptFocused = true
            actions.runCodexCommand?(command)
        }
    }

    /// "Add files or photos": an image (or, for Codex, audio) the harness carries joins as an
    /// attachment, as the earlier media picker added it; any other file joins as context, as the
    /// earlier `@` button added it.
    private func chooseFiles() {
        if let chosen = ComposerFilePicker.chooseFiles(policy: inputPolicy) { composerDraft.add(chosen: chosen) }
    }

    /// What "Add files or photos" adds for each chosen file.
    static func addedInputs(_ urls: [URL], policy: HarnessComposerInputPolicy) -> [CodexUserInput] {
        urls.compactMap { url in
            // Only Codex has an audio envelope, so only its picker attaches one; elsewhere an audio
            // file is context, a path the model can read, never an attachment the send refuses.
            let kind = CodexUserInput.localAttachmentKind(for: url)
            if (kind == .image && policy.carriesImages) || (kind == .audio && policy.acceptsAudioAttachments),
               let attachment = CodexUserInput.localAttachment(for: url) {
                return attachment
            }
            return CodexUserInput.localMention(for: url)
        }
    }

    /// "Add folder": folders join as context, as the earlier `@` button added them.
    private func chooseFolders() {
        if let chosen = ComposerFilePicker.chooseFolders() { composerDraft.add(chosen: chosen) }
    }
}

/// A composer compared `.equatable()` is drawn again only when what it shows or offers changed. Its
/// task surface is drawn again for every fragment a streaming conversation publishes and hands the
/// composer fresh actions each time; the actions are bound to the same task (`providerSession`), so
/// they are left out. The draft is compared by identity: its own changes redraw the composer
/// through Observation.
extension PromptComposer: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.composerDraft === rhs.composerDraft && lhs.options == rhs.options
            && lhs.providerSession == rhs.providerSession && lhs.isProviderAttached == rhs.isProviderAttached
            && lhs.isRunning == rhs.isRunning && lhs.canSteer == rhs.canSteer
            && lhs.skills == rhs.skills && lhs.modes == rhs.modes && lhs.selectedModeID == rhs.selectedModeID
            && lhs.modelCatalog == rhs.modelCatalog
            && lhs.prefilledDraft == rhs.prefilledDraft && lhs.prefilledDraftID == rhs.prefilledDraftID
            && lhs.codexQueue == rhs.codexQueue && lhs.isCodexQueuePaused == rhs.isCodexQueuePaused
            && lhs.mentionRoots == rhs.mentionRoots && lhs.codexHasThread == rhs.codexHasThread
            && lhs.codexTokenUsage == rhs.codexTokenUsage && lhs.canOpenSideChat == rhs.canOpenSideChat
            && lhs.workspaceURL == rhs.workspaceURL && lhs.actions.shape == rhs.actions.shape
    }
}

/// A row of the composer's queue-or-steer menu with its key at the end, as a menu shows a shortcut.
struct ComposerFollowUpMenuRow: View {
    let title: String
    let systemImage: String
    /// The key that sends this way, as a menu writes it (`SendShortcut.sendSymbol`, `alternateSymbol`).
    let key: String

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 0)
            Text(verbatim: key)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

extension ComposerContextUsageDetails.Compact {
    /// The context window's "Compact session": Claude Code's `/compact` as the next message, or
    /// Codex's Compact command, once the turn has finished. The composer's ring and the session
    /// rail's Context card offer the same.
    @MainActor
    static func make(options: ComposerSessionOptions, actions: ComposerActions, isRunning: Bool,
                     isAttached: Bool) -> ComposerContextUsageDetails.Compact? {
        let run: () -> Void
        switch options.compact {
        case let .providerCommand(command)?:
            run = { actions.send(HarnessUserInput(text: command)) }
        case .codexCommand?:
            guard let runCodexCommand = actions.runCodexCommand else { return nil }
            run = { runCodexCommand(.compact) }
        case nil:
            return nil
        }
        return ComposerContextUsageDetails.Compact(
            isAvailable: !isRunning && isAttached,
            unavailableReason: isRunning
                ? L10n.format("Available when %@ finishes this turn", options.harnessName)
                : L10n.string("Available when reconnected"),
            run: run
        )
    }
}
