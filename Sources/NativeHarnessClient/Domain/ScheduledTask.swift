import Foundation

/// A task Yardlet starts on a schedule while it is running: the prompt, when it
/// runs, and where — a new task each run, through the new-task path, or the next message of one task.
/// The person makes and changes them in Scheduled tasks, and an agent through the scheduled-task
/// tools as the Claude app's agents do (`ScheduleToolCatalog`, after its harness asks where it
/// would). Yardlet keeps them in its own storage (`~/.yardlet/schedules.json`) and installs nothing
/// outside it: no launchd
/// job, no wake schedule. A schedule that comes due while Yardlet is closed or the Mac sleeps runs
/// once when Yardlet next looks, within `ScheduleRunPolicy.catchUpWindow`.
struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var prompt: String
    var trigger: ScheduleTrigger
    var destination: ScheduleDestination
    /// Off while paused, and once it turned itself off (`state.stopReason`).
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    /// The other app's schedule this one was imported from, which importing again recognises.
    var origin: ScheduleOrigin?
    /// The task whose agent made the schedule, or last changed its prompt or where its runs go, with
    /// the scheduled-task tools; nil when the person wrote the prompt. A run sends such a prompt as
    /// that task's message (`TaskMessage`), so neither the receiving task nor the person reads it as
    /// the person's own.
    var agentTaskID: UUID?
    var state: ScheduleRunState

    init(id: UUID = UUID(), name: String, prompt: String, trigger: ScheduleTrigger,
         destination: ScheduleDestination, isEnabled: Bool = true, createdAt: Date = Date(),
         origin: ScheduleOrigin? = nil, agentTaskID: UUID? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.trigger = trigger
        self.destination = destination
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.origin = origin
        self.agentTaskID = agentTaskID
        state = ScheduleRunState(scanFloor: createdAt)
    }

    /// What a run sends: the person's prompt as written, or an agent's as its task's message, with how
    /// the sending task stands to the task that receives it (its parent, the task itself, or another).
    func runText(sender: String?, relation: TaskMessage.Relation) -> String {
        guard let agentTaskID else { return prompt }
        var message = TaskMessage(senderID: agentTaskID.uuidString, senderName: sender, body: prompt)
        message.relation = relation
        return message.text(in: .yardlet)
    }

    /// The run whose task is the latest this schedule started.
    var latestStartedRun: ScheduledTaskRun? {
        state.runs.first { $0.outcome == .started && $0.taskID != nil }
    }

    /// It turned itself off without doing its work: its runs kept failing to start, or a one-off's
    /// time passed while it could not run. A schedule the person paused, or a one-off that ran, did not.
    var hasStoppedItself: Bool {
        guard !isEnabled else { return false }
        return state.stopReason == .repeatedFailures || state.stopReason == .expired
    }
}

/// Where each run goes.
struct ScheduleDestination: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Each run starts a task of its own (the default, the Codex app's "Start each run in new chat").
        case newTask
        /// Each run is the next message of `targetTaskID`, as a Codex heartbeat is.
        case continueTask
    }

    var mode: Mode = .newTask
    var harness: HarnessKind
    /// The account (`AccountChoice.id`) new runs start on; nil starts on the one the harness's new
    /// tasks start on when the run starts.
    var accountID: String?
    /// The model, effort and permission mode, in the harness's own values, as the new-task screen
    /// keeps them.
    var modelChoice: NewTaskModelChoice?
    /// The folder a new task runs in; nil starts a chat, in a folder made for it.
    var workspacePath: String?
    var projectID: UUID?
    var startsInNewWorktree = false
    /// The task `continueTask` sends to.
    var targetTaskID: UUID?
    /// The task new runs nest under in the sidebar, when the schedule came from one.
    var parentTaskID: UUID?

    var workspaceURL: URL? {
        workspacePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

/// The other app a schedule was imported from and its own ID there.
struct ScheduleOrigin: Codable, Hashable, Sendable {
    enum App: String, Codable, Sendable {
        case claudeApp
        case codexApp
    }

    var app: App
    var sourceID: String
}

/// What a schedule has done, kept with it.
struct ScheduleRunState: Codable, Equatable, Sendable {
    /// No slot at or before this is run late: the moment the schedule was made, resumed, given a
    /// new trigger or imported (the Claude app's `missedRunScanFloor`).
    var scanFloor: Date
    /// The latest slot that was run or skipped.
    var lastSlot: Date?
    var lastRunAt: Date?
    var consecutiveFailures = 0
    /// Why the schedule turned itself off.
    var stopReason: ScheduleStopReason?
    /// Newest first, at most `ScheduleRunPolicy.runHistoryLimit`.
    var runs: [ScheduledTaskRun] = []

    init(scanFloor: Date) {
        self.scanFloor = scanFloor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanFloor = try container.decode(Date.self, forKey: .scanFloor)
        lastSlot = try container.decodeIfPresent(Date.self, forKey: .lastSlot)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        stopReason = try container.decodeIfPresent(ScheduleStopReason.self, forKey: .stopReason)
        runs = try container.decodeIfPresent([ScheduledTaskRun].self, forKey: .runs) ?? []
    }
}

enum ScheduleStopReason: String, Codable, Sendable {
    /// Its runs failed to start `ScheduleRunPolicy.failureLimit` times in a row.
    case repeatedFailures
    /// A one-off that ran.
    case finished
    /// A one-off whose time passed while it could not run (outside the catch-up window, or before
    /// it was imported).
    case expired
}

/// One time a schedule came due or was run by hand, and what came of it.
struct ScheduledTaskRun: Codable, Equatable, Identifiable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case scheduled
        /// Its time passed while Yardlet was closed or the Mac slept; run once, late.
        case missed
        /// Run now.
        case manual
    }

    enum Outcome: String, Codable, Sendable {
        case started
        case skipped
        case failed
    }

    enum SkipReason: String, Codable, Sendable {
        /// The task the previous run started is still working or waiting on the person.
        case previousRunActive
        /// The task a continuing schedule sends to is working, waiting, or being edited.
        case targetBusy
    }

    var id = UUID()
    /// The time it was due; nil for Run now.
    var slot: Date?
    var at: Date
    var trigger: Trigger
    var outcome: Outcome
    var skipReason: SkipReason?
    /// Why it failed to start.
    var failure: String?
    /// The task it started or continued.
    var taskID: UUID?
    /// The account it went to instead of the schedule's or the task's own, which was nearly spent.
    var account: AccountAssignment?
}
