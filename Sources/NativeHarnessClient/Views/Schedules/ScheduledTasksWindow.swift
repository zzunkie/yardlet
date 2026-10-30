import SwiftUI

/// A window's scheduled-tasks place: whether it shows, the chosen schedule, and the editor, delete
/// question and import sheet it has open.
@MainActor
@Observable
final class ScheduledTasksWindowState {
    struct EditorRequest: Identifiable {
        let id = UUID()
        let draft: ScheduleDraft
        let existing: ScheduledTask?
    }

    var isShowing = false
    var selection: UUID?
    var editor: EditorRequest?
    var pendingDelete: UUID?
    var isImporting = false
    var importListing: ScheduleImportListing?

    var hasModal: Bool { editor != nil || pendingDelete != nil || isImporting }
}

/// The sidebar's list for the window's schedules.
struct ScheduledTasksSidebar: View {
    let model: AppModel
    @Bindable var state: ScheduledTasksWindowState
    let onBack: () -> Void
    let actions: ScheduledTaskActions

    var body: some View {
        let center = model.scheduledTasks
        ScheduledTaskList(
            schedules: center.schedules,
            sessionJobs: model.scheduledSessionJobs,
            selection: state.selection,
            startingIDs: center.startingIDs,
            now: center.displayNow,
            nextRun: { center.nextRun(of: $0) },
            onBack: onBack,
            actions: actions)
    }
}

/// The chosen schedule beside the list, and the sheets the schedules open.
struct ScheduledTasksMain: View {
    let model: AppModel
    @Bindable var state: ScheduledTasksWindowState
    let actions: ScheduledTaskActions
    let projectName: (SessionRecord) -> String

    private var center: ScheduledTaskCenter { model.scheduledTasks }

    var body: some View {
        Group {
            if let id = state.selection, let schedule = center.schedule(id: id) {
                ScheduledTaskDetail(
                    schedule: schedule, nextRun: center.nextRun(of: schedule),
                    isStarting: center.startingIDs.contains(id), now: center.displayNow,
                    context: context, actions: actions)
            } else {
                ScheduledTaskEmptyDetail(hasSchedules: !center.schedules.isEmpty, actions: actions)
            }
        }
        .sheet(item: $state.editor) { request in
            ScheduledTaskEditor(
                draft: request.draft, existing: request.existing,
                projects: model.projects.projects.filter { !$0.isHidden },
                tasks: model.sidebarSessions.sorted { $0.updatedAt > $1.updatedAt },
                runtimeSelections: model.runtimeSelections, connections: model.connections,
                models: NewTaskModelSource(catalogs: model.modelCatalogs) {
                    await model.loadNewTaskModels(harness: $0, runtimeURL: $1, connection: $2, workspaceURL: $3)
                },
                now: { center.now() },
                projectName: projectName,
                onCancel: { state.editor = nil },
                onSave: { schedule in
                    if request.existing == nil {
                        center.create(schedule)
                    } else {
                        center.update(schedule)
                    }
                    state.selection = schedule.id
                    state.editor = nil
                })
        }
        .sheet(isPresented: $state.isImporting) {
            ScheduleImportSheet(
                listing: state.importListing, now: center.now(),
                onImport: { chosen in
                    let count = model.importSchedules(chosen, linkedTasks: state.importListing?.linkedTasks ?? [:])
                    if var listing = state.importListing {
                        for item in chosen where center.isImported(item.origin) { listing.imported.insert(item.id) }
                        state.importListing = listing
                    }
                    if state.selection == nil { state.selection = center.schedules.last?.id }
                    return count
                },
                onDismiss: { state.isImporting = false })
            .task {
                guard state.importListing == nil else { return }
                state.importListing = await model.scheduleImportListing()
            }
        }
        .alert(L10n.string("Delete scheduled task?"), isPresented: Binding(
            get: { state.pendingDelete != nil },
            set: { if !$0 { state.pendingDelete = nil } })) {
            Button(L10n.string("Delete"), role: .destructive) {
                if let id = state.pendingDelete {
                    center.delete(id)
                    if state.selection == id { state.selection = center.schedules.first?.id }
                }
                state.pendingDelete = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { state.pendingDelete = nil }
        } message: {
            Text(L10n.format("“%@” will not run again. The tasks its runs started stay in the sidebar.",
                             state.pendingDelete.flatMap(center.schedule(id:))?.name ?? ""))
        }
    }

    private var context: ScheduledTaskContext {
        ScheduledTaskContext(
            task: { id in model.store.sessions.first { $0.id == id } },
            projectName: { schedule in
                let destination = schedule.destination
                if let project = model.projects.project(id: destination.projectID) { return project.name }
                if let path = destination.workspacePath {
                    return ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path))
                }
                return L10n.string("Chat (no project)")
            },
            accountName: { schedule in
                let harness = schedule.destination.harness
                let choices = model.connections.choices(for: [harness], includingMoving: true)
                let id = schedule.destination.accountID ?? model.connections.selection[harness]
                    ?? AccountChoice.nativeID(for: harness)
                return choices.first { $0.id == id }?.title
            })
    }
}

extension ScheduledTasksWindowState {
    /// The actions the window's schedule views take, against the model's center.
    func actions(model: AppModel, newDraft: @escaping () -> ScheduleDraft, openTask: @escaping (UUID) -> Void)
        -> ScheduledTaskActions {
        let center = model.scheduledTasks
        return ScheduledTaskActions(
            select: { [weak self] id in self?.selection = id },
            create: { [weak self] in self?.editor = EditorRequest(draft: newDraft(), existing: nil) },
            importFromApps: { [weak self] in
                self?.importListing = nil
                self?.isImporting = true
            },
            runNow: { id in Task { await center.runNow(id) } },
            setEnabled: { id, enabled in center.setEnabled(enabled, for: id) },
            edit: { [weak self] id in
                guard let schedule = center.schedule(id: id) else { return }
                self?.editor = EditorRequest(draft: ScheduleDraft(editing: schedule, now: center.now()), existing: schedule)
            },
            delete: { [weak self] id in self?.pendingDelete = id },
            openTask: openTask)
    }
}
