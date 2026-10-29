import SwiftUI

/// The one account list. The new-task account chip, a task's account sheet, a limit card's
/// "Continue with another account" and Settings › Accounts all show it, each in its own mode: the
/// same rows, limits, freshness wording and refresh button in the same places for every harness.
/// Readings and checks belong to the `ProviderConnectionStore`.
struct AccountList: View {
    let mode: AccountListMode
    @Bindable var store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
    /// Choosing a row the mode lets the user choose.
    let onChoose: (AccountChoice) -> Void
    /// The harness's own sign-in for a row that needs it (new task and Settings only).
    var onConnect: ((AccountChoice) -> Void)? = nil
    /// Adding an account: for the new task's harness, or for the Settings filter's harness.
    var onAdd: ((HarnessKind?) -> Void)? = nil
    /// Opening Settings › Accounts (new task only).
    var onManage: (() -> Void)? = nil
    /// Closing the sheet the list is shown in.
    var onDone: (() -> Void)? = nil
    /// Settings only: linking a saved Claude account's folder with the default folder, taking a
    /// saved account off the list or signing it out and deleting it, and adding a folder found
    /// with a login (`DiscoveredAccountHome`).
    var onShare: ((ProviderConnection) -> Void)? = nil
    var onRemove: ((ProviderConnection, AccountRemoval) -> Void)? = nil
    var onAddFound: ((DiscoveredAccountHome) -> Void)? = nil
    /// Settings › Accounts' harness filter, and how harnesses are used for its default scope. Nil
    /// usage lists every available harness.
    var harnessFilter: Binding<HarnessKind?> = .constant(nil)
    var harnessUsage: AccountHarnessScope.Usage? = nil
    /// The scrolling list's largest height inside a popover or sheet; nil fills the space.
    var maxListHeight: CGFloat? = nil
    @State private var search = ""
    @State private var showsAllHarnesses = false

    private var choices: [AccountChoice] {
        AccountListProjection.choices(mode, store: store, manageHarnesses: manageHarnesses, search: search)
    }

    var body: some View {
        let choices = choices
        VStack(alignment: .leading, spacing: 12) {
            header(choices: choices)
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let empty = AccountListProjection.emptyText(mode, choices: choices, search: search) {
                Text(empty).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            list(choices: choices)
            footer
        }
        .lineSpacing(3)
        .environment(\.usageResetContext, UsageResetContext(store: store, runtimeSelections: runtimeSelections))
        .task(id: mode) {
            // Settings checks once per presentation, whichever section shows, so its list does not.
            guard mode != .manage else { return }
            await check(choices: choices, policy: .ifStale)
        }
    }

    // MARK: Header and footer

    @ViewBuilder private func header(choices: [AccountChoice]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            switch mode {
            case let .newTask(harness):
                HarnessIdentityLabel(harness: harness)
                Spacer(minLength: 8)
            case let .switchTask(session), let .continueAfterLimit(session):
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string(mode == .switchTask(session) ? "Choose account" : "Continue with another account"))
                        .font(.headline)
                    Text(session.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
            case .manage:
                Picker(L10n.string("Harness"), selection: filter) {
                    if harnessUsage != nil {
                        Text(L10n.string("Harnesses in use")).tag(AccountHarnessScope.Filter.inUse)
                    }
                    Text(L10n.string("All harnesses")).tag(harnessUsage == nil ? .inUse : AccountHarnessScope.Filter.all)
                    Divider()
                    ForEach(filterHarnesses, id: \.self) { Text($0.displayName).tag(AccountHarnessScope.Filter.harness($0)) }
                }.labelsHidden().frame(width: 165)
                TextField(L10n.string("Search accounts"), text: $search).textFieldStyle(.roundedBorder)
            }
            Button { Task { await check(choices: choices, policy: .refresh) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.string("Refresh usage")).accessibilityLabel(L10n.string("Refresh usage"))
            .disabled(store.isChecking(anyOf: AccountListProjection.harnesses(mode, manageHarnesses: manageHarnesses)))
            if mode == .manage, let onAdd {
                Button(L10n.string("Add account")) { onAdd(harnessFilter.wrappedValue) }
                    .disabled(harnessFilter.wrappedValue.map {
                        !HarnessConnectionCapabilities.capabilities(for: $0).supportsSeparateHome
                    } ?? false)
            }
            if let onDone {
                Button(L10n.string("Done"), action: onDone).keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if case let .newTask(harness) = mode, onAdd != nil || onManage != nil {
            Divider()
            HStack {
                if let onAdd, HarnessConnectionCapabilities.capabilities(for: harness).supportsSeparateHome {
                    Button(L10n.string("Add another account")) { onAdd(harness) }
                }
                Spacer()
                if let onManage { Button(L10n.string("Manage accounts"), action: onManage) }
            }.font(.callout)
        }
    }

    // MARK: List

    @ViewBuilder private func list(choices: [AccountChoice]) -> some View {
        let groups = AccountListProjection.groups(choices)
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(groups) { group in
                    AccountListSection(group: group, mode: mode, store: store,
                        showsHarness: mode == .manage, onChoose: onChoose,
                        onConnect: onConnect, onShare: onShare, onRemove: onRemove)
                }
                if let onAddFound, !found.isEmpty {
                    DiscoveredAccountsSection(homes: found, onAdd: onAddFound)
                }
            }
            .padding(.bottom, mode == .manage ? 16 : 0)
        }
        .frame(maxHeight: maxListHeight)
    }

    /// Folders with a login that are not saved accounts, for the harnesses and search the list shows.
    private var found: [DiscoveredAccountHome] {
        guard mode == .manage else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.discoveredHomes.filter {
            manageHarnesses.contains($0.harness)
                && (query.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query))
        }
    }

