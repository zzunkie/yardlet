import SwiftUI

/// The accounts of a provider whose services Yardlet serves itself (Google's, Microsoft's), as the
/// setup pages show them: each account's address, a chip per service that turns it on or off for
/// that account, its state and reasons, and below them the services a new account signs in with
/// and the button that signs one in (docs/CONNECTORS.md, "UI").
struct ServiceAccountList: View {
    let center: ConnectorCenter
    let provider: ConnectorAccountProvider
    @Binding var newAccountServices: Set<LocalConnectorService>

    private var canSignIn: Bool { center.canSignIn(with: provider) }
    /// What a new sign-in can turn on: not Google Analytics or Ads with Yardlet's own Google app.
    private var signInServices: [LocalConnectorService] { center.signInServices(provider) }

    private var signInTitle: String {
        switch provider {
        case .google: L10n.string("Sign in with Google")
        case .microsoft: L10n.string("Sign in with Microsoft")
        }
    }

    private var addTitle: String {
        switch provider {
        case .google: L10n.string("Add another Google account")
        case .microsoft: L10n.string("Add another Microsoft account")
        }
    }

    private var accountWord: String {
        switch provider {
        case .google: L10n.string("Google account")
        case .microsoft: L10n.string("Microsoft account")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let list = center.accounts(provider)
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
            HStack(spacing: 10) {
                ForEach(provider.services) { service in
                    let available = signInServices.contains(service)
                    Toggle(service.shortName, isOn: Binding(
                        get: { available && newAccountServices.contains(service) },
                        set: { on in
                            if on { newAccountServices.insert(service) } else { newAccountServices.remove(service) }
                        }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(!available)
                        .help(available ? "" : L10n.string("Connects only with a Google OAuth app of your own"))
                }
                Spacer(minLength: 6)
                Button {
                    center.addAccount(services: newAccountServices)
                } label: {
                    Label(list.isEmpty ? signInTitle : addTitle, systemImage: "person.badge.plus")
                }
                .parityProminentButton()
                .controlSize(.small)
                .disabled(!canSignIn || newAccountServices.intersection(signInServices).isEmpty)
            }
            if !canSignIn {
                Text(provider == .google ? L10n.string("Save the Google OAuth app first.") : L10n.string("Save the Microsoft app first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func accountRow(_ account: ConnectorCenter.ServiceAccount) -> some View {
        let states = account.services.map { ConnectorSettingsState.make($0, in: center) }
        let busy = states.contains { $0 == .connecting || $0 == .waitingForBrowser }
        let needsSignIn = account.services.contains { $0.status == .signInRequired }
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
                        if let first = account.services.first { center.cancelConnect(first.id) }
                    }
                    .controlSize(.small)
                } else if needsSignIn || !reasons.isEmpty || account.address == nil {
                    Button(account.address == nil ? L10n.string("Connect") : L10n.string("Reconnect")) {
                        if let first = account.services.first {
                            account.address == nil ? center.connect(first.id) : center.reconnect(first.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!canSignIn)
                }
                Menu {
                    if let first = account.services.first {
                        Button(L10n.string("Reconnect")) { center.reconnect(first.id) }
                    }
                    Divider()
                    Button(provider == .google ? L10n.string("Remove this Google account") : L10n.string("Remove this Microsoft account"),
                           role: .destructive) {
                        center.removeAccount(account.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.format("More for %@", account.address ?? accountWord))
            }
            HStack(spacing: 6) {
                ForEach(provider.services) { service in
                    serviceChip(service, account: account)
                }
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

    /// A service turned on or off for one account, with its state's dot.
    private func serviceChip(_ service: LocalConnectorService, account: ConnectorCenter.ServiceAccount) -> some View {
        let record = account.record(service)
        let state = record.map { ConnectorSettingsState.make($0, in: center) }
        let on = record != nil
        let available = signInServices.contains(service)
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
            .frame(height: 22)
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
        .disabled(!on && !(canSignIn && available))
        .help(on ? L10n.format("Turn %@ off for this account", service.name)
              : available ? L10n.format("Turn %@ on for this account", service.name)
              : L10n.string("Connects only with a Google OAuth app of your own"))
        .accessibilityLabel(service.name)
        .accessibilityValue(on ? (state?.word ?? L10n.string("On")) : L10n.string("Off"))
    }
}
