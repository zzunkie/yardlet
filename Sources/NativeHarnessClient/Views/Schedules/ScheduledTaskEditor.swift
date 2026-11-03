import SwiftUI

/// The sheet that makes or changes a schedule: its name and instructions, when it runs, and where
/// each run goes — a new task with the new-task screen's choices (project, local or new worktree,
/// harness, account, model and permission), or the next message of a task.
struct ScheduledTaskEditor: View {
    let existing: ScheduledTask?
    let projects: [Project]
    /// The tasks "Continue this task" can choose, most recent first.
    let tasks: [SessionRecord]
    let runtimeSelections: RuntimeSelectionStore
    let connections: ProviderConnectionStore
    var models: NewTaskModelSource? = nil
    var calendar: Calendar = .autoupdatingCurrent
    var now: () -> Date = Date.init
    let projectName: (SessionRecord) -> String
    let onCancel: () -> Void
    let onSave: (ScheduledTask) -> Void

    @State private var draft: ScheduleDraft

    init(draft: ScheduleDraft, existing: ScheduledTask?, projects: [Project], tasks: [SessionRecord],
         runtimeSelections: RuntimeSelectionStore, connections: ProviderConnectionStore,
         models: NewTaskModelSource? = nil, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         projectName: @escaping (SessionRecord) -> String,
         onCancel: @escaping () -> Void, onSave: @escaping (ScheduledTask) -> Void) {
        _draft = State(initialValue: draft)
        self.existing = existing
        self.projects = projects
        self.tasks = tasks
        self.runtimeSelections = runtimeSelections
        self.connections = connections
        self.models = models
        self.calendar = calendar
        self.now = now
        self.projectName = projectName
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var problem: String? { draft.problem(now: now(), calendar: calendar) }

    private var targetTask: SessionRecord? {
        draft.targetTaskID.flatMap { id in tasks.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string(existing == nil ? "New scheduled task" : "Edit scheduled task"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(L10n.string("Name")) {
                        TextField(L10n.string("Name"), text: $draft.name,
                                  prompt: Text(SessionTitleProjection.provisionalTitle(from: draft.prompt).isEmpty
                                               ? L10n.string("Named after the instructions")
                                               : SessionTitleProjection.provisionalTitle(from: draft.prompt)))
                            .textFieldStyle(.roundedBorder)
                    }
                    field(L10n.string("Instructions")) {
                        TextEditor(text: $draft.prompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 96, maxHeight: 160)
                            .background(ParityTheme.input, in: RoundedRectangle(cornerRadius: 7))
                            .overlay { RoundedRectangle(cornerRadius: 7).stroke(ParityTheme.separator) }
                            .accessibilityLabel(L10n.string("Instructions"))
                    }
                    scheduleSection
                    destinationSection
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 600, height: 680)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - When

    private var scheduleSection: some View {
        field(L10n.string("Schedule")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.string("Schedule"), selection: $draft.kind) {
                    ForEach(ScheduleDraft.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch draft.kind {
                case .daily:
                    timeRow
                case .weekly:
                    dayToggles($draft.days)
                    timeRow
                case .interval:
                    Stepper(value: $draft.intervalHours, in: ScheduleTrigger.intervalHours) {
                        Text(draft.intervalHours == 1 ? L10n.string("Every hour")
                             : L10n.format("Every %lld hours", Int64(draft.intervalHours)))
                    }
                    .fixedSize()
                    dayToggles($draft.intervalDays)
                case .once:
                    DatePicker(L10n.string("At"), selection: $draft.onceAt, in: now()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .fixedSize()
                }
                Group {
                    if let next = draft.nextRun(now: now(), calendar: calendar), problem == nil {
                        Text(L10n.format("Next run %@", ScheduleText.moment(next, relativeTo: now(), calendar: calendar)))
                    } else {
                        Text(L10n.string("Yardlet runs scheduled tasks only while it is open."))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var timeRow: some View {
        DatePicker(L10n.string("Time"), selection: Binding(
            get: {
                calendar.date(bySettingHour: draft.time.hour, minute: draft.time.minute, second: 0,
                              of: calendar.startOfDay(for: now())) ?? now()
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                draft.time = ScheduleTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .datePickerStyle(.compact)
            .fixedSize()
    }

    private func dayToggles(_ days: Binding<Set<ScheduleWeekday>>) -> some View {
        HStack(spacing: 4) {
            ForEach(ScheduleWeekday.ordered(ScheduleWeekday.everyDay, calendar: calendar), id: \.self) { day in
                let isOn = days.wrappedValue.contains(day)
                Button {
                    if isOn { days.wrappedValue.remove(day) } else { days.wrappedValue.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day.rawValue - 1])
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(isOn ? ParityTheme.primaryActionForeground : .primary)
                        .background(isOn ? ParityTheme.primaryActionFill : ParityTheme.subtleFill,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(calendar.weekdaySymbols[day.rawValue - 1])
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
            Button(L10n.string("Weekdays")) { days.wrappedValue = ScheduleWeekday.weekdays }
                .buttonStyle(.borderless)
                .padding(.leading, 6)
                .parityPointer()
            Button(L10n.string("Every day")) { days.wrappedValue = ScheduleWeekday.everyDay }
                .buttonStyle(.borderless)
                .parityPointer()
        }
    }

    // MARK: - Where

    private var destinationSection: some View {
        field(L10n.string("Each run")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.string("Each run"), selection: $draft.mode) {
                    Text(L10n.string("New task each time")).tag(ScheduleDestination.Mode.newTask)
                    Text(L10n.string("Continue a task")).tag(ScheduleDestination.Mode.continueTask)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch draft.mode {
                case .continueTask:
                    continuePicker
                case .newTask:
                    newTaskChoices
                }
            }
        }
    }

    private var continuePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L10n.string("Task"), selection: $draft.targetTaskID) {
                Text(L10n.string("Choose a task")).tag(UUID?.none)
                ForEach(tasks) { task in
                    Text(verbatim: "\(task.title) — \(projectName(task))").tag(UUID?.some(task.id))
                }
            }
            .frame(maxWidth: 460)
            Text(targetTask.map { L10n.format("Each run is sent to “%@” as its next message, with its own harness, account and model.", $0.title) }
                 ?? L10n.string("Each run is sent to the task as its next message."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var harnesses: [HarnessDescriptor] { runtimeSelections.connectedDescriptors }

    private var accountChoices: [AccountChoice] {
        guard let harness = draft.harness else { return [] }
        return connections.choices(for: [harness]).filter(\.canSelect)
    }

    private var selectedConnection: ProviderConnection? {
        guard let harness = draft.harness else { return nil }
        guard let id = draft.accountID else { return connections.selected(for: harness) }
        return connections.connections(for: harness).first { $0.id == id }
    }

    private var workspaceURL: URL? {
        switch draft.place {
        case let .project(id): projects.first { $0.id == id }?.primaryRoot
        case let .folder(path): URL(filePath: path, directoryHint: .isDirectory)
        case .chat: nil
        }
    }

    private var placeTitle: String {
        switch draft.place {
        case let .project(id): projects.first { $0.id == id }?.name ?? L10n.string("Choose project")
        case let .folder(path): URL(filePath: path).lastPathComponent
        case .chat: L10n.string("Chat (no project)")
        }
    }

    private var newTaskChoices: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label(L10n.string("Project"))
                Picker(L10n.string("Project"), selection: $draft.place) {
                    ForEach(projects) { Text($0.name).tag(ScheduleDraft.Place.project($0.id)) }
                    if case let .folder(path) = draft.place {
                        Text(verbatim: ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path)))
                            .tag(ScheduleDraft.Place.folder(path))
                    }
                    Divider()
                    Text(L10n.string("Chat (no project)")).tag(ScheduleDraft.Place.chat)
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)
                .accessibilityValue(placeTitle)
            }
            if workspaceURL != nil {
                GridRow {
                    label(L10n.string("Runs in"))
                    Picker(L10n.string("Runs in"), selection: $draft.startsInNewWorktree) {
                        Text(L10n.string("Local")).tag(false)
                        Text(L10n.string("New worktree")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                label(L10n.string("Harness"))
                Picker(L10n.string("Harness"), selection: Binding(
                    get: { draft.harness },
                    set: { harness in
                        guard harness != draft.harness else { return }
                        draft.harness = harness
                        draft.accountID = harness.flatMap { connections.selection[$0] }
                        draft.modelChoice = nil
                    })) {
                    if draft.harness == nil || !harnesses.contains(where: { $0.id == draft.harness }) {
                        Text(draft.harness?.displayName ?? L10n.string("Choose harness")).tag(draft.harness)
                    }
                    ForEach(harnesses) { Text($0.displayName).tag(HarnessKind?.some($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)
            }
            if let harness = draft.harness, !accountChoices.isEmpty {
                GridRow {
                    label(L10n.string("Account"))
                    Picker(L10n.string("Account"), selection: Binding(
                        get: { draft.accountID ?? connections.selection[harness] ?? AccountChoice.nativeID(for: harness) },
                        set: { draft.accountID = $0 })) {
                        ForEach(accountChoices) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }
            if let harness = draft.harness, let models {
                let options = ComposerSessionOptionsProjection.newTask(
                    harness: harness, choice: draft.modelChoice, catalogs: models.catalogs,
                    connection: selectedConnection, workspaceURL: workspaceURL)
                if options.model != nil || options.permission != nil {
                    GridRow {
                        label(L10n.string("Model"))
                        HStack(spacing: 6) {
                            ComposerSessionControls(options: options, placement: .trailing,
                                                    onChoose: { choose($0, harness: harness, models: models) },
                                                    onPrepare: { await prepare(harness, models: models) })
                            ComposerSessionControls(options: options, placement: .leading,
                                                    onChoose: { choose($0, harness: harness, models: models) },
                                                    onPrepare: { await prepare(harness, models: models) })
                        }
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func choose(_ choice: ComposerSessionChoice, harness: HarnessKind, models: NewTaskModelSource) {
        guard let chosen = NewTaskModelProjection.choosing(choice, harness: harness, choice: draft.modelChoice,
                                                           catalogs: models.catalogs, connection: selectedConnection,
                                                           workspaceURL: workspaceURL) else { return }
        draft.modelChoice = chosen
    }

    private func prepare(_ harness: HarnessKind, models: NewTaskModelSource) async {
        guard let runtime = runtimeSelections.selectedURL(for: harness) else { return }
        await models.load(harness, runtime, selectedConnection, workspaceURL)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(L10n.string(existing == nil ? "Create" : "Save")) {
                onSave(draft.schedule(projects: projects, existing: existing, now: now(), calendar: calendar,
                                      targetHarness: draft.mode == .continueTask ? targetTask?.harness : nil))
            }
            .keyboardShortcut(.defaultAction)
            .parityProminentButton()
            .disabled(problem != nil)
        }
    }
}
