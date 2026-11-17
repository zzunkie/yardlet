import Foundation
import Observation
import UWP
import WinUI
import YardletRemote

/// Settings, as Windows 11's Settings draws its pages: a title, then groups under their names, each setting a card
/// with its words at the left and its control at the right. It holds what the Mac's Settings › Remote holds
/// (`RemoteSettingsPane`), when this computer's tasks can be followed from elsewhere, and Connect to a Mac, which the
/// Mac keeps under File: a link pasted from another Mac, and the Macs paired before, each opened in a window of its own.
@MainActor
final class SettingsPane {
    let view = ScrollViewer()
    private let remote: RemoteSettingsPane?
    private let connect: ConnectToMacSection

    init(remote service: RemoteControlService?, directory: RemoteHostDirectory, log: QAEventLog) {
        remote = service.map { RemoteSettingsPane(service: $0) }
        connect = ConnectToMacSection(directory: directory, log: log)
        let page = StackPanel()
        page.padding = Thickness(left: 36, top: 24, right: 36, bottom: 36)
        page.maxWidth = 1000
        let title = TextBlock()
        title.text = L10n.string("Settings")
        title.fontSize = 28
        title.fontWeight = UWP.FontWeight(weight: 600)
        title.foreground = WindowsTheme.text.brush
        title.margin = Thickness(left: 0, top: 0, right: 0, bottom: 8)
        page.children.append(title)
        if let remote {
            page.children.append(SettingsCard.groupTitle(L10n.string("Remote")))
            page.children.append(remote.view)
        }
        page.children.append(SettingsCard.groupTitle(L10n.string("Connect to a Mac")))
        page.children.append(connect.view)
        view.content = page
        view.verticalScrollBarVisibility = .auto
    }

    /// Opens a paired Mac's window.
    var onOpenHost: (String) -> Void {
        get { connect.onOpen }
        set { connect.onOpen = newValue }
    }

    /// Closes a paired Mac's window before it is forgotten.
    var onRemoveHost: (String) -> Void {
        get { connect.onRemove }
        set { connect.onRemove = newValue }
    }

    /// The page as it opens: the devices read again, as the Mac's view reads them.
    func show() {
        remote?.show()
    }
}

/// Windows 11 Settings' rows: a card for each setting, its symbol and words at the left and its control at the right,
/// four pixels from the next, under its group's name.
@MainActor
enum SettingsCard {
    /// The cards' fill and edge, Windows' own card colors.
    static let fill = ThemeColor(light: .paper(0.70), dark: .paper(0.05))
    static let stroke = ThemeColor(light: .ink(0.06), dark: .ink(0.10))
    static let spacing: Double = 4

    static func groupTitle(_ words: String) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.fontSize = 14
        block.fontWeight = UWP.FontWeight(weight: 600)
        block.foreground = WindowsTheme.text.brush
        block.margin = Thickness(left: 0, top: 20, right: 0, bottom: 8)
        return block
    }

    /// A card around `content`.
    static func card(_ content: UIElement) -> Border {
        let card = Border()
        card.background = fill.brush
        card.borderBrush = stroke.brush
        card.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        card.cornerRadius = CornerRadius(topLeft: 4, topRight: 4, bottomRight: 4, bottomLeft: 4)
        card.padding = Thickness(left: 16, top: 12, right: 16, bottom: 12)
        card.minHeight = 64
        card.child = content
        return card
    }

    /// A setting's row: its symbol, its title with what it does under it, and its control.
    static func row(glyph: String?, title: String, description: String? = nil, control: FrameworkElement? = nil)
        -> (row: Grid, description: TextBlock) {
        let row = Grid()
        row.columnSpacing = 16
        SidebarStyle.columns(row, [SidebarStyle.auto, SidebarStyle.star, SidebarStyle.auto])
        if let glyph {
            let icon = SidebarStyle.glyph(glyph, size: 20, color: WindowsTheme.text)
            icon.verticalAlignment = .center
            icon.width = 20
            row.children.append(icon)
        }
        let words = StackPanel()
        words.verticalAlignment = .center
        words.spacing = 2
        let titleBlock = TextBlock()
        titleBlock.text = title
        titleBlock.fontSize = 14
        titleBlock.foreground = WindowsTheme.text.brush
        titleBlock.textWrapping = .wrap
        words.children.append(titleBlock)
        let detail = TextBlock()
        detail.text = description ?? ""
        detail.fontSize = 12
        detail.foreground = WindowsTheme.secondaryText.brush
        detail.textWrapping = .wrap
        detail.visibility = (description ?? "").isEmpty ? .collapsed : .visible
        words.children.append(detail)
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        if let control {
            control.verticalAlignment = .center
            try? Grid.setColumn(control, 2)
            row.children.append(control)
        }
        return (row, detail)
    }

    /// A switch for a card's end, with no words of its own: the card's title names it.
    static func toggle(named name: String) -> ToggleSwitch {
        let toggle = ToggleSwitch()
        toggle.onContent = ""
        toggle.offContent = ""
        toggle.minWidth = 0
        try? AutomationProperties.setName(toggle, name)
        return toggle
    }

    static func button(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.click.addHandler { _, _ in action() }
        return button
    }
}

