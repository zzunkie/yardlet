import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Suggested tasks (`spawn_task`, docs/AGENT_BROWSER_TOOLS.md, "Task suggestion tools"): the tools as the Yardlet MCP server lists them
/// and forwards them, the app's answers, the chip each harness's call becomes, where its Start starts
/// the task, what Do it here sends, the draft its Options opens and the task that draft starts, and
/// what the task keeps of each chip. No harness runs and no
/// model is contacted; the user's preferences are not touched (every store here is in memory).
@MainActor
final class TaskSuggestionTests: XCTestCase {
    private static let noted = TaskSuggestionToolCatalog.notedResult(taskID: "task_1a2b3c4d")
    private static let arguments: [String: Any] = [
        "title": "Remove the dead retry flag",
        "tldr": "The retry flag in the uploader is never read since the queue rewrite. The new task deletes it.",
        "prompt": "Delete `retryOnFailure` from Sources/Uploader/UploadOptions.swift and its two call sites.",
        "useWorktree": true
    ]

    // MARK: - The tools

    func testTheToolsAreNamedAndDescribedAsTheClaudeAppsAre() throws {
        let spawn = try XCTUnwrap(TaskSuggestionToolCatalog.definition(named: "spawn_task")).json
        XCTAssertTrue(spawn["description"]?.stringValue?.hasPrefix("Flag an out-of-scope issue for a separate task.") == true)
        XCTAssertTrue(spawn["description"]?.stringValue?.contains("call dismiss_task with it") == true)
        XCTAssertEqual(spawn["inputSchema"]?["required"], .array([.string("title"), .string("prompt"), .string("tldr")]))
        XCTAssertEqual(spawn["inputSchema"]?["properties"]?.objectValue?.keys.sorted(),
                       ["chat", "cwd", "parent_task_id", "prompt", "title", "tldr", "useWorktree"])
        XCTAssertEqual(spawn["inputSchema"]?["properties"]?["chat"]?["type"], .string("boolean"),
                       "New Task's \"No project\", which the Claude app's spawn_task does not have")
        XCTAssertTrue(spawn["inputSchema"]?["properties"]?["cwd"]?["description"]?.stringValue?
            .hasPrefix("Optional. Absolute path to a different project root") == true, "The Claude app's cwd")
        XCTAssertEqual(spawn["inputSchema"]?["properties"]?["useWorktree"]?["type"], .string("boolean"))
        XCTAssertEqual(spawn["annotations"]?["readOnlyHint"], .bool(true), "It only shows a chip")
        XCTAssertEqual(spawn["annotations"]?["openWorldHint"], .bool(false))
        XCTAssertEqual(spawn["annotations"]?["destructiveHint"], .bool(false))
        XCTAssertEqual(spawn["_meta"]?["anthropic/alwaysLoad"], .bool(true),
                       "Claude Code keeps it in the prompt, as the Claude app loads its spawn_task")
        XCTAssertEqual(spawn["_meta"]?["antigravity/alwaysLoad"], .bool(true), "Antigravity CLI 1.3.3 and later too")
        XCTAssertNil(AgentToolCatalog.browserTools.first?.json["_meta"], "The browser tools stay behind tool search")

        let dismiss = try XCTUnwrap(TaskSuggestionToolCatalog.definition(named: "dismiss_task")).json
        XCTAssertEqual(dismiss["inputSchema"]?["required"], .array([.string("task_id")]))
        XCTAssertEqual(dismiss["inputSchema"]?["properties"]?.objectValue?.keys.sorted(), ["reason", "task_id"])
        XCTAssertTrue(AgentToolCatalog.serverInstructions.contains("spawn_task"))
        XCTAssertEqual(Array(AgentToolServerLaunch.claudeAllowedTools.prefix(2)),
                       ["mcp__yardlet__spawn_task", "mcp__yardlet__dismiss_task"])

        let id = TaskSuggestionToolCatalog.newTaskID()
        XCTAssertTrue(TaskSuggestionToolCatalog.isTaskID(id), id)
        for bad in ["task_1A2B3C4D", "task_123", "task_1a2b3c4d5", "1a2b3c4d", "task_xyzxyzxy"] {
            XCTAssertFalse(TaskSuggestionToolCatalog.isTaskID(bad), bad)
        }
        XCTAssertEqual(TaskSuggestionToolCatalog.taskID(inResult: Self.noted), "task_1a2b3c4d")
        XCTAssertNil(TaskSuggestionToolCatalog.taskID(inResult: Self.claudeAppResult),
                     "The Claude app's own answer is not Yardlet's")
    }

