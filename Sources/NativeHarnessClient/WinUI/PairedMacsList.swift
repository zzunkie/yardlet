import Foundation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// The Macs this computer paired with, under Connect to a Mac, as the Mac's Connect window lists them: each with when
/// it last connected, Open and Remove…. Removing asks first, then closes the host's window, forgets the host and its
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
        view.spacing = 8
        view.margin = Thickness(left: 0, top: 12, right: 0, bottom: 0)
    }

    func show(_ hosts: [RemoteSavedHost]) {
        view.children.clear()
        guard !hosts.isEmpty else { return }
        let title = TextBlock()
        title.text = L10n.string("Paired Macs")
        title.fontWeight = UWP.FontWeight(weight: 600)
        view.children.append(title)
        let now = Date()
        for host in hosts {
            let row = Grid()
            let wordsColumn = ColumnDefinition()
            wordsColumn.width = GridLength(value: 1, gridUnitType: .star)
            row.columnDefinitions.append(wordsColumn)
            for _ in 0..<2 {
                let buttonColumn = ColumnDefinition()
                buttonColumn.width = GridLength(value: 0, gridUnitType: .auto)
                row.columnDefinitions.append(buttonColumn)
            }
            row.columnSpacing = 8
            let words = StackPanel()
            words.children.append(Self.text(host.name))
            let seen = host.lastConnectedAt.map { L10n.format("Last connected %@", RelativeTime.ago($0, relativeTo: now)) }
                ?? L10n.string("Never connected")
            let detail = Self.text(seen)
            detail.fontSize = 12
            detail.opacity = 0.6
            words.children.append(detail)
            row.children.append(words)
            let remove = Self.button(L10n.string("Remove…")) { [weak self] in self?.confirmRemoval(of: host) }
            try? AutomationProperties.setName(remove, L10n.format("Remove %@", host.name))
            try? Grid.setColumn(remove, 1)
            row.children.append(remove)
            let open = Self.button(L10n.string("Open")) { [weak self] in self?.onOpen?(host.id) }
            try? AutomationProperties.setName(open, L10n.format("Open %@", host.name))
            try? Grid.setColumn(open, 2)
            row.children.append(open)
            view.children.append(row)
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

    private static func text(_ words: String) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.textWrapping = .wrap
        block.verticalAlignment = .center
        return block
    }

    private static func button(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.verticalAlignment = .center
        button.click.addHandler { _, _ in action() }
        return button
    }
}
