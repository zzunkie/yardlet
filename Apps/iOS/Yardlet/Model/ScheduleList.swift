import Foundation
import Observation
import YardletRemote

/// The Mac's scheduled tasks as the Schedules screen shows them (docs/REMOTE_PROTOCOL.md §15.21). The list is read
/// when the screen opens, on every connection (the Mac sends `schedulesChanged` only to a connection that asked), on
/// `schedulesChanged` and after each command, one read at a time, in order. Pause and Resume show at once and hold
/// until the Mac's answer and the first list read after it settle them; a refusal puts the switch back.
@MainActor
@Observable
final class ScheduleList {
    /// The person's Pause or Resume. Once the Mac took it, the first list read after the answer settles it.
    private struct Pick {
        var enabled: Bool
        var settledBy: Int?
    }

    let session: HostSession
    /// A list came back since the screen opened.
    private(set) var isLoaded = false
    /// The last read failed while no list came back.
    private(set) var failedToLoad = false
    /// Run now sent and not answered yet.
    private(set) var starting: Set<String> = []
    private var listed: [RemoteSchedule] = []
    private var picks: [String: Pick] = [:]

    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var readsAgain = false

    init(session: HostSession) {
        self.session = session
    }

    /// The Mac's list, with the person's Pause and Resume shown at once.
    var schedules: [RemoteSchedule] {
        listed.map { schedule in
            guard let pick = picks[schedule.id] else { return schedule }
            var shown = schedule
            shown.enabled = pick.enabled
            return shown
        }
    }

    /// Reads the list again; a read asked for while one is under way follows it.
    func read() {
        guard reading == nil else {
            readsAgain = true
            return
        }
        reading = Task {
            repeat {
                readsAgain = false
                await fetch()
            } while readsAgain
            reading = nil
        }
    }

    /// Pull to refresh: the list read again, or the connection tried again.
    func refresh() async {
        guard session.isConnected else { return session.reconnectNow() }
        read()
        await reading?.value
    }

    private func fetch() async {
        reads += 1
        let read = reads
        let response = await session.response(to: .scheduledTasks)
        guard response.ok else {
            failedToLoad = !isLoaded
            return
        }
        listed = response.schedules ?? []
        isLoaded = true
        failedToLoad = false
        picks = picks.filter { $0.value.settledBy.map { $0 > read } ?? true }
    }

    /// Pause (`false`) or Resume (`true`), shown at once.
    func setEnabled(_ scheduleID: String, _ enabled: Bool) {
        picks[scheduleID] = Pick(enabled: enabled)
        Task {
            let response = await session.response(to: .setScheduledTaskEnabled(scheduleID: scheduleID, enabled: enabled))
            // A later pick of the person's has its own answer coming.
            if let pick = picks[scheduleID], pick.enabled == enabled, pick.settledBy == nil {
                picks[scheduleID] = response.ok ? Pick(enabled: enabled, settledBy: reads + 1) : nil
            }
            if !response.ok { session.commandError = message(for: response.error) }
            read()
        }
    }

    func runNow(_ scheduleID: String) {
        guard !starting.contains(scheduleID) else { return }
        starting.insert(scheduleID)
        Task {
            let response = await session.response(to: .runScheduledTask(scheduleID: scheduleID))
            starting.remove(scheduleID)
            if !response.ok { session.commandError = message(for: response.error) }
            read()
        }
    }

    /// A refused command in a line: a refusal that says why (a choice this device may not make, §15.28, and the like)
    /// as other commands say it; else a schedule the Mac no longer has, one starting already, and a Resume the Mac does
    /// not offer (§15.21).
    private func message(for error: RemoteError?) -> String {
        let host = session.name
        guard error?.reason == nil else { return HostSession.message(for: error, host: host) }
        switch error?.code {
        case .notFound?: return String(localized: "\(host) no longer has this scheduled task.")
        case .busy?: return String(localized: "A run of it is already starting.")
        case .notAllowed?: return String(localized: "This scheduled task can't be resumed. Edit it on \(host).")
        default: return HostSession.message(for: error, host: host)
        }
    }
}
