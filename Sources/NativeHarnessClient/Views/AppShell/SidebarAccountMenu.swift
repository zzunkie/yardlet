import AppKit
import SwiftUI

/// Shortcuts the app menu and the sidebar's account menu share, so both show the same keys.
enum YardletAppShortcut {
    /// Yardlet › Settings…
    static let settings = KeyboardShortcut(",", modifiers: .command)
}

/// Who the sidebar's account button names: the person signed in to this Mac. Yardlet has no
/// account of its own and holds several provider accounts at once, each task on its own, so the
/// button names the one person all of them belong to rather than one provider's account (the
/// common sidebar). It is read from macOS, never from a provider.
struct SidebarAccountIdentity: Equatable, Sendable {
    /// The full name, else the short user name, else "Settings" as the Codex app's footer says
    /// when it has no profile (`codex.profileFooter.settingsFallback`).
    let name: String
    /// The name's first letter, for the round mark before it; empty without a name.
    let initial: String

    init(fullName: String?, userName: String?) {
        let candidates = [fullName, userName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name = candidates.first(where: { !$0.isEmpty }) {
            self.name = name
            initial = name.first.map { String($0).uppercased() } ?? ""
        } else {
            name = L10n.string("Settings")
            initial = ""
        }
    }

    /// The person signed in to this Mac. A visual fixture (`--ui-fixture…`) or a test run names a
    /// made-up person instead, so their windows, renders and screenshots never show whose Mac drew
    /// them.
    static func current() -> SidebarAccountIdentity {
#if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-fixture") }) || NSClassFromString("XCTestCase") != nil {
            return fixture
        }
#endif
        return SidebarAccountIdentity(fullName: NSFullUserName(), userName: NSUserName())
    }

#if DEBUG
    /// The person fixtures and renders show.
    static let fixture = SidebarAccountIdentity(fullName: "Jordan Park", userName: "jordan")
#endif
}

/// What the sidebar's account button opens, after the Claude app's user menu (`UserMenuItems`:
/// the person, Settings ⌘, then Usage) and the Codex app's profile menu (`codex.profileDropdown`:
/// Settings with its shortcut, then Usage with what is left). Yardlet's own app-wide places follow:
/// the Settings sections reached from elsewhere, archived tasks, task resource usage, importing
/// conversations, and installing a staged update. Each opens what its app menu or command palette
/// item opens, with the same shortcut.
struct SidebarAccountMenu: Equatable {
    enum Destination: Hashable, Sendable {
        case settings
        /// A Settings section: Accounts, Connectors, Remote, Harnesses.
        case settingsSection(SettingsSection)
        /// Settings › Accounts, showing a harness's accounts (a Usage line).
        case accountUsage(HarnessKind)
        /// Settings › Accounts, where each account's usage is, while no account has a reading to
        /// list here.
        case usage
        case archivedTasks
        case taskResourceUsage
        case importConversation
        case importFromOtherApps
        /// A pass over the Claude app's and Codex's lists now (`AppModel.followSessionListsNow`).
        case refreshFromOtherApps
        case installUpdate
        /// Sparkle's Check for Updates…, in a build that updates with it.
        case checkForUpdates
        /// "Waiting to Update", a dimmed line while an update waits for tasks to finish.
        case updateWaiting
        /// Cancel Update: stop waiting for tasks to finish.
        case cancelUpdateWait
    }

    struct Item: Equatable, Identifiable {
        let destination: Destination
        let title: String
        /// The SF Symbol before the title; nil for a Usage line, which shows its harness's mark.
        var systemName: String?
        var harness: HarnessKind?
        var help: String?
        /// The smaller line under the title (a Usage line's harnesses and limits).
        var subtitle: String?
        var shortcut: KeyboardShortcut?
        /// False for a line that only says what is happening.
        var isEnabled = true

