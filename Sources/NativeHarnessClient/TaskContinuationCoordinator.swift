import Foundation
import Observation

/// Continues a task's work that something other than the person cut off or put off: a turn a lost
/// connection cut off (`ConnectionResumePolicy`), the turns and questions a restart cut off
/// (`RestartResumePolicy`), the continue armed for a usage limit's reset (`UsageLimitAutoContinue`),
/// an account chosen while the task worked (`chooseAccount`), a context limit that waits for the
/// task's runtime to start again (`chooseContextLimit`), and the idle runtimes a sign-in ends
/// (`continueTasks(afterSignInOf:connection:isFirstReading:)`).
///
/// It keeps every per-task value these need, so a task leaving the list takes them all along
/// (`removeSession`) and a quit stops their timers (`shutdown`). `AppModel` keeps the tasks, their
/// runtimes and conversations, tells this coordinator what happens to them, and is what it acts
/// through.
@MainActor
@Observable
final class TaskContinuationCoordinator {
    /// The model whose tasks continue here; it owns this coordinator.
    @ObservationIgnored weak var model: AppModel?

    // MARK: State

    /// Limit cards whose task sends the continue message once the limit resets. Kept in memory
    /// only; a restart forgets them.
    private(set) var usageLimitAutoContinue: [UUID: UsageLimitAutoContinue] = [:]
    /// Why continuing a limited task under another account was refused, for its limit card.
    var usageLimitSwitchErrorBySessionID: [UUID: String] = [:]
    @ObservationIgnored private var usageLimitAutoContinueTasks: [UUID: Task<Void, Never>] = [:]
    /// Follows `UsageLimitAutoContinuePreference` once the setting has armed a continue.
    @ObservationIgnored private var usageLimitAutoContinuePreferenceObserver: (any NSObjectProtocol)?
    /// The armed continue the person's message took over, until the turn it started ends: a card that
    /// turn ends on is armed in its place.
    @ObservationIgnored var usageLimitAutoContinueHandedOver: [UUID: UsageLimitAutoContinue] = [:]
    /// How long after a limit's reset the continue message waits, so the provider's own clock
    /// has passed it too.
    @ObservationIgnored var usageLimitResumeGrace: Duration = .seconds(10)
    /// Tasks Yardlet continued after the last restart, for the line above their composer. Kept in
    /// memory only and cleared once the person sends to or stops the task.
    private(set) var restartResumeNoticeSessionIDs = Set<UUID>()
    /// Cut-off turns that continue once their task is opened, with the last moment they may.
    @ObservationIgnored private var restartResumesWhenOpened: [UUID: Date] = [:]
    /// Cut-off turns continuing from launch, a few starting at a time (`RestartResumeLine`).
    @ObservationIgnored private(set) var restartResumeLine = RestartResumeLine()
    /// Starting continuations Yardlet has asked for, until their provider shows work.
    @ObservationIgnored private(set) var restartResumesAwaitingWork = Set<UUID>()
    /// The wait after which a starting continuation gives up its place in line.
    @ObservationIgnored private var restartResumeStartWaits: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var continuesRestartResumeLine = false
    /// The record's entry for each cut-off turn not continued yet, in line or until opened, for a
    /// quit before then to carry over.
    @ObservationIgnored private var restartResumesToContinue: [UUID: RestartResumeRecord.Entry] = [:] {
        didSet { restartRecordMayHaveChanged() }
    }
    /// Whether the record a quit writes is kept as it would be written now, so that an exit that
    /// writes nothing (a force quit, a crash, a kill) leaves it too (`RestartResumePolicy`): from the
    /// launch's reading of the last record, which it would otherwise overwrite, until the quit writes
    /// its own.
    @ObservationIgnored private var keepsRestartRecordCurrent = false
    @ObservationIgnored private var restartRecordWrite: Task<Void, Never>?
    /// How long a change waits before the kept record is written, so that a burst of them writes once.
    @ObservationIgnored var restartRecordDelay: Duration = .seconds(1)
    /// Idle Claude Code tasks in line whose CLI starts again, with nothing sent, for the session jobs
    /// it brings back (`ClaudeSessionJobs`).
    @ObservationIgnored private(set) var sessionJobRelaunches = Set<UUID>()
    /// The launch's read of saved conversations for those jobs, which quitting cancels.
    @ObservationIgnored private var sessionJobScan: Task<[UUID], Never>?
    /// The cards of the questions a restart cut off, asked again until the person answers in their
    /// next message, sends anything else, or a turn starts (`RestartResumePolicy.Plan.questions`).
    /// A quit before then carries them over with their entry in `restartResumesToContinue`.
    private(set) var restartQuestions: [UUID: ConversationRequest] = [:]
    /// Whether this Mac's network path is up, as the system last reported it (`NetworkWatch`); up
    /// until it says otherwise.
    private(set) var isNetworkAvailable = true
    /// Tasks whose turn a lost connection cut off, until their continuation has run or the person
    /// takes over (`ConnectionResumePolicy`).
    private(set) var connectionResumes: [UUID: ConnectionResume] = [:]
    @ObservationIgnored private var connectionResumeWaits: [UUID: Task<Void, Never>] = [:]
    /// Waits out a connection resume's delay; tests hand it a clock of their own.
    @ObservationIgnored var connectionResumeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Waits out `RestartResumePolicy.startWindow`; tests hand it a clock of their own.
    @ObservationIgnored var restartResumeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Tasks whose running turn Yardlet continued after a restart while nobody had them open, with
    /// how many times in a row it has. A quit writes one down again until
    /// `RestartResumePolicy.unseenContinuationLimit`.
    @ObservationIgnored var unseenRestartResumes: [UUID: Int] = [:] {
        didSet { restartRecordMayHaveChanged() }
    }
    /// Tasks whose turn the person stopped, until their next turn starts.
    @ObservationIgnored var stoppedByPerson = Set<UUID>() {
        didSet { restartRecordMayHaveChanged() }
    }
    /// Tasks whose running CLI still has the context limit it started with, which is kept here until
    /// the chosen one reaches it (`chooseContextLimit`).
    var contextLimitRestarts: [UUID: String] = [:]
    /// The account each task moves to when its turn ends, chosen while it worked (`chooseAccount`).
    private(set) var accountSwitchesAfterTurn: [UUID: ProviderConnection] = [:]
    /// Tasks moving to the account chosen during their turn now that it ended, and the wait of each
    /// for what else keeps it busy; the end of another turn cuts the wait short.
    @ObservationIgnored private var switchingAfterTurn = Set<UUID>()
    /// How many times the moves after a turn have looked at their tasks, for tests that count them.
    @ObservationIgnored private(set) var accountMoveLooks = 0
    /// The moves in `accountSwitchesAfterTurn` Yardlet made itself, to an account with room
    /// (AppModel+AccountMoves.swift), and the state each was made for.
    @ObservationIgnored private(set) var automaticAccountMoves: [UUID: AutomaticAccountMove] = [:]
    /// Tasks whose automatic move the person cancelled, or that Yardlet gave up at its deadline: they
    /// stay until they work again.
    @ObservationIgnored var declinedAccountMoves = Set<UUID>()
    /// What each move in `accountSwitchesAfterTurn` waits for once its task's turn has ended, while it
    /// waits; the line above the composer says it.
    private(set) var accountMoveHolds: [UUID: AccountMoveHold] = [:]
    /// The time a move's wait is measured by; tests hand it a clock of their own.
    @ObservationIgnored var accountMoveClock: () -> Date = { Date() }

