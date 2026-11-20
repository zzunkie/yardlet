import AuthenticationServices
import SwiftUI
import YardletRemote

extension PhoneAccount {
    /// Signs in through the system's browser sign-in sheet that SwiftUI presents over the current screen.
    func signIn(with provider: String, using session: WebAuthenticationSession) async -> Bool {
        await signIn(with: provider) { url, scheme in
            if #available(iOS 17.4, *) {
                try await session.authenticate(using: url, callback: .customScheme(scheme), additionalHeaderFields: [:])
            } else {
                try await session.authenticate(using: url, callbackURLScheme: scheme)
            }
        }
    }
}

/// "Sign in with GitHub", "Sign in with Google": a button for each provider the relay offers, and none when it offers
/// none (docs/REMOTE_PROTOCOL.md §14.4). `onSignedIn` follows a sign-in that finished.
struct AccountSignInButtons: View {
    let onSignedIn: () -> Void
    @Environment(PhoneModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        ForEach(model.account.providers, id: \.self) { provider in
            Button {
                Task {
                    if await model.account.signIn(with: provider, using: webAuthenticationSession) { onSignedIn() }
                }
            } label: {
                Text("Sign in with \(PhoneAccount.providerName(provider))")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(CardButtonStyle(role: "secondary"))
            .disabled(model.account.isSigningIn)
        }
    }
}

/// The Macs on the account (§14.4). One paired already is shown; another is asked to let this phone in (§12.1), and
/// shows the same code as this phone while it waits for someone to allow it there. Before any Mac is paired this is
/// also where the account is signed out.
struct AccountMacsView: View {
    /// Called once a Mac is shown: the one chosen, or the one that let this phone in.
    let onDone: () -> Void
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: RemoteAccountClient.Mac?
    @State private var linking: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let link = model.accountLink {
                    LinkCodeView(link: link) { if let chosen { choose(chosen) } }
                } else {
                    list
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if model.accountLink != nil {
                            stopLinking()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .task { if model.account.macs == nil { await model.account.loadMacs() } }
        .onDisappear { stopLinking() }
        .interactiveDismissDisabled(isWaiting)
    }

    private var title: String {
        switch model.accountLink {
        case let .asking(mac)?, let .waiting(mac, _)?, let .failed(mac, _)?: mac
        case nil: String(localized: "Macs on Your Account")
        }
    }

    private var isWaiting: Bool {
        if case .waiting? = model.accountLink { return true }
        return false
    }

    private var list: some View {
        List {
            Section {
                if let macs = model.account.macs {
                    ForEach(macs, id: \.room) { mac in row(mac) }
                } else if model.account.error == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                if let error = model.account.error {
                    Text(error).foregroundStyle(.red)
                    if model.account.account != nil {
                        Button("Try Again") { Task { await model.account.loadMacs() } }
                    }
                }
            } footer: {
                if model.account.macs?.isEmpty == true {
                    Text("No Mac is on this account yet. On your Mac, sign in with the same account under Yardlet › Settings… › Yardlet Account, and turn on Allow remote connections under Remote.")
                } else if model.account.macs != nil {
                    Text("Choose your Mac. It shows a number; allow this phone there when it matches the one here.")
                }
            }

            if let name = model.account.name {
                Section {
                    LabeledContent("Signed in", value: name)
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await model.account.signOut()
                            dismiss()
                        }
                    }
                }
            }
        }
        .refreshable { await model.account.loadMacs() }
    }

    private func row(_ mac: RemoteAccountClient.Mac) -> some View {
        Button {
            choose(mac)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).foregroundStyle(.primary)
                    if model.pairedHost(mac) != nil {
                        Text("Paired with this phone").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func choose(_ mac: RemoteAccountClient.Mac) {
        if let host = model.pairedHost(mac) {
            model.select(host.id)
            onDone()
            return
        }
        chosen = mac
        linking?.cancel()
        linking = Task {
            if await model.link(mac) { onDone() }
        }
    }

    private func stopLinking() {
        linking?.cancel()
        linking = nil
        model.clearAccountLink()
    }
}

/// A link request on its way (§12.1): the code this phone computed, which the Mac shows beside the request, and the
/// line that says where to allow it.
private struct LinkCodeView: View {
    let link: PhoneModel.AccountLink
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            switch link {
            case let .asking(mac):
                ProgressView()
                Text("Asking \(mac)…")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            case let .waiting(mac, code):
                Text("Check Your Mac")
                    .font(.title2.weight(.semibold))
                Text(verbatim: PushNotice.spaced(code))
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .padding(.top, 24)
                    .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
                Text("Check that \(mac) shows the same number, then choose Allow there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for your Mac…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 28)
            case let .failed(_, message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Button("Try Again", action: retry)
                    .padding(.top, 20)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}
