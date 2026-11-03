import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import YardletRemote

/// Settings › Remote: the switch that lets a phone or Yardlet on another computer follow and drive this
/// Mac's tasks, the switch for connecting from outside through the Yardlet relay, keeping the Mac awake on
/// power, the paths a device can take now, pairing a device (a QR code or its link, once, for five
/// minutes), a phone asking to link through the account, and the paired devices with how each is
/// connected and a way to remove each (docs/REMOTE_PROTOCOL.md §11–§14). Rows follow Settings › General.
struct RemoteSettingsView: View {
    let service: RemoteControlService
    @State private var deviceToRemove: RemoteDevice?
    /// The pairing link was just copied, said beside the button for a moment.
    @State private var copiedLink: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                row(setting: .remoteConnections) {
                    Toggle(YardletSetting.remoteConnections.title, isOn: Binding(
                        get: { service.isEnabled }, set: { service.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.paritySwitch)
                        .controlSize(.small)
                }
                if service.isEnabled {
                    if service.relayURL != nil {
                        divider
                        row(setting: .connectFromOutside) {
                            Toggle(YardletSetting.connectFromOutside.title, isOn: Binding(
                                get: { service.isRelayEnabled }, set: { service.setRelayEnabled($0) }))
                                .labelsHidden()
                                .toggleStyle(.paritySwitch)
                                .controlSize(.small)
                        }
                    }
                    divider
                    row(setting: .keepAwakeOnPower) {
                        Toggle(YardletSetting.keepAwakeOnPower.title, isOn: Binding(
                            get: { service.keepsAwakeOnPower }, set: { service.setKeepsAwakeOnPower($0) }))
                            .labelsHidden()
                            .toggleStyle(.paritySwitch)
                            .controlSize(.small)
                    }
                    divider
                    row(icon: "network", title: L10n.string("Connections"), detail: reachText,
                        detailColor: canPair ? .secondary : .orange) { EmptyView() }
                    if service.showsAccount {
                        divider
                        accountRow
                    }
                }
            }
            .padding(.horizontal, 12)
            .parityCard()

            if service.isEnabled {
                if let request = service.linkRequest { linkCard(request) }
                pairingCard
            }
            devicesCard
        }
        .task {
            await service.reloadDevices()
            // The relay may have gained or lost sign-in providers since the remote started.
            await service.refreshAccount()
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 30 + 12) // under the words, past the icon and the gap
    }

    private func row<Accessory: View>(
        icon: String, title: String, detail: String, detailColor: Color = .secondary,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            RemoteSettingsIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    /// A switch's row, in the words the settings catalog gives it.
    private func row<Accessory: View>(setting: YardletSetting, @ViewBuilder accessory: () -> Accessory) -> some View {
        row(icon: setting.symbol, title: setting.title, detail: setting.detail ?? "", accessory: accessory)
    }

    /// Signed in: the account and Sign out. Signed out: a button per provider the relay offers.
    private var accountRow: some View {
        row(icon: "person.crop.circle", title: L10n.string("Account"), detail: accountText,
            detailColor: service.accountError == nil ? .secondary : .orange) {
            if service.account != nil {
                Button(L10n.string("Sign out")) { Task { await service.signOut() } }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    ForEach(service.accountProviders, id: \.self) { provider in
                        Button(L10n.format("Sign in with %@", Self.providerName(provider))) {
                            Task { await service.signIn(with: provider) }
                        }
                        .controlSize(.small)
                        .disabled(service.isSigningIn)
                    }
                }
            }
        }
    }

    private var accountText: String {
        if let error = service.accountError { return error }
        guard let account = service.account else { return L10n.string("Find this Mac from a new phone without the QR code.") }
        return [Self.providerName(account.provider), account.name].compactMap { $0 }.joined(separator: " · ")
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "github": "GitHub"
        case "google": "Google"
        default: provider
        }
    }

    /// A phone can reach this Mac some way now.
    private var canPair: Bool {
        let reach = service.reach
        return reach.direct || reach.relay == .connected
    }

    /// The paths, in one line: "Same network · Tailscale · Yardlet server".
    private var reachText: String {
        let reach = service.reach
        var parts: [String] = []
        if reach.direct {
            parts.append(L10n.string("Same Wi-Fi"))
            if reach.tailscale { parts.append("Tailscale") }
        }
        switch reach.relay {
        case .connected?: parts.append(L10n.string("Yardlet server"))
        case .connecting?: parts.append(L10n.string("Connecting to the Yardlet server…"))
        case .failed?: parts.append(L10n.string("Can't reach the Yardlet server"))
        case .off?, nil: break
        }
        if let failure = reach.directFailure { parts.append(L10n.format("Can't listen for connections: %@", failure)) }
        return parts.isEmpty ? L10n.string("Starting…") : parts.joined(separator: " · ")
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pairing = service.pairing {
                HStack(alignment: .top, spacing: 18) {
                    RemotePairingQRCode(text: pairing.url?.absoluteString ?? "")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Scan this code with Yardlet on your phone."))
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.string("On another computer, copy the link and open it in Yardlet there."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L10n.format("Works once for 5 minutes · %@ left", Self.remaining(until: pairing.expiresAt, now: context.date)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            if let url = pairing.url {
                                Button(L10n.string("Copy link")) { copy(url) }
                                    .controlSize(.small)
                                if copiedLink == url {
                                    Text(L10n.string("Copied"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button(L10n.string("Cancel")) { service.cancelPairing() }
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
            } else {
                row(icon: "qrcode", title: L10n.string("Pair a device"), detail: pairingDescription) {
                    Button(L10n.string("Pair…")) { Task { await service.startPairing() } }
                        .controlSize(.small)
                        .disabled(!canPair)
                }
            }
        }
        .padding(.horizontal, 12)
        .parityCard()
    }

    private var pairingDescription: String {
        if let name = service.pairedDeviceName { return L10n.format("%@ is paired.", name) }
        return L10n.string("Shows a code to scan with your phone, and a link for Yardlet on another computer. It works once and expires after 5 minutes.")
    }

    /// The pairing link on the clipboard, for Yardlet on another computer: pasted there, or opened as a
    /// link (Universal Clipboard, AirDrop, a note). It is the QR code's secret, so it is marked as one.
    private func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        // Clipboard managers that honor it keep no history of the secret.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copiedLink = url
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedLink == url { copiedLink = nil }
        }
    }

    static func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Link requests

    private func linkCard(_ request: RemoteLinkRequest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RemoteSettingsIcon(systemName: "smartphone")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("%@ wants to connect to this Mac", request.name)).font(.callout.weight(.medium))
                Text(verbatim: Self.spaced(request.code))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .accessibilityLabel(L10n.string("Link code"))
                    .accessibilityValue(request.code)
                Text(L10n.string("Allow it if the phone shows the same number."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Decline")) { Task { await service.answerLink(approve: false) } }
                .controlSize(.small)
            // Not the default button: adding a device takes a click after comparing the numbers, not Return.
            Button(L10n.string("Allow")) { Task { await service.answerLink(approve: true) } }
                .controlSize(.small)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .parityCard()
    }

    /// `482913` as `482 913`.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("Paired devices"))
                .font(.callout.weight(.semibold))
                .padding(.vertical, 12)
            if service.devices.isEmpty {
                Text(L10n.string("No paired devices"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }
            ForEach(Array(service.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().padding(.leading, 48) }
                HStack(spacing: 12) {
                    RemoteSettingsIcon(systemName: Self.icon(for: device))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.callout.weight(.medium))
                        Text(deviceDetail(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.string("Remove"), role: .destructive) { deviceToRemove = device }
                        .controlSize(.small)
                        .accessibilityLabel(L10n.format("Remove %@", device.name))
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .parityCard()
        .confirmationDialog(
            L10n.format("Remove %@?", deviceToRemove?.name ?? ""),
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } })
        ) {
            Button(L10n.string("Remove"), role: .destructive) {
                if let device = deviceToRemove { Task { await service.remove(device) } }
                deviceToRemove = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { deviceToRemove = nil }
        } message: {
            Text(L10n.string("The device disconnects and has to pair again."))
        }
    }

    /// A computer reads as one; anything else as the phone it most likely is.
    static func icon(for device: RemoteDevice) -> String {
        switch device.platform {
        case "macos": "laptopcomputer"
        case "windows": "pc"
        default: "smartphone"
        }
    }

    private func deviceDetail(_ device: RemoteDevice) -> String {
        var parts: [String] = []
        if service.connectedDeviceIDs.contains(device.id) {
            parts.append(L10n.string("Connected"))
            switch service.connectedPaths[device.id] {
            case .local?, .loopback?: parts.append(L10n.string("Same Wi-Fi"))
            case .tailscale?: parts.append("Tailscale")
            case .relay?: parts.append(L10n.string("Yardlet server"))
            case nil: break
            }
        } else if let seen = device.lastSeenAt {
            parts.append(L10n.format("Last connected %@", seen.formatted(.relative(presentation: .named))))
        } else {
            parts.append(L10n.string("Never connected"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct RemoteSettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The pairing URL as a QR code (CoreImage `CIQRCodeGenerator`), black on white in both appearances
/// so a phone's camera reads it.
struct RemotePairingQRCode: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: 156, height: 156)
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(L10n.string("Pairing QR code"))
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
