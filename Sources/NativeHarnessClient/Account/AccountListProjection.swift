import Foundation

/// Where an account list is shown, which decides which accounts it lists, in what order, and what
/// choosing one does. Every mode draws the same rows, limits and freshness wording.
enum AccountListMode: Hashable {
    /// The new-task account chip: the harness's default login and saved accounts. Choosing one
    /// makes it the account the next task of that harness starts on.
    case newTask(HarnessKind)
    /// A task's account sheet: the saved accounts the task may continue under
    /// (`TaskAccountSwitch.allows`), with the most limit left first.
    case switchTask(SessionRecord)
    /// The same list, opened from the card of a task a plan limit stopped.
    case continueAfterLimit(SessionRecord)
    /// Settings › Accounts: every harness the filter covers, grouped by account.
    case manage

    /// The task whose account the list moves, if it moves one.
    var session: SessionRecord? {
        switch self {
        case let .switchTask(session), let .continueAfterLimit(session): session
        case .newTask, .manage: nil
        }
    }
}

/// What Settings › Accounts does with a harness's default login, through the harness's own CLI.
enum DefaultLoginAction: Hashable {
    /// Signed out, as the Harnesses page's sign-out does.
    case signOut
    /// Signed out, then the harness's sign-in opens.
    case signInWithAnotherAccount
}

/// The accounts an `AccountList` shows and what each row offers. Pure, so each mode's filtering,
/// sorting and actions are tested without drawing.
@MainActor
enum AccountListProjection {
    /// The harnesses the list covers. `manageHarnesses` is what the Settings filter selects.
    static func harnesses(_ mode: AccountListMode, manageHarnesses: [HarnessKind] = []) -> [HarnessKind] {
        switch mode {
        case let .newTask(harness): [harness]
        case let .switchTask(session), let .continueAfterLimit(session): [session.harness]
        case .manage: manageHarnesses
        }
    }

