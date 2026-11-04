import Foundation
import XCTest
@testable import NativeHarnessClient

/// The rail's Agents card, the Background tasks card's real tasks and outputs, Codex's background
/// terminals and the Preview card. No provider, process or user data: a Claude
/// Code stream through the CLI projection, Codex threads as the App Server sends them, files in a
/// temporary folder.
@MainActor
final class SessionRailAgentsTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures

    // MARK: - Agents

    /// A Claude task's foreground and background agents are agents; its background shell stays a
    /// background task, and the composer's line lists only what the rail does not.
    func testClaudeSubagentsAreAgentsAndItsShellsStayBackgroundTasks() throws {
        let entries = try Self.claudeEntries()
        let agents = try XCTUnwrap(SessionRailAgents.make(harness: .claudeCode, entries: entries, codexState: nil))
        XCTAssertEqual(agents.agents.map(\.title), ["Survey the parser", "Read the docs"],
                       "The running agent first, then the finished one")
        XCTAssertEqual(agents.agents.map(\.status), [.running, .completed])
        XCTAssertEqual(agents.agents.first?.canStop, true)
        XCTAssertEqual(agents.agents.first?.opensPanel, true)
        XCTAssertEqual(agents.agents.first?.model, "claude-sonnet-5-5")
        XCTAssertEqual(agents.activeCount, 1)

        let tasks = BackgroundTasksProjection(entries: entries, includesAgents: false)
        XCTAssertEqual(tasks.rows.map(\.title), ["swift test"])
        let everything = BackgroundTasksProjection(entries: entries)
        XCTAssertEqual(Set(everything.rows.map(\.title)), ["swift test", "Survey the parser"])
        XCTAssertEqual(BackgroundTasksProjection(entries: entries, includesTasks: false).rows.map(\.title),
                       ["Survey the parser"])

        let rail = SessionRailContent.make(
            session: Fixtures.session(.claudeCode), projectName: "p",
            instructionSources: TaskInstructionSources(origin: .detected, paths: []), git: nil,
            options: ComposerSessionOptionsProjection.make(harness: .claudeCode, session: Fixtures.session(.claudeCode),
                                                            providerCapabilities: nil, providerUsage: nil,
                                                            entries: entries, isAttached: true),
            connectors: nil, account: nil, entries: entries, codexPlan: nil, pullRequest: nil, pullRequestState: nil)
        XCTAssertTrue(rail.cards(SessionRailPreferences()).contains(.agents))
        XCTAssertEqual(rail.rollup(.agents), L10n.format("%lld running", 1))
        XCTAssertEqual(rail.backgroundTasks?.rows.map(\.title), ["swift test"])
        XCTAssertEqual(rail.rollup(.backgroundTasks), L10n.format("%lld running", 1))
    }

    /// A `run_agent` call reads its state from the subagent the app holds, its request with it; one
    /// from an earlier launch keeps how its call ended; one its own subagent ran is listed too.
    func testYardletSubagentsReadTheirRunAndCarryTheirRequests() throws {
        let heldID = UUID()
        let keptID = UUID()
        var builder = TranscriptBuilder()
        builder.appendUser("Review the change")
        builder.apply(.activityStarted(HarnessActivity(
            id: "ra1", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"codex","model":"gpt-5.5","prompt":"Check the migration\nThen report"}"#)))
        builder.apply(.activityStarted(HarnessActivity(
            id: "ra0", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"claude-code","prompt":"Summarize the logs"}"#)))
        builder.apply(.activityCompleted(HarnessActivity(
            id: "ra0", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"claude-code","prompt":"Summarize the logs"}"#,
            output: "agent_id: \(keptID.uuidString)\nharness: claude-code · state: completed\n\nAll quiet.")))
        let request = ConversationRequest(id: "req-1", title: "Codex agent · gpt-5.5: Run swift test", state: .pending,
                                          source: .transcript(TranscriptEntry(content: .plan("x"))))
        let held = SessionRailAgents.Run(id: heldID, harness: .codex, model: "gpt-5.5",
                                         prompt: "Check the migration\nThen report", state: .waitingForApproval,
                                         startedAt: Date(timeIntervalSince1970: 100), requests: [request])
        let nested = SessionRailAgents.Run(id: UUID(), harness: .claudeCode, prompt: "Look up the API",
                                           state: .running, startedAt: Date(timeIntervalSince1970: 200), isTasksOwn: false)
        let agents = try XCTUnwrap(SessionRailAgents.make(harness: .claudeCode, entries: builder.entries, codexState: nil,
                                                          runs: [held, nested]))
        let byTitle = Dictionary(uniqueKeysWithValues: agents.agents.map { ($0.title, $0) })
        let check = try XCTUnwrap(byTitle["Check the migration"])
        XCTAssertEqual(check.status, .waiting)
        XCTAssertEqual(check.requests.map(\.id), ["req-1"])
        XCTAssertEqual(check.harnessLabel, "Codex · gpt-5.5")
        XCTAssertEqual(check.kind, .yardletAgent(agentID: heldID, prompt: "Check the migration\nThen report"))
        XCTAssertTrue(check.canStop)
        let kept = try XCTUnwrap(byTitle["Summarize the logs"])
        XCTAssertEqual(kept.status, .completed)
        XCTAssertEqual(kept.kind, .yardletAgent(agentID: keptID, prompt: "Summarize the logs"))
        XCTAssertFalse(kept.canStop)
        XCTAssertEqual(byTitle["Look up the API"]?.status, .running)

        let rail = SessionRailContent.make(
            session: Fixtures.session(.claudeCode), projectName: "p",
            instructionSources: TaskInstructionSources(origin: .detected, paths: []), git: nil,
            options: Self.options(.claudeCode), connectors: nil, account: nil, entries: builder.entries,
            codexPlan: nil, pullRequest: nil, pullRequestState: nil, agentRuns: [held, nested])
        XCTAssertEqual(rail.rollup(.agents), L10n.string("Needs approval"))
    }

    func testRepeatedPromptsKeepDistinctStableCallIdentities() throws {
        var builder = TranscriptBuilder()
        builder.appendUser("Review twice")
        for id in ["first", "second"] {
            builder.apply(.activityStarted(HarnessActivity(
                id: id, kind: "mcp__yardlet__run_agent", title: "run_agent",
                input: #"{"harness":"codex","prompt":"Review the change"}"#)))
        }
        let before = try XCTUnwrap(SessionRailAgents.make(harness: .claudeCode, entries: builder.entries, codexState: nil))
        XCTAssertEqual(before.agents.count, 2)
        XCTAssertEqual(Set(before.agents.map(\.id)).count, 2)
        builder.apply(.activityCompleted(HarnessActivity(
            id: "first", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"codex","prompt":"Review the change"}"#, output: "Done")))
        let after = try XCTUnwrap(SessionRailAgents.make(harness: .claudeCode, entries: builder.entries, codexState: nil))
        XCTAssertEqual(Set(after.agents.map(\.id)), Set(before.agents.map(\.id)))
        XCTAssertEqual(after.agents.filter { $0.status == .running }.count, 1)
        XCTAssertEqual(after.agents.filter { $0.status == .completed }.count, 1)

        // A rail draws on every publication of a task that handed out thousands of calls: each draw
        // reads only the calls that changed, and draws what reading them all would.
        var long = TranscriptBuilder(limit: 10_000)
        long.appendUser("Hand the work out")
        for index in 0..<2_000 {
            long.apply(.activityStarted(HarnessActivity(
                id: "call-\(index)", kind: "mcp__yardlet__run_agent", title: "run_agent",
                input: #"{"harness":"codex","model":"gpt-5.5","prompt":"Part \#(index)"}"#)))
        }
        let calls = SessionRailAgents.Calls()
        let first = SessionRailAgents.make(harness: .claudeCode, entries: long.entries, codexState: nil, calls: calls)
        XCTAssertEqual(calls.inputsRead, 2_000)
        XCTAssertEqual(first?.agents.count, 2_000)
        XCTAssertEqual(first?.agents.first?.harnessLabel, "Codex · gpt-5.5")
        _ = SessionRailAgents.make(harness: .claudeCode, entries: long.entries, codexState: nil, calls: calls)
        XCTAssertEqual(calls.inputsRead, 2_000, "An unchanged transcript is not read again")
        long.apply(.activityCompleted(HarnessActivity(
            id: "call-7", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"codex","model":"gpt-5.5","prompt":"Part 7"}"#, output: "Done")))
        let changed = SessionRailAgents.make(harness: .claudeCode, entries: long.entries, codexState: nil, calls: calls)
        XCTAssertEqual(calls.inputsRead, 2_001, "Only the call that changed is read again")
        XCTAssertEqual(changed, SessionRailAgents.make(harness: .claudeCode, entries: long.entries, codexState: nil))
    }

    /// Codex child threads come from the thread's own calls, with the state they last reported; once
    /// the task's turn ended, a child it last saw running is no longer called running.
    func testCodexChildThreadsFollowTheStatesTheThreadReported() throws {
        let running = try Self.codexState(turnStatus: "inProgress")
        let agents = try XCTUnwrap(SessionRailAgents.make(harness: .codex, entries: [], codexState: running))
        XCTAssertEqual(agents.agents.map(\.kind), [.codexThread("child-b"), .codexThread("child-a")])
        XCTAssertEqual(agents.agents.map(\.title), ["explorer", "Audit the build scripts"])
        XCTAssertEqual(agents.agents.map(\.status), [.running, .completed])
        XCTAssertEqual(agents.agents.last?.model, "gpt-5.5")
        XCTAssertTrue(agents.agents.allSatisfy(\.opensPanel))

        let ended = try Self.codexState(turnStatus: "completed")
        let after = try XCTUnwrap(SessionRailAgents.make(harness: .codex, entries: [], codexState: ended))
        XCTAssertEqual(after.agents.first { $0.kind == .codexThread("child-b") }?.status, .idle)
        XCTAssertEqual(after.activeCount, 0)
        XCTAssertEqual(SessionRailAgents.codexStatus("errored"), .failed)
        XCTAssertEqual(SessionRailAgents.codexStatus("shutdown"), .completed)
        XCTAssertNil(SessionRailAgents.codexStatus("later"))
    }

    /// A child task `create_task` made is a row that goes to the task, in the state its record says.
    func testChildTasksReadTheirRecordsState() {
        let base = Fixtures.session(.codex)
        func child(_ status: SessionStatus, _ completion: SessionCompletionState = .none) -> SessionRailAgents.Child {
            var record = base
            record.status = status
            record.completionState = completion
            return SessionRailAgents.Child(record)
        }
        XCTAssertEqual(child(.running).status, .running)
        XCTAssertEqual(child(.waitingForApproval).status, .waiting)
        XCTAssertEqual(child(.ready, .completed).status, .completed)
        XCTAssertEqual(child(.ready).status, .idle)
        XCTAssertEqual(child(.failed).status, .failed)
        var running = base
        running.status = .running
        XCTAssertEqual(SessionRailAgents.Child(running, waitsForPerson: true).status, .waiting)

        let agents = SessionRailAgents.make(harness: .claudeCode, entries: [], codexState: nil,
                                            children: [child(.running)])
        XCTAssertEqual(agents?.agents.first?.kind, .childTask(base.id))
        XCTAssertEqual(agents?.agents.first?.harnessLabel, "Codex", "A child on another harness names it")
        XCTAssertEqual(agents?.agents.first?.opensPanel, false, "It goes to the task instead")
        XCTAssertNil(SessionRailAgents.make(harness: .claudeCode, entries: [], codexState: nil), "No agents, no card")
    }

    // MARK: - Background work

    /// The CLI's output file is found by session and task under its temp root, and its newest part is
    /// read from a whole line; an ID that is not the CLI's finds nothing.
    func testAClaudeTaskOutputIsTheNewestPartOfItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-output-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString.lowercased()
        let tasks = root.appending(path: "-Users-me-project/\(session)/tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: tasks.appending(path: "b1a2c3d4e.output"))

        let reader = ClaudeTaskOutputReader(roots: [root], limit: 64)
        let output = try XCTUnwrap(reader.read(taskID: "b1a2c3d4e", sessionID: session))
        XCTAssertTrue(output.isTruncated)
        XCTAssertTrue(output.text.hasSuffix("line 200\n"))
        XCTAssertTrue(output.text.hasPrefix("line "), "It starts at a whole line")
        XCTAssertLessThanOrEqual(output.text.utf8.count, 64)
        XCTAssertEqual(ClaudeTaskOutputReader(roots: [root]).read(taskID: "b1a2c3d4e", sessionID: session)?.isTruncated,
                       false)
        XCTAssertNil(reader.read(taskID: "../b1a2c3d4e", sessionID: session))
        XCTAssertNil(reader.read(taskID: "b1a2c3d4e", sessionID: "not-a-session"))
        XCTAssertNil(reader.read(taskID: "other", sessionID: session))
    }

    /// Codex's background terminals are asked of the thread with the App Server's experimental calls.
    func testCodexBackgroundTerminalsAreTheThreadsOwnList() throws {
        XCTAssertEqual(CodexProtocol.listBackgroundTerminals(id: 1, threadID: "t").method, "thread/backgroundTerminals/list")
        XCTAssertEqual(CodexProtocol.listBackgroundTerminals(id: 1, threadID: "t", cursor: "c").params["cursor"],
                       .string("c"))
        let terminate = CodexProtocol.terminateBackgroundTerminal(id: 2, threadID: "t", processID: "p")
        XCTAssertEqual(terminate.method, "thread/backgroundTerminals/terminate")
        XCTAssertEqual(terminate.params["processId"], .string("p"))
        XCTAssertEqual(CodexProtocol.cleanBackgroundTerminals(id: 3, threadID: "t").params, .object(["threadId": .string("t")]))

        let listed = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"processId":"42","itemId":"call-1","command":"npm run dev","cwd":"/tmp/app","osPid":4242}
        """#.utf8))
        XCTAssertEqual(CodexBackgroundTerminal(json: listed),
                       CodexBackgroundTerminal(processID: "42", itemID: "call-1", command: "npm run dev",
                                               workspacePath: "/tmp/app"))
        XCTAssertNil(CodexBackgroundTerminal(json: .object(["itemId": .string("x"), "command": .string("y")])))

        let rail = SessionRailContent.make(
            session: Fixtures.session(.codex), projectName: "p",
            instructionSources: TaskInstructionSources(origin: .detected, paths: []), git: nil,
            options: Self.options(.codex), connectors: nil, account: nil, entries: [], codexPlan: nil,
            pullRequest: nil, pullRequestState: nil,
            backgroundTerminals: [CodexBackgroundTerminal(processID: "42", itemID: "i", command: "npm run dev", workspacePath: "")])
        XCTAssertTrue(rail.has(.backgroundTasks))
        XCTAssertEqual(rail.rollup(.backgroundTasks), L10n.format("%lld running", 1))
    }

    // MARK: - Preview

    /// The browser preview is there while the turn runs after the agent drove a tab, and not while the
    /// side panel shows the browser; the computer-use preview is the running turn's newest screenshot.
    func testThePreviewFollowsTheTurnAndStepsAsideForTheBrowserPanel() throws {
        XCTAssertNotNil(SessionRailPreview.browser(tab: 3, title: "Docs", isTurnRunning: true, panelShowsBrowser: false))
        XCTAssertEqual(SessionRailPreview.browser(tab: 3, title: " ", isTurnRunning: true, panelShowsBrowser: false)?.caption,
                       L10n.string("Browser"))
        XCTAssertNil(SessionRailPreview.browser(tab: 3, title: "Docs", isTurnRunning: false, panelShowsBrowser: false))
        XCTAssertNil(SessionRailPreview.browser(tab: 3, title: "Docs", isTurnRunning: true, panelShowsBrowser: true))
        XCTAssertNil(SessionRailPreview.browser(tab: nil, title: nil, isTurnRunning: true, panelShowsBrowser: false))

        let use = BrowserAgentUse()
        let session = UUID()
        use.noteUse(session: session, tab: 7)
        XCTAssertEqual(use.tabs[session], 7)
        use.endTurn(session: session)
        XCTAssertNil(use.tabs[session])
        use.noteUse(session: session, tab: 8)
        use.tabClosed(8)
        XCTAssertNil(use.tabs[session])

        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let state = try Self.codexComputerUse(turnStatus: "inProgress", image: png)
        let frame = try XCTUnwrap(SessionRailComputerFrame.latest(in: state))
        XCTAssertEqual(frame.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(frame.mimeType, "image/png")
        XCTAssertNil(SessionRailComputerFrame.latest(in: try Self.codexComputerUse(turnStatus: "completed", image: png)),
                     "It goes when the turn ends")
        XCTAssertTrue(SessionRailComputerFrame.isComputerUse(server: "computer-use"))
        XCTAssertFalse(SessionRailComputerFrame.isComputerUse(server: "yardlet"))
    }

    // MARK: - The side panel

    /// An agent's conversation or a task's output covers the side panel's tab and returns to it; it is
    /// not a tab and does not come back after a restart.
    func testAPanelDetailCoversTheShownTabAndReturnsToIt() throws {
        let state = TaskWorkspaceState(snapshot: TaskWorkspaceSnapshot(panels: .init(trailingSurfaceID: "files",
                                                                                     trailingTabs: ["files"])))
        state.showPanelDetail(.codexThread("child", title: "explorer"))
        XCTAssertEqual(state.panels.trailingSurfaceID, TaskPanelDetail.surfaceID)
        XCTAssertEqual(state.panels.trailingTabs, ["files"], "It is not a tab")
        XCTAssertEqual(state.panelDetail?.title, "explorer")
        state.showPanelDetail(.agentRun(UUID(), title: "Codex agent"))
        state.closePanelDetail()
        XCTAssertEqual(state.panels.trailingSurfaceID, "files", "Back to the tab it covered, past the detail it replaced")
        XCTAssertNil(state.panelDetail)

        let hidden = TaskWorkspaceState()
        hidden.showPanelDetail(.claudeTaskOutput(activityID: "a", title: "swift test"))
        let restored = TaskWorkspaceState(snapshot: hidden.snapshot)
        XCTAssertNil(restored.panels.trailingSurfaceID)
        hidden.closePanelDetail()
        XCTAssertNil(hidden.panels.trailingSurfaceID, "A panel the detail opened hides again")
        XCTAssertEqual(TaskSurfaceNavigationProjection.placement(for: TaskPanelDetail.surfaceID), .trailing)
    }

    // MARK: - Fixtures

    static func options(_ harness: HarnessKind) -> ComposerSessionOptions {
        ComposerSessionOptionsProjection.make(harness: harness, session: Fixtures.session(harness),
                                              providerCapabilities: nil, providerUsage: nil, isAttached: false)
    }

    /// A Claude task with a finished foreground agent, a background agent and a background shell.
    static func claudeEntries() throws -> [TranscriptEntry] {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Fix the parser bug")
        func apply(_ json: String) throws {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) {
                builder.apply(payload)
            }
        }
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"docs","name":"Agent","input":{"description":"Read the docs","prompt":"Read docs/","subagent_type":"general-purpose"}}]}}"#)
        try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"docs","content":"The docs say so."}]}}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"survey","name":"Agent","input":{"description":"Survey the parser","prompt":"Survey","model":"claude-sonnet-5-5","run_in_background":true}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"a-survey","tool_use_id":"survey","description":"Survey the parser","task_type":"local_agent","is_backgrounded":true}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"shell","name":"Bash","input":{"command":"swift test","run_in_background":true}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"swift test","task_type":"local_bash","is_backgrounded":true}"#)
        return builder.entries
    }

    /// A Codex thread that spawned one child and saw another start through `subAgentActivity`; the
    /// first child's `wait` reported it done.
    static func codexState(turnStatus: String) throws -> CodexTaskState {
        let json = #"""
        {"id":"parent","turns":[{"id":"turn-1","status":"\#(turnStatus)","items":[
          {"id":"u1","type":"userMessage","content":[{"type":"text","text":"Split the audit"}]},
          {"id":"c1","type":"collabAgentToolCall","tool":"spawnAgent","status":"completed","senderThreadId":"parent",
           "receiverThreadIds":["child-a"],"prompt":"Audit the build scripts\nand report","model":"gpt-5.5",
           "agentsStates":{"child-a":{"status":"running"}}},
          {"id":"s1","type":"subAgentActivity","agentThreadId":"child-b","agentPath":"/root/explorer","kind":"started"},
          {"id":"c2","type":"collabAgentToolCall","tool":"wait","status":"completed","senderThreadId":"parent",
           "receiverThreadIds":["child-a"],"agentsStates":{"child-a":{"status":"completed"}}}
        ]}]}
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return CodexTaskState(thread: try XCTUnwrap(CodexTaskDecoder().thread(from: value)))
    }

    /// A Codex turn whose computer-use call returned a screenshot.
    static func codexComputerUse(turnStatus: String, image: String, thread: String = "cu") throws -> CodexTaskState {
        let json = #"""
        {"id":"\#(thread)","turns":[{"id":"turn-1","status":"\#(turnStatus)","items":[
          {"id":"m1","type":"mcpToolCall","server":"computer-use","tool":"screenshot","status":"completed","arguments":{},
           "result":{"content":[{"type":"text","text":"Took a screenshot"},{"type":"image","data":"\#(image)","mimeType":"image/png"}]}}
        ]}]}
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return CodexTaskState(thread: try XCTUnwrap(CodexTaskDecoder().thread(from: value)))
    }
}
