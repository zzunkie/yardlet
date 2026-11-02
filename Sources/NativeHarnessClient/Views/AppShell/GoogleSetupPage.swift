import AppKit
import SwiftUI

/// Settings → Connectors → Set up Google: each Google account signed in once with the services the
/// person picks for it (Gmail, Calendar, Drive, Analytics, Ads). Yardlet serves them itself over
/// Google's public APIs, so personal and Workspace accounts both connect, without Google's developer
/// preview (docs/CONNECTORS.md, "Google").
///
/// A build that carries Yardlet's own Google app (`GoogleOAuth.BuiltInApp`) shows only the sign-in,
/// with a link to set up an app of the person's own instead, which Analytics and Ads need.
/// Otherwise, or after that link, it is laid out as the setup assistant (`ConnectorSetupAssistant`):
/// each console step with the button that opens its page and copy buttons for what it asks to
/// paste, the client fields checked as they are typed, and a check per step. Once the app is saved,
/// its steps fold into one line.
struct GoogleSetupPage: View {
    let center: ConnectorCenter
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var editingApp = false
    @State private var saving = false
    @State private var appError: String?
    @State private var showsSteps: Bool
    /// The services a new account signs in with.
    @State private var newAccountServices: Set<LocalConnectorService>
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// - Parameters:
    ///   - showsSteps: the app's steps start open even with an app saved (review renders).
    ///   - service: the service the page was opened for (an import suggestion); a new account
    ///     starts with Gmail, Calendar, and Drive either way, and with it when a sign-in can turn it on.
    ///   - clientID, clientSecret: the fields start with these (review renders).
    init(center: ConnectorCenter, showsSteps: Bool = false, service: LocalConnectorService? = nil,
         clientID: String = "", clientSecret: String = "") {
        self.center = center
        _clientID = State(initialValue: clientID)
        _clientSecret = State(initialValue: clientSecret)
        _showsSteps = State(initialValue: showsSteps)
        let opened = service.flatMap { center.signInServices(.google).contains($0) ? [$0] : nil } ?? []
        _newAccountServices = State(initialValue: Set(LocalConnectorService.googleDefaults).union(opened))
    }

    /// The person saved a Google OAuth app of their own.
    private var hasApp: Bool { center.googleAppClientID != nil }
    /// Accounts sign in with the app this build carries: no app of the person's own is saved or
    /// being set up.
    private var usesBuiltInApp: Bool { center.googleBuiltInApp != nil && !hasApp && !editingApp }

    private var opened: Set<ConnectorSetupAssistant.StepID> { ConnectorSetupProgress.decode(openedSteps) }

    /// Google services a new sign-in cannot turn on: Analytics and Ads, while accounts sign in with
    /// Yardlet's own app.
    private var ownAppOnly: [LocalConnectorService] {
        let available = center.signInServices(.google)
        return LocalConnectorService.google.filter { !available.contains($0) }
    }

