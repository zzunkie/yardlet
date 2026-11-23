import SwiftUI
import YardletRemote

/// Remote Mac Settings (§15.36) and Harness Accounts (§15.37) overview on iOS.
/// Strictly read-only when the paired device lacks `Change settings` permission on the host Mac.
struct HostSettingsView: View {
    let session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false
    @State private var isWatching = false
    @State private var showsInstructionsEditor = false
    @State private var activeAlert: ActiveAlert?

    private enum ActiveAlert: Identifiable {
        case setting(SettingConfirmation)
        case cliUpdate(CLIActionConfirmation)

        var id: String {
            switch self {
            case let .setting(confirmation): "setting:\(confirmation.id)"
            case let .cliUpdate(action): "cli:\(action.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case let .setting(confirmation): confirmation.title
            case let .cliUpdate(action): action.title
            }
        }

        var message: String {
            switch self {
            case let .setting(confirmation): confirmation.message
            case let .cliUpdate(action): action.message
            }
        }
    }

    private struct SettingConfirmation: Identifiable {
        let id: String
        let title: String
        let message: String
        let targetValue: String
    }

    private struct CLIActionConfirmation: Identifiable {
        let id = UUID()
        let action: String
        let harness: String
        let title: String
        let message: String
        let confirmLabel: String
    }

    private var settings: RemoteHostSettings? { session.hostSettings }
    private var accounts: RemoteAccountsState? { session.hostAccounts }

    private var isWritable: Bool {
        if let settings { return settings.writable }
        if let accounts { return accounts.editable == true }
        return false
    }

