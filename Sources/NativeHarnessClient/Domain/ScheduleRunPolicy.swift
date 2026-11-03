import Foundation

/// When a schedule runs, from its trigger, what it has done and the time.
///
/// - **Only while Yardlet runs.** Nothing wakes the Mac or opens Yardlet.
/// - **A missed run runs once.** When Yardlet looks after its slots passed — it was closed, or the
///   Mac slept — only the latest slot within the past `catchUpWindow` runs, once, and says it was
///   missed. That is the Claude app's rule (its scheduled-task runner scans back seven days,
///   `6048e5` ms, from the later of the last run and `missedRunScanFloor`); the Codex app runs a
///   stored `next_run_at` that passed once at any age. Slots before the schedule was made, resumed,
///   given a new trigger or imported never run late (`ScheduleRunState.scanFloor`).
/// - **A slot up to `onTimeTolerance` late is on time** (the Claude app's two minutes, `12e4` ms).
/// - **Skip if still running.** A slot whose previous run's task is still working or waiting on the
///   person is skipped and recorded (`ScheduledTaskRun.SkipReason`); the center checks that, since
///   it needs the tasks. One-off continuations instead keep a pending run for at most 24 hours.
/// - **Repeated failures turn it off.** `failureLimit` failed starts in a row pause the schedule
///   with the reason.
enum ScheduleRunPolicy {
    static let busyDeferralWindow: TimeInterval = 24 * 3_600
    static let catchUpWindow: TimeInterval = 7 * 24 * 3_600
    static let onTimeTolerance: TimeInterval = 120
    static let failureLimit = 3
    static let runHistoryLimit = 50

    enum Decision: Equatable, Sendable {
        /// Nothing is due; the next slot, if any.
        case wait(next: Date?)
        case run(slot: Date, trigger: ScheduledTaskRun.Trigger)
        /// A one-off whose moment passed where it may not run late.
        case expire(slot: Date)
    }

    static func decide(_ schedule: ScheduledTask, now: Date, calendar: Calendar) -> Decision {
        guard schedule.isEnabled else { return .wait(next: nil) }
        let state = schedule.state
        if let pending = state.runs.first(where: { $0.outcome == .deferred }), let slot = pending.slot {
            return now.timeIntervalSince(slot) >= busyDeferralWindow
                ? .expire(slot: slot) : .run(slot: slot, trigger: .missed)
        }
        let floor = max(state.lastSlot ?? .distantPast, state.scanFloor, now.addingTimeInterval(-catchUpWindow))
        if let slot = schedule.trigger.latestSlot(after: floor, notAfter: now, calendar: calendar) {
            return .run(slot: slot, trigger: now.timeIntervalSince(slot) > onTimeTolerance ? .missed : .scheduled)
        }
        if case let .once(moment) = schedule.trigger, moment <= now {
            return .expire(slot: moment)
        }
        return .wait(next: schedule.trigger.nextSlot(after: now, calendar: calendar))
    }

    /// The next time the schedule runs, for the list: nil when it is off or has no slot left.
    static func nextRun(of schedule: ScheduledTask, now: Date, calendar: Calendar) -> Date? {
        switch decide(schedule, now: now, calendar: calendar) {
        case let .wait(next): next
        case .run: now
        case .expire: nil
        }
    }

    /// The schedule after a slot ran, was skipped, or failed to start.
    static func record(_ run: ScheduledTaskRun, in schedule: ScheduledTask) -> ScheduledTask {
        var schedule = schedule
        var state = schedule.state
        // Replace the pending record; repeated checks never add duplicate runs.
        if let index = state.runs.firstIndex(where: { $0.outcome == .deferred && $0.slot == run.slot }) {
            state.runs.remove(at: index)
        }
        if let slot = run.slot, run.outcome != .deferred { state.lastSlot = max(state.lastSlot ?? slot, slot) }
        if run.outcome == .started || run.outcome == .failed { state.lastRunAt = run.at }
        state.runs.insert(run, at: 0)
        while state.runs.count > runHistoryLimit,
              let index = state.runs.lastIndex(where: { $0.outcome != .deferred }) {
            state.runs.remove(at: index)
        }
        switch run.outcome {
        case .started:
            state.consecutiveFailures = 0
        case .failed:
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= failureLimit {
                schedule.isEnabled = false
                state.stopReason = .repeatedFailures
            }
        case .skipped, .deferred, .expired:
            break
        }
        // A one-off is done once its moment has been dealt with, however it went.
        if case .once = schedule.trigger, run.slot != nil, run.outcome != .deferred, state.stopReason == nil {
            schedule.isEnabled = false
            state.stopReason = .finished
        }
        schedule.state = state
        return schedule
    }

    /// A one-off that may no longer run.
    static func expire(_ schedule: ScheduledTask, slot: Date) -> ScheduledTask {
        var schedule = schedule
        schedule.isEnabled = false
        schedule.state.lastSlot = slot
        for index in schedule.state.runs.indices where schedule.state.runs[index].outcome == .deferred {
            schedule.state.runs[index].outcome = .expired
        }
        schedule.state.stopReason = .expired
        return schedule
    }

    /// Pausing keeps everything; resuming starts counting from now, so slots passed while it was
    /// paused do not run late, and clears a stop.
    static func setEnabled(_ enabled: Bool, _ schedule: ScheduledTask, now: Date) -> ScheduledTask {
        var schedule = schedule
        guard schedule.isEnabled != enabled else { return schedule }
        schedule.isEnabled = enabled
        for index in schedule.state.runs.indices where schedule.state.runs[index].outcome == .deferred {
            schedule.state.runs[index].outcome = .skipped
            schedule.state.runs[index].skipReason = .targetBusy
        }
        schedule.updatedAt = now
        if enabled {
            schedule.state.scanFloor = now
            schedule.state.consecutiveFailures = 0
            schedule.state.stopReason = nil
        }
        return schedule
    }

    /// The schedule with the person's edits. A new trigger counts from now, as resuming does, and a
    /// one-off given a new moment may run again.
    static func edit(_ schedule: ScheduledTask, to edited: ScheduledTask, now: Date) -> ScheduledTask {
        var result = edited
        result.id = schedule.id
        result.createdAt = schedule.createdAt
        result.origin = schedule.origin
        result.updatedAt = now
        result.state = schedule.state
        if edited.trigger != schedule.trigger || edited.destination != schedule.destination {
            result.state.runs.removeAll { $0.outcome == .deferred }
        }
        if edited.trigger != schedule.trigger {
            result.state.scanFloor = now
            result.state.lastSlot = nil
            if result.state.stopReason == .finished || result.state.stopReason == .expired {
                result.state.stopReason = nil
                result.isEnabled = true
            }
        }
        return result
    }
}