    private func check(choices: [AccountChoice], policy: AccountCheckPolicy) async {
        let scope = AccountListProjection.checkScope(mode, choices: choices, manageHarnesses: manageHarnesses)
        await store.check(defaultsOf: scope.defaults, savedOf: scope.saved, connectionIDs: scope.connectionIDs,
            policy: policy, runtimeSelections: runtimeSelections)
    }

    // MARK: Settings filter

    private var availableHarnesses: [HarnessKind] {
        let catalog = HarnessCatalog.builtIns.map(\.id)
        return AccountHarnessScope.available(
            catalog: catalog,
            installed: Set(catalog.filter { runtimeSelections.selectedURL(for: $0) != nil }),
            savedAccounts: Set(store.connections.map(\.harness)),
            signedInDefaults: Set(store.defaultSnapshots.values.filter { $0.state == .signedIn }.map(\.harness))
        )
    }
    private var harnessesInUse: [HarnessKind] {
        guard let harnessUsage else { return availableHarnesses }
        return AccountHarnessScope.inUse(available: availableHarnesses, withTasks: harnessUsage.withTasks,
            savedAccounts: Set(store.connections.map(\.harness)), chosenForNewTask: harnessUsage.chosenForNewTask)
    }
    /// Every harness the filter offers, including one a caller asked for that is not available.
    private var filterHarnesses: [HarnessKind] {
        guard let chosen = harnessFilter.wrappedValue, !availableHarnesses.contains(chosen) else { return availableHarnesses }
        return availableHarnesses + [chosen]
    }
    private var filter: Binding<AccountHarnessScope.Filter> {
        Binding(get: {
            harnessFilter.wrappedValue.map { .harness($0) } ?? (showsAllHarnesses ? .all : .inUse)
        }, set: { value in
            harnessFilter.wrappedValue = value.harness
            showsAllHarnesses = value == .all
        })
    }
    private var manageHarnesses: [HarnessKind] {
        guard mode == .manage else { return [] }
        return AccountHarnessScope.harnesses(for: filter.wrappedValue, available: availableHarnesses,
            inUse: harnessesInUse)
    }
}

/// One account in a list. An account reached through one connection is one row; an account
/// several connections share (the same ChatGPT login through Codex and OpenCode, say) shows its
/// name, limits and freshness once, with a row per connection underneath.
struct AccountListSection: View {
    let group: AccountGroup
    let mode: AccountListMode
    let store: ProviderConnectionStore
    var showsHarness = false
    let onChoose: (AccountChoice) -> Void
    var onConnect: ((AccountChoice) -> Void)? = nil
    var onShare: ((ProviderConnection) -> Void)? = nil
    var onRemove: ((ProviderConnection, AccountRemoval) -> Void)? = nil