/// Connect to a Mac in Settings, as the Mac's Connect window: the link another Mac copies, pasted into a field, and
/// Connect, which pairs with that Mac and opens its window; then the Macs paired before (`PairedMacsList`).
@MainActor
final class ConnectToMacSection {
    let view = StackPanel()
    var onOpen: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }

    private let directory: RemoteHostDirectory
    private let log: QAEventLog
    private let linkField = TextBox()
    private let connectButton = Button()
    private let connectStatus = TextBlock()
    private let pairedMacs: PairedMacsList

    init(directory: RemoteHostDirectory, log: QAEventLog) {
        self.directory = directory
        self.log = log
        pairedMacs = PairedMacsList(directory: directory, log: log)
        view.spacing = SettingsCard.spacing

        let content = StackPanel()
        content.spacing = 12
        let (heading, _) = SettingsCard.row(
            glyph: "\u{E71B}", title: L10n.string("Connect to a Mac"),
            description: L10n.string("Follow and drive another Mac's tasks here. On that Mac, open Settings › Remote, choose Pair…, then Copy link, and paste the link below."))
        content.children.append(heading)
        let entry = Grid()
        entry.columnSpacing = 8
        entry.margin = Thickness(left: 36, top: 0, right: 0, bottom: 0)
        SidebarStyle.columns(entry, [SidebarStyle.star, SidebarStyle.auto])
        linkField.placeholderText = "yardlet-remote://pair?…"
        try? AutomationProperties.setName(linkField, L10n.string("Connection link"))
        entry.children.append(linkField)
        connectButton.content = L10n.string("Connect")
        try? AutomationProperties.setName(connectButton, L10n.string("Connect"))
        connectButton.click.addHandler { [weak self] _, _ in self?.connect() }
        try? Grid.setColumn(connectButton, 1)
        entry.children.append(connectButton)
        content.children.append(entry)
        connectStatus.textWrapping = .wrap
        connectStatus.fontSize = 12
        connectStatus.foreground = WindowsTheme.secondaryText.brush
        connectStatus.margin = Thickness(left: 36, top: 0, right: 0, bottom: 0)
        connectStatus.visibility = .collapsed
        content.children.append(connectStatus)
        let note = TextBlock()
        note.text = L10n.string("The link works once, for 5 minutes. Pair once while both Macs are together; from then on this Mac connects on the same network, over Tailscale or through the Yardlet server.")
        note.textWrapping = .wrap
        note.fontSize = 12
        note.foreground = WindowsTheme.secondaryText.brush
        note.margin = Thickness(left: 36, top: 0, right: 0, bottom: 0)
        content.children.append(note)
        view.children.append(SettingsCard.card(content))

        pairedMacs.onOpen = { [weak self] hostID in self?.onOpen(hostID) }
        pairedMacs.onRemove = { [weak self] hostID in self?.onRemove(hostID) }
        view.children.append(pairedMacs.view)
        followHosts()
    }

    private func followHosts() {
        let hosts = withObservationTracking {
            directory.hosts
        } onChange: { [weak self] in
            Task { @MainActor in self?.followHosts() }
        }
        pairedMacs.show(hosts)
    }

    private func showStatus(_ words: String) {
        connectStatus.text = words
        connectStatus.visibility = words.isEmpty ? .collapsed : .visible
    }

    /// Pairs with the host the pasted link names; nothing pairs until Connect is chosen.
    private func connect() {
        let link = linkField.text
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connectButton.isEnabled = false
        showStatus(L10n.string("Connecting…"))
        log.write("remote pairing")
        Task {
            defer { connectButton.isEnabled = true }
            do {
                let host = try await directory.pair(link: link)
                log.write("remote paired: \(host.name)")
                linkField.text = ""
                showStatus("")
                onOpen(host.id)
            } catch let failure as RemoteHostDirectory.PairingFailure {
                log.write("remote pairing failed: \(failure.message)")
                showStatus(failure.message)
            } catch {
                showStatus(error.localizedDescription)
            }
        }
    }
}
