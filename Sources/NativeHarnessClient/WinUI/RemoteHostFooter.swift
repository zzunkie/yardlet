import Foundation
import Observation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// The foot of another computer's sidebar, as the Mac's host window ends its sidebar (`RemoteHostFooter`): the
/// computer, its name and how it is reached, which opens Try Again while it is not connected and Remove…, which asks
/// as Connect to a Mac does, then closes the window and forgets the host here. The Mac's host Settings, Connect to Mac
/// and Archived tasks there are the Mac's alone for now.
@MainActor
final class RemoteHostFooter {
    let view = Button()
    /// Closes the host's window before the host is forgotten.
    var onRemove: () -> Void = {}

    private let model: RemoteHostModel
    private let directory: RemoteHostDirectory
    private let log: QAEventLog
    private let name = TextBlock()
    private let line = TextBlock()
    private let menu = MenuFlyout()
    private let tryAgain = MenuFlyoutItem()
    private let tryAgainLine = MenuFlyoutSeparator()

    init(model: RemoteHostModel, directory: RemoteHostDirectory, log: QAEventLog) {
        self.model = model
        self.directory = directory
        self.log = log
        SidebarStyle.stylePlain(view)
        view.margin = Thickness(left: SidebarStyle.rowInset, top: 0, right: SidebarStyle.rowInset, bottom: 0)
        view.padding = Thickness(left: 0, top: 0, right: 10, bottom: 0)
        view.height = 36

        let row = Grid()
        SidebarStyle.columns(row, [SidebarStyle.pixels(SidebarStyle.gutterWidth), SidebarStyle.star])
        let mark = SidebarStyle.glyph("\u{E7F4}", size: 13, color: WindowsTheme.secondaryText)
        mark.horizontalAlignment = .center
        mark.verticalAlignment = .center
        row.children.append(mark)
        let words = StackPanel()
        words.verticalAlignment = .center
        name.text = model.name
        name.fontSize = SidebarStyle.titleFontSize
        name.foreground = WindowsTheme.secondaryText.brush
        name.textTrimming = .characterEllipsis
        name.maxLines = 1
        words.children.append(name)
        line.fontSize = 11
        line.foreground = WindowsTheme.tertiaryText.brush
        line.textTrimming = .characterEllipsis
        line.maxLines = 1
        words.children.append(line)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        view.content = row

        tryAgain.text = L10n.string("Try Again")
        tryAgain.click.addHandler { [weak self] _, _ in self?.model.reconnectNow() }
        menu.items.append(tryAgain)
        menu.items.append(tryAgainLine)
        let remove = MenuFlyoutItem()
        remove.text = L10n.string("Remove…")
        remove.click.addHandler { [weak self] _, _ in self?.confirmRemoval() }
        menu.items.append(remove)
        menu.placement = .topEdgeAlignedLeft
        view.flyout = menu
        follow()
    }

    private func follow() {
        let (connection, isConnected) = withObservationTracking {
            (model.connection, model.isConnected)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        let words = RemoteConnectionText.line(connection)
        line.text = words
        line.visibility = words.isEmpty ? .collapsed : .visible
        tryAgain.visibility = isConnected ? .collapsed : .visible
        tryAgainLine.visibility = tryAgain.visibility
        try? AutomationProperties.setName(view, L10n.format("%@, %@", model.name, words))
    }

    /// The question Connect to a Mac asks before it removes a host.
    private func confirmRemoval() {
        let dialog = ContentDialog()
        dialog.title = L10n.format("Remove %@?", model.name)
        dialog.content = L10n.string("Its window closes and this computer forgets it. When it can be reached now, it forgets this computer too; otherwise remove this computer in its Settings › Remote.")
        dialog.primaryButtonText = L10n.string("Remove")
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.xamlRoot = view.xamlRoot
        let directory = directory, id = model.id, name = model.name, log = log
        Task { [weak self] in
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else { return }
            log.write("remote host removed: \(name)")
            self?.onRemove()
            await directory.forget(id)
        }
    }
}
