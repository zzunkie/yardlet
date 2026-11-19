import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Connectors → Add connector → App Store Connect: Apple's App Store Connect API with an
/// API key of the person's own (docs/CONNECTORS.md, "Apple"). The person makes the key in App Store
/// Connect, chooses the `.p8` file App Store Connect let them download once, and confirms its key ID
/// (read from the file's name) and, for a team key, the issuer ID. The key goes to the keychain;
/// once Yardlet has checked it, the page asks in a line of its own whether to move the file to the
/// Trash, rather than with a dialog over the sheet.
struct AppStoreConnectSetupPage: View {
    let center: ConnectorCenter
    /// Moves a file to the Trash (tests pass one that does not).
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    @State private var team: Bool
    @State private var keyFile: URL?
    @State private var keyID: String
    @State private var issuerID: String
    @State private var busy = false
    @State private var error: String?
    /// The file to offer to move to the Trash once its key connected.
    @State private var connectedFile: URL?
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// - Parameters: the page starts with these (review renders).
    init(center: ConnectorCenter, team: Bool = true, keyFile: URL? = nil, keyID: String = "", issuerID: String = "",
         trash: ((URL) throws -> Void)? = nil) {
        self.center = center
        if let trash { self.trash = trash }
        _team = State(initialValue: team)
        _keyFile = State(initialValue: keyFile)
        _keyID = State(initialValue: keyID)
        _issuerID = State(initialValue: issuerID)
    }

    private var keys: [ConnectorRecord] {
        center.connectors.filter { $0.localService == .appStoreConnect }
    }

    private var keyIDValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateAppStoreKeyID(keyID) }
    private var issuerValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateIssuerID(issuerID) }

    private var canConnect: Bool {
        keyFile != nil && keyIDValidation.isValid && (!team || issuerValidation.isValid) && !busy
    }

    private var assistant: ConnectorSetupAssistant {
        .appStoreConnect(opened: ConnectorSetupProgress.decode(openedSteps),
                         keyChosen: keyFile != nil && keyIDValidation.isValid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(L10n.string("Yardlet calls Apple's App Store Connect API itself with your API key, which stays in your keychain. No other company's server holds it."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            if !keys.isEmpty { keyList }
            if let connectedFile { trashQuestion(connectedFile) }
            ConnectorSetupHeader(title: keys.isEmpty ? L10n.string("Set up App Store Connect") : L10n.string("Add another key"),
                                 assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(assistant.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 28) }
                    ConnectorSetupStepRow(number: index + 1, step: step, isCurrent: assistant.current == step.id,
                                          onToggle: step.id == .ascCreateKey ? { toggle(step.id) } : nil,
                                          onOpen: { mark(step.id) }) {
                        switch step.id {
                        case .ascKeyFile: keyFields
                        case .ascConnect: connectRow
                        default: EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(L10n.string("Reading comes first: apps, builds, TestFlight, reviews, and App Store versions. Inviting or removing testers, giving a build to a group, answering a review, and submitting for review ask you each time."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The key is in the keychain now; the downloaded file need not stay in Downloads.
    private func trashQuestion(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(L10n.format("Move %@ to the Trash?", file.lastPathComponent))
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(L10n.string("Yardlet keeps the key in your keychain. App Store Connect won't let you download it again, so keep a copy somewhere safe if you need one."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 6)
                Button(L10n.string("Keep the File")) { connectedFile = nil }
                Button(L10n.string("Move to Trash"), action: moveToTrash)
                    .parityProminentButton()
            }
            .controlSize(.small)
        }
        .padding(12)
        .parityCard(cornerRadius: 10)
    }

    /// The keys added already, each with its state.
    private var keyList: some View {
        VStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, record in
                if index > 0 { Divider().padding(.leading, 12) }
                let state = ConnectorSettingsState.make(record, in: center)
                HStack(spacing: 8) {
                    Text(L10n.format("Key %@", record.account ?? ""))
                        .font(.callout.weight(.medium))
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

    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.string("Key type"), selection: $team) {
                Text(L10n.string("Team key")).tag(true)
                Text(L10n.string("Individual key")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 8) {
                Button(keyFile == nil ? L10n.string("Choose .p8 File…") : L10n.string("Choose Another…"), action: chooseFile)
                if let keyFile {
                    Label(keyFile.lastPathComponent, systemImage: "key")
                        .font(.caption.monospaced()).fontDesign(nil)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ConnectorValidatedField(title: L10n.string("Key ID"), text: $keyID, validation: keyIDValidation)
            if team {
                ConnectorValidatedField(title: L10n.string("Issuer ID"), text: $issuerID, validation: issuerValidation)
            } else {
                Text(L10n.string("An individual key can't reach certificates, profiles, sales and finance, or notarization."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private var connectRow: some View {
        HStack(spacing: 8) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.string("Connect"), action: connect)
                    .parityProminentButton()
                    .controlSize(.small)
                    .disabled(!canConnect)
            }
        }
        .padding(.top, 2)
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

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose the App Store Connect key")
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyFile = url
        error = nil
        if let id = AppStoreConnectKey.keyID(fromFileName: url.lastPathComponent) { keyID = id }
    }

    /// Reads the file only now, hands the key to the keychain, and once Apple has accepted it
    /// offers to put the file in the Trash.
    private func connect() {
        guard let keyFile else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let pem = try String(contentsOf: keyFile, encoding: .utf8)
                let record = try await center.addAppStoreConnectKey(privateKey: pem, keyID: keyID,
                                                                    issuerID: team ? issuerID : nil)
                await center.waitForConnection(record.id)
                if center.record(record.id)?.status == .connected {
                    connectedFile = keyFile
                    self.keyFile = nil
                    keyID = ""
                    issuerID = ""
                } else {
                    error = center.failures[record.id]
                }
            } catch let failure as CocoaError where failure.code == .fileReadNoPermission || failure.code == .fileReadNoSuchFile {
                error = L10n.string("Yardlet couldn't read that file. Choose it again.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func moveToTrash() {
        guard let file = connectedFile else { return }
        connectedFile = nil
        do {
            try trash(file)
        } catch {
            self.error = L10n.format("Yardlet couldn't move the file to the Trash: %@", error.localizedDescription)
        }
    }
}
