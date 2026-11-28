import SwiftUI

/// Account-specific agent authorization and the separate sign-in for Yardlet's Calendar.
struct GoogleSetupPage: View {
    let center: ConnectorCenter
    let openMail: () -> Void
    @State private var personalClient: GoogleClientDraft
    @State private var sharedClient = GoogleClientDraft()
    @State private var personalServices = Set(LocalConnectorService.googleDefaults)
    @State private var sharedServices: Set<LocalConnectorService>
    @State private var showShared: Bool
    @State private var saving = false
    @State private var issue: String?

    init(center: ConnectorCenter, showsSteps: Bool = false, service: LocalConnectorService? = nil,
         clientID: String = "", clientSecret: String = "", openMail: @escaping () -> Void = {}) {
        self.center = center
        self.openMail = openMail
        let sharedOnly = service == .googleAds || service == .googleAnalytics
        _showShared = State(initialValue: showsSteps || sharedOnly)
        _sharedServices = State(initialValue: service.map { [$0] } ?? Set(LocalConnectorService.googleDefaults))
        _personalClient = State(initialValue: GoogleClientDraft(id: clientID, secret: clientSecret))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Agent tools")).font(.headline)
            GooglePersonalModeLink()
            GoogleClientFields(client: $personalClient)
            servicePicker(LocalConnectorService.googleDefaults, selection: $personalServices)
            Button(L10n.string("Sign in with Google")) {
                perform {
                    guard try await center.addGoogleAccount(services: personalServices, clientID: personalClient.id,
                                                            secret: personalClient.secret) != nil else {
                        throw GoogleSignInError.needsOwnApp(Array(personalServices))
                    }
                    personalClient = GoogleClientDraft()
                }
            }
            .parityProminentButton()
            .disabled(!personalClient.valid || personalServices.isEmpty || saving)
            ServiceAccountList(center: center, provider: .google, newAccountServices: $personalServices)
            DisclosureGroup(isExpanded: $showShared) {
                sharedSetup
            } label: {
                Text(L10n.string("Shared app for Workspace, Analytics, or Ads"))
                    .font(.callout.weight(.medium))
            }
            Divider()
            Text(L10n.string("Yardlet Calendar and Mailbox")).font(.headline)
            if center.googleBuiltInApp != nil {
                Button(L10n.string("Sign in to Google for Yardlet Calendar")) {
                    perform { try await center.signInGoogleCalendarUI() }
                }
                .disabled(saving)
            }
            Button(L10n.string("Connect Gmail with an app password in Mail (IMAP)"), action: openMail)
                .parityLinkButton()
            if let issue {
                Text(issue).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sharedSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("For Workspace agent tools, select AI-powered agent when creating the desktop client. Use an Internal app for accounts in your organization."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(L10n.string("Enable APIs"), destination: ConnectorSetupAssistant.googleAPIs)
            Link(L10n.string("Create client"), destination: ConnectorSetupAssistant.googleClients)
            if let saved = center.googleAppClientID {
                Text(saved).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            GoogleClientFields(client: $sharedClient)
            HStack {
                Button(L10n.string("Save")) {
                    perform {
                        try await center.saveGoogleApp(clientID: sharedClient.id, secret: sharedClient.secret)
                        sharedClient = GoogleClientDraft()
                    }
                }
                .disabled(!sharedClient.valid)
                if center.googleAppClientID != nil {
                    Button(L10n.string("Remove the Google OAuth app"), role: .destructive) {
                        perform { try await center.removeGoogleApp() }
                    }
                }
            }
            servicePicker(LocalConnectorService.google, selection: $sharedServices)
            Button(L10n.string("Sign in with Google")) {
                center.addAccount(services: sharedServices)
            }
            .disabled(center.googleAppClientID == nil || sharedServices.isEmpty)
        }
        .disabled(saving)
        .padding(.vertical, 6)
    }

    private func servicePicker(_ services: [LocalConnectorService], selection: Binding<Set<LocalConnectorService>>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), alignment: .leading)], alignment: .leading) {
            ForEach(services) { service in
                Toggle(service.shortName, isOn: Binding(get: { selection.wrappedValue.contains(service) }, set: { on in
                    if on { selection.wrappedValue.insert(service) } else { selection.wrappedValue.remove(service) }
                }))
                .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true
        issue = nil
        Task {
            defer { saving = false }
            do { try await action() }
            catch is CancellationError {}
            catch { issue = error.localizedDescription }
        }
    }
}

struct GoogleClientDraft {
    var id = ""
    var secret = ""
    var valid: Bool {
        ConnectorSetupAssistant.validateGoogleClientID(id).isValid
            && ConnectorSetupAssistant.validateGoogleSecret(secret).isValid
    }
}

struct GoogleClientFields: View {
    @Binding var client: GoogleClientDraft

    var body: some View {
        VStack(spacing: 6) {
            ConnectorValidatedField(title: L10n.string("OAuth client ID"), text: $client.id,
                                    validation: ConnectorSetupAssistant.validateGoogleClientID(client.id))
            ConnectorValidatedField(title: L10n.string("Client secret"), text: $client.secret, secure: true,
                                    validation: ConnectorSetupAssistant.validateGoogleSecret(client.secret))
        }
    }
}

struct GooglePersonalModeLink: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Link(L10n.string("Create a Personal Mode client"), destination: GoogleOAuth.personalModeURL)
            Text(L10n.string("Open Google Cloud with the account you want to connect, then paste its client ID and secret."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension LocalConnectorService {
    /// "Gmail", "Calendar", "Drive", "Outlook", "OneDrive", "Teams", where the provider is said already.
    var shortName: String {
        switch self {
        case .gmail: "Gmail"
        case .googleCalendar, .outlookCalendar: "Calendar"
        case .googleDrive: "Drive"
        case .googleAnalytics: "Analytics"
        case .googleAds: "Ads"
        case .outlookMail: "Outlook"
        case .teams: "Teams"
        default: name
        }
    }
}

extension ConnectorSettingsState {
    /// A service chip's word, shorter than the row's: nothing when connected.
    var chipWord: String {
        switch self {
        case .connected: ""
        case .needsSignIn: L10n.string("Needs sign-in")
        case .error: L10n.string("Error")
        case .connecting, .waitingForBrowser: "…"
        case .notConnected: L10n.string("Not connected")
        }
    }
}
