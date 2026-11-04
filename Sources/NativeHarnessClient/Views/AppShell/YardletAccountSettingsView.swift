import SwiftUI
import YardletRemote

/// Settings › Yardlet Account: the account on the Yardlet server that lets a new phone find this Mac without
/// the QR code (docs/REMOTE_PROTOCOL.md §14.4). Signed in, the account and Sign out; signed out, a button per
/// provider the server offers. Signing in works whether or not remote connections are on; while they are
/// off, a line says the account finds this Mac only once they are. Opening the page reads the providers
/// (`RemoteControlService.refreshAccountPage`); nothing reads them on a schedule. Rows follow Settings › Remote.
struct YardletAccountSettingsView: View {
    let service: RemoteControlService

    var body: some View {
        HStack(spacing: 12) {
            RemoteSettingsIcon(systemName: "person.crop.circle")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Account")).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(service.accountError == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !service.isEnabled {
                    Text(L10n.string("Turn on remote connections so a new phone can find this Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 12)
        .parityCard()
        .task { await service.refreshAccountPage() }
    }

    @ViewBuilder
    private var accessory: some View {
        if service.account != nil {
            Button(L10n.string("Sign out")) { Task { await service.signOut() } }
                .controlSize(.small)
        } else if !service.accountProviders.isEmpty {
            HStack(spacing: 6) {
                ForEach(service.accountProviders, id: \.self) { provider in
                    Button(L10n.format("Sign in with %@", Self.providerName(provider))) {
                        Task { await service.signIn(with: provider) }
                    }
                    .controlSize(.small)
                    .disabled(service.isSigningIn)
                }
            }
        } else if service.accountProvidersRead == nil {
            ProgressView().controlSize(.small)
        }
    }

    private var detail: String {
        if let error = service.accountError { return error }
        if let account = service.account { return Self.name(of: account) }
        switch service.accountProvidersRead {
        case false?: return L10n.string("Can't reach the Yardlet server")
        case true? where service.accountProviders.isEmpty:
            return L10n.string("This Yardlet server doesn't offer sign-in.")
        default: return L10n.string("Find this Mac from a new phone without the QR code.")
        }
    }

    /// The line under the section's name in the Settings list: the account, or that nobody is signed in.
    static func summary(_ service: RemoteControlService) -> String {
        service.account.map(name(of:)) ?? L10n.string("Not signed in")
    }

    static func name(of account: RemoteAccountClient.Account) -> String {
        [providerName(account.provider), account.name].compactMap { $0 }.joined(separator: " · ")
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "github": "GitHub"
        case "google": "Google"
        default: provider
        }
    }
}
