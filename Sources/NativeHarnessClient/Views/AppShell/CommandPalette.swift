import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemName: String
    /// A task the palette opens, which shows its project (`subtitle`) beside its title.
    var isTask = false
    let action: () -> Void
}

/// Pure keyboard-selection behavior for the command palette. Keeping the wraparound rule
/// outside the view makes the native keyboard path deterministic and directly testable.
enum CommandPaletteSelection {
    /// What ⌘K lists, as the Codex app's command menu searches chats and commands: with no query the
    /// commands and then the most recent tasks; with one, the tasks whose title or project has it
    /// first (the side panel launcher's counts), then the commands that match.
    static func shown(commands: [CommandPaletteItem], tasks: [CommandPaletteItem],
                      query: String) -> [CommandPaletteItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return commands + tasks.prefix(SidePanelLauncher.recentCount) }
        let matches = { (item: CommandPaletteItem) in
            item.title.localizedLowercase.contains(normalized) || item.subtitle.localizedLowercase.contains(normalized)
        }
        return Array(tasks.filter(matches).prefix(SidePanelLauncher.matchLimit)) + commands.filter(matches)
    }

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
    let onSelect: (CommandPaletteItem) -> Void
    @State private var query = ""
    @State private var selectedIndex: Int?
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        CommandPaletteSelection.shown(commands: items, tasks: tasks, query: query)
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
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
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
                                if item.isTask, index == 0 || !filteredItems[index - 1].isTask {
                                    Text(L10n.string("Tasks"))
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
                                        if item.isTask {
                                            Text(item.subtitle)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
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
                                .accessibilityLabel(item.isTask ? "\(item.title), \(item.subtitle)" : item.title)
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