    private var assistant: ConnectorSetupAssistant {
        .google(opened: opened, appSaved: hasApp,
                connectedAccounts: center.googleAccounts.filter { $0.services.contains { $0.status == .connected } }.count,
                builtIn: usesBuiltInApp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(usesBuiltInApp
                     ? L10n.string("Yardlet runs its own Gmail, Google Calendar, and Google Drive servers and signs in with its own Google app. Personal Gmail and Google Workspace accounts both work.")
                     : L10n.string("Yardlet runs its own Gmail, Google Calendar, and Google Drive servers with one Google OAuth app of yours. Personal Gmail and Google Workspace accounts both work, without Google's developer preview."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            ConnectorSetupHeader(title: L10n.string("Set up Google"), assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                if usesBuiltInApp, let signIn = assistant.steps.first {
                    row(1, signIn) { ServiceAccountList(center: center, provider: .google, newAccountServices: $newAccountServices) }
                } else {
                    appSteps
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(usesBuiltInApp
                 ? L10n.string("The first sign-in of each account shows “Google hasn't verified this app”: choose Advanced, then go on to Yardlet. Until Google reviews Yardlet's app, it lets up to 100 people sign in with it.")
                 : L10n.string("The first sign-in of each account shows “Google hasn't verified this app”. It is your own app: choose Advanced, then go on to it. Google lets an unverified app sign in up to 100 users."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !ownAppOnly.isEmpty {
                Text(L10n.string("Google Analytics and Google Ads connect only with a Google OAuth app of your own."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usesBuiltInApp {
                Button(L10n.string("Use a Google OAuth app of your own…")) {
                    clientID = ""
                    clientSecret = ""
                    appError = nil
                    editingApp = true
                    showsSteps = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            scopeNote
        }
    }

    /// The console steps for an app of the person's own, or the saved app on one line, then the
    /// sign-in.
    @ViewBuilder
    private var appSteps: some View {
        if hasApp, !editingApp, !showsSteps {
            savedApp
                .padding(.vertical, 8)
        } else {
            let steps = assistant.steps.filter { $0.id != .googleSignIn }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider().padding(.leading, 28) }
                row(index + 1, step) {
                    if step.id == .client { clientEntry }
                }
            }
            if hasApp, !editingApp {
                Divider().padding(.leading, 28)
                savedApp.padding(.vertical, 8)
            }
        }
        Divider().padding(.leading, 28)
        if let signIn = assistant.steps.first(where: { $0.id == .googleSignIn }) {
            row(assistant.steps.count, signIn) { ServiceAccountList(center: center, provider: .google, newAccountServices: $newAccountServices) }
        }
    }

    private func row<Content: View>(_ number: Int, _ step: ConnectorSetupAssistant.Step,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        let consoleStep = step.id != .client && step.id != .googleSignIn
        return ConnectorSetupStepRow(number: number, step: step, isCurrent: assistant.current == step.id,
                                     onToggle: consoleStep && !hasApp ? { toggle(step.id) } : nil,
                                     onOpen: { mark(step.id) }, content: content)
    }

    private func mark(_ id: ConnectorSetupAssistant.StepID) {
        var steps = opened
        steps.insert(id)
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    private func toggle(_ id: ConnectorSetupAssistant.StepID) {
        var steps = opened
        if steps.contains(id) { steps.remove(id) } else { steps.insert(id) }
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    // MARK: The Google OAuth app

    private var savedApp: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Google OAuth app saved in your keychain")).font(.callout.weight(.medium))
                Text(center.googleAppClientID ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(showsSteps ? L10n.string("Hide steps") : L10n.string("Setup steps")) { showsSteps.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)
            Button(L10n.string("Change…")) {
                clientID = center.googleAppClientID ?? ""
                clientSecret = ""
                appError = nil
                editingApp = true
                showsSteps = true
            }
            .controlSize(.small)
            Menu {
                Button(L10n.string("Remove the Google OAuth app"), role: .destructive) {
                    Task { try? await center.removeGoogleApp() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.string("More for the Google OAuth app"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Google OAuth app"))
    }

    private var idValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateGoogleClientID(clientID) }
    private var secretValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateGoogleSecret(clientSecret) }

    @ViewBuilder
    private var clientEntry: some View {
        if !hasApp || editingApp {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    ConnectorValidatedField(title: L10n.string("OAuth client ID"), text: $clientID, validation: idValidation)
                    ConnectorValidatedField(title: L10n.string("Client secret"), text: $clientSecret, secure: true,
                                            validation: secretValidation)
                        .frame(width: 170)
                }
                HStack {
                    if let appError {
                        Text(appError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if editingApp {
                        Button(L10n.string("Cancel")) {
                            editingApp = false
                            clientID = ""
                            clientSecret = ""
                        }
                    }
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.string("Save"), action: saveApp)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!idValidation.isValid || !secretValidation.isValid)
                    }
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func saveApp() {
        let id = clientID, secret = clientSecret
        saving = true
        appError = nil
        Task {
            do {
                try await center.saveGoogleApp(clientID: id, secret: secret)
                editingApp = false
                showsSteps = false
                clientID = ""
                clientSecret = ""
            } catch {
                appError = error.localizedDescription
            }
            saving = false
        }
    }

    /// What each service asks Google for, by Google's own classes.
    private var scopeNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.string("What Yardlet asks Google for"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(GoogleOAuth.scopes, id: \.url) { scope in
                HStack(spacing: 6) {
                    Text(scope.service.shortName)
                        .frame(width: 56, alignment: .leading)
                    Text(scope.shortName)
                        .font(.caption.monospaced())
                    Text(scope.classification.word)
                        .foregroundStyle(scope.classification == .restricted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    if ownAppOnly.contains(scope.service) {
                        Text(L10n.string("your own app only"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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

extension GoogleOAuth.Classification {
    var word: String {
        switch self {
        case .nonSensitive: L10n.string("non-sensitive")
        case .sensitive: L10n.string("sensitive")
        case .restricted: L10n.string("restricted")
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