        var id: String { "\(destination)|\(title)" }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.destination == rhs.destination && lhs.title == rhs.title && lhs.systemName == rhs.systemName
                && lhs.harness == rhs.harness && lhs.help == rhs.help && lhs.subtitle == rhs.subtitle
                && lhs.isEnabled == rhs.isEnabled
                && lhs.shortcut?.key == rhs.shortcut?.key && lhs.shortcut?.modifiers == rhs.shortcut?.modifiers
        }
    }

    struct Section: Equatable, Identifiable {
        /// A heading over the section's items (Usage); nil for a plain group.
        var title: String?
        let items: [Item]

        var id: String { title ?? items.first?.id ?? "" }
    }

    let identity: SidebarAccountIdentity
    let sections: [Section]

    /// Every item, in the order the menu lists them.
    var items: [Item] { sections.flatMap(\.items) }

    /// The menu for a window offering `settingsSections` (`SettingsSection.available`), with one
    /// Usage line per account Yardlet has a reading for (`MenuBarMenuProjection.usage`, the menu bar
    /// item's lines; nothing is checked to make them), else one Usage item, as the Codex menu always
    /// has one. The update lines are the app menu's (`YardletUpdateMenu`): Install Update…, or
    /// Check for Updates… in a build that updates with Sparkle, and while an update waits for tasks to
    /// finish, the wait's lines.
    static func make(
        identity: SidebarAccountIdentity,
        settingsSections: [SettingsSection],
        usage: [MenuBarMenu.UsageAccount] = [],
        usageToday: String? = nil,
        updateIsWaiting: Bool = false,
        checksForUpdates: Bool = false,
        refreshing: Bool = false
    ) -> SidebarAccountMenu {
        var settings = [Item(destination: .settings, title: L10n.string("Settings…"), systemName: "gearshape",
                             shortcut: YardletAppShortcut.settings)]
        // The sections reached from elsewhere, in Settings' own order; the ones a window offers.
        for section in [SettingsSection.accounts, .connectors, .remote, .harnesses]
        where settingsSections.contains(section) {
            settings.append(Item(destination: .settingsSection(section), title: section.title,
                                 systemName: section.systemName))
        }
        var sections = [Section(items: settings)]
        if settingsSections.contains(.accounts) {
            // Today's count opens Settings › Usage, while it counts.
            let today = usageToday.flatMap { line in settingsSections.contains(.usage)
                ? [Item(destination: .settingsSection(.usage), title: line, systemName: "chart.bar.xaxis")] : nil } ?? []
            if usage.isEmpty {
                sections.append(Section(items: [
                    Item(destination: .usage, title: L10n.string("Usage"),
                         systemName: "gauge.with.dots.needle.67percent"),
                ] + today))
            } else {
                sections.append(Section(title: L10n.string("Usage"), items: today + usage.map {
                    Item(destination: .accountUsage($0.harness), title: $0.line, harness: $0.harness, help: $0.help,
                         subtitle: $0.detail.isEmpty ? nil : $0.detail)
                }))
            }
        }
        sections.append(Section(items: [
            Item(destination: .archivedTasks, title: L10n.string("Archived tasks"), systemName: "archivebox"),
            Item(destination: .taskResourceUsage, title: L10n.string("Task Resource Usage"), systemName: "cpu"),
        ]))
        sections.append(Section(items: [
            Item(destination: .importConversation, title: L10n.string("Import conversation…"),
                 systemName: "square.and.arrow.down"),
            Item(destination: .importFromOtherApps, title: L10n.string("Import Conversations from Other Apps…"),
                 systemName: "square.and.arrow.down.on.square"),
            Item(destination: .refreshFromOtherApps,
                 title: refreshing ? L10n.string("Refreshing from the Claude App and Codex…")
                     : L10n.string("Refresh from the Claude App and Codex"),
                 systemName: "arrow.clockwise",
                 help: L10n.string("Brings in conversations started there and follows what was archived there"),
                 isEnabled: !refreshing),
        ]))
        sections.append(Section(items: YardletUpdateMenu.items(isWaiting: updateIsWaiting,
                                                               checksForUpdates: checksForUpdates).map { line in
            switch line {
            case .install:
                Item(destination: .installUpdate, title: line.title, systemName: "arrow.down.circle")
            case .checkForUpdates:
                Item(destination: .checkForUpdates, title: line.title, systemName: "arrow.down.circle")
            case .waiting:
                Item(destination: .updateWaiting, title: line.title, systemName: "clock", help: line.help,
                     isEnabled: false)
            case .cancelWaiting:
                Item(destination: .cancelUpdateWait, title: line.title, systemName: "xmark.circle")
            }
        }))
        return SidebarAccountMenu(identity: identity, sections: sections)
    }
}

