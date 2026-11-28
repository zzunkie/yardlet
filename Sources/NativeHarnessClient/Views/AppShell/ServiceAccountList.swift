import SwiftUI

/// The accounts of a provider whose services Yardlet serves itself (Google's, Microsoft's), as the
/// setup pages show them: each account's address, a chip per service that turns it on or off for
/// that account, its state and reasons, and below them the services a new account signs in with
/// and the button that signs one in (docs/CONNECTORS.md, "UI").
struct ServiceAccountList: View {
    let center: ConnectorCenter
    let provider: ConnectorAccountProvider
    @Binding var newAccountServices: Set<LocalConnectorService>
    /// The account whose removal waits for the person's answer.
    @State private var removingAccount: UUID?
    @State private var editingGoogleAccount: ConnectorCenter.ServiceAccount?
    @State private var calendarIssue: String?
    @State private var calendarSigningIn = false

    private var canSignIn: Bool { center.canSignIn(with: provider) }
    private var signInServices: [LocalConnectorService] { center.signInServices(provider) }

    private var accountWord: String {
        switch provider {
        case .google: L10n.string("Google account")
        case .microsoft: L10n.string("Microsoft account")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let list = center.accounts(provider)
            if let calendarIssue {
                Text(calendarIssue).font(.caption).foregroundStyle(.red)
            }
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        accountRow(account)
                    }
                }
                .padding(.horizontal, 10)
                .background(ParityTheme.subtleFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if provider == .microsoft { microsoftSignIn(listIsEmpty: list.isEmpty) }
        }
        .padding(.top, 2)
        .sheet(item: $editingGoogleAccount) { account in
            GoogleAccountClientSheet(center: center, account: account)
        }
        // Removing signs the account out of every service, so it asks first, naming the account.
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removingAccount != nil },
                                                               set: { if !$0 { removingAccount = nil } })) {
            Button(L10n.string("Remove"), role: .destructive) {
                if let id = removingAccount { center.removeAccount(id) }
                removingAccount = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { removingAccount = nil }
        } message: {
            Text(L10n.string("Tasks stop using its services, and Yardlet signs out of the account."))
        }
    }

    private func microsoftSignIn(listIsEmpty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach(signInServices) { service in
                    Toggle(service.shortName, isOn: Binding(
                        get: { newAccountServices.contains(service) },
                        set: { on in
                            if on { newAccountServices.insert(service) } else { newAccountServices.remove(service) }
                        }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer(minLength: 6)
                Button {
                    center.addAccount(services: newAccountServices)
                } label: {
                    Label(listIsEmpty ? L10n.string("Sign in with Microsoft") : L10n.string("Add another Microsoft account"),
                          systemImage: "person.badge.plus")
                }
                .parityProminentButton()
                .controlSize(.small)
                .disabled(!canSignIn || newAccountServices.intersection(signInServices).isEmpty)
            }
            if !canSignIn {
                Text(L10n.string("Save the Microsoft app first.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var removalTitle: String {
        let account = center.accounts(provider).first { $0.id == removingAccount }
        return L10n.format("Remove %@?", account?.address ?? accountWord)
    }

    private func accountRow(_ account: ConnectorCenter.ServiceAccount) -> some View {
        let enabled = account.services.filter { $0.localService.map(account.enabled.contains) == true }
        let states = enabled.map { ConnectorSettingsState.make($0, in: center) }
        let busy = states.contains { $0 == .connecting || $0 == .waitingForBrowser }
        let needsSignIn = enabled.contains { $0.status == .signInRequired }
        let reasons = Array(Set(states.compactMap { state -> String? in
            if case let .error(reason) = state { return reason }
            return nil
        })).sorted()
        let notes = Array(Set(account.services.compactMap { ConnectorSettingsState.note($0, in: center) })).sorted()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(account.address ?? L10n.string("Not signed in yet"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.mini)
                    Text(states.contains(.waitingForBrowser) ? L10n.string("Sign in in your browser") : L10n.string("Connecting…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("Cancel")) {
                        if let first = enabled.first { center.cancelConnect(first.id) }
                    }
                    .controlSize(.small)
                } else if needsSignIn || !reasons.isEmpty || account.address == nil {
                    Button(account.address == nil ? L10n.string("Connect") : L10n.string("Reconnect")) {
                        if provider == .google && !hasClient(account) {
                            editingGoogleAccount = account
                        } else if let first = enabled.first {
                            account.address == nil ? center.connect(first.id) : center.reconnect(first.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(provider == .microsoft && !canSignIn)
                }
                Menu {
                    if let first = enabled.first, provider != .google || hasClient(account) {
                        Button(L10n.string("Reconnect")) { center.reconnect(first.id) }
                    }
                    if provider == .google {
                        Button(L10n.string("Change OAuth client for this account…")) { editingGoogleAccount = account }
                        if center.googleBuiltInApp != nil {
                            Button(L10n.string("Sign in to Google for Yardlet Calendar")) {
                                calendarSigningIn = true
                                calendarIssue = nil
                                Task {
                                    defer { calendarSigningIn = false }
                                    do { try await center.signInGoogleCalendarUI(account: account.id) }
                                    catch is CancellationError {}
                                    catch { calendarIssue = error.localizedDescription }
                                }
                            }
                            .disabled(calendarSigningIn)
                        }
                    }
                    Divider()
                    Button(provider == .google ? L10n.string("Remove this Google account…") : L10n.string("Remove this Microsoft account…"),
                           role: .destructive) {
                        removingAccount = account.id
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.format("More for %@", account.address ?? accountWord))
            }
            if account.services.contains(where: { $0.hasGoogleUISignIn }) {
                Label(L10n.string("Yardlet Calendar connected"), systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if provider == .google {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 123), alignment: .leading)], alignment: .leading, spacing: 5) {
                    chips(account)
                }
            } else {
                HStack(spacing: 6) { chips(account) }
            }
            ForEach(reasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(account.address ?? accountWord)
    }

    private func chips(_ account: ConnectorCenter.ServiceAccount) -> some View {
        ForEach(provider.services) { service in serviceChip(service, account: account) }
    }

    private func hasClient(_ account: ConnectorCenter.ServiceAccount) -> Bool {
        center.googleAppClientID != nil || account.services.contains { $0.googleOAuthClientID != nil }
    }

    /// A service turned on or off for one account, with its state's dot.
    private func serviceChip(_ service: LocalConnectorService, account: ConnectorCenter.ServiceAccount) -> some View {
        let record = account.record(service)
        let state = record.map { ConnectorSettingsState.make($0, in: center) }
        let on = account.enabled.contains(service)
        let available = provider == .google ? hasClient(account) : canSignIn && signInServices.contains(service)
        return Button {
            Task { await center.setService(service, on: !on, account: account.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? AnyShapeStyle(state?.color ?? ParityTheme.accent) : AnyShapeStyle(.tertiary))
                Text(service.shortName)
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let word = state?.chipWord, on, !word.isEmpty {
                    Text(word)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(on ? ParityTheme.subtleFill : Color.clear)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ParityTheme.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .disabled(!on && !available)
        .help(on ? L10n.format("Turn %@ off for this account", service.name)
              : available ? L10n.format("Turn %@ on for this account", service.name)
              : L10n.string("Connects only with a Google OAuth app of your own"))
        .accessibilityLabel(service.name)
        .accessibilityValue(on ? (state?.word ?? L10n.string("On")) : L10n.string("Off"))
    }
}

private struct GoogleAccountClientSheet: View {
    let center: ConnectorCenter
    let account: ConnectorCenter.ServiceAccount
    @Environment(\.dismiss) private var dismiss
    @State private var client: GoogleClientDraft
    @State private var issue: String?
    @State private var saving = false

    init(center: ConnectorCenter, account: ConnectorCenter.ServiceAccount) {
        self.center = center
        self.account = account
        _client = State(initialValue: GoogleClientDraft(id: account.services.first?.googleOAuthClientID ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.address ?? L10n.string("Google account")).font(.headline)
            GooglePersonalModeLink()
            GoogleClientFields(client: $client)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account.enabled.isEmpty ? L10n.string("Save") : L10n.string("Reconnect")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await center.saveGoogleClient(account: account.id, clientID: client.id, secret: client.secret)
                            if let first = account.services.first(where: { $0.localService.map(account.enabled.contains) == true }) {
                                center.reconnect(first.id)
                            }
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!client.valid)
            }
        }
        .disabled(saving)
        .padding(20)
        .frame(width: 440)
    }
}
