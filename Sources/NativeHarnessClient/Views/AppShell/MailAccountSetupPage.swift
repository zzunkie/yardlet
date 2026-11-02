import AppKit
import SwiftUI

/// Settings → Connectors → Add connector → Mail (IMAP): a mail account without an API, over IMAP and SMTP
/// with an app password (docs/MAILBOX.md, "Mail accounts over IMAP"). The address picks the service;
/// its steps say what to turn on at the service first, with a link to where. Yardlet signs in once to
/// check, keeps the password in the keychain, and lists the account in the mailbox and as a connector.
struct MailAccountSetupPage: View {
    let center: ConnectorCenter
    @State private var address: String
    @State private var password = ""
    /// The service chosen by hand; nil follows the address.
    @State private var chosenPreset: String?
    @State private var custom: MailServerSettings
    @State private var busy = false
    @State private var error: String?
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// The "Other IMAP server" choice, which shows the server fields.
    static let otherID = "other"

    init(center: ConnectorCenter, address: String = "", preset: String? = nil) {
        self.center = center
        _address = State(initialValue: address)
        _chosenPreset = State(initialValue: preset)
        _custom = State(initialValue: MailServerSettings(preset: nil, imapHost: "", imapPort: 993, imapSecurity: .tls, imapUsername: "",
                                                         smtpHost: "", smtpPort: 465, smtpSecurity: .tls, smtpUsername: ""))
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The service chosen, else the one the address is at, else other servers once an address is typed.
    private var presetID: String? {
        chosenPreset ?? MailServerPreset.matching(trimmedAddress)?.id
            ?? (trimmedAddress.contains("@") && MailServerPreset.connectorService(for: trimmedAddress) == nil ? Self.otherID : nil)
    }

    private var preset: MailServerPreset? { presetID.flatMap(MailServerPreset.preset(id:)) }

    private var accounts: [ConnectorRecord] { center.connectors.filter { $0.localService == .imapMail } }

    private var settings: MailServerSettings? {
        if let preset { return preset.settings(for: trimmedAddress) }
        guard presetID == Self.otherID, !custom.imapHost.isEmpty, !custom.smtpHost.isEmpty else { return nil }
        var settings = custom
        if settings.imapUsername.isEmpty { settings.imapUsername = trimmedAddress }
        if settings.smtpUsername.isEmpty { settings.smtpUsername = settings.imapUsername }
        return settings
    }

    private var canConnect: Bool {
        trimmedAddress.contains("@") && !password.isEmpty && settings != nil && !busy
            && MailServerPreset.connectorService(for: trimmedAddress) == nil
    }

    private var assistant: ConnectorSetupAssistant {
        .mail(preset, opened: ConnectorSetupProgress.decode(openedSteps), accountEntered: canConnect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(L10n.string("Yardlet signs in to your mail server itself with an app password, which stays in your keychain. Mail is read from the server and kept in memory only."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            if !accounts.isEmpty { accountList }
            serviceRow
            if let service = MailServerPreset.connectorService(for: trimmedAddress) {
                Text(L10n.format("%@ accounts connect through their own sign-in, which reads them better. Choose %@ in the list of connectors.",
                                 service.name, service.name))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConnectorSetupHeader(title: accounts.isEmpty ? L10n.string("Set up a mail account") : L10n.string("Add another mail account"),
                                 assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(assistant.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 28) }
                    ConnectorSetupStepRow(number: index + 1, step: step, isCurrent: assistant.current == step.id,
                                          onToggle: ConnectorSetupAssistant.mailServiceSteps.contains(step.id) ? { toggle(step.id) } : nil,
                                          onOpen: { mark(step.id) }) {
                        switch step.id {
                        case .mailAccount: accountFields
                        case .mailConnect: connectRow
                        default: EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(L10n.string("Agents read and draft with this account's tools, and sending asks you each time. Removing the account deletes its password from the keychain; delete the app password at the service too."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Another service has other steps, so the website steps ticked for the last one start over.
        .onChange(of: presetID) { forgetServiceSteps() }
    }

    /// The service, which the address picks; a menu to choose another or type a server.
    private var serviceRow: some View {
        HStack(spacing: 8) {
            Text(L10n.string("Mail service")).font(.callout.weight(.medium))
            Spacer(minLength: 6)
            Picker(L10n.string("Mail service"), selection: Binding(get: { presetID }, set: { chosenPreset = $0 })) {
                if presetID == nil { Text(L10n.string("Choose a service")).tag(String?.none) }
                ForEach(MailServerPreset.all) { preset in
                    Text(L10n.string(preset.name)).tag(Optional(preset.id))
                }
                Divider()
                Text(L10n.string("Other IMAP server")).tag(Optional(Self.otherID))
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var accountFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(L10n.string("Email address"), text: $address, prompt: "name@example.com")
            HStack(spacing: 8) {
                Text(L10n.string("App password")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("App password"))
            }
            if presetID == Self.otherID { serverFields }
        }
        .font(.callout)
        .padding(.top, 2)
    }

    /// An IMAP server the presets do not know: its incoming and outgoing servers and the user name.
    private var serverFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(L10n.string("IMAP server"), text: $custom.imapHost, prompt: "imap.example.com")
            portRow(L10n.string("IMAP port"), port: $custom.imapPort, security: $custom.imapSecurity)
            field(L10n.string("SMTP server"), text: $custom.smtpHost, prompt: "smtp.example.com")
            portRow(L10n.string("SMTP port"), port: $custom.smtpPort, security: $custom.smtpSecurity)
            field(L10n.string("User name"), text: $custom.imapUsername, prompt: L10n.string("The address, unless the service says otherwise"))
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
    }

    private func portRow(_ label: String, port: Binding<Int>, security: Binding<MailSocketSecurity>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            TextField("", value: port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .accessibilityLabel(label)
            Picker(label, selection: security) {
                Text("TLS").tag(MailSocketSecurity.tls)
                Text("STARTTLS").tag(MailSocketSecurity.startTLS)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    connect()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(L10n.string("Connect")) }
                }
                .parityProminentButton()
                .disabled(!canConnect)
                Spacer(minLength: 0)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    /// The mail accounts added already, each with its state.
    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, record in
                if index > 0 { Divider().padding(.leading, 12) }
                let state = ConnectorSettingsState.make(record, in: center)
                HStack(spacing: 8) {
                    Text(record.account ?? record.name).font(.callout.weight(.medium))
                    Text(record.name).font(.caption).foregroundStyle(.secondary)
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.word).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if case .error(let reason) = state {
                        Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2).help(reason)
                    }
                    Spacer(minLength: 6)
                    Button(L10n.string("Remove"), role: .destructive) { center.remove(record.id) }
                        .controlSize(.small)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .parityCard(cornerRadius: 10)
    }

    private func connect() {
        guard let settings else { return }
        busy = true
        error = nil
        let address = trimmedAddress
        let name = preset.map { L10n.string($0.name) } ?? address
        Task {
            do {
                _ = try await center.addMailAccount(address: address, password: password, settings: settings, name: name)
                password = ""
                self.address = ""
                chosenPreset = nil
                forgetServiceSteps()
            } catch {
                self.error = MailAccountSetupPage.explanation(for: error, preset: preset)
            }
            busy = false
        }
    }

    /// What a failed check means for the person: a refused sign-in names what the service needs first.
    static func explanation(for error: Error, preset: MailServerPreset?) -> String {
        let reason = error.localizedDescription
        if (error as? MailFailure)?.kind == .signInRequired {
            let hint = preset?.steps.isEmpty == false
                ? L10n.string("Check the app password and that the steps above are done; most services refuse a sign-in until IMAP is turned on and an app password is used.")
                : L10n.string("Check the user name and the app password.")
            return L10n.format("The mail server refused the sign-in (%@).", reason) + " " + hint
        }
        return L10n.format("Yardlet could not reach the mail server (%@).", reason)
    }

    private func forgetServiceSteps() {
        let opened = ConnectorSetupProgress.decode(openedSteps).subtracting(ConnectorSetupAssistant.mailServiceSteps)
        openedSteps = ConnectorSetupProgress.encode(opened)
    }

    private func mark(_ step: ConnectorSetupAssistant.StepID) {
        var opened = ConnectorSetupProgress.decode(openedSteps)
        opened.insert(step)
        openedSteps = ConnectorSetupProgress.encode(opened)
    }

    private func toggle(_ step: ConnectorSetupAssistant.StepID) {
        var opened = ConnectorSetupProgress.decode(openedSteps)
        if opened.contains(step) { opened.remove(step) } else { opened.insert(step) }
        openedSteps = ConnectorSetupProgress.encode(opened)
    }
}
