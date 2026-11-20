import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemName: String
    /// A task the palette opens, which shows its project (`subtitle`) beside its title.
    var isTask = false
    /// A setting Settings search found, which shows where it is in Settings (`subtitle`) beside its title.
    var isSetting = false
    /// The menu bar's key for the same command, shown at the row's end as both apps' palettes do.
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
}

extension CommandPaletteItem {
    /// The task's harness settings sheet, for every harness: its controls, and its skills and
    /// plugins with their switches.
    static func harnessSettings(for session: SessionRecord, action: @escaping () -> Void) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "harness-settings-\(session.id)",
            title: L10n.string("Harness settings…"),
            subtitle: L10n.string("The task's harness controls, skills and plugins."),
            systemName: "slider.horizontal.3",
            action: action
        )
    }
}

/// Pure keyboard-selection behavior for the command palette. Keeping the wraparound rule
/// outside the view makes the native keyboard path deterministic and directly testable.
enum CommandPaletteSelection {
    /// What ⌘K lists, as the Codex app's command menu searches chats and commands: with no query the
    /// commands and then the most recent tasks; with one, the tasks whose title or project has it
    /// first (the side panel launcher's counts), then the commands that match, then the settings Settings
    /// search finds for it (`settings`, already ranked), at most `settingLimit`.
    static func shown(commands: [CommandPaletteItem], tasks: [CommandPaletteItem],
                      settings: (String) -> [CommandPaletteItem] = { _ in [] },
                      query: String) -> [CommandPaletteItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return commands + tasks.prefix(SidePanelLauncher.recentCount) }
        let matches = { (item: CommandPaletteItem) in
            item.title.localizedLowercase.contains(normalized) || item.subtitle.localizedLowercase.contains(normalized)
        }
        return Array(tasks.filter(matches).prefix(SidePanelLauncher.matchLimit)) + commands.filter(matches)
            + settings(query).prefix(settingLimit)
    }

    static let settingLimit = 8

    static func movedIndex(currentIndex: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0, offset != 0 else { return count > 0 ? currentIndex ?? 0 : nil }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : count)
        return (startingIndex + offset).modulo(count)
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [CommandPaletteItem]
    /// The tasks the palette finds, most recent first.
    var tasks: [CommandPaletteItem] = []
    /// The settings Settings search finds for the words, best first.
    var settings: (String) -> [CommandPaletteItem] = { _ in [] }
    let onSelect: (CommandPaletteItem) -> Void
    @State private var query = ""
    @State private var selectedIndex: Int?
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        CommandPaletteSelection.shown(commands: items, tasks: tasks, settings: settings, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField(L10n.string("Search tasks and commands"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
                    .accessibilityLabel(L10n.string("Search tasks and commands"))
                    .onMacShortcutSubmit(.paletteChoose) { runSelected() }
                    .onMacKeyPress(.paletteNext) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onMacKeyPress(.palettePrevious) {
                        moveSelection(by: -1)
                        return .handled
                    }
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(MacShortcut.paletteClose.binding)
                    .controlSize(.small)
            }
            .padding(14)

            Rectangle().fill(ParityTheme.separator).frame(height: 1)

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    L10n.string("No matching tasks or commands"),
                    systemImage: "command"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                if item.isTask || item.isSetting,
                                   index == 0 || filteredItems[index - 1].isTask != item.isTask
                                    || filteredItems[index - 1].isSetting != item.isSetting {
                                    Text(L10n.string(item.isTask ? "Tasks" : "Settings"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 2 : 10)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                Button {
                                    selectedIndex = index
                                    onSelect(item)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.systemName)
                                            .frame(width: 22)
                                            .foregroundStyle(.secondary)
                                        Text(item.title)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                            .help(item.title)
                                        Spacer(minLength: 0)
                                        if item.isTask || item.isSetting {
                                            Text(item.subtitle)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        } else if let shortcut = item.shortcut {
                                            Text(shortcut.displayText)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .fixedSize()
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .contentShape(Rectangle())
                                }
                                .id(item.id)
                                .buttonStyle(.borderless)
                                .parityPointer()
                                .background(
                                    index == selectedIndex
                                        ? ParityTheme.selectedFill
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(item.isTask || item.isSetting ? "\(item.title), \(item.subtitle)" : item.title)
                                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard let index, filteredItems.indices.contains(index) else { return }
                        proxy.scrollTo(filteredItems[index].id)
                    }
                    .onChange(of: query) { _, _ in
                        if let first = filteredItems.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
        .background(ParityTheme.canvas)
        .onAppear {
            isSearchFocused = true
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
    }

    private func moveSelection(by offset: Int) {
        selectedIndex = CommandPaletteSelection.movedIndex(
            currentIndex: selectedIndex,
            count: filteredItems.count,
            offset: offset
        )
    }

    private func runSelected() {
        guard !filteredItems.isEmpty else { return }
        let index = min(max(selectedIndex ?? 0, 0), filteredItems.count - 1)
        let item = filteredItems[index]
        onSelect(item)
        dismiss()
    }
}
