import AppKit
import SwiftUI
import YardletRemote

/// Keeps one browser operation alive as account snapshots redraw the remote Settings sheet.
struct RemoteConnectorSetupSheet: View {
    let model: RemoteHostModel
    let reconnecting: ConnectorRecord?
    let onClose: () -> Void
    @State private var client: RemoteConnectorSetupClient

    init(model: RemoteHostModel, reconnecting: ConnectorRecord?, onClose: @escaping () -> Void) {
        self.model = model
        self.reconnecting = reconnecting
        self.onClose = onClose
        _client = State(initialValue: model.makeConnectorSetupClient(userAgent: MacOAuthUserAgent()))
    }

    var body: some View {
        RemoteConnectorAddSheet(hostName: model.name, client: client, reconnecting: reconnecting, onClose: onClose)
    }
}

/// Adds to the host, while the default browser on this computer handles the person's sign-in.
struct RemoteConnectorAddSheet: View {
    let hostName: String
    @Bindable var client: RemoteConnectorSetupClient
    var reconnecting: ConnectorRecord? = nil
    let onClose: () -> Void
    @State private var selectedID: String?
    @State private var query = ""
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var tokenHeader = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var tenant = ""
    @State private var auth = Authentication.automatic

    enum Authentication: String, CaseIterable { case automatic, token, client }

    init(hostName: String, client: RemoteConnectorSetupClient, reconnecting: ConnectorRecord? = nil,
         initialPresetID: String? = nil, initialAuthentication: Authentication? = nil, onClose: @escaping () -> Void) {
        self.hostName = hostName
        self.client = client
        self.reconnecting = reconnecting
        self.onClose = onClose
        _selectedID = State(initialValue: initialPresetID ?? reconnecting?.presetID ?? (reconnecting == nil ? nil : "custom"))
        _auth = State(initialValue: initialAuthentication ?? (reconnecting?.usesRegisteredClient == true ? .client :
            reconnecting?.authorization == .token ? .token : .automatic))
    }

    static func supports(_ preset: ConnectorPreset) -> Bool {
        switch preset.signIn {
        case .oauth, .token, .registeredClient, .none, .googleAccount, .microsoftAccount: true
        case .macPermission, .localApp, .mailPassword, .appStoreConnectKey: false
        }
    }

