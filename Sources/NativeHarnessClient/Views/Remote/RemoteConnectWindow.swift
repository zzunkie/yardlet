import SwiftUI
import YardletRemote

/// File › Connect to Mac…: the Macs this one paired with, each opening its window, and a field for a new
/// Mac's connection link (Settings › Remote › Pair… › Copy link on that Mac). A link opened with Yardlet
/// lands in the field; nothing pairs until the person chooses Connect.
struct RemoteConnectWindow: View {
    static let sceneID = "remote-connect"

    let directory: RemoteHostDirectory
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var link = ""
    @State private var error: String?
    @State private var isPairing = false
    @State private var hostToRemove: RemoteSavedHost?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Connect to a Mac"))
                    .font(.title3.weight(.semibold))
                Text(L10n.string("Follow and drive another Mac's tasks here. On that Mac, open Settings › Remote, choose Pair…, then Copy link, and paste the link below."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(L10n.string("Connection link"), text: $link, prompt: Text(verbatim: "yardlet-remote://pair?…"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pair)
                        .accessibilityLabel(L10n.string("Connection link"))
                    Button(L10n.string("Connect"), action: pair)
                        .parityProminentButton()
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)
                }
                if isPairing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Connecting…")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.string("The link works once, for 5 minutes. Pair once while both Macs are together; from then on this Mac connects on the same network, over Tailscale or through the Yardlet server."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !directory.hosts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.string("Paired Macs"))
                        .font(.callout.weight(.semibold))
                        .padding(.vertical, 10)
                    ForEach(Array(directory.hosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.callout.weight(.medium))
                                Text(host.lastConnectedAt.map { L10n.format("Last connected %@", $0.formatted(.relative(presentation: .named))) }
                                     ?? L10n.string("Never connected"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(L10n.string("Remove…"), role: .destructive) { hostToRemove = host }
                                .controlSize(.small)
                                .accessibilityLabel(L10n.format("Remove %@", host.name))
                            Button(L10n.string("Open")) { open(host.id) }
                                .controlSize(.small)
                                .accessibilityLabel(L10n.format("Open %@", host.name))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .parityCard()
            }
        }
        .padding(22)
        .frame(width: 540, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(ParityTheme.canvas)
        .onAppear(perform: takeOpenedLink)
        .onChange(of: directory.openedLink) { _, _ in takeOpenedLink() }
        .confirmationDialog(
            L10n.format("Remove %@?", hostToRemove?.name ?? ""),
            isPresented: Binding(get: { hostToRemove != nil }, set: { if !$0 { hostToRemove = nil } })
        ) {
            Button(L10n.string("Remove"), role: .destructive) {
                if let host = hostToRemove { Task { await directory.forget(host.id) } }
                hostToRemove = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { hostToRemove = nil }
        } message: {
            Text(L10n.string("Its window closes and this Mac forgets it. When it can be reached now, it forgets this Mac too; otherwise remove this Mac in its Settings › Remote."))
        }
    }

    private func takeOpenedLink() {
        guard let opened = directory.openedLink else { return }
        link = opened
        error = nil
        directory.openedLink = nil
    }

    private func pair() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isPairing else { return }
        isPairing = true
        error = nil
        Task {
            defer { isPairing = false }
            do {
                let host = try await directory.pair(link: text)
                link = ""
                open(host.id)
            } catch let failure as RemoteHostDirectory.PairingFailure {
                error = failure.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func open(_ hostID: String) {
        openWindow(id: RemoteHostWindow.sceneID, value: hostID)
        dismissWindow(id: Self.sceneID)
    }
}

/// File › Connect to Mac… and the Macs paired before, each opening its window.
struct RemoteHostCommands: Commands {
    let directory: RemoteHostDirectory
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(L10n.string("Connect to Mac…")) { openWindow(id: RemoteConnectWindow.sceneID) }
            if !directory.hosts.isEmpty {
                Menu(L10n.string("Paired Macs")) {
                    ForEach(directory.hosts) { host in
                        Button(host.name) { openWindow(id: RemoteHostWindow.sceneID, value: host.id) }
                    }
                }
            }
        }
    }
}

/// Lets the app open host windows from outside a view (a notification's click, a `yardlet-remote` link):
/// the main window hands its `openWindow` to the directory once it shows.
struct RemoteWindowOpening: ViewModifier {
    let directory: RemoteHostDirectory?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard let directory else { return }
            directory.openHostWindow = { hostID in
                openWindow(id: RemoteHostWindow.sceneID, value: hostID)
                RemoteHostWindow.bringForward(hostID: hostID)
            }
            directory.openConnectWindow = { openWindow(id: RemoteConnectWindow.sceneID) }
        }
    }
}
