import SwiftUI
import UIKit
import YardletRemote

/// Remote Connectors management (§15.37) with in-app RFC 8252 `127.0.0.1` loopback OAuth sign-in.
struct ConnectorsView: View {
    let session: HostSession
    let isPresentedAsSheet: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var setupController: ConnectorSetupController
    @State private var isRefreshing = false
    @State private var isWatchingAccounts = false
    @State private var activeSheet: ActiveSheet?
    @State private var pendingDraft: RemoteConnectorDraft?
    @State private var pendingSafari: ConnectorSetupController.SignInSession?
    @State private var presentedSafariID: String?
    @State private var copiedDeviceCode = false
    @State private var copiedSafariDeviceCode = false

    private enum ActiveSheet: Identifiable, Equatable {
        case addConnector
        case safari(ConnectorSetupController.SignInSession)

        var id: String {
            switch self {
            case .addConnector: "addConnector"
            case let .safari(signIn): "safari-\(signIn.id)"
            }
        }
    }

    init(session: HostSession, isPresentedAsSheet: Bool = false) {
        self.session = session
        self.isPresentedAsSheet = isPresentedAsSheet
        _setupController = State(initialValue: ConnectorSetupController(session: session))
    }

    private var accounts: RemoteAccountsState? { session.hostAccounts }
    private var isEditable: Bool { accounts?.editable == true }
    private var canSetUp: Bool { setupController.canSetUp }

