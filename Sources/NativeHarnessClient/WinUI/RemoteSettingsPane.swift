import Foundation
import Observation
import QRCodeGenerator
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// Settings › Remote in the Windows app, as the Mac's (`RemoteSettingsView`): the switch that lets a phone or
/// Yardlet on another computer follow and drive this computer's tasks, the paths a device can take now, pairing
/// a device (a QR code or its link, once, for five minutes) and the paired devices with how each is connected,
/// its permissions and a way to remove each (docs/REMOTE_PROTOCOL.md §11–§14). The service is the engine's
/// `RemoteControlService`; this pane follows it through Observation. Its settings share the grouped rows used by
/// `SettingsPane`. The Mac's switches for the relay and for keeping the computer
/// awake, and its account link requests, are not here.
@MainActor
final class RemoteSettingsPane {
    let view = StackPanel()
    private let service: RemoteControlService
    private let log = QAEventLog.shared
    private let enabledSwitch = SettingsGroup.toggle(named: L10n.string("Allow remote connections"))
    private var reachRow = Border()
    private var reachLine = TextBlock()
    private let pairingPanel = StackPanel()
    private var pairingCard = Border()
    private let devicesPanel = StackPanel()
    private var shownPairing: RemoteControlService.Pairing?
    private var countdown: TextBlock?
    private var countdownTask: Task<Void, Never>?
    private var copiedNote: TextBlock?
    private var shownDevices: [String]?
    private var permissionSwitches: [RemotePermissionKey: ToggleSwitch] = [:]
    private var loggedReach: String?

    init(service: RemoteControlService) {
        self.service = service
        view.spacing = 16
        enabledSwitch.isOn = service.isEnabled
        enabledSwitch.toggled.addHandler { [weak self] _, _ in
            guard let self, self.enabledSwitch.isOn != self.service.isEnabled else { return }
            self.service.setEnabled(self.enabledSwitch.isOn)
            self.log.write("remote host: \(self.enabledSwitch.isOn ? "on" : "off")")
        }
        let (enabled, _) = SettingsGroup.row(
            title: L10n.string("Allow remote connections"),
            description: L10n.string("Follow and drive this computer's tasks from Yardlet on your phone or another computer."),
            control: enabledSwitch)
        let connections = SettingsGroup([enabled])
        let (reach, reachLine) = SettingsGroup.row(title: L10n.string("Connections"))
        self.reachLine = reachLine
        reachRow = connections.append(reach)
        view.children.append(connections.view)
        pairingPanel.spacing = 8
        pairingCard = SettingsGroup([pairingPanel]).view
        view.children.append(pairingCard)
        view.children.append(devicesPanel)
        follow()
    }

    /// The pane as it opens: the devices read again, as the Mac's view reads them.
    func show() {
        Task { await service.reloadDevices() }
    }