    // MARK: A task leaving, and quitting

    /// A task leaving the list (archived or deleted) takes along every continuation waiting for it: a
    /// cut-off turn, a lost connection's resume, the continue armed for its limit's reset, and the
    /// account it was to move to. Nothing of them fires afterwards, nor once the task is unarchived;
    /// its next limit or move arms them again.
    func removeSession(_ id: UUID) {
        personActed(on: id)
        cancelUsageLimitAutoContinue(for: id)
        usageLimitAutoContinueHandedOver.removeValue(forKey: id)
        usageLimitSwitchErrorBySessionID.removeValue(forKey: id)
        accountSwitchesAfterTurn.removeValue(forKey: id)
        automaticAccountMoves.removeValue(forKey: id)
        declinedAccountMoves.remove(id)
        forgetAccountMoveHold(id)
        model?.taskMayHaveSettled(id)
        contextLimitRestarts.removeValue(forKey: id)
    }

    /// Yardlet quits: the quit has written down what was still in line, so nothing more begins, and
    /// the timers that would continue a task stop. An account move's wait is left: cancelling it
    /// means "look again now".
    func shutdown() {
        stopKeepingRestartRecord()
        restartResumeLine = RestartResumeLine()
        sessionJobScan?.cancel()
        sessionJobRelaunches.removeAll()
        restartResumeStartWaits.values.forEach { $0.cancel() }
        restartResumeStartWaits.removeAll()
        usageLimitAutoContinueTasks.values.forEach { $0.cancel() }
        usageLimitAutoContinueTasks.removeAll()
        connectionResumeWaits.values.forEach { $0.cancel() }
        connectionResumeWaits.removeAll()
    }

    /// Whether a turn a restart or a lost connection cut off is still to continue in the task, or is
    /// continuing now: in the record, until the task is opened, in line, or after the connection.
    func continuesCutOffTurn(_ id: UUID) -> Bool {
        restartResumesToContinue[id] != nil || restartResumesWhenOpened[id] != nil
            || restartResumeLine.waiting.contains(id) || restartResumeLine.starting.contains(id)
            || connectionResumes[id] != nil
    }

    // MARK: An account chosen during a turn

    /// Choose account for a task. A task nothing keeps busy moves now. One in a turn or waiting for an
    /// answer keeps the choice and moves once that is over, and so does one something else a move waits
    /// for holds (`settlesForAccountMove`): its background work, say, which moving would end. What is
    /// sent meanwhile goes after the move. Choosing its own account again forgets the choice.
    func chooseAccount(_ connection: ProviderConnection, for session: SessionRecord) async {
        guard let model, let current = model.store.sessions.first(where: { $0.id == session.id }) else { return }
        // The person's choice takes the place of one Yardlet made.
        automaticAccountMoves.removeValue(forKey: current.id)
        let working = AppModel.isWorking(current)
        guard working || !model.settlesForAccountMove(current) else {
            cancelAccountSwitchAfterTurn(for: current.id)
            await model.switchAccount(to: connection, for: current)
            return
        }
        guard connection != current.connection else {
            cancelAccountSwitchAfterTurn(for: current.id)
            return
        }
        guard TaskAccountSwitch.allows(connection, for: current) else { return }
        accountSwitchesAfterTurn[current.id] = connection
        // With no turn to end, it waits now, and the line above the composer says what for.
        if !working { switchAccountAfterTurn(current.id) }
    }

    /// Moves a task Yardlet chose to move itself, as a choice made in its turn moves: now if nothing
    /// keeps it busy, else once that is over, with the line above the composer and its Cancel.
    func moveAutomatically(_ id: UUID, to connection: ProviderConnection, as move: AutomaticAccountMove) {
        guard let model, accountSwitchesAfterTurn[id] == nil,
              !(model.store.sessions.first { $0.id == id }.map { model.isHeld($0, by: TaskBlocker.holdingOffRuntimeUse) } ?? false) else { return }
        accountSwitchesAfterTurn[id] = connection
        automaticAccountMoves[id] = move
        switchAccountAfterTurn(id)
    }

    /// Keeps a working task on its account after all. An automatic move the person cancels, or one
    /// given up at its deadline, is not made again until the task works again.
    func cancelAccountSwitchAfterTurn(for sessionID: UUID, declined: Bool = true) {
        guard let model, accountSwitchesAfterTurn.removeValue(forKey: sessionID) != nil else { return }
        if automaticAccountMoves.removeValue(forKey: sessionID) != nil, declined {
            declinedAccountMoves.insert(sessionID)
        }
        forgetAccountMoveHold(sessionID)
        model.taskMayHaveSettled(sessionID)
        // What was sent for the new account goes on this one.
        if !model.isRunning(sessionID) { model.scheduleFollowUpDrain(for: sessionID) }
        model.scheduleShellDelivery(for: sessionID)
    }

    /// The person's own message does not wait for a move Yardlet chose itself (`AppModel.send`): the
    /// move is called off at once and the message goes on this account. What waited behind the move
    /// follows that message's turn, as what is queued during a turn does. False when no such move waits.
    func callOffAutomaticAccountMove(for id: UUID) -> Bool {
        guard automaticAccountMoves.removeValue(forKey: id) != nil else { return false }
        accountSwitchesAfterTurn.removeValue(forKey: id)
        forgetAccountMoveHold(id)
        model?.taskMayHaveSettled(id)
        return true
    }

    /// Only an actual change publishes: every window showing a task reads the holds.
    private func forgetAccountMoveHold(_ id: UUID) {
        if accountMoveHolds[id] != nil { accountMoveHolds.removeValue(forKey: id) }
    }

    /// Puts what another task, a schedule or auto-fix sends to an idle task in its queue while the task
    /// waits to move to another account, whoever chose the move: it goes after the move, on the new
    /// account, or once the move is cancelled or given up. False when no move waits.
    func holdUntilAccountMoves(_ input: HarnessUserInput, for id: UUID) -> Bool {
        guard let model, accountSwitchesAfterTurn[id] != nil else { return false }
        model.followUps.append(QueuedFollowUp(draft: CodexComposerDraft(input)), to: id)
        return true
    }

