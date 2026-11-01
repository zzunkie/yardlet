import Foundation
import XCTest
@testable import NativeHarnessClient

/// Schedules in the app: a run is a task started through the new-task path (with a stand-in
/// harness, so no runtime or model is contacted), skipped while the previous run still works,
/// sent to its task when it continues one, announced when it was missed, kept off an account that is
/// nearly spent, paused and resumed, turned off after failed starts, kept across a relaunch, and
/// imported once.
@MainActor
final class ScheduledTaskTests: XCTestCase {
    private var root: URL!
    private var seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "schedules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        seoul.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeModel(adapter: SuggestionRecordingAdapter = SuggestionRecordingAdapter(),
                           notifications: any SystemNotificationCenter = ScheduleNotificationRecorder(),
                           repository: any ScheduledTaskRepository = InMemoryScheduledTaskRepository(),
                           connections: ProviderConnectionStore? = nil,
                           clock: Clock) -> AppModel {
        let defaults = SuggestionVolatileDefaults()
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        // An executable that exists stands in for each runtime; the stand-in harness never runs it.
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .openCode)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: runtimes,
            registry: HarnessRegistry { _, _ in adapter },
            connections: connections,
            preferences: defaults,
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            scheduleRepository: repository,
            chatWorkspaceHome: root.appending(path: "home", directoryHint: .isDirectory),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: notifications,
            restoresIndexOnLaunch: false)
        model.scheduledTasks.now = { clock.now }
        model.scheduledTasks.calendar = { [seoul] in seoul }
        return model
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func dailySchedule(project: Project, prompt: String = "Summarize the open issues.") -> ScheduledTask {
        ScheduledTask(name: "Issue digest", prompt: prompt, trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                      destination: ScheduleDestination(
                          harness: .openCode, workspacePath: ProjectSidebarPresentation.normalizedPath(for: project.primaryRoot),
                          projectID: project.id))
    }

    // MARK: - A run is a task

    func testARunStartsATaskThroughTheNewTaskPathBesideThePersonsWork() async throws {
        let adapter = SuggestionRecordingAdapter()
        let clock = Clock(date(16, 20))
        let model = makeModel(adapter: adapter, clock: clock)
        let project = model.projects.ensureProject(forRoot: try folder("issues"), name: "Issues")
        let mine = try await model.store.createSession(
            harness: .openCode, workspaceURL: project.primaryRoot, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "My own work", projectID: project.id)
        XCTAssertEqual(model.store.selectedSessionID, mine.id)
        model.scheduledTasks.create(dailySchedule(project: project))

        clock.now = date(17, 9, 0, 30)
        await model.scheduledTasks.checkDue()

        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        let run = try XCTUnwrap(schedule.state.runs.first)
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.trigger, .scheduled)
        XCTAssertEqual(run.slot, date(17, 9))
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == run.taskID })
        XCTAssertTrue(task.title.hasPrefix("Issue digest · "), task.title)
        XCTAssertEqual(task.titleOrigin, .manual, "The run keeps the schedule's name")
        XCTAssertEqual(task.projectID, project.id)
        XCTAssertTrue(Project.isSamePath(task.workspaceURL, project.primaryRoot))
        XCTAssertEqual(model.store.selectedSessionID, mine.id, "A run starts beside the person's work")
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Summarize the open issues."])
        XCTAssertEqual(model.scheduledTasks.schedule(startedTask: task.id)?.id, schedule.id)
        XCTAssertEqual(model.scheduledTasks.scheduledTaskIDs, [task.id])
        await model.shutdown()
    }

    func testASlotWhosePreviousRunIsStillGoingIsSkipped() async throws {
        let adapter = SuggestionRecordingAdapter()
        let clock = Clock(date(16, 20))
        let model = makeModel(adapter: adapter, clock: clock)
        let project = model.projects.ensureProject(forRoot: try folder("issues"))
        model.scheduledTasks.create(dailySchedule(project: project))
        clock.now = date(17, 9)
        await model.scheduledTasks.checkDue()
        let first = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs.first?.taskID)
        try await model.store.updateSession(id: first, status: .running)

        clock.now = date(18, 9)
        await model.scheduledTasks.checkDue()
        var runs = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs)
        XCTAssertEqual(runs.first?.outcome, .skipped)
        XCTAssertEqual(runs.first?.skipReason, .previousRunActive)
        XCTAssertEqual(runs.first?.slot, date(18, 9))
        var prompts = await adapter.prompts
        XCTAssertEqual(prompts.count, 1, "Nothing was sent for the skipped slot")
        await model.scheduledTasks.checkDue()
        XCTAssertEqual(model.scheduledTasks.schedules.first?.state.runs.count, 2, "The skipped slot is not tried again")

        // Waiting on the person counts as still going too.
        try await model.store.updateSession(id: first, status: .waitingForApproval)
        XCTAssertEqual(model.scheduledRunBusyReason(try XCTUnwrap(model.scheduledTasks.schedules.first)), .previousRunActive)

        try await model.store.updateSession(id: first, status: .completed)
        clock.now = date(19, 9)
        await model.scheduledTasks.checkDue()
        runs = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs)
        XCTAssertEqual(runs.first?.outcome, .started)
        XCTAssertNotEqual(runs.first?.taskID, first, "A new task for the new run")
        prompts = await adapter.prompts
        XCTAssertEqual(prompts.count, 2)
        await model.shutdown()
    }

    func testAContinuingScheduleSendsToItsTaskAndWaitsWhileItIsBusy() async throws {
        let adapter = SuggestionRecordingAdapter()
        let clock = Clock(date(16, 20))
        let model = makeModel(adapter: adapter, clock: clock)
        let project = model.projects.ensureProject(forRoot: try folder("issues"))
        let target = try await model.store.createSession(
            harness: .openCode, workspaceURL: project.primaryRoot, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Release watch", projectID: project.id)
        var destination = ScheduleDestination(harness: .openCode)
        destination.mode = .continueTask
        destination.targetTaskID = target.id
        model.scheduledTasks.create(ScheduledTask(name: "Heartbeat", prompt: "Any new failures since last time?",
                                                  trigger: .interval(hours: 2, anchor: date(16, 22), days: []),
                                                  destination: destination))
        let tasksBefore = model.store.sessions.count

        clock.now = date(17, 0, 0, 10)
        await model.scheduledTasks.checkDue()
        let run = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs.first)
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.taskID, target.id)
        XCTAssertEqual(model.store.sessions.count, tasksBefore, "No new task")
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Any new failures since last time?"], "Sent as the person's own message")

        try await model.store.updateSession(id: target.id, status: .running)
        clock.now = date(17, 2, 0, 10)
        await model.scheduledTasks.checkDue()
        let skipped = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs.first)
        XCTAssertEqual(skipped.outcome, .skipped)
        XCTAssertEqual(skipped.skipReason, .targetBusy)
        await model.shutdown()
    }

    func testAMissedRunRunsOnceAndSaysSo() async throws {
        let notifications = ScheduleNotificationRecorder()
        let adapter = SuggestionRecordingAdapter()
        let clock = Clock(date(14, 20))
        let model = makeModel(adapter: adapter, notifications: notifications, clock: clock)
        let project = model.projects.ensureProject(forRoot: try folder("issues"))
        model.scheduledTasks.create(dailySchedule(project: project))

        // Yardlet was closed from the 14th's evening until the 17th at noon.
        clock.now = date(17, 12)
        await model.scheduledTasks.checkDue()
        await model.scheduledTasks.checkDue()
        let runs = try XCTUnwrap(model.scheduledTasks.schedules.first?.state.runs)
        XCTAssertEqual(runs.count, 1, "Three slots passed; one run")
        XCTAssertEqual(runs.first?.trigger, .missed)
        XCTAssertEqual(runs.first?.slot, date(17, 9))
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(notifications.posts.count, 1)
        XCTAssertEqual(notifications.posts.first?.target.sessionID, runs.first?.taskID, "It leads to the run's task")
        XCTAssertTrue(notifications.posts.first?.body.contains("Issue digest") == true)
        await model.shutdown()
    }

    func testTheSubmissionCarriesTheSchedulesChoices() throws {
        let clock = Clock(date(16, 20))
        let model = makeModel(clock: clock)
        let repository = try folder("app")
        let project = model.projects.ensureProject(forRoot: repository, name: "App")
        let parent = UUID()
        var destination = ScheduleDestination(
            harness: .claudeCode, accountID: AccountChoice.nativeID(for: .claudeCode),
            modelChoice: NewTaskModelChoice(model: "claude-opus-5-5", effort: "high", permissionMode: "bypassPermissions"),
            workspacePath: ProjectSidebarPresentation.normalizedPath(for: repository), projectID: project.id,
            startsInNewWorktree: true)
        destination.parentTaskID = parent
        let schedule = ScheduledTask(name: "Nightly", prompt: "  Run the nightly checks.  ",
                                     trigger: .daily(ScheduleTime(hour: 22, minute: 0)), destination: destination)

        let submission = try model.scheduledSubmission(for: schedule, at: date(16, 22)).get()
        XCTAssertEqual(submission.harness, .claudeCode)
        XCTAssertEqual(submission.runtimeURL, URL(filePath: "/usr/bin/true"))
        XCTAssertNil(submission.connection, "The harness's own login")
        XCTAssertEqual(submission.projectID, project.id)
        XCTAssertTrue(submission.startsInNewWorktree)
        XCTAssertEqual(submission.prompt, "Run the nightly checks.")
        XCTAssertEqual(submission.providerOptions, [
            ClaudeLaunchOption.model: "claude-opus-5-5", ClaudeLaunchOption.effort: "high",
            ClaudeLaunchOption.permissionMode: "bypassPermissions",
        ])
        XCTAssertFalse(submission.selectsTask)
        XCTAssertNil(submission.parentTaskID, "A parent that is not in Yardlet is left out")
        XCTAssertEqual(submission.titleOrigin, .manual)
        XCTAssertTrue(submission.title.hasPrefix("Nightly · "))

        var gone = schedule
        gone.destination.workspacePath = root.appending(path: "missing").path
        XCTAssertNotNil(model.scheduledSubmission(for: gone, at: date(16, 22)).failureMessage)
        var unknownAccount = schedule
        unknownAccount.destination.accountID = "no-such-account"
        XCTAssertNotNil(model.scheduledSubmission(for: unknownAccount, at: date(16, 22)).failureMessage)
        var noRuntime = schedule
        noRuntime.destination.harness = .codex
        XCTAssertNotNil(model.scheduledSubmission(for: noRuntime, at: date(16, 22)).failureMessage)
        var chat = schedule
        chat.destination.workspacePath = nil
        let chatSubmission = try model.scheduledSubmission(for: chat, at: date(16, 22)).get()
        XCTAssertNil(chatSubmission.workspaceURL)
        XCTAssertFalse(chatSubmission.startsInNewWorktree, "A chat has no repository for a worktree")
    }

    // MARK: - Accounts

    /// A run whose account is nearly spent starts on the account automatic assignment picks instead, and
    /// its line in the run history and its task's hover card say which and why. A run whose account has
    /// room stays on it. When every account is nearly spent the run starts on the one that frees up
    /// first, where a refusal shows on its task as it did before.
    func testARunWhoseAccountIsNearlySpentStartsOnTheAccountAutomaticAssignmentPicks() async throws {
        let clock = Clock(date(16, 20))
        let accounts = try claudeAccounts(shared: ["work", "roomy"], separate: ["own"])
        let model = makeModel(connections: accounts.store, clock: clock)
        accounts.read("work", used: 0.95)
        accounts.read("roomy", used: 0.1)
        accounts.read("own", used: 0)
        let modelChoice = NewTaskModelChoice(model: "claude-opus-5-5")
        model.scheduledTasks.create(ScheduledTask(name: "Nightly", prompt: "Run the nightly checks.",
            trigger: .daily(ScheduleTime(hour: 22, minute: 0)),
            destination: ScheduleDestination(harness: .claudeCode, accountID: "work", modelChoice: modelChoice)))
        let id = try XCTUnwrap(model.scheduledTasks.schedules.first?.id)
        // Each run's task ends, so the next run is not skipped for it.
        func latestRun() async throws -> (ScheduledTaskRun, SessionRecord) {
            let run = try XCTUnwrap(model.scheduledTasks.schedule(id: id)?.state.runs.first)
            XCTAssertEqual(run.outcome, .started, run.failure ?? "")
            let task = try XCTUnwrap(model.store.sessions.first { $0.id == run.taskID })
            try await model.store.updateSession(id: task.id, status: .completed)
            return (run, task)
        }

        await model.scheduledTasks.runNow(id)
        var (run, task) = try await latestRun()
        XCTAssertEqual(task.connection, accounts["roomy"], "An account with room, not the one left out of automatic assignment")
        XCTAssertEqual(run.account?.accountID, "roomy")
        XCTAssertEqual(run.account?.replacedAccountName, "work@example.test")
        XCTAssertEqual(run.account?.basis, .headroom)
        XCTAssertEqual(model.accountAssignments.assignment(for: task.id), run.account, "The task's hover card says it too")
        let row = try XCTUnwrap(ScheduledRunRow.rows(for: try XCTUnwrap(model.scheduledTasks.schedule(id: id)),
                                                     task: { _ in task }).first)
        let line = try XCTUnwrap(row.switchLine)
        XCTAssertTrue(line.contains("roomy@example.test") && line.contains("work@example.test"), line)
        XCTAssertTrue(row.detailText.hasSuffix(line), row.detailText)
        XCTAssertEqual(model.scheduledTasks.schedule(id: id)?.destination.accountID, "work", "The schedule keeps its own account")

        accounts.read("work", used: 0.5)
        await model.scheduledTasks.runNow(id)
        (run, task) = try await latestRun()
        XCTAssertEqual(task.connection, accounts["work"])
        XCTAssertNil(run.account)
        XCTAssertNil(model.accountAssignments.assignment(for: task.id))

        // Every account is nearly spent: the one that frees up first.
        accounts.read("work", used: 0.95, resetsIn: 4)
        accounts.read("roomy", used: 1, resetsIn: 1)
        await model.scheduledTasks.runNow(id)
        (run, task) = try await latestRun()
        XCTAssertEqual(task.connection, accounts["roomy"])
        XCTAssertEqual(run.account?.basis, .nearlySpent)
        XCTAssertNotNil(run.account?.freesUpAt)
        accounts.read("roomy", used: 1, resetsIn: 5)
        await model.scheduledTasks.runNow(id)
        (run, task) = try await latestRun()
        XCTAssertEqual(task.connection, accounts["work"], "Its own account frees up first")
        XCTAssertNil(run.account)
        await model.shutdown()
    }

    /// A run that continues a Claude task whose account is nearly spent first moves the task to another
    /// account that shares its history, as Continue with another account does, keeping its conversation,
    /// and then sends. With no such account the message goes on the task's own account, as before.
    func testAContinuingRunMovesItsTaskOffANearlySpentAccountFirst() async throws {
        let adapter = SuggestionRecordingAdapter()
        let clock = Clock(date(16, 20))
        let accounts = try claudeAccounts(shared: ["work", "roomy"], separate: ["own"])
        let model = makeModel(adapter: adapter, connections: accounts.store, clock: clock)
        accounts.read("work", used: 0.97)
        accounts.read("roomy", used: 0.2)
        accounts.read("own", used: 0.97)
        let project = try folder("release")
        func continuing(_ account: String) async throws -> (SessionRecord, UUID) {
            let task = try await model.store.createSession(
                harness: .claudeCode, workspaceURL: project, runtimeExecutableURL: accounts.cli,
                title: "Release watch on \(account)", providerSessionID: UUID().uuidString.lowercased(),
                connection: accounts[account])
            var destination = ScheduleDestination(harness: .claudeCode)
            destination.mode = .continueTask
            destination.targetTaskID = task.id
            let schedule = ScheduledTask(name: "Heartbeat \(account)", prompt: "Any new failures since last time?",
                                         trigger: .interval(hours: 2, anchor: date(16, 22), days: []),
                                         destination: destination)
            model.scheduledTasks.create(schedule)
            return (task, schedule.id)
        }

        let (moving, movingSchedule) = try await continuing("work")
        await model.scheduledTasks.runNow(movingSchedule)
        var run = try XCTUnwrap(model.scheduledTasks.schedule(id: movingSchedule)?.state.runs.first)
        XCTAssertEqual(run.outcome, .started, run.failure ?? "")
        let moved = try XCTUnwrap(model.store.sessions.first { $0.id == moving.id })
        XCTAssertEqual(moved.connection, accounts["roomy"])
        XCTAssertEqual(moved.providerSessionID, moving.providerSessionID, "The same conversation goes on")
        XCTAssertEqual(run.account?.accountID, "roomy")
        XCTAssertEqual(run.account?.replacedAccountName, "work@example.test")
        XCTAssertEqual(model.accountAssignments.assignment(for: moving.id), run.account)
        var prompts = await adapter.prompts
        XCTAssertEqual(prompts, ["Any new failures since last time?"], "Sent after the move")

        let (staying, stayingSchedule) = try await continuing("own")
        await model.scheduledTasks.runNow(stayingSchedule)
        run = try XCTUnwrap(model.scheduledTasks.schedule(id: stayingSchedule)?.state.runs.first)
        XCTAssertEqual(run.outcome, .started, run.failure ?? "")
        XCTAssertNil(run.account)
        XCTAssertEqual(model.store.sessions.first { $0.id == staying.id }?.connection, accounts["own"],
                       "No other account shares its history")
        XCTAssertNil(model.errorBySessionID[staying.id])
        prompts = await adapter.prompts
        XCTAssertEqual(prompts.count, 2)
        await model.shutdown()
    }

    // MARK: - The center

    func testPausingStopsRunsAndResumingDoesNotCatchUp() async throws {
        let clock = Clock(date(16, 20))
        let center = ScheduledTaskCenter()
        center.now = { clock.now }
        center.calendar = { [seoul] in seoul }
        var started: [Date?] = []
        center.start = { _, _, slot in
            started.append(slot)
            return .started(taskID: UUID())
        }
        center.create(ScheduledTask(name: "Daily", prompt: "Go.", trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                    destination: ScheduleDestination(harness: .openCode)))
        let id = try XCTUnwrap(center.schedules.first?.id)
        center.setEnabled(false, for: id)
        clock.now = date(17, 9)
        await center.checkDue()
        XCTAssertTrue(started.isEmpty)
        XCTAssertNil(center.nextRun(of: try XCTUnwrap(center.schedule(id: id))))

        clock.now = date(17, 12)
        center.setEnabled(true, for: id)
        await center.checkDue()
        XCTAssertTrue(started.isEmpty, "The slot passed while paused does not run")
        XCTAssertEqual(center.nextRun(of: try XCTUnwrap(center.schedule(id: id))), date(18, 9))
        clock.now = date(18, 9)
        await center.checkDue()
        XCTAssertEqual(started, [date(18, 9)])

        await center.runNow(id)
        XCTAssertEqual(started, [date(18, 9), nil], "Run now runs outside the trigger")
        XCTAssertEqual(center.schedule(id: id)?.state.lastSlot, date(18, 9), "and leaves the next slot as it was")
        XCTAssertEqual(center.schedule(id: id)?.state.runs.first?.trigger, .manual)
    }

    func testThreeFailedStartsTurnTheScheduleOffWithItsReason() async throws {
        let clock = Clock(date(16, 20))
        let center = ScheduledTaskCenter()
        center.now = { clock.now }
        center.calendar = { [seoul] in seoul }
        center.start = { _, _, _ in .failed("Claude Code is not available in Yardlet.") }
        center.create(ScheduledTask(name: "Daily", prompt: "Go.", trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                    destination: ScheduleDestination(harness: .claudeCode)))
        for day in 17...19 {
            clock.now = date(day, 9)
            await center.checkDue()
        }
        let schedule = try XCTUnwrap(center.schedules.first)
        XCTAssertFalse(schedule.isEnabled)
        XCTAssertEqual(schedule.state.stopReason, .repeatedFailures)
        XCTAssertEqual(schedule.state.runs.map(\.failure), Array(repeating: "Claude Code is not available in Yardlet.", count: 3))
        XCTAssertTrue(ScheduleText.status(schedule, nextRun: nil, isStarting: false).contains("3"))
    }

    func testTheLoopLooksAtOnceAndRunsWhatIsDue() async throws {
        let center = ScheduledTaskCenter()
        let clock = Clock(date(16, 20))
        center.now = { clock.now }
        center.calendar = { [seoul] in seoul }
        var count = 0
        center.start = { _, _, _ in
            count += 1
            return .started(taskID: UUID())
        }
        center.create(ScheduledTask(name: "Soon", prompt: "Go.", trigger: .once(date(16, 21)),
                                    destination: ScheduleDestination(harness: .openCode)))
        clock.now = date(16, 21)
        center.startLoop()
        defer { center.stop() }
        try await waitUntil { count != 0 }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(center.isRunning)
        center.stop()
        XCTAssertFalse(center.isRunning)
    }

    // MARK: - Storage

    func testSchedulesSurviveARelaunchExactly() throws {
        let file = root.appending(path: ".yardlet/schedules.json")
        let first = ScheduledTaskCenter(repository: FileScheduledTaskRepository(fileURL: file))
        first.now = { Date(timeIntervalSince1970: 1_792_000_000.5) }
        var continuing = ScheduleDestination(harness: .codex)
        continuing.mode = .continueTask
        continuing.targetTaskID = UUID()
        let schedules = [
            ScheduledTask(name: "Daily", prompt: "One\nTwo “quoted”", trigger: .daily(ScheduleTime(hour: 9, minute: 5)),
                          destination: ScheduleDestination(
                              harness: .claudeCode, accountID: "account-1",
                              modelChoice: NewTaskModelChoice(model: "claude-opus-5-5", effort: "high", permissionMode: "plan"),
                              workspacePath: "/tmp/project", projectID: UUID(), startsInNewWorktree: true)),
            ScheduledTask(name: "Weekly", prompt: "Go.", trigger: .weekly(days: [.monday, .thursday], time: ScheduleTime(hour: 7, minute: 0)),
                          destination: continuing, isEnabled: false),
            ScheduledTask(name: "Interval", prompt: "Go.", trigger: .interval(hours: 3, anchor: Date(timeIntervalSince1970: 1_791_999_000), days: [.friday]),
                          destination: ScheduleDestination(harness: .openCode),
                          origin: ScheduleOrigin(app: .codexApp, sourceID: "nightly-sweep")),
            ScheduledTask(name: "Once", prompt: "Go.", trigger: .once(Date(timeIntervalSince1970: 1_792_100_000)),
                          destination: ScheduleDestination(harness: .openCode)),
        ]
        for schedule in schedules { first.create(schedule) }
        let id = try XCTUnwrap(first.schedules.first?.id)
        first.setEnabled(false, for: id)

        let second = ScheduledTaskCenter(repository: FileScheduledTaskRepository(fileURL: file))
        XCTAssertEqual(second.schedules, first.schedules)
        XCTAssertEqual(second.schedules.count, 4)

        // A file this build cannot read is set aside, not lost to the next save.
        try Data("{\"version\": 2, \"schedules\": []}".utf8).write(to: file)
        let third = ScheduledTaskCenter(repository: FileScheduledTaskRepository(fileURL: file))
        XCTAssertTrue(third.schedules.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("schedules-unreadable-") }
        XCTAssertEqual(aside.count, 1)
    }

    // MARK: - The editor and the quit confirmation

    func testTheEditorDraftMakesTheScheduleItShows() throws {
        let now = date(17, 2, 30)
        let project = Project(name: "App", primaryRoot: try folder("app"))
        var draft = ScheduleDraft(now: now, calendar: seoul, place: .project(project.id), harness: .claudeCode,
                                  accountID: "account-1", modelChoice: NewTaskModelChoice(model: nil, permissionMode: "plan"),
                                  startsInNewWorktree: true)
        XCTAssertEqual(draft.problem(now: now, calendar: seoul), L10n.string("Write what each run asks."))
        draft.prompt = "  Check the nightly build.\nThen report.  "
        XCTAssertNil(draft.problem(now: now, calendar: seoul))
        XCTAssertEqual(draft.nextRun(now: now, calendar: seoul), date(17, 9), "Daily at nine by default")

        let made = draft.schedule(projects: [project], existing: nil, now: now, calendar: seoul)
        XCTAssertEqual(made.name, "Check the nightly build.", "Named after the instructions when left empty")
        XCTAssertEqual(made.prompt, "Check the nightly build.\nThen report.")
        XCTAssertEqual(made.destination.projectID, project.id)
        XCTAssertEqual(made.destination.workspacePath, ProjectSidebarPresentation.normalizedPath(for: project.primaryRoot))
        XCTAssertTrue(made.destination.startsInNewWorktree)
        XCTAssertEqual(made.destination.accountID, "account-1")
        XCTAssertEqual(made.destination.modelChoice?.permissionMode, "plan")

        draft.kind = .interval
        draft.intervalHours = 3
        guard case let .interval(hours, anchor, days) = draft.trigger(now: now, calendar: seoul) else {
            return XCTFail("An interval")
        }
        XCTAssertEqual(hours, 3)
        XCTAssertEqual(anchor, date(17, 0), "Counted from midnight, as cron's */3 hours are")
        XCTAssertEqual(days, [])
        XCTAssertEqual(draft.nextRun(now: now, calendar: seoul), date(17, 3))
        draft.intervalHours = 0
        XCTAssertEqual(draft.problem(now: now, calendar: seoul), L10n.string("Schedules run at most once an hour."))
        draft.kind = .weekly
        draft.days = []
        XCTAssertEqual(draft.problem(now: now, calendar: seoul), L10n.string("Choose at least one day."))
        draft.kind = .once
        draft.onceAt = date(17, 1)
        XCTAssertEqual(draft.problem(now: now, calendar: seoul), L10n.string("Choose a time that has not passed."))
        draft.kind = .daily
        draft.mode = .continueTask
        XCTAssertEqual(draft.problem(now: now, calendar: seoul), L10n.string("Choose the task to continue."))
        let target = UUID()
        draft.targetTaskID = target
        let continuing = draft.schedule(projects: [project], existing: made, now: now, calendar: seoul, targetHarness: .codex)
        XCTAssertEqual(continuing.id, made.id, "Editing keeps the schedule")
        XCTAssertEqual(continuing.destination.mode, .continueTask)
        XCTAssertEqual(continuing.destination.targetTaskID, target)
        XCTAssertEqual(continuing.destination.harness, .codex, "The continued task's harness")
        XCTAssertNil(continuing.destination.workspacePath)

        let reopened = ScheduleDraft(editing: continuing, now: now, calendar: seoul)
        XCTAssertEqual(reopened.mode, .continueTask)
        XCTAssertEqual(reopened.targetTaskID, target)
        XCTAssertEqual(reopened.kind, .daily)
    }

    func testTheQuitConfirmationSaysSchedulesWaitForYardlet() {
        let running = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                                    title: "Long refactor", status: .running)
        let line = L10n.format("%lld scheduled tasks do not run while Yardlet is closed.", Int64(2))
        XCTAssertTrue(QuitConfirmation(active: [running], continuing: [], enabledSchedules: 2).message.hasSuffix(line))
        XCTAssertFalse(QuitConfirmation(active: [running], continuing: []).message.contains(line))
    }

    func testImportingTheSameScheduleTwiceAddsItOnce() {
        let clock = Clock(date(16, 20))
        let center = ScheduledTaskCenter()
        center.now = { clock.now }
        let origin = ScheduleOrigin(app: .claudeApp, sourceID: "morning-check")
        let item = ScheduledTask(name: "Morning", prompt: "Go.", trigger: .once(date(17, 9, 30)),
                                 destination: ScheduleDestination(harness: .claudeCode), origin: origin)
        let past = ScheduledTask(name: "Yesterday", prompt: "Go.", trigger: .once(date(15, 9)),
                                 destination: ScheduleDestination(harness: .claudeCode),
                                 origin: ScheduleOrigin(app: .claudeApp, sourceID: "yesterday"))
        XCTAssertEqual(center.add(imported: [item, past]).count, 2)
        XCTAssertEqual(center.add(imported: [item]).count, 0)
        XCTAssertEqual(center.schedules.count, 2)
        XCTAssertTrue(center.isImported(origin))
        let imported = try? XCTUnwrap(center.schedules.first { $0.origin == origin })
        XCTAssertEqual(imported?.state.scanFloor, date(16, 20), "Nothing before the import runs late")
        XCTAssertTrue(imported?.isEnabled == true)
        let ended = center.schedules.first { $0.origin?.sourceID == "yesterday" }
        XCTAssertEqual(ended?.isEnabled, false)
        XCTAssertEqual(ended?.state.stopReason, .expired, "A past one-off comes in ended, never to run")
    }
}