    func testTheServerForwardsBothToolsToTheApp() async throws {
        let invoker = ForwardingInvoker()
        let server = MCPServer(version: "1", invoker: invoker)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"spawn_task","arguments":{"title":"T","prompt":"P","tldr":"S"}}}"#
        let handled = await server.handle(Data(request.utf8))
        let data = try XCTUnwrap(handled)
        let reply = try JSONDecoder().decode(ToolJSON.self, from: data)
        XCTAssertEqual(reply["result"]?["isError"], .bool(false))
        let dismiss = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"dismiss_task","arguments":{"task_id":"task_00000000"}}}"#
        _ = await server.handle(Data(dismiss.utf8))
        let calls = await invoker.calls
        XCTAssertEqual(calls.map(\.tool), ["spawn_task", "dismiss_task"])
        XCTAssertEqual(calls.first?.arguments["prompt"], .string("P"))
    }

    func testTheBrokerAnswersForTheCallingTaskAndEveryTaskGetsTheServer() async throws {
        let model = makeModel()
        let connectors = ClashingConnectors()
        let broker = makeBroker(browserTools: false)
        broker.suggestions = model
        broker.connectors = connectors
        let task = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: []),
                                   "With the browser tools off and no connector, a task still gets the chip tools")
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])

        let listed = await broker.list(AgentToolCall(token: token, session: task.uuidString, tool: "",
                                                     arguments: .object([:]), method: AgentToolCall.listMethod))
        let list = try XCTUnwrap(listed)
        XCTAssertEqual(list.tools.compactMap { $0["name"]?.stringValue }, ["spawn_task", "dismiss_task", "linear_list_issues"],
                       "No browser tools when they were off; a connector tool spelled like Yardlet's own is left out")

        let call = AgentToolCall(token: token, session: task.uuidString, tool: "spawn_task",
                                 arguments: try suggestionToolJSON(Self.arguments))
        let body = await broker.respond(to: try JSONEncoder().encode(call))
        let result = try JSONDecoder().decode(AgentToolResult.self, from: body)
        XCTAssertFalse(result.isError, result.text)
        let id = try XCTUnwrap(TaskSuggestionToolCatalog.taskID(inResult: result.text), result.text)
        XCTAssertNil(model.taskSuggestions.resolution(of: id, in: task), "Suggesting keeps nothing")
        let connectorCalls = connectors.calls
        XCTAssertTrue(connectorCalls.isEmpty, "Yardlet's own tool is never sent to a connector")

        let dismissed = await broker.handle(AgentToolCall(token: token, session: task.uuidString, tool: "dismiss_task",
                                                          arguments: .object(["task_id": .string(id)])))
        XCTAssertTrue(dismissed.text.contains("withdrawn"), dismissed.text)
        XCTAssertEqual(model.taskSuggestions.resolution(of: id, in: task)?.outcome, .dismissed)
        XCTAssertNil(model.taskSuggestions.resolution(of: id, in: UUID()), "Kept with the task that called")

        // Over the socket, as yardlet-mcp reaches the app.
        let directory = FileManager.default.temporaryDirectory.appending(path: "yts-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        let listener = try UnixSocketListener(path: path) { body, peer in await broker.respond(to: body, peer: peer) }
        defer { listener.stop() }
        var environment = launch.environment
        environment[AgentToolEnvironment.endpoint] = path
        let invoker = UnixSocketToolInvoker(environment: environment)
        let viaSocket = await invoker.call(tool: "spawn_task", arguments: try suggestionToolJSON(Self.arguments))
        XCTAssertNotNil(TaskSuggestionToolCatalog.taskID(inResult: viaSocket.text), viaSocket.text)
        let socketList = await invoker.listTools()?.tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(socketList?.prefix(2), ["spawn_task", "dismiss_task"])
        _ = model
    }

    func testTheAppChecksASuggestionAndSaysWhatBecameOfAWithdrawal() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let task = UUID()
        func respond(_ tool: String, _ arguments: [String: Any]) throws -> AgentToolResult {
            TaskSuggestionToolCall.respond(to: tool, arguments: JSONValue(try suggestionToolJSON(arguments)), taskID: task,
                                           store: store, newTaskID: { "task_0000beef" })
        }
        XCTAssertEqual(try respond("spawn_task", ["title": "T", "tldr": "S", "prompt": "  "]).text,
                       "prompt is required and cannot be empty.")
        let long = try respond("spawn_task", ["title": "T", "tldr": "S", "prompt": String(repeating: "a", count: 32_001)])
        XCTAssertTrue(long.isError)
        XCTAssertTrue(long.text.contains("32001"), long.text)
        let noted = try respond("spawn_task", Self.arguments)
        XCTAssertFalse(noted.isError)
        XCTAssertTrue(noted.text.hasPrefix("Noted (task_id: task_0000beef)."), noted.text)
        XCTAssertEqual(store.revision, 0, "A suggestion is not stored; the conversation holds it")

        let cleaned = TaskSuggestionToolCall.suggestion(from: JSONValue(try suggestionToolJSON([
            "title": "  " + String(repeating: "t", count: 300), "tldr": " Why ", "prompt": " Do it "
        ])))
        guard case let .success(suggestion) = cleaned else { return XCTFail("\(cleaned)") }
        XCTAssertEqual(suggestion.title?.count, 200)
        XCTAssertEqual(suggestion.tldr, "Why")
        XCTAssertEqual(suggestion.prompt, "Do it")
        XCTAssertFalse(suggestion.startsInNewWorktree)

        XCTAssertTrue(try respond("dismiss_task", ["task_id": "chip-1"]).isError)
        XCTAssertTrue(try respond("dismiss_task", ["task_id": "task_0000beef"]).text.contains("withdrawn"))
        XCTAssertTrue(try respond("dismiss_task", ["task_id": "task_0000beef"]).text.contains("already dismissed"))
        store.markStarted("task_0000cafe", in: task, startedTaskID: UUID())
        XCTAssertTrue(try respond("dismiss_task", ["task_id": "task_0000cafe"]).text.contains("already started"))
        XCTAssertEqual(store.resolution(of: "task_0000cafe", in: task)?.outcome, .started, "A started one stays started")
        XCTAssertTrue(try respond("spawn_tasks", [:]).isError)
    }

    // MARK: - The chip

    func testEachHarnessCallBecomesAChipOnceYardletAnswered() throws {
        // Claude Code, through Yardlet's own projector: the `tool_use` block, then its `tool_result`.
        let claude = try claudeActivity(result: Self.noted)
        guard case let .taskSuggestion(chip) = kind(claude.completed, harness: .claudeCode) else {
            return XCTFail("\(kind(claude.completed, harness: .claudeCode))")
        }
        XCTAssertEqual(chip, ConversationTaskSuggestion(
            id: "task_1a2b3c4d", title: "Remove the dead retry flag",
            tldr: "The retry flag in the uploader is never read since the queue rewrite. The new task deletes it.",
            prompt: "Delete `retryOnFailure` from Sources/Uploader/UploadOptions.swift and its two call sites.",
            startsInNewWorktree: true))
        guard case .tool = kind(claude.started, harness: .claudeCode, phase: .running) else {
            return XCTFail("A call still running is a tool line")
        }
        let claudeApp = try claudeActivity(result: Self.claudeAppResult, server: "ccd_session")
        guard case .tool = kind(claudeApp.completed, harness: .claudeCode) else {
            return XCTFail("The Claude app's own spawn_task, in an imported conversation, stays a tool line")
        }
        var failed = claude.completed
        failed.outcome = .failed
        guard case .tool = kind(failed, harness: .claudeCode, phase: .failed) else { return XCTFail("A failed call") }
        // Every completed call's input is read, a command with a lone `}` before its first `{` among
        // them (the session rail stopped the app on one).
        var command = claude.completed
        command.input = "sed -n '/^}/,/^{/p' main.c"
        XCTAssertNil(ConversationTaskSuggestionProjection.suggestion(from: command))
        XCTAssertNil(ConversationAgentRunProjection.arguments(in: command.input))

        // An ACP agent, in its own title, through the ACP projector.
        let acp = try XCTUnwrap(ACPEventProjector().activity(from: .object([
            "toolCallId": .string("call_7"), "title": .string("yardlet_spawn_task"), "kind": .string("other"),
            "status": .string("completed"), "rawInput": JSONValue(try suggestionToolJSON(Self.arguments)),
            "content": .array([.object(["type": .string("content"),
                                        "content": .object(["type": .string("text"), "text": .string(Self.noted)])])])
        ])))
        guard case let .taskSuggestion(acpChip) = kind(acp, harness: .openCode) else {
            return XCTFail("\(kind(acp, harness: .openCode))")
        }
        XCTAssertEqual(acpChip.id, "task_1a2b3c4d")
        XCTAssertTrue(acpChip.startsInNewWorktree)

        // Codex, through its decoder and conversation projection.
        let presentation = CodexConversationProjection.presentation(
            codexThread(items: [try codexCall(id: "mcp-1", server: "yardlet"), try codexCall(id: "mcp-2", server: "other")]),
            workspaceURL: URL(filePath: "/work/app"), historySelection: nil
        )
        let work = try XCTUnwrap(presentation.turns.first?.work)
        guard case let .taskSuggestion(codexChip) = work.first(where: { $0.id == "mcp-1" })?.kind else {
            return XCTFail("\(work.map(\.kind))")
        }
        XCTAssertEqual(codexChip.title, "Remove the dead retry flag")
        guard case .tool = work.first(where: { $0.id == "mcp-2" })?.kind else {
            return XCTFail("Another server's spawn_task is a tool line")
        }
    }

    func testSuggestionsStayTogetherAndInViewWhenTheTurnFolds() {
        func chip(_ id: String) -> ConversationItem {
            ConversationItem(id: id, kind: .taskSuggestion(ConversationTaskSuggestion(
                id: "task_0000000\(id.suffix(1))", title: id, tldr: nil, prompt: "p", startsInNewWorktree: false)),
                phase: .completed, source: .transcript(TranscriptEntry(content: .plan(""))))
        }
        let read = ToolRowWordingTests.claudeItem("Read", ["file_path": "/tmp/a"], phase: .completed)
        let grep = ToolRowWordingTests.claudeItem("Grep", ["pattern": "x"], phase: .completed)
        let runs = ConversationWorkGrouping.runs([read, grep, chip("a1"), chip("a2"), read, chip("a3")])
        XCTAssertEqual(runs.map(\.id), ["group-\(read.id)", "suggestions-a1", read.id, "suggestions-a3"])
        guard case let .suggestions(together) = runs[1] else { return XCTFail("\(runs)") }
        XCTAssertEqual(together.map(\.id), ["a1", "a2"], "Consecutive chips are one card, as the Claude app aggregates them")
        var turn = ConversationTurn(id: "t", status: .completed, timing: ConversationTurnTiming())
        turn.work = [read, chip("a1"), grep, chip("a2")]
        XCTAssertEqual(ConversationDrawOrder.keptRuns(turn, harness: .claudeCode).map(\.id),
                       ["suggestions-a1"], "A folded turn keeps its chips, still one card")
    }

    // MARK: - Start

    /// A draft saved while a chip's Options opened one (until 2026-10-22) still holds its suggestion.
    func testADraftHoldingASuggestionStartsTheSuggestionsTask() throws {
        let project = Project(name: "Uploader", primaryRoot: URL(filePath: "/work/uploader", directoryHint: .isDirectory))
        let source = UUID()
        let chip = suggestion(startsInNewWorktree: true)
        let draft = NewTaskDraft()
        draft.prepare(defaultProject: project, availableHarnesses: [.claudeCode])
        draft.text = chip.prompt
        draft.suggestion = NewTaskSuggestionOrigin(sourceTaskID: source, suggestionID: chip.id, title: chip.title,
                                                   prompt: chip.prompt)

        let restored = NewTaskDraft()
        restored.apply(try JSONDecoder().decode(HomeDraftSnapshot.self, from: JSONEncoder().encode(draft.snapshot)))
        XCTAssertEqual(restored.suggestion, draft.suggestion, "The suggestion survives a relaunch with the draft")
        let older = try JSONDecoder().decode(HomeDraftSnapshot.self, from: Data(#"{"text":"x","hasPreparedWorkspace":true}"#.utf8))
        XCTAssertNil(older.suggestion, "Drafts saved before it existed still load")

        // Sent as written, the task takes the suggestion's title and keeps it; edited, the request names it.
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: URL(filePath: "/tmp/claude"),
                                                             startsInNewWorktree: true))
        XCTAssertEqual(submission.suggestion, draft.suggestion)
        XCTAssertEqual(submission.title, "Remove the dead retry flag")
        XCTAssertEqual(submission.titleOrigin, .manual)
        draft.complete(submission, succeeded: true)
        XCTAssertNil(draft.suggestion, "The suggestion has its task")
        XCTAssertEqual(draft.text, "")

        let edited = NewTaskDraft()
        edited.prepare(defaultProject: project, availableHarnesses: [.claudeCode])
        edited.text = "Delete the flag, but keep the setting migration"
        edited.suggestion = NewTaskSuggestionOrigin(sourceTaskID: source, suggestionID: chip.id, title: chip.title,
                                                    prompt: chip.prompt)
        let editedSubmission = try XCTUnwrap(edited.beginSubmission(runtimeURL: URL(filePath: "/tmp/claude")))
        XCTAssertNotNil(editedSubmission.suggestion, "Still the suggestion's task")
        XCTAssertEqual(editedSubmission.title, SessionTitleProjection.provisionalTitle(from: edited.text))
        XCTAssertNil(editedSubmission.titleOrigin)
        edited.complete(editedSubmission, succeeded: false)
        edited.text = "  "
        XCTAssertNil(edited.suggestion, "An emptied draft lets the suggestion go")
    }

    func testATaskStartedFromAChipIsTheSuggestionsAndNestsUnderTheTaskThatSuggestedIt() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let adapter = SuggestionRecordingAdapter()
        let model = makeModel(adapter: adapter, worktrees: fixture.service())
        let project = model.projects.ensureProject(forRoot: repository, name: "Sample")
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: repository, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue", projectID: project.id)
        let chip = suggestion(startsInNewWorktree: true)

        let draft = NewTaskDraft()
        draft.text = chip.prompt
        draft.harness = .openCode
        draft.projectID = project.id
        draft.workspaceURL = repository
        draft.setStartsInNewWorktree(true, projectID: project.id)
        draft.suggestion = NewTaskSuggestionOrigin(sourceTaskID: source.id, suggestionID: chip.id, title: chip.title,
                                                   prompt: chip.prompt)
        let prompts = await adapter.prompts
        XCTAssertTrue(prompts.isEmpty, "Start sends nothing")
        let submission = try XCTUnwrap(draft.beginSubmission(
            runtimeURL: URL(filePath: "/tmp/opencode"), startsInNewWorktree: draft.startsInNewWorktree(projectID: project.id)))
        let created = try await model.createTask(submission)
        let task = try XCTUnwrap(created)
        draft.complete(submission, succeeded: true)

        let stored = try XCTUnwrap(model.store.sessions.first { $0.id == task.id })
        XCTAssertEqual(stored.title, "Remove the dead retry flag")
        XCTAssertEqual(stored.titleOrigin, .manual)
        XCTAssertEqual(stored.parentTaskID, source.id, "Nested under the task that suggested it")
        XCTAssertNotNil(model.worktrees.layout.worktreeURL(containing: stored.workspaceURL), "Started in a fresh worktree")
        XCTAssertEqual(stored.projectID, project.id)
        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id))
        XCTAssertEqual(resolution.outcome, .started)
        XCTAssertEqual(resolution.startedTaskID, task.id)
        let sent = await adapter.prompts
        XCTAssertEqual(sent, [chip.prompt], "The prompt went once, when the person sent the draft")
        await model.shutdown()
    }

    // MARK: - Start, Do it here

    func testASuggestionStartsInTheSuggestingTasksRepositoryAndProject() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let repository = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
        let project = Project(name: "uploader", primaryRoot: repository)
        let local = suggestion(startsInNewWorktree: false)
        func task(_ folder: URL, origin: URL? = nil, projectID: UUID? = nil) -> SessionRecord {
            SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                          title: "Rewrite the queue", projectID: projectID, originWorkspacePath: origin?.path(percentEncoded: false))
        }

        let inRepository = task(repository, projectID: project.id)
        let git: (URL) -> Bool = { _ in true }
        XCTAssertEqual(SuggestedTaskPlace.of(local, from: inRepository, in: [project], isRepository: git, home: home),
                       SuggestedTaskPlace(folder: repository, project: project, startsInNewWorktree: false),
                       "The suggesting task's own folder and project, not a chat")
        XCTAssertTrue(SuggestedTaskPlace.of(suggestion(startsInNewWorktree: true), from: inRepository, in: [project],
                                            isRepository: git, home: home).startsInNewWorktree, "A worktree when the agent asked")
        XCTAssertTrue(SuggestedTaskPlace.of(local, from: inRepository, in: [project], worktreeByDefault: { $0 == project.id },
                                            isRepository: git, home: home).startsInNewWorktree,
                      "Left to the person, the project's Local / New worktree choice")
        XCTAssertFalse(SuggestedTaskPlace.of(suggestion(startsInNewWorktree: true), from: inRepository, in: [project],
                                             worktreeByDefault: { _ in true }, isRepository: { _ in false },
                                             home: home).startsInNewWorktree,
                       "A folder outside Git starts locally, whatever was asked, as the new-task screen starts it")
        var asChat = local
        asChat.startsAsChat = true
        XCTAssertEqual(SuggestedTaskPlace.of(asChat, from: inRepository, in: [project], home: home),
                       SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false),
                       "The agent asked for a chat: no project, a folder made for it when it starts")

        // The Claude app's worktree sessions are kept as hidden one-folder projects of their own;
        // a child goes to the repository's project, in a worktree of its own, as the Claude app starts one.
        let worktree = repository.appending(path: ".claude/worktrees/brave-fox", directoryHint: .isDirectory)
        let hidden = Project(name: "brave-fox", primaryRoot: worktree, isHidden: true)
        XCTAssertEqual(SuggestedTaskPlace.of(local, from: task(worktree, origin: repository, projectID: hidden.id),
                                             in: [project, hidden], isRepository: git, home: home),
                       SuggestedTaskPlace(folder: repository, project: project, startsInNewWorktree: true))

        let chat = task(home.appending(path: "Documents/Yardlet/2026-10-22/notes", directoryHint: .isDirectory))
        XCTAssertEqual(SuggestedTaskPlace.of(local, from: chat, in: [project], home: home),
                       SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false), "A chat's starts a chat")

    }

    func testStartStartsTheTaskAtOnceUnderTheTaskThatSuggestedIt() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let repository = try fixture.makeRepository()
        let adapter = SuggestionRecordingAdapter()
        let model = makeModel(adapter: adapter, worktrees: fixture.service())
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .openCode)
        let project = model.projects.ensureProject(forRoot: repository, name: "Sample")
        let options = ["model": "sonnet", "effort": "high"]
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: repository, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue", providerOptions: options, projectID: project.id)
        let selected = model.store.selectedSessionID
        let chip = suggestion(startsInNewWorktree: true)

        await model.startTaskSuggestion(chip, from: source.id)

        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id))
        XCTAssertEqual(resolution.outcome, .started)
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == resolution.startedTaskID })
        XCTAssertEqual(task.parentTaskID, source.id, "Nested under the task that suggested it")
        XCTAssertEqual(task.projectID, project.id, "In its project, not a chat")
        XCTAssertEqual(task.harness, .openCode)
        XCTAssertNotNil(model.worktrees.layout.worktreeURL(containing: task.workspaceURL), "In a fresh worktree")
        XCTAssertEqual(task.title, "Remove the dead retry flag")
        XCTAssertEqual(task.titleOrigin, .manual)
        XCTAssertEqual(task.providerOptions, options, "The suggesting task's model and effort")
        XCTAssertEqual(model.store.selectedSessionID, selected, "The window stays where it is")
        XCTAssertNil(model.taskSuggestions.progress(of: chip.id, in: source.id))
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts, [chip.prompt], "The prompt went once, as the new task's first message")

        await model.startTaskSuggestion(chip, from: source.id)
        XCTAssertEqual(model.store.sessions.filter { $0.parentTaskID == source.id }.count, 1, "Started once")
        await model.shutdown()
    }

    func testAStartThatCannotHappenSaysWhyAndAFolderOutsideGitStartsLocally() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appending(path: "not-a-repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = makeModel(worktrees: fixture.service())
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue")
        let chip = suggestion(startsInNewWorktree: true)

        await model.startTaskSuggestion(chip, from: source.id)
        let unavailable = L10n.format("%@ is not available in Yardlet.", HarnessKind.openCode.displayName)
        XCTAssertEqual(model.taskSuggestions.progress(of: chip.id, in: source.id), .failed(unavailable))
        XCTAssertNil(model.taskSuggestions.resolution(of: chip.id, in: source.id), "Start can try again")
        XCTAssertEqual(model.store.sessions.map(\.id), [source.id], "Nothing started")

        // The agent asked for a worktree, but the folder is not in Git: it starts here, locally,
        // and the row says so quietly, as the new-task screen starts such a folder's tasks.
        let start = try XCTUnwrap(try? model.suggestedTaskStart(for: chip, from: source).get())
        XCTAssertFalse(start.place.startsInNewWorktree)
        let choice = model.suggestedTaskChoice(for: chip, start: start, in: source.id)
        XCTAssertTrue(model.suggestedTaskSettingsLabel(choice, for: chip)
            .hasPrefix(L10n.string("Local") + " · " + HarnessKind.openCode.displayName))
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .openCode)
        await model.startTaskSuggestion(chip, from: source.id)
        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id))
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == resolution.startedTaskID })
        XCTAssertEqual(task.workspaceURL.standardizedFileURL, folder.standardizedFileURL, "In the folder itself")
        XCTAssertNil(model.worktrees.layout.worktreeURL(containing: task.workspaceURL))
        await model.shutdown()
    }

    func testDoItHereSendsTheSuggestionToItsTaskAsTheClaudeAppDoes() async throws {
        let adapter = SuggestionRecordingAdapter()
        let model = makeModel(adapter: adapter)
        let folder = FileManager.default.temporaryDirectory.appending(path: "suggestion-here-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue")
        let chip = suggestion(startsInNewWorktree: true)

        await model.doTaskSuggestionHere(chip, in: source.id)
        let prompts = await adapter.prompts
        XCTAssertEqual(prompts, [L10n.format("Do this task here: “%@”", "Remove the dead retry flag")])
        XCTAssertEqual(model.taskSuggestions.resolution(of: chip.id, in: source.id)?.outcome, .sentHere)
        XCTAssertEqual(model.store.sessions.count, 1, "No other task")
        let answer = TaskSuggestionToolCall.respond(
            to: TaskSuggestionToolCatalog.dismissTask, arguments: .object(["task_id": .string(chip.id)]),
            taskID: source.id, store: model.taskSuggestions)
        XCTAssertTrue(answer.text.contains("done here"), answer.text)
        await model.shutdown()

        // Untitled, the summary names it, then the prompt's first line; quotes become the app's own.
        var untitled = suggestion(startsInNewWorktree: false)
        untitled.title = nil
        XCTAssertEqual(TaskSuggestionHereMessage.text(for: untitled),
                       L10n.format("Do this task here: “%@”", untitled.tldr ?? ""))
        untitled.tldr = nil
        untitled.prompt = "\n  Rename the “retry” flag\nand its call sites"
        XCTAssertEqual(TaskSuggestionHereMessage.text(for: untitled), L10n.format("Do this task here: “%@”", "Rename the 'retry' flag"))
        untitled.title = String(repeating: "a", count: 240)
        XCTAssertEqual(TaskSuggestionHereMessage.text(for: untitled),
                       L10n.format("Do this task here: “%@”", String(repeating: "a", count: 199) + "\u{2026}"))
    }

    // MARK: - Where the agent says it starts

    func testThePlaceArgumentsAreCheckedAsTheClaudeAppChecksCwd() throws {
        func parsed(_ extra: [String: Any]) throws -> Result<TaskSuggestionToolCall.Suggestion, TaskSuggestionToolCall.SuggestionError> {
            TaskSuggestionToolCall.suggestion(from: JSONValue(try suggestionToolJSON(Self.arguments.merging(extra) { $1 })))
        }
        XCTAssertEqual(try parsed(["cwd": " /work/web-app "]).map(\.cwd), .success("/work/web-app"))
        XCTAssertEqual(try parsed(["parent_task_id": "self"]).map(\.parentTaskReference), .success("self"))
        XCTAssertEqual(try parsed(["cwd": "work/rental"]), .failure(.cwdNotAbsolute("work/rental")))
        XCTAssertEqual(try parsed(["cwd": "/work/../etc"]), .failure(.cwdDotSegment))
        XCTAssertEqual(try parsed(["cwd": "/work", "parent_task_id": UUID().uuidString]), .failure(.cwdAndParent))
        XCTAssertEqual(try parsed(["parent_task_id": "CS"]), .failure(.parentNotATaskID("CS")))
        XCTAssertEqual(TaskSuggestionToolCall.SuggestionError.cwdNotAbsolute("x").message,
                       "cwd must be an absolute path (got \"x\"). Omit cwd to use the current project.")
        // A chat, as New Task's "No project": no other place with it, and no worktree to start in.
        XCTAssertEqual(try parsed(["chat": true]).map(\.startsAsChat), .success(true))
        XCTAssertEqual(try parsed([:]).map(\.startsAsChat), .success(false))
        XCTAssertEqual(try parsed(["chat": true, "cwd": "/work"]), .failure(.chatAndPlace))
        XCTAssertEqual(try parsed(["chat": true, "parent_task_id": "self"]), .failure(.chatAndPlace))
        XCTAssertEqual(try parsed(["chat": true, "useWorktree": true]).map(\.startsInNewWorktree), .success(false))
        XCTAssertEqual(ConversationTaskSuggestionProjection.suggestion(
            arguments: JSONValue(try suggestionToolJSON(Self.arguments.merging(["chat": true]) { $1 })),
            result: Self.noted)?.startsAsChat, true, "The chip keeps that it starts as a chat")

        let parent = UUID()
        let chip = ConversationTaskSuggestionProjection.suggestion(
            arguments: JSONValue(try suggestionToolJSON(Self.arguments.merging(["parent_task_id": parent.uuidString]) { $1 })),
            result: Self.noted)
        XCTAssertEqual(chip?.parentTaskID, parent, "The chip keeps the task it starts under")
        XCTAssertNil(ConversationTaskSuggestionProjection.suggestion(
            arguments: JSONValue(try suggestionToolJSON(Self.arguments.merging(["parent_task_id": "self"]) { $1 })),
            result: Self.noted)?.parentTaskID, "self is the task that suggested it")
    }

    func testANamedPlaceThatIsNotThereIsTheCallsError() async throws {
        let model = makeModel()
        let root = FileManager.default.temporaryDirectory.appending(path: "suggestion-places-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "notes.txt")
        try Data("x".utf8).write(to: file)
        let caller = try await model.store.createSession(
            harness: .openCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Caller")
        let open = try await model.store.createSession(
            harness: .openCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "CS replies")
        let archived = try await model.store.createSession(
            harness: .openCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Old")
        try await model.store.archiveSession(id: archived.id)

        func call(_ extra: [String: Any]) async throws -> AgentToolResult {
            await model.callTaskSuggestionTool(named: "spawn_task",
                                               arguments: try suggestionToolJSON(Self.arguments.merging(extra) { $1 }),
                                               sessionID: caller.id)
        }
        let missing = try await call(["cwd": root.appending(path: "gone").path(percentEncoded: false)])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("does not exist or is not a directory"), missing.text)
        let notAFolder = try await call(["cwd": file.path(percentEncoded: false)])
        XCTAssertTrue(notAFolder.isError, notAFolder.text)
        let noTask = try await call(["parent_task_id": UUID().uuidString])
        XCTAssertTrue(noTask.isError)
        XCTAssertTrue(noTask.text.hasPrefix("No task"), noTask.text)
        let archivedTask = try await call(["parent_task_id": archived.id.uuidString])
        XCTAssertTrue(archivedTask.isError)
        XCTAssertTrue(archivedTask.text.contains("is archived"), archivedTask.text)

        let folder = try await call(["cwd": root.path(percentEncoded: false)])
        XCTAssertFalse(folder.isError, folder.text)
        XCTAssertTrue(folder.text.contains("one click starts it as a new task in \(root.path(percentEncoded: false))"), folder.text)
        XCTAssertNotNil(TaskSuggestionToolCatalog.taskID(inResult: folder.text), "Still Yardlet's answer, so a chip")
        let underTask = try await call(["parent_task_id": open.id.uuidString])
        XCTAssertTrue(underTask.text.contains("nested under task \(open.id.uuidString) (CS replies)"), underTask.text)
        await model.shutdown()
    }

    func testStartNestsTheTaskUnderTheTaskTheAgentNamedOnThatTasksHarnessAndProject() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let here = try fixture.makeRepository(named: "uploader")
        let there = try fixture.makeRepository(named: "web-app")
        let adapter = SuggestionRecordingAdapter()
        let model = makeModel(adapter: adapter, worktrees: fixture.service())
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .openCode)
        let hereProject = model.projects.ensureProject(forRoot: here, name: "uploader")
        let thereProject = model.projects.ensureProject(forRoot: there, name: "web-app")
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: here, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue", providerOptions: ["model": "sonnet"], projectID: hereProject.id)
        let options = ["model": "opus", "effort": "low"]
        let parent = try await model.store.createSession(
            harness: .openCode, workspaceURL: there, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "CS replies", providerOptions: options, projectID: thereProject.id)
        var chip = suggestion(startsInNewWorktree: false)
        chip.parentTaskID = parent.id

        let start = try XCTUnwrap(try? model.suggestedTaskStart(for: chip, from: source).get())
        XCTAssertEqual(model.suggestedTaskPlaceLabel(for: chip, start: start, from: source),
                       L10n.format("As a subtask of ‘%@’", "CS replies"))
        await model.startTaskSuggestion(chip, from: source.id)

        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id),
                                       "The chip in the suggesting task reads Started")
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == resolution.startedTaskID })
        XCTAssertEqual(task.parentTaskID, parent.id, "Nested under the task the agent named")
        XCTAssertEqual(task.projectID, thereProject.id)
        XCTAssertEqual(task.workspaceURL.standardizedFileURL, there.standardizedFileURL, "That task's folder")
        XCTAssertEqual(task.providerOptions, options, "That task's model and effort")

        // The named task went away before Start: the row says so and nothing starts.
        var orphan = suggestion(startsInNewWorktree: false)
        orphan.id = "task_00000bad"
        orphan.parentTaskID = UUID()
        await model.startTaskSuggestion(orphan, from: source.id)
        XCTAssertEqual(model.taskSuggestions.progress(of: orphan.id, in: source.id),
                       .failed(L10n.string("The task it would start under is no longer open in Yardlet.")))
        XCTAssertEqual(model.store.sessions.count, 3)
        await model.shutdown()
    }

    func testStartWithAnotherProjectsRootStartsInAWorktreeUnderIt() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let here = try fixture.makeRepository(named: "uploader")
        let there = try fixture.makeRepository(named: "web-app")
        let model = makeModel(worktrees: fixture.service())
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .openCode)
        let thereProject = model.projects.ensureProject(forRoot: there, name: "web-app")
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: here, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue")
        var chip = suggestion(startsInNewWorktree: false)
        chip.cwd = there.path(percentEncoded: false)

        let start = try XCTUnwrap(try? model.suggestedTaskStart(for: chip, from: source).get())
        XCTAssertEqual(start.parent.id, source.id)
        XCTAssertTrue(start.place.startsInNewWorktree, "A repository's root: a fresh worktree under it")
        XCTAssertEqual(model.suggestedTaskPlaceLabel(for: chip, start: start, from: source),
                       L10n.format("Starts in %@", "web-app"))
        await model.startTaskSuggestion(chip, from: source.id)

        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id))
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == resolution.startedTaskID })
        XCTAssertEqual(task.parentTaskID, source.id, "Still nested under the task that suggested it")
        XCTAssertEqual(task.projectID, thereProject.id)
        XCTAssertNotNil(model.worktrees.layout.worktreeURL(containing: task.workspaceURL), "A fresh worktree")
        await model.shutdown()

        // A folder that is no repository is the folder itself, even when the agent asked for a worktree.
        let plain = fixture.root.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        chip.cwd = plain.path(percentEncoded: false)
        chip.startsInNewWorktree = true
        XCTAssertFalse(SuggestedTaskPlace.of(chip, from: source, in: []).startsInNewWorktree)
    }

    // MARK: - Options

    func testOptionsReadAndWriteWhatTheNewTaskControlsChoose() throws {
        let claude = ["model": "opus", "effort": "high", "permissionMode": "bypassPermissions", "other": "kept"]
        let choice = TaskSuggestionStartOptions.modelChoice(from: claude, harness: .claudeCode)
        XCTAssertEqual(choice, NewTaskModelChoice(model: "opus", effort: "high", permissionMode: "bypassPermissions"))
        var changed = choice
        changed?.model = "sonnet"
        XCTAssertEqual(TaskSuggestionStartOptions.providerOptions(claude, harness: .claudeCode, choice: changed),
                       ["model": "sonnet", "effort": "high", "permissionMode": "bypassPermissions", "other": "kept"],
                       "What the controls do not show stays")
        XCTAssertEqual(TaskSuggestionStartOptions.providerOptions(claude, harness: .claudeCode, choice: nil), ["other": "kept"])

        // Codex's permission is the new-task screen's choice too.
        let codex = [CodexRunLocation.storageKey: CodexRunLocation.dangerFullAccess.rawValue]
        XCTAssertEqual(TaskSuggestionStartOptions.modelChoice(from: codex, harness: .codex),
                       NewTaskModelChoice(model: nil, permissionMode: CodexRunLocation.dangerFullAccess.rawValue))
        XCTAssertNil(TaskSuggestionStartOptions.modelChoice(from: [:], harness: .codex))
        XCTAssertEqual(TaskSuggestionStartOptions.providerOptions(codex, harness: .codex,
            choice: NewTaskModelChoice(model: nil, permissionMode: CodexRunLocation.readOnly.rawValue)),
                       [CodexRunLocation.storageKey: CodexRunLocation.readOnly.rawValue])
        XCTAssertEqual(TaskSuggestionStartOptions.providerOptions(codex, harness: .codex, choice: nil),
                       [:], "Codex's default leaves the key out")

        let codexStart = TaskSuggestionStartChoice(harness: .codex, providerOptions: codex,
                                                   place: SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false))
        let codexOptions = TaskSuggestionStartOptions.sessionOptions(for: codexStart, catalogs: nil)
        XCTAssertEqual(codexOptions.permission?.title, CodexRunLocation.dangerFullAccess.displayName,
                       "Codex's sandbox, as the task composer offers it")
        let claudeStart = TaskSuggestionStartChoice(harness: .claudeCode, providerOptions: claude,
                                                    place: SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false))
        let claudeOptions = TaskSuggestionStartOptions.sessionOptions(for: claudeStart, catalogs: nil)
        XCTAssertEqual(TaskSuggestionStartOptions.summary(harness: .claudeCode, options: claudeOptions),
                       HarnessKind.claudeCode.displayName + " · " + L10n.string("Bypass permissions"))

        // A pick in Options is the start's choice at once, by the new-task screen's rule.
        let repository = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
        let notes = URL(filePath: "/work/notes", directoryHint: .isDirectory)
        let git: (URL) -> Bool = { $0 == repository }
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: URL(filePath: "/tmp/suggestion-options-none/claude"),
            codexHome: URL(filePath: "/tmp/suggestion-options-none/codex"),
            codexYardletHome: URL(filePath: "/tmp/suggestion-options-none/y")), environment: [:])
        let start = TaskSuggestionStartChoice(harness: .claudeCode, providerOptions: claude,
                                              place: SuggestedTaskPlace(folder: repository, project: nil, startsInNewWorktree: true))
        let accepting = TaskSuggestionStartOptions.choosing(.providerOption(id: ClaudeLaunchOption.permissionMode, value: "acceptEdits"),
                                                            in: start, catalogs: catalogs)
        XCTAssertEqual(accepting?.providerOptions,
                       ["model": "opus", "effort": "high", "permissionMode": "acceptEdits", "other": "kept"])
        XCTAssertEqual(accepting?.place, start.place)
        XCTAssertNil(TaskSuggestionStartOptions.choosing(.providerOption(id: ClaudeLaunchOption.permissionMode, value: "nonsense"),
                                                         in: start, catalogs: catalogs), "Only what the list offers")
        XCTAssertNil(TaskSuggestionStartOptions.choosing(harness: .claudeCode, in: start, options: [:], connection: nil),
                     "The harness already chosen keeps its choices")
        let onCodex = try XCTUnwrap(TaskSuggestionStartOptions.choosing(harness: .codex, in: start, options: codex, connection: nil))
        XCTAssertEqual(onCodex, TaskSuggestionStartChoice(harness: .codex, providerOptions: codex, place: start.place),
                       "Another harness takes its own options and account, in the same place")
        XCTAssertEqual(TaskSuggestionStartOptions.choosing(.codexRunLocation(.readOnly), in: onCodex, catalogs: catalogs)?
                        .providerOptions, [CodexRunLocation.storageKey: CodexRunLocation.readOnly.rawValue])
        XCTAssertEqual(start.startingInNewWorktree(false, isRepository: git).place.startsInNewWorktree, false)
        let moved = start.moving(to: notes, project: nil, isRepository: git)
        XCTAssertEqual(moved.place, SuggestedTaskPlace(folder: notes, project: nil, startsInNewWorktree: false),
                       "A folder outside Git has no worktree")
        XCTAssertFalse(moved.startingInNewWorktree(true, isRepository: git).place.startsInNewWorktree)
        XCTAssertTrue(moved.moving(to: repository, project: nil, isRepository: git)
                        .startingInNewWorktree(true, isRepository: git).place.startsInNewWorktree)
        XCTAssertEqual(start.moving(to: nil, project: nil, isRepository: git).place,
                       SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false), "A chat")
    }

    func testOptionsStartFromTheParentsLevelOnAnotherHarnessAndStartWhatWasChosen() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let here = try fixture.makeRepository(named: "uploader")
        let there = try fixture.makeRepository(named: "web-app")
        let adapter = SuggestionRecordingAdapter()
        let model = makeModel(adapter: adapter, worktrees: fixture.service())
        for harness in [HarnessKind.openCode, .kimiCode] { model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: harness) }
        let thereProject = model.projects.ensureProject(forRoot: there, name: "web-app")
        let source = try await model.store.createSession(
            harness: .openCode, workspaceURL: here, runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Rewrite the queue", providerOptions: ["model": "sonnet"])
        let bypassing = SessionRecord(harness: .claudeCode, workspaceURL: here, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                      title: "Bypassing", providerOptions: ["permissionMode": "bypassPermissions", "model": "opus"])
        XCTAssertEqual(model.suggestedTaskOptions(harness: .claudeCode, parent: bypassing),
                       ["permissionMode": "bypassPermissions", "model": "opus"], "The parent's own on its harness")
        XCTAssertEqual(model.suggestedTaskOptions(harness: .codex, parent: bypassing),
                       [CodexRunLocation.storageKey: CodexRunLocation.dangerFullAccess.rawValue],
                       "Another harness at the parent's level, in its words")

        let chip = suggestion(startsInNewWorktree: false)
        let start = try XCTUnwrap(try? model.suggestedTaskStart(for: chip, from: source).get())
        let defaults = model.suggestedTaskChoice(for: chip, start: start, in: source.id)
        XCTAssertEqual(defaults.harness, .openCode)
        XCTAssertEqual(defaults.providerOptions, ["model": "sonnet"])
        XCTAssertEqual(defaults.connection, source.connection, "The parent's account")
        XCTAssertTrue(model.suggestedTaskSettingsLabel(defaults, for: chip).hasPrefix(HarnessKind.openCode.displayName))

        // Options chose another harness and project: the row's Start starts with them.
        let chosen = TaskSuggestionStartChoice(
            harness: .kimiCode, providerOptions: ["model": "k2"],
            place: SuggestedTaskPlace(folder: there, project: thereProject, startsInNewWorktree: false))
        model.taskSuggestions.setChoice(chosen, of: chip.id, in: source.id)
        XCTAssertEqual(model.suggestedTaskPlaceLabel(for: chip, start: start, choice: chosen, from: source),
                       L10n.format("Starts in %@", "web-app"))
        await model.startTaskSuggestion(chip, from: source.id)

        let resolution = try XCTUnwrap(model.taskSuggestions.resolution(of: chip.id, in: source.id))
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == resolution.startedTaskID })
        XCTAssertEqual(task.harness, .kimiCode)
        XCTAssertEqual(task.providerOptions, ["model": "k2"])
        XCTAssertEqual(task.projectID, thereProject.id)
        XCTAssertEqual(task.workspaceURL.standardizedFileURL, there.standardizedFileURL)
        XCTAssertEqual(task.parentTaskID, source.id, "Still nested under the task that suggested it")
        await model.shutdown()
    }

    // MARK: - Dismiss

    func testADismissalIsKeptWithTheTaskThroughARelaunchAndArchiveAndGoesWithDeletion() async throws {
        let defaults = SuggestionVolatileDefaults()
        let repository = UserDefaultsTaskSuggestionRepository(defaults: defaults)
        let task = UUID()
        let first = TaskSuggestionStore(repository: repository)
        let before = first.revision
        first.dismiss("task_0000aaaa", in: task)
        XCTAssertGreaterThan(first.revision, before, "A chip that read it draws again")
        XCTAssertEqual(TaskSuggestionStore(repository: repository).resolution(of: "task_0000aaaa", in: task)?.outcome,
                       .dismissed, "A relaunch reads it back")
        XCTAssertNotNil(defaults.data(forKey: "Yardlet.taskSuggestions.\(task.uuidString)"))

        // The latest hundred are kept, as the Claude app keeps them.
        let many = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        var clock = Date(timeIntervalSince1970: 0)
        many.now = { clock.addTimeInterval(1); return clock }
        for index in 0..<105 { many.dismiss(String(format: "task_%08x", index), in: task) }
        XCTAssertNil(many.resolution(of: "task_00000000", in: task))
        XCTAssertNotNil(many.resolution(of: "task_00000068", in: task))

        // Through the app: archiving keeps it, deleting takes it along.
        let suggestions = InMemoryTaskSuggestionRepository()
        let model = makeModel(repository: suggestions)
        let kept = try await model.store.createSession(harness: .openCode, workspaceURL: URL(filePath: "/tmp/kept"),
                                                       runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Kept")
        let gone = try await model.store.createSession(harness: .openCode, workspaceURL: URL(filePath: "/tmp/gone"),
                                                       runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Gone")
        model.dismissTaskSuggestion("task_0000bbbb", in: kept.id)
        model.dismissTaskSuggestion("task_0000cccc", in: gone.id)
        await model.archive(kept)
        await model.delete(gone)
        XCTAssertEqual(suggestions.load(for: kept.id)["task_0000bbbb"]?.outcome, .dismissed)
        XCTAssertTrue(suggestions.load(for: gone.id).isEmpty)
        XCTAssertNil(model.taskSuggestions.resolution(of: "task_0000cccc", in: gone.id))
        await model.shutdown()
    }

    // MARK: - Fixtures

    static let claudeAppResult = "Noted (position 1, task_id: task_1a2b3c4d). A chip is showing for the user \u{2014} "
        + "they can start it in a fresh worktree with one click, or dismiss it. Continue your current work."

    private func suggestion(startsInNewWorktree: Bool) -> ConversationTaskSuggestion {
        ConversationTaskSuggestion(
            id: "task_1a2b3c4d", title: "Remove the dead retry flag",
            tldr: "The retry flag in the uploader is never read since the queue rewrite.",
            prompt: "Delete `retryOnFailure` from Sources/Uploader/UploadOptions.swift and its two call sites.",
            startsInNewWorktree: startsInNewWorktree)
    }

    private func kind(_ activity: HarnessActivity, harness: HarnessKind,
                      phase: ConversationItemPhase = .completed) -> ConversationItemKind {
        ConversationActivityProjection.kind(activity, harness: harness, phase: phase, isApproved: false)
    }

    /// A Claude Code MCP call as Yardlet's Claude projector reads its `tool_use` and `tool_result`.
    private func claudeActivity(result: String, server: String = "yardlet") throws
        -> (started: HarnessActivity, completed: HarnessActivity) {
        let id = "toolu_\(UUID().uuidString.prefix(8))"
        let block: JSONValue = .object(["type": .string("tool_use"), "id": .string(id),
                                        "name": .string("mcp__\(server)__spawn_task"),
                                        "input": JSONValue(try suggestionToolJSON(Self.arguments))])
        let projector = ClaudeEventProjector()
        let started = try XCTUnwrap(projector.payloads(from: .object([
            "type": .string("assistant"), "message": .object(["content": .array([block])])
        ])).compactMap { payload -> HarnessActivity? in
            if case let .activityStarted(activity) = payload { return activity }
            return nil
        }.first)
        let completed = try XCTUnwrap(projector.payloads(from: .object([
            "type": .string("user"),
            "message": .object(["content": .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string(id),
                "content": .array([.object(["type": .string("text"), "text": .string(result)])])
            ])])])
        ]), activities: [id: started]).compactMap { payload -> HarnessActivity? in
            if case let .activityCompleted(activity) = payload { return activity }
            return nil
        }.first)
        return (started, completed)
    }

    private func codexCall(id: String, server: String) throws -> JSONValue {
        .object([
            "id": .string(id), "type": .string("mcpToolCall"), "server": .string(server),
            "tool": .string("spawn_task"), "status": .string("completed"),
            "arguments": JSONValue(try suggestionToolJSON(Self.arguments)),
            "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(Self.noted)])])])
        ])
    }

    private func codexThread(items: [JSONValue]) -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-suggest")]))!
        var turn = decoder.turn(from: .object(["id": .string("turn-1"), "status": .string("completed"),
                                               "items": .array([])]), fallbackID: "turn-1")!
        turn.items = [decoder.item(from: .object([
            "id": .string("u1"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("Rewrite the upload queue")])])
        ]), fallbackID: "u1", lifecycle: .completed)] + items.enumerated().map { index, item in
            decoder.item(from: item, fallbackID: "mcp-\(index)", lifecycle: .completed)
        }
        thread.turns = [turn]
        return CodexTaskState(thread: thread)
    }

    private func makeBroker(browserTools: Bool) -> AgentToolBroker {
        AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: URL(filePath: "/bin/sh"),
                endpoint: "/tmp/Yardlet-tools-test/tools.sock",
                privateDirectory: URL(filePath: "/tmp/Yardlet-tools-test"),
                isEnabled: { browserTools }
            ),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) })
        )
    }

    private func makeModel(
        adapter: SuggestionRecordingAdapter = SuggestionRecordingAdapter(),
        worktrees: TaskWorktreeService = TaskWorktreeService(),
        repository: any TaskSuggestionRepository = InMemoryTaskSuggestionRepository()
    ) -> AppModel {
        AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                                     loadsPersistedSelections: false),
            registry: HarnessRegistry { _, _ in adapter },
            preferences: SuggestionVolatileDefaults(),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: SuggestionVolatileDefaults()),
            taskSuggestionRepository: repository,
            worktrees: worktrees,
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: QuietSuggestionNotificationCenter(),
            restoresIndexOnLaunch: false
        )
    }
}