/// What the sidebar needs to show its account button and act on its menu. The window passes the
/// person on this Mac (`SidebarAccountIdentity.current()`); left out, as in a test's sidebar, the
/// button says "Settings" and names nobody.
struct SidebarAccountMenuContext {
    var identity = SidebarAccountIdentity(fullName: nil, userName: nil)
    /// The Settings sections the window offers (`SettingsSection.available`).
    var settingsSections: [SettingsSection] = SettingsSection.available(hasAccounts: true, hasConnectors: false)
    /// The Usage lines, read when the menu opens.
    var usage: () -> [MenuBarMenu.UsageAccount] = { [] }
    /// Today's token count, first under Usage while Settings › Usage counts it.
    var usageToday: () -> String? = { nil }
    /// Checks the accounts the Usage lines show (`AppModel.checkUsageAccounts`), started as the
    /// menu opens; the open menu takes the answers.
    var checkUsage: @MainActor () async -> Void = {}
    /// Whether an update waits for tasks to finish, read when the menu opens.
    var updateIsWaiting: () -> Bool = { false }
    /// Whether this build updates with Sparkle (Check for Updates… instead of Install Update…).
    var checksForUpdates = false
    /// Whether a refresh from the Claude app and Codex is running, read when the menu opens.
    var refreshing: () -> Bool = { false }
    /// A staged build ready to install, for the strip over the button (`SidebarUpdateStrip`), read as
    /// the sidebar draws, so the sidebar follows it.
    var update: () -> MenuBarMenu.UpdateLine? = { nil }
    var onSelect: (SidebarAccountMenu.Destination) -> Void = { _ in }

    /// The menu as it is now.
    func menu() -> SidebarAccountMenu {
        SidebarAccountMenu.make(identity: identity, settingsSections: settingsSections, usage: usage(),
                                usageToday: usageToday(), updateIsWaiting: updateIsWaiting(), checksForUpdates: checksForUpdates,
                                refreshing: refreshing())
    }
}

/// The account menu as an AppKit menu: the person's name as its heading, the items with their
/// symbols and shortcuts, a Usage heading over the account lines with each harness's mark.
/// Choosing an item calls back once the menu has closed.
@MainActor
final class SidebarAccountMenuController: NSObject {
    let menu: NSMenu
    private var content: SidebarAccountMenu
    private let onSelect: (SidebarAccountMenu.Destination) -> Void

    init(content: SidebarAccountMenu, onSelect: @escaping (SidebarAccountMenu.Destination) -> Void) {
        self.content = content
        self.onSelect = onSelect
        menu = NSMenu(title: content.identity.name)
        super.init()
        menu.autoenablesItems = false
        menu.items = items()
    }

    /// Shows newer contents in the menu, open or not (`NSMenu.update(to:)`).
    func update(to content: SidebarAccountMenu) {
        self.content = content
        menu.update(to: items())
    }

    private func items() -> [NSMenuItem] {
        var items = [NSMenuItem.sectionHeader(title: content.identity.name)]
        for section in content.sections {
            items.append(.separator())
            if let title = section.title { items.append(.sectionHeader(title: title)) }
            items += section.items.map(menuItem)
        }
        return items
    }

    private func menuItem(_ item: SidebarAccountMenu.Item) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = SidebarAccountMenuChoice(item.destination)
        if let shortcut = item.shortcut {
            menuItem.keyEquivalent = String(shortcut.key.character)
            menuItem.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
        }
        if let harness = item.harness {
            menuItem.image = MenuBarItemMarks.harness(harness)
        } else if let systemName = item.systemName {
            menuItem.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        }
        if let subtitle = item.subtitle { menuItem.subtitle = subtitle }
        menuItem.toolTip = item.help
        menuItem.isEnabled = item.isEnabled
        return menuItem
    }

    static func modifierMask(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SidebarAccountMenuChoice else { return }
        // After the menu's tracking ends, so a sheet or window it opens comes up in front.
        let onSelect = onSelect
        DispatchQueue.main.async { onSelect(choice.destination) }
    }

    /// Opens the menu above `view`, its left edge on the view's, as the Claude and Codex menus
    /// open up from the bottom of the sidebar. Returns once the menu closes.
    func popUp(above view: NSView) {
        let gap: CGFloat = 6
        let height = menu.size.height
        let top = view.isFlipped ? -gap - height : view.bounds.maxY + gap + height
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: top), in: view)
    }
}

/// An item's destination, carried by its `NSMenuItem`.
final class SidebarAccountMenuChoice: NSObject {
    let destination: SidebarAccountMenu.Destination
    init(_ destination: SidebarAccountMenu.Destination) { self.destination = destination }
}

