import SwiftUI

/// The side panel's launcher, as the Codex app's panel launcher (`RightPanelTabsEmptyState`): what the
/// panel can open for this task, each with its key; under them the pages this task's browser tabs showed, closed
/// tabs first (where the Codex app's New tab lists the chat's recent work, docs/BROWSER_HOST.md, section 3, "Start
/// page"); and the tasks whose conversations the panel can show as tabs, recent first, with a search. A panel with no
/// tab shows it; the + menu's "All Tasks…" shows it over the tabs, and its close returns to the tab it covered.
struct SidePanelLauncher: View {
    let workspaceURL: URL
    let choices: [WorkSurfaceTab]
    /// The task's pages to offer again, each by its address (`TaskSidePanelTabs.visitedPageTabs`); read in the
    /// launcher's body.
    var pages: () -> [WorkSurfaceTab] = { [] }
    /// Every task whose conversation can open here, most recent first; read in the launcher's body.
    let tasks: () -> [WorkSurfaceTab]
    let onOpen: (String) -> Void
    /// A page opens in a new browser tab.
    var onOpenPage: (String) -> Void = { _ in }
    var onRemovePage: (String) -> Void = { _ in }
    let onClose: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// The Codex app's recent list shows six rows before it scrolls.
    static let recentCount = 6
    static let matchLimit = 30
    static let pageCount = 5

    /// The tasks the list shows: the most recent, or those whose title or project has the search.
    static func shown(_ tasks: [WorkSurfaceTab], query: String) -> [WorkSurfaceTab] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return Array(tasks.prefix(recentCount)) }
        return Array(tasks.filter {
            $0.title.localizedLowercase.contains(normalized)
                || ($0.detail?.localizedLowercase.contains(normalized) ?? false)
        }.prefix(matchLimit))
    }

    var body: some View {
        let tasks = tasks()
        let pages = pages()
        return VStack(spacing: 0) {
            WorkSurfaceHeader(title: L10n.string("New tab"), systemName: "plus", workspaceURL: workspaceURL,
                              onClose: onClose) { EmptyView() }
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(spacing: 1) {
                            ForEach(choices) { choice in
                                LauncherRow(tab: choice) { onOpen(choice.id) }
                            }
                        }
                        if !pages.isEmpty {
                            LauncherPageSection(pages: pages, onOpen: onOpenPage, onRemove: onRemovePage)
                        }
                        if !tasks.isEmpty { taskSection(tasks) }
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 28)
                    // Centred while it fits, as the Codex app's launcher is; it scrolls when it does not.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        }
        .background(ParityTheme.canvas)
        .taskFocus(.launcher, isFocused: $isSearchFocused, enabled: !tasks.isEmpty)
    }

    private func taskSection(_ tasks: [WorkSurfaceTab]) -> some View {
        let shown = Self.shown(tasks, query: query)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Tasks"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField(L10n.string("Search tasks"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isSearchFocused)
                    .onSubmit { if let first = shown.first { onOpen(first.id) } }
                    .accessibilityLabel(L10n.string("Search tasks"))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 1) {
                if shown.isEmpty {
                    Text(L10n.string("No matching tasks"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                } else {
                    ForEach(shown) { task in
                        LauncherRow(tab: task) { onOpen(task.id) }
                    }
                }
            }
        }
    }
}

/// "Pages in this task" in the launcher and on a new tab's start page: a page by its title, its site on the right and
/// its address in its help. Its menu takes it out of the list.
struct LauncherPageSection: View {
    let pages: [WorkSurfaceTab]
    let onOpen: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Pages in this task"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            VStack(spacing: 1) {
                ForEach(pages) { page in
                    LauncherRow(tab: page, help: page.id) { onOpen(page.id) }
                        .contextMenu {
                            Button(L10n.string("Remove from list")) { onRemove(page.id) }
                        }
                }
            }
        }
    }
}

/// One launcher choice: its symbol, harness mark or page icon, its title, and on the right its key, project or site.
struct LauncherRow: View {
    let tab: WorkSurfaceTab
    var help: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                WorkSurfaceTabIcon(systemName: tab.systemName, harness: tab.harness, favicon: tab.favicon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let trailing = tab.shortcut ?? tab.detail {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
            .foregroundStyle(tab.isAvailable ? .primary : .tertiary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isHovering && tab.isAvailable ? ParityTheme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!tab.isAvailable)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(help ?? tab.detail.map { "\(tab.title) · \($0)" } ?? tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.detail ?? "")
    }
}