    private var preset: ConnectorPreset? { selectedID.flatMap(ConnectorPreset.preset(id:)) }
    private var existingID: String? { reconnecting?.id.uuidString ?? client.state?.connectorID }
    private var isAccount: Bool { preset?.signIn == .googleAccount || preset?.signIn == .microsoftAccount }
    private var choosesAuthentication: Bool { selectedID == "custom" || preset?.acceptsRegisteredClient == true }
    private var showsToken: Bool {
        choosesAuthentication ? auth == .token : preset?.signIn == .token
    }
    private var showsClient: Bool {
        isAccount || preset?.signIn == .registeredClient || (choosesAuthentication && auth == .client)
    }
    private var mayOpenBrowser: Bool {
        guard !showsToken, preset?.signIn != ConnectorPreset.SignIn.none else { return false }
        return !(reconnecting?.authorization == .token && auth == .automatic)
    }
    private var isFinished: Bool { client.state?.status == .connected }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if selectedID != nil, reconnecting == nil {
                    Button {
                        selectedID = nil
                        clearCredentials()
                        client.reset()
                        auth = .automatic
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("Back"))
                    .disabled(client.isRunning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(reconnecting?.name ?? preset?.name ?? L10n.string(selectedID == "custom" ? "Custom connector" : "Add connector"))
                        .font(.headline)
                    Text(L10n.format("Connect a service on %@.", hostName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if reconnecting == nil, selectedID == nil {
                        directory
                    } else {
                        setup
                    }
                    if client.isRunning || client.error != nil || isFinished {
                        progress
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L10n.string(client.isRunning ? "Cancel" : "Done")) {
                    client.cancel()
                    onClose()
                }
                .keyboardShortcut(MacShortcut.dismiss.binding)
                Spacer()
                if selectedID != nil || reconnecting != nil {
                    Button(L10n.string(reconnecting == nil ? "Connect" : "Reconnect"), action: connect)
                        .parityProminentButton()
                        .disabled(client.isRunning || isFinished || !canConnect)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 660)
        .background(ParityTheme.canvas)
        .onDisappear { client.cancel(); clearCredentials() }
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(L10n.string("Search services"), text: $query)
                .textFieldStyle(.roundedBorder)
            VStack(spacing: 0) {
                ForEach(ConnectorPreset.all.filter { Self.supports($0) && ConnectorSetupGuide.matches($0, query: query) }) { preset in
                    Button {
                        selectedID = preset.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbol)
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).font(SettingsMetrics.titleFont)
                                Text(method(for: preset)).font(SettingsMetrics.detailFont).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 40)
                }
                Button {
                    selectedID = "custom"
                } label: {
                    Label(L10n.string("Custom connector"), systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            Text(L10n.format("Connect local apps, Mac data, mail passwords, and App Store Connect keys on %@.", hostName))
                .font(SettingsMetrics.detailFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mayOpenBrowser {
                Text(L10n.string("Sign-in opens in this computer's browser. Return here when it finishes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if existingID != nil {
                detail(L10n.string("Enter corrected credentials, or leave them blank to retry the saved sign-in."))
            }
            Group {
                if selectedID == "custom", reconnecting == nil {
                    field(L10n.string("Name")) { TextField(L10n.string("Connector name"), text: $name) }
                        .disabled(existingID != nil)
                    field(L10n.string("Server URL")) { TextField("https://example.com/mcp", text: $address) }
                        .disabled(existingID != nil)
                }
                if choosesAuthentication {
                    Picker(L10n.string("Authentication"), selection: $auth) {
                        Text(L10n.string(existingID == nil ? "Automatic sign-in" : "Use saved sign-in")).tag(Authentication.automatic)
                        Text(L10n.string("Access token")).tag(Authentication.token)
                        Text(L10n.string("OAuth client")).tag(Authentication.client)
                    }
                }
                if showsToken {
                    field(L10n.string("Access token")) { SecureField(L10n.string("Access token"), text: $token) }
                    if selectedID == "custom" {
                        field(L10n.string("Token header (optional)")) {
                            TextField("Authorization", text: $tokenHeader)
                        }
                        detail(existingID == nil
                            ? L10n.string("Leave blank to send the token as Authorization: Bearer.")
                            : L10n.string("Leave blank to keep the saved token header."))
                    }
                }
                if preset?.id == "github", auth == .automatic, existingID == nil {
                    detail(L10n.string("Uses the host's GitHub app, if configured. Otherwise, choose an access token or your own OAuth client."))
                }
                if showsClient {
                    if isAccount {
                        detail(L10n.string("Leave the app fields blank to use the OAuth app already configured on the host."))
                    }
                    field(L10n.string("Client ID")) { TextField(L10n.string("Client ID"), text: $clientID) }
                    if preset?.signIn != .microsoftAccount {
                        field(L10n.string("Client secret")) { SecureField(L10n.string("Client secret (optional)"), text: $clientSecret) }
                    } else {
                        field(L10n.string("Directory (tenant) ID")) { TextField("common", text: $tenant) }
                    }
                    if !isAccount {
                        detail(L10n.string("Register this redirect URL with your OAuth app:"))
                        Text(verbatim: "http://127.0.0.1:\(ConnectorOAuth.registeredClientRedirectPort)/callback")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let preset, let url = preset.setupURL {
                    Link(L10n.string("Open service setup"), destination: url)
                        .font(.callout)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(client.isRunning || isFinished)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if client.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string(client.state?.step?.kind == .callback ? "Finish signing in in your browser…" : "Connecting…"))
                }
            }
            if let code = client.deviceCode {
                Text(L10n.string("Paste this code on GitHub's page:"))
                    .font(SettingsMetrics.detailFont)
                HStack {
                    Text(code).font(.title3.monospaced()).textSelection(.enabled)
                    Button(L10n.string("Copy")) { TranscriptClipboard.copy(code) }
                }
            }
            if let error = client.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if isFinished {
                Label(L10n.string("Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .parityCard()
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(SettingsMetrics.detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func method(for preset: ConnectorPreset) -> String {
        if preset.acceptsRegisteredClient { return L10n.string("Browser sign-in, token, or OAuth client") }
        return switch preset.signIn {
        case .oauth: L10n.string("Sign in with your browser")
        case .token: L10n.string("Access token or API key")
        case .registeredClient: L10n.string("Your own OAuth app")
        case .googleAccount, .microsoftAccount: L10n.string("Account sign-in")
        default: L10n.string("No sign-in")
        }
    }

    private var canConnect: Bool {
        if showsToken, !tokenHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if showsClient, !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if existingID != nil { return true }
        if selectedID == "custom" {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host() != nil, url.user == nil, url.password == nil else { return false }
        }
        if showsToken, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if showsClient, !isAccount, clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return selectedID != nil
    }

    private func connect() {
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let existing = existingID
        let draft = RemoteConnectorDraft(
            presetID: existing == nil ? preset?.id : nil,
            name: existing == nil && selectedID == "custom" ? value(name) : nil,
            serverURL: existing == nil && selectedID == "custom" ? value(address) : nil,
            token: showsToken ? value(token) : nil,
            tokenHeader: showsToken && selectedID == "custom" ? value(tokenHeader) : nil,
            clientID: showsClient ? value(clientID) : nil,
            clientSecret: showsClient ? value(clientSecret) : nil,
            tenant: preset?.signIn == .microsoftAccount && !clientID.isEmpty ? value(tenant) : nil)
        let hasCredentials = draft.token != nil || draft.clientID != nil
        client.start(draft: existing == nil || hasCredentials ? draft : nil, connectorID: existing)
        clearCredentials()
    }

    private func clearCredentials() {
        token = ""
        tokenHeader = ""
        clientID = ""
        clientSecret = ""
    }
}
