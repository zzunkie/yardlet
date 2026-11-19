import SwiftUI

/// What a view showing a file reads its related tasks with, and opens one with.
struct FileTaskServices {
    /// The task whose panel shows the file, which its list names "This task".
    let currentTaskID: UUID?
    let lookup: @MainActor (URL) async -> FileTasks
    /// Opens the task's conversation where it last edited, or read, the file.
    let open: @MainActor (FileTasks.Item) -> Void
}

/// A place in this task's conversation another view asked to show (`AppModel.revealCall`), and what
/// tells the app it was shown.
struct ConversationPlace {
    let request: ConversationPlaceRequest
    let done: @MainActor () -> Void
}

private struct FileTaskServicesKey: EnvironmentKey {
    static let defaultValue: FileTaskServices? = nil
}

private struct ConversationPlaceKey: EnvironmentKey {
    static let defaultValue: ConversationPlace? = nil
}

extension EnvironmentValues {
    /// Nil where files show without tasks to relate them to (tests, fixtures).
    var fileTaskServices: FileTaskServices? {
        get { self[FileTaskServicesKey.self] }
        set { self[FileTaskServicesKey.self] = newValue }
    }

    var conversationPlace: ConversationPlace? {
        get { self[ConversationPlaceKey.self] }
        set { self[ConversationPlaceKey.self] = newValue }
    }
}

extension View {
    /// Reads `fileURL`'s related tasks into `tasks` when the file or `refresh` changes. A nil file (the
    /// view is still loading it) keeps what is shown; another file's tasks are cleared first.
    func loadsFileTasks(for fileURL: URL?, refresh: String = "", into tasks: Binding<FileTasks>) -> some View {
        modifier(FileTasksLoader(fileURL: fileURL, refresh: refresh, tasks: tasks))
    }
}

private struct FileTasksLoader: ViewModifier {
    let fileURL: URL?
    let refresh: String
    @Binding var tasks: FileTasks
    @State private var shownFile: URL?
    @Environment(\.fileTaskServices) private var services

    func body(content: Content) -> some View {
        content.task(id: "\(fileURL?.path(percentEncoded: false) ?? "")|\(refresh)") {
            guard let fileURL, let services else { return }
            if shownFile != fileURL {
                shownFile = fileURL
                tasks = FileTasks()
            }
            let found = await services.lookup(fileURL)
            guard !Task.isCancelled else { return }
            tasks = found
        }
    }
}

/// A file's related tasks in one line under its name: "Edited in" and the two tasks that edited it
/// last, each with the day, opening its conversation where it last edited the file; the other tasks
/// that edited it and the tasks that only read it in a menu beside them. A file only read shows the
/// menu alone; a file no task touched shows nothing.
///
/// Reads are kept out of the line: nearly every task reads the files that guide the work (AGENTS.md,
/// the project's notes), which would push out the few that changed them.
struct FileTasksLine: View {
    let tasks: FileTasks
    /// Tasks named in the line; the rest are in the menu.
    static let lineLimit = 2
    /// Tasks of each kind the menu lists, the latest first: about the sessions one works with at once.
    static let menuLimit = 10

    @Environment(\.fileTaskServices) private var services

    var body: some View {
        if let services, !tasks.isEmpty {
            HStack(spacing: 6) {
                if !tasks.edited.isEmpty {
                    Text(L10n.string("Edited in")).foregroundStyle(.secondary).fixedSize()
                    ForEach(Array(tasks.edited.prefix(Self.lineLimit).enumerated()), id: \.element.id) { offset, item in
                        if offset > 0 { Text(verbatim: "·").foregroundStyle(.tertiary) }
                        taskButton(item, services: services)
                    }
                }
                let rest = Array(tasks.edited.dropFirst(Self.lineLimit))
                if !rest.isEmpty || !tasks.readOnly.isEmpty {
                    moreMenu(rest: rest, services: services)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    private func taskButton(_ item: FileTasks.Item, services: FileTaskServices) -> some View {
        Button { services.open(item) } label: {
            HStack(spacing: 4) {
                Text(name(item, services: services)).foregroundStyle(ParityTheme.accentText).truncationMode(.tail)
                Text(Self.day(item.at)).foregroundStyle(.secondary).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(help(item))
        .accessibilityLabel("\(name(item, services: services)), \(Self.day(item.at))")
    }

    private func moreMenu(rest: [FileTasks.Item], services: FileTaskServices) -> some View {
        let count = rest.count + tasks.readOnly.count
        return Menu {
            if !rest.isEmpty {
                Section(L10n.string("Edited in")) {
                    ForEach(rest.prefix(Self.menuLimit)) { item in menuItem(item, services: services) }
                }
            }
            if !tasks.readOnly.isEmpty {
                Section(L10n.string("Only read in")) {
                    ForEach(tasks.readOnly.prefix(Self.menuLimit)) { item in menuItem(item, services: services) }
                }
            }
        } label: {
            // The label's own font: a borderless menu draws its label apart from the line around it.
            Text(tasks.edited.isEmpty ? L10n.format("Read in %d tasks", tasks.readOnly.count)
                                      : L10n.format("%d more", count))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.secondary)
        .fixedSize()
        .parityPointer()
        .help(L10n.string("Tasks that edited or read this file"))
    }

    private func menuItem(_ item: FileTasks.Item, services: FileTaskServices) -> some View {
        Button("\(name(item, services: services)) · \(Self.day(item.at))") { services.open(item) }
    }

    private func name(_ item: FileTasks.Item, services: FileTaskServices) -> String {
        item.id == services.currentTaskID ? L10n.string("This task") : item.title
    }

    private func help(_ item: FileTasks.Item) -> String {
        "\(item.title) · \(item.harness.displayName) · \(item.at.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The day as a list of recent work says it: "today", "yesterday", "3 days ago", then the date.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        guard (0..<7).contains(days) else {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day())
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(from: DateComponents(day: -days))
    }
}