    var body: some View {
        if group.choices.count == 1, let choice = group.choices.first {
            row(choice, style: .account)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                AccountGroupHeader(group: group, freshness: freshness)
                ForEach(group.choices) { choice in row(choice, style: .member) }
            }
            .padding(.bottom, 6)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var freshness: AccountFreshness {
        AccountFreshnessProjection.freshness(of: group.choices, status: store.readingStatus(for:),
            isChecking: store.isChecking)
    }

    private func row(_ choice: AccountChoice, style: AccountRow.Style) -> some View {
        let canChoose = AccountListProjection.canChoose(choice, mode: mode)
        return AccountRow(choice: choice, style: style, memberTitle: group.memberTitle(choice),
            selected: AccountListProjection.isSelected(choice, mode: mode, store: store),
            canChoose: canChoose,
            selectedValue: mode.session == nil ? L10n.string("Selected for new tasks") : L10n.string("Current account"),
            showsHarness: showsHarness,
            freshness: style == .account ? freshness : nil,
            usage: style == .account ? group : nil,
            automaticAssignment: mode == .manage ? store.isInAutomaticAssignment(choice) : nil,
            onSelect: { if canChoose { onChoose(choice) } },
            onConnect: onConnect.flatMap { connect in
                AccountListProjection.offersConnect(choice, mode: mode) ? { connect(choice) } : nil
            },
            onSetAutomaticAssignment: mode == .manage ? { store.setInAutomaticAssignment($0, for: choice) } : nil,
            onShare: sharing(choice),
            onRemove: removals(choice))
    }

    /// A saved account can leave the list; one in a folder Yardlet made can also be signed out
    /// and deleted. The default login keeps its own sign-out.
    private func removals(_ choice: AccountChoice) -> [AccountRemoval: () -> Void] {
        guard let onRemove, let connection = choice.connection else { return [:] }
        var actions: [AccountRemoval: () -> Void] = [.fromList: { onRemove(connection, .fromList) }]
        if store.canSignOutAndDelete(connection) {
            actions[.signOutAndDelete] = { onRemove(connection, .signOutAndDelete) }
        }
        return actions
    }

    /// A saved Claude account whose conversations are not the default login's can be linked to it.
    private func sharing(_ choice: AccountChoice) -> (() -> Void)? {
        guard let onShare, let connection = choice.connection, choice.harness == .claudeCode,
              !store.sharesConversationsWithDefaultLogin(choice) else { return nil }
        return { onShare(connection) }
    }
}

/// An account's row. As a whole account it names the account and shows its limits and how
/// current they are; under an account block it names its connection and that connection's status.
struct AccountRow: View {
    enum Style { case account, member }

    let choice: AccountChoice
    var style: Style = .account
    /// How the row names itself under an account block (`AccountGroup.memberTitle`).
    var memberTitle: String? = nil
    let selected: Bool
    var canChoose = true
    /// What the selected mark means to VoiceOver.
    var selectedValue = L10n.string("Selected for new tasks")
    var showsHarness = false
    var freshness: AccountFreshness? = nil
    /// The account the limits are drawn from; nil for a member row, whose account shows them.
    var usage: AccountGroup? = nil
    /// Whether tasks an agent starts may run on it; nil where the list does not say.
    var automaticAssignment: Bool? = nil
    let onSelect: () -> Void
    var onConnect: (() -> Void)? = nil
    /// The row's menu item that includes it in automatic assignment or leaves it out (Settings only).
    var onSetAutomaticAssignment: ((Bool) -> Void)? = nil
    /// The row's menu items that link its folder with the default folder and remove the account.
    var onShare: (() -> Void)? = nil
    var onRemove: [AccountRemoval: () -> Void] = [:]

