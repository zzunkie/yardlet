import AuthenticationServices
import SwiftUI
import UserNotifications
import YardletRemote

/// The Macs this phone paired with, pairing another, the Yardlet account, App Lock and notifications.
struct SettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isScanning = false
    @State private var isPasting = false
    @State private var showsAccountMacs = false
    @State private var removing: RemoteSavedHost?
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.hosts) { host in
                        Button {
                            model.select(host.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                if host.id == model.session?.id && !model.isDemo, let session = model.session {
                                    ConnectionStatusDot(connection: session.connection, size: 8)
                                } else {
                                    StatusDot(color: YardletPalette.outline, size: 8)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).foregroundStyle(YardletPalette.onSurface)
                                    Text(status(host)).font(.footnote).foregroundStyle(YardletPalette.onSurfaceVariant)
                                }
                                Spacer()
                                if host.id == model.session?.id && !model.isDemo {
                                    Image(systemName: "checkmark").foregroundStyle(YardletPalette.primary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = host }
                        }
                    }
                    Menu {
                        Button {
                            isScanning = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            isPasting = true
                        } label: {
                            Label("Paste a Pairing Link", systemImage: "link")
                        }
                        if model.account.account != nil {
                            Button {
                                showsAccountMacs = true
                            } label: {
                                Label("Choose a Mac on Your Account", systemImage: "person.crop.circle")
                            }
                        } else {
                            ForEach(model.account.providers, id: \.self) { provider in
                                Button {
                                    Task {
                                        if await model.account.signIn(with: provider, using: webAuthenticationSession) {
                                            showsAccountMacs = true
                                        }
                                    }
                                } label: {
                                    Label("Sign in with \(PhoneAccount.providerName(provider))", systemImage: "person.crop.circle")
                                }
                            }
                        }
                    } label: {
                        Label("Pair a Mac", systemImage: "plus")
                    }
                    if model.isDemo {
                        Button {
                            model.leaveDemo()
                            dismiss()
                        } label: {
                            Label("Leave Demo", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("To pair a Mac, open Yardlet › Settings › Remote on it and choose Pair beside Pair a device. Swipe left on a Mac to remove it; that Mac unpairs this phone too.")
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .listRowBackground(YardletPalette.surfaceContainerLow)

                if let name = model.account.name {
                    Section {
                        LabeledContent("Signed in", value: name)
                        Button("Sign Out", role: .destructive) { Task { await model.account.signOut() } }
                    } header: {
                        Text("Yardlet Account")
                    } footer: {
                        Text("Lists the Macs signed in to this account, to pair one without a QR code. Signing out leaves your paired Macs connected.")
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    .listRowBackground(YardletPalette.surfaceContainerLow)
                } else if let error = model.account.error, !showsAccountMacs {
                    Section {
                        Text(error).foregroundStyle(YardletPalette.error)
                    } header: {
                        Text("Yardlet Account")
                    }
                    .listRowBackground(YardletPalette.surfaceContainerLow)
                }

                Section {
                    Toggle("App Lock", isOn: Binding(get: { model.lock.isEnabled },
                                                     set: { on in Task { await model.lock.setEnabled(on) } }))
                        .disabled(!model.lock.isAvailable)
                } footer: {
                    Text("Asks for Face ID or your passcode each time you open Yardlet.")
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .listRowBackground(YardletPalette.surfaceContainerLow)

                Section {
                    switch notifications {
                    case .authorized, .provisional, .ephemeral:
                        LabeledContent("Notifications", value: String(localized: "On"))
                    case .denied:
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            LinkRow("Turn On Notifications in Settings", symbol: "arrow.up.right")
                        }
                    default:
                        Button {
                            model.requestNotificationPermission()
                        } label: {
                            LinkRow("Turn On Notifications", symbol: "chevron.right")
                        }
                    }
                } footer: {
                    Text("Approvals, questions and finished tasks, sent by your Mac while Yardlet is closed. Their content is encrypted for this phone; Apple and the relay can't read it.")
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .listRowBackground(YardletPalette.surfaceContainerLow)

                Section {
                    LabeledContent("Version", value: Self.version)
                    Link(destination: URL(string: "https://github.com/zzunkie/yardlet")!) {
                        LinkRow("Source Code", symbol: "arrow.up.right")
                    }
                    Link(destination: URL(string: "https://yardlet.app/privacy.html")!) {
                        LinkRow("Privacy Policy", symbol: "arrow.up.right")
                    }
                }
                .listRowBackground(YardletPalette.surfaceContainerLow)
            }
            .scrollContentBackground(.hidden)
            .background(YardletPalette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
            .task { await model.account.refreshProviders() }
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
                                presenting: removing) { host in
                Button("Remove", role: .destructive) { Task { await model.remove(host.id) } }
            } message: { _ in
                Text("This phone stops following its tasks, and the Mac forgets this phone. Pair again to connect.")
            }
            .sheet(isPresented: $isScanning) {
                PairingScanner { link in
                    isScanning = false
                    dismiss()
                    Task { await model.pair(link) }
                }
            }
            .sheet(isPresented: $isPasting) {
                PasteLinkView { link in
                    isPasting = false
                    dismiss()
                    Task { await model.pair(link) }
                }
            }
            .sheet(isPresented: $showsAccountMacs, onDismiss: { model.account.error = nil }) {
                AccountMacsView {
                    showsAccountMacs = false
                    dismiss()
                }
            }
        }
    }

    private func status(_ host: RemoteSavedHost) -> String {
        if host.id == model.session?.id, let session = model.session {
            switch session.connection {
            case .connected(.relay): return String(localized: "Connected through the relay")
            case .connected: return String(localized: "Connected directly")
            case .connecting: return String(localized: "Connecting…")
            case .removed: return String(localized: "Removed this phone")
            default: return String(localized: "Not reachable")
            }
        }
        if let date = host.lastConnectedAt {
            return String(localized: "Last connected \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }
}

/// A settings row that goes somewhere: its title, and a chevron for a step in the app or an arrow for a page that
/// opens outside it.
private struct LinkRow: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .accessibilityHidden(true)
        }
    }
}