extension ScheduledTaskTests {
    /// Claude account folders that a fake Claude reports signed in. The `shared` ones link `projects` to
    /// the default login's, so automatic assignment may use them and a task moves between them; the
    /// `separate` ones keep their own. The default login reads as signed out, so it takes no run.
    fileprivate struct ClaudeAccounts {
        let store: ProviderConnectionStore
        let cli: URL
        let connections: [String: ProviderConnection]

        subscript(_ name: String) -> ProviderConnection? { connections[name] }

        /// Shows a reading of the account with a 5 hour limit used as given, resetting in `hours`.
        @MainActor func read(_ name: String, used: Double, resetsIn hours: Double = 4) {
            guard let connection = connections[name] else { return }
            let now = Date()
            store.publish(HarnessAccountSnapshot(id: name, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: "\(name)@example.test", detail: "", credentialOwner: "", checkedAt: now,
                usage: [AccountUsageMetric(id: "claude:session:", label: "5 hour limit", usedFraction: used, detail: "",
                    resetsAt: now.addingTimeInterval(hours * 3600), evidence: .exactQuota, windowMinutes: 300)],
                canLogin: false, canLogout: false), for: connection)
        }
    }

    fileprivate func claudeAccounts(shared: [String], separate: [String]) throws -> ClaudeAccounts {
        let native = try folder("claude-native")
        try FileManager.default.createDirectory(at: native.appending(path: "projects"), withIntermediateDirectories: true)
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": native.path]
        store.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [],
            canLogin: true, canLogout: false)])
        var connections: [String: ProviderConnection] = [:]
        for name in shared + separate {
            let home = try folder("claude-\(name)")
            if shared.contains(name) {
                try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                                                           withDestinationURL: native.appending(path: "projects"))
            } else {
                try FileManager.default.createDirectory(at: home.appending(path: "projects"), withIntermediateDirectories: true)
            }
            let connection = ProviderConnection(id: name, name: name, harness: .claudeCode, providerID: nil,
                                                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            connections[name] = connection
        }
        let cli = root.appending(path: "claude-fixture")
        try Data("#!/bin/sh\necho '{\"loggedIn\":true}'\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return ClaudeAccounts(store: store, cli: cli, connections: connections)
    }
}

private extension Result where Failure == AppModel.ScheduleStartFailure {
    var failureMessage: String? {
        if case let .failure(failure) = self { return failure.message }
        return nil
    }
}

/// Records notifications, authorized.
final class ScheduleNotificationRecorder: SystemNotificationCenter {
    private(set) var posts: [SystemNotification] = []
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
    func post(_ notification: SystemNotification) async { posts.append(notification) }
}
