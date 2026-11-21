import SwiftUI
import YardletRemote

struct RemoteAccountMacList: View {
    let service: RemoteControlService
    let directory: RemoteHostDirectory
    let onOpen: (String) -> Void
    @Binding var busy: Bool
    @State private var macs: [RemoteAccountClient.Mac] = []
    @State private var loading = false
    @State private var error: String?
    @State private var number: String?
    @State private var connectingRoom: String?
    @State private var attempt: Task<Void, Never>?

    private var availableMacs: [RemoteAccountClient.Mac] {
        let pairedKeys = Set(directory.hosts.map(\.hostKey))
        return macs.filter { !pairedKeys.contains($0.macKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("Macs on your account")).font(.callout.weight(.semibold))
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.string("Refresh"))
                .disabled(loading || busy)
            }
            if loading {
                ProgressView().controlSize(.small)
            } else if availableMacs.isEmpty && error == nil {
                Text(L10n.string("No more Macs to connect on this account.")).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(availableMacs, id: \.room) { mac in
                        HStack {
                            Label(mac.name, systemImage: "desktopcomputer").lineLimit(1)
                            Spacer()
                            if connectingRoom == mac.room {
                                ProgressView().controlSize(.small)
                                Button(L10n.string("Cancel")) { attempt?.cancel() }
                            } else {
                                Button(L10n.string("Connect")) { connect(mac) }
                                    .disabled(busy)
                                    .accessibilityLabel(L10n.format("Open %@", mac.name))
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .frame(height: min(CGFloat(availableMacs.count) * 32, 160))
            if let number {
                Text(L10n.format("Confirm %@ on the other Mac or on a phone already connected to it.", number))
                    .font(.callout)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await refresh() }
        .onDisappear { attempt?.cancel() }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            macs = try await service.otherAccountMacs()
        } catch {
            macs = []
            self.error = L10n.string("Couldn’t load the Macs on your account. Try refreshing.")
        }
    }

    private func connect(_ mac: RemoteAccountClient.Mac) {
        guard !busy else { return }
        busy = true
        connectingRoom = mac.room
        number = nil
        error = nil
        attempt = Task { @MainActor in
            defer {
                busy = false
                connectingRoom = nil
                number = nil
            }
            do {
                let host = try await directory.connect(to: mac, service: service) { code in
                    Task { @MainActor in
                        if connectingRoom == mac.room { number = code }
                    }
                }
                if !Task.isCancelled { onOpen(host.id) }
            } catch let failure as RemoteHostDirectory.PairingFailure {
                if !Task.isCancelled { self.error = failure.message }
            } catch {
                guard !Task.isCancelled else { return }
                switch error as? RemoteHostConnection.LinkFailure {
                case .refused?: self.error = L10n.format("%@ didn't accept the connection.", mac.name)
                case .declined(let reason)? where reason.code == .linkUnavailable || reason.code == .notAllowed:
                    self.error = L10n.string("Check that both Macs are signed in to the same Yardlet account.")
                case .expired?: self.error = L10n.string("The connection request expired. Try again.")
                default: self.error = L10n.format("Can't reach %@. Check that it's awake and that remote connections are on.", mac.name)
                }
            }
        }
    }
}
