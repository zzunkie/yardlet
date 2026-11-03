import SwiftUI
import UserNotifications
import YardletRemote

/// The Macs this phone paired with, pairing another, App Lock and notifications.
struct SettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = false
    @State private var isPasting = false
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
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).foregroundStyle(.primary)
                                    Text(status(host)).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if host.id == model.session?.id && !model.isDemo {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
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
                    } label: {
                        Label("Pair a Mac", systemImage: "plus")
                    }
                    if model.isDemo {
                        Button("Leave Demo") {
                            model.leaveDemo()
                            dismiss()
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("Pair a Mac from Yardlet on it: Settings › Remote › Pair a device. Swipe a Mac to remove it; it forgets this phone too.")
                }

                Section {
                    Toggle("App Lock", isOn: Binding(get: { model.lock.isEnabled },
                                                     set: { on in Task { await model.lock.setEnabled(on) } }))
                        .disabled(!model.lock.isAvailable)
                } footer: {
                    Text("Asks for Face ID or your passcode each time you open Yardlet.")
                }

                Section {
                    switch notifications {
                    case .authorized, .provisional, .ephemeral:
                        LabeledContent("Notifications", value: String(localized: "On"))
                    case .denied:
                        Button("Turn On Notifications in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    default:
                        Button("Turn On Notifications") {
                            model.requestNotificationPermission()
                        }
                    }
                } footer: {
                    Text("Approvals, questions and finished tasks, sent by your Mac while Yardlet is closed. Their content is encrypted for this phone; Apple and the relay can't read it.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    Link("Source Code", destination: URL(string: "https://github.com/zzunkie/yardlet")!)
                    Link("Privacy Policy", destination: URL(string: "https://yardlet.app/privacy.html")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
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