    var body: some View {
        Group {
            if isPresentedAsSheet {
                NavigationStack {
                    content
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !session.isConnected {
                    offlineCard
                } else if !session.capabilities.hostAccounts {
                    unsupportedCard
                } else if accounts == nil {
                    if let failure = session.hostAccountsFailure, !isRefreshing {
                        ReadFailureCard(message: failure) { Task { await refresh() } }
                    } else {
                        loadingCard
                    }
                } else {
                    if !isEditable {
                        readOnlyBanner
                    }
                    if setupController.isRunning {
                        activeSetupBanner
                    }
                    if let banner = setupController.banner {
                        resultBanner(banner)
                    }
                    connectorsSection
                    if let accounts {
                        claudeAISection(accounts)
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
            await refresh()
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(YardletPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canSetUp {
                    Button {
                        activeSheet = .addConnector
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(setupController.isRunning)
                    .accessibilityLabel("Add Connector")
                }
                if isPresentedAsSheet {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .addConnector:
                AddConnectorSheet(hostName: session.name) { draft in
                    pendingDraft = draft
                    activeSheet = nil
                }
            case let .safari(signIn):
                safariSignInContainer(signIn)
                    .onAppear {
                        presentedSafariID = signIn.id
                        copiedSafariDeviceCode = false
                    }
            }
        }
        .alert(
            "Sign in on another site?",
            isPresented: Binding(
                get: { setupController.pendingConfirmation != nil },
                set: { if !$0 { setupController.respondToConfirmation(accepted: false) } }
            ),
            presenting: setupController.pendingConfirmation
        ) { _ in
            Button("Continue") {
                setupController.respondToConfirmation(accepted: true)
            }
            Button("Cancel", role: .cancel) {
                setupController.respondToConfirmation(accepted: false)
            }
        } message: { confirmation in
            Text("\(confirmation.connector) (\(confirmation.serverHost)) wants to open \(confirmation.signInHost) to sign in.")
        }
        .onChange(of: setupController.activeSignIn) { _, next in
            if let next {
                if activeSheet == nil {
                    activeSheet = .safari(next)
                } else if case .safari = activeSheet {
                    activeSheet = .safari(next)
                } else {
                    pendingSafari = next
                    activeSheet = nil
                }
            } else if case .safari = activeSheet {
                presentedSafariID = nil
                activeSheet = nil
            }
        }
        .onAppear {
            guard !isWatchingAccounts else { return }
            isWatchingAccounts = true
            session.beginWatchingHostAccounts()
        }
        .onDisappear {
            setupController.cancel()
            if isWatchingAccounts {
                isWatchingAccounts = false
                session.endWatchingHostAccounts()
            }
        }
    }

    @ViewBuilder
    private func safariSignInContainer(_ signIn: ConnectorSetupController.SignInSession) -> some View {
        if let code = signIn.deviceCode, !code.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verification code")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Text(verbatim: code)
                            .font(.headline.monospaced().weight(.semibold))
                            .foregroundStyle(YardletPalette.onSurface)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button(copiedSafariDeviceCode ? "Copied" : "Copy Code") {
                        UIPasteboard.general.string = code
                        copiedSafariDeviceCode = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedSafariDeviceCode = false
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(YardletPalette.onPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(YardletPalette.primary, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(YardletPalette.surfaceContainer)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(YardletPalette.outlineVariant)
                        .frame(height: 0.5)
                }

                SafariSignInSheet(url: signIn.url) {
                    presentedSafariID = nil
                    setupController.userCancelledSafari()
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .background(YardletPalette.background)
        } else {
            SafariSignInSheet(url: signIn.url) {
                presentedSafariID = nil
                setupController.userCancelledSafari()
            }
            .ignoresSafeArea()
        }
    }

    private func handleSheetDismiss() {
        let dismissedSafariID = presentedSafariID
        presentedSafariID = nil

        if let draft = pendingDraft {
            pendingDraft = nil
            setupController.start(draft: draft)
            return
        }
        if let next = pendingSafari {
            pendingSafari = nil
            activeSheet = .safari(next)
            return
        }
        if let dismissedSafariID, setupController.activeSignIn?.id == dismissedSafariID {
            setupController.userCancelledSafari()
        }
    }

    private func refresh() async {
        guard session.isConnected, session.capabilities.hostAccounts else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await session.fetchHostAccounts(watching: true)
    }

    // MARK: - Banners & State Cards

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
                    Text("To add connectors or turn them on or off from here, allow Change settings for this device in Settings › Remote › Paired devices on \(session.name).")
                        .font(.footnote)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activeSetupBanner: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainer, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(setupController.statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(YardletPalette.onSurface)
                    Spacer(minLength: 8)
                    Button("Cancel") {
                        setupController.cancel()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                }

                if let code = setupController.deviceCode, !code.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter this verification code when prompted:")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        HStack(spacing: 10) {
                            Text(verbatim: code)
                                .font(.title3.monospaced().weight(.semibold))
                                .foregroundStyle(YardletPalette.onSurface)
                                .textSelection(.enabled)
                            Spacer()
                            Button(copiedDeviceCode ? "Copied" : "Copy Code") {
                                UIPasteboard.general.string = code
                                copiedDeviceCode = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    copiedDeviceCode = false
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(YardletPalette.onPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(YardletPalette.primary, in: Capsule())
                        }
                    }
                    .padding(10)
                    .background(YardletPalette.surfaceContainerLow,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func resultBanner(_ banner: ConnectorSetupController.Banner) -> some View {
        MonochromeCard(
            fill: banner.isSuccess ? YardletPalette.surfaceContainer : YardletPalette.errorContainer,
            border: banner.isSuccess ? YardletPalette.outlineVariant : YardletPalette.error.opacity(0.35),
            padding: 14
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(banner.isSuccess ? YardletPalette.Status.connected : YardletPalette.error)
                    .padding(.top, 1)
                Text(verbatim: banner.message)
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    setupController.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private var offlineCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not Connected")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text("Connect to \(session.name) to view and manage connectors.")
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
                Text("Update Yardlet on \(session.name) to manage connectors from your phone.")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
    }

    private var loadingCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Loading connectors from \(session.name)…")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
    }

    // MARK: - Connectors List

    private var connectorsSection: some View {
        let connectors = accounts?.connectors ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connected Services")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.horizontal, 4)
                Spacer()
                if canSetUp && !connectors.isEmpty {
                    Button {
                        activeSheet = .addConnector
                    } label: {
                        Label("Add Connector", systemImage: "plus")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurface)
                    }
                    .disabled(setupController.isRunning)
                }
            }

            if connectors.isEmpty {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "powerplug")
                            .font(.title2)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        Text("No Connectors")
                            .font(.headline)
                            .foregroundStyle(YardletPalette.onSurface)
                        Text("Connect Gmail, Calendar, Linear, Notion, Slack, or custom MCP servers on \(session.name).")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        if canSetUp {
                            Button("Add Connector") {
                                activeSheet = .addConnector
                            }
                            .prominentButton()
                            .disabled(setupController.isRunning)
                            .padding(.top, 2)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(connectors.enumerated()), id: \.element.id) { index, connector in
                        if index > 0 {
                            Rectangle()
                                .fill(YardletPalette.outlineVariant)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                        connectorRow(connector)
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

    private func connectorRow(_ connector: RemoteConnectorInfo) -> some View {
        let isConnected = connector.status == "connected"
        let isOn = connector.enabled ?? true
        let canToggle = isEditable && (isConnected || !isOn)
        let supportsRemoteReconnect = canSetUp && Self.supportsRemoteSignIn(connector)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(color: statusColor(for: connector), size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: connector.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(YardletPalette.onSurface)
                            .lineLimit(1)
                        if connector.toolCount > 0 {
                            Text("\(connector.toolCount) tools")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                        }
                    }
                    Text(verbatim: connectorSubtitle(connector))
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isEditable {
                    Toggle(connector.name, isOn: Binding(
                        get: { isOn },
                        set: { next in
                            Task { _ = await session.setHostConnector(id: connector.id, enabled: next) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!canToggle)
                }
            }

            if let failure = connector.failure, !failure.isEmpty {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(YardletPalette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if supportsRemoteReconnect {
                HStack {
                    Button(isConnected ? "Reconnect" : "Sign In") {
                        setupController.start(connectorID: connector.id)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isConnected ? YardletPalette.onSurface : YardletPalette.onPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isConnected ? YardletPalette.surfaceContainerHigh : YardletPalette.primary,
                        in: Capsule()
                    )
                    .disabled(setupController.isRunning)
                    Spacer()
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func claudeAISection(_ accounts: RemoteAccountsState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account Connectors")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .padding(.horizontal, 4)
            MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
                Toggle(isOn: Binding(
                    get: { accounts.claudeAIConnectors },
                    set: { enabled in
                        Task {
                            _ = await session.setHostConnector(id: "claude_ai_connectors", enabled: enabled)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use claude.ai account connectors")
                            .font(.body)
                            .foregroundStyle(YardletPalette.onSurface)
                        Text("Claude tasks also load connectors enabled on each claude.ai account.")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!isEditable)
            }
        }
    }

    private func statusColor(for connector: RemoteConnectorInfo) -> Color {
        if connector.failure != nil { return YardletPalette.Status.failed }
        switch connector.status {
        case "connected":
            return (connector.enabled ?? true) ? YardletPalette.Status.connected : YardletPalette.Status.running
        case "signInRequired":
            return YardletPalette.Status.question
        default:
            return YardletPalette.Status.running
        }
    }

    private func connectorSubtitle(_ connector: RemoteConnectorInfo) -> String {
        var parts: [String] = []
        if let activity = connector.activity {
            switch activity {
            case "connecting": parts.append(String(localized: "Connecting…"))
            case "waitingForBrowser": parts.append(String(localized: "Waiting for sign-in…"))
            default: break
            }
        } else {
            switch connector.status {
            case "connected":
                parts.append((connector.enabled ?? true) ? String(localized: "Connected") : String(localized: "Off"))
            case "signInRequired":
                parts.append(String(localized: "Sign-in required"))
            default:
                parts.append(String(localized: "Not connected"))
            }
        }
        if let account = connector.account, !account.isEmpty {
            parts.append(account)
        } else if let host = connector.serverHost, !host.isEmpty {
            parts.append(host)
        } else if let program = connector.programSummary, !program.isEmpty {
            parts.append(program)
        }
        return parts.joined(separator: " · ")
    }

    /// Matches host `RemoteConnectorSetupCoordinator.supports(_:)`: excludes local programs and Mac-only services.
    private static func supportsRemoteSignIn(_ connector: RemoteConnectorInfo) -> Bool {
        guard connector.programSummary == nil else { return false }
        guard let local = connector.localService else { return true }
        let accountServices: Set<String> = [
            "gmail", "google-calendar", "google-drive", "google-analytics", "google-ads",
            "outlook-mail", "outlook-calendar", "onedrive", "microsoft-teams"
        ]
        return accountServices.contains(local)
    }
}

// MARK: - Add Connector Sheet

private struct AddConnectorSheet: View {
    struct Preset: Identifiable {
        enum AuthKind {
            case oauth
            case account
            case registeredClient
            case tokenOrClient
        }

        let id: String
        let name: String
        let symbol: String
        let authKind: AuthKind
        let detail: LocalizedStringKey
    }

    /// 10 standard presets matching `ConnectorDirectory.swift` IDs on the host Mac.
    static let presets: [Preset] = [
        Preset(id: "gmail", name: "Gmail", symbol: "envelope", authKind: .account, detail: "Google account sign-in"),
        Preset(id: "google-calendar", name: "Google Calendar", symbol: "calendar", authKind: .account, detail: "Google account sign-in"),
        Preset(id: "google-drive", name: "Google Drive", symbol: "externaldrive", authKind: .account, detail: "Google account sign-in"),
        Preset(id: "outlook-mail", name: "Outlook Mail", symbol: "envelope.badge", authKind: .account, detail: "Microsoft account sign-in"),
        Preset(id: "slack", name: "Slack", symbol: "number", authKind: .registeredClient, detail: "Sign in with Slack OAuth app"),
        Preset(id: "linear", name: "Linear", symbol: "checklist", authKind: .oauth, detail: "Browser sign-in"),
        Preset(id: "notion", name: "Notion", symbol: "doc.text", authKind: .oauth, detail: "Browser sign-in"),
        Preset(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", authKind: .tokenOrClient, detail: "Personal access token or OAuth app"),
        Preset(id: "stripe", name: "Stripe", symbol: "dollarsign.circle", authKind: .oauth, detail: "Browser sign-in"),
        Preset(id: "atlassian", name: "Atlassian", symbol: "square.stack.3d.up", authKind: .oauth, detail: "Browser sign-in")
    ]

    let hostName: String
    let onStartSetup: (RemoteConnectorDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: Preset?
    @State private var showsCustomForm = false

    // Preset optional/required credentials
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""

    // Custom MCP form
    @State private var customName = ""
    @State private var customURL = ""
    @State private var customToken = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    securityNoteCard

                    if let preset = selectedPreset {
                        presetDetailForm(preset)
                    } else if showsCustomForm {
                        customMCPForm
                    } else {
                        presetDirectory
                        customEntryRow
                    }
                }
                .padding(16)
            }
            .background(YardletPalette.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selectedPreset != nil || showsCustomForm {
                        Button("Back") {
                            selectedPreset = nil
                            showsCustomForm = false
                            clearCredentials()
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { clearCredentials() }
    }

    private var navigationTitle: String {
        if let preset = selectedPreset { return preset.name }
        if showsCustomForm { return String(localized: "Custom MCP Server") }
        return String(localized: "Add Connector")
    }

    private var securityNoteCard: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainer, padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.top, 1)
                Text("Sign-in opens on this phone, and credentials are stored securely on \(hostName).")
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presetDirectory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Services")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(Self.presets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 {
                        Rectangle()
                            .fill(YardletPalette.outlineVariant)
                            .frame(height: 0.5)
                            .padding(.leading, 48)
                    }
                    Button {
                        if preset.authKind == .oauth {
                            onStartSetup(RemoteConnectorDraft(presetID: preset.id))
                        } else {
                            selectedPreset = preset
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbol)
                                .font(.subheadline)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: preset.name)
                                    .font(.body)
                                    .foregroundStyle(YardletPalette.onSurface)
                                Text(preset.detail)
                                    .font(.caption)
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(YardletPalette.outline)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

    private var customEntryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom MCP")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .padding(.horizontal, 4)

            Button {
                showsCustomForm = true
            } label: {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom MCP Server")
                                .font(.body)
                                .foregroundStyle(YardletPalette.onSurface)
                            Text("Connect any remote MCP server by HTTPS URL")
                                .font(.caption)
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

    private func presetDetailForm(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    switch preset.authKind {
                    case .account:
                        Text("Leave the fields below blank to use the OAuth app already configured on \(hostName).")
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        inputField("Client ID (optional)") {
                            TextField("Client ID", text: $clientID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if preset.id != "outlook-mail" {
                            inputField("Client Secret (optional)") {
                                SecureField("Client Secret", text: $clientSecret)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }

                    case .registeredClient:
                        Text("Enter the Client ID from your \(preset.name) OAuth app.")
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        inputField("Client ID") {
                            TextField("Client ID", text: $clientID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        inputField("Client Secret (optional)") {
                            SecureField("Client Secret", text: $clientSecret)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                    case .tokenOrClient:
                        Text("Paste a personal access token, or leave blank to use the GitHub OAuth app configured on \(hostName).")
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                        inputField("Personal Access Token (optional)") {
                            SecureField("Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                    case .oauth:
                        EmptyView()
                    }
                }
            }

            Button {
                let draft = RemoteConnectorDraft(
                    presetID: preset.id,
                    token: trimmed(token),
                    clientID: trimmed(clientID),
                    clientSecret: trimmed(clientSecret)
                )
                clearCredentials()
                onStartSetup(draft)
            } label: {
                Text("Connect \(preset.name)")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .prominentButton()
            .disabled(!canSubmitPreset(preset))
        }
    }

    private var customMCPForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    inputField("Name") {
                        TextField("Connector name", text: $customName)
                    }
                    inputField("Server URL") {
                        TextField("https://example.com/mcp" as String, text: $customURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    inputField("Access Token (optional)") {
                        SecureField("Leave blank for OAuth sign-in", text: $customToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidCustomURL {
                        Text("Enter a valid https:// server URL.")
                            .font(.caption)
                            .foregroundStyle(YardletPalette.error)
                    }
                }
            }

            Button {
                let draft = RemoteConnectorDraft(
                    name: trimmed(customName),
                    serverURL: normalizedCustomURL,
                    token: trimmed(customToken)
                )
                clearCredentials()
                onStartSetup(draft)
            } label: {
                Text("Connect")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .prominentButton()
            .disabled(!isValidCustomURL)
        }
    }

    private func inputField<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            content()
                .font(.body)
                .foregroundStyle(YardletPalette.onSurface)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(YardletPalette.surfaceContainer,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                )
        }
    }

    private func canSubmitPreset(_ preset: Preset) -> Bool {
        if trimmed(clientSecret) != nil && trimmed(clientID) == nil { return false }
        if preset.authKind == .registeredClient {
            return trimmed(clientID) != nil
        }
        return true
    }

    private var normalizedCustomURL: String? {
        guard let raw = trimmed(customURL),
              var components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.scheme?.lowercased() == "https" else {
            return nil
        }
        components.scheme = "https"
        return components.url?.absoluteString
    }

    private var isValidCustomURL: Bool {
        normalizedCustomURL != nil
    }

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func clearCredentials() {
        token = ""
        clientID = ""
        clientSecret = ""
        customToken = ""
    }
}