    /// A task whose account was chosen during its turn moves once the turn ends, before the messages
    /// sent meanwhile go: they start its next turn on the new account. One still busy otherwise (a
    /// message the provider holds, a background command) is looked at again, as an account move
    /// looks again at its tasks: when something that holds the task may have let it go
    /// (`AppModel.taskMayHaveSettled`), and at the latest after `TaskWaitTiming.moveFallback`; a turn
    /// that starts meanwhile looks again when it ends. While it waits, its hold says what for, and a
    /// move Yardlet chose itself that has waited past its deadline is given up rather than forced, so
    /// what was queued behind it goes on this account.
    func switchAccountAfterTurn(_ id: UUID) {
        guard let model, accountSwitchesAfterTurn[id] != nil else { return }
        guard switchingAfterTurn.insert(id).inserted else {
            model.taskMayHaveSettled(id)
            return
        }
        Task {
            defer {
                switchingAfterTurn.remove(id)
                forgetAccountMoveHold(id)
            }
            while let target = accountSwitchesAfterTurn[id] {
                accountMoveLooks += 1
                let look = ContinuousClock.now
                guard let task = model.store.sessions.first(where: { $0.id == id }) else {
                    accountSwitchesAfterTurn.removeValue(forKey: id)
                    return
                }
                guard !AppModel.isWorking(task) else { return }
                // One Yardlet made goes only while it still saves what it was made for.
                if automaticAccountMoves[id].map({ !model.automaticAccountMoveHolds($0, for: task) }) ?? false {
                    cancelAccountSwitchAfterTurn(for: id, declined: false)
                    return
                }
                guard let blocker = model.accountMoveBlocker(of: task, heldMessagesGoAfter: true) else {
                    accountSwitchesAfterTurn.removeValue(forKey: id)
                    await completeAccountSwitch(task, to: target, automatic: automaticAccountMoves.removeValue(forKey: id))
                    return
                }
                let owner: AccountMoveHold.Owner = automaticAccountMoves[id] == nil ? .person : .yardlet
                let now = accountMoveClock()
                let since = accountMoveHolds[id].flatMap { $0.owner == owner ? $0.since : nil } ?? now
                let hold = AccountMoveHold(owner: owner, waitsFor: blocker, since: since)
                // Waiting on would hold up what is queued behind the move for as long as, say, a dev
                // server runs; moving anyway would end that server with the CLI.
                if let deadline = hold.deadline, now >= deadline {
                    cancelAccountSwitchAfterTurn(for: id)
                    return
                }
                if accountMoveHolds[id] != hold { accountMoveHolds[id] = hold }
                await model.taskWaits.wait(for: [id], since: look, spacing: model.taskWaitTiming.moveSpacing,
                                           fallback: model.taskWaitTiming.moveFallback)
            }
        }
    }

    /// Moves a task whose turn ended to the account chosen during it, then sends what waited for the
    /// move. A refusal shows as the immediate switch's does, and holds what the person queued for
    /// the new account until they resume it; what was queued while Yardlet moved the task on its own
    /// goes on its account instead.
    private func completeAccountSwitch(_ task: SessionRecord, to target: ProviderConnection,
                                       automatic: AutomaticAccountMove? = nil) async {
        guard let model else { return }
        let target = model.connections.connections.first { $0.id == target.id } ?? target
        if TaskAccountSwitch.allows(target, for: task) {
            await model.switchAccount(to: target, for: task)
        } else {
            model.errorBySessionID[task.id] = L10n.format(
                "%@ no longer shares this task's conversation history, so the task stays on its account.",
                model.accountChoice(harness: task.harness, connection: target).title)
        }
        let moved = model.store.sessions.first(where: { $0.id == task.id })?.connection == target
        if let automatic, moved {
            await model.finishAutomaticAccountMove(automatic, of: task.id)
        } else if !moved, automatic == nil {
            model.followUps.pause(task.id)
        }
        model.scheduleFollowUpDrain(for: task.id)
        model.scheduleShellDelivery(for: task.id)
    }

    // MARK: A task's context limit

    /// Keeps a Claude task's context limit with the task. Claude Code reads the limit when it starts and
    /// nothing changes it in a running process, so a task with a runtime gets it back on the same
    /// conversation, as Choose account does: now if nothing keeps the task busy, else when its turn
    /// ends (`restartForContextLimit`). No turn starts, and a task with no runtime takes the limit when
    /// it next starts.
    func chooseContextLimit(_ value: String, for session: SessionRecord) async {
        guard let model, let current = model.store.sessions.first(where: { $0.id == session.id }),
              current.harness == .claudeCode, !model.store.isTemporary(current.id) else { return }
        let isDefault = value == ClaudeLaunchOption.defaultContextLimit
        guard isDefault || ClaudeLaunchOption.contextLimitTokens(value) != nil else { return }
        let saved = current.providerOptions[ClaudeLaunchOption.contextLimit] ?? ClaudeLaunchOption.defaultContextLimit
        guard value != saved else { return }
        do {
            if isDefault {
                try await model.store.removeProviderOption(id: current.id, optionID: ClaudeLaunchOption.contextLimit)
            } else {
                try await model.store.updateProviderOption(id: current.id, optionID: ClaudeLaunchOption.contextLimit, value: value)
            }
        } catch {
            model.updateProviderActionError(error, for: current.id)
            return
        }
        guard model.handlesBySessionID[current.id] != nil else { return }
        // Choosing again what the runtime started with leaves nothing to do.
        let running = contextLimitRestarts[current.id] ?? saved
        contextLimitRestarts[current.id] = value == running ? nil : running
        await restartForContextLimit(current.id)
    }

    /// Gives a task with a waiting context limit its runtime back, once the task settles as an account
    /// move waits for it to. One that stays busy, with a background command say, takes the limit
    /// the next time it starts, and so does one whose runtime is gone meanwhile: nothing is started for it.
    func restartForContextLimit(_ id: UUID) async {
        guard let model, contextLimitRestarts[id] != nil else { return }
        guard model.handlesBySessionID[id] != nil else {
            contextLimitRestarts[id] = nil
            return
        }
        guard let task = model.store.sessions.first(where: { $0.id == id }),
              model.settlesForAccountMove(task), model.beginAccountSwitch(of: id) else { return }
        defer { model.endAccountSwitch(of: id) }
        contextLimitRestarts[id] = nil
        await model.detachRuntime(of: id, reason: .contextLimit)?.value
        guard let current = model.store.sessions.first(where: { $0.id == id }) else { return }
        do { try await model.attach(current, resumesExistingSession: current.providerSessionID != nil) }
        catch { model.errorBySessionID[id] = error.localizedDescription }
    }

    // MARK: Continuing after a usage limit

    /// Moves a task a plan limit stopped to another account that shares its history, then asks
    /// Claude to pick up where it stopped. Nothing is sent unless the switch completed.
    func continueAfterUsageLimit(using connection: ProviderConnection, for session: SessionRecord) async {
        guard let model else { return }
        // An earlier failure is superseded by this attempt, so one left afterwards is its own.
        usageLimitSwitchErrorBySessionID.removeValue(forKey: session.id)
        model.errorBySessionID.removeValue(forKey: session.id)
        await model.switchAccount(to: connection, for: session)
        guard let updated = model.store.sessions.first(where: { $0.id == session.id }),
              updated.connection == connection, model.handlesBySessionID[updated.id] != nil,
              model.errorBySessionID[updated.id] == nil else {
            // A refusal such as a signed-out account shows on the limit card that asked for it.
            if let message = model.errorBySessionID[session.id] { usageLimitSwitchErrorBySessionID[session.id] = message }
            return
        }
        await model.send(HarnessUserInput(text: UsageLimitContinuation.afterAccountSwitch), to: updated)
    }

    /// Arms or disarms the automatic continue for the task's limit card, the one naming `resetsAt`.
    /// Armed, the task sends the continue message once the limit has reset, unless it changed in the
    /// meantime. A relaunch arms it again (`restoreUsageLimitAutoContinues`). `armedBy` is nil for the
    /// person's own choice on the card.
    func setUsageLimitAutoContinue(_ enabled: Bool, resetsAt: Date, armedBy: UsageLimitAutoContinue.ArmedBy? = nil,
                                   for session: SessionRecord) {
        guard let model else { return }
        cancelUsageLimitAutoContinue(for: session.id)
        guard enabled, let current = model.store.sessions.first(where: { $0.id == session.id }),
              current.harness == .claudeCode else {
            // What waited for the continue goes now, as it would have without it.
            model.scheduleFollowUpDrain(for: session.id)
            return
        }
        arm(UsageLimitAutoContinue(resetsAt: resetsAt, providerSessionID: current.providerSessionID,
            connection: current.connection, armedBy: armedBy), for: current.id)
    }

