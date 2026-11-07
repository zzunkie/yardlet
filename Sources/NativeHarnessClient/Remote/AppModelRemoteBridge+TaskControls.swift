import Foundation
import Observation
import YardletRemote

/// A task's controls for another device (docs/REMOTE_PROTOCOL.md §15.23): the settings its composer's bottom row shows,
/// the slash commands it offers that may run from elsewhere, and the edit and fork of its turns. Each reads what the
/// Mac's composer and turn read (`ComposerSessionOptionsProjection`, `ConversationTurnActions`) and acts through the
/// paths their menus take (`MainWindow.composerActions`, `conversationActions`).
extension AppModelRemoteBridge {
    // MARK: - Settings

    /// The task composer's options as its bottom row reads them (`TaskSurface`). The context ring is not a setting and
    /// is left out; a waiting request shows from the task's own state on the other device.
    static func composerOptions(of session: SessionRecord, in model: AppModel) -> ComposerSessionOptions {
        ComposerSessionOptionsProjection.make(
            harness: session.harness, session: session, codexCapabilities: model.composerCodexCapabilities(for: session),
            providerCapabilities: model.composerProviderCapabilities(for: session), providerUsage: nil,
            isAttached: model.isAttached(session.id))
    }

    /// The bottom row's settings in its order: the mode (or Codex's Plan indicator, while Plan mode is on), the
    /// permissions, and the model menu's model, effort and speed, each with its choices now. A choice the Mac asks about
    /// first carries the Mac's words for it.
    static func taskSettings(_ options: ComposerSessionOptions) -> [RemoteSetting] {
        var settings: [RemoteSetting] = []
        switch options.mode {
        case .planIndicator?:
            settings.append(RemoteSetting(id: "planMode", name: L10n.string("Plan mode"), value: "plan", choices: [],
                                          role: "plan"))
        case let .selector(selector, canChoose, _)?:
            settings.append(setting(selector, role: "mode", prepares: !canChoose))
        case nil:
            break
        }
        if let permission = options.permission {
            var setting: RemoteSetting
            if let selector = permission.selector {
                setting = self.setting(selector, role: "permission", prepares: !permission.canChoose,
                                       confirmations: permission.confirmations)
            } else {
                setting = RemoteSetting(id: "permissions", name: L10n.string("Permissions"), value: "", choices: [],
                                        role: "permission")
                setting.title = RemoteText.short(permission.title, RemoteText.titleLimit)
            }
            setting.note = RemoteText.short(permission.explanation?.text, RemoteText.detailLimit)
            if permission.isElevated { setting.elevated = true }
            settings.append(setting)
        }
        if let menu = options.model?.menu {
            for (selector, role) in [(menu.model, "model"), (menu.effort, "effort"), (menu.speed, "speed")] {
                if let selector { settings.append(setting(selector, role: role, prepares: !menu.canChoose)) }
            }
        }
        if let limit = options.contextLimit {
            var setting = setting(limit.selector, role: "contextLimit", prepares: false)
            setting.note = RemoteText.short(limit.note, RemoteText.detailLimit)
            settings.append(setting)
        }
        return settings
    }

    private static func setting(_ selector: ProviderCapabilitySelector, role: String, prepares: Bool,
                                confirmations: [String: ComposerPermissionSlot.Confirmation] = [:]) -> RemoteSetting {
        var setting = RemoteSetting(
            id: selector.id, name: RemoteText.short(selector.name, RemoteText.titleLimit) ?? selector.id,
            value: selector.currentValue,
            choices: selector.choices.map { choice in
                RemoteSetting.Choice(
                    value: choice.value, name: RemoteText.short(choice.name, RemoteText.titleLimit) ?? choice.value,
                    description: RemoteText.short(choice.description, RemoteText.detailLimit),
                    confirm: confirmations[choice.value].map {
                        RemoteSetting.Confirmation(title: $0.title, message: $0.message, button: $0.confirm)
                    })
            },
            role: role)
        if prepares { setting.prepare = true }
        return setting
    }

