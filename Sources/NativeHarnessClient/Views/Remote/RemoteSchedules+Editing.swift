import SwiftUI
import YardletRemote

/// Capable hosts use the same list and detail as this Mac. Older hosts keep their read-only presentation.
struct RemoteScheduleList: View {
    let model: RemoteHostModel
    var now: Date = Date()
    var body: some View {
        if model.schedules.canEdit {
            @Bindable var state = model.schedules.window
            ScheduledTaskList(
                schedules: model.schedules.definitions, sessionJobs: model.schedules.sessionJobs,
                selection: selection, startingIDs: Set(model.schedules.starting.compactMap(UUID.init(uuidString:))),
                now: now, nextRun: model.schedules.nextRun,
                taskTitle: { [context = model.schedules.context] in context.task($0)?.title },
                expandedSections: $state.expandedSections,
                onBack: { model.showsSchedules = false; model.select(.none) }, actions: model.schedules.actions, calendar: model.schedules.calendar)
        } else { LegacyRemoteScheduleList(model: model) }
    }
    private var selection: UUID? {
        if case let .schedule(id) = model.selection { return UUID(uuidString: id) }
        return nil
    }
}

struct RemoteScheduleDetail: View {
    let model: RemoteHostModel
    let schedule: RemoteSchedule
    var now: Date = Date()
    var body: some View {
        if let definition = schedule.localDefinition {
            ScheduledTaskDetail(schedule: definition, nextRun: model.schedules.nextRun(definition),
                                isStarting: model.schedules.starting.contains(schedule.id), now: now,
                                context: model.schedules.context, actions: model.schedules.actions, calendar: model.schedules.calendar)
        } else { LegacyRemoteScheduleDetail(model: model, schedule: schedule) }
    }
}

struct RemoteScheduleSheets: ViewModifier {
    let model: RemoteHostModel
    func body(content: Content) -> some View {
        @Bindable var state = model.schedules.window
        content
            .sheet(item: $state.editor) { request in RemoteScheduleEditor(model: model, request: request) }
            .alert(L10n.string("Delete scheduled task?"), isPresented: Binding(
                get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
                Button(L10n.string("Delete"), role: .destructive) {
                    if let id = state.pendingDelete { model.schedules.delete([id], completedOnly: false) }
                    state.pendingDelete = nil
                }
                Button(L10n.string("Cancel"), role: .cancel) { state.pendingDelete = nil }
            } message: {
                Text(L10n.format("“%@” will not run again. The tasks its runs started stay in the sidebar.",
                                 state.pendingDelete.flatMap { model.schedules.schedule($0.uuidString)?.name } ?? ""))
            }
            .alert(L10n.format("Delete %lld completed scheduled tasks?", Int64(state.pendingDeleteCompleted?.count ?? 0)),
                   isPresented: Binding(get: { state.pendingDeleteCompleted != nil },
                                        set: { if !$0 { state.pendingDeleteCompleted = nil } })) {
                Button(L10n.string("Delete"), role: .destructive) {
                    if let ids = state.pendingDeleteCompleted { model.schedules.delete(ids, completedOnly: true) }
                    state.pendingDeleteCompleted = nil
                }
                Button(L10n.string("Cancel"), role: .cancel) { state.pendingDeleteCompleted = nil }
            } message: {
                Text(L10n.string("They ran once and will not run again. The tasks their runs started stay in the sidebar."))
            }
    }
}

private struct RemoteScheduleOptionsKey: Equatable {
    let place: ScheduleDraft.Place
    let harness: HarnessKind?
    let accountID: String?
    let settings: [String: String]
    let connected: Bool

    init(_ draft: ScheduleDraft, settings: [String: String], connected: Bool) {
        place = draft.place
        harness = draft.harness
        accountID = draft.accountID
        self.settings = settings
        self.connected = connected
    }
}

/// The editor shares the schedule fields; its destination controls read only host choices.
struct RemoteScheduleEditor: View {
    let model: RemoteHostModel
    let request: ScheduledTasksWindowState.EditorRequest
    var loadsOptions = true
    @State private var options: RemoteResponse?
    @State private var settings: [String: String] = [:]
    @State private var pending: ScheduledTask?
    @State private var confirmation: RemoteSetting.Confirmation?
    @State private var saving = false
    @State private var validatedOptions: RemoteScheduleOptionsKey?
    @State private var consentedOptions: RemoteScheduleOptionsKey?
    @State private var editorError: String?

    init(model: RemoteHostModel, request: ScheduledTasksWindowState.EditorRequest, initialOptions: RemoteResponse? = nil, loadsOptions: Bool = true) {
        self.model = model
        self.request = request
        self.loadsOptions = loadsOptions
        _options = State(initialValue: initialOptions)
        _validatedOptions = State(initialValue: initialOptions == nil ? nil :
            RemoteScheduleOptionsKey(request.draft, settings: [:], connected: model.isConnected))
    }

