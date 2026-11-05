import SwiftUI

/// Narrows the archived list the way the sidebar search narrows tasks, by title (a name the person
/// replaced too), project, and harness. Archived tasks keep no local transcript, so there is no
/// conversation text to match.
enum ArchivedTaskFilter {
    static func matches(
        _ archived: [ArchivedSessionRecord],
        query: String,
        projectName: (SessionRecord) -> String
    ) -> [ArchivedSessionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return archived }
        return archived.filter { record in
            ([record.session.title, projectName(record.session), record.session.harness.displayName]
                + record.session.previousTitles)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// The sidebar's archived-tasks view. It takes the task list's place, as the Codex app's archive
/// does, lists archived tasks with the most recently archived first, and restores one with
/// Unarchive. Back returns to the task list.
struct ArchivedTaskList: View {
    /// nil until the index has been read.
    let archived: [ArchivedSessionRecord]?
    let errorMessage: String?
    let restoringIDs: Set<UUID>
    @Binding var searchText: String
    let projectName: (SessionRecord) -> String
    let onBack: () -> Void
    let onUnarchive: (ArchivedSessionRecord) -> Void
    var showsWorkspace = true

    private var shown: [ArchivedSessionRecord] {
        ArchivedTaskFilter.matches(archived ?? [], query: searchText, projectName: projectName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onBack) {
                SidebarActionRow(systemName: "chevron.left", title: L10n.string("Archived tasks"),
                                 symbolWeight: .semibold, titleWeight: .medium, height: 32)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .help(L10n.string("Back to tasks"))
            .accessibilityLabel(L10n.string("Back to tasks"))
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary)

            SidebarSearchField(placeholder: L10n.string("Search archived tasks"), text: $searchText)
                .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 8)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 13)
                            .padding(.bottom, 8)
                    }
                    if archived == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Loading archived tasks…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 13)
                        .accessibilityElement(children: .combine)
                    } else if shown.isEmpty {
                        Text(L10n.string(searchText.isEmpty ? "No archived tasks." : "No matching archived tasks."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                    } else {
                        ForEach(shown) { record in
                            ArchivedTaskRow(
                                record: record,
                                projectName: projectName(record.session),
                                isRestoring: restoringIDs.contains(record.id),
                                onUnarchive: { onUnarchive(record) }, showsWorkspace: showsWorkspace
                            )
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
        }
        .background(ParityTheme.sidebar)
        .onExitCommand(perform: onBack)
        .focusSection()
    }
}

struct ArchivedTaskRow: View {
    let record: ArchivedSessionRecord
    let projectName: String
    let isRestoring: Bool
    let onUnarchive: () -> Void
    let showsWorkspace: Bool
    @State private var isHovering: Bool
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    /// `isHovering` lets a window-less render show the hover action.
    init(
        record: ArchivedSessionRecord,
        projectName: String,
        isRestoring: Bool,
        onUnarchive: @escaping () -> Void,
        isHovering: Bool = false,
        showsWorkspace: Bool = true
    ) {
        self.record = record
        self.projectName = projectName
        self.isRestoring = isRestoring
        self.onUnarchive = onUnarchive
        self.showsWorkspace = showsWorkspace
        _isHovering = State(initialValue: isHovering)
    }

    private var session: SessionRecord { record.session }

    var body: some View {
        HStack(spacing: 8) {
            HarnessIdentityIcon(harness: session.harness, size: SidebarMetrics.nestedIconSize * interfaceScale)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 13 * interfaceScale))
                    .lineLimit(1)
                Text(verbatim: "\(projectName) · \(session.harness.shortDisplayName)")
                    .font(.system(size: 10 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 3)
            if isRestoring {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else if isHovering {
                Button(L10n.string("Unarchive"), action: onUnarchive)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(ParityTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5))
                    .parityPointer()
                    .accessibilityLabel(L10n.format("Unarchive %@", session.title))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 36 * interfaceScale)
        .contentShape(Rectangle())
        .background(isHovering ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .help(([session.title, session.harness.displayName] + (showsWorkspace ? [session.workspaceURL.path(percentEncoded: false)] : []))
            .joined(separator: "\n"))
        .contextMenu {
            Button(L10n.string("Unarchive"), action: onUnarchive)
                .disabled(isRestoring)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.harness.displayName)")
        .accessibilityValue(projectName)
        .accessibilityAction(named: L10n.string("Unarchive"), onUnarchive)
    }
}

/// The line under the window that says what archiving or unarchiving did with a task's worktree
/// when it did not simply tidy it away. It stays until it is closed or the next archive.
struct WorktreeNoticeBar: View {
    let message: String
    var systemImage = "arrow.triangle.branch"
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .help(L10n.string("Close"))
            .accessibilityLabel(L10n.string("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
