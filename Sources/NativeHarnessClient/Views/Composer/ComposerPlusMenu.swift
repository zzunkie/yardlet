import SwiftUI

/// One row of the composer's "+" menu and the lists it opens, drawn as the Claude app draws its
/// composer menus (2.42304.0 `Fi`): an icon, the name, an optional second line, and at the end a
/// chevron with its hint, a switch, or a button.
struct ComposerMenuEntry: Identifiable {
    enum Icon {
        case symbol(String)
        case connector(name: String, presetID: String?, sources: ConnectorIconSources)
    }

    enum Accessory {
        case none
        /// Opens a list in place; the hint ("2 need reconnection") sits before the chevron.
        case submenu(hint: String?)
        /// The row's switch; clicking the row flips it too, and the menu stays open.
        case toggle(isOn: Bool, label: String)
        /// A button at the row's end that does what clicking the row does ("Reconnect").
        case button(String)
    }

    enum Tone {
        case secondary
        case warning
        case error
    }

    let id: String
    var title: String
    var subtitle: String? = nil
    var subtitleTone: Tone = .secondary
    var icon: Icon? = nil
    var accessory: Accessory = .none
    /// A divider above the row, with the group's heading when it has one.
    var startsGroup = false
    var groupTitle: String? = nil
    /// What clicking the row, Return, or Space does. Nil for a row that only shows a state.
    var action: (() -> Void)? = nil
    var accessibilityValue: String? = nil

    var opensList: Bool {
        if case .submenu = accessory { return true }
        return false
    }

    var keepsMenuOpen: Bool {
        if case .toggle = accessory { return true }
        return false
    }
}

/// A list of menu rows with the keys of a menu: ↑ and ↓ move the highlight, Return and Space
/// choose, → opens a list, ← goes back from one, and Escape closes the menu. The pointer
/// highlights the row under it, as in a menu.
struct ComposerMenuList: View {
    let entries: [ComposerMenuEntry]
    /// The list's title with a way back, for a list opened from the "+" menu.
    var title: String? = nil
    var footnotes: [String] = []
    var width: CGFloat = 248
    /// Opened from the keyboard: the first row starts highlighted.
    var highlightsFirstRow = false
    var onBack: (() -> Void)? = nil
    let onDismiss: () -> Void

    @State private var highlighted: String?
    @FocusState private var isFocused: Bool

    private var choosable: [ComposerMenuEntry] { entries.filter { $0.action != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, let onBack {
                ComposerMenuBackHeader(title: title, onBack: onBack)
                Divider().padding(.horizontal, 6).padding(.vertical, 4)
            }
            ForEach(entries) { entry in
                if entry.startsGroup {
                    Divider().padding(.horizontal, 6).padding(.vertical, 4)
                }
                if let groupTitle = entry.groupTitle {
                    Text(groupTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 3)
                }
                ComposerMenuRow(entry: entry, isHighlighted: highlighted == entry.id)
                    .onHover { hovering in
                        if hovering, entry.action != nil {
                            highlighted = entry.id
                        } else if highlighted == entry.id {
                            highlighted = nil
                        }
                    }
            }
            ForEach(footnotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
        }
        .padding(5)
        .frame(width: width, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) { choose() }
        .onKeyPress(.space) { choose() }
        .onKeyPress(.rightArrow) {
            guard let entry = highlightedEntry, entry.opensList else { return .ignored }
            entry.action?()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let onBack else { return .ignored }
            onBack()
            return .handled
        }
        .onExitCommand(perform: onDismiss)
        .onAppear {
            isFocused = true
            if highlightsFirstRow { highlighted = choosable.first?.id }
        }
    }

    private var highlightedEntry: ComposerMenuEntry? {
        choosable.first { $0.id == highlighted }
    }

    private func move(by step: Int) -> KeyPress.Result {
        let rows = choosable
        guard !rows.isEmpty else { return .ignored }
        guard let current = rows.firstIndex(where: { $0.id == highlighted }) else {
            highlighted = (step > 0 ? rows.first : rows.last)?.id
            return .handled
        }
        highlighted = rows[(current + step + rows.count) % rows.count].id
        return .handled
    }

    private func choose() -> KeyPress.Result {
        guard let entry = highlightedEntry, let action = entry.action else { return .ignored }
        action()
        return .handled
    }
}

/// "‹ Connectors": a list's title, which goes back to the "+" menu.
struct ComposerMenuBackHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityLabel(L10n.string("Back"))
        .accessibilityValue(title)
    }
}

