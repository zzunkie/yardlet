import Foundation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// The Macs this computer paired with, under Connect to a Mac in Settings, as the Mac's Connect window lists them: a card
/// for each, as Windows 11 Settings draws a setting, with when it last connected, Remove… and Open. Removing asks first, then closes the host's window, forgets the host and its
/// key, and asks the host to forget this computer when it can be reached (`RemoteHostDirectory.forget`).
@MainActor
final class PairedMacsList {
    let view = StackPanel()
    /// Opens the host's window.
    var onOpen: ((String) -> Void)?
    /// Closes the host's window before it is forgotten.
    var onRemove: ((String) -> Void)?

    private let directory: RemoteHostDirectory
    private let log: QAEventLog

    init(directory: RemoteHostDirectory, log: QAEventLog) {
        self.directory = directory
        self.log = log
        view.spacing = SettingsCard.spacing
    }

    func show(_ hosts: [RemoteSavedHost]) {
        view.children.clear()
        guard !hosts.isEmpty else { return }
        view.children.append(SettingsCard.groupTitle(L10n.string("Paired Macs")))
        let now = Date()
        for host in hosts {
            let seen = host.lastConnectedAt.map { L10n.format("Last connected %@", RelativeTime.ago($0, relativeTo: now)) }
                ?? L10n.string("Never connected")
            let buttons = StackPanel()
            buttons.orientation = .horizontal
            buttons.spacing = 8
            let remove = SettingsCard.button(L10n.string("Remove…")) { [weak self] in self?.confirmRemoval(of: host) }
            try? AutomationProperties.setName(remove, L10n.format("Remove %@", host.name))
            buttons.children.append(remove)
            let open = SettingsCard.button(L10n.string("Open")) { [weak self] in self?.onOpen?(host.id) }
            try? AutomationProperties.setName(open, L10n.format("Open %@", host.name))
            buttons.children.append(open)
            let (row, _) = SettingsCard.row(glyph: "\u{E7F4}", title: host.name, description: seen, control: buttons)
            view.children.append(SettingsCard.card(row))
        }
    }

    /// The Mac's question, said of this computer rather than of a Mac.
    private func confirmRemoval(of host: RemoteSavedHost) {
        let dialog = ContentDialog()
        dialog.title = L10n.format("Remove %@?", host.name)
        dialog.content = L10n.string("Its window closes and this computer forgets it. When it can be reached now, it forgets this computer too; otherwise remove this computer in its Settings › Remote.")
        dialog.primaryButtonText = L10n.string("Remove")
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.xamlRoot = view.xamlRoot
        Task {
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else { return }
            log.write("remote host removed: \(host.name)")
            onRemove?(host.id)
            await directory.forget(host.id)
        }
    }
}
