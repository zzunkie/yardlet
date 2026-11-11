import Foundation

/// Settings › Harness Accounts: whether Claude Code tasks move to an account with room on their own
/// (docs/PROVIDER_CONNECTIONS.md, "Moving tasks to an account with room"). On unless turned off.
enum AccountMovePreference {
    static let key = "YardletMovesTasksToAccountsWithRoom"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// A move to another account Yardlet chose for a task itself (`TaskContinuationCoordinator.moveAutomatically`).
struct AutomaticAccountMove: Equatable {
    /// The limit card the task continues from once it has moved, when a limit stopped it; the move
    /// goes only while the task still continues from that card (`UsageLimitContinuation.card`).
    let continuesFrom: UUID?
    /// Where it goes and why, kept for the task once it has moved.
    let assignment: AccountAssignment
}

/// What keeps a task from moving to another account now (`AppModel.accountMoveBlocker`), as the line
/// above the composer names it.
enum AccountMoveBlocker: Equatable {
    /// Its turn runs, or waits for an approval.
    case turn
    /// A question or request in its conversation waits for the person's answer.
    case request
    /// A message or shell output on its way to the provider.
    case messages
    /// A shell command the person ran in it.
    case shellCommand
    /// The harness's background commands.
    case backgroundWork
    /// Agents it runs (`run_agent`).
    case agents
    /// A message the person is editing.
    case edit
    /// Another change under way: a switch, a restart, a fork, a side chat opening, unarchiving, a
    /// worktree being made again, or a cut-off turn about to continue.
    case otherChange
}

/// A move after a turn that waits on its task (`TaskContinuationCoordinator.switchAccountAfterTurn`):
/// who chose it, what keeps it waiting now, and since when. One Yardlet chose itself waits only until
/// its deadline and is then given up, not forced; one the person chose waits until they cancel it.
struct AccountMoveHold: Equatable {
    enum Owner: Equatable { case person, yardlet }

    /// How long a move Yardlet chose itself waits on its task before it is given up.
    static let yardletWaitLimit: TimeInterval = 10 * 60

    let owner: Owner
    var waitsFor: AccountMoveBlocker
    let since: Date

    var deadline: Date? { owner == .yardlet ? since.addingTimeInterval(Self.yardletWaitLimit) : nil }
}

// Moving Claude Code tasks to an account with room, by what a move costs (`AccountRouting.move`):
// an idle task whose prompt cache has expired leaves a nearly spent account, a task a limit stopped
// moves and continues there unless the limit resets before its cache expires, and a task whose
// cache lives stays where it is. A move never cuts into a turn: it goes through the same path as an
// account chosen during one (`moveAutomatically`), and it never holds up the person: their message goes
// at once and calls the move off, and one that waits past its deadline is given up
// (`AccountMoveHold`). What Yardlet reads is what it already holds: the
// accounts' readings, which the tasks' own limit reports keep current, each task's last activity
// and the conversation of a task that just ran. A look follows a turn's end, a change in which
// accounts have room, and the moment the next cache expires or account frees up; never a timer
// that looks at every task.
extension AppModel {
    /// Whether tasks move on their own: the setting, as followed from launch (`startAccountMoves`).
    var movesTasksToAccountsWithRoom: Bool { followedAccountMovePreference == true }

