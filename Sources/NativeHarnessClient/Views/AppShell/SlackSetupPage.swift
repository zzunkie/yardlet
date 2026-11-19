import AppKit
import SwiftUI

/// Settings → Connectors → Set up Slack: Slack's own MCP server, through a Slack app of the
/// person's own that Yardlet's manifest creates (`SlackAppManifest`). One button opens Slack's
/// create-from-manifest page filled in; the person picks a workspace and presses Create, pastes the
/// client ID here (checked as it is typed), and signs in.
struct SlackSetupPage: View {
    let center: ConnectorCenter
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showsSecret = false
    @State private var busy = false
    @State private var error: String?
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// - Parameter clientID: the field starts with this (review renders).
    init(center: ConnectorCenter, clientID: String = "") {
        self.center = center
        _clientID = State(initialValue: clientID)
    }

    private var slack: ConnectorRecord? {
        center.connectors.first { $0.presetID == "slack" && $0.preset != nil }
    }

    private var idValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateSlackClientID(clientID) }
    private var secretValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateSlackSecret(clientSecret) }

    private var assistant: ConnectorSetupAssistant {
        .slack(opened: ConnectorSetupProgress.decode(openedSteps),
               clientEntered: idValidation.isValid || slack?.usesRegisteredClient == true,
               connected: slack?.status == .connected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(L10n.string("Yardlet uses Slack's own MCP server with a Slack app of yours. Yardlet's manifest makes the app: you pick a workspace and press Create, then paste one value here."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            ConnectorSetupHeader(title: L10n.string("Set up Slack"), assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(assistant.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 28) }
                    ConnectorSetupStepRow(number: index + 1, step: step, isCurrent: assistant.current == step.id,
                                          onToggle: step.id == .slackCreate ? { toggle(step.id) } : nil,
                                          onOpen: { mark(step.id) }) {
                        switch step.id {
                        case .slackCredentials: credentials
                        case .slackSignIn: signIn
                        default: EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(L10n.string("Slack lets Yardlet's app stay signed in while it is used; after 30 days without use, sign in again. Only apps made in your workspace, or listed in Slack's Marketplace, can use Slack's MCP server."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mark(_ id: ConnectorSetupAssistant.StepID) {
        var steps = ConnectorSetupProgress.decode(openedSteps)
        steps.insert(id)
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    private func toggle(_ id: ConnectorSetupAssistant.StepID) {
        var steps = ConnectorSetupProgress.decode(openedSteps)
        if steps.contains(id) { steps.remove(id) } else { steps.insert(id) }
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    @ViewBuilder
    private var credentials: some View {
        if let slack, slack.usesRegisteredClient, clientID.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(slack.oauthClientID ?? "")
                    .font(.caption.monospaced()).fontDesign(nil)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                Button(L10n.string("Change…")) { clientID = slack.oauthClientID ?? "" }
                    .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ConnectorValidatedField(title: L10n.string("Slack client ID"), text: $clientID, validation: idValidation)
                DisclosureGroup(isExpanded: $showsSecret) {
                    ConnectorValidatedField(title: L10n.string("Client secret"), text: $clientSecret, secure: true,
                                            validation: secretValidation)
                        .padding(.top, 4)
                } label: {
                    Text(L10n.string("An app without PKCE also needs its client secret"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var signIn: some View {
        HStack(spacing: 8) {
            if let slack {
                let state = ConnectorSettingsState.make(slack, in: center)
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(state.word).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if case .connected(let tools) = state {
                    Text(L10n.format("%lld tools", Int64(tools))).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let slack, case .error(let reason) = ConnectorSettingsState.make(slack, in: center) {
                Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let slack, let note = ConnectorSettingsState.note(slack, in: center) {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(note)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
            } else if slack?.status != .connected || !clientID.isEmpty {
                Button(L10n.string("Sign in to Slack"), action: signInToSlack)
                    .parityProminentButton()
                    .controlSize(.small)
                    .disabled(!canSignIn)
            }
        }
        .padding(.top, 2)
    }

    /// A new client ID that checks out, or the one saved already.
    private var canSignIn: Bool {
        if !clientID.isEmpty { return idValidation.isValid && (clientSecret.isEmpty || secretValidation.isValid) }
        return slack?.usesRegisteredClient == true
    }

    private func signInToSlack() {
        guard let preset = ConnectorPreset.preset(id: "slack") else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        error = nil
        Task {
            do {
                if let slack {
                    if id.isEmpty {
                        center.reconnect(slack.id)
                    } else {
                        try await center.useRegisteredClient(id: id, secret: secret.isEmpty ? nil : secret, for: slack.id)
                    }
                } else {
                    let record = try await center.add(name: preset.name, serverURL: preset.serverURL,
                                                      client: (id: id, secret: secret.isEmpty ? nil : secret), preset: preset)
                    center.connect(record.id)
                }
                clientID = ""
                clientSecret = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
