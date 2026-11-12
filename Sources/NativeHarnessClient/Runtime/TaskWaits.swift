import Foundation

/// How waits on tasks look again (`TaskWaits`): how soon after a wake from a frequent change, and how long with no
/// wake at all. Tests change them.
struct TaskWaitTiming {
    /// An account move waiting on its task, or an account's tasks waiting to move.
    var moveSpacing: Duration = .seconds(1)
    var moveFallback: Duration = .seconds(10)
    /// `wait_tasks`, waiting for a task or agent to end its turn or wait for the person.
    var toolSpacing: Duration = .milliseconds(250)
    var toolFallback: Duration = .seconds(5)
    /// The message that a child task or background agent has ended.
    var notificationSpacing: Duration = .seconds(1)
    var notificationFallback: Duration = .seconds(10)
}

/// Waits on tasks that look again when something that can hold one of their tasks (`TaskBlocker`) may have let it
/// go, rather than on a timer. A change that ends at one moment (a turn, a change of the task, a shell command)
/// wakes them at once (`wake(_:urgent:)` with `urgent`); one that comes often (the conversation, the queue) wakes
/// them no sooner than their spacing after their last look, so a task whose conversation streams while it waits
/// costs a look per spacing, not one per event. A wake while the waiter still looks counts once it waits. What holds
/// a task ends in many places, so a wait also looks again once its fallback passes with no wake: a place that
/// forgot to wake it delays it, rather than holding it forever.
@MainActor
final class TaskWaits {
    private enum Resumed { case fallback, wake, urgentWake, cancelled }

    private struct Waiter {
        let ids: Set<UUID>
        /// Waiting out the spacing after a frequent change's wake: only an urgent wake ends it early.
        let urgentOnly: Bool
        let continuation: CheckedContinuation<Resumed, Never>
        var fallback: Task<Void, Never>?
    }

    private var waiters: [UUID: Waiter] = [:]
    private var waitersByTask: [UUID: Set<UUID>] = [:]
    /// When each task was last woken, for a waiter that was still looking then.
    private var lastWake: [UUID: ContinuousClock.Instant] = [:]
    private var lastUrgentWake: [UUID: ContinuousClock.Instant] = [:]

    /// Whether something waits on the task now; a frequent change asks before it does more.
    func isWaiting(on id: UUID) -> Bool {
        waitersByTask[id] != nil
    }

    /// Something that can hold the task may have let it go: what waits on it looks again.
    func wake(_ id: UUID, urgent: Bool = false) {
        let now = ContinuousClock.now
        lastWake[id] = now
        if urgent { lastUrgentWake[id] = now }
        // A look takes seconds at most; a wake older than a minute counts for none.
        if lastWake.count > 1_024 {
            lastWake = lastWake.filter { $0.value.duration(to: now) < .seconds(60) }
            lastUrgentWake = lastUrgentWake.filter { $0.value.duration(to: now) < .seconds(60) }
        }
        guard let tokens = waitersByTask[id] else { return }
        for token in tokens where urgent || waiters[token]?.urgentOnly == false {
            resume(token, as: urgent ? .urgentWake : .wake)
        }
    }

    /// Waits until one of `ids` wakes it, `fallback` passes, or the calling task is cancelled. After a frequent
    /// change's wake it returns no sooner than `spacing` after `lastLook`, unless an urgent wake comes meanwhile.
    /// Wakes since `lastLook` count as if they came now.
    func wait(for ids: some Sequence<UUID>, since lastLook: ContinuousClock.Instant, spacing: Duration,
              fallback: Duration) async {
        let ids = Set(ids)
        func woken(_ wakes: [UUID: ContinuousClock.Instant]) -> Bool {
            ids.contains { wakes[$0].map { $0 > lastLook } == true }
        }
        if !woken(lastWake) {
            guard await suspend(on: ids, for: fallback, urgentOnly: false) == .wake else { return }
        }
        let spaced = ContinuousClock.now.duration(to: lastLook.advanced(by: spacing))
        guard spaced > .zero, !woken(lastUrgentWake) else { return }
        _ = await suspend(on: ids, for: spaced, urgentOnly: true)
    }

    private func suspend(on ids: Set<UUID>, for duration: Duration, urgentOnly: Bool) async -> Resumed {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Resumed, Never>) in
                guard !Task.isCancelled, !ids.isEmpty else { return continuation.resume(returning: .cancelled) }
                var waiter = Waiter(ids: ids, urgentOnly: urgentOnly, continuation: continuation)
                waiter.fallback = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.resume(token, as: .fallback)
                }
                waiters[token] = waiter
                for id in ids { waitersByTask[id, default: []].insert(token) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(token, as: .cancelled) }
        }
    }

    private func resume(_ token: UUID, as resumed: Resumed) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        for id in waiter.ids {
            waitersByTask[id]?.remove(token)
            if waitersByTask[id]?.isEmpty == true { waitersByTask.removeValue(forKey: id) }
        }
        waiter.fallback?.cancel()
        waiter.continuation.resume(returning: resumed)
    }
}
