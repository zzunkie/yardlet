import Foundation
import YardletRemote

extension RemoteSchedule {
    var localDefinition: ScheduledTask? {
        definition.flatMap { try? JSONDecoder().decode(ScheduledTask.self, from: $0) }
    }
}

extension RemoteHostSchedules {
    var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let timeZone, let zone = TimeZone(identifier: timeZone) { calendar.timeZone = zone }
        return calendar
    }

    var definitions: [ScheduledTask] { (list ?? []).compactMap(\.localDefinition) }

    func nextRun(_ schedule: ScheduledTask) -> Date? {
        self.schedule(schedule.id.uuidString)?.nextRunAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var context: ScheduledTaskContext {
        ScheduledTaskContext(
            task: { [weak self] id in self?.model?.sidebar.sessions.first { $0.id == id } },
            projectName: { [weak self] schedule in
                self?.schedule(schedule.id.uuidString)?.projectName ?? L10n.string("Chat (no project)")
            },
            accountName: { [weak self] schedule in self?.schedule(schedule.id.uuidString)?.accountName })
    }

    var actions: ScheduledTaskActions {
        ScheduledTaskActions(
            canEdit: canEdit, canImport: false,
            select: { [weak self] id in self?.model?.select(.schedule(id.uuidString)) },
            create: { [weak self] in
                guard let self, canEdit else { return }
                window.editor = .init(draft: ScheduleDraft(now: Date(), calendar: calendar), existing: nil)
            },
            runNow: { [weak self] id in self?.runNow(id.uuidString) },
            setEnabled: { [weak self] id, enabled in self?.setEnabled(id.uuidString, enabled) },
            edit: { [weak self] id in
                guard let self, canEdit, let schedule = schedule(id.uuidString)?.localDefinition else { return }
                window.editor = .init(draft: ScheduleDraft(editing: schedule, now: Date(), calendar: calendar), existing: schedule)
            },
            delete: { [weak self] id in guard self?.canEdit == true else { return }; self?.window.pendingDelete = id },
            deleteCompleted: { [weak self] in
                guard let self, canEdit else { return }
                window.pendingDeleteCompleted = Set(definitions.filter { ScheduleListSections.section(of: $0) == .finished }.map(\.id))
            },
            openTask: { [weak self] id in self?.model?.select(.task(id.uuidString)) })
    }

    func delete(_ ids: Set<UUID>, completedOnly: Bool) {
        guard canEdit else { return }
        model?.request(.deleteScheduledTasks(scheduleIDs: ids.map(\.uuidString), completedOnly: completedOnly, confirmed: true)) { [weak self] response in
            guard let self else { return }
            refused(response)
            if response.ok {
                if case let .schedule(id) = model?.selection, ids.contains(where: { $0.uuidString == id }) { model?.select(.none) }
                load()
            }
        }
    }
}
