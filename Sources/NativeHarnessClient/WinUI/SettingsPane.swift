import Foundation
import Observation
import UWP
import WinUI
import YardletRemote

/// Settings groups related rows in one box, with each setting's words at the left and its control at the right.
/// Settings › Remote controls access to this computer's tasks. Connect to a Mac accepts a pairing link and lists
/// previously paired Macs, each of which opens in its own window.
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
            page.children.append(SettingsGroup.groupTitle(L10n.string("Remote")))
            page.children.append(remote.view)
        }
        page.children.append(SettingsGroup.groupTitle(L10n.string("Connect to a Mac")))
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

/// A box around related settings, with an inset divider between rows. Hiding a row hides its divider too.
@MainActor
final class SettingsGroup {
    let view = Border()
    private let rows = StackPanel()

    init(_ contents: [UIElement] = []) {
        view.background = WindowsTheme.elevated.brush
        view.borderBrush = WindowsTheme.separator.brush
        view.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        view.cornerRadius = ConversationStyle.corners(WindowsTheme.panelCornerRadius)
        view.padding = Thickness(left: 16, top: 0, right: 16, bottom: 0)
        view.child = rows
        for content in contents { append(content) }
    }

    @discardableResult
    func append(_ content: UIElement) -> Border {
        let row = Border()
        row.padding = Thickness(left: 0, top: 12, right: 0, bottom: 12)
        if rows.children.size > 0 {
            row.borderBrush = WindowsTheme.separator.brush
            row.borderThickness = Thickness(left: 0, top: 1, right: 0, bottom: 0)
        }
        row.child = content
        rows.children.append(row)
        return row
    }

    static func groupTitle(_ words: String) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.fontSize = 13
        block.fontWeight = UWP.FontWeight(weight: 600)
        block.foreground = WindowsTheme.text.brush
        block.margin = Thickness(left: 0, top: 20, right: 0, bottom: 8)
        return block
    }

    /// A setting's title and description at the left and its control at the right.
    static func row(title: String, description: String? = nil, control: FrameworkElement? = nil)
        -> (row: Grid, description: TextBlock) {
        let row = Grid()
        row.columnSpacing = 12
        SidebarStyle.columns(row, [SidebarStyle.star, SidebarStyle.auto])
        let words = StackPanel()
        words.verticalAlignment = .center
        words.spacing = 2
        words.children.append(text(title, isTitle: true))
        let detail = text(description ?? "")
        detail.visibility = (description ?? "").isEmpty ? .collapsed : .visible
        words.children.append(detail)
        row.children.append(words)
        if let control {
            control.verticalAlignment = .center
            try? Grid.setColumn(control, 1)
            row.children.append(control)
        }
        return (row, detail)
    }

    static func text(_ value: String, isTitle: Bool = false) -> TextBlock {
        let block = TextBlock()
        block.text = value
        block.fontSize = isTitle ? 13 : 12
        block.foreground = isTitle ? WindowsTheme.text.brush : WindowsTheme.secondaryText.brush
        if isTitle { block.fontWeight = UWP.FontWeight(weight: 500) }
        block.textWrapping = .wrap
        return block
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
    private let connectStatus = SettingsGroup.text("")
    private let pairedMacs: PairedMacsList

    init(directory: RemoteHostDirectory, log: QAEventLog) {
        self.directory = directory
        self.log = log
        pairedMacs = PairedMacsList(directory: directory, log: log)

        let content = StackPanel()
        content.spacing = 12
        content.children.append(SettingsGroup.text(L10n.string("Follow and drive another Mac's tasks here. On that Mac, open Settings › Remote, choose Pair…, then Copy link, and paste the link below.")))
        let entry = Grid()
        entry.columnSpacing = 8
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
        connectStatus.visibility = .collapsed
        content.children.append(connectStatus)
        content.children.append(SettingsGroup.text(L10n.string("The link works once, for 5 minutes. Pair once while both computers are together; from then on this computer connects on the same network, over Tailscale or through the Yardlet server.")))
        view.children.append(SettingsGroup([content]).view)

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