    var body: some View {
        ScheduledTaskEditor(
            draft: request.draft, existing: request.existing, projects: model.sidebar.projects,
            tasks: model.sidebar.sessions.sorted { $0.updatedAt > $1.updatedAt },
            destinationChoices: { draft in AnyView(RemoteScheduleDestination(model: model, draft: draft, options: $options, settings: $settings,
                    validatedOptions: $validatedOptions, consentedOptions: $consentedOptions, editorError: $editorError,
                    existing: request.existing.flatMap { model.schedules.schedule($0.id.uuidString) }, loadsOptions: loadsOptions)) },
            calendar: model.schedules.calendar,
            projectName: { task in model.projects.first { $0.id == task.projectID?.uuidString }?.name ?? L10n.string("Chats") },
            onCancel: { model.schedules.window.editor = nil }, onSave: save,
            canSave: { draft in
                model.isConnected && (draft.mode == .continueTask ||
                    validatedOptions == RemoteScheduleOptionsKey(draft, settings: settings, connected: model.isConnected))
            }, errorMessage: editorError)
            .environment(\.timeZone, model.schedules.calendar.timeZone)
            .disabled(saving)
            .alert(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil; pending = nil } })) {
                Button(confirmation?.button ?? L10n.string("Continue")) {
                    if let pending { send(pending, confirmed: true) }
                    pending = nil
                    confirmation = nil
                }
                Button(L10n.string("Cancel"), role: .cancel) { confirmation = nil; pending = nil }
            } message: { Text(confirmation?.message ?? "") }
    }

    private func save(_ schedule: ScheduledTask) {
        guard !saving else { return }
        if schedule.destination.mode == .newTask {
            guard let options, options.ok else { return }
            for setting in options.settings ?? [] {
                let value = settings[setting.id] ?? setting.value
                if let question = setting.choices.first(where: { $0.value == value })?.confirm {
                    if let consentedOptions, consentedOptions == validatedOptions {
                        send(schedule, confirmed: true)
                        return
                    }
                    pending = schedule
                    confirmation = question
                    return
                }
            }
        }
        send(schedule, confirmed: false)
    }

    private func send(_ schedule: ScheduledTask, confirmed: Bool) {
        var schedule = schedule
        // The host resolves project identity; presentation-only folders never travel.
        if schedule.destination.workspacePath != "yardlet-host-folder" { schedule.destination.workspacePath = nil }
        guard let definition = try? JSONEncoder().encode(schedule) else { return }
        saving = true
        editorError = nil
        var picks = settings
        for setting in options?.settings ?? [] where picks[setting.id] == nil { picks[setting.id] = setting.value }
        model.request(.saveScheduledTask(scheduleID: request.existing?.id.uuidString, definition: definition,
                                         settings: picks, confirmed: confirmed)) { response in
            saving = false
            model.schedules.refused(response)
            if !response.ok { editorError = RemoteHostModel.message(for: response.error, host: model.name) }
            if response.ok {
                model.schedules.window.editor = nil
                model.schedules.load()
                if let id = response.scheduleId { model.select(.schedule(id)) }
            }
        }
    }
}

private struct RemoteScheduleDestination: View {
    let model: RemoteHostModel
    @Binding var draft: ScheduleDraft
    @Binding var options: RemoteResponse?
    @Binding var settings: [String: String]
    @Binding var validatedOptions: RemoteScheduleOptionsKey?
    @Binding var consentedOptions: RemoteScheduleOptionsKey?
    @Binding var editorError: String?
    let existing: RemoteSchedule?
    let loadsOptions: Bool
    @State private var seeded = false