/// The view the menu opens from, so it opens above the button wherever the sidebar is.
@MainActor
final class SidebarAccountMenuAnchor {
    weak var view: NSView?
}

private struct SidebarAccountMenuAnchorView: NSViewRepresentable {
    let anchor: SidebarAccountMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// The sidebar's bottom row: one button with the person's initial and name, as the Claude and Codex
/// apps put their profile at the sidebar's bottom left, opening `SidebarAccountMenu` above it.
struct SidebarAccountButton: View {
    let context: SidebarAccountMenuContext
    @State private var isHovering = false
    @State private var anchor = SidebarAccountMenuAnchor()

    /// The row's height; the Claude app's footer button is at least 28 pt (`--df-footer-btn-size`),
    /// the old footer rows here 32.
    static let height: CGFloat = 32
    /// The round mark with the name's initial (the Claude app's 20 pt mark in its 24 pt slot).
    static let markSize: CGFloat = 20

    var body: some View {
        Button(action: open) {
            SidebarAccountButtonLabel(identity: context.identity, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .background(SidebarAccountMenuAnchorView(anchor: anchor))
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(context.identity.name)
        .accessibilityLabel(L10n.format("Account menu, %@", context.identity.name))
    }

    private func open() {
        guard let view = anchor.view else { return }
        let controller = SidebarAccountMenuController(content: context.menu(), onSelect: context.onSelect)
        // Runs while the menu tracks (the main queue is served in its run loop mode); once the menu
        // has closed the controller is gone and nothing is shown.
        Task { [weak controller, context] in
            await context.checkUsage()
            controller?.update(to: context.menu())
        }
        controller.popUp(above: view)
    }
}

/// The button's face: the initial in a round mark, the name, and a caret, as the Claude app's
/// `df-user-menu-btn` (secondary name, muted caret).
struct SidebarAccountButtonLabel: View {
    let identity: SidebarAccountIdentity
    var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            SidebarAccountMark(initial: identity.initial)
                .frame(width: SidebarMetrics.gutterWidth)
            Text(identity.name)
                .font(.system(size: 13 * interfaceScale))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9 * interfaceScale, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 10)
        .frame(height: SidebarAccountButton.height * interfaceScale)
        .contentShape(Rectangle())
        .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
    }
}

/// The initial in a round, quiet mark; a person glyph without one.
struct SidebarAccountMark: View {
    let initial: String
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let size = SidebarAccountButton.markSize * interfaceScale
        ZStack {
            Circle().fill(Color.primary.opacity(0.1))
            if initial.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: 10 * interfaceScale, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(initial)
                    .font(.system(size: 10.5 * interfaceScale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Restart to update" over the account button while a staged build is ready to install, as the
/// Claude app puts "Relaunch to update" over its account button once an update has downloaded
/// (`df-update-strip`: a filled pill as high as the footer button, the title in primary text at medium
/// weight, an arrow at the end that darkens on hover, "Relaunch to update · v1.2.3" as its tooltip).
/// It opens what Install Update… opens. While the update waits for tasks it reads "Waiting to Update"
/// and does nothing, as the app menu's line does.
struct SidebarUpdateStrip: View {
    let line: MenuBarMenu.UpdateLine
    let onRestart: () -> Void
    @State private var isHovering = false

    var body: some View {
        if line == .waiting {
            SidebarUpdateStripLabel(line: line)
                .help(line.help)
                .accessibilityElement(children: .combine)
        } else {
            Button(action: onRestart) {
                SidebarUpdateStripLabel(line: line, isHovering: isHovering)
            }
            .buttonStyle(.plain)
            .parityPointer()
            .onHover { isHovering = $0 }
            .help(line.help)
        }
    }
}

/// The strip's face: the title on the sidebar's hover fill, the selected fill under the pointer.
struct SidebarUpdateStripLabel: View {
    let line: MenuBarMenu.UpdateLine
    var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let isWaiting = line == .waiting
        HStack(spacing: 6) {
            if isWaiting {
                Image(systemName: "clock")
                    .font(.system(size: 11 * interfaceScale, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text(line.title)
                .font(.system(size: 13 * interfaceScale, weight: isWaiting ? .regular : .medium))
                .foregroundStyle(isWaiting ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !isWaiting {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10 * interfaceScale, weight: .semibold))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarAccountButton.height * interfaceScale)
        .contentShape(Rectangle())
        .background(isHovering ? ParityTheme.selectedFill : ParityTheme.hoverFill, in: SidebarMetrics.rowShape())
    }
}