func suggestionToolJSON(_ object: [String: Any]) throws -> ToolJSON {
    try JSONDecoder().decode(ToolJSON.self, from: JSONSerialization.data(withJSONObject: object))
}

/// Preferences held in memory, so nothing reaches the user's preferences. Safe from any thread, as
/// `UserDefaults` is: the app writes some of them from queues of its own, as `CodexCardWriter`
/// and `TranscriptSnapshotWriter` do.
final class SuggestionVolatileDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func set(_ value: Bool, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { lock.withLock { values[defaultName] = nil } }
}

private actor ForwardingInvoker: AgentToolInvoking {
    private(set) var calls: [(tool: String, arguments: ToolJSON)] = []

    nonisolated func call(tool: String, arguments: ToolJSON) async -> AgentToolResult {
        await record(tool, arguments)
        return .text(TaskSuggestionToolCatalog.notedResult(taskID: "task_00000001"))
    }

    private func record(_ tool: String, _ arguments: ToolJSON) { calls.append((tool, arguments)) }
}

/// A connector whose slug and tool spell one of Yardlet's own tools, beside an ordinary one.
@MainActor
private final class ClashingConnectors: ConnectorToolProviding {
    private(set) var calls: [String] = []
    var offersTools: Bool { false }
    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] {
        [.object(["name": .string("spawn_task")]), .object(["name": .string("linear_list_issues")])]
    }
    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
        calls.append(name)
        return .text("connector")
    }
}

/// Starts sessions without a runtime and records what it was asked to send.
actor SuggestionRecordingAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind = .openCode
    private(set) var prompts: [String] = []
    private var streams: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                             providerSessionID: UUID().uuidString.lowercased(), workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                             workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { prompts.append(prompt) }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
        streams[session.localSessionID] = continuation
        return stream
    }
    func close(_ session: HarnessSessionHandle) async {
        streams.removeValue(forKey: session.localSessionID)?.finish()
    }
}

private final class QuietSuggestionNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
