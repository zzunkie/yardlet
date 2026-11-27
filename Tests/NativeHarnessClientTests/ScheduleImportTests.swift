import Foundation
import XCTest
@testable import NativeHarnessClient

/// Importing the Claude app's scheduled tasks and the Codex app's automations: the files' real key
/// shapes with made-up values, their dates and repeat rules, what each becomes in Yardlet, which rows
/// start checked, and that the apps' files are only read.
@MainActor
final class ScheduleImportTests: XCTestCase {
    private var home: URL!
    private var seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "schedule-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures (the apps' key shapes, fake values)

    /// 2026-10-17 09:30 and 14:30 KST, 2026-10-07 10:00 KST, in epoch milliseconds.
    private let morning: Int64 = 1_792_197_000_000
    private let afternoon: Int64 = 1_792_215_000_000
    private let past: Int64 = 1_791_334_800_000

    private func claudeJSON(filePrefix: String) -> String {
        """
        {
          "scheduledTasks": [
            {"id": "sample-morning-check", "displayName": "Sample morning check", "fireAt": \(morning), "enabled": true,
             "filePath": "\(filePrefix)/sample-morning-check/SKILL.md", "createdAt": 1792134669838,
             "cwd": "/tmp/sample-project", "notifySessionId": "local_00000000-0000-4000-8000-000000000001",
             "permissionMode": "bypassPermissions", "permissionModeCarried": true},
            {"id": "sample-afternoon", "displayName": "Sample afternoon", "fireAt": \(afternoon), "enabled": true,
             "filePath": "\(filePrefix)/sample-afternoon/SKILL.md", "createdAt": 1792128951813,
             "cwd": "/tmp/sample-project", "notifySessionId": "local_00000000-0000-4000-8000-000000000002",
             "permissionMode": "default"},
            {"id": "sample-old", "displayName": "Sample old", "fireAt": \(past), "enabled": false,
             "filePath": "\(filePrefix)/sample-old/SKILL.md", "createdAt": 1791000000000,
             "lastRunAt": "2026-10-01T01:00:49.430Z", "lastScheduledFor": "2026-10-01T01:00:00.000Z",
             "cwd": "/tmp/sample-project", "notifySessionId": "local_00000000-0000-4000-8000-000000000003"},
            {"id": "sample-weekdays", "displayName": "Sample weekdays", "cronExpression": "15 8 * * 1-5", "enabled": true,
             "filePath": "\(filePrefix)/sample-weekdays/SKILL.md", "createdAt": 1791000000000, "cwd": "/tmp/sample-project",
             "useWorktree": true, "model": "claude-sample-model"},
            {"id": "sample-monthly", "displayName": "Sample monthly", "cronExpression": "0 9 1 * *", "enabled": true,
             "filePath": "\(filePrefix)/sample-monthly/SKILL.md", "createdAt": 1791000000000, "cwd": "/tmp/sample-project"}
          ],
          "recordedSkips": {},
          "sundayAliasBoundaryStamped": true,
          "dayFieldsOrBoundaryStamped": true
        }
        """
    }

    private func skill(_ name: String) -> String {
        """
        ---
        name: \(name)
        description: A made-up task for the tests
        ---

        Fake prompt for \(name): look at the sample dashboard and report.
        Second line.
        """
    }

    private let heartbeatTOML = """
        version = 1
        id = "sample-heartbeat"
        kind = "heartbeat"
        name = "Sample heartbeat"
        prompt = "Fake heartbeat prompt.\\nCheck the \\"sample\\" queue and say \\u00e9t\\u00e9."
        status = "ACTIVE"
        rrule = "RRULE:FREQ=DAILY;BYHOUR=22;BYMINUTE=5;BYSECOND=0"
        notification_policy = "failed_runs_only"
        target_thread_id = "00000000-0000-7000-8000-00000000000a"
        created_at = 1790692563769
        updated_at = 1791983890215
        """

