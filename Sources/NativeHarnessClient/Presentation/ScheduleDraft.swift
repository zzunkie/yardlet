import Foundation

/// What the schedule editor holds while the person fills it in, and the schedule it makes.
struct ScheduleDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case daily, weekly, interval, once
        var id: String { rawValue }

        var title: String {
            switch self {
            case .daily: L10n.string("Daily")
            case .weekly: L10n.string("Weekly schedule")
            case .interval: L10n.string("Every few hours")
            case .once: L10n.string("Once")
            }
        }
    }

    /// Where a new run starts: a project's primary folder, a folder no project holds, or a chat.
    enum Place: Hashable {
        case project(UUID)
        case folder(String)
        case chat
    }

    /// One of the editor's times of day. Its id stays with it while times are added and removed, so each
    /// picker stays with its time, and no later row takes it.
    struct TimeRow: Identifiable, Equatable {
        let id: Int
        var time: ScheduleTime
    }

    var name = ""
    var prompt = ""
    var kind = Kind.daily
    /// The daily and weekly trigger's times of day, at least one, as the editor lists them; the trigger
    /// keeps them earliest first.
    private(set) var timeRows = [TimeRow(id: 0, time: ScheduleTime(hour: 9, minute: 0))]
    private var nextTimeRowID = 1
    /// The weekly trigger's days, and the days an interval runs on (all when it is every day).
    var days = ScheduleWeekday.weekdays
    var intervalDays = ScheduleWeekday.everyDay
    var intervalHours = 1
    /// Kept from the schedule being edited, so an interval keeps its rhythm; a new one counts from
    /// today's midnight, so every 3 hours is 0:00, 3:00, 6:00… as cron's `*/3` hours are.
    var intervalAnchor: Date?
    var onceAt: Date
    var mode = ScheduleDestination.Mode.newTask
    var targetTaskID: UUID?
    var harness: HarnessKind?
    var accountID: String?
    var modelChoice: NewTaskModelChoice?
    var place = Place.chat
    var startsInNewWorktree = false
    var parentTaskID: UUID?

    /// A new schedule: tomorrow-ish defaults, in the new-task screen's project and harness.
    init(now: Date, calendar: Calendar = .autoupdatingCurrent, place: Place = .chat, harness: HarnessKind? = nil,
         accountID: String? = nil, modelChoice: NewTaskModelChoice? = nil, startsInNewWorktree: Bool = false) {
        let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
        onceAt = nextHour
        self.place = place
        self.harness = harness
        self.accountID = accountID
        self.modelChoice = modelChoice
        self.startsInNewWorktree = startsInNewWorktree
    }

    /// The editor for an existing schedule.
    init(editing schedule: ScheduledTask, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.init(now: now, calendar: calendar)
        name = schedule.name
        prompt = schedule.prompt
        switch schedule.trigger {
        case let .daily(times):
            kind = .daily
            self.times = times
        case let .weekly(days, times):
            kind = .weekly
            self.days = days
            self.times = times
        case let .interval(hours, anchor, days):
            kind = .interval
            intervalHours = hours
            intervalAnchor = anchor
            intervalDays = days.isEmpty ? ScheduleWeekday.everyDay : days
        case let .once(moment):
            kind = .once
            onceAt = moment
        }
        let destination = schedule.destination
        mode = destination.mode
        targetTaskID = destination.targetTaskID
        harness = destination.harness
        accountID = destination.accountID
        modelChoice = destination.modelChoice
        if let id = destination.projectID {
            place = .project(id)
        } else if let path = destination.workspacePath {
            place = .folder(path)
        } else {
            place = .chat
        }
        startsInNewWorktree = destination.startsInNewWorktree
        parentTaskID = destination.parentTaskID
    }

    /// The times in the editor's order. Setting them starts the rows afresh.
    var times: [ScheduleTime] {
        get { timeRows.map(\.time) }
        set {
            timeRows = newValue.enumerated().map { TimeRow(id: $0.offset, time: $0.element) }
            nextTimeRowID = newValue.count
        }
    }

    /// The time Add time adds: an hour after the latest time, at its minute, or the next hour after it that is
    /// an hour or more from every time. Nil once there are `ScheduleTrigger.maxTimes` or no hour is left, which
    /// also turns Add time off.
    var nextTime: ScheduleTime? {
        guard times.count < ScheduleTrigger.maxTimes else { return nil }
        guard let latest = times.max() else { return ScheduleTime(hour: 9, minute: 0) }
        return (1...23).lazy.map { ScheduleTime(hour: (latest.hour + $0) % 24, minute: latest.minute) }
            .first { next in times.allSatisfy { $0.minutes(from: next) >= ScheduleTrigger.minutesBetweenTimes } }
    }

    mutating func addTime() {
        guard let next = nextTime else { return }
        timeRows.append(TimeRow(id: nextTimeRowID, time: next))
        nextTimeRowID += 1
    }

    /// Removes a time, but never the last one.
    mutating func removeTime(_ id: TimeRow.ID) {
        guard timeRows.count > 1 else { return }
        timeRows.removeAll { $0.id == id }
    }

    mutating func setTime(_ time: ScheduleTime, of id: TimeRow.ID) {
        guard let index = timeRows.firstIndex(where: { $0.id == id }) else { return }
        timeRows[index].time = time
    }

    func trigger(now: Date, calendar: Calendar = .autoupdatingCurrent) -> ScheduleTrigger {
        switch kind {
        case .daily:
            return .daily(ScheduleTime.ordered(times))
        case .weekly:
            let times = ScheduleTime.ordered(times)
            return days == ScheduleWeekday.everyDay ? .daily(times) : .weekly(days: days, times: times)
        case .interval:
            let anchor = intervalAnchor ?? calendar.startOfDay(for: now)
            return .interval(hours: intervalHours, anchor: anchor,
                             days: intervalDays == ScheduleWeekday.everyDay ? [] : intervalDays)
        case .once:
            return .once(onceAt)
        }
    }

    /// What keeps the schedule from being saved, or nil.
    func problem(now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.string("Write what each run asks.") }
        switch mode {
        case .newTask:
            if harness == nil { return L10n.string("Choose a harness.") }
        case .continueTask:
            if targetTaskID == nil { return L10n.string("Choose the task to continue.") }
        }
        switch kind {
        case .weekly where days.isEmpty, .interval where intervalDays.isEmpty:
            return L10n.string("Choose at least one day.")
        case .daily where times.isEmpty, .weekly where times.isEmpty:
            return L10n.string("Choose a time.")
        case .daily where !ScheduleTrigger.timesAreValid(times), .weekly where !ScheduleTrigger.timesAreValid(times),
             .interval where !ScheduleTrigger.intervalHours.contains(intervalHours):
            return L10n.string("Schedules run at most once an hour.")
        case .once where onceAt <= now:
            return L10n.string("Choose a time that has not passed.")
        default:
            return nil
        }
    }

    /// The first run the schedule would make, for the editor's preview.
    func nextRun(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        trigger(now: now, calendar: calendar).nextSlot(after: now, calendar: calendar)
    }

    /// The schedule this draft makes. `existing` keeps its identity, history and origin.
    func schedule(projects: [Project], existing: ScheduledTask?, now: Date,
                  calendar: Calendar = .autoupdatingCurrent, targetHarness: HarnessKind? = nil) -> ScheduledTask {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var destination = ScheduleDestination(mode: mode, harness: targetHarness ?? harness ?? .claudeCode)
        switch mode {
        case .continueTask:
            destination.targetTaskID = targetTaskID
        case .newTask:
            destination.accountID = accountID
            destination.modelChoice = modelChoice
            destination.parentTaskID = parentTaskID
            switch place {
            case let .project(id):
                let project = projects.first { $0.id == id }
                destination.projectID = id
                destination.workspacePath = project.map { ProjectSidebarPresentation.normalizedPath(for: $0.primaryRoot) }
            case let .folder(path):
                destination.workspacePath = path
            case .chat:
                break
            }
            destination.startsInNewWorktree = destination.workspacePath != nil && startsInNewWorktree
        }
        var schedule = existing ?? ScheduledTask(name: "", prompt: "", trigger: trigger(now: now, calendar: calendar),
                                                 destination: destination, createdAt: now)
        schedule.name = trimmedName.isEmpty ? SessionTitleProjection.provisionalTitle(from: prompt) : trimmedName
        // A prompt the person rewrote is theirs, whoever wrote the one before.
        if schedule.prompt != prompt { schedule.agentTaskID = nil }
        schedule.prompt = prompt
        schedule.trigger = trigger(now: now, calendar: calendar)
        schedule.destination = destination
        return schedule
    }
}