    /// Follows the setting and the accounts' readings from now on.
    func startAccountMoves() {
        guard accountMovePreferenceObserver == nil, !usesVisualFixture else { return }
        nonisolated(unsafe) let watched = preferences
        accountMovePreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: watched, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.followAccountMovePreference() }
        }
        connections.onReadingsChange = { [weak self] in self?.accountReadingsChanged() }
        followAccountMovePreference()
    }

    /// Turned on, looks at the tasks now; turned off, the moves Yardlet chose and the continues it
    /// armed are undone and nothing more is looked at, as before the setting.
    func followAccountMovePreference() {
        let isOn = AccountMovePreference.isOn(in: preferences)
        // Any setting posts the change; only this one's own changes anything here.
        guard isOn != followedAccountMovePreference else { return }
        followedAccountMovePreference = isOn
        if isOn {
            claudeAccountsWithRoom = nil
            accountReadingsChanged()
        } else {
            endAccountMoveLooks()
            for id in Array(continuations.automaticAccountMoves.keys) {
                continuations.cancelAccountSwitchAfterTurn(for: id, declined: false)
            }
            for (id, armed) in continuations.usageLimitAutoContinue where armed.armedBy == .accountMove {
                guard let task = store.sessions.first(where: { $0.id == id }) else { continue }
                continuations.setUsageLimitAutoContinue(false, resetsAt: armed.resetsAt, for: task)
            }
            continuations.declinedAccountMoves.removeAll()
            claudeAccountsWithRoom = nil
        }
    }

    /// Cancels the next look, as the setting goes off.
    func endAccountMoveLooks() {
        accountMoveLook?.task.cancel()
        accountMoveLook = nil
    }

    /// Yardlet quits: the setting and the readings are no longer followed. A move waiting on a task
    /// is forgotten with it, as one the person chose is.
    func stopFollowingAccountMoves() {
        endAccountMoveLooks()
        if let observer = accountMovePreferenceObserver { NotificationCenter.default.removeObserver(observer) }
        accountMovePreferenceObserver = nil
        connections.onReadingsChange = nil
        followedAccountMovePreference = nil
    }

    /// A reading changed: when it changed which Claude Code accounts have room, a task may now have
    /// somewhere to go, or a reason to.
    func accountReadingsChanged() {
        guard movesTasksToAccountsWithRoom else { return }
        let now = Date()
        let withRoom = Set(claudeReadings().compactMap { id, snapshot in
            AccountRouting.headroom(of: snapshot.usage, model: nil, now: now).map { $0.isNearlySpent ? nil : id } ?? nil
        })
        guard withRoom != claudeAccountsWithRoom else { return }
        claudeAccountsWithRoom = withRoom
        armAccountMoveLook(at: now)
    }

    /// A Claude Code task's turn ended. One a limit stopped moves to an account with room or waits for
    /// the reset; one on a nearly spent account is looked at again once its cache has expired.
    func considerAccountMoveAfterTurn(_ id: UUID) {
        guard movesTasksToAccountsWithRoom, continuations.accountSwitchesAfterTurn[id] == nil,
              let task = store.sessions.first(where: { $0.id == id }), task.harness == .claudeCode else { return }
        if let card = limitCard(of: id), case let .usageLimit(limit) = card.content {
            Task { await moveOrWaitAfterLimit(id, card: card.id, limit: limit) }
        } else if accountHeadroom(of: task, now: Date())?.isNearlySpent == true {
            armAccountMoveLook(at: task.updatedAt.addingTimeInterval(AccountRouting.promptCacheLifetime))
        }
    }

    /// The next look, unless one comes sooner.
    func armAccountMoveLook(at date: Date) {
        guard movesTasksToAccountsWithRoom else { return }
        if let look = accountMoveLook, look.at <= date { return }
        accountMoveLook?.task.cancel()
        let task = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.accountMoveLook = nil
            await self.lookForAccountMoves()
        }
        accountMoveLook = (date, task)
    }

    /// Moves each idle task on a nearly spent account whose cache has expired to an account with
    /// room, and looks again when the next one's cache expires, or when an account frees up for one
    /// that had nowhere to go.
    func lookForAccountMoves() async {
        guard movesTasksToAccountsWithRoom else { return }
        guard !isLookingForAccountMoves else {
            looksForAccountMovesAgain = true
            return
        }
        isLookingForAccountMoves = true
        defer {
            isLookingForAccountMoves = false
            if looksForAccountMovesAgain {
                looksForAccountMovesAgain = false
                armAccountMoveLook(at: Date())
            }
        }
        var now = Date()
        var next: Date?
        var due: [SessionRecord] = []
        for task in store.sessions where canMoveAutomatically(task)
            && accountHeadroom(of: task, now: now)?.isNearlySpent == true {
            let expires = task.updatedAt.addingTimeInterval(AccountRouting.promptCacheLifetime)
            if expires > now { next = min(next ?? expires, expires) } else { due.append(task) }
        }
        var waitsForRoom = false
        if !due.isEmpty {
            await refreshAccountReadings(of: .claudeCode)
            for listed in due {
                now = Date()
                guard let task = store.sessions.first(where: { $0.id == listed.id }), task.connection == listed.connection,
                      canMoveAutomatically(task), accountHeadroom(of: task, now: now)?.isNearlySpent == true else { continue }
                let start = accountWithRoom(for: task, now: now)
                guard AccountRouting.move(.nearlySpent,
                                          cacheExpiresAt: task.updatedAt.addingTimeInterval(AccountRouting.promptCacheLifetime),
                                          hasRoomElsewhere: start != nil, now: now) == .move,
                      let start, let target = start.connection else {
                    waitsForRoom = true
                    continue
                }
                // A task waiting for its limit to reset continues on the account with room at once.
                let card = continuations.usageLimitAutoContinue[task.id].flatMap { armed in
                    limitCard(of: task.id).flatMap { card -> UUID? in
                        guard case let .usageLimit(limit) = card.content, armed.waits(for: limit.resetsAt) else { return nil }
                        return card.id
                    }
                }
                await moveTask(task, to: target, as: AutomaticAccountMove(continuesFrom: card, assignment: start.assignment))
            }
        }
        if waitsForRoom, let reset = nextReset(after: now) { next = min(next ?? reset, reset) }
        if let next { armAccountMoveLook(at: next) }
    }

    /// A limit stopped the task's turn: it waits for the reset when that comes before its cache
    /// expires, or when no account has room; else it moves to the one that has and continues there.
    /// Only a continue the person armed keeps it waiting; one a setting armed stands aside.
    private func moveOrWaitAfterLimit(_ id: UUID, card: UUID, limit: HarnessRateLimit) async {
        await refreshAccountReadings(of: .claudeCode)
        guard movesTasksToAccountsWithRoom, let task = store.sessions.first(where: { $0.id == id }),
              canMoveAutomatically(task), limitCard(of: id)?.id == card,
              continuations.usageLimitAutoContinue[id].map({ $0.armedBy != nil }) ?? true else { return }
        let now = Date()
        let start = accountWithRoom(for: task, now: now)
        let lastRequest = lastRequest(beforeLimit: card, in: id) ?? task.updatedAt
        switch AccountRouting.move(.stoppedByLimit(resetsAt: limit.resetsAt),
                                   cacheExpiresAt: lastRequest.addingTimeInterval(AccountRouting.promptCacheLifetime),
                                   hasRoomElsewhere: start != nil, now: now) {
        case .waitForReset:
            // Waiting only for a reset within a day, as Claude Code waits; the setting's continue may
            // already wait for it.
            guard let resetsAt = limit.resetsAt, continuations.usageLimitAutoContinue[id]?.waits(for: resetsAt) != true,
                  resetsAt.timeIntervalSinceNow <= UsageLimitAutoContinuePreference.horizon else { return }
            continuations.setUsageLimitAutoContinue(true, resetsAt: resetsAt, armedBy: .accountMove, for: task)
        case .move:
            guard let start, let target = start.connection else { return }
            await moveTask(task, to: target, as: AutomaticAccountMove(continuesFrom: card, assignment: start.assignment))
        case .stay:
            break
        }
    }

    /// An idle task with nothing to continue moves as an account's tasks move when it leaves the
    /// list, without starting its CLI; any other goes through the move after a turn.
    private func moveTask(_ task: SessionRecord, to target: ProviderConnection, as move: AutomaticAccountMove) async {
        guard move.continuesFrom == nil, settlesForAccountMove(task) else {
            continuations.moveAutomatically(task.id, to: target, as: move)
            return
        }
        do {
            _ = try await taskReadyToResume(task, under: target)
            guard let current = store.sessions.first(where: { $0.id == task.id }), current.connection == task.connection,
                  canMoveAutomatically(current), settlesForAccountMove(current) else { return }
            try await moveSettledTask(current, to: target)
        } catch {
            return
        }
        guard store.sessions.first(where: { $0.id == task.id })?.connection == target else { return }
        accountAssignments.record(move.assignment, for: task.id)
    }

    /// A move Yardlet chose that waited on the task goes only while it still saves what it was
    /// chosen for: the task still continues from the limit card. A turn since cancels it as the turn
    /// starts.
    func automaticAccountMoveHolds(_ move: AutomaticAccountMove, for task: SessionRecord) -> Bool {
        guard movesTasksToAccountsWithRoom else { return false }
        guard let card = move.continuesFrom else { return true }
        return limitCard(of: task.id)?.id == card
    }

    /// The task has moved: it keeps why, and one a limit stopped asks Claude to pick up where it
    /// stopped, as Continue with another account does.
    func finishAutomaticAccountMove(_ move: AutomaticAccountMove, of id: UUID) async {
        accountAssignments.record(move.assignment, for: id)
        guard let card = move.continuesFrom, limitCard(of: id)?.id == card,
              let task = store.sessions.first(where: { $0.id == id }) else { return }
        await send(HarnessUserInput(text: UsageLimitContinuation.afterAccountSwitch), to: task)
    }

    /// The account a task could move to now: the one `AccountRouting.pick` picks among the accounts it
    /// can go on under that automatic assignment may use and that are signed in, when that one has
    /// room (or no reading yet). Nil when none has.
    func accountWithRoom(for task: SessionRecord, now: Date) -> AccountStart? {
        let model = Self.modelOption(task.providerOptions, harness: task.harness)
        let candidates = automaticMoveTargets(for: task).map { routingCandidate($0, harness: task.harness, model: model) }
        guard let pick = AccountRouting.pick(candidates, model: model, now: now), pick.basis != .nearlySpent,
              pick.choice.connection != nil else { return nil }
        return AccountStart(connection: pick.choice.connection, assignment: AccountAssignment(
            choice: pick.choice, origin: .automatic, pick: pick,
            replacing: accountChoice(harness: task.harness, connection: task.connection), at: now))
    }

    /// The other accounts a task can go on under (`TaskAccountSwitch`, as Continue with another
    /// account offers them) that automatic assignment may use and that are signed in.
    func automaticMoveTargets(for task: SessionRecord) -> [AccountChoice] {
        usageLimitAccounts(for: task).map { accountChoice(harness: task.harness, connection: $0) }.filter {
            $0.canSelect && $0.snapshot?.state == .signedIn && connections.isInAutomaticAssignment($0)
        }
    }

    /// The limit card a stopped task continues from (`UsageLimitContinuation.card`), in the conversation
    /// Yardlet holds.
    func limitCard(of id: UUID) -> TranscriptEntry? {
        heldTranscript(of: id).flatMap(UsageLimitContinuation.card(in:))
    }

    /// The limits of a task's account that apply to its model, from the last reading.
    func accountHeadroom(of task: SessionRecord, now: Date) -> AccountRouting.Headroom? {
        let reading = task.connection.map { connections.snapshots[$0.id] } ?? connections.defaultSnapshots[task.harness]
        return reading.flatMap {
            AccountRouting.headroom(of: $0.usage, model: Self.modelOption(task.providerOptions, harness: task.harness), now: now)
        }
    }

    /// When the task's conversation last went to Claude before the limit card stopped it, from the
    /// conversation Yardlet holds: its last answer, thinking or tool call. A compaction after that
    /// left nothing cached to keep. Nil when the held conversation does not say.
    func lastRequest(beforeLimit card: UUID, in id: UUID) -> Date? {
        guard let entries = heldTranscript(of: id) else { return nil }
        for entry in entries.reversed() where entry.id != card {
            switch entry.content {
            case .assistant, .reasoning, .activity:
                return entry.createdAt
            case let .compaction(compaction) where compaction.phase == .completed:
                return .distantPast
            default:
                continue
            }
        }
        return nil
    }

    /// A task Yardlet may move now: a Claude Code task that is idle, has no move of its own coming,
    /// and whose last automatic move was neither cancelled by the person nor given up at its deadline
    /// since it last worked.
    func canMoveAutomatically(_ task: SessionRecord) -> Bool {
        task.harness == .claudeCode && !Self.isWorking(task) && continuations.accountSwitchesAfterTurn[task.id] == nil
            && !switchingAccounts.contains(task.id) && !continuations.declinedAccountMoves.contains(task.id)
    }

    /// Each Claude Code account's last reading, by `AccountChoice.id`.
    private func claudeReadings() -> [String: HarnessAccountSnapshot] {
        var readings: [String: HarnessAccountSnapshot] = [:]
        readings[AccountChoice.nativeID(for: .claudeCode)] = connections.defaultSnapshots[.claudeCode]
        for connection in connections.connections(for: .claudeCode) {
            readings[connection.id] = connections.snapshots[connection.id]
        }
        return readings
    }

    /// The first reset to come of a nearly spent Claude Code limit, when an account frees up.
    private func nextReset(after now: Date) -> Date? {
        claudeReadings().values
            .compactMap { AccountRouting.headroom(of: $0.usage, model: nil, now: now) }
            .flatMap(\.windows).filter(\.isNearlySpent).compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}