    func taskSettings(taskID: String, prepare: Bool) async -> Result<[RemoteSetting], RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        if prepare {
            // As opening a menu that cannot choose yet does: a detached task reads its saved settings, or Codex its
            // model list. No turn starts.
            await RemoteServer.waitAtMost(10) { @MainActor in
                switch ComposerSessionOptionsProjection.wiring(for: session.harness).settings {
                case .codexModels: await model.loadCodexModels(for: session)
                case .providerCapabilities: await model.loadProviderCapabilities(for: session)
                }
            }
        }
        guard let current = self.session(taskID) else { return .failure(RemoteError(.notFound)) }
        return .success(watchSettings(of: current.id))
    }

    func setTaskSetting(taskID: String, setting id: String, value: String,
                        confirmed: Bool) async -> Result<[RemoteSetting], RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        let options = Self.composerOptions(of: session, in: model)
        // The control that holds the setting, and the path its choices take.
        var found: (selector: ProviderCapabilitySelector, canChoose: Bool, apply: ComposerApplyPath,
                    confirmations: [String: ComposerPermissionSlot.Confirmation])?
        if case let .selector(selector, canChoose, apply)? = options.mode, selector.id == id {
            found = (selector, canChoose, apply, [:])
        } else if let permission = options.permission, let selector = permission.selector, selector.id == id {
            found = (selector, permission.canChoose, permission.apply, permission.confirmations)
        } else if let slot = options.model,
                  let selector = [slot.menu.model, slot.menu.effort, slot.menu.speed].compactMap({ $0 }).first(where: { $0.id == id }) {
            found = (selector, slot.menu.canChoose, slot.apply, [:])
        } else if let limit = options.contextLimit, limit.selector.id == id {
            found = (limit.selector, true, .providerOption, [:])
        }
        guard let found else { return .failure(RemoteError(.notAllowed, "The task's composer has no such setting")) }
        guard found.canChoose else {
            return .failure(RemoteError(.notAllowed, "Read the choices first (taskSettings with prepare)"))
        }
        guard found.selector.choices.contains(where: { $0.value == value }),
              let choice = found.apply.choice(id: id, value: value) else {
            return .failure(RemoteError(.notAllowed, "The menu does not offer that choice now"))
        }
        // The Mac asks before Bypass permissions and Full access; the other device asked too, and says so.
        guard found.confirmations[value] == nil || confirmed else {
            return .failure(RemoteError(.notAllowed, "This choice is confirmed first"))
        }
        // The composer's own apply (`ComposerActions.apply`), answered once the provider took it, or after a while.
        await RemoteServer.waitAtMost(10) { @MainActor in
            switch choice {
            case let .codexModel(selection): await model.selectCodexModel(selection, for: session)
            case let .codexRunLocation(location): await model.selectCodexRunLocation(location, for: session)
            case let .providerOption(id, value): await model.setProviderOption(id, value: value, for: session)
            }
        }
        guard let current = self.session(taskID) else { return .failure(RemoteError(.notFound)) }
        return .success(watchSettings(of: current.id))
    }

    /// The task's settings, watched until what they are read from changes; then they are read again, and the server is
    /// told only when they differ from what was answered.
    func watchSettings(of id: UUID) -> [RemoteSetting] {
        guard let model else { return [] }
        let read = { [weak self] in
            self?.listedSession(id).map { Self.taskSettings(Self.composerOptions(of: $0, in: model)) } ?? []
        }
        let settings: [RemoteSetting]
        if watchesSettings.contains(id) {
            settings = read()
        } else {
            watchesSettings.insert(id)
            settings = withObservationTracking(read) { [weak self] in
                Task { @MainActor in self?.settingsMayHaveChanged(id) }
            }
        }
        answeredSettings[id] = settings
        return settings
    }

    private func settingsMayHaveChanged(_ id: UUID) {
        watchesSettings.remove(id)
        guard let answered = answeredSettings[id] else { return }
        // A task no phone follows any more is no longer watched.
        guard watched.contains(id) else {
            answeredSettings[id] = nil
            return
        }
        if watchSettings(of: id) != answered { changeHandler?(.taskSettings(id.uuidString)) }
    }

    // MARK: - Slash commands

    /// The Codex app's commands a phone may run: Compact, Fork chat, New chat, Plan mode and the speed (`service-tier:`).
    /// The others edit files (Init), need a window of the Mac's (Code review, Rename, Side, Status), or are the
    /// sidebar's (Pin, Archive, §15.10) or the composer's own settings (Model, Reasoning).
    /// Skills resolve against the host catalog when sent; their filesystem paths never travel.
    static let codexCommandNames: Set<String> = ["compact", "fork", "new", "plan-mode"]
    /// Claude Code built-ins allowed remotely. Explicitly advertised user commands join these below;
    /// unclassified and other built-in commands may change settings or accounts and stay on the host.
    static let claudeCommandNames = ["compact", "clear"]
    /// What Claude Code's `/compact` takes, in the CLI's words.
    static let claudeCompactHint = "<optional custom summarization instructions>"

    func composerCommands(taskID: String) async -> Result<[RemoteComposerCommand], RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        if session.harness == .codex { await model.prepareCodexComposerCommands(for: session) }
        else if session.harness == .claudeCode, !model.isAttached(session.id) { await model.loadProviderCapabilities(for: session) }
        return .success(Self.commands(of: session, in: model))
    }

    /// The commands the task's composer lists that a phone may run, in the list's order and words.
    static func commands(of session: SessionRecord, in model: AppModel) -> [RemoteComposerCommand] {
        switch session.harness {
        case .codex:
            return CodexComposerCommands.catalog(codexCommandContext(of: session, in: model)).compactMap { row in
                guard codexCommandNames.contains(row.name) || row.name.hasPrefix("service-tier:") || row.name.hasPrefix("skill:") else { return nil }
                return RemoteComposerCommand(name: row.name, title: row.title, description: RemoteText.short(row.description, RemoteText.detailLimit),
                                             argumentHint: row.name.hasPrefix("skill:") ? "<prompt>" : nil,
                                             group: row.group, runs: !row.name.hasPrefix("skill:"))
            }
        case .claudeCode:
            // The CLI's own words where it listed them; before the task read them, Yardlet's, and `/compact` takes its
            // instructions either way.
            let listed = model.providerCapabilitiesBySessionID[session.id]?.composerCommands ?? []
            let names = claudeCommandNames + listed.filter { $0.builtin == false && !claudeCommandNames.contains($0.name) }.map(\.name)
            return names.map { name in
                let row = listed.first { $0.name == name }
                let description = row?.description.isEmpty == false ? row?.description : name == "clear"
                    ? L10n.string("Start a new conversation and keep this chat.") : L10n.string("Compact this chat's context")
                let hint = row.map(\.argumentHint) ?? (name == "compact" ? claudeCompactHint : nil)
                return RemoteComposerCommand(name: name, description: RemoteText.short(description, RemoteText.detailLimit),
                                             argumentHint: RemoteText.short(hint, RemoteText.detailLimit))
            }
        default:
            return []
        }
    }

    /// What the Codex list reads (`PromptComposer.codexCommandContext`), with an empty composer: the other device's
    /// draft is its own.
    private static func codexCommandContext(of session: SessionRecord, in model: AppModel) -> CodexComposerCommandContext {
        let capabilities = model.composerCodexCapabilities(for: session)
        let tokenUsage = model.codexPresentationBySessionID[session.id]?.thread?.turns.last(where: { $0.tokenUsage != nil })?
            .tokenUsage ?? model.restoredCodexTokenUsageBySessionID[session.id]
        return CodexComposerCommandContext(
            hasThread: session.providerSessionID != nil, isRunning: isRunning(session), workspaceURL: session.workspaceURL,
            modelCatalog: capabilities.modelCatalog, modes: capabilities.modes, selectedModeID: capabilities.selectedModeID,
            tokenUsage: tokenUsage, skills: capabilities.skills)
    }

    func runComposerCommand(taskID: String, command name: String, arguments: String?) async -> Result<String?, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        let listed = Self.commands(of: session, in: model)
        guard let command = listed.first(where: { $0.name == name }) else {
            return .failure(RemoteError(.notAllowed, "The task's composer offers no such command here"))
        }
        let isUserCommand = session.harness == .claudeCode && model.providerCapabilitiesBySessionID[session.id]?
            .composerCommands.first(where: { $0.name == name })?.builtin == false
        guard arguments == nil || command.argumentHint != nil || isUserCommand else {
            return .failure(RemoteError(.notAllowed, "/\(name) takes nothing after it"))
        }
        if model.switchingAccounts.contains(session.id) || model.sessionMutations.contains(session.id) {
            return .failure(RemoteError(.busy, "The task is changing on the Mac"))
        }
        switch model.sendRefusal(for: session) {
        case .heldElsewhere?: return .failure(RemoteError(.busy, "Another app holds this conversation"))
        case .folderMissing?: return .failure(RemoteError(.unavailable, "The task's folder no longer exists"))
        case nil: break
        }
        // What the Mac's composer would only say in its notice is said here instead.
        if Self.isRunning(session), name == "compact" || name == "clear" || name == "new" {
            return .failure(RemoteError(.busy, L10n.format("Available when %@ finishes this turn", session.harness.displayName)))
        }
        switch session.harness {
        case .codex:
            guard let row = CodexComposerCommands.catalog(Self.codexCommandContext(of: session, in: model)).first(where: { $0.name == name }),
                  let codex = CodexComposerCommands.command(for: row, in: Self.codexCommandContext(of: session, in: model)) else {
                return .failure(RemoteError(.notAllowed))
            }
            switch codex {
            case let .skill(name, path):
                let draft = CodexComposerDraft(inputs: [.text(arguments ?? "", textElements: []), .skill(name: name, path: URL(filePath: path))])
                Task { await model.submitCodex(draft, action: .automatic, to: session) }
                return .success(nil)
            case .fork, .newChat:
                // A task of its own, which the Mac's window does not switch to.
                let point: BranchPoint = codex == .fork ? .latest : .start
                guard let started = await model.branch(session, at: point, placement: .sidebarInBackground) else {
                    return .failure(RemoteError(.internal, "The new task did not start"))
                }
                return .success(started.id.uuidString)
            case .compact:
                if model.composerDrafts.tasks.draft(for: session.id).editState != nil || !model.followUps.queue(for: session.id).isEmpty {
                    return .failure(RemoteError(.busy, L10n.string("Use this command with an empty composer while the chat is idle.")))
                }
                Task { await model.runCodexComposerCommand(.compact, in: session) }
                return .success(nil)
            default:
                // Plan mode and the speed: the next turn's, as the list's rows apply them.
                Task { await model.runCodexComposerCommand(codex, in: session) }
                return .success(nil)
            }
        case .claudeCode:
            if name == "clear" {
                guard let started = await model.restartClaudeConversation(session, placement: .sidebarInBackground) else {
                    return .failure(RemoteError(.internal, "The new conversation did not start"))
                }
                return .success(started.id.uuidString)
            }
            // As the composer sends a chosen `/compact`, and the context window's Compact session.
            let text = ["/\(name)", arguments].compactMap { $0 }.joined(separator: " ")
            Task { await model.send(HarnessUserInput(text: text), to: session) }
            return .success(nil)
        default:
            return .failure(RemoteError(.notAllowed))
        }
    }

    private static func isRunning(_ session: SessionRecord) -> Bool {
        session.status == .running || session.status == .waitingForApproval
    }

    // MARK: - Edit and fork

    /// What a turn offers another device, as its own message actions offer it (`ConversationTurnAction`): Codex's edit
    /// of its request and fork from any finished turn, Claude Code's edit of its latest message and fork of the whole
    /// conversation from its latest turn. Restoring files uses the host-reviewed receipt and device file permission. An edit is offered only
    /// where the message reaches the other device whole.
    static func turnOptions(_ turn: ConversationTurn, canBranch: Bool) -> [String] {
        var options: [String] = []
        if editText(of: turn).map({ $0.count <= RemoteText.userLimit }) == true { options.append("edit") }
        if turn.actions.canFork, canBranch { options.append("fork") }
        if turn.actions.restoreFiles != nil { options.append("restoreFiles") }
        return options
    }

    /// The words the turn's Edit message starts from.
    private static func editText(of turn: ConversationTurn) -> String? {
        if turn.actions.editsTurnInComposer, turn.actions.canEdit, let draft = turn.actions.editDraft { return draft.text }
        return turn.actions.editLatest?.text
    }

    /// Each turn's `turn` item with what the turn offers (§15.23), set after projection because whether the task can
    /// fork is the app's, as the timeline's handlers read it.
    func withTurnOptions(_ conversation: RemoteConversation, presentation: ConversationPresentation,
                         of session: SessionRecord, in model: AppModel) -> RemoteConversation {
        // Codex forks by its turn menu's own path; any other harness where its adapter has a fork.
        let canBranch = HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline || model.canBranch(session)
        var offered: [String: (options: [String], actions: ConversationTurnActions)] = [:]
        for turn in presentation.turns {
            let options = Self.turnOptions(turn, canBranch: canBranch)
            offered[turn.id] = (options, turn.actions)
        }
        guard !offered.isEmpty else { return conversation }
        var conversation = conversation
        for index in conversation.turns.indices {
            guard let offer = offered[conversation.turns[index].id],
                  let header = conversation.turns[index].items.firstIndex(where: { $0.kind == .turn }) else { continue }
            let local = offer.actions
            var next = offer.options
            if local.canRetry, (session.status == .ready || session.status == .failed), model.followUps.queue(for: session.id).isEmpty { next.append("retry") }
            conversation.turns[index].items[header].options = next
        }
        return conversation
    }

    /// Edit message and Send (§15.23) through the composer's own edit (`AppModel.editMessage`).
    func editMessage(taskID: String, turnID: String, text: String) async -> RemoteError? {
        guard let model, let session = session(taskID) else { return RemoteError(.notFound) }
        guard let turn = presentation(of: session, in: model).turns.first(where: { $0.id == turnID }),
              Self.turnOptions(turn, canBranch: true).contains("edit") else {
            return RemoteError(.notAllowed, "This message can no longer be edited")
        }
        if model.switchingAccounts.contains(session.id) || model.sessionMutations.contains(session.id) {
            return RemoteError(.busy, "The task is changing on the Mac")
        }
        guard model.followUps.queue(for: session.id).isEmpty else {
            return RemoteError(.busy, "Messages wait in the task's queue")
        }
        let start: AppModel.ConversationEditStart
        if session.harness == .codex {
            guard let state = model.codexPresentationBySessionID[session.id]?.thread?.turns.first(where: { $0.id == turnID }) else {
                return RemoteError(.notAllowed, "This message can no longer be edited")
            }
            start = .codexTurn(state)
        } else {
            guard let target = turn.actions.editLatest else { return RemoteError(.notAllowed) }
            start = .claudeMessage(target.text)
        }
        if let reason = await model.editMessage(start, to: text, in: session) { return RemoteError(.notAllowed, reason) }
        return nil
    }

    func forkTask(taskID: String, turnID: String?) async -> Result<String, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        let turns = presentation(of: session, in: model).turns
        let canBranch = HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline || model.canBranch(session)
        // The turn named, or the latest; Claude Code forks its whole conversation from the latest turn only (D10).
        guard let turn = turnID.map({ id in turns.first { $0.id == id } }) ?? turns.last,
              Self.turnOptions(turn, canBranch: canBranch).contains("fork") else {
            return .failure(RemoteError(.notAllowed, "This turn cannot be forked now"))
        }
        let point: BranchPoint = HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline ? .turn(turn.id) : .latest
        guard let forked = await model.branch(session, at: point, placement: .sidebarInBackground) else {
            return .failure(RemoteError(.internal, "The fork did not start"))
        }
        return .success(forked.id.uuidString)
    }
}
