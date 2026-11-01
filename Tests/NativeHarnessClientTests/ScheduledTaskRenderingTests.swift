import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Scheduled tasks drawn for review into `.build/schedules-qa/`, light and dark: the sidebar entry,
/// the list in the task list's place beside the chosen schedule with its run history (a run that went
/// to another account among them, and its task's hover card), the empty
/// place, the editor for each trigger and for continuing a task, and the other-app import sheet
/// before and after an import. No provider, runtime or app file is touched; the import sheet draws a
/// listing made from made-up schedules.
@MainActor
final class ScheduledTaskRenderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "schedules-qa-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "yardlet"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        let model: AppModel
        let state: ScheduledTasksWindowState
        let project: Project
        let releaseTask: SessionRecord
        let schedules: [String: ScheduledTask]
        /// The run that went to another account, and its task.
        let switchedRun: (task: SessionRecord, account: AccountAssignment)
    }

    private func makeFixture() async throws -> Fixture {
        let defaults = SuggestionVolatileDefaults()
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        for harness in [HarnessKind.claudeCode, .codex, .openCode] { runtimes.select(URL(filePath: "/usr/bin/true"), for: harness) }
        let store = SessionStore(repository: InMemorySessionRepository())
        let projectRepository = InMemoryProjectRepository()
        let seededProjects = ProjectStore(repository: projectRepository, chatWorkspaceHome: root)
        let project = seededProjects.ensureProject(forRoot: root.appending(path: "yardlet", directoryHint: .isDirectory),
                                                   name: "yardlet")
        seededProjects.persistNow()
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: days, to: today)!.addingTimeInterval(Double(hour * 3_600 + minute * 60))
        }
        func task(_ title: String, _ harness: HarnessKind, status: SessionStatus, unread: Bool = false) async throws -> SessionRecord {
            let created = try await store.createSession(
                harness: harness, workspaceURL: project.primaryRoot, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                title: title, selectsSession: false, projectID: project.id)
            try await store.updateSession(id: created.id, status: status, hasUnreadUpdate: unread)
            return created
        }
        let path = ProjectSidebarPresentation.normalizedPath(for: project.primaryRoot)
        let releaseTask = try await task("Release watch", .codex, status: .completed)
        let todayRun = try await task(ScheduleText.runTitle("Morning check", at: at(0, 9)), .claudeCode, status: .completed,
                                      unread: true)
        let yesterdayRun = try await task(ScheduleText.runTitle("Morning check", at: at(-1, 9)), .claudeCode, status: .completed)
        let missedRun = try await task(ScheduleText.runTitle("Morning check", at: at(-3, 9)), .claudeCode, status: .failed)
        let standupRun = try await task(ScheduleText.runTitle("Standup notes", at: at(-1, 9, 30)), .codex, status: .running)
        func account(_ name: String) -> AccountChoice {
            AccountChoice(harness: .claudeCode, connection: ProviderConnection(id: name, name: name, harness: .claudeCode,
                providerID: nil, homePath: "/tmp/\(name)", credentialSelector: nil), snapshot: nil,
                knownLabel: "\(name)@example.test")
        }
        let switched = AccountAssignment(choice: account("personal"), origin: .automatic, replacing: account("work"),
                                         at: at(-1, 9))

        var morning = ScheduledTask(
            name: "Morning check", prompt: "Look at last night's CI runs and open pull requests, and list what needs me today.",
            trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
            destination: ScheduleDestination(harness: .claudeCode, modelChoice: NewTaskModelChoice(
                model: "claude-opus-5-5", effort: "high", permissionMode: "acceptEdits"),
                workspacePath: path, projectID: project.id))
        morning.state.runs = [
            ScheduledTaskRun(slot: at(0, 9), at: at(0, 9), trigger: .scheduled, outcome: .started, taskID: todayRun.id),
            ScheduledTaskRun(slot: at(-1, 9), at: at(-1, 9), trigger: .scheduled, outcome: .started, taskID: yesterdayRun.id,
                             account: switched),
            ScheduledTaskRun(slot: at(-2, 9), at: at(-2, 9), trigger: .scheduled, outcome: .skipped, skipReason: .previousRunActive),
            ScheduledTaskRun(slot: at(-3, 9), at: at(-3, 12, 4), trigger: .missed, outcome: .started, taskID: missedRun.id),
            ScheduledTaskRun(slot: at(-9, 9), at: at(-9, 9), trigger: .scheduled, outcome: .failed,
                             failure: "Claude Code is not available in Yardlet."),
        ]
        morning.state.lastRunAt = at(0, 9)
        morning.state.lastSlot = at(0, 9)
        var standup = ScheduledTask(
            name: "Standup notes", prompt: "Summarize yesterday's merged pull requests as standup notes.",
            trigger: .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 9, minute: 30)),
            destination: ScheduleDestination(harness: .codex, workspacePath: path, projectID: project.id, startsInNewWorktree: true))
        standup.state.runs = [ScheduledTaskRun(slot: at(-1, 9, 30), at: at(-1, 9, 30), trigger: .scheduled, outcome: .started,
                                               taskID: standupRun.id)]
        var release = ScheduledTask(
            name: "Release heartbeat", prompt: "Any new failures since the last check?",
            trigger: .interval(hours: 2, anchor: at(0, 8), days: []),
            destination: ScheduleDestination(mode: .continueTask, harness: .codex, targetTaskID: releaseTask.id),
            origin: ScheduleOrigin(app: .codexApp, sourceID: "release-heartbeat"))
        release.state.runs = [ScheduledTaskRun(slot: at(0, 10), at: at(0, 10), trigger: .scheduled, outcome: .started,
                                               taskID: releaseTask.id)]
        release.state.lastSlot = at(0, 10)
        release.state.lastRunAt = at(0, 10)
        var cleanup = ScheduledTask(
            name: "Branch cleanup", prompt: "Delete merged local branches.", trigger: .daily(ScheduleTime(hour: 18, minute: 0)),
            destination: ScheduleDestination(harness: .openCode, workspacePath: path, projectID: project.id), isEnabled: false)
        cleanup.state.runs = []
        var nightly = ScheduledTask(
            name: "Nightly sweep", prompt: "Run the long test suite.", trigger: .daily(ScheduleTime(hour: 23, minute: 0)),
            destination: ScheduleDestination(harness: .claudeCode, workspacePath: path, projectID: project.id), isEnabled: false)
        nightly.state.stopReason = .repeatedFailures
        nightly.state.runs = (1...3).map { day in
            ScheduledTaskRun(slot: at(-day, 23), at: at(-day, 23), trigger: .scheduled, outcome: .failed,
                             failure: "The folder ~/old-checkout is no longer there.")
        }
        var migration = ScheduledTask(
            name: "One-off migration check", prompt: "Check the migration finished.", trigger: .once(at(-1, 14, 30)),
            destination: ScheduleDestination(harness: .claudeCode, workspacePath: path, projectID: project.id), isEnabled: false)
        migration.state.stopReason = .finished
        migration.state.lastRunAt = at(-1, 14, 30)

        // The schedules as a relaunch reads them from the file, history and all.
        let repository = InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: [
            morning, standup, release, cleanup, nightly, migration]))
        let model = AppModel(store: store, runtimeSelections: runtimes, preferences: defaults,
                             codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                             projectRepository: projectRepository, scheduleRepository: repository,
                             chatWorkspaceHome: root,
                             sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0,
                             systemNotificationCenter: ScheduleNotificationRecorder(), restoresIndexOnLaunch: false)
        // Drawn as at half past ten today, after the morning runs.
        model.scheduledTasks.now = { at(0, 10, 30) }
        let state = ScheduledTasksWindowState()
        state.isShowing = true
        state.selection = morning.id
        return Fixture(model: model, state: state, project: project, releaseTask: releaseTask,
                       schedules: ["morning": morning, "release": release, "nightly": nightly],
                       switchedRun: (yesterdayRun, switched))
    }

    private func render<Content: View>(_ name: String, size: NSSize, appearances: [WindowlessRender.Appearance] = WindowlessRender.Appearance.allCases,
                                       _ content: @escaping (ColorScheme) -> Content) throws -> [WindowlessRender.AccessibilityElement] {
        let directory = try WindowlessRender.directory("schedules-qa")
        var elements: [WindowlessRender.AccessibilityElement] = []
        for appearance in appearances {
            let host = WindowlessRender.Host(
                content(appearance.colorScheme)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    // A sheet's own background, which the window gives a presented sheet.
                    .background(Color(nsColor: .windowBackgroundColor)),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle(passes: 10)
            let capture = try host.capture()
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            if appearance == .light { elements = host.accessibilityElements() }
        }
        let text = elements.map(\.description).joined(separator: "\n")
        try text.write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
        return elements
    }

    private func shows(_ elements: [WindowlessRender.AccessibilityElement], _ text: String) -> Bool {
        elements.contains { $0.label.contains(text) || $0.value.contains(text) }
    }

    // MARK: - The window

    func testTheListBesideTheChosenScheduleAndItsRuns() async throws {
        let fixture = try await makeFixture()
        let window = try render("window", size: NSSize(width: 1180, height: 820)) { _ in
            HStack(spacing: 0) {
                ScheduledTasksSidebar(model: fixture.model, state: fixture.state, onBack: {},
                                      actions: fixture.state.actions(model: fixture.model, newDraft: { ScheduleDraft(now: Date()) },
                                                                     openTask: { _ in }))
                    .frame(width: 280)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ScheduledTasksMain(model: fixture.model, state: fixture.state,
                                   actions: ScheduledTaskActions(), projectName: { _ in "yardlet" })
            }
            .background(ParityTheme.canvas)
        }
        XCTAssertTrue(shows(window, "Morning check"))
        XCTAssertTrue(shows(window, L10n.string("Paused")), "Branch cleanup is paused")
        XCTAssertTrue(shows(window, L10n.format("Turned off after %lld failed starts", Int64(3))))
        XCTAssertTrue(shows(window, L10n.string("Ran once")))
        XCTAssertTrue(shows(window, L10n.string("Skipped: the previous run is still going")))
        XCTAssertTrue(shows(window, L10n.string("Missed, ran late")))
        XCTAssertTrue(shows(window, L10n.format("Switched to %@: %@ was nearly out of its limit",
                                                "personal@example.test", "work@example.test")))
        let switched = fixture.switchedRun
        let card = try render("hover-card-switched-account", size: NSSize(width: SidebarHoverCardMetrics.width + 40, height: 200)) { _ in
            SidebarHoverCardView(content: SidebarHoverCardContent(
                session: switched.task, projectName: "yardlet", status: nil, isScheduledRun: true, cpuPercent: nil,
                pullRequest: nil, accountAssignment: switched.account))
            .padding(10)
        }
        XCTAssertTrue(shows(card, L10n.format("Switched from %@: nearly out of its limit", "work@example.test")))
        XCTAssertTrue(shows(window, L10n.string("Today")))
        XCTAssertTrue(shows(window, L10n.string("Previous 7 days")))
        XCTAssertTrue(shows(window, L10n.string("Older")))
        XCTAssertTrue(shows(window, L10n.string("Run now")))
        XCTAssertFalse(shows(window, L10n.string("Session schedules")), "No session job, no group")

        // The session jobs Claude Code tasks' CLIs hold, under Yardlet's own schedules; a click opens the task.
        let now = Date()
        let inbox = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                                  title: "Customer inbox", status: .ready)
        let deploy = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                                   title: "Deploy watch", status: .running)
        let jobs = [
            ScheduledSessionJob(session: inbox, job: ClaudeSessionJob(
                id: "a1b2c3d4", kind: .recurring, cron: "*/15 * * * *", schedule: "Every 15 minutes", prompt: "[Inbox check]",
                createdAt: now.addingTimeInterval(-2 * 86_400), reportedRun: now.addingTimeInterval(372))),
            ScheduledSessionJob(session: deploy, job: ClaudeSessionJob(
                id: "toolu_wake", kind: .wakeup, cron: nil, schedule: nil, prompt: "/loop watch the deploy",
                createdAt: now.addingTimeInterval(-60), reportedRun: now.addingTimeInterval(1_200)))
        ]
        let center = fixture.model.scheduledTasks
        let list = try render("list-session-schedules", size: NSSize(width: 280, height: 820)) { _ in
            ScheduledTaskList(schedules: center.schedules, sessionJobs: jobs, selection: nil, startingIDs: [],
                              now: now, nextRun: { center.nextRun(of: $0) }, onBack: {},
                              actions: ScheduledTaskActions())
        }
        XCTAssertTrue(shows(list, L10n.string("Session schedules")))
        XCTAssertTrue(shows(list, "Customer inbox"))
        XCTAssertTrue(shows(list, L10n.format("Every %lld minutes", Int64(15))))
        XCTAssertTrue(shows(list, L10n.string("Loop wakeup")))
        XCTAssertTrue(shows(list, "Morning check"), "Yardlet's own schedules stay above")

        fixture.state.selection = fixture.schedules["release"]?.id
        let release = try render("detail-imported-continuing", size: NSSize(width: 900, height: 640), appearances: [.light]) { _ in
            ScheduledTasksMain(model: fixture.model, state: fixture.state, actions: ScheduledTaskActions(), projectName: { _ in "" })
        }
        XCTAssertTrue(shows(release, L10n.format("Continues “%@”", "Release watch")))
        XCTAssertTrue(shows(release, L10n.string("Imported from the Codex app.")))

        fixture.state.selection = fixture.schedules["nightly"]?.id
        _ = try render("detail-turned-off", size: NSSize(width: 900, height: 700), appearances: [.light]) { _ in
            ScheduledTasksMain(model: fixture.model, state: fixture.state, actions: ScheduledTaskActions(), projectName: { _ in "" })
        }

        let empty = try render("empty", size: NSSize(width: 900, height: 520)) { _ in
            ScheduledTaskEmptyDetail(hasSchedules: false, actions: ScheduledTaskActions())
        }
        XCTAssertTrue(shows(empty, L10n.string("Import Schedules from Other Apps…")))
        await fixture.model.shutdown()
    }

    func testTheSidebarEntrySitsUnderNewTaskAndRunsWearAClock() throws {
        let projects = ProjectStore(repository: InMemoryProjectRepository(),
                                    chatWorkspaceHome: root.appending(path: "home", directoryHint: .isDirectory))
        let folder = root.appending(path: "yardlet", directoryHint: .isDirectory)
        _ = projects.ensureProject(forRoot: folder, name: "yardlet")
        func task(_ title: String, minutesAgo: Double) -> SessionRecord {
            SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                          title: title, titleOrigin: .provider, status: .completed,
                          updatedAt: Date().addingTimeInterval(-minutesAgo * 60))
        }
        let run = task(ScheduleText.runTitle("Morning check", at: Date()), minutesAgo: 1)
        let own = task("Refactor the sidebar rows", minutesAgo: 5)
        let groups = projects.visibleGroups(sessions: [run, own])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: [], splits: [],
                                              isFiltering: false, disclosure: SidebarDisclosure(collapsedKeys: []),
                                              selection: .home, waiting: [])
        let elements = try render("sidebar-entry", size: NSSize(width: ParityTheme.sidebarWidth, height: 300)) { _ in
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .home, searchText: .constant(""),
                        onNewTask: {}, onShowSchedules: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                        projects: projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in },
                        onRemoveProject: { _ in }, onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in },
                        onRename: { _ in }, onMarkRead: { _ in })
                .environment(\.scheduledTaskIDs, [run.id])
                .background(ParityTheme.sidebar)
        }
        let labels = elements.map(\.label)
        let home = try XCTUnwrap(labels.firstIndex(of: L10n.string("Home")))
        let schedules = try XCTUnwrap(labels.firstIndex(of: L10n.string("Scheduled tasks")))
        XCTAssertEqual(schedules, home + 1, "Right under Home")
        let runRow = try XCTUnwrap(elements.first { $0.label.hasPrefix("Morning check") })
        XCTAssertTrue(runRow.value.contains(L10n.string("Scheduled task")), runRow.description)
        let ownRow = try XCTUnwrap(elements.first { $0.label.hasPrefix("Refactor the sidebar rows") })
        XCTAssertFalse(ownRow.value.contains(L10n.string("Scheduled task")))
    }

    // MARK: - The editor

    func testTheEditorForEachTriggerAndForContinuingATask() async throws {
        let fixture = try await makeFixture()
        let now = Date()
        func editor(_ draft: ScheduleDraft, existing: ScheduledTask? = nil) -> ScheduledTaskEditor {
            ScheduledTaskEditor(
                draft: draft, existing: existing, projects: [fixture.project],
                tasks: fixture.model.store.sessions.sorted { $0.updatedAt > $1.updatedAt },
                runtimeSelections: fixture.model.runtimeSelections, connections: fixture.model.connections,
                models: NewTaskModelSource(catalogs: fixture.model.modelCatalogs) { _, _, _, _ in },
                now: { now }, projectName: { _ in "yardlet" }, onCancel: {}, onSave: { _ in })
        }
        var draft = ScheduleDraft(now: now, place: .project(fixture.project.id), harness: .claudeCode,
                                  modelChoice: NewTaskModelChoice(model: nil, permissionMode: "acceptEdits"))
        draft.name = "Morning check"
        draft.prompt = "Look at last night's CI runs and open pull requests, and list what needs me today."
        let size = NSSize(width: 600, height: 680)

        let daily = try render("editor-daily", size: size) { _ in editor(draft) }
        XCTAssertTrue(shows(daily, L10n.string("New scheduled task")))
        XCTAssertTrue(shows(daily, L10n.string("Yardlet runs scheduled tasks only while it is open.")) == false,
                      "A valid draft previews its next run instead")

        var weekly = draft
        weekly.kind = .weekly
        weekly.startsInNewWorktree = true
        _ = try render("editor-weekly", size: size) { _ in editor(weekly) }

        var interval = draft
        interval.kind = .interval
        interval.intervalHours = 3
        interval.intervalDays = ScheduleWeekday.weekdays
        _ = try render("editor-interval", size: size, appearances: [.light]) { _ in editor(interval) }

        var once = draft
        once.kind = .once
        once.onceAt = now.addingTimeInterval(26 * 3_600)
        _ = try render("editor-once", size: size, appearances: [.light]) { _ in editor(once) }

        var continuing = draft
        continuing.mode = .continueTask
        continuing.targetTaskID = fixture.releaseTask.id
        continuing.kind = .interval
        continuing.intervalHours = 2
        let edit = try render("editor-continue-edit", size: size, appearances: [.light]) { _ in
            editor(continuing, existing: fixture.schedules["release"])
        }
        XCTAssertTrue(shows(edit, L10n.string("Edit scheduled task")))

        var empty = ScheduleDraft(now: now, place: .chat, harness: .codex)
        empty.kind = .weekly
        empty.days = []
        let problem = try render("editor-problem", size: size, appearances: [.light]) { _ in editor(empty) }
        XCTAssertTrue(shows(problem, L10n.string("Write what each run asks.")))
        await fixture.model.shutdown()
    }

    // MARK: - Importing from the other apps

    func testTheImportSheetListsBothAppsAndSaysHowToAvoidDoubleRuns() throws {
        let now = Date(timeIntervalSince1970: 1_792_190_000)
        let skill = { (id: String) in "---\nname: \(id)\ndescription: fake\n---\nFake prompt for \(id)." }
        let claudeJSON = """
            {"scheduledTasks": [
              {"id": "sample-morning", "displayName": "Prod check (morning)", "fireAt": 1792197000000, "enabled": true,
               "filePath": "/fake/sample-morning/SKILL.md", "createdAt": 1792134669838, "cwd": "/Users/sample/work/app",
               "notifySessionId": "local_00000000-0000-4000-8000-000000000001", "permissionMode": "bypassPermissions"},
              {"id": "sample-access", "displayName": "Access check", "fireAt": 1792215000000, "enabled": true,
               "filePath": "/fake/sample-access/SKILL.md", "createdAt": 1792128951813, "cwd": "/Users/sample/work/app",
               "notifySessionId": "local_00000000-0000-4000-8000-000000000002"},
              {"id": "sample-old", "displayName": "Failure rate re-measure", "fireAt": 1790989200000, "enabled": false,
               "filePath": "/fake/sample-old/SKILL.md", "createdAt": 1790699437291, "cwd": "/Users/sample/work/app",
               "notifySessionId": "local_00000000-0000-4000-8000-000000000003"},
              {"id": "sample-monthly", "displayName": "Monthly report", "cronExpression": "0 9 1 * *", "enabled": true,
               "filePath": "/fake/sample-monthly/SKILL.md", "createdAt": 1790699437291, "cwd": "/Users/sample/work/app"}
            ], "recordedSkips": {}, "sundayAliasBoundaryStamped": true, "dayFieldsOrBoundaryStamped": true}
            """
        let claude = OtherAppScheduleImport.claudeSchedules(from: Data(claudeJSON.utf8)) { _, id in skill(id) }
        let codex = try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: """
            version = 1
            id = "sample-heartbeat"
            kind = "heartbeat"
            name = "Nightly follow-up"
            prompt = "Fake heartbeat prompt."
            status = "ACTIVE"
            rrule = "RRULE:FREQ=DAILY;BYHOUR=22;BYMINUTE=5;BYSECOND=0"
            notification_policy = "failed_runs_only"
            target_thread_id = "00000000-0000-7000-8000-00000000000a"
            created_at = 1790692563769
            updated_at = 1791983890215
            """))
        var listing = ScheduleImportListing(claude: claude, codex: [codex])
        listing.linkedTasks = ["claudeApp:sample-morning": UUID()]
        listing.imported = ["claudeApp:sample-access"]
        let size = NSSize(width: 720, height: 600)
        let before = try render("import", size: size) { _ in
            ScheduleImportSheet(listing: listing, now: now, onImport: { $0.count }, onDismiss: {})
        }
        XCTAssertTrue(shows(before, "Prod check (morning)"))
        XCTAssertTrue(shows(before, L10n.string("Already in Yardlet")))
        XCTAssertTrue(shows(before, L10n.string("Yardlet cannot repeat it on this rule.")))
        XCTAssertTrue(shows(before, L10n.string("The Codex task it continues is not in Yardlet, so each run starts a new chat.")))
        XCTAssertTrue(shows(before, L10n.format("%lld selected", Int64(2))), "The morning check and the heartbeat")

        var imported = listing
        imported.imported.formUnion(["claudeApp:sample-morning", "codexApp:sample-heartbeat"])
        let after = try render("import-done", size: size, appearances: [.light]) { _ in
            ScheduleImportSheet(listing: imported, now: now, selection: [], importedCount: 2, onImport: { $0.count },
                                onDismiss: {})
        }
        XCTAssertTrue(shows(after, L10n.format("Imported %lld.", Int64(2))))
    }
}
