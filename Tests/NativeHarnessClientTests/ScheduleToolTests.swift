import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's scheduled-task tools (docs/AGENT_BROWSER_TOOLS.md, "Scheduled-task tools", after the Claude app's `scheduled-tasks`
/// server): the schemas the MCP server lists, create, list, update, delete and run-now through the
/// broker, the defaults a schedule takes from the task that made it, continuing that task, the file
/// the schedules live in, who asks before a change (the harness, as each app has its harness ask),
/// and the conversation reading the call as the schedule it made. No harness runs and no model is
/// contacted: adapters are doubles, every store and preference is in memory, and the only files are
/// temporary.
@MainActor
final class ScheduleToolTests: XCTestCase {
    private var root: URL!
    private var seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "schedule-tools-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        seoul.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Schemas

    func testTheToolsFollowTheClaudeAppsNamesAndStayBehindToolSearch() throws {
        let names = ScheduleToolCatalog.tools.map(\.name)
        XCTAssertEqual(names, ["create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task",
                               "delete_scheduled_task", "run_scheduled_task", "list_task_runs"])
        let required: [String: [String]] = [
            "create_scheduled_task": ["prompt"], "list_scheduled_tasks": [], "update_scheduled_task": ["scheduleId"],
            "delete_scheduled_task": ["scheduleId"], "run_scheduled_task": ["scheduleId"], "list_task_runs": ["scheduleId"]
        ]
        let readOnly: Set<String> = ["list_scheduled_tasks", "list_task_runs"]
        for tool in ScheduleToolCatalog.tools {
            let json = tool.json
            XCTAssertEqual(json["inputSchema"]?["type"], .string("object"), tool.name)
            XCTAssertEqual(json["inputSchema"]?["additionalProperties"], .bool(false), tool.name)
            XCTAssertEqual(json["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                           required[tool.name], tool.name)
            XCTAssertEqual(json["annotations"]?["readOnlyHint"], .bool(readOnly.contains(tool.name)), tool.name)
            XCTAssertEqual(json["annotations"]?["openWorldHint"], .bool(false), tool.name)
            XCTAssertNil(json["_meta"], "\(tool.name) stays behind Claude Code's tool search (no alwaysLoad)")
            let description = try XCTUnwrap(json["description"]?.stringValue)
            XCTAssertLessThan(description.count, 300, tool.name)
            for nudge in ["Use this", "use this", "Call this", "call this", "When you", "when you", "when the user",
                          "should", "must", "Go ahead", "proactive"] {
                XCTAssertFalse(description.contains(nudge), "\(tool.name) says what it does, not when: \(nudge)")
            }
            for case let (name, property) in json["inputSchema"]?["properties"]?.objectValue ?? [:] {
                let words = property["description"]?.stringValue ?? ""
                XCTAssertFalse(words.isEmpty, "\(tool.name).\(name) says what it is")
                XCTAssertFalse(words.contains("should") || words.contains("must"), "\(tool.name).\(name): \(words)")
            }
        }
        let create = try XCTUnwrap(ScheduleToolCatalog.definition(named: "create_scheduled_task")?.json)
        let properties = Set(create["inputSchema"]?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        XCTAssertEqual(properties, ["name", "prompt", "cronExpression", "fireAt", "continueTaskId", "harness", "project",
                                    "chat", "useWorktree", "topLevel", "model", "effort", "permissionMode"])
        XCTAssertEqual(create["inputSchema"]?["properties"]?["permissionMode"]?["enum"],
                       .array(["default", "plan", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "askForApproval",
                               "approveForMe", "dangerFullAccess", "custom", "readOnly"].map { .string($0) }),
                       "The Claude app's own modes, then Codex's own permissions")
        let update = try XCTUnwrap(ScheduleToolCatalog.definition(named: "update_scheduled_task")?.json)
        XCTAssertEqual(update["inputSchema"]?["properties"]?["enabled"]?["type"], .string("boolean"))
        let runs = try XCTUnwrap(ScheduleToolCatalog.definition(named: "list_task_runs")?.json)
        XCTAssertEqual(runs["inputSchema"]?["properties"]?.objectValue?.keys.sorted(), ["limit", "scheduleId"])
        XCTAssertEqual(Array(AgentToolCatalog.builtInTools.suffix(6)).map(\.name), names,
                       "The server's own list, when the app cannot answer, ends with them")
    }

    // MARK: - Who asks

    func testEachHarnessAsksBeforeAChangeAsItsAppHasItAsk() async throws {
        // Claude Code: only list_task_runs is allowed up front, as the Claude app allows only its own;
        // the CLI asks before the others as before any tool.
        let allowed = Set(AgentToolServerLaunch.claudeAllowedTools)
        XCTAssertTrue(allowed.contains("mcp__yardlet__list_task_runs"))
        for name in ["create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task",
                     "run_scheduled_task"] {
            XCTAssertFalse(allowed.contains("mcp__yardlet__\(name)"), name)
        }
        for name in (TaskSuggestionToolCatalog.tools + SessionToolCatalog.tools).map(\.name) {
            XCTAssertTrue(allowed.contains("mcp__yardlet__\(name)"), "\(name) still runs without the CLI's card")
        }

        // Codex: asking follows the task's own approval setting (2026-10-22), so Yardlet sets no
        // per-tool `approval_mode`.
        let launch = AgentToolServerLaunch(command: "/Applications/Yardlet.app/Contents/Helpers/yardlet-mcp",
                                           environment: ["YARDLET_TOOLS_TOKEN": "t"])
        XCTAssertNil(launch.codexConfig["mcp_servers"]?["yardlet"]?["tools"])
        XCTAssertEqual(launch.codexConfig["mcp_servers"]?["yardlet"]?["tool_timeout_sec"], .integer(1_800))

        // Claude Code's card for a change: the action, name, schedule, where runs go and the prompt, and
        // no "always allow" even when the CLI offers one, as the Claude app strips it.
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let recorder = PermissionRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case let .permissionRequested(request) = event.payload { await recorder.append(request) }
            }
        }
        defer { collector.cancel() }
        let suggestion: JSONValue = .object([
            "type": .string("addRules"), "destination": .string("session"), "behavior": .string("allow"),
            "rules": .array([.object(["toolName": .string("mcp__yardlet__create_scheduled_task")])])
        ])
        await transport.emit(canUseTool(id: "create-1", tool: "mcp__yardlet__create_scheduled_task", input: .object([
            "name": .string("Morning check"), "prompt": .string("Check the overnight builds."),
            "cronExpression": .string("0 9 * * *")
        ]), suggestions: [suggestion]))
        let create = try await recorder.waitFor("create-1")
        XCTAssertEqual(create.title, L10n.format("Allow Claude to create the scheduled task “%@”?", "Morning check"))
        let detail = try XCTUnwrap(create.detail)
        XCTAssertTrue(detail.contains(ScheduleText.summary(.daily(ScheduleTime(hour: 9, minute: 0)))), detail)
        XCTAssertTrue(detail.contains(L10n.string("Each run starts a new task.")), detail)
        XCTAssertTrue(detail.contains("Check the overnight builds."), detail)
        XCTAssertTrue(create.actions.isEmpty, "No always-allow choice: \(create.actions.map(\.id))")

        // Another tool's request keeps the CLI's offer.
        await transport.emit(canUseTool(id: "list-1", tool: "mcp__yardlet__list_scheduled_tasks", input: .object([:]),
                                        suggestions: [suggestion]))
        let list = try await recorder.waitFor("list-1")
        XCTAssertFalse(list.actions.isEmpty, "Listing is the CLI's ordinary card, as in the Claude app")
        await adapter.close(handle)

        // The other changes name the schedule they change.
        let id = UUID()
        let names: (UUID) -> String? = { $0 == id ? "Morning check" : nil }
        for (tool, title) in [
            ("delete_scheduled_task", L10n.format("Allow Claude to delete the scheduled task “%@”?", "Morning check")),
            ("run_scheduled_task", L10n.format("Allow Claude to run the scheduled task “%@” now?", "Morning check")),
            ("update_scheduled_task", L10n.format("Allow Claude to update the scheduled task “%@”?", "Morning check"))
        ] {
            let text = try XCTUnwrap(ScheduleToolApproval.request(
                toolName: "mcp__yardlet__\(tool)", input: .object(["scheduleId": .string(id.uuidString),
                                                                   "enabled": .bool(false)]), name: names))
            XCTAssertEqual(text.title, title, tool)
        }
        // The card names where each run goes, as the call gives it, and the mode it asks for.
        let elsewhere = try XCTUnwrap(ScheduleToolApproval.request(
            toolName: "mcp__yardlet__create_scheduled_task",
            input: .object(["prompt": .string("Go."), "fireAt": .string("2026-10-18T09:00:00+09:00"),
                            "project": .string("site"), "permissionMode": .string("acceptEdits")])))
        XCTAssertTrue(elsewhere.detail.contains(L10n.format("Project or folder: %@", "site")), elsewhere.detail)
        XCTAssertTrue(elsewhere.detail.contains(L10n.format("Its runs will use %@ mode.", L10n.string("Accept edits"))),
                      elsewhere.detail)
        let onCodex = try XCTUnwrap(ScheduleToolApproval.request(
            toolName: "mcp__yardlet__create_scheduled_task",
            input: .object(["prompt": .string("Go."), "fireAt": .string("2026-10-18T09:00:00+09:00"),
                            "harness": .string("codex"), "permissionMode": .string("dangerFullAccess")])))
        XCTAssertTrue(onCodex.detail.contains(L10n.format("Its runs will use %@ mode.", L10n.string("Full access"))),
                      "In the words of Codex's own control: \(onCodex.detail)")
        XCTAssertNil(ScheduleToolApproval.request(toolName: "mcp__scheduled-tasks__create_scheduled_task",
                                                  input: .object([:])), "The Claude app's own tool is its own")
        XCTAssertNil(ScheduleToolApproval.request(toolName: "mcp__yardlet__list_task_runs", input: .object([:])))
    }

    // MARK: - Through the broker

    func testTheBrokerListsTheToolsAndCreatesListsUpdatesRunsAndDeletesForTheCallingTask() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: URL(filePath: "/bin/sh"), endpoint: "/tmp/Yardlet-tools-test/tools.sock",
                privateDirectory: URL(filePath: "/tmp/Yardlet-tools-test"), isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) }))
        broker.schedules = model
        let launch = try XCTUnwrap(broker.agentToolServer(for: fixture.caller.id, workspaceRoots: []),
                                   "The scheduled-task tools alone are reason to inject the server")
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> AgentToolResult {
            await broker.handle(AgentToolCall(token: token, session: fixture.caller.id.uuidString, tool: tool,
                                              arguments: try suggestionToolJSON(arguments)))
        }
        let list = await broker.list(AgentToolCall(token: token, session: fixture.caller.id.uuidString, tool: "",
                                                   arguments: .object([:]), method: AgentToolCall.listMethod))
        XCTAssertEqual(list?.tools.compactMap { $0["name"]?.stringValue }, ScheduleToolCatalog.tools.map(\.name))

        // Create: what arrives was allowed by the harness, so it is made at once; Yardlet asks nothing more.
        let created = try await call("create_scheduled_task", [
            "name": "Nightly digest", "prompt": "Summarize today's merged pull requests.", "cronExpression": "30 21 * * 1-5"
        ])
        XCTAssertFalse(created.isError, created.text)
        XCTAssertTrue(model.approvalsAreEmpty(in: fixture.caller.id), "Yardlet adds no card of its own")
        XCTAssertEqual(fixture.notifications.posts, [], "An OpenCode caller is not the Claude app's unasked case")
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        XCTAssertEqual(schedule.name, "Nightly digest")
        XCTAssertEqual(schedule.prompt, "Summarize today's merged pull requests.")
        XCTAssertEqual(schedule.trigger, .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 21, minute: 30)))
        XCTAssertTrue(schedule.isEnabled)
        XCTAssertEqual(ScheduleToolCatalog.created(inResult: created.text)?.scheduleID, schedule.id.uuidString)
        XCTAssertEqual(ScheduleToolCatalog.created(inResult: created.text)?.name, "Nightly digest")
        XCTAssertTrue(created.text.hasPrefix("Scheduled task \"Nightly digest\" created in Yardlet (scheduleId: "), created.text)
        XCTAssertTrue(created.text.contains("**Schedule:** weekdays at 21:30"), created.text)
        XCTAssertTrue(created.text.contains("**Next run:** 2026-10-19T21:30:00+09:00"),
                      "Saturday evening's next weekday run is Monday's, in local time: \(created.text)")
        XCTAssertTrue(created.text.contains("**Each run:** a new OpenCode task in "), created.text)

        // List.
        let listed = try await call("list_scheduled_tasks", [:])
        XCTAssertFalse(listed.isError, listed.text)
        let entries = try JSONDecoder().decode(Listing.self, from: Data(listed.text.utf8)).scheduledTasks
        XCTAssertEqual(entries.map(\.scheduleId), [schedule.id.uuidString])
        XCTAssertEqual(entries.first?.harness, "opencode")
        XCTAssertEqual(entries.first?.eachRun, "new task")
        XCTAssertEqual(entries.first?.cronExpression, "30 21 * * 1,2,3,4,5")
        XCTAssertEqual(entries.first?.nextRunAt, "2026-10-19T21:30:00+09:00")
        XCTAssertEqual(entries.first?.enabled, true)

        // Update: a new time, a new prompt, then pause and resume.
        let updated = try await call("update_scheduled_task", [
            "scheduleId": schedule.id.uuidString, "cronExpression": "0 8 * * *", "prompt": "Summarize yesterday's merges."
        ])
        XCTAssertFalse(updated.isError, updated.text)
        XCTAssertTrue(updated.text.contains("updated: prompt, schedule (every day at 08:00)"), updated.text)
        let changed = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id))
        XCTAssertEqual(changed.trigger, .daily(ScheduleTime(hour: 8, minute: 0)))
        XCTAssertEqual(changed.prompt, "Summarize yesterday's merges.")
        XCTAssertEqual(changed.name, "Nightly digest", "A field left out stays")
        XCTAssertEqual(changed.destination, schedule.destination, "Where it runs stays")
        let paused = try await call("update_scheduled_task", ["scheduleId": schedule.id.uuidString, "enabled": false])
        XCTAssertTrue(paused.text.contains("updated: paused"), paused.text)
        XCTAssertEqual(model.scheduledTasks.schedule(id: schedule.id)?.isEnabled, false)
        _ = try await call("update_scheduled_task", ["scheduleId": schedule.id.uuidString, "enabled": true])
        XCTAssertEqual(model.scheduledTasks.schedule(id: schedule.id)?.isEnabled, true)
        let nothing = try await call("update_scheduled_task", ["scheduleId": schedule.id.uuidString])
        XCTAssertTrue(nothing.isError && nothing.text.contains("give at least one of"), nothing.text)

        // Run now: a task through the new-task path, and the run in its history.
        let ran = try await call("run_scheduled_task", ["scheduleId": schedule.id.uuidString])
        XCTAssertFalse(ran.isError, ran.text)
        let run = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.state.runs.first)
        XCTAssertEqual(run.trigger, .manual)
        XCTAssertEqual(run.outcome, .started)
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == run.taskID })
        XCTAssertTrue(ran.text.contains("it started task \(task.id.uuidString)"), ran.text)
        XCTAssertEqual(task.parentTaskID, fixture.caller.id, "Its runs nest under the task that made it")
        XCTAssertNotEqual(model.store.selectedSessionID, task.id, "A run starts beside the person's work")
        // The agent's prompt reaches the run as the message of the task that made it, its parent.
        let prompts = await fixture.adapter.prompts
        XCTAssertEqual(prompts, [TaskMessage(senderID: fixture.caller.id.uuidString, senderName: "Deploy watch",
                                             body: "Summarize yesterday's merges.", relation: .parent).text(in: .yardlet)])
        XCTAssertEqual(model.sessionToolDepth(of: task.id), 1, "A run nests one below the task whose schedule started it")
        let runs = try await call("list_task_runs", ["scheduleId": schedule.id.uuidString])
        let history = try JSONDecoder().decode(Runs.self, from: Data(runs.text.utf8))
        XCTAssertEqual(history.totalRuns, 1)
        XCTAssertEqual(history.runs.first?.trigger, "manual")
        XCTAssertEqual(history.runs.first?.outcome, "started")
        XCTAssertEqual(history.runs.first?.taskId, task.id.uuidString)
        XCTAssertEqual(history.runs.first?.taskLink, SessionToolText.link(title: task.title, taskID: task.id))

        // A second run while the first one's task still works is skipped and says why.
        try await model.store.updateSession(id: task.id, status: .running)
        let busy = try await call("run_scheduled_task", ["scheduleId": schedule.id.uuidString])
        XCTAssertTrue(busy.isError)
        XCTAssertTrue(busy.text.contains("still working"), busy.text)

        // Delete.
        let deleted = try await call("delete_scheduled_task", ["scheduleId": schedule.id.uuidString])
        XCTAssertFalse(deleted.isError, deleted.text)
        XCTAssertTrue(model.scheduledTasks.schedules.isEmpty)
        XCTAssertTrue(model.store.sessions.contains { $0.id == task.id }, "The run's task stays")
        let gone = try await call("run_scheduled_task", ["scheduleId": schedule.id.uuidString])
        XCTAssertTrue(gone.isError)
        let empty = try await call("list_scheduled_tasks", [:])
        XCTAssertEqual(empty.text, "No scheduled tasks in Yardlet.")

        let forged = await broker.handle(AgentToolCall(token: "wrong", session: fixture.caller.id.uuidString,
                                                       tool: "create_scheduled_task",
                                                       arguments: try suggestionToolJSON(["prompt": "x", "fireAt": "2027-01-01T00:00:00Z"])))
        XCTAssertTrue(forged.isError, "A call without the task's token makes nothing")
        XCTAssertTrue(model.scheduledTasks.schedules.isEmpty)
        await model.shutdown()
    }

    /// The list gives what will run first, soonest first, then what is off, with the start of each prompt;
    /// the one-offs that ran only when asked, and a whole prompt for one schedule named by its id.
    func testTheListGivesWhatRunsFirstAndLeavesOutTheOneOffsThatRanUnlessAsked() async throws {
        func schedule(_ name: String, _ trigger: ScheduleTrigger, prompt: String? = nil) -> ScheduledTask {
            ScheduledTask(name: name, prompt: prompt ?? "\(name).", trigger: trigger,
                          destination: ScheduleDestination(harness: .openCode, workspacePath: root.path), createdAt: date(17, 20))
        }
        let long = String(repeating: "Read the failing job's log and say what broke. ", count: 20)
        let digest = schedule("Digest", .daily(ScheduleTime(hour: 9, minute: 0)), prompt: long)
        let soon = schedule("Check CI", .once(date(17, 21)))
        var paused = schedule("Cleanup", .daily(ScheduleTime(hour: 18, minute: 0)))
        paused.isEnabled = false
        var ran = schedule("Check CI earlier", .once(date(17, 19)))
        ran.isEnabled = false
        ran.state.stopReason = .finished
        ran.state.lastRunAt = date(17, 19)
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20), repository: InMemoryScheduledTaskRepository(
            snapshot: ScheduleSnapshot(schedules: [ran, paused, digest, soon])))
        let model = fixture.model

        let listed = try JSONDecoder().decode(Listing.self, from: Data(
            await call(model, "list_scheduled_tasks", [:], from: fixture.caller).text.utf8))
        XCTAssertEqual(listed.scheduledTasks.map(\.name), ["Check CI", "Digest", "Cleanup"])
        XCTAssertEqual(listed.finishedNotListed, 1)
        let cut = try XCTUnwrap(listed.scheduledTasks.first { $0.name == "Digest" }?.prompt)
        XCTAssertEqual(cut, String(long.prefix(ScheduleToolCatalog.listedPromptLength)) + "…")
        XCTAssertTrue(listed.note?.contains("scheduleId gives it whole") == true, listed.note ?? "")
        XCTAssertEqual(listed.scheduledTasks.first?.prompt, "Check CI.", "A short prompt is whole")

        let all = try JSONDecoder().decode(Listing.self, from: Data(
            await call(model, "list_scheduled_tasks", ["includeFinished": true], from: fixture.caller).text.utf8))
        XCTAssertEqual(all.scheduledTasks.map(\.name), ["Check CI", "Digest", "Cleanup", "Check CI earlier"])
        XCTAssertEqual(all.scheduledTasks.last?.stoppedBecause, "it ran once")
        XCTAssertNil(all.finishedNotListed)

        let one = try JSONDecoder().decode(Listing.self, from: Data(
            await call(model, "list_scheduled_tasks", ["scheduleId": digest.id.uuidString], from: fixture.caller).text.utf8))
        XCTAssertEqual(one.scheduledTasks.map(\.prompt), [long])
        XCTAssertNil(one.note)
        let finished = try JSONDecoder().decode(Listing.self, from: Data(
            await call(model, "list_scheduled_tasks", ["scheduleId": ran.id.uuidString], from: fixture.caller).text.utf8))
        XCTAssertEqual(finished.scheduledTasks.map(\.name), ["Check CI earlier"], "Named by its id, a finished one is given")
        let unknown = await call(model, "list_scheduled_tasks", ["scheduleId": UUID().uuidString], from: fixture.caller)
        XCTAssertTrue(unknown.isError, unknown.text)
        await model.shutdown()
    }

    // MARK: - Defaults from the caller

    func testANewScheduleTakesTheCallersHarnessFolderProjectAndAccount() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let result = await call(model, "create_scheduled_task",
                                ["prompt": "Check the release checklist.", "fireAt": "2026-10-18T09:15:00+09:00"],
                                from: fixture.claude)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("**Will run once at:** 2026-10-18T09:15:00+09:00"), result.text)
        XCTAssertTrue(result.text.contains("in the default permission mode"), result.text)
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        XCTAssertEqual(schedule.trigger, .once(date(18, 9, 15)))
        XCTAssertEqual(schedule.name, SessionTitleProjection.provisionalTitle(from: "Check the release checklist."))
        let destination = schedule.destination
        XCTAssertEqual(destination.mode, .newTask)
        XCTAssertEqual(destination.harness, .claudeCode)
        XCTAssertEqual(destination.workspacePath, ProjectSidebarPresentation.normalizedPath(for: fixture.app.primaryRoot),
                       "A caller in a worktree schedules in the folder it came from (the Claude app's originCwd)")
        XCTAssertEqual(destination.projectID, fixture.app.id)
        XCTAssertEqual(destination.accountID, fixture.connection.id, "The caller's account")
        XCTAssertNil(destination.modelChoice, "The harness's model, and Accept edits is not carried over")
        XCTAssertFalse(destination.startsInNewWorktree)
        XCTAssertEqual(destination.parentTaskID, fixture.claude.id)
        XCTAssertEqual(fixture.notifications.posts, [], "A caller in Accept edits saw Claude Code's card")

        // Chosen values win; another harness does not take the caller's account.
        let other = await call(model, "create_scheduled_task", [
            "prompt": "Triage new issues.", "cronExpression": "0 */6 * * *", "harness": "opencode",
            "project": "site", "useWorktree": true
        ], from: fixture.claude)
        XCTAssertFalse(other.isError, other.text)
        let second = try XCTUnwrap(model.scheduledTasks.schedules.last)
        XCTAssertEqual(second.destination.harness, .openCode)
        XCTAssertEqual(second.destination.projectID, fixture.site.id)
        XCTAssertNil(second.destination.accountID, "The harness's new-task account when the run starts")
        XCTAssertNil(second.destination.modelChoice)
        XCTAssertTrue(second.destination.startsInNewWorktree)
        guard case let .interval(hours, anchor, days) = second.trigger else { return XCTFail("\(second.trigger)") }
        XCTAssertEqual(hours, 6)
        XCTAssertTrue(days.isEmpty)
        XCTAssertEqual(seoul.component(.hour, from: anchor) % 6, 0, "Cron's hours: 0, 6, 12, 18")

        let chosen = await call(model, "create_scheduled_task", [
            "prompt": "Write the weekly notes.", "cronExpression": "0 17 * * 5", "model": "claude-opus-5-5",
            "effort": "high", "permissionMode": "default"
        ], from: fixture.claude)
        XCTAssertFalse(chosen.isError, chosen.text)
        XCTAssertEqual(model.scheduledTasks.schedules.last?.destination.modelChoice,
                       NewTaskModelChoice(model: "claude-opus-5-5", effort: "high", permissionMode: ClaudePermissionMode.manual))
        let raised = await call(model, "create_scheduled_task", [
            "prompt": "Clean up.", "cronExpression": "0 3 * * *", "permissionMode": "bypassPermissions"
        ], from: fixture.claude)
        XCTAssertTrue(raised.isError, "A schedule does no more without asking than the task that makes it")
        XCTAssertTrue(raised.text.contains("lets each run do more without asking than this task may"), raised.text)
        let auto = await call(model, "create_scheduled_task", [
            "prompt": "Clean up.", "cronExpression": "0 3 * * *", "permissionMode": "auto"
        ], from: fixture.claude)
        XCTAssertTrue(auto.isError, "Nor in a mode freer than the caller's own: \(auto.text)")
        XCTAssertEqual(model.scheduledTasks.schedules.count, 3)

        // Codex's permissions in Codex's own values, no freer than the caller's (a harness's default asks): Approve for
        // me lets a reviewer answer for the person, as Auto does, and Full access asks nothing.
        for freer in ["approveForMe", "dangerFullAccess", "custom"] {
            let refused = await call(model, "create_scheduled_task", [
                "prompt": "Clean up.", "cronExpression": "0 3 * * *", "harness": "codex", "permissionMode": freer
            ], from: fixture.caller)
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("lets each run do more without asking than this task may"), refused.text)
        }
        let claudeWords = await call(model, "create_scheduled_task", [
            "prompt": "Clean up.", "cronExpression": "0 3 * * *", "harness": "codex", "permissionMode": "plan"
        ], from: fixture.caller)
        XCTAssertTrue(claudeWords.text.contains(
            "must be one of askForApproval, approveForMe, dangerFullAccess, custom, readOnly"), claudeWords.text)
        let readOnly = await call(model, "create_scheduled_task", [
            "prompt": "Read the logs.", "cronExpression": "0 3 * * *", "harness": "codex", "permissionMode": "readOnly"
        ], from: fixture.caller)
        XCTAssertFalse(readOnly.isError, readOnly.text)
        XCTAssertTrue(readOnly.text.contains("a new Codex task in"), readOnly.text)
        XCTAssertTrue(readOnly.text.contains("in readOnly mode"), readOnly.text)
        let codexSchedule = try XCTUnwrap(model.scheduledTasks.schedules.last)
        XCTAssertEqual(codexSchedule.destination.modelChoice, NewTaskModelChoice(model: nil, permissionMode: "readOnly"))
        XCTAssertEqual(model.scheduleToolEntry(codexSchedule).permissionMode, "readOnly")
        let plain = await call(model, "create_scheduled_task", [
            "prompt": "Read the logs.", "cronExpression": "0 4 * * *", "harness": "codex"
        ], from: fixture.caller)
        XCTAssertTrue(plain.text.contains("in askForApproval mode"), plain.text)
        XCTAssertNil(model.scheduledTasks.schedules.last?.destination.modelChoice, "Ask for approval, as before")
        XCTAssertEqual(model.scheduledTasks.schedules.count, 5)
        await model.shutdown()
    }

    /// The choices Scheduled tasks' editor has, for an agent: "Chat (no project)", whose runs each start
    /// in a folder of their own, and a top-level task nested under none, as a schedule made there starts.
    func testAScheduleRunsAsAChatOrATopLevelTaskAsOneMadeInScheduledTasksDoes() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let created = await call(model, "create_scheduled_task", [
            "prompt": "Review the week's notes.", "cronExpression": "0 9 * * 1", "chat": true, "topLevel": true
        ], from: fixture.caller)
        XCTAssertFalse(created.isError, created.text)
        XCTAssertTrue(created.text.contains("task in a new chat folder"), created.text)
        XCTAssertTrue(created.text.contains("as a top-level task"), created.text)
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        XCTAssertNil(schedule.destination.workspacePath)
        XCTAssertNil(schedule.destination.projectID)
        XCTAssertNil(schedule.destination.parentTaskID)
        XCTAssertEqual(schedule.destination.harness, .openCode, "Still the caller's harness")
        let draft = ScheduleDraft(editing: schedule, now: date(17, 20), calendar: seoul)
        XCTAssertEqual(draft.place, .chat, "The editor reads it as its own Chat (no project)")
        XCTAssertNil(draft.parentTaskID)

        let ran = await call(model, "run_scheduled_task", ["scheduleId": schedule.id.uuidString], from: fixture.caller)
        XCTAssertFalse(ran.isError, ran.text)
        let taskID = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.state.runs.first?.taskID)
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == taskID })
        XCTAssertNil(task.projectID)
        XCTAssertTrue(model.projects.isChatFolder(task.workspaceURL), task.workspaceURL.path())
        XCTAssertNil(task.parentTaskID, "A top-level task")

        // Into a project and under this task again, then back to a chat, then to this task's folder.
        let id = schedule.id.uuidString
        // Another project asks first, as `create_task` would, since the caller's harness did not.
        let moving = Task { await self.call(model, "update_scheduled_task", ["scheduleId": id, "project": "site",
                                                                              "useWorktree": true, "topLevel": false],
                                            from: fixture.caller) }
        let card = try await waitForApproval(in: fixture.caller.id, model: model)
        XCTAssertEqual(card.request.title, L10n.string("Schedule a task in another project"))
        XCTAssertTrue(model.sessionTools.answer(card.id, allow: true))
        let moved = await moving.value
        XCTAssertTrue(moved.text.contains("updated: where each run goes"), moved.text)
        var destination = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.destination)
        XCTAssertEqual(destination.projectID, fixture.site.id)
        XCTAssertEqual(destination.parentTaskID, fixture.caller.id)
        _ = await call(model, "update_scheduled_task", ["scheduleId": id, "chat": true], from: fixture.caller)
        destination = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.destination)
        XCTAssertNil(destination.workspacePath)
        XCTAssertNil(destination.projectID)
        XCTAssertFalse(destination.startsInNewWorktree, "A chat has no repository")
        XCTAssertEqual(destination.parentTaskID, fixture.caller.id, "Left out, the nesting stays")
        _ = await call(model, "update_scheduled_task", ["scheduleId": id, "chat": false], from: fixture.caller)
        destination = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.destination)
        XCTAssertEqual(destination.workspacePath, ProjectSidebarPresentation.normalizedPath(for: fixture.app.primaryRoot))
        XCTAssertEqual(destination.projectID, fixture.app.id)
        await model.shutdown()
    }

    func testACallerInAutoOrBypassCarriesItsModeAndIsTold() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20), claudeMode: "bypassPermissions")
        let model = fixture.model
        let result = await call(model, "create_scheduled_task", [
            "name": "Nightly cleanup", "prompt": "Remove stale branches.", "cronExpression": "0 2 * * *"
        ], from: fixture.claude)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("in bypassPermissions mode"), result.text)
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        XCTAssertEqual(schedule.destination.modelChoice?.permissionMode, ClaudePermissionMode.bypassPermissions)
        // No card was shown, so the person is told, as the Claude app's notice tells them.
        let post = try XCTUnwrap(fixture.notifications.posts.first)
        XCTAssertEqual(post.title, L10n.format("%@ scheduled a task: “%@”", "Claude Code", "Nightly cleanup"))
        XCTAssertEqual(post.body, L10n.format("Its runs will use %@ mode.", L10n.string("Bypass permissions")))
        XCTAssertEqual(post.target.sessionID, fixture.claude.id)
        let raised = await call(model, "create_scheduled_task", [
            "prompt": "Clean up.", "cronExpression": "0 3 * * *", "permissionMode": "bypassPermissions"
        ], from: fixture.claude)
        XCTAssertFalse(raised.isError, "A caller that runs without asking may choose it: \(raised.text)")

        // A task that asks may not schedule messages into one that does not, unless the person agrees on its card.
        let count = model.scheduledTasks.schedules.count
        let into = Task { await self.call(model, "create_scheduled_task", [
            "prompt": "Deploy now.", "fireAt": "2026-10-18T09:00:00+09:00", "continueTaskId": fixture.claude.id.uuidString
        ], from: fixture.caller) }
        let card = try await waitForApproval(in: fixture.caller.id, model: model)
        XCTAssertEqual(card.request.title, L10n.string("Schedule messages to a task that runs without asking"))
        XCTAssertTrue(card.request.detail?.contains("Deploy watch → Release prep") == true, card.request.detail ?? "")
        XCTAssertTrue(model.sessionTools.answer(card.id, allow: false))
        let refusedInto = await into.value
        XCTAssertTrue(refusedInto.isError && refusedInto.text.contains("did not approve"), refusedInto.text)
        XCTAssertEqual(model.scheduledTasks.schedules.count, count)

        // The person's own Bypass schedule: an agent that asks may not put its words into it, and a change of name
        // alone leaves the person's prompt theirs.
        var destination = ScheduleDestination(harness: .claudeCode)
        destination.modelChoice = NewTaskModelChoice(model: nil, permissionMode: ClaudePermissionMode.bypassPermissions)
        model.scheduledTasks.create(ScheduledTask(name: "Mine", prompt: "Prune old branches.",
                                                  trigger: .daily(ScheduleTime(hour: 4, minute: 0)), destination: destination))
        let mine = try XCTUnwrap(model.scheduledTasks.schedules.last)
        let rewritten = await call(model, "update_scheduled_task", ["scheduleId": mine.id.uuidString, "prompt": "Push to main."],
                                   from: fixture.caller)
        XCTAssertTrue(rewritten.isError && rewritten.text.contains("bypassPermissions mode"), rewritten.text)
        XCTAssertEqual(model.scheduledTasks.schedule(id: mine.id)?.prompt, "Prune old branches.")
        let renamed = await call(model, "update_scheduled_task", ["scheduleId": mine.id.uuidString, "name": "Prune"],
                                 from: fixture.caller)
        XCTAssertFalse(renamed.isError, renamed.text)
        XCTAssertNil(model.scheduledTasks.schedule(id: mine.id)?.agentTaskID)
        await model.shutdown()

        let auto = try Fixture(root: root, calendar: seoul, now: date(17, 20), claudeMode: "auto")
        _ = await call(auto.model, "create_scheduled_task", ["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00"],
                       from: auto.claude)
        XCTAssertEqual(auto.model.scheduledTasks.schedules.first?.destination.modelChoice?.permissionMode, "auto")
        XCTAssertEqual(auto.notifications.posts.count, 1)
        // Auto is the standard level, so a Codex schedule's runs keep Ask for approval.
        _ = await call(auto.model, "create_scheduled_task", ["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00",
                                                             "harness": "codex"], from: auto.claude)
        XCTAssertNil(auto.model.scheduledTasks.schedules.last?.destination.modelChoice)
        // Approve for me lets Codex's reviewer answer for the person as Auto's classifier does, so Auto may name it;
        // Full access it may not.
        let approved = await call(auto.model, "create_scheduled_task", [
            "prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "harness": "codex", "permissionMode": "approveForMe"
        ], from: auto.claude)
        XCTAssertFalse(approved.isError, approved.text)
        XCTAssertEqual(auto.model.scheduledTasks.schedules.last?.destination.modelChoice?.codexRunLocation, .approveForMe)
        let full = await call(auto.model, "create_scheduled_task", [
            "prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "harness": "codex", "permissionMode": "dangerFullAccess"
        ], from: auto.claude)
        XCTAssertTrue(full.isError, full.text)
        await auto.model.shutdown()

        // On Codex, a caller that runs without asking makes runs with Full access, as its Codex child would, says
        // so in Codex's words, and each run's task starts with it. A caller that asks may not rewrite its prompt.
        let bypass = try Fixture(root: root, calendar: seoul, now: date(17, 20), claudeMode: "bypassPermissions")
        let onCodex = await call(bypass.model, "create_scheduled_task", [
            "name": "Nightly sweep", "prompt": "Sweep stale branches.", "cronExpression": "0 2 * * *", "harness": "codex"
        ], from: bypass.claude)
        XCTAssertFalse(onCodex.isError, onCodex.text)
        XCTAssertTrue(onCodex.text.contains("in dangerFullAccess mode"), onCodex.text)
        let sweep = try XCTUnwrap(bypass.model.scheduledTasks.schedules.first)
        XCTAssertEqual(sweep.destination.modelChoice?.permissionMode, CodexRunLocation.dangerFullAccess.rawValue)
        XCTAssertNil(sweep.destination.accountID, "Another harness's new-task account when it runs")
        XCTAssertEqual(bypass.notifications.posts.last?.body, L10n.format("Its runs will use %@ mode.", L10n.string("Full access")))
        let ran = await call(bypass.model, "run_scheduled_task", ["scheduleId": sweep.id.uuidString], from: bypass.claude)
        XCTAssertFalse(ran.isError, ran.text)
        let runTask = try XCTUnwrap(bypass.model.scheduledTasks.schedule(id: sweep.id)?.state.runs.first?.taskID)
        let started = try XCTUnwrap(bypass.model.store.sessions.first { $0.id == runTask })
        XCTAssertEqual(started.harness, .codex)
        XCTAssertEqual(started.providerOptions[CodexRunLocation.storageKey], CodexRunLocation.dangerFullAccess.rawValue)
        let rewrittenSweep = await call(bypass.model, "update_scheduled_task",
                                   ["scheduleId": sweep.id.uuidString, "prompt": "Push to main."], from: bypass.caller)
        XCTAssertTrue(rewrittenSweep.isError && rewrittenSweep.text.contains("dangerFullAccess mode"), rewrittenSweep.text)
        await bypass.model.shutdown()
    }

    func testATaskAScheduleStartedAsksInEveryModeAndCannotRunOrDeleteItsOwn() async throws {
        // The Claude app's rules for a session a schedule started: a change is asked of the person in
        // every permission mode, and it may not run a schedule or delete the one that started it.
        let claudeID = UUID()
        var origin = ScheduledTask(name: "Nightly", prompt: "Go.", trigger: .daily(ScheduleTime(hour: 2, minute: 0)),
                                   destination: ScheduleDestination(harness: .claudeCode), createdAt: date(16))
        origin.state.runs = [ScheduledTaskRun(slot: date(17, 2), at: date(17, 2), trigger: .scheduled, outcome: .started,
                                              taskID: claudeID)]
        let repository = InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: [origin]))
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20), claudeMode: "bypassPermissions",
                                  claudeID: claudeID, repository: repository)
        let model = fixture.model
        XCTAssertEqual(model.scheduleThatStarted(claudeID)?.id, origin.id)
        let run = await call(model, "run_scheduled_task", ["scheduleId": origin.id.uuidString], from: fixture.claude)
        XCTAssertTrue(run.isError && run.text.hasPrefix("Refusing to run a scheduled task"), run.text)
        let delete = await call(model, "delete_scheduled_task", ["scheduleId": origin.id.uuidString], from: fixture.claude)
        XCTAssertTrue(delete.isError && delete.text.hasPrefix("Refusing to delete the scheduled task whose run"), delete.text)
        XCTAssertNotNil(model.scheduledTasks.schedule(id: origin.id))

        // Bypass permissions would not ask, so Yardlet's own card does: refused, then allowed.
        let arguments: [String: Any] = ["name": "Follow-up", "prompt": "Check again.", "fireAt": "2026-10-18T09:00:00+09:00"]
        let refused = Task { await self.call(model, "create_scheduled_task", arguments, from: fixture.claude) }
        let first = try await waitForApproval(in: claudeID, model: model)
        XCTAssertEqual(first.request.title, L10n.format("Allow Claude to create the scheduled task “%@”?", "Follow-up"))
        XCTAssertTrue(model.sessionTools.answer(first.id, allow: false))
        let no = await refused.value
        XCTAssertTrue(no.isError && no.text.contains("needs the person's approval"), no.text)
        XCTAssertEqual(model.scheduledTasks.schedules.count, 1)
        let allowed = Task { await self.call(model, "create_scheduled_task", arguments, from: fixture.claude) }
        let second = try await waitForApproval(in: claudeID, model: model)
        XCTAssertTrue(model.sessionTools.answer(second.id, allow: true))
        let yes = await allowed.value
        XCTAssertFalse(yes.isError, yes.text)
        XCTAssertEqual(model.scheduledTasks.schedules.last?.name, "Follow-up")

        // A task the person started asks nothing more than its harness does.
        let other = await call(model, "update_scheduled_task", ["scheduleId": origin.id.uuidString, "enabled": false],
                               from: fixture.caller)
        XCTAssertFalse(other.isError, other.text)
        XCTAssertTrue(model.approvalsAreEmpty(in: fixture.caller.id))
        await model.shutdown()

        // A run that only continued a task leaves it the person's. The task that made a schedule continuing
        // itself, which now starts new tasks, asks nothing more (a run kept before runs said which they did),
        // and a run keeps what it did when the schedule's runs go elsewhere later.
        let ownID = UUID(), runID = UUID()
        var moved = ScheduledTask(name: "Check in", prompt: "Go.", trigger: .daily(ScheduleTime(hour: 12, minute: 0)),
                                  destination: ScheduleDestination(harness: .codex), createdAt: date(16),
                                  agentTaskID: ownID)
        moved.destination.parentTaskID = ownID
        moved.state.runs = [ScheduledTaskRun(slot: date(17, 12), at: date(17, 12), trigger: .scheduled,
                                             outcome: .started, taskID: ownID)]
        let own = try Fixture(root: root.appending(path: "own"), calendar: seoul, now: date(17, 20),
                              claudeMode: "bypassPermissions", claudeID: ownID,
                              repository: InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: [moved])))
        XCTAssertNil(own.model.scheduleThatStarted(ownID))
        XCTAssertFalse(own.model.scheduledTasks.scheduledTaskIDs.contains(ownID))
        let made = await call(own.model, "create_scheduled_task", arguments, from: own.claude)
        XCTAssertFalse(made.isError, made.text)
        XCTAssertTrue(own.model.approvalsAreEmpty(in: ownID))
        await own.model.shutdown()
        moved.destination = ScheduleDestination(mode: .continueTask, harness: .claudeCode)
        moved.destination.targetTaskID = ownID
        moved.state.runs.insert(ScheduledTaskRun(at: date(18, 12), trigger: .manual, outcome: .started, taskID: runID,
                                                 mode: .newTask), at: 0)
        XCTAssertTrue(moved.startedTask(runID))
        XCTAssertFalse(moved.startedTask(ownID))
    }

    private func waitForApproval(in taskID: UUID, model: AppModel) async throws -> SessionToolApproval {
        try await waitUntil { !model.sessionTools.approvals(for: taskID).isEmpty }
        return try XCTUnwrap(model.sessionTools.approvals(for: taskID).last)
    }

    func testRunHistoryReportsDeferredContinuationWithoutChangingManualRuns() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let created = await call(model, "create_scheduled_task", [
            "prompt": "Check the results", "fireAt": "2026-10-17T21:00", "continueTaskId": "self"
        ], from: fixture.caller)
        XCTAssertFalse(created.isError, created.text)
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        try await model.store.updateSession(id: fixture.caller.id, status: .running)
        fixture.clock.now = date(17, 21)
        await model.scheduledTasks.checkDue()
        let history = await call(model, "list_task_runs", ["scheduleId": schedule.id.uuidString], from: fixture.caller)
        XCTAssertTrue(history.text.contains("deferred"), history.text)
        let manual = await call(model, "run_scheduled_task", ["scheduleId": schedule.id.uuidString], from: fixture.caller)
        XCTAssertTrue(manual.isError)
        XCTAssertEqual(model.scheduledTasks.schedules[0].state.runs.first?.outcome, .skipped)
        XCTAssertTrue(model.scheduledTasks.schedules[0].isEnabled)
        fixture.clock.now = date(18, 21)
        await model.scheduledTasks.checkDue()
        let expired = await call(model, "list_task_runs", ["scheduleId": schedule.id.uuidString], from: fixture.caller)
        XCTAssertTrue(expired.text.contains("expired"), expired.text)
        await model.shutdown()
    }

    func testContinuingThisTaskTargetsTheCaller() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let result = await call(model, "create_scheduled_task", [
            "name": "Check back", "prompt": "Check whether the deploy finished.", "fireAt": "2026-10-17T21:00",
            "continueTaskId": "self"
        ], from: fixture.caller)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("**Each run:** the next message of task \(fixture.caller.id.uuidString) (Deploy watch)"),
                      result.text)
        let schedule = try XCTUnwrap(model.scheduledTasks.schedules.first)
        XCTAssertEqual(schedule.trigger, .once(date(17, 21)), "No offset is the Mac's local time")
        XCTAssertEqual(schedule.destination.mode, .continueTask)
        XCTAssertEqual(schedule.destination.targetTaskID, fixture.caller.id)
        XCTAssertEqual(schedule.destination.harness, fixture.caller.harness)

        let refused = await call(model, "create_scheduled_task", [
            "prompt": "x", "fireAt": "2026-10-17T21:00", "continueTaskId": "self", "model": "gpt-5"
        ], from: fixture.caller)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("continues a task uses that task's own"), refused.text)

        // Switching it to a new task each run takes the caller's folder again.
        let switched = await call(model, "update_scheduled_task", [
            "scheduleId": schedule.id.uuidString, "harness": "opencode"
        ], from: fixture.caller)
        XCTAssertFalse(switched.isError, switched.text)
        XCTAssertEqual(model.scheduledTasks.schedule(id: schedule.id)?.destination.mode, .newTask)
        XCTAssertEqual(model.scheduledTasks.schedule(id: schedule.id)?.destination.projectID, fixture.app.id)
        _ = await call(model, "update_scheduled_task", ["scheduleId": schedule.id.uuidString, "continueTaskId": "self"],
                       from: fixture.caller)

        // The run is the caller's next message.
        fixture.clock.now = date(17, 21, 0)
        await model.scheduledTasks.checkDue()
        let run = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.state.runs.first)
        XCTAssertEqual(run.outcome, .started)
        XCTAssertEqual(run.taskID, fixture.caller.id)
        // An agent's prompt arrives as its task's own scheduled message, not as the person's.
        let prompts = await fixture.adapter.prompts
        XCTAssertEqual(prompts, [TaskMessage(senderID: fixture.caller.id.uuidString, senderName: "Deploy watch",
                                             body: "Check whether the deploy finished.", relation: .itself).text(in: .yardlet)])
        XCTAssertEqual(TaskMessage.parse(prompts.first ?? "")?.relation, .itself)
        await model.shutdown()
    }

    func testCallsThatCannotBeScheduledAreRefusedAndChangeNothing() async throws {
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20))
        let model = fixture.model
        let cases: [([String: Any], String)] = [
            (["prompt": "  "], "prompt is required"),
            (["prompt": "Go."], "give cronExpression (repeating) or fireAt (one run)"),
            (["prompt": "Go.", "cronExpression": "*/5 * * * *"], "Yardlet cannot repeat"),
            (["prompt": "Go.", "cronExpression": "0 9 1 * *"], "Yardlet cannot repeat"),
            (["prompt": "Go.", "cronExpression": "0 9 * * *", "fireAt": "2026-10-18T09:00:00+09:00"], "not both"),
            (["prompt": "Go.", "fireAt": "2026-10-17T19:00:00+09:00"], "must be in the future"),
            (["prompt": "Go.", "fireAt": "tomorrow"], "invalid fireAt"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "harness": "nope"], "no harness"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "project": "nowhere"], "no project"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "continueTaskId": UUID().uuidString], "no task"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "permissionMode": "plan"], "is for Claude Code"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "chat": true, "project": "site"], "takes no project"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "chat": true, "useWorktree": true],
             "no repository for a worktree"),
            (["prompt": "Go.", "fireAt": "2026-10-18T09:00:00+09:00", "continueTaskId": "self", "topLevel": true],
             "is for a new task each run"),
            (["prompt": String(repeating: "a", count: 32_001), "fireAt": "2026-10-18T09:00:00+09:00"], "longer than")
        ]
        for (arguments, words) in cases {
            let result = await call(model, "create_scheduled_task", arguments, from: fixture.caller)
            XCTAssertTrue(result.isError, "\(arguments.keys.sorted()): \(result.text)")
            XCTAssertTrue(result.text.hasPrefix("Nothing was created: "), result.text)
            XCTAssertTrue(result.text.contains(words), "\(words) ← \(result.text)")
        }
        XCTAssertTrue(model.scheduledTasks.schedules.isEmpty)
        for tool in ["update_scheduled_task", "delete_scheduled_task", "run_scheduled_task", "list_task_runs"] {
            let missing = await call(model, tool, [:], from: fixture.caller)
            XCTAssertTrue(missing.isError && missing.text.contains("scheduleId is required"), "\(tool): \(missing.text)")
            let unknown = await call(model, tool, ["scheduleId": UUID().uuidString], from: fixture.caller)
            XCTAssertTrue(unknown.isError && unknown.text.contains("list_scheduled_tasks gives the ids"), unknown.text)
        }
        let stranger = await model.callScheduleTool(named: "create_scheduled_task",
                                                    arguments: try suggestionToolJSON(["prompt": "Go."]), callerID: UUID())
        XCTAssertTrue(stranger.isError, "A call from no task makes nothing")
        await model.shutdown()
    }

    // MARK: - Persistence

    func testAScheduleAnAgentMadeIsKeptInYardletsFileAcrossARelaunch() async throws {
        let file = root.appending(path: ".yardlet/schedules.json")
        let fixture = try Fixture(root: root, calendar: seoul, now: date(17, 20),
                                  repository: FileScheduledTaskRepository(fileURL: file))
        let result = await call(fixture.model, "create_scheduled_task", [
            "name": "Morning check", "prompt": "Check the overnight builds.", "cronExpression": "0 9 * * *"
        ], from: fixture.claude)
        XCTAssertFalse(result.isError, result.text)
        let made = fixture.model.scheduledTasks.schedules
        await fixture.model.shutdown()

        let reopened = ScheduledTaskCenter(repository: FileScheduledTaskRepository(fileURL: file))
        XCTAssertEqual(reopened.schedules, made)
        XCTAssertEqual(reopened.schedules.first?.name, "Morning check")
        XCTAssertEqual(ScheduleNameDirectory.shared.name(of: try XCTUnwrap(made.first?.id)), "Morning check",
                       "The request card reads names the scheduler keeps")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("Check the overnight builds."))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["schedules.json"], "Nothing else is written")
    }

    // MARK: - The conversation

    func testTheConversationReadsYardletsCreateAnswerAsTheScheduleItMade() throws {
        let id = UUID()
        let answer = ScheduleToolCatalog.createdResult(scheduleID: id.uuidString, name: "Morning\n\"check\"",
                                                       body: "**Schedule:** every day at 09:00")
        XCTAssertEqual(ScheduleToolCatalog.created(inResult: answer)?.name, "Morning \"check\"", "One line, quotes kept")
        XCTAssertEqual(ScheduleToolCatalog.created(inResult: answer)?.scheduleID, id.uuidString)

        // Claude Code.
        let claude = HarnessActivity(id: "toolu_1", kind: "mcp__yardlet__create_scheduled_task",
                                     title: "mcp__yardlet__create_scheduled_task",
                                     input: #"{"prompt":"Check the builds.","cronExpression":"0 9 * * *"}"#, output: answer)
        guard case let .scheduleCreated(creation) = kind(of: claude) else { return XCTFail("\(kind(of: claude))") }
        XCTAssertEqual(creation, ConversationScheduleCreation(scheduleID: id, name: "Morning \"check\""))

        // The Claude app's own tool, in a conversation imported from it, stays a tool line.
        let imported = HarnessActivity(id: "toolu_2", kind: "mcp__scheduled-tasks__create_scheduled_task",
                                       title: "mcp__scheduled-tasks__create_scheduled_task", input: "{}",
                                       output: "Scheduled task \"morning-check\" created.\n\n**Task file:** ~/.claude/x")
        guard case .tool = kind(of: imported) else { return XCTFail("\(kind(of: imported))") }

        // Codex.
        let codexItem = CodexMCPToolItem(server: "yardlet", tool: "create_scheduled_task", status: "completed",
                                         arguments: .object(["prompt": .string("Check the builds.")]),
                                         result: .object(["content": .array([.object(["type": .string("text"),
                                                                                      "text": .string(answer)])])]),
                                         error: nil, pluginID: nil, durationMilliseconds: nil)
        XCTAssertEqual(ConversationScheduleProjection.creation(from: codexItem)?.scheduleID, id)
        let otherServer = CodexMCPToolItem(server: "codex_app", tool: codexItem.tool, status: codexItem.status,
                                           arguments: codexItem.arguments, result: codexItem.result, error: nil,
                                           pluginID: nil, durationMilliseconds: nil)
        XCTAssertNil(ConversationScheduleProjection.creation(from: otherServer))

        // A refused call is not a schedule.
        XCTAssertNil(ConversationScheduleProjection.creation(result: "Nothing was created: prompt is required."))
        let row = ConversationItem(id: "r", kind: .scheduleCreated(creation), phase: .completed,
                                   source: .transcript(TranscriptEntry(content: .activity(claude, state: .completed))))
        var turn = ConversationTurn(id: "t", status: .completed, timing: ConversationTurnTiming())
        turn.work = [row]
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.id), ["r"], "The person sees what the agent scheduled in a folded turn")
        let remote = try XCTUnwrap(RemoteConversationProjection.item(row, turnID: "t", harness: .claudeCode,
                                                                      workspaceURL: nil, inWork: true))
        XCTAssertEqual(remote.activity, "tool", "The phone has no Scheduled tasks to open")
        XCTAssertEqual(remote.title, L10n.format("Created scheduled task: %@", "Morning \"check\""))
    }

    // MARK: - Helpers

    private func kind(of activity: HarnessActivity) -> ConversationItemKind {
        ConversationActivityProjection.kind(activity, harness: .claudeCode, phase: .completed, isApproved: false)
    }

    private func call(_ model: AppModel, _ tool: String, _ arguments: [String: Any],
                      from caller: SessionRecord) async -> AgentToolResult {
        guard let json = try? suggestionToolJSON(arguments) else { return .error("arguments") }
        return await model.callScheduleTool(named: tool, arguments: json, callerID: caller.id)
    }

    private func canUseTool(id: String, tool: String, input: JSONValue, suggestions: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("control_request"), "request_id": .string(id),
            "request": .object([
                "subtype": .string("can_use_tool"), "tool_name": .string(tool), "input": input,
                "tool_use_id": .string("toolu-\(id)"), "permission_suggestions": .array(suggestions)
            ])
        ])
    }

    private actor PermissionRecorder {
        private var requests: [PermissionRequest] = []
        func append(_ request: PermissionRequest) { requests.append(request) }
        func waitFor(_ id: String) async throws -> PermissionRequest {
            let deadline = ContinuousClock.now + testWaitLimit
            while ContinuousClock.now < deadline {
                if let request = requests.last(where: { $0.id == id }) { return request }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw HarnessAdapterError.invalidProviderEvent("no permission request \(id)")
        }
    }

    private struct Entry: Decodable {
        var scheduleId: String
        var name: String = ""
        var harness: String
        var eachRun: String
        var cronExpression: String?
        var nextRunAt: String?
        var enabled: Bool
        var stoppedBecause: String?
        var prompt: String = ""
    }

    private struct Listing: Decodable {
        var scheduledTasks: [Entry]
        var finishedNotListed: Int?
        var note: String?
    }

    private struct Runs: Decodable {
        struct Run: Decodable {
            var trigger: String
            var outcome: String
            var taskId: String?
            var taskLink: String?
        }
        var totalRuns: Int
        var runs: [Run]
    }

    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// A model with two projects; an OpenCode caller (the stand-in harness runs its runs) and a Claude
    /// Code caller in a worktree of the app project, on a saved account, in Accept edits unless told.
    @MainActor
    final class Fixture {
        let app: Project
        let site: Project
        let caller: SessionRecord
        let claude: SessionRecord
        let connection: ProviderConnection
        let adapter = SuggestionRecordingAdapter()
        let notifications = ScheduleNotificationRecorder()
        let clock: Clock
        let model: AppModel

        init(root: URL, calendar: Calendar, now: Date, claudeMode: String = "acceptEdits", claudeID: UUID = UUID(),
             repository: any ScheduledTaskRepository = InMemoryScheduledTaskRepository()) throws {
            let appRoot = root.appending(path: "app", directoryHint: .isDirectory)
            let siteRoot = root.appending(path: "site", directoryHint: .isDirectory)
            let worktree = root.appending(path: "worktrees/app-fix", directoryHint: .isDirectory)
            for folder in [appRoot, siteRoot, worktree] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            app = Project(name: "app", primaryRoot: appRoot)
            site = Project(name: "site", primaryRoot: siteRoot)
            connection = ProviderConnection(id: "claude-work", name: "Work", harness: .claudeCode, providerID: nil,
                                            homePath: root.appending(path: "claude-home").path, credentialSelector: nil)
            let runtime = URL(filePath: "/usr/bin/true")
            caller = SessionRecord(harness: .openCode, workspaceURL: appRoot, runtimeExecutableURL: runtime,
                                   title: "Deploy watch", projectID: app.id)
            claude = SessionRecord(id: claudeID, harness: .claudeCode, workspaceURL: worktree, runtimeExecutableURL: runtime,
                                   title: "Release prep",
                                   providerOptions: [ClaudeLaunchOption.permissionMode: claudeMode,
                                                     ClaudeLaunchOption.model: "claude-sonnet-5"],
                                   connection: connection, projectID: app.id,
                                   originWorkspacePath: appRoot.path(percentEncoded: false), worktreeName: "app-fix")
            clock = Clock(now)
            let defaults = SuggestionVolatileDefaults()
            let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
            for harness in [HarnessKind.openCode, .claudeCode, .codex] { runtimes.select(runtime, for: harness) }
            let sessions = [caller, claude]
            let adapter = adapter
            model = AppModel(
                store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                runtimeSelections: runtimes,
                registry: HarnessRegistry { _, _ in adapter },
                preferences: defaults,
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                projectRepository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: [app, site])),
                scheduleRepository: repository,
                chatWorkspaceHome: root.appending(path: "home", directoryHint: .isDirectory),
                sessionTitleResolver: { _ in nil },
                sessionTitleRetryCount: 0,
                systemNotificationCenter: notifications,
                restoresIndexOnLaunch: false)
            let clock = clock
            model.scheduledTasks.now = { clock.now }
            model.scheduledTasks.calendar = { calendar }
        }
    }
}
