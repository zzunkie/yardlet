import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

enum ConnectionCenterTab { case accounts, harnesses }

/// Starts an accounts presentation's checks once and follows Codex's account notifications while
/// it is open. The owner applies it, so the checks keep running while the user moves between
/// Settings sections, and the notifications stop when the window closes. The readings belong to
/// the accounts store; a check another list already started is joined, and a reading confirmed
/// within the last minute is kept.
struct ConnectionCenterLifecycle: ViewModifier {
    let model: AccountCenterModel
    let connections: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
    /// False until the presentation first shows an accounts or harnesses page.
    let isActive: Bool
    let initialHarness: HarnessKind?
    var fixtureSnapshots: [HarnessAccountSnapshot]? = nil
    var fixtureLogin: (HarnessKind, AccountInteractiveCommand)? = nil
    @State private var followsLiveUpdates = false

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                guard isActive, model.claimInitialLoad() else { return }
                if let fixtureSnapshots {
                    connections.publishDefaults(fixtureSnapshots)
                    await connections.check(defaultsOf: [], savedOf: initialHarness.map { [$0] },
                        runtimeSelections: runtimeSelections)
                } else {
                    // Folders with a login that are not saved accounts, read from their names only.
                    await connections.findUnsavedAccountHomes()
                    // Every default login (the Harnesses page shows each) and the saved accounts
                    // the list opens on, side by side; every row keeps its last reading until its
                    // own answer arrives.
                    await connections.check(defaultsOf: nil, savedOf: initialHarness.map { [$0] },
                        runtimeSelections: runtimeSelections)
                    // Closed meanwhile: nothing is left to follow.
                    guard !Task.isCancelled else { return }
                    followsLiveUpdates = true
                    await connections.startLiveUpdates(runtimeSelections: runtimeSelections)
                }
                if let (harness, command) = fixtureLogin {
                    model.seedConnectionFlow(harness: harness, command: command)
                }
            }
            .onDisappear {
                model.closeConsole()
                guard followsLiveUpdates else { return }
                followsLiveUpdates = false
                Task { await connections.stopLiveUpdates() }
            }
    }
}

