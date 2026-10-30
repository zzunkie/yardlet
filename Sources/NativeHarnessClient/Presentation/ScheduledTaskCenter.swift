import Foundation
import Observation

/// What starting one run did.
enum ScheduleStartResult: Equatable, Sendable {
    case started(taskID: UUID)
    case failed(String)
}

/// Yardlet's schedules and the one loop that runs them while Yardlet is open.
/// The loop wakes for the next slot, or at least every `checkInterval`, and reads the wall clock
/// each time, so a slot passed while the Mac slept or the clock changed is found on the next look
/// (`ScheduleRunPolicy`). Starting a run is the app model's (`start`): a task through the new-task
/// path, or the next message of a task. Tests drive `checkDue()` with their own clock instead.
@MainActor
@Observable
final class ScheduledTaskCenter {
    private(set) var schedules: [ScheduledTask]
    /// Schedules whose run is being started now.
    private(set) var startingIDs: Set<UUID> = []
    /// Bumped by each look, so a list showing "next run" redraws as time passes.
    private(set) var lastCheck = Date()

    /// The time views show "next run" and history against; reading it redraws them after each look.
    var displayNow: Date {
        _ = lastCheck
        return now()
    }

    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }
    /// Starts one run: the app model's new-task path or its send to a task.
    @ObservationIgnored var start: ((ScheduledTask, ScheduledTaskRun.Trigger, Date?) async -> ScheduleStartResult)?
    /// Why a run may not start now (the previous run's task, or the continued task, is busy).
    @ObservationIgnored var busyReason: ((ScheduledTask) -> ScheduledTaskRun.SkipReason?)?
    /// The longest the loop sleeps between looks.
    @ObservationIgnored var checkInterval: Duration = .seconds(60)

    @ObservationIgnored private let repository: any ScheduledTaskRepository
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The loop's current sleep; cancelling it ends the sleep, not the loop.
    @ObservationIgnored private var sleeper: Task<Void, Never>?

    init(repository: any ScheduledTaskRepository = InMemoryScheduledTaskRepository()) {
        self.repository = repository
        schedules = repository.load()?.schedules ?? []
        ScheduleNameDirectory.shared.update(schedules)
    }

    func schedule(id: UUID) -> ScheduledTask? {
        schedules.first { $0.id == id }
    }

    /// The schedule whose run started this task, for the sidebar's clock and the run history.
    func schedule(startedTask taskID: UUID) -> ScheduledTask? {
        schedules.first { $0.state.runs.contains { $0.taskID == taskID && $0.outcome == .started } }
    }

    /// The tasks schedules started, for the sidebar's clock mark.
    var scheduledTaskIDs: Set<UUID> {
        Set(schedules.flatMap { schedule in
            schedule.state.runs.compactMap { run in
                run.outcome == .started && schedule.destination.mode == .newTask ? run.taskID : nil
            }
        })
    }

    var enabledCount: Int { schedules.filter(\.isEnabled).count }

    func nextRun(of schedule: ScheduledTask) -> Date? {
        ScheduleRunPolicy.nextRun(of: schedule, now: now(), calendar: calendar())
    }

    // MARK: - The person's changes

    func create(_ schedule: ScheduledTask) {
        var schedule = schedule
        let now = now()
        schedule.createdAt = now
        schedule.updatedAt = now
        schedule.state = ScheduleRunState(scanFloor: now)
        schedules.append(schedule)
        persist()
    }

    func update(_ edited: ScheduledTask) {
        guard let index = schedules.firstIndex(where: { $0.id == edited.id }) else { return }
        schedules[index] = ScheduleRunPolicy.edit(schedules[index], to: edited, now: now())
        persist()
    }

    func delete(_ id: UUID) {
        schedules.removeAll { $0.id == id }
        persist()
    }

    /// Points the schedules whose runs start on one account at another, as the account's tasks move
    /// there before it leaves the list. Nothing else about them changes.
    func moveAccount(_ accountID: String, to targetID: String) {
        guard schedules.contains(where: { $0.destination.accountID == accountID }) else { return }
        for index in schedules.indices where schedules[index].destination.accountID == accountID {
            schedules[index].destination.accountID = targetID
        }
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index] = ScheduleRunPolicy.setEnabled(enabled, schedules[index], now: now())
        persist()
    }

    /// Adds imported schedules, skipping any whose origin is already here. Each counts from now:
    /// nothing that came due before the import runs late. Returns those added.
    @discardableResult
    func add(imported: [ScheduledTask]) -> [ScheduledTask] {
        var origins = Set(schedules.compactMap(\.origin))
        var added: [ScheduledTask] = []
        let now = now()
        for var schedule in imported {
            guard let origin = schedule.origin, origins.insert(origin).inserted else { continue }
            let enabled = schedule.isEnabled
            schedule.createdAt = now
            schedule.updatedAt = now
            schedule.state = ScheduleRunState(scanFloor: now)
            if case let .once(moment) = schedule.trigger, moment <= now {
                schedule = ScheduleRunPolicy.expire(schedule, slot: moment)
            } else {
                schedule.isEnabled = enabled
            }
            schedules.append(schedule)
            added.append(schedule)
        }
        if !added.isEmpty { persist() }
        return added
    }

    func isImported(_ origin: ScheduleOrigin) -> Bool {
        schedules.contains { $0.origin == origin }
    }

    // MARK: - Running

    /// Runs a schedule now, outside its trigger. Its next slot stays as it was.
    func runNow(_ id: UUID) async {
        guard let schedule = schedule(id: id), !startingIDs.contains(id) else { return }
        await execute(schedule, slot: nil, trigger: .manual)
    }

    /// One look: every schedule due runs once, a busy one is skipped, a one-off past its window ends.
    func checkDue() async {
        let now = now()
        let calendar = calendar()
        lastCheck = now
        for schedule in schedules where !startingIDs.contains(schedule.id) {
            switch ScheduleRunPolicy.decide(schedule, now: now, calendar: calendar) {
            case .wait:
                continue
            case let .expire(slot):
                replace(ScheduleRunPolicy.expire(schedule, slot: slot))
            case let .run(slot, trigger):
                await execute(schedule, slot: slot, trigger: trigger)
            }
        }
    }

    private func execute(_ schedule: ScheduledTask, slot: Date?, trigger: ScheduledTaskRun.Trigger) async {
        if let reason = busyReason?(schedule) {
            record(ScheduledTaskRun(slot: slot, at: now(), trigger: trigger, outcome: .skipped, skipReason: reason),
                   for: schedule.id)
            return
        }
        guard let start else { return }
        startingIDs.insert(schedule.id)
        // The slot is taken before the start begins, so a second look cannot start it again.
        if let slot, var current = self.schedule(id: schedule.id) {
            current.state.lastSlot = max(current.state.lastSlot ?? slot, slot)
            replace(current)
        }
        let at = now()
        let result = await start(schedule, trigger, slot)
        startingIDs.remove(schedule.id)
        switch result {
        case let .started(taskID):
            record(ScheduledTaskRun(slot: slot, at: at, trigger: trigger, outcome: .started, taskID: taskID),
                   for: schedule.id)
        case let .failed(message):
            record(ScheduledTaskRun(slot: slot, at: at, trigger: trigger, outcome: .failed, failure: message),
                   for: schedule.id)
        }
    }

    private func record(_ run: ScheduledTaskRun, for id: UUID) {
        guard let current = schedule(id: id) else { return }
        replace(ScheduleRunPolicy.record(run, in: current))
    }

    private func replace(_ schedule: ScheduledTask) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
        persist()
    }

    private func persist() {
        repository.save(ScheduleSnapshot(schedules: schedules))
        ScheduleNameDirectory.shared.update(schedules)
        // A change can bring the next slot closer than the loop's sleep.
        sleeper?.cancel()
    }

    // MARK: - The loop

    var isRunning: Bool { loop != nil }

    /// Looks now, then again at the next slot or after `checkInterval`, whichever is sooner, until
    /// `stop()`.
    func startLoop() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkDue()
                let delay = self.delayUntilNextLook()
                await self.sleep(for: delay)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
    }

    private func delayUntilNextLook() -> Duration {
        let now = now()
        let calendar = calendar()
        let next = schedules.compactMap { ScheduleRunPolicy.nextRun(of: $0, now: now, calendar: calendar) }.min()
        guard let next else { return checkInterval }
        // A second past the slot, so the look finds it due.
        let seconds = max(1, next.timeIntervalSince(now) + 1)
        return min(checkInterval, .milliseconds(Int(seconds * 1_000)))
    }

    private func sleep(for delay: Duration) async {
        let sleeper = Task { _ = try? await Task.sleep(for: delay) }
        self.sleeper = sleeper
        await sleeper.value
    }
}
