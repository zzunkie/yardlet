import SwiftUI
import YardletRemote

/// The first screen: connect to a Mac by its pairing code or through the account it is signed in to, or look around
/// with the demo Mac.
struct WelcomeView: View {
    @Environment(PhoneModel.self) private var model
    @State private var isScanning = false
    @State private var isPasting = false
    @State private var showsAccountMacs = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("AppIconImage")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("Connect to your Mac")
                .font(.title2.weight(.semibold))
                .padding(.top, 24)
            Text("On your Mac, open Yardlet › Settings… › Remote and choose Pair… beside Pair a device. Then scan the code it shows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    isScanning = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(CardButtonStyle(role: "primary"))
                if model.account.account != nil {
                    Button {
                        showsAccountMacs = true
                    } label: {
                        Text("Choose a Mac on Your Account")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(CardButtonStyle(role: "secondary"))
                } else {
                    AccountSignInButtons { showsAccountMacs = true }
                }
                Button {
                    isPasting = true
                } label: {
                    Text("Paste a Pairing Link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(CardButtonStyle(role: "secondary"))
                Button("Try Without a Mac") {
                    Task {
                        await model.startDemo()
                        // As pairing a Mac asks: the demo shows a notification once the person leaves the app.
                        if model.isDemo { model.requestNotificationPermission() }
                    }
                }
                .font(.callout)
                .padding(.top, 8)
                Link("Privacy Policy", destination: URL(string: "https://yardlet.app/privacy.html")!)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .disabled(model.isPairing)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task { await model.account.refreshProviders() }
        .overlay {
            if model.isPairing {
                ProgressView("Connecting…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .sheet(isPresented: $isScanning) {
            PairingScanner { link in
                isScanning = false
                Task { await model.pair(link) }
            }
        }
        .sheet(isPresented: $isPasting) {
            PasteLinkView { link in
                isPasting = false
                Task { await model.pair(link) }
            }
        }
        .sheet(isPresented: $showsAccountMacs, onDismiss: { model.account.error = nil }) {
            AccountMacsView { showsAccountMacs = false }
        }
        .alert("Couldn't sign in", isPresented: Binding(get: { model.account.error != nil && !showsAccountMacs },
                                                        set: { if !$0 { model.account.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.account.error ?? "")
        }
    }
}

/// A pairing link typed or pasted by hand: the one Copy link puts on the Mac's clipboard.
struct PasteLinkView: View {
    let onLink: (RemoteSecurePairingURL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var link: RemoteSecurePairingURL? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(RemoteSecurePairingURL.parse)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("yardlet-remote://pair?…", text: $text, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                } footer: {
                    if !text.isEmpty && link == nil {
                        Text("This isn't a Yardlet pairing link.")
                    } else {
                        Text("On your Mac, choose Copy link under the pairing code, then paste the link here.")
                    }
                }
            }
            .navigationTitle("Pairing Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { if let link { onLink(link) } }
                        .disabled(link == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