    var body: some View {
        HStack(spacing: 12) {
            identityButton
            trailing
            if let onConnect {
                Button(choice.needsProvider ? L10n.string("Choose provider") : L10n.string("Connect"), action: onConnect)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(minHeight: 68)
        .background(selected ? ParityTheme.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            if let onSetAutomaticAssignment, let automaticAssignment {
                Toggle(L10n.string("Include in Automatic Assignment"), isOn: Binding(
                    get: { automaticAssignment }, set: { onSetAutomaticAssignment($0) }))
            }
            if let onShare { Button(L10n.string("Share With the Default Folder…"), action: onShare) }
            if !onRemove.isEmpty { Divider() }
            if let remove = onRemove[.fromList] { Button(L10n.string("Remove from List…"), action: remove) }
            if let delete = onRemove[.signOutAndDelete] {
                Button(L10n.string("Sign Out and Delete…"), role: .destructive, action: delete)
            }
        }
    }

    private var title: String { style == .member ? memberTitle ?? choice.connectionTitle : choice.title }
    /// The organization beside an account's address; a member row names its connection instead.
    private var organization: String? { style == .member ? nil : choice.organizationTitle }
    private var subtitle: String { style == .member ? choice.subtitle : AccountListProjection.accountLine(choice) }
    /// Said only of an account that could otherwise be used: signed in, and left out.
    private var isExcludedFromAutomaticAssignment: Bool {
        automaticAssignment == false && choice.snapshot?.state == .signedIn
    }

    private var identityButton: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ParityTheme.accent : Color.secondary.opacity(canChoose ? 0.5 : 0.25))
                    .font(.system(size: 15))
                if showsHarness, let descriptor = HarnessCatalog.descriptor(for: choice.harness) {
                    HarnessLogoView(descriptor: descriptor, size: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    AccountTitleLine(title: title, organization: organization, weight: .medium)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if let freshness { AccountFreshnessLine(freshness: freshness) }
                    if isExcludedFromAutomaticAssignment {
                        Text(L10n.string("Excluded from automatic assignment"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row a task already runs under stays readable; it simply has nothing to do.
        .disabled(!canChoose && !selected)
        .allowsHitTesting(canChoose)
        .accessibilityLabel(title + (organization.map { ", " + $0 } ?? "") + ", " + subtitle
            + (isExcludedFromAutomaticAssignment ? ", " + L10n.string("Excluded from automatic assignment") : ""))
        .accessibilityValue(selected ? selectedValue : choice.status)
        .help(choice.snapshot?.detail ?? choice.status)
    }

    @ViewBuilder private var trailing: some View {
        if let usage, !usage.usageBlocks.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(usage.usageBlocks) { block in
                    AccountUsageBlockView(title: choice.title, block: block, resetChoice: usage.resetChoice(for: block))
                }
            }
        } else {
            Text(usage == nil ? choice.status : (usage?.usageUnavailableText ?? choice.usageUnavailableText))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 190, alignment: .trailing)
                .help(choice.snapshot?.detail ?? choice.status)
        }
    }
}

/// The name, provider, plan and freshness of an account several connections share, with its limits.
private struct AccountGroupHeader: View {
    let group: AccountGroup
    let freshness: AccountFreshness
    private var organization: String? { group.choices.lazy.compactMap(\.organizationTitle).first }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                AccountTitleLine(title: group.identity.displayLabel, organization: organization, weight: .semibold)
                Text(AccountListProjection.groupLine(group)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                AccountFreshnessLine(freshness: freshness)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(group.identity.displayLabel + (organization.map { ", " + $0 } ?? "") + ", "
                    + AccountListProjection.groupLine(group))
            if group.usageBlocks.isEmpty {
                Text(group.usageUnavailableText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 190, alignment: .trailing)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(group.usageBlocks) { block in
                        AccountUsageBlockView(title: group.identity.displayLabel, block: block,
                                              resetChoice: group.resetChoice(for: block))
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }
}

/// How a saved account leaves Settings › Accounts.
enum AccountRemoval: Hashable {
    /// Off Yardlet's list only; the login and its folder stay.
    case fromList
    /// Signed out by its CLI, then off the list with the folder Yardlet made in the Trash.
    case signOutAndDelete
}

/// An account's address with its organization after it ("· Personal", "· Example Team"), so one
/// address's two accounts read apart. In a narrow row the address shortens in the middle first,
/// because the organization is what tells the two apart.
struct AccountTitleLine: View {
    let title: String
    let organization: String?
    var weight: Font.Weight = .medium

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(organization == nil ? .tail : .middle)
            if let organization {
                Text("· " + organization).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
        }
        .font(.system(size: 13, weight: weight))
    }
}

/// Settings › Accounts' folders with a Claude or Codex login that are not saved accounts, each
/// with where it was found and a button that adds it as it is (or, for a Claude folder whose
/// conversations are apart, after showing what linking it would change).
struct DiscoveredAccountsSection: View {
    let homes: [DiscoveredAccountHome]
    let onAdd: (DiscoveredAccountHome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string("Accounts You Can Add"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(homes) { home in
                HStack(spacing: 12) {
                    if let descriptor = HarnessCatalog.descriptor(for: home.harness) {
                        HarnessLogoView(descriptor: descriptor, size: 24)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        AccountTitleLine(title: home.email ?? home.title,
                                         organization: home.email == nil ? nil
                                             : AccountIdentityProjection.organizationTitle(home.organization, of: home.email))
                        Text(home.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if home.harness == .claudeCode, !home.sharesConversations {
                            Text(L10n.string("Keeps its own conversation history"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Button(L10n.string("Add")) { onAdd(home) }.controlSize(.small)
                        .accessibilityLabel(L10n.format("Add %@", home.title))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .help(home.path)
            }
        }
    }
}

/// "Updated 3 min ago" under an account, with a spinner while a new check runs. A check that
/// could not finish says so next to the time of the reading still shown.
struct AccountFreshnessLine: View {
    let freshness: AccountFreshness

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = AccountFreshnessProjection.text(freshness, now: context.date) {
                HStack(spacing: 5) {
                    if freshness.isChecking { ProgressView().controlSize(.mini) }
                    Text(text).lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(freshness.status == .checkFailed && !freshness.isChecking
                    ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
        }
    }
}

/// One reading of an account's limits: the first two as limit window rows, and every limit with
/// its exact reset a click away. Resets of the limits the account holds show under them.
struct AccountUsageBlockView: View {
    let title: String
    let block: AccountUsageBlock
    /// The connection whose harness reported resets of these limits.
    var resetChoice: AccountChoice? = nil
    @State private var showsAllLimits = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let harnessTitle = block.title {
                Text(harnessTitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { showsAllLimits = true } label: {
                HStack(spacing: 10) {
                    AccountLimitWindowList(metrics: Array(block.metrics.prefix(2)), reset: .time)
                    VStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                        if block.metrics.count > 2 {
                            Text("+\(block.metrics.count - 2)").monospacedDigit()
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(lastChecked)
            .accessibilityLabel(L10n.string("View all limits"))
            .accessibilityValue(block.metrics.map { "\($0.label): \($0.detail)" }.joined(separator: ", "))
            .popover(isPresented: $showsAllLimits) {
                AccountLimitsView(title: title, metrics: block.metrics, checkedAt: block.checkedAt)
            }
            if let resetChoice { UsageResetButton(choice: resetChoice) }
        }
    }

    private var lastChecked: String {
        guard let checkedAt = block.checkedAt else { return "" }
        return L10n.format("Last checked: %@", checkedAt.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Every limit of one reading, with its exact reset, in the same rows as beside the account.
struct AccountLimitsView: View {
    let title: String
    let metrics: [AccountUsageMetric]
    let checkedAt: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Account limits")).font(.headline)
            Text(title).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            // As tall as its rows, up to the popover's limit.
            ScrollView {
                AccountLimitWindowList(metrics: metrics, reset: .absolute, fontSize: 12, rowSpacing: 8)
                    .padding(.vertical, 2)
            }
            .frame(maxHeight: 390)
            .fixedSize(horizontal: false, vertical: true)
            if let checkedAt {
                Text(L10n.format("Last checked: %@", checkedAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 500)
    }
}