    /// A limit that stopped a Claude Code task's turn arms its card's automatic continue as it comes:
    /// the continue the person's message took over, when the turn it started hit the limit again, as
    /// Claude Code keeps its wait when a message typed during it hits the limit again; else, while
    /// the setting is on (`UsageLimitAutoContinuePreference`), one for a reset within a day. Not when
    /// one waits for that reset already, and not for a card read back from saved history.
    func armAtUsageLimit(_ limit: HarnessRateLimit, for id: UUID) {
        guard let model, let resetsAt = limit.resetsAt, resetsAt > Date(),
              usageLimitAutoContinue[id]?.waits(for: resetsAt) != true,
              let session = model.store.sessions.first(where: { $0.id == id }) else { return }
        let settingArms = UsageLimitAutoContinuePreference.isOn(in: model.preferences)
        if let previous = usageLimitAutoContinueHandedOver.removeValue(forKey: id),
           settingArms || previous.armedBy != .setting {
            setUsageLimitAutoContinue(true, resetsAt: resetsAt, armedBy: previous.armedBy, for: session)
        } else if settingArms, resetsAt.timeIntervalSinceNow <= UsageLimitAutoContinuePreference.horizon {
            setUsageLimitAutoContinue(true, resetsAt: resetsAt, armedBy: .setting, for: session)
        }
    }

    /// The person's message takes over from an armed continue, which the turn it starts hands to
    /// the card it ends on if it hits the limit again (`armAtUsageLimit`).
    func handOverUsageLimitAutoContinue(for sessionID: UUID) {
        if let armed = usageLimitAutoContinue[sessionID] { usageLimitAutoContinueHandedOver[sessionID] = armed }
        cancelUsageLimitAutoContinue(for: sessionID)
    }

    /// The reset a task waits for with its automatic continue armed, while it is ahead. What another
    /// task, a schedule or auto-fix sends meanwhile waits in the task's queue and goes after the
    /// continue, as Claude Code keeps what is queued during its wait for its continue: a turn started
    /// now would only hit the limit again. The person's own message goes at once.
    func usageLimitHold(of id: UUID) -> Date? {
        usageLimitAutoContinue[id].map(\.resetsAt).flatMap { $0 > Date() ? $0 : nil }
    }

    /// Puts a message in the task's queue for after the continue while the task waits for its reset
    /// (`usageLimitHold`), and says until when; nil when it does not wait.
    func holdUntilUsageLimitResets(_ input: HarnessUserInput, for id: UUID) -> Date? {
        guard let model, let resetsAt = usageLimitHold(of: id) else { return nil }
        model.followUps.append(QueuedFollowUp(draft: CodexComposerDraft(input)), to: id)
        return resetsAt
    }

