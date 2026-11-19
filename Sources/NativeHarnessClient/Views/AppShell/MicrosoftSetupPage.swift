import AppKit
import SwiftUI

/// Settings → Connectors → Set up Microsoft 365: each Microsoft account signed in once with the
/// services the person picks for it (Outlook mail and calendar, OneDrive, Teams). Yardlet serves the
/// four itself over Microsoft Graph, so personal and work or school accounts connect without
/// Microsoft's own MCP servers (docs/CONNECTORS.md, "Microsoft 365").
///
/// A build that carries Yardlet's own Microsoft app (`MicrosoftOAuth.BuiltInApp`) shows only the
/// sign-in, with a link to set up an app of the person's own instead. Otherwise, or after that
/// link, it is laid out as the setup assistant (`ConnectorSetupAssistant.microsoft`): each Entra
/// step with its page and copy buttons, the application and directory fields checked as they are
/// typed, and a check per step. Once the app is saved, its steps fold into one line.
struct MicrosoftSetupPage: View {
    let center: ConnectorCenter
    @State private var clientID = ""
    @State private var tenant = ""
    @State private var editingApp = false
    @State private var showsSteps: Bool
    @State private var newAccountServices: Set<LocalConnectorService>
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// - Parameters:
    ///   - showsSteps: the app's steps start open even with an app saved (review renders).
    ///   - clientID, tenant: the fields start with these (review renders).
    init(center: ConnectorCenter, showsSteps: Bool = false, service: LocalConnectorService? = nil,
         clientID: String = "", tenant: String = "") {
        self.center = center
        _clientID = State(initialValue: clientID)
        _tenant = State(initialValue: tenant)
        _showsSteps = State(initialValue: showsSteps)
        // Teams works only for work or school accounts, so a new account starts without it.
        _newAccountServices = State(initialValue: Set([.outlookMail, .outlookCalendar, .oneDrive]).union(service.map { [$0] } ?? []))
    }

    private var hasApp: Bool { center.microsoftApp != nil }
    private var usesBuiltInApp: Bool { center.microsoftBuiltInApp != nil && !hasApp && !editingApp }

    private var opened: Set<ConnectorSetupAssistant.StepID> { ConnectorSetupProgress.decode(openedSteps) }

    private var assistant: ConnectorSetupAssistant {
        .microsoft(opened: opened, appSaved: hasApp,
                   connectedAccounts: center.microsoftAccounts.filter { $0.services.contains { $0.status == .connected } }.count,
                   builtIn: usesBuiltInApp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(usesBuiltInApp
                     ? L10n.string("Yardlet runs its own Outlook, OneDrive, and Teams servers on Microsoft Graph and signs in with its own Microsoft app. Personal accounts have Outlook and OneDrive; Teams needs a work or school account.")
                     : L10n.string("Yardlet runs its own Outlook, OneDrive, and Teams servers on Microsoft Graph with one Microsoft app of yours. Personal accounts have Outlook and OneDrive; Teams needs a work or school account."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            ConnectorSetupHeader(title: L10n.string("Set up Microsoft 365"), assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                if usesBuiltInApp, let signIn = assistant.steps.first {
                    row(1, signIn) { accounts }
                } else {
                    appSteps
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(L10n.string("A work or school organization may let only apps its administrator approved read mail, calendars, and chats. If Microsoft asks for an administrator's approval, ask them to grant it, or register this app in your organization."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if usesBuiltInApp {
                Button(L10n.string("Use a Microsoft app of your own…")) {
                    clientID = ""
                    tenant = ""
                    editingApp = true
                    showsSteps = true
                }
                .parityLinkButton()
                .font(.caption)
            }
            permissionNote
        }
    }

    @ViewBuilder
    private var appSteps: some View {
        if hasApp, !editingApp, !showsSteps {
            savedApp.padding(.vertical, 8)
        } else {
            let steps = assistant.steps.filter { $0.id != .msSignIn }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider().padding(.leading, 28) }
                row(index + 1, step) {
                    if step.id == .msClient { appEntry }
                }
            }
            if hasApp, !editingApp {
                Divider().padding(.leading, 28)
                savedApp.padding(.vertical, 8)
            }
        }
        Divider().padding(.leading, 28)
        if let signIn = assistant.steps.first(where: { $0.id == .msSignIn }) {
            row(assistant.steps.count, signIn) { accounts }
        }
    }

    private var accounts: some View {
        ServiceAccountList(center: center, provider: .microsoft, newAccountServices: $newAccountServices)
    }

    private func row<Content: View>(_ number: Int, _ step: ConnectorSetupAssistant.Step,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        let consoleStep = step.id != .msClient && step.id != .msSignIn
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

    // MARK: The Microsoft app

    private var savedApp: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Microsoft app saved")).font(.callout.weight(.medium))
                Text([center.microsoftApp?.clientID, center.microsoftApp?.tenant].compactMap { $0 }.joined(separator: " · "))
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
                clientID = center.microsoftApp?.clientID ?? ""
                tenant = center.microsoftApp.map { $0.tenant == MicrosoftOAuth.commonTenant ? "" : $0.tenant } ?? ""
                editingApp = true
                showsSteps = true
            }
            .controlSize(.small)
            Menu {
                Button(L10n.string("Remove the Microsoft app"), role: .destructive) { center.removeMicrosoftApp() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.string("More for the Microsoft app"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Microsoft app"))
    }

    private var idValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateMicrosoftClientID(clientID) }
    private var tenantValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateMicrosoftTenant(tenant) }

    @ViewBuilder
    private var appEntry: some View {
        if !hasApp || editingApp {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    ConnectorValidatedField(title: L10n.string("Application (client) ID"), text: $clientID, validation: idValidation)
                    ConnectorValidatedField(title: L10n.string("Directory ID (optional)"), text: $tenant, validation: tenantValidation)
                        .frame(width: 190)
                }
                HStack {
                    Spacer()
                    if editingApp {
                        Button(L10n.string("Cancel")) {
                            editingApp = false
                            clientID = ""
                            tenant = ""
                        }
                    }
                    Button(L10n.string("Save")) {
                        center.saveMicrosoftApp(clientID: clientID, tenant: tenant)
                        editingApp = false
                        showsSteps = false
                        clientID = ""
                        tenant = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!idValidation.isValid || tenantValidation.message != nil)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    /// What each service asks Microsoft for: Graph's delegated permissions, none of which needs an
    /// administrator by Microsoft's own table.
    private var permissionNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.string("What Yardlet asks Microsoft for"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(LocalConnectorService.microsoft) { service in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(service.shortName)
                        .frame(width: 64, alignment: .leading)
                    Text(service.scopes.joined(separator: " "))
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(L10n.string("With every account: offline_access and User.Read, to stay signed in and know whose account it is."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