    /// The rows the list shows, in order.
    static func choices(_ mode: AccountListMode, store: ProviderConnectionStore,
                        manageHarnesses: [HarnessKind] = [], search: String = "") -> [AccountChoice] {
        switch mode {
        case let .newTask(harness):
            return store.choices(for: [harness])
        case let .switchTask(session), let .continueAfterLimit(session):
            let labels = store.knownAccountLabels
            // An account whose tasks are moving away takes none; the task's own still shows.
            let accounts = store.connections(for: session.harness).filter {
                $0 == session.connection || (!store.isMovingAway($0) && TaskAccountSwitch.allows($0, for: session))
            }
            return sortedByRemainingLimit(accounts.map {
                AccountChoice(harness: $0.harness, connection: $0, snapshot: store.snapshots[$0.id],
                              knownLabel: labels[$0.id])
            })
        case .manage:
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return store.choices(for: manageHarnesses, includingMoving: true).filter {
                query.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query)
            }
        }
    }

    /// Accounts with the most limit left first; accounts without a limit reading last. Ties keep
    /// their order.
    static func sortedByRemainingLimit(_ choices: [AccountChoice]) -> [AccountChoice] {
        choices.enumerated().sorted { lhs, rhs in
            let left = lhs.element.remainingFraction ?? -1
            let right = rhs.element.remainingFraction ?? -1
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    /// The rows grouped by account, keeping the order each account first appears in.
    static func groups(_ choices: [AccountChoice]) -> [AccountGroup] {
        AccountGroupProjection.groups(from: choices)
    }

    /// The row marked as chosen: the next new task's account, or the account the task runs under.
    static func isSelected(_ choice: AccountChoice, mode: AccountListMode, store: ProviderConnectionStore) -> Bool {
        if let session = mode.session { return choice.connection == session.connection }
        return store.selection[choice.harness] == choice.connection?.id
    }

    /// Whether choosing the row does something. A task moves only to another account the last
    /// check did not find signed out: the switch would refuse it.
    static func canChoose(_ choice: AccountChoice, mode: AccountListMode) -> Bool {
        guard let session = mode.session else { return choice.canSelect }
        return choice.connection != session.connection && choice.canSelect && choice.snapshot?.state != .signedOut
    }

    /// Whether the row offers its harness's sign-in. Moving a task never signs in.
    static func offersConnect(_ choice: AccountChoice, mode: AccountListMode) -> Bool {
        guard mode.session == nil else { return false }
        return choice.snapshot?.canLogin == true && (choice.needsLogin || choice.snapshot?.state == .unknown)
    }

    /// What the default login's row offers besides choosing it, as the Harnesses page offers it:
    /// the harness's own sign-out, and for an account login, signing out to sign in with another
    /// account (the only way to change a login a harness cannot keep in a separate folder). Only
    /// Settings offers them, and only while the last reading says the CLI can sign out. A harness
    /// that connects model providers instead disconnects one; connecting another needs no sign-out.
    static func defaultLoginActions(_ choice: AccountChoice, mode: AccountListMode) -> [DefaultLoginAction] {
        guard mode == .manage, choice.connection == nil, choice.snapshot?.canLogout == true else { return [] }
        return AccountConnectionPresentation.usesProviderLanguage(choice.harness)
            ? [.signOut] : [.signInWithAnotherAccount, .signOut]
    }

    /// What appearing and the refresh button check: the default logins and saved accounts the
    /// list shows. A task's list checks only the accounts it offers.
    static func checkScope(_ mode: AccountListMode, choices: [AccountChoice], manageHarnesses: [HarnessKind] = [])
        -> (defaults: [HarnessKind], saved: [HarnessKind], connectionIDs: Set<String>?) {
        switch mode {
        case let .newTask(harness): ([harness], [harness], nil)
        case let .switchTask(session), let .continueAfterLimit(session):
            ([], [session.harness], Set(choices.compactMap { $0.connection?.id }))
        case .manage: (manageHarnesses, manageHarnesses, nil)
        }
    }

    /// What an empty list, or a task's list with no other account, says.
    static func emptyText(_ mode: AccountListMode, choices: [AccountChoice], search: String = "") -> String? {
        switch mode {
        case .newTask:
            return choices.isEmpty ? L10n.string("Connect a harness to use an account.") : nil
        case let .switchTask(session), let .continueAfterLimit(session):
            guard choices.allSatisfy({ $0.connection == session.connection }) else { return nil }
            return L10n.string(session.harness == .claudeCode
                ? "No other account shares this task's conversation history."
                : "No selectable stored accounts in this task's environment.")
        case .manage:
            guard choices.isEmpty else { return nil }
            return L10n.string(search.isEmpty ? "Connect a harness to use an account." : "No matching accounts.")
        }
    }

    /// The second line of a row that stands for a whole account: the connection, the provider it
    /// names, the plan, and an unknown account said as such.
    static func accountLine(_ choice: AccountChoice) -> String {
        var parts = [choice.connectionTitle]
        if let provider = choice.connection?.providerID ?? choice.snapshot?.providerID {
            parts.append(ProviderConnection.providerDisplayName(provider))
        }
        let identity = choice.identity
        if !identity.isIdentified, choice.snapshot != nil, choice.knownLabel == nil {
            parts.append(L10n.string("Unknown account"))
        }
        if let plan = choice.snapshot?.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            parts.append(plan)
        }
        return parts.joined(separator: " · ")
    }

    /// The second line of an account block's header: provider, plan, and an unknown account said
    /// as such.
    static func groupLine(_ group: AccountGroup) -> String {
        var parts: [String] = []
        if let provider = group.identity.providerDisplayName { parts.append(provider) }
        // Before its first answer a connection is not yet an unknown account, only an unchecked one.
        let hasReading = group.choices.contains { $0.snapshot != nil }
        if !group.identity.isIdentified, hasReading { parts.append(L10n.string("Unknown account")) }
        if let plan = group.identity.planLabel, !plan.isEmpty { parts.append(plan) }
        if parts.isEmpty { parts.append(group.harnesses.map(\.displayName).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

extension AccountChoice {
    /// The smallest share any of the account's plan limits has left, from its last reading.
    var remainingFraction: Double? { snapshot.flatMap(ProviderConnectionStore.remainingFraction) }
}