    /// Disarms the continues the setting armed once it is turned off, so that nothing it did is left
    /// but the setting. Any setting's change posts the notification; only this one acts.
    private func followUsageLimitAutoContinuePreference() {
        guard let model, usageLimitAutoContinuePreferenceObserver == nil else { return }
        nonisolated(unsafe) let watched = model.preferences
        usageLimitAutoContinuePreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: model.preferences, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !UsageLimitAutoContinuePreference.isOn(in: watched) else { return }
                for (id, armed) in self.usageLimitAutoContinue where armed.armedBy == .setting {
                    self.cancelUsageLimitAutoContinue(for: id)
                    self.model?.scheduleFollowUpDrain(for: id)
                }
            }
        }
    }

    private func arm(_ armed: UsageLimitAutoContinue, for sessionID: UUID) {
        usageLimitAutoContinue[sessionID] = armed
        saveUsageLimitAutoContinues()
        if armed.armedBy == .setting { followUsageLimitAutoContinuePreference() }
        let wait = Duration.seconds(max(0, armed.resetsAt.timeIntervalSinceNow)) + usageLimitResumeGrace
        usageLimitAutoContinueTasks[sessionID] = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps, so a reset that passed
            // during sleep is acted on at wake.
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.continueAfterUsageLimitReset(sessionID, armed: armed)
        }
    }

    func cancelUsageLimitAutoContinue(for sessionID: UUID) {
        usageLimitAutoContinueTasks.removeValue(forKey: sessionID)?.cancel()
        if usageLimitAutoContinue[sessionID] != nil {
            usageLimitAutoContinue.removeValue(forKey: sessionID)
            saveUsageLimitAutoContinues()
        }
    }

    private func continueAfterUsageLimitReset(_ sessionID: UUID, armed: UsageLimitAutoContinue) async {
        guard let model, usageLimitAutoContinue[sessionID] == armed else { return }
        usageLimitAutoContinue.removeValue(forKey: sessionID)
        usageLimitAutoContinueTasks.removeValue(forKey: sessionID)
        saveUsageLimitAutoContinues()
        await sendContinueAfterReset(to: sessionID, leftAs: armed)
        // What waited for the reset goes after the continue, or now if the task had moved on.
        model.scheduleFollowUpDrain(for: sessionID)
    }

    /// The armed continues, written as they change, so that one armed before a quit, a crash or an
    /// update still waits for its reset after the relaunch (Claude Code itself drops its wait when it
    /// relaunches).
    private func saveUsageLimitAutoContinues() {
        guard let model, !model.isVisualFixture else { return }
        UsageLimitAutoContinue.save(usageLimitAutoContinue, to: model.preferences)
    }

    /// Arms again, at launch, the continues armed before the last quit, for the tasks still on the same
    /// conversation and account; a reset that passed meanwhile continues the task now, within the day
    /// a cut-off turn continues in (`RestartResumePolicy.maxAge`). Whether the task still stands at
    /// the card is checked when the message would go. Those a setting armed wait only while it is on.
    private func restoreUsageLimitAutoContinues(now: Date) {
        guard let model else { return }
        let settingArms = UsageLimitAutoContinuePreference.isOn(in: model.preferences)
        let movesArm = AccountMovePreference.isOn(in: model.preferences)
        for (id, armed) in UsageLimitAutoContinue.load(from: model.preferences)
        where now < armed.resetsAt.addingTimeInterval(RestartResumePolicy.maxAge)
            && (settingArms || armed.armedBy != .setting) && (movesArm || armed.armedBy != .accountMove) {
            guard let session = model.store.sessions.first(where: { $0.id == id }), session.harness == .claudeCode,
                  session.providerSessionID == armed.providerSessionID, session.connection == armed.connection,
                  usageLimitAutoContinue[id] == nil else { continue }
            arm(armed, for: id)
        }
        saveUsageLimitAutoContinues()
    }

    /// A limit card's Resume once its limit has reset, for a task the person comes back to: the
    /// message the armed continue sends at the reset, sent now under the task's own account. The
    /// card must still be the one the task continues from (`UsageLimitContinuation.card`) and its
    /// reset time past.
    func continueAfterUsageLimitReset(entryID: UUID, for session: SessionRecord) async {
        guard let model else { return }
        model.flushTranscriptDeltas(for: session.id)
        guard let current = model.store.sessions.first(where: { $0.id == session.id }), current.harness == .claudeCode,
              let card = UsageLimitContinuation.card(in: model.heldTranscript(of: current.id) ?? []), card.id == entryID,
              case let .usageLimit(limit) = card.content, let resetsAt = limit.resetsAt, resetsAt <= Date() else { return }
        await sendContinueAfterReset(to: current.id, leftAs: UsageLimitAutoContinue(
            resetsAt: resetsAt, providerSessionID: current.providerSessionID, connection: current.connection))
    }

    /// The continue message goes only to the task exactly as it was left: the same conversation
    /// and account, idle, still at the limit card naming that reset, and no message being edited.
    private func sendContinueAfterReset(to sessionID: UUID, leftAs left: UsageLimitAutoContinue) async {
        guard let model else { return }
        model.flushTranscriptDeltas(for: sessionID)
        guard let session = model.store.sessions.first(where: { $0.id == sessionID }),
              session.providerSessionID == left.providerSessionID, session.connection == left.connection,
              model.firstBlocker(of: session, among: TaskBlocker.holdingOffContinuations) == nil,
              let card = UsageLimitContinuation.card(in: model.heldTranscript(of: sessionID) ?? []),
              case let .usageLimit(limit) = card.content, left.waits(for: limit.resetsAt) else { return }
        await model.send(HarnessUserInput(text: UsageLimitContinuation.afterReset), to: session)
    }

    // MARK: - Continuing after a restart

    /// Writes down, while Yardlet quits, the tasks whose turn the quit cuts off and that their own
    /// app would continue (`RestartResumePolicy`), and those the last launch had not continued yet.
    /// With the setting off, or nothing to continue, any earlier record goes.
    func recordWorkForRestart(trigger: RestartTrigger, now: Date = Date()) {
        guard let model, !model.isVisualFixture else { return }
        // The quit's own record: nothing kept while running writes over it.
        stopKeepingRestartRecord()
        RestartResumeRecord(trigger: trigger, recordedAt: now, entries: restartResumeEntries(now: now)).save(to: model.preferences)
    }

    /// What runs, waits or is still to continue may have changed: a moment later the record is written
    /// again as a quit now would write it, while Yardlet keeps it (`keepsRestartRecordCurrent`).
    func restartRecordMayHaveChanged() {
        guard keepsRestartRecordCurrent, restartRecordWrite == nil else { return }
        let delay = restartRecordDelay
        restartRecordWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            restartRecordWrite = nil
            writeRestartRecord()
        }
    }

    /// Writes the record an exit that writes nothing leaves: what a quit now would write, less the
    /// tasks whose continuation is starting (`RestartResumeLine.starting`). One that stopped Yardlet
    /// as it started is not started again by the next launch; the Claude app likewise clears a
    /// session's mark before it continues it.
    private func writeRestartRecord(now: Date = Date()) {
        guard keepsRestartRecordCurrent, let model else { return }
        let entries = restartResumeEntries(now: now, leavingOut: restartResumeLine.starting)
        RestartResumeRecord(trigger: .quit, recordedAt: now, entries: entries).save(to: model.preferences)
    }

    private func stopKeepingRestartRecord() {
        keepsRestartRecordCurrent = false
        restartRecordWrite?.cancel()
        restartRecordWrite = nil
    }

    /// The tasks that continue when Yardlet opens again if it quit now, for the quit confirmation
    /// to say which of the running ones do. Empty with the setting off.
    func tasksContinuingAfterRestart() -> Set<UUID> {
        guard let model, !model.isVisualFixture, RestartResumePreference.isOn(in: model.preferences) else { return [] }
        return Set(restartResumeEntries(now: Date()).map(\.sessionID))
    }

    /// The entries under the setting on: `RestartResumeRecord.save` reads the setting off the main
    /// thread as it writes them down. `leavingOut` names tasks that are not written down.
    private func restartResumeEntries(now: Date, leavingOut: Set<UUID> = []) -> [RestartResumeRecord.Entry] {
        guard let model else { return [] }
        let candidates = model.store.sessions.filter { !leavingOut.contains($0.id) }.map { session in
            // Only a turn that runs or waits is written down, so only its transcript is read.
            let holdsTurn = session.status == .running || session.status == .waitingForApproval
            return RestartResumePolicy.Candidate(
                session: session,
                hasQueuedMessages: !model.followUps.queue(for: session.id).isEmpty,
                stoppedByPerson: stoppedByPerson.contains(session.id),
                unseenContinuations: model.isSessionVisible(session.id) ? 0 : unseenRestartResumes[session.id] ?? 0,
                isSubagentThread: model.codexPresentationBySessionID[session.id]?.thread?.parentThreadID != nil,
                waitingQuestion: holdsTurn ? Self.waitingQuestion(in: model.transcriptBySessionID[session.id] ?? [],
                                                                  codex: model.codexPresentationBySessionID[session.id]) : nil
            )
        }
        let stillToContinue = restartResumesToContinue.values.filter { !leavingOut.contains($0.sessionID) }
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        return RestartResumePolicy.entries(for: candidates, stillToContinue: stillToContinue, now: now, isOn: true)
    }

    /// The question a task's latest turn waits on the person to answer, when it waits on nothing
    /// else: its one open request asks questions, in the shared transcript (Claude Code's
    /// `AskUserQuestion`) or among the Codex thread's requests (`item/tool/requestUserInput`). A Codex
    /// question with a secret answer is left out: its answer would go as a message anyone reads.
    nonisolated static func waitingQuestion(in transcript: [TranscriptEntry], codex: CodexTaskState?) -> RestartQuestion? {
        // Every open request by its ID (a Codex approval shows in both records), with its question.
        var open: [String: RestartQuestion] = [:]
        var others = Set<String>()
        for entry in transcript.reversed() {
            if case .user = entry.content, entry.joinsRunningTurn != true { break }
            guard case let .permission(request, .pending) = entry.content else { continue }
            if case .questions = request.structured { open[request.id] = .request(request) } else { others.insert(request.id) }
        }
        if let codex {
            // As the Codex row reads them (`TaskAttentionDetail.reading`): those of the running turn.
            func isOpen(_ turnID: String?) -> Bool { turnID == nil || turnID == codex.activeTurnID }
            for approval in codex.approvalsByID.values where approval.resolution == .pending && isOpen(approval.turnID) {
                others.insert(approval.id)
            }
            for request in codex.serverRequestsByID.values where request.resolution == .pending && isOpen(request.turnID) {
                if request.kind == .toolUserInput,
                   !CodexRequestResponseProjection.questions(request.params).contains(where: \.isSecret) {
                    open[request.id] = .codex(CodexPendingServerRequest(request))
                } else {
                    others.insert(request.id)
                }
            }
        }
        guard open.count == 1, others.subtracting(open.keys).isEmpty else { return nil }
        return open.values.first
    }

    /// Reads the record the last run left, once, after the task index is back, and continues what
    /// it allows: the most recent first, a few starting at a time, and those that waited on the
    /// person once they are opened. The record is the last quit's, or, after an exit that wrote
    /// nothing, the one the last run kept. The subagents it cut off cannot continue; the callers that
    /// waited for them are told.
    /// Then the idle Claude Code tasks whose CLI brings session jobs back start again, after them.
    func continueWorkInterruptedByRestart(now: Date = Date()) async {
        guard let model, !model.isVisualFixture else { return }
        // These start once the cut-off turns below are planned, and their tasks wait for them.
        model.continueAccountTaskMoves()
        restoreUsageLimitAutoContinues(now: now)
        // Before any turn continues, so that a caller asking after its subagents finds them.
        let waitedFor = model.restoreAgentRunsCutOffByQuit()
        await continueTurnsCutOffByRestart(now: now)
        await tellCallersOfAgentRunsCutOffByQuit(waitedFor, now: now)
        await relaunchForSessionJobs()
    }

    private func continueTurnsCutOffByRestart(now: Date) async {
        guard let model else { return }
        let record = RestartResumeRecord.load(from: model.preferences)
        // From here on the record is kept as a quit would write it, and replaces the one just read.
        keepsRestartRecordCurrent = true
        guard let record else {
            writeRestartRecord(now: now)
            return
        }
        let plan = RestartResumePolicy.plan(for: record, sessions: model.store.sessions, now: now,
            isOn: RestartResumePreference.isOn(in: model.preferences))
        restartResumesToContinue.merge(plan.entries) { _, new in new }
        restartResumesWhenOpened.merge(plan.whenOpened) { _, new in new }
        // A question the quit cut off waits for the person on the card it was asked on.
        for (id, question) in plan.questions {
            restartQuestions[id] = switch question {
            case let .request(request):
                TranscriptConversationProjection.conversationRequest(
                    request, state: .pending, entry: TranscriptEntry(content: .permission(request, state: .pending)))
            case let .codex(request):
                CodexRequestResponseProjection.request(request.state)
            }
            model.refreshAttentionDetail(for: id)
        }
        restartResumeLine.append(plan.atLaunch)
        // What this launch has still to continue, which an exit before then carries over.
        writeRestartRecord(now: now)
        await continueRestartResumeLine()
        // A task already open counts as opened.
        taskOpened(model.store.selectedSessionID, now: now)
    }

    /// Tells each caller that waited for a subagent the last quit cut off, as `notify` tells it of one
    /// that ended, with its answer so far: a foreground call's caller holds no ID to ask with. Only
    /// under the restart setting and within its day, as a cut-off turn continues; the message starts
    /// a turn in an idle caller.
    private func tellCallersOfAgentRunsCutOffByQuit(_ interrupted: [SessionToolCenter.InterruptedRun], now: Date) async {
        guard let model, RestartResumePreference.isOn(in: model.preferences) else { return }
        for run in interrupted where now < run.interruptedAt.addingTimeInterval(RestartResumePolicy.maxAge) {
            await model.notifyCaller(of: run.id, hostTaskID: run.hostTaskID)
        }
    }

    /// Whether a cut-off turn waits for its task to be opened before it continues.
    func continuesWhenOpened(_ id: UUID) -> Bool {
        restartResumesWhenOpened[id] != nil
    }

    /// Starts again, with nothing sent, the CLI of each idle Claude Code task whose saved conversation
    /// holds a session job the CLI brings back on resuming it (`ClaudeSessionJobs`):
    /// the jobs ran only in the CLI the quit ended. They take their turn in the restart line behind
    /// the cut-off turns, and only under the restart setting.
    private func relaunchForSessionJobs() async {
        guard let model, RestartResumePreference.isOn(in: model.preferences) else { return }
        let now = Date()
        // Whether another app holds a conversation is asked only of those found to have jobs.
        let candidates = model.store.sessions.filter { relaunchesForSessionJobs($0, now: now, askingRefusal: false) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { session in session.providerSessionID.map { (session.id, model.claudeSessionReader(for: session), $0) } }
        guard !candidates.isEmpty else { return }
        let scan = Task.detached(priority: .utility) { () -> [UUID] in
            candidates.filter { _, reader, conversation in
                guard !Task.isCancelled else { return false }
                let records = (try? reader.recordsNamingSessionJobs(sessionID: conversation)) ?? []
                return !ClaudeSessionJobs.broughtBack(from: records, now: Date()).isEmpty
            }.map(\.0)
        }
        sessionJobScan = scan
        let found = await scan.value
        guard !scan.isCancelled else { return }
        sessionJobScan = nil
        let relaunching = found.filter { id in
            model.store.sessions.first { $0.id == id }.map { relaunchesForSessionJobs($0, now: Date()) } ?? false
        }
        sessionJobRelaunches.formUnion(relaunching)
        restartResumeLine.append(relaunching)
        await continueRestartResumeLine()
    }

    /// Whether a task's CLI may start again for its session jobs: an idle Claude Code task touched
    /// within a recurring job's lifetime, with no runtime, nothing the restart already continues or
    /// keeps waiting for the person (its turn, an approval, a question), no message waiting to go, and
    /// nothing being edited, moved or refused. The rest start when the person comes to them.
    private func relaunchesForSessionJobs(_ session: SessionRecord, now: Date, askingRefusal: Bool = true) -> Bool {
        guard let model else { return false }
        return session.harness == .claudeCode && session.providerSessionID != nil
            && now.timeIntervalSince(session.updatedAt) < ClaudeSessionJobs.recurringMaxAge
            && model.handlesBySessionID[session.id] == nil
            && restartResumesToContinue[session.id] == nil && connectionResumes[session.id] == nil
            && model.firstBlocker(of: session, among: TaskBlocker.holdingOffSessionJobRelaunches) == nil
            && (!askingRefusal || model.sendRefusal(for: session) == nil)
    }

    /// Begins the continuations in line while fewer than `RestartResumePolicy.launchLimit` are
    /// starting. One Yardlet asked for keeps its place until its provider shows work or
    /// `RestartResumePolicy.startWindow` passes; one with nothing to continue gives it up at once.
    private func continueRestartResumeLine() async {
        guard !continuesRestartResumeLine else { return }
        continuesRestartResumeLine = true
        defer { continuesRestartResumeLine = false }
        while let id = restartResumeLine.next() {
            // Written down without it at once: Yardlet may stop as it starts.
            if restartResumesToContinue[id] != nil { writeRestartRecord() }
            let asked = await continueAfterRestart(id)
            // Its provider may have shown work already.
            guard restartResumeLine.starting.contains(id) else { continue }
            guard asked else {
                restartResumeStarted(id)
                continue
            }
            let sleep = restartResumeSleep
            restartResumeStartWaits[id] = Task { [weak self] in
                do { try await sleep(RestartResumePolicy.startWindow) } catch { return }
                guard !Task.isCancelled else { return }
                self?.restartResumeStarted(id)
            }
        }
    }

    /// A starting continuation showed work, waited out its window, or had nothing to start: the
    /// next one in line may begin.
    func restartResumeStarted(_ id: UUID) {
        restartResumesAwaitingWork.remove(id)
        restartResumeStartWaits.removeValue(forKey: id)?.cancel()
        // No longer starting, it is written down as any running turn is.
        restartRecordMayHaveChanged()
        // A line already running picks up the free place itself.
        guard restartResumeLine.finishStarting(id), !continuesRestartResumeLine else { return }
        Task { await continueRestartResumeLine() }
    }

    /// The person opened a task: a turn that waits for that, in line or until opened, continues now.
    func taskOpened(_ id: UUID?, now: Date = Date()) {
        guard let id, let model else { return }
        model.readSavedConversation(of: id)
        unseenRestartResumes.removeValue(forKey: id)
        if restartResumeLine.removeWaiting(id) {
            Task { await continueAfterRestart(id) }
            return
        }
        guard let deadline = restartResumesWhenOpened.removeValue(forKey: id) else { return }
        guard now < deadline else {
            restartResumesToContinue.removeValue(forKey: id)
            return
        }
        Task { await continueAfterRestart(id) }
    }

    /// Whatever the person does in a task takes over from continuing it, and from the line saying
    /// it was continued.
    func personActed(on id: UUID) {
        restartResumesWhenOpened.removeValue(forKey: id)
        restartResumeLine.removeWaiting(id)
        sessionJobRelaunches.remove(id)
        restartResumesToContinue.removeValue(forKey: id)
        if restartResumeNoticeSessionIDs.contains(id) { restartResumeNoticeSessionIDs.remove(id) }
        stopAskingRestartQuestion(id)
        forgetConnectionResume(id)
    }

    // MARK: Continuing after a lost connection

    /// The system reported the network path: once it is up again, every task whose cut-off turn is due
    /// continues.
    func networkPathChanged(isSatisfied: Bool) {
        guard isNetworkAvailable != isSatisfied else { return }
        isNetworkAvailable = isSatisfied
        if isSatisfied { continueDueConnectionResumes() }
    }

    /// The provider ended a turn on its own connection error: the task waits for the network and the
    /// Claude app's time after the cut, then continues, as many times in a row as the policy allows.
    /// A turn the person stopped, or a task the setting leaves alone, does not.
    func acceptTurnCut(_ cut: TurnCut, for id: UUID, at date: Date) {
        guard let model, cut != .quit, RestartResumePreference.isOn(in: model.preferences), !stoppedByPerson.contains(id),
              model.store.sessions.contains(where: { $0.id == id }) else { return }
        let continued = connectionResumes[id]?.continuations ?? 0
        guard continued < ConnectionResumePolicy.limit else {
            forgetConnectionResume(id)
            return
        }
        connectionResumes[id] = ConnectionResume(cut: cut, cutAt: date, continuations: continued, isWaiting: true)
        model.refreshAttentionDetail(for: id)
        connectionResumeWaits.removeValue(forKey: id)?.cancel()
        let delay = max(0, connectionResumes[id]?.dueAt.timeIntervalSinceNow ?? 0)
        let sleep = connectionResumeSleep
        connectionResumeWaits[id] = Task { [weak self] in
            do { try await sleep(.milliseconds(Int64(delay * 1_000))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.connectionResumeIsDue(id)
        }
    }

    private func connectionResumeIsDue(_ id: UUID) {
        connectionResumeWaits.removeValue(forKey: id)
        guard connectionResumes[id]?.isWaiting == true else { return }
        connectionResumes[id]?.isDue = true
        if isNetworkAvailable { continueDueConnectionResumes() }
    }

    /// Continues every waiting task whose time has come, in the order their turns were cut off, a few
    /// starting at once (`RestartResumeLine`), while the network is up.
    func continueDueConnectionResumes() {
        let due = connectionResumes.filter { $0.value.isWaiting && $0.value.isDue }
            .sorted { $0.value.cutAt < $1.value.cutAt }.map(\.key)
        guard isNetworkAvailable, !due.isEmpty else { return }
        restartResumeLine.append(due)
        Task { await continueRestartResumeLine() }
    }

    /// The task no longer waits to continue after a lost connection: it continued and ended, someone
    /// else started a turn, or the person took over.
    func forgetConnectionResume(_ id: UUID) {
        connectionResumeWaits.removeValue(forKey: id)?.cancel()
        guard connectionResumes.removeValue(forKey: id) != nil else { return }
        restartResumeLine.removeWaiting(id)
        model?.refreshAttentionDetail(for: id)
    }

    /// Continues a turn a lost connection cut off, the way its provider's app does: Claude Code is sent
    /// the Claude app's "Try again" (or its sleep message), Codex the Codex app's Resume. A message
    /// waiting in the queue goes instead, as the next turn. True once the provider was asked.
    private func continueAfterConnectionCut(_ id: UUID) async -> Bool {
        guard let model, var record = connectionResumes[id], record.isWaiting, isNetworkAvailable,
              RestartResumePreference.isOn(in: model.preferences),
              let session = model.store.sessions.first(where: { $0.id == id }),
              model.firstBlocker(of: session, among: TaskBlocker.holdingOffContinuations) == nil else { return false }
        let inLine = restartResumeLine.starting.contains(id)
        if !model.followUps.queue(for: id).isEmpty {
            forgetConnectionResume(id)
            if inLine { restartResumesAwaitingWork.insert(id) }
            model.scheduleFollowUpDrain(for: id)
            return true
        }
        if model.handlesBySessionID[id] == nil { await model.resume(session) }
        guard connectionResumes[id]?.isWaiting == true, let current = model.matchingSession(session),
              current.status != .running, current.status != .waitingForApproval,
              let adapter = model.adaptersBySessionID[id] as? any HarnessInterruptedTurnContinuing,
              let handle = model.handlesBySessionID[id] else {
            forgetConnectionResume(id)
            return false
        }
        record.isWaiting = false
        record.isDue = false
        record.continuations += 1
        connectionResumes[id] = record
        model.refreshAttentionDetail(for: id)
        // The continuation is a turn of its own after the error that ended the last one, with no
        // request of the person's to show (the provider's message is the app speaking).
        if !HarnessPresentationPolicy(harness: current.harness).usesCodexTimeline {
            model.mutateTranscript(for: id, publishImmediately: true) { builder in
                builder.appendUser("", origin: .provider)
            }
        }
        await model.markSubmissionStarted(for: id)
        if inLine { restartResumesAwaitingWork.insert(id) }
        do {
            let started = try await adapter.continueInterruptedTurn(in: handle, after: record.cut)
            guard model.store.sessions.contains(where: { $0.id == id }) else { return false }
            if !started {
                forgetConnectionResume(id)
                if model.store.sessions.first(where: { $0.id == id })?.status == .running {
                    await model.turnEnded(id, as: .ready, cause: .continuationEnded)
                }
            }
            return started
        } catch {
            guard model.store.sessions.contains(where: { $0.id == id }) else { return false }
            forgetConnectionResume(id)
            await model.turnEnded(id, as: .failed, cause: .continuationEnded,
                                  notificationDetail: error.localizedDescription)
            model.errorBySessionID[id] = error.localizedDescription
            return false
        }
    }

    // MARK: Questions a restart cut off

    /// The question a restart cut off in this task, while the provider's record shows nothing asked
    /// after its call: the card drawn at the end of the latest turn.
    func restartQuestion(in id: UUID) -> ConversationRequest? {
        guard let card = restartQuestions[id], let model else { return nil }
        // A Codex thread with a turn after the one that asked.
        if case let .codexServerRequest(request) = card.source, let turns = model.codexPresentationBySessionID[id]?.thread?.turns,
           let asked = turns.firstIndex(where: { $0.id == request.turnID }), asked < turns.count - 1 {
            return nil
        }
        // A transcript with a request after the call that asked.
        guard let callID = card.toolCallID, let transcript = model.transcriptBySessionID[id],
              let call = transcript.lastIndex(where: { entry in
                  if case let .activity(activity, _) = entry.content { activity.id == callID } else { false }
              }) else { return card }
        return transcript[(call + 1)...].contains(where: \.opensTurn) ? nil : card
    }

    /// Whether the task's row waits on a question a restart cut off (`restartQuestion(in:)`). One the
    /// provider's record went on past (another app continued the conversation) no longer waits, here
    /// or after a later quit.
    func asksRestartQuestion(in id: UUID) -> Bool {
        guard restartQuestions[id] != nil else { return false }
        if restartQuestion(in: id) != nil { return true }
        restartQuestions.removeValue(forKey: id)
        restartResumesToContinue.removeValue(forKey: id)
        return false
    }

    /// The question stops waiting: the person answered it or sent something else, or a turn began.
    /// A later quit no longer carries it over.
    func stopAskingRestartQuestion(_ id: UUID) {
        guard restartQuestions.removeValue(forKey: id) != nil else { return }
        restartResumesToContinue.removeValue(forKey: id)
        model?.refreshAttentionDetail(for: id)
    }

    /// The person's answers to a question a restart cut off go as their next message, which names
    /// the questions it answers (`RestartQuestionAnswer`): the call that asked them is gone. False
    /// when the request is not that question.
    /// Its card's route brings the answers in the provider's own shape: Claude Code's per-question
    /// picks, or Codex's answers under each question's ID.
    func answerRestartQuestion(_ requestID: String, answer: PermissionStructuredAnswer? = nil,
                               codexResponse: CodexServerRequestResponse? = nil,
                               in session: SessionRecord) async -> Bool {
        guard let card = restartQuestions[session.id], card.id == requestID else { return false }
        stopAskingRestartQuestion(session.id)
        let text: String
        switch (card.form, answer, codexResponse) {
        case let (.choices(questions)?, .questions(answers)?, _):
            text = RestartQuestionAnswer.message(questions: questions, answers: answers)
        case let (.freeText(questions)?, _, .toolUserInput(answers)?):
            // The words Codex sent for each question, not the card's stand-in for a question without any.
            var params: JSONValue?
            if case let .codexServerRequest(request) = card.source { params = request.params }
            let asked = params?["questions"]?.arrayValue ?? []
            text = RestartQuestionAnswer.message(questions.map { question in
                let sent = asked.first { $0["id"]?.stringValue == question.id }
                return (sent?["text"]?.stringValue ?? sent?["question"]?.stringValue, answers[question.id] ?? [])
            })
        default:
            return true
        }
        guard !text.isEmpty, let model, let current = model.store.sessions.first(where: { $0.id == session.id }) else { return true }
        await model.send(HarnessUserInput(text: text), to: current)
        return true
    }

    /// Resumes the task's conversation and asks its provider to continue, only while the task is
    /// as the record left it: idle, nothing being edited or moved. A task whose queue holds messages
    /// sends the first of them instead, as the next turn. True once the provider was asked. A task in
    /// line because a lost connection cut its turn off continues that way instead.
    /// A task in line for its session jobs only starts its CLI again, as long as it still may; nothing
    /// is asked, so its place frees at once.
    @discardableResult
    private func continueAfterRestart(_ id: UUID) async -> Bool {
        guard let model else { return false }
        if connectionResumes[id]?.isWaiting == true { return await continueAfterConnectionCut(id) }
        if sessionJobRelaunches.remove(id) != nil {
            if let session = model.store.sessions.first(where: { $0.id == id }), relaunchesForSessionJobs(session, now: Date()) {
                await model.resume(session)
            }
            return false
        }
        let unseenBefore = restartResumesToContinue[id]?.unseenContinuations ?? 0
        // Until it is asked, a quit still carries it over.
        defer { restartResumesToContinue.removeValue(forKey: id) }
        guard let session = model.store.sessions.first(where: { $0.id == id }),
              model.firstBlocker(of: session, among: TaskBlocker.holdingOffContinuations) == nil else { return false }
        if model.handlesBySessionID[id] == nil { await model.resume(session) }
        let inLine = restartResumeLine.starting.contains(id)
        if !model.followUps.queue(for: id).isEmpty {
            if inLine { restartResumesAwaitingWork.insert(id) }
            model.scheduleFollowUpDrain(for: id)
            return true
        }
        guard let current = model.matchingSession(session), current.status != .running,
              current.status != .waitingForApproval, current.status != .failed,
              let adapter = model.adaptersBySessionID[id] as? any HarnessInterruptedTurnContinuing,
              let handle = model.handlesBySessionID[id] else { return false }
        await model.markSubmissionStarted(for: id)
        // Work the provider shows from here on is this continuation's.
        if inLine { restartResumesAwaitingWork.insert(id) }
        do {
            let started = try await adapter.continueInterruptedTurn(in: handle, after: .quit)
            guard model.store.sessions.contains(where: { $0.id == id }) else { return false }
            if started {
                restartResumeNoticeSessionIDs.insert(id)
                if !model.isSessionVisible(id) { unseenRestartResumes[id] = unseenBefore + 1 }
                return true
            } else if model.store.sessions.first(where: { $0.id == id })?.status == .running {
                // The provider's record says the turn had ended; it stays as it ended.
                await model.turnEnded(id, as: .ready, cause: .continuationEnded)
            }
        } catch {
            guard model.store.sessions.contains(where: { $0.id == id }) else { return false }
            await model.turnEnded(id, as: .failed, cause: .continuationEnded,
                                  notificationDetail: error.localizedDescription)
            model.errorBySessionID[id] = error.localizedDescription
        }
        return false
    }

    // MARK: Continuing after a sign-in

    /// A turn the CLI refused for its sign-in, which the account's reading may not know yet.
    func noteSignInRefused(_ message: String, for sessionID: UUID) {
        guard let model, let session = model.store.sessions.first(where: { $0.id == sessionID }) else { return }
        AccountCheckLog.record(AccountCheckLog.Entry(event: "turn-refused", harness: session.harness.rawValue,
            account: session.connection?.id ?? "default", runtime: session.runtimeExecutableURL.path(percentEncoded: false),
            configHome: session.connection?.homePath ?? "default", failure: message))
        let account = model.connections.choice(for: session.harness, connection: session.connection)
        Task { await model.connections.check(account, policy: .refresh, runtimeSelections: model.runtimeSelections) }
    }

    /// A login was just read signed in. A CLI that found none keeps running on that answer, so each
    /// idle one on this login ends and the task's next message starts one that reads it. The
    /// provider ID, history and binding stay, and a task that failed for it reads ready again. The
    /// first reading of a login says nothing about the CLIs running on it, so only a task that
    /// failed for its sign-in is touched then.
    func continueTasks(afterSignInOf harness: HarnessKind, connection: ProviderConnection?,
                       isFirstReading: Bool = false) async {
        guard let model else { return }
        for session in model.store.sessions where session.harness == harness && session.connection == connection {
            guard session.status != .running, session.status != .waitingForApproval else { continue }
            let failedForSignIn = model.errorBySessionID[session.id].map(ProviderSignIn.asksToSignIn) == true
            guard failedForSignIn || !isFirstReading else { continue }
            if model.handlesBySessionID[session.id] != nil {
                await model.endRuntimeToSaveMemory(session.id, evenOnScreen: true, reason: .signIn)
            }
            if failedForSignIn {
                model.errorBySessionID.removeValue(forKey: session.id)
                try? await model.store.updateSession(id: session.id, status: .ready)
            }
        }
    }
}