/// One row: the whole row chooses; a switch or button at its end does the same.
struct ComposerMenuRow: View {
    let entry: ComposerMenuEntry
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 8) {
            if let action = entry.action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.title)
                    .accessibilityValue(entry.accessibilityValue ?? entry.subtitle ?? "")
            } else {
                // A row that only shows a state is not a button.
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([entry.title, entry.accessibilityValue ?? entry.subtitle]
                        .compactMap { $0 }.joined(separator: ", "))
            }
            switch entry.accessory {
            case let .toggle(isOn, label):
                Toggle(label, isOn: Binding(get: { isOn }, set: { _ in entry.action?() }))
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.mini)
            case let .button(title):
                Button(title) { entry.action?() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ParityTheme.accent)
            case .none, .submenu:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: entry.subtitle == nil ? 28 : 36, alignment: .leading)
        .background(isHighlighted ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .modifier(MenuRowPointer(isChoosable: entry.action != nil))
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if case let .submenu(hint) = entry.accessory {
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch entry.icon {
        case let .symbol(name)?:
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        case let .connector(name, presetID, sources)?:
            ConnectorIcon(name: name, presetID: presetID, sources: sources, size: 20)
        case nil:
            EmptyView()
        }
    }

    private var subtitleStyle: AnyShapeStyle {
        switch entry.subtitleTone {
        case .secondary: AnyShapeStyle(.secondary)
        case .warning: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        }
    }
}

/// The hand pointer only over a row that does something.
private struct MenuRowPointer: ViewModifier {
    let isChoosable: Bool

    func body(content: Content) -> some View {
        if isChoosable { content.parityPointer() } else { content }
    }
}

/// The composer's "+" menu, in the order of the Claude app's Code composer (2.42304.0 `xj`, `pj`):
/// files or photos and a folder, then slash commands and connectors, which open their lists in
/// place. The chat composer's menu draws the same line between what is added and the tools.
enum ComposerPlusMenu {
    struct Actions {
        var addFiles: () -> Void
        var addFolder: () -> Void
        var openCommands: (() -> Void)?
        var openConnectors: (() -> Void)?
    }

    static func entries(carriesImages: Bool, connectors: ComposerConnectorList?,
                        actions: Actions) -> [ComposerMenuEntry] {
        var entries = [
            ComposerMenuEntry(id: "files",
                              title: carriesImages ? L10n.string("Add files or photos") : L10n.string("Add files"),
                              icon: .symbol("paperclip"), action: actions.addFiles),
            ComposerMenuEntry(id: "folder", title: L10n.string("Add folder"), icon: .symbol("folder"),
                              action: actions.addFolder)
        ]
        if let openCommands = actions.openCommands {
            entries.append(ComposerMenuEntry(id: "commands", title: L10n.string("Slash commands"),
                                             icon: .symbol("slash.circle"), accessory: .submenu(hint: nil),
                                             action: openCommands))
        }
        if let connectors, let openConnectors = actions.openConnectors {
            entries.append(ComposerMenuEntry(id: "connectors", title: L10n.string("Connectors"),
                                             icon: .symbol("powerplug"), accessory: .submenu(hint: connectors.hint),
                                             action: openConnectors, accessibilityValue: connectors.hint))
        }
        if entries.count > 2 { entries[2].startsGroup = true }
        return entries
    }
}