    private let cronTOML = """
        version = 1
        id = "sample-cron"
        kind = "cron"
        name = "Sample cron"
        prompt = \"\"\"
        Fake multi-line prompt.
        Second line.\"\"\"
        status = "PAUSED"
        rrule = "FREQ=HOURLY;INTERVAL=6;BYMINUTE=30"
        model = "gpt-sample"
        reasoning_effort = "high"
        execution_environment = "worktree"
        target = { type = "project", project_id = "sample-project-id" }
        cwds = [
          "/tmp/sample-codex-project", # the first is the folder
          "/tmp/other",
        ]
        created_at = 1790692563769
        updated_at = 1790692563769
        """

    // MARK: - Claude app

    func testClaudeScheduledTasksReadWithTheirDatesPromptsAndModes() throws {
        let prompts = ["sample-morning-check", "sample-afternoon", "sample-old", "sample-weekdays", "sample-monthly"]
        let schedules = OtherAppScheduleImport.claudeSchedules(from: Data(claudeJSON(filePrefix: "/fake").utf8)) { path, id in
            XCTAssertEqual(path, "/fake/\(id)/SKILL.md")
            return prompts.contains(id) ? self.skill(id) : nil
        }
        XCTAssertEqual(schedules.map(\.origin.sourceID), prompts)
        let first = schedules[0]
        XCTAssertEqual(first.origin.app, .claudeApp)
        XCTAssertEqual(first.name, "Sample morning check")
        XCTAssertEqual(first.trigger, .once(Date(timeIntervalSince1970: 1_792_197_000)))
        XCTAssertEqual(seoul.dateComponents([.month, .day, .hour, .minute], from: Date(timeIntervalSince1970: 1_792_197_000)),
                       DateComponents(month: 10, day: 17, hour: 9, minute: 30), "fireAt is epoch milliseconds")
        XCTAssertEqual(first.prompt, "Fake prompt for sample-morning-check: look at the sample dashboard and report.\nSecond line.",
                       "The SKILL.md body without its frontmatter")
        XCTAssertEqual(first.permissionMode, "bypassPermissions")
        XCTAssertEqual(first.workspacePath, "/tmp/sample-project")
        XCTAssertEqual(first.link, .claudeAppSession("local_00000000-0000-4000-8000-000000000001"))
        XCTAssertEqual(first.harness, .claudeCode)
        XCTAssertTrue(first.isEnabled)
        XCTAssertEqual(schedules[1].permissionMode, ClaudePermissionMode.manual, "The app's default is Manual")
        XCTAssertFalse(schedules[2].isEnabled)

        let weekdays = schedules[3]
        XCTAssertEqual(weekdays.trigger, .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 8, minute: 15)))
        XCTAssertTrue(weekdays.startsInNewWorktree)
        XCTAssertEqual(weekdays.model, "claude-sample-model")
        XCTAssertNil(schedules[4].trigger, "A day-of-month rule has no Yardlet trigger")
        XCTAssertEqual(schedules[4].rule, "0 9 1 * *")
        XCTAssertFalse(schedules[4].canImport)
    }

    func testCronExpressionsYardletCanRepeat() {
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("0 9 * * *"), .daily(ScheduleTime(hour: 9, minute: 0)))
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("30 18 * * 0,6"),
                       .weekly(days: [.sunday, .saturday], time: ScheduleTime(hour: 18, minute: 30)))
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("30 18 * * 7"),
                       .weekly(days: [.sunday], time: ScheduleTime(hour: 18, minute: 30)), "7 is Sunday too")
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("0 7 * * mon-fri"),
                       .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 7, minute: 0)))
        XCTAssertEqual(OtherAppScheduleImport.cronDays("1-7"), ScheduleWeekday.everyDay)
        guard case let .interval(hours, anchor, days)? = OtherAppScheduleImport.cronTrigger("5 */6 * * *", calendar: seoul) else {
            return XCTFail("Every six hours")
        }
        XCTAssertEqual(hours, 6)
        XCTAssertEqual(days, [])
        XCTAssertEqual(seoul.dateComponents([.hour, .minute], from: anchor), DateComponents(hour: 0, minute: 5))
        XCTAssertEqual(ScheduleTrigger.interval(hours: hours, anchor: anchor, days: days)
            .nextSlot(after: seoul.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 7))!, calendar: seoul),
                       seoul.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12, minute: 5)),
                       "Hours divisible by six, at five past")
        XCTAssertNotNil(OtherAppScheduleImport.cronTrigger("0 * * * *"))
        XCTAssertNil(OtherAppScheduleImport.cronTrigger("0 9 * 1 *"))
        XCTAssertNil(OtherAppScheduleImport.cronTrigger("*/15 * * * *"), "More than once an hour")
        XCTAssertNil(OtherAppScheduleImport.cronTrigger("0,30 9 * * *"), "Twice in an hour")

        // An hour list or range is one schedule at each of its hours, at the minute.
        func at(_ hours: Int..., minute: Int = 0) -> [ScheduleTime] { hours.map { ScheduleTime(hour: $0, minute: minute) } }
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("0 9,17 * * *"), .daily(at(9, 17)))
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("55 9-17/2 * * 1-5"),
                       .weekly(days: ScheduleWeekday.weekdays, times: at(9, 11, 13, 15, 17, minute: 55)))
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("30 8-10,14 * * *"), .daily(at(8, 9, 10, 14, minute: 30)))
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("0 17,9,9 * * *"), .daily(at(9, 17)), "Earliest first, once each")
        XCTAssertEqual(OtherAppScheduleImport.cronTrigger("0 */5 * * *"), .daily(at(0, 5, 10, 15, 20)),
                       "Five hours do not divide a day, so cron's hours divisible by five are times of day")
        for unreadable in ["0 9-25 * * *", "0 17-9 * * *", "0 9,,17 * * *", "0 9-17/0 * * *", "0 9/2 * * *", "0 9- * * *"] {
            XCTAssertNil(OtherAppScheduleImport.cronTrigger(unreadable), unreadable)
        }
    }

    func testASkillFileWithoutFrontmatterIsAllPrompt() {
        let parsed = OtherAppScheduleImport.skillPrompt("Just a fake prompt.\n")
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.prompt, "Just a fake prompt.")
        let quoted = OtherAppScheduleImport.skillPrompt("---\nname: \"Quoted: name\"\nmodel: sample-model\n---\nBody")
        XCTAssertEqual(quoted.name, "Quoted: name")
        XCTAssertEqual(quoted.model, "sample-model")
        XCTAssertEqual(quoted.prompt, "Body")
    }

    // MARK: - Codex app

    func testCodexHeartbeatAndCronAutomationsRead() throws {
        let heartbeat = try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML))
        XCTAssertEqual(heartbeat.origin, ScheduleOrigin(app: .codexApp, sourceID: "sample-heartbeat"))
        XCTAssertEqual(heartbeat.prompt, "Fake heartbeat prompt.\nCheck the \"sample\" queue and say été.")
        XCTAssertEqual(heartbeat.trigger, .daily(ScheduleTime(hour: 22, minute: 5)))
        XCTAssertEqual(heartbeat.link, .codexThread("00000000-0000-7000-8000-00000000000a"))
        XCTAssertTrue(heartbeat.isEnabled)
        XCTAssertNil(heartbeat.workspacePath, "A heartbeat has no folder of its own")
        XCTAssertEqual(heartbeat.harness, .codex)

        let cron = try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: cronTOML))
        XCTAssertEqual(cron.prompt, "Fake multi-line prompt.\nSecond line.")
        XCTAssertFalse(cron.isEnabled, "PAUSED")
        XCTAssertEqual(cron.workspacePath, "/tmp/sample-codex-project")
        XCTAssertEqual(cron.model, "gpt-sample")
        XCTAssertEqual(cron.effort, "high")
        XCTAssertTrue(cron.startsInNewWorktree)
        XCTAssertEqual(cron.link, .none)
        guard case let .interval(hours, anchor, days)? = cron.trigger else { return XCTFail("Every six hours") }
        XCTAssertEqual(hours, 6)
        XCTAssertEqual(days, [])
        // Created 2026-09-29 23:36 KST: the rule counts from that hour, at its minute.
        let created = Date(timeIntervalSince1970: 1_790_692_563.769)
        XCTAssertEqual(anchor, Calendar.autoupdatingCurrent.dateInterval(of: .hour, for: created)!.start.addingTimeInterval(30 * 60))

        XCTAssertNil(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML.replacingOccurrences(
            of: "target_thread_id = \"00000000-0000-7000-8000-00000000000a\"", with: "")),
                     "A heartbeat without its thread is not one the Codex app reads either")
        XCTAssertNil(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML.replacingOccurrences(of: "version = 1", with: "version = 2")))
        XCTAssertNil(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML.replacingOccurrences(of: "ACTIVE", with: "DELETED")))
    }

    func testRRulesYardletCanRepeat() {
        let created = seoul.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 20))!
        func rule(_ text: String) -> ScheduleTrigger? { OtherAppScheduleImport.rruleTrigger(text, createdAt: created, calendar: seoul) }
        XCTAssertEqual(rule("RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"), .daily(ScheduleTime(hour: 9, minute: 0)))
        XCTAssertEqual(rule("FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=7;BYMINUTE=45"),
                       .weekly(days: [.monday, .wednesday, .friday], time: ScheduleTime(hour: 7, minute: 45)))
        XCTAssertEqual(rule("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=18;BYMINUTE=0"),
                       .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 18, minute: 0)))
        XCTAssertEqual(rule("FREQ=HOURLY;INTERVAL=24;BYMINUTE=0"),
                       .interval(hours: 24, anchor: seoul.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14))!,
                                 days: []), "The Codex app's default rule, from the hour it was made")
        XCTAssertEqual(rule("DTSTART:20261001T000000Z\nRRULE:FREQ=HOURLY;INTERVAL=2;BYDAY=SA,SU"),
                       .interval(hours: 2, anchor: seoul.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14))!,
                                 days: [.saturday, .sunday]))
        XCTAssertNil(rule("FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9"))
        XCTAssertNil(rule("FREQ=MINUTELY;INTERVAL=30"))
        XCTAssertNil(rule("FREQ=DAILY;INTERVAL=2;BYHOUR=9;BYMINUTE=0"), "Every other day has no Yardlet trigger")
        XCTAssertNil(rule("FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0"))
        XCTAssertNil(rule("FREQ=HOURLY;INTERVAL=48"))
        XCTAssertNil(rule("FREQ=WEEKLY;BYHOUR=9"), "A weekly rule names its days")
    }

    func testTheMinimalTOMLReaderReadsWhatItClaims() throws {
        let values = try MinimalTOML.parse("""
            # comment
            a = "x\\ty" # trailing
            b = 'C:\\no\\escape'
            c = 42
            d = -1_000
            e = true
            f = [1, "two", [3]]
            g = { h = "i", j = { k = false } }
            "quoted key" = 1.5
            [section]
            l = '''
            raw "text"'''
            """)
        XCTAssertEqual(values["a"], .string("x\ty"))
        XCTAssertEqual(values["b"], .string("C:\\no\\escape"))
        XCTAssertEqual(values["c"], .integer(42))
        XCTAssertEqual(values["d"], .integer(-1000))
        XCTAssertEqual(values["e"], .bool(true))
        XCTAssertEqual(values["f"], .array([.integer(1), .string("two"), .array([.integer(3)])]))
        XCTAssertEqual(values["g"]?.table?["j"], .table(["k": .bool(false)]))
        XCTAssertEqual(values["quoted key"], .float(1.5))
        XCTAssertEqual(values["section.l"], .string("raw \"text\""))
        XCTAssertThrowsError(try MinimalTOML.parse("a = \"unterminated"))
        XCTAssertThrowsError(try MinimalTOML.parse("a = what"))
    }

    // MARK: - Into Yardlet

    func testEachKindMapsToAYardletSchedule() throws {
        let claude = OtherAppScheduleImport.claudeSchedules(from: Data(claudeJSON(filePrefix: "/fake").utf8)) { _, id in self.skill(id) }
        let parent = UUID()
        let project = UUID()
        let fromClaude = try XCTUnwrap(OtherAppScheduleImport.schedule(from: claude[0], linkedTask: parent, projectID: project))
        XCTAssertEqual(fromClaude.trigger, .once(Date(timeIntervalSince1970: 1_792_197_000)))
        XCTAssertEqual(fromClaude.destination.mode, .newTask)
        XCTAssertEqual(fromClaude.destination.harness, .claudeCode)
        XCTAssertEqual(fromClaude.destination.workspacePath, "/tmp/sample-project")
        XCTAssertEqual(fromClaude.destination.projectID, project)
        XCTAssertEqual(fromClaude.destination.modelChoice?.permissionMode, "bypassPermissions")
        XCTAssertEqual(fromClaude.destination.parentTaskID, parent, "Runs nest under the imported session")
        XCTAssertEqual(fromClaude.origin, ScheduleOrigin(app: .claudeApp, sourceID: "sample-morning-check"))
        XCTAssertEqual(fromClaude.destination.accountID, nil, "The account Claude Code's new tasks start on")
        let unlinked = try XCTUnwrap(OtherAppScheduleImport.schedule(from: claude[0], linkedTask: nil, projectID: nil))
        XCTAssertNil(unlinked.destination.parentTaskID)
        XCTAssertNil(OtherAppScheduleImport.schedule(from: claude[4], linkedTask: nil, projectID: nil), "No trigger, no schedule")

        let heartbeat = try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML))
        let task = UUID()
        let continuing = try XCTUnwrap(OtherAppScheduleImport.schedule(from: heartbeat, linkedTask: task, projectID: nil))
        XCTAssertEqual(continuing.destination.mode, .continueTask)
        XCTAssertEqual(continuing.destination.targetTaskID, task)
        XCTAssertTrue(OtherAppScheduleImport.notes(for: heartbeat, linkedTask: task, isImported: false).isEmpty)
        let alone = try XCTUnwrap(OtherAppScheduleImport.schedule(from: heartbeat, linkedTask: nil, projectID: nil))
        XCTAssertEqual(alone.destination.mode, .newTask)
        XCTAssertNil(alone.destination.workspacePath, "Each run starts a chat")
        XCTAssertEqual(OtherAppScheduleImport.notes(for: heartbeat, linkedTask: nil, isImported: false),
                       [L10n.string("The Codex task it continues is not in Yardlet, so each run starts a new chat.")])

        let cron = try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: cronTOML))
        let fromCron = try XCTUnwrap(OtherAppScheduleImport.schedule(from: cron, linkedTask: nil, projectID: nil))
        XCTAssertEqual(fromCron.destination.modelChoice, NewTaskModelChoice(model: "gpt-sample", effort: "high"))
        XCTAssertTrue(fromCron.destination.startsInNewWorktree)
        XCTAssertFalse(fromCron.isEnabled, "Paused in the Codex app, paused here")
    }

    func testOnAndAheadStartChecked() throws {
        let now = Date(timeIntervalSince1970: 1_792_190_000) // 2026-10-17 07:33 KST
        let claude = OtherAppScheduleImport.claudeSchedules(from: Data(claudeJSON(filePrefix: "/fake").utf8)) { _, id in self.skill(id) }
        let codex = [try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML)),
                     try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: cronTOML))]
        var listing = ScheduleImportListing(claude: claude, codex: codex)
        XCTAssertEqual(listing.preselected(now: now),
                       ["claudeApp:sample-morning-check", "claudeApp:sample-afternoon", "claudeApp:sample-weekdays",
                        "codexApp:sample-heartbeat"])
        listing.imported = ["claudeApp:sample-afternoon"]
        XCTAssertFalse(listing.preselected(now: now).contains("claudeApp:sample-afternoon"), "Already in Yardlet")
        XCTAssertFalse(listing.preselected(now: Date(timeIntervalSince1970: 1_792_200_000)).contains("claudeApp:sample-morning-check"),
                       "A one-off whose time has passed is shown unchecked")
    }

    // MARK: - Reading the apps' folders, read only

    func testTheCatalogReadsBothAppsFoldersWithoutChangingThem() throws {
        let claudeRoot = home.appending(path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory)
        let promptRoot = home.appending(path: ".claude/scheduled-tasks", directoryHint: .isDirectory)
        let account = claudeRoot.appending(path: "account-a/org-b", directoryHint: .isDirectory)
        let emptyAccount = claudeRoot.appending(path: "account-a/org-c", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyAccount, withIntermediateDirectories: true)
        try Data(claudeJSON(filePrefix: promptRoot.path).utf8).write(to: account.appending(path: "scheduled-tasks.json"))
        try Data(#"{"scheduledTasks": [], "recordedSkips": {}}"#.utf8).write(to: emptyAccount.appending(path: "scheduled-tasks.json"))
        for id in ["sample-morning-check", "sample-afternoon", "sample-weekdays", "sample-monthly"] {
            let folder = promptRoot.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(skill(id).utf8).write(to: folder.appending(path: "SKILL.md"))
        }
        // The session the first task reports to, as the Claude app keeps it.
        try Data("""
            {"sessionId": "local_00000000-0000-4000-8000-000000000001", "cliSessionId": "11111111-2222-4333-8444-555555555555",
             "cwd": "/tmp/sample-project", "title": "Fake session"}
            """.utf8).write(to: account.appending(path: "local_00000000-0000-4000-8000-000000000001.json"))
        let automations = home.appending(path: ".codex/automations", directoryHint: .isDirectory)
        for (id, text) in [("sample-heartbeat", heartbeatTOML), ("sample-cron", cronTOML)] {
            let folder = automations.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appending(path: "automation.toml"))
        }
        try Data("salt".utf8).write(to: automations.appending(path: ".run-jitter-salt"))
        let before = try snapshot(of: home)

        let listing = OtherAppScheduleCatalog.read(home: home, claudeRoot: claudeRoot)

        XCTAssertEqual(listing.claude.map(\.origin.sourceID),
                       ["sample-morning-check", "sample-afternoon", "sample-old", "sample-weekdays", "sample-monthly"])
        XCTAssertNil(listing.claude[2].prompt, "Its SKILL.md is not there")
        XCTAssertFalse(listing.claude[2].canImport)
        XCTAssertEqual(Set(listing.codex.map(\.origin.sourceID)), ["sample-heartbeat", "sample-cron"])
        XCTAssertEqual(listing.claudeAppSessions, ["local_00000000-0000-4000-8000-000000000001": "11111111-2222-4333-8444-555555555555"])
        XCTAssertEqual(try snapshot(of: home), before, "Nothing in either app's folders changed")
    }

    func testTheListingFindsTheirTasksAndImportingTwiceAddsOnce() async throws {
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                             runtimeSelections: RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                                                      loadsPersistedSelections: false),
                             preferences: SuggestionVolatileDefaults(),
                             codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: SuggestionVolatileDefaults()),
                             sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0,
                             systemNotificationCenter: ScheduleNotificationRecorder(), restoresIndexOnLaunch: false)
        let claudeTask = try await model.store.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/sample-project"), runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Imported Claude session", providerSessionID: "11111111-2222-4333-8444-555555555555")
        let codexTask = try await model.store.createSession(
            harness: .codex, workspaceURL: URL(filePath: "/tmp/sample-project"), runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Imported Codex thread", providerSessionID: "00000000-0000-7000-8000-00000000000a")
        var found = OtherAppScheduleCatalog.Listing()
        found.claude = OtherAppScheduleImport.claudeSchedules(from: Data(claudeJSON(filePrefix: "/fake").utf8)) { _, id in self.skill(id) }
        found.codex = [try XCTUnwrap(OtherAppScheduleImport.codexSchedule(fromTOML: heartbeatTOML))]
        found.claudeAppSessions = ["local_00000000-0000-4000-8000-000000000001": "11111111-2222-4333-8444-555555555555"]

        let listing = model.scheduleImportListing(found)
        XCTAssertEqual(listing.linkedTasks["claudeApp:sample-morning-check"], claudeTask.id)
        XCTAssertEqual(listing.linkedTasks["codexApp:sample-heartbeat"], codexTask.id)
        XCTAssertNil(listing.linkedTasks["claudeApp:sample-afternoon"])

        let chosen = found.all.filter { $0.canImport }
        XCTAssertEqual(model.importSchedules(chosen, linkedTasks: listing.linkedTasks), chosen.count)
        XCTAssertEqual(model.importSchedules(chosen, linkedTasks: listing.linkedTasks), 0, "Keyed on app and source ID")
        XCTAssertEqual(model.scheduledTasks.schedules.count, chosen.count)
        let again = model.scheduleImportListing(found)
        XCTAssertEqual(again.imported, Set(chosen.map(\.id)))
        XCTAssertTrue(again.preselected(now: Date(timeIntervalSince1970: 1_792_190_000)).isEmpty)
        let heartbeat = try XCTUnwrap(model.scheduledTasks.schedules.first { $0.origin?.sourceID == "sample-heartbeat" })
        XCTAssertEqual(heartbeat.destination.mode, .continueTask)
        XCTAssertEqual(heartbeat.destination.targetTaskID, codexTask.id)
        let morning = try XCTUnwrap(model.scheduledTasks.schedules.first { $0.origin?.sourceID == "sample-morning-check" })
        XCTAssertEqual(morning.destination.parentTaskID, claudeTask.id)
        await model.shutdown()
    }

    /// `YARDLET_LIVE_SCHEDULE_IMPORT=1` reads this Mac's real Claude app and Codex app schedules,
    /// read only, and prints each one's shape — never its prompt or name.
    func testLiveReadOfThisMacsSchedules() throws {
        guard ProcessInfo.processInfo.environment["YARDLET_LIVE_SCHEDULE_IMPORT"] == "1" else {
            throw XCTSkip("Set YARDLET_LIVE_SCHEDULE_IMPORT=1 to read this Mac's schedules.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let before = try snapshot(of: home.appending(path: ".codex/automations", directoryHint: .isDirectory))
        let listing = OtherAppScheduleCatalog.read()
        let now = Date()
        for item in listing.all {
            let trigger = item.trigger.map { ScheduleText.summary($0, now: now) } ?? "unsupported"
            let link: String
            switch item.link {
            case .none: link = "none"
            case let .claudeAppSession(id):
                link = "claude session (\(listing.claudeAppSessions[id] == nil ? "not found" : "found"))"
            case .codexThread: link = "codex thread"
            }
            print("LIVE \(item.origin.app.rawValue) enabled=\(item.isEnabled) upcoming=\(item.isUpcoming(now: now)) "
                  + "prompt=\(item.prompt == nil ? "missing" : "\(item.prompt!.count) chars") trigger=\(trigger) "
                  + "folder=\(item.workspacePath == nil ? "none" : "set") mode=\(item.permissionMode ?? "-") link=\(link)")
        }
        XCTAssertEqual(try snapshot(of: home.appending(path: ".codex/automations", directoryHint: .isDirectory)), before)
    }

    /// Every file under a folder with its contents and modification date.
    private func snapshot(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            result[url.path] = "\(data.hashValue)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }
}