/// The accounts sheet a new task opens to add or connect an account; it returns to the task when
/// done. Account and harness management otherwise lives in Settings.
struct HarnessCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let runtimeSelections: RuntimeSelectionStore
    let initialHarness: HarnessKind?
    let initialChoice: AccountChoice?
    let returnsSetupToTask: Bool
    let fixtureSnapshots: [HarnessAccountSnapshot]?
    let fixtureLogin: (HarnessKind, AccountInteractiveCommand)?
    let localSessionUsage: LocalSessionUsageOverview?
    @State private var model: AccountCenterModel
    @State private var connections: ProviderConnectionStore
    @State private var tab: ConnectionCenterTab
    @State private var addingAccount: Bool
    @State private var setupExpanded = false

    init(
        runtimeSelections: RuntimeSelectionStore,
        connections: ProviderConnectionStore? = nil,
        initialTab: ConnectionCenterTab = .accounts,
        initialHarness: HarnessKind? = nil,
        addsAccount: Bool = false,
        initialChoice: AccountChoice? = nil,
        fixtureSnapshots: [HarnessAccountSnapshot]? = nil,
        fixtureLoginHarness: HarnessKind? = nil,
        fixtureLoginCommand: AccountInteractiveCommand? = nil,
        localSessionUsage: LocalSessionUsageOverview? = nil,
        codexEnvironmentManager: CodexEnvironmentManager? = nil
    ) {
        self.runtimeSelections = runtimeSelections
        self.initialHarness = initialHarness
        self.initialChoice = initialChoice
        self.returnsSetupToTask = addsAccount || initialChoice != nil
        self.fixtureSnapshots = fixtureSnapshots
        if let fixtureLoginHarness, let fixtureLoginCommand {
            fixtureLogin = (fixtureLoginHarness, fixtureLoginCommand)
        } else {
            fixtureLogin = nil
        }
        self.localSessionUsage = localSessionUsage
        _tab = State(initialValue: initialTab)
        _addingAccount = State(initialValue: addsAccount)
        let store = connections ?? ProviderConnectionStore()
        _connections = State(initialValue: store)
        _model = State(initialValue: AccountCenterModel(connections: store,
            codexEnvironmentManager: codexEnvironmentManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.string("Connections"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L10n.string("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.loginController.isRunning)
                    .controlSize(.small)
                    .parityPointer()
            }
            .padding(.horizontal, 14)
            .frame(height: ParityTheme.toolbarHeight)

            Rectangle().fill(ParityTheme.separator).frame(height: 1)

            if model.activeHarness == nil && !addingAccount {
                Picker(L10n.string("Connections"), selection: $tab) {
                    Text(L10n.string("Accounts")).tag(ConnectionCenterTab.accounts)
                    Text(L10n.string("Harnesses")).tag(ConnectionCenterTab.harnesses)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            ConnectionCenterContent(
                tab: tab, model: model, runtimeSelections: runtimeSelections, connections: connections,
                initialHarness: initialHarness, initialChoice: initialChoice,
                returnsSetupToTask: returnsSetupToTask, addingAccount: $addingAccount,
                setupExpanded: $setupExpanded, isFixture: fixtureSnapshots != nil,
                localSessionUsage: localSessionUsage, onFinish: { dismiss() }
            )
        }
        .frame(width: addingAccount && model.activeHarness == nil ? 560 : 780,
               height: addingAccount && model.activeHarness == nil ? (setupExpanded ? 540 : 380) : 620)
        .background(ParityTheme.canvas)
        .modifier(ConnectionCenterLifecycle(
            model: model, connections: connections, runtimeSelections: runtimeSelections,
            // Connecting a chosen account goes straight to its sign-in; the checks follow it.
            isActive: initialChoice == nil,
            initialHarness: initialHarness, fixtureSnapshots: fixtureSnapshots, fixtureLogin: fixtureLogin
        ))
    }
}

/// The Accounts and Harnesses pages: the account list with its add and sign-in steps, and the
/// harness list with each harness's runtime and connection. Settings shows each as a section;
/// the task account sheet shows them with a switch between the two.
struct ConnectionCenterContent: View {
    let tab: ConnectionCenterTab
    @Bindable var model: AccountCenterModel
    @Bindable var runtimeSelections: RuntimeSelectionStore
    let connections: ProviderConnectionStore
    var harnessUsage: AccountHarnessScope.Usage? = nil
    let initialChoice: AccountChoice?
    let returnsSetupToTask: Bool
    @Binding var addingAccount: Bool
    @Binding var setupExpanded: Bool
    let isFixture: Bool
    let localSessionUsage: LocalSessionUsageOverview?
    /// Called when an add or sign-in step that a task opened is over.
    let onFinish: () -> Void
    /// The tasks on a saved account, archived ones included; removing accounts is offered only with it.
    var tasksUsingAccount: ((ProviderConnection) -> AccountTaskCount)? = nil
    /// Moves an account's tasks to another folder of the same account, then removes it.
    var moveTasks: ((ProviderConnection, ProviderConnection) -> Void)? = nil
    @State private var pendingLogout: HarnessDescriptor?
    @State private var shareRequest: AccountHomeShareSheet.Request?
    @State private var pendingRemoval: (connection: ProviderConnection, kind: AccountRemoval)?
    @State private var movingRemoval: AccountRemovalSheet.Request?
    @State private var accountNote: String?
    @State private var selectedHarness: HarnessKind?
    @State private var showsLoginDetails = false
    @State private var searchText = ""
    @State private var filter: HarnessCenterFilter = .all
    @State private var hoveredHarness: HarnessKind?
    @State private var showsConnectionDetails = false
    @State private var runtimeVersionNote: HarnessRuntimeVersionNote?
    @State private var piProviderID = ""
    @State private var accountFilter: HarnessKind?
    @State private var connectChoice: AccountChoice?

    init(
        tab: ConnectionCenterTab,
        model: AccountCenterModel,
        runtimeSelections: RuntimeSelectionStore,
        connections: ProviderConnectionStore,
        harnessUsage: AccountHarnessScope.Usage? = nil,
        initialHarness: HarnessKind?,
        initialChoice: AccountChoice? = nil,
        returnsSetupToTask: Bool = false,
        addingAccount: Binding<Bool>,
        setupExpanded: Binding<Bool>,
        isFixture: Bool = false,
        localSessionUsage: LocalSessionUsageOverview? = nil,
        tasksUsingAccount: ((ProviderConnection) -> AccountTaskCount)? = nil,
        moveTasks: ((ProviderConnection, ProviderConnection) -> Void)? = nil,
        onFinish: @escaping () -> Void
    ) {
        self.tab = tab
        self.model = model
        self.runtimeSelections = runtimeSelections
        self.connections = connections
        self.harnessUsage = harnessUsage
        self.initialChoice = initialChoice
        self.returnsSetupToTask = returnsSetupToTask
        _addingAccount = addingAccount
        _setupExpanded = setupExpanded
        self.isFixture = isFixture
        self.localSessionUsage = localSessionUsage
        self.tasksUsingAccount = tasksUsingAccount
        self.moveTasks = moveTasks
        self.onFinish = onFinish
        _accountFilter = State(initialValue: initialHarness)
    }

    var body: some View {
        Group {
            if let activeHarness = model.activeHarness,
               let descriptor = HarnessCatalog.descriptor(for: activeHarness) {
                loginConsole(descriptor: descriptor)
            } else if addingAccount {
                AddProviderConnectionView(store: connections, runtimeSelections: runtimeSelections,
                    initialHarness: accountFilter, existingChoice: connectChoice, showsAdvanced: $setupExpanded,
                    closesOnCancel: returnsSetupToTask,
                    onCancel: {
                        if returnsSetupToTask { onFinish() }
                        else { addingAccount = false; connectChoice = nil; setupExpanded = false }
                    }, onLogin: startAccountLogin)
            } else if tab == .accounts {
                AccountList(mode: .manage, store: connections, runtimeSelections: runtimeSelections,
                    onChoose: { connections.choose($0) }, onConnect: connectAccount,
                    onAdd: { accountFilter = $0; connectChoice = nil; addingAccount = true },
                    onShare: share, onRemove: tasksUsingAccount == nil ? nil : { confirmRemoval($0, $1) },
                    onAddFound: addFound,
                    harnessFilter: $accountFilter, harnessUsage: harnessUsage)
                    .padding(.horizontal, 16).padding(.top, 16)
            } else if let selectedHarness,
                      let descriptor = HarnessCatalog.descriptor(for: selectedHarness) {
                harnessDetail(descriptor: descriptor)
            } else {
                harnessGrid
            }
        }
        .task {
            guard let initialChoice else { return }
            connectAccount(initialChoice)
        }
        .onChange(of: selectedHarness) { _, harness in
            showsConnectionDetails = harness.map { runtimeSelections.selectedURL(for: $0) == nil } ?? false
            if harness == .pi { piProviderID = HarnessAccountBroker.piConfiguredProvider(homePath: nil) ?? "" }
        }
        .onChange(of: model.activeHarness) { _, activeHarness in
            if activeHarness != nil { showsLoginDetails = false }
        }
        .alert(disconnectConfirmationTitle, isPresented: Binding(
            get: { pendingLogout != nil },
            set: { if !$0 { pendingLogout = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { pendingLogout = nil }
            Button(disconnectConfirmationAction, role: .destructive) {
                guard let descriptor = pendingLogout else { return }
                pendingLogout = nil
                Task { await model.logout(
                    descriptor: descriptor,
                    runtimeSelections: runtimeSelections
                ) }
            }
        } message: {
            Text(disconnectConfirmationMessage)
        }
        .sheet(item: $movingRemoval) { request in
            AccountRemovalSheet(request: request,
                onMove: { target in movingRemoval = nil; moveTasks?(request.connection, target) },
                onRemove: { movingRemoval = nil; remove(request.connection, .fromList) },
                onCancel: { movingRemoval = nil })
        }
        .sheet(item: $shareRequest) { request in
            AccountHomeShareSheet(request: request, defaultFolder: connections.claudeDefaultHome,
                onShare: { shareRequest = nil; finishSharing(request, links: true) },
                onKeep: { shareRequest = nil; finishSharing(request, links: false) },
                onCancel: { shareRequest = nil })
        }
        .alert(removalTitle, isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button(L10n.string("Cancel"), role: .cancel) { pendingRemoval = nil }
            if let pending = pendingRemoval {
                // A folder tasks still run in is only taken off the list.
                if pending.kind == .signOutAndDelete, tasksUsing(pending.connection) == 0 {
                    Button(L10n.string("Sign Out and Delete"), role: .destructive) { remove(pending.connection, .signOutAndDelete) }
                } else {
                    Button(L10n.string("Remove from List"), role: .destructive) { remove(pending.connection, .fromList) }
                }
            }
        } message: {
            Text(removalMessage)
        }
        .alert(L10n.string("Accounts"), isPresented: Binding(
            get: { accountNote != nil },
            set: { if !$0 { accountNote = nil } }
        )) {
            Button(L10n.string("OK")) { accountNote = nil }
        } message: {
            Text(accountNote ?? "")
        }
    }

    // MARK: Account folders

    /// Adds a found folder as it is, unless it is a Claude folder that linking would change: then
    /// the sheet shows what would change first, and the person chooses.
    private func addFound(_ found: DiscoveredAccountHome) {
        if let plan = connections.sharingPlan(for: found.connection), plan.hasChanges || !plan.sharesConversations {
            shareRequest = AccountHomeShareSheet.Request(connection: found.connection, found: found, plan: plan)
        } else {
            finishSharing(AccountHomeShareSheet.Request(connection: found.connection, found: found,
                plan: ClaudeAccountHome.Plan()), links: false)
        }
    }

    private func share(_ connection: ProviderConnection) {
        guard let plan = connections.sharingPlan(for: connection) else { return }
        shareRequest = AccountHomeShareSheet.Request(connection: connection, found: nil, plan: plan)
    }

    private func finishSharing(_ request: AccountHomeShareSheet.Request, links: Bool) {
        do {
            if let found = request.found { try connections.add(found) }
            if links { try connections.share(request.connection, plan: request.plan) }
        } catch {
            accountNote = error.localizedDescription
        }
        Task {
            await connections.check(defaultsOf: [], savedOf: [request.connection.harness],
                connectionIDs: [request.connection.id], policy: .restart, runtimeSelections: runtimeSelections)
        }
    }

    private func tasksUsing(_ connection: ProviderConnection) -> Int { tasksUsingAccount?(connection).total ?? 0 }

    /// Removing an account whose tasks could go on under another folder of the same account offers to
    /// move them there first; any other removal is confirmed as before.
    private func confirmRemoval(_ connection: ProviderConnection, _ kind: AccountRemoval) {
        let tasks = tasksUsingAccount?(connection) ?? AccountTaskCount()
        let targets = connections.taskMoveTargets(for: connection)
        guard kind == .fromList, moveTasks != nil, tasks.total > 0, !targets.isEmpty else {
            pendingRemoval = (connection, kind)
            return
        }
        let choices = connections.choices(for: [connection.harness], includingMoving: true)
        movingRemoval = AccountRemovalSheet.Request(connection: connection, targets: targets.map { target in
            AccountRemovalSheet.Target(connection: target, title: choices.first { $0.connection?.id == target.id }
                .map { AccountGroupProjection.memberTitle($0, among: choices) } ?? target.name)
        }, tasks: tasks)
    }

    private var removalTitle: String {
        guard let pending = pendingRemoval else { return "" }
        return L10n.format(pending.kind == .fromList ? "Remove %@ from the List?" : "Sign Out of %@ and Delete It?", pending.connection.name)
    }

    /// One or two sentences, as the Claude and Codex apps confirm a sign-out: what stays, what goes,
    /// and what happens to the account's tasks.
    private var removalMessage: String {
        guard let pending = pendingRemoval else { return "" }
        let connection = pending.connection
        let tasks = tasksUsing(connection)
        switch pending.kind {
        case .fromList:
            return tasks == 0 ? L10n.string("The login and its folder stay.")
                : L10n.format("The login and its folder stay. The %lld tasks on this account go on in that folder as before.",
                              Int64(tasks))
        case .signOutAndDelete:
            guard tasks == 0 else {
                return L10n.format("%lld tasks on this account use its folder, so deleting it would stop them. Remove the account from the list instead; the folder stays.",
                                   Int64(tasks))
            }
            return L10n.string(connections.keepsConversationsInDefaultFolder(connection)
                ? "The folder Yardlet made for this account goes to the Trash. Conversations and settings stay in the default folder."
                : "The folder Yardlet made for this account goes to the Trash, with the conversations kept only there.")
        }
    }

    private func remove(_ connection: ProviderConnection, _ kind: AccountRemoval) {
        pendingRemoval = nil
        Task {
            do {
                switch kind {
                case .fromList: try connections.remove(connection)
                case .signOutAndDelete:
                    try await connections.signOutAndDelete(connection,
                        executableURL: runtimeSelections.selectedURL(for: connection.harness))
                }
            } catch {
                accountNote = error.localizedDescription
            }
            await connections.findUnsavedAccountHomes()
        }
    }

    private var filteredHarnesses: [HarnessDescriptor] {
        HarnessCatalog.builtIns.filter {
            HarnessCenterListingProjection.matches($0, snapshot: connections.defaultSnapshots[$0.id], query: searchText,
                filter: .all)
                && (filter == .all || (filter == .connected) == (runtimeSelections.selectedURL(for: $0.id) != nil))
        }
    }

    /// Checks a harness's accounts again after its sign-in console ran: the login may have
    /// changed, so a check that started before is not reused. A fixture's default logins stay.
    private func recheckAccounts(of harness: HarnessKind) async {
        await connections.check(defaultsOf: isFixture ? [] : [harness], savedOf: [harness], policy: .restart,
            runtimeSelections: runtimeSelections)
    }

    private func connectAccount(_ choice: AccountChoice) {
        if choice.harness == .pi && choice.connection?.providerID == nil {
            accountFilter = choice.harness
            connectChoice = choice
            addingAccount = true
        } else { startAccountLogin(choice.harness, choice.connection) }
    }

    private func startAccountLogin(_ harness: HarnessKind, _ connection: ProviderConnection?) {
        guard let descriptor = HarnessCatalog.descriptor(for: harness) else { return }
        addingAccount = false
        connectChoice = nil
        Task { await model.login(descriptor: descriptor, connection: connection, runtimeSelections: runtimeSelections) }
    }

    private var harnessGrid: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.string("Search harnesses"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).parityPointer()
                            .accessibilityLabel(L10n.string("Clear search"))
                    }
                }
                .padding(10)
                .background(ParityTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                HStack(spacing: 12) {
                    Picker(L10n.string("Connection status"), selection: $filter) {
                        ForEach(HarnessCenterFilter.allCases) { item in
                            Text(L10n.string(item == .all ? "All" : item == .connected ? "Installed" : "Not installed")).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if !isFixture {
                        Button {
                            Task { await connections.check(savedOf: [], policy: .refresh,
                                runtimeSelections: runtimeSelections) }
                        } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.string("Refresh"))
                        .accessibilityLabel(L10n.string("Refresh"))
                        .disabled(HarnessCatalog.builtIns.contains { connections.isCheckingDefault($0.id) })
                        .parityPointer()
                    }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                if filteredHarnesses.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text(L10n.string("No matching harnesses")).font(.headline)
                        Button(L10n.string("Show all harnesses")) { searchText = ""; filter = .all }
                            .parityPointer()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 46)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHarnesses) { descriptor in
                            harnessRow(descriptor)
                            if descriptor.id != filteredHarnesses.last?.id {
                                Divider().padding(.leading, 50).padding(.trailing, 10)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func harnessRow(_ descriptor: HarnessDescriptor) -> some View {
        let installed = runtimeSelections.selectedURL(for: descriptor.id) != nil
        let status = L10n.string(installed ? "Installed" : "Not installed")
        return Button { selectedHarness = descriptor.id } label: {
            HStack(spacing: 12) {
                HarnessLogoView(descriptor: descriptor, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 12)
                Label(status, systemImage: installed ? "checkmark.circle" : "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                hoveredHarness == descriptor.id ? ParityTheme.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).parityPointer()
        .onHover { hovering in
            if hovering { hoveredHarness = descriptor.id }
            else if hoveredHarness == descriptor.id { hoveredHarness = nil }
        }
        .accessibilityLabel(descriptor.displayName)
        .accessibilityValue(status)
    }

    private func accountLabel(_ snapshot: HarnessAccountSnapshot) -> String? {
        let account = snapshot.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return account?.isEmpty == false ? account : nil
    }

    private func harnessDetail(descriptor: HarnessDescriptor) -> some View {
        let snapshot = connections.defaultSnapshots[descriptor.id]
        // The accounts this harness's tasks start on. With saved accounts the default login is one
        // way in among them, not the harness's state.
        let accounts = connections.choices(for: [descriptor.id])
        let hasSavedAccounts = accounts.contains { $0.connection != nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        selectedHarness = nil
                    } label: {
                        Label(L10n.string("Back"), systemImage: "chevron.left")
                    }
                    .controlSize(.small)
                    .parityPointer()
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    HarnessLogoView(descriptor: descriptor, size: 42)

                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(descriptor.displayName)
                                .font(.system(size: 16, weight: .semibold))
                            if hasSavedAccounts {
                                Text(accounts.map(\.title).joined(separator: ", "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                if let summary = accountSummary(snapshot, harness: descriptor.id) {
                                    Text(summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                if let snapshot {
                                    Text(snapshot.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(descriptor.displayName)
                        .accessibilityValue(hasSavedAccounts
                            ? ([accountsStatus(accounts)] + accounts.map(\.title)).joined(separator: ", ")
                            : AccountAccessibilityProjection.value(for: snapshot))
                        if hasSavedAccounts, let snapshot {
                            HStack(spacing: 8) {
                                Text(L10n.string("Default login") + " · " + AccountConnectionPresentation.status(for: snapshot))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                defaultLoginButton(descriptor: descriptor, snapshot: snapshot)
                            }
                        }
                    }

                    Spacer()
                    if hasSavedAccounts {
                        let state = accountsState(accounts)
                        Label(accountsStatus(accounts), systemImage: stateSymbol(state))
                            .font(.system(size: 10.5))
                            .foregroundStyle(stateColor(state))
                            .accessibilityHidden(true)
                    } else {
                        accountActions(descriptor: descriptor, snapshot: snapshot)
                    }
                }
                .padding(14)
                .parityCard()

                HStack(spacing: 12) {
                    Label(L10n.string(runtimeSelections.selectedURL(for: descriptor.id) == nil ? "Runtime unavailable" : "Runtime ready"), systemImage: "terminal")
                    Spacer()
                    Text(HarnessConnectionCapabilities.capabilities(for: descriptor.id).access.title)
                        .foregroundStyle(.secondary)
                }.font(.callout).padding(14).parityCard()

                if AccountConnectionPresentation.usesProviderLanguage(descriptor.id) {
                    providerConnectionSection(descriptor: descriptor, snapshot: snapshot)
                        .padding(14)
                        .parityCard()
                }

                DisclosureGroup(L10n.string("Runtime and connection details"), isExpanded: $showsConnectionDetails) {
                    VStack(alignment: .leading, spacing: 14) {
                        runtimeSection(descriptor)
                        if let snapshot {
                            Divider()
                            Text(L10n.format("Stored by: %@", snapshot.credentialOwner))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(L10n.format("Last checked: %@", snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.callout.weight(.medium))
                .padding(14)
                .parityCard()

                if let snapshot, !snapshot.usage.isEmpty {
                    // The default login's limits as the account list draws them, then its totals. The
                    // day-by-day history is a series, which the Codex app draws as a chart, not rows.
                    let quotas = snapshot.usage.filter { $0.evidence == .exactQuota }
                    let totals = snapshot.usage.filter {
                        $0.evidence != .exactQuota && !$0.id.hasPrefix(HarnessAccountBroker.dailyUsageIDPrefix)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.string("Usage"))
                                .font(.system(size: 12, weight: .semibold))
                            if let account = accountLabel(snapshot) {
                                Text(account).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let freshness = AccountFreshnessProjection.text(
                                checkedAt: snapshot.checkedAt,
                                status: connections.readingStatus[AccountSnapshotCache.defaultKey(for: descriptor.id)],
                                isChecking: connections.isCheckingDefault(descriptor.id)) {
                                Text(freshness).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        if !quotas.isEmpty {
                            AccountLimitWindowList(metrics: quotas, reset: .absolute, fontSize: 11.5, rowSpacing: 6)
                        }
                        ForEach(totals) { metric in
                            usageRow(metric, leadingPadding: 0)
                        }
                    }
                    .padding(14)
                    .parityCard()
                }

                if let localSessionUsage,
                   localSessionUsage.harness == descriptor.id {
                    localSessionUsageSection(localSessionUsage)
                        .padding(14)
                        .parityCard()
                }
            }
            .padding(14)
        }
        .background(ParityTheme.canvas)
    }

    @ViewBuilder
    private func accountActions(
        descriptor: HarnessDescriptor,
        snapshot: HarnessAccountSnapshot?
    ) -> some View {
        VStack(alignment: .trailing, spacing: 7) {
            if let snapshot {
                Label(
                    AccountConnectionPresentation.status(for: snapshot),
                    systemImage: stateSymbol(snapshot.state)
                )
                    .font(.system(size: 10.5))
                    .foregroundStyle(stateColor(snapshot.state))
                    .accessibilityHidden(true)
                if !AccountConnectionPresentation.usesProviderLanguage(descriptor.id),
                   snapshot.canLogin {
                    Button(AccountConnectionPresentation.connectAction(for: descriptor.id)) {
                        Task { await model.login(
                            descriptor: descriptor,
                            runtimeSelections: runtimeSelections
                        ) }
                    }
                    .controlSize(.small)
                    .parityPointer()
                } else if !AccountConnectionPresentation.usesProviderLanguage(descriptor.id),
                          snapshot.canLogout {
                    Button(AccountConnectionPresentation.disconnectAction(for: descriptor.id)) {
                        pendingLogout = descriptor
                    }
                    .controlSize(.small)
                    .parityPointer()
                }
            } else if connections.isCheckingDefault(descriptor.id) {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// A harness with saved accounts is connected when any of them is; otherwise it is as its first
    /// reading says.
    private func accountsState(_ accounts: [AccountChoice]) -> AccountAuthState {
        accounts.contains { $0.snapshot?.state == .signedIn } ? .signedIn
            : accounts.compactMap(\.snapshot?.state).first ?? .unknown
    }

    private func accountsStatus(_ accounts: [AccountChoice]) -> String {
        let state = accountsState(accounts)
        return state == .signedIn ? L10n.string("Connected") : state.displayName
    }

    /// Signing the default login in or out, beside its line when the harness also has saved accounts.
    @ViewBuilder
    private func defaultLoginButton(descriptor: HarnessDescriptor, snapshot: HarnessAccountSnapshot) -> some View {
        if !AccountConnectionPresentation.usesProviderLanguage(descriptor.id), snapshot.canLogin {
            Button(AccountConnectionPresentation.connectAction(for: descriptor.id)) {
                Task { await model.login(descriptor: descriptor, runtimeSelections: runtimeSelections) }
            }
            .controlSize(.mini)
            .parityPointer()
        } else if !AccountConnectionPresentation.usesProviderLanguage(descriptor.id), snapshot.canLogout {
            Button(AccountConnectionPresentation.disconnectAction(for: descriptor.id)) { pendingLogout = descriptor }
                .controlSize(.mini)
                .parityPointer()
        }
    }

    private func providerConnectionSection(
        descriptor: HarnessDescriptor,
        snapshot: HarnessAccountSnapshot?
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(ParityTheme.accent)
                Text(L10n.string("Model provider"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(AccountConnectionPresentation.providerBadge(for: descriptor.id))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(ParityTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ParityTheme.subtleFill, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AccountConnectionPresentation.providerTitle(for: descriptor.id))
                    .font(.system(size: 11.5, weight: .medium))
                Text(AccountConnectionPresentation.providerDescription(for: descriptor.id))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if snapshot?.canLogin == true {
                    if descriptor.id == .pi {
                        PiConnectionProviderPicker(selection: $piProviderID)
                            .frame(maxWidth: 260)
                    }
                    Button(AccountConnectionPresentation.connectAction(for: descriptor.id)) {
                        Task { await model.login(
                            descriptor: descriptor,
                            connection: descriptor.id == .pi ? ProviderConnection(id: "pi-configured", name: "Pi",
                                harness: .pi, providerID: piProviderID, homePath: nil, credentialSelector: nil) : nil,
                            runtimeSelections: runtimeSelections
                        ) }
                    }
                    .disabled(descriptor.id == .pi && piProviderID.isEmpty)
                    .controlSize(.small)
                    .parityPointer()
                }
                if snapshot?.canLogout == true {
                    Button(AccountConnectionPresentation.disconnectAction(for: descriptor.id)) {
                        pendingLogout = descriptor
                    }
                    .controlSize(.small)
                    .parityPointer()
                }
            }


        }
        .accessibilityElement(children: .contain)
    }

    private func runtimeSection(_ descriptor: HarnessDescriptor) -> some View {
        let runtime = runtimeSelections.selectedURL(for: descriptor.id)
        let compatibility = HarnessRuntimeVersionNote.compatibility(for: descriptor.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(ParityTheme.accent)
                Text(L10n.string("Runtime"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.string("Choose…")) {
                    chooseRuntime(for: descriptor.id)
                }
                .controlSize(.small)
                .parityPointer()
            }

            if let runtime {
                Label(L10n.string("Available"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
                Text(runtime.path(percentEncoded: false))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if compatibility != nil, let runtimeVersionNote {
                    Text(runtimeVersionNote.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(runtimeVersionNote.standing == .verified ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(L10n.string("Not installed"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .task(id: runtimeVersionProbeKey(descriptor.id, runtime)) {
            // A note belongs to the harness it was read from, so the previous one never
            // survives a harness or runtime change.
            runtimeVersionNote = nil
            guard let compatibility, let runtime else { return }
            // `<runtime> --version` only; no home, account, or thread is touched.
            let note = await Task.detached(priority: .utility) {
                HarnessRuntimeVersionNote.read(
                    executableURL: runtime,
                    compatibility: compatibility
                )
            }.value
            guard !Task.isCancelled else { return }
            runtimeVersionNote = note
        }
    }

    /// Non-nil only for harnesses whose runtime version Yardlet reports, so the version line is
    /// read again when the selected harness or its runtime path changes.
    private func runtimeVersionProbeKey(_ harness: HarnessKind, _ runtime: URL?) -> String? {
        guard HarnessRuntimeVersionNote.compatibility(for: harness) != nil else { return nil }
        return "\(harness.rawValue)|\(runtime?.path(percentEncoded: false) ?? "")"
    }

    private func chooseRuntime(for harness: HarnessKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Select runtime")
        if panel.runModal() == .OK, let url = panel.url {
            runtimeSelections.select(url, for: harness)
            // A check that started with the previous runtime does not describe this one.
            Task { await connections.check(defaultsOf: [harness], savedOf: [harness], policy: .restart,
                runtimeSelections: runtimeSelections) }
        }
    }

    private func localSessionUsageSection(
        _ overview: LocalSessionUsageOverview
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(ParityTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Thread usage"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(overview.taskTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.string("Thread usage"))
            .accessibilityValue(
                [overview.taskTitle, L10n.string("Local session usage")]
                    .joined(separator: ", ")
            )

            ForEach(overview.metrics) { metric in
                usageRow(metric, leadingPadding: 0)
            }
        }
    }

    private func accountSummary(_ snapshot: HarnessAccountSnapshot?, harness: HarnessKind) -> String? {
        guard let snapshot else {
            return L10n.string(connections.isCheckingDefault(harness) ? "Checking account status…" : "Unknown")
        }
        return snapshot.state == .signedIn ? accountLabel(snapshot) : nil
    }

    private var disconnectConfirmationTitle: String {
        guard let pendingLogout else { return L10n.string("Sign out?") }
        return AccountConnectionPresentation.usesProviderLanguage(pendingLogout.id)
            ? L10n.string("Disconnect provider?")
            : L10n.string("Sign out?")
    }

    private var disconnectConfirmationAction: String {
        guard let pendingLogout else { return L10n.string("Sign out") }
        return AccountConnectionPresentation.disconnectAction(for: pendingLogout.id)
    }

    private var disconnectConfirmationMessage: String {
        guard let pendingLogout else {
            return L10n.string("The selected CLI will remove its own stored account credentials.")
        }
        return AccountConnectionPresentation.usesProviderLanguage(pendingLogout.id)
            ? L10n.string("The selected CLI will remove its own stored provider credentials.")
            : L10n.string("The selected CLI will remove its own stored account credentials.")
    }

    private func usageRow(
        _ metric: AccountUsageMetric,
        leadingPadding: CGFloat = 39
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.label).font(.system(size: 11, weight: .medium))
                Text(metric.evidence.displayName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(metric.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if let usedFraction = metric.usedFraction {
                ProgressView(value: min(max(1 - usedFraction, 0), 1))
                    .tint(usedFraction >= 0.9 ? .orange : ParityTheme.accent)
                if let resetsAt = metric.resetsAt {
                    Text(L10n.format(
                        "Resets %@",
                        resetsAt.formatted(date: .abbreviated, time: .shortened)
                    ))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, leadingPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.label)
        .accessibilityValue(AccountUsageAccessibilityProjection.value(for: metric))
    }

    private func loginConsole(descriptor: HarnessDescriptor) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.closeConsole()
                    Task { await recheckAccounts(of: descriptor.id) }
                } label: {
                    Label(L10n.string("Back"), systemImage: "chevron.left")
                }
                .parityPointer()
                .disabled(model.loginController.isRunning)
                Spacer()
                HStack(spacing: 7) {
                    HarnessLogoView(descriptor: descriptor, size: 20)
                    Text(descriptor.displayName)
                        .font(.headline)
                }
                Spacer()
                if model.loginController.isRunning {
                    Button(L10n.string("Cancel"), role: .destructive) { model.loginController.cancel() }
                        .parityPointer()
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 16) {
                Spacer(minLength: 4)

                HarnessLogoView(descriptor: descriptor, size: 52)

                VStack(spacing: 6) {
                    Text(connectionHeading(descriptor: descriptor))
                        .font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        if model.loginController.phase == .preparing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: connectionPhaseSymbol)
                        }
                        Text(connectionPhaseTitle)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(connectionPhaseColor)
                    Text(connectionPhaseDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }

                if let code = model.loginController.detectedCode {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.string("Verification code"))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(L10n.string("Copy code")) {
                            model.loginController.copyDetectedCode()
                        }
                        .controlSize(.small)
                        .parityPointer()
                    }
                    .padding(11)
                    .frame(maxWidth: 430)
                    .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9).stroke(ParityTheme.separator)
                    }
                }

                HStack(spacing: 8) {
                    if model.loginController.detectedURL != nil {
                        Button(L10n.string("Continue in browser")) {
                            model.loginController.openDetectedURL()
                        }
                        .parityProminentButton()
                        .controlSize(.small)
                        .parityPointer()
                    }
                    if model.loginController.phase == .inputRequired,
                       !showsLoginDetails {
                        Button(L10n.string("Continue setup")) {
                            showsLoginDetails = true
                        }
                        .parityProminentButton()
                        .controlSize(.small)
                        .parityPointer()
                    }
                    if !model.loginController.isRunning {
                        Button(L10n.string(model.loginController.phase == .completed ? "Use this account" : "Back")) {
                            if model.loginController.phase == .completed {
                                let binding = model.activeConnection.flatMap { active in connections.connections.first { $0.id == active.id } }
                                connections.selection[descriptor.id] = binding?.id
                                model.closeConsole()
                                onFinish()
                            } else {
                                model.closeConsole()
                                Task { await recheckAccounts(of: descriptor.id) }
                            }
                        }
                        .controlSize(.small)
                        .parityPointer()
                    }
                }

                Spacer(minLength: 2)

                Button {
                    showsLoginDetails.toggle()
                } label: {
                    Label(
                        L10n.string(showsLoginDetails ? "Hide CLI details" : "Show CLI details"),
                        systemImage: showsLoginDetails ? "chevron.down" : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .parityPointer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, showsLoginDetails ? 10 : 18)

            AccountLoginTerminalHost(
                controller: model.loginController,
                isVisible: showsLoginDetails
            )
            .frame(maxWidth: .infinity)
            .frame(height: showsLoginDetails ? 175 : 1)
            .opacity(showsLoginDetails ? 1 : 0)
            .clipped()
            .allowsHitTesting(showsLoginDetails)
            .background(Color(nsColor: NativeTerminalSession.backgroundColor))
            .accessibilityHidden(!showsLoginDetails)
            .accessibilityLabel(L10n.string("Interactive CLI terminal"))
            .accessibilityHint(L10n.string(
                "Click the terminal, then type or paste the response requested by the CLI."
            ))

            if showsLoginDetails {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text(L10n.string("Type directly in the terminal. Paste with Command-V."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.loginController.isRunning {
                        Button { model.loginController.moveUp() } label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel(L10n.string("Move up"))
                            .controlSize(.small)
                            .parityPointer()
                        Button { model.loginController.moveDown() } label: { Image(systemName: "arrow.down") }
                            .accessibilityLabel(L10n.string("Move down"))
                            .controlSize(.small)
                            .parityPointer()
                        Button(L10n.string("Enter")) { model.loginController.pressEnter() }
                            .controlSize(.small)
                            .parityPointer()
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
        .onChange(of: model.loginController.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            Task { await recheckAccounts(of: descriptor.id) }
        }
    }

    private func connectionHeading(descriptor: HarnessDescriptor) -> String {
        if let connection = model.activeConnection { return connection.name + " · " + descriptor.displayName }
        return switch model.loginController.operation {
        case .connect:
            L10n.format("Connect %@", descriptor.displayName)
        case .disconnect:
            L10n.format("Disconnect %@", descriptor.displayName)
        }
    }

    private var connectionPhaseTitle: String {
        switch model.loginController.phase {
        case .preparing: L10n.string("Preparing secure connection…")
        case .browserHandoff: L10n.string("Continue in your browser")
        case .inputRequired: L10n.string("One more setup step is required")
        case .completed: L10n.string("Connection flow completed")
        case .failed: L10n.string("Connection could not be completed")
        case .cancelled: L10n.string("Connection cancelled")
        }
    }

    private var connectionPhaseDetail: String {
        switch model.loginController.phase {
        case .preparing:
            L10n.string("Yardlet is waiting for the harness to prepare its secure sign-in flow.")
        case .browserHandoff:
            L10n.string("Complete account selection and approval in the browser. Yardlet never receives your password.")
        case .inputRequired:
            L10n.string("This harness owns the next provider or method choice. Continue in its setup controls below.")
        case .completed:
            L10n.string("The harness finished its account flow. Return to verify the current connection state.")
        case .failed:
            L10n.string("Open CLI details for the runtime error, then retry from the harness page.")
        case .cancelled:
            L10n.string("No account change was completed. You can return and try again.")
        }
    }

    private var connectionPhaseSymbol: String {
        switch model.loginController.phase {
        case .preparing: "arrow.triangle.2.circlepath"
        case .browserHandoff: "safari"
        case .inputRequired: "list.bullet.rectangle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var connectionPhaseColor: SwiftUI.Color {
        switch model.loginController.phase {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .preparing, .browserHandoff, .inputRequired: ParityTheme.accent
        }
    }

    private func stateSymbol(_ state: AccountAuthState) -> String {
        switch state {
        case .signedIn: "checkmark.circle.fill"
        case .signedOut: "person.crop.circle.badge.xmark"
        case .actionRequired: "exclamationmark.circle"
        case .unavailable: "slash.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func stateColor(_ state: AccountAuthState) -> SwiftUI.Color {
        switch state {
        case .signedIn: .green
        case .signedOut, .actionRequired: .orange
        case .unavailable, .unknown: .secondary
        }
    }
}

private struct AccountLoginTerminalHost: NSViewRepresentable {
    let controller: AccountLoginController
    let isVisible: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = AccountLoginTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 5_000)
        )
        view.wantsLayer = true
        view.nativeForegroundColor = NativeTerminalSession.foregroundColor
        view.nativeBackgroundColor = NativeTerminalSession.backgroundColor
        view.layer?.backgroundColor = NativeTerminalSession.backgroundColor.cgColor
        view.caretColor = NSColor.systemBlue
        view.getTerminal().setCursorStyle(CursorStyle.steadyBlock)
        view.metalBufferingMode = MetalBufferingMode.perFrameAggregated
        try? view.setUseMetal(false)
        controller.attach(view)
        context.coordinator.wasVisible = isVisible
        if isVisible { view.requestFocus() }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if isVisible, !context.coordinator.wasVisible,
           let view = nsView as? AccountLoginTerminalView {
            view.requestFocus()
        }
        context.coordinator.wasVisible = isVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.controller.detach(nsView)
    }

    @MainActor
    final class Coordinator {
        let controller: AccountLoginController
        var wasVisible = false

        init(controller: AccountLoginController) {
            self.controller = controller
        }
    }
}

/// The login console's terminal. SwiftTerm reports that a process exited and delivers what it
/// printed on separate paths, so the exit can come before the last lines; the view passes each
/// delivery on, so those lines still reach `AccountLoginController.output`.
final class AccountLoginTerminalView: LocalProcessTerminalView {
    var onOutput: (@MainActor () -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    func requestFocus() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct HarnessLogoView: View {
    let descriptor: HarnessDescriptor
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(ParityTheme.subtleFill)
            if let image = HarnessLogoCatalog.image(for: descriptor.id) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: descriptor.symbolName)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(ParityTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }
}
