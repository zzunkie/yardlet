import AppKit
import SwiftUI

/// Settings → Connectors: the services whose tools Yardlet gives every harness and account it
/// starts, each signed in once (docs/CONNECTORS.md); whether Claude tasks also load each account's
/// claude.ai connectors; and, below, services other harnesses have, offered for import.
///
/// Laid out as the Claude app's Customize → Connectors reads (2.42304.0 `c40525e86`): "Your
/// connectors" with each one's state in a word — connected first — "Add connector" beside the
/// heading, and an empty state that says what to do. Adding happens in `ConnectorAddSheet`.
struct ConnectorSettingsView: View {
    let center: ConnectorCenter
    @State private var adding: ConnectorAddSheet.Start?
    @AppStorage(ClaudeAIConnectorPreference.key) private var claudeAIConnectors = false
    @AppStorage(Self.importDismissedKey) private var importDismissed = false

    static let importDismissedKey = "Yardlet.connectorImportDismissed"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.string("Services you connect here give their tools to every task Yardlet starts or resumes, in Claude Code, Codex, and ACP harnesses and every account. Antigravity isn't supported."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if center.cannotReadSavedSettings {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(L10n.format("Yardlet couldn't read %@, so your saved connectors aren't shown. The file is left as it is, and changes made here are lost when Yardlet quits.",
                                     "~/\(YardletProduct.storageDirectoryName)/connectors.json"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string("Your connectors"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    // With none yet, the empty state holds the one "Add connector".
                    if !center.connectors.isEmpty {
                        Button {
                            adding = .directory
                        } label: {
                            Label(L10n.string("Add connector"), systemImage: "plus")
                        }
                        .controlSize(.small)
                    }
                }
                .frame(minHeight: 22)
                if center.connectors.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(ConnectorSettingsState.ordered(center).enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider().padding(.leading, 42) }
                            ConnectorRow(center: center, record: record, onSetUp: { adding = .preset($0) })
                        }
                    }
                    .padding(.horizontal, 12)
                    .parityCard()
                    Text(L10n.string("Claude Code tasks get changes from their next turn; tasks in other harnesses, when they next start or resume. A connector signed in again works again in every task at once."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let suggestions = center.importSuggestions
            if !importDismissed, !suggestions.isEmpty {
                ConnectorImportList(suggestions: suggestions, center: center,
                                    onSetUp: { preset in adding = .preset(preset) },
                                    onReview: { draft in adding = .program(draft) },
                                    onDismiss: { importDismissed = true })
            }

            ConnectorSetupTiles(center: center) { preset in adding = .preset(preset) }

            claudeAIRow
                .padding(.horizontal, 12)
                .parityCard()
        }
        .task { await center.loadNativeInventory() }
        .sheet(item: $adding) { start in
            ConnectorAddSheet(center: center, start: start) { adding = nil }
        }
    }

    /// The Claude app's "No connectors configured" / "Add your first connectors".
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "powerplug")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(L10n.string("No connectors yet"))
                .font(.callout.weight(.semibold))
            Text(L10n.string("Connect a service such as Linear, Notion, or GitHub, and every task can use its tools."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Add connector")) { adding = .directory }
                .parityProminentButton()
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .parityCard()
    }

    private var claudeAIRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Use claude.ai account connectors")).font(.callout.weight(.medium))
                Text(L10n.string("On: Claude tasks also load the connectors each Claude account connected on claude.ai, such as Gmail, Google Calendar, and Google Drive. They differ by account, and a service also connected here appears twice. Codex and ACP tasks are unaffected."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(L10n.string("Use claude.ai account connectors"), isOn: $claudeAIConnectors)
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
        }
        .padding(.vertical, 12)
    }
}

/// "Set up in one go": the services that need an app of the person's own, or sign in per account
/// (Google, Microsoft 365, Slack, Zoom), each opening its setup assistant, with how far along it is.
struct ConnectorSetupTiles: View {
    let center: ConnectorCenter
    let onOpen: (ConnectorPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Set up in one go")).font(.headline)
            Text(L10n.string("For services that need an app of your own: each step opens the right page, with every value to paste ready to copy."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(name: "Google", detail: L10n.string("Gmail · Calendar · Drive"), status: googleStatus,
                     done: center.canSignInWithGoogle && googleConnected > 0, preset: "gmail")
                tile(name: "Microsoft 365", detail: L10n.string("Outlook · OneDrive · Teams"), status: microsoftStatus,
                     done: center.canSignInWithMicrosoft && microsoftConnected > 0, preset: "outlook-mail")
                tile(name: "Slack", detail: L10n.string("From Yardlet's manifest"), status: slackStatus,
                     done: slack?.status == .connected, preset: "slack")
                tile(name: "Zoom", detail: L10n.string("Meetings · Chat · Docs"), status: zoomStatus,
                     done: zoom.contains { $0.status == .connected }, preset: "zoom-meetings")
            }
            .padding(.top, 2)
        }
    }

    private var googleConnected: Int {
        center.googleAccounts.filter { $0.services.contains { $0.status == .connected } }.count
    }

    private var googleStatus: String {
        guard center.canSignInWithGoogle else { return L10n.string("Not set up") }
        let count = center.googleAccounts.count
        guard count == 0 else { return L10n.format("%lld Google accounts", Int64(count)) }
        return center.googleAppClientID == nil ? L10n.string("Sign in to start") : L10n.string("App saved · no account yet")
    }

    private var microsoftConnected: Int {
        center.microsoftAccounts.filter { $0.services.contains { $0.status == .connected } }.count
    }

    private var microsoftStatus: String {
        guard center.canSignInWithMicrosoft else { return L10n.string("Not set up") }
        let count = center.microsoftAccounts.count
        guard count == 0 else { return L10n.format("%lld Microsoft accounts", Int64(count)) }
        return center.microsoftApp == nil ? L10n.string("Sign in to start") : L10n.string("App saved · no account yet")
    }

    private var zoom: [ConnectorRecord] {
        center.connectors.filter { $0.preset?.isZoom == true }
    }

    private var zoomStatus: String {
        zoom.isEmpty ? L10n.string("Not set up") : L10n.format("%lld products added", Int64(zoom.count))
    }

    private var slack: ConnectorRecord? {
        center.connectors.first { $0.presetID == "slack" && $0.preset != nil }
    }

    private var slackStatus: String {
        guard let slack else { return L10n.string("Not set up") }
        return ConnectorSettingsState.make(slack, in: center).word
    }

    private func tile(name: String, detail: String, status: String, done: Bool, preset id: String) -> some View {
        HStack(spacing: 10) {
            ConnectorIcon(name: name, presetID: id == "gmail" ? nil : id, sources: id == "gmail" ? .google : nil, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(done ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(done ? L10n.string("Open") : L10n.string("Set up…")) {
                if let preset = ConnectorPreset.preset(id: id) { onOpen(preset) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .parityCard(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Set up %@", name))
        .accessibilityValue(status)
    }
}

/// A connector's state on the settings page, in the words the person asked for: connected, needs
/// sign-in, or error with the reason — or what is happening right now. A connector whose tools
/// still reach tasks stays connected when an attempt fails (a reconnect or a tool refresh, as in
/// the Codex and Claude apps); the reason is its row's note.
enum ConnectorSettingsState: Equatable {
    case connected(tools: Int)
    case connecting
    case waitingForBrowser
    case needsSignIn
    case error(String)
    /// A server without sign-in that has not answered yet.
    case notConnected

    static func make(_ record: ConnectorRecord, activity: ConnectorCenter.Activity?, failure: String?) -> Self {
        switch activity {
        case .connecting?: return .connecting
        case .waitingForBrowser?: return .waitingForBrowser
        case nil: break
        }
        if let failure, !failure.isEmpty, record.status != .connected { return .error(failure) }
        switch record.status {
        case .connected: return .connected(tools: record.offeredTools.count)
        case .signInRequired: return .needsSignIn
        case .notConnected: return record.authorization == .none ? .notConnected : .needsSignIn
        }
    }

    @MainActor
    static func make(_ record: ConnectorRecord, in center: ConnectorCenter) -> Self {
        make(record, activity: center.activity[record.id], failure: center.failures[record.id])
    }

    /// Why the last attempt failed, for a connector that stayed connected: one short line.
    @MainActor
    static func note(_ record: ConnectorRecord, in center: ConnectorCenter) -> String? {
        guard case .connected = make(record, in: center), let failure = center.failures[record.id],
              !failure.isEmpty else { return nil }
        return failure
    }

    /// Connected first, then what is under way, then what needs the person.
    var rank: Int {
        switch self {
        case .connected: 0
        case .connecting, .waitingForBrowser: 1
        case .needsSignIn: 2
        case .error: 3
        case .notConnected: 4
        }
    }

    @MainActor
    static func ordered(_ center: ConnectorCenter) -> [ConnectorRecord] {
        // A connected connector signing in again or reading its tools keeps its place.
        func rank(_ record: ConnectorRecord) -> Int {
            let activity = record.status == .connected ? nil : center.activity[record.id]
            return make(record, activity: activity, failure: center.failures[record.id]).rank
        }
        return center.connectors.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element), right = rank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    var word: String {
        switch self {
        case .connected: L10n.string("Connected")
        case .connecting: L10n.string("Connecting…")
        case .waitingForBrowser: L10n.string("Sign in in your browser")
        case .needsSignIn: L10n.string("Needs sign-in")
        case .error: L10n.string("Error")
        case .notConnected: L10n.string("Not connected")
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .waitingForBrowser: ParityTheme.accent
        case .needsSignIn: .orange
        case .error: .red
        case .notConnected: .secondary
        }
    }
}

/// The redirect address a registered OAuth client needs, with a button that copies it.
struct RedirectURIField: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.string("Redirect URL"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ConnectorOAuth.registeredClientRedirectURI.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button {
                TranscriptClipboard.copy(ConnectorOAuth.registeredClientRedirectURI.absoluteString)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Copy"))
            .accessibilityLabel(L10n.string("Copy redirect URL"))
        }
    }
}

private struct ConnectorRow: View {
    let center: ConnectorCenter
    let record: ConnectorRecord
    /// Opens Add connector at a service's page (Gmail's Google OAuth app).
    var onSetUp: (ConnectorPreset) -> Void = { _ in }
    @State private var entering: Entry?
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""

    private enum Entry { case token, client }

    private var state: ConnectorSettingsState { .make(record, in: center) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ConnectorIcon(name: record.name, presetID: record.presetID, sources: record.iconSources, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if case let .error(reason) = state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if let note = ConnectorSettingsState.note(record, in: center) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note)
                }
                if state == .waitingForBrowser, let code = center.deviceCodes[record.id] {
                    gitHubCode(code)
                }
                switch entering {
                case .token?: tokenEntry
                case .client?: clientEntry
                case nil: EmptyView()
                }
            }
            Spacer(minLength: 8)
            statusLabel
            primaryAction
            moreMenu
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.displayName)
    }

    /// GitHub's device sign-in: the code to paste on GitHub's page, which Yardlet put on the
    /// clipboard, with a button to copy it again.
    private func gitHubCode(_ code: String) -> some View {
        HStack(spacing: 6) {
            Text(L10n.string("Paste this code on GitHub's page:"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.callout.monospaced().weight(.semibold))
                .textSelection(.enabled)
            Button {
                TranscriptClipboard.copy(code)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Copy"))
            .accessibilityLabel(L10n.string("Copy the GitHub code"))
        }
        .padding(.top, 2)
    }

    /// What the connector gives and how it signs in; the address only for one outside the directory.
    private var detail: String? {
        var parts: [String] = []
        switch record.localService {
        case let service? where service.accountProvider != nil:
            parts.append(record.account ?? L10n.string("Not signed in yet"))
        case .appStoreConnect?:
            parts.append(L10n.format("Key %@", record.account ?? ""))
        case .xcode?:
            // Its tools answer only while Xcode is open with a project.
            parts.append(L10n.format("%@ · while it's open with a project", center.xcodeDescription ?? "Xcode"))
        case .some:
            parts.append(L10n.string("On this Mac"))
        case nil:
            if let program = record.program {
                parts.append(L10n.format("On this Mac · %@", program.summary))
            } else if record.preset == nil {
                parts.append(record.serverURL.host() ?? record.serverURL.absoluteString)
            }
        }
        if case let .connected(tools) = state { parts.append(L10n.format("%lld tools", Int64(tools))) }
        if record.usesRegisteredClient { parts.append(L10n.string("Your OAuth client")) }
        switch needsEntryFirst {
        case .client?: parts.append(L10n.string("Needs an OAuth app of your own"))
        case .token?: parts.append(record.preset?.tokenQueryParameter == nil ? L10n.string("Personal access token")
                                   : L10n.string("API key"))
        case nil: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            switch state {
            case .connecting, .waitingForBrowser:
                ProgressView().controlSize(.mini)
            default:
                Circle().fill(state.color).frame(width: 7, height: 7)
            }
            Text(state.word)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateTextStyle)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var stateTextStyle: AnyShapeStyle {
        switch state {
        case .needsSignIn: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var tokenEntry: some View {
        HStack(spacing: 6) {
            SecureField(record.preset?.tokenQueryParameter == nil ? L10n.string("Access token") : L10n.string("API key"),
                        text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connectWithToken)
            Button(L10n.string("Cancel")) {
                entering = nil
                token = ""
            }
            Button(L10n.string("Connect"), action: connectWithToken)
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    private var clientEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(L10n.string("OAuth client ID"), text: $clientID)
                SecureField(L10n.string("Client secret (optional)"), text: $clientSecret)
            }
            .textFieldStyle(.roundedBorder)
            RedirectURIField()
            if let preset = record.preset { ConnectorGuideLinks(preset: preset) }
            HStack(spacing: 6) {
                Spacer()
                Button(L10n.string("Cancel")) {
                    entering = nil
                    clientID = ""
                    clientSecret = ""
                }
                Button(L10n.string("Sign in"), action: connectWithClient)
                    .keyboardShortcut(.defaultAction)
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func connectWithToken() {
        let value = token
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entering = nil
        token = ""
        Task { try? await center.useToken(value, for: record.id) }
    }

    private func connectWithClient() {
        let id = clientID
        let secret = clientSecret
        entering = nil
        clientID = ""
        clientSecret = ""
        Task { try? await center.useRegisteredClient(id: id, secret: secret, for: record.id) }
    }

    /// A server that needs a client or token the connector does not have yet asks for it first.
    private var needsEntryFirst: Entry? {
        guard record.status != .connected, record.needsSetupBeforeConnecting, !center.signsInOnGitHub(record) else { return nil }
        return record.preset?.needsRegisteredClient == true ? .client : .token
    }

    /// The one thing to do now: sign in again, connect, or try again.
    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .connecting, .waitingForBrowser:
            Button(L10n.string("Cancel")) { center.cancelConnect(record.id) }
                .controlSize(.small)
        case .connected:
            EmptyView()
        case .needsSignIn, .error, .notConnected:
            if entering == nil {
                Button(actionTitle, action: signIn)
                    .controlSize(.small)
            }
        }
    }

    /// A Google or Microsoft account with no app to sign in with: its page in Add connector comes first.
    private var needsAccountApp: Bool {
        record.localService?.accountProvider.map { !center.canSignIn(with: $0) } ?? false
    }

    /// An App Store Connect key Apple refused: a new key is added on its page.
    private var needsNewKey: Bool {
        record.localService == .appStoreConnect && record.status == .signInRequired
    }

    private var actionTitle: String {
        if needsEntryFirst != nil || needsAccountApp || needsNewKey { return L10n.string("Set up…") }
        if case .error = state { return L10n.string("Try again") }
        return record.status == .signInRequired ? L10n.string("Reconnect") : L10n.string("Connect")
    }

    private func signIn() {
        if needsAccountApp || needsNewKey, let preset = record.preset {
            onSetUp(preset)
        } else if let first = needsEntryFirst {
            entering = first
        } else if record.status == .signInRequired {
            // A refused pasted token needs a new one; an OAuth sign-in starts over.
            if record.authorization == .token { entering = .token } else { center.reconnect(record.id) }
        } else {
            center.connect(record.id)
        }
    }

    /// Only what applies to this connector: a directory service that signs in by itself is not
    /// offered a token or an OAuth client of the person's own.
    private var acceptsToken: Bool {
        guard let preset = record.preset else { return record.authorization != .none }
        return preset.usesToken
    }

    private var acceptsClient: Bool {
        guard let preset = record.preset else { return record.authorization != .none && record.authorization != .token }
        return preset.needsRegisteredClient || preset.acceptsRegisteredClient
    }

    private var moreMenu: some View {
        Menu {
            if record.status == .connected {
                // A Google or Apple service's tools come with the app, and a Google sign-in is its
                // account's; Xcode's are its server's.
                if record.localService == nil || record.localService == .xcode {
                    Button(L10n.string("Reload tools")) { center.connect(record.id) }
                }
                if record.authorization == .oauth {
                    Button(L10n.string("Reconnect")) { center.reconnect(record.id) }
                    if record.localService == nil {
                        Button(L10n.string("Disconnect")) { center.disconnect(record.id) }
                    }
                }
                // A program stops and keeps what it starts with, for connecting again.
                if record.program != nil {
                    Button(L10n.string("Disconnect")) { center.disconnect(record.id) }
                }
            }
            if record.isGoogle, let preset = record.preset {
                Button(L10n.string("Google accounts and services…")) { onSetUp(preset) }
            }
            if record.localService?.isMicrosoft == true, let preset = record.preset {
                Button(L10n.string("Microsoft accounts and services…")) { onSetUp(preset) }
            }
            if record.localService == .appStoreConnect, let preset = record.preset {
                Button(L10n.string("App Store Connect keys…")) { onSetUp(preset) }
            }
            if let kind = record.localService.flatMap(MacDataToolRunner.kind(of:)) {
                Button(L10n.string("Open Privacy & Security…")) { NSWorkspace.shared.open(kind.privacySettingsURL) }
            }
            if acceptsToken {
                Button(L10n.string("Connect with an access token…")) { entering = .token }
            }
            if acceptsClient {
                Button(L10n.string("Use an OAuth client of your own…")) {
                    clientID = record.oauthClientID ?? ""
                    entering = .client
                }
            }
            if record.isGoogle {
                Button(L10n.string("Add another Google account")) {
                    center.addAccount(services: Set(LocalConnectorService.googleDefaults))
                }
                .disabled(!center.canSignInWithGoogle)
            }
            if record.localService?.isMicrosoft == true {
                Button(L10n.string("Add another Microsoft account")) {
                    center.addAccount(services: [.outlookMail, .outlookCalendar, .oneDrive])
                }
                .disabled(!center.canSignInWithMicrosoft)
            }
            if let setup = record.preset?.setupURL {
                Button(L10n.string("Open the service's setup page")) { NSWorkspace.shared.open(setup) }
            }
            Divider()
            Button(L10n.string("Remove"), role: .destructive) { center.remove(record.id) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.format("More for %@", record.displayName))
    }
}

/// Services the person uses elsewhere, read by name only: each claude.ai account's connectors
/// (`claudeAiMcpEverConnected`), each Codex home's ChatGPT apps and plugins, and the servers in the
/// harnesses' own settings. Each is connectable through Yardlet with one click (the browser
/// sign-in is still the person's), or opens its setup assistant or key field first. Drawn under
/// "Your connectors" and lighter than it: a suggestion, not something configured.
struct ConnectorImportList: View {
    let suggestions: [ConnectorImportSuggestion]
    let center: ConnectorCenter
    let onSetUp: (ConnectorPreset) -> Void
    /// Opens a program's page with what its settings start, read from the file now.
    var onReview: (ConnectorProgramDraft) -> Void = { _ in }
    let onDismiss: () -> Void
    @State private var unreadable: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.string("You use these elsewhere"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.string("Hide"), action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.string("Found in your claude.ai accounts, Codex apps and plugins, harness settings, and the Claude app, Cursor, and VS Code. Connect one here once and every harness and account gets it; their settings stay as they are."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    if index > 0 { Divider().padding(.leading, 20 + 10) } // under the words
                    row(suggestion)
                }
            }
            .padding(.horizontal, 10)
            .overlay {
                RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator)
            }
            if let unreadable {
                Text(unreadable).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ suggestion: ConnectorImportSuggestion) -> some View {
        HStack(spacing: 10) {
            ConnectorIcon(name: suggestion.name, presetID: presetID(suggestion), size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.name).font(.callout)
                Text(([suggestion.foundIn.joined(separator: ", ")] + programDetail(suggestion)).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // One click for a service that signs in by itself; the setup assistant or the key's
            // field for one that needs an app or a key first; a program's page for a program.
            if case .program(let name, let server, let home) = suggestion.target {
                Button(L10n.string("Review…")) { review(name: name, server: server, home: home, place: suggestion.foundIn.first ?? "") }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
            } else {
                Button(L10n.string("Connect in Yardlet")) {
                    if suggestion.connectsInOneClick || (presetID(suggestion) == "github" && center.canSignInToGitHub) {
                        connect(suggestion)
                    } else if case .preset(let preset) = suggestion.target {
                        onSetUp(preset)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(suggestion.name)
    }

    private func review(name: String, server: NativeMCPServer, home: NativeMCPHome, place: String) {
        unreadable = nil
        Task {
            let launch = await Task.detached { NativeMCPLaunch.read(server, in: home) }.value
            if let launch {
                onReview(.imported(name: name, place: place, launch: launch))
            } else {
                unreadable = L10n.format("%@'s settings no longer have %@.", place, name)
            }
        }
    }

    /// What a program runs, by its program and package (`npx @example/notes-mcp`).
    private func programDetail(_ suggestion: ConnectorImportSuggestion) -> [String] {
        guard case .program(_, let server, _) = suggestion.target, !server.detail.isEmpty else { return [] }
        return [server.detail]
    }

    private func presetID(_ suggestion: ConnectorImportSuggestion) -> String? {
        if case .preset(let preset) = suggestion.target { return preset.id }
        return nil
    }

    private func connect(_ suggestion: ConnectorImportSuggestion) {
        let preset: ConnectorPreset? = if case .preset(let preset) = suggestion.target { preset } else { nil }
        Task {
            guard let url = suggestion.serverURL,
                  let record = try? await center.add(name: suggestion.name, serverURL: url, preset: preset)
            else { return }
            center.connect(record.id)
        }
    }
}