    private var runningTaskCount: Int {
        session.tasks.filter(\.running).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    if !session.isConnected {
                        offlineCard
                    } else if !session.capabilities.hostSettings && !session.capabilities.hostAccounts {
                        unsupportedCard
                    } else if settings == nil && accounts == nil {
                        loadingCard
                    } else {
                        if !isWritable {
                            readOnlyBanner
                        }
                        if let usage = settings?.usage {
                            usageSection(usage)
                        }
                        if session.capabilities.hostAccounts {
                            connectorsEntrySection
                        }
                        if let accounts {
                            harnessAccountsSection(accounts)
                        }
                        if let settings {
                            generalSettingsSection(settings)
                        }
                        if let instructions = settings?.instructions {
                            instructionsSection(instructions)
                        }
                        if let cliUpdates = settings?.cliUpdates {
                            cliUpdatesSection(cliUpdates)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(YardletPalette.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.commandError != nil {
                    CommandErrorBanner(session: session)
                        .padding(.bottom, 8)
                }
            }
            .refreshable {
                await refreshAll()
            }
            .navigationTitle("Host Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(!session.isConnected || isRefreshing)
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsInstructionsEditor) {
                InstructionsEditorSheet(
                    hostName: session.name,
                    initialText: settings?.instructions?.text ?? "",
                    writable: isWritable
                ) { updatedText in
                    await session.saveHostInstructions(text: updatedText)
                }
            }
            .alert(
                activeAlert?.title ?? "",
                isPresented: Binding(
                    get: { activeAlert != nil },
                    set: { if !$0 { activeAlert = nil } }
                ),
                presenting: activeAlert
            ) { alert in
                switch alert {
                case let .setting(confirmation):
                    Button("Confirm") {
                        Task {
                            _ = await session.setHostSetting(
                                id: confirmation.id,
                                value: confirmation.targetValue,
                                confirmed: true
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                case let .cliUpdate(action):
                    Button(action.confirmLabel) {
                        Task {
                            _ = await session.runHostCLIUpdate(action: action.action, harness: action.harness)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
        }
        .onAppear {
            guard !isWatching else { return }
            isWatching = true
            session.beginWatchingHostSettings()
            session.beginWatchingHostAccounts()
        }
        .onDisappear {
            guard isWatching else { return }
            isWatching = false
            session.endWatchingHostSettings()
            session.endWatchingHostAccounts()
        }
    }

    // MARK: - Header & Status Cards

    private var headerCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
            HStack(spacing: 12) {
                ConnectionStatusDot(connection: session.connection, size: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: session.name)
                        .font(.headline)
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)
                    Text(session.isConnected ? String(localized: "Remote Mac") : String(localized: "Offline"))
                        .font(.footnote)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                Spacer(minLength: 8)
                if settings != nil || accounts != nil {
                    HStack(spacing: 5) {
                        StatusDot(
                            color: isWritable ? YardletPalette.Status.connected : YardletPalette.Status.running,
                            size: 7
                        )
                        Text(isWritable ? "Editable" : "Read-only")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(YardletPalette.surfaceContainer, in: Capsule())
                    .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
                }
            }
        }
    }

    private var readOnlyBanner: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainer, padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-only access")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurface)
                    Text("To change settings from here, allow Change settings for this device in Settings › Remote › Paired devices on \(session.name).")
                        .font(.footnote)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var offlineCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not Connected")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text("Connect to \(session.name) to view and manage its settings.")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Button("Retry") { session.reconnectNow() }
                    .prominentButton()
            }
        }
    }

    private var unsupportedCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Unavailable on \(session.name)")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text("Update Yardlet on \(session.name) to view and manage host settings from your phone.")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
    }

    private var loadingCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Loading settings from \(session.name)…")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
    }

    // MARK: - Usage & Plan Limits

    private func usageSection(_ usage: RemoteHostSettings.Usage) -> some View {
        let summary = thirtyDaySummary(usage.days)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Usage and Plan Limits")
            MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    if usage.isCounting {
                        HStack(spacing: 12) {
                            metricBox(
                                label: String(localized: "30-day tokens"),
                                value: Self.compactTokens(summary.tokens)
                            )
                            metricBox(
                                label: String(localized: "Estimated cost"),
                                value: Self.currency(summary.cost)
                            )
                            metricBox(
                                label: String(localized: "Requests"),
                                value: summary.requests.formatted(.number)
                            )
                        }
                    } else {
                        Text("Token usage counting is turned off on \(session.name).")
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }

                    if !usage.limits.isEmpty {
                        hairline(leading: 0)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(usage.limits, id: \.id) { line in
                                limitLineView(line)
                            }
                        }
                    }
                }
            }
        }
    }

    private func metricBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .lineLimit(1)
            Text(verbatim: value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(YardletPalette.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func limitLineView(_ line: RemoteHostSettings.Usage.LimitLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HarnessMark(harness: line.harness, harnessName: line.harness, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: line.account)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)
                    if !line.address.isEmpty && line.address != line.account {
                        Text(verbatim: line.address)
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
            }

            ForEach(line.windows, id: \.id) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: window.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Spacer(minLength: 8)
                        if let used = window.usedFraction {
                            Text(verbatim: "\(Int((used * 100).rounded()))%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(YardletPalette.onSurface)
                        } else if !window.detail.isEmpty {
                            Text(verbatim: window.detail)
                                .font(.caption)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                    if let used = window.usedFraction {
                        MonochromeProgressBar(fraction: used)
                    }
                    if let resetsAt = window.resetsAt {
                        Text("Resets \(session.date(resetsAt).formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                }
            }
        }
    }

    // MARK: - Connectors Entry

    private var connectorsEntrySection: some View {
        let connectors = accounts?.connectors ?? []
        let connectedCount = connectors.filter { $0.status == "connected" }.count
        let subtitle: String = if accounts == nil {
            String(localized: "Manage connected services")
        } else if connectedCount > 0 {
            String(localized: "\(connectedCount) connected")
        } else if !connectors.isEmpty {
            String(localized: "\(connectors.count) configured")
        } else {
            String(localized: "No services connected yet")
        }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Connectors")
            NavigationLink {
                ConnectorsView(session: session, isPresentedAsSheet: false)
            } label: {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "powerplug")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connectors")
                                .font(.body)
                                .foregroundStyle(YardletPalette.onSurface)
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(YardletPalette.outline)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Harness Accounts

    private func harnessAccountsSection(_ accounts: RemoteAccountsState) -> some View {
        let hasSavedClaudeAccounts = accounts.accounts.contains {
            $0.harness == "claude-code" && $0.connectionName != nil
        }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Harness Accounts")
            VStack(spacing: 0) {
                toggleRow(
                    title: "Auto-pick account",
                    subtitle: "Start new tasks on the account with the most limit room left.",
                    isOn: Binding(
                        get: { accounts.picksNewTaskAccount },
                        set: { enabled in
                            Task {
                                _ = await session.setHostAccount(
                                    settingID: "new_task_account_automatically",
                                    enabled: enabled
                                )
                            }
                        }
                    ),
                    disabled: !isWritable
                )
                hairline(leading: 14)
                toggleRow(
                    title: "Auto-continue at usage limit",
                    subtitle: "Continue tasks stopped at a usage limit once the limit resets.",
                    isOn: Binding(
                        get: { accounts.continuesAtUsageLimit },
                        set: { enabled in
                            Task {
                                _ = await session.setHostAccount(
                                    settingID: "continue_at_usage_limit",
                                    enabled: enabled
                                )
                            }
                        }
                    ),
                    disabled: !isWritable
                )
                if hasSavedClaudeAccounts {
                    hairline(leading: 14)
                    toggleRow(
                        title: "Auto-switch to account with room",
                        subtitle: "Move Claude Code tasks from an account near its limit to one with room.",
                        isOn: Binding(
                            get: { accounts.movesTasksToAccountWithRoom },
                            set: { enabled in
                                Task {
                                    _ = await session.setHostAccount(
                                        settingID: "move_tasks_to_accounts_with_room",
                                        enabled: enabled
                                    )
                                }
                            }
                        ),
                        disabled: !isWritable
                    )
                }

                if !accounts.accounts.isEmpty {
                    hairline(leading: 0)
                    ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { hairline(leading: 44) }
                        accountRow(account)
                    }
                }
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    private func accountRow(_ account: RemoteAccount) -> some View {
        let canSelect = isWritable && account.available == true && account.harness != nil && account.current != true
        let rowContent = HStack(spacing: 12) {
            HarnessMark(harness: account.harness ?? "", harnessName: account.harness ?? account.name, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: account.name)
                        .font(.subheadline.weight(account.current == true ? .semibold : .regular))
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)
                    StatusDot(color: accountStatusColor(account.state), size: 7)
                }
                if let detailLine = accountDetailLine(account) {
                    Text(verbatim: detailLine)
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if account.checking == true {
                ProgressView().controlSize(.mini)
            } else if account.current == true {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(YardletPalette.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())

        return Group {
            if canSelect, let harness = account.harness {
                Button {
                    Task {
                        _ = await session.setHostAccount(harness: harness, accountID: account.id)
                    }
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private func accountStatusColor(_ state: RemoteAccount.State?) -> Color {
        switch state {
        case .signedIn?: YardletPalette.Status.connected
        case .actionRequired?: YardletPalette.Status.question
        case .signedOut?, .unavailable?, .unknown?, nil: YardletPalette.Status.running
        }
    }

    private func accountDetailLine(_ account: RemoteAccount) -> String? {
        var parts: [String] = []
        if let plan = account.plan, !plan.isEmpty { parts.append(plan) }
        if let detail = account.detail, !detail.isEmpty, detail != account.name { parts.append(detail) }
        if let firstUsage = account.usage.first, let pct = firstUsage.usedPercent {
            parts.append("\(firstUsage.label) \(pct)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - General Remote Settings

    private func generalSettingsSection(_ settings: RemoteHostSettings) -> some View {
        let values = settings.values
        let keys = [
            "continue_after_restart",
            "keep_screen_unlocked",
            "follow_up_behavior",
            "idle_compaction",
            "auto_fix_failing_ci"
        ].filter { values[$0] != nil }

        return Group {
            if !keys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("General Settings")
                    VStack(spacing: 0) {
                        ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                            if index > 0 { hairline(leading: 14) }
                            generalSettingRow(key: key, value: values[key] ?? "")
                        }
                    }
                    .background(YardletPalette.surfaceContainerLow,
                                in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                            .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func generalSettingRow(key: String, value: String) -> some View {
        switch key {
        case "continue_after_restart":
            toggleRow(
                title: "Continue running work after a restart",
                subtitle: "Tasks resume where they left off after Yardlet quits or updates.",
                isOn: Binding(
                    get: { value == "on" },
                    set: { isOn in
                        Task {
                            _ = await session.setHostSetting(
                                id: "continue_after_restart",
                                value: isOn ? "on" : "off"
                            )
                        }
                    }
                ),
                disabled: !isWritable
            )

        case "keep_screen_unlocked":
            toggleRow(
                title: "Keep screen unlocked while tasks work",
                subtitle: "Prevents display sleep while a task is running.",
                isOn: Binding(
                    get: { value == "on" },
                    set: { isOn in
                        activeAlert = .setting(SettingConfirmation(
                            id: "keep_screen_unlocked",
                            title: String(localized: "Keep screen unlocked while tasks work"),
                            message: isOn
                                ? String(localized: "Prevent \(session.name)'s display from sleeping and locking while tasks are running?")
                                : String(localized: "Allow \(session.name)'s display to sleep normally while tasks run?"),
                            targetValue: isOn ? "on" : "off"
                        ))
                    }
                ),
                disabled: !isWritable
            )

        case "follow_up_behavior":
            VStack(alignment: .leading, spacing: 8) {
                Text("Follow-up behavior")
                    .font(.body)
                    .foregroundStyle(YardletPalette.onSurface)
                Text("Choose whether messages sent during a running turn steer it or wait in the queue.")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                CompactSegmentedSwitch(
                    items: [
                        .init(value: "steer", title: "Steer"),
                        .init(value: "queue", title: "Queue")
                    ],
                    selection: Binding(
                        get: { value == "queue" ? "queue" : "steer" },
                        set: { next in
                            guard next != value else { return }
                            Task {
                                _ = await session.setHostSetting(id: "follow_up_behavior", value: next)
                            }
                        }
                    )
                )
                .disabled(!isWritable)
                .opacity(isWritable ? 1 : 0.55)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

        case "idle_compaction":
            toggleRow(
                title: "Idle compaction",
                subtitle: "Compact long idle Claude Code conversations before prompt cache expires.",
                isOn: Binding(
                    get: { value == "on" },
                    set: { isOn in
                        Task {
                            _ = await session.setHostSetting(
                                id: "idle_compaction",
                                value: isOn ? "on" : "off"
                            )
                        }
                    }
                ),
                disabled: !isWritable
            )

        case "auto_fix_failing_ci":
            toggleRow(
                title: "Auto-fix failing CI",
                subtitle: "Ask whether to send failing checks to a task when it opens a pull request.",
                isOn: Binding(
                    get: { value == "ask" },
                    set: { isOn in
                        Task {
                            _ = await session.setHostSetting(
                                id: "auto_fix_failing_ci",
                                value: isOn ? "ask" : "never"
                            )
                        }
                    }
                ),
                disabled: !isWritable
            )

        default:
            EmptyView()
        }
    }

    // MARK: - Yardlet Instructions

    private func instructionsSection(_ instructions: RemoteHostSettings.Instructions) -> some View {
        let enabledValue = settings?.values["yardlet_instructions"]
        let trimmed = instructions.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Yardlet Instructions")
            VStack(alignment: .leading, spacing: 0) {
                if let enabledValue {
                    toggleRow(
                        title: "Use Yardlet instructions",
                        subtitle: "Added to tasks started or resumed on \(session.name).",
                        isOn: Binding(
                            get: { enabledValue == "on" },
                            set: { isOn in
                                activeAlert = .setting(SettingConfirmation(
                                    id: "yardlet_instructions",
                                    title: String(localized: "Use Yardlet instructions"),
                                    message: isOn
                                        ? String(localized: "Enable Yardlet instructions for tasks on \(session.name)?")
                                        : String(localized: "Disable Yardlet instructions on \(session.name)?"),
                                    targetValue: isOn ? "on" : "off"
                                ))
                            }
                        ),
                        disabled: !isWritable
                    )
                    hairline(leading: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(trimmed.isEmpty ? String(localized: "No instructions set.") : trimmed)
                        .font(.footnote)
                        .foregroundStyle(trimmed.isEmpty ? YardletPalette.onSurfaceVariant : YardletPalette.onSurface)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(YardletPalette.surfaceContainer,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        Spacer()
                        Button(isWritable ? "Edit Instructions" : "View Instructions") {
                            showsInstructionsEditor = true
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(YardletPalette.onSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                    }
                }
                .padding(14)
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    // MARK: - CLI Updates

    private func cliUpdatesSection(_ updates: RemoteHostSettings.CLIUpdates) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("CLI Updates")
                Spacer(minLength: 8)
                Button {
                    Task { _ = await session.runHostCLIUpdate(action: "checkAll") }
                } label: {
                    if updates.isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Check for Updates")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(isWritable ? YardletPalette.onSurface : YardletPalette.onSurfaceVariant)
                    }
                }
                .disabled(!isWritable || updates.isChecking)
            }

            VStack(spacing: 0) {
                if let notice = updates.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.footnote)
                            .foregroundStyle(notice.isWarning ? YardletPalette.Status.limit : YardletPalette.onSurfaceVariant)
                            .padding(.top, 2)
                        Text(verbatim: notice.text)
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurface)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if isWritable {
                            Button {
                                Task { _ = await session.runHostCLIUpdate(action: "dismissNotice") }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                            }
                            .accessibilityLabel("Dismiss")
                        }
                    }
                    .padding(14)
                    .background(YardletPalette.surfaceContainer)
                    hairline(leading: 0)
                }

                ForEach(Array(updates.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { hairline(leading: 44) }
                    cliRow(row)
                }

                if let checkedAt = updates.lastCheckedAt {
                    hairline(leading: 14)
                    HStack {
                        Text("Last checked \(session.date(checkedAt).formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    private func cliRow(_ row: RemoteHostSettings.CLIUpdates.Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HarnessMark(harness: row.harness, harnessName: row.title, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(YardletPalette.onSurface)
                Text(verbatim: [row.method, row.versions].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                if let status = row.status, !status.isEmpty {
                    Text(verbatim: status)
                        .font(.caption)
                        .foregroundStyle(row.isWarning ? YardletPalette.Status.limit : YardletPalette.onSurfaceVariant)
                }
                if let newerText = row.newerText, !newerText.isEmpty {
                    Text(verbatim: newerText)
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
            }
            Spacer(minLength: 8)
            if row.working {
                ProgressView().controlSize(.small)
            } else if let newerVersion = row.newerVersion {
                Button("Update") {
                    confirmCLIUpdate(action: "useNewest", row: row, targetVersion: newerVersion)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(isWritable ? YardletPalette.onPrimary : YardletPalette.onSurfaceVariant)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    isWritable ? YardletPalette.primary : YardletPalette.surfaceContainerHigh,
                    in: Capsule()
                )
                .disabled(!isWritable)
            } else {
                Button("Update") {
                    confirmCLIUpdate(action: "check", row: row, targetVersion: nil)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(isWritable ? YardletPalette.onSurface : YardletPalette.onSurfaceVariant)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                .disabled(!isWritable)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func confirmCLIUpdate(action: String, row: RemoteHostSettings.CLIUpdates.Row, targetVersion: String?) {
        let running = runningTaskCount
        let message: String
        if running > 0 {
            if let targetVersion {
                message = String(localized: "\(running) tasks are currently running on \(session.name). Updating \(row.title) to \(targetVersion) may affect active work.")
            } else {
                message = String(localized: "\(running) tasks are currently running on \(session.name). Checking and updating \(row.title) now may affect active work.")
            }
        } else if let targetVersion {
            message = String(localized: "Switch \(row.title) to \(targetVersion) on \(session.name)?")
        } else {
            message = String(localized: "Check for and apply available \(row.title) CLI updates on \(session.name)?")
        }

        activeAlert = .cliUpdate(CLIActionConfirmation(
            action: action,
            harness: row.harness,
            title: String(localized: "Update \(row.title)?"),
            message: message,
            confirmLabel: String(localized: "Update")
        ))
    }

    // MARK: - Helpers

    private func refreshAll() async {
        guard session.isConnected else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if session.capabilities.hostSettings {
            _ = await session.fetchHostSettings(watching: true)
        }
        if session.capabilities.hostAccounts {
            _ = await session.fetchHostAccounts(watching: true)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
            .padding(.horizontal, 4)
    }

    private func toggleRow(title: LocalizedStringKey, subtitle: LocalizedStringKey?, isOn: Binding<Bool>,
                           disabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(YardletPalette.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(disabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func hairline(leading: CGFloat) -> some View {
        Rectangle()
            .fill(YardletPalette.outlineVariant)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }

    private func thirtyDaySummary(_ days: [RemoteHostSettings.Usage.Day]) -> (tokens: Int64, cost: Double, requests: Int) {
        let cutoff = Int64((Date().timeIntervalSince1970 - 30 * 86_400) * 1000)
        let recent = days.filter { $0.start >= cutoff }
        let source = recent.isEmpty ? days : recent
        var tokens: Int64 = 0
        var cost = 0.0
        var requests = 0
        for day in source {
            tokens += day.amount.freshInput + day.amount.cacheWrite + day.amount.cacheRead + day.amount.output
            cost += day.amount.kindCost.values.reduce(0, +)
            requests += day.amount.requests
        }
        return (tokens, cost, requests)
    }

    private static func compactTokens(_ count: Int64) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(count)"
    }

    private static func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

// MARK: - Monochrome Progress Bar

/// Monochrome usage/limit bar matching YardletTheme; shifts to status color only near or at limit.
struct MonochromeProgressBar: View {
    let fraction: Double

    private var clamped: Double { min(max(fraction, 0), 1) }

    private var fillColor: Color {
        if fraction >= 0.95 { return YardletPalette.Status.failed }
        if fraction >= 0.80 { return YardletPalette.Status.limit }
        return YardletPalette.primary
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(YardletPalette.surfaceContainerHighest)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, proxy.size.width * clamped))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Yardlet Instructions Editor Sheet

private struct InstructionsEditorSheet: View {
    let hostName: String
    let writable: Bool
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false

    init(hostName: String, initialText: String, writable: Bool, onSave: @escaping (String) async -> Bool) {
        self.hostName = hostName
        self.writable = writable
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if writable {
                    TextEditor(text: $text)
                        .font(.body)
                        .foregroundStyle(YardletPalette.onSurface)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(YardletPalette.surfaceContainerLow,
                                    in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                        )
                        .padding(16)
                } else {
                    ScrollView {
                        Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? String(localized: "No instructions set.")
                             : text)
                            .font(.body)
                            .foregroundStyle(YardletPalette.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(16)
                    }
                    .background(YardletPalette.surfaceContainerLow,
                                in: RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: YardletMetrics.radiusCard, style: .continuous)
                            .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                    )
                    .padding(16)
                }

                Text("Instructions are saved on \(hostName) and applied to tasks started or resumed there.")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .background(YardletPalette.background)
            .navigationTitle("Yardlet Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(writable ? "Cancel" : "Close") { dismiss() }
                        .disabled(isSaving)
                }
                if writable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            isSaving = true
                            Task {
                                let ok = await onSave(text)
                                isSaving = false
                                if ok { dismiss() }
                            }
                        }
                        .disabled(isSaving || text.utf8.count > 65_536)
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
