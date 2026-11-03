import Foundation
import YardletRemote

/// Fixture projects, tasks and conversations behind the remote protocol, for building the phone
/// client without a Mac running real tasks (`yardlet-remote-fixture`, docs/REMOTE_PROTOCOL.md §9).
/// Its tasks act out what real ones do: an approval that runs a command and streams an answer once
/// allowed, an answer streaming word by word that `stopTurn` interrupts, a long finished history
/// whose earliest turns the "provider" hands over only when asked, a question only the Mac answers,
/// a reply to any message sent to an idle task, and a message sent to a running task queued until
/// its turn ends. For v2 phones (§15) the question and a plan review are answerable, lines open into
/// output and diffs, a suggested task can be started, and tasks can be pinned, archived and started.
/// Since 2026-10-27 (§15.13–§15.18) the approval also allows for the session or takes a note with its
/// denial, messages carry images and steer or queue, queued messages act like the Mac's chips, a new
/// task picks its harness, model and worktree, a task a plan limit stopped continues under another
/// account, and a task waits on a browser tab handed to the person. Later the same day (§15.19, §15.20) the
/// approval offers every answer its card gives, one task waits on an MCP form and one on a question with a secret
/// answer, and messages and new tasks carry files. Since 2026-11-02 (§15.21) it lists scheduled tasks: one that runs
/// every morning and whose last run started a task, a paused one that continues a task, one that turned itself off
/// after failed starts, and a one-off that ran. Run now starts or continues a task, or records a skip while that task
/// is busy and a failure for the one that cannot start; Pause and Resume act as on the Mac. Since then (§15.22) a phone
/// opens what a task made: each project's tasks have a folder of their own in a temporary folder, and "Summarize the
/// crash reports" lists two outputs, a PDF beside its folder and a PNG inside it, and names a text file in its folder;
/// a file beside them that is neither is refused. Since 2026-11-03 (§15.23) a task's composer settings change (Bypass
/// permissions and Full access only once confirmed), "Check the footer on mobile" reads its settings first as a task
/// not connected to its harness does, each task offers its slash commands that may run from elsewhere (Compact, a new
/// chat, Codex's fork and Plan mode), and a task's latest message is edited and its turns forked as on the Mac. Nothing
/// else is read from or written to the Mac.
public actor RemoteFixtureBridge: RemoteBridge {
    public enum ID {
        public static let approval = "0F1E0001-0000-4000-8000-000000000001"
        public static let streaming = "0F1E0002-0000-4000-8000-000000000002"
        public static let history = "0F1E0003-0000-4000-8000-000000000003"
        public static let idle = "0F1E0004-0000-4000-8000-000000000004"
        public static let question = "0F1E0005-0000-4000-8000-000000000005"
        public static let chat = "0F1E0006-0000-4000-8000-000000000006"
        public static let child = "0F1E0007-0000-4000-8000-000000000007"
        public static let failed = "0F1E0008-0000-4000-8000-000000000008"
        public static let plan = "0F1E0009-0000-4000-8000-000000000009"
        public static let limit = "0F1E000A-0000-4000-8000-00000000000A"
        public static let handoff = "0F1E000B-0000-4000-8000-00000000000B"
        public static let form = "0F1E000C-0000-4000-8000-00000000000C"
        public static let secret = "0F1E000D-0000-4000-8000-00000000000D"
        static let yardlet = "0F1E00A1-0000-4000-8000-0000000000A1"
        static let website = "0F1E00A2-0000-4000-8000-0000000000A2"
        // Schedules (§15.21)
        public static let morningSchedule = "0F1E5001-0000-4000-8000-000000005001"
        public static let footerSchedule = "0F1E5002-0000-4000-8000-000000005002"
        public static let screenshotsSchedule = "0F1E5003-0000-4000-8000-000000005003"
        public static let reminderSchedule = "0F1E5004-0000-4000-8000-000000005004"
    }

    private struct Entry {
        var task: RemoteTask
        var turns: [RemoteTurn]
        /// Turns the "provider" still holds before `turns`, handed over by `loadEarlierConversation`.
        var held: [RemoteTurn] = []
        var pendingRequest: (id: String, kind: RemotePendingRequest)?
        /// Messages sent while the turn ran, taken when it ends.
        var queue: [RemoteItem] = []
        /// The account the task runs under (the plan limit task's list, §15.17).
        var account = "fixture-home"
        /// Its composer's settings (§15.23), and whether they were read, as a task not connected to its harness reads
        /// them when a menu opens.
        var settings: [RemoteSetting] = []
        var settingsRead = true
    }

    /// A scheduled task as the Mac keeps it (§15.21): when, where its runs go, whether it is on, and its runs.
    private struct Schedule {
        enum When {
            case daily(hour: Int, minute: Int)
            case weekdays(hour: Int, minute: Int)
            case once(Date)
        }

        enum Destination {
            case newTask(project: String, harness: Harness)
            case continueTask(String)
        }

        enum Stop {
            case repeatedFailures
            case finished
        }

        struct Run {
            var at: Date
            var outcome: RemoteSchedule.Run.Outcome
            var taskID: String?
            /// Why it started nothing, in the Mac's run history's words.
            var reason: String?
        }

        var id: String
        var name: String
        var prompt: String
        var when: When
        var destination: Destination
        var enabled = true
        var stop: Stop?
        var failures = 0
        /// Why a start fails, for the schedule that cannot start.
        var failure: String?
        /// Newest first.
        var runs: [Run] = []
        var starting = false

        /// The task its latest started run started or continued.
        var latestTaskID: String? { runs.first { $0.outcome == .started && $0.taskID != nil }?.taskID }
    }

    private var order: [String] = []
    private var tasks: [String: Entry] = [:]
    private var schedules: [Schedule] = []
    private let projects: [RemoteProject]
    private var handler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var scripts: [String: Task<Void, Never>] = [:]
    /// What starts again later: a new request, the next release build.
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0
    /// How much faster than real time the scripts run (tests run them fast).
    private let speed: Double
    /// Where the tasks' folders and files are (§15.22), made the first time a phone asks for them.
    public nonisolated let filesFolder: URL
    private var madeFiles = false
    private let filesWrittenAt: Date

    /// `filesFolder` holds the tasks' folders and files; by default a new folder in the temporary folder.
    public init(speed: Double = 1, filesFolder: URL? = nil) {
        self.speed = max(0.01, speed)
        self.filesFolder = filesFolder ?? FileManager.default.temporaryDirectory
            .appending(path: "yardlet-remote-fixture-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        projects = [
            RemoteProject(id: ID.yardlet, name: "Yardlet", kind: .project, canCreateTask: true),
            RemoteProject(id: ID.website, name: "Website", kind: .project, canCreateTask: true),
            RemoteProject(id: "chats", name: "Chats", kind: .chats, canCreateTask: true)
        ]
        let now = Date()
        func at(_ minutesAgo: Double) -> Int64 { RemoteJSON.milliseconds(now.addingTimeInterval(-minutesAgo * 60)) }
        var historyTurns = (1...30).map { Self.historyTurn($0, now: now) }
        let held = Array(historyTurns.prefix(10))
        historyTurns.removeFirst(10)
        var entries = [
            Entry(task: Self.task(ID.approval, "Approve the index migration", .claude, ID.yardlet, at(1)),
                  turns: Self.approvalTurns(now: now), pendingRequest: ("toolu_fixture_1", .approval)),
            Entry(task: Self.task(ID.streaming, "Build the release bundle", .codex, ID.yardlet, at(2)), turns: []),
            Entry(task: Self.task(ID.history, "Summarize the crash reports", .codex, ID.website, at(6), unread: true),
                  turns: historyTurns, held: held),
            Entry(task: Self.task(ID.idle, "Fix the footer links", .claude, ID.website, at(12)),
                  turns: [Self.finishedTurn("footer-1", prompt: "Find the footer links that 404", answer: Self.footerAnswer,
                                            now: now, suggestion: true)]),
            Entry(task: Self.task(ID.plan, "Plan the cache rewrite", .claude, ID.yardlet, at(4)),
                  turns: Self.planReviewTurns(now: now), pendingRequest: ("toolu_fixture_plan", .approval)),
            Entry(task: Self.task(ID.question, "Pick the release name", .claude, ID.yardlet, at(3)),
                  turns: Self.questionTurns(now: now), pendingRequest: ("toolu_fixture_question", .input)),
            Entry(task: Self.task(ID.chat, "Plan the weekend trip", .claude, "chats", at(30)), turns: [Self.planTurn(now: now)]),
            Entry(task: Self.task(ID.child, "Check the footer on mobile", .claude, ID.website, at(14), parent: ID.idle),
                  turns: [Self.finishedTurn("child-1", prompt: "Check the footer at 375 pt",
                                            answer: "The footer wraps cleanly at 375 pt.", now: now)]),
            Entry(task: Self.task(ID.failed, "Regenerate the screenshots", .claude, ID.website, at(20), unread: true),
                  turns: [Self.failedTurn(now: now)]),
            Entry(task: Self.task(ID.limit, "Write the migration guide", .claude, ID.yardlet, at(8), unread: true),
                  turns: [Self.limitTurn(now: now)]),
            Entry(task: Self.task(ID.handoff, "Publish the release notes", .codex, ID.website, at(5)),
                  turns: Self.handoffTurns(now: now), pendingRequest: ("handoff_fixture_1", .input)),
            Entry(task: Self.task(ID.form, "Create the GitHub repository", .codex, ID.yardlet, at(7)),
                  turns: Self.formTurns(now: now), pendingRequest: ("form_fixture_1", .input)),
            Entry(task: Self.task(ID.secret, "Connect the staging database", .codex, ID.website, at(9)),
                  turns: Self.secretTurns(now: now), pendingRequest: ("secret_fixture_1", .input))
        ]
        entries = entries.map { entry in
            var entry = Self.withState(entry)
            entry.settings = Self.taskSettings(for: Harness(id: entry.task.harness) ?? .claude)
            entry.settingsRead = entry.task.id != ID.child
            return entry
        }
        order = entries.map(\.task.id)
        tasks = Dictionary(uniqueKeysWithValues: entries.map { ($0.task.id, $0) })
        schedules = Self.schedules(now: now)
        filesWrittenAt = now.addingTimeInterval(-6 * 60)
    }

    // MARK: - Bridge

    public func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) {
        self.handler = handler
        if scripts[ID.streaming] == nil, timers[ID.streaming] == nil { later(ID.streaming, after: 0) { await $0.streamRelease() } }
    }

    public func snapshot() -> RemoteSnapshot {
        var listed = order.compactMap { tasks[$0] }.sorted { $0.task.lastActivityAt > $1.task.lastActivityAt }
        var requests: [String: String] = [:]
        var summaries: [String: String] = [:]
        for index in listed.indices {
            let entry = listed[index]
            guard let request = entry.pendingRequest else { continue }
            requests[entry.task.id] = request.id
            let item = entry.turns.last?.items.last { $0.requestId == request.id }
            let summary = item?.requestKind == "question"
                ? RemoteSummary.line([item?.questions?.first])
                : RemoteSummary.line([item?.title, item?.detail ?? item?.command])
            summaries[entry.task.id] = summary
            listed[index].task.pendingSummary = summary
            listed[index].task.pendingKind = item?.requestKind
        }
        return RemoteSnapshot(projects: projects, tasks: listed.map(\.task), newestRequestIDs: requests,
                              requestSummaries: summaries,
                              newTask: RemoteNewTask(harness: "claude-code", harnessName: "Claude Code"), followUp: .steer,
                              scheduledTasks: true, taskFiles: true, taskControls: true)
    }

    /// The fixture's tasks hold nothing beyond the phone's projection (§15.24).
    public func conversation(of taskID: String, detail: RemoteConversationDetail) -> RemoteConversation? {
        conversation(of: taskID)
    }

    /// The task's turns with what each offers (§15.23), and the messages queued behind its running turn at the end of
    /// the last one.
    public func conversation(of taskID: String) -> RemoteConversation? {
        guard let entry = tasks[taskID] else { return nil }
        var turns = entry.turns
        for index in turns.indices {
            let options = Self.turnOptions(turns[index], in: entry)
            if !options.isEmpty, let header = turns[index].items.firstIndex(where: { $0.kind == .turn }) {
                turns[index].items[header].options = options
            }
        }
        if !entry.queue.isEmpty, let last = turns.indices.last {
            turns[last].items += entry.queue.map { queued in
                var item = queued
                item.turnId = turns[last].id
                return item
            }
        }
        return RemoteConversation(turns: turns, hasEarlier: !entry.held.isEmpty)
    }

    public func prepareConversation(of taskID: String) {}

    public func loadEarlierConversation(of taskID: String) async {
        guard tasks[taskID]?.held.isEmpty == false else { return }
        try? await Task.sleep(for: .seconds(0.8 / speed))
        guard var entry = tasks[taskID] else { return }
        entry.turns = entry.held + entry.turns
        entry.held = []
        tasks[taskID] = entry
        changed(taskID)
    }

    public func setWatchedTasks(_ taskIDs: Set<String>) {}

    public func perform(_ command: RemoteCommand) async -> RemoteError? {
        switch command {
        case let .editMessage(taskID, turnID, text):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard let turn = entry.turns.first(where: { $0.id == turnID }),
                  Self.turnOptions(turn, in: entry).contains("edit") else {
                return RemoteError(.notAllowed, "This message can no longer be edited")
            }
            // The turn goes, and the edited message starts it again.
            tasks[taskID]?.turns.removeAll { $0.id == turnID }
            startReply(to: text, in: taskID)
            return nil
        case let .sendMessage(taskID, text, images, followUp, files):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            guard images.isEmpty || tasks[taskID]?.task.acceptsImages == true else { return RemoteError(.notAllowed) }
            guard files.isEmpty || tasks[taskID]?.task.acceptsFiles == true else { return RemoteError(.notAllowed) }
            send(Self.withFiles(Self.withImages(text, images.count), files), to: taskID, followUp: followUp ?? .steer)
            return nil
        case let .answerApproval(taskID, requestID, answer, note):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard let item = entry.turns.last?.items.last(where: {
                $0.kind == .approval && $0.requestId == requestID && $0.status == "pending"
            }) else { return RemoteError(.requestNotFound) }
            guard item.options?.contains(answer.rawValue) == true else { return RemoteError(.notAllowed) }
            answerApproval(taskID, item: item, allow: answer != .deny, note: note)
            return nil
        case let .stopTurn(taskID):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard entry.task.running else { return RemoteError(.notRunning) }
            stop(taskID)
            return nil
        case let .markRead(taskID):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            tasks[taskID]?.task.unread = false
            refreshState(taskID)
            changed(taskID)
            return nil
        case let .answerQuestion(taskID, requestID, answers):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard item.options?.contains(RemoteProtocol.answerOption) == true
                    || item.options?.contains(RemoteProtocol.answerSecretOption) == true, let steps = item.questionSteps,
                  let words = Self.answerText(answers, to: steps) else { return RemoteError(.notAllowed) }
            resolve(taskID, item: item, status: "answered",
                    reply: item.questionSteps?.contains { $0.secret == true } == true
                        ? "Thanks. Connected to the staging database; the password is not kept in this task."
                        : "Going with **\(words)**. I'll use it in the release notes and the tag.")
            return nil
        case let .reviewPlan(taskID, requestID, decision, reason):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard item.requestKind == "planReview" else { return RemoteError(.notAllowed) }
            resolve(taskID, item: item, status: decision == .approve ? "allowed" : "denied",
                    reply: decision == .approve ? "Plan approved. Starting with the read path."
                        : "I'll rework the plan\(reason.map { ": \($0)" } ?? ".")")
            return nil
        case let .actOnSuggestion(taskID, suggestionID, action):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard var item = entry.turns.flatMap(\.items).first(where: { $0.suggestionId == suggestionID }),
                  item.options?.contains(action.rawValue) == true else { return RemoteError(.notAllowed) }
            item.options = nil
            switch action {
            case .dismiss:
                item.suggestionState = "dismissed"
                replaceItem(item, in: taskID)
            case .here:
                item.suggestionState = "sentHere"
                replaceItem(item, in: taskID)
                send("Do this task here: “\(item.title ?? "")”", to: taskID)
            case .start:
                let started = startTask(title: item.title ?? "Suggested task", text: item.detail ?? "", project: entry.task.projectId,
                                        parent: taskID)
                item.suggestionState = "started"
                item.startedTaskId = started
                replaceItem(item, in: taskID)
            }
            return nil
        case let .setPinned(taskID, pinned):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            tasks[taskID]?.task.pinned = pinned
            changed(taskID)
            return nil
        case let .archiveTask(taskID):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard !entry.task.running else { return RemoteError(.busy, "The task is running") }
            tasks[taskID] = nil
            order.removeAll { $0 == taskID }
            handler?(.tasks)
            handler?(.conversation(taskID))
            return nil
        case let .actOnQueued(taskID, itemID, action):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard let index = entry.queue.firstIndex(where: { $0.id == itemID }) else { return RemoteError(.notFound) }
            guard entry.queue[index].options?.contains(action.rawValue) == true else { return RemoteError(.notAllowed) }
            let queued = entry.queue[index]
            tasks[taskID]?.queue.remove(at: index)
            switch action {
            case .remove:
                touch(taskID)
            case .sendNow:
                steer(queued.text ?? "", into: taskID)
            case .stopAndSend:
                stop(taskID, takingQueue: false)
                startReply(to: queued.text ?? "", in: taskID)
            }
            return nil
        case let .continueWithAccount(taskID, accountID):
            guard let entry = tasks[taskID], let limit = latestLimit(in: entry) else { return RemoteError(.notFound) }
            guard limit.options?.contains("continueWithAccount") == true,
                  Self.accounts(current: entry.account).contains(where: { $0.id == accountID && $0.available == true }) else {
                return RemoteError(.notAllowed)
            }
            tasks[taskID]?.account = accountID
            settleLimit(limit, in: taskID)
            startReply(to: "Continue where you left off.", in: taskID)
            return nil
        case let .setAutoContinue(taskID, enabled):
            guard let entry = tasks[taskID], var limit = latestLimit(in: entry),
                  limit.options?.contains("autoContinue") == true else { return RemoteError(.notAllowed) }
            limit.autoContinue = enabled ? true : nil
            replaceItem(limit, in: taskID)
            return nil
        case let .chooseAnswer(taskID, requestID, choice, note, values):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard let picked = item.choices?.first(where: { $0.id == choice }) else { return RemoteError(.notAllowed, "No such answer") }
            guard note == nil || picked.role == "destructive" else { return RemoteError(.notAllowed, "A note goes with a denial only") }
            if item.requestKind == "form" {
                if picked.role == "primary" {
                    guard case let .text(repo)? = values["repo"], !repo.trimmingCharacters(in: .whitespaces).isEmpty else {
                        return RemoteError(.notAllowed, "Repository: Required")
                    }
                    let isPrivate = values["private"] ?? .flag(true)
                    resolve(taskID, item: item, status: "answered",
                            reply: "Created **\(repo)** (\(isPrivate == .flag(false) ? "public" : "private")) and pushed the first commit.")
                } else {
                    resolve(taskID, item: item, status: "denied", reply: "Okay, I didn't create the repository.")
                }
            } else {
                answerApproval(taskID, item: item, allow: picked.role != "destructive", note: note)
            }
            return nil
        case let .answerHandoff(taskID, requestID, answer):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard item.requestKind == "browserHandoff" else { return RemoteError(.notAllowed) }
            resolve(taskID, item: item, status: answer == .done ? "answered" : "denied",
                    reply: answer == .done ? "Thanks, the session is signed in. The release notes are published at github.com/acme/web/releases."
                        : "Okay, I left the release notes as a draft. Publish it from the Releases page when you can.")
            return nil
        case let .runScheduledTask(scheduleID):
            guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return RemoteError(.notFound) }
            guard !schedules[index].starting else { return RemoteError(.busy, "A run of it is starting") }
            // As the Mac's Run now: a skip while the task of its previous run (or the task it continues) is busy.
            let (busyTask, reason): (String?, String) = switch schedules[index].destination {
            case .newTask: (schedules[index].latestTaskID, "Skipped: the previous run is still going")
            case let .continueTask(taskID): (taskID, "Skipped: the task was busy")
            }
            if let busyTask, tasks[busyTask]?.task.running == true {
                record(Schedule.Run(at: Date(), outcome: .skipped, reason: reason), in: scheduleID)
                return nil
            }
            schedules[index].starting = true
            handler?(.schedules)
            Task { await self.startRun(scheduleID) }
            return nil
        case let .setScheduledTaskEnabled(scheduleID, enabled):
            guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return RemoteError(.notFound) }
            let schedule = schedules[index]
            if enabled, !schedule.enabled, Self.isOnce(schedule), schedule.stop != nil {
                return RemoteError(.notAllowed, "A one-off that ran runs again once edited on the Mac")
            }
            guard schedule.enabled != enabled else { return nil }
            schedules[index].enabled = enabled
            if enabled {
                schedules[index].stop = nil
                schedules[index].failures = 0
            }
            handler?(.schedules)
            return nil
        }
    }

    public func scheduledTasks() async -> Result<[RemoteSchedule], RemoteError> {
        let now = Date()
        return .success(schedules.map { schedule in
            let attention = schedule.latestTaskID.flatMap { tasks[$0]?.task.attention }
            let next = Self.nextRun(of: schedule, after: now)
            var remote = RemoteSchedule(
                id: schedule.id, name: schedule.name, when: Self.whenText(schedule.when, now: now), enabled: schedule.enabled,
                running: attention == .active || attention == .waiting, nextRunAt: next.map(RemoteJSON.milliseconds),
                status: Self.status(schedule, next: next, now: now), harnessName: harness(of: schedule).name,
                canResume: !schedule.enabled && (!Self.isOnce(schedule) || schedule.stop == nil) ? true : nil)
            switch schedule.destination {
            case let .newTask(project, _):
                remote.projectName = project == "chats" ? nil : projects.first { $0.id == project }?.name
            case let .continueTask(taskID):
                let project = tasks[taskID]?.task.projectId
                remote.projectName = project == "chats" ? nil : projects.first { $0.id == project }?.name
            }
            if let run = schedule.runs.first {
                let when = "Last run \(Self.moment(run.at, now: now))"
                remote.lastRun = RemoteSchedule.Run(
                    at: RemoteJSON.milliseconds(run.at), outcome: run.outcome,
                    taskId: run.outcome == .started ? run.taskID.flatMap { tasks[$0] == nil ? nil : $0 } : nil,
                    line: run.reason.map { "\(when) · \($0)" } ?? when)
            }
            return remote
        })
    }

    // MARK: - Files (§15.22)

    public func taskOutputs(taskID: String) async -> Result<[RemoteOutput], RemoteError> {
        guard tasks[taskID] != nil else { return .failure(RemoteError(.notFound)) }
        let written = RemoteJSON.milliseconds(filesWrittenAt)
        return .success(outputs(of: taskID).enumerated().map { index, url in
            RemoteOutput(path: url.path(percentEncoded: false), name: url.lastPathComponent,
                         writtenAt: written - Int64(index) * 60_000)
        })
    }

    public func fileScope(taskID: String) async -> Result<RemoteFileScope, RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        makeFiles()
        let project = projects.first { $0.id == entry.task.projectId }?.name ?? "Chats"
        return .success(RemoteFileScope(folder: filesFolder.appending(path: project, directoryHint: .isDirectory),
                                        outputs: outputs(of: taskID)))
    }

    /// Newest first: the summary it saved on the "Desktop", beside its folder, and the chart inside it.
    private func outputs(of taskID: String) -> [URL] {
        guard taskID == ID.history else { return [] }
        makeFiles()
        return [filesFolder.appending(path: "Desktop/crash-summary.pdf"), filesFolder.appending(path: "Website/reports/crash-chart.png")]
    }

    /// Each project's folder, the crash task's files, and a file beside them a phone may not open.
    private func makeFiles() {
        guard !madeFiles else { return }
        madeFiles = true
        let manager = FileManager.default
        for folder in ["Yardlet", "Website/reports", "Chats", "Desktop"] {
            try? manager.createDirectory(at: filesFolder.appending(path: folder, directoryHint: .isDirectory),
                                         withIntermediateDirectories: true)
        }
        let files: [(String, Data)] = [
            ("Desktop/crash-summary.pdf", Self.pdf(["Crash summary", "30 reports, one cause: TaskSidebar.row(for:)",
                                                    "reads a task the archive already removed."])),
            ("Website/reports/crash-chart.png", Data(base64Encoded: Self.chartPNG) ?? Data()),
            ("Website/reports/crash-notes.txt", Data(Self.crashNotes.utf8)),
            ("Desktop/private-notes.txt", Data("Not one of the task's files.\n".utf8))
        ]
        for (path, data) in files {
            try? data.write(to: filesFolder.appending(path: path))
        }
    }

    /// A one-page PDF with a line of text each.
    private static func pdf(_ lines: [String]) -> Data {
        var text = "BT /F1 14 Tf 72 720 Td 18 TL"
        for line in lines {
            let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            text += " (\(escaped)) Tj T*"
        }
        text += " ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    /// A small bar chart.
    private static let chartPNG = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAIAAADbtmxLAAAATElEQVR42u3YMQ0AIAxE0bpiJ4jCAI5wUxvdwUHZ4BL+zwl489kSywC9A8W0ZIAA/QyqI5IBAgQIkAbIW0kGCBAgQIAA3QR1sTgbTm2R8Ia3mL5g4AAAAABJRU5ErkJggg=="

    private static let crashNotes = """
    Crash notes

    - 30 reports, all in TaskSidebar.row(for:) while a task was being archived.
    - The row reads the task after the archive removed it.
    - Fix: read the row's task once, before the archive starts.

    """

    /// A run starting, as the Mac's new-task path or a continued task's next message takes a moment.
    private func startRun(_ scheduleID: String) async {
        await pause(0.6)
        guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        schedules[index].starting = false
        let schedule = schedules[index]
        if let failure = schedule.failure {
            record(Schedule.Run(at: Date(), outcome: .failed, reason: "Could not start: \(failure)"), in: scheduleID)
            return
        }
        switch schedule.destination {
        case let .newTask(project, harness):
            let started = startTask(title: "\(schedule.name) · \(Self.moment(Date(), now: Date(), relative: false))",
                                    text: schedule.prompt, project: project, parent: nil, harness: harness)
            record(Schedule.Run(at: Date(), outcome: .started, taskID: started), in: scheduleID)
        case let .continueTask(taskID):
            guard tasks[taskID] != nil else {
                record(Schedule.Run(at: Date(), outcome: .failed,
                                    reason: "Could not start: The task this schedule continues is no longer in Yardlet."),
                       in: scheduleID)
                return
            }
            send(schedule.prompt, to: taskID)
            record(Schedule.Run(at: Date(), outcome: .started, taskID: taskID), in: scheduleID)
        }
    }

    /// A run recorded as the Mac records one: three failed starts in a row turn the schedule off.
    private func record(_ run: Schedule.Run, in scheduleID: String) {
        guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        schedules[index].runs.insert(run, at: 0)
        switch run.outcome {
        case .started:
            schedules[index].failures = 0
        case .failed:
            schedules[index].failures += 1
            if schedules[index].failures >= 3 {
                schedules[index].enabled = false
                schedules[index].stop = .repeatedFailures
            }
        case .skipped:
            break
        }
        handler?(.schedules)
    }

    private func harness(of schedule: Schedule) -> Harness {
        switch schedule.destination {
        case let .newTask(_, harness): harness
        case let .continueTask(taskID): tasks[taskID].flatMap { Harness(id: $0.task.harness) } ?? .claude
        }
    }

    public func createTask(_ start: RemoteTaskStart) async -> Result<String, RemoteError> {
        guard projects.contains(where: { $0.id == start.projectID }) else { return .failure(RemoteError(.notFound)) }
        guard let harness = start.harness.map(Harness.init(id:)) ?? .claude else { return .failure(RemoteError(.notAllowed)) }
        let offered = Self.settings(for: harness)
        for (id, value) in start.settings {
            guard offered.first(where: { $0.id == id })?.choices.contains(where: { $0.value == value }) == true else {
                return .failure(RemoteError(.notAllowed, "\(id) has no choice \(value)"))
            }
        }
        guard start.images.isEmpty || harness.acceptsImages else { return .failure(RemoteError(.notAllowed)) }
        guard start.attachedFiles.isEmpty || harness.acceptsImages else { return .failure(RemoteError(.notAllowed)) }
        let title = String((start.text.split(separator: "\n").first.map(String.init) ?? "New task").prefix(60))
        let model = start.settings["model"].flatMap { value in
            offered.first { $0.id == "model" }?.choices.first { $0.value == value }?.name
        }
        let words = Self.withFiles(Self.withImages(start.text, start.images.count), start.attachedFiles)
            + (model.map { " (on \($0)\(start.worktree == true ? ", in a new worktree" : ""))" } ?? "")
        return .success(startTask(title: title.isEmpty ? "New task" : title, text: words, project: start.projectID,
                                  parent: nil, harness: harness))
    }

    public func newTaskOptions(projectID: String?, harness: String?, settings: [String: String] = [:]) async -> Result<RemoteNewTaskOptions, RemoteError> {
        if let projectID, !projects.contains(where: { $0.id == projectID }) { return .failure(RemoteError(.notFound)) }
        guard let chosen = harness.map(Harness.init(id:)) ?? .claude else { return .failure(RemoteError(.notAllowed)) }
        // As the Mac reads a model list it has not read yet.
        await pause(0.4)
        return .success(RemoteNewTaskOptions(
            harness: chosen.option, harnesses: Harness.allCases.map(\.option), settings: Self.settings(for: chosen),
            worktree: projectID == nil || projectID == "chats" ? nil : false))
    }

    public func limitAccounts(taskID: String) async -> Result<[RemoteAccount], RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        guard latestLimit(in: entry) != nil else { return .failure(RemoteError(.unavailable)) }
        // As the Mac rereads the limits it has not checked within the last minute.
        await pause(0.6)
        return .success(Self.accounts(current: entry.account))
    }

    public func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError> {
        guard let entry = tasks[taskID], let item = entry.turns.flatMap(\.items).first(where: { $0.id == itemID }) else {
            return .failure(RemoteError(.notFound))
        }
        switch item.activity {
        case "fileChange"?:
            let file = item.title?.split(separator: " ").last.map(String.init) ?? "File.swift"
            return .success(RemoteItemDetail(diffs: [RemoteDiff(path: "Sources/\(file)", patch: Self.samplePatch,
                                                                additions: item.additions, deletions: item.deletions)]))
        case "command"?:
            return .success(RemoteItemDetail(output: Self.sampleOutput(for: item.title ?? "")))
        default:
            return .failure(RemoteError(.unavailable))
        }
    }

    // MARK: - A task's controls (§15.23)

    public func taskSettings(taskID: String, prepare: Bool) async -> Result<[RemoteSetting], RemoteError> {
        guard tasks[taskID] != nil else { return .failure(RemoteError(.notFound)) }
        if prepare, tasks[taskID]?.settingsRead == false {
            // As the Mac connects a task to its harness to read its settings when a menu opens.
            await pause(0.5)
            tasks[taskID]?.settingsRead = true
        }
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        return .success(Self.shownSettings(entry))
    }

    public func setTaskSetting(taskID: String, setting id: String, value: String,
                               confirmed: Bool) async -> Result<[RemoteSetting], RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        guard let index = entry.settings.firstIndex(where: { $0.id == id }), entry.settings[index].role != "plan" else {
            return .failure(RemoteError(.notAllowed, "The task's composer has no such setting"))
        }
        guard entry.settingsRead else { return .failure(RemoteError(.notAllowed, "Read the choices first")) }
        guard let choice = entry.settings[index].choices.first(where: { $0.value == value }) else {
            return .failure(RemoteError(.notAllowed, "The menu does not offer that choice now"))
        }
        guard choice.confirm == nil || confirmed else { return .failure(RemoteError(.notAllowed, "This choice is confirmed first")) }
        await pause(0.2)
        tasks[taskID]?.settings[index].value = value
        tasks[taskID]?.settings[index].elevated = choice.confirm != nil ? true : nil
        handler?(.taskSettings(taskID))
        return .success(Self.shownSettings(tasks[taskID] ?? entry))
    }

    public func composerCommands(taskID: String) async -> Result<[RemoteComposerCommand], RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        return .success(Self.commands(for: entry))
    }

    public func runComposerCommand(taskID: String, command name: String, arguments: String?) async -> Result<String?, RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        guard let command = Self.commands(for: entry).first(where: { $0.name == name }) else {
            return .failure(RemoteError(.notAllowed, "The task's composer offers no such command here"))
        }
        guard arguments == nil || command.argumentHint != nil else {
            return .failure(RemoteError(.notAllowed, "/\(name) takes nothing after it"))
        }
        if entry.task.running, ["compact", "clear", "new"].contains(name) {
            return .failure(RemoteError(.busy, "Available when \(entry.task.harnessName) finishes this turn"))
        }
        switch name {
        case "compact":
            guard let turnID = entry.turns.last?.id else { return .failure(RemoteError(.notAllowed, "Nothing to compact yet")) }
            counter += 1
            var notice = RemoteItem(id: "i:\(turnID)-compacted-\(counter)", turnId: turnID, kind: .notice)
            notice.text = "Context compacted"
            Task { [notice] in await self.append(notice, to: taskID, after: 0.6) }
            return .success(nil)
        case "clear", "new":
            return .success(blankTask(like: entry))
        case "fork":
            return forkTask(entry, through: nil).map(Optional.some)
        case "plan-mode":
            if entry.settings.first?.role == "plan" {
                tasks[taskID]?.settings.removeFirst()
            } else {
                tasks[taskID]?.settings.insert(RemoteSetting(id: "planMode", name: "Plan mode", value: "plan", choices: [],
                                                             role: "plan"), at: 0)
            }
            handler?(.taskSettings(taskID))
            return .success(nil)
        default:
            return .failure(RemoteError(.notAllowed))
        }
    }

    public func forkTask(taskID: String, turnID: String?) async -> Result<String, RemoteError> {
        guard let entry = tasks[taskID] else { return .failure(RemoteError(.notFound)) }
        return forkTask(entry, through: turnID)
    }

    private func append(_ item: RemoteItem, to taskID: String, after seconds: Double) async {
        await pause(seconds)
        appendItem(item, to: taskID)
    }

    /// A fork from a turn (Codex) or of the whole conversation from the latest turn (Claude Code), nested under the task.
    private func forkTask(_ entry: Entry, through turnID: String?) -> Result<String, RemoteError> {
        guard let turn = turnID.map({ id in entry.turns.first { $0.id == id } }) ?? entry.turns.last,
              Self.turnOptions(turn, in: entry).contains("fork"),
              let end = entry.turns.firstIndex(where: { $0.id == turn.id }) else {
            return .failure(RemoteError(.notAllowed, "This turn cannot be forked now"))
        }
        counter += 1
        let id = String(format: "0F1E2%03d-0000-4000-8000-%012d", counter % 1000, counter)
        var fork = Entry(task: Self.task(id, "Fork of \(entry.task.title)", Harness(id: entry.task.harness) ?? .claude,
                                         entry.task.projectId ?? "chats", RemoteJSON.milliseconds(Date()), parent: entry.task.id),
                         turns: Array(entry.turns[...end]))
        fork.settings = entry.settings
        tasks[id] = Self.withState(fork)
        order.insert(id, at: 0)
        handler?(.tasks)
        return .success(id)
    }

    /// A blank task in the same project, harness and settings: Claude Code's `/clear`, Codex's New chat.
    private func blankTask(like entry: Entry) -> String {
        counter += 1
        let id = String(format: "0F1E3%03d-0000-4000-8000-%012d", counter % 1000, counter)
        var blank = Entry(task: Self.task(id, "New task", Harness(id: entry.task.harness) ?? .claude, entry.task.projectId ?? "chats",
                                          RemoteJSON.milliseconds(Date())), turns: [])
        blank.settings = entry.settings
        tasks[id] = Self.withState(blank)
        order.insert(id, at: 0)
        handler?(.tasks)
        return id
    }

    /// What a turn offers, by the Mac's rules: Codex forks from any finished turn and edits its latest request once
    /// every turn finished; Claude Code edits its latest message and forks its whole conversation from its latest turn,
    /// while idle.
    private static func turnOptions(_ turn: RemoteTurn, in entry: Entry) -> [String] {
        let finished = turn.items.first { $0.kind == .turn }.map { $0.status != "running" } ?? false
        let isLast = entry.turns.last?.id == turn.id
        let hasRequest = turn.items.contains { $0.kind == .user && $0.queued != true && $0.shell != true }
        let idle = !entry.task.running
        if entry.task.harness == "codex" {
            return (isLast && idle && hasRequest ? ["edit"] : []) + (finished ? ["fork"] : [])
        }
        return isLast && idle && hasRequest ? ["edit", "fork"] : []
    }

    /// The settings as the composer shows them now: before they were read, each menu reads them first.
    private static func shownSettings(_ entry: Entry) -> [RemoteSetting] {
        entry.settingsRead ? entry.settings : entry.settings.map { setting in
            var setting = setting
            if setting.role != "plan" { setting.prepare = true }
            return setting
        }
    }

    /// The slash commands a task's composer offers that may run from elsewhere, in its list's words.
    private static func commands(for entry: Entry) -> [RemoteComposerCommand] {
        switch entry.task.harness {
        case "codex":
            let plan = entry.settings.first?.role == "plan"
            return [
                RemoteComposerCommand(name: "compact", title: "Compact", description: "Compact this chat's context", runs: true),
                RemoteComposerCommand(name: "fork", title: "Fork chat", description: "Fork this chat", runs: true),
                RemoteComposerCommand(name: "new", title: "New chat", description: "Start a blank chat in the same workspace", runs: true),
                RemoteComposerCommand(name: "plan-mode", title: "Plan mode",
                                      description: plan ? "Turn plan mode off" : "Turn plan mode on", runs: true)
            ]
        case "claude-code":
            return [
                RemoteComposerCommand(name: "compact", description: "Clear conversation history but keep a summary in context",
                                      argumentHint: "<optional custom summarization instructions>"),
                RemoteComposerCommand(name: "clear", description: "Start a new conversation and keep this chat.")
            ]
        default:
            return []
        }
    }

    /// A new task in a project, replying like any idle task.
    private func startTask(title: String, text: String, project: String?, parent: String?, harness: Harness = .claude) -> String {
        counter += 1
        let id = String(format: "0F1E1%03d-0000-4000-8000-%012d", counter % 1000, counter)
        let entry = Entry(task: Self.task(id, title, harness, project ?? "chats", RemoteJSON.milliseconds(Date()), parent: parent),
                          turns: [])
        tasks[id] = Self.withState(entry)
        order.insert(id, at: 0)
        startReply(to: text, in: id)
        return id
    }

    /// The plan limit card of the task's latest turn, while the task is idle (§15.17).
    private func latestLimit(in entry: Entry) -> RemoteItem? {
        guard !entry.task.running else { return nil }
        return entry.turns.last?.items.last { $0.kind == .error && $0.errorKind == "usageLimit" }
    }

    /// A limit card the task moved past: it offers nothing any more.
    private func settleLimit(_ limit: RemoteItem, in taskID: String) {
        var settled = limit
        settled.options = nil
        settled.autoContinue = nil
        replaceItem(settled, in: taskID)
    }

    private func pendingItem(_ taskID: String, _ requestID: String) -> RemoteItem? {
        tasks[taskID]?.turns.last?.items.last { $0.kind == .approval && $0.requestId == requestID && $0.status == "pending" }
    }

    /// The words a question form's answers come to, or nil when they do not answer its steps.
    static func answerText(_ answers: [RemoteQuestionAnswer], to steps: [RemoteQuestionStep]) -> String? {
        var words: [String] = []
        for step in steps {
            guard let answer = answers.first(where: { $0.questionId == step.id }) else { return nil }
            if answer.skipped == true {
                guard step.skippable else { return nil }
                continue
            }
            let picked = answer.options ?? []
            guard picked.allSatisfy({ label in step.options.contains { $0.label == label } }),
                  step.multiple || picked.count <= 1 else { return nil }
            let own = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard own.isEmpty || step.custom else { return nil }
            let value = (picked + (own.isEmpty ? [] : [own])).joined(separator: ", ")
            guard !value.isEmpty else { return nil }
            words.append(value)
        }
        return words.joined(separator: "; ")
    }

    /// A question or plan review answered: it joins the work and a short answer finishes the turn.
    private func resolve(_ taskID: String, item: RemoteItem, status: String, reply: String) {
        var answered = item
        answered.status = status
        answered.options = nil
        answered.choices = nil
        answered.formFields = nil
        answered.optionTitles = nil
        answered.macNote = nil
        answered.moreOnMac = nil
        answered.inWork = true
        replaceItem(answered, in: taskID)
        tasks[taskID]?.pendingRequest = nil
        refreshState(taskID)
        changed(taskID)
        let turnID = item.turnId
        scripts[taskID]?.cancel()
        scripts[taskID] = Task {
            await self.stream(reply, id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            guard !Task.isCancelled else { return }
            self.finishTurn(taskID, turnID: turnID, status: "completed")
        }
    }

    // MARK: - Scripts

    /// A message to a running task goes into its turn when steered (the turn reads it at its next
    /// step) and otherwise waits in its queue, with the queue chip's actions, until the turn ends; to an
    /// idle task it starts a turn that replies. A task waiting on a request queues it either way.
    private func send(_ text: String, to taskID: String, followUp: RemoteFollowUpMode = .queue) {
        guard let entry = tasks[taskID] else { return }
        counter += 1
        if entry.task.running {
            if followUp == .steer, entry.task.steers == true, entry.pendingRequest == nil {
                steer(text, into: taskID)
                return
            }
            var queued = RemoteItem(id: "queued:\(counter)", turnId: "", kind: .user)
            queued.text = text
            queued.queued = true
            queued.options = entry.task.harness == "claude-code"
                ? RemoteQueuedAction.allCases.map(\.rawValue)
                : [RemoteQueuedAction.sendNow.rawValue, RemoteQueuedAction.remove.rawValue]
            tasks[taskID]?.queue.append(queued)
            touch(taskID)
            return
        }
        startReply(to: text, in: taskID)
    }

    /// A message the running turn takes now, as a sent message in that turn.
    private func steer(_ text: String, into taskID: String) {
        guard let turnID = tasks[taskID]?.turns.last?.id else { return }
        counter += 1
        var item = RemoteItem(id: "i:\(turnID)-steer-\(counter)", turnId: turnID, kind: .user)
        item.text = text
        appendItem(item, to: taskID)
    }

    /// The message's words, with the files that came with it as the reply reads them.
    private static func withFiles(_ text: String, _ files: [RemoteFile]) -> String {
        guard !files.isEmpty else { return text }
        let names = "[" + files.map(\.name).joined(separator: ", ") + "]"
        return text.isEmpty ? names : "\(text) \(names)"
    }

    /// The message's words, with how many images came with it as the reply reads them.
    private static func withImages(_ text: String, _ count: Int) -> String {
        guard count > 0 else { return text }
        let images = count == 1 ? "1 image" : "\(count) images"
        return text.isEmpty ? "[\(images)]" : "\(text) [\(images)]"
    }

    private func startReply(to text: String, in taskID: String) {
        counter += 1
        let turnID = "reply-\(counter)"
        tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [Self.user(turnID, text), Self.turnItem(turnID, running: true)]))
        tasks[taskID]?.task.running = true
        touch(taskID)
        scripts[taskID]?.cancel()
        scripts[taskID] = Task { await self.reply(to: text, in: taskID, turnID: turnID) }
    }

    private func reply(to text: String, in taskID: String, turnID: String) async {
        await pause(1)
        guard !Task.isCancelled else { return }
        appendItem(Self.activity(turnID, "read", "Read Footer.tsx", "completed"), to: taskID)
        await pause(0.8)
        guard !Task.isCancelled else { return }
        var edit = Self.activity(turnID, "edit", "Edited Footer.tsx", "running")
        edit.activity = "fileChange"
        appendItem(edit, to: taskID)
        await pause(1)
        guard !Task.isCancelled else { return }
        edit.status = "completed"
        edit.additions = 3
        edit.deletions = 1
        replaceItem(edit, in: taskID)
        let answer = "Done. I fixed the footer for “\(String(text.prefix(80)))”:\n\n- Updated **Footer.tsx** so the links point at `/docs`.\n- Checked the other pages; nothing else needed a change."
        await stream(answer, id: "i:\(turnID)-answer", turnID: turnID, in: taskID)
        guard !Task.isCancelled else { return }
        finishTurn(taskID, turnID: turnID, status: "completed")
    }

    private func answerApproval(_ taskID: String, item: RemoteItem, allow: Bool, note: String? = nil) {
        var answered = item
        answered.status = allow ? "allowed" : "denied"
        answered.options = nil
        answered.choices = nil
        answered.formFields = nil
        answered.optionTitles = nil
        answered.macNote = nil
        answered.moreOnMac = nil
        answered.inWork = true
        replaceItem(answered, in: taskID)
        tasks[taskID]?.pendingRequest = nil
        refreshState(taskID)
        changed(taskID)
        let turnID = item.turnId
        scripts[taskID]?.cancel()
        scripts[taskID] = Task {
            if allow {
                var command = Self.activity(turnID, "run-\(item.requestId ?? "")", "Ran swift test --filter Migration", "running")
                command.activity = "command"
                command.approved = true
                self.appendItem(command, to: taskID)
                await self.pause(1.5)
                guard !Task.isCancelled else { return }
                command.status = "completed"
                command.exitCode = 0
                self.replaceItem(command, in: taskID)
                await self.stream("All **12** migration tests pass. The index now uses the new schema, and old rows are read through the compatibility view.",
                                  id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            } else if let note {
                await self.stream("Okay, I won't run the tests. You said: “\(note)”. I'll do that instead.",
                                  id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            } else {
                await self.stream("Okay, I won't run the tests. The migration is written but not verified; run `swift test --filter Migration` when you're ready.",
                                  id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            }
            guard !Task.isCancelled else { return }
            self.finishTurn(taskID, turnID: turnID, status: "completed")
        }
    }

    /// A new request in the approval or question task, as after the person asked again on the Mac.
    private func askAgain(_ taskID: String) {
        guard tasks[taskID]?.task.running == false else { return }
        counter += 1
        let turnID = "again-\(counter)"
        if taskID == ID.plan {
            let requestID = "toolu_fixture_plan_\(counter)"
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Plan the cache rewrite again"),
                Self.turnItem(turnID, running: true, waiting: true),
                Self.planReview(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .approval)
        } else if taskID == ID.form || taskID == ID.secret {
            let again = taskID == ID.form ? Self.formTurns(now: Date()) : Self.secretTurns(now: Date())
            var turn = again[0]
            let requestID = "\(taskID == ID.form ? "form" : "secret")_fixture_\(counter)"
            turn = RemoteTurn(id: turnID, items: turn.items.map { item in
                var item = item
                item.turnId = turnID
                if item.kind == .approval { item.id = "req:\(requestID)"; item.requestId = requestID }
                if item.kind == .turn { item.id = "turn:\(turnID)" }
                if item.kind == .user { item.id = "i:\(turnID)-user" }
                return item
            })
            tasks[taskID]?.turns.append(turn)
            tasks[taskID]?.pendingRequest = (requestID, .input)
        } else if taskID == ID.handoff {
            let requestID = "handoff_fixture_\(counter)"
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Publish the release notes again"),
                Self.turnItem(turnID, running: true, waiting: true),
                Self.handoff(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .input)
        } else if taskID == ID.question {
            let requestID = "toolu_fixture_question_\(counter)"
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Pick a name for the 1.0 release, again"),
                Self.turnItem(turnID, running: true, waiting: true),
                Self.question(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .input)
        } else {
            let requestID = "toolu_fixture_\(counter)"
            var edit = Self.activity(turnID, "edit-\(counter)", "Edited SessionRepository.swift", "completed")
            edit.activity = "fileChange"
            edit.additions = 4
            edit.deletions = 2
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Run the migration tests again"),
                Self.turnItem(turnID, running: true, waiting: true),
                edit,
                Self.approval(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .approval)
        }
        tasks[taskID]?.task.running = true
        touch(taskID)
    }

    private func streamRelease() async {
        guard tasks[ID.streaming]?.task.running == false else { return }
        counter += 1
        let turnID = "release-\(counter)"
        tasks[ID.streaming]?.turns.append(RemoteTurn(id: turnID, items: [
            Self.user(turnID, counter > 1 ? "Build the release bundle again" : "Build the release bundle and summarize what changed"),
            Self.turnItem(turnID, running: true)
        ]))
        tasks[ID.streaming]?.task.running = true
        touch(ID.streaming)
        scripts[ID.streaming] = Task {
            var command = Self.activity(turnID, "build-\(turnID)", "Running swift build -c release", "running")
            command.activity = "command"
            self.appendItem(command, to: ID.streaming)
            await self.stream(Self.releaseNotes, id: "i:\(turnID)-answer", turnID: turnID, in: ID.streaming, wordDelay: 0.12)
            guard !Task.isCancelled else { return }
            command.title = "Ran swift build -c release"
            command.status = "completed"
            command.exitCode = 0
            self.replaceItem(command, in: ID.streaming)
            self.finishTurn(ID.streaming, turnID: turnID, status: "completed")
        }
    }

    /// The stop button: the running script ends, what ran stops, a waiting request expires, and the
    /// turn ends interrupted; a message queued behind it is taken next unless the caller sends its own.
    private func stop(_ taskID: String, takingQueue: Bool = true) {
        scripts[taskID]?.cancel()
        scripts[taskID] = nil
        guard var turn = tasks[taskID]?.turns.last else { return }
        for index in turn.items.indices {
            if turn.items[index].streaming == true { turn.items[index].streaming = nil }
            if turn.items[index].kind == .activity, turn.items[index].status == "running" { turn.items[index].status = "stopped" }
            if turn.items[index].kind == .approval, turn.items[index].status == "pending" {
                turn.items[index].status = "expired"
                turn.items[index].options = nil
                turn.items[index].choices = nil
                turn.items[index].formFields = nil
                turn.items[index].macNote = nil
                turn.items[index].moreOnMac = nil
                turn.items[index].inWork = true
            }
        }
        let lastIndex = (tasks[taskID]?.turns.count ?? 1) - 1
        tasks[taskID]?.turns[lastIndex] = turn
        tasks[taskID]?.pendingRequest = nil
        finishTurn(taskID, turnID: turn.id, status: "interrupted", takingQueue: takingQueue)
    }

    /// Writes `text` into an answer a few words at a time.
    private func stream(_ text: String, id: String, turnID: String, in taskID: String, wordDelay: Double = 0.06) async {
        var item = RemoteItem(id: id, turnId: turnID, kind: .assistant)
        item.role = "answer"
        item.text = ""
        item.streaming = true
        appendItem(item, to: taskID)
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            await pause(wordDelay)
            guard !Task.isCancelled else { return }
            item.text = (item.text ?? "") + (index == 0 ? "" : " ") + word
            replaceItem(item, in: taskID)
        }
        item.streaming = nil
        replaceItem(item, in: taskID)
    }

    /// Ends the turn. A message queued behind it is taken next; otherwise the approval, question and
    /// release tasks start over 30 seconds later, so each can be tried again.
    private func finishTurn(_ taskID: String, turnID: String, status: String, takingQueue: Bool = true) {
        guard var entry = tasks[taskID], let index = entry.turns.firstIndex(where: { $0.id == turnID }),
              let header = entry.turns[index].items.firstIndex(where: { $0.kind == .turn }) else { return }
        var item = entry.turns[index].items[header]
        item.status = status
        item.progress = nil
        let completedAt = RemoteJSON.milliseconds(Date())
        item.completedAt = completedAt
        item.durationMs = item.startedAt.map { completedAt - $0 }
        item.foldsWork = entry.turns[index].items.contains { $0.inWork == true }
        item.workCount = entry.turns[index].items.filter { $0.inWork == true }.count
        entry.turns[index].items[header] = item
        entry.task.running = false
        entry.task.unread = true
        tasks[taskID] = entry
        touch(taskID)
        scripts[taskID] = nil
        if takingQueue, let next = tasks[taskID]?.queue.first {
            tasks[taskID]?.queue.removeFirst()
            startReply(to: next.text ?? "", in: taskID)
            return
        }
        guard takingQueue else { return }
        switch taskID {
        case ID.approval, ID.question, ID.plan, ID.handoff, ID.form, ID.secret: later(taskID, after: 30) { await $0.askAgain(taskID) }
        case ID.streaming: later(taskID, after: 30) { await $0.streamRelease() }
        default: break
        }
    }

    private func later(_ taskID: String, after seconds: Double, _ action: @escaping @Sendable (RemoteFixtureBridge) async -> Void) {
        timers[taskID]?.cancel()
        timers[taskID] = Task {
            await self.pause(seconds)
            guard !Task.isCancelled else { return }
            self.clearTimer(taskID)
            await action(self)
        }
    }

    private func clearTimer(_ taskID: String) {
        timers[taskID] = nil
    }

    private func appendItem(_ item: RemoteItem, to taskID: String) {
        guard var turn = tasks[taskID]?.turns.last, turn.id == item.turnId else { return }
        if let header = turn.items.firstIndex(where: { $0.kind == .turn }) {
            turn.items[header].progress = nil
        }
        turn.items.append(item)
        let lastIndex = (tasks[taskID]?.turns.count ?? 1) - 1
        tasks[taskID]?.turns[lastIndex] = turn
        touch(taskID)
    }

    private func replaceItem(_ item: RemoteItem, in taskID: String) {
        guard let turns = tasks[taskID]?.turns,
              let turn = turns.firstIndex(where: { $0.id == item.turnId }),
              let index = turns[turn].items.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[taskID]?.turns[turn].items[index] = item
        touch(taskID)
    }

    private func touch(_ taskID: String) {
        tasks[taskID]?.task.lastActivityAt = RemoteJSON.milliseconds(Date())
        refreshState(taskID)
        changed(taskID)
    }

    private func refreshState(_ taskID: String) {
        guard let entry = tasks[taskID] else { return }
        tasks[taskID] = Self.withState(entry)
    }

    /// The task's attention, mark and request as the Mac's sidebar would read them. A turn waiting
    /// on a request is still running, so the stop button applies, as on the Mac.
    private static func withState(_ entry: Entry) -> Entry {
        var entry = entry
        let failed = entry.turns.last?.items.contains { $0.kind == .error } == true
        let limited = entry.turns.last?.items.contains { $0.kind == .error && $0.errorKind == "usageLimit" } == true
        if let request = entry.pendingRequest {
            entry.task.running = true
            entry.task.attention = .waiting
            entry.task.pendingRequest = request.kind
            entry.task.indicator = request.kind == .input ? .needsInput : .awaitingApproval
        } else if entry.task.running {
            entry.task.attention = .active
            entry.task.pendingRequest = nil
            entry.task.indicator = .running
        } else {
            entry.task.attention = entry.task.unread ? .unread : .idle
            entry.task.pendingRequest = nil
            entry.task.indicator = limited ? .usageLimit : failed ? .failed : entry.task.unread ? .unread : nil
        }
        return entry
    }

    private func changed(_ taskID: String) {
        handler?(.tasks)
        handler?(.conversation(taskID))
        // A schedule shows whether the task of its latest run still works.
        if schedules.contains(where: { $0.latestTaskID == taskID }) { handler?(.schedules) }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / speed))
    }

    // MARK: - Fixture schedules (§15.21)

    /// Every morning, with a run that started the crash report task; a paused one that continues the footer task;
    /// one that turned itself off after three failed starts; and a one-off that ran in Chats.
    private static func schedules(now: Date) -> [Schedule] {
        let calendar = Calendar.current
        func latest(_ hour: Int, daysBack: Int = 0) -> Date {
            let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
            let slot = today > now ? calendar.date(byAdding: .day, value: -1, to: today) ?? today : today
            return calendar.date(byAdding: .day, value: -daysBack, to: slot) ?? slot
        }
        let failure = "The iOS Simulator runtime is not installed."
        return [
            Schedule(id: ID.morningSchedule, name: "Summarize new crash reports",
                     prompt: "Summarize the crash reports that came in overnight.", when: .daily(hour: 9, minute: 0),
                     destination: .newTask(project: ID.website, harness: .codex),
                     runs: [Schedule.Run(at: latest(9), outcome: .started, taskID: ID.history)]),
            Schedule(id: ID.footerSchedule, name: "Check the footer links", prompt: "Check the footer links again.",
                     when: .weekdays(hour: 18, minute: 0), destination: .continueTask(ID.idle), enabled: false,
                     runs: [Schedule.Run(at: latest(18, daysBack: 1), outcome: .started, taskID: ID.idle)]),
            Schedule(id: ID.screenshotsSchedule, name: "Nightly screenshots", prompt: "Regenerate the App Store screenshots.",
                     when: .daily(hour: 2, minute: 0), destination: .newTask(project: ID.website, harness: .claude), enabled: false,
                     stop: .repeatedFailures, failures: 3, failure: failure,
                     runs: (0..<3).map { Schedule.Run(at: latest(2, daysBack: $0), outcome: .failed, reason: "Could not start: \(failure)") }),
            Schedule(id: ID.reminderSchedule, name: "Weekend trip reminder", prompt: "Remind me what is left for the weekend trip.",
                     when: .once(latest(17, daysBack: 1)), destination: .newTask(project: "chats", harness: .claude),
                     enabled: false, stop: .finished,
                     runs: [Schedule.Run(at: latest(17, daysBack: 1), outcome: .started, taskID: ID.chat)])
        ]
    }

    private static func isOnce(_ schedule: Schedule) -> Bool {
        if case .once = schedule.when { return true }
        return false
    }

    /// The next time it runs on its own: nil while it is off, and for a one-off whose moment passed.
    private static func nextRun(of schedule: Schedule, after now: Date) -> Date? {
        guard schedule.enabled else { return nil }
        let calendar = Calendar.current
        switch schedule.when {
        case let .once(date):
            return date > now ? date : nil
        case let .daily(hour, minute):
            return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        case let .weekdays(hour, minute):
            var next = now
            for _ in 0..<8 {
                guard let candidate = calendar.nextDate(after: next, matching: DateComponents(hour: hour, minute: minute),
                                                        matchingPolicy: .nextTime) else { return nil }
                if !calendar.isDateInWeekend(candidate) { return candidate }
                next = candidate
            }
            return nil
        }
    }

    /// The Mac's words for when it runs, in English.
    private static func whenText(_ when: Schedule.When, now: Date) -> String {
        func time(_ hour: Int, _ minute: Int) -> String {
            let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        switch when {
        case let .daily(hour, minute): return "Every day at \(time(hour, minute))"
        case let .weekdays(hour, minute): return "Weekdays at \(time(hour, minute))"
        case let .once(date): return "Once, \(moment(date, now: now))"
        }
    }

    /// The Mac's status line: when it runs next, or why it does not.
    private static func status(_ schedule: Schedule, next: Date?, now: Date) -> String {
        if schedule.starting { return "Starting a run…" }
        switch schedule.stop {
        case .repeatedFailures?: return "Turned off after 3 failed starts"
        case .finished?: return "Ran once"
        case nil: break
        }
        guard schedule.enabled else { return "Paused" }
        return next.map { "Next run \(moment($0, now: now))" } ?? "No next run"
    }

    /// "Today at 9:00 AM", "Sat 9:00 AM" within the week, else the date, as the Mac writes a moment.
    private static func moment(_ date: Date, now: Date, relative: Bool = true) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if relative, (-1...1).contains(days) {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        } else if relative, (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        }
        return formatter.string(from: date)
    }

    // MARK: - Fixture content

    private enum Harness: CaseIterable {
        case claude
        case codex
        case opencode

        init?(id: String) {
            guard let harness = Self.allCases.first(where: { $0.id == id }) else { return nil }
            self = harness
        }

        var id: String {
            switch self {
            case .claude: "claude-code"
            case .codex: "codex"
            case .opencode: "opencode"
            }
        }

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            }
        }

        var acceptsImages: Bool { self != .opencode }
        var steers: Bool { self != .opencode }
        var option: RemoteHarnessOption {
            RemoteHarnessOption(harness: id, harnessName: name, acceptsImages: acceptsImages ? true : nil,
                                acceptsFiles: acceptsImages ? true : nil)
        }
    }

    private static func task(_ id: String, _ title: String, _ harness: Harness, _ project: String, _ at: Int64,
                             unread: Bool = false, parent: String? = nil) -> RemoteTask {
        var task = RemoteTask(id: id, title: title, harness: harness.id, harnessName: harness.name, projectId: project,
                              attention: .idle, unread: unread, lastActivityAt: at, parentTaskId: parent)
        task.acceptsImages = harness.acceptsImages ? true : nil
        task.acceptsFiles = harness.acceptsImages ? true : nil
        task.steers = harness.steers ? true : nil
        return task
    }

    /// The new-task screen's settings for a harness, as the Mac's menus name them (§15.16).
    private static func settings(for harness: Harness) -> [RemoteSetting] {
        typealias Choice = RemoteSetting.Choice
        switch harness {
        case .claude:
            return [
                RemoteSetting(id: "model", name: "Model", value: "opus", choices: [
                    Choice(value: "opus", name: "Opus 5.5", description: "Most capable for complex work"),
                    Choice(value: "sonnet", name: "Sonnet 5.5", description: "Best for everyday tasks"),
                    Choice(value: "haiku", name: "Haiku 5.5", description: "Fastest for quick answers")]),
                RemoteSetting(id: "effort", name: "Effort", value: "high", choices: ["low", "medium", "high", "xhigh", "max"].map {
                    Choice(value: $0, name: $0 == "xhigh" ? "Extra high" : $0.prefix(1).uppercased() + $0.dropFirst())
                }),
                RemoteSetting(id: "permissionMode", name: "Permissions", value: "default", choices: [
                    Choice(value: "default", name: "Manual"), Choice(value: "acceptEdits", name: "Accept edits"),
                    Choice(value: "plan", name: "Plan"), Choice(value: "auto", name: "Auto")])
            ]
        case .codex:
            return [
                RemoteSetting(id: "model", name: "Model", value: "gpt-6", choices: [
                    Choice(value: "gpt-6", name: "GPT-6"), Choice(value: "gpt-6-astra", name: "GPT-6 Astra")]),
                RemoteSetting(id: "reasoningEffort", name: "Reasoning effort", value: "high",
                              choices: ["low", "medium", "high", "xhigh"].map {
                                  Choice(value: $0, name: $0 == "xhigh" ? "Extra high" : $0.prefix(1).uppercased() + $0.dropFirst())
                              })
            ]
        case .opencode:
            return []
        }
    }

    /// A task's composer settings, as the Mac's bottom row names them (§15.23): its permissions, then the model menu.
    private static func taskSettings(for harness: Harness) -> [RemoteSetting] {
        typealias Choice = RemoteSetting.Choice
        let menu = settings(for: harness).filter { $0.id != "permissionMode" }.map { setting in
            var setting = setting
            setting.role = setting.id == "model" ? "model" : "effort"
            return setting
        }
        switch harness {
        case .claude:
            let bypass = RemoteSetting.Confirmation(
                title: "Bypass permission checks?", message: "Claude Code will change files and run commands without asking.",
                button: "Use bypass permissions")
            return [RemoteSetting(id: "permissionMode", name: "Permission mode", value: "default", choices: [
                Choice(value: "default", name: "Manual"), Choice(value: "acceptEdits", name: "Accept edits"),
                Choice(value: "plan", name: "Plan"), Choice(value: "auto", name: "Auto"),
                Choice(value: "bypassPermissions", name: "Bypass permissions", confirm: bypass)], role: "permission")] + menu
        case .codex:
            let full = RemoteSetting.Confirmation(
                title: "Allow full access?",
                message: "Codex will run commands, use the internet, and create and edit files anywhere on this Mac without asking.",
                button: "Allow full access")
            return [RemoteSetting(id: "runLocation", name: "Permissions", value: "automatic", choices: [
                Choice(value: "automatic", name: "Default"), Choice(value: "readOnly", name: "Read-only"),
                Choice(value: "workspaceWrite", name: "Workspace write"),
                Choice(value: "dangerFullAccess", name: "Full access", confirm: full)], role: "permission")] + menu
        case .opencode:
            var permission = RemoteSetting(id: "permissions", name: "Permissions", value: "", choices: [], role: "permission")
            permission.title = "On request"
            permission.note = "Protected actions ask before they run. Approve or deny them from the request card."
            return [permission]
        }
    }

    /// The limit card's list for the plan limit task: its account now, one that shares its history
    /// with most of its limit left, and one signed out (§15.17).
    private static func accounts(current: String) -> [RemoteAccount] {
        let reset = RemoteJSON.milliseconds(Date().addingTimeInterval(2 * 3600))
        let week = RemoteJSON.milliseconds(Date().addingTimeInterval(4 * 86_400))
        var accounts = [
            RemoteAccount(id: "fixture-work", name: "work@example.test", detail: "Claude Max",
                          usage: [.init(label: "5-hour", usedPercent: 12, resetsAt: reset),
                                  .init(label: "Weekly", usedPercent: 40, resetsAt: week)]),
            RemoteAccount(id: "fixture-home", name: "home@example.test", detail: "Claude Pro",
                          usage: [.init(label: "5-hour", usedPercent: 100, resetsAt: reset),
                                  .init(label: "Weekly", usedPercent: 71, resetsAt: week)]),
            RemoteAccount(id: "fixture-old", name: "old@example.test", detail: "Signed out")
        ]
        for index in accounts.indices {
            let isCurrent = accounts[index].id == current
            accounts[index].current = isCurrent ? true : nil
            accounts[index].available = !isCurrent && accounts[index].id != "fixture-old" ? true : nil
        }
        return accounts
    }

    private static func user(_ turnID: String, _ text: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-user", turnId: turnID, kind: .user)
        item.text = text
        return item
    }

    private static func turnItem(_ turnID: String, running: Bool, waiting: Bool = false, durationMs: Int64? = nil,
                                 now: Date = Date()) -> RemoteItem {
        var item = RemoteItem(id: "turn:\(turnID)", turnId: turnID, kind: .turn)
        item.status = running ? "running" : "completed"
        item.startedAt = RemoteJSON.milliseconds(now) - (durationMs ?? 0)
        if running {
            item.progress = waiting ? nil : "thinking"
        } else {
            item.completedAt = RemoteJSON.milliseconds(now)
            item.durationMs = durationMs
        }
        item.foldsWork = !running
        return item
    }

    private static func activity(_ turnID: String, _ key: String, _ title: String, _ status: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-\(key)", turnId: turnID, kind: .activity)
        item.inWork = true
        item.activity = "tool"
        item.title = title
        item.status = status
        if title.hasPrefix("Edited") || title.hasPrefix("Ran") || title.hasPrefix("Running") { item.hasDetail = true }
        return item
    }

    private static func answer(_ turnID: String, _ text: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-answer", turnId: turnID, kind: .assistant)
        item.role = "answer"
        item.text = text
        return item
    }

    private static func approval(_ turnID: String, requestID: String) -> RemoteItem {
        var item = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        item.requestId = requestID
        item.requestKind = "approval"
        item.status = "pending"
        item.title = "Bash"
        item.command = "swift test --filter Migration"
        item.detail = "Run the migration tests"
        item.options = [RemoteApprovalAnswer.allowOnce.rawValue, RemoteApprovalAnswer.allowForSession.rawValue,
                        RemoteApprovalAnswer.deny.rawValue]
        item.optionTitles = [RemoteApprovalAnswer.allowForSession.rawValue: "Allow for session"]
        item.moreOnMac = true
        item.macNote = "Only on the Mac: Always allow in this project (saved to .claude/settings.local.json)"
        item.choices = [
            RemoteChoice(id: "0", title: "Deny", role: "destructive"),
            RemoteChoice(id: "1", title: "Always allow in this project (saved to .claude/settings.local.json)", role: "secondary",
                         standing: true),
            RemoteChoice(id: "2", title: "Allow for session", role: "secondary"),
            RemoteChoice(id: "3", title: "Allow", role: "primary")
        ]
        return item
    }

    private static func formTurns(now: Date) -> [RemoteTurn] {
        let turnID = "repo-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-50))
        var item = RemoteItem(id: "req:form_fixture_1", turnId: turnID, kind: .approval)
        item.requestId = "form_fixture_1"
        item.requestKind = "form"
        item.status = "pending"
        item.title = "GitHub"
        item.detail = "Create a repository for the new service."
        item.questions = ["Repository", "Private", "Team"]
        var repo = RemoteFormField(id: "repo", label: "Repository", type: "text")
        repo.required = true
        repo.maxLength = 100
        repo.description = "owner/name"
        var isPrivate = RemoteFormField(id: "private", label: "Private", type: "boolean")
        isPrivate.default = .flag(true)
        var team = RemoteFormField(id: "team", label: "Team", type: "choice")
        team.options = [.init(value: "web", title: "Web"), .init(value: "ios", title: "iOS")]
        item.formFields = [repo, isPrivate, team]
        item.choices = [RemoteChoice(id: "0", title: "Decline", role: "destructive"),
                        RemoteChoice(id: "1", title: "Submit", role: "primary")]
        item.options = []
        item.moreOnMac = true
        return [RemoteTurn(id: turnID, items: [user(turnID, "Create a GitHub repository for the billing service"), header, item])]
    }

    private static func secretTurns(now: Date) -> [RemoteTurn] {
        let turnID = "db-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-70))
        var item = RemoteItem(id: "req:secret_fixture_1", turnId: turnID, kind: .approval)
        item.requestId = "secret_fixture_1"
        item.requestKind = "form"
        item.status = "pending"
        item.title = "Question"
        item.questions = ["What is the staging database password?"]
        item.questionSteps = [RemoteQuestionStep(id: "password", header: "Password", text: "What is the staging database password?",
                                                 options: [], custom: true, secret: true)]
        item.options = [RemoteProtocol.answerSecretOption]
        item.moreOnMac = true
        item.macNote = "This question takes a secret answer. Answer it on the Mac."
        return [RemoteTurn(id: turnID, items: [user(turnID, "Connect the app to the staging database"), header, item])]
    }

    private static func handoff(_ turnID: String, requestID: String) -> RemoteItem {
        var item = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        item.requestId = requestID
        item.requestKind = "browserHandoff"
        item.status = "pending"
        item.title = "github.com"
        item.detail = "Sign in to GitHub so I can publish the release notes."
        item.options = [RemoteHandoffAnswer.done.rawValue, RemoteHandoffAnswer.decline.rawValue]
        return item
    }

    private static func handoffTurns(now: Date) -> [RemoteTurn] {
        let turnID = "notes-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-90))
        var open = activity(turnID, "open", "Opened github.com/acme/web/releases/new", "completed")
        open.activity = "tool"
        return [RemoteTurn(id: turnID, items: [user(turnID, "Publish the 1.0 release notes on GitHub"), header, open,
                                               handoff(turnID, requestID: "handoff_fixture_1")])]
    }

    private static func limitTurn(now: Date) -> RemoteTurn {
        let turnID = "guide-1"
        var header = turnItem(turnID, running: false, durationMs: 340_000, now: now.addingTimeInterval(-480))
        header.status = "failed"
        header.workCount = 1
        var limit = RemoteItem(id: "outcome:\(turnID)", turnId: turnID, kind: .error)
        limit.errorKind = "usageLimit"
        limit.title = "You've hit your session limit"
        limit.message = "Resets in 2 hours"
        limit.resetsAt = RemoteJSON.milliseconds(now.addingTimeInterval(2 * 3600))
        limit.options = ["continueWithAccount", "autoContinue"]
        return RemoteTurn(id: turnID, items: [
            user(turnID, "Write a migration guide for the new session index"), header, limit,
            activity(turnID, "read", "Read docs/MIGRATION.md", "completed")
        ])
    }

    private static func finishedTurn(_ turnID: String, prompt: String, answer text: String, now: Date,
                                     suggestion: Bool = false) -> RemoteTurn {
        var header = turnItem(turnID, running: false, durationMs: 48_000, now: now.addingTimeInterval(-600))
        header.workCount = 2
        var items = [
            user(turnID, prompt), header,
            activity(turnID, "search", "Searched href=\"/doc\"", "completed"),
            activity(turnID, "read", "Read Footer.tsx", "completed"),
            answer(turnID, text)
        ]
        if suggestion {
            var chip = RemoteItem(id: "i:\(turnID)-suggestion", turnId: turnID, kind: .activity)
            chip.activity = "taskSuggestion"
            chip.title = "Add a link checker to CI"
            chip.detail = "Run a link check on every pull request so footer links cannot break again."
            chip.status = "completed"
            chip.suggestionId = "task_fixture1"
            chip.suggestionState = "open"
            chip.options = [RemoteSuggestionAction.start.rawValue, RemoteSuggestionAction.here.rawValue,
                            RemoteSuggestionAction.dismiss.rawValue]
            items.append(chip)
        }
        return RemoteTurn(id: turnID, items: items)
    }

    private static func planReviewTurns(now: Date) -> [RemoteTurn] {
        let turnID = "cache-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-60))
        return [RemoteTurn(id: turnID, items: [user(turnID, "Plan how to replace the session cache"), header,
                                               activity(turnID, "read", "Read SessionStore.swift", "completed"),
                                               planReview(turnID, requestID: "toolu_fixture_plan")])]
    }

    private static func planReview(_ turnID: String, requestID: String) -> RemoteItem {
        var item = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        item.requestId = requestID
        item.requestKind = "planReview"
        item.status = "pending"
        item.title = "Plan"
        item.text = """
        ## Replace the session cache

        1. Move reads behind `SessionStore.read`.
        2. Write through to SQLite and drop the JSON mirror.
        3. Migrate on first launch and keep a backup of the old file.
        """
        item.options = [RemoteProtocol.keepPlanningOption, RemoteProtocol.approvePlanOption]
        return item
    }

    private static let samplePatch = """
    @@ -12,7 +12,9 @@ struct SessionRepository {
         func load() throws -> [Session] {
    -        let data = try Data(contentsOf: legacyURL)
    -        return try decoder.decode([Session].self, from: data)
    +        guard let rows = try index.rows() else { return [] }
    +        return rows.map(Session.init(row:))
         }
    +
    +    private let index: SessionIndex
     }
    """

    private static func sampleOutput(for title: String) -> String {
        if title.contains("swift test") {
            return "Building for debugging...\nTest Suite 'MigrationTests' started.\n" +
                (1...12).map { "Test Case 'MigrationTests.test\($0)' passed (0.0\($0 % 10) seconds)." }.joined(separator: "\n") +
                "\nExecuted 12 tests, with 0 failures (0 unexpected) in 0.31 seconds"
        }
        return "Compiling Yardlet (412 sources)\nLinking Yardlet\nBuild complete! (128.4s)"
    }

    private static func approvalTurns(now: Date) -> [RemoteTurn] {
        let first = finishedTurn("migration-0", prompt: "Explain how the session index is stored",
                                 answer: "The index is one SQLite file, `session-index.sqlite3`, with one row per task.", now: now)
        let turnID = "migration-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-40))
        var edit = activity(turnID, "edit", "Edited SessionRepository.swift", "completed")
        edit.activity = "fileChange"
        edit.additions = 42
        edit.deletions = 7
        var note = RemoteItem(id: "i:\(turnID)-note", turnId: turnID, kind: .assistant)
        note.role = "commentary"
        note.inWork = true
        note.text = "Now I'll run the migration tests."
        return [first, RemoteTurn(id: turnID, items: [
            user(turnID, "Migrate the index to the new schema and run the migration tests"),
            header,
            activity(turnID, "read", "Read SessionRepository.swift", "completed"),
            edit, note,
            approval(turnID, requestID: "toolu_fixture_1")
        ])]
    }

    private static func questionTurns(now: Date) -> [RemoteTurn] {
        let turnID = "name-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-20))
        return [RemoteTurn(id: turnID, items: [user(turnID, "Pick a name for the 1.0 release"), header,
                                               question(turnID, requestID: "toolu_fixture_question")])]
    }

    private static func question(_ turnID: String, requestID: String) -> RemoteItem {
        var question = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        question.requestId = requestID
        question.requestKind = "question"
        question.status = "pending"
        question.title = "Question"
        question.questions = ["Which name should the release use?"]
        question.questionSteps = [
            RemoteQuestionStep(id: "Which name should the release use?", header: "Name", text: "Which name should the release use?",
                               options: [.init(label: "Juniper", description: "Short and easy to say"),
                                         .init(label: "Larch", description: "Keeps the tree names"),
                                         .init(label: "Hornbeam")],
                               custom: true)
        ]
        question.options = [RemoteProtocol.answerOption]
        return question
    }

    private static func planTurn(now: Date) -> RemoteTurn {
        let turnID = "trip-1"
        var plan = RemoteItem(id: "plan:\(turnID)", turnId: turnID, kind: .plan)
        plan.inWork = true
        plan.explanation = "Book the cabin first; it sells out."
        plan.steps = [
            RemotePlanStep(text: "Book the cabin", status: "completed"),
            RemotePlanStep(text: "Pack the hiking gear", status: "inProgress"),
            RemotePlanStep(text: "Check the trail conditions", status: "pending")
        ]
        var header = turnItem(turnID, running: false, durationMs: 12_000, now: now.addingTimeInterval(-1800))
        header.workCount = 1
        return RemoteTurn(id: turnID, items: [user(turnID, "Plan a weekend trip to the mountains"), header, plan,
                                              answer(turnID, "Here's the plan. The cabin is booked for Saturday.")])
    }

    private static func failedTurn(now: Date) -> RemoteTurn {
        let turnID = "shots-1"
        var header = turnItem(turnID, running: false, durationMs: 9_000, now: now.addingTimeInterval(-1200))
        header.status = "failed"
        header.foldsWork = false
        var error = RemoteItem(id: "outcome:\(turnID)", turnId: turnID, kind: .error)
        error.errorKind = "error"
        error.title = "The screenshot script failed"
        error.message = "scripts/screenshots.sh exited with code 1: Simulator not found."
        error.recoverable = true
        return RemoteTurn(id: turnID, items: [user(turnID, "Regenerate the App Store screenshots"), header, error])
    }

    private static func historyTurn(_ number: Int, now: Date) -> RemoteTurn {
        let turnID = "crash-\(number)"
        var header = turnItem(turnID, running: false, durationMs: Int64(20_000 + number * 1_000),
                              now: now.addingTimeInterval(Double(number - 31) * 900))
        header.workCount = 1
        var command = activity(turnID, "grep", "Searched crash-\(number).ips for EXC_BAD_ACCESS", "completed")
        command.activity = "command"
        command.exitCode = 0
        return RemoteTurn(id: turnID, items: [
            user(turnID, "Summarize crash report \(number)"), header, command,
            answer(turnID, "Crash \(number): a nil dereference in `TaskSidebar.row(for:)` while a task was being archived."
                   + (number == 30 ? " I put the summary in crash-summary.pdf on the Desktop, the chart in "
                      + "`reports/crash-chart.png` and my notes in `reports/crash-notes.txt`." : ""))
        ])
    }

    private static let footerAnswer = """
    Two footer links 404:

    | Link | Points at | Should be |
    |---|---|---|
    | Docs | `/doc` | `/docs` |
    | Blog | `/blog/` | `/blog` |
    """

    private static let releaseNotes = """
    ## Release 1.0

    The release bundle is building. What changed since 0.9:

    - **Remote control:** a phone on your tailnet can follow tasks, answer approvals and stop turns.
    - **Menu bar:** running, unread and pinned tasks, with the sidebar's state dots.
    - **Diff comments:** comments on diff lines travel with the next message.

    Signing and notarization run after the build; I'll report when the bundle is ready.
    """
}