    private func follow() {
        let state = withObservationTracking {
            (service.isEnabled, service.reach, service.pairing, service.pairedDeviceName, deviceRows())
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        let (isEnabled, reach, pairing, pairedName, devices) = state
        if enabledSwitch.isOn != isEnabled { enabledSwitch.isOn = isEnabled }
        let reachText = isEnabled ? Self.reachText(reach) : ""
        reachLine.text = reachText
        reachLine.visibility = .visible
        reachRow.visibility = isEnabled ? .visible : .collapsed
        if isEnabled, reachText != loggedReach {
            loggedReach = reachText
            log.write("remote host reach: \(reachText)")
        }
        showPairing(isEnabled ? pairing : nil, visible: isEnabled, canPair: reach.direct || reach.relay == .connected,
                    pairedName: pairedName)
        showDevices(devices)
    }

    // MARK: - Pairing

    private func showPairing(_ pairing: RemoteControlService.Pairing?, visible: Bool, canPair: Bool, pairedName: String?) {
        pairingCard.visibility = visible ? .visible : .collapsed
        guard visible else { return }
        if let pairing, pairing == shownPairing { return }
        shownPairing = pairing
        countdownTask?.cancel()
        countdown = nil
        copiedNote = nil
        pairingPanel.children.clear()
        guard let pairing else {
            let pair = SettingsGroup.button(L10n.string("Pair…")) { [weak self] in Task { await self?.service.startPairing() } }
            pair.isEnabled = canPair
            let (row, _) = SettingsGroup.row(
                title: L10n.string("Pair a device"),
                description: pairedName.map { L10n.format("%@ is paired.", $0) }
                    ?? L10n.string("A code to scan with your phone, or a link for Yardlet on another computer."),
                control: pair)
            pairingPanel.children.append(row)
            return
        }
        let row = Grid()
        row.columnSpacing = 18
        let codeColumn = ColumnDefinition()
        codeColumn.width = GridLength(value: 0, gridUnitType: .auto)
        let wordsColumn = ColumnDefinition()
        wordsColumn.width = GridLength(value: 1, gridUnitType: .star)
        row.columnDefinitions.append(codeColumn)
        row.columnDefinitions.append(wordsColumn)
        let link = pairing.url?.absoluteString ?? ""
        row.children.append(Self.qrCode(link))
        let words = StackPanel()
        words.spacing = 8
        words.children.append(SettingsGroup.text(L10n.string("Scan this code with Yardlet on your phone."), isTitle: true))
        words.children.append(SettingsGroup.text(L10n.string("On another computer, copy the link and open it in Yardlet there.")))
        let countdown = SettingsGroup.text("")
        words.children.append(countdown)
        self.countdown = countdown
        let buttons = StackPanel()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        if let url = pairing.url {
            buttons.children.append(SettingsGroup.button(L10n.string("Copy link")) { [weak self] in self?.copy(url) })
            let copied = SettingsGroup.text("")
            copied.verticalAlignment = .center
            buttons.children.append(copied)
            copiedNote = copied
        }
        buttons.children.append(SettingsGroup.button(L10n.string("Cancel")) { [weak self] in self?.service.cancelPairing() })
        words.children.append(buttons)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        pairingPanel.children.append(row)
        log.write("remote host pairing shown")
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.countdown?.text = L10n.format("Works once for 5 minutes · %@ left",
                                                    Self.remaining(until: pairing.expiresAt, now: Date()))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The pairing link on the clipboard, for Yardlet on another computer. It is the QR code's secret, so it is
    /// kept out of the clipboard's history and off other devices, as the Mac marks it concealed.
    private func copy(_ url: URL) {
        let package = DataPackage()
        guard (try? package.setText(url.absoluteString)) != nil else { return }
        let options = ClipboardContentOptions()
        options.isAllowedInHistory = false
        options.isRoamable = false
        guard (try? Clipboard.setContentWithOptions(package, options)) == true else { return }
        log.write("remote host link copied")
        copiedNote?.text = L10n.string("Copied")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copiedNote?.text = ""
        }
    }

    static func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The link as a QR code, black on white whatever the theme so a phone's camera reads it: each row's runs
    /// of dark modules as cells of a grid, inside a quiet zone.
    private static func qrCode(_ text: String) -> UIElement {
        let box = Border()
        box.background = SolidColorBrush(UWP.Color(a: 0xFF, r: 0xFF, g: 0xFF, b: 0xFF))
        box.padding = Thickness(left: 10, top: 10, right: 10, bottom: 10)
        box.cornerRadius = CornerRadius(topLeft: 10, topRight: 10, bottomRight: 10, bottomLeft: 10)
        box.verticalAlignment = .top
        try? AutomationProperties.setName(box, L10n.string("Pairing QR code"))
        guard let code = try? QRCode.encode(text: text, ecl: .medium) else { return box }
        let grid = Grid()
        let side = 156.0
        grid.width = side
        grid.height = side
        for _ in 0..<code.size {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            grid.columnDefinitions.append(column)
            let row = RowDefinition()
            row.height = GridLength(value: 1, gridUnitType: .star)
            grid.rowDefinitions.append(row)
        }
        let black = SolidColorBrush(UWP.Color(a: 0xFF, r: 0, g: 0, b: 0))
        for y in 0..<code.size {
            var x = 0
            while x < code.size {
                guard code.getModule(x: x, y: y) else { x += 1; continue }
                let start = x
                while x < code.size, code.getModule(x: x, y: y) { x += 1 }
                let cell = Border()
                cell.background = black
                try? Grid.setRow(cell, Int32(y))
                try? Grid.setColumn(cell, Int32(start))
                try? Grid.setColumnSpan(cell, Int32(x - start))
                grid.children.append(cell)
            }
        }
        box.child = grid
        return box
    }

    // MARK: - Devices

    /// What the device list shows, read under observation.
    private func deviceRows() -> [DeviceRow] {
        service.devices.map { device in
            DeviceRow(device: device, detail: deviceDetail(device),
                      permissions: RemoteDevicePermission.allCases.map { permission in
                          let key = RemotePermissionKey(deviceID: device.id, permission: permission)
                          return service.pendingPermissionValues[key] ?? device.permissions?[permission] ?? false
                      },
                      removing: service.removingDeviceIDs.contains(device.id))
        } + [DeviceRow(errors: [service.removalError, service.permissionError].compactMap { $0 },
                       canRetry: service.canRetryPermissionChange && service.updatingDevicePermissions.isEmpty)]
    }

    private struct DeviceRow {
        var device: RemoteDevice?
        var detail = ""
        var permissions: [Bool] = []
        var removing = false
        var errors: [String] = []
        var canRetry = false

        init(device: RemoteDevice, detail: String, permissions: [Bool], removing: Bool) {
            self.device = device
            self.detail = detail
            self.permissions = permissions
            self.removing = removing
        }

        init(errors: [String], canRetry: Bool) {
            self.errors = errors
            self.canRetry = canRetry
        }
    }

    /// The list drawn again when its devices or what they say change; a permission's switch is set where it is,
    /// so a switch the person just turned keeps its focus.
    private func showDevices(_ rows: [DeviceRow]) {
        let layout = rows.map { row in
            [row.device?.id ?? "", row.device?.name ?? "", row.detail, row.removing ? "removing" : ""]
                .joined(separator: "\n") + "\n" + row.errors.joined(separator: "\n") + (row.canRetry ? "\nretry" : "")
        }
        if layout == shownDevices {
            for row in rows {
                guard let device = row.device else { continue }
                for (permission, isOn) in zip(RemoteDevicePermission.allCases, row.permissions) {
                    let toggle = permissionSwitches[RemotePermissionKey(deviceID: device.id, permission: permission)]
                    if toggle?.isOn != isOn { toggle?.isOn = isOn }
                }
            }
            return
        }
        shownDevices = layout
        permissionSwitches = [:]
        devicesPanel.children.clear()
        devicesPanel.children.append(SettingsGroup.groupTitle(L10n.string("Paired devices")))
        let group = SettingsGroup()
        devicesPanel.children.append(group.view)
        let devices = rows.compactMap(\.device)
        if devices.isEmpty {
            group.append(SettingsGroup.text(L10n.string("No paired devices")))
        }
        for row in rows {
            guard let device = row.device else {
                for error in row.errors {
                    let line = SettingsGroup.text(error)
                    line.foreground = SolidColorBrush(UWP.Color(a: 0xFF, r: 0xC4, g: 0x2B, b: 0x1C))
                    group.append(line)
                }
                if row.canRetry {
                    group.append(SettingsGroup.button(L10n.string("Retry")) { [weak self] in
                        Task { await self?.service.retryPermissionChange() }
                    })
                }
                continue
            }
            let remove = SettingsGroup.button(L10n.string("Remove")) { [weak self] in self?.confirmRemoval(of: device) }
            remove.isEnabled = !row.removing
            try? AutomationProperties.setName(remove, L10n.format("Remove %@", device.name))
            let (header, _) = SettingsGroup.row(title: device.name, description: row.detail, control: remove)
            let content = StackPanel()
            content.spacing = 12
            content.children.append(header)
            for (permission, isOn) in zip(RemoteDevicePermission.allCases, row.permissions) {
                content.children.append(permissionRow(permission, isOn: isOn, device: device, enabled: !row.removing))
            }
            group.append(content)
        }
        log.write("remote host devices: \(devices.map(\.name).joined(separator: ", "))")
    }

    private func permissionRow(_ permission: RemoteDevicePermission, isOn: Bool, device: RemoteDevice,
                               enabled: Bool) -> UIElement {
        let title = Self.permissionTitle(permission)
        let toggle = SettingsGroup.toggle(named: L10n.format("%@ for %@", title, device.name))
        toggle.isOn = isOn
        toggle.isEnabled = enabled
        toggle.toggled.addHandler { [weak self, weak toggle] _, _ in
            guard let self, let toggle else { return }
            let key = RemotePermissionKey(deviceID: device.id, permission: permission)
            let current = self.service.pendingPermissionValues[key]
                ?? self.service.devices.first { $0.id == device.id }?.permissions?[permission] ?? false
            guard toggle.isOn != current else { return }
            Task { await self.service.setPermission(permission, allowed: toggle.isOn, for: device) }
        }
        let (row, _) = SettingsGroup.row(title: title, description: Self.permissionDetail(permission),
                                        control: toggle)
        permissionSwitches[RemotePermissionKey(deviceID: device.id, permission: permission)] = toggle
        return row
    }

    /// The Mac's confirmation: the device disconnects and has to pair again.
    private func confirmRemoval(of device: RemoteDevice) {
        let dialog = ContentDialog()
        dialog.title = L10n.format("Remove %@?", device.name)
        dialog.content = L10n.string("The device disconnects and has to pair again.")
        dialog.primaryButtonText = L10n.string("Remove")
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.xamlRoot = view.xamlRoot
        Task {
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else { return }
            await service.remove(device)
        }
    }

    private static func permissionTitle(_ permission: RemoteDevicePermission) -> String {
        switch permission {
        case .terminal: L10n.string("Terminal")
        case .fileWrites: L10n.string("Write files")
        case .settings: L10n.string("Change settings")
        case .mailCalendar: L10n.string("Mail and Calendar")
        }
    }

    private static func permissionDetail(_ permission: RemoteDevicePermission) -> String {
        switch permission {
        case .terminal: L10n.string("Run shell commands as the host user, and let agents act without asking.")
        case .fileWrites: L10n.string("Save and discard changes in the task's workspace.")
        case .settings: L10n.string("Change Yardlet settings on this computer.")
        case .mailCalendar: L10n.string("Read and send mail, and read the calendar and answer invitations, with this computer's accounts.")
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

    /// The paths, in one line, as the Mac says them.
    private static func reachText(_ reach: RemoteControlService.Reach) -> String {
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
}