    private var projectID: String { if case let .project(id) = draft.place { return id.uuidString }; return RemoteTaskProjection.chatsProjectID }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label(L10n.string("Project"))
                Picker(L10n.string("Project"), selection: $draft.place) {
                    ForEach(model.sidebar.projects) { Text($0.name).tag(ScheduleDraft.Place.project($0.id)) }
                    if case let .folder(path) = draft.place {
                        Text(existing?.projectName ?? L10n.string("Project")).tag(ScheduleDraft.Place.folder(path))
                    }
                    Divider()
                    Text(L10n.string("Chat (no project)")).tag(ScheduleDraft.Place.chat)
                }.labelsHidden().frame(maxWidth: 300, alignment: .leading)
            }
            if options?.worktree != nil {
                GridRow {
                    label(L10n.string("Runs in"))
                    Picker(L10n.string("Runs in"), selection: $draft.startsInNewWorktree) {
                        Text(L10n.string("Local")).tag(false)
                        Text(L10n.string("New worktree")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            GridRow {
                label(L10n.string("Harness"))
                Picker(L10n.string("Harness"), selection: Binding(get: { draft.harness }, set: {
                    draft.harness = $0; draft.accountID = nil; draft.modelChoice = nil
                    settings = [:]; options = nil
                })) {
                    if let harness = draft.harness,
                       !(options?.harnesses ?? []).contains(where: { $0.harness == harness.rawValue }) {
                        Text(harness.displayName).tag(HarnessKind?.some(harness))
                    }
                    ForEach(options?.harnesses ?? [], id: \.harness) { harness in
                        Text(harness.harnessName).tag(HarnessKind?.some(HarnessKind(rawValue: harness.harness)))
                    }
                }.labelsHidden().frame(maxWidth: 300, alignment: .leading)
            }
            if let selectedAccountID {
                GridRow {
                    label(L10n.string("Account"))
                    Picker(L10n.string("Account"), selection: Binding(
                        get: { draft.accountID ?? selectedAccountID },
                        set: { id in
                            guard id != (draft.accountID ?? selectedAccountID) else { return }
                            draft.accountID = id
                            draft.modelChoice = nil
                            settings = [:]
                            editorError = nil
                        })) {
                        if !accountChoices.contains(where: { $0.id == selectedAccountID }) {
                            Text(options?.scheduleAccountName ?? existing?.accountName ?? L10n.string("Account"))
                                .tag(selectedAccountID)
                                .disabled(true)
                        }
                        ForEach(accountChoices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }
            if !(options?.settings ?? []).isEmpty {
                GridRow {
                    label(L10n.string("Model"))
                    HStack(spacing: 6) {
                        let controls = RemoteTaskSettingsProjection.options(currentSettings, task: nil)
                        ComposerSessionControls(options: controls, placement: .trailing, isDisabled: !optionsAreCurrent, onChoose: choose, onPrepare: {})
                        ComposerSessionControls(options: controls, placement: .leading, isDisabled: !optionsAreCurrent, onChoose: choose, onPrepare: {})
                    }
                }
            }
        }
        .task(id: RemoteScheduleOptionsKey(draft, settings: settings, connected: model.isConnected)) {
            guard loadsOptions else { return }
            validatedOptions = nil
            guard model.isConnected else { return }
            editorError = nil
            let requestKey = RemoteScheduleOptionsKey(draft, settings: settings, connected: model.isConnected)
            let response = await model.response(to: .scheduledTaskOptions(projectID: projectID, harness: draft.harness?.rawValue, settings: settings, scheduleID: existing?.id, accountID: draft.accountID))
            guard !Task.isCancelled else { return }
            if response.ok {
                options = response
                if !seeded {
                    seeded = true
                    if existing == nil { draft.startsInNewWorktree = response.worktree ?? false }
                    if let choice = draft.modelChoice {
                        for setting in response.settings ?? [] {
                            let value: String? = switch setting.role {
                            case "model": choice.model
                            case "effort": choice.effort
                            case "permission": draft.harness == .codex ? choice.codexRunLocation.rawValue : choice.permissionMode
                            case "speed": choice.serviceTier
                            default: nil
                            }
                            if let value, setting.choices.contains(where: { $0.value == value }) { settings[setting.id] = value }
                        }
                    }
                }
                if draft.harness == nil, let harness = response.harness { draft.harness = HarnessKind(rawValue: harness) }
                if response.worktree == nil, case .project = draft.place { draft.startsInNewWorktree = false }
                validatedOptions = requestKey
            } else {
                editorError = RemoteHostModel.message(for: response.error, host: model.name)
                model.schedules.refused(response)
            }
        }
    }
    private var accountChoices: [RemoteAccount] {
        (options?.accounts ?? []).filter { $0.available != false }
    }
    private var selectedAccountID: String? { draft.accountID ?? options?.accountId }
    private var optionsAreCurrent: Bool {
        validatedOptions == RemoteScheduleOptionsKey(draft, settings: settings, connected: model.isConnected)
    }
    private var currentSettings: [RemoteSetting] {
        (options?.settings ?? []).map { setting in
            var setting = setting
            setting.value = settings[setting.id] ?? setting.value
            return setting
        }
    }
    private func choose(_ choice: ComposerSessionChoice) {
        if case let .providerOption(id, value) = choice {
            settings[id] = value
            // The shared permission control calls back only after its confirmation was accepted.
            // Reuse that consent only for the same destination, account and validated settings.
            if options?.settings?.first(where: { $0.id == id })?.choices.first(where: { $0.value == value })?.confirm != nil {
                consentedOptions = RemoteScheduleOptionsKey(draft, settings: settings, connected: model.isConnected)
            }
        }
    }
    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}