/// The list "+" → "Connectors" opens, as the Claude app's Code composer lists them: "Manage
/// connectors" and "Add connectors" first, then each of Yardlet's connectors with this task's switch, those that need
/// a sign-in with "Reconnect", and under their own heading the servers the harness loaded itself,
/// read-only.
struct ComposerConnectorsMenu: View {
    let list: ComposerConnectorList
    let onManage: (() -> Void)?
    var onAdd: (() -> Void)? = nil
    var onSwitch: ((UUID, Bool) -> Void)? = nil
    var onReconnect: ((UUID) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var highlightsFirstRow = false
    var onDismiss: () -> Void = {}

    var body: some View {
        ComposerMenuList(entries: Self.entries(list: list, onManage: onManage, onAdd: onAdd, onSwitch: onSwitch,
                                               onReconnect: onReconnect),
                         title: onBack == nil ? nil : L10n.string("Connectors"),
                         footnotes: Self.footnotes(list: list, switches: onSwitch != nil),
                         width: 300, highlightsFirstRow: highlightsFirstRow, onBack: onBack, onDismiss: onDismiss)
    }

    static func footnotes(list: ComposerConnectorList, switches: Bool) -> [String] {
        var notes: [String] = []
        if switches, list.rows.contains(where: { $0.state == .offInTask }) {
            notes.append(list.toolListFollowsNextTurn
                ? L10n.string("A connector turned off here stops at once; the task's tool list follows from its next turn.")
                : L10n.string("A connector turned off here stops at once; the task's tool list follows when it next starts or resumes."))
        }
        if list.rows.isEmpty {
            notes.append(L10n.string("No connectors yet."))
        }
        return notes
    }

    static func entries(list: ComposerConnectorList, onManage: (() -> Void)?, onAdd: (() -> Void)? = nil,
                        onSwitch: ((UUID, Bool) -> Void)?, onReconnect: ((UUID) -> Void)?) -> [ComposerMenuEntry] {
        var entries: [ComposerMenuEntry] = []
        if let onManage {
            entries.append(ComposerMenuEntry(id: "manage", title: L10n.string("Manage connectors"),
                                             icon: .symbol("wrench.and.screwdriver"), action: onManage))
        }
        // The Claude app's "Add connectors": the directory, without Settings.
        if let onAdd {
            entries.append(ComposerMenuEntry(id: "add", title: L10n.string("Add connectors"),
                                             icon: .symbol("plus"), action: onAdd))
        }
        // Switches first, then what needs a sign-in, as the Claude app lists them.
        let yardlet = list.rows.filter { $0.source == .yardlet }
        let ordered = yardlet.filter { !$0.canReconnect } + yardlet.filter(\.canReconnect)
        for (index, row) in ordered.enumerated() {
            var entry = Self.entry(for: row, onSwitch: onSwitch, onReconnect: onReconnect)
            entry.startsGroup = index == 0 && !entries.isEmpty
            entries.append(entry)
        }
        let session = list.rows.filter { $0.source == .session }
        for (index, row) in session.enumerated() {
            var entry = Self.entry(for: row, onSwitch: nil, onReconnect: nil)
            if index == 0 {
                entry.startsGroup = !entries.isEmpty
                entry.groupTitle = L10n.string("The harness's own servers")
            }
            entries.append(entry)
        }
        return entries
    }

    private static func entry(for row: ComposerConnectorList.Row, onSwitch: ((UUID, Bool) -> Void)?,
                              onReconnect: ((UUID) -> Void)?) -> ComposerMenuEntry {
        var entry = ComposerMenuEntry(id: row.id, title: row.name, icon: .connector(name: row.name, presetID: row.presetID, sources: row.icons),
                                      accessibilityValue: row.statusText)
        switch row.state {
        case .connected, .offInTask:
            // The switch says it; a harness's own server says it is connected.
            if row.source == .session { entry.subtitle = L10n.string("Connected") }
        case .pending:
            entry.subtitle = L10n.string("Connecting…")
        case .needsAuthentication:
            entry.subtitle = L10n.string("Needs sign-in")
            entry.subtitleTone = .warning
        case .failed:
            entry.subtitle = L10n.string("Error")
            entry.subtitleTone = .error
        case .disabled:
            entry.subtitle = L10n.string("Turned off for this project")
        case .notConnected:
            entry.subtitle = L10n.string("Not connected")
        case .harnessHasIt:
            entry.subtitle = L10n.string("Uses the harness's own server")
        case .yardletStandsIn:
            entry.subtitle = L10n.string("Uses Yardlet's connector")
        }
        if row.canReconnect, let id = row.connectorID, let onReconnect {
            entry.accessory = .button(row.reconnectTitle)
            entry.action = { onReconnect(id) }
        } else if row.isSwitchable, let id = row.connectorID, let onSwitch {
            let isOn = row.isOn
            entry.accessory = .toggle(isOn: isOn, label: L10n.format("Use %@ in this task", row.name))
            entry.action = { onSwitch(id, !isOn) }
        }
        return entry
    }
}
